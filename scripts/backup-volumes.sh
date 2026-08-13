#!/bin/bash
#
# Backup essential Docker named volumes for arr-stack
#
# Usage:
#   ./scripts/backup-volumes.sh [OPTIONS] [BACKUP_DIR]
#
# Backs up Docker named volumes holding configuration, plus teslamate-db via
# pg_dump (a live Postgres data dir copies torn and can refuse to start).
#
# Immich is checked but not copied: both its database dump and its photo
# originals go off-site via scripts/backup-to-b2.sh, and duplicating the ~140MB
# dump here would re-upload it twice nightly.
#
# Options:
#   --tar           Create a .tar.gz archive (recommended for off-NAS transfer)
#   --prefix NAME   Volume prefix (default: auto-detect from running containers)
#   --staging DIR   Where to assemble the copy before tarring (default: /tmp).
#                   /tmp is on the eMMC boot device, so scheduled runs should
#                   point this at a data volume.
#   --usb DIR_NAME  Dynamically find USB device under /mnt/@usb/sd*/ containing DIR_NAME
#                   (device letters change on reboot, so never hardcode e.g. /mnt/@usb/sdd1)
#
# Examples:
#   ./scripts/backup-volumes.sh --tar                     # Backup to /tmp, create tarball
#   ./scripts/backup-volumes.sh --tar ~/backups           # Backup to custom dir with tarball
#   ./scripts/backup-volumes.sh --tar --usb arr-backups   # Auto-find USB, save to arr-backups/
#   ./scripts/backup-volumes.sh --prefix media-stack      # Use custom volume prefix
#
# Pulling backup to another machine:
#   # Ugreen NAS (scp doesn't work with /tmp, use cat pipe):
#   ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
#
#   # Other systems (scp works normally):
#   scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
#
# Restoring a volume:
#   docker run --rm -v ./backup/gluetun-config:/source:ro \
#     -v PREFIX_gluetun-config:/dest alpine cp -a /source/. /dest/
#

# Don't use set -e as arithmetic operations can return non-zero

# --- Failure notifications via Home Assistant webhook ---
notify_failure() {
  local msg="${1:-Backup failed}"
  echo "ERROR: ${msg}"
  if [ -n "${HA_WEBHOOK_URL:-}" ]; then
    curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Arr Stack: Backup Failed\",\"message\":\"${msg}\"}" || true
  fi
}
STEP="initialising"
trap 'notify_failure "Failed during: ${STEP}. Check /var/log/arr-backup.log"' ERR

# Ensure critical services are running on ANY exit (normal, error, or interrupt)
ensure_services_running() {
  COMPOSE_FILE="/volume2/docker/arr-stack/docker-compose.arr-stack.yml"
  [ -f "$COMPOSE_FILE" ] || return 0

  CRITICAL="gluetun pihole sonarr radarr prowlarr qbittorrent jellyfin sabnzbd"
  STOPPED=""

  for svc in $CRITICAL; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$"; then
      STOPPED="$STOPPED $svc"
    fi
  done

  if [ -n "$STOPPED" ]; then
    echo ""
    echo "SAFETY: Ensuring services are running:$STOPPED"
    docker compose -f "$COMPOSE_FILE" up -d $STOPPED 2>/dev/null
  fi
}
trap 'ensure_services_running' EXIT

# Find USB backup directory dynamically (device letters change on reboot)
# Searches /mnt/@usb/sd*/ for a subdirectory matching the given name,
# falling back to the first non-empty mounted device.
find_usb_dir() {
  local dir_name="$1"
  local usb_base="/mnt/@usb"

  # First: look for an existing backup directory by name
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    if [ -d "$dev$dir_name" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  # Fallback: first non-empty mounted USB device
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    # Check it's actually mounted (not just an empty mount point)
    if [ "$(ls -A "$dev" 2>/dev/null)" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  echo "ERROR: No USB device found under $usb_base" >&2
  return 1
}

# Parse arguments
CREATE_TAR=false
BACKUP_DIR=""
VOLUME_PREFIX=""
USB_DIR_NAME=""
# Where the uncompressed copy is assembled before tarring. Defaults to /tmp,
# which on this NAS lives on the eMMC boot device; point it at a data volume
# for scheduled runs to avoid several hundred MB of flash writes per night.
STAGING_ROOT="/tmp"

while [[ $# -gt 0 ]]; do
  case $1 in
    --tar)
      CREATE_TAR=true
      shift
      ;;
    --prefix)
      VOLUME_PREFIX="$2"
      shift 2
      ;;
    --usb)
      USB_DIR_NAME="$2"
      shift 2
      ;;
    --staging)
      STAGING_ROOT="$2"
      shift 2
      ;;
    *)
      BACKUP_DIR="$1"
      shift
      ;;
  esac
done

# Resolve USB backup directory if --usb was specified
STEP="finding USB device"
if [ -n "$USB_DIR_NAME" ]; then
  BACKUP_DIR=$(find_usb_dir "$USB_DIR_NAME") || { notify_failure "Failed during: ${STEP}. No USB device found under /mnt/@usb/"; exit 1; }
  echo "USB device found: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
fi

STEP="detecting volume prefix"
# Auto-detect volume prefix from running containers if not specified
if [ -z "$VOLUME_PREFIX" ]; then
  # Try to find prefix from gluetun container's volumes
  VOLUME_PREFIX=$(docker inspect gluetun 2>/dev/null | grep -o '"[^"]*_gluetun-config"' | head -1 | tr -d '"' | sed 's/_gluetun-config$//' || true)

  # Fallback: check for any arr-stack-like volumes
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX=$(docker volume ls --format '{{.Name}}' | grep -o '^[^_]*' | grep -E 'arr-stack|media' | head -1 || true)
  fi

  # Final fallback
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX="arr-stack"
    echo "Warning: Could not auto-detect volume prefix, using '$VOLUME_PREFIX'"
    echo "         Use --prefix to specify if your volumes have a different prefix"
    echo ""
  fi
fi

# Backup location handling:
# - Always create backup in /tmp first (reliable space)
# - If destination specified and different from /tmp, move tarball there after checking space
FINAL_DEST="${BACKUP_DIR:-}"
BACKUP_DIR="${STAGING_ROOT}/arr-stack-backup-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR" || { notify_failure "Cannot create staging dir $BACKUP_DIR"; exit 1; }
# A stale staging dir from an interrupted run would leave deleted files behind
# in the tarball, so start clean.
rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null

# Sweep staging trees abandoned by interrupted runs. Historically staging was
# /tmp, which the NAS clears on reboot, so nothing ever cleaned up after itself.
# On a persistent volume that leaks ~700MB a night.
find "$STAGING_ROOT" -maxdepth 1 -name 'arr-stack-backup-*' -type d \
  ! -path "$BACKUP_DIR" -mtime +1 -exec rm -rf {} + 2>/dev/null

# Rotate old backups at final destination (keep 7 days)
KEEP_DAYS=7
if [ -n "$FINAL_DEST" ] && [ -d "$FINAL_DEST" ]; then
  find "$FINAL_DEST" -maxdepth 1 -name "arr-stack-backup-*" -type d -mtime +$KEEP_DAYS -exec rm -rf {} \; 2>/dev/null
  find "$FINAL_DEST" -maxdepth 1 -name "arr-stack-backup-*.tar.gz" -type f -mtime +$KEEP_DAYS -delete 2>/dev/null
fi

# Get current user for ownership fix (avoids needing sudo for tar)
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# Essential volumes only (small, hard to recreate)
# These are settings/configs that would require manual reconfiguration if lost
VOLUME_SUFFIXES=(
  gluetun-config          # VPN provider credentials and settings
  qbittorrent-config      # Client settings, categories, watched folders
  sabnzbd-config          # Usenet provider credentials and settings
  prowlarr-config         # Indexer configs and API keys
  bazarr-config           # Subtitle provider credentials
  uptime-kuma-data        # Monitor configurations
  pihole-etc-dnsmasq      # Custom DNS settings (small)
  tailscale-state         # Tailscale node identity and keys
  recyclarr-config        # TRaSH Guide sync cache and state
  vaultwarden-data        # Vault database (SQLite), attachments, config
)

# Request manager - detect which variant is in use (Jellyfin or Plex)
if docker volume inspect "${VOLUME_PREFIX}_seerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(seerr-config)
elif docker volume inspect "${VOLUME_PREFIX}_jellyseerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(jellyseerr-config)  # Legacy pre-Seerr migration
elif docker volume inspect "${VOLUME_PREFIX}_overseerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(overseerr-config)
fi

# Large volumes excluded by default (regenerate by re-scanning/re-downloading):
#   jellyfin-config (407MB) - library metadata, watch history (re-scan to rebuild)
#   plex-config             - same as above for Plex variant
#   sonarr-config (43MB)    - series database (re-scan to rebuild)
#   radarr-config (110MB)   - movie database (re-scan to rebuild)
#   pihole-etc-pihole (138MB) - blocklists auto-download on startup
#   jellyfin-cache          - transcoding cache, fully regenerates
#   duc-index               - disk usage index, regenerates on restart

STEP="backing up volumes"
echo "=== Arr-Stack Backup ==="
echo "Volume prefix: ${VOLUME_PREFIX}_*"
echo "Backup dir:    $BACKUP_DIR"
echo ""

BACKED_UP=0
SKIPPED=0
FAILED=0

for suffix in "${VOLUME_SUFFIXES[@]}"; do
  vol="${VOLUME_PREFIX}_${suffix}"

  if docker volume inspect "$vol" &>/dev/null; then
    echo -n "Backing up $suffix... "

    # Copy files and fix ownership in one container run
    # The chown ensures we can tar without sudo later
    if docker run --rm --name arr-backup-worker \
      -v "$vol":/source:ro \
      -v "$BACKUP_DIR":/backup \
      alpine sh -c "mkdir -p /backup/$suffix && cp -a /source/. /backup/$suffix/ && chown -R $CURRENT_UID:$CURRENT_GID /backup/$suffix" 2>/dev/null; then

      # Check if anything was actually copied
      if [ -d "$BACKUP_DIR/$suffix" ] && [ "$(ls -A "$BACKUP_DIR/$suffix" 2>/dev/null)" ]; then
        SIZE=$(du -sh "$BACKUP_DIR/$suffix" 2>/dev/null | cut -f1)
        echo "OK ($SIZE)"
        BACKED_UP=$((BACKED_UP + 1))
      else
        echo "OK (empty)"
        BACKED_UP=$((BACKED_UP + 1))
      fi
    else
      echo "FAILED (permission denied or volume error)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "Skipping $suffix (volume not found)"
    SKIPPED=$((SKIPPED + 1))
  fi
done

STEP="dumping databases"
# ─────────────────────────────────────────────────────────────────────────────
# Database dumps
#
# Postgres data directories must NOT be captured with a plain file copy while
# the server is running: the result is a torn snapshot that may refuse to
# start. Dump them through the server instead.
#
# Note that immich-postgres is deliberately absent here. Immich runs its own
# nightly dump into /volume1/immich/upload/backups/ (14 retained); we copy the
# newest one rather than dumping a second time.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Database dumps ==="

# TeslaMate - drive/charge history, years of data, not regenerable
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^teslamate-db$'; then
  echo -n "Dumping teslamate-db... "
  mkdir -p "$BACKUP_DIR/teslamate-db"
  if docker exec teslamate-db pg_dump -U teslamate -d teslamate --format=custom \
      > "$BACKUP_DIR/teslamate-db/teslamate.dump" 2>/dev/null \
     && [ -s "$BACKUP_DIR/teslamate-db/teslamate.dump" ]; then
    SIZE=$(du -sh "$BACKUP_DIR/teslamate-db/teslamate.dump" 2>/dev/null | cut -f1)
    echo "OK ($SIZE)"
    BACKED_UP=$((BACKED_UP + 1))
  else
    echo "FAILED (pg_dump error or empty output)"
    rm -rf "$BACKUP_DIR/teslamate-db"
    FAILED=$((FAILED + 1))
  fi
else
  echo "Skipping teslamate-db (container not running)"
  SKIPPED=$((SKIPPED + 1))
fi

# Immich - checked, deliberately NOT copied.
#
# Immich writes its own dump here nightly and scripts/backup-to-b2.sh already
# ships this whole directory to B2 alongside the photos the dump indexes.
# Copying it in here as well meant uploading the same ~140MB twice every night,
# since this tarball is re-uploaded in full each run. The dump is still backed
# up off-site; it just travels with the library rather than with the configs.
#
# The freshness check stays. It is the only thing that would tell you Immich's
# scheduled backup has been turned off, and a silently absent dump would mean
# the photos are backed up with no catalogue to restore them into.
IMMICH_BACKUP_DIR="/volume1/immich/upload/backups"
if [ -d "$IMMICH_BACKUP_DIR" ]; then
  echo -n "Checking Immich DB dump freshness... "
  NEWEST_IMMICH=$(ls -t "$IMMICH_BACKUP_DIR"/immich-db-backup-*.sql.gz 2>/dev/null | head -1)
  if [ -n "$NEWEST_IMMICH" ] && [ -s "$NEWEST_IMMICH" ]; then
    DUMP_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST_IMMICH") ) / 86400 ))
    SIZE=$(du -sh "$NEWEST_IMMICH" 2>/dev/null | cut -f1)
    echo "OK (${SIZE}, ${DUMP_AGE_DAYS}d old, backed up via B2 immich/backups/)"
    if [ "$DUMP_AGE_DAYS" -gt 2 ]; then
      echo "  WARNING: newest Immich dump is ${DUMP_AGE_DAYS} days old."
      echo "           Check Administration -> Settings -> Backup Settings in Immich."
      notify_failure "Immich DB dump is stale (${DUMP_AGE_DAYS} days old)"
    fi
  else
    echo "FAILED (no dumps found in $IMMICH_BACKUP_DIR)"
    notify_failure "No Immich DB dumps found - Immich's scheduled backup may be disabled"
    FAILED=$((FAILED + 1))
  fi
else
  echo "Skipping Immich DB check (${IMMICH_BACKUP_DIR} not found)"
  SKIPPED=$((SKIPPED + 1))
fi

echo ""
echo "Summary: $BACKED_UP backed up, $SKIPPED skipped, $FAILED failed"
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
echo "Total size: $TOTAL_SIZE"

# Warn about failures
if [ $FAILED -gt 0 ]; then
  echo ""
  echo "WARNING: Some volumes failed to backup. Check permissions."
  notify_failure "${FAILED} volume(s) failed to backup. ${BACKED_UP} succeeded, ${SKIPPED} skipped."
fi

STEP="creating tarball"
# Create tarball if requested
if [ "$CREATE_TAR" = true ]; then
  TARBALL="${BACKUP_DIR}.tar.gz"
  echo ""
  echo "Creating tarball..."

  # Exclusions, in order:
  #   ipc-socket        - qbittorrent socket, cannot be archived at all
  #   recyclarr resources - a clone of the TRaSH-Guides repo (~293MB), re-cloned
  #                       on the next sync; by far the largest thing in here
  #   logs / logs.db    - application logs, no restore value
  #   Sentry            - crash-report spool, no restore value
  # Together these cut the archive by roughly 390MB per night, which matters
  # because every byte is re-uploaded to B2 daily (the .tar.gz changes wholly).
  tar -czf "$TARBALL" \
    --exclude='*/ipc-socket' \
    --exclude='*/recyclarr-config/resources' \
    --exclude='*/logs' \
    --exclude='*/logs.db' \
    --exclude='*/Sentry' \
    -C "$(dirname "$BACKUP_DIR")" \
    "$(basename "$BACKUP_DIR")" 2>/dev/null

  TARBALL_SIZE_BYTES=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null)
  TARBALL_SIZE_MB=$(( TARBALL_SIZE_BYTES / 1024 / 1024 ))
  TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
  echo "Created: $TARBALL ($TARBALL_SIZE)"

  STEP="moving tarball to USB"
  # Move to final destination if specified and different from /tmp
  if [ -n "$FINAL_DEST" ] && [ "$FINAL_DEST" != "/tmp" ]; then
    AVAILABLE_MB=$(df -m "$FINAL_DEST" 2>/dev/null | awk 'NR==2 {print $4}')
    REQUIRED_MB=$(( TARBALL_SIZE_MB + 10 ))  # Actual size + 10MB buffer

    if [ -n "$AVAILABLE_MB" ] && [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
      echo ""
      echo "WARNING: Not enough space at $FINAL_DEST (${AVAILABLE_MB}MB free, need ${REQUIRED_MB}MB)"
      echo "         Tarball remains in /tmp - copy manually when space available"
    else
      FINAL_TARBALL="$FINAL_DEST/arr-stack-backup-$(date +%Y%m%d).tar.gz"
      if mv "$TARBALL" "$FINAL_TARBALL" 2>/dev/null; then
        TARBALL="$FINAL_TARBALL"
        echo "Moved to: $TARBALL"
      else
        notify_failure "Could not move tarball to ${FINAL_DEST}. Backup remains in ${STAGING_ROOT}."
      fi
    fi
  fi

  # Drop the uncompressed staging tree now that it is archived. Skipped when the
  # tarball could not be moved, so the only copy is never thrown away.
  if [ "$TARBALL" != "${BACKUP_DIR}.tar.gz" ] || [ -z "$FINAL_DEST" ]; then
    rm -rf "${BACKUP_DIR:?}"
  else
    echo "Keeping staging dir $BACKUP_DIR (tarball was not moved)"
  fi

  echo ""
  echo "To copy off-NAS:"
  echo "  # Ugreen NAS (scp doesn't work):"
  echo "  ssh user@nas 'cat $TARBALL' > ./backup.tar.gz"
fi

# Safety check runs via EXIT trap (ensure_services_running)

echo ""
if [[ "${TARBALL:-}" == /tmp/* ]]; then
  echo "NOTE: Backup is in /tmp, which is cleared on reboot and lives on the"
  echo "      eMMC boot device. Pass --staging and a destination on a data"
  echo "      volume for anything scheduled."
fi
echo ""
echo "To restore: docker run --rm -v ./backup/VOLUME:/src:ro -v ${VOLUME_PREFIX}_VOLUME:/dst alpine cp -a /src/. /dst/"
