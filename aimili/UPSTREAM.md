# AI Mili VPNGate 修改版说明

本目录包含基于 [OpenMili/aimili-vpngate](https://github.com/OpenMili/aimili-vpngate) 修改的 `vpngate_manager.py`。

- 原始上游提交：`2cd7dc58cebd1be5a99a0d2d83c701645207596f`（2026-10-14）
- 上游原版版本：2.1.5
- 上游版权与许可：[GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html)
- 原始代码及作者信息以[上游仓库](https://github.com/OpenMili/aimili-vpngate)为准。

## 相对于原版的改动

- 新增 `residential_strict` 路由类型，网页端提供可选按钮。
- 节点候选筛选、手工连接验证、自动故障切换均要求 `ip_type == residential` 且置信度是 `medium` 或 `high`。
- 新连接 OpenVPN 后，通过已有的 SOCKS5 出口检测获取真实出口 IP，再调用上游 IP 类型分类检查；无法确认则连接失败。
- 现有连接改变公网出口时，后台健康检查重复验证，在失败时按原有故障处理机制尝试切换。
- 新拉取节点时优先完成 IP 类型数据补齐，以免未知候选被误当成合格目标。
- 修复刷新时 IP 类型置信度等元数据丢失的问题。

## 限制

- 本仓库不改变 VPNGate 节点的真实运营商或公网 IP；IP 分类来自上游所用第三方情报源及启发式判定，存在误判可能。
- 由于先筛选 VPNGate **入口服务器 IP**，再确认**代理出口 IP**，可能漏掉实际为住宅出口但入口不符的候选，这是严格模式为了减少误选做出的保守取舍。
- 严格模式找不到候选时会保持不可用，不回退到机房、移动或未知类型。
- 此修改需要与上游 2.1.5 版的其他模块配套。更新上游源码前需重新测试兼容性。
- 部署安装器仅覆盖 `/opt/aimilivpn/vpngate_manager.py` 和路由类型设置；不会把节点密钥、登录账号、节点列表写到此仓库。

本目录里的改版程序按 GPL-3.0 的条件使用与再分发；不暗示获得上游作者支持或背书。
