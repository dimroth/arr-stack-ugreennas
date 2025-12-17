# Complete Media Automation Stack for Ugreen NAS

A production-ready Docker Compose stack for media automation, featuring VPN routing, reverse proxy with SSL, and comprehensive media management tools.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Setup](#detailed-setup)
- [Service Configuration](#service-configuration)
- [Maintenance](#maintenance)
- [FAQ](#faq)

---

## Overview

This stack provides a complete media library management solution with:
- **VPN-protected networking** via Gluetun (supports 30+ VPN providers)
- **SSL/TLS certificates** (Traefik + Cloudflare) - *optional, for remote access*
- **Media library organization** (Sonarr, Radarr, Prowlarr, Bazarr)
- **Media streaming** (Jellyfin)
- **Request management** (Jellyseerr)
- **Remote access** (WireGuard VPN) - *optional*
- **Ad-blocking DNS** (Pi-hole)
- **Service monitoring** (Uptime Kuma)

> **Local-only deployment?** You can skip the domain, Cloudflare, and remote access features. See [Deployment Options in README.md](../README.md#deployment-options).

### Services Included

| Service | Purpose | External URL | Local URL |
|---------|---------|--------------|-----------|
| **Traefik** | Reverse proxy + SSL | traefik.yourdomain.com | - |
| **Gluetun** | VPN gateway for privacy | (Internal) | - |
| **qBittorrent** | BitTorrent client | qbit.yourdomain.com | - |
| **Sonarr** | TV show library management | sonarr.yourdomain.com | - |
| **Radarr** | Movie library management | radarr.yourdomain.com | - |
| **Prowlarr** | Search aggregator | prowlarr.yourdomain.com | - |
| **Bazarr** | Subtitle management | bazarr.yourdomain.com | - |
| **Jellyfin** | Media streaming server | jellyfin.yourdomain.com | your-nas.local:8096 |
| **Jellyseerr** | Media request system | jellyseerr.yourdomain.com | your-nas.local:5055 |
| **Pi-hole** | DNS + Ad blocking | pihole.yourdomain.com | your-nas.local:80 |
| **WireGuard** | VPN server | wg.yourdomain.com | - |
| **Uptime Kuma** | Service monitoring | uptime.yourdomain.com | your-nas.local:3001 |
| **FlareSolverr** | CAPTCHA solver | flaresolverr.yourdomain.com | - |

### Local Network Access

For devices on your home network (FireTV, phones, tablets), use the local URLs for faster access:

| Service | Local URL | Notes |
|---------|-----------|-------|
| **Jellyfin** | `http://your-nas.local:8096` | Media streaming |
| **Jellyseerr** | `http://your-nas.local:5055` | Request content |
| **Uptime Kuma** | `http://your-nas.local:3001` | Monitoring |
| **Pi-hole** | `http://your-nas.local:80` | DNS admin |

**Why use local URLs?**
- ✅ Faster (no internet round-trip via Cloudflare)
- ✅ Works even if internet/Cloudflare is down
- ✅ mDNS names work on macOS, iOS, Android, FireTV, Linux

**Note:** Replace `your-nas.local` with your NAS hostname if different.

---

## Features

### Security
- All services behind SSL/TLS (automatic certificates via Let's Encrypt)
- VPN routing for network privacy
- Pi-hole for ad-blocking and DNS security
- WireGuard for secure remote access
- Security headers via Traefik middleware

### Library Management
- Automated media organization and renaming
- Subtitle management (Bazarr)
- Media requests via Jellyseerr
- Search aggregation (Prowlarr)
- CAPTCHA solving for protected sites (FlareSolverr)

### Reliability
- Health checks for all services
- Automatic restart policies
- Centralized logging
- Volume-based persistent storage

---

## Architecture

### Network Topology

```
Internet
    │
    ├─── Cloudflare Tunnel ────────► Traefik (Reverse Proxy, ports 8080/8443)
    │    (recommended)                   │
    │                                    ├─► traefik-proxy network (192.168.100.0/24)
    │                                    │   │
    │                                    │   ├─► Jellyfin (.4)
    │                                    │   ├─► Pi-hole (.5)
    │                                    │   ├─► WireGuard (.6)
    │                                    │   ├─► Uptime Kuma (.13)
    │                                    │   └─► Other services
    │                                    │
    │                                    └─► Gluetun (.3) ◄─── VPN Connection (your provider)
    │                                            │
    │                                            └─► qBittorrent, Sonarr, Radarr, Prowlarr
    │                                                (network_mode: service:gluetun)
    │
    └─── Port 51820/udp ───────────► WireGuard VPN Server (optional)

Note: Ugreen NAS nginx uses ports 80/443, so Traefik uses 8080/8443.
Cloudflare Tunnel bypasses port forwarding entirely (recommended).
```

### Why Three Separate Docker Compose Files?

You'll notice this project uses **three separate compose files**:
1. `docker-compose.traefik.yml` - Infrastructure layer (reverse proxy, SSL)
2. `docker-compose.arr-stack.yml` - Application layer (media services)
3. `docker-compose.cloudflared.yml` - Tunnel layer (external access via Cloudflare)

**This is intentional and follows best practices.** Here's why:

#### 1. **Independent Lifecycle Management**
- Restart/update media services without affecting the reverse proxy
- Update Traefik without touching your media stack
- If arr-stack crashes, Traefik stays running for other potential services

#### 2. **Scalability & Reusability**
Traefik can serve multiple stacks on the same server:
```
traefik (shared reverse proxy)
    ↓
    ├── arr-stack (media automation)
    ├── monitoring-stack (Grafana, Prometheus) ← Future addition
    ├── home-automation (Home Assistant)        ← Future addition
    └── other-services                          ← Future addition
```

All using the same Traefik instance, same SSL certificates, same domain!

#### 3. **Clean Separation of Concerns**
- **Infrastructure Layer** (Traefik): Handles SSL, routing, network
- **Application Layer** (arr-stack): Handles your actual services

This is standard practice in production environments.

#### 4. **Easier Troubleshooting**
- Problem with downloads? Check arr-stack logs
- Problem with SSL/routing? Check Traefik logs
- Clear separation makes debugging simpler

#### 5. **Network Management**
- Traefik compose file **creates** the `traefik-proxy` network
- arr-stack compose file **uses** it (via `external: true`)
- Other future stacks can join the same network

#### Deployment Order Matters
Because of this separation:
1. **Deploy Traefik first** (creates network, sets up SSL)
2. **Deploy arr-stack second** (joins network, uses Traefik)

**Alternative**: You could combine them into one file, but you'd lose the flexibility and would need to restart everything together. The three-file approach is more maintainable and follows industry best practices.

### Storage Structure

```
/volume1/
├── Media/
│   ├── downloads/          # qBittorrent downloads
│   ├── tv/                 # TV shows (Sonarr → Jellyfin)
│   └── movies/             # Movies (Radarr → Jellyfin)
│
└── docker/
    └── arr-stack/
        ├── gluetun-config/
        ├── jellyseerr/config/
        ├── bazarr/config/
        └── traefik/
            ├── traefik.yml
            ├── acme.json
            └── dynamic/
                └── tls.yml
```

---

## Prerequisites

### Hardware Requirements
- Ugreen NAS (or compatible device)
- Support for `/dev/net/tun` (for VPN)
- Docker with `NET_ADMIN` capability support
- Minimum 4GB RAM (8GB+ recommended)
- Storage for media files

### Software Requirements
- Docker Engine 20.10+
- Docker Compose v2.0+
- SSH access to NAS (enable in UGOS Control Panel → Terminal → SSH, set "Shut down automatically" to 2h)

  ![UGOS SSH Settings](images/UGOS-SSH.png)
- Basic Linux command-line knowledge

### External Services

**Required:**
- **VPN Subscription** - Any provider supported by Gluetun (30+ options)
  - Surfshark, NordVPN, PIA, Mullvad, ProtonVPN, etc.
  - See [Gluetun providers](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

**Optional (for remote access):**
- **Domain Name** (e.g., yourdomain.com) - ~$10/year from any registrar
- **Cloudflare Account** (free tier) - For DNS and Cloudflare Tunnel

> **Local-only?** Skip domain and Cloudflare. Access services via `http://NAS_IP:PORT`.

### Network Requirements
- Static IP for NAS (recommended for local access)
- **Cloudflare Tunnel** (recommended) - Bypasses port forwarding entirely
- *Alternative*: Port forwarding (80→8080, 443→8443, 51820/udp) - Often blocked by ISP/CGNAT

---

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/yourusername/arr-stack-ugreennas.git
cd arr-stack-ugreennas
```

### 2. Configure Environment

```bash
# Copy example environment file
cp .env.example .env

# Edit with your values
nano .env
```

**Required values**:
- `VPN_SERVICE_PROVIDER`: Your VPN provider (surfshark, nordvpn, etc.)
- VPN credentials (varies by provider - see [Step 3](#step-3-add-vpn-credentials))
- `PIHOLE_UI_PASS`: Pi-hole admin password

**For remote access** (optional):
- `DOMAIN`: Your domain (e.g., yourdomain.com)
- `CF_DNS_API_TOKEN`: Cloudflare API token
- `WG_PASSWORD_HASH`: WireGuard password hash
- `TRAEFIK_DASHBOARD_AUTH`: Traefik dashboard auth

### 3. Create Directory Structure on NAS

#### Important: GUI vs SSH Folder Creation

**Why does this matter?** Folders created via SSH don't automatically appear in the UGOS Files app. Folders created via the UGOS GUI are registered as "Shared Folders" with proper permissions and visibility.

#### Option A: Create All Folders via UGOS GUI (Recommended)

If you want all your media folders visible in the UGOS Files app:

1. Open UGOS web interface (http://your-nas-ip)
2. Open the **Files** app
3. Create the folder structure:
   - **Media** (shared folder)
     - **downloads** (subfolder inside Media)
     - **tv** (subfolder inside Media)
     - **movies** (subfolder inside Media)
   - **docker** (shared folder)

Then via SSH, create only the Docker config subdirectories:

```bash
ssh user@nas-ip
sudo mkdir -p /volume1/docker/arr-stack/{gluetun-config,jellyseerr/config,bazarr/config,traefik/dynamic}
sudo chown -R 1000:1000 /volume1/docker/arr-stack
sudo touch /volume1/docker/arr-stack/traefik/acme.json
sudo chmod 600 /volume1/docker/arr-stack/traefik/acme.json
```

#### Option B: Create via SSH Only

If you don't need folders visible in UGOS Files app:

```bash
# SSH to NAS
ssh user@nas-ip

# Create all directories
sudo mkdir -p /volume1/docker/arr-stack/{gluetun-config,jellyseerr/config,bazarr/config,traefik/dynamic}
sudo mkdir -p /volume1/Media/{downloads,tv,movies}

# Set permissions
sudo chown -R 1000:1000 /volume1/docker/arr-stack
sudo chown -R 1000:1000 /volume1/Media

# Create Traefik certificate file
sudo touch /volume1/docker/arr-stack/traefik/acme.json
sudo chmod 600 /volume1/docker/arr-stack/traefik/acme.json
```

### 4. Copy Configuration Files

```bash
# From your local machine
scp traefik/traefik.yml user@nas:/volume1/docker/arr-stack/traefik/
scp traefik/dynamic/tls.yml user@nas:/volume1/docker/arr-stack/traefik/dynamic/
```

### 5. Create Docker Network

```bash
# On NAS
docker network create \
  --driver=bridge \
  --subnet=192.168.100.0/24 \
  --gateway=192.168.100.1 \
  traefik-proxy
```

### 6. Deploy Traefik

```bash
docker compose -f docker-compose.traefik.yml up -d
```

**Verify**:
```bash
docker logs traefik -f
# Look for "Configuration loaded" and certificate acquisition
```

### 7. Configure DNS (see DNS-SETUP.md)

Create DNS records pointing to your NAS IP.

### 8. Deploy Media Stack

```bash
# Deploy in stages
docker compose -f docker-compose.arr-stack.yml up -d gluetun
docker compose -f docker-compose.arr-stack.yml up -d qbittorrent
docker compose -f docker-compose.arr-stack.yml up -d sonarr radarr prowlarr
docker compose -f docker-compose.arr-stack.yml up -d jellyfin jellyseerr bazarr
docker compose -f docker-compose.arr-stack.yml up -d pihole wg-easy uptime-kuma
docker compose -f docker-compose.arr-stack.yml up -d flaresolverr
```

### 9. Access Services

Visit `https://uptime.yourdomain.com` for the monitoring dashboard.

---

## Remote Access (Optional)

**Skip this section if you only need local access.** The stack works perfectly on your home network without any domain or external setup.

If you want to access your services from outside your home (phone on mobile data, travelling, etc.), you'll need to set up remote access. We recommend **Cloudflare Tunnel** - see [Cloudflare Tunnel Setup](CLOUDFLARE-TUNNEL-SETUP.md) for instructions.

> **Why Cloudflare Tunnel?** Traditional port forwarding requires your ISP to allow incoming connections - many don't. Cloudflare Tunnel works by connecting *outbound* from your NAS, so it works regardless of your ISP's restrictions.

---

## Detailed Setup

### Step-by-Step: Filling Out the .env File

Before deployment, you need to configure your `.env` file with credentials and API tokens. **Follow these steps in order** for the easiest setup:

#### Step 1: Copy the Template

```bash
cp .env.example .env
```

Your `.env` already has:
- ✅ Domain configured
- ✅ Static IP addresses set
- ⏳ Empty fields for credentials (we'll fill these next)

---

#### Step 2: Generate Cloudflare API Token

**You need this for automatic SSL certificates.**

1. **Open**: https://dash.cloudflare.com/profile/api-tokens
2. **Click**: "Create Token"
3. **Select**: "Edit zone DNS" template
4. **Configure Permissions** - Click "+ Add more" to add a second permission:
   - Permission 1: `Zone → DNS → Edit`
   - Permission 2: `Zone → Zone → Read` (click "+ Add more")
5. **Zone Resources**: "All zones" (this is fine if you have one domain)
6. **Click**: "Continue to summary" → "Create Token"
7. **COPY THE TOKEN** (shown only once!)
8. **Paste** into `.env`:
   ```bash
   CF_DNS_API_TOKEN=your_token_here
   ```

---

#### Step 3: Add VPN Credentials

Gluetun supports 30+ VPN providers. Configuration varies by provider - see [Gluetun provider docs](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

<details>
<summary><strong>Surfshark (WireGuard) - Click to expand</strong></summary>

**Get your WireGuard configuration from**: https://my.surfshark.com/

1. Login to Surfshark
2. Navigate to: **VPN** → **Manual Setup** → **Router** → **WireGuard**
3. Select **"I don't have a key pair"** to generate new keys
4. **Select a server location** (e.g., "United Kingdom" or "USA - New York")
   - You MUST select a location before the Download button appears
   - Choose based on your priority: closest = fastest, or specific country for region-locked content
5. Click **"Download"** to get the `.conf` file
6. **Open the downloaded file** and extract:

   ```ini
   [Interface]
   Address = 10.14.0.2/16          ← Copy this
   PrivateKey = uHSC4GWQ...        ← Copy this
   ```

7. **Add** to `.env`:
   ```bash
   VPN_SERVICE_PROVIDER=surfshark
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=your_private_key_here
   WIREGUARD_ADDRESSES=10.14.0.2/16
   SERVER_COUNTRIES=United Kingdom
   ```

**Note**: You MUST download the config file to get the Address field - it's not shown on the web interface.

</details>

<details>
<summary><strong>Other Providers (NordVPN, PIA, Mullvad, etc.)</strong></summary>

Each provider has different requirements. See the Gluetun wiki for your provider:
- [NordVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md)
- [Private Internet Access](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md)
- [Mullvad](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/mullvad.md)
- [ProtonVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)
- [All providers](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

Update `.env` with the variables required by your provider.

</details>

---

#### Step 4: Set Pi-hole Admin Password

**Choose a secure password** for Pi-hole's web interface, or generate one:

```bash
# Generate random secure password
openssl rand -base64 24
```

**Add** to `.env`:
```bash
PIHOLE_UI_PASS=your_chosen_password
```

**Save this password** - you'll need it to login to Pi-hole!

---

#### Step 5: Generate WireGuard Password Hash

**Choose a password** for WireGuard admin interface, then generate the bcrypt hash:

```bash
# Start Docker Desktop if not running, then:
docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'YOUR_WIREGUARD_PASSWORD'
```

**Example**:
```bash
docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'MySecureWGPass123!'
```

This outputs:
```
PASSWORD_HASH='$2a$12$...'
```

**Copy the hash** (the `$2a$12$...` part) and **add** to `.env`:
```bash
WG_PASSWORD_HASH=$2a$12$your_generated_hash
```

**Save your WireGuard password** (the plain text one) - you'll need it to login!

**Note**: The hash is just a text string - it's safe to generate on Mac/Windows/Linux, it will work on your NAS.

---

#### Step 6: Generate Traefik Dashboard Authentication

**Choose credentials** for Traefik dashboard (username: `admin`, password: your choice):

```bash
# Replace 'your_password' with your chosen password
docker run --rm httpd:alpine htpasswd -nb admin 'your_password' | sed -e s/\\$/\\$\\$/g
```

**Example**:
```bash
docker run --rm httpd:alpine htpasswd -nb admin 'MyTraefikPass123' | sed -e s/\\$/\\$\\$/g
```

This outputs:
```
admin:$$apr1$$...$$...
```

**Copy the entire output** and **add** to `.env`:
```bash
TRAEFIK_DASHBOARD_AUTH=admin:$$apr1$$...$$...
```

**Save your Traefik password** - you'll need it to login!

---

#### Step 7: Verify Your .env File

Your completed `.env` should have these filled in:

```bash
# VPN (required) - variables depend on your provider
VPN_SERVICE_PROVIDER=surfshark      # ✅ Your provider
WIREGUARD_PRIVATE_KEY=...           # ✅ Or OPENVPN_USER/PASSWORD

# Domain/Remote Access (optional - skip for local-only)
DOMAIN=yourdomain.com               # ✅ If using remote access
CF_DNS_API_TOKEN=abc123...          # ✅ If using Cloudflare

# Service passwords
PIHOLE_UI_PASS=yourpass             # ✅ Filled
WG_PASSWORD_HASH=$2a$12$...         # ✅ If using WireGuard remote access
TRAEFIK_DASHBOARD_AUTH=admin:$$...  # ✅ If using Traefik
```

**All required fields filled?** ✅ You're ready for deployment!

---

### Save Your Passwords!

**You'll need these to login to services** (save in password manager):

| Service | Username | Password |
|---------|----------|----------|
| Pi-hole | (none) | Your Pi-hole password |
| WireGuard | (none) | Your WireGuard password (NOT the hash!) |
| Traefik | admin | Your Traefik password |

**Important**: The `.env` file contains secrets - **never commit it to git**! (It's in `.gitignore`)

### Verifying VPN Connection

```bash
# Check Gluetun logs
docker logs gluetun -f

# Should show:
# [INFO] Connected to VPN
# [INFO] IP: <surfshark-ip>

# Test external IP
docker exec gluetun wget -qO- ifconfig.me
# Should show VPN IP, NOT your home IP

# Test from qBittorrent
docker exec qbittorrent wget -qO- ifconfig.me
# Should also show VPN IP (confirms network_mode works)
```

---

## Service Configuration

### Prowlarr Setup

1. **Access**: `https://prowlarr.yourdomain.com`

2. **Add Indexers**:
   - Settings → Indexers → Add Indexer
   - Search for your preferred indexers
   - Configure each indexer

3. **Add FlareSolverr** (for Cloudflare-protected indexers):
   - Settings → Indexers → Add FlareSolverr
   - Name: FlareSolverr
   - Tags: `flaresolverr`
   - Host: `http://flaresolverr:8191`
   - Test and Save
   - Tag indexers that need Cloudflare bypass

4. **Connect to Sonarr**:
   - Settings → Apps → Add Application → Sonarr
   - Name: Sonarr
   - Sync Level: Full Sync
   - Prowlarr Server: `http://prowlarr:9696`
   - Sonarr Server: `http://sonarr:8989`
   - API Key: (copy from Sonarr → Settings → General → Security)
   - Test and Save

5. **Connect to Radarr**:
   - Settings → Apps → Add Application → Radarr
   - Name: Radarr
   - Sync Level: Full Sync
   - Prowlarr Server: `http://prowlarr:9696`
   - Radarr Server: `http://radarr:7878`
   - API Key: (copy from Radarr → Settings → General → Security)
   - Test and Save

6. **Sync Indexers**:
   - Settings → Apps → Sync App Indexers (button at bottom)
   - Verify indexers appear in Sonarr and Radarr

---

### Sonarr Configuration

1. **Access**: `https://sonarr.yourdomain.com`

2. **Add Root Folder**:
   - Settings → Media Management → Root Folders
   - Add: `/tv`

3. **Add Download Client**:
   - Settings → Download Clients → Add → qBittorrent
   - Name: qBittorrent
   - Host: `gluetun` (important! not localhost)
   - Port: `8085`
   - Username: `admin`
   - Password: (your qBittorrent password)
   - Category: `sonarr`
   - Test and Save

4. **Quality Profiles** (optional):
   - Settings → Profiles
   - Customize to your preferences

5. **Add Series**:
   - Series → Add New
   - Search for TV show
   - Select quality profile, monitored status
   - Add

---

### Radarr Configuration

1. **Access**: `https://radarr.yourdomain.com`

2. **Add Root Folder**:
   - Settings → Media Management → Root Folders
   - Add: `/movies`

3. **Add Download Client**:
   - Settings → Download Clients → Add → qBittorrent
   - Name: qBittorrent
   - Host: `gluetun`
   - Port: `8085`
   - Username: `admin`
   - Password: (your qBittorrent password)
   - Category: `radarr`
   - Test and Save

4. **Add Movies**:
   - Movies → Add New
   - Search for movie
   - Select quality profile, monitored status
   - Add

---

### Jellyfin Configuration

1. **Access**: `https://jellyfin.yourdomain.com`

2. **Initial Setup**:
   - Create admin account
   - Select language

3. **Add Media Libraries**:
   - Movies:
     - Content type: Movies
     - Folder: `/media/movies`
     - Enable: Automatically refresh metadata
   - TV Shows:
     - Content type: Shows
     - Folder: `/media/tv`
     - Enable: Automatically refresh metadata

4. **Configure Metadata** (optional):
   - Settings → Libraries → Metadata downloaders
   - Configure TMDB, TVDB, etc.

5. **User Management**:
   - Dashboard → Users
   - Create accounts for family/friends

---

### Jellyseerr Configuration

1. **Access**: `https://jellyseerr.yourdomain.com`

2. **Sign In**:
   - Use Jellyfin Sign-In
   - Jellyfin URL: `http://jellyfin:8096`
   - Enter Jellyfin credentials
   - Import Jellyfin libraries

3. **Configure Sonarr**:
   - Settings → Services → Sonarr
   - Default Server: ON
   - Server Name: Sonarr
   - Hostname/IP: `sonarr`
   - Port: `8989`
   - API Key: (from Sonarr)
   - URL Base: (leave empty)
   - Quality Profile: (select default)
   - Root Folder: `/tv`
   - Season Folders: ON
   - Test and Save

4. **Configure Radarr**:
   - Settings → Services → Radarr
   - Default Server: ON
   - Server Name: Radarr
   - Hostname/IP: `radarr`
   - Port: `7878`
   - API Key: (from Radarr)
   - URL Base: (leave empty)
   - Quality Profile: (select default)
   - Root Folder: `/movies`
   - Test and Save

5. **User Permissions**:
   - Settings → Users
   - Configure request limits, auto-approval, etc.

---

### Bazarr Configuration

1. **Access**: `https://bazarr.yourdomain.com`

2. **Connect to Sonarr**:
   - Settings → Sonarr
   - Enabled: ON
   - Hostname/IP: `sonarr`
   - Port: `8989`
   - API Key: (from Sonarr)
   - Test and Save

3. **Connect to Radarr**:
   - Settings → Radarr
   - Enabled: ON
   - Hostname/IP: `radarr`
   - Port: `7878`
   - API Key: (from Radarr)
   - Test and Save

4. **Add Subtitle Providers**:
   - Settings → Providers
   - Enable providers (OpenSubtitles, Subscene, etc.)
   - Configure credentials if needed

5. **Languages**:
   - Settings → Languages
   - Add preferred subtitle languages
   - Set as default

---

### qBittorrent Configuration

1. **Access**: `https://qbit.yourdomain.com`
2. **Default Login**: `admin` / `adminadmin`
3. **IMMEDIATELY CHANGE PASSWORD**:
   - Tools → Options → Web UI → Authentication
   - Change password

4. **Categories** (for Sonarr/Radarr):
   - Right-click in categories → Add category
   - Add: `sonarr`, `radarr`
   - Set save paths:
     - sonarr → `/downloads/sonarr`
     - radarr → `/downloads/radarr`

5. **Connection Settings**:
   - Tools → Options → Connection
   - Verify port 8085
   - DO NOT enable UPnP (behind VPN)

6. **Downloads**:
   - Tools → Options → Downloads
   - Default Save Path: `/downloads`
   - Keep incomplete torrents in: `/downloads/incomplete`
   - Copy .torrent files to: `/downloads/torrents`

---

### Pi-hole Configuration

1. **Access**: `https://pihole.yourdomain.com/admin` or `http://your-nas.local:80/admin`
2. **Login**: Use password from `PIHOLE_UI_PASS` in .env

3. **Settings → DNS**:
   - Upstream DNS Servers:
     - Cloudflare (1.1.1.1, 1.0.0.1)
     - Or your preference
   - Interface settings: Listen on all interfaces

4. **Adlists** (optional):
   - Group Management → Adlists
   - Add additional blocklists

5. **Test DNS**:
   ```bash
   dig @YOUR_NAS_IP google.com
   dig @YOUR_NAS_IP doubleclick.net  # Should return 0.0.0.0 (blocked)
   ```

### Network-Wide Pi-hole Setup

To use Pi-hole for ad-blocking on all devices in your home:

1. **Configure Router DHCP DNS**:
   - Access your router admin (e.g., `http://192.168.0.1`)
   - Go to: **Network → DHCP Server**
   - Set **Primary DNS**: `YOUR_NAS_IP` (your NAS IP)
   - Set **Secondary DNS**: `YOUR_NAS_IP` (same, to prevent fallback leaks)
   - Save and reboot router

2. **Configure Router Internet DNS** (optional but recommended):
   - Go to: **Internet → DNS settings**
   - Set both Primary and Secondary to `YOUR_NAS_IP`
   - This prevents the router from adding itself as a fallback DNS

3. **Renew DHCP on devices**:
   - Reconnect to Wi-Fi, or
   - macOS: `networksetup -setdhcp "Wi-Fi"`

4. **Verify**:
   ```bash
   # Check DNS servers in use
   scutil --dns | grep nameserver

   # Should show YOUR_NAS_IP only
   ```

**Note: iCloud Private Relay**

Apple devices may show "This network is blocking iCloud Private Relay" when using Pi-hole. This is expected - Private Relay encrypts DNS which bypasses Pi-hole.

**Recommended**: Disable Private Relay on your home network:
- iPhone: Settings → Wi-Fi → (i) next to your network → iCloud Private Relay → OFF
- Keep it enabled for public Wi-Fi and cellular

---

### WireGuard Configuration

1. **Access**: `https://wg.yourdomain.com`
2. **Login**: Use password you set (used to generate `WG_PASSWORD_HASH`)

3. **Create Client**:
   - Click "New"
   - Name: `My Phone` (or device name)
   - Download QR code or config file

4. **Port Forwarding**:
   - Ensure UDP 51820 is forwarded on router
   - Port → NAS:51820

5. **Connect**:
   - Install WireGuard on device
   - Scan QR code or import config
   - Connect

6. **Verify**:
   - While connected, access: `https://uptime.yourdomain.com`
   - Should work even without external DNS (using internal IP)

---


## Maintenance

### Updating Services

```bash
# Update all services
docker compose -f docker-compose.arr-stack.yml pull
docker compose -f docker-compose.arr-stack.yml up -d

# Update specific service
docker compose -f docker-compose.arr-stack.yml pull sonarr
docker compose -f docker-compose.arr-stack.yml up -d sonarr
```

### Backup

**Important volumes to backup**:
```bash
# List all volumes
docker volume ls | grep arr-stack

# Backup volumes
docker run --rm \
  -v sonarr-config:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/sonarr-config.tar.gz -C /data .

# Repeat for: radarr-config, prowlarr-config, jellyfin-config, etc.
```

**Backup configuration files**:
```bash
tar czf arr-stack-config-backup.tar.gz \
  /volume1/docker/arr-stack/gluetun-config \
  /volume1/docker/arr-stack/jellyseerr \
  /volume1/docker/arr-stack/bazarr \
  /volume1/docker/arr-stack/traefik
```

### Logs

```bash
# View logs for all services
docker compose -f docker-compose.arr-stack.yml logs -f

# View logs for specific service
docker logs -f sonarr

# View last 100 lines
docker logs --tail 100 sonarr

# Save logs to file
docker logs sonarr > sonarr-logs.txt
```

### Resource Monitoring

```bash
# View resource usage
docker stats

# View disk usage
docker system df

# Clean up unused images
docker image prune -a
```

---

## FAQ

### Q: How do I change my domain?

1. Update `.env`: `DOMAIN=newdomain.com`
2. Update `traefik/traefik.yml`: domains section
3. Recreate services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml down
   docker compose -f docker-compose.arr-stack.yml up -d
   ```
4. Update DNS records (see DNS-SETUP.md)

### Q: Can I use a different VPN provider?

Yes! Edit `docker-compose.arr-stack.yml`:
```yaml
gluetun:
  environment:
    - VPN_SERVICE_PROVIDER=nordvpn  # or protonvpn, etc.
    - OPENVPN_USER=${VPN_USER}
    - OPENVPN_PASSWORD=${VPN_PASSWORD}
```

See Gluetun docs for supported providers: https://github.com/qdm12/gluetun-wiki

### Q: Services aren't accessible externally?

Check:
1. DNS records point to your public IP
2. **Port forwarding configured correctly**:
   - If Traefik uses ports 8080/8443, forward: External 80→8080, External 443→8443
   - Router may need restart for port forwarding to activate
3. Firewall allows ports 8080, 8443 on NAS
4. Cloudflare proxy disabled (DNS only - gray cloud)
5. ISP may be blocking ports 80/443 (common for residential)

See TROUBLESHOOTING.md → "Can't access services externally" for detailed solutions.

### Q: How do I restrict *arr services to local network only?

Remove Traefik labels from services you want local-only, or add authentication middleware.

### Q: qBittorrent not connecting?

1. Check VPN connection: `docker logs gluetun`
2. Verify qBittorrent can reach internet: `docker exec qbittorrent wget -qO- ifconfig.me`
3. Check if download client configured in Sonarr/Radarr
4. Verify categories exist in qBittorrent

### Q: SSL certificates not working?

1. Check Cloudflare API token is correct
2. Verify DNS records exist
3. Check Traefik logs: `docker logs traefik -f`
4. Verify acme.json permissions: `chmod 600 traefik/acme.json`

### Q: How do I add more storage?

Update volume mounts in `docker-compose.arr-stack.yml`:
```yaml
volumes:
  - /volume2/more-storage/movies:/movies2
```

Then add the path in Sonarr/Radarr root folders.

### Q: Container won't start - "address already in use"?

**Problem**: IP address conflict on traefik-proxy network

**Solution**: Assign static IPs to all services:
```yaml
services:
  service-name:
    networks:
      traefik-proxy:
        ipv4_address: 192.168.100.X
```

See TROUBLESHOOTING.md → "IP Address Conflicts" for full IP allocation plan.

### Q: Gluetun error: "Wireguard settings: interface address is not set"?

**Problem**: WireGuard requires an Address field that some VPN providers don't show on their web UI

**Solution**:
1. Download the full WireGuard `.conf` file from your VPN provider (don't just copy credentials from web)
2. Open the .conf file and find `Address = x.x.x.x/xx` in the [Interface] section
3. Add to `.env`: `WIREGUARD_ADDRESSES=10.14.0.2/16` (use your actual value)

See [Gluetun wiki](https://github.com/qdm12/gluetun-wiki) for provider-specific setup.

### Q: Docker commands fail with "permission denied"?

On Ugreen NAS, use sudo:
```bash
sudo docker compose up -d
# Or via SSH:
echo 'YOUR_PASSWORD' | sudo -S docker compose up -d
```

**Permanent fix**: Add user to docker group
```bash
sudo usermod -aG docker $USER
# Logout and login again
```

### Q: Port forwarding doesn't work / External access fails?

**Symptoms**: Services work locally but timeout from external network

**Common causes**:
1. **CGNAT** (most likely) - ISP puts you behind carrier-grade NAT
   - Port forwarding cannot work with CGNAT
   - Affects ~30% of residential internet
   - ISPs don't advertise this

2. **ISP blocking** - ISP blocks all incoming connections

**How to test**:
```bash
# From phone on cellular data:
curl -I http://YOUR_PUBLIC_IP:8080

# If timeout after 10+ seconds = CGNAT or ISP blocking
```

**Solutions**:
- **Cloudflare Tunnel** (recommended) - See CLOUDFLARE-TUNNEL-SETUP.md
- **VPN-only access** - Use WireGuard for all access
- **Contact ISP** - Ask about CGNAT, request public IP (may cost extra)

See EXTERNAL-ACCESS-ISSUE.md for detailed diagnosis.

---

## Support

- **Issues**: https://github.com/yourusername/arr-stack-ugreennas/issues
- **Documentation**: See DEPLOYMENT-PLAN.md, DNS-SETUP.md, TROUBLESHOOTING.md
- **Gluetun**: https://github.com/qdm12/gluetun
- **Traefik**: https://doc.traefik.io/traefik/
- **Sonarr/Radarr**: https://wiki.servarr.com/

---

**Last Updated**: 2025-11-29
