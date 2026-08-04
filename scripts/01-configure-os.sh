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
# Deploy SSH keys to a single node
# ---------------------------------------------------------------------------
deploy_ssh_keys() {
    local hostname="$1"
    local ipv4="$2"

    log_info "Deploying SSH keys to ${hostname} (${ipv4})..."

    # Deploy authorized_keys
    if [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]]; then
        remote_exec "${ipv4}" "
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            cat > /root/.ssh/authorized_keys << 'AUTHKEYS'
${SSH_AUTHORIZED_KEYS}
AUTHKEYS
            chmod 600 /root/.ssh/authorized_keys
        "
        log_success "  SSH authorized_keys deployed"
    elif [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        # Fallback: use the public key file from ssh.key_path
        local pubkey
        pubkey=$(cat "${SSH_KEY_PATH}.pub")
        remote_exec "${ipv4}" "
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            echo '${pubkey}' >> /root/.ssh/authorized_keys
            sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
        "
        log_success "  SSH public key deployed from ${SSH_KEY_PATH}.pub"
    else
        log_warn "  No SSH keys configured. Skipping key deployment."
        return
    fi

    # Harden SSH configuration
    if [[ "${SSH_DISABLE_PASSWORD_AUTH:-false}" == "true" ]]; then
        remote_exec "${ipv4}" "
            mkdir -p /etc/ssh/sshd_config.d
            cat > /etc/ssh/sshd_config.d/10-k3s-hardening.conf << 'SSHD'
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHD
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        "
        log_success "  SSH hardened (password auth disabled)"
    fi
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
# Deploy SSH keys to all nodes
# ---------------------------------------------------------------------------
log_info "Deploying SSH keys..."
echo ""

# Build SSH_AUTHORIZED_KEYS from inventory if defined
if [[ -z "${SSH_AUTHORIZED_KEYS:-}" ]]; then
    # Try reading from SSH_KEY_PATH.pub as fallback
    if [[ -f "${SSH_KEY_PATH}.pub" ]]; then
        SSH_AUTHORIZED_KEYS=$(cat "${SSH_KEY_PATH}.pub")
    fi
fi

# Fetch SSH keys from GitHub users if configured
if [[ -n "${SSH_GITHUB_USERS:-}" ]]; then
    log_info "Fetching SSH keys from GitHub..."
    for github_user in ${SSH_GITHUB_USERS}; do
        if [[ -z "${github_user}" ]]; then
            continue
        fi
        log_info "  Fetching keys for github.com/${github_user}..."
        github_keys=$(curl -sfL "https://github.com/${github_user}.keys" 2>/dev/null || echo "")
        if [[ -n "${github_keys}" ]]; then
            SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-}
${github_keys}"
            log_success "  Fetched $(echo "${github_keys}" | wc -l) key(s) for ${github_user}"
        else
            log_warn "  No keys found for ${github_user} (or user does not exist)"
        fi
    done
    echo ""
fi

# Default for disable password auth
SSH_DISABLE_PASSWORD_AUTH="${SSH_DISABLE_PASSWORD_AUTH:-false}"

for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    deploy_ssh_keys "${hostname}" "${ipv4}"
done

for node_entry in "${WORKER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    deploy_ssh_keys "${hostname}" "${ipv4}"
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
