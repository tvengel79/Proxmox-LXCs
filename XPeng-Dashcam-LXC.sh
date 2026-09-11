#!/usr/bin/env bash
# create-xpeng-dashcam-lxc.sh
#
# Creates a new LXC on pve2 for the XPENG Dashcam Viewer
# (https://github.com/psuurbach/xpeng-dashcam) and provisions it:
# Python venv, ffmpeg, the app itself, and a systemd service that starts it
# on boot.
#
# NOTE ON THE FOOTAGE MOUNT: earlier versions of this script had the LXC
# itself mount the CIFS share (via the `mount=cifs` container feature).
# That hit AppArmor "DENIED" mount/userns_create errors on this host - a
# known rough edge with CIFS mounts inside unprivileged containers. This
# version mounts the share on the PROXMOX HOST instead (as root, no
# namespace restrictions) and bind-mounts that directory straight into the
# container - the standard, reliable way to hand an LXC a network share.
#
# RUN THIS DIRECTLY ON pve2 AS ROOT.
#   ssh root@pve2
#   ./create-xpeng-dashcam-lxc.sh
#
# If CT 9012 already exists from an earlier, broken attempt (wrong
# architecture template, or the old in-container CIFS mount that failed),
# destroy it first for a clean run:
#   pct stop 9012 ; pct destroy 9012

set -euo pipefail

### ---------------- Review before running ----------------
CTID=9012
CT_HOSTNAME="xpeng-dashcam"

BRIDGE="vmbr0"
NAMESERVER="172.16.25.2"

# Container disk (local-lvm, per pve2 convention). Footage lives on the NAS
# share via a host bind mount, not on this disk, so 8G just covers the OS +
# app + venv + thumbnails/DB (thumbs+db are roughly 1% of the footage
# archive - bump DISK_SIZE if your archive is large).
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"   # where vztmpl templates live on pve2
DISK_SIZE="8"              # GB
CORES=2
MEMORY=2048                # MB
SWAP=512                   # MB

TIMEZONE="Europe/Brussels"

# NAS footage share - mounted on the HOST at HOST_MOUNT, then bind-mounted
# into the container at MOUNT_POINT.
SMB_SERVER="172.16.10.99"
SMB_SHARE="xpeng"
SMB_USER="xpeng"
SMB_PASS='Buster2800+-!'
HOST_MOUNT="/mnt/xpeng-footage"   # on pve2
MOUNT_POINT="/mnt/xpeng"          # inside the container

APP_USER="xpeng-dashcam"
APP_DIR="/opt/xpeng-dashcam"
APP_PORT=8965
REPO_URL="https://github.com/psuurbach/xpeng-dashcam.git"
### ---------------------------------------------------------

MOUNT_UNIT_NAME=$(systemd-escape -p --suffix=mount "$HOST_MOUNT")

echo "==> Making sure cifs-utils is installed on pve2"
if ! command -v mount.cifs >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y cifs-utils
fi

echo "==> SMB credentials + mount unit on the HOST for $HOST_MOUNT"
install -m 600 /dev/null /etc/xpeng-smb-credentials
cat > /etc/xpeng-smb-credentials <<CRED
username=$SMB_USER
password=$SMB_PASS
CRED
chmod 600 /etc/xpeng-smb-credentials

mkdir -p "$HOST_MOUNT"
cat > "/etc/systemd/system/${MOUNT_UNIT_NAME}" <<UNIT
[Unit]
Description=XPENG dashcam footage share (//${SMB_SERVER}/${SMB_SHARE})

[Mount]
What=//${SMB_SERVER}/${SMB_SHARE}
Where=${HOST_MOUNT}
Type=cifs
Options=credentials=/etc/xpeng-smb-credentials,uid=0,gid=0,file_mode=0644,dir_mode=0755,vers=3.0,_netdev

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$MOUNT_UNIT_NAME"
echo "    mounted: $(mount | grep "$HOST_MOUNT" || echo "NOT MOUNTED - check: systemctl status $MOUNT_UNIT_NAME")"

if pct status "$CTID" >/dev/null 2>&1; then
  echo "==> CT $CTID already exists - skipping pct create."
  echo "    Making sure the bind mount is set (mp0) on the existing CT..."
  pct set "$CTID" --mp0 "${HOST_MOUNT},mp=${MOUNT_POINT}"
else
  echo "==> Finding a Debian 13 (trixie) amd64 template"
  pveam update
  # pve2's mirror carries both amd64 and arm64 builds per distro - pve2
  # itself is amd64 hardware, so the template must be the amd64 one.
  TEMPLATE=$(pveam available --section system | awk '{print $2}' | grep -E '^debian-13-standard.*amd64' | sort -V | tail -1)
  if [ -z "$TEMPLATE" ]; then
    echo "No debian-13-standard amd64 template found via 'pveam available'. Available system templates:" >&2
    pveam available --section system >&2
    echo "Pick one from the list above and set TEMPLATE by hand near the top of this script." >&2
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
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --nameserver "$NAMESERVER" \
    --unprivileged 1 \
    --mp0 "${HOST_MOUNT},mp=${MOUNT_POINT}" \
    --onboot 1
fi

echo "==> Making sure CT $CTID only starts after ${HOST_MOUNT} is mounted"
mkdir -p "/etc/systemd/system/pve-container@${CTID}.service.d"
cat > "/etc/systemd/system/pve-container@${CTID}.service.d/xpeng-mount.conf" <<OVERRIDE
[Unit]
After=${MOUNT_UNIT_NAME}
Requires=${MOUNT_UNIT_NAME}
OVERRIDE
systemctl daemon-reload

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
MOUNT_POINT="$MOUNT_POINT"
APP_USER="$APP_USER"
APP_DIR="$APP_DIR"
APP_PORT="$APP_PORT"
REPO_URL="$REPO_URL"

echo "==> Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip ffmpeg git ca-certificates
timedatectl set-timezone "\$TIMEZONE"

echo "==> Service account"
id -u "\$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir "\$APP_DIR" "\$APP_USER"

echo "==> Confirming \$MOUNT_POINT is populated (bind-mounted by the host)"
ls "\$MOUNT_POINT" >/dev/null 2>&1 && echo "    OK: \$(ls "\$MOUNT_POINT" | wc -l) entries" || echo "    WARNING: \$MOUNT_POINT looks empty - check the host-side mount"

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
After=network-online.target
Wants=network-online.target

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

# Nothing sensitive is left in this script (credentials live only on the
# host now), but clean up anyway.
rm -f "\$0"
PROV

echo "==> Pushing provisioning script into CT $CTID and running it"
pct push "$CTID" /tmp/xpeng-provision.sh /root/xpeng-provision.sh --perms 700
pct exec "$CTID" -- /root/xpeng-provision.sh
rm -f /tmp/xpeng-provision.sh

echo
echo "================================================================"
echo " CT $CTID ($CT_HOSTNAME) is up."
echo " Viewer:   http://${IP:-<ct-ip>}:$APP_PORT"
echo " Footage:  //$SMB_SERVER/$SMB_SHARE mounted on the HOST at $HOST_MOUNT,"
echo "           bind-mounted into the CT at $MOUNT_POINT"
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
