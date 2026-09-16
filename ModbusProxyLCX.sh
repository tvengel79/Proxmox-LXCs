#!/usr/bin/env bash
#
# deploy-modbus-proxy-lxc.sh
#
# Creates an unprivileged Debian LXC on Proxmox VE and installs modbus-proxy
# (https://github.com/tiagocoutinho/modbus-proxy) inside it, configured to
# front one or more upstream Modbus TCP devices/servers so that multiple
# Modbus clients can query them concurrently without stepping on each
# other's connections.
#
# Also installs a small self-contained web GUI (Flask) inside the same
# container to:
#   - add / edit / remove the Modbus TCP servers the proxy polls
#   - show a live overview of which clients currently have a connection
#     open to each proxy listen port
#
# Run this ON THE PROXMOX HOST as root, e.g.:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/tvengel79/Proxmox-LXCs/main/deploy-modbus-proxy-lxc.sh)"
#
# It is interactive (whiptail) — you will be asked for the CTID, sizing,
# network settings, the list of Modbus TCP servers to proxy, and GUI
# login details.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
msg_info()  { echo -e " ${YELLOW}➜${NC} $1"; }
msg_ok()    { echo -e " ${GREEN}✔${NC} $1"; }
msg_warn()  { echo -e " ${YELLOW}⚠${NC} $1"; }
msg_error() { echo -e " ${RED}✘${NC} $1" >&2; }

CT_CREATED=0
CTID=""

cleanup_on_error() {
  local rc=$?
  if [ "$CT_CREATED" -eq 1 ] && [ -n "$CTID" ]; then
    msg_error "Setup failed after container $CTID was created."
    read -r -p "Destroy container $CTID to clean up? [y/N] " ans || true
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" >/dev/null 2>&1 || true
      msg_ok "Container $CTID destroyed."
    fi
  fi
  exit "$rc"
}
trap cleanup_on_error ERR

if [ "$(id -u)" -ne 0 ]; then
  msg_error "This script must be run as root on the Proxmox VE host."
  exit 1
fi
if ! command -v pveversion >/dev/null 2>&1; then
  msg_error "pveversion not found — this doesn't look like a Proxmox VE host."
  exit 1
fi
if ! command -v whiptail >/dev/null 2>&1; then
  msg_info "Installing whiptail..."
  apt-get update -qq && apt-get install -y -qq whiptail
fi

wt_input() {
  # $1=title $2=prompt $3=default
  local result
  set +e
  result=$(whiptail --backtitle "Modbus Proxy LXC Deploy" --title "$1" --inputbox "$2" 10 74 "$3" 3>&1 1>&2 2>&3)
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then msg_error "Cancelled."; exit 1; fi
  echo "$result"
}

wt_password() {
  # $1=title $2=prompt
  local result
  set +e
  result=$(whiptail --backtitle "Modbus Proxy LXC Deploy" --title "$1" --passwordbox "$2" 10 74 3>&1 1>&2 2>&3)
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then msg_error "Cancelled."; exit 1; fi
  echo "$result"
}

wt_menu2() {
  # $1=title $2=prompt $3=tag1 $4=desc1 $5=tag2 $6=desc2
  local result
  set +e
  result=$(whiptail --backtitle "Modbus Proxy LXC Deploy" --title "$1" --menu "$2" 12 74 2 "$3" "$4" "$5" "$6" 3>&1 1>&2 2>&3)
  local rc=$?
  set -e
  if [ $rc -ne 0 ]; then msg_error "Cancelled."; exit 1; fi
  echo "$result"
}

# ---------------------------------------------------------------------------
# Container sizing / identity
# ---------------------------------------------------------------------------
DEFAULT_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

CTID=$(wt_input "Container ID" "CTID for the new container:" "$DEFAULT_CTID")
HOSTNAME=$(wt_input "Hostname" "Hostname for the container:" "modbus-proxy")
DISK_GB=$(wt_input "Disk size (GB)" "Root disk size in GB:" "4")
CORES=$(wt_input "CPU cores" "Number of CPU cores:" "1")
RAM_MB=$(wt_input "Memory (MB)" "RAM in MB:" "512")

# Storage pool for the container's root disk (per Tim's pve2 convention: local-lvm)
STORAGE=$(wt_input "Storage pool" "Storage pool for the container disk:" "local-lvm")

# ---------------------------------------------------------------------------
# Template selection (amd64 only — pve2's template mirror carries both
# amd64 and arm64 builds per distro, so filter explicitly)
# ---------------------------------------------------------------------------
TEMPLATE_STORAGE="local"
msg_info "Refreshing template list..."
pveam update >/dev/null 2>&1 || true

TEMPLATE=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-13-standard_.*_amd64\.tar\.zst$' | sort -V | tail -n1 || true)
if [ -z "$TEMPLATE" ]; then
  msg_warn "Could not find a debian-13-standard amd64 template. Falling back to the newest available debian-12 amd64 template."
  TEMPLATE=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64\.tar\.zst$' | sort -V | tail -n1 || true)
fi
if [ -z "$TEMPLATE" ]; then
  msg_error "No suitable Debian amd64 template found. Run 'pveam available' manually and adjust the script."
  exit 1
fi

if [ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]; then
  msg_info "Downloading template ${TEMPLATE}..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi
msg_ok "Using template ${TEMPLATE}"

# ---------------------------------------------------------------------------
# Networking — untagged on vmbr0 (per convention: not every CT uses VLAN 70)
# ---------------------------------------------------------------------------
BRIDGE=$(wt_input "Bridge" "Network bridge:" "vmbr0")

NETMODE=$(wt_menu2 "Networking" "How should this container get its IP?" \
  "dhcp" "DHCP" \
  "static" "Static IP")

if [ "$NETMODE" = "static" ]; then
  IP_CIDR=$(wt_input "Static IP" "IP address with CIDR (e.g. 192.168.1.50/24):" "192.168.1.50/24")
  GATEWAY=$(wt_input "Gateway" "Default gateway:" "192.168.1.1")
  NETCONF="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}"
else
  NETCONF="name=eth0,bridge=${BRIDGE},ip=dhcp"
fi

DNS=$(wt_input "DNS server" "Nameserver for the container (blank = inherit host's):" "1.1.1.1")

# ---------------------------------------------------------------------------
# Modbus TCP servers to proxy
# ---------------------------------------------------------------------------
SRV_COUNT=$(wt_input "Modbus servers" "How many Modbus TCP servers/devices should this proxy front?" "2")
if ! [[ "$SRV_COUNT" =~ ^[0-9]+$ ]] || [ "$SRV_COUNT" -lt 1 ]; then
  msg_error "Server count must be a positive integer."
  exit 1
fi

declare -a SRV_NAME SRV_HOST SRV_PORT SRV_LISTEN
for ((i = 1; i <= SRV_COUNT; i++)); do
  DEF_LISTEN=$((5020 + i - 1))
  SRV_NAME[i]=$(wt_input "Modbus server #$i" "Short name/label for this device:" "device${i}")
  SRV_HOST[i]=$(wt_input "Modbus server #$i" "Upstream host/IP for ${SRV_NAME[i]}:" "192.168.1.$((100 + i))")
  SRV_PORT[i]=$(wt_input "Modbus server #$i" "Upstream Modbus TCP port for ${SRV_NAME[i]}:" "502")
  SRV_LISTEN[i]=$(wt_input "Modbus server #$i" "Local port the proxy should listen on for ${SRV_NAME[i]} (clients connect here):" "$DEF_LISTEN")
done

# ---------------------------------------------------------------------------
# Web GUI
# ---------------------------------------------------------------------------
GUI_PORT=$(wt_input "Web GUI" "TCP port for the web GUI:" "8088")
GUI_USER=$(wt_input "Web GUI login" "Username for the GUI (leave blank to disable login — not recommended unless this CT is on a locked-down VLAN):" "admin")
GUI_PASS=""
if [ -n "$GUI_USER" ]; then
  while true; do
    P1=$(wt_password "Web GUI login" "Password for '$GUI_USER':")
    P2=$(wt_password "Web GUI login" "Confirm password:")
    if [ -n "$P1" ] && [ "$P1" = "$P2" ]; then
      GUI_PASS="$P1"
      break
    fi
    whiptail --backtitle "Modbus Proxy LXC Deploy" --msgbox "Passwords did not match or were empty. Try again." 10 60
  done
fi

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------
SUMMARY="CTID: ${CTID}\nHostname: ${HOSTNAME}\nDisk/CPU/RAM: ${DISK_GB}GB / ${CORES} core(s) / ${RAM_MB}MB\nStorage: ${STORAGE}\nBridge: ${BRIDGE} (untagged)\nNetwork: ${NETMODE}\nGUI port: ${GUI_PORT} (user: ${GUI_USER:-none / no login})\n\nModbus servers:\n"
for ((i = 1; i <= SRV_COUNT; i++)); do
  SUMMARY+=" - ${SRV_NAME[i]}: clients -> CT:${SRV_LISTEN[i]}  ->  ${SRV_HOST[i]}:${SRV_PORT[i]}\n"
done
whiptail --backtitle "Modbus Proxy LXC Deploy" --title "Confirm" --yesno "$SUMMARY\nProceed?" 26 78 || { msg_error "Cancelled."; exit 1; }

# ---------------------------------------------------------------------------
# Create the container
# ---------------------------------------------------------------------------
msg_info "Creating container $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM_MB" \
  --swap 512 \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "$NETCONF" \
  ${DNS:+--nameserver "$DNS"} \
  --unprivileged 1 \
  --features nesting=0 \
  --onboot 1 \
  --start 0
CT_CREATED=1
msg_ok "Container $CTID created."

msg_info "Starting container..."
pct start "$CTID"

msg_info "Waiting for network..."
for i in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    msg_error "Container did not get network connectivity in time."
    exit 1
  fi
done
msg_ok "Network is up."

# ---------------------------------------------------------------------------
# Install modbus-proxy + Flask GUI dependencies (in a venv, to sidestep
# Debian 13's PEP 668 "externally managed environment" restriction)
# ---------------------------------------------------------------------------
msg_info "Installing Python, modbus-proxy and GUI dependencies inside the container..."
pct exec "$CTID" -- bash -c "
  set -e
  apt-get update -qq
  apt-get install -y -qq python3 python3-venv python3-pip iproute2
  mkdir -p /opt/modbus-proxy /opt/modbus-proxy-gui /etc/modbus-proxy /etc/modbus-proxy-gui
  python3 -m venv /opt/modbus-proxy/venv
  /opt/modbus-proxy/venv/bin/pip install --upgrade pip -q
  /opt/modbus-proxy/venv/bin/pip install -q modbus-proxy flask pyyaml
"
msg_ok "modbus-proxy and GUI dependencies installed."

# ---------------------------------------------------------------------------
# Build and push the modbus-proxy config + friendly-name sidecar file
# ---------------------------------------------------------------------------
msg_info "Writing modbus-proxy config..."
CONFIG_FILE=$(mktemp)
{
  echo "devices:"
  for ((i = 1; i <= SRV_COUNT; i++)); do
    echo "  - modbus:"
    echo "      url: ${SRV_HOST[i]}:${SRV_PORT[i]}"
    echo "    listen:"
    echo "      bind: 0.0.0.0:${SRV_LISTEN[i]}"
  done
} > "$CONFIG_FILE"
pct push "$CTID" "$CONFIG_FILE" /etc/modbus-proxy/config.yml
rm -f "$CONFIG_FILE"

# The GUI keeps friendly names in a sidecar file rather than injecting extra
# keys into config.yml, so modbus-proxy's own config schema is never touched.
NAMES_FILE=$(mktemp)
{
  echo "{"
  for ((i = 1; i <= SRV_COUNT; i++)); do
    sep=","
    if [ "$i" -eq "$SRV_COUNT" ]; then sep=""; fi
    printf '  "%s": "%s"%s\n' "${SRV_LISTEN[i]}" "${SRV_NAME[i]}" "$sep"
  done
  echo "}"
} > "$NAMES_FILE"
pct push "$CTID" "$NAMES_FILE" /etc/modbus-proxy/gui-names.json
rm -f "$NAMES_FILE"
msg_ok "Config written to /etc/modbus-proxy/config.yml in CT $CTID."

# ---------------------------------------------------------------------------
# modbus-proxy systemd service
# ---------------------------------------------------------------------------
msg_info "Creating modbus-proxy systemd service..."
SERVICE_FILE=$(mktemp)
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Modbus TCP Proxy (modbus-proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/modbus-proxy/venv/bin/modbus-proxy -c /etc/modbus-proxy/config.yml
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" "$SERVICE_FILE" /etc/systemd/system/modbus-proxy.service
rm -f "$SERVICE_FILE"

pct exec "$CTID" -- bash -c "systemctl daemon-reload && systemctl enable --now modbus-proxy"
sleep 2
if pct exec "$CTID" -- systemctl is-active --quiet modbus-proxy; then
  msg_ok "modbus-proxy service is running."
else
  msg_error "modbus-proxy service did not start — check 'pct exec $CTID -- journalctl -u modbus-proxy -e'."
fi

# ---------------------------------------------------------------------------
# Web GUI application
# ---------------------------------------------------------------------------
msg_info "Deploying web GUI..."
GUI_APP_FILE=$(mktemp)
cat > "$GUI_APP_FILE" <<'PYEOF'
#!/usr/bin/env python3
"""
Modbus Proxy GUI
- Add / edit / remove the upstream Modbus TCP servers that modbus-proxy
  fronts, writing directly to /etc/modbus-proxy/config.yml and restarting
  the modbus-proxy service.
- Shows a live overview of which clients currently have a TCP connection
  open to each proxy listen port.

Friendly labels for each device are kept separately in gui-names.json so
this app never writes fields modbus-proxy's own config schema doesn't
expect.
"""
import json
import os
import subprocess
from functools import wraps

import yaml
from flask import Flask, Response, redirect, render_template_string, request, url_for
from werkzeug.security import check_password_hash

CONFIG_PATH = "/etc/modbus-proxy/config.yml"
NAMES_PATH = "/etc/modbus-proxy/gui-names.json"
AUTH_PATH = "/etc/modbus-proxy-gui/auth"
SERVICE_NAME = "modbus-proxy"

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Auth (optional — only enforced if /etc/modbus-proxy-gui/auth exists)
# ---------------------------------------------------------------------------
def _load_auth():
    if not os.path.exists(AUTH_PATH):
        return None, None
    with open(AUTH_PATH) as f:
        line = f.read().strip()
    if ":" not in line:
        return None, None
    user, pwhash = line.split(":", 1)
    return user, pwhash


def _check_auth(username, password):
    user, pwhash = _load_auth()
    if not user:
        return True
    return username == user and check_password_hash(pwhash, password)


def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        user, _ = _load_auth()
        if user is None:
            return f(*args, **kwargs)
        auth = request.authorization
        if not auth or not _check_auth(auth.username, auth.password):
            return Response(
                "Authentication required", 401,
                {"WWW-Authenticate": 'Basic realm="Modbus Proxy GUI"'},
            )
        return f(*args, **kwargs)
    return decorated


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
def load_names():
    if not os.path.exists(NAMES_PATH):
        return {}
    try:
        with open(NAMES_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_names(names):
    tmp = NAMES_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(names, f, indent=2)
    os.replace(tmp, NAMES_PATH)


def load_devices():
    if not os.path.exists(CONFIG_PATH):
        return []
    with open(CONFIG_PATH) as f:
        data = yaml.safe_load(f) or {}
    names = load_names()
    devices = []
    for d in data.get("devices", []):
        modbus = d.get("modbus", {}) or {}
        listen = d.get("listen", {}) or {}
        url = str(modbus.get("url", ""))
        host, _, port = url.rpartition(":")
        bind = str(listen.get("bind", ""))
        _, _, lport = bind.rpartition(":")
        label = names.get(lport, f"{host}:{port}")
        devices.append({"name": label, "host": host, "port": port, "listen_port": lport})
    devices.sort(key=lambda d: int(d["listen_port"]) if d["listen_port"].isdigit() else 0)
    return devices


def save_devices(devices):
    data = {"devices": []}
    names = {}
    for d in devices:
        data["devices"].append({
            "modbus": {"url": f"{d['host']}:{d['port']}"},
            "listen": {"bind": f"0.0.0.0:{d['listen_port']}"},
        })
        if d.get("name"):
            names[d["listen_port"]] = d["name"]
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    os.replace(tmp, CONFIG_PATH)
    save_names(names)


def restart_proxy():
    subprocess.run(["systemctl", "restart", SERVICE_NAME], check=False)


def service_active():
    r = subprocess.run(["systemctl", "is-active", SERVICE_NAME], capture_output=True, text=True)
    return r.stdout.strip() == "active"


def get_clients(port):
    clients = []
    if not port:
        return clients
    try:
        r = subprocess.run(
            ["ss", "-tn", "state", "established", f"( sport = :{port} )"],
            capture_output=True, text=True, timeout=5,
        )
        for line in r.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4:
                peer = parts[-1]
                ip, _, pport = peer.rpartition(":")
                if ip:
                    clients.append({"ip": ip, "port": pport})
    except Exception:
        pass
    return clients


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------
CSS = """
:root{--bg:#0f172a;--card:#1e293b;--text:#e2e8f0;--muted:#94a3b8;--accent:#38bdf8;--ok:#22c55e;--bad:#ef4444;--border:#334155;}
*{box-sizing:border-box;}
body{margin:0;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--text);}
header{background:var(--card);padding:16px 24px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;}
header h1{font-size:18px;margin:0;}
nav a{color:var(--muted);text-decoration:none;margin-left:20px;font-size:14px;}
nav a.active,nav a:hover{color:var(--accent);}
main{padding:24px;max-width:1000px;margin:0 auto;}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:20px;margin-bottom:20px;}
table{width:100%;border-collapse:collapse;}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--border);font-size:14px;vertical-align:top;}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;}
.badge{display:inline-block;padding:2px 10px;border-radius:12px;font-size:12px;font-weight:600;}
.badge.ok{background:rgba(34,197,94,.15);color:var(--ok);}
.badge.bad{background:rgba(239,68,68,.15);color:var(--bad);}
.btn{display:inline-block;padding:8px 16px;background:var(--accent);color:#0f172a;border:none;border-radius:6px;font-weight:600;text-decoration:none;cursor:pointer;font-size:14px;}
.btn.danger{background:var(--bad);color:#fff;}
.btn.secondary{background:transparent;border:1px solid var(--border);color:var(--text);}
input{width:100%;padding:8px 10px;border-radius:6px;border:1px solid var(--border);background:#0f172a;color:var(--text);margin-bottom:12px;font-size:14px;}
label{font-size:13px;color:var(--muted);display:block;margin-bottom:4px;}
.error{background:rgba(239,68,68,.15);color:var(--bad);padding:10px 14px;border-radius:6px;margin-bottom:16px;font-size:14px;}
.row{display:flex;gap:12px;flex-wrap:wrap;}
.row > div{flex:1;min-width:140px;}
.stat{font-size:28px;font-weight:700;}
.stat-label{color:var(--muted);font-size:13px;}
.stats{display:flex;gap:16px;margin-bottom:20px;flex-wrap:wrap;}
.stats .card{flex:1;min-width:160px;margin-bottom:0;}
.pill{display:inline-block;background:#0f172a;border:1px solid var(--border);border-radius:12px;padding:2px 8px;font-size:12px;margin:2px 4px 2px 0;}
form.inline{display:inline;}
h2{font-size:15px;color:var(--muted);text-transform:uppercase;letter-spacing:.03em;margin-top:0;}
"""


def layout(title, active, body):
    return ("""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>""" + title + """ - Modbus Proxy</title>
<style>""" + CSS + """</style></head><body>
<header>
  <h1>Modbus Proxy</h1>
  <nav>
    <a href="/" class=\"""" + ("active" if active == "dashboard" else "") + """\">Dashboard</a>
    <a href="/servers" class=\"""" + ("active" if active == "servers" else "") + """\">Servers</a>
  </nav>
</header>
<main>""" + body + """</main>
</body></html>""")


DASHBOARD_BODY = """
{% if not active %}
<div class="card"><span class="badge bad">STOPPED</span> The modbus-proxy service is not running.
<form class="inline" method="post" action="/restart"><button class="btn" style="margin-left:10px;">Start / Restart</button></form></div>
{% endif %}
<div class="stats">
  <div class="card"><div class="stat">{{ devices|length }}</div><div class="stat-label">Configured servers</div></div>
  <div class="card"><div class="stat">{{ total_clients }}</div><div class="stat-label">Active client connections</div></div>
  <div class="card"><span class="badge {{ 'ok' if active else 'bad' }}">{{ 'RUNNING' if active else 'STOPPED' }}</span>
    <div class="stat-label" style="margin-top:8px;">modbus-proxy service</div>
    <form class="inline" method="post" action="/restart"><button class="btn secondary" style="margin-top:8px;padding:4px 10px;font-size:12px;">Restart</button></form>
  </div>
</div>
<div class="card">
<h2>Servers &amp; who's polling them</h2>
<table>
<tr><th>Name</th><th>Upstream</th><th>Proxy listen port</th><th>Active clients</th></tr>
{% for d in devices %}
<tr>
  <td>{{ d.name }}</td>
  <td>{{ d.host }}:{{ d.port }}</td>
  <td>{{ d.listen_port }}</td>
  <td>
    {% if d.clients %}
      {% for c in d.clients %}<span class="pill">{{ c.ip }}</span>{% endfor %}
    {% else %}<span style="color:var(--muted);">no clients connected</span>{% endif %}
  </td>
</tr>
{% else %}
<tr><td colspan="4" style="color:var(--muted);">No servers configured yet — add one on the <a href="/servers">Servers</a> page.</td></tr>
{% endfor %}
</table>
</div>
"""

SERVERS_BODY = """
{% if error %}<div class="error">{{ error }}</div>{% endif %}
<div class="card">
<h2>Configured servers</h2>
<table>
<tr><th>Name</th><th>Upstream host</th><th>Upstream port</th><th>Listen port</th><th></th></tr>
{% for d in devices %}
<tr>
  <td>{{ d.name }}</td><td>{{ d.host }}</td><td>{{ d.port }}</td><td>{{ d.listen_port }}</td>
  <td>
    <a class="btn secondary" href="/servers/{{ d.listen_port }}/edit" style="padding:4px 10px;font-size:12px;">Edit</a>
    <form class="inline" method="post" action="/servers/{{ d.listen_port }}/delete" onsubmit="return confirm('Remove {{ d.name }}?');">
      <button class="btn danger" style="padding:4px 10px;font-size:12px;">Delete</button>
    </form>
  </td>
</tr>
{% else %}
<tr><td colspan="5" style="color:var(--muted);">No servers configured yet.</td></tr>
{% endfor %}
</table>
</div>
<div class="card">
<h2>Add a Modbus TCP server</h2>
<form method="post">
  <div class="row">
    <div><label>Name</label><input name="name" placeholder="e.g. PLC-Line1" required></div>
    <div><label>Upstream host / IP</label><input name="host" placeholder="192.168.1.101" required></div>
  </div>
  <div class="row">
    <div><label>Upstream Modbus port</label><input name="port" value="502" required></div>
    <div><label>Proxy listen port (clients connect here)</label><input name="listen_port" placeholder="5020" required></div>
  </div>
  <button class="btn" type="submit">Add server</button>
</form>
</div>
"""

EDIT_BODY = """
{% if error %}<div class="error">{{ error }}</div>{% endif %}
<div class="card">
<h2>Edit {{ device.name }}</h2>
<form method="post">
  <div class="row">
    <div><label>Name</label><input name="name" value="{{ device.name }}" required></div>
    <div><label>Upstream host / IP</label><input name="host" value="{{ device.host }}" required></div>
  </div>
  <div class="row">
    <div><label>Upstream Modbus port</label><input name="port" value="{{ device.port }}" required></div>
    <div><label>Proxy listen port</label><input name="listen_port" value="{{ device.listen_port }}" required></div>
  </div>
  <button class="btn" type="submit">Save</button>
  <a class="btn secondary" href="/servers">Cancel</a>
</form>
</div>
"""


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.route("/")
@requires_auth
def dashboard():
    devices = load_devices()
    total_clients = 0
    for d in devices:
        d["clients"] = get_clients(d["listen_port"])
        total_clients += len(d["clients"])
    body = render_template_string(
        DASHBOARD_BODY, devices=devices, active=service_active(), total_clients=total_clients
    )
    return layout("Dashboard", "dashboard", body)


@app.route("/restart", methods=["POST"])
@requires_auth
def restart():
    restart_proxy()
    return redirect(url_for("dashboard"))


@app.route("/servers", methods=["GET", "POST"])
@requires_auth
def servers():
    devices = load_devices()
    error = None
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        host = request.form.get("host", "").strip()
        port = request.form.get("port", "502").strip()
        listen_port = request.form.get("listen_port", "").strip()
        if not name or not host or not port.isdigit() or not listen_port.isdigit():
            error = "All fields are required; ports must be numeric."
        elif any(d["listen_port"] == listen_port for d in devices):
            error = f"Listen port {listen_port} is already in use."
        else:
            devices.append({"name": name, "host": host, "port": port, "listen_port": listen_port})
            save_devices(devices)
            restart_proxy()
            return redirect(url_for("servers"))
    body = render_template_string(SERVERS_BODY, devices=devices, error=error)
    return layout("Servers", "servers", body)


@app.route("/servers/<listen_port>/edit", methods=["GET", "POST"])
@requires_auth
def edit_server(listen_port):
    devices = load_devices()
    device = next((d for d in devices if d["listen_port"] == listen_port), None)
    if not device:
        return redirect(url_for("servers"))
    error = None
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        host = request.form.get("host", "").strip()
        port = request.form.get("port", "502").strip()
        new_listen_port = request.form.get("listen_port", "").strip()
        if not name or not host or not port.isdigit() or not new_listen_port.isdigit():
            error = "All fields are required; ports must be numeric."
        elif any(d["listen_port"] == new_listen_port and d["listen_port"] != listen_port for d in devices):
            error = f"Listen port {new_listen_port} is already used by another server."
        device.update(name=name, host=host, port=port, listen_port=new_listen_port)
        if not error:
            save_devices(devices)
            restart_proxy()
            return redirect(url_for("servers"))
    body = render_template_string(EDIT_BODY, device=device, error=error)
    return layout("Edit server", "servers", body)


@app.route("/servers/<listen_port>/delete", methods=["POST"])
@requires_auth
def delete_server(listen_port):
    devices = [d for d in load_devices() if d["listen_port"] != listen_port]
    save_devices(devices)
    restart_proxy()
    return redirect(url_for("servers"))


if __name__ == "__main__":
    gui_port = int(os.environ.get("GUI_PORT", "8088"))
    app.run(host="0.0.0.0", port=gui_port)
PYEOF
pct push "$CTID" "$GUI_APP_FILE" /opt/modbus-proxy-gui/app.py
rm -f "$GUI_APP_FILE"
msg_ok "GUI application deployed."

# ---------------------------------------------------------------------------
# GUI authentication
# ---------------------------------------------------------------------------
if [ -n "$GUI_USER" ]; then
  msg_info "Setting up GUI authentication..."
  GUI_HASH=$(pct exec "$CTID" -- /opt/modbus-proxy/venv/bin/python3 -c '
import sys
from werkzeug.security import generate_password_hash
print(generate_password_hash(sys.stdin.readline().rstrip("\n")))
' <<< "$GUI_PASS")
  AUTH_FILE=$(mktemp)
  printf '%s:%s\n' "$GUI_USER" "$GUI_HASH" > "$AUTH_FILE"
  pct push "$CTID" "$AUTH_FILE" /etc/modbus-proxy-gui/auth
  rm -f "$AUTH_FILE"
  unset GUI_PASS P1 P2
  msg_ok "GUI login configured for user '$GUI_USER'."
else
  msg_warn "No GUI username set — the web GUI will be reachable WITHOUT a login. Restrict network access accordingly."
fi

# ---------------------------------------------------------------------------
# GUI systemd service
# ---------------------------------------------------------------------------
msg_info "Creating GUI systemd service..."
GUI_SERVICE_FILE=$(mktemp)
cat > "$GUI_SERVICE_FILE" <<EOF
[Unit]
Description=Modbus Proxy Web GUI
After=network-online.target modbus-proxy.service
Wants=network-online.target

[Service]
Type=simple
Environment=GUI_PORT=${GUI_PORT}
WorkingDirectory=/opt/modbus-proxy-gui
ExecStart=/opt/modbus-proxy/venv/bin/python3 /opt/modbus-proxy-gui/app.py
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
pct push "$CTID" "$GUI_SERVICE_FILE" /etc/systemd/system/modbus-proxy-gui.service
rm -f "$GUI_SERVICE_FILE"

pct exec "$CTID" -- bash -c "systemctl daemon-reload && systemctl enable --now modbus-proxy-gui"
sleep 2
if pct exec "$CTID" -- systemctl is-active --quiet modbus-proxy-gui; then
  msg_ok "Web GUI is running."
else
  msg_error "modbus-proxy-gui service did not start — check 'pct exec $CTID -- journalctl -u modbus-proxy-gui -e'."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

echo
msg_ok "Deployment complete."
echo "----------------------------------------------------------------------"
echo " Container:   CTID $CTID  (${HOSTNAME})"
echo " IP address:  ${CT_IP}"
echo " Web GUI:     http://${CT_IP}:${GUI_PORT}/"
if [ -n "$GUI_USER" ]; then
  echo "   Login:     user '${GUI_USER}' / the password you entered"
else
  echo "   Login:     none configured — restrict network access to this port"
fi
echo " Config file: /etc/modbus-proxy/config.yml (inside the CT)"
echo " Services:    modbus-proxy, modbus-proxy-gui  (systemctl status/restart, inside the CT)"
echo
echo " Client connections (point your Modbus clients here instead of the"
echo " original devices):"
for ((i = 1; i <= SRV_COUNT; i++)); do
  echo "   ${SRV_NAME[i]}:  ${CT_IP}:${SRV_LISTEN[i]}  -->  ${SRV_HOST[i]}:${SRV_PORT[i]}"
done
echo
echo " Servers can now also be added/edited/removed from the web GUI, and"
echo " the Dashboard page shows which client IPs are currently connected"
echo " to each proxy port."
echo
echo " Note: the GUI can edit the proxy config and restart the service —"
echo " treat it like any other admin interface and keep it off untrusted"
echo " networks."
echo "----------------------------------------------------------------------"
