#!/bin/bash
# =============================================================================
# K3s Cluster - Join Additional Server Nodes
# =============================================================================
# Joins master-02 and master-03 to the existing K3s cluster.
# The first server must already be running (03-install-k3s-first.sh).
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory

echo "============================================================"
echo " K3s Cluster - Join Additional Server Nodes"
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
    # Try to retrieve from first master
    FIRST_IPV4=$(parse_node "${MASTER_NODES[0]}" "ipv4")
    K3S_TOKEN=$(remote_exec "${FIRST_IPV4}" "cat /var/lib/rancher/k3s/server/token" 2>/dev/null || true)
    if [[ -z "${K3S_TOKEN}" ]]; then
        die "Cannot determine K3s token. Run 03-install-k3s-first.sh first."
    fi
    log_info "Retrieved token from first master"
fi

# First master is the join target
FIRST_IPV4=$(parse_node "${MASTER_NODES[0]}" "ipv4")

# ---------------------------------------------------------------------------
# Build TLS SANs (same as first server)
# ---------------------------------------------------------------------------
TLS_SANS="${K3S_VIP_IPV4},${K3S_VIP_IPV6},k3s-api.${CLUSTER_DOMAIN}"
for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    TLS_SANS+=",${hostname}.${CLUSTER_DOMAIN},${hostname},${ipv4}"
done

# ---------------------------------------------------------------------------
# Join each additional server node (skip first)
# ---------------------------------------------------------------------------
for i in $(seq 1 $(( ${#MASTER_NODES[@]} - 1 ))); do
    node_entry="${MASTER_NODES[$i]}"
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")
    ipv6=$(parse_node "${node_entry}" "ipv6")

    log_info "Joining ${hostname} (${ipv4}) to the cluster..."

    # Create K3s config
    remote_exec "${ipv4}" "mkdir -p /etc/rancher/k3s"

    K3S_CONFIG="server: \"https://${FIRST_IPV4}:${K3S_API_PORT}\"
token: \"${K3S_TOKEN}\"
tls-san:"

    IFS=',' read -ra SAN_ARRAY <<< "${TLS_SANS}"
    for san in "${SAN_ARRAY[@]}"; do
        K3S_CONFIG+="
  - \"${san}\""
    done

    K3S_CONFIG+="
node-ip: \"${ipv4},${ipv6}\"
advertise-address: \"${ipv4}\"
cluster-cidr: \"${K3S_CLUSTER_CIDR},${K3S_CLUSTER_CIDR_V6}\"
service-cidr: \"${K3S_SERVICE_CIDR},${K3S_SERVICE_CIDR_V6}\"
disable:"

    IFS=',' read -ra DISABLE_ARRAY <<< "${K3S_DISABLE}"
    for component in "${DISABLE_ARRAY[@]}"; do
        K3S_CONFIG+="
  - \"${component}\""
    done

    K3S_CONFIG+="
write-kubeconfig-mode: \"0644\"
etcd-expose-metrics: true
kube-apiserver-arg:
  - \"advertise-address=${ipv4}\""

    echo "${K3S_CONFIG}" | remote_exec "${ipv4}" "cat > /etc/rancher/k3s/config.yaml"
    log_success "  Config written to /etc/rancher/k3s/config.yaml"

    # Install K3s
    INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server\" sh -s -"
    if [[ -n "${K3S_VERSION}" ]]; then
        INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"${K3S_VERSION}\" INSTALL_K3S_EXEC=\"server\" sh -s -"
    fi

    remote_exec "${ipv4}" "${INSTALL_CMD}"
    log_success "  K3s installed on ${hostname}"

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
            log_error "  Check: ssh root@${ipv4} 'journalctl -u k3s -f'"
            break
        fi
        sleep 5
    done

    log_success "  ${hostname} joined the cluster"
    echo ""
done

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
log_info "Cluster status:"
remote_exec "${FIRST_IPV4}" "kubectl get nodes -o wide"
echo ""

# Check etcd members
log_info "etcd cluster members:"
remote_exec "${FIRST_IPV4}" "
    kubectl -n kube-system get pods -l component=etcd -o name 2>/dev/null | head -1 | \
    xargs -I{} kubectl -n kube-system exec {} -- \
        etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
        --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
        --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
        member list -w table 2>/dev/null
" 2>/dev/null || log_warn "Could not query etcd members (pods may still be starting)"

echo ""
echo "============================================================"
log_success "All server nodes joined the cluster!"
echo ""
echo "  Verify API via VIP: curl -k https://${K3S_VIP_IPV4}:${HAPROXY_FRONTEND_PORT}/version"
echo ""
echo "  Next: Run ./scripts/05-install-k3s-agents.sh to add worker nodes."
echo "============================================================"
