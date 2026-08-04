# K3s Baremetal High-Availability Cluster

This repository provides a complete installation and configuration procedure for deploying a highly available K3s Kubernetes cluster on baremetal servers running **SUSE Linux Enterprise Micro (SLE Micro)** or **openSUSE MicroOS**.

## Architecture Overview

```
                        +-------------------+
                        |   Virtual IP      |
                        | (HAProxy Float)   |
                        +--------+----------+
                                 |
              +------------------+------------------+
              |                  |                  |
     +--------v------+  +-------v-------+  +------v--------+
     | HAProxy Node  |  | HAProxy Node  |  | HAProxy Node  |
     | (colocated on |  | (colocated on |  | (colocated on |
     |  master-01)   |  |  master-02)   |  |  master-03)   |
     +--------+------+  +-------+-------+  +------+--------+
              |                  |                  |
     +--------v------+  +-------v-------+  +------v--------+
     |  K3s Server   |  |  K3s Server   |  |  K3s Server   |
     |  (master-01)  |  |  (master-02)  |  |  (master-03)  |
     +---------------+  +---------------+  +---------------+
                                 |
              +------------------+------------------+
              |                  |                  |
     +--------v------+  +-------v-------+  +------v--------+
     |  K3s Agent    |  |  K3s Agent    |  |  K3s Agent    |
     |  (worker-01)  |  |  (worker-02)  |  |  (worker-N)   |
     +---------------+  +---------------+  +---------------+
```

## Components

| Component | Purpose |
|-----------|---------|
| SUSE Linux Enterprise Micro / openSUSE MicroOS | Immutable OS optimized for containers |
| K3s | Lightweight Kubernetes distribution |
| HAProxy | Load balancer for K3s API server (port 6443) |
| Keepalived | Virtual IP failover for HAProxy |
| DHCPv4/DHCPv6 static leases | Predictable network addressing |

## Network Requirements

All nodes use **DHCPv4 and DHCPv6** for network configuration. Static DHCP leases **must** be configured on your DHCP server before deployment to ensure predictable IP addressing for all cluster components.

## Repository Structure

```
.
├── README.md                       # This file
├── variables.yaml                  # Single source of truth for all config values
├── generate.py                     # Jinja2 template renderer (generates configs)
├── lint_configs.py                 # Custom linter for conf/cfg files
├── requirements.txt                # Python dependencies
├── pyproject.toml                  # Ruff (Python linter) configuration
├── .yamllint.yaml                  # yamllint configuration
├── .github/
│   └── workflows/
│       └── lint.yaml               # CI: lint Python, YAML, configs, shell
├── docs/
│   ├── 01-os-installation.md       # OS installation guide (SLE Micro / MicroOS)
│   ├── 02-os-configuration.md      # Post-install OS configuration
│   ├── 03-network-planning.md      # Network and DHCP lease planning
│   ├── 04-haproxy-setup.md         # HAProxy + Keepalived setup
│   ├── 05-k3s-installation.md      # K3s cluster bootstrap
│   └── 06-worker-nodes.md          # Adding worker nodes
├── templates/
│   ├── jinja2/                     # Jinja2 templates (source of generated configs)
│   │   ├── haproxy.cfg.j2          # HAProxy load balancer
│   │   ├── keepalived.conf.j2      # Keepalived VIP (per-node)
│   │   ├── k3s-server.yaml.j2      # K3s server config (per-node)
│   │   ├── k3s-agent.yaml.j2       # K3s agent config (per-node)
│   │   ├── dhcpd4-leases.conf.j2   # ISC DHCPv4 static leases
│   │   ├── dhcpd6-leases.conf.j2   # ISC DHCPv6 static leases
│   │   ├── dnsmasq-leases.conf.j2  # dnsmasq leases + DNS
│   │   ├── hosts.j2                # /etc/hosts entries
│   │   └── sysctl-k3s.conf.j2      # Kernel parameters
│   └── inventory.example.conf      # Legacy inventory template
├── configs/                        # Reference configs (static examples)
│   ├── haproxy/
│   ├── k3s/
│   ├── network/
│   └── os/
├── generated/                      # OUTPUT of generate.py (gitignored)
│   ├── haproxy/
│   ├── keepalived/{hostname}/
│   ├── k3s/{hostname}/
│   ├── network/
│   └── os/
└── scripts/
    ├── 00-validate-environment.sh  # Pre-flight checks
    ├── 01-configure-os.sh          # OS post-install configuration
    ├── 02-install-haproxy.sh       # HAProxy + Keepalived installation
    ├── 03-install-k3s-first.sh     # Bootstrap first K3s server
    ├── 04-install-k3s-servers.sh   # Join additional K3s servers
    ├── 05-install-k3s-agents.sh    # Join K3s worker agents
    └── env.sh                      # Environment variables and settings
```

## Configuration Generation (Jinja2 Templates)

All deployment configurations are generated from Jinja2 templates using a single
variables file. This ensures consistency and makes it easy to adapt the cluster
to different environments.

### Workflow

```
variables.yaml  ──┐
                   ├──▶  generate.py  ──▶  generated/
templates/jinja2/ ─┘                        ├── haproxy/haproxy.cfg
                                            ├── keepalived/master-01/keepalived.conf
                                            ├── keepalived/master-02/keepalived.conf
                                            ├── keepalived/master-03/keepalived.conf
                                            ├── k3s/master-01/config.yaml
                                            ├── k3s/master-02/config.yaml
                                            ├── k3s/master-03/config.yaml
                                            ├── k3s/worker-01/config.yaml
                                            ├── k3s/worker-02/config.yaml
                                            ├── k3s/worker-03/config.yaml
                                            ├── network/dhcpd4-leases.conf
                                            ├── network/dhcpd6-leases.conf
                                            ├── network/dnsmasq-leases.conf
                                            ├── network/hosts
                                            └── os/sysctl-k3s.conf
```

### Usage

```bash
# Install Python dependencies
pip install -r requirements.txt

# Edit the variables file with your cluster details
vim variables.yaml

# Generate all configs
python3 generate.py

# Generate only specific groups
python3 generate.py --only haproxy,keepalived

# Dry-run (validate without writing)
python3 generate.py --dry-run

# Use a custom variables file (e.g., for a different environment)
python3 generate.py --vars production.yaml --output-dir generated-prod
```

### Linting

```bash
# Lint Python code
ruff check .
ruff format --check .

# Lint YAML files
yamllint -c .yamllint.yaml variables.yaml configs/k3s/*.yaml

# Lint generated config files (HAProxy, Keepalived, DHCP)
python3 lint_configs.py

# Lint shell scripts
shellcheck -x scripts/*.sh
```

## Quick Start

1. Plan your network and configure DHCP static leases (see `docs/03-network-planning.md`)
2. Install the operating system (see `docs/01-os-installation.md`)
3. Configure the OS (see `docs/02-os-configuration.md`)
4. Install Python dependencies and configure:
   ```bash
   pip install -r requirements.txt
   # Edit variables.yaml with your cluster details (IPs, MACs, tokens)
   vim variables.yaml
   ```
5. Generate configuration files:
   ```bash
   python3 generate.py
   ```
6. Run the deployment:
   ```bash
   ./scripts/00-validate-environment.sh
   ./scripts/01-configure-os.sh
   ./scripts/02-install-haproxy.sh
   ./scripts/03-install-k3s-first.sh
   ./scripts/04-install-k3s-servers.sh
   ./scripts/05-install-k3s-agents.sh
   ```

## Prerequisites

- 3 baremetal servers for control plane (masters)
- 1+ baremetal servers for worker nodes
- DHCP server with static lease support (DHCPv4 and DHCPv6)
- Network connectivity between all nodes
- Internet access for package installation (or local mirror)
- SSH key-based access configured between deployment host and all nodes
- Python 3.11+ with pip (for configuration generation)
