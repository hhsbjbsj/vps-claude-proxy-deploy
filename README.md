# VPS Direct — 不含 AI Mili 的独立版本

**当前为 no-aimili 分支，主分支 main 保持完整功能，互不影响。**

- [独立直连版 no-aimili](https://github.com/hhsbjbsj/vps-claude-proxy-deploy/tree/no-aimili)
- [完整版本 main（含 AI Mili）](https://github.com/hhsbjbsj/vps-claude-proxy-deploy/tree/main)

这个分支只部署 sing-box 的 VLESS + REALITY + Vision。**不会安装或调用 AI Mili、OpenVPN、VPNGate，亦不创建 7928 SOCKS5、8787 Web 面板、住宅 IP 筛选与自动切换。** 不会删除用户机器原来装过的其他服务。

## 两个独立节点

| 入口 | 出站 | 用途 |
| --- | --- | --- |
| TCP 443 | vps-direct | 主节点；可用 VP 菜单切换 IPv4-only 或 IPv6-only |
| TCP 8443 | backup-direct | 备用节点；独立直连，不随 443 的切换更改配置 |

两个入口不是相互转发，也不是住宅链式代理。它们使用 VPS 的公网 IP 出站。同一台 VPS 和同一进程不构成真正的双机容灾。

## 系统支持

- Debian 12/13、Ubuntu 24.04+：APT + systemd。
- Alpine Linux：APK + OpenRC。
- Fedora、Rocky、AlmaLinux 等 RPM 系：DNF/YUM + systemd，具体依赖可能随发行版不同。
- CPU 支持 x86_64 和 aarch64，需 root、有效的系统包源与 GitHub 下载权限。
- 不需要 OpenVPN、VPNGate 或服务器的 /dev/net/tun。客户端 Karing 的 TUN 则由客户端自行决定。
- 开放云服务商安全组入站 TCP 443、8443；**不要为此版本开放 7928、8787**。

目前通过的是自动化预检、静态语法和逻辑测试，尚未在每种真实 VPS 上完成端到端验收。请先审查源码。

## 新 VPS 首次安装

**仅用于没有 sing-box 配置和服务的全新 VPS。** 若服务器已经安装完整版本或存在 /etc/sing-box/config.json，会主动拒绝覆盖，避免重新生成 UUID / REALITY 私钥。不要删除现有配置后盲装。

Debian / Ubuntu 先运行：

~~~bash
apt-get update && apt-get install -y bash curl ca-certificates less
~~~

Alpine 则使用：

~~~bash
apk add --no-cache bash curl ca-certificates less
~~~

Fedora / Rocky 等使用：

~~~bash
dnf install -y bash curl ca-certificates less
~~~

后续下载此分支专用脚本，**不要下载 main 的安装器**：

~~~bash
curl -fL --retry 3 -o /root/deploy-direct.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/no-aimili/deploy_vps_claude.sh
~~~

预检（不修改服务器）：

~~~bash
bash -n /root/deploy-direct.sh && bash /root/deploy-direct.sh --preflight
~~~

阅读源代码：

~~~bash
less /root/deploy-direct.sh
~~~

按 q 退出，再执行：

~~~bash
bash /root/deploy-direct.sh
~~~

如无法自动获取公网 IPv4，请确认后运行 PUBLIC_IP=你的公网IPv4 bash /root/deploy-direct.sh。

安装后 Karing 链接会存储于 **/root/karing-nodes.txt**，权限为 0600，包含私人的 UUID 和节点连接参数，不要公开分享。

## 管理菜单 VP（SSH 终端面板）

本分支只提供 VPS 终端交互菜单，不部署新的 Web 管理面板或 3x-ui。

~~~text
1  运行状态、IPv4/IPv6 出口检查
2  443 主节点切换到 IPv4-only
3  443 主节点切换到 IPv6-only（可选源地址）
4  打开 BBRv3 菜单（需手动确认）
5  显示 Karing 节点链接（敏感）
6  查看 sing-box 最近日志
7  更新 VP 直连版管理工具
0  退出
~~~

通过 VP 调整 443 的出口时，8443 使用独立的 backup-direct，不随切换修改。若 VPS 没有公网 IPv6 或默认 IPv6 路由，菜单会拒绝 IPv6-only；仅有 IPv4 的目标在 IPv6-only 模式下可能无法访问。

BBRv3 功能仅对 Debian/Ubuntu 开放，需单独确认后才能启动内核变更菜单，默认不会安装内核。

单独更新 VP 菜单（**只适用于本分支部署的配置**）：

~~~bash
curl -fL --retry 3 -o /root/install_manager.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/no-aimili/install_manager.sh
~~~

~~~bash
bash -n /root/install_manager.sh && bash /root/install_manager.sh
~~~

也可以使用 vp、vp status、vp egress ipv4、vp egress ipv6、vp bbr、vp update。新版管理器会先校验配置身份，不允许用直连版管理工具覆盖 main 分支的配置。启动器设置了 UTF-8 输出，可避开最小化 Debian 的 Latin-1 中文菜单错误。

## 验收

Debian、Ubuntu、Fedora 等 systemd 系统：

~~~bash
systemctl is-active sing-box
~~~

Alpine/OpenRC：

~~~bash
rc-service sing-box status
~~~

通用检查：

~~~bash
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
~~~

~~~bash
ls -l /root/karing-nodes.txt
~~~

~~~bash
vp status
~~~

在 Karing 中分别测试两个节点的 TCP、UDP 和 DNS/IPv6 出口；只看 VPS 本机 curl 检测无法证明 Karing 的真实分流或 DNS 出口。

## 注意事项

- 这是 **VPS 机房出口直连版**，没有住宅 IP，更不能保证任何第三方平台的风控结果。
- 443 与 8443 虽使用两个独立直连出站，但仍共用同一个 sing-box 服务及 VPS。
- 系统原有的服务和防火墙规则不会被清除，云服务商侧安全组需要用户自行检查。
- sing-box 二进制固定为 1.14.4，并校验 SHA-256；不会在安装器中悄悄更新内核或部署其他代理面板。
