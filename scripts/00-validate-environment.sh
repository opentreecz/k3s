#!/bin/bash
# =============================================================================
# K3s Cluster - Pre-flight Validation
# =============================================================================
# Validates the environment before deployment:
# - Checks inventory file
# - Verifies SSH connectivity to all nodes
# - Validates DHCP leases (correct IPs)
# - Checks required tools on deployment host
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory

echo "============================================================"
echo " K3s Cluster - Pre-flight Validation"
echo "============================================================"
echo ""

ERRORS=0

# ---------------------------------------------------------------------------
# Check local dependencies
# ---------------------------------------------------------------------------
log_info "Checking local tools..."

for tool in ssh scp curl openssl; do
    if command -v "${tool}" &>/dev/null; then
        log_success "  ${tool} found"
    else
        log_error "  ${tool} NOT found"
        ((ERRORS++))
    fi
done

# ---------------------------------------------------------------------------
# Check SSH key
# ---------------------------------------------------------------------------
log_info "Checking SSH key..."
if [[ -f "${SSH_KEY_PATH}" ]]; then
    log_success "  SSH key exists: ${SSH_KEY_PATH}"
else
    log_error "  SSH key NOT found: ${SSH_KEY_PATH}"
    ((ERRORS++))
fi

# ---------------------------------------------------------------------------
# Check SSH connectivity to all nodes
# ---------------------------------------------------------------------------
log_info "Checking SSH connectivity to master nodes..."

for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")

    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -o ConnectTimeout=10 \
           -i "${SSH_KEY_PATH}" \
           -p "${SSH_PORT}" \
           "${SSH_USER}@${ipv4}" "true" 2>/dev/null; then
        log_success "  ${hostname} (${ipv4}) - reachable"
    else
        log_error "  ${hostname} (${ipv4}) - NOT reachable"
        ((ERRORS++))
    fi
done

log_info "Checking SSH connectivity to worker nodes..."

for node_entry in "${WORKER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")

    if ssh -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -o ConnectTimeout=10 \
           -i "${SSH_KEY_PATH}" \
           -p "${SSH_PORT}" \
           "${SSH_USER}@${ipv4}" "true" 2>/dev/null; then
        log_success "  ${hostname} (${ipv4}) - reachable"
    else
        log_error "  ${hostname} (${ipv4}) - NOT reachable"
        ((ERRORS++))
    fi
done

# ---------------------------------------------------------------------------
# Validate IP addresses match DHCP leases
# ---------------------------------------------------------------------------
log_info "Validating IP addresses on nodes..."

for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")

    actual_ip=$(ssh -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    -o ConnectTimeout=10 \
                    -i "${SSH_KEY_PATH}" \
                    -p "${SSH_PORT}" \
                    "${SSH_USER}@${ipv4}" \
                    "ip -4 addr show ${NETWORK_INTERFACE} | grep -oP '(?<=inet\s)\d+(\.\d+){3}'" 2>/dev/null || echo "UNREACHABLE")

    if [[ "${actual_ip}" == "${ipv4}" ]]; then
        log_success "  ${hostname}: IP ${ipv4} confirmed on ${NETWORK_INTERFACE}"
    elif [[ "${actual_ip}" == "UNREACHABLE" ]]; then
        log_warn "  ${hostname}: Could not verify IP (node unreachable)"
    else
        log_error "  ${hostname}: Expected ${ipv4}, got ${actual_ip} on ${NETWORK_INTERFACE}"
        ((ERRORS++))
    fi
done

# ---------------------------------------------------------------------------
# Check OS on nodes
# ---------------------------------------------------------------------------
log_info "Checking OS distribution on master nodes..."

for node_entry in "${MASTER_NODES[@]}"; do
    hostname=$(parse_node "${node_entry}" "hostname")
    ipv4=$(parse_node "${node_entry}" "ipv4")

    os_id=$(remote_exec "${ipv4}" "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo "UNKNOWN")
    log_info "  ${hostname}: OS=${os_id}"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
if [[ ${ERRORS} -eq 0 ]]; then
    log_success "All pre-flight checks passed! Ready to deploy."
    echo "============================================================"
    exit 0
else
    log_error "${ERRORS} error(s) found. Fix the issues above before proceeding."
    echo "============================================================"
    exit 1
fi
