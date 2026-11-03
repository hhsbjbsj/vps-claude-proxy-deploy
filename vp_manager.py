#!/usr/bin/env python3
"""VP direct-only VPS management: sing-box v1.14, IPv4/IPv6, opt-in BBRv3."""
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
URL = 'https://raw.githubusercontent.com/hhsbjbsj/vps-claude-proxy-deploy/no-aimili'
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
    if 'normal-443' not in ins or 'backup-8443' not in ins:
        raise RuntimeError('不是 no-aimili 分支的 443/8443 配置；拒绝修改其他项目的节点。')
    if outs.get('vps-direct', {}).get('type') != 'direct' or outs.get('backup-direct', {}).get('type') != 'direct':
        raise RuntimeError('需要两个独立 VPS 直连出站；拒绝修改未识别配置。')
    if not any(r.get('inbound') == ['backup-8443'] and r.get('action') == 'route'
               and r.get('outbound') == 'backup-direct'
               for r in cfg.get('route', {}).get('rules', [])):
        raise RuntimeError('缺少备用 8443 的独立路由；为保护备用节点，已停止。')
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
    # Preserve custom rules while updating only the primary 443 inlet.
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
        print('仅对 443 主节点应用出口切换；8443 备用节点保持默认直连策略。')
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
    for name in ('sing-box',):
        print(f'{name}: {service_status(name)}')
    print('IPv6 全局地址：' + (', '.join(ipv6_addresses()) or '无'))
    route6 = cmd(['ip', '-6', 'route', 'show', 'default'], timeout=5)
    print('IPv6 默认路由：' + (route6.stdout.strip() or '无'))
    for kind, args in (
        ('VPS IPv4 直连', ['curl','-4','-fsS','--max-time','7','https://api.ipify.org']),
        ('VPS IPv6 直连', ['curl','-6','-fsS','--max-time','7','https://api64.ipify.org']),
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
        print(' VP · VPS 直连版管理面板 (no-aimili)')
        print(' 443 主节点：' + mode + '   |   8443：备用 VPS 直连')
        print('='*50)
        print('1  运行状态、IPv4/IPv6 出口检查')
        print('2  443 主节点切换到 IPv4-only')
        print('3  443 主节点切换到 IPv6-only（可选源地址）')
        print('4  打开 BBRv3 安装菜单（需确认）')
        print('5  显示 Karing 节点链接（敏感凭据）')
        print('6  查看 sing-box 最近日志')
        print('7  更新 VP 直连版管理工具')
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
                    print('没有检测到有效公网 IPv6 或默认路由。')
                    continue
                for i, address in enumerate(addrs, 1):
                    print(f'{i}. {address}')
                selected = input('请选择源 IPv6 地址编号：').strip()
                if not selected.isdigit() or not 1 <= int(selected) <= len(addrs):
                    print('选择无效。')
                    continue
                switch('ipv6', addrs[int(selected)-1])
            elif choice == '4':
                bbr_menu()
            elif choice == '5':
                p = Path('/root/karing-nodes.txt')
                print(p.read_text() if p.is_file() else '没有找到节点链接。')
                print('不要公开这些含 UUID 和 REALITY 公钥参数的节点链接。')
            elif choice == '6':
                if has_systemd():
                    subprocess.run(['journalctl','-u','sing-box','-n','50','--no-pager'],check=False)
                else:
                    p = Path('/var/log/sing-box.err.log')
                    if not p.is_file():
                        p = Path('/var/log/sing-box.log')
                    subprocess.run(['tail','-n','50',str(p)],check=False)
            elif choice == '7':
                update_manager()
            else:
                print('请选择有效菜单编号。')
        except (OSError, RuntimeError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError) as exc:
            print('操作失败：' + str(exc))
        except KeyboardInterrupt:
            print('\n操作已取消。')

def main() -> None:
    parser = argparse.ArgumentParser(description='VP VPS proxy terminal manager')
    sub = parser.add_subparsers(dest='command')
    sub.add_parser('status')
    out = sub.add_parser('egress')
    out.add_argument('mode',choices=['ipv4','ipv6'])
    out.add_argument('--source-ipv6',default=None)
    sub.add_parser('bbr')
    sub.add_parser('update')
    args = parser.parse_args()
    try:
        if args.command == 'status': run_status()
        elif args.command == 'egress': switch(args.mode,args.source_ipv6)
        elif args.command == 'bbr': bbr_menu()
        elif args.command == 'update': update_manager()
        else: menu()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError, ValueError) as e:
        print('错误：'+str(e),file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()