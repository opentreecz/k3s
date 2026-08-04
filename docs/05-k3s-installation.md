# K3s Installation

This guide covers bootstrapping the K3s highly-available cluster with 3 master (server) nodes using the embedded etcd datastore.

## Architecture

- **3 server nodes** running K3s in server mode (control plane + etcd)
- **Embedded etcd** for cluster state (no external database needed)
- **API accessed via VIP** (HAProxy load-balanced)
- **Dual-stack networking** (IPv4 + IPv6)

## Automated Installation

```bash
# Bootstrap the first server node
./scripts/03-install-k3s-first.sh

# Join the remaining server nodes
./scripts/04-install-k3s-servers.sh
```

Both scripts check for pre-generated K3s server configuration files in `generated/k3s/{hostname}/config.yaml`. If found (from `generate.py` or Web UI ZIP), these are deployed directly to each node. If not found, the scripts generate the configuration inline from `inventory.conf`.

## Manual Installation

### Step 1: Generate Cluster Token

Generate a secure token that will be shared across all nodes:

```bash
# Generate a random token
K3S_TOKEN=$(openssl rand -hex 32)
echo "K3S_TOKEN=${K3S_TOKEN}"
# Save this token securely - it's needed for all nodes
```

### Step 2: Bootstrap First Server (master-01)

The first server initializes the cluster with `--cluster-init`:

```bash
ssh root@master-01

# Install K3s as the first server node
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
    --cluster-init \
    --token "${K3S_TOKEN}" \
    --tls-san "192.168.1.100" \
    --tls-san "fd00::100" \
    --tls-san "k3s-api.k3s.local" \
    --tls-san "master-01.k3s.local" \
    --tls-san "master-02.k3s.local" \
    --tls-san "master-03.k3s.local" \
    --node-ip "192.168.1.101,fd00::101" \
    --advertise-address "192.168.1.101" \
    --cluster-cidr "10.42.0.0/16,fd42::/48" \
    --service-cidr "10.43.0.0/16,fd43::/112" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode "0644" \
    --etcd-expose-metrics \
    --kube-apiserver-arg "advertise-address=192.168.1.101"
```

Alternatively, use a configuration file at `/etc/rancher/k3s/config.yaml`:

```yaml
# /etc/rancher/k3s/config.yaml - First server node
cluster-init: true
token: "YOUR_TOKEN_HERE"
tls-san:
  - "192.168.1.100"
  - "fd00::100"
  - "k3s-api.k3s.local"
  - "master-01.k3s.local"
  - "master-02.k3s.local"
  - "master-03.k3s.local"
node-ip: "192.168.1.101,fd00::101"
advertise-address: "192.168.1.101"
cluster-cidr: "10.42.0.0/16,fd42::/48"
service-cidr: "10.43.0.0/16,fd43::/112"
disable:
  - traefik
  - servicelb
write-kubeconfig-mode: "0644"
etcd-expose-metrics: true
kube-apiserver-arg:
  - "advertise-address=192.168.1.101"
```

Then install K3s:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s -
```

### Step 3: Verify First Server

```bash
# Wait for node to be ready
kubectl get nodes
# NAME        STATUS   ROLES                       AGE   VERSION
# master-01   Ready    control-plane,etcd,master   1m    v1.xx.x+k3s1

# Check all pods are running
kubectl get pods -A

# Verify etcd is healthy
kubectl get endpoints -n kube-system
```

### Step 4: Join Second Server (master-02)

```bash
ssh root@master-02

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
    --server "https://192.168.1.101:6443" \
    --token "${K3S_TOKEN}" \
    --tls-san "192.168.1.100" \
    --tls-san "fd00::100" \
    --tls-san "k3s-api.k3s.local" \
    --tls-san "master-01.k3s.local" \
    --tls-san "master-02.k3s.local" \
    --tls-san "master-03.k3s.local" \
    --node-ip "192.168.1.102,fd00::102" \
    --advertise-address "192.168.1.102" \
    --cluster-cidr "10.42.0.0/16,fd42::/48" \
    --service-cidr "10.43.0.0/16,fd43::/112" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode "0644" \
    --etcd-expose-metrics \
    --kube-apiserver-arg "advertise-address=192.168.1.102"
```

Or use config file `/etc/rancher/k3s/config.yaml`:

```yaml
# /etc/rancher/k3s/config.yaml - Additional server node (master-02)
server: "https://192.168.1.101:6443"
token: "YOUR_TOKEN_HERE"
tls-san:
  - "192.168.1.100"
  - "fd00::100"
  - "k3s-api.k3s.local"
  - "master-01.k3s.local"
  - "master-02.k3s.local"
  - "master-03.k3s.local"
node-ip: "192.168.1.102,fd00::102"
advertise-address: "192.168.1.102"
cluster-cidr: "10.42.0.0/16,fd42::/48"
service-cidr: "10.43.0.0/16,fd43::/112"
disable:
  - traefik
  - servicelb
write-kubeconfig-mode: "0644"
etcd-expose-metrics: true
kube-apiserver-arg:
  - "advertise-address=192.168.1.102"
```

### Step 5: Join Third Server (master-03)

```bash
ssh root@master-03

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
    --server "https://192.168.1.101:6443" \
    --token "${K3S_TOKEN}" \
    --tls-san "192.168.1.100" \
    --tls-san "fd00::100" \
    --tls-san "k3s-api.k3s.local" \
    --tls-san "master-01.k3s.local" \
    --tls-san "master-02.k3s.local" \
    --tls-san "master-03.k3s.local" \
    --node-ip "192.168.1.103,fd00::103" \
    --advertise-address "192.168.1.103" \
    --cluster-cidr "10.42.0.0/16,fd42::/48" \
    --service-cidr "10.43.0.0/16,fd43::/112" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode "0644" \
    --etcd-expose-metrics \
    --kube-apiserver-arg "advertise-address=192.168.1.103"
```

### Step 6: Verify Cluster

```bash
# On master-01
kubectl get nodes
# NAME        STATUS   ROLES                       AGE   VERSION
# master-01   Ready    control-plane,etcd,master   5m    v1.xx.x+k3s1
# master-02   Ready    control-plane,etcd,master   3m    v1.xx.x+k3s1
# master-03   Ready    control-plane,etcd,master   1m    v1.xx.x+k3s1

# Check etcd cluster health
kubectl -n kube-system exec -it $(kubectl -n kube-system get pods -l component=etcd -o name | head -1) -- \
    etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
    member list

# Verify HA via VIP
curl -k https://192.168.1.100:6443/version
```

### Step 7: Configure kubeconfig for VIP Access

After the cluster is up, update kubeconfig to use the VIP:

```bash
# Copy kubeconfig from master-01
scp root@master-01:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Update the server URL to use the VIP
sed -i 's|https://127.0.0.1:6443|https://192.168.1.100:6443|g' ~/.kube/config

# Verify
kubectl cluster-info
kubectl get nodes
```

## K3s Server Configuration Reference

The configuration file used is at `configs/k3s/server-config.yaml`.

## Important Notes

1. **TLS SANs**: All server certificates include the VIP and all master hostnames. This allows kubectl to connect via any path.

2. **First node bootstrap**: Only the first node uses `--cluster-init`. All subsequent nodes use `--server` to join.

3. **Join URL**: Subsequent servers join via the first server's direct IP (`192.168.1.101:6443`), NOT the VIP. This avoids a chicken-and-egg problem during bootstrap.

4. **After bootstrap**: Once all servers are running, clients (including agents) should use the VIP (`192.168.1.100:6443`).

5. **Token security**: The cluster token provides full cluster access. Store it securely.

## Troubleshooting

```bash
# Check K3s service logs
journalctl -u k3s -f

# Check K3s is listening
ss -tlnp | grep 6443

# Restart K3s
systemctl restart k3s

# Check etcd data directory
ls -la /var/lib/rancher/k3s/server/db/etcd/
```

## Next Steps

Proceed to [06 - Worker Nodes](06-worker-nodes.md) to add worker nodes to the cluster.
