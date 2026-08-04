# Adding Worker Nodes

Worker nodes (agents) run workloads but do not participate in the control plane or etcd cluster. They connect to the K3s API via the HAProxy VIP for high availability.

## Prerequisites

- K3s control plane is fully operational (all 3 masters running)
- HAProxy VIP is functional (`192.168.1.100:6443` responds)
- Worker nodes have OS installed and configured
- DHCP static leases are active for worker nodes
- Worker node can reach the VIP on port 6443

## Automated Installation

```bash
./scripts/05-install-k3s-agents.sh
```

## Manual Installation

### Step 1: Retrieve the Cluster Token

The token was set during server installation. Retrieve it from any master:

```bash
ssh root@master-01 "cat /var/lib/rancher/k3s/server/node-token"
```

### Step 2: Install K3s Agent

On each worker node:

```bash
ssh root@worker-01

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
    --server "https://192.168.1.100:6443" \
    --token "${K3S_TOKEN}" \
    --node-ip "192.168.1.111,fd00::111"
```

Or use a configuration file at `/etc/rancher/k3s/config.yaml`:

```yaml
# /etc/rancher/k3s/config.yaml - Agent configuration
server: "https://192.168.1.100:6443"
token: "YOUR_TOKEN_HERE"
node-ip: "192.168.1.111,fd00::111"
```

Then install:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s -
```

### Step 3: Repeat for Additional Workers

#### worker-02

```bash
ssh root@worker-02

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
    --server "https://192.168.1.100:6443" \
    --token "${K3S_TOKEN}" \
    --node-ip "192.168.1.112,fd00::112"
```

#### worker-03

```bash
ssh root@worker-03

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
    --server "https://192.168.1.100:6443" \
    --token "${K3S_TOKEN}" \
    --node-ip "192.168.1.113,fd00::113"
```

### Step 4: Verify Workers Joined

From the deployment host or any master:

```bash
kubectl get nodes -o wide
# NAME        STATUS   ROLES                       AGE   VERSION        INTERNAL-IP
# master-01   Ready    control-plane,etcd,master   10m   v1.xx.x+k3s1  192.168.1.101
# master-02   Ready    control-plane,etcd,master   8m    v1.xx.x+k3s1  192.168.1.102
# master-03   Ready    control-plane,etcd,master   6m    v1.xx.x+k3s1  192.168.1.103
# worker-01   Ready    <none>                      2m    v1.xx.x+k3s1  192.168.1.111
# worker-02   Ready    <none>                      1m    v1.xx.x+k3s1  192.168.1.112
# worker-03   Ready    <none>                      30s   v1.xx.x+k3s1  192.168.1.113
```

## Adding More Workers Later

To add additional workers at any time:

1. **Configure DHCP static lease** for the new node on your DHCP server
2. **Install the OS** (SLE Micro or MicroOS)
3. **Run OS configuration** (or use `scripts/01-configure-os.sh` targeting the new node)
4. **Install K3s agent**:

```bash
# Add the new node to inventory.conf WORKER_NODES array, then:
./scripts/05-install-k3s-agents.sh

# Or manually:
ssh root@worker-04
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -s - \
    --server "https://192.168.1.100:6443" \
    --token "${K3S_TOKEN}" \
    --node-ip "192.168.1.114,fd00::114"
```

## Worker Node Labels and Taints

After joining, apply labels to organize workers:

```bash
# Label nodes by role
kubectl label node worker-01 node-role.kubernetes.io/worker=worker
kubectl label node worker-02 node-role.kubernetes.io/worker=worker
kubectl label node worker-03 node-role.kubernetes.io/worker=worker

# Label by hardware characteristics (example)
kubectl label node worker-01 disktype=ssd
kubectl label node worker-02 disktype=ssd
kubectl label node worker-03 disktype=hdd

# Taint masters to prevent scheduling workloads on them (optional)
kubectl taint nodes master-01 node-role.kubernetes.io/master=:NoSchedule
kubectl taint nodes master-02 node-role.kubernetes.io/master=:NoSchedule
kubectl taint nodes master-03 node-role.kubernetes.io/master=:NoSchedule
```

## Removing a Worker Node

```bash
# Drain the node (evicts all pods)
kubectl drain worker-03 --ignore-daemonsets --delete-emptydir-data

# Delete the node from the cluster
kubectl delete node worker-03

# On the worker node itself, uninstall K3s
ssh root@worker-03 "/usr/local/bin/k3s-agent-uninstall.sh"
```

## Agent Configuration Reference

The full agent configuration template is at `configs/k3s/agent-config.yaml`.

### Optional Agent Settings

```yaml
# /etc/rancher/k3s/config.yaml
server: "https://192.168.1.100:6443"
token: "YOUR_TOKEN_HERE"
node-ip: "192.168.1.111,fd00::111"

# Optional settings:
node-label:
  - "node-role.kubernetes.io/worker=worker"
  - "disktype=ssd"
# node-taint:
#   - "special=true:NoSchedule"
# kubelet-arg:
#   - "max-pods=110"
#   - "eviction-hard=memory.available<500Mi,nodefs.available<10%"
# protect-kernel-defaults: true
```

## Troubleshooting

```bash
# Check K3s agent service
systemctl status k3s-agent
journalctl -u k3s-agent -f

# Verify connectivity to API
curl -k https://192.168.1.100:6443/version

# Check node conditions
kubectl describe node worker-01

# Check if agent can reach the server
# On the worker:
curl -k https://192.168.1.100:6443/healthz
```

### Common Issues

| Problem | Cause | Solution |
|---------|-------|----------|
| Node stays NotReady | Agent can't reach API | Check firewall, VIP, HAProxy |
| Token rejected | Wrong token | Re-copy from `/var/lib/rancher/k3s/server/node-token` |
| DNS resolution fails | Missing /etc/hosts | Run OS configuration script |
| Certificate error | TLS SAN missing | Regenerate server certs with all SANs |
