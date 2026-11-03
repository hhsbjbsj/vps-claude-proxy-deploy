#!/usr/bin/env python3
"""VPS proxy management (terminal): sing-box v1.14, Aimili, and opt-in BBRv3."""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def configure_utf8_stdio() -> None:
    """Minimal VPS installations sometimes advertise Latin-1 for console IO.
    Do not let printing a Chinese menu crash VP. This is process-local only.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='backslashreplace')
        except (AttributeError, OSError, ValueError):
            pass


configure_utf8_stdio()

CFG = Path('/etc/sing-box/config.json')
BASE = Path('/etc/sing-box')
URL = 'https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/main'
BBR_REF = '4f9bd79bd66b6115f717665403e6d29839551604'
BBR_URL = f'https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/{BBR_REF}/install.sh'
MANAGED_INBOUND = ['normal-443']


def require_root() -> None:
    if os.geteuid() != 0:
        raise RuntimeError('请使用 sudo vp 或 root 用户运行。')


def cmd(argv: list[str], timeout: int = 30, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=check)


def has_systemd() -> bool:
    return Path('/run/systemd/system').is_dir() and shutil.which('systemctl') is not None


def service_restart(name: str) -> subprocess.CompletedProcess:
    if has_systemd():
        return cmd(['systemctl', 'restart', name], timeout=30)
    if shutil.which('rc-service'):
        return cmd(['rc-service', name, 'restart'], timeout=30)
    raise RuntimeError('既不是 systemd 也不是 OpenRC，无法管理服务。')


def service_is_active(name: str) -> bool:
    if has_systemd():
        return cmd(['systemctl', 'is-active', '--quiet', name], timeout=5).returncode == 0
    if shutil.which('rc-service'):
        return cmd(['rc-service', name, 'status'], timeout=5).returncode == 0
    return False


def service_status(name: str) -> str:
    if has_systemd():
        c = cmd(['systemctl', 'is-active', name], timeout=5)
        return c.stdout.strip() or 'inactive'
    if shutil.which('rc-service'):
        return 'active' if service_is_active(name) else 'inactive'
    return 'unknown'


def load() -> dict:
    if not CFG.is_file():
        raise RuntimeError('未发现 sing-box 配置；请先完成主部署。')
    cfg = json.loads(CFG.read_text())
    ins = {x.get('tag'): x for x in cfg.get('inbounds', [])}
    outs = {x.get('tag'): x for x in cfg.get('outbounds', [])}
    if 'normal-443' not in ins or 'strict-8443' not in ins:
        raise RuntimeError('不是本项目预期的 443/8443 配置；为避免误改，已停止。')
    if outs.get('vps-direct', {}).get('type') != 'direct':
        raise RuntimeError('缺少本项目的 vps-direct 出站；已停止。')
    if cfg.get('route', {}).get('final') != 'vps-direct':
        raise RuntimeError('默认出站已自定义，不能自动切换 IPv4/IPv6。')
    return cfg


def is_managed_rule(rule: dict) -> bool:
    if rule.get('inbound') != MANAGED_INBOUND:
        return False
    if set(rule) == {'inbound', 'action', 'server', 'strategy'}:
        return (rule['action'] == 'resolve' and rule['server'] == 'local-dns'
                and rule['strategy'] in ('ipv4_only', 'ipv6_only'))
    if set(rule) == {'inbound', 'ip_version', 'action'}:
        return rule['action'] == 'reject' and rule['ip_version'] in (4, 6)
    return False


def current_mode(cfg: dict) -> str:
    for rule in cfg.get('route', {}).get('rules', []):
        if is_managed_rule(rule) and rule.get('action') == 'resolve':
            return 'IPv6-only' if rule['strategy'] == 'ipv6_only' else 'IPv4-only'
    return '未固定（原始配置）'


def ipv6_addresses() -> list[str]:
    result = cmd(['ip', '-j', '-6', 'addr', 'show', 'scope', 'global'], timeout=5)
    if result.returncode != 0:
        return []
    addresses = []
    for iface in json.loads(result.stdout):
        for info in iface.get('addr_info', []):
            raw = info.get('local', '')
            try:
                ip = ipaddress.IPv6Address(raw)
            except ValueError:
                continue
            flags = set(info.get('flags') or [])
            if not ip.is_global or flags.intersection({'temporary', 'tentative', 'dadfailed', 'deprecated'}):
                continue
            if raw not in addresses:
                addresses.append(raw)
    return addresses


def ipv6_ready(address: str) -> None:
    choices = ipv6_addresses()
    if address not in choices:
        raise RuntimeError('所选 IPv6 不是当前网卡的有效全局地址。可用地址：' + ', '.join(choices))
    if not cmd(['ip', '-6', 'route', 'show', 'default'], timeout=5).stdout.strip():
        raise RuntimeError('没有 IPv6 默认路由，拒绝切换。')
    result = cmd(['curl', '-6', '-fsS', '--interface', address,
                  '--connect-timeout', '5', '--max-time', '12',
                  'https://api64.ipify.org'], timeout=16)
    if result.returncode:
        raise RuntimeError('选定 IPv6 地址不能成功访问公网；未修改配置。' + result.stderr.strip()[-200:])
    try:
        outgoing = ipaddress.IPv6Address(result.stdout.strip())
    except ValueError as exc:
        raise RuntimeError('公网 IPv6 检查未返回合法 IPv6 地址。') from exc
    if not outgoing.is_global:
        raise RuntimeError('出站检测返回非全局 IPv6，拒绝切换。')


def switch(mode: str, address: str | None = None) -> None:
    require_root()
    if mode not in ('ipv4', 'ipv6'):
        raise RuntimeError('出口模式仅支持 ipv4 / ipv6。')
    cfg = load()
    if mode == 'ipv6':
        if not address:
            choices = ipv6_addresses()
            if len(choices) != 1:
                raise RuntimeError('请指定 IPv6 地址。当前可选：' + ', '.join(choices))
            address = choices[0]
        ipv6_ready(address)
    else:
        if not cmd(['ip', '-4', 'route', 'show', 'default'], timeout=5).stdout.strip():
            raise RuntimeError('没有 IPv4 默认路由，拒绝切换。')

    updated = copy.deepcopy(cfg)
    rules = updated['route'].setdefault('rules', [])
    # Preserve existing custom routes and the independent 8443 residential entry.
    rules[:] = [rule for rule in rules if not is_managed_rule(rule)]
    rules.append({'inbound': MANAGED_INBOUND, 'action': 'resolve',
                  'server': 'local-dns',
                  'strategy': 'ipv6_only' if mode == 'ipv6' else 'ipv4_only'})
    rules.append({'inbound': MANAGED_INBOUND, 'ip_version': 4 if mode == 'ipv6' else 6,
                  'action': 'reject'})
    direct = next(x for x in updated['outbounds'] if x['tag'] == 'vps-direct')
    direct.pop('inet4_bind_address', None)
    direct.pop('inet6_bind_address', None)
    if mode == 'ipv6':
        direct['inet6_bind_address'] = address

    BASE.mkdir(mode=0o700, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=BASE,
                                     prefix='.vp-new-', suffix='.json', delete=False) as handle:
        tmp = Path(handle.name)
        json.dump(updated, handle, indent=2, ensure_ascii=False)
        handle.write('\n')
    os.chmod(tmp, 0o600)
    try:
        check = cmd(['/usr/local/bin/sing-box', 'check', '-c', str(tmp)], timeout=20)
        if check.returncode:
            raise RuntimeError('sing-box check 未通过，配置保持不变：\n' + check.stderr[-1000:])
        backups = BASE / 'vp-backups'
        backups.mkdir(mode=0o700, exist_ok=True)
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        with tempfile.NamedTemporaryFile(dir=backups, prefix=stamp+'-', suffix='.json', delete=False) as h:
            backup = Path(h.name)
        shutil.copy2(CFG, backup)
        os.chmod(backup, 0o600)
        os.replace(tmp, CFG)
        restart = service_restart('sing-box')
        time.sleep(1)
        active = service_is_active('sing-box')
        if restart.returncode or not active:
            shutil.copy2(backup, CFG)
            service_restart('sing-box')
            raise RuntimeError('新配置启动失败，已尝试回滚原配置。日志：\n' + restart.stderr[-1000:])
        print(f'成功：443 普通节点直连流量使用 {mode.upper()} 出口。')
        if address:
            print('绑定源 IPv6 地址：' + address)
        print('443 主入口按出站策略直连，包括 Claude；8443 独立住宅入口保持不变。')
        print('配置备份：' + str(backup))
        print('注意：原有连接可能在 sing-box 重启时中断；只对新连接生效。')
    finally:
        tmp.unlink(missing_ok=True)


def run_status() -> None:
    require_root()
    print('\n== VPS 代理管理状态 ==')
    try:
        cfg = load()
        print('443 直接出口策略：' + current_mode(cfg))
        outbound = next(x for x in cfg['outbounds'] if x.get('tag') == 'vps-direct')
        if outbound.get('inet6_bind_address'):
            print('绑定 IPv6：' + outbound['inet6_bind_address'])
    except Exception as e:
        print('配置：' + str(e))
    for name in ('sing-box', 'aimilivpn'):
        print(f'{name}: {service_status(name)}')
    print('IPv6 全局地址：' + (', '.join(ipv6_addresses()) or '无'))
    route6 = cmd(['ip', '-6', 'route', 'show', 'default'], timeout=5)
    print('IPv6 默认路由：' + (route6.stdout.strip() or '无'))
    for kind, args in (
        ('VPS IPv4 直连', ['curl','-4','-fsS','--max-time','7','https://api.ipify.org']),
        ('VPS IPv6 直连', ['curl','-6','-fsS','--max-time','7','https://api64.ipify.org']),
        ('AI Mili SOCKS5 TCP', ['curl','-4','-fsS','--max-time','7','--proxy','socks5h://127.0.0.1:7928','https://api.ipify.org']),
    ):
        try:
            r = cmd(args, timeout=9)
            print(f'{kind}: {r.stdout.strip() if r.returncode == 0 else "不可用"}')
        except Exception as e:
            print(f'{kind}: 检测异常（{e}）')
    print('注意：以上 curl 是 VPS 本机检测，不能替代通过 Karing 节点的端到端出口验收。')


def bbr_menu() -> None:
    require_root()
    print('\n即将下载 byJoey/Actions-bbr-v3 官方脚本。')
    print('安装 BBR 内核可能影响系统引导、网络驱动，并需要重启。')
    print('此菜单不会自动安装内核或关闭 IPv6；后续操作由上游菜单决定。')
    distro = {}
    try:
        for line in Path('/etc/os-release').read_text().splitlines():
            if line.startswith('ID='):
                distro['id'] = line.partition('=')[2].strip('"')
    except OSError:
        pass
    if distro.get('id') not in ('debian', 'ubuntu'):
        raise RuntimeError('byJoey BBRv3 内核安装器目前只支持 Debian/Ubuntu；此发行版不允许从 VP 菜单直接运行。')
    print('上游固定提交：' + BBR_REF)
    if input('输入 BBR 继续下载并打开上游菜单（其他输入取消）：').strip() != 'BBR':
        return
    with tempfile.TemporaryDirectory(prefix='vp-bbr-') as directory:
        path = Path(directory) / 'install.sh'
        result = cmd(['curl','-fL','--retry','3','-o',str(path),BBR_URL],timeout=90)
        if result.returncode:
            raise RuntimeError('BBR 脚本下载失败：'+result.stderr[-300:])
        check = cmd(['bash','-n',str(path)],timeout=10)
        if check.returncode:
            raise RuntimeError('BBR 脚本 Bash 语法检查失败。')
        subprocess.run(['bash',str(path)],env={**os.environ,'BBRV3_SKIP_QUICK_COMMAND':'1'},check=False)


def install_strict_residential() -> None:
    require_root()
    print('\n这会替换 AimiliVPN 管理器代码，保留面板账号和 sing-box 节点。')
    print('仅选择识别为住宅、置信度中/高的 VPNGate 节点，并检查实际代理出口。')
    print('没有符合条件的节点时不回退到未知、移动或机房 IP。')
    if input('输入 STRICT 确认安装或修复此模式（其他输入取消）：').strip() != 'STRICT':
        return
    with tempfile.TemporaryDirectory(prefix='vp-aimili-strict-') as directory:
        script = Path(directory) / 'install_aimili_strict.sh'
        r = cmd(['curl', '-fL', '--retry', '3', '-o', str(script),
                 URL + '/install_aimili_strict.sh'], timeout=90)
        if r.returncode:
            raise RuntimeError('下载严格住宅安装器失败：' + r.stderr[-300:])
        v = cmd(['bash', '-n', str(script)], timeout=10)
        if v.returncode:
            raise RuntimeError('安装器语法检查失败：' + v.stderr[-300:])
        subprocess.run(['bash', str(script)], check=True)


def update_manager() -> None:
    require_root()
    print('更新管理菜单不会覆盖 sing-box 配置，也不会重新安装节点。')
    if input('输入 UPDATE 确认更新（其他取消）：').strip() != 'UPDATE':
        return
    with tempfile.TemporaryDirectory(prefix='vp-update-') as directory:
        path = Path(directory) / 'install_manager.sh'
        r = cmd(['curl','-fL','--retry','3','-o',str(path),URL+'/install_manager.sh'],timeout=90)
        if r.returncode:
            raise RuntimeError('更新下载失败：' + r.stderr[-300:])
        subprocess.run(['bash',str(path)],check=True)


def menu() -> None:
    require_root()
    while True:
        try:
            mode = current_mode(load())
        except Exception:
            mode = '配置不可识别'
        print('\n' + '='*50)
        print(' VP · Linux VPS 代理管理面板（终端版）')
        print(' 443 出站：' + mode + '   |   8443：严格住宅 TCP')
        print('='*50)
        print('1  运行状态、IPv4/IPv6 和住宅出口检查')
        print('2  将 443 普通出口切换为 IPv4-only')
        print('3  将 443 普通出口切换为 IPv6-only（可选择源地址）')
        print('4  打开 AI Mili 管理菜单（ml）')
        print('5  打开 BBRv3 官方菜单（手动确认）')
        print('6  显示 Karing 节点链接（敏感凭据）')
        print('7  查看 sing-box 最近日志')
        print('8  更新 VP 管理工具（不更改节点配置）')
        print('9  AI Mili 严格住宅 IP 自动选择（安装/修复）')
        print('0  退出')
        choice = input('请选择：').strip()
        try:
            if choice == '0':
                break
            elif choice == '1':
                run_status()
            elif choice == '2':
                switch('ipv4')
            elif choice == '3':
                addrs = ipv6_addresses()
                if not addrs:
                    print('未检测到可用的公网 IPv6，先检查服务商 IPv6 和默认路由。')
                    continue
                for i, addr in enumerate(addrs, 1):
                    print(f'{i}. {addr}')
                selected = input('选择要绑定的 IPv6 地址编号：').strip()
                if not selected.isdigit() or not 1 <= int(selected) <= len(addrs):
                    print('选择无效。'); continue
                switch('ipv6',addrs[int(selected)-1])
            elif choice == '4':
                subprocess.run(['ml'],check=False)
            elif choice == '5':
                bbr_menu()
            elif choice == '6':
                path=Path('/root/karing-nodes.txt')
                print(path.read_text() if path.exists() else '没有找到节点链接。')
                print('请勿公开分享这些含 UUID 和密钥参数的节点链接。')
            elif choice == '7':
                if has_systemd():
                    subprocess.run(['journalctl','-u','sing-box','-n','50','--no-pager'],check=False)
                else:
                    path = Path('/var/log/sing-box.err.log')
                    if not path.exists():
                        path = Path('/var/log/sing-box.log')
                    subprocess.run(['tail','-n','50',str(path)],check=False)
            elif choice == '8':
                update_manager()
            elif choice == '9':
                install_strict_residential()
            else:
                print('请选择有效菜单编号。')
        except (OSError, RuntimeError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError) as e:
            print('操作失败：' + str(e))
        except KeyboardInterrupt:
            print('\n本次操作已取消。')


def main() -> None:
    parser = argparse.ArgumentParser(description='VP VPS proxy terminal manager')
    sub = parser.add_subparsers(dest='command')
    sub.add_parser('status')
    out = sub.add_parser('egress')
    out.add_argument('mode',choices=['ipv4','ipv6'])
    out.add_argument('--source-ipv6',default=None)
    sub.add_parser('bbr')
    sub.add_parser('update')
    sub.add_parser('residential-strict')
    args = parser.parse_args()
    try:
        if args.command == 'status': run_status()
        elif args.command == 'egress': switch(args.mode,args.source_ipv6)
        elif args.command == 'bbr': bbr_menu()
        elif args.command == 'update': update_manager()
        elif args.command == 'residential-strict': install_strict_residential()
        else: menu()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError) as e:
        print('错误：'+str(e),file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()