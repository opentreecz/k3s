#!/usr/bin/env python3
"""K3s Cluster Configuration Generator.

Renders Jinja2 templates using variables from variables.yaml to produce
ready-to-deploy configuration files in the generated/ directory.

Usage:
    python3 generate.py [--vars VARIABLES_FILE] [--output-dir OUTPUT_DIR]
    python3 generate.py --help

Examples:
    # Generate with defaults (variables.yaml -> generated/)
    python3 generate.py

    # Use a custom variables file
    python3 generate.py --vars my-cluster.yaml

    # Output to a different directory
    python3 generate.py --output-dir /tmp/k3s-configs

    # Validate templates without writing (dry-run)
    python3 generate.py --dry-run

    # Generate only specific templates
    python3 generate.py --only haproxy,keepalived
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError:
    print("ERROR: Jinja2 is required. Install with: pip install jinja2")
    sys.exit(1)


# =============================================================================
# Constants
# =============================================================================

SCRIPT_DIR = Path(__file__).parent.resolve()
DEFAULT_VARS_FILE = SCRIPT_DIR / "variables.yaml"
DEFAULT_OUTPUT_DIR = SCRIPT_DIR / "generated"
TEMPLATES_DIR = SCRIPT_DIR / "templates" / "jinja2"


# =============================================================================
# Template rendering definitions
# =============================================================================

# Each entry defines:
#   template: Jinja2 template file name
#   output: Output path relative to output_dir
#   per_node: If set, generates one file per node (master/worker)
#   node_type: "master" or "worker" (only used if per_node is True)

RENDER_TARGETS: list[dict[str, Any]] = [
    # HAProxy - single file for all masters
    {
        "template": "haproxy.cfg.j2",
        "output": "haproxy/haproxy.cfg",
        "per_node": False,
        "group": "haproxy",
    },
    # Keepalived - one file per master node
    {
        "template": "keepalived.conf.j2",
        "output": "keepalived/{hostname}/keepalived.conf",
        "per_node": True,
        "node_type": "master",
        "group": "keepalived",
    },
    # K3s server config - one file per master node
    {
        "template": "k3s-server.yaml.j2",
        "output": "k3s/{hostname}/config.yaml",
        "per_node": True,
        "node_type": "master",
        "group": "k3s",
    },
    # K3s agent config - one file per worker node
    {
        "template": "k3s-agent.yaml.j2",
        "output": "k3s/{hostname}/config.yaml",
        "per_node": True,
        "node_type": "worker",
        "group": "k3s",
    },
    # DHCP leases - single files
    {
        "template": "dhcpd4-leases.conf.j2",
        "output": "network/dhcpd4-leases.conf",
        "per_node": False,
        "group": "network",
    },
    {
        "template": "dhcpd6-leases.conf.j2",
        "output": "network/dhcpd6-leases.conf",
        "per_node": False,
        "group": "network",
    },
    {
        "template": "dnsmasq-leases.conf.j2",
        "output": "network/dnsmasq-leases.conf",
        "per_node": False,
        "group": "network",
    },
    # Hosts file entries
    {
        "template": "hosts.j2",
        "output": "network/hosts",
        "per_node": False,
        "group": "network",
    },
    # Sysctl configuration
    {
        "template": "sysctl-k3s.conf.j2",
        "output": "os/sysctl-k3s.conf",
        "per_node": False,
        "group": "os",
    },
    # Disk partitioning - AutoYaST (template resolved dynamically)
    {
        "template": None,  # resolved dynamically based on disk_layout
        "output": "os/disk-partitioning.xml",
        "per_node": False,
        "group": "storage",
        "dynamic_template": True,
    },
    # Disk partitioning - Ignition (MicroOS)
    {
        "template": "disk-ignition.json.j2",
        "output": "os/disk-ignition.json",
        "per_node": False,
        "group": "storage",
    },
    # Longhorn Helm values (only when provider == "longhorn")
    {
        "template": "longhorn-values.yaml.j2",
        "output": "storage/longhorn-values.yaml",
        "per_node": False,
        "group": "storage",
        "condition": "longhorn",
    },
    # Local-path StorageClass (only when provider == "local-path")
    {
        "template": "storageclass-local-path.yaml.j2",
        "output": "storage/storageclass-local-path.yaml",
        "per_node": False,
        "group": "storage",
        "condition": "local-path",
    },
]


# =============================================================================
# Functions
# =============================================================================


def load_variables(vars_file: Path) -> dict[str, Any]:
    """Load and validate the variables YAML file."""
    if not vars_file.exists():
        print(f"ERROR: Variables file not found: {vars_file}")
        sys.exit(1)

    with vars_file.open() as f:
        variables = yaml.safe_load(f)

    if not isinstance(variables, dict):
        print(f"ERROR: Variables file must be a YAML mapping: {vars_file}")
        sys.exit(1)

    # Validate required sections
    required_sections = [
        "network",
        "vip",
        "masters",
        "workers",
        "k3s",
        "haproxy",
        "keepalived",
        "dhcp",
    ]
    missing = [s for s in required_sections if s not in variables]
    if missing:
        print(f"ERROR: Missing required sections in variables: {', '.join(missing)}")
        sys.exit(1)

    # Validate master count
    if len(variables["masters"]) < 1:
        print("ERROR: At least 1 master node is required")
        sys.exit(1)

    return variables


def create_jinja_env(templates_dir: Path) -> Environment:
    """Create and configure the Jinja2 environment."""
    if not templates_dir.exists():
        print(f"ERROR: Templates directory not found: {templates_dir}")
        sys.exit(1)

    return Environment(
        loader=FileSystemLoader(str(templates_dir)),
        undefined=StrictUndefined,
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )


def render_template(
    env: Environment,
    template_name: str,
    context: dict[str, Any],
) -> str:
    """Render a single template with the given context."""
    template = env.get_template(template_name)
    return template.render(**context)


def write_output(output_path: Path, content: str, dry_run: bool = False) -> None:
    """Write rendered content to a file."""
    if dry_run:
        print(f"  [DRY-RUN] Would write: {output_path}")
        return

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w") as f:
        f.write(content)
    print(f"  Generated: {output_path}")


def generate_configs(
    variables: dict[str, Any],
    env: Environment,
    output_dir: Path,
    dry_run: bool = False,
    only_groups: list[str] | None = None,
) -> int:
    """Generate all configuration files from templates.

    Returns the number of files generated.
    """
    count = 0

    for target in RENDER_TARGETS:
        # Filter by group if --only is specified
        if only_groups and target["group"] not in only_groups:
            continue

        # Check conditional rendering (storage provider condition)
        condition = target.get("condition")
        if condition:
            provider = variables.get("storage", {}).get("provider", "none")
            if provider != condition:
                continue

        template_name = target["template"]

        # Handle dynamic template resolution (disk layout)
        if target.get("dynamic_template"):
            disk_layout = variables.get("storage", {}).get("disk_layout", "single-root")
            layout_map = {
                "single-root": "disk-single-root.xml.j2",
                "single-disk-multipart": "disk-multipart.xml.j2",
                "multi-disk": "disk-multidisk.xml.j2",
            }
            template_name = layout_map.get(disk_layout, "disk-single-root.xml.j2")

        if target["per_node"]:
            # Determine which nodes to iterate
            node_type = target["node_type"]
            nodes = (
                variables["masters"] if node_type == "master" else variables["workers"]
            )

            for idx, node in enumerate(nodes):
                # Build per-node context
                context = {
                    **variables,
                    "node": node,
                    "node_index": idx,
                }

                # Render
                content = render_template(env, template_name, context)

                # Determine output path
                output_path = output_dir / target["output"].format(
                    hostname=node["hostname"]
                )
                write_output(output_path, content, dry_run)
                count += 1
        else:
            # Single file generation
            context = {**variables}
            content = render_template(env, template_name, context)

            output_path = output_dir / target["output"]
            write_output(output_path, content, dry_run)
            count += 1

    return count


# =============================================================================
# Main
# =============================================================================


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Generate K3s cluster configuration from Jinja2 templates.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 generate.py                    Generate all configs
  python3 generate.py --dry-run          Validate without writing
  python3 generate.py --only haproxy     Generate only HAProxy configs
  python3 generate.py --vars prod.yaml   Use custom variables file
        """,
    )
    parser.add_argument(
        "--vars",
        type=Path,
        default=DEFAULT_VARS_FILE,
        help=f"Path to variables YAML file (default: {DEFAULT_VARS_FILE})",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Output directory for generated files (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--templates-dir",
        type=Path,
        default=TEMPLATES_DIR,
        help=f"Jinja2 templates directory (default: {TEMPLATES_DIR})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate templates and variables without writing files",
    )
    parser.add_argument(
        "--only",
        type=str,
        default=None,
        help="Comma-separated list of groups to generate: "
        "haproxy,keepalived,k3s,network,os",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove the output directory before generating",
    )

    args = parser.parse_args()

    print("=" * 60)
    print(" K3s Configuration Generator")
    print("=" * 60)
    print(f"  Variables:  {args.vars}")
    print(f"  Templates:  {args.templates_dir}")
    print(f"  Output:     {args.output_dir}")
    if args.dry_run:
        print("  Mode:       DRY-RUN (no files will be written)")
    print()

    # Load variables
    print("Loading variables...")
    variables = load_variables(args.vars)
    print(
        f"  Cluster: {len(variables['masters'])} masters, "
        f"{len(variables['workers'])} workers"
    )
    print(f"  VIP: {variables['vip']['ipv4']} / {variables['vip']['ipv6']}")
    print(f"  Domain: {variables['network']['domain']}")
    print()

    # Clean output directory if requested
    if args.clean and not args.dry_run:
        import shutil

        if args.output_dir.exists():
            shutil.rmtree(args.output_dir)
            print(f"Cleaned output directory: {args.output_dir}")
            print()

    # Create Jinja2 environment
    env = create_jinja_env(args.templates_dir)

    # Parse --only groups
    only_groups = None
    if args.only:
        only_groups = [g.strip() for g in args.only.split(",")]
        print(f"Generating only: {', '.join(only_groups)}")
        print()

    # Generate
    print("Generating configuration files...")
    try:
        count = generate_configs(
            variables=variables,
            env=env,
            output_dir=args.output_dir,
            dry_run=args.dry_run,
            only_groups=only_groups,
        )
    except Exception as e:
        print(f"\nERROR: Template rendering failed: {e}")
        return 1

    print()
    print("=" * 60)
    print(f"  {count} file(s) generated successfully.")
    if not args.dry_run:
        print(f"  Output directory: {args.output_dir}")
    print("=" * 60)

    return 0


if __name__ == "__main__":
    sys.exit(main())
