"""Offline tests for the direct-only branch's independent inbounds/outbounds."""
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
        'inbounds': [{'tag': 'normal-443'}, {'tag': 'backup-8443'}],
        'outbounds': [
            {'type': 'direct', 'tag': 'vps-direct'},
            {'type': 'direct', 'tag': 'backup-direct'},
        ],
        'dns': {'servers': [{'tag': 'local-dns', 'type': 'local'}]},
        'route': {
            'final': 'vps-direct',
            'rules': [{'inbound': ['backup-8443'], 'action': 'route', 'outbound': 'backup-direct'}],
        },
    }


def fake_cmd(argv, **kwargs):
    if argv[0] == 'ip':
        return subprocess.CompletedProcess(argv, 0, 'default via 2001:db8::1\n', '')
    return subprocess.CompletedProcess(argv, 0, 'active\n', '')


def test_switch_ipv6_and_back():
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        cfg_path = folder / 'config.json'
        cfg_path.write_text(json.dumps(base()))
        with patch.object(vp, 'CFG', cfg_path), patch.object(vp, 'BASE', folder), \
             patch.object(vp, 'cmd', fake_cmd), patch.object(vp, 'require_root', lambda: None), \
             patch.object(vp, 'ipv6_ready', lambda address: None), \
             patch.object(vp.time, 'sleep', lambda seconds: None):
            vp.switch('ipv6', '2001:4860::abcd')
            saved = json.loads(cfg_path.read_text())
            assert saved['outbounds'][0]['inet6_bind_address'] == '2001:4860::abcd'
            assert saved['outbounds'][1] == {'type': 'direct', 'tag': 'backup-direct'}
            assert saved['route']['rules'][0] == base()['route']['rules'][0]
            assert saved['route']['rules'][-2]['strategy'] == 'ipv6_only'
            assert saved['route']['rules'][-1]['ip_version'] == 4
            assert len(saved['route']['rules']) == 3

            vp.switch('ipv4')
            saved = json.loads(cfg_path.read_text())
            assert 'inet6_bind_address' not in saved['outbounds'][0]
            assert saved['outbounds'][1] == {'type': 'direct', 'tag': 'backup-direct'}
            assert saved['route']['rules'][0] == base()['route']['rules'][0]
            assert saved['route']['rules'][-2]['strategy'] == 'ipv4_only'
            assert saved['route']['rules'][-1]['ip_version'] == 6
            assert len(saved['route']['rules']) == 3


if __name__ == '__main__':
    test_switch_ipv6_and_back()
    print('PASS: 443 IPv4/IPv6 switch leaves independent 8443 backup direct egress intact')
