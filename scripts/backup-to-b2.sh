#!/bin/bash
#
# Push backups off-site to Backblaze B2 via the rclone container.
#
# Three independent jobs:
#   1. immich  - photo/video originals + Immich's own Postgres dumps
#   2. stack   - the tarballs produced by backup-volumes.sh
#   3. files   - personal media directories (see FILE_SETS below)
#
# Every job is one-way: rclone sync writes only to B2 and never back to disk,
# and all sources are mounted read-only in the container.
#
# Usage:
#   ./scripts/backup-to-b2.sh              # all jobs
#   ./scripts/backup-to-b2.sh immich       # photos only
#   ./scripts/backup-to-b2.sh stack        # config tarballs only
#   ./scripts/backup-to-b2.sh files        # personal media only
#   ./scripts/backup-to-b2.sh files immich # several, in the order given
#   ./scripts/backup-to-b2.sh --dry-run    # show what would transfer
#
# Requires in .env:
#   B2_ACCOUNT_ID, B2_APP_KEY, B2_BUCKET
# Optional in .env:
#   B2_BWLIMIT      e.g. "20M" or "08:00,1M 22:00,off" (default: unlimited)
#   B2_MAX_DELETE   abort a sync that would delete more than N files (default: 500)
#
# Scheduled by cron; see docs/BACKUP.md.
#

set -uo pipefail

STACK_DIR="/volume2/docker/arr-stack"
COMPOSE_FILE="$STACK_DIR/docker-compose.arr-stack.yml"
ENV_FILE="$STACK_DIR/.env"
IMMICH_SRC="/volume1/immich/upload"
STACK_SRC="/volume2/docker/arr-stack-backups"
LOCK_FILE="/var/run/backup-to-b2.lock"

# Personal media directories, as "b2-prefix|container-path|host-glob".
#
# The container path must match a read-only mount on the rclone service in
# docker-compose.arr-stack.yml. The host glob is used only for the pre-flight
# "is the source actually there" check; it is a glob rather than a literal so
# that accented directory names cannot fail to match over a Unicode
# normalisation difference (NFC vs NFD).
FILE_SETS=(
  "harmony-photos|/data/harmony|/home/uesh/Photos/Harmony"
  "audio|/data/audio|/volume1/Audio"
  "photos|/data/photos|/volume1/Photos"
  "videos|/data/videos|/volume1/Vid*"
)

# ── Read a single key from .env without sourcing it ─────────────────────────
# .env contains unquoted values with spaces (BESZEL_KEY), so `source` breaks.
env_get() {
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

B2_BUCKET="$(env_get B2_BUCKET)"
B2_BWLIMIT="$(env_get B2_BWLIMIT)"
B2_MAX_DELETE="$(env_get B2_MAX_DELETE)"
B2_MAX_DELETE="${B2_MAX_DELETE:-500}"

TG_TOKEN="$(env_get DIUN_TELEGRAM_TOKEN)"
TG_CHAT="$(env_get DIUN_TELEGRAM_CHATID)"

# ── Notification ────────────────────────────────────────────────────────────
notify() {
  local msg="$1"
  echo "NOTIFY: $msg"
  if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
    curl -s -m 15 -X POST \
      "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT}" \
      -d "text=Arr Stack B2 backup: ${msg}" >/dev/null || true
  fi
  if [ -n "${HA_WEBHOOK_URL:-}" ]; then
    curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Arr Stack: B2 Backup\",\"message\":\"${msg}\"}" || true
  fi
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Argument parsing ────────────────────────────────────────────────────────
DRY_RUN=""
JOBS=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="--dry-run" ;;
    immich|stack|files) JOBS="$JOBS $arg" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
JOBS="${JOBS:-stack files immich}"

# ── Preconditions ───────────────────────────────────────────────────────────
if [ -z "$B2_BUCKET" ]; then
  notify "FAILED - B2_BUCKET not set in .env"
  exit 1
fi
if [ ! -f "$COMPOSE_FILE" ]; then
  notify "FAILED - compose file not found at $COMPOSE_FILE"
  exit 1
fi

# Single instance only. The first full upload takes days; a second cron firing
# on top of it would fight for bandwidth and B2 transactions.
# /var/run needs root; fall back to /tmp when run as an unprivileged user.
# The probe runs in a subshell because a failed redirection is reported by the
# shell itself, before any redirection of the command's own stderr applies.
if ! ( : >>"$LOCK_FILE" ) 2>/dev/null; then
  LOCK_FILE="/tmp/backup-to-b2.lock"
fi
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another run is still in progress, exiting."
  exit 0
fi

cd "$STACK_DIR" || { notify "FAILED - cannot cd to $STACK_DIR"; exit 1; }

# Shared rclone flags.
#
# The memory settings are not arbitrary. UGOS runs earlyoom, which SIGKILLs the
# highest-scoring process once free swap runs low, and this NAS sits at ~95%
# swap usage even at idle. Default B2 settings buffer
# chunk-size x transfers x upload-concurrency in RAM: 96MiB x 8 x 4 is far more
# than this box can spare, and earlyoom killed a first attempt at 962MiB RSS.
# 16MiB x 4 x 2 caps the buffers near 128MiB instead.
#
# --fast-list is cheap here (roughly 1KB per object, ~22k objects) and cuts B2
# class C transactions substantially.
RCLONE_FLAGS=(
  --fast-list
  --transfers 4
  --checkers 8
  --b2-chunk-size 16M
  --b2-upload-concurrency 2
  --retries 3
  --low-level-retries 10
  --stats 5m
  --stats-one-line
  --log-level INFO
  --max-delete "$B2_MAX_DELETE"
)
[ -n "$B2_BWLIMIT" ] && RCLONE_FLAGS+=(--bwlimit "$B2_BWLIMIT")
[ -n "$DRY_RUN" ] && RCLONE_FLAGS+=("$DRY_RUN")

run_rclone() {
  docker compose -f "$COMPOSE_FILE" run --rm rclone "$@"
}

FAILURES=""

# ── Job: immich ─────────────────────────────────────────────────────────────
# Excludes thumbs/ and encoded-video/ (about 53 GB) because Immich regenerates
# both from the originals. library/ holds the originals and is the only part
# that is genuinely unrecoverable; backups/ holds Immich's nightly pg dumps,
# without which the originals restore as an unsorted pile with no albums,
# faces, or users.
sync_immich() {
  log "=== immich -> b2:${B2_BUCKET}/immich ==="

  # Guard against syncing an empty source. If the bind mount were ever missing,
  # an unguarded `rclone sync` would read an empty dir and delete the entire
  # off-site copy.
  if [ ! -d "$IMMICH_SRC/library" ] || [ -z "$(ls -A "$IMMICH_SRC/library" 2>/dev/null)" ]; then
    notify "FAILED - $IMMICH_SRC/library missing or empty, refusing to sync"
    FAILURES="$FAILURES immich"
    return 1
  fi

  if run_rclone sync /data/immich "b2:${B2_BUCKET}/immich" \
      --exclude "/thumbs/**" \
      --exclude "/encoded-video/**" \
      "${RCLONE_FLAGS[@]}"; then
    log "immich sync OK"
  else
    log "immich sync FAILED (exit $?)"
    FAILURES="$FAILURES immich"
    return 1
  fi
}

# ── Job: stack ──────────────────────────────────────────────────────────────
sync_stack() {
  log "=== stack -> b2:${B2_BUCKET}/arr-stack ==="

  if [ ! -d "$STACK_SRC" ] || [ -z "$(ls -A "$STACK_SRC" 2>/dev/null)" ]; then
    log "No tarballs in $STACK_SRC yet, skipping."
    return 0
  fi

  # Only the finished archives. The exclusions below are a safety net in case a
  # staging or partial directory is ever created inside this folder: syncing an
  # uncompressed staging tree would upload hundreds of MB of files that the
  # tarball deliberately leaves out.
  if run_rclone sync /data/stack "b2:${B2_BUCKET}/arr-stack" \
      --include "/*.tar.gz" \
      "${RCLONE_FLAGS[@]}"; then
    log "stack sync OK"
  else
    log "stack sync FAILED (exit $?)"
    FAILURES="$FAILURES stack"
    return 1
  fi
}

# ── Job: files ──────────────────────────────────────────────────────────────
# Personal media directories. Each set is independent: one failing does not
# stop the rest, and each is reported separately.
sync_files() {
  log "=== files -> b2:${B2_BUCKET}/files ==="

  for entry in "${FILE_SETS[@]}"; do
    local name="${entry%%|*}"
    local rest="${entry#*|}"
    local cpath="${rest%%|*}"
    local hglob="${rest#*|}"

    # Same reasoning as the immich guard: syncing a source that failed to
    # mount would delete the off-site copy. Word splitting on the glob is
    # intended here.
    # shellcheck disable=SC2086
    local resolved
    resolved=$(ls -d $hglob 2>/dev/null | head -1)
    if [ -z "$resolved" ] || [ -z "$(ls -A "$resolved" 2>/dev/null)" ]; then
      log "  ${name}: source missing or empty ($hglob), skipping"
      notify "WARNING - ${name} source missing or empty, not synced"
      FAILURES="$FAILURES files:${name}"
      continue
    fi

    log "  ${name}: ${resolved} -> b2:${B2_BUCKET}/files/${name}"
    # NAS and OS bookkeeping, none of it worth off-site storage. Excluding
    # #recycle matters beyond the few KB it occupies today: without it, deleting
    # a large file on the NAS would quietly push a copy of it off-site.
    # Filter patterns are deliberately bare, not "**/name". In rclone a pattern
    # without a leading / matches at any depth, whereas "**/name" requires at
    # least one directory component and so silently misses a file sitting at the
    # root of the set. Verified: "**/.DS_Store" left 1 of 2 behind here.
    if run_rclone sync "$cpath" "b2:${B2_BUCKET}/files/${name}" \
        --exclude "/#recycle/**" \
        --exclude "@eaDir/**" \
        --exclude "desktop.ini" \
        --exclude ".DS_Store" \
        --exclude "Thumbs.db" \
        "${RCLONE_FLAGS[@]}"; then
      log "  ${name}: OK"
    else
      log "  ${name}: FAILED (exit $?)"
      FAILURES="$FAILURES files:${name}"
    fi
  done
}

START=$(date +%s)
for job in $JOBS; do
  case "$job" in
    immich) sync_immich ;;
    stack)  sync_stack ;;
    files)  sync_files ;;
  esac
done
ELAPSED=$(( $(date +%s) - START ))

if [ -n "$FAILURES" ]; then
  notify "FAILED jobs:${FAILURES} (after ${ELAPSED}s). Check /var/log/arr-backup.log"
  exit 1
fi

log "All jobs completed in ${ELAPSED}s"
exit 0
