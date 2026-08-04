#!/bin/bash
# =============================================================================
# K3s Cluster - Bootstrap First Server Node
# =============================================================================
# Initializes the K3s cluster by installing K3s on the first master node
# with --cluster-init (embedded etcd).
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory
ensure_k3s_token

echo "============================================================"
echo " K3s Cluster - Bootstrap First Server (cluster-init)"
echo "============================================================"
echo ""

# First master node
FIRST_NODE="${MASTER_NODES[0]}"
FIRST_HOSTNAME=$(parse_node "${FIRST_NODE}" "hostname")
FIRST_IPV4=$(parse_node "${FIRST_NODE}" "ipv4")
FIRST_IPV6=$(parse_node "${FIRST_NODE}" "ipv6")

log_info "Bootstrapping K3s on ${FIRST_HOSTNAME} (${FIRST_IPV4})..."
echo ""

# ---------------------------------------------------------------------------
# Create K3s config file on first server
# ---------------------------------------------------------------------------
log_info "Deploying K3s server configuration..."

remote_exec "${FIRST_IPV4}" "mkdir -p /etc/rancher/k3s"

if use_generated_configs && config_file_exists "k3s/${FIRST_HOSTNAME}/config.yaml"; then
    log_info "  Using pre-generated config from ${CONFIG_DIR}/k3s/${FIRST_HOSTNAME}/config.yaml"
    K3S_CONFIG=$(load_config_file "k3s/${FIRST_HOSTNAME}/config.yaml")
    echo "${K3S_CONFIG}" | remote_exec "${FIRST_IPV4}" "cat > /etc/rancher/k3s/config.yaml"
else
    log_info "  Generating K3s config inline from inventory..."
    # Build TLS SANs
    TLS_SANS="${K3S_VIP_IPV4},${K3S_VIP_IPV6},k3s-api.${CLUSTER_DOMAIN}"
    for node_entry in "${MASTER_NODES[@]}"; do
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")
        TLS_SANS+=",${hostname}.${CLUSTER_DOMAIN},${hostname},${ipv4}"
    done

    # Build config.yaml
    K3S_CONFIG="cluster-init: true
token: \"${K3S_TOKEN}\"
tls-san:"

    # Add all TLS SANs
    IFS=',' read -ra SAN_ARRAY <<< "${TLS_SANS}"
    for san in "${SAN_ARRAY[@]}"; do
        K3S_CONFIG+="
  - \"${san}\""
    done

    K3S_CONFIG+="
node-ip: \"${FIRST_IPV4},${FIRST_IPV6}\"
advertise-address: \"${FIRST_IPV4}\"
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
  - \"advertise-address=${FIRST_IPV4}\""

    echo "${K3S_CONFIG}" | remote_exec "${FIRST_IPV4}" "cat > /etc/rancher/k3s/config.yaml"
fi
log_success "  Config written to /etc/rancher/k3s/config.yaml"

# ---------------------------------------------------------------------------
# Install K3s
# ---------------------------------------------------------------------------
log_info "Installing K3s on ${FIRST_HOSTNAME}..."

INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"server\" sh -s -"
if [[ -n "${K3S_VERSION}" ]]; then
    INSTALL_CMD="curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=\"${K3S_VERSION}\" INSTALL_K3S_EXEC=\"server\" sh -s -"
fi

remote_exec "${FIRST_IPV4}" "${INSTALL_CMD}"
log_success "  K3s installed"

# ---------------------------------------------------------------------------
# Wait for K3s to be ready
# ---------------------------------------------------------------------------
log_info "Waiting for K3s to be ready..."

TIMEOUT=120
START_TIME=$(date +%s)
while true; do
    if remote_exec "${FIRST_IPV4}" "kubectl get nodes 2>/dev/null | grep -q 'Ready'" 2>/dev/null; then
        break
    fi

    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
        die "Timeout waiting for K3s to become ready on ${FIRST_HOSTNAME}"
    fi
    sleep 5
done

log_success "  K3s is ready on ${FIRST_HOSTNAME}"

# ---------------------------------------------------------------------------
# Display status
# ---------------------------------------------------------------------------
echo ""
log_info "Cluster status:"
remote_exec "${FIRST_IPV4}" "kubectl get nodes -o wide"
echo ""

# Store the node-token for other nodes
NODE_TOKEN=$(remote_exec "${FIRST_IPV4}" "cat /var/lib/rancher/k3s/server/node-token")
log_info "Node token: ${NODE_TOKEN}"
echo ""

# ---------------------------------------------------------------------------
# Save token to local file for subsequent scripts
# ---------------------------------------------------------------------------
TOKEN_FILE="${PROJECT_DIR}/.k3s-token"
echo "${K3S_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
log_info "Token saved to ${TOKEN_FILE}"

echo ""
echo "============================================================"
log_success "First K3s server bootstrapped successfully!"
echo ""
echo "  Node: ${FIRST_HOSTNAME} (${FIRST_IPV4})"
echo "  Token file: ${TOKEN_FILE}"
echo ""
echo "  Next: Run ./scripts/04-install-k3s-servers.sh to join"
echo "        remaining server nodes."
echo "============================================================"
