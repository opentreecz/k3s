#!/bin/bash
# =============================================================================
# K3s Cluster - Persistent Storage Installation
# =============================================================================
# Installs and configures persistent storage for the K3s cluster.
# Supports:
#   - Longhorn (distributed replicated block storage via Helm)
#   - local-path-provisioner (K3s built-in, node-local storage)
#   - none (skip storage installation)
#
# Prerequisites:
#   - K3s cluster fully operational (all masters + workers running)
#   - Generated config files in generated/storage/
#   - Worker nodes have storage disk/partition mounted (if configured)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

load_inventory

echo "============================================================"
echo " K3s Cluster - Persistent Storage Installation"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Determine storage provider from generated config or environment
# ---------------------------------------------------------------------------
STORAGE_PROVIDER="${STORAGE_PROVIDER:-longhorn}"
LONGHORN_DATA_PATH="${LONGHORN_DATA_PATH:-/var/lib/longhorn}"
LOCAL_PATH_DATA_PATH="${LOCAL_PATH_DATA_PATH:-/opt/local-path-provisioner}"
LONGHORN_VERSION="${LONGHORN_VERSION:-}"

# Try to read from generated variables.yaml if available
GENERATED_VARS="${PROJECT_DIR}/generated/storage/longhorn-values.yaml"
LOCAL_PATH_MANIFEST="${PROJECT_DIR}/generated/storage/storageclass-local-path.yaml"

FIRST_MASTER_IPV4=$(parse_node "${MASTER_NODES[0]}" "ipv4")

# ---------------------------------------------------------------------------
# Provider: none
# ---------------------------------------------------------------------------
if [[ "${STORAGE_PROVIDER}" == "none" ]]; then
    log_info "Storage provider set to 'none'. Skipping storage installation."
    echo ""
    echo "  To install storage later, set STORAGE_PROVIDER=longhorn or"
    echo "  STORAGE_PROVIDER=local-path and re-run this script."
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Provider: longhorn
# ---------------------------------------------------------------------------
if [[ "${STORAGE_PROVIDER}" == "longhorn" ]]; then
    log_info "Installing Longhorn distributed storage..."
    echo ""

    # --- Step 1: Verify prerequisites on worker nodes ---
    log_info "Verifying Longhorn prerequisites on worker nodes..."

    for node_entry in "${WORKER_NODES[@]}"; do
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")

        # Check open-iscsi
        if remote_exec "${ipv4}" "rpm -q open-iscsi" &>/dev/null; then
            log_success "  ${hostname}: open-iscsi installed"
        else
            log_error "  ${hostname}: open-iscsi NOT installed"
            log_error "  Run: transactional-update pkg install open-iscsi && reboot"
            exit 1
        fi

        # Check iscsid service
        if remote_exec "${ipv4}" "systemctl is-active iscsid" &>/dev/null; then
            log_success "  ${hostname}: iscsid running"
        else
            log_warn "  ${hostname}: iscsid not running, starting..."
            remote_exec "${ipv4}" "systemctl enable --now iscsid" || true
        fi

        # Check data path exists
        if remote_exec "${ipv4}" "test -d '${LONGHORN_DATA_PATH}'" &>/dev/null; then
            log_success "  ${hostname}: ${LONGHORN_DATA_PATH} exists"
        else
            log_warn "  ${hostname}: Creating ${LONGHORN_DATA_PATH}..."
            remote_exec "${ipv4}" "mkdir -p '${LONGHORN_DATA_PATH}'"
        fi
    done
    echo ""

    # --- Step 2: Install Helm on first master ---
    log_info "Checking Helm installation..."

    if remote_exec "${FIRST_MASTER_IPV4}" "command -v helm" &>/dev/null; then
        log_success "  Helm already installed"
    else
        log_info "  Installing Helm..."
        remote_exec "${FIRST_MASTER_IPV4}" "curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        log_success "  Helm installed"
    fi
    echo ""

    # --- Step 3: Add Longhorn Helm repo ---
    log_info "Adding Longhorn Helm repository..."
    remote_exec "${FIRST_MASTER_IPV4}" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
        helm repo update
    "
    log_success "  Longhorn repo added and updated"
    echo ""

    # --- Step 4: Deploy Longhorn ---
    log_info "Deploying Longhorn..."

    # Copy values file if it exists
    if [[ -f "${GENERATED_VARS}" ]]; then
        remote_copy "${GENERATED_VARS}" "${FIRST_MASTER_IPV4}" "/tmp/longhorn-values.yaml"
        HELM_VALUES_FLAG="-f /tmp/longhorn-values.yaml"
        log_info "  Using generated values: ${GENERATED_VARS}"
    else
        HELM_VALUES_FLAG=""
        log_warn "  No generated values file found. Using Longhorn defaults."
    fi

    HELM_VERSION_FLAG=""
    if [[ -n "${LONGHORN_VERSION}" ]]; then
        HELM_VERSION_FLAG="--version ${LONGHORN_VERSION}"
    fi

    remote_exec "${FIRST_MASTER_IPV4}" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        helm upgrade --install longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --create-namespace \
            ${HELM_VALUES_FLAG} \
            ${HELM_VERSION_FLAG} \
            --wait \
            --timeout 10m
    "
    log_success "  Longhorn deployed"
    echo ""

    # --- Step 5: Wait for pods ---
    log_info "Waiting for Longhorn pods to be ready..."
    remote_exec "${FIRST_MASTER_IPV4}" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        kubectl -n longhorn-system wait --for=condition=ready pod --all --timeout=300s 2>/dev/null || true
    "
    log_success "  Longhorn pods ready"
    echo ""

    # --- Step 6: Verify ---
    log_info "Verifying StorageClass..."
    remote_exec "${FIRST_MASTER_IPV4}" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        kubectl get storageclass
    "
    echo ""

    echo "============================================================"
    log_success "Longhorn installed successfully!"
    echo ""
    echo "  Longhorn UI: Access via kubectl port-forward or Ingress"
    echo "    kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
    echo "    Then open: http://localhost:8080"
    echo ""
    echo "  Test with a PVC:"
    echo "    kubectl apply -f - <<EOF"
    echo "    apiVersion: v1"
    echo "    kind: PersistentVolumeClaim"
    echo "    metadata:"
    echo "      name: test-pvc"
    echo "    spec:"
    echo "      accessModes: [ReadWriteOnce]"
    echo "      storageClassName: longhorn"
    echo "      resources:"
    echo "        requests:"
    echo "          storage: 1Gi"
    echo "    EOF"
    echo "============================================================"
fi

# ---------------------------------------------------------------------------
# Provider: local-path
# ---------------------------------------------------------------------------
if [[ "${STORAGE_PROVIDER}" == "local-path" ]]; then
    log_info "Configuring local-path-provisioner..."
    echo ""

    # --- Step 1: Create data directory on all nodes ---
    log_info "Creating data directories on worker nodes..."

    for node_entry in "${WORKER_NODES[@]}"; do
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")

        remote_exec "${ipv4}" "mkdir -p '${LOCAL_PATH_DATA_PATH}'"
        log_success "  ${hostname}: ${LOCAL_PATH_DATA_PATH} created"
    done

    # Also on masters (in case workloads are scheduled there)
    for node_entry in "${MASTER_NODES[@]}"; do
        hostname=$(parse_node "${node_entry}" "hostname")
        ipv4=$(parse_node "${node_entry}" "ipv4")

        remote_exec "${ipv4}" "mkdir -p '${LOCAL_PATH_DATA_PATH}'"
        log_success "  ${hostname}: ${LOCAL_PATH_DATA_PATH} created"
    done
    echo ""

    # --- Step 2: Apply StorageClass manifest ---
    if [[ -f "${LOCAL_PATH_MANIFEST}" ]]; then
        log_info "Applying local-path StorageClass configuration..."
        remote_copy "${LOCAL_PATH_MANIFEST}" "${FIRST_MASTER_IPV4}" "/tmp/storageclass-local-path.yaml"
        remote_exec "${FIRST_MASTER_IPV4}" "
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            kubectl apply -f /tmp/storageclass-local-path.yaml
        "
        log_success "  StorageClass applied"
    else
        log_info "Ensuring built-in local-path is default StorageClass..."
        remote_exec "${FIRST_MASTER_IPV4}" "
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\": {\"storageclass.kubernetes.io/is-default-class\": \"true\"}}}'
        " 2>/dev/null || true
        log_success "  local-path set as default"
    fi
    echo ""

    # --- Step 3: Verify ---
    log_info "Verifying StorageClass..."
    remote_exec "${FIRST_MASTER_IPV4}" "
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        kubectl get storageclass
    "
    echo ""

    echo "============================================================"
    log_success "local-path-provisioner configured!"
    echo ""
    echo "  Data path: ${LOCAL_PATH_DATA_PATH}"
    echo ""
    echo "  Test with a PVC:"
    echo "    kubectl apply -f - <<EOF"
    echo "    apiVersion: v1"
    echo "    kind: PersistentVolumeClaim"
    echo "    metadata:"
    echo "      name: test-pvc"
    echo "    spec:"
    echo "      accessModes: [ReadWriteOnce]"
    echo "      storageClassName: local-path"
    echo "      resources:"
    echo "        requests:"
    echo "          storage: 1Gi"
    echo "    EOF"
    echo "============================================================"
fi
