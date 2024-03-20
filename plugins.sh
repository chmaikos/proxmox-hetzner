#!/bin/bash

WAN_IFACE=$(ip route show default | awk '/default/ {print $5}')
PUBLIC_IPV4=$(ip -f inet addr show ${WAN_IFACE} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')

add_ssh_key_to_authorized_keys() {
    if [ -n "$ssh_key" ]; then
        if [ -f "$ssh_key" ]; then
            # Copy SSH key to local host via scp
            ssh-copy-id -f -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$ssh_key"  -p 5555 root@127.0.0.1  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
            echo "Added SSH public key to authorized_keys"

            # Disable password authentication for SSH
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "sed -i 's/^PasswordAuthentication yes$/PasswordAuthentication no/' /etc/ssh/sshd_config"  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
            echo "Password authentication disabled for SSH"
        else
            echo "Error: File '$ssh_key' does not exist."
            exit 1
        fi
    fi
}

change_ssh_port() {
    if [ -n "$ssh_port" ]; then
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "sed -i 's/^#Port.*$/Port $ssh_port/' /etc/ssh/sshd_config"  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "echo 'Port $ssh_port' >> /root/.ssh/config"  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
        echo "SSH port changed to $ssh_port on proxmox server."
    fi
}

disable_rpcbind() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "systemctl disable --now rpcbind rpcbind.socket"  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
    echo "rpcbind disabled on proxmox server."
}

install_iptables_rule() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections &&
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections &&
        apt-get install -y iptables-persistent &&
        iptables -I INPUT -i vmbr0 -p tcp -m tcp --dport 3128 -j DROP &&
        netfilter-persistent save
    "  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
}

update_locale_gen() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        if grep -q \"^# *\$LC_NAME\" /etc/locale.gen; then
            sed -i \"s/^# *\$LC_NAME/\$LC_NAME/\" /etc/locale.gen
            locale-gen
            echo \"Updated /etc/locale.gen and generated locales for \$LC_NAME\"
        fi
        update-locale LANG=en_US.UTF-8
    "  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
}

set_network() {
    curl -L "https://github.com/WMP/proxmox-hetzner/raw/main/files/main_vmbr0_basic_template.txt" -o ~/interfaces_sample
    
    if [ "$specified_iface_name" ]; then
        IFACE_NAME=$specified_iface_name
    else
        IFACE_NAME="$(udevadm info -e | grep -m1 -A 20 ^P.*${WAN_IFACE} | grep ID_NET_NAME_PATH | cut -d'=' -f2)"
    fi

    # Continue with setting up the network using the chosen IFACE_NAME
    MAIN_IPV4_CIDR="$(ip address show ${IFACE_NAME} | grep global | grep "inet "| xargs | cut -d" " -f2)"
    MAIN_IPV4_GW="$(ip route | grep default | xargs | cut -d" " -f3)"
    MAIN_IPV6_CIDR="$(ip address show ${IFACE_NAME} | grep global | grep "inet6 "| xargs | cut -d" " -f2)"
    MAIN_MAC_ADDR="$(cat /sys/class/net/${WAN_IFACE}/address)"

    sed -i "s|#IFACE_NAME#|$IFACE_NAME|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_CIDR#|$MAIN_IPV4_CIDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_GW#|$MAIN_IPV4_GW|g" ~/interfaces_sample
    sed -i "s|#MAIN_MAC_ADDR#|$MAIN_MAC_ADDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV6_CIDR#|$MAIN_IPV6_CIDR|g" ~/interfaces_sample

    # Display the configuration for user verification
    if [ "$verbose" = true ]; then
        echo "The generated network configuration is as follows:"
        cat ~/interfaces_sample
    fi

    # Apply the configuration
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 ~/interfaces_sample root@127.0.0.1:/etc/network/interfaces  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "printf 'nameserver 185.12.64.1\nnameserver  185.12.64.1\n' > /etc/resolv.conf"  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
}

set_private_network(){
    IFS='/' read -r -a address_parts <<< "$PRIVATE_ADDRESS"
    PRIVATE_CIDR="${address_parts[0]}"
    PRIVATE_CIDR_BASE="${PRIVATE_CIDR%.*}.0/${address_parts[1]}"

    NET_IFACE_CONF="auto vmbr1
iface vmbr1 inet static
    address $PRIVATE_ADDRESS
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '$PRIVATE_CIDR_BASE' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '$PRIVATE_CIDR_BASE' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1"

    TMP_FILE=$(mktemp)

    # Write the configuration to the temporary file
    echo "$NET_IFACE_CONF" > "$TMP_FILE"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 "$TMP_FILE" root@127.0.0.1:/tmp/priv_conf
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "cat /tmp/vlan_conf >> /etc/network/interfaces && rm /tmp/priv_conf"

}

set_public_network(){
    NET_IFACE_CONF="auto vmbr2
iface vmbr2 inet static
    address $PUBLIC_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0"

    TMP_FILE=$(mktemp)

    # Write the configuration to the temporary file
    echo "$NET_IFACE_CONF" > "$TMP_FILE"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 "$TMP_FILE" root@127.0.0.1:/tmp/pub_conf
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "cat /tmp/vlan_conf >> /etc/network/interfaces && rm /tmp/pub_conf"

}

set_vswitch_network(){
    IFS='/' read -r IP CIDR <<< "$VLAN_ADDRESS"
    IFS='.' read -r -a address_parts <<< "$IP"
    VLAN_GW="${address_parts[0]}.${address_parts[1]}.${address_parts[2]}.1"
    VLAN_CIDR="${address_parts[0]}.${address_parts[1]}.0.0/16"

    NET_IFACE_CONF="auto vlan$VLAN_ID
iface vlan$VLAN_ID inet static
    address $VLAN_ADDRESS
    mtu 1400
    vlan-raw-device vmbr0
    up ip route add $VLAN_CIDR via $VLAN_GW dev vlan$VLAN_ID
    down ip route del $VLAN_CIDR via $VLAN_GW dev vlan$VLAN_ID"

    # Create a temporary file
    TMP_FILE=$(mktemp)

    # Write the configuration to the temporary file
    echo "$NET_IFACE_CONF" > "$TMP_FILE"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 "$TMP_FILE" root@127.0.0.1:/tmp/vlan_conf
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "cat /tmp/vlan_conf >> /etc/network/interfaces && rm /tmp/vlan_conf"

}

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

    echo "Downloading the latest ISO file"
    curl --remove-on-error -o "$latest_iso_name" "$ISO_URL/$latest_iso_name"

    if [ $? -eq 0 ]; then
        echo "Downloaded the latest ISO image: $latest_iso_name"
    else
        echo "Error downloading the ISO image."
    fi
}

init_proxmox(){
    # Call the function to download the latest Proxmox ISO
    download_latest_proxmox_iso

    # Detecting EFI/UEFI system
    if [ -d "/sys/firmware/efi" ]; then
        bios="-bios /usr/share/ovmf/OVMF.fd"
    else
        bios=""
    fi

    # Array to store disk information as text
    hard_disks_text=()

    # Read disk information using lsblk and store it in the array
    first_line=true
    while read -r line; do
        if $first_line; then
            first_line=false
            continue
        fi
        hard_disks_text+=("$line")
    done < <(lsblk -o NAME,SIZE,SERIAL,VENDOR,MODEL,PARTTYPE -d -p | grep -v 'loop')

    # Add a column with device path /dev/vd*
    device_path="/dev/vd"
    counter=97  # ASCII code for 'a'
    for ((i = 0; i < ${#hard_disks_text[@]}; i++)); do
        if (( $counter > 122 )); then  # If ASCII code exceeds 'z'
            echo "Too many disks to assign"
            break
        fi
        # Append device path to each disk entry
        hard_disks_text[$i]="${hard_disks_text[$i]} $device_path$(printf "\x$(printf %x $counter)")"
        ((counter++))
    done

    # Display the list of disks with the added device path
    if [ "$verbose" = true ]; then
        echo "Disk mapping table:"
        for disk_info in "${hard_disks_text[@]}"; do
            echo "$disk_info"
        done
    fi

    hard_disks=()
    while read -r line; do
        hard_disks+=("$line")
    done < <(lsblk -o NAME -d -n -p | grep -v 'loop')

    if [ "$skip_installer" = false ]; then
        if [ ! -n "$vnc_password" ]; then
            # Generate random VNC password
            vnc_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        fi
        echo
        echo "Connecto to vnc://$PUBLIC_IPV4:5900 with password: $vnc_password"
        echo "If VNC stuck before open installator, try to reconnect VNC client"
        echo
        # Building QEMU command with detected hard disks
        qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $latest_iso_name -vnc :0,password -monitor stdio -no-reboot"
        for disk in "${hard_disks[@]}"; do
            qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
        done

        # Running QEMU
        if [ "$verbose" = true ]; then
            echo "$qemu_command"
        fi
        eval "$qemu_command > /dev/null 2>&1"
    fi

    qemu_command="qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -smp 4 -m 4096"
    for disk in "${hard_disks[@]}"; do
        qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
    done

    # Running QEMU
    if [ "$verbose" = true ]; then
        echo "$qemu_command"
    fi
    eval "$qemu_command   > /dev/null 2>&1 &"
}

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

register_acme_account() {
    ssh -o CheckHostIP=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 " 
        apt update && apt install -y expect && 
        expect -c \"
            spawn pvenode acme account register default $acme_email --directory https://acme-v02.api.letsencrypt.org/directory
            expect -re {Do you agree}
            send \"y\\\r\"
            interact
        \" && pvenode config set --acme domains=\$(hostname -f) 
    "  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
    order_acme_certificate
}

run_tteck_post-pve-install() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1  -t  'bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/post-pve-install.sh)"'
}

order_acme_certificate() {
    cat <<EOF > /root/acme_certificate_order_script.sh
#!/bin/bash
sleep 30;
pvenode acme cert order

rm "/etc/cron.d/acme_certificate_order_cron"
rm "/root/acme_certificate_order_script.sh"
EOF

    chmod +x /root/acme_certificate_order_script.sh

    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 /root/acme_certificate_order_script.sh 127.0.0.1:/root/acme_certificate_order_script.sh  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)' && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        echo -e \"@reboot root /root/acme_certificate_order_script.sh > /var/log/acme_certificate_order_script.log\n\" > /etc/cron.d/acme_certificate_order_cron && \
        chmod 644 /etc/cron.d/acme_certificate_order_cron
    "  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
}