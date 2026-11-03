#!/usr/bin/env bash
# Install or update only the VP terminal management menu. No sing-box or kernel rewrite.
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] 请使用 root 或 sudo。' >&2; exit 1; }
[[ -f /etc/sing-box/config.json ]] || { echo '[ERROR] 未发现现有 sing-box 配置，先部署基础节点。' >&2; exit 1; }
command -v python3 >/dev/null || { echo '[ERROR] 缺少 python3。' >&2; exit 1; }
command -v curl >/dev/null || { echo '[ERROR] 缺少 curl。' >&2; exit 1; }
python3 - <<'PY'
import json, sys
path='/etc/sing-box/config.json'
try:
    with open(path, encoding='utf-8') as f:
        cfg=json.load(f)
    tags={i.get('tag') for i in cfg.get('inbounds',[])}
    outs={o.get('tag'):o.get('type') for o in cfg.get('outbounds',[])}
    assert {'normal-443','backup-8443'} <= tags
    assert outs.get('vps-direct') == 'direct'
    assert outs.get('backup-direct') == 'direct'
    assert cfg.get('route',{}).get('final') == 'vps-direct'
    assert all(o.get('type') != 'socks' for o in cfg.get('outbounds',[]))
except Exception:
    print('[ERROR] 检测到非 no-aimili 版本的配置；为避免覆盖其他版本的 VP，已停止。',file=sys.stderr)
    sys.exit(1)
PY

TARGET=/usr/local/libexec/vp_manager.py
WRAPPER=/usr/local/bin/vp
if [[ -e "$WRAPPER" ]] && ! grep -qF '/usr/local/libexec/vp_manager.py' "$WRAPPER"; then
  echo '[ERROR] /usr/local/bin/vp 已存在其他程序，不会覆盖。' >&2; exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SOURCE=https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/no-aimili/vp_manager.py
curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$WORK/vp_manager.py" "$SOURCE"
python3 -m py_compile "$WORK/vp_manager.py"
# Reject stale CDN downloads or scripts from before the terminal encoding fix.
if ! grep -qF 'backup-8443' "$WORK/vp_manager.py"; then
  echo '[ERROR] 下载到错误分支的 VP 程序（缺少备用入口标签），不覆盖原有管理器。' >&2
  exit 1
fi
if ! grep -qF 'def configure_utf8_stdio()' "$WORK/vp_manager.py"; then
  echo '[ERROR] 下载到旧版 VP 管理器：缺少 UTF-8 输出修复。为保护现有安装，拒绝覆盖。' >&2
  exit 1
fi
install -d -m 755 /usr/local/libexec
install -m 755 "$WORK/vp_manager.py" "$TARGET"
cat > "$WORK/vp" <<'EOF'
#!/usr/bin/env bash
# Force UTF-8 for Chinese menu output even if the VPS login environment is Latin-1.
export PYTHONIOENCODING=utf-8:backslashreplace
exec /usr/bin/python3 /usr/local/libexec/vp_manager.py "$@"
EOF
install -m 755 "$WORK/vp" "$WRAPPER"
if ! grep -qF 'export PYTHONIOENCODING=utf-8:backslashreplace' "$WRAPPER"; then
  echo '[ERROR] VP 启动器未安装 UTF-8 修复，请检查安装路径。' >&2
  exit 1
fi
"$WRAPPER" --help >/dev/null || {
  echo '[ERROR] VP 新版启动器未通过自测。' >&2
  exit 1
}
echo '[OK] VP 管理菜单已安装。输入 vp 打开面板。'
echo '[OK] 输入 vp status 检查出站；输入 vp egress ipv4 / vp egress ipv6 切换 443。'
echo '[提示] 这只是管理工具安装，不会更改 sing-box 配置或安装 BBR 内核。'
echo '[OK] UTF-8 启动器校验通过（可直接使用 vp，无需设置环境变量）。'
