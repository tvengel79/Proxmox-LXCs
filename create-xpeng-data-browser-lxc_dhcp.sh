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
CTID=9011                     # 9010 is already taken on pve2 — bump if this collides too
HOSTNAME="xpeng-data-browser-test"
STORAGE="local-lvm"          # <-- verify with `pvesm status`, adjust if needed
TEMPLATE_STORAGE="local"     # where the CT template lives/gets downloaded
BRIDGE="vmbr0"                # matches web1/web2's bridge
VLAN_TAG=""                   # empty = untagged/native VLAN. Set e.g. "70" to tag.
IP="dhcp"                     # "dhcp", or a static CIDR like "172.16.70.20/24"
GATEWAY=""                    # only used when IP is a static CIDR
NAMESERVER=""                 # empty = let DHCP hand out DNS. Set to override.
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

# Build the net0 string piece by piece so VLAN tag / static gateway / nameserver
# stay fully optional — this defaults to plain DHCP on the native VLAN.
NET0="name=eth0,bridge=${BRIDGE},firewall=1,ip=${IP}"
if [ -n "$VLAN_TAG" ]; then
  NET0="${NET0},tag=${VLAN_TAG}"
fi
if [ "$IP" != "dhcp" ] && [ -n "$GATEWAY" ]; then
  NET0="${NET0},gw=${GATEWAY}"
fi

CREATE_ARGS=(
  --hostname "$HOSTNAME"
  --unprivileged "$UNPRIVILEGED"
  --cores "$CORES"
  --memory "$MEMORY_MB"
  --swap "$SWAP_MB"
  --rootfs "${STORAGE}:${DISK_SIZE_GB}"
  --net0 "$NET0"
  --features "nesting=1"
  --onboot 1
  --start 1
)
if [ -n "$NAMESERVER" ]; then
  CREATE_ARGS+=(--nameserver "$NAMESERVER")
fi

echo "==> Creating CT $CTID ($HOSTNAME) with net0: $NET0"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${CREATE_ARGS[@]}"

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

# This is a SvelteKit app using @sveltejs/adapter-cloudflare — NOT a plain
# Vite dist/ build. The whole site is prerendered (root +layout.ts sets
# prerender = true / ssr = true, inherited by every route), so the adapter
# output at .svelte-kit/cloudflare is genuinely static and nginx can serve
# it directly; we just do not need wrangler/Cloudflare Workers to run it.
rm -rf /var/www/html/*
cp -r .svelte-kit/cloudflare/* /var/www/html/

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
if [ "$IP" = "dhcp" ]; then
  ACTUAL_IP=$(pct exec "$CTID" -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1 || true)
  if [ -n "$ACTUAL_IP" ]; then
    echo "==> Done. CT ${CTID} (${HOSTNAME}) is serving the app at http://${ACTUAL_IP}/"
  else
    echo "==> Done. CT ${CTID} (${HOSTNAME}) is up — check its DHCP address with: pct exec ${CTID} -- ip a"
  fi
else
  echo "==> Done. CT ${CTID} (${HOSTNAME}) is serving the app at http://${IP%/*}/"
fi
echo "    (LAN-only — no port is exposed outside your network by this script)"
