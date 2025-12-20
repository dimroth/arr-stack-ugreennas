# Quick Reference: URLs, Commands, Network

## Services & Network

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Traefik | 192.168.100.2 | 80, 443 | Reverse proxy |
| **Gluetun** | **192.168.100.3** | — | VPN gateway |
| ↳ qBittorrent | (via Gluetun) | 8085 | Download client |
| ↳ Sonarr | (via Gluetun) | 8989 | TV shows |
| ↳ Radarr | (via Gluetun) | 7878 | Movies |
| ↳ Prowlarr | (via Gluetun) | 9696 | Indexer manager |
| Jellyfin | 192.168.100.4 | 8096 | Media server |
| Pi-hole | 192.168.100.5 | 8081 | DNS ad-blocking (`/admin`) |
| WireGuard | 192.168.100.6 | 51820/udp | Remote VPN access |
| Jellyseerr | 192.168.100.8 | 5055 | Request management |
| Bazarr | 192.168.100.9 | 6767 | Subtitles |
| FlareSolverr | 192.168.100.10 | 8191 | Cloudflare bypass |
| ↳ SABnzbd | (via Gluetun) | 8082 | Usenet downloads (VPN) |

**Optional** (utilities.yml / cloudflared.yml):

| Service | IP | Port | Notes |
|---------|-----|------|-------|
| Cloudflared | 192.168.100.12 | — | Tunnel (no ports exposed) |
| Uptime Kuma | 192.168.100.13 | 3001 | Monitoring |
| duc | — | 8838 | Disk usage (no static IP) |

### Service Connection Guide

**VPN-protected services** (qBittorrent, Sonarr, Radarr, Prowlarr) share Gluetun's network via `network_mode: service:gluetun`. This means:

| From | To | Use | Why |
|------|-----|-----|-----|
| Sonarr | qBittorrent | `localhost:8085` | Same network stack |
| Radarr | qBittorrent | `localhost:8085` | Same network stack |
| Prowlarr | Sonarr | `localhost:8989` | Same network stack |
| Prowlarr | Radarr | `localhost:7878` | Same network stack |
| Prowlarr | FlareSolverr | `flaresolverr:8191` | Docker DNS works |
| Jellyseerr | Sonarr | `gluetun:8989` | Must go through gluetun |
| Jellyseerr | Radarr | `gluetun:7878` | Must go through gluetun |
| Jellyseerr | Jellyfin | `jellyfin:8096` | Both have own IPs |
| Bazarr | Sonarr | `gluetun:8989` | Must go through gluetun |
| Bazarr | Radarr | `gluetun:7878` | Must go through gluetun |
| Sonarr | SABnzbd | `localhost:8080` | Same network stack |
| Radarr | SABnzbd | `localhost:8080` | Same network stack |

> **Why `gluetun` not `sonarr`?** Services sharing gluetun's network don't get their own Docker DNS entries. Jellyseerr/Bazarr must use `gluetun` hostname (or `192.168.100.3`) to reach them.

## Common Commands

```bash
# All commands below run on your NAS via SSH

# View all containers
docker ps

# View logs
docker logs -f <container_name>

# Restart single service
docker compose -f docker-compose.arr-stack.yml restart <service_name>

# Restart entire stack (safe - Pi-hole restarts immediately)
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# Pull repo updates then redeploy
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# Update container images
docker compose -f docker-compose.arr-stack.yml pull
docker compose -f docker-compose.arr-stack.yml up -d
```

> ⚠️ **Never use `docker compose down`** - this stops Pi-hole which kills DNS for your entire network if your router uses Pi-hole. Use `up -d --force-recreate` instead to restart the stack safely.

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| traefik-proxy | 192.168.100.0/24 | Service communication |
| vpn-net | 10.8.1.0/24 | Internal VPN routing (WireGuard peers) |
