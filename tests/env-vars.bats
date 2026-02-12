#!/usr/bin/env bats
# Environment variable coverage tests

setup() {
    load helpers/setup
}

@test "all compose variables are documented in .env.example" {
    local env_example="$REPO_ROOT/.env.example"
    [[ -f "$env_example" ]] || skip ".env.example not found"

    # Extract vars from .env.example (including commented ones)
    local documented_vars
    documented_vars=$(grep -E '^[# ]*[A-Z_][A-Z0-9_]*=' "$env_example" | \
        sed -E 's/^[# ]*([A-Z_][A-Z0-9_]*)=.*/\1/' | sort -u)

    # Extract all ${VAR} from compose files
    local missing=""
    for f in $(get_compose_files); do
        while IFS= read -r var; do
            [[ -z "$var" ]] && continue
            if ! echo "$documented_vars" | grep -qx "$var"; then
                missing+="  $var (in $(basename "$f"))\n"
            fi
        done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*' "$f" | sed 's/\${//' | sort -u)
    done

    if [[ -n "$missing" ]]; then
        fail "Variables not in .env.example:\n$missing"
    fi
}

@test ".env.example has no real secret values" {
    local env_example="$REPO_ROOT/.env.example"
    [[ -f "$env_example" ]] || skip ".env.example not found"

    # Check for patterns that look like real secrets (not placeholders)
    # WireGuard keys: 44 chars base64 ending in =
    if grep -E 'WIREGUARD_PRIVATE_KEY=[A-Za-z0-9+/]{43}=' "$env_example" | \
       grep -qvE '(your|here|example|placeholder|xxx)'; then
        fail ".env.example contains what looks like a real WireGuard key"
    fi

    # JWT tokens
    if grep -qE '=eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$env_example"; then
        fail ".env.example contains what looks like a JWT token"
    fi

    # Long random-looking strings in password fields
    if grep -E '(PASSWORD|SECRET)=[A-Za-z0-9+/]{30,}' "$env_example" | \
       grep -qvE '(your|here|example|placeholder|xxx|bcrypt)'; then
        fail ".env.example contains what looks like a real password"
    fi
}
