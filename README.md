# Ubuntu VPS：sing-box + AI Mili VPNGate 部署脚本

在全新 Ubuntu VPS 上部署 VLESS + REALITY 节点，以及 AI Mili VPNGate SOCKS5 出口。**仓库不包含任何运行后生成的凭据、UUID、REALITY 私钥、节点链接或 VPS IP。**

> ⚠️ 实验性配置：已做 Bash 语法检查，但未在目标 VPS 上完成端到端验证。脚本会安装服务、修改系统网络参数；应在可通过云厂商控制台恢复的 VPS 上使用。请先审查源码。

## 部署内容

- sing-box 1.14.4，启动 VLESS + REALITY（Vision），随机生成凭据。
- TCP **443**：普通入口，服务端能识别的 Claude 域名的 TCP 流量走 AI Mili，其他默认由 VPS 直连。
- TCP **8443**：严格入口，所有 TCP 通过 AI Mili，失败后不自动改走 VPS 机房出口；UDP 拒绝。
- AI Mili 的 SOCKS5：`127.0.0.1:7928`，Web 控制面板：`0.0.0.0:8787`（公网 IPv4 可访问）。
- Karing 导入链接保存在 VPS 的 `/root/karing-nodes.txt`，文件权限为 0600。

## 运行要求

全新 Ubuntu VPS，`x86_64` 或 `aarch64` 架构，具备 root/sudo 权限、systemd、`/dev/net/tun`，可访问 apt 和 GitHub。云服务商安全组允许 TCP **443**、**8443**、**8787** 入站；**不要将 7928 代理端口开放到互联网**。公网面板使用随机路径与账号密码，建议额外配置 HTTPS 或可信来源 IP 限制。

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

AI Mili 管理面板默认公网监听。在浏览器打开 `http://你的VPS公网IP:8787/随机安全路径/`，随机路径和账号由 VPS 的 `ml status` 给出。如无法打开，请检查云厂商的防火墙/安全组是否允许 TCP 8787。**HTTP 明文访问可能泄露登录凭据；建议为公网访问配置 HTTPS 反向代理。**根据需要在 AI Mili 面板选择 VPNGate 节点，并核验 SOCKS5 的实际出口 IP。

## 注意事项

- VPNGate 是第三方志愿者出口，公网 IP 可能变化。**这不是固定住宅 IP、Claude 账号风控免疫、或绝对 DNS 不泄漏的保证。**
- AI Mili 当前 SOCKS5 只实现 TCP CONNECT；不支持 UDP ASSOCIATE。严格入口拒绝 UDP，可能影响 QUIC/HTTP3。
- 只有真正经过 VPS、且被服务端识别的域名才能匹配域名规则。Karing 端仍需要 TUN、DNS 接管和适当的路由规则。本地直连或应用自带 DoH 不由服务端保证。
- 上游 AI Mili 来自其官方 `main` 分支，随时间变化；生产环境宜固定版本并审查代码。
- 本脚本不会自动调整云服务商防火墙；本地防火墙只在 UFW 已启用时添加 443/8443/8787 TCP。
- 不要提交 `/etc/sing-box/config.json`、`/root/karing-nodes.txt` 或 AI Mili 的账号、凭据文件到公开仓库。

## 上游项目

[sing-box](https://github.com/SagerNet/sing-box) · [AI Mili VPNGate](https://github.com/baoweise-bot/aimili-vpngate)

## 常驻 VPS 管理面板（vp）

这个项目新增了**终端交互管理面板**。安装一次以后，重启系统或重新登录 SSH 也可以随时输入 `vp` 召唤；它不是需要开放公网端口的独立 Web 站点。AI Mili 的 8787 Web 管理后台仍保持原有配置。

已经安装过本项目的 VPS，**不要再次运行 `deploy_vps_claude.sh`**，而是单独安装常驻菜单（以下每条都是完整的单行命令）：

```bash
curl -fL --retry 3 -o /root/install_manager.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_manager.sh
bash -n /root/install_manager.sh
bash /root/install_manager.sh
vp
```

以后新装 VPS，主部署脚本完成后会自动尝试安装 `vp`。

菜单包括：状态检查、443 普通节点 IPv4-only/IPv6-only 出口切换、选择本机 IPv6 源地址、AI Mili 菜单、BBRv3 官方菜单、节点链接、日志及菜单更新。也支持无需进入交互菜单的命令：

```bash
vp status
vp egress ipv4
vp egress ipv6
vp egress ipv6 --source-ipv6 你的公网IPv6
vp bbr
vp update
```

### IPv6 出口切换范围与限制

- 切换的是 **443 普通节点的 VPS 直连出站**，不是 443 的连接入口地址，也不是 VPS 系统全局 IPv6 开关。
- Claude 域名匹配后的流量仍走 AI Mili SOCKS5；**8443 严格住宅出口始终不变**。VPNGate 本身无法因此获得 IPv6 住宅出口。
- 选择 IPv6-only 前会检查 VPS 的全局 IPv6 地址、默认 IPv6 路由以及公网可达性，支持多地址时手动选定出站源 IPv6。没有 IPv6 的 VPS 会拒绝切换。
- IPv6-only 模式对普通 443 流量启用 IPv6 DNS 解析、拒绝解析后的 IPv4 地址；因此仅有 IPv4 的目标网站可能无法访问，而不是退回 VPS IPv4。
- 切换前自动保留 `/etc/sing-box/vp-backups/` 备份，先运行 `sing-box check`，再重启 sing-box，服务启动失败会尝试自动回滚。切换可能短暂中断节点连接，不会主动改变 SSH 和系统默认路由。
- 此功能不能代替 Karing TUN 和 DNS 接管；是否真正使用 IPv6 出口应在 Karing 节点连接后做端到端测试。只看 VPS 上 `curl -6` 的检测结果不足以证明代理客户端使用了 IPv6。

### BBRv3 项目集成

菜单选择 BBRv3 后才会下载并启动 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 的交互式安装脚本。出于安全性和可重现性，上游脚本固定至提交 `4f9bd79bd66b6115f717665403e6d29839551604`；不复制其内核包，也不会在安装 `vp`、切换 IPv6 时自动装内核或重启。

⚠️ BBRv3 是内核级变更，可能影响 VPS 驱动、引导和网络；必须确认能通过云厂商控制台/救援模式恢复后再自行在上游菜单选择安装。**BBRv3 安装与 IPv6 出口切换是完全独立的两个功能。**
