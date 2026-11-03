#!/usr/bin/env python3
"""Remove only legacy server-side Claude -> Aimili rules from a main-branch deployment.

Default mode is read-only. --apply backs up, validates and reloads; no reinstall.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

CFG = Path("/etc/sing-box/config.json")
CLAUDE_DOMAINS = frozenset(("anthropic.com", "claude.ai", "claude.com"))


def _legacy_domains(rule: dict) -> bool:
    suffix = rule.get("domain_suffix")
    return isinstance(suffix, list) and set(suffix) == CLAUDE_DOMAINS and len(suffix) == 3


def legacy_dns_rule(rule: dict) -> bool:
    return (
        _legacy_domains(rule)
        and set(rule) == {"domain_suffix", "action", "server"}
        and rule["action"] == "route"
        and rule["server"] == "residential-doh"
    )


def legacy_route_rule(rule: dict) -> bool:
    if not _legacy_domains(rule):
        return False
    return (
        set(rule) == {"domain_suffix", "action", "outbound"}
        and rule["action"] == "route"
        and rule["outbound"] == "aimili-residential"
    ) or (
        set(rule) == {"domain_suffix", "network", "action"}
        and rule["network"] == "udp"
        and rule["action"] == "reject"
    )


def validated_main_config(config: dict) -> None:
    inbound_tags = {item.get("tag") for item in config.get("inbounds", [])}
    outbound = {item.get("tag"): item.get("type") for item in config.get("outbounds", [])}
    if not {"normal-443", "strict-8443"} <= inbound_tags:
        raise RuntimeError("Not a main-branch 443/8443 deployment; refusing to modify.")
    if outbound.get("vps-direct") != "direct" or outbound.get("aimili-residential") != "socks":
        raise RuntimeError("Unrecognized outbound configuration; refusing to modify.")
    if config.get("route", {}).get("final") != "vps-direct":
        raise RuntimeError("Unexpected default route; refusing to modify.")


def strip_legacy_claude_rules(config: dict) -> tuple[dict, int, int]:
    """Pure function; does not remove any 8443 inbound rules or other custom rules."""
    validated_main_config(config)
    updated = copy.deepcopy(config)
    dns_rules = updated.get("dns", {}).get("rules", [])
    route_rules = updated.get("route", {}).get("rules", [])
    if not isinstance(dns_rules, list) or not isinstance(route_rules, list):
        raise RuntimeError("Unexpected DNS/route rule format.")
    updated.setdefault("dns", {})["rules"] = [r for r in dns_rules if not legacy_dns_rule(r)]
    updated.setdefault("route", {})["rules"] = [r for r in route_rules if not legacy_route_rule(r)]
    dns_removed = len(dns_rules) - len(updated["dns"]["rules"])
    route_removed = len(route_rules) - len(updated["route"]["rules"])

    # Refuse to claim success if there are more Claude -> residential customizations.
    for section, rules in (("DNS", updated["dns"]["rules"]), ("route", updated["route"]["rules"])):
        for rule in rules:
            suffix = rule.get("domain_suffix", [])
            if isinstance(suffix, str):
                suffix = [suffix]
            if not isinstance(suffix, list):
                continue
            if not CLAUDE_DOMAINS.intersection(suffix):
                continue
            if section == "DNS" and rule.get("server") == "residential-doh":
                raise RuntimeError("Other Claude-specific residential DNS rules found; manual review needed.")
            if section == "route" and rule.get("outbound") == "aimili-residential":
                raise RuntimeError("Other Claude-specific residential route rules found; manual review needed.")
    return updated, dns_removed, route_removed


def run(args: list[str], check: bool = True, timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run(args, text=True, capture_output=True, check=check, timeout=timeout)


def service_commands() -> tuple[list[str], list[str]]:
    if Path("/run/systemd/system").is_dir() and shutil.which("systemctl"):
        return (["systemctl", "restart", "sing-box"], ["systemctl", "is-active", "--quiet", "sing-box"])
    if shutil.which("rc-service"):
        return (["rc-service", "sing-box", "restart"], ["rc-service", "sing-box", "status"])
    raise RuntimeError("No supported service manager found.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Remove legacy Claude-specific Aimili routing safely")
    parser.add_argument("--apply", action="store_true", help="Back up, validate and apply configuration change")
    options = parser.parse_args()
    if not CFG.is_file():
        raise RuntimeError("sing-box config not found")
    cfg = json.loads(CFG.read_text(encoding="utf-8"))
    updated, dns_removed, route_removed = strip_legacy_claude_rules(cfg)
    print(f"Found {dns_removed} legacy Claude DNS rule(s), {route_removed} traffic rule(s).")
    print("443 will use VPS-direct for Claude and all other domains.")
    print("8443 keeps its separate opt-in residential outbound; service keys are unchanged.")
    if not dns_removed and not route_removed:
        print("Nothing to change; recognized forced-route rules are already absent.")
        return
    if not options.apply:
        print("Read-only check complete. Pass --apply to back up, validate and change the configuration.")
        return
    if os.geteuid() != 0:
        raise RuntimeError("Use root to apply changes.")

    restart, is_active = service_commands()
    if run(is_active, check=False).returncode:
        raise RuntimeError("sing-box is not active; inspect service status before applying.")
    binary = Path("/usr/local/bin/sing-box")
    if not binary.is_file():
        raise RuntimeError("/usr/local/bin/sing-box not found.")
    backup_dir = CFG.parent / "vp-backups"
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = backup_dir / f"remove-claude-forcing-{stamp}.json"
    if backup.exists():
        raise RuntimeError("Backup path collision; retry in a moment.")
    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=CFG.parent,
            prefix=".vp-claude-route-", suffix=".json", delete=False
        ) as handle:
            tmp_path = Path(handle.name)
            json.dump(updated, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.chmod(tmp_path, 0o600)
        result = run([str(binary), "check", "-c", str(tmp_path)], check=False)
        if result.returncode:
            raise RuntimeError("sing-box check failed; no changes applied: " + result.stderr[-1000:])
        shutil.copy2(CFG, backup)
        os.chmod(backup, 0o600)
        os.replace(tmp_path, CFG)
        tmp_path = None
        try:
            run(restart)
            time.sleep(2)
            if run(is_active, check=False).returncode:
                raise RuntimeError("Service is not active after restart.")
        except Exception as exc:
            shutil.copy2(backup, CFG)
            run(restart, check=False)
            raise RuntimeError("Changes rolled back; sing-box restart failed: " + str(exc)) from exc
    finally:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
    print("OK: Claude-specific forced DNS/TCP/UDP rules removed.")
    print("Backup saved at " + str(backup))
    print("Karing rules may still separately choose a residential chain; check client policies too.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        sys.exit(1)
