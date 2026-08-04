# Network Planning and DHCP Static Leases

Since the network is controlled by DHCPv4 and DHCPv6, **all nodes must have static DHCP lease reservations** configured on your DHCP server before deployment. This ensures predictable, stable IP addressing without using static OS-level network configuration.

## Why Static DHCP Leases Are Required

- K3s cluster certificates are bound to specific IP addresses
- HAProxy and Keepalived depend on stable IPs
- etcd cluster membership requires consistent addressing
- DNS records must resolve to predictable addresses
- Node identity in Kubernetes is tied to IP addresses

## IP Address Planning

### Required Addresses

| Resource | Hostname | IPv4 | IPv6 | MAC Address | Purpose |
|----------|----------|------|------|-------------|---------|
| VIP | k3s-api | 192.168.1.100 | fd00::100 | N/A (virtual) | API load balancer VIP |
| Master 1 | master-01 | 192.168.1.101 | fd00::101 | aa:bb:cc:dd:ee:01 | Control plane + HAProxy |
| Master 2 | master-02 | 192.168.1.102 | fd00::102 | aa:bb:cc:dd:ee:02 | Control plane + HAProxy |
| Master 3 | master-03 | 192.168.1.103 | fd00::103 | aa:bb:cc:dd:ee:03 | Control plane + HAProxy |
| Worker 1 | worker-01 | 192.168.1.111 | fd00::111 | aa:bb:cc:dd:ee:11 | Workload node |
| Worker 2 | worker-02 | 192.168.1.112 | fd00::112 | aa:bb:cc:dd:ee:12 | Workload node |
| Worker 3 | worker-03 | 192.168.1.113 | fd00::113 | aa:bb:cc:dd:ee:13 | Workload node |

### Subnet Planning

| Network | Purpose |
|---------|---------|
| 192.168.1.0/24 | Node network (physical) |
| fd00::/64 | Node network (IPv6) |
| 10.42.0.0/16 | K3s Pod CIDR (internal) |
| 10.43.0.0/16 | K3s Service CIDR (internal) |
| fd42::/48 | K3s Pod CIDR IPv6 (internal) |
| fd43::/112 | K3s Service CIDR IPv6 (internal) |

## DHCP Server Configuration

### Option 1: ISC DHCP Server (dhcpd)

#### DHCPv4 Static Leases

Add to your `/etc/dhcp/dhcpd.conf` (or include from a separate file):

```conf
# K3s Cluster - Static Leases
# File: configs/network/dhcpd4-leases.conf

group k3s-cluster {
    option domain-name "k3s.local";
    option domain-name-servers 192.168.1.1;
    option routers 192.168.1.1;

    # Master nodes
    host master-01 {
        hardware ethernet aa:bb:cc:dd:ee:01;
        fixed-address 192.168.1.101;
        option host-name "master-01";
    }
    host master-02 {
        hardware ethernet aa:bb:cc:dd:ee:02;
        fixed-address 192.168.1.102;
        option host-name "master-02";
    }
    host master-03 {
        hardware ethernet aa:bb:cc:dd:ee:03;
        fixed-address 192.168.1.103;
        option host-name "master-03";
    }

    # Worker nodes
    host worker-01 {
        hardware ethernet aa:bb:cc:dd:ee:11;
        fixed-address 192.168.1.111;
        option host-name "worker-01";
    }
    host worker-02 {
        hardware ethernet aa:bb:cc:dd:ee:12;
        fixed-address 192.168.1.112;
        option host-name "worker-02";
    }
    host worker-03 {
        hardware ethernet aa:bb:cc:dd:ee:13;
        fixed-address 192.168.1.113;
        option host-name "worker-03";
    }
}
```

#### DHCPv6 Static Leases

Add to your `/etc/dhcp/dhcpd6.conf`:

```conf
# K3s Cluster - DHCPv6 Static Leases
# File: configs/network/dhcpd6-leases.conf

group k3s-cluster {
    option dhcp6.domain-search "k3s.local";

    # Master nodes
    host master-01 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:01;
        fixed-address6 fd00::101;
    }
    host master-02 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:02;
        fixed-address6 fd00::102;
    }
    host master-03 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:03;
        fixed-address6 fd00::103;
    }

    # Worker nodes
    host worker-01 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:11;
        fixed-address6 fd00::111;
    }
    host worker-02 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:12;
        fixed-address6 fd00::112;
    }
    host worker-03 {
        host-identifier option dhcp6.client-id 00:01:00:01:XX:XX:XX:XX:aa:bb:cc:dd:ee:13;
        fixed-address6 fd00::113;
    }
}
```

### Option 2: dnsmasq

Add to your dnsmasq configuration:

```conf
# K3s Cluster - Static DHCP Leases (dnsmasq)
# File: configs/network/dnsmasq-leases.conf

# Format: dhcp-host=MAC,IPv4,hostname,lease-time
# DHCPv4
dhcp-host=aa:bb:cc:dd:ee:01,192.168.1.101,master-01,infinite
dhcp-host=aa:bb:cc:dd:ee:02,192.168.1.102,master-02,infinite
dhcp-host=aa:bb:cc:dd:ee:03,192.168.1.103,master-03,infinite
dhcp-host=aa:bb:cc:dd:ee:11,192.168.1.111,worker-01,infinite
dhcp-host=aa:bb:cc:dd:ee:12,192.168.1.112,worker-02,infinite
dhcp-host=aa:bb:cc:dd:ee:13,192.168.1.113,worker-03,infinite

# DHCPv6 (using DUID)
# Format: dhcp-host=id:DUID,[IPv6],hostname,lease-time
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:01,[fd00::101],master-01,infinite
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:02,[fd00::102],master-02,infinite
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:03,[fd00::103],master-03,infinite
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:11,[fd00::111],worker-01,infinite
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:12,[fd00::112],worker-02,infinite
dhcp-host=id:00:01:00:01:*:aa:bb:cc:dd:ee:13,[fd00::113],worker-03,infinite

# DNS records for the cluster
address=/k3s-api.k3s.local/192.168.1.100
address=/k3s-api.k3s.local/fd00::100
address=/master-01.k3s.local/192.168.1.101
address=/master-02.k3s.local/192.168.1.102
address=/master-03.k3s.local/192.168.1.103
address=/worker-01.k3s.local/192.168.1.111
address=/worker-02.k3s.local/192.168.1.112
address=/worker-03.k3s.local/192.168.1.113
```

### Option 3: Kea DHCP (ISC Kea)

For modern deployments using ISC Kea:

```json
{
    "Dhcp4": {
        "reservations": [
            {
                "hw-address": "aa:bb:cc:dd:ee:01",
                "ip-address": "192.168.1.101",
                "hostname": "master-01"
            },
            {
                "hw-address": "aa:bb:cc:dd:ee:02",
                "ip-address": "192.168.1.102",
                "hostname": "master-02"
            },
            {
                "hw-address": "aa:bb:cc:dd:ee:03",
                "ip-address": "192.168.1.103",
                "hostname": "master-03"
            },
            {
                "hw-address": "aa:bb:cc:dd:ee:11",
                "ip-address": "192.168.1.111",
                "hostname": "worker-01"
            },
            {
                "hw-address": "aa:bb:cc:dd:ee:12",
                "ip-address": "192.168.1.112",
                "hostname": "worker-02"
            },
            {
                "hw-address": "aa:bb:cc:dd:ee:13",
                "ip-address": "192.168.1.113",
                "hostname": "worker-03"
            }
        ]
    }
}
```

## DNS Records

In addition to DHCP leases, configure forward and reverse DNS records:

### Forward DNS (A and AAAA records)

```
k3s-api.k3s.local.    IN  A       192.168.1.100
k3s-api.k3s.local.    IN  AAAA    fd00::100
master-01.k3s.local.  IN  A       192.168.1.101
master-01.k3s.local.  IN  AAAA    fd00::101
master-02.k3s.local.  IN  A       192.168.1.102
master-02.k3s.local.  IN  AAAA    fd00::102
master-03.k3s.local.  IN  A       192.168.1.103
master-03.k3s.local.  IN  AAAA    fd00::103
worker-01.k3s.local.  IN  A       192.168.1.111
worker-01.k3s.local.  IN  AAAA    fd00::111
worker-02.k3s.local.  IN  A       192.168.1.112
worker-02.k3s.local.  IN  AAAA    fd00::112
worker-03.k3s.local.  IN  A       192.168.1.113
worker-03.k3s.local.  IN  AAAA    fd00::113
```

### Reverse DNS (PTR records)

```
101.1.168.192.in-addr.arpa.  IN  PTR  master-01.k3s.local.
102.1.168.192.in-addr.arpa.  IN  PTR  master-02.k3s.local.
103.1.168.192.in-addr.arpa.  IN  PTR  master-03.k3s.local.
111.1.168.192.in-addr.arpa.  IN  PTR  worker-01.k3s.local.
112.1.168.192.in-addr.arpa.  IN  PTR  worker-02.k3s.local.
113.1.168.192.in-addr.arpa.  IN  PTR  worker-03.k3s.local.
```

## Obtaining MAC Addresses

Before nodes are installed, obtain MAC addresses from:

1. **Server BMC/IPMI/iLO/iDRAC**: Check the management interface
2. **BIOS/UEFI**: Visible during boot or in setup
3. **Physical label**: Often on the NIC or server chassis
4. **First boot**: Install OS, note the MAC, then configure DHCP lease

```bash
# On a running node, find the MAC address:
ip link show eth0 | grep ether
```

## Virtual IP (VIP) Considerations

The VIP (`192.168.1.100` / `fd00::100`) used by Keepalived:
- Must **not** be assigned to any physical interface via DHCP
- Should be within the same subnet as the master nodes
- Can be reserved in DHCP as a "dummy" lease to prevent assignment to other devices
- Must be excluded from the DHCP dynamic range

## Verification

After configuring DHCP leases and booting all nodes:

```bash
# Verify each node got the expected address
for node in master-01 master-02 master-03 worker-01 worker-02 worker-03; do
    echo "=== $node ==="
    ssh root@$node "ip -4 addr show eth0; ip -6 addr show eth0"
done
```

## Next Steps

Proceed to [04 - HAProxy Setup](04-haproxy-setup.md) to configure the API load balancer.
