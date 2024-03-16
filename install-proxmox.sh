#!/bin/bash

# Help function to display usage instructions
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "OPTIONS:"
    echo "  -v, --vnc-password PASSWORD   Set VNC password"
    echo "  -p, --password PASSWORD       Set ssh password for proxmox" 
    echo "  -P, --port PORT               Change default SSH port"
    echo "  -k, --ssh-key SSH_KEY         Add SSH public key to authorized_keys"
    echo "  -h, --help                    Show this help message and exit"
}

# Function to add SSH public key to authorized_keys
add_ssh_key_to_authorized_keys() {
    local ssh_key="$1"
    if [ -n "$ssh_key" ]; then
        if [ -f "$ssh_key" ]; then
            # Copy SSH key to local host via scp
            scp -P 5555 "$ssh_key" root@127.0.0.1:/root/.ssh/authorized_keys
            echo "Added SSH public key to authorized_keys"

            # Disable password authentication for SSH
            ssh -p 5555 root@127.0.0.1 "sed -i 's/^PasswordAuthentication yes$/PasswordAuthentication no/' /etc/ssh/sshd_config"
            echo "Password authentication disabled for SSH"
        else
            echo "Error: File '$ssh_key' does not exist."
            exit 1
        fi
    fi
}

change_ssh_port() {
    if [ -n "$ssh_port" ]; then
        ssh -p 5555 root@127.0.0.1 "sed -i 's/^#Port.*$/Port $ssh_port/' /etc/ssh/sshd_config"
        echo "SSH port changed to $ssh_port on proxmox server."
    fi
}

disable_rpcbind() {
    ssh -p 5555 root@127.0.0.1 "systemctl disable --now rpcbind rpcbind.socket"
    echo "rpcbind disabled on proxmox server."
}

install_iptables_rule() {
    ssh -p 5555 127.0.0.1 "
        apt-get update &&
        apt-get install -y iptables-persistent &&
        iptables -I INPUT -d vmbr0 -p tcp -m tcp --dport 3128 -j DROP &&
        netfilter-persistent save
    "
}



set_network() {
    curl -L "https://github.com/WMP/proxmox-hetzner/raw/main/files/main_vmbr0_basic_template.txt" -o ~/interfaces_sample
    IFACE_NAME="$(udevadm info -e | grep -m1 -A 20 ^P.*eth0 | grep ID_NET_NAME_ONBOARD | cut -d'=' -f2)"
    MAIN_IPV4_CIDR="$(ip address show ${IFACE_NAME} | grep global | grep "inet "| xargs | cut -d" " -f2)"
    MAIN_IPV4_GW="$(ip route | grep default | xargs | cut -d" " -f3)"
    MAIN_IPV6_CIDR="$(ip address show ${IFACE_NAME} | grep global | grep "inet6 "| xargs | cut -d" " -f2)"
    MAIN_MAC_ADDR="$(ifconfig eth0 | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}')"

    sed -i "s|#IFACE_NAME#|$IFACE_NAME|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_CIDR#|$MAIN_IPV4_CIDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_GW#|$MAIN_IPV4_GW|g" ~/interfaces_sample
    sed -i "s|#MAIN_MAC_ADDR#|$MAIN_MAC_ADDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV6_CIDR#|$MAIN_IPV6_CIDR|g" ~/interfaces_sample

    scp -P 5555 ~/interfaces_sample root@127.0.0.1:/etc/network/interfaces
    ssh -p 5555 127.0.0.1 "printf 'nameserver 185.12.64.1\nnameserver  185.12.64.2\n" > /etc/resolv.conf
}

# Function to download the latest Proxmox ISO if not already downloaded
download_latest_proxmox_iso() {
    # URL from which we fetch Proxmox ISO images
    ISO_URL="https://enterprise.proxmox.com/iso/"

    # Fetching the list of ISO images
    iso_list=$(curl -s "$ISO_URL")

    # Extracting the name of the latest ISO file
    latest_iso_name=$(echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -r | head -n 1 | sed 's/">proxmox-ve.*//')

    # Check if ISO already exists
    if [ -f "$latest_iso_name" ]; then
        echo "ISO already exists at $latest_iso_name"
        return
    fi

    # Downloading the latest ISO file
    curl -o "$latest_iso_name" "$ISO_URL/$latest_iso_name"

    if [ $? -eq 0 ]; then
        echo "Downloaded the latest ISO image: $latest_iso_name"
    else
        echo "Error downloading the ISO image."
    fi
}

# Function to check if SSH server is up with a timeout of 60 seconds
check_ssh_server() {
    local server="127.0.0.1"
    local port="5555"
    local timeout=60
    local end_time=$((SECONDS + timeout))

    while [ $SECONDS -lt $end_time ]; do
        if nc -z "$server" "$port" </dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Call the function to download the latest Proxmox ISO
download_latest_proxmox_iso

# Parsing command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -v|--vnc-password)
            vnc_password="$2"
            shift
            shift
            ;;
        -p|--password)
            password="$2"
            shift
            shift
            ;;
        -P|--port)
            ssh_port="$2"
            shift
            shift
            ;;
        -k|--ssh-key)
            ssh_key="$2"
            shift
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done



if [ ! -n "$vnc_password" ]; then
    # Generate random VNC password
    vnc_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
fi
echo
echo "Connecto to VNC on port :5900 with password: $vnc_password"
echo "If VNC stuck before open installator try to reconnect VNC client"
echo

# Detecting EFI/UEFI system
if [ -d "/sys/firmware/efi" ]; then
    bios="-bios /usr/share/ovmf/OVMF.fd"
else
    bios=""
fi

hard_disks=()
while read -r line; do
    hard_disks+=("$line")
done < <(lsblk -o NAME -d -n -p | grep -v 'loop')

# Building QEMU command with detected hard disks
qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $latest_iso_name -vnc :0,password -monitor stdio -no-reboot"
for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Running QEMU
echo "$qemu_command"
eval "$qemu_command"

qemu_command="qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -smp 4 -m 4096"
for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Running QEMU
echo "$qemu_command"
eval "$qemu_command &"

local bg_pid=$!

# Performing SSH operations
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
fi
apt install sshpass



echo "Waiting for start SSH server on proxmox..."
check_ssh_server || echo "Fatal: Proxmox may not have started properly because SSH on socket 127.0.0.1:5555 is not working."


sshpass -p $password ssh-copy-id -p 5555 root@127.0.0.1

ssh 127.0.0.1 -p 5555 -o StrictHostKeyChecking=no -C exit




set_network



change_ssh_port

# Call the function to add SSH public key to authorized_keys
add_ssh_key_to_authorized_keys "$ssh_key"
disable_rpcbind
install_iptables_rule


ssh 127.0.0.1 -p 5555 -t  'bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/post-pve-install.sh)"'

kill $bg_pid