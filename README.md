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
├── README.md                    # This file
├── docs/
│   ├── 01-os-installation.md    # OS installation guide (SLE Micro / MicroOS)
│   ├── 02-os-configuration.md   # Post-install OS configuration
│   ├── 03-network-planning.md   # Network and DHCP lease planning
│   ├── 04-haproxy-setup.md      # HAProxy + Keepalived setup
│   ├── 05-k3s-installation.md   # K3s cluster bootstrap
│   └── 06-worker-nodes.md       # Adding worker nodes
├── configs/
│   ├── haproxy/
│   │   ├── haproxy.cfg          # HAProxy configuration
│   │   └── keepalived.conf      # Keepalived configuration
│   ├── k3s/
│   │   ├── server-config.yaml   # K3s server configuration
│   │   └── agent-config.yaml    # K3s agent configuration
│   ├── network/
│   │   ├── dhcpd4-leases.conf   # ISC DHCPv4 static leases
│   │   ├── dhcpd6-leases.conf   # ISC DHCPv6 static leases
│   │   └── dnsmasq-leases.conf  # dnsmasq static leases (alternative)
│   └── os/
│       ├── sle-micro.xml        # AutoYaST profile for SLE Micro
│       └── microos-ignition.json # Ignition config for MicroOS
├── scripts/
│   ├── 00-validate-environment.sh  # Pre-flight checks
│   ├── 01-configure-os.sh          # OS post-install configuration
│   ├── 02-install-haproxy.sh       # HAProxy + Keepalived installation
│   ├── 03-install-k3s-first.sh     # Bootstrap first K3s server
│   ├── 04-install-k3s-servers.sh   # Join additional K3s servers
│   ├── 05-install-k3s-agents.sh    # Join K3s worker agents
│   └── env.sh                      # Environment variables and settings
└── templates/
    └── inventory.example.conf      # Example inventory file
```

## Quick Start

1. Plan your network and configure DHCP static leases (see `docs/03-network-planning.md`)
2. Install the operating system (see `docs/01-os-installation.md`)
3. Configure the OS (see `docs/02-os-configuration.md`)
4. Copy and edit the inventory file:
   ```bash
   cp templates/inventory.example.conf inventory.conf
   # Edit inventory.conf with your node details
   ```
5. Run the deployment:
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
