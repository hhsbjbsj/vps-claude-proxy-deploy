#!/usr/bin/env bash
# Linux VPS (Debian, Ubuntu, Alpine, Fedora, and compatible RPM): sing-box + AI Mili VPNGate
# 443 = split route, 8443 = strict TCP residential; no residential UDP fallback.
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
  if [[ -c /dev/net/tun ]]; then echo 'TUN: present'; else echo 'TUN: missing (required for full deployment)'; fi
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
[[ -c /dev/net/tun ]] || fail "Missing /dev/net/tun: enable TUN/TAP in your VPS control panel before installation."

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
[[ ! -e /opt/aimilivpn ]] || fail "/opt/aimilivpn already exists; refusing to overwrite."
for p in 443 8443 7928 8787; do
  if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${p}$"; then
    fail "TCP port $p is already occupied; stop and inspect the existing service first."
  fi
done

info "Installing Linux dependencies ($distro_family)"
case "$distro_family" in
  apt)
    apt-get update
    apt-get install -y ca-certificates curl git iproute2 iptables openssl python3 openvpn psmisc tar
    ;;
  apk)
    apk update
    apk add bash ca-certificates curl git iproute2 iptables openssl python3 openvpn psmisc tar coreutils
    ;;
  rpm)
    if command -v dnf >/dev/null 2>&1; then pkg=dnf
    elif command -v yum >/dev/null 2>&1; then pkg=yum
    else fail "RPM distribution has neither dnf nor yum."
    fi
    if [[ "$ID" != fedora && "$ID" != amzn ]]; then
      "$pkg" install -y epel-release || echo '[WARN] EPEL not directly available; trying the configured repositories.'
    fi
    "$pkg" install -y ca-certificates curl git iproute iptables openssl python3 openvpn psmisc tar
    ;;
esac
python3 - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit(
        "AI Mili requires Python >= 3.10; detected {}.{}. "
        "On this distribution, install a supported system Python before deploying. "
        "No sing-box configuration has been written.".format(*sys.version_info[:2])
    )
print("Python compatibility: {}.{}".format(*sys.version_info[:2]))
PY
command -v openvpn >/dev/null || fail "openvpn package not installed; check software repositories (EPEL may be needed on RPM systems)."


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

info "Writing sing-box config"
install -d -m 0700 /etc/sing-box
python3 - "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SNI" <<'PY'
import json, sys, os
uuid, private_key, sid, sni = sys.argv[1:]
claude_domains = ["anthropic.com", "claude.ai", "claude.com"]
def vless_in(tag, port):
    return {
      "type": "vless", "tag": tag, "listen": "::", "listen_port": port,
      "users": [{"name": "user", "uuid": uuid, "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": True, "server_name": sni,
        "reality": {
          "enabled": True,
          "handshake": {"server": sni, "server_port": 443},
          "private_key": private_key,
          "short_id": [sid]
        }
      }
    }
cfg = {
 "log": {"level": "info", "timestamp": True},
 "inbounds": [vless_in("normal-443", 443), vless_in("strict-8443", 8443)],
 "outbounds": [
   {"type": "direct", "tag": "vps-direct"},
   {"type": "socks", "tag": "aimili-residential", "server": "127.0.0.1", "server_port": 7928, "version": "5", "network": "tcp"}
 ],
 "dns": {
   "servers": [
     {"type": "local", "tag": "local-dns"},
     {"type": "https", "tag": "residential-doh", "server": "1.1.1.1", "path": "/dns-query", "tls": {"enabled": True, "server_name": "cloudflare-dns.com"}, "detour": "aimili-residential"}
   ],
   "rules": [
     {"inbound": ["strict-8443"], "action": "route", "server": "residential-doh"},
     {"domain_suffix": claude_domains, "action": "route", "server": "residential-doh"}
   ],
   "final": "local-dns"
 },
 "route": {
   "default_domain_resolver": "local-dns",
   "rules": [
     {"action": "sniff", "timeout": "300ms"},
     {"inbound": ["strict-8443"], "network": "udp", "action": "reject"},
     {"inbound": ["strict-8443"], "action": "route", "outbound": "aimili-residential"},
     {"domain_suffix": claude_domains, "network": "udp", "action": "reject"},
     {"domain_suffix": claude_domains, "action": "route", "outbound": "aimili-residential"}
   ],
   "final": "vps-direct"
 }
}
path = "/etc/sing-box/config.json"
fd = os.open(path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
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

# Bind AI Mili Web UI to the public IPv4 interface, while keeping SOCKS5 loopback-only.
info "Preparing AI Mili installer with a public IPv4 control panel"
curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$work/aimili-install.sh" \
  https://raw.githubusercontent.com/baoweise-bot/aimili-vpngate/main/install.sh
# Only replace the literal initial config default; no bypass of installation.
python3 - "$work/aimili-install.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='"host": "::"'
assert s.count(needle)>=2, "Upstream installer changed; inspect it before continuing"
p.write_text(s.replace(needle, '"host": "0.0.0.0"'))
PY
info "Installing AI Mili (may fetch a free VPNGate node automatically)"
AIMILIVPN_NONINTERACTIVE=1 bash "$work/aimili-install.sh"

info "Checking local services"
svc_status sing-box
svc_status aimilivpn
ss -lntp | grep -E ':(443|8443|7928|8787)\b' || true

# Ensure that the management UI uses the requested public IPv4 bind.
if [[ -f /opt/aimilivpn/vpngate_data/ui_auth.json ]]; then
  python3 - <<'PY'
import json,os
p='/opt/aimilivpn/vpngate_data/ui_auth.json'
with open(p) as f: data=json.load(f)
if data.get('host') != '0.0.0.0':
    data['host']='0.0.0.0'
    tmp=p+'.tmp'
    with open(tmp,'w') as f: json.dump(data,f,indent=2)
    os.chmod(tmp,0o600); os.replace(tmp,p)
PY
  svc_restart aimilivpn || true
fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 443/tcp
  ufw allow 8443/tcp
  ufw allow 8787/tcp
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qx running; then
  for p in 443 8443 8787; do firewall-cmd --permanent --add-port="$p/tcp" || true; done
  firewall-cmd --reload || true
fi

info "Integrating strict residential-only AimiliVPN selection"
curl -fL --retry 3 --connect-timeout 10 --max-time 90 \
  -o "$work/install_aimili_strict.sh" \
  https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_aimili_strict.sh
bash -n "$work/install_aimili_strict.sh"
bash "$work/install_aimili_strict.sh" || fail "Strict residential Aimili integration failed. Do not assume the exit is residential."

info "Saving Karing import links (root-only)"
link_base="vless://${UUID}@${PUBLIC_IP}"
query="encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision"
cat > /root/karing-nodes.txt <<EOF
${link_base}:443?${query}#VPS-Direct-443
${link_base}:8443?${query}#Residential-Strict-8443
EOF
chmod 600 /root/karing-nodes.txt
printf '\n===== Import links (keep private) =====\n'
cat /root/karing-nodes.txt
printf '\n===== AI Mili panel =====\n'
echo "AI Mili Web UI: http://${PUBLIC_IP}:8787/SECRET_PATH/"
echo 'Use: ml status (on VPS) to see the actual panel path and credentials.'
echo 'Open inbound TCP 8787 in your VPS provider firewall/security group if required.'
printf '\n===== Local AI Mili SOCKS test =====\n'
if curl -4fsS --max-time 12 --proxy socks5h://127.0.0.1:7928 https://api.ipify.org; then echo; else
  echo 'Residential SOCKS egress is NOT verified. Check tun0 and select a fixed VPNGate node in the panel.'
fi
printf '\n===== Important =====\n'
echo '443: default VPS egress; recognized Claude TCP routed via AI Mili.'
echo '8443: all TCP through AI Mili; UDP rejected; no fallback to VPS direct.'
echo 'Keep Karing TUN & DNS routing configured. 8443 is best for fail-closed sensitive traffic.'
echo 'In provider firewall/security group, allow inbound TCP 443, 8443, and 8787.'
echo 'VPNGate public exit IP may change. No stable IP or account access is guaranteed.'

info "Installing VP terminal manager (non-destructive)"
if curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$work/install_manager.sh" \
  https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_manager.sh; then
  if bash "$work/install_manager.sh"; then
    echo '[OK] Run vp anytime to open the menu. BBRv3 integration is optional.'
  else
    echo '[WARN] VP menu installer failed; core proxy deployment is still complete.'
  fi
else
  echo '[WARN] Cannot fetch VP menu installer. Retry installation separately from GitHub.'
fi
