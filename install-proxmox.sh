#!/bin/bash

# Help function to display usage instructions
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "OPTIONS:"
    echo "  -p, --password PASSWORD   Set VNC password"
    echo "  -h, --help                Show this help message and exit"
}

ISO_FILE_PATH="/root/latest_proxmox.iso"

# Function to set VNC password
set_vnc_password() {
    if [ -n "$vnc_password" ]; then
        printf "%s\n" "$vnc_password" | qemu-system-x86_64 -vnc :0,password -monitor stdio
    else
        qemu-system-x86_64 -vnc :0,password -monitor stdio
    fi
}

# Function to download the latest Proxmox ISO if not already downloaded
download_latest_proxmox_iso() {
    # URL from which we fetch Proxmox ISO images
    ISO_URL="https://enterprise.proxmox.com/iso/"

    # Path to save the ISO file
    

    # Check if ISO already exists
    if [ -f "$ISO_FILE_PATH" ]; then
        echo "ISO already exists at $ISO_FILE_PATH"
        return
    fi

    # Fetching the list of ISO images
    iso_list=$(curl -s "$ISO_URL")

    # Extracting the name of the latest ISO file
    latest_iso_name=$(echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -r | head -n 1 | sed 's/">proxmox-ve.*//')

    # Downloading the latest ISO file
    curl -o "$ISO_FILE_PATH" "$ISO_URL/$latest_iso_name"

    if [ $? -eq 0 ]; then
        echo "Downloaded the latest ISO image: $latest_iso_name to $ISO_FILE_PATH"
    else
        echo "Error downloading the ISO image."
    fi
}

# Call the function to download the latest Proxmox ISO
download_latest_proxmox_iso






# Detecting EFI/UEFI system
if [ -d "/sys/firmware/efi" ]; then
    echo "System is using UEFI."
    bios="-bios /usr/share/ovmf/OVMF.fd"
else
    bios=""
fi

# Parsing command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -p|--password)
            vnc_password="$2"
            set_vnc_password
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

# Detecting hard disks
hard_disks=()
while IFS= read -r -d '' disk; do
    hard_disks+=("$disk")
done < <(find /dev -type b -name 'sd*' -o -name 'hd*' -print0)

# Building QEMU command with detected hard disks
qemu_command="qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $ISO_FILE_PATH -vnc :0,password -monitor stdio -no-reboot"
for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Running QEMU
eval "$qemu_command"

qemu_command="qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -smp 4 -m 4096"
for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Performing SSH operations
ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
apt install sshpass

sleep 10
sshpass -p 1q2w3e4r ssh-copy-id -p 5555 root@127.0.0.1

ssh 127.0.0.1 -p 5555 -o StrictHostKeyChecking=no -C exit

## Run this in rescue session
bash <(curl -sSL https://github.com/WMP/proxmox-hetzner/raw/main/files/update_main_vmbr0_basic_from_template.sh)
