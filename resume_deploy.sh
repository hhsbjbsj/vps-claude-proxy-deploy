#!/usr/bin/env bash
# Recover a partially completed VP deployment without rotating sing-box keys.
set -Eeuo pipefail
umask 077
fail() { echo "[ERROR] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "Run as root."
[[ -f /etc/sing-box/config.json ]] || fail "Missing /etc/sing-box/config.json; not a partial VP deployment."
[[ -f /opt/aimilivpn/vpngate_manager.py ]] || fail "Missing Aimili source; this recovery tool is not an initial installer."
[[ -f /opt/aimilivpn/vpngate_data/ui_auth.json ]] || fail "Missing Aimili configuration; inspect your previous installation."
command -v python3 >/dev/null && command -v curl >/dev/null && command -v openssl >/dev/null || fail "Missing python3/curl/openssl."
[[ -x /usr/local/bin/sing-box ]] || fail "Expected /usr/local/bin/sing-box, not found."
if [[ -d /run/systemd/system ]]; then
  command -v systemctl >/dev/null || fail "systemctl missing."
  systemctl is-active --quiet sing-box || fail "sing-box service is not active. Inspect its logs first."
else
  command -v rc-service >/dev/null || fail "No supported service manager."
  rc-service sing-box status >/dev/null || fail "sing-box service is not active."
fi

echo '==> Verifying existing config and preserving VLESS+REALITY keys...'
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
python3 - <<'PY'
import json
from pathlib import Path
cfg = json.loads(Path('/etc/sing-box/config.json').read_text(encoding='utf-8'))
ins = {i.get('tag'):i for i in cfg.get('inbounds', [])}
assert ins.get('normal-443',{}).get('listen_port') == 443
assert ins.get('strict-8443',{}).get('listen_port') == 8443
assert any(o.get('tag')=='aimili-residential' and o.get('type')=='socks' for o in cfg.get('outbounds', []))
print('Existing deployment signature: valid. No keys will be changed.')
PY

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main
echo '==> Repairing the strict residential Aimili integration...'
curl -fL --retry 3 -o "$tmp/install_aimili_strict.sh" "$base/install_aimili_strict.sh"
bash -n "$tmp/install_aimili_strict.sh"
bash "$tmp/install_aimili_strict.sh" || fail "Aimili strict installation did not succeed; check the service journal, do not rerun the main installer."

echo '==> Recovering Karing import links from existing credentials...'
if [[ -e /root/karing-nodes.txt ]]; then
  echo '[OK] Existing Karing file is preserved; no credentials will be overwritten.'
else
  python3 - <<'PY'
from pathlib import Path
from urllib.parse import quote
import base64
import ipaddress
import json
import os
import subprocess

cfg = json.loads(Path('/etc/sing-box/config.json').read_text(encoding='utf-8'))
ins = {i.get('tag'):i for i in cfg.get('inbounds', [])}
first, second = ins['normal-443'], ins['strict-8443']
uuid = first['users'][0]['uuid']
tls = first['tls']
sni = tls['server_name']
private_s = tls['reality']['private_key']
sid = tls['reality']['short_id'][0]
assert first['tls']['reality']['private_key']==second['tls']['reality']['private_key']
assert first['users'][0]['uuid']==second['users'][0]['uuid']
private = base64.urlsafe_b64decode(private_s + '=' * (-len(private_s) % 4))
assert len(private) == 32, 'Invalid X25519 private key'
der = bytes.fromhex('302e020100300506032b656e04220420') + private
proc = subprocess.run(
    ['openssl','pkey','-inform','DER','-pubout','-outform','DER'],
    input=der, capture_output=True, check=True
)
prefix = bytes.fromhex('302a300506032b656e032100')
assert len(proc.stdout)==len(prefix)+32 and proc.stdout.startswith(prefix)
public = base64.urlsafe_b64encode(proc.stdout[len(prefix):]).decode().rstrip('=')

ip_s = os.environ.get('PUBLIC_IP','').strip()
if not ip_s:
    cp = subprocess.run(
        ['curl','-4','-fsS','--connect-timeout','5','--max-time','15','https://api.ipify.org'],
        capture_output=True,text=True,check=True
    )
    ip_s = cp.stdout.strip()
ip = ipaddress.IPv4Address(ip_s)
assert ip.is_global, 'Detected address is not a public IPv4; set PUBLIC_IP to actual VPS address'
params = '&'.join([
    'encryption=none','security=reality','sni='+quote(sni,safe=''),
    'fp=chrome','pbk='+quote(public,safe=''),'sid='+quote(sid,safe=''),
    'type=tcp','flow=xtls-rprx-vision'
])
urls = (
    f'vless://{uuid}@{ip}:443?{params}#VPS-Direct-443\n'
    f'vless://{uuid}@{ip}:8443?{params}#Residential-Strict-8443\n'
)
path = '/root/karing-nodes.txt'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd,'w',encoding='utf-8') as file:
    file.write(urls)
print('Node links saved securely: /root/karing-nodes.txt (mode 0600)')
PY
fi

echo '==> Installing or updating VP management menu...'
curl -fL --retry 3 -o "$tmp/install_manager.sh" "$base/install_manager.sh"
bash -n "$tmp/install_manager.sh"
bash "$tmp/install_manager.sh"
echo '[OK] Resume completed without changing sing-box credentials.'
echo 'Check: vp status'
echo 'Check: ls -l /root/karing-nodes.txt'
echo 'Residential traffic availability still depends on a working classified VPNGate exit.'
