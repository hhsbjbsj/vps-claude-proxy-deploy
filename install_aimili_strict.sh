#!/usr/bin/env bash
# Apply local AimiliVPN strict-residential customization and preserve user data.
set -Eeuo pipefail
umask 077

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] 请以 root 运行。' >&2; exit 1; }
APP=/opt/aimilivpn/vpngate_manager.py
AUTH=/opt/aimilivpn/vpngate_data/ui_auth.json
[[ -f "$APP" && -f "$AUTH" ]] || { echo '[ERROR] 未发现 AimiliVPN 源码与配置；请先完成原始部署。' >&2; exit 1; }
grep -q 'DEFAULT_APP_VERSION = "2.1.5"' "$APP" || {
  echo '[ERROR] 当前 AimiliVPN 版本不匹配已审核的 2.1.5 基线。拒绝覆盖；需更新适配。' >&2
  exit 1
}
command -v curl >/dev/null && command -v python3 >/dev/null || {
  echo '[ERROR] 缺少 curl 或 Python 3。' >&2; exit 1
}
command -v systemctl >/dev/null || { echo '[ERROR] 当前不是 systemd 系统。' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
URL=https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/aimili/vpngate_manager.py
echo '==> 下载严格住宅筛选版 AimiliVPN...'
curl -fL --retry 3 --connect-timeout 10 --max-time 90 -o "$WORK/vpngate_manager.py" "$URL"
python3 -m py_compile "$WORK/vpngate_manager.py"
grep -q 'def strict_residential_match(' "$WORK/vpngate_manager.py" || {
  echo '[ERROR] 下载内容没有严格住宅功能，已终止。' >&2; exit 1
}
grep -q 'DEFAULT_APP_VERSION = "2.1.5"' "$WORK/vpngate_manager.py" || {
  echo '[ERROR] 修改版的上游版本不匹配。' >&2; exit 1
}

BACKUP_DIR=/var/backups/vp-aimili
install -d -m 700 "$BACKUP_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_APP="$BACKUP_DIR/vpngate_manager.$STAMP.py"
BACKUP_AUTH="$BACKUP_DIR/ui_auth.$STAMP.json"
cp -a "$APP" "$BACKUP_APP"
cp -a "$AUTH" "$BACKUP_AUTH"
chmod 600 "$BACKUP_APP" "$BACKUP_AUTH"

echo '==> 配置持久保护：避免上游 ml update 静默覆盖严格筛选...'
PINNED_DIR=/usr/local/share/vp/aimili
PINNED="$PINNED_DIR/vpngate_manager.py"
GUARD=/usr/local/libexec/vp-aimili-guard
DROPIN=/etc/systemd/system/aimilivpn.service.d/10-vp-strict.conf
install -d -m 755 "$PINNED_DIR" /usr/local/libexec /etc/systemd/system/aimilivpn.service.d
install -m 644 "$WORK/vpngate_manager.py" "$PINNED"
cat > "$GUARD" <<'GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail
# Only pair the patched manager with the reviewed Aimili 2.1.5 dependency version.
[[ -f /opt/aimilivpn/VERSION ]] || { echo '[VP] Missing Aimili version file' >&2; exit 1; }
[[ "$(cat /opt/aimilivpn/VERSION)" == "2.1.5" ]] || {
  echo '[VP] Aimili version changed; strict-residential guard refuses unsafe startup.' >&2
  exit 1
}
install -m 644 /usr/local/share/vp/aimili/vpngate_manager.py /opt/aimilivpn/vpngate_manager.py
GUARD
chmod 755 "$GUARD"
cat > "$DROPIN" <<'DROPIN'
[Service]
ExecStartPre=/usr/local/libexec/vp-aimili-guard
DROPIN
chmod 644 "$DROPIN"
systemctl daemon-reload
echo '==> 启用严格住宅筛选，保留已有面板地址及登录凭据...'
install -m 644 "$WORK/vpngate_manager.py" "$APP"
python3 - "$AUTH" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    cfg = json.load(handle)
cfg["routing_ip_type"] = "residential_strict"
cfg["routing_mode"] = "auto"
directory = os.path.dirname(path)
fd, temp = tempfile.mkstemp(prefix=".vp-aimili-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(cfg, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temp, 0o600)
    os.replace(temp, path)
finally:
    if os.path.exists(temp):
        os.unlink(temp)
PY

echo '==> 重启 AimiliVPN（sing-box 配置和密钥不变）...'
if ! systemctl restart aimilivpn; then
  echo '[ERROR] 重启失败，尝试恢复旧版程序和配置。' >&2
  rm -f "$DROPIN" "$GUARD" "$PINNED"
  systemctl daemon-reload || true
  cp -a "$BACKUP_APP" "$APP"
  cp -a "$BACKUP_AUTH" "$AUTH"
  systemctl restart aimilivpn || true
  exit 1
fi
sleep 3
if ! systemctl is-active --quiet aimilivpn; then
  echo '[ERROR] AimiliVPN 未保持运行，正在回滚。' >&2
  rm -f "$DROPIN" "$GUARD" "$PINNED"
  systemctl daemon-reload || true
  cp -a "$BACKUP_APP" "$APP"
  cp -a "$BACKUP_AUTH" "$AUTH"
  systemctl restart aimilivpn || true
  exit 1
fi

echo '[OK] 严格住宅模式已安装，已启用自动选择。'
echo '[OK] 未修改 sing-box 443 / 8443 入口，也未修改 7928 / 8787 端口。'
echo '[说明] 仅接受 ip_type=residential 且 confidence=medium/high 的候选；连接后复核实际出口。'
echo '[说明] 如果无符合条件的出口，代理可能不可用；不会为此改用未知/移动/机房节点。'
echo "[备份] $BACKUP_DIR"
echo '[保护] 上游 ml update 若仍为 Aimili 2.1.5，systemd 启动时会恢复本修改版。'
echo '[保护] 若上游版本变化，服务拒绝启动以避免悄悄失去严格住宅保障；需先更新本修改版。'
