"""Regression: Claude must not be silently forced onto residential from 443."""
import copy
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("remove_claude_forced_routes", root / "remove_claude_forced_routes.py")
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

domains = ["anthropic.com", "claude.ai", "claude.com"]
config = {
    "inbounds": [
        {"type": "vless", "tag": "normal-443", "listen_port": 443},
        {"type": "vless", "tag": "strict-8443", "listen_port": 8443},
    ],
    "outbounds": [
        {"type": "direct", "tag": "vps-direct"},
        {"type": "socks", "tag": "aimili-residential", "server": "127.0.0.1", "server_port": 7928},
    ],
    "dns": {
        "servers": [
            {"type": "local", "tag": "local-dns"},
            {"type": "https", "tag": "residential-doh", "detour": "aimili-residential"},
        ],
        "rules": [
            {"inbound": ["strict-8443"], "action": "route", "server": "residential-doh"},
            {"domain_suffix": domains, "action": "route", "server": "residential-doh"},
        ],
        "final": "local-dns",
    },
    "route": {
        "rules": [
            {"action": "sniff", "timeout": "300ms"},
            {"inbound": ["strict-8443"], "network": "udp", "action": "reject"},
            {"inbound": ["strict-8443"], "action": "route", "outbound": "aimili-residential"},
            {"domain_suffix": domains, "network": "udp", "action": "reject"},
            {"domain_suffix": domains, "action": "route", "outbound": "aimili-residential"},
            {"domain_suffix": ["example.com"], "action": "route", "outbound": "vps-direct"},
        ],
        "final": "vps-direct",
    },
}
original = copy.deepcopy(config)
updated, dns_removed, traffic_removed = repair.strip_legacy_claude_rules(config)
assert dns_removed == 1
assert traffic_removed == 2
assert config == original, "pure helper must not modify original dict or credentials"
assert len(updated["dns"]["rules"]) == 1
assert updated["dns"]["rules"][0]["inbound"] == ["strict-8443"]
assert len(updated["route"]["rules"]) == 4
assert updated["route"]["rules"][1]["network"] == "udp"
assert updated["route"]["rules"][2]["outbound"] == "aimili-residential"
assert updated["route"]["rules"][3]["domain_suffix"] == ["example.com"]
updated2, dns_removed2, traffic_removed2 = repair.strip_legacy_claude_rules(updated)
assert updated2 == updated and dns_removed2 == traffic_removed2 == 0

# Do not silently delete an unrecognized custom residential rule.
bad = copy.deepcopy(config)
bad["route"]["rules"].append({
    "domain_suffix": ["claude.ai"], "action": "route", "outbound": "aimili-residential"
})
try:
    repair.strip_legacy_claude_rules(bad)
    raise AssertionError("Must fail closed on unknown Claude-specific routing")
except RuntimeError:
    pass

# Main's freshly generated configuration must no longer contain Claude-special-case paths.
deployer = (root / "deploy_vps_claude.sh").read_text(encoding="utf-8")
block = deployer.split('info "Writing sing-box config"', 1)[1].split(
    'sing-box check -c /etc/sing-box/config.json', 1
)[0]
assert "claude_domains" not in block
assert '"domain_suffix"' not in block
assert '"server": "residential-doh"' in block
assert '"inbound": ["strict-8443"]' in block
assert '"outbound": "aimili-residential"' in block

print("PASS: 443 Claude uses VPS-direct; opt-in 8443 remains residential; repair is idempotent")
