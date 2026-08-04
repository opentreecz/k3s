# Operating System Configuration

Post-installation configuration for all nodes before K3s deployment.

## Prerequisites

- OS installed (SLE Micro or openSUSE MicroOS)
- SSH access to all nodes
- DHCP leases active (nodes have their expected IPs)
- Inventory file configured (`inventory.conf`)

## Automated Configuration

Run the OS configuration script from the deployment host:

```bash
./scripts/01-configure-os.sh
```

This script performs all steps described below automatically.

## Manual Configuration Steps

### 1. Set Hostname

Each node must have a unique, resolvable hostname:

```bash
# On each node
hostnamectl set-hostname master-01.k3s.local
```

### 2. Configure /etc/hosts

Add all cluster nodes to `/etc/hosts` for local resolution:

```
# K3s Cluster Nodes
192.168.1.100   k3s-api.k3s.local k3s-api
192.168.1.101   master-01.k3s.local master-01
192.168.1.102   master-02.k3s.local master-02
192.168.1.103   master-03.k3s.local master-03
192.168.1.111   worker-01.k3s.local worker-01
192.168.1.112   worker-02.k3s.local worker-02
192.168.1.113   worker-03.k3s.local worker-03
```

### 3. Configure Timezone and NTP

```bash
timedatectl set-timezone Europe/Berlin
# NTP is configured via systemd-timesyncd or chrony
```

### 4. Kernel Parameters

Required kernel parameters for K3s and container networking:

```bash
# Create sysctl configuration
cat > /etc/sysctl.d/90-k3s.conf << 'EOF'
# IPv4 forwarding
net.ipv4.ip_forward = 1

# IPv6 forwarding
net.ipv6.conf.all.forwarding = 1

# Bridge networking
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Increase inotify limits
fs.inotify.max_user_instances = 524288
fs.inotify.max_user_watches = 524288

# Increase conntrack table size
net.netfilter.nf_conntrack_max = 131072
EOF

sysctl --system
```

### 5. Load Required Kernel Modules

```bash
cat > /etc/modules-load.d/k3s.conf << 'EOF'
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

# Load immediately
for mod in br_netfilter overlay ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe $mod
done
```

### 6. Disable Swap (if enabled)

K3s does not require swap to be disabled (unlike kubeadm), but it is recommended:

```bash
# Check if swap is active
swapon --show

# Disable swap
swapoff -a
# Remove swap entries from /etc/fstab if present
```

### 7. Firewall Configuration

#### Using firewalld (default on SLE Micro / MicroOS)

```bash
# On master nodes
firewall-cmd --permanent --add-port=6443/tcp    # K3s API
firewall-cmd --permanent --add-port=2379/tcp    # etcd client
firewall-cmd --permanent --add-port=2380/tcp    # etcd peer
firewall-cmd --permanent --add-port=10250/tcp   # Kubelet
firewall-cmd --permanent --add-port=8472/udp    # VXLAN (Flannel)
firewall-cmd --permanent --add-port=51820/udp   # WireGuard (IPv4)
firewall-cmd --permanent --add-port=51821/udp   # WireGuard (IPv6)
firewall-cmd --permanent --add-port=5001/tcp    # Embedded registry
firewall-cmd --permanent --add-port=8404/tcp    # HAProxy stats

# On worker nodes
firewall-cmd --permanent --add-port=10250/tcp   # Kubelet
firewall-cmd --permanent --add-port=8472/udp    # VXLAN (Flannel)
firewall-cmd --permanent --add-port=51820/udp   # WireGuard (IPv4)
firewall-cmd --permanent --add-port=51821/udp   # WireGuard (IPv6)
firewall-cmd --permanent --add-port=30000-32767/tcp  # NodePort range
firewall-cmd --permanent --add-port=30000-32767/udp  # NodePort range

firewall-cmd --reload
```

#### Alternative: Disable firewalld

For lab environments, you may choose to disable the firewall entirely:

```bash
systemctl disable --now firewalld
```

### 8. Configure Open File Limits

```bash
cat > /etc/security/limits.d/90-k3s.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
EOF
```

### 9. Install Required Packages

#### SLE Micro

```bash
transactional-update pkg install \
    open-iscsi \
    nfs-client \
    cryptsetup \
    apparmor-parser
transactional-update reboot
```

#### openSUSE MicroOS

```bash
transactional-update pkg install \
    open-iscsi \
    nfs-client \
    cryptsetup \
    apparmor-parser
transactional-update reboot
```

### 10. Enable iSCSI (for Longhorn storage, if used)

```bash
systemctl enable --now iscsid
```

### 11. SSH Key Distribution

Ensure passwordless SSH between deployment host and all nodes:

```bash
# From deployment host
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@master-01
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@master-02
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@master-03
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@worker-01
# ... for all nodes
```

## Transactional Updates Note

Both SLE Micro and openSUSE MicroOS use **transactional-update** for system modifications. Changes take effect after reboot:

```bash
# Apply pending updates
transactional-update run <command>

# Apply package installs
transactional-update pkg install <package>

# Reboot into new snapshot
transactional-update reboot
```

## Verification

After configuration, verify each node:

```bash
# Check kernel parameters
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

# Check modules
lsmod | grep br_netfilter
lsmod | grep overlay

# Check hostname
hostnamectl

# Check connectivity to other nodes
ping -c1 master-01
ping -c1 master-02
ping -c1 master-03
```

## Next Steps

Proceed to [03 - Network Planning](03-network-planning.md) to configure DHCP static leases.
