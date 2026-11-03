#!/usr/bin/env bash
# VPS Direct Edition (Debian/Ubuntu/Alpine/RPM): sing-box VLESS+REALITY without AI Mili
# 443 primary, 8443 backup: two independent VPS-direct inbounds.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
trap 'echo "[ERROR] Failed at line ${LINENO}. Check the output above." >&2' ERR

[[ $EUID -eq 0 ]] || fail "Run as root (sudo bash deploy_vps_claude.sh)"
[[ -r /etc/os-release ]] || fail "Cannot detect Linux distribution (/etc/os-release missing)."
source /etc/os-release
case "${ID:-unknown}" in
  ubuntu|debian)
    distro_family=apt
    distro_service=systemd
    ;;
  alpine)
    distro_family=apk
    distro_service=openrc
    ;;
  fedora|rocky|almalinux|rhel|centos|ol|amzn)
    distro_family=rpm
    distro_service=systemd
    ;;
  *)
    fail "Unsupported Linux distribution: ${ID:-unknown}. Supported: Debian, Ubuntu, Alpine/OpenRC, Fedora and compatible RPM systemd distributions."
    ;;
esac
check_apt_sources() {
  [[ "$distro_family" == apt ]] || return 0
  # This parses all enabled APT source files without updating package lists or networking.
  # Do not edit third-party repositories automatically: they may be needed by existing users.
  local diagnostics
  if diagnostics="$(apt-get indextargets 2>&1 >/dev/null)"; then
    echo "APT source syntax: OK"
    return 0
  fi
  printf '%s\n' "$diagnostics" >&2
  cat >&2 <<'HELP'
[ERROR] APT sources cannot be parsed. This problem predates VPS deployment.
Inspect the file named in the error under /etc/apt/sources.list.d/.
For example, when the error names sagernet.sources:
  cat /etc/apt/sources.list.d/sagernet.sources
  mv /etc/apt/sources.list.d/sagernet.sources /etc/apt/sources.list.d/sagernet.sources.disabled
  apt-get update
Disable ONLY the invalid third-party file; do not delete default Debian/Ubuntu sources.
The script will NOT change APT repositories for you.
HELP
  return 1
}
check_apt_sources || fail "APT repository validation failed; repair the reported source and retry."

info "Detected distro: ${PRETTY_NAME:-$ID}; package family: $distro_family; service: $distro_service"
if [[ ${1:-} == --preflight ]]; then
  echo "Preflight only: no packages, configurations, or services have been changed."
  echo 'TUN: not required (no OpenVPN or local TUN used)'
  if command -v python3 >/dev/null; then python3 --version; else echo 'Python 3: not installed (installer will install; requires >=3.10)'; fi
  if [[ $distro_service == systemd ]]; then
    [[ -d /run/systemd/system ]] && echo 'systemd: running' || echo 'systemd: not running (required)'
  else
    command -v rc-service >/dev/null && echo 'OpenRC command: present' || echo 'OpenRC command: missing (required)'
  fi
  exit 0
fi
[[ $# == 0 ]] || fail "Unknown argument: $1 (supported: --preflight)."
if [[ $distro_service == systemd ]]; then
  [[ -d /run/systemd/system ]] || fail "systemd is not running; container/shared host? This installer requires a real service manager."
else
  command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 || fail "OpenRC tools not found."
fi
echo '[INFO] Direct-only mode requires no TUN device.'

svc_enable() {
  if [[ $distro_service == systemd ]]; then systemctl enable --now "$1"; else rc-update add "$1" default && rc-service "$1" start; fi
}
svc_restart() {
  if [[ $distro_service == systemd ]]; then systemctl restart "$1"; else rc-service "$1" restart; fi
}
svc_active() {
  if [[ $distro_service == systemd ]]; then systemctl is-active --quiet "$1"; else rc-service "$1" status >/dev/null 2>&1; fi
}
svc_status() {
  if svc_active "$1"; then echo "$1: active"; else echo "$1: inactive"; fi
}

case "$(uname -m)" in
  x86_64) arch=amd64; checksum=699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968 ;;
  aarch64) arch=arm64; checksum=436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26 ;;
  *) fail "Only x86_64 and aarch64 are supported by this deploy script." ;;
esac

# This is intended for a clean reinstall. Avoid rotating live credentials.
[[ ! -f /etc/sing-box/config.json ]] || fail "/etc/sing-box/config.json already exists; refusing to overwrite."
[[ ! -e /etc/systemd/system/sing-box.service && ! -e /etc/init.d/sing-box ]] || fail 'Existing sing-box service found; refusing to replace.'
for p in 443 8443; do
  if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${p}$"; then
    fail "TCP port $p is already occupied; stop and inspect the existing service first."
  fi
done

info "Installing minimal Linux dependencies"
case "$distro_family" in
  apt)
    apt-get update
    apt-get install -y ca-certificates curl iproute2 openssl python3 tar
    ;;
  apk)
    apk update
    apk add --no-cache bash ca-certificates curl iproute2 openssl python3 tar coreutils
    ;;
  rpm)
    if command -v dnf >/dev/null 2>&1; then pkg=dnf
    elif command -v yum >/dev/null 2>&1; then pkg=yum
    else fail "RPM distribution has neither dnf nor yum."
    fi
    "$pkg" install -y ca-certificates curl iproute openssl python3 tar
    ;;
esac
command -v ss >/dev/null || fail "ss is required to inspect occupied ports."
for p in 443 8443; do
  if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])$p$"; then
    fail "TCP port $p occupied; refusing to overwrite existing service."
  fi
done
info "Checking public IPv4"
PUBLIC_IP="${PUBLIC_IP:-$(curl -4fsS --connect-timeout 5 --max-time 15 https://api.ipify.org || true)}"
[[ $PUBLIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Cannot determine IPv4; rerun with PUBLIC_IP=your_vps_ipv4 sudo -E bash deploy_vps_claude.sh"
echo "VPS IPv4: $PUBLIC_IP"

info "Downloading verified sing-box 1.14.4"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg="sing-box-1.14.4-linux-${arch}"
curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
  -o "$work/${pkg}.tar.gz" \
  "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/${pkg}.tar.gz"
printf '%s  %s\n' "$checksum" "$work/${pkg}.tar.gz" | sha256sum -c -
tar -xzf "$work/${pkg}.tar.gz" -C "$work"
install -m 0755 "$work/$pkg/sing-box" /usr/local/bin/sing-box
sing-box version | head -n 2

info "Generating VLESS and REALITY credentials"
UUID="$(sing-box generate uuid)"
KEYPAIR="$(sing-box generate reality-keypair)"
PRIVATE_KEY="$(printf '%s\n' "$KEYPAIR" | sed -nE 's/^[[:space:]]*PrivateKey:[[:space:]]*//p' | head -1)"
PUBLIC_KEY="$(printf '%s\n' "$KEYPAIR" | sed -nE 's/^[[:space:]]*PublicKey:[[:space:]]*//p' | head -1)"
SHORT_ID="$(openssl rand -hex 8)"
[[ -n $UUID && -n $PRIVATE_KEY && -n $PUBLIC_KEY && -n $SHORT_ID ]] || fail "Credential generation failed."
SNI=www.microsoft.com

info "Writing direct-only sing-box configuration"
install -d -m 0700 /etc/sing-box
python3 - "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" <<'PY'
import json, sys, os
uuid, private, sid, sni = sys.argv[1:]
def vless_in(tag, port):
    return {
      "type": "vless", "tag": tag, "listen": "::", "listen_port": port,
      "users": [{"name": "user", "uuid": uuid, "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": True, "server_name": sni,
        "reality": {
          "enabled": True,
          "handshake": {"server": sni, "server_port": 443},
          "private_key": private,
          "short_id": [sid]
        }
      }
    }
cfg = {
 "log": {"level": "info", "timestamp": True},
 "inbounds": [vless_in("normal-443", 443), vless_in("backup-8443", 8443)],
 "outbounds": [
   {"type": "direct", "tag": "vps-direct"},
   {"type": "direct", "tag": "backup-direct"}
 ],
 "dns": {"servers": [{"type": "local", "tag": "local-dns"}], "final": "local-dns"},
 "route": {
   "default_domain_resolver": "local-dns",
   "rules": [{"inbound": ["backup-8443"], "action": "route", "outbound": "backup-direct"}],
   "final": "vps-direct"
 }
}
p = "/etc/sing-box/config.json"
fd = os.open(p, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
sing-box check -c /etc/sing-box/config.json || fail "sing-box config validation failed."

info "Installing sing-box $distro_service service"
if [[ $distro_service == systemd ]]; then
  cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box VLESS Reality proxy
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
else
  cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
description="sing-box VLESS Reality proxy"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err.log"
depend() { need net; after firewall; }
EOF
  chmod 755 /etc/init.d/sing-box
fi
svc_enable sing-box
svc_active sing-box || fail "sing-box service failed to start. Check journalctl (systemd) or /var/log/sing-box.err.log (OpenRC)."

# Open only the two VLESS Reality TCP entry ports.
# No 7928 SOCKS5, 8787 web UI, or OpenVPN is installed.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 443/tcp
  ufw allow 8443/tcp
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; then
  for p in 443 8443; do firewall-cmd --permanent --add-port="$p/tcp" || true; done
  firewall-cmd --reload || true
fi
info "Saving Karing import links (root-only)"
link_base="vless://${UUID}@${PUBLIC_IP}"
query="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision"
cat > /root/karing-nodes.txt <<EOF
${link_base}:443?${query}#VPS-Direct-443
${link_base}:8443?${query}#VPS-Direct-8443-Backup
EOF
chmod 600 /root/karing-nodes.txt
echo '[OK] Karing import links saved at /root/karing-nodes.txt (permissions 0600).'
echo '[INFO] 443 primary and 8443 backup are independent entries with VPS-direct egress.'
echo '[INFO] Allow inbound TCP 443/8443 in the provider firewall; do not open 7928/8787.'

info "Installing VP terminal manager (non-destructive)"
if curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$work/install_manager.sh" \
  https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/no-aimili/install_manager.sh; then
  if bash "$work/install_manager.sh"; then
    echo '[OK] Run vp anytime to open the menu. BBRv3 integration is optional.'
  else
    echo '[WARN] VP menu installer failed; core proxy deployment is still complete.'
  fi
else
  echo '[WARN] Cannot fetch VP menu installer. Retry installation separately from GitHub.'
fi
