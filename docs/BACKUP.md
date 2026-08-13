# Backup & Restore

This stack uses Docker named volumes for service data. This guide covers backing up and restoring your configuration.

There are two layers:

1. **Local** - `scripts/backup-volumes.sh` builds a nightly config tarball on `volume2`.
2. **Off-site** - `scripts/backup-to-b2.sh` pushes that tarball plus the Immich photo library to Backblaze B2.

## Prerequisites

**Storage for the local tarball**

Backups are written to `/volume2/docker/arr-stack-backups`, assembled first in
`/volume2/docker/arr-stack-staging`. Both are created automatically. Seven days
are retained and rotated.

> Do **not** stage in `/tmp`. On this NAS `/tmp` is on the eMMC boot device, so a
> nightly several-hundred-MB write cycle wears out flash that is painful to
> replace. And never stage *inside* the backups directory, or the B2 sync will
> upload the entire uncompressed tree.

**For off-site backup**

A Backblaze B2 bucket and an application key scoped to it. Set `B2_ACCOUNT_ID`,
`B2_APP_KEY`, and `B2_BUCKET` in `.env`. See [Off-Site Backup to Backblaze B2](#off-site-backup-to-backblaze-b2).

---

## What Gets Backed Up

`scripts/backup-volumes.sh` captures configuration that is hard to recreate,
plus two databases that cannot be safely file-copied:

| Item | Size | Contents |
|------|------|----------|
| gluetun-config | ~7MB | VPN provider settings |
| qbittorrent-config | ~42MB | Client settings, categories |
| sabnzbd-config | ~28MB | Usenet provider credentials |
| prowlarr-config | ~29MB | Indexer configs, API keys |
| bazarr-config | ~4MB | Subtitle provider credentials |
| uptime-kuma-data | ~18MB | Monitor configurations |
| pihole-etc-dnsmasq | ~4KB | Custom DNS settings |
| tailscale-state | ~48KB | Node identity and keys |
| recyclarr-config | ~3MB | Sync state and settings |
| vaultwarden-data | ~13MB | Password vault (SQLite), attachments |
| seerr-config | ~7MB | User accounts, requests |
| teslamate-db | ~19MB | `pg_dump` of drive/charge history |
| immich-db | ~140MB | Newest of Immich's own nightly dumps |

**Total: ~198MB compressed**

> **Postgres is dumped, never copied.** A file copy of a live Postgres data
> directory can be torn and refuse to start. `teslamate-db` goes through
> `pg_dump`; Immich already writes its own nightly dump into
> `/volume1/immich/upload/backups/` (14 retained) and the newest is copied in.

Immich's photo and video **originals are not in this tarball** - far too large.
They go off-site directly via `scripts/backup-to-b2.sh`.

## What's NOT Backed Up

Anything that regenerates automatically:

| Item | Size | Why Excluded |
|------|------|--------------|
| jellyfin-config | ~407MB | Re-scan library to rebuild metadata |
| sonarr-config | ~43MB | Re-scan library to rebuild |
| radarr-config | ~110MB | Re-scan library to rebuild |
| pihole-etc-pihole | ~138MB | Blocklists auto-download on startup |
| jellyfin-cache | ~43MB | Transcoding cache, fully regenerates |
| duc-index | ~20MB | Disk usage index, regenerates on restart |
| recyclarr `resources/` | ~293MB | Clone of the TRaSH-Guides repo, re-cloned on next sync |
| `logs/`, `logs.db`, `Sentry/` | ~100MB | Application logs and crash spool |
| Immich `thumbs/`, `encoded-video/` | ~53GB | Rebuilt from the originals |

> Excluding the last three matters more than it looks: the `.tar.gz` changes
> completely every night, so every excluded byte is a byte re-uploaded to B2
> daily. They cut the archive from ~466MB to ~198MB.

> **Note:** If you want to preserve watch history (Jellyfin) or avoid re-scanning, you can manually backup these volumes using the same docker command shown below.

---

## Running a Backup

### On the NAS

```bash
# SSH into your NAS first, then:
cd /volume2/docker/arr-stack
./scripts/backup-volumes.sh --tar \
  --staging /volume2/docker/arr-stack-staging \
  /volume2/docker/arr-stack-backups
```

Output:
```
=== Arr-Stack Backup ===
Volume prefix: arr-stack_*
Backup dir:    /volume2/docker/arr-stack-staging/arr-stack-backup-20260813

Backing up gluetun-config... OK (7.1M)
Backing up qbittorrent-config... OK (42M)
...
=== Database dumps ===
Dumping teslamate-db... OK (19M)
Copying newest Immich DB dump... OK (140M, 0d old)

Summary: 13 backed up, 0 skipped, 0 failed
Total size: 687M

Created: .../arr-stack-backup-20260813.tar.gz (198M)
Moved to: /volume2/docker/arr-stack-backups/arr-stack-backup-20260813.tar.gz
```

If the Immich dump is reported as more than 2 days old, the script warns and
sends a notification: Immich's scheduled backup has probably been turned off.
Check Administration → Settings → Backup Settings in the Immich UI.

### Copying Off-NAS

```bash
ssh user@nas "cat /volume2/docker/arr-stack-backups/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
```

`scp` does not work on UGOS, so use the `cat` pipe above.

---

## Restore

### Full Restore (New Installation)

1. Deploy the stack normally (see [Setup Guide](SETUP.md))
2. SSH into your NAS and stop the services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml down
   ```
3. Extract backup and restore each volume:
   ```bash
   tar -xzf backup.tar.gz
   cd arr-stack-backup-20241217

   for dir in */; do
     vol="arr-stack_${dir%/}"
     echo "Restoring $vol..."
     docker run --rm \
       -v "$(pwd)/$dir":/source:ro \
       -v "$vol":/dest \
       alpine cp -a /source/. /dest/
   done
   ```
4. Start services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml up -d
   ```

> The loop above restores `teslamate-db/` and `immich-db/` as plain directories,
> which does nothing useful. Those two are database dumps and must be replayed
> through their server; see [Restoring Databases](#restoring-databases).

### Single Volume Restore

```bash
# On NAS via SSH - example: restore seerr config
docker compose -f docker-compose.arr-stack.yml stop seerr

docker run --rm \
  -v ./backup/seerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine cp -a /source/. /dest/

docker compose -f docker-compose.arr-stack.yml start seerr
```

### Restoring Databases

**TeslaMate** (custom-format dump):
```bash
docker exec -i teslamate-db pg_restore -U teslamate -d teslamate --clean --if-exists < teslamate-db/teslamate.dump
docker restart teslamate
```

**Immich** (plain SQL, gzipped). Immich must be stopped so nothing writes while
the schema is replaced:
```bash
docker stop immich-server immich-machine-learning
gunzip -c immich-db/immich-db-backup-*.sql.gz | docker exec -i immich-postgres psql -U postgres -d immich
docker start immich-server immich-machine-learning
```

Restoring the Immich database without also restoring
`/volume1/immich/upload/library` (from B2) leaves you with a catalogue pointing
at files that are not there. Restore both, or neither.

### Restoring Immich Photos from B2

The `rclone` compose service mounts the Immich library **read-only** on purpose,
so a mistyped command can never write over the originals. A restore therefore
needs a one-off container with the mount writable:

```bash
cd /volume2/docker/arr-stack
set -a; B2_ACCOUNT_ID=$(grep ^B2_ACCOUNT_ID= .env | cut -d= -f2-); \
        B2_APP_KEY=$(grep ^B2_APP_KEY= .env | cut -d= -f2-); set +a

docker run --rm \
  -e RCLONE_CONFIG_B2_TYPE=b2 \
  -e RCLONE_CONFIG_B2_ACCOUNT="$B2_ACCOUNT_ID" \
  -e RCLONE_CONFIG_B2_KEY="$B2_APP_KEY" \
  -v /volume1/immich/upload:/data/immich \
  rclone/rclone:1.75 copy b2:YOUR_BUCKET/immich /data/immich --progress
```

Use `copy`, not `sync`: `copy` only adds and overwrites, while `sync` would
delete anything on disk that is missing from the bucket.

`thumbs/` and `encoded-video/` are deliberately absent from B2. Immich
regenerates both: Administration → Jobs → run *Generate Thumbnails* and
*Transcode Videos*.

---

## Script Options

```bash
./scripts/backup-volumes.sh [OPTIONS] [BACKUP_DIR]

Options:
  --tar           Create .tar.gz archive (recommended)
  --prefix NAME   Override volume prefix (default: auto-detect)
  --staging DIR   Where to assemble before tarring (default: /tmp)
  --usb DIR_NAME  Find a USB device under /mnt/@usb/sd*/ containing DIR_NAME

Examples:
  ./scripts/backup-volumes.sh --tar                    # Default location
  ./scripts/backup-volumes.sh --tar /path/to/backup    # Custom location
  ./scripts/backup-volumes.sh --prefix media-stack     # Custom prefix
  ./scripts/backup-volumes.sh --tar --staging /volume2/docker/arr-stack-staging /volume2/docker/arr-stack-backups
```

### Volume Prefix Auto-Detection

The script auto-detects your volume prefix from running containers. If you cloned the repo to a different directory (e.g., `media-stack` instead of `arr-stack`), it will detect this automatically.

If auto-detection fails, use `--prefix`:
```bash
./scripts/backup-volumes.sh --tar --prefix media-stack
```

### Jellyfin vs Plex

The script auto-detects which variant you're using and backs up the appropriate request manager:
- Jellyfin stack: `seerr-config`
- Plex stack: `overseerr-config`

---

## Automated Daily Backup

Two entries in the **root** crontab (`sudo crontab -l`):

```bash
# Local config tarball at 03:30
30 3 * * * cd /volume2/docker/arr-stack && ./scripts/backup-volumes.sh --tar --staging /volume2/docker/arr-stack-staging /volume2/docker/arr-stack-backups >> /var/log/arr-backup.log 2>&1

# Off-site push at 05:00
0 5 * * * /volume2/docker/arr-stack/scripts/backup-to-b2.sh >> /var/log/arr-backup.log 2>&1
```

Immich writes its own database dump at 02:00, so the 03:30 tarball always picks
up a fresh one, and the 05:00 push has a comfortable margin behind it.

**Features:**
- ✓ Stages on `volume2`, not the eMMC boot device
- ✓ Keeps 7 days locally, auto-rotates old ones
- ✓ Checks free space before moving the tarball into place
- ✓ EXIT trap ensures critical services stay running no matter what
- ✓ Does NOT stop services during backup
- ✓ Failures notify via Telegram (reuses the Diun bot credentials)

`/var/log/arr-backup.log` is rotated weekly by `/etc/logrotate.d/arr-backup`,
keeping 8 compressed generations.

**To modify the schedule:**
```bash
sudo crontab -e
```

---

## Off-Site Backup to Backblaze B2

`scripts/backup-to-b2.sh` drives an `rclone` container. That compose service sits
behind a `backup` profile, so `up -d --force-recreate` never starts it; it only
runs when invoked.

### Setup

1. Create a B2 bucket.
2. Create an application key **scoped to that bucket** with Read and Write.
   Never use the master key.
3. Add to `.env`:
   ```bash
   B2_ACCOUNT_ID=your_application_key_id
   B2_APP_KEY=your_application_key
   B2_BUCKET=your_bucket_name
   ```
4. Verify:
   ```bash
   docker compose -f docker-compose.arr-stack.yml run --rm rclone lsd b2:
   ```

The key never lands in an `rclone.conf`; it is passed through
`RCLONE_CONFIG_B2_*` environment variables at run time.

### Usage

```bash
./scripts/backup-to-b2.sh              # all jobs
./scripts/backup-to-b2.sh immich       # photo library only
./scripts/backup-to-b2.sh stack        # config tarballs only
./scripts/backup-to-b2.sh files        # personal media only
./scripts/backup-to-b2.sh --dry-run    # show what would transfer
```

Jobs run smallest-first by default (`stack files immich`) so a multi-hour Immich
run never delays the quick ones. The first Immich run uploads roughly 170GB and
takes hours. A `flock` guard means a cron firing on top of a still-running sync
exits immediately rather than competing for bandwidth.

### Bucket Layout

```
your-bucket/
├── immich/          # library/, upload/, profile/, backups/ (~170GB)
├── arr-stack/       # arr-stack-backup-YYYYMMDD.tar.gz (7 retained)
└── files/           # personal media, ~88GB total
    ├── harmony-photos/   # /home/uesh/Photos/Harmony   (~41GB)
    ├── audio/            # /volume1/Audio              (~1.2GB)
    ├── photos/           # /volume1/Photos             (~11GB)
    └── videos/           # /volume1/Vidéos             (~35GB)
```

### Adding a Directory to the `files` Job

Two edits, both required:

1. **Mount it read-only** on the `rclone` service in
   `docker-compose.arr-stack.yml`:
   ```yaml
   - /volume1/YourDir:/data/yourdir:ro
   ```
2. **Add an entry** to `FILE_SETS` in `scripts/backup-to-b2.sh`, as
   `b2-prefix|container-path|host-glob`:
   ```bash
   "yourdir|/data/yourdir|/volume1/YourDir"
   ```

Keep container paths ASCII even when the host path is not. `/volume1/Vidéos` is
mounted at `/data/videos` so no script has to carry an accented literal, and the
host entry is a glob (`/volume1/Vid*`) so the pre-flight check cannot fail over a
Unicode normalisation mismatch between NFC and NFD.

Each set excludes `#recycle/`, `@eaDir/`, `desktop.ini`, `.DS_Store`, and
`Thumbs.db`. Excluding the NAS recycle bin matters for more than space: without
it, deleting a large file on the NAS would quietly push a copy of it off-site.

### Safety Rails

These exist because a sync is a destructive operation pointed at your only
off-site copy:

| Rail | What it prevents |
|------|------------------|
| Source guard | Refuses to sync if `/volume1/immich/upload/library` is missing or empty, so a failed bind mount cannot empty the bucket |
| `--max-delete 500` | Aborts a run that would delete an implausible number of files (tune with `B2_MAX_DELETE`) |
| `hard_delete=false` | Deletions become hidden versions rather than immediate removals |
| Lifecycle rule | Hidden versions are purged 30 days after deletion, bounding both the recovery window and the bill |
| Read-only mounts | The container cannot write to the Immich library or the backups directory |
| `--include "/*.tar.gz"` | Only finished archives are pushed, never a staging tree |

Inspect or change the lifecycle rule:
```bash
docker compose -f docker-compose.arr-stack.yml run --rm rclone backend lifecycle b2:YOUR_BUCKET
docker compose -f docker-compose.arr-stack.yml run --rm rclone backend lifecycle b2:YOUR_BUCKET -o daysFromHidingToDeleting=30
```

### Throttling

The nightly push can saturate the uplink. Cap it in `.env`:
```bash
B2_BWLIMIT=20M                      # constant cap
B2_BWLIMIT="08:00,5M 22:00,off"     # slow by day, unlimited overnight
```

---

## Troubleshooting

### "Permission denied" errors
The backup script runs docker containers which handle permissions internally. If you see permission errors, ensure:
- You're in the docker group: `groups` should show `docker`
- Docker daemon is running: `docker ps`

### "Volume not found"
- Ensure services have been started at least once (volumes are created on first run)
- Check the volume prefix matches: `docker volume ls | grep config`

### Backup too large
Expect ~198MB, of which ~140MB is the Immich database dump. If it is much larger,
check that the tar exclusions still match reality: `recyclarr-config/resources`
alone is ~293MB.

### B2 sync uploads far more than expected
Confirm nothing is staging inside `/volume2/docker/arr-stack-backups`. The stack
job is restricted to `/*.tar.gz`, but an uncompressed tree left there wastes
local disk regardless.

### "Address already in use" when running rclone
The `rclone` service intentionally has no `container_name` and no static IP so
that several throwaway containers can coexist. If you add either back, only one
invocation can run at a time and an ad-hoc command will fail while the nightly
sync is running.

### Immich dump is stale
The tarball reports the age of the newest Immich dump and warns past 2 days.
Immich writes these itself; re-enable it under Administration → Settings →
Backup Settings.
