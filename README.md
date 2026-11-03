# Ubuntu VPS：sing-box + AI Mili VPNGate 部署脚本

在全新 Ubuntu VPS 上部署 VLESS + REALITY 节点，以及 AI Mili VPNGate SOCKS5 出口。**仓库不包含任何运行后生成的凭据、UUID、REALITY 私钥、节点链接或 VPS IP。**

> ⚠️ 实验性配置：已做 Bash 语法检查，但未在目标 VPS 上完成端到端验证。脚本会安装服务、修改系统网络参数；应在可通过云厂商控制台恢复的 VPS 上使用。请先审查源码。

## 部署内容

- sing-box 1.14.4，启动 VLESS + REALITY（Vision），随机生成凭据。
- TCP **443**：普通入口，服务端能识别的 Claude 域名的 TCP 流量走 AI Mili，其他默认由 VPS 直连。
- TCP **8443**：严格入口，所有 TCP 通过 AI Mili，失败后不自动改走 VPS 机房出口；UDP 拒绝。
- AI Mili 的 SOCKS5：`127.0.0.1:7928`，Web 控制面板：`127.0.0.1:8787`（SSH 隧道访问）。
- Karing 导入链接保存在 VPS 的 `/root/karing-nodes.txt`，文件权限为 0600。

## 运行要求

全新 Ubuntu VPS，`x86_64` 或 `aarch64` 架构，具备 root/sudo 权限、systemd、`/dev/net/tun`，可访问 apt 和 GitHub。云服务商安全组允许 TCP **443**、**8443** 入站；不要将 7928 或 8787 对互联网开放。

若已存在 `/etc/sing-box/config.json` 或 `/opt/aimilivpn`，脚本会拒绝覆盖，以免误删旧配置。

## 一键安装

登录 VPS 后执行：

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl
curl -fL --retry 3 -o /tmp/deploy_vps_claude.sh \
  https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/deploy_vps_claude.sh
less /tmp/deploy_vps_claude.sh   # 请先检查下载的脚本
sudo bash /tmp/deploy_vps_claude.sh
```

如无法自动检测公网 IPv4：

```bash
sudo env PUBLIC_IP=你的VPS公网IPv4 bash /tmp/deploy_vps_claude.sh
```

## 验收与管理

```bash
systemctl is-active sing-box aimilivpn
sudo sing-box check -c /etc/sing-box/config.json
sudo cat /root/karing-nodes.txt
sudo ml status
curl -4 --max-time 15 --proxy socks5h://127.0.0.1:7928 https://api.ipify.org
```

在 Windows PowerShell 中建立面板隧道：

```powershell
ssh -N -L 8787:127.0.0.1:8787 root@你的VPS公网IP
```

随后在本机浏览器打开 `http://127.0.0.1:8787/随机安全路径/`，路径和账号由 VPS 的 `ml status` 给出。根据需要在 AI Mili 面板选择 VPNGate 节点，并核验 SOCKS5 的实际出口 IP。

## 注意事项

- VPNGate 是第三方志愿者出口，公网 IP 可能变化。**这不是固定住宅 IP、Claude 账号风控免疫、或绝对 DNS 不泄漏的保证。**
- AI Mili 当前 SOCKS5 只实现 TCP CONNECT；不支持 UDP ASSOCIATE。严格入口拒绝 UDP，可能影响 QUIC/HTTP3。
- 只有真正经过 VPS、且被服务端识别的域名才能匹配域名规则。Karing 端仍需要 TUN、DNS 接管和适当的路由规则。本地直连或应用自带 DoH 不由服务端保证。
- 上游 AI Mili 来自其官方 `main` 分支，随时间变化；生产环境宜固定版本并审查代码。
- 本脚本不会自动调整云服务商防火墙；本地防火墙只在 UFW 已启用时添加 443/8443 TCP。
- 不要提交 `/etc/sing-box/config.json`、`/root/karing-nodes.txt` 或 AI Mili 的账号、凭据文件到公开仓库。

## 上游项目

[sing-box](https://github.com/SagerNet/sing-box) · [AI Mili VPNGate](https://github.com/baoweise-bot/aimili-vpngate)
