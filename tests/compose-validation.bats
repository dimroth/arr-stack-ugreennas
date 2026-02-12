#!/usr/bin/env bats
# Compose file validation tests

setup() {
    load helpers/setup
}

# Extract lines belonging to a specific service from a compose file
# Args: $1 = service name, $2 = file path
get_service_block() {
    local svc="$1" file="$2"
    awk -v svc="$svc" '
        $0 ~ "^  "svc":" { found=1; next }
        found && /^  [a-zA-Z#]/ { found=0 }
        found
    ' "$file"
}

@test "all compose files pass docker compose config" {
    skip "requires docker compose CLI"
    for f in $(get_compose_files); do
        run docker compose -f "$f" --env-file "$TEST_DIR/fixtures/.env.test" config -q
        assert_success
    done
}

@test "every service has a restart policy" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        local services
        services=$(awk '/^services:/{found=1; next} found && /^  [a-z]/{gsub(/:.*/, ""); gsub(/^  /, ""); print} found && /^[a-z]/{found=0}' "$f")
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local block
            block=$(get_service_block "$svc" "$f")
            if ! echo "$block" | grep -q 'restart:'; then
                fail "Service '$svc' in $fname is missing restart policy"
            fi
        done <<< "$services"
    done
}

@test "every service has logging config" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        local services
        services=$(awk '/^services:/{found=1; next} found && /^  [a-z]/{gsub(/:.*/, ""); gsub(/^  /, ""); print} found && /^[a-z]/{found=0}' "$f")
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local block
            block=$(get_service_block "$svc" "$f")
            if ! echo "$block" | grep -q 'logging:'; then
                fail "Service '$svc' in $fname is missing logging config"
            fi
        done <<< "$services"
    done
}

@test "no service uses privileged: true" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        if grep -qE 'privileged:[[:space:]]*true' "$f" 2>/dev/null; then
            fail "privileged: true found in $fname"
        fi
    done
}

@test "all images are pinned (no :latest, no missing tags)" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        while IFS= read -r line; do
            local image
            image=$(echo "$line" | sed -E 's/^[[:space:]]+image:[[:space:]]*//')
            [[ -z "$image" ]] && continue
            if [[ "$image" == *":latest"* ]]; then
                fail "Image '$image' in $fname uses :latest tag"
            fi
            if [[ "$image" != *":"* ]] && [[ "$image" != *'${'* ]]; then
                fail "Image '$image' in $fname has no version tag"
            fi
        done < <(grep -E '^[[:space:]]+image:[[:space:]]' "$f" 2>/dev/null)
    done
}
