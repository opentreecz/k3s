# 07 - Persistent Storage

> **Previous:** [06 - Worker Nodes](06-worker-nodes.md)

## Overview

The K3s cluster supports three storage provider options, configured via the
`STORAGE_PROVIDER` variable:

| Provider | Description | Replication | Snapshots | Complexity |
|----------|-------------|:-----------:|:---------:|:----------:|
| `longhorn` | Distributed replicated block storage from SUSE/Rancher | Yes | Yes | Medium |
| `local-path` | K3s built-in local path provisioner | No | No | Low |
| `none` | No persistent storage configured | N/A | N/A | None |

### Longhorn

Longhorn is a cloud-native distributed block storage system. It provides:

- Synchronous replication across nodes
- Scheduled snapshots and backups
- Disaster recovery (DR) via S3 or NFS backup targets
- Incremental backup and restore
- Volume expansion and cloning

**Requirements:**

- Dedicated disk or partition on each worker node
- `open-iscsi` package installed and `iscsid` service running
- Helm v3

### local-path-provisioner

The local-path-provisioner is bundled with K3s. It creates PersistentVolumes
backed by a directory on the node where the pod is scheduled.

- No replication -- data lives on a single node
- Volumes are bound to the node where they were created
- Simple and lightweight

### none

When set to `none`, no storage provisioner is deployed. Use this if you manage
storage externally or do not need persistent volumes.

---

## Disk Layout Requirements

The disk layout choice (`single-root`, `single-disk-multipart`, or `multi-disk`)
determines how storage partitions are provisioned on each node.

### Longhorn

Longhorn benefits from a dedicated XFS-formatted partition mounted at:

```
/var/lib/longhorn
```

| Disk Layout | Longhorn Partition |
|---|---|
| `single-root` | Subdirectory under root filesystem (not recommended for production) |
| `single-disk-multipart` | Dedicated partition on the same disk, formatted XFS |
| `multi-disk` | Dedicated disk or partition, formatted XFS |

A dedicated partition ensures Longhorn I/O does not contend with the OS or
container runtime and allows XFS features (reflink, ftype) to be used optimally.

### local-path

The local-path provisioner only needs a directory on each node. The default path
is:

```
/opt/local-path-provisioner
```

Any disk layout works. The directory is created automatically if it does not
exist.

---

## Automated Installation

Use the storage installation script with the `STORAGE_PROVIDER` environment
variable:

```bash
# Install Longhorn
STORAGE_PROVIDER=longhorn ./scripts/06-install-storage.sh

# Install local-path provisioner
STORAGE_PROVIDER=local-path ./scripts/06-install-storage.sh

# Skip storage installation
STORAGE_PROVIDER=none ./scripts/06-install-storage.sh
```

The script handles prerequisites, Helm chart installation (for Longhorn),
StorageClass creation, and verification.

---

## Longhorn Deep-Dive

### Prerequisites

Before Longhorn can be installed, each worker node must have:

1. **open-iscsi** installed:
   ```bash
   sudo apt-get install -y open-iscsi
   ```

2. **iscsid** service enabled and running:
   ```bash
   sudo systemctl enable iscsid --now
   ```

3. **Dedicated mount** at `/var/lib/longhorn` (XFS recommended):
   ```bash
   # Example: format and mount a dedicated partition
   sudo mkfs.xfs /dev/sdb1
   echo '/dev/sdb1 /var/lib/longhorn xfs defaults 0 0' | sudo tee -a /etc/fstab
   sudo mkdir -p /var/lib/longhorn
   sudo mount -a
   ```

### Architecture

Longhorn consists of three main components:

- **Longhorn Manager** -- DaemonSet running on every node. Manages volume
  lifecycle via the Kubernetes API.
- **Longhorn Engine** -- Each volume gets its own lightweight storage controller
  (one engine per volume).
- **Replicas** -- Each volume has multiple replicas distributed across nodes for
  redundancy.

```
┌─────────────────────────────────────────────────────┐
│                  Longhorn Manager                    │
│              (DaemonSet on each node)                │
└──────────────────────┬──────────────────────────────┘
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │  Engine  │  │  Engine  │  │  Engine  │
   │ (vol-1)  │  │ (vol-2)  │  │ (vol-3)  │
   └────┬─────┘  └────┬─────┘  └────┬─────┘
        │              │              │
   ┌────┴────┐    ┌────┴────┐   ┌────┴────┐
   │Replica x3│   │Replica x3│  │Replica x3│
   └──────────┘   └──────────┘  └──────────┘
```

### Helm Installation

The automated script installs Longhorn via Helm:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath=/var/lib/longhorn \
  --set defaultSettings.defaultReplicaCount=3
```

### Longhorn UI Access

**Port-forward (quick access):**

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# Open http://localhost:8080
```

**Via Ingress (production):**

Create an Ingress resource pointing to the `longhorn-frontend` service on port
80 in the `longhorn-system` namespace.

### Default Settings

| Setting | Default Value |
|---------|--------------|
| Replica count | `3` |
| Data path | `/var/lib/longhorn` |
| StorageClass name | `longhorn` |
| Reclaim policy | `Delete` |
| Volume expansion | Enabled |

### Verification

```bash
# Check Longhorn pods are running
kubectl -n longhorn-system get pods

# Verify StorageClass exists
kubectl get storageclass longhorn

# Check Longhorn nodes are ready
kubectl -n longhorn-system get nodes.longhorn.io

# Check Longhorn volumes
kubectl -n longhorn-system get volumes.longhorn.io
```

### Backup and Restore

Longhorn supports scheduled and on-demand backups to external targets:

- **S3-compatible storage** (MinIO, AWS S3, etc.)
- **NFS shares**

Configure a backup target in the Longhorn UI or via settings:

```bash
kubectl -n longhorn-system edit settings.longhorn.io backup-target
```

Example S3 target value:

```
s3://longhorn-backups@us-east-1/
```

Restores can be performed from the UI or by creating a Volume resource
referencing a backup URL.

---

## Local-Path Deep-Dive

### How It Works

The local-path-provisioner watches for PersistentVolumeClaims with the
`local-path` StorageClass. When a claim is created:

1. A directory is created on the scheduled node under the configured base path
2. A PersistentVolume is created with a `hostPath` pointing to that directory
3. The PV is bound to the PVC

When the PVC is deleted (with `Delete` reclaim policy), the directory is removed.

### Limitations

- **No replication** -- data exists only on a single node
- **Node-bound** -- pods using the PVC must run on the same node
- **No snapshots** -- no built-in snapshot or backup mechanism
- **No volume expansion** -- resizing is not supported

### When to Use It

- Development and testing environments
- Single-node clusters
- Non-critical workloads where data loss is acceptable
- Workloads that handle their own replication (e.g., databases with built-in clustering)

### Configuration

Customize the data path by editing the local-path-provisioner ConfigMap:

```bash
kubectl -n kube-system edit configmap local-path-config
```

Set the `paths` field to the desired directory:

```json
{
  "nodePathMap": [
    {
      "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
      "paths": ["/opt/local-path-provisioner"]
    }
  ]
}
```

### Making It the Default StorageClass

```bash
# Set local-path as default
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'

# Remove default from another StorageClass (if needed)
kubectl patch storageclass longhorn \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
```

---

## Testing Persistent Storage

### Create a PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn  # or local-path
  resources:
    requests:
      storage: 1Gi
```

### Create a Pod That Uses the PVC

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-storage-pod
spec:
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sh", "-c", "echo 'Storage works!' > /data/test.txt && cat /data/test.txt && sleep 3600"]
      volumeMounts:
        - name: test-volume
          mountPath: /data
  volumes:
    - name: test-volume
      persistentVolumeClaim:
        claimName: test-pvc
```

### Verify

```bash
# Apply the resources
kubectl apply -f test-pvc.yaml
kubectl apply -f test-pod.yaml

# Check PVC is bound
kubectl get pvc test-pvc

# Check pod is running
kubectl get pod test-storage-pod

# Verify data was written
kubectl exec test-storage-pod -- cat /data/test.txt

# Clean up
kubectl delete pod test-storage-pod
kubectl delete pvc test-pvc
```

---

## Troubleshooting

| Symptom | Possible Cause | Resolution |
|---------|---------------|------------|
| PVC stuck in `Pending` | No StorageClass matches or no available nodes | Check `kubectl describe pvc <name>` for events; verify StorageClass exists |
| Longhorn pods in CrashLoopBackOff | `iscsid` not running on nodes | Run `sudo systemctl enable iscsid --now` on all worker nodes |
| Longhorn volume degraded | Fewer healthy replicas than configured | Check node health with `kubectl -n longhorn-system get nodes.longhorn.io`; verify `/var/lib/longhorn` mount is healthy |
| Volume attach timeout | iSCSI initiator misconfigured | Verify `open-iscsi` is installed and `/etc/iscsi/initiatorname.iscsi` exists |
| local-path PVC bound but pod won't schedule | Pod scheduled to a different node than the PV | Use node affinity or let the scheduler place the pod; PV is node-local |
| No space left on device | Longhorn data path partition is full | Expand partition, add disk, or clean up old snapshots/volumes |
| Longhorn UI not accessible | Port-forward not running or service not ready | Verify `longhorn-frontend` pod is running; restart port-forward |
| Backup failed | Backup target not configured or unreachable | Check backup target settings and network connectivity to S3/NFS |

---

## Next Steps

With persistent storage configured, workloads can now maintain state across pod
restarts and rescheduling. Consider:

- Setting a default StorageClass if one is not already configured
- Configuring Longhorn backup schedules for production data
- Monitoring storage usage via the Longhorn UI or Prometheus metrics
