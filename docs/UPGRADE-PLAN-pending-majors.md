# Upgrade plan — pending major bumps

**For:** A fresh Claude Code session (or operator) executing the three held-back upgrades from May 2026.
**Read first:** `CLAUDE.md` (root) for SSH conventions, the `docker compose down` warning, and gluetun-recreate gotchas.
**Working dir on local:** `/Users/uesh/Dev/arr-stack-ugreennas`
**Working dir on NAS:** `/volume2/docker/arr-stack`
**Deploy pattern (always):** edit local → `git commit && git push` → `git pull` on NAS → recreate the affected service. Never `docker compose down`.

The three upgrades below are **independent** — do them in any order, or just one. They are listed cheapest first.

---

## 1. TeslaMate v2.2.0 → v3.0.0 (non-breaking)

Currently runs with `image: teslamate/teslamate:latest` (line ~495 of `docker-compose.arr-stack.yml`). The `:latest` tag now resolves to v3.0.0. No compose edit is required — the bump is purely a re-pull.

### Pre-flight

1. Snapshot the TeslaMate Postgres DB (the user has 38h+ of drives stored). Run on the NAS:
   ```bash
   docker exec teslamate-db pg_dump -U teslamate teslamate | gzip > /tmp/teslamate-pre-v3-$(date +%Y%m%d).sql.gz
   ls -lh /tmp/teslamate-pre-v3-*.sql.gz
   ```
2. Confirm Tesla isn't actively driving (a mid-drive restart loses the in-flight trip segment). Check the TeslaMate web UI at `http://teslamate.lan` — vehicle should show `asleep` or `online idle`.

### Execute

```bash
ssh-to-nas "cd /volume2/docker/arr-stack && \
  docker compose -f docker-compose.arr-stack.yml pull teslamate && \
  docker compose -f docker-compose.arr-stack.yml up -d teslamate"
```

Wait ~60 s, then verify:
```bash
docker inspect teslamate --format 'label.version={{index .Config.Labels "org.opencontainers.image.version"}}'
# expected: v3.0.0
docker logs teslamate --since 2m 2>&1 | grep -iE 'error|fatal' | head
# expected: no fatal errors
curl -sI http://teslamate.lan | head -1
# expected: HTTP/1.1 302 (redirect to /sign_in)
```

### Known issues to flag to the user (from upstream v3.0.0 release notes)

- **"No Data" in Grafana dashboards** after the bump (Grafana 12.1.1 → 12.4.0 changed something internal). Workaround: in Grafana → Connections → Data sources → TeslaMate → click **Save & test**. Tell the user to do this once after the grafana bump in section 3.
- **Geofence-filtered dashboards fail when no Geofence is defined** (Grafana 12.4.0 regression). Workaround: define at least one Geofence in the TeslaMate UI before opening those dashboards. Will be fixed in v3.0.1.

### Rollback

```bash
docker compose -f docker-compose.arr-stack.yml stop teslamate
docker pull teslamate/teslamate:v2.2.0
# Edit docker-compose.arr-stack.yml: image: teslamate/teslamate:v2.2.0  (pin instead of :latest)
docker compose -f docker-compose.arr-stack.yml up -d teslamate
# If schema migrated: restore the dump from /tmp/teslamate-pre-v3-*.sql.gz:
gunzip -c /tmp/teslamate-pre-v3-*.sql.gz | docker exec -i teslamate-db psql -U teslamate teslamate
```

---

## 2. TeslaMate-Grafana (Grafana 12.1.1 → 12.4.0, dashboards re-bundled)

The `teslamate/grafana:latest` image ships TeslaMate's pre-built dashboards on top of the Grafana version that TeslaMate itself was tested against. **Bump it together with TeslaMate v3** — they ship in lockstep. Do this step *after* section 1.

### Execute

```bash
ssh-to-nas "cd /volume2/docker/arr-stack && \
  docker compose -f docker-compose.arr-stack.yml pull teslamate-grafana && \
  docker compose -f docker-compose.arr-stack.yml up -d teslamate-grafana"
```

Wait ~60 s, then verify:
```bash
docker exec teslamate-grafana grafana server -v 2>&1 | head -1
# expected: Version 12.4.0 (...)
curl -sI http://grafana-tesla.lan | head -1
# expected: HTTP/1.1 302 (Grafana login redirect)
```

### Post-bump action (manual, in Grafana web UI at `http://grafana-tesla.lan`)

1. Log in (default `admin` / set password if first run).
2. **Connections → Data sources → TeslaMate → Save & test.** This fixes the "No Data" regression flagged above.
3. Spot-check the **Drives** and **Overview** dashboards — both should render.

### Rollback

```bash
docker pull teslamate/grafana:v2.2.0   # match the previous teslamate version
# Edit compose: image: teslamate/grafana:v2.2.0
docker compose -f docker-compose.arr-stack.yml up -d teslamate-grafana
```

Dashboards live in the image; they reset to whatever the image ships, so user customizations to dashboard JSON would need re-import. The user has not customized any (verify with `docker exec teslamate-grafana ls /etc/grafana/provisioning/dashboards/`).

---

## 3. Recyclarr v7.5.2 → v8.6.0 (BREAKING — most work)

Currently runs with `image: ghcr.io/recyclarr/recyclarr` (no tag, defaults to `latest`, line ~679). The `:latest` tag now resolves to v8.6.0. Two breaking changes affect this user's `recyclarr/recyclarr.yml`:

1. The `replace_existing_custom_formats` setting was **removed**. Recyclarr now does ID-first matching automatically.
2. **All official include templates were removed** from the `config-templates` repo. Every `include: - template:` entry in the user's config must be migrated.

Authoritative source: <https://recyclarr.dev/guide/upgrade-guide/v8.0/>. Re-fetch this page before editing — the migration recipe may have evolved.

### Current user config (for reference, do not blindly apply — re-read before editing)

`recyclarr/recyclarr.yml` uses these now-removed templates:

- **Sonarr:** `sonarr-quality-definition-series`, `sonarr-v4-quality-profile-web-1080p`, `sonarr-v4-custom-formats-web-1080p`, `sonarr-v4-quality-profile-web-2160p`, `sonarr-v4-custom-formats-web-2160p`, `sonarr-v4-quality-profile-anime`, `sonarr-v4-custom-formats-anime`, `sonarr-v4-quality-profile-bluray-web-1080p-french-multi-vo`, `sonarr-v4-custom-formats-bluray-web-1080p-french-multi-vo`
- **Radarr:** `radarr-quality-definition-movie`, `radarr-quality-profile-hd-bluray-web`, `radarr-custom-formats-hd-bluray-web`, `radarr-quality-profile-uhd-bluray-web`, `radarr-custom-formats-uhd-bluray-web`, `radarr-quality-profile-remux-web-1080p`, `radarr-custom-formats-remux-web-1080p`, `radarr-quality-profile-remux-web-2160p`, `radarr-custom-formats-remux-web-2160p`, `radarr-quality-profile-anime`, `radarr-custom-formats-anime`, `radarr-quality-profile-hd-bluray-web-french-multi-vo`, `radarr-custom-formats-hd-bluray-web-french-multi-vo`

Plus `replace_existing_custom_formats: true` (twice — sonarr + radarr blocks).

### Pre-flight

1. Save the current Sonarr + Radarr custom-format and quality-profile state (in case the migration produces a different result and you need to compare):
   ```bash
   ssh-to-nas '
     SKEY=$(docker exec sonarr awk -F"<|>" "/<ApiKey>/{print \$3}" /config/config.xml)
     RKEY=$(docker exec radarr awk -F"<|>" "/<ApiKey>/{print \$3}" /config/config.xml)
     mkdir -p /tmp/recyclarr-pre-v8
     for ep in customformat qualityprofile; do
       docker exec gluetun wget -qO- "http://localhost:8989/api/v3/$ep" --header="X-Api-Key: $SKEY" > /tmp/recyclarr-pre-v8/sonarr-$ep.json
       docker exec gluetun wget -qO- "http://localhost:7878/api/v3/$ep" --header="X-Api-Key: $RKEY" > /tmp/recyclarr-pre-v8/radarr-$ep.json
     done
     tar czf /tmp/recyclarr-pre-v8-$(date +%Y%m%d).tar.gz -C /tmp recyclarr-pre-v8
     ls -lh /tmp/recyclarr-pre-v8-*.tar.gz
   '
   ```
2. Back up the recyclarr.yml itself:
   ```bash
   cp recyclarr/recyclarr.yml recyclarr/recyclarr.yml.v7-backup
   ```
   (Add `recyclarr.yml.v7-backup` to `.gitignore` if not already covered, or remove after a successful migration.)

### Migration steps (do these in order, on local repo)

1. **Re-fetch the upgrade guide** to get the current recommended migration syntax — the v8 templates / config schema have evolved since v8.0:
   ```
   WebFetch https://recyclarr.dev/guide/upgrade-guide/v8.0/ → ask for: full migration recipe with current syntax and any post-v8.0 changes
   WebFetch https://recyclarr.dev/guide/yaml/getting-started/ → ask for: current example config showing guide-backed quality profiles + custom format groups
   ```
2. **Edit `recyclarr/recyclarr.yml`:**
   - Remove both occurrences of `replace_existing_custom_formats: true` (lines 6 and 25 as of this writing).
   - Replace each `- template: <name>` entry with the equivalent guide-backed quality profile / custom format group block. The TRaSH Guide IDs the templates referenced are still valid; they just need to be expressed inline now using the v8 schema.
   - Recyclarr v8 supports two patterns; pick whichever the upstream docs show as canonical for guide-backed profiles:
     - Inline `quality_profiles` with `trash_id` references (preferred for one-off profiles)
     - `resource_providers` + custom shared includes (preferred if you want to factor out shared logic)
3. **Validate the new config locally** before pushing:
   ```bash
   # Run a dry-run inside a v8 container against the current config
   ssh-to-nas '
     docker run --rm \
       -v /volume2/docker/arr-stack/recyclarr/recyclarr.yml:/config/recyclarr.yml:ro \
       -v /volume2/docker/arr-stack/recyclarr/secrets.yml:/config/secrets.yml:ro \
       ghcr.io/recyclarr/recyclarr:8 \
       sync --preview
   '
   ```
   The `--preview` (or whatever flag v8 uses — check the guide) shows what *would* change without writing. Iterate on `recyclarr.yml` until the preview shows the expected delta vs current state (which should be small if profile names match).
4. **Pin the major** to avoid silent v9 surprises later. In `docker-compose.arr-stack.yml` change:
   ```diff
   -    image: ghcr.io/recyclarr/recyclarr
   +    image: ghcr.io/recyclarr/recyclarr:8
   ```

### Deploy

```bash
git add recyclarr/recyclarr.yml docker-compose.arr-stack.yml
git commit -m "chore: migrate recyclarr to v8.x"
git push
ssh-to-nas "cd /volume2/docker/arr-stack && git pull && \
  docker compose -f docker-compose.arr-stack.yml pull recyclarr && \
  docker compose -f docker-compose.arr-stack.yml up -d recyclarr && \
  docker compose -f docker-compose.arr-stack.yml run --rm recyclarr sync"
```

The trailing `run --rm recyclarr sync` triggers an immediate sync (otherwise you'd wait until the daily cron at `${RECYCLARR_CRON:-@daily}`).

### Verify

- The sync command should exit 0 with no errors.
- Open Sonarr → Settings → Profiles → confirm the expected profiles still exist with the expected scores.
- Same for Radarr.
- If anything looks wrong, compare against the snapshot:
  ```bash
  diff <(docker exec gluetun wget -qO- "http://localhost:8989/api/v3/qualityprofile" --header="X-Api-Key: $SKEY") /tmp/recyclarr-pre-v8/sonarr-qualityprofile.json
  ```

### Rollback

```bash
# On local
git revert HEAD
git push
# On NAS
cd /volume2/docker/arr-stack && git pull
docker compose -f docker-compose.arr-stack.yml pull recyclarr
docker compose -f docker-compose.arr-stack.yml up -d recyclarr
docker compose -f docker-compose.arr-stack.yml run --rm recyclarr sync
```

If the v8 sync corrupted Sonarr/Radarr profile data badly enough that re-syncing v7 doesn't fix it, restore quality profiles + custom formats one by one from the JSON snapshots in `/tmp/recyclarr-pre-v8/` via the Sonarr/Radarr API (POST to `/api/v3/qualityprofile` and `/api/v3/customformat`).

---

## Verification once all three are done

```bash
ssh-to-nas '
  echo "--- recyclarr ---"
  docker exec recyclarr recyclarr --version
  echo "--- teslamate ---"
  docker inspect teslamate --format "{{index .Config.Labels \"org.opencontainers.image.version\"}}"
  echo "--- teslamate-grafana ---"
  docker exec teslamate-grafana grafana server -v 2>&1 | head -1
  echo "--- container health ---"
  docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "recyclarr|teslamate"
'
```

Expected:
- recyclarr: `v8.6.0` (or later)
- teslamate: `v3.0.0` (or later)
- teslamate-grafana: `Version 12.4.0` (or later)
- All containers show `Up X minutes (healthy)` (recyclarr has no healthcheck — `Up X minutes` is fine).

## What to update after a successful run

- Remove this file (or rename to `docs/UPGRADE-PLAN-completed-MAY-2026.md` if you want an audit trail).
- If recyclarr was pinned to `:8`, add a note in `CHANGELOG.md` under the next release.
- If you discovered new gotchas during the upgrade, append them to `docs/TROUBLESHOOTING.md`.
