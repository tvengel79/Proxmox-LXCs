#!/usr/bin/env bash
# create-xpeng-dashcam-lxc.sh
#
# Creates a new LXC on pve2 for the XPENG Dashcam Viewer
# (https://github.com/psuurbach/xpeng-dashcam) and provisions it:
# Python venv, ffmpeg, a CIFS mount of the footage share, the app itself,
# and a systemd service that starts it on boot (after the share is mounted).
#
# RUN THIS DIRECTLY ON pve2 AS ROOT.
#   ssh root@pve2
#   ./create-xpeng-dashcam-lxc.sh
#
# It is idempotent-ish: re-running after a partial failure will skip the
# template download if already present and re-clone/re-run setup safely,
# but it will NOT re-create the container if $CTID already exists.

set -euo pipefail

### ---------------- Review before running ----------------
CTID=9012
CT_HOSTNAME="xpeng-dashcam"

BRIDGE="vmbr0"
VLAN_TAG=70
NAMESERVER="172.16.25.2"

# Container disk (local-lvm, per pve2 convention). Footage itself lives on
# the NAS share, not on this disk, so 8G is just for the OS + app + venv +
# thumbnails/DB (thumbs+db are roughly 1% of the footage archive - bump
# DISK_SIZE if your archive is large).
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"   # where vztmpl templates live on pve2
DISK_SIZE="8"              # GB
CORES=2
MEMORY=2048                # MB
SWAP=512                   # MB

TIMEZONE="Europe/Brussels"

# NAS footage share
SMB_SERVER="172.16.10.99"
SMB_SHARE="xpeng"
SMB_USER="xpeng"
SMB_PASS='Buster2800+-!'
MOUNT_POINT="/mnt/xpeng"

APP_USER="xpeng-dashcam"
APP_DIR="/opt/xpeng-dashcam"
APP_PORT=8965
REPO_URL="https://github.com/psuurbach/xpeng-dashcam.git"
### ---------------------------------------------------------

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists - skipping pct create. Delete it first (pct destroy $CTID) if you want a clean re-run." >&2
else
  echo "==> Finding a Debian 12 (bookworm) arm64 template"
  pveam update
  TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard.*arm64' | sort -V | tail -1)
  if [ -z "$TEMPLATE" ]; then
    echo "No debian-12-standard arm64 template found via 'pveam available'." >&2
    echo "Run 'pveam available | grep arm64' on pve2, pick one, and set TEMPLATE by hand." >&2
    exit 1
  fi
  if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]; then
    echo "    downloading $TEMPLATE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  fi

  echo "==> Creating CT $CTID ($CT_HOSTNAME)"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},ip=dhcp" \
    --nameserver "$NAMESERVER" \
    --unprivileged 1 \
    --features "mount=cifs" \
    --onboot 1
fi

echo "==> Starting CT $CTID"
pct start "$CTID" >/dev/null 2>&1 || true

echo "==> Waiting for network"
IP=""
for i in $(seq 1 30); do
  IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}') || true
  [ -n "${IP:-}" ] && break
  sleep 2
done
echo "    CT IP: ${IP:-unknown (check DHCP leases / pct exec $CTID -- ip a)}"

echo "==> Writing in-container provisioning script"
# Unquoted heredoc delimiter on purpose: host-side variables above are baked
# in as literal values now, so nothing sensitive is re-typed by hand later.
cat > /tmp/xpeng-provision.sh <<PROV
#!/usr/bin/env bash
set -euo pipefail

TIMEZONE="$TIMEZONE"
SMB_SERVER="$SMB_SERVER"
SMB_SHARE="$SMB_SHARE"
SMB_USER="$SMB_USER"
SMB_PASS='$SMB_PASS'
MOUNT_POINT="$MOUNT_POINT"
APP_USER="$APP_USER"
APP_DIR="$APP_DIR"
APP_PORT="$APP_PORT"
REPO_URL="$REPO_URL"

echo "==> Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip ffmpeg git cifs-utils ca-certificates
timedatectl set-timezone "\$TIMEZONE"

echo "==> Service account"
id -u "\$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir "\$APP_DIR" "\$APP_USER"

echo "==> SMB credentials + mount unit for \$MOUNT_POINT"
install -m 600 /dev/null /etc/xpeng-smb-credentials
cat > /etc/xpeng-smb-credentials <<CRED
username=\$SMB_USER
password=\$SMB_PASS
CRED
chmod 600 /etc/xpeng-smb-credentials

mkdir -p "\$MOUNT_POINT"
UID_APP=\$(id -u "\$APP_USER")
GID_APP=\$(id -g "\$APP_USER")

cat > /etc/systemd/system/mnt-xpeng.mount <<UNIT
[Unit]
Description=XPENG dashcam footage share (//\$SMB_SERVER/\$SMB_SHARE)

[Mount]
What=//\$SMB_SERVER/\$SMB_SHARE
Where=\$MOUNT_POINT
Type=cifs
Options=credentials=/etc/xpeng-smb-credentials,uid=\$UID_APP,gid=\$GID_APP,file_mode=0644,dir_mode=0755,vers=3.0,_netdev

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mnt-xpeng.mount
echo "    mounted: \$(mount | grep "\$MOUNT_POINT" || echo 'NOT MOUNTED - check systemctl status mnt-xpeng.mount')"

echo "==> Fetching xpeng-dashcam"
mkdir -p "\$APP_DIR"
if [ ! -d "\$APP_DIR/.git" ]; then
  git clone "\$REPO_URL" "\$APP_DIR"
else
  git -C "\$APP_DIR" pull
fi

echo "==> setup.sh (venv + deps + config.json)"
cd "\$APP_DIR"
./setup.sh

echo "==> Pointing config.json at \$MOUNT_POINT"
python3 - <<PY
import json
with open("config.json") as f:
    cfg = json.load(f)
cfg["root"] = "\$MOUNT_POINT"
cfg["timezone"] = "\$TIMEZONE"
cfg.setdefault("web", {})["port"] = \$APP_PORT
with open("config.json", "w") as f:
    json.dump(cfg, f, indent=2)
PY

chown -R "\$APP_USER:\$APP_USER" "\$APP_DIR"

echo "==> systemd service"
cat > /etc/systemd/system/xpeng-dashcam.service <<UNIT
[Unit]
Description=XPENG Dashcam Viewer
After=network-online.target mnt-xpeng.mount
Wants=network-online.target
RequiresMountsFor=\$MOUNT_POINT

[Service]
Type=simple
User=\$APP_USER
Group=\$APP_USER
WorkingDirectory=\$APP_DIR
ExecStart=\$APP_DIR/.venv/bin/uvicorn app:app --host 0.0.0.0 --port \$APP_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xpeng-dashcam.service

echo "==> Done. Service status:"
systemctl --no-pager status xpeng-dashcam.service || true

# Credential hygiene: this provisioning script (with the SMB password baked
# in) has served its purpose - remove it so it isn't left lying around.
shred -u "\$0" 2>/dev/null || rm -f "\$0"
PROV

echo "==> Pushing provisioning script into CT $CTID and running it"
pct push "$CTID" /tmp/xpeng-provision.sh /root/xpeng-provision.sh --perms 700
pct exec "$CTID" -- /root/xpeng-provision.sh
shred -u /tmp/xpeng-provision.sh 2>/dev/null || rm -f /tmp/xpeng-provision.sh

echo
echo "================================================================"
echo " CT $CTID ($CT_HOSTNAME) is up."
echo " Viewer:   http://${IP:-<ct-ip>}:$APP_PORT"
echo " Footage:  //$SMB_SERVER/$SMB_SHARE mounted at $MOUNT_POINT"
echo
echo " Next (build the index - the viewer is empty until this runs):"
echo "   pct exec $CTID -- su -s /bin/bash $APP_USER -c '"
echo "     cd $APP_DIR &&"
echo "     ./.venv/bin/python scan.py &&"
echo "     ./.venv/bin/python thumbs.py &&   # slow on a big archive, needs ffmpeg"
echo "     ./.venv/bin/python ritten.py"
echo "   '"
echo
echo " IP is DHCP - consider a reservation for $CTID's MAC if you want a"
echo " stable address (e.g. to put it behind the nginx proxy on 172.16.25.4)."
echo "================================================================"
