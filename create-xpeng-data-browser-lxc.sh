#!/usr/bin/env bash
#
# Creates a Proxmox LXC container that builds and serves the
# XPeng Data Export Browser (https://github.com/schliflo/xpeng-data-export-browser).
#
# The app is a Svelte/Vite SPA that runs entirely client-side (no backend,
# no database — it stores parsed data in the browser's IndexedDB), so this
# container just builds the static site and serves it with nginx.
#
# Run this ON THE PROXMOX HOST (as root). Written as a single script
# (not a multi-line pct create one-liner) specifically to avoid the
# backslash line-continuation trap.
#
# Confirmed working on pve2 (x86_64, storage pool "local-lvm").

set -euo pipefail

### --- Configuration --------------------------------------------------
CTID=9010
HOSTNAME="xpeng-data-browser"
STORAGE="local-lvm"          # <-- verify with `pvesm status`, adjust if needed
TEMPLATE_STORAGE="local"     # where the CT template lives/gets downloaded
BRIDGE="vmbr0"                # matches web1/web2's bridge
VLAN_TAG="70"                 # 172.16.70.x lives on VLAN 70
IP="172.16.70.20/24"
GATEWAY="172.16.70.1"
DISK_SIZE_GB="8"             # room for apt + node + pnpm store + build output
MEMORY_MB="1024"
SWAP_MB="512"
CORES="2"
UNPRIVILEGED=1
TEMPLATE_PATTERN="debian-13-standard"   # same Debian 13 base as trackerway-trips
REPO_URL="https://github.com/schliflo/xpeng-data-export-browser.git"
APP_DIR="/opt/xpeng-data-export-browser"
### ----------------------------------------------------------------------

if pct status "$CTID" &>/dev/null; then
  echo "CTID $CTID already exists — pick a different CTID or destroy it first." >&2
  exit 1
fi

echo "==> Refreshing template catalog and making sure a Debian 13 template is available"
pveam update
TEMPLATE=$(pveam available --section system \
  | awk '{print $2}' \
  | grep "^${TEMPLATE_PATTERN}" \
  | grep "_amd64\.tar\.zst$" \
  | sort -V | tail -1)

if [ -z "$TEMPLATE" ]; then
  echo "No amd64 template matching '${TEMPLATE_PATTERN}' found in the catalog." >&2
  exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo "==> Downloading $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

echo "==> Creating CT $CTID ($HOSTNAME)"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --unprivileged "$UNPRIVILEGED" \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --swap "$SWAP_MB" \
  --rootfs "${STORAGE}:${DISK_SIZE_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},firewall=1,ip=${IP},gw=${GATEWAY}" \
  --features "nesting=1" \
  --onboot 1 \
  --start 1

echo "==> Waiting for the container network to come up"
sleep 8

echo "==> Provisioning the app inside CT $CTID"
pct exec "$CTID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl git nginx ca-certificates gnupg

# Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# pnpm, via corepack (bundled with Node 22)
corepack enable
corepack prepare pnpm@latest --activate

# Fetch and build the app
git clone '"$REPO_URL"' '"$APP_DIR"'
cd '"$APP_DIR"'
pnpm install --frozen-lockfile
pnpm build

# Serve the static build with nginx, with SPA fallback routing
rm -rf /var/www/html/*
cp -r dist/* /var/www/html/

cat > /etc/nginx/sites-available/default <<"NGINX"
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX

systemctl enable nginx
systemctl restart nginx
'

echo ""
echo "==> Done. CT ${CTID} (${HOSTNAME}) is serving the app at http://${IP%/*}/"
echo "    (LAN-only — no port is exposed outside your network by this script)"
