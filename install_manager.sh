#!/usr/bin/env bash
# Install or update only the VP terminal management menu. No sing-box or kernel rewrite.
set -Eeuo pipefail
umask 077
[[ \${EUID:-$(id -u)} -eq 0 ]] || { echo '[ERROR] 请使用 root 或 sudo。' >&2; exit 1; }
[[ -f /etc/sing-box/config.json ]] || { echo '[ERROR] 未发现现有 sing-box 配置，先部署基础节点。' >&2; exit 1; }
command -v python3 >/dev/null || { echo '[ERROR] 缺少 python3。' >&2; exit 1; }
command -v curl >/dev/null || { echo '[ERROR] 缺少 curl。' >&2; exit 1; }
TARGET=/usr/local/libexec/vp_manager.py
WRAPPER=/usr/local/bin/vp
if [[ -e "$WRAPPER" ]] && ! grep -qF '/usr/local/libexec/vp_manager.py' "$WRAPPER"; then
  echo '[ERROR] /usr/local/bin/vp 已存在其他程序，不会覆盖。' >&2; exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SOURCE=https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/vp_manager.py
curl -fL --retry 3 --connect-timeout 10 --max-time 60 -o "$WORK/vp_manager.py" "$SOURCE"
python3 -m py_compile "$WORK/vp_manager.py"
install -d -m 755 /usr/local/libexec
install -m 755 "$WORK/vp_manager.py" "$TARGET"
cat > "$WORK/vp" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/libexec/vp_manager.py "$@"
EOF
install -m 755 "$WORK/vp" "$WRAPPER"
echo '[OK] VP 管理菜单已安装。输入 vp 打开面板。'
echo '[OK] 输入 vp status 检查出站；输入 vp egress ipv4 / vp egress ipv6 切换 443。'
echo '[提示] 这只是管理工具安装，不会更改 sing-box 配置或安装 BBR 内核。'
