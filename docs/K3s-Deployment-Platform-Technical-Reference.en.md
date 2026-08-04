# K3s High-Availability Baremetal Deployment Platform

## Technical Reference Document

**Version:** 1.0.0  
**Last Updated:** August 2026  
**Repository:** [github.com/opentreecz/k3s](https://github.com/opentreecz/k3s)  
**Web Generator:** [opentreecz.github.io/k3s](https://opentreecz.github.io/k3s/)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Project Overview](#2-project-overview)
3. [Architecture](#3-architecture)
4. [Component Deep-Dive](#4-component-deep-dive)
   - [4.1 Operating System Layer](#41-operating-system-layer)
   - [4.2 K3s Kubernetes Distribution](#42-k3s-kubernetes-distribution)
   - [4.3 HAProxy Load Balancer](#43-haproxy-load-balancer)
   - [4.4 Keepalived and Virtual IP](#44-keepalived-and-virtual-ip)
   - [4.5 Longhorn Distributed Storage](#45-longhorn-distributed-storage)
   - [4.6 Network Architecture (DHCPv4/DHCPv6)](#46-network-architecture-dhcpv4dhcpv6)
5. [Deployment Workflow](#5-deployment-workflow)
6. [Configuration Generation System](#6-configuration-generation-system)
7. [Disk Partitioning Strategy](#7-disk-partitioning-strategy)
8. [Security Model](#8-security-model)
9. [Persistent Storage Architecture](#9-persistent-storage-architecture)
10. [Continuous Integration and Quality Assurance](#10-continuous-integration-and-quality-assurance)
11. [Web-Based Configuration Generator](#11-web-based-configuration-generator)
12. [Summary](#12-summary)

---

## 1. Executive Summary

This project provides a complete, automated deployment platform for establishing a **highly available K3s Kubernetes cluster** on baremetal servers. The platform targets environments running **SUSE Linux Enterprise Micro (SLE Micro)** or **openSUSE MicroOS** — immutable, container-optimized operating systems designed specifically for edge and Kubernetes workloads.

The deployment platform addresses the full lifecycle of cluster provisioning:

- Operating system installation and configuration
- Network planning with DHCPv4/DHCPv6 static lease management
- API server high availability via HAProxy and Keepalived
- Automated K3s cluster bootstrap with embedded etcd
- Worker node enrollment
- Persistent storage provisioning (Longhorn or local-path)
- SSH key management with GitHub key import

All configuration is driven by a **single variables file** and rendered through **Jinja2 templates**, ensuring consistency, repeatability, and auditability across environments.

---

## 2. Project Overview

### 2.1 Problem Statement

Deploying a production-grade Kubernetes cluster on baremetal servers presents several challenges that managed cloud environments abstract away:

- No automated infrastructure provisioning (no Terraform/cloud APIs)
- No built-in load balancer for the API server
- No managed storage backend
- Network addressing must be planned and coordinated with existing DHCP infrastructure
- Operating system installation and hardening is manual
- Certificate management requires careful IP/hostname planning

### 2.2 Solution Architecture

This platform solves these challenges through a layered approach:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Configuration Generation Layer                     │
│                                                                       │
│   variables.yaml ──► Jinja2 Templates ──► Generated Configs          │
│   (single source)    (18 templates)       (19+ output files)         │
│                                                                       │
│   Web UI (GitHub Pages) ──► Browser-side Nunjucks ──► ZIP Archive    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Deployment Automation Layer                      │
│                                                                       │
│   00-validate-environment.sh    Pre-flight checks                    │
│   01-configure-os.sh            OS hardening, SSH keys, sysctl       │
│   02-install-haproxy.sh         HAProxy + Keepalived on masters      │
│   03-install-k3s-first.sh       Bootstrap first server (cluster-init)│
│   04-install-k3s-servers.sh     Join additional server nodes         │
│   05-install-k3s-agents.sh      Join worker nodes                    │
│   06-install-storage.sh         Longhorn or local-path deployment    │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       Infrastructure Layer                            │
│                                                                       │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │master-01 │  │master-02 │  │master-03 │  Control Plane (3 nodes) │
│   │HAProxy   │  │HAProxy   │  │HAProxy   │                          │
│   │Keepalived│  │Keepalived│  │Keepalived│                          │
│   │K3s Server│  │K3s Server│  │K3s Server│                          │
│   │etcd      │  │etcd      │  │etcd      │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
│         │              │              │                               │
│         └──────────────┼──────────────┘                              │
│                        │ VIP: 192.168.1.100                          │
│                        │                                             │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│   │worker-01 │  │worker-02 │  │worker-03 │  Data Plane (N nodes)    │
│   │K3s Agent │  │K3s Agent │  │K3s Agent │                          │
│   │Longhorn  │  │Longhorn  │  │Longhorn  │                          │
│   └──────────┘  └──────────┘  └──────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 Repository Structure

```
k3s/
├── variables.yaml                  # Single source of truth
├── generate.py                     # Python template renderer
├── lint_configs.py                 # Custom configuration linter
├── requirements.txt                # Python dependencies
├── pyproject.toml                  # Ruff linter configuration
├── .yamllint.yaml                  # YAML lint rules
├── .shellcheckrc                   # Shell lint configuration
├── .github/workflows/
│   ├── lint.yaml                   # CI: lint all file types
│   └── pages.yaml                  # CI: deploy web UI to GitHub Pages
├── docs/                           # Step-by-step documentation
├── templates/jinja2/               # 18 Jinja2 configuration templates
├── configs/                        # Static reference configurations
├── scripts/                        # 7 deployment automation scripts
├── web/                            # Browser-based configuration generator
└── generated/                      # Output directory (gitignored)
```

---

## 3. Architecture

### 3.1 High-Availability Topology

The cluster employs a **3-node control plane** with **embedded etcd** for consensus, fronted by **HAProxy** for API load balancing and **Keepalived** for Virtual IP (VIP) failover.

```
                    ┌─────────────────────────────┐
                    │         Clients              │
                    │   (kubectl, CI/CD, apps)     │
                    └──────────────┬───────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │     Virtual IP (VIP)         │
                    │    192.168.1.100:6443        │
                    │    fd00::100:6443            │
                    │  (managed by Keepalived)     │
                    └──────────────┬───────────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                    │
              ▼                    ▼                    ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │   HAProxy       │  │   HAProxy       │  │   HAProxy       │
    │   (frontend)    │  │   (frontend)    │  │   (frontend)    │
    │   master-01     │  │   master-02     │  │   master-03     │
    │                 │  │                 │  │                 │
    │   K3s Server    │  │   K3s Server    │  │   K3s Server    │
    │   API Server    │  │   API Server    │  │   API Server    │
    │   Controller    │  │   Controller    │  │   Controller    │
    │   Scheduler     │  │   Scheduler     │  │   Scheduler     │
    │                 │  │                 │  │                 │
    │   etcd          │  │   etcd          │  │   etcd          │
    │  (embedded)     │  │  (embedded)     │  │  (embedded)     │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
              │                    │                    │
              │         etcd peer replication          │
              └────────────────────┼────────────────────┘
                                   │
                                   ▼
    ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
    │   K3s Agent     │  │   K3s Agent     │  │   K3s Agent     │
    │   kubelet       │  │   kubelet       │  │   kubelet       │
    │   kube-proxy    │  │   kube-proxy    │  │   kube-proxy    │
    │   Longhorn      │  │   Longhorn      │  │   Longhorn      │
    │                 │  │                 │  │                 │
    │   worker-01     │  │   worker-02     │  │   worker-03     │
    └─────────────────┘  └─────────────────┘  └─────────────────┘
```

### 3.2 Failure Domains

The architecture tolerates the following failures without service disruption:

| Failure Scenario | Impact | Recovery |
|-----------------|--------|----------|
| 1 master node down | No impact (2/3 etcd quorum maintained) | Automatic VIP failover |
| 1 worker node down | Pods rescheduled to remaining workers | Automatic by Kubernetes |
| HAProxy on 1 master | VIP moves to healthy HAProxy node | Keepalived failover (<3s) |
| Network partition (1 master isolated) | Quorum maintained by majority | Automatic reconciliation |
| 2 master nodes down | **Cluster unavailable** (quorum lost) | Manual intervention required |

### 3.3 Network Flow

```
kubectl ──► VIP:6443 ──► HAProxy ──► K3s API Server (any of 3 masters)
                              │
                              ├──► master-01:6443 (check: TCP health)
                              ├──► master-02:6443 (check: TCP health)
                              └──► master-03:6443 (check: TCP health)

Worker Agent ──► VIP:6443 ──► HAProxy ──► K3s API Server
                                              │
                                              ▼
                                     Register node
                                     Receive pod specs
                                     Report status
```

---

## 4. Component Deep-Dive

### 4.1 Operating System Layer

#### SUSE Linux Enterprise Micro (SLE Micro)

**SLE Micro** is SUSE's commercially-supported, immutable operating system purpose-built for containerized and virtualized workloads. Key characteristics:

- **Immutable root filesystem**: The root partition is read-only. Changes are applied via `transactional-update`, which creates a new Btrfs snapshot. The system boots into the new snapshot on next reboot, providing atomic upgrades with instant rollback capability.
- **Minimal attack surface**: Ships with only essential packages. No desktop environment, no unnecessary daemons.
- **SELinux/AppArmor**: Mandatory access control enabled by default.
- **Commercial lifecycle**: 4+ years of maintenance and security updates per major release.
- **Certification**: FIPS 140-2, Common Criteria certified variants available.

#### openSUSE MicroOS

**openSUSE MicroOS** is the community-driven upstream of SLE Micro, sharing the same architecture:

- **Rolling release**: Continuous updates (Tumbleweed-based).
- **Identical transactional-update mechanism**: Same atomic upgrade system.
- **No registration required**: Freely available, community-supported.
- **Ideal for**: Development clusters, proof-of-concept, community production environments.

#### Transactional Update Mechanism

```
┌─────────────────────────────────────────────────────────────┐
│                    Btrfs Root Filesystem                      │
│                                                              │
│  Snapshot #1 (current, read-only)                           │
│  └── / (running system)                                     │
│                                                              │
│  Snapshot #2 (created by transactional-update)              │
│  └── / (modified system: new packages, config changes)      │
│                                                              │
│  transactional-update reboot ──► Boot into Snapshot #2      │
│                                                              │
│  If Snapshot #2 fails:                                       │
│  └── Rollback to Snapshot #1 (instant, no data loss)        │
└─────────────────────────────────────────────────────────────┘
```

The `transactional-update` tool is the exclusive mechanism for modifying the operating system:

```bash
# Install packages (takes effect after reboot)
transactional-update pkg install open-iscsi nfs-client

# Apply all pending updates
transactional-update up

# Reboot into the new snapshot
transactional-update reboot
```

### 4.2 K3s Kubernetes Distribution

#### What is K3s?

**K3s** is a certified, production-grade Kubernetes distribution developed by SUSE/Rancher. It packages the entire Kubernetes control plane into a single binary (~60MB), making it suitable for resource-constrained environments, edge computing, and baremetal deployments where the operational overhead of kubeadm-based clusters is undesirable.

#### K3s vs Upstream Kubernetes

| Feature | K3s | Upstream (kubeadm) |
|---------|-----|-------------------|
| Binary size | ~60 MB | ~300+ MB (multiple binaries) |
| Memory footprint | ~512 MB (server) | ~1-2 GB (server) |
| Installation | Single curl command | Multi-step, certificate management |
| etcd | Embedded (or external) | Must provision separately |
| Container runtime | containerd (built-in) | Must install separately |
| Networking | Flannel (built-in) | Must install CNI plugin |
| Certificate management | Automatic rotation | Manual configuration |
| Upgrade | Replace binary + restart | Rolling upgrade procedure |

#### K3s Server Architecture (Control Plane)

Each K3s server node runs:

```
┌──────────────────────────────────────────────────────┐
│                    K3s Server Process                  │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │ API Server  │  │ Controller  │  │  Scheduler  │  │
│  │             │  │  Manager    │  │             │  │
│  └──────┬──────┘  └─────────────┘  └─────────────┘  │
│         │                                            │
│  ┌──────▼──────┐  ┌─────────────┐                   │
│  │   etcd      │  │ containerd  │                   │
│  │ (embedded)  │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐                   │
│  │  Flannel    │  │ CoreDNS     │                   │
│  │  (CNI)      │  │             │                   │
│  └─────────────┘  └─────────────┘                   │
└──────────────────────────────────────────────────────┘
```

#### K3s Agent Architecture (Worker)

Each K3s agent node runs:

```
┌──────────────────────────────────────────────────────┐
│                    K3s Agent Process                   │
│                                                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  kubelet    │  │ kube-proxy  │  │ containerd  │  │
│  │             │  │             │  │             │  │
│  └─────────────┘  └─────────────┘  └─────────────┘  │
│                                                       │
│  ┌─────────────┐  ┌─────────────────────────────┐   │
│  │  Flannel    │  │  Workload Pods              │   │
│  │  (CNI)      │  │  (user applications)        │   │
│  └─────────────┘  └─────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

#### Embedded etcd Cluster

K3s uses an embedded etcd cluster for storing all cluster state. With 3 server nodes, the etcd cluster operates with the Raft consensus algorithm:

- **Quorum**: 2 out of 3 nodes must agree on writes (majority)
- **Leader election**: One node is the leader; others are followers
- **Data replication**: All data is replicated to all 3 nodes
- **Failure tolerance**: Survives 1 node failure without data loss

```
         ┌─────────────┐
         │   etcd      │
         │  (leader)   │
         │  master-01  │
         └──────┬──────┘
                │
       ┌────────┴────────┐
       │  Raft consensus │
       │  replication    │
       ▼                 ▼
┌─────────────┐   ┌─────────────┐
│   etcd      │   │   etcd      │
│ (follower)  │   │ (follower)  │
│  master-02  │   │  master-03  │
└─────────────┘   └─────────────┘
```

#### K3s Cluster Bootstrap Sequence

The cluster initialization follows a precise order:

1. **First server** starts with `--cluster-init`, creating a single-node etcd cluster
2. **Second server** joins via `--server https://<first>:6443`, becoming an etcd follower
3. **Third server** joins similarly, completing the 3-node etcd quorum
4. **Agents** join via the VIP (`https://<VIP>:6443`) for high availability

```
Time ──────────────────────────────────────────────────────────────►

master-01: [cluster-init] ──► [etcd leader, 1/1] ──► [etcd leader, 1/3]
                                                              │
master-02:                    [join] ──► [etcd follower, 2/3] ─┤
                                                              │
master-03:                              [join] ──► [follower, 3/3]
                                                              │
                                              Quorum achieved ─┘
                                                              │
worker-01:                                         [join via VIP]
worker-02:                                         [join via VIP]
worker-03:                                         [join via VIP]
```

#### TLS Certificate Architecture

K3s automatically generates and manages TLS certificates. The `--tls-san` flags ensure certificates are valid for all access paths:

```
Certificate Subject Alternative Names:
├── 192.168.1.100        (VIP IPv4)
├── fd00::100            (VIP IPv6)
├── k3s-api.k3s.local    (VIP hostname)
├── master-01.k3s.local  (node FQDN)
├── master-01            (short name)
├── 192.168.1.101        (node IP)
├── master-02.k3s.local
├── master-02
├── 192.168.1.102
├── master-03.k3s.local
├── master-03
└── 192.168.1.103
```

This ensures `kubectl` can connect via:
- The VIP (normal operation)
- Any individual master IP (debugging/emergency)
- Any hostname variant

### 4.3 HAProxy Load Balancer

#### Purpose

HAProxy serves as the **Layer 4 (TCP) load balancer** for the K3s API server. It distributes incoming connections on port 6443 across all three master nodes, providing:

- **Load distribution**: Round-robin balancing across healthy backends
- **Health checking**: TCP-level health probes every 10 seconds
- **Automatic failover**: Removes unhealthy backends from the pool within 2 failed checks
- **Connection persistence**: Maintains existing connections during backend transitions

#### HAProxy Configuration Architecture

```
┌──────────────────────────────────────────────────────┐
│                   HAProxy Process                      │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Frontend: k3s_api_frontend          │ │
│  │              bind *:6443 (TCP mode)             │ │
│  └──────────────────────┬──────────────────────────┘ │
│                          │                            │
│  ┌──────────────────────▼──────────────────────────┐ │
│  │              Backend: k3s_api_backend            │ │
│  │              balance: roundrobin                 │ │
│  │                                                  │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │ │
│  │  │master-01 │  │master-02 │  │master-03 │      │ │
│  │  │:6443     │  │:6443     │  │:6443     │      │ │
│  │  │ check ✓  │  │ check ✓  │  │ check ✓  │      │ │
│  │  └──────────┘  └──────────┘  └──────────┘      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │              Listen: stats                       │ │
│  │              bind *:8404 (HTTP mode)            │ │
│  │              /stats dashboard                    │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

#### Health Check Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `inter` | 10s | Check interval when server is UP |
| `downinter` | 5s | Check interval when server is DOWN |
| `rise` | 2 | Consecutive successful checks to mark UP |
| `fall` | 2 | Consecutive failed checks to mark DOWN |
| `slowstart` | 60s | Gradual traffic ramp after recovery |
| `maxconn` | 250 | Max concurrent connections per backend |

#### Why TCP Mode (Layer 4)?

HAProxy operates in TCP mode (not HTTP) because:

1. The K3s API uses **mutual TLS** (mTLS) — HAProxy cannot terminate the connection
2. TCP mode has **lower overhead** (no HTTP parsing)
3. The API protocol is **HTTP/2** with streaming (watches) — TCP mode handles this natively
4. Health checks use **TCP connect** (port 6443 responsive = healthy)

### 4.4 Keepalived and Virtual IP

#### Purpose

Keepalived implements the **Virtual Router Redundancy Protocol (VRRP)** to manage a floating Virtual IP (VIP) address across the three master nodes. This VIP is the single entry point for all API access.

#### VRRP Operation

```
Normal Operation:                     After master-01 Failure:

  master-01 (MASTER, priority 101)      master-01 (DOWN)
  ├── VIP: 192.168.1.100 ✓             ├── VIP: (released)
  ├── Sends VRRP advertisements        │
  │                                     │
  master-02 (BACKUP, priority 100)      master-02 (MASTER, priority 100)
  ├── VIP: (standby)                   ├── VIP: 192.168.1.100 ✓
  ├── Listens for advertisements       ├── Sends VRRP advertisements
  │                                     │
  master-03 (BACKUP, priority 99)       master-03 (BACKUP, priority 99)
  ├── VIP: (standby)                   ├── VIP: (standby)
  ├── Listens for advertisements       ├── Listens for advertisements
```

#### Failover Sequence

1. Master-01 (MASTER) sends VRRP advertisements every 1 second
2. Master-02 and master-03 (BACKUP) listen for these advertisements
3. If advertisements stop arriving for 3 seconds (fall × interval):
   - The BACKUP with highest priority (master-02, priority 100) transitions to MASTER
   - It sends a Gratuitous ARP announcing the VIP on its MAC address
   - All network switches update their MAC tables
   - Traffic flows to master-02 immediately
4. When master-01 recovers:
   - With preemption enabled: master-01 reclaims MASTER (higher priority)
   - Without preemption: master-02 retains MASTER until it fails

#### Health-Tracking Script

Keepalived uses a health check script to tie VIP ownership to HAProxy health:

```bash
vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"   # Signal 0 = check if process exists
    interval 2                              # Check every 2 seconds
    weight 2                                # Add 2 to priority if healthy
    fall 3                                  # 3 failures to consider DOWN
    rise 2                                  # 2 successes to consider UP
}
```

This ensures the VIP only resides on a node where HAProxy is actually running and accepting connections.

#### Dual-Stack VIP (IPv4 + IPv6)

The VIP configuration includes both IPv4 and IPv6 addresses:

```
virtual_ipaddress {
    192.168.1.100/24 dev eth0    # IPv4 VIP
    fd00::100/64 dev eth0        # IPv6 VIP
}
```

Both addresses failover together, maintaining dual-stack API accessibility.

### 4.5 Longhorn Distributed Storage

#### What is Longhorn?

**Longhorn** is an open-source, cloud-native distributed block storage system developed by SUSE/Rancher for Kubernetes. It provides:

- **Replicated block storage**: Each volume is replicated across multiple nodes
- **Snapshots and backups**: Point-in-time snapshots with S3/NFS backup targets
- **Disaster recovery**: Cross-cluster replication for DR scenarios
- **Self-healing**: Automatic replica rebuilding when nodes fail
- **Thin provisioning**: Storage allocated on demand, not upfront
- **Web UI**: Visual dashboard for volume management

#### Longhorn Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                             │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │              Longhorn Manager (DaemonSet)                  │   │
│  │              Runs on all nodes                             │   │
│  │              Orchestrates volumes, replicas, engines       │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │  Longhorn CSI    │  │  Longhorn UI     │                     │
│  │  Driver          │  │  (Deployment)    │                     │
│  │  (DaemonSet)     │  │  Dashboard       │                     │
│  └──────────────────┘  └──────────────────┘                     │
│                                                                   │
│  Per-Volume Architecture:                                         │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Volume: my-app-data (10Gi, 3 replicas)                  │    │
│  │                                                           │    │
│  │  ┌─────────────┐                                         │    │
│  │  │   Engine    │  (runs on node where pod is scheduled)  │    │
│  │  │  (iSCSI)    │                                         │    │
│  │  └──────┬──────┘                                         │    │
│  │         │                                                 │    │
│  │    ┌────┼────────────────┐                                │    │
│  │    │    │                │                                │    │
│  │    ▼    ▼                ▼                                │    │
│  │  ┌────────┐  ┌────────┐  ┌────────┐                      │    │
│  │  │Replica │  │Replica │  │Replica │                      │    │
│  │  │worker-1│  │worker-2│  │worker-3│                      │    │
│  │  └────────┘  └────────┘  └────────┘                      │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

#### Write Path

When a pod writes data to a Longhorn volume:

1. Write enters the **Engine** (iSCSI target on the pod's node)
2. Engine **synchronously replicates** to all configured replicas
3. Write is acknowledged only after **all replicas** confirm
4. If a replica fails, the Engine marks it degraded and continues with remaining replicas
5. Longhorn Manager detects the degraded state and schedules a **rebuild** on a healthy node

#### Longhorn vs Local-Path Comparison

| Feature | Longhorn | Local-Path |
|---------|----------|------------|
| Replication | Yes (configurable, 1-5 replicas) | No (single node) |
| Node failure tolerance | Yes (data survives node loss) | No (data lost if node dies) |
| Snapshots | Yes (incremental, efficient) | No |
| Backups | Yes (S3, NFS targets) | No (manual) |
| Performance overhead | ~10-15% (replication cost) | None (direct disk I/O) |
| Complexity | Medium (Helm deployment) | Minimal (built into K3s) |
| Resource usage | ~500MB RAM per node | Negligible |
| Use case | Production, stateful workloads | Development, ephemeral data |

### 4.6 Network Architecture (DHCPv4/DHCPv6)

#### Why DHCP with Static Leases?

This deployment uses **DHCP** (both v4 and v6) for network configuration rather than static OS-level configuration because:

1. **Centralized management**: All addressing is managed on the DHCP server
2. **Consistency**: Same mechanism as other network devices
3. **Flexibility**: Changing addresses doesn't require OS reconfiguration
4. **IPv6 compatibility**: SLAAC and DHCPv6 work naturally with this model

However, **static DHCP leases** (reservations) are mandatory because:

- K3s certificates are bound to specific IP addresses
- etcd cluster membership requires stable addressing
- HAProxy backends are configured with fixed IPs
- Keepalived VIP must be predictable

#### IPv6 and Forwarding: The accept_ra Problem

A critical interaction exists between IPv6 forwarding and Router Advertisement (RA) processing:

```
Default Linux kernel behavior:
  net.ipv6.conf.all.forwarding = 0  →  accept_ra = 1 (process RAs) ✓
  net.ipv6.conf.all.forwarding = 1  →  accept_ra = 1 (IGNORE RAs)  ✗

K3s requires forwarding = 1 for pod networking.
This BREAKS SLAAC and DHCPv6 address acquisition.

Solution:
  net.ipv6.conf.all.accept_ra = 2   →  Process RAs even with forwarding ✓
  net.ipv6.conf.eth0.accept_ra = 2  →  Per-interface override            ✓
```

This platform automatically configures `accept_ra = 2` on all nodes to ensure IPv6 addressing continues to function with packet forwarding enabled.

#### Dual-Stack Networking

The cluster operates in full dual-stack mode:

| Network | IPv4 | IPv6 |
|---------|------|------|
| Node network | 192.168.1.0/24 | fd00::/64 |
| Pod CIDR | 10.42.0.0/16 | fd42::/48 |
| Service CIDR | 10.43.0.0/16 | fd43::/112 |
| VIP | 192.168.1.100 | fd00::100 |

---

## 5. Deployment Workflow

The deployment follows a strict sequential order. Each step depends on the successful completion of the previous step.

### Step 0: Environment Validation

```bash
./scripts/00-validate-environment.sh
```

**Purpose**: Validates all prerequisites before any changes are made.

**Checks performed**:
1. Inventory file exists and is parseable
2. Required local tools present (ssh, scp, curl, openssl)
3. SSH key file exists at configured path
4. SSH connectivity to all master nodes (timeout: 10s each)
5. SSH connectivity to all worker nodes
6. Actual IP addresses match expected DHCP leases (verifies DHCP is working)
7. Operating system identification on each node

**Exit behavior**: Exits with code 1 if any check fails, reporting all failures.

### Step 1: Operating System Configuration

```bash
./scripts/01-configure-os.sh
```

**Purpose**: Configures all nodes for K3s operation after OS installation.

**Actions per node**:

| Action | Detail |
|--------|--------|
| Set hostname | `hostnamectl set-hostname <hostname>.<domain>` |
| Configure /etc/hosts | All node IPs (IPv4 + IPv6) for local resolution |
| Kernel parameters | ip_forward, bridge-nf-call, accept_ra=2, inotify, conntrack |
| Kernel modules | br_netfilter, overlay, ip_vs, ip_vs_rr/wrr/sh, nf_conntrack |
| File limits | nofile=65536, nproc=65536 (soft+hard) |
| Firewall | Open ports: 6443, 2379, 2380, 10250, 8472, 51820, etc. |
| Packages | open-iscsi, nfs-client, cryptsetup, apparmor-parser |
| Non-local bind | For HAProxy (masters only): ip_nonlocal_bind=1 |
| SSH keys | Deploy authorized_keys + sshd hardening |
| GitHub keys | Fetch from https://github.com/<user>.keys |

### Step 2: HAProxy + Keepalived Installation

```bash
./scripts/02-install-haproxy.sh
```

**Purpose**: Installs and configures the API load balancer on all master nodes.

**Sequence**:
1. Generate HAProxy configuration (backends from inventory)
2. Generate per-node Keepalived configuration (different priority per node)
3. For each master node:
   - Install haproxy and keepalived packages
   - Deploy haproxy.cfg
   - Deploy keepalived.conf (node-specific)
   - Enable and start services
4. Verify VIP is assigned to the highest-priority node
5. Verify HAProxy is listening on port 6443

### Step 3: Bootstrap First K3s Server

```bash
./scripts/03-install-k3s-first.sh
```

**Purpose**: Initializes the K3s cluster on the first master node.

**Critical details**:
- Uses `--cluster-init` flag (creates single-node etcd cluster)
- Generates or uses provided cluster token
- Includes all TLS SANs (VIP, all master IPs, all hostnames)
- Configures dual-stack CIDRs
- Disables default Traefik and ServiceLB
- Waits for node to reach Ready state
- Saves token to local file for subsequent scripts

### Step 4: Join Additional Servers

```bash
./scripts/04-install-k3s-servers.sh
```

**Purpose**: Joins master-02 and master-03 to the cluster.

**Key difference from Step 3**: Uses `--server https://<first-master-IP>:6443` instead of `--cluster-init`. Joins via the first master's direct IP (not VIP) to avoid chicken-and-egg issues during bootstrap.

**After completion**: 3-node etcd quorum is established. The cluster is now HA.

### Step 5: Join Worker Nodes

```bash
./scripts/05-install-k3s-agents.sh
```

**Purpose**: Enrolls all worker nodes into the cluster.

**Key details**:
- Workers connect via the **VIP** (not individual masters) — HA is already active
- Uses `INSTALL_K3S_EXEC="agent"` (not "server")
- Applies worker labels automatically
- Waits for each node to reach Ready state

### Step 6: Install Persistent Storage

```bash
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh
```

**Purpose**: Deploys the chosen persistent storage solution.

**For Longhorn**:
1. Verify prerequisites (open-iscsi, iscsid, data path)
2. Install Helm on first master
3. Add Longhorn Helm repository
4. Deploy with generated values file
5. Wait for all pods to be ready (timeout: 300s)
6. Verify StorageClass is created

**For local-path**:
1. Create data directory on all nodes
2. Apply StorageClass configuration
3. Set as default StorageClass

---

## 6. Configuration Generation System

### 6.1 Design Philosophy

The configuration generation system follows the principle of **"single source of truth, multiple outputs"**:

```
                    ┌─────────────────┐
                    │  variables.yaml  │  ◄── User edits THIS ONE file
                    │  (240+ lines)    │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────┐
     │  Python    │  │  Web UI    │  │  Scripts   │
     │ generate.py│  │ (browser)  │  │  (bash)    │
     └─────┬──────┘  └─────┬──────┘  └─────┬──────┘
           │                │               │
           ▼                ▼               │
     ┌────────────┐  ┌────────────┐         │
     │ generated/ │  │  ZIP file  │         │
     │ (19 files) │  │ (download) │         │
     └────────────┘  └────────────┘         │
                                            ▼
                                    ┌────────────┐
                                    │ Remote SSH │
                                    │ execution  │
                                    └────────────┘
```

### 6.2 Template Engine

**Server-side (Python)**: Uses Jinja2 3.1+ with `StrictUndefined` — any missing variable causes an immediate error rather than silent empty output.

**Client-side (Browser)**: Uses Nunjucks 3.2.4, a JavaScript port of Jinja2, enabling identical template syntax in the web UI.

### 6.3 Template Catalog

| Template | Output | Type |
|----------|--------|------|
| haproxy.cfg.j2 | haproxy/haproxy.cfg | Single |
| keepalived.conf.j2 | keepalived/{hostname}/keepalived.conf | Per-master |
| k3s-server.yaml.j2 | k3s/{hostname}/config.yaml | Per-master |
| k3s-agent.yaml.j2 | k3s/{hostname}/config.yaml | Per-worker |
| dhcpd4-leases.conf.j2 | network/dhcpd4-leases.conf | Single |
| dhcpd6-leases.conf.j2 | network/dhcpd6-leases.conf | Single |
| dnsmasq-leases.conf.j2 | network/dnsmasq-leases.conf | Single |
| hosts.j2 | network/hosts | Single |
| sysctl-k3s.conf.j2 | os/sysctl-k3s.conf | Single |
| ssh-config.j2 | os/ssh-config.txt | Single |
| disk-single-root.xml.j2 | os/disk-partitioning.xml | Conditional |
| disk-multipart.xml.j2 | os/disk-partitioning.xml | Conditional |
| disk-multidisk.xml.j2 | os/disk-partitioning.xml | Conditional |
| disk-ignition.json.j2 | os/disk-ignition.json | Single |
| longhorn-values.yaml.j2 | storage/longhorn-values.yaml | Conditional |
| storageclass-local-path.yaml.j2 | storage/storageclass-local-path.yaml | Conditional |

### 6.4 Conditional Rendering

The generator supports two types of conditional logic:

1. **Dynamic template selection**: The disk partitioning template is selected based on `storage.disk_layout` value
2. **Provider condition**: Storage templates only render when the matching provider is selected

```python
# Dynamic template selection
if target.get("dynamic_template"):
    disk_layout = variables["storage"]["disk_layout"]
    template_name = layout_map[disk_layout]

# Conditional rendering
condition = target.get("condition")
if condition and variables["storage"]["provider"] != condition:
    continue  # Skip this template
```

---

## 7. Disk Partitioning Strategy

### 7.1 Layout Options

#### Option A: Single Root

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────────────────────────┤
│ /boot/efi│            /                 │
│  512 MB  │     (Btrfs, remaining)       │
│  (vfat)  │                              │
│          │  Subvolumes:                  │
│          │  @/var                        │
│          │  @/var/lib/rancher            │
│          │  @/var/lib/longhorn           │
│          │  @/home                       │
│          │  @/.snapshots                 │
└──────────┴──────────────────────────────┘
```

#### Option B: Multi-Partition (Recommended)

```
┌─────────────────────────────────────────┐
│             /dev/sda                     │
├──────────┬──────────┬──────────┬────────┤
│ /boot/efi│    /     │/var/lib/ │Storage │
│  512 MB  │  40 GB   │rancher   │  max   │
│  (vfat)  │ (Btrfs)  │ 100 GB   │ (XFS)  │
│          │          │  (XFS)   │        │
└──────────┴──────────┴──────────┴────────┘
```

#### Option C: Multi-Disk

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│    /dev/sda      │  │    /dev/sdb      │  │    /dev/sdc      │
├──────────┬───────┤  ├──────────────────┤  ├──────────────────┤
│ /boot/efi│   /   │  │  /var/lib/rancher│  │  /var/lib/       │
│  512 MB  │  max  │  │    (entire disk) │  │  longhorn        │
│  (vfat)  │(Btrfs)│  │      (XFS)       │  │  (entire disk)   │
│          │       │  │                  │  │    (XFS)         │
└──────────┴───────┘  └──────────────────┘  └──────────────────┘
    OS Disk               Data Disk             Storage Disk
```

### 7.2 Filesystem Selection Rationale

| Mount Point | Filesystem | Reason |
|-------------|-----------|--------|
| / | Btrfs | Supports transactional-update snapshots, copy-on-write, compression |
| /var/lib/rancher | XFS | High-performance for container layer writes, no CoW overhead |
| /var/lib/longhorn | XFS | Block storage backend needs consistent sequential write performance |
| /boot/efi | vfat | Required by UEFI specification |

---

## 8. Security Model

### 8.1 SSH Key Management

The platform provides three methods for SSH key deployment:

```
┌─────────────────────────────────────────────────────────┐
│                 SSH Key Sources                           │
│                                                          │
│  1. Manual keys (variables.yaml)                        │
│     ssh.authorized_keys:                                 │
│       - "ssh-ed25519 AAAA... user@host"                 │
│                                                          │
│  2. GitHub key import (fetched at deploy time)          │
│     ssh.github_users:                                    │
│       - "username"                                       │
│     → curl https://github.com/username.keys             │
│                                                          │
│  3. Local key file fallback                             │
│     ssh.key_path: "~/.ssh/id_ed25519"                   │
│     → Reads ~/.ssh/id_ed25519.pub                       │
└─────────────────────────────────────────────┬───────────┘
                                              │
                                              ▼
                                    ┌──────────────────┐
                                    │  All keys merged  │
                                    │  Deployed to:     │
                                    │  /root/.ssh/      │
                                    │  authorized_keys  │
                                    │  (all nodes)      │
                                    └──────────────────┘
```

### 8.2 SSH Hardening

When `ssh.disable_password_auth: true` is set:

```
/etc/ssh/sshd_config.d/10-k3s-hardening.conf:
  PasswordAuthentication no
  ChallengeResponseAuthentication no
  PubkeyAuthentication yes
  PermitRootLogin prohibit-password
  MaxAuthTries 3
  ClientAliveInterval 300
  ClientAliveCountMax 2
```

### 8.3 Network Security (Firewall Rules)

| Port | Protocol | Direction | Purpose | Nodes |
|------|----------|-----------|---------|-------|
| 6443 | TCP | Inbound | K3s API server | Masters |
| 2379 | TCP | Masters only | etcd client | Masters |
| 2380 | TCP | Masters only | etcd peer | Masters |
| 10250 | TCP | Inbound | Kubelet metrics | All |
| 8472 | UDP | Inbound | VXLAN (Flannel) | All |
| 51820 | UDP | Inbound | WireGuard IPv4 | All |
| 51821 | UDP | Inbound | WireGuard IPv6 | All |
| 8404 | TCP | Inbound | HAProxy stats | Masters |
| 30000-32767 | TCP/UDP | Inbound | NodePort range | Workers |
| VRRP (112) | IP | Masters only | Keepalived | Masters |

---

## 9. Persistent Storage Architecture

### 9.1 Longhorn Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Pod writes data                                             │
│  └──► /dev/longhorn/volume-xyz (block device)               │
│        └──► Longhorn Engine (iSCSI target, same node)       │
│              └──► Synchronous replication                    │
│                    ├──► Replica 1 (worker-01:/var/lib/longhorn/replicas/vol-xyz/)
│                    ├──► Replica 2 (worker-02:/var/lib/longhorn/replicas/vol-xyz/)
│                    └──► Replica 3 (worker-03:/var/lib/longhorn/replicas/vol-xyz/)
│                                                              │
│  All 3 replicas acknowledge ──► Write confirmed to Pod      │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 StorageClass Configuration

**Longhorn StorageClass** (deployed by Helm):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "2880"
```

**Local-Path StorageClass** (K3s built-in):
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
```

---

## 10. Continuous Integration and Quality Assurance

### 10.1 CI Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                GitHub Actions Workflow: lint.yaml             │
│                                                              │
│  Trigger: push to main, pull_request to main                │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ python-lint  │  │  yaml-lint   │  │ config-lint  │      │
│  │              │  │              │  │              │      │
│  │ ruff check . │  │  yamllint    │  │lint_configs.py│     │
│  │ ruff format  │  │  variables   │  │  HAProxy     │      │
│  │  --check .   │  │  configs/k3s │  │  Keepalived  │      │
│  │              │  │  workflows   │  │  DHCP        │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                                                              │
│  ┌──────────────────────────┐  ┌──────────────────────┐     │
│  │   generate-validate      │  │    shell-lint        │     │
│  │                          │  │                      │     │
│  │  python3 generate.py     │  │  shellcheck -x       │     │
│  │    --dry-run             │  │    scripts/*.sh      │     │
│  │  python3 generate.py     │  │                      │     │
│  │  lint generated output   │  │                      │     │
│  │  yamllint generated YAML │  │                      │     │
│  └──────────────────────────┘  └──────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 Lint Tools

| Tool | Target | Rules |
|------|--------|-------|
| **ruff** | Python (.py) | PEP8, isort, bugbear, comprehensions, pathlib, type-checking |
| **yamllint** | YAML (.yaml) | Line length 120, 2-space indent, truthy values |
| **shellcheck** | Shell (.sh) | SC1091 disabled (dynamic source), all other rules |
| **lint_configs.py** | .cfg, .conf | HAProxy sections, Keepalived syntax, DHCP braces/semicolons |

---

## 11. Web-Based Configuration Generator

### 11.1 Architecture

The web UI is a **static single-page application** deployed to GitHub Pages. It runs entirely in the browser — no server-side processing, no data transmission.

```
┌─────────────────────────────────────────────────────────────┐
│                  Browser (Client-Side Only)                   │
│                                                              │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │ HTML Form │──►│  Nunjucks    │──►│  Generated Files  │   │
│  │ (user     │    │  Template    │    │  (preview +       │   │
│  │  input)   │    │  Engine      │    │   download)       │   │
│  └──────────┘    └──────────────┘    └────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │      JSZip         │   │
│                                     │  Archive Generator │   │
│                                     └─────────┬──────────┘   │
│                                               │              │
│                                     ┌─────────▼──────────┐   │
│                                     │    FileSaver.js    │   │
│                                     │  Download Trigger  │   │
│                                     └────────────────────┘   │
│                                               │              │
│                                               ▼              │
│                                     k3s-config-v1.0.0-       │
│                                     20260804-143052.zip      │
└─────────────────────────────────────────────────────────────┘
```

### 11.2 Technology Stack

| Library | Version | Purpose |
|---------|---------|---------|
| Nunjucks | 3.2.4 | Jinja2-compatible template engine (CDN) |
| JSZip | 3.10.1 | ZIP archive generation in browser (CDN) |
| FileSaver.js | 2.0.5 | Triggers file download from Blob (CDN) |
| Pure CSS | - | Custom dark theme, responsive layout |

### 11.3 ZIP Archive Naming

```
k3s-config-v1.0.0-20260804-143052.zip
│           │     │        │
│           │     │        └── Time: HHMMSS
│           │     └── Date: YYYYMMDD
│           └── Application version
└── Fixed prefix
```

---

## 12. Summary

This K3s Baremetal High-Availability Deployment Platform provides a complete, production-ready solution for deploying Kubernetes on physical servers. The key characteristics are:

**Architecture**:
- 3-node control plane with embedded etcd for HA consensus
- HAProxy + Keepalived for API server load balancing and VIP failover
- Tolerates single node failure without service disruption
- Dual-stack networking (IPv4 + IPv6) throughout

**Automation**:
- 7 sequential scripts covering the full deployment lifecycle
- Configuration generation from a single variables file (19+ output files)
- Web-based generator for browser-only operation (no server required)
- GitHub Actions CI for continuous quality assurance

**Storage**:
- Longhorn distributed replicated storage (production-grade, snapshots, backups)
- Local-path provisioner alternative (development/simple workloads)
- 3 disk layout options accommodating different hardware configurations

**Security**:
- SSH key deployment with GitHub key import
- SSHD hardening (password auth disabled, key-only access)
- Firewall configuration with minimal open ports
- TLS certificates covering all access paths (VIP + individual nodes)
- Immutable OS base (transactional-update, read-only root)

**Flexibility**:
- Choice of SLE Micro (commercial) or openSUSE MicroOS (community)
- Choice of Longhorn, local-path, or no storage
- Choice of single-root, multi-partition, or multi-disk layout
- DHCPv4/DHCPv6 support with ISC DHCP, dnsmasq, and Kea configurations
- Configurable via YAML, web UI, or environment variables

**Quality**:
- All code linted (Python, YAML, Shell, config files)
- Template validation on every commit
- Generated output verified by CI pipeline
- Comprehensive documentation (7 guides + this reference)

---

*This document describes version 1.0.0 of the K3s Baremetal HA Deployment Platform. For the latest updates, refer to the [repository](https://github.com/opentreecz/k3s).*
