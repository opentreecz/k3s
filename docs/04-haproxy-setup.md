# HAProxy and Keepalived Setup

HAProxy provides load balancing for the K3s API server across all three master nodes. Keepalived manages a Virtual IP (VIP) that floats between HAProxy instances for high availability.

## Architecture

```
Client (kubectl) --> VIP:6443 --> HAProxy --> master-01:6443
                                         --> master-02:6443
                                         --> master-03:6443
```

HAProxy and Keepalived run on all three master nodes. If the primary master fails, Keepalived migrates the VIP to another master where HAProxy continues to serve.

## Automated Installation

```bash
./scripts/02-install-haproxy.sh
```

The script uses pre-generated HAProxy and Keepalived configuration files from `generated/haproxy/haproxy.cfg` and `generated/keepalived/{hostname}/keepalived.conf` if available. These can be produced by `python3 generate.py` or by extracting a [Web UI](https://opentreecz.github.io/k3s/) ZIP into `generated/`. If no pre-generated configs are found, the script generates them inline from `inventory.conf`.

## Manual Installation

### Install Packages

#### SLE Micro

```bash
transactional-update pkg install haproxy keepalived
systemctl reboot
```

#### openSUSE MicroOS

```bash
transactional-update pkg install haproxy keepalived
systemctl reboot
```

### HAProxy Configuration

Deploy the following configuration to all master nodes at `/etc/haproxy/haproxy.cfg`:

```cfg
#---------------------------------------------------------------------
# K3s API Server Load Balancer
# /etc/haproxy/haproxy.cfg
#---------------------------------------------------------------------

global
    log         /dev/log local0
    log         /dev/log local1 notice
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout check           10s
    maxconn                 3000

#---------------------------------------------------------------------
# Statistics page
#---------------------------------------------------------------------
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:admin

#---------------------------------------------------------------------
# K3s API Server Frontend
#---------------------------------------------------------------------
frontend k3s_api_frontend
    bind *:6443
    mode tcp
    option tcplog
    default_backend k3s_api_backend

#---------------------------------------------------------------------
# K3s API Server Backend
#---------------------------------------------------------------------
backend k3s_api_backend
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100

    server master-01 192.168.1.101:6443 check
    server master-02 192.168.1.102:6443 check
    server master-03 192.168.1.103:6443 check
```

### Keepalived Configuration

Deploy to all master nodes at `/etc/keepalived/keepalived.conf`.

**Important**: The `priority` value must differ on each node. The node with the highest priority becomes the initial MASTER.

#### master-01 (MASTER, priority 101)

```conf
! /etc/keepalived/keepalived.conf
! Configuration for master-01

global_defs {
    router_id K3S_APISERVER
    script_user root
    enable_script_security
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
    fall 3
    rise 2
}

vrrp_instance K3S_VIP {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass K3sHA2024
    }

    virtual_ipaddress {
        192.168.1.100/24 dev eth0
        fd00::100/64 dev eth0
    }

    track_script {
        check_haproxy
    }
}
```

#### master-02 (BACKUP, priority 100)

```conf
! /etc/keepalived/keepalived.conf
! Configuration for master-02

global_defs {
    router_id K3S_APISERVER
    script_user root
    enable_script_security
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
    fall 3
    rise 2
}

vrrp_instance K3S_VIP {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass K3sHA2024
    }

    virtual_ipaddress {
        192.168.1.100/24 dev eth0
        fd00::100/64 dev eth0
    }

    track_script {
        check_haproxy
    }
}
```

#### master-03 (BACKUP, priority 99)

```conf
! /etc/keepalived/keepalived.conf
! Configuration for master-03

global_defs {
    router_id K3S_APISERVER
    script_user root
    enable_script_security
}

vrrp_script check_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
    fall 3
    rise 2
}

vrrp_instance K3S_VIP {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 99
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass K3sHA2024
    }

    virtual_ipaddress {
        192.168.1.100/24 dev eth0
        fd00::100/64 dev eth0
    }

    track_script {
        check_haproxy
    }
}
```

### Enable and Start Services

On all master nodes:

```bash
systemctl enable --now haproxy
systemctl enable --now keepalived
```

## Verification

### Check HAProxy

```bash
# Check service status
systemctl status haproxy

# Check listening port
ss -tlnp | grep 6443

# Access stats page
curl http://master-01:8404/stats
```

### Check Keepalived

```bash
# Check service status
systemctl status keepalived

# Verify VIP is assigned (should be on master-01 initially)
ip addr show eth0 | grep "192.168.1.100"

# Check VRRP logs
journalctl -u keepalived -f
```

### Test Failover

```bash
# On master-01, stop HAProxy to trigger failover
systemctl stop haproxy

# Check which node now holds the VIP
# On master-02:
ip addr show eth0 | grep "192.168.1.100"

# Restore master-01
systemctl start haproxy
```

### Test API Connectivity (after K3s is installed)

```bash
# Via VIP
curl -k https://192.168.1.100:6443/version

# Via each backend directly
curl -k https://192.168.1.101:6443/version
curl -k https://192.168.1.102:6443/version
curl -k https://192.168.1.103:6443/version
```

## Firewall Rules for VRRP

Keepalived uses VRRP (multicast 224.0.0.18, protocol 112). Ensure this is permitted:

```bash
firewall-cmd --permanent --add-rich-rule='rule protocol value="vrrp" accept'
firewall-cmd --permanent --add-port=8404/tcp
firewall-cmd --reload
```

## Non-local IP Binding

HAProxy needs to bind to the VIP before Keepalived assigns it. Enable non-local bind:

```bash
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/90-haproxy.conf
echo "net.ipv6.ip_nonlocal_bind = 1" >> /etc/sysctl.d/90-haproxy.conf
sysctl --system
```

## Next Steps

Proceed to [05 - K3s Installation](05-k3s-installation.md) to bootstrap the K3s cluster.
