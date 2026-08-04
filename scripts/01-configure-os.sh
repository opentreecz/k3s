#!/bin/bash
# =============================================================================
# K3s Cluster - OS Configuration
# =============================================================================
# Configures all cluster nodes after OS installation:
# - Sets hostnames
# - Configures /etc/hosts
# - Sets kernel parameters
# - Loads kernel modules
# - Configures firewall
# - Installs required packages
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory

echo "============================================================"
echo " K3s Cluster - OS Configuration"
echo "============================================================"
echo ""

# Generate hosts entries
HOSTS_ENTRIES=$(generate_hosts_entries)

# ---------------------------------------------------------------------------
# Configure a single node
# ---------------------------------------------------------------------------
configure_node() {
    local hostname="$1"
    local ipv4="$2"
    local role="$3"  # "master" or "worker"

    log_info "Configuring ${hostname} (${ipv4}) as ${role}..."

    # Set hostname
    remote_exec "${ipv4}" "hostnamectl set-hostname ${hostname}.${CLUSTER_DOMAIN}"
    log_success "  Hostname set to ${hostname}.${CLUSTER_DOMAIN}"

    # Configure /etc/hosts
    remote_exec "${ipv4}" "
        # Remove any previous K3s entries
        sed -i '/# K3s Cluster/,/# End K3s Cluster/d' /etc/hosts
        # Add new entries
        echo '# K3s Cluster' >> /etc/hosts
        echo '${HOSTS_ENTRIES}' >> /etc/hosts
        echo '# End K3s Cluster' >> /etc/hosts
    "
    log_success "  /etc/hosts configured"

    # Kernel parameters
    remote_exec "${ipv4}" "
        cat > /etc/sysctl.d/90-k3s.conf << 'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.${NETWORK_INTERFACE}.accept_ra = 2
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_instances = 524288
fs.inotify.max_user_watches = 524288
net.netfilter.nf_conntrack_max = 131072
SYSCTL
        sysctl --system >/dev/null 2>&1
    "
    log_success "  Kernel parameters configured"

    # Kernel modules
    remote_exec "${ipv4}" "
        cat > /etc/modules-load.d/k3s.conf << 'MODULES'
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
MODULES
        for mod in br_netfilter overlay ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
            modprobe \${mod} 2>/dev/null || true
        done
    "
    log_success "  Kernel modules loaded"

    # File limits
    remote_exec "${ipv4}" "
        cat > /etc/security/limits.d/90-k3s.conf << 'LIMITS'
* soft nofile 65536
* hard nofile 65536
* soft nproc 65536
* hard nproc 65536
LIMITS
    "
    log_success "  File limits configured"

    # Firewall configuration
    if remote_exec "${ipv4}" "systemctl is-active firewalld" &>/dev/null; then
        if [[ "${role}" == "master" ]]; then
            remote_exec "${ipv4}" "
                firewall-cmd --permanent --add-port=6443/tcp >/dev/null
                firewall-cmd --permanent --add-port=2379/tcp >/dev/null
                firewall-cmd --permanent --add-port=2380/tcp >/dev/null
                firewall-cmd --permanent --add-port=10250/tcp >/dev/null
                firewall-cmd --permanent --add-port=8472/udp >/dev/null
                firewall-cmd --permanent --add-port=51820/udp >/dev/null
                firewall-cmd --permanent --add-port=51821/udp >/dev/null
                firewall-cmd --permanent --add-port=5001/tcp >/dev/null
                firewall-cmd --permanent --add-port=8404/tcp >/dev/null
                firewall-cmd --permanent --add-rich-rule='rule protocol value=\"vrrp\" accept' >/dev/null
                firewall-cmd --reload >/dev/null
            "
        else
            remote_exec "${ipv4}" "
                firewall-cmd --permanent --add-port=10250/tcp >/dev/null
                firewall-cmd --permanent --add-port=8472/udp >/dev/null
                firewall-cmd --permanent --add-port=51820/udp >/dev/null
                firewall-cmd --permanent --add-port=51821/udp >/dev/null
                firewall-cmd --permanent --add-port=30000-32767/tcp >/dev/null
                firewall-cmd --permanent --add-port=30000-32767/udp >/dev/null
                firewall-cmd --reload >/dev/null
            "
        fi
        log_success "  Firewall configured"
    else
        log_warn "  Firewall (firewalld) not active, skipping"
    fi

    # Install required packages via transactional-update
    # Note: This requires a reboot to take effect
    remote_exec "${ipv4}" "
        # Check if packages are already installed
        if ! rpm -q open-iscsi &>/dev/null; then
            transactional-update --non-interactive pkg install open-iscsi nfs-client cryptsetup apparmor-parser 2>/dev/null || true
            echo 'REBOOT_NEEDED=true'
        else
            echo 'REBOOT_NEEDED=false'
        fi
    "
    log_success "  Packages checked/installed"

    # HAProxy non-local bind (master nodes only)
    if [[ "${role}" == "master" ]]; then
        remote_exec "${ipv4}" "
            cat > /etc/sysctl.d/90-haproxy.conf << 'HAPROXY'
net.ipv4.ip_nonlocal_bind = 1
net.ipv6.ip_nonlocal_bind = 1
HAPROXY
            sysctl --system >/dev/null 2>&1
        "
        log_success "  Non-local bind enabled (for HAProxy)"
    fi

    log_success "Configuration complete for ${hostname}"
    echo ""
}

# ---------------------------------------------------------------------------
# Configure all master nodes
# ---------------------------------------------------------------------------
log_info "Configuring master nodes..."
echo ""

for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    configure_node "${hostname}" "${ipv4}" "master"
done

# ---------------------------------------------------------------------------
# Configure all worker nodes
# ---------------------------------------------------------------------------
log_info "Configuring worker nodes..."
echo ""

for node_entry in "${WORKER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    configure_node "${hostname}" "${ipv4}" "worker"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================================"
log_success "OS configuration complete for all nodes."
log_warn "If packages were installed, nodes will need a reboot:"
echo "  For each node that needs it, run:"
echo "    ssh root@<node-ip> 'transactional-update reboot'"
echo "============================================================"
