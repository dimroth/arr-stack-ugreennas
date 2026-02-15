# Project Instructions for Claude Code

## ⚠️ FIRST: NAS SSH Access

**Before ANY SSH command, read `config.local.md` for hostname/IP and username.**

The SSH password is stored in `~/.ssh/.nas_pass` (local machine, not in repo). Use `sshpass -f` for all commands:

```bash
# Pattern for ALL NAS commands:
sshpass -f ~/.ssh/.nas_pass ssh USER@HOST 'COMMAND'

# With sudo (write password to temp file on NAS, then use it):
sshpass -f ~/.ssh/.nas_pass ssh USER@HOST 'python3 -c "import shutil; shutil.copy2(\"/dev/stdin\", \"/tmp/.sudopw\")" < ~/.ssh/.nas_pass && cat /tmp/.sudopw | sudo -S COMMAND && rm -f /tmp/.sudopw'
```

**⚠️ Password contains special characters (`\`, `!`, `*`).** Never use `sshpass -p` — it breaks. Always use `sshpass -f` with the password file.

**If `~/.ssh/.nas_pass` doesn't exist**, create it from `config.local.md`:
```bash
python3 -c "with open('$HOME/.ssh/.nas_pass', 'w') as f: f.write(r'PASSWORD_FROM_CONFIG')"
chmod 600 ~/.ssh/.nas_pass
```

**NEVER guess usernames or try random SSH keys. The credentials are in `config.local.md`.**

---

## What This Project Is

A Docker Compose media automation stack **that runs on a NAS**, not on this local machine. Users request TV shows/movies via Seerr → Sonarr/Radarr search for them → qBittorrent/SABnzbd download them (through VPN) → media appears in Jellyfin ready to watch.

**⚠️ IMPORTANT: This repo is the SOURCE CODE. The stack RUNS on a remote NAS.**
- Local machine (where Claude Code runs): Development, editing config files
- NAS (remote): Where Docker containers actually run
- **All `docker` commands must be run via SSH to the NAS** - they won't work locally
- See `config.local.md` for NAS hostname/IP and SSH credentials

**Key services:**
- **Jellyfin** - Media server (like Netflix for your own content)
- **Seerr** - Request portal for users to ask for shows/movies
- **Sonarr/Radarr** - TV/Movie managers that find and organize downloads
- **Prowlarr** - Indexer manager (finds download sources)
- **qBittorrent** - Torrent client (downloads via VPN)
- **SABnzbd** - Usenet client (downloads via VPN)
- **Gluetun** - VPN gateway container (protects all download traffic)
- **Pi-hole** - DNS + DHCP server (enables `.lan` domains, blocks ads, assigns IPs)
- **Tailscale** - Mesh VPN subnet router (full remote LAN access to `.lan` domains and admin UIs)
- **Traefik** - Reverse proxy (routes `sonarr.lan` → correct container)
- **Immich** - Self-hosted photo/video management (backup, facial recognition, smart search)
- **Recyclarr** - TRaSH Guide sync (auto-applies quality profiles/custom formats to Sonarr/Radarr)

**Networking:** Services behind VPN share Gluetun's network (`network_mode: service:gluetun`). They reach each other via `localhost`. Services outside the VPN reach them via `gluetun` hostname.

> **Note:** Jellyseerr was renamed to Seerr upstream. Old `jellyseerr.lan` / `jellyseerr.yourdomain.com` URLs redirect to `seerr.lan` / `seerr.yourdomain.com`.

---

## ⚠️ CRITICAL: Read Before Any Docker Commands

**Pi-hole provides DNS and DHCP for the entire LAN. Stopping it = no internet and no new IP assignments.**

```bash
# ❌ NEVER DO THIS - kills DNS, you lose connection before up -d runs
docker compose -f docker-compose.arr-stack.yml down
docker compose -f docker-compose.arr-stack.yml up -d

# ✅ ALWAYS USE THIS - atomic restart, Pi-hole back in seconds
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# ✅ OR USE THE WRAPPER SCRIPT
./scripts/restart-stack.sh
```

**If you lose internet:** Mobile hotspot → SSH to NAS IP → `docker compose -f docker-compose.arr-stack.yml up -d pihole`

**Pi-hole admin UI** is at `http://PIHOLE_LAN_IP/admin` (macvlan IP, e.g., `192.168.1.25`). NAS IP port mappings don't work with macvlan.

---

## Documentation Strategy

- **Public docs** (tracked): Generic instructions with placeholders (`yourdomain.com`, `YOUR_NAS_IP`)
- **Private config** (`config.local.md`, gitignored): Actual hostnames, IPs, usernames
- **Credentials** (`.env`, gitignored): Passwords and tokens

**Always read `config.local.md`** for actual deployment values (domain, IPs, NAS hostname).

## Security

**NEVER commit secrets.** Use `${VAR_NAME}` references in compose files, real values in `.env` (gitignored).

Forbidden in tracked files: API keys, passwords, tokens, private keys, public IPs, email addresses.

## File Locations

| Location | Purpose |
|----------|---------|
| Git repo (local) | Development |
| Git repo (NAS: `/volume2/docker/arr-stack/`) | Deployment via `git pull` |

**Deployed via git**: `docker-compose.*.yml`, `traefik/`, `scripts/`, `.claude/instructions.md`
**Gitignored but required on NAS**: `.env` (manual setup), app data directories
**Not needed on NAS**: `docs/`, `.env.example` (but git pull includes them, harmless)

## Deployment Workflow

**The NAS has a git clone of this repo. Deploy via git, not file copy.**

```bash
# 1. Commit and push locally
git add -A && git commit -m "..." && git push

# 2. Pull on NAS
sshpass -f ~/.ssh/.nas_pass ssh <user>@<nas-host> "cd /volume2/docker/arr-stack && git pull"

# 3. Restart affected services
sshpass -f ~/.ssh/.nas_pass ssh <user>@<nas-host> "docker restart traefik"  # For routing changes
sshpass -f ~/.ssh/.nas_pass ssh <user>@<nas-host> "cd /volume2/docker/arr-stack && docker compose -f docker-compose.arr-stack.yml up -d"  # For compose changes
```

## NAS Access

**See `config.local.md` for hostname and username. Password in `~/.ssh/.nas_pass`.**

**On any auth failure, immediately ask the user for credentials. Don't retry or guess.**

```bash
# SSH shorthand (always use sshpass -f, NEVER sshpass -p):
sshpass -f ~/.ssh/.nas_pass ssh <user>@<nas-host> 'command'

# SCP doesn't work on UGOS. Use stdin redirect (for rare cases):
sshpass -f ~/.ssh/.nas_pass ssh <user>@<nas-host> "cat > /path/file" < localfile

# Image updates need pull + recreate (restart keeps old image):
docker compose -f docker-compose.arr-stack.yml pull <service>
docker compose -f docker-compose.arr-stack.yml up -d <service>
```

## Service Networking

VPN services (Sonarr, Radarr, Prowlarr, qBittorrent, SABnzbd) use `network_mode: service:gluetun`.

| Route | Use |
|-------|-----|
| VPN → VPN (Sonarr/Radarr → qBittorrent) | `localhost` |
| Non-VPN → VPN (Seerr → Sonarr) | `gluetun` |
| Any → Non-VPN (Any → Jellyfin) | container name |

**Download client config**: Sonarr/Radarr → qBittorrent: Host=`localhost`, Port=`8085`. SABnzbd: Host=`localhost`, Port=`8080`.

**CRITICAL: When restarting gluetun, always recreate ALL dependent services.** Docker stores the actual container ID at creation time. If gluetun is recreated but dependents aren't, they point to a stale/non-existent network namespace and `localhost` connections fail between them.

```bash
# WRONG - leaves dependent services attached to old gluetun
docker compose -f docker-compose.arr-stack.yml up -d gluetun

# RIGHT - recreate everything to ensure correct network attachment
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

If you see "Unable to connect" errors between VPN-routed services (e.g., Sonarr → qBittorrent), check network attachment:
```bash
docker inspect gluetun --format '{{.Id}}' | cut -c1-12  # Get current gluetun ID
docker inspect sonarr --format '{{.HostConfig.NetworkMode}}'  # Should match
```

## Traefik Routing

Routes defined in `traefik/dynamic/vpn-services.yml`, NOT Docker labels.

Docker labels are minimal (`traefik.enable=true`, `traefik.docker.network=arr-stack`). To add routes, edit `vpn-services.yml`.

**Remote vs Local-only services:**
- **Remote** (via Cloudflare Tunnel): Jellyfin, Seerr, Traefik dashboard
- **Local-only** (NAS_IP:PORT or via VPN): Sonarr, Radarr, Prowlarr, qBittorrent, Bazarr, Pi-hole, Uptime Kuma, duc

Why local-only? These services default to "no login from local network". Cloudflare Tunnel traffic appears local, bypassing auth. Use Seerr for remote media requests.

## Cloudflare Tunnel

Dashboard path: **Zero Trust → Networks → Connectors → Cloudflare Tunnels → [tunnel] → Configure → Published application routes**

All routes point to `<NAS_IP>:8080` (Traefik). Traefik routes by Host header. See `config.local.md` for actual IPs and tunnel name.

## Pi-hole DNS + DHCP (v6+)

### ⚠️ CRITICAL: Pi-hole DNS/DHCP Dependency

**Pi-hole serves both DNS and DHCP. Stopping it = total network DNS failure + no new DHCP leases.**

This affects:
- All devices on the network (no internet)
- New device connections (no IP assignment via DHCP)
- SSH connections using hostnames (use IP instead)
- Claude Code sessions (can't reach API)

Pi-hole has a macvlan LAN IP (`PIHOLE_LAN_IP` in `.env`) for serving DHCP broadcasts on the physical network. DHCP is configured via the Pi-hole web UI (Settings → DHCP).

**IPv6 DNS gotcha:** Routers often advertise themselves as IPv6 DNS via Router Advertisement (RA/RDNSS), independently of DHCP. Devices prefer IPv6 DNS, so `.lan` domains fail because the router doesn't know about them. Fix: disable IPv6 DNS/DHCPv6/RDNSS on the router. Do NOT enable "SLAAC + RA" in Pi-hole — it reintroduces the dual-DNS conflict.

**NEVER run `docker compose down` on arr-stack** - it stops Pi-hole and you lose DNS before you can run `up -d`. The `down` command also REMOVES containers, so UGOS Docker UI can't restart them.

```bash
# WRONG - stops Pi-hole, kills DNS, removes containers, you're stuck
docker compose -f docker-compose.arr-stack.yml down
docker compose -f docker-compose.arr-stack.yml up -d  # Can't run this - no DNS!

# RIGHT - single atomic command, Pi-hole restarts immediately
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

### Emergency Recovery (Pi-hole Down)

If Pi-hole is down and you've lost DNS:

1. **Connect to mobile hotspot** (different network, uses mobile DNS)
2. **SSH to NAS using IP address** (not hostname):
   ```bash
   ssh <user>@<NAS_IP>  # e.g., ssh mooseadmin@10.10.0.10
   ```
3. **Start the stack**:
   ```bash
   cd /volume2/docker/arr-stack && docker compose -f docker-compose.arr-stack.yml up -d
   ```
4. **Wait 30 seconds**, reconnect to home WiFi - DNS restored

**Know your NAS IP!** Check `config.local.md` or your router's DHCP leases. Write it down somewhere accessible offline.

### Pi-hole Configuration

**⚠️ CRITICAL: Don't duplicate .lan domains**

Stack `.lan` domains are defined in `pihole/02-local-dns.conf` (dnsmasq config). User-specific domains can go in either:
- `02-local-dns.conf` (CLI)
- Pi-hole web UI (Local DNS → DNS Records) → writes to `pihole.toml`

**Never define the same domain in both places.** If both dnsmasq and pihole.toml define a domain with different IPs, resolution is unpredictable.

**Adding stack .lan domains** (use dnsmasq):
```bash
# On NAS - edit the config file
nano /volume2/docker/arr-stack/pihole/02-local-dns.conf

# Add your entry
address=/myservice.lan/10.10.0.XX

# Reload (or restart for bind-mount changes)
docker exec pihole pihole reloaddns
```

**TLDs**: `.local` fails in Docker (mDNS reserved). Use `.lan` for local DNS.

## Architecture

- **3 compose files**: traefik (infra), arr-stack (apps), cloudflared (tunnel)
- **Network**: arr-stack (172.20.0.0/24) static IPs, traefik-lan (macvlan, shared by Traefik + Pi-hole)
- **External access**: Cloudflare Tunnel (bypasses CGNAT)

## Adding Services

1. Add to `docker-compose.arr-stack.yml` with static IP
2. Add route to `traefik/dynamic/vpn-services.yml`
3. If VPN-routed: use `network_mode: service:gluetun`
4. Sync compose + traefik config to NAS

## Service Notes

| Service | Note |
|---------|------|
| Pi-hole | v6 API uses password not separate token. Serves DHCP via macvlan LAN IP (`PIHOLE_LAN_IP`). DHCP config via web UI. |
| Gluetun | VPN gateway. Services using it share IP 172.20.0.3. Uses Pi-hole DNS. `FIREWALL_OUTBOUND_SUBNETS` must include LAN for HA access |
| Cloudflared | SSL terminated at Cloudflare, Traefik receives HTTP |
| FlareSolverr | Cloudflare bypass for Prowlarr. Configure in Prowlarr: Settings → Indexers → add FlareSolverr with Host `flaresolverr.lan` |
| Tailscale | Mesh VPN subnet router (172.20.0.16 / `TAILSCALE_LAN_IP`). Advertises `LAN_SUBNET` for full remote LAN access. Auth: set `TS_AUTHKEY` in `.env` OR leave blank and check `docker logs tailscale` for login URL. `TS_AUTH_ONCE=true` so auth only needed on first launch. After deploy: approve routes + exit node in Tailscale admin console, add Pi-hole as DNS for `lan` search domain. |
| TeslaMate | Tesla data logger (172.20.0.6:4000). Logs drives, charges, battery health. Sign in with Tesla account at `teslamate.lan`. Requires `TESLAMATE_ENCRYPTION_KEY` and `TESLAMATE_DB_PASS` in `.env`. |
| TeslaMate Grafana | Pre-built dashboards for Tesla data (172.20.0.11:3000, mapped to NAS_IP:3100). Access at `grafana-tesla.lan`. Default login: admin/admin. |
| Mosquitto | MQTT broker for TeslaMate (172.20.0.17:1883). Internal only, no auth (local network). |
| Immich | Self-hosted photo/video management (172.20.0.18:2283). 4 containers: server, machine-learning (OpenVINO for Intel N100), PostgreSQL (with pgvecto.rs), Redis (Valkey). Photos stored at `/volume1/immich/upload`. Safe to expose publicly (built-in auth). First registered user becomes admin. Requires `IMMICH_VERSION` and `IMMICH_DB_PASSWORD` in `.env`. |
| Recyclarr | TRaSH Guide sync (172.20.0.22). No web UI. Config: `recyclarr/recyclarr.yml`, secrets: `recyclarr/secrets.yml` (gitignored). Manual sync: `docker compose run --rm recyclarr sync`. |

## Container Updates

UGOS handles automatic updates natively (no Watchtower needed):
- **Docker → Management → Image update**
- Update detection: enabled
- Update as scheduled: weekly

## Backups

### Prerequisites

**USB drive mounted at `/mnt/arr-backup`** for automated backups. Without it, backups stay in `/tmp` (cleared on reboot).

### Automated Daily Backup (6am)

Cron runs daily at 6am:
```
0 6 * * * /volume2/docker/arr-stack/scripts/backup-volumes.sh --tar /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

**How it works:**
1. Creates backup in `/tmp` first (reliable space)
2. Creates tarball (~13MB)
3. Checks actual tarball size vs USB space
4. Moves to USB only if space available
5. Falls back to `/tmp` with warning if USB full
6. EXIT trap ensures services stay running no matter what

**Does NOT stop services** - safe live backup. Keeps 7 days on USB.

### Manual Backup / Pull to Local

```bash
# Run backup manually on NAS
ssh <user>@<nas-host> "cd /volume2/docker/arr-stack && ./scripts/backup-volumes.sh --tar"

# Pull from /tmp to local repo (gitignored backups/ folder)
ssh <user>@<nas-host> "cat /tmp/arr-stack-backup-*.tar.gz" > backups/arr-stack-backup-$(date +%Y%m%d).tar.gz

# Or pull from USB drive
ssh <user>@<nas-host> "cat /mnt/arr-backup/arr-stack-backup-*.tar.gz" > backups/arr-stack-backup-$(date +%Y%m%d).tar.gz
```

### What's Backed Up

**Included** (~13MB compressed): gluetun, qbittorrent, prowlarr, bazarr, uptime-kuma, pihole-dnsmasq, seerr, sabnzbd configs.

**Excluded** (regeneratable): jellyfin-config (407MB), sonarr (43MB), radarr (110MB), pihole blocklists (138MB).

## Uptime Kuma SQLite

**Networking:** Uptime Kuma uses `extra_hosts` in `docker-compose.utilities.yml` to map `.lan` domains to Traefik's bridge IP (172.20.0.2). This is required because `.lan` domains resolve to Traefik's macvlan IP, which is unreachable from the Docker bridge network. When adding a new `.lan` service, add its `extra_hosts` entry too.

**Query monitors:**
```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id, name, url FROM monitor"
```

**Update monitor URL:**
```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "UPDATE monitor SET url='http://NEW_URL' WHERE id=ID"
docker restart uptime-kuma
```

**Add HTTP monitors:**

**CRITICAL: Always include `user_id=1` - monitors without it won't appear in the UI!**

```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "INSERT INTO monitor (name, type, url, interval, accepted_statuscodes_json, ignore_tls, active, maxretries, user_id) VALUES ('Service Name', 'http', 'http://service.lan/', 60, '[\"200-299\"]', 0, 1, 3, 1);"
docker restart uptime-kuma
```

**Add Docker container monitors** (for services without a web UI):

```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "INSERT INTO monitor (name, type, docker_container, docker_host, interval, accepted_statuscodes_json, active, maxretries, user_id) VALUES ('Container Name', 'docker', 'container-name', 1, '[\"200-299\"]', 1, 3, 1);"
docker restart uptime-kuma
```

`docker_host=1` references the pre-configured local Docker socket. The `docker_container` column holds the container name (NOT the `url` column).

**Monitor URL guidelines:**
- Use `.lan` URLs for services with Traefik routes (clickable in the dashboard)
- Use `/ping` endpoint for Sonarr/Radarr/Prowlarr (returns 200 without auth, e.g. `http://sonarr.lan/ping`)
- Use direct IPs for services without `.lan` routes (e.g. FlareSolverr: `http://172.20.0.10:8191/`)
- For auth-protected endpoints: `accepted_statuscodes_json='[\"200-299\",\"401\"]'`
- For HTTPS with self-signed cert: `ignore_tls=1`

## Bash Script Gotchas

**SSH command substitution with `set -e`**: When using `set -e` (exit on error), command substitution causes script exit if the command fails. Add `|| true` to prevent this:

```bash
# WRONG - script exits if SSH fails
result=$(ssh_to_nas "some command")

# RIGHT - gracefully handle SSH failure
result=$(ssh_to_nas "some command") || true
if [[ -z "$result" ]]; then
    echo "SKIP: SSH failed"
    return 0
fi
```

This pattern is used in `scripts/lib/check-env-backup.sh` and `check-uptime-monitors.sh`.

## Custom .lan Domains (User-Specific Services)

To add `.lan` domains for services outside this stack (e.g., Frigate, Home Assistant):

**1. Add DNS entry** (gitignored `pihole/02-local-dns.conf`):
```
address=/frigate.lan/TRAEFIK_LAN_IP
```

**2. Add Traefik route** (create `traefik/dynamic/my-services.local.yml` - gitignored):
```yaml
http:
  routers:
    frigate-lan:
      rule: "Host(`frigate.lan`)"
      entryPoints: [web]
      service: frigate-lan

  services:
    frigate-lan:
      loadBalancer:
        servers:
          - url: "http://172.20.0.30:5000"
```

**3. Deploy**:
```bash
# On NAS - reload Pi-hole DNS
docker exec pihole pihole restartdns
# Traefik picks up *.local.yml automatically
```

**Requirement**: Service must be on `arr-stack` network with a static IP.

## .env Gotchas

**Bcrypt hashes must be quoted** (they contain `$` which Docker interprets as variables):
```bash
# Wrong
TRAEFIK_DASHBOARD_AUTH=admin:$2y$05$abc...

# Correct
TRAEFIK_DASHBOARD_AUTH='admin:$2y$05$abc...'
```

## Troubleshooting: SABnzbd Stuck Downloads

If a movie/show shows "Downloading" in Radarr at 100% but has 0 B file size:

1. Check for `_UNPACK_*` directory buildup in `/volume1/Media/downloads/` — each is a failed unpack retry wasting 20-50 GB
2. The actual completed file is usually in `/volume1/Media/downloads/incomplete/<release>/` with an obfuscated filename
3. SABnzbd UI/API will likely be unresponsive (locked by the post-processing loop)
4. Fix: `docker stop sabnzbd` → delete `postproc2.sab` from admin dir → delete `_UNPACK_*` dirs → move file to movie folder → `docker start sabnzbd` → clear Radarr queue → trigger RefreshMovie
5. Key lesson: the SABnzbd history API delete does NOT clear the postproc queue — must delete `postproc2.sab` while stopped
6. See `docs/TROUBLESHOOTING.md` for full step-by-step

**SABnzbd API** (via container): `http://localhost:8080/api?apikey=KEY&mode=history&output=json`
**Radarr API** (via container): `http://localhost:7878/api/v3/...?apikey=KEY`

## GitHub Releases

**⚠️ CRITICAL: Always update CHANGELOG.md when creating a release.**

Update `CHANGELOG.md` BEFORE creating the GitHub release. The changelog is the permanent record; GitHub releases can change but the changelog is in the repo.

When creating release notes:
- Link to `docs/UPGRADING.md` for upgrade instructions instead of inline steps
- Keep notes concise - bullet points, not paragraphs
- Don't mention Reddit/community feedback as motivation for changes

**⚠️ CRITICAL: Force-pushing a tag resets the GitHub release to Draft status.**

When updating a release tag to a new commit:
```bash
# Move tag to new commit
git tag -d v1.x && git tag v1.x
git push origin :refs/tags/v1.x && git push origin v1.x

# REQUIRED: Fix the release status (force-push sets it to Draft)
gh release edit v1.x --draft=false --latest
```

**Always run `gh release edit` after force-pushing a tag.** Without it, the release stays Draft and won't show as Latest.
