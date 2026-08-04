# Operating System Installation

This guide covers the installation of either **SUSE Linux Enterprise Micro (SLE Micro)** or **openSUSE MicroOS** on baremetal servers. Both are immutable, container-optimized operating systems ideal for running K3s.

## Choosing Your Distribution

| Feature | SLE Micro | openSUSE MicroOS |
|---------|-----------|------------------|
| Support | Commercial (SUSE) | Community |
| Lifecycle | 4+ years per release | Rolling release |
| Updates | Managed, tested | Continuous |
| Registration | Required (subscription) | Not required |
| Use case | Production / Enterprise | Lab / Community production |

## Option A: SUSE Linux Enterprise Micro

### Download

Download the installation ISO from the SUSE Customer Center:
- URL: https://www.suse.com/download/sle-micro/
- Select the latest SLE Micro version (6.x recommended)
- Choose the "Full" ISO for baremetal installation

### Interactive Installation

1. Boot from the ISO
2. Select **Installation** from the GRUB menu
3. Accept the license agreement
4. Configure:
   - **Registration**: Enter your SUSE registration code
   - **Extensions**: Enable "Containers Module" and "Public Cloud Module" (if applicable)
   - **System Role**: Select "Default"
   - **Disk**: Select target disk, use full disk with Btrfs (default)
   - **Network**: Leave as DHCP (static leases handle addressing)
   - **Time**: Configure NTP servers
   - **Root Password**: Set the root password
   - **SSH**: Enable SSH service and open firewall port
5. Confirm and install

### Automated Installation (AutoYaST)

Use the provided AutoYaST profile for unattended installation:

```bash
# Boot with the kernel parameter:
autoyast=http://<your-server>/sle-micro.xml
```

The AutoYaST profile is located at `configs/os/sle-micro.xml`.

Key customizations to make in the profile:
- Registration code
- Root password (hashed)
- SSH public key
- Disk layout (adjust for your hardware)

## Option B: openSUSE MicroOS

### Download

Download the installation ISO:
- URL: https://get.opensuse.org/microos/
- Select **Bare Metal / Virtual Machine** -> **Offline Image** (full installer)
- Architecture: x86_64

### Interactive Installation

1. Boot from the ISO
2. Select **Installation** from the GRUB menu
3. Configure:
   - **System Role**: Select "MicroOS" (not "MicroOS Desktop")
   - **Disk**: Select target disk, use full disk with Btrfs (default)
   - **Network**: Leave as DHCP (static leases handle addressing)
   - **Time**: Configure NTP servers  
   - **Root Password**: Set the root password
   - **SSH**: Enable SSH service
4. Confirm and install

### Automated Installation (Ignition/Combustion)

openSUSE MicroOS supports **Ignition** (from CoreOS) and **Combustion** for automated provisioning on first boot.

#### Using Ignition

Place the Ignition config on a USB drive labeled `ignition`:

```bash
# Format USB drive
mkfs.ext4 -L ignition /dev/sdX1

# Mount and copy config
mount /dev/sdX1 /mnt
cp configs/os/microos-ignition.json /mnt/config.ign
umount /mnt
```

#### Using Combustion

Create a USB drive labeled `combustion` with a `script` file:

```bash
# Format USB drive  
mkfs.ext4 -L combustion /dev/sdX1

# Mount and create script
mount /dev/sdX1 /mnt
mkdir -p /mnt/combustion
cat > /mnt/combustion/script << 'EOF'
#!/bin/bash
# combustion: network

# Set hostname (will be overridden per-node)
echo "k3s-node" > /etc/hostname

# Enable SSH
systemctl enable sshd.service

# Set root password (change this hash)
echo 'root:$6$rounds=4096$YOURSALT$YOURHASH' | chpasswd -e

# Add SSH public key
mkdir -p /root/.ssh
echo "ssh-ed25519 YOUR_PUBLIC_KEY user@host" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# Enable required services
systemctl enable NetworkManager
EOF
chmod +x /mnt/combustion/script
umount /mnt
```

## Post-Installation (Both Distributions)

After installation, verify the node is accessible:

```bash
# From your deployment host
ssh root@<node-ip> "hostnamectl"
```

Confirm:
- SSH access works
- Network is configured via DHCP
- System time is synchronized (timedatectl)
- The system has booted into the correct snapshot

## Disk Recommendations

| Mount Point | Size | Purpose |
|-------------|------|---------|
| / | 40 GB+ | Root filesystem (Btrfs with snapshots) |
| /var/lib/rancher | 100 GB+ | K3s data (containers, volumes) |
| /var/lib/containers | 50 GB+ | Container images |

For production, consider separating `/var/lib/rancher` on its own partition or disk for performance.

## Next Steps

Proceed to [02 - OS Configuration](02-os-configuration.md) for post-installation setup.
