# Architecture Overview

This guide explains how the stack fits together and why it's designed this way.

## The Request-to-Watch Flow

When someone requests a movie or TV show, here's what happens:

```
┌─────────────┐     ┌──────────────┐     ┌───────────┐     ┌─────────────┐     ┌──────────┐
│ Jellyseerr  │────▶│ Sonarr/Radarr│────▶│ Prowlarr  │────▶│ qBittorrent │────▶│ Jellyfin │
│ (request)   │     │ (monitor)    │     │ (search)  │     │ (download)  │     │ (watch)  │
└─────────────┘     └──────────────┘     └───────────┘     └─────────────┘     └──────────┘
      │                    │                   │                  │                  │
      │                    │                   │                  │                  │
      └────────────────────┴───────────────────┴──────────────────┘                  │
                           Through VPN (Gluetun)                              Not through VPN
```

1. **Jellyseerr** - User requests "The Office Season 1"
2. **Sonarr** - Receives request, monitors for releases
3. **Prowlarr** - Searches indexers for downloads
4. **qBittorrent** - Downloads the files (through VPN)
5. **Jellyfin** - Makes files available to stream

## VPN Protection

**Why VPN?** Your ISP can see BitTorrent traffic. The VPN encrypts this so they only see "encrypted traffic to VPN server".

**Why not everything through VPN?** Streaming from Jellyfin doesn't need protection (you're watching your own files) and VPN would slow it down.

```
                              ┌─────────────────────────────────────────┐
                              │            GLUETUN (VPN)                │
                              │                                         │
Internet ◄───VPN Tunnel───────│  qBittorrent  Sonarr  Radarr  Prowlarr  │
                              │       ▲         ▲       ▲        ▲      │
                              │       │         │       │        │      │
                              │       └─────────┴───────┴────────┘      │
                              │         All share localhost             │
                              └─────────────────────────────────────────┘
                                                 │
                                    ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─
                                                 │
                              ┌──────────────────┴──────────────────────┐
Internet ◄───────Direct───────│  Jellyfin    Jellyseerr    Pi-hole     │
                              │  (stream)    (requests)    (DNS)        │
                              └─────────────────────────────────────────┘
```

## Service Connections

Services inside Gluetun's network use `localhost` to talk to each other. Services outside must use the `gluetun` hostname.

```
Inside Gluetun (same network):       Outside Gluetun:
─────────────────────────────        ─────────────────
Sonarr → qBittorrent                 Jellyseerr → Sonarr
  └── localhost:8085                   └── gluetun:8989

Radarr → qBittorrent                 Bazarr → Radarr
  └── localhost:8085                   └── gluetun:7878

Prowlarr → Sonarr
  └── localhost:8989
```

## Network Layout

All services run on the `traefik-proxy` network with static IPs:

```
traefik-proxy network (172.20.0.0/24)
────────────────────────────────────────────────────────────────
│ IP           │ Service      │ Notes                          │
├──────────────┼──────────────┼────────────────────────────────│
│ 172.20.0.2   │ Traefik      │ Reverse proxy                  │
│ 172.20.0.3   │ Gluetun      │ VPN gateway + arr services     │
│ 172.20.0.4   │ Jellyfin     │ Media server                   │
│ 172.20.0.5   │ Pi-hole      │ DNS server                     │
│ 172.20.0.6   │ WireGuard    │ VPN server (incoming)          │
│ 172.20.0.8   │ Jellyseerr   │ Request portal                 │
│ 172.20.0.9   │ Bazarr       │ Subtitles                      │
│ 172.20.0.10  │ FlareSolverr │ Cloudflare bypass              │
│ 172.20.0.12  │ Cloudflared  │ Tunnel to Cloudflare           │
│ 172.20.0.13  │ Uptime Kuma  │ Monitoring                     │
│ 172.20.0.14  │ duc          │ Disk usage                     │
────────────────────────────────────────────────────────────────
```

## Access Levels

```
┌─────────────────────────────────────────────────────────────────────────┐
│                             CORE                                         │
│                      Access via NAS_IP:port                              │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐            │
│  │ :8096     │  │ :8989     │  │ :7878     │  │ :5055     │  ...       │
│  │ Jellyfin  │  │ Sonarr    │  │ Radarr    │  │Jellyseerr │            │
│  └───────────┘  └───────────┘  └───────────┘  └───────────┘            │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ + Pi-hole
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          + LOCAL DNS                                     │
│                      Access via .lan domains                             │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐               │
│  │ jellyfin.lan  │  │ sonarr.lan    │  │ radarr.lan    │  ...          │
│  └───────────────┘  └───────────────┘  └───────────────┘               │
│                                                                          │
│  Your device → Pi-hole (DNS) → Traefik → Service                        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ + Traefik + Cloudflare Tunnel
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        + REMOTE ACCESS                                   │
│                   Access from outside your home                          │
│  ┌─────────────────────┐  ┌─────────────────────┐                       │
│  │ jellyfin.domain.com │  │ jellyseerr.domain.com│  ...                 │
│  └─────────────────────┘  └─────────────────────┘                       │
│                                                                          │
│  Phone → Cloudflare → Tunnel → Traefik → Service                        │
└─────────────────────────────────────────────────────────────────────────┘
```

## Docker Compose Files

| File | Purpose | Required for |
|------|---------|--------------|
| `docker-compose.arr-stack.yml` | Core media stack + VPN | All setups |
| `docker-compose.traefik.yml` | Reverse proxy for external access | + remote access |
| `docker-compose.cloudflared.yml` | Tunnel to Cloudflare | + remote access |
| `docker-compose.utilities.yml` | Monitoring, disk usage, auto-recovery | Optional |

## Why This Design?

**Static IPs:** Prevents "container not found" errors after restarts. Services always know where to find each other.

**Separate compose files:** Deploy only what you need. Core users don't need Traefik or Cloudflared.

**VPN for downloads only:** Protects privacy where it matters, doesn't slow down streaming.

**Pi-hole for DNS:** Enables friendly `.lan` domains and blocks ads across your network.

**Named volumes:** Data persists across container updates. Easy to backup with the included script.
