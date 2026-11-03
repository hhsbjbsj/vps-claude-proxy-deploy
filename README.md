# Linux VPS：sing-box + AI Mili VPNGate 多发行版部署

在全新 Debian、Ubuntu、Alpine、Fedora 或兼容 RPM 系 Linux VPS 上部署 VLESS + REALITY 节点，以及 AI Mili VPNGate SOCKS5 出口。**仓库不包含任何运行后生成的凭据、UUID、REALITY 私钥、节点链接或 VPS IP。**

> ⚠️ 实验性配置：已做 Bash 语法检查，但未在目标 VPS 上完成端到端验证。脚本会安装服务、修改系统网络参数；应在可通过云厂商控制台恢复的 VPS 上使用。请先审查源码。

## 已部署 VPS 的 VP 中文菜单乱码或 Latin-1 报错

部分最小化 Debian VPS 的 Python 标准输出使用 Latin-1，可能导致 `vp` 的中文菜单抛出 `UnicodeEncodeError`。**服务 `sing-box`、`aimilivpn` 正常运行时，完全不需要重新部署代理或更换节点凭据。**

### 先验证原因（只读）

```bash
type -a vp
```

```bash
sed -n '1,8p' /usr/local/bin/vp
```

如果输出只有：

```bash
#!/usr/bin/env bash
exec /usr/bin/python3 /usr/local/libexec/vp_manager.py "$@"
```

那么是**本地旧启动器缺少 UTF-8 环境设置**，不是 Linux 发行版、服务端节点或别名造成的。临时运行：

```bash
PYTHONIOENCODING=utf-8:backslashreplace vp status
```

### 立即修复当前服务器（不影响代理服务）

先备份，再给缺少设置的启动器补一行；此命令可重复执行，不会重复添加相同设置：

```bash
cp -an /usr/local/bin/vp /usr/local/bin/vp.bak
```

```bash
grep -q '^export PYTHONIOENCODING=utf-8:backslashreplace$' /usr/local/bin/vp || sed -i '2i export PYTHONIOENCODING=utf-8:backslashreplace' /usr/local/bin/vp
```

```bash
bash -n /usr/local/bin/vp && vp status
```

再直接运行 `vp` 即可。这**只改 `/usr/local/bin/vp`**，不会重启 sing-box / AI Mili、修改 443/8443 或覆盖 Karing 链接。

### 从 GitHub 更新菜单（更推荐后续使用）

```bash
curl -fL --retry 3 -o /root/install_manager.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_manager.sh
```

```bash
bash -n /root/install_manager.sh && bash /root/install_manager.sh
```

新版安装器会**检测下载的管理程序是否包含 UTF-8 修复**，安装后还会校验 `/usr/local/bin/vp` 的 UTF-8 设置并运行启动测试。若下载到旧缓存内容，会拒绝静默覆盖原有程序。更新后可通过 `sed -n '1,8p' /usr/local/bin/vp` 查看启动器是否包含 `export PYTHONIOENCODING=utf-8:backslashreplace`。

如果依然出现编码异常，请附上 `type -a vp`、`sed -n '1,8p' /usr/local/bin/vp` 和 `vp status` 的输出继续诊断。

## 部署内容

- sing-box 1.14.4，启动 VLESS + REALITY（Vision），随机生成凭据。
- TCP **443**：普通入口，**所有网站（包括 Claude）默认使用 VPS 直连出口及本地 DNS**，不再有 Claude 域名强制住宅规则。
- TCP **8443**：严格入口，所有 TCP 通过 AI Mili，失败后不自动改走 VPS 机房出口；UDP 拒绝。
- AI Mili 的 SOCKS5：`127.0.0.1:7928`，Web 控制面板：`0.0.0.0:8787`（公网 IPv4 可访问）。
- Karing 导入链接保存在 VPS 的 `/root/karing-nodes.txt`，文件权限为 0600。

## 已部署完整版本：移除 Claude 强制住宅路由

**2026-11-03 修正：旧版 main 部署器曾写入三条 Claude 特殊规则**，强行将 Claude 的 TCP 出站和 DNS 指向住宅代理，并拒绝其 UDP 流量。这会使普通 443 节点也走住宅代理。最新版**不再生成这些规则**：

- **443**：所有网站（包括 Claude）默认经 VPS 直连（vps-direct），使用本地 DNS（local-dns），没有 Claude 特判。
- **8443**：是另一个可选的住宅入口，TCP 走本地 AI Mili SOCKS5，UDP 拒绝，相关 DoH 仍通过住宅出口。只有在 Karing **主动选择 8443 节点**或自行配置链式代理时才会走它。
- **已有 VPS 不会因为 GitHub 更新自动改变配置**，需要单独迁移。迁移不卸载 AI Mili、不会替换 UUID/REALITY 密钥，也不更改 Karing 节点链接。

为避免误删定制规则，仓库提供只清除旧版三条 Claude 强制规则的修复器 remove_claude_forced_routes.py。先下载并做只读检查：

~~~bash
curl -fL --retry 3 -o /root/remove_claude_forced_routes.py https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/remove_claude_forced_routes.py
~~~

~~~bash
python3 /root/remove_claude_forced_routes.py
~~~

审查修复器后，明确执行修改（包含配置备份、sing-box check、重启和失败回滚）：

~~~bash
python3 /root/remove_claude_forced_routes.py --apply
~~~

备份写入 /etc/sing-box/vp-backups/，只作用于符合本项目 main 443/8443 结构的配置。**如果检测到其他自定义 Claude 住宅规则，会拒绝自动删除并提示人工检查。** 应用时 sing-box 会短暂重启，SSH、AI Mili 服务和客户端节点凭据保持不变。

> 注意：修复的是 **VPS sing-box 服务端** 规则。如果你在 **Karing** 客户端另设了 Claude → 住宅节点或链式代理，客户端规则仍然有效；需要分别检查。

## 运行要求与兼容性

需要全新 VPS、root 权限、`x86_64` / `aarch64` 架构、`/dev/net/tun`、可工作的软件源和 GitHub 下载连通性，且 **Python 3.10 或更高版本**。共享内核容器未必允许建立 TUN 或策略路由；这种环境不应直接使用本部署器。

| 发行版 | 包管理器 | 服务管理 | 支持范围 |
| --- | --- | --- | --- |
| Debian 12 / 13 | apt-get | systemd | 核心支持 |
| Ubuntu 24.04+ / 26.04 | apt-get | systemd | 核心支持 |
| Alpine Linux（OpenRC） | apk | OpenRC | 已加入安装适配，仍需真实 VPS 验收 |
| Fedora（现代版本） | dnf | systemd | 已加入安装适配，仍需真实 VPS 验收 |
| Rocky / AlmaLinux / RHEL / Oracle Linux / CentOS Stream / Amazon Linux | dnf 或 yum | systemd | **有条件适配**：要求 Python 3.10+，OpenVPN 软件包可用，EPEL/额外仓库可能必需；RHEL9 系常见的 Python 3.9 **不满足要求** |
| Arch / Manjaro / openSUSE / Void / 其他 | — | — | 暂不支持，预检将明确拒绝，不会盲装 |

公网 Web 面板监听 TCP **8787**，VLESS Reality 监听 TCP **443 / 8443**；请在 VPS 服务商防火墙允许这些端口。**SOCKS5 7928 只监听 127.0.0.1，禁止向公网开放。** 公网面板直接使用 HTTP 存在明文凭据风险，建议为其配置 HTTPS 反向代理或 IP 白名单。

若已有 `/etc/sing-box/config.json` 或 `/opt/aimilivpn`，主部署器会拒绝覆盖。更新已有服务器请使用 `vp` 管理菜单，不要重新执行首次安装。

## Debian / Ubuntu 常见故障：APT 软件源配置损坏

如果尚未运行本项目的安装脚本，执行 \`apt-get update\` 就出现：

\`\`\`text
E: Malformed entry 1 in sources file /etc/apt/sources.list.d/sagernet.sources (URI)
E: The list of sources could not be read.
\`\`\`

说明**系统中已存在格式错误的第三方软件源**，APT 不能解析其地址。这不是切换到 \`apk\` 或 \`dnf\` 能解决的；Debian/Ubuntu 始终使用 \`apt-get\`。

先查看文件：

\`\`\`bash
cat /etc/apt/sources.list.d/sagernet.sources
\`\`\`

确认报错指向该文件后，保留备份、暂时禁用它：

\`\`\`bash
mv /etc/apt/sources.list.d/sagernet.sources /etc/apt/sources.list.d/sagernet.sources.disabled
\`\`\`

重新运行：

\`\`\`bash
apt-get update && apt-get install -y bash curl ca-certificates less
\`\`\`

**仅停用报错点名的损坏文件，不要删除系统原生的 Debian/Ubuntu 软件源，也不要执行 \`rm -rf /etc/apt\`。** 如果下一次报错指向其他文件，请针对新的错误检查，不要盲目批量禁用。

**现在部署器的 \`--preflight\` 会使用 \`apt-get indextargets\` 只做本地源文件语法解析**：发现格式损坏会直接解释原因并中止，不会自动篡改现有软件源，也不需要访问网络。

## 全新 VPS：首次一键安装（请先做这一步）

**第一步：根据发行版安装下载工具**。所有命令都是完整的一行，避免因为反斜杠换行复制出错。

**Debian / Ubuntu：**

```bash
apt-get update && apt-get install -y bash curl ca-certificates less
```

**Alpine Linux：**

```bash
apk add --no-cache bash curl ca-certificates less
```

**Fedora / RHEL 系：**

```bash
dnf install -y bash curl ca-certificates less
```

如果该发行版没有 `dnf` 而只有 `yum`，使用 `yum install -y bash curl ca-certificates less`。

**第二步：下载主部署器（所有发行版相同）**

```bash
curl -fL --retry 3 -o /root/deploy.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/deploy_vps_claude.sh
```

**第三步：检查脚本并执行无修改预检**

```bash
ls -lh /root/deploy.sh && bash -n /root/deploy.sh && bash /root/deploy.sh --preflight
```

预检只显示发行版、包管理器、服务管理器、Python 版本和 TUN 状态，**不会安装软件或改变系统配置**。如果报告缺少 TUN、未运行 systemd/OpenRC，或 Python 版本过低，需要先解决；尤其不要把 Rocky/Alma/RHEL9 上的 Python 3.9 当成已兼容。

**第四步：阅读并开始安装**

```bash
less /root/deploy.sh
```

查看完按 `q` 返回终端，再运行：

```bash
bash /root/deploy.sh
```

部署器会安装 sing-box 双 Reality 节点、AI Mili、严格住宅筛选、Karing 导入链接和 `vp` 管理菜单。安装结果需以日志和下方验收为准；出现 `[ERROR]` / `FATAL` 必须先排查，不要继续当作部署成功验收。

如果不能自动获取公网 IPv4，确认真实公网地址后运行 `PUBLIC_IP=你的公网IPv4 bash /root/deploy.sh`。主脚本为防止覆盖旧密钥和配置，不会直接重装已有的 sing-box / AI Mili；中断时先查日志、不要直接删除配置。

## 部署中断恢复（不用重装 VPS 或更换节点密钥）

如果首次部署完成了 sing-box 安装（\`systemctl is-active sing-box\` 为 \`active\`），但是 AI Mili 在严格住宅集成步骤报错，主脚本可能还没执行到保存 Karing 链接和安装 \`vp\` 菜单。**不要再次执行主部署脚本，也不要删除 \`/etc/sing-box/config.json\`。**

本仓库提供单独的断点续装脚本 \`resume_deploy.sh\`。它会验证本项目 443/8443 配置，修复 AI Mili 严格住宅集成，从既有 REALITY 私钥**推导已有公钥**来恢复节点链接，并补装 \`vp\`；不会重新生成 UUID / REALITY 私钥，不会覆盖已有 \`/root/karing-nodes.txt\`。

在 Debian / Ubuntu 等 systemd 系统发生 AI Mili 无限重启时，先执行：

\`\`\`bash
systemctl stop aimilivpn
\`\`\`

然后下载并运行：

\`\`\`bash
curl -fL --retry 3 -o /root/resume_deploy.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/resume_deploy.sh
\`\`\`

\`\`\`bash
bash -n /root/resume_deploy.sh && bash /root/resume_deploy.sh
\`\`\`

脚本**只适用于本仓库生成的配置**（入站标签 \`normal-443\` / \`strict-8443\`）；已有其他项目的 sing-box 配置会被拒绝。即使续装成功，AI Mili 是否连接到真实可用的 VPNGate 住宅出口仍需单独验证。

### Debian 13 最小化系统的 AI Mili 字符编码报错

如果日志出现 \`UnicodeEncodeError: 'latin-1' codec can't encode characters\`，原因是原版 AI Mili 将中文日志输出到 Latin-1 的 systemd 标准输出。仓库中的 AI Mili 修改版已经加入 UTF-8 输出和回退处理；严格住宅安装器还会设置 \`PYTHONIOENCODING=utf-8:backslashreplace\`。不用为此升级 Python 或重装 Debian。详见 \`tests/test_aimili_encoding.py\`。

## 首次安装完成后：逐项验收（不是安装命令）

只有第 4 步安装结束、没有出现 `[ERROR]` / `FATAL` 后，才执行以下命令。保持一条一条运行，避免终端复制时把不同命令拼在一起。

**检查两项服务是否运行：** Debian、Ubuntu、Fedora、RPM 系使用：

```bash
systemctl is-active sing-box aimilivpn
```

Alpine Linux（OpenRC）使用：

```bash
rc-service sing-box status && rc-service aimilivpn status
```

**检查 sing-box 配置：**

```bash
/usr/local/bin/sing-box check -c /etc/sing-box/config.json
```

**确认节点文件存在（其中包含私人节点连接凭据，不要公开）：**

```bash
ls -l /root/karing-nodes.txt
```

**查看 AI Mili 状态（不要公开面板账号或安全路径）：**

```bash
ml status
```

**确认本地住宅 SOCKS5 实际出口：**

```bash
curl -4 --max-time 20 --proxy socks5h://127.0.0.1:7928 https://api.ipify.org
```

如果此时 `sing-box` / `ml` 提示未找到，或者两个服务都未运行，优先确认是否真的执行过 `bash /root/deploy.sh` 以及它中途是否报错；仅仅安装 `curl` 不会安装代理。住宅 SOCKS5 检测失败并不一定代表 sing-box 安装失败，可能是尚无合格的 AI Mili VPNGate 出口。


AI Mili 管理面板默认公网监听。在浏览器打开 `http://你的VPS公网IP:8787/随机安全路径/`，随机路径和账号由 VPS 的 `ml status` 给出。如无法打开，请检查云厂商的防火墙/安全组是否允许 TCP 8787。**HTTP 明文访问可能泄露登录凭据；建议为公网访问配置 HTTPS 反向代理。**根据需要在 AI Mili 面板选择 VPNGate 节点，并核验 SOCKS5 的实际出口 IP。

## 注意事项

- VPNGate 是第三方志愿者出口，公网 IP 可能变化。**这不是固定住宅 IP、Claude 账号风控免疫、或绝对 DNS 不泄漏的保证。**
- AI Mili 当前 SOCKS5 只实现 TCP CONNECT；不支持 UDP ASSOCIATE。严格入口拒绝 UDP，可能影响 QUIC/HTTP3。
- 只有真正经过 VPS、且被服务端识别的域名才能匹配域名规则。Karing 端仍需要 TUN、DNS 接管和适当的路由规则。本地直连或应用自带 DoH 不由服务端保证。
- 上游 AI Mili 来自其官方 `main` 分支，随时间变化；生产环境宜固定版本并审查代码。
- 脚本不会自动调整云服务商防火墙；在已启用 UFW 或 firewalld 时尝试放行 443/8443/8787 TCP。Alpine、自定义 nftables 规则需单独检查。
- 不要提交 `/etc/sing-box/config.json`、`/root/karing-nodes.txt` 或 AI Mili 的账号、凭据文件到公开仓库。

## 上游项目

[sing-box](https://github.com/SagerNet/sing-box) · [AI Mili VPNGate](https://github.com/baoweise-bot/aimili-vpngate)

## 常驻 VPS 管理面板（vp）

这个项目新增了**终端交互管理面板**，支持 systemd 与 OpenRC。安装一次以后，重启系统或重新登录 SSH 也可以随时输入 `vp` 召唤；它不是需要开放公网端口的独立 Web 站点。AI Mili 的 8787 Web 管理后台仍保持原有配置。

已经安装过本项目的 VPS，**不要再次运行 `deploy_vps_claude.sh`**，而是单独安装常驻菜单（以下每条都是完整的单行命令）：

```bash
curl -fL --retry 3 -o /root/install_manager.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_manager.sh
bash -n /root/install_manager.sh
bash /root/install_manager.sh
vp
```

以后新装 VPS，主部署脚本完成后会自动尝试安装 `vp`。先完成上述「首次一键安装」，不要在全新系统上只运行这里的管理菜单安装器。

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
- **443 不对 Claude 做特殊住宅分流**；443 使用 VPS 直连出站，**8443 是独立、由用户主动选择的住宅入口**。VPNGate 本身不会因为 VPS 切换 IPv6 就获得 IPv6 住宅出口。
- 选择 IPv6-only 前会检查 VPS 的全局 IPv6 地址、默认 IPv6 路由以及公网可达性，支持多地址时手动选定出站源 IPv6。没有 IPv6 的 VPS 会拒绝切换。
- IPv6-only 模式对普通 443 流量启用 IPv6 DNS 解析、拒绝解析后的 IPv4 地址；因此仅有 IPv4 的目标网站可能无法访问，而不是退回 VPS IPv4。
- 切换前自动保留 `/etc/sing-box/vp-backups/` 备份，先运行 `sing-box check`，再重启 sing-box，服务启动失败会尝试自动回滚。切换可能短暂中断节点连接，不会主动改变 SSH 和系统默认路由。
- 此功能不能代替 Karing TUN 和 DNS 接管；是否真正使用 IPv6 出口应在 Karing 节点连接后做端到端测试。只看 VPS 上 `curl -6` 的检测结果不足以证明代理客户端使用了 IPv6。

### AI Mili 改进版：严格住宅 IP 自动选择

> 2026-11-03：本仓库提供 [AI Mili VPNGate](https://github.com/OpenMili/aimili-vpngate) 2.1.5 的修改版 `aimili/vpngate_manager.py`，并将其整合进新的 VPS 一键部署流程。原始项目依照 GPL-3.0 授权；本仓库的修改说明见 `aimili/UPSTREAM.md`。

这是**真正的服务端节点选择策略**，与两个 VLESS 入口不是同一回事：

- 443 和 8443 是两个**独立的入站端口**；不能根据访问的网站偷偷改变入口或自动走住宅 IP。
- 443 普通入口的所有流量（包括 Claude）通过 `vps-direct`，默认 DNS 使用 `local-dns`，**不会因 Claude 域名自动发送到 `aimili-residential`**。
- 8443 独立入口继续要求 TCP 全部交由 AI Mili，UDP 拒绝。
- 新增 AI Mili 网页面板选项 **「严格住宅 IP」**：自动候选和手工连接均只接受 `ip_type=residential` 且 `ip_type_confidence=medium/high`；明确排除 `unknown` / `hosting` / `mobile` / 低置信度。
- 完成 OpenVPN 连接后会重新检测**实际 SOCKS5 出口 IP**；健康检查也复核出口。无法证明为住宅时拒绝该连接、尝试符合条件的其他节点；没有候选则保持出口不可用，不自动降级到机房或未知。
- 有效 IP 分类来自项目现有的 ip-api / ipapi.is 数据和启发式规则；「中/高置信度」**不等于独立证实住宅身份**。分类有误差，VPNGate 节点出口也可能发生变化，不能保证 Claude 账号不触发风控。

**现有已安装 VPS，无须重装、不用重新生成 REALITY 密钥：**

```bash
curl -fL --retry 3 -o /root/install_aimili_strict.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_aimili_strict.sh
bash -n /root/install_aimili_strict.sh
bash /root/install_aimili_strict.sh
```

安装器会保留原面板地址、端口、账号及密码，在 `/var/backups/vp-aimili/` 备份原始管理器源码与 UI 配置，并启用自动选择的严格住宅模式。首次启动可能需要完成 IP 分类后才有可用节点。

已经安装 `vp` 管理工具的用户，更新菜单后可通过 **菜单 9** 或运行 `vp residential-strict` 重新安装此功能；原有 `ml` 菜单与 8787 Web 面板依旧保留。Web 面板里也可以手动切换筛选模式。

```bash
curl -fL --retry 3 -o /root/install_manager.sh https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main/install_manager.sh
bash /root/install_manager.sh
vp
```

**更新保护：**本项目会安装一个启动前检查（systemd 或 OpenRC）：当 AI Mili 仍为经过适配的 2.1.5 版本时，即使 `ml update` 覆盖了管理器源码，下次重启也会自动恢复严格住宅修改版。如果上游更新为其他版本，启动前检查会**拒绝启动 AI Mili**，避免静默失去严格住宅筛选。OpenRC 的原版 `ml update` 可能覆盖服务启动钩子，Alpine 更新上游后应重新运行严格住宅安装器。此时需先适配新版本，不能强行关闭检查来继续使用。此保护仅作用于 Aimili 服务，不会改动 sing-box 或 SSH。

### BBRv3 项目集成

仅在 Debian / Ubuntu 系统上，菜单选择 BBRv3 后才会下载并启动 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 的交互式安装脚本。出于安全性和可重现性，上游脚本固定至提交 `4f9bd79bd66b6115f717665403e6d29839551604`；不复制其内核包，也不会在安装 `vp`、切换 IPv6 时自动装内核或重启。

⚠️ BBRv3 是内核级变更，可能影响 VPS 驱动、引导和网络；必须确认能通过云厂商控制台/救援模式恢复后再自行在上游菜单选择安装。**BBRv3 安装与 IPv6 出口切换是完全独立的两个功能。**
