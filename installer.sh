#!/bin/bash

# ===============================================
# Pterodactyl Wings VM Setup Script
# ===============================================
# This script creates a VM environment with:
# - Docker support
# - Debian system
# - Pterodactyl Wings
# - iptables configuration
# - Custom terminal prompt
# ===============================================

set -e  # Exit on any error

# Configuration variables
VM_DIR="$HOME/VM"
VM_NAME="pterodactyl-vm"
DEBIAN_VERSION="bullseye"  # Debian 11
DISK_SIZE="20G"
MEMORY_SIZE="2048"
CPUS="2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print status messages
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check dependencies
check_dependencies() {
    info "Checking dependencies..."
    local deps=("qemu-system-x86_64" "qemu-img" "cloud-localds" "wget")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "$dep is not installed. Please install it first."
        fi
    done
}

# Create VM directory
create_vm_directory() {
    info "Creating VM directory at $VM_DIR..."
    mkdir -p "$VM_DIR" || error "Failed to create VM directory"
    cd "$VM_DIR" || error "Failed to enter VM directory"
}

# Download Debian cloud image
download_debian_image() {
    info "Downloading Debian cloud image..."
    local image_url="https://cloud.debian.org/images/cloud/$DEBIAN_VERSION/latest/debian-11-generic-amd64.qcow2"
    if [ ! -f "debian-base.qcow2" ]; then
        wget -O debian-base.qcow2 "$image_url" || error "Failed to download Debian image"
    else
        info "Debian image already exists, skipping download."
    fi
}

# Create cloud-init configuration
create_cloud_init() {
    info "Creating cloud-init configuration..."
    
    # Create user-data file
    cat > user-data << EOF
#cloud-config
hostname: pterodactyl-vm
manage_etc_hosts: true
users:
  - name: vps
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQD... (Please set up SSH key first)")
packages:
  - qemu-guest-agent
  - docker.io
  - docker-compose
  - curl
  - wget
  - iptables
  - systemd
package_update: true
package_upgrade: true
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker vps
  - echo 'export PS1="Vps@ubuntu#~ "' >> /home/vps/.bashrc
  - echo 'cd /etc/pterodactyl' >> /home/vps/.bashrc
final_message: "System setup complete! Enjoy your Pterodactyl environment!"
EOF

    # Create meta-data file
    cat > meta-data << EOF
instance-id: pterodactyl-vm
local-hostname: pterodactyl-vm
EOF

    # Create network-config file
    cat > network-config << EOF
version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp6: false
EOF

    # Create cloud-init disk - FIXED: network-config is not a direct argument to cloud-localds
    # Instead, we need to use the -N flag for network configuration
    cloud-localds -v -N network-config init.img user-data meta-data || error "Failed to create cloud-init disk"
}

# Create VM disk
create_vm_disk() {
    info "Creating VM disk..."
    qemu-img create -f qcow2 -F qcow2 -b debian-base.qcow2 vm-disk.qcow2 $DISK_SIZE || error "Failed to create VM disk"
}

# Install Pterodactyl Wings
install_pterodactyl_wings() {
    info "Creating Pterodactyl Wings installation script..."
    
    cat > install-wings.sh << 'EOF'
#!/bin/bash

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash || exit 1
fi

# Start and enable Docker
systemctl enable --now docker

# Create Pterodactyl directory
mkdir -p /etc/pterodactyl || exit 1

# Install Wings
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")" || exit 1
chmod u+x /usr/local/bin/wings || exit 1

# Enable swap if needed (for kernels < 6.1)
KERNEL_VERSION=$(uname -r | cut -d. -f1)
if [ "$KERNEL_VERSION" -lt 6 ]; then
    if ! grep -q "swapaccount=1" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& swapaccount=1/' /etc/default/grub
        update-grub
        echo "Swap enabled. Reboot required to take effect."
    fi
fi

# Create systemd service for Wings
cat > /etc/systemd/system/wings.service << 'SERVICE'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload

echo "Pterodactyl Wings installation script created!"
echo "After booting the VM, run:"
echo "1. sudo systemctl enable --now wings"
echo "2. Configure your wings config in /etc/pterodactyl/config.yml"
EOF

    chmod +x install-wings.sh
}

# Configure iptables for Docker
configure_iptables() {
    info "Creating iptables configuration script..."
    
    cat > configure-iptables.sh << 'EOF'
#!/bin/bash

# Ensure iptables is installed
apt-get update
apt-get install -y iptables-persistent

# Configure iptables rules for Docker
# Docker manages iptables rules automatically, but we can add custom rules to DOCKER-USER chain
# to ensure they persist and aren't modified by Docker

# Create custom iptables rules file
cat > /etc/iptables/rules.v4 << 'RULES'
*filter
:INPUT ACCEPT [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER - [0:0]
:DOCKER-ISOLATION-STAGE-1 - [0:0]
:DOCKER-ISOLATION-STAGE-2 - [0:0]
:DOCKER-USER - [0:0]
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-ISOLATION-STAGE-1
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o docker0 -j DOCKER
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT
-A FORWARD -i docker0 -o docker0 -j ACCEPT
-A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2
-A DOCKER-ISOLATION-STAGE-1 -j RETURN
-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
-A DOCKER-ISOLATION-STAGE-2 -j RETURN
-A DOCKER-USER -j RETURN
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
:DOCKER - [0:0]
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
-A DOCKER -i docker0 -j RETURN
COMMIT
RULES

# Apply the rules
iptables-restore < /etc/iptables/rules.v4

# Make sure rules persist after reboot
systemctl enable netfilter-persistent
systemctl start netfilter-persistent

echo "iptables configured for Docker!"
EOF

    chmod +x configure-iptables.sh
}

# Start the VM
# Start the VM
start_vm() {
    info "Starting VM..."
    
    # Choose ONE of the following options:
    
    # Option 1: Run in background (daemonize) with VNC
    qemu-system-x86_64 \
        -machine type=q35,accel=kvm \
        -cpu host \
        -smp $CPUS \
        -m $MEMORY_SIZE \
        -drive file=vm-disk.qcow2,if=virtio \
        -drive file=init.img,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -daemonize \
        -vnc :1  # Access via VNC at localhost:5901
    
    # Option 2: Run in foreground with console output (remove -daemonize and -vnc)
    # qemu-system-x86_64 \
    #     -machine type=q35,accel=kvm \
    #     -cpu host \
    #     -smp $CPUS \
    #     -m $MEMORY_SIZE \
    #     -drive file=vm-disk.qcow2,if=virtio \
    #     -drive file=init.img,if=virtio \
    #     -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    #     -device virtio-net-pci,netdev=net0 \
    #     -nographic
    
    info "VM started successfully!"
    info "You can SSH into the VM with: ssh -p 2222 vps@localhost"
    info "The terminal prompt will appear as 'Vps@ubuntu#~'"
    
    # If using Option 1 with VNC:
    info "VM is also accessible via VNC at localhost:5901"
}

# Run main function
main "$@"
