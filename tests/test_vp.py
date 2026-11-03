"""Offline tests for VP's non-destructive sing-box route switching."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('vp', Path(__file__).resolve().parent.parent / 'vp_manager.py')
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)


def base():
    return {
        'inbounds': [{'tag': 'normal-443'}, {'tag': 'strict-8443'}],
        'outbounds': [
            {'type': 'direct', 'tag': 'vps-direct'},
            {'type': 'socks', 'tag': 'aimili-residential', 'server': '127.0.0.1', 'server_port': 7928}
        ],
        'dns': {'servers': [{'tag': 'local-dns'}]},
        'route': {'final': 'vps-direct', 'rules': [
            {'action': 'sniff', 'timeout': '300ms'},
            {'inbound': ['strict-8443'], 'network': 'udp', 'action': 'reject'},
            {'inbound': ['strict-8443'], 'action': 'route', 'outbound': 'aimili-residential'},
            {'domain_suffix': ['anthropic.com', 'claude.ai'], 'action': 'route', 'outbound': 'aimili-residential'}
        ]}
    }


def fake_cmd(argv, **kwargs):
    if argv[0] == 'ip':
        return subprocess.CompletedProcess(argv, 0, 'default via 2001:db8::1\n', '')
    return subprocess.CompletedProcess(argv, 0, 'active\n', '')


def test_switch_ipv6_and_back():
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        config = folder / 'config.json'
        config.write_text(json.dumps(base()))
        with patch.object(vp, 'CFG', config), patch.object(vp, 'BASE', folder), \
             patch.object(vp, 'cmd', fake_cmd), patch.object(vp, 'require_root', lambda: None), \
             patch.object(vp, 'ipv6_ready', lambda address: None), \
             patch.object(vp.time, 'sleep', lambda seconds: None):
            vp.switch('ipv6', '2001:4860::abcd')
            saved = json.loads(config.read_text())
            assert saved['outbounds'][0]['inet6_bind_address'] == '2001:4860::abcd'
            assert saved['route']['rules'][2]['outbound'] == 'aimili-residential'
            assert saved['route']['rules'][3]['outbound'] == 'aimili-residential'
            assert saved['route']['rules'][-2]['strategy'] == 'ipv6_only'
            assert saved['route']['rules'][-1]['ip_version'] == 4
            vp.switch('ipv4')
            saved = json.loads(config.read_text())
            assert 'inet6_bind_address' not in saved['outbounds'][0]
            assert saved['route']['rules'][-2]['strategy'] == 'ipv4_only'
            assert saved['route']['rules'][-1]['ip_version'] == 6
            assert len(saved['route']['rules']) == 6


if __name__ == '__main__':
    test_switch_ipv6_and_back()
    print('PASS: IPv6/IPv4 egress switching preserves residential rules')
