#!/bin/bash
# =============================================================================
# K3s Cluster - Install K3s Agents (Worker Nodes)
# =============================================================================
# Joins all worker nodes to the K3s cluster as agents.
# Workers connect via the HAProxy VIP for high availability.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory

echo "============================================================"
echo " K3s Cluster - Install K3s Agents (Workers)"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Load or retrieve token
# ---------------------------------------------------------------------------
TOKEN_FILE="${PROJECT_DIR}/.k3s-token"
if [[ -f "${TOKEN_FILE}" ]]; then
    K3S_TOKEN=$(cat "${TOKEN_FILE}")
    log_info "Loaded token from ${TOKEN_FILE}"
elif [[ -n "${K3S_TOKEN:-}" ]]; then
    log_info "Using token from inventory"
else
    FIRST_IPV4=$(parse_node "${MASTER_NODES[0]}" "ipv4")
    K3S_TOKEN=$(remote_exec "${FIRST_IPV4}" "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null || true)
    if [[ -z "${K3S_TOKEN}" ]]; then
        die "Cannot determine K3s token. Ensure the cluster is running."
    fi
    log_info "Retrieved node-token from first master"
fi

# Verify API is accessible via VIP
log_info "Verifying K3s API via VIP (${K3S_VIP_IPV4}:${HAPROXY_FRONTEND_PORT})..."
if curl -sk --connect-timeout 10 "https://${K3S_VIP_IPV4}:${HAPROXY_FRONTEND_PORT}/version" &>/dev/null; then
    log_success "  K3s API reachable via VIP"
else
    die "K3s API NOT reachable via VIP ${K3S_VIP_IPV4}:${HAPROXY_FRONTEND_PORT}. Check HAProxy."
fi
echo ""

# ---------------------------------------------------------------------------
# Install K3s agent on each worker
# ---------------------------------------------------------------------------
FIRST_IPV4=$(parse_node "${MASTER_NODES[0]}" "ipv4")

for node_entry in "${WORKER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    ipv6=$(parse_node "${node_entry}" "ipv6")

    log_info "Installing K3s agent on ${hostname} (${ipv4})..."

    # Create K3s agent config
    remote_exec "${ipv4}" "mkdir -p /etc/rancher/k3s"

    if use_generated_configs && config_file_exists "k3s/${hostname}/config.yaml"; then
        log_info "  Using pre-generated config from ${CONFIG_DIR}/k3s/${hostname}/config.yaml"
        AGENT_CONFIG=$(load_config_file "k3s/${hostname}/config.yaml")
    else
        log_info "  Generating agent config inline from inventory..."
        AGENT_CONFIG="server: \"https://${K3S_VIP_IPV4}:${HAPROXY_FRONTEND_PORT}\"
token: \"${K3S_TOKEN}\"
node-ip: \"${ipv4},${ipv6}\"
node-label:
  - \"node-role.kubernetes.io/worker=worker\""
    fi

    echo "${AGENT_CONFIG}" | remote_exec "${ipv4}" "cat > /etc/rancher/k3s/config.yaml"
    log_success "  Agent config deployed"

    # Install K3s agent
    INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"agent\" sh -s -"
    if [[ -n "${K3S_VERSION}" ]]; then
        INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"${K3S_VERSION}\" INSTALL_K3S_EXEC=\"agent\" sh -s -"
    fi

    remote_exec "${ipv4}" "${INSTALL_CMD}"
    log_success "  K3s agent installed"

    # Wait for node to join
    log_info "  Waiting for ${hostname} to become Ready..."
    TIMEOUT=120
    START_TIME=$(date +%s)
    while true; do
        if remote_exec "${FIRST_IPV4}" "kubectl get nodes 2>/dev/null | grep '${hostname}' | grep -q 'Ready'" 2>/dev/null; then
            break
        fi

        ELAPSED=$(( $(date +%s) - START_TIME ))
        if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
            log_error "  Timeout waiting for ${hostname} to become Ready"
            log_error "  Check: ssh root@${ipv4} 'journalctl -u k3s-agent -f'"
            break
        fi
        sleep 5
    done

    log_success "  ${hostname} joined as worker"
    echo ""
done

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
log_info "Final cluster status:"
remote_exec "${FIRST_IPV4}" "kubectl get nodes -o wide"
echo ""

echo "============================================================"
log_success "All worker nodes joined the cluster!"
echo ""
echo "  Cluster is ready for workloads."
echo ""
echo "  Get kubeconfig:"
echo "    scp root@${FIRST_IPV4}:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
echo "    sed -i 's|127.0.0.1|${K3S_VIP_IPV4}|g' ~/.kube/config"
echo "============================================================"
