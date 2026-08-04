#!/bin/bash
# =============================================================================
# K3s Cluster - Environment Configuration
# =============================================================================
# This file is sourced by all other scripts. It loads the inventory
# configuration and provides helper functions.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${PROJECT_DIR}/inventory.conf"

# Pre-generated configuration directory.
# Can be populated by:
#   1. python3 generate.py                        (from variables.yaml)
#   2. Extracting a Web UI ZIP into generated/     (from opentreecz.github.io/k3s)
# Override with: CONFIG_DIR=/path/to/configs ./scripts/01-configure-os.sh
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_DIR}/generated}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# Load inventory file
load_inventory() {
    if [[ ! -f "${INVENTORY_FILE}" ]]; then
        echo "Copy the template and edit it:"
        echo "  cp templates/inventory.example.conf inventory.conf"
        die "Inventory file not found: ${INVENTORY_FILE}"
    fi
    # shellcheck source=/dev/null
    source "${INVENTORY_FILE}"
    log_info "Loaded inventory from ${INVENTORY_FILE}"
}

# Parse a node entry: "hostname ipv4 ipv6 mac"
parse_node() {
    local entry="$1"
    local field="$2"
    case "${field}" in
        hostname) echo "${entry}" | awk '{print $1}' ;;
        ipv4)     echo "${entry}" | awk '{print $2}' ;;
        ipv6)     echo "${entry}" | awk '{print $3}' ;;
        mac)      echo "${entry}" | awk '{print $4}' ;;
        *)        die "Unknown field: ${field}" ;;
    esac
}

# Execute a command on a remote node via SSH
remote_exec() {
    local host="$1"
    shift
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" \
        -p "${SSH_PORT}" \
        "${SSH_USER}@${host}" "$@"
}

# Copy a file to a remote node via SCP
remote_copy() {
    local src="$1"
    local host="$2"
    local dest="$3"
    scp -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "${SSH_KEY_PATH}" \
        -P "${SSH_PORT}" \
        "${src}" "${SSH_USER}@${host}:${dest}"
}

# Wait for a node to become reachable via SSH
wait_for_ssh() {
    local host="$1"
    local timeout="${2:-120}"
    local start_time
    start_time=$(date +%s)

    log_info "Waiting for SSH on ${host}..."
    while true; do
        if ssh -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR \
               -o ConnectTimeout=5 \
               -i "${SSH_KEY_PATH}" \
               -p "${SSH_PORT}" \
               "${SSH_USER}@${host}" "true" 2>/dev/null; then
            log_success "SSH available on ${host}"
            return 0
        fi

        local elapsed=$(( $(date +%s) - start_time ))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_error "Timeout waiting for SSH on ${host} after ${timeout}s"
            return 1
        fi
        sleep 5
    done
}

# Generate K3s token if not provided
ensure_k3s_token() {
    if [[ -z "${K3S_TOKEN:-}" ]]; then
        K3S_TOKEN=$(openssl rand -hex 32)
        log_info "Generated K3s token: ${K3S_TOKEN}"
        log_warn "Save this token! You will need it to add nodes later."
    fi
}

# Check if pre-generated configs are available in CONFIG_DIR.
# Returns 0 (true) if the directory exists and contains at least haproxy.cfg.
use_generated_configs() {
    [[ -d "${CONFIG_DIR}" ]] && [[ -f "${CONFIG_DIR}/haproxy/haproxy.cfg" ]]
}

# Read a file from CONFIG_DIR. Dies if the file does not exist.
load_config_file() {
    local relpath="$1"
    local filepath="${CONFIG_DIR}/${relpath}"
    if [[ ! -f "${filepath}" ]]; then
        die "Generated config file not found: ${filepath}"
    fi
    cat "${filepath}"
}

# Check if a specific generated config file exists.
config_file_exists() {
    local relpath="$1"
    [[ -f "${CONFIG_DIR}/${relpath}" ]]
}

# Generate /etc/hosts content for all nodes
generate_hosts_entries() {
    local entries=""
    entries+="${K3S_VIP_IPV4}   k3s-api.${CLUSTER_DOMAIN} k3s-api\n"

    for node_entry in "${MASTER_NODES[@]}"; do
        local hostname ipv4
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")
        entries+="${ipv4}   ${hostname}.${CLUSTER_DOMAIN} ${hostname}\n"
    done

    for node_entry in "${WORKER_NODES[@]}"; do
        local hostname ipv4
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")
        entries+="${ipv4}   ${hostname}.${CLUSTER_DOMAIN} ${hostname}\n"
    done

    echo -e "${entries}"
}
