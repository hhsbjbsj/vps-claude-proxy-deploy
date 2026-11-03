#!/usr/bin/env bash
# Ubuntu VPS: sing-box 1.14.4 VLESS+REALITY + AI Mili VPNGate
# 443 = split route, 8443 = strict TCP residential; no residential UDP fallback.
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
trap 'echo "[ERROR] Failed at line ${LINENO}. Check the output above." >&2' ERR

[[ $EUID -eq 0 ]] || fail "Use sudo bash deploy_vps_claude.sh"
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || fail "This script is for Ubuntu only (detected: ${ID:-unknown})."
[[ -d /run/systemd/system ]] || fail "systemd not found."
[[ -c /dev/net/tun ]] || fail "Missing /dev/net/tun: enable TUN/TAP in your VPS control panel before installation."

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

info "Installing Ubuntu dependencies"
apt-get update
apt-get install -y ca-certificates curl git iproute2 iptables openssl python3 openvpn psmisc tar

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

info "Installing sing-box service"
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
systemctl enable --now sing-box
systemctl is-active --quiet sing-box || fail "sing-box failed. Inspect: journalctl -u sing-box -n 80"

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
systemctl is-active sing-box || true
systemctl is-active aimilivpn || true
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
  systemctl restart aimilivpn || true
fi

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow 443/tcp
  ufw allow 8443/tcp
  ufw allow 8787/tcp
fi

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