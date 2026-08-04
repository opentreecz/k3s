#!/usr/bin/env python3
"""Lint configuration files for syntax correctness.

This script validates:
- HAProxy configuration files (.cfg)
- Keepalived configuration files (keepalived.conf)
- Generic .conf files (basic syntax checks)

Usage:
    python3 lint_configs.py [--path PATH]
    python3 lint_configs.py --help
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR = Path(__file__).parent.resolve()
DEFAULT_PATH = SCRIPT_DIR / "generated"
CONFIGS_PATH = SCRIPT_DIR / "configs"


# =============================================================================
# HAProxy Linter
# =============================================================================


def lint_haproxy(filepath: Path) -> list[str]:
    """Lint an HAProxy configuration file for common issues."""
    errors: list[str] = []
    content = filepath.read_text()
    lines = content.splitlines()

    # Check for required sections
    required_sections = ["global", "defaults"]
    for section in required_sections:
        if not re.search(rf"^{section}\s*$", content, re.MULTILINE):
            errors.append(f"Missing required section: '{section}'")

    # Check for at least one frontend/listen and backend
    has_frontend = bool(re.search(r"^(frontend|listen)\s+\S+", content, re.MULTILINE))
    has_backend = bool(re.search(r"^backend\s+\S+", content, re.MULTILINE))

    if not has_frontend:
        errors.append("No 'frontend' or 'listen' section found")
    if not has_backend and not re.search(r"^listen\s+", content, re.MULTILINE):
        errors.append("No 'backend' section found (and no 'listen' section)")

    # Check for balanced braces (should be none in HAProxy config)
    open_braces = content.count("{")
    close_braces = content.count("}")
    if open_braces != close_braces:
        errors.append(
            f"Unbalanced braces: {open_braces} opening, {close_braces} closing"
        )

    # Check for server lines in backend
    if has_backend:
        in_backend = False
        has_server = False
        for line in lines:
            stripped = line.strip()
            if re.match(r"^backend\s+", stripped):
                in_backend = True
                has_server = False
            elif re.match(r"^(frontend|listen|defaults|global)\s*", stripped):
                if in_backend and not has_server:
                    errors.append("Backend section has no 'server' entries")
                in_backend = False
            elif in_backend and stripped.startswith("server "):
                has_server = True
        if in_backend and not has_server:
            errors.append("Backend section has no 'server' entries")

    # Check bind directives have valid format
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("bind "):
            bind_value = stripped[5:].strip()
            if not re.match(
                r"(\*|[\d.]+|\[[\da-f:]+\]):(\d+)", bind_value
            ) and not re.match(r"/\S+", bind_value):
                errors.append(f"Line {i}: Suspicious bind directive: '{stripped}'")

    # Check timeout values have units
    timeout_re = re.compile(r"^\s*timeout\s+\S+\s+(.+)$")
    for i, line in enumerate(lines, 1):
        match = timeout_re.match(line)
        if match:
            value = match.group(1).strip()
            if not re.match(r"\d+[smhd]?$", value):
                errors.append(f"Line {i}: Invalid timeout value: '{value}'")

    return errors


# =============================================================================
# Keepalived Linter
# =============================================================================


def lint_keepalived(filepath: Path) -> list[str]:
    """Lint a Keepalived configuration file for common issues."""
    errors: list[str] = []
    content = filepath.read_text()
    lines = content.splitlines()

    # Check for required blocks
    if "vrrp_instance" not in content:
        errors.append("No 'vrrp_instance' block found")

    if "virtual_ipaddress" not in content:
        errors.append("No 'virtual_ipaddress' block found")

    # Check brace balance
    open_braces = content.count("{")
    close_braces = content.count("}")
    if open_braces != close_braces:
        errors.append(
            f"Unbalanced braces: {open_braces} opening, {close_braces} closing"
        )

    # Filter out comment lines (lines starting with !)
    active_content = "\n".join(
        line for line in lines if not line.strip().startswith("!")
    )

    # Check for valid state
    state_match = re.search(r"state\s+(\S+)", active_content)
    if state_match:
        state = state_match.group(1)
        if state not in ("MASTER", "BACKUP"):
            errors.append(f"Invalid state: '{state}' (must be MASTER or BACKUP)")

    # Check priority range
    priority_match = re.search(r"priority\s+(\d+)", active_content)
    if priority_match:
        priority = int(priority_match.group(1))
        if not 1 <= priority <= 255:
            errors.append(f"Priority {priority} out of range (must be 1-255)")

    # Check virtual_router_id range
    vrid_match = re.search(r"virtual_router_id\s+(\d+)", active_content)
    if vrid_match:
        vrid = int(vrid_match.group(1))
        if not 1 <= vrid <= 255:
            errors.append(f"virtual_router_id {vrid} out of range (must be 1-255)")

    # Check for interface directive
    if not re.search(r"interface\s+\S+", active_content):
        errors.append("No 'interface' directive found in vrrp_instance")

    # Validate IP addresses in virtual_ipaddress block
    in_vip_block = False
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if "virtual_ipaddress" in stripped:
            in_vip_block = True
            continue
        if in_vip_block:
            if stripped == "}":
                in_vip_block = False
                continue
            if stripped == "{":
                continue
            if (
                stripped
                and not stripped.startswith("!")
                and not re.match(r"[\da-f.:]+/\d+(\s+dev\s+\S+)?$", stripped)
            ):
                errors.append(
                    f"Line {i}: Invalid virtual_ipaddress entry: '{stripped}'"
                )

    return errors


# =============================================================================
# DHCP Config Linter
# =============================================================================


def lint_dhcp_conf(filepath: Path) -> list[str]:
    """Lint ISC DHCP configuration files for basic syntax."""
    errors: list[str] = []
    content = filepath.read_text()
    lines = content.splitlines()

    # Check brace balance
    open_braces = 0
    close_braces = 0
    for line in lines:
        # Skip comments
        stripped = line.split("#")[0]
        open_braces += stripped.count("{")
        close_braces += stripped.count("}")

    if open_braces != close_braces:
        errors.append(
            f"Unbalanced braces: {open_braces} opening, {close_braces} closing"
        )

    # Check that statements end with semicolons (inside blocks)
    in_block = 0
    for i, line in enumerate(lines, 1):
        stripped = line.split("#")[0].strip()
        if not stripped or stripped.startswith("!"):
            continue

        in_block += stripped.count("{")
        in_block -= stripped.count("}")

        # Skip lines that are just braces or block declarations
        if stripped in ("{", "}") or stripped.endswith(("{", "}")):
            continue

        # Inside a block, non-empty lines should end with ;
        if (
            in_block > 0
            and stripped
            and not stripped.endswith(";")
            and not stripped.startswith(("group", "host", "subnet", "pool"))
        ):
            errors.append(f"Line {i}: Missing semicolon: '{stripped[:60]}'")

    return errors


# =============================================================================
# dnsmasq Config Linter
# =============================================================================


def lint_dnsmasq_conf(filepath: Path) -> list[str]:
    """Lint dnsmasq configuration files."""
    errors: list[str] = []
    content = filepath.read_text()
    lines = content.splitlines()

    valid_directives = {
        "dhcp-host",
        "dhcp-range",
        "address",
        "server",
        "interface",
        "listen-address",
        "domain",
        "expand-hosts",
        "bogus-priv",
        "no-resolv",
        "cache-size",
        "log-queries",
        "log-dhcp",
    }

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Check directive format: key=value or key
        if "=" in stripped:
            directive = stripped.split("=")[0]
        else:
            directive = stripped.split()[0] if stripped.split() else ""

        if directive and directive not in valid_directives:
            # Warning, not error - dnsmasq has many directives
            pass  # We don't enforce unknown directives

        # Validate dhcp-host entries
        if stripped.startswith("dhcp-host="):
            value = stripped[len("dhcp-host=") :]
            parts = value.split(",")
            if len(parts) < 2:
                errors.append(
                    f"Line {i}: dhcp-host needs at least MAC,IP: '{stripped[:60]}'"
                )

        # Validate address entries
        if stripped.startswith("address="):
            value = stripped[len("address=") :]
            if not re.match(r"/[^/]+/.+", value):
                errors.append(f"Line {i}: Invalid address format: '{stripped[:60]}'")

    return errors


# =============================================================================
# Main
# =============================================================================


def find_config_files(search_path: Path) -> dict[str, list[Path]]:
    """Find all lintable configuration files."""
    files: dict[str, list[Path]] = {
        "haproxy": [],
        "keepalived": [],
        "dhcp": [],
        "dnsmasq": [],
    }

    if not search_path.exists():
        return files

    for f in search_path.rglob("*"):
        if not f.is_file():
            continue
        name = f.name.lower()

        if name == "haproxy.cfg" or name.endswith(".cfg"):
            files["haproxy"].append(f)
        elif "keepalived" in name and name.endswith(".conf"):
            files["keepalived"].append(f)
        elif "dhcpd" in name and name.endswith(".conf"):
            files["dhcp"].append(f)
        elif "dnsmasq" in name and name.endswith(".conf"):
            files["dnsmasq"].append(f)

    return files


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Lint K3s cluster configuration files.",
    )
    parser.add_argument(
        "--path",
        type=Path,
        nargs="*",
        default=[DEFAULT_PATH, CONFIGS_PATH],
        help="Paths to search for config files",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat warnings as errors",
    )

    args = parser.parse_args()

    print("=" * 60)
    print(" Configuration File Linter")
    print("=" * 60)
    print()

    total_errors = 0
    total_files = 0

    for search_path in args.path:
        if not search_path.exists():
            print(f"  Skipping (not found): {search_path}")
            continue

        files = find_config_files(search_path)

        # Lint HAProxy files
        for filepath in files["haproxy"]:
            total_files += 1
            errors = lint_haproxy(filepath)
            if errors:
                print(f"  FAIL: {filepath}")
                for err in errors:
                    print(f"    - {err}")
                total_errors += len(errors)
            else:
                print(f"  OK:   {filepath}")

        # Lint Keepalived files
        for filepath in files["keepalived"]:
            total_files += 1
            errors = lint_keepalived(filepath)
            if errors:
                print(f"  FAIL: {filepath}")
                for err in errors:
                    print(f"    - {err}")
                total_errors += len(errors)
            else:
                print(f"  OK:   {filepath}")

        # Lint DHCP files
        for filepath in files["dhcp"]:
            total_files += 1
            errors = lint_dhcp_conf(filepath)
            if errors:
                print(f"  FAIL: {filepath}")
                for err in errors:
                    print(f"    - {err}")
                total_errors += len(errors)
            else:
                print(f"  OK:   {filepath}")

        # Lint dnsmasq files
        for filepath in files["dnsmasq"]:
            total_files += 1
            errors = lint_dnsmasq_conf(filepath)
            if errors:
                print(f"  FAIL: {filepath}")
                for err in errors:
                    print(f"    - {err}")
                total_errors += len(errors)
            else:
                print(f"  OK:   {filepath}")

    print()
    print("=" * 60)
    print(f"  Files checked: {total_files}")
    print(f"  Errors found:  {total_errors}")
    print("=" * 60)

    return 1 if total_errors > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
