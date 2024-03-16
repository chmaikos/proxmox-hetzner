 #!/bin/bash

#!/bin/bash

# Function to show help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "OPTIONS:"
    echo "  -v, --vnc-password PASSWORD   Set VNC password"
    echo "  -P, --port PORT               Change default SSH port"
    echo "  -k, --ssh-key SSH_KEY         Add SSH public key to authorized_keys"
    echo "  -e, --acme-email EMAIL        Set email for ACME account"
    echo "  --skip-installer              Skip Proxmox installer and boot directly from installed disks"
    echo "  --disable PLUGIN1,PLUGIN2     Disable specified plugins"
    echo "  -h, --help                    Show this help message and exit"
    echo ""
    echo "Available plugins (default enabled):"
    for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
        echo "  $plugin: $(describe_plugin "$plugin")"
    done
}

# Function to describe each plugin
describe_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            echo "Run additional post-installation tasks from https://tteck.github.io/Proxmox/"
            ;;
        "set_network")
            echo "Configure network settings based on Hetzner rescure network"
            ;;
        "update_locale_gen")
            echo "Update locale settings with your ssh_client LC_NAME: ${LC_NAME}"
            ;;
        "register_acme_account")
            echo "Get Let's Encrypt certificate for hostname set in Proxmox installer. Cert ordering is after reboot"
            ;;
        "disable_rpcbind")
            echo "Disable rpcbind service"
            ;;
        "install_iptables_rule")
            echo "Install custom iptables rule"
            ;;
        "add_ssh_key_to_authorized_keys")
            echo "Add SSH public key to authorized_keys file and disable ssh only password login"
            ;;
        "change_ssh_port")
            echo "Change default SSH port"
            ;;
        *)
            echo "No description available"
            ;;
    esac
}

# Function to run the specified plugin
run_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            run_tteck_post-pve-install
            ;;
        "set_network")
            set_network
            ;;
        "update_locale_gen")
            update_locale_gen
            ;;
        "register_acme_account")
            register_acme_account
            ;;
        "disable_rpcbind")
            disable_rpcbind
            ;;
        "install_iptables_rule")
            install_iptables_rule
            ;;
        "add_ssh_key_to_authorized_keys")
            add_ssh_key_to_authorized_keys
            ;;
        "change_ssh_port")
            change_ssh_port
            ;;
        *)
            echo "Unknown plugin: $1"
            ;;
    esac
}

# Default list of plugins
plugin_list="run_tteck_post-pve-install,set_network,update_locale_gen,register_acme_account,disable_rpcbind,install_iptables_rule,add_ssh_key_to_authorized_keys,change_ssh_port"

# Parsing command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -v|--vnc-password)
            vnc_password="$2"
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
        -e|--acme-email)
            acme_email="$2"
            shift
            shift
            ;;
        --skip-installer)
            skip_installer=true
            shift
            ;;
        --disable)
            disabled_plugins="$2"
            IFS=',' read -ra plugins_to_disable <<< "$disabled_plugins"
            for plugin in "${plugins_to_disable[@]}"; do
                plugin_list="${plugin_list//$plugin/}"
            done
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

public_ipv4=$(ip -f inet addr show eth0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')



# Function to add SSH public key to authorized_keys
add_ssh_key_to_authorized_keys() {
    if [ -n "$ssh_key" ]; then
        if [ -f "$ssh_key" ]; then
            # Copy SSH key to local host via scp
            ssh-copy-id -f -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$ssh_key"  -p 5555 root@127.0.0.1  2>&1  | grep -v 'Warning: Permanently added '
            echo "Added SSH public key to authorized_keys"

            # Disable password authentication for SSH
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "sed -i 's/^PasswordAuthentication yes$/PasswordAuthentication no/' /etc/ssh/sshd_config"  2>&1  | grep -v 'Warning: Permanently added '
            echo "Password authentication disabled for SSH"
        else
            echo "Error: File '$ssh_key' does not exist."
            exit 1
        fi
    fi
}

change_ssh_port() {
    if [ -n "$ssh_port" ]; then
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "sed -i 's/^#Port.*$/Port $ssh_port/' /etc/ssh/sshd_config"  2>&1  | grep -v 'Warning: Permanently added '
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "echo 'Port $ssh_port' > /root/.ssh/config"  2>&1  | grep -v 'Warning: Permanently added '
        echo "SSH port changed to $ssh_port on proxmox server."
    fi
}

disable_rpcbind() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "systemctl disable --now rpcbind rpcbind.socket"  2>&1  | grep -v 'Warning: Permanently added '
    echo "rpcbind disabled on proxmox server."
}

install_iptables_rule() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        apt-get update &&
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections &&
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections &&
        apt-get install -y iptables-persistent &&
        iptables -I INPUT -i vmbr0 -p tcp -m tcp --dport 3128 -j DROP &&
        netfilter-persistent save
    "  2>&1  | grep -v 'Warning: Permanently added '
}

update_locale_gen() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        if grep -q \"^# *\$LC_NAME\" /etc/locale.gen; then
            sed -i \"s/^# *\$LC_NAME/\$LC_NAME/\" /etc/locale.gen
            locale-gen
            echo \"Updated /etc/locale.gen and generated locales for \$LC_NAME\"
        fi
    "  2>&1  | grep -v 'Warning: Permanently added '
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

    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 ~/interfaces_sample root@127.0.0.1:/etc/network/interfaces  2>&1  | grep -v 'Warning: Permanently added '
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "printf 'nameserver 185.12.64.1\nnameserver  185.12.64.2\n' > /etc/resolv.conf"  2>&1  | grep -v 'Warning: Permanently added '
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
    curl --remove-on-error -o "$latest_iso_name" "$ISO_URL/$latest_iso_name"

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

order_acme_certificate() {
    cat <<EOF > /root/acme_certificate_order_script.sh
#!/bin/bash

pvenode acme cert order

rm "/root/acme_certificate_order_script.sh"
rm "/etc/cron.d/acme_certificate_order_cron"
EOF

    chmod +x /root/acme_certificate_order_script.sh

    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 5555 /root/acme_certificate_order_script.sh 127.0.0.1:/root/acme_certificate_order_script.sh  2>&1  | grep -v 'Warning: Permanently added ' && ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 "
        echo \"@reboot root /root/acme_certificate_order_script.sh\" > /etc/cron.d/acme_certificate_order_cron && \
        chmod 644 /etc/cron.d/acme_certificate_order_cron
    "  2>&1  | grep -v 'Warning: Permanently added '
}

register_acme_account() {
    ssh -o CheckHostIP=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1 " 
        apt install -y expect && 
        expect -c \"
            spawn pvenode acme account register default $acme_email --directory https://acme-v02.api.letsencrypt.org/directory
            expect -re {Do you agree}
            send \"y\\\r\"
            interact
        \" && pvenode config set --acme domains=$(hostname -f) && 
    "  2>&1  | grep -v 'Warning: Permanently added '
    order_acme_certificate
}

run_tteck_post-pve-install() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1  -t  'bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/post-pve-install.sh)"'
}



# Call the function to download the latest Proxmox ISO
download_latest_proxmox_iso




if [ ! -n "$vnc_password" ]; then
    # Generate random VNC password
    vnc_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
fi
echo
echo "Connecto to vnc://$public_ipv4:5900 with password: $vnc_password"
echo "If VNC stuck before open installator, try to reconnect VNC client"
echo

# Detecting EFI/UEFI system
if [ -d "/sys/firmware/efi" ]; then
    bios="-bios /usr/share/ovmf/OVMF.fd"
else
    bios=""
fi



# Array to store disk information as text
hard_disks_text=()

# Read disk information using lsblk and store it in the array
while read -r line; do
    hard_disks_text+=("$line")
done < <(lsblk -o NAME,SIZE,SERIAL,VENDOR,MODEL,PARTTYPE -d -n -p | grep -v 'loop')

# Add a column with device path /dev/vd*
device_path="/dev/v"
counter=97  # ASCII code for 'a'
for ((i = 0; i < ${#hard_disks_text[@]}; i++)); do
    if (( $counter > 122 )); then  # If ASCII code exceeds 'z'
        echo "Too many disks to assign"
        break
    fi
    # Append device path to each disk entry
    hard_disks_text[$i]="${hard_disks_text[$i]} $device_path$(printf "\x$(printf %x $counter)"))"
    ((counter++))
done

# Display the list of disks with the added device path
for disk_info in "${hard_disks_text[@]}"; do
    echo "$disk_info"
done



hard_disks=()
while read -r line; do
    hard_disks+=("$line")
done < <(lsblk -o NAME -d -n -p | grep -v 'loop')

if [ ! -n "$skip_installer" ]; then
    # Building QEMU command with detected hard disks
    qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $latest_iso_name -vnc :0,password -monitor stdio -no-reboot"
    for disk in "${hard_disks[@]}"; do
        qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
    done

    # Running QEMU
    # echo "$qemu_command"
    eval "$qemu_command > /dev/null 2>&1"
fi



qemu_command="qemu-system-x86_64 -machine pc-q35-5.2 -enable-kvm $bios -cpu host -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -smp 4 -m 4096"
for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Running QEMU
# echo "$qemu_command"
eval "$qemu_command   > /dev/null 2>&1 &"

bg_pid=$!

# Performing SSH operations
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
fi

echo "Waiting for start SSH server on proxmox..."
check_ssh_server || echo "Fatal: Proxmox may not have started properly because SSH on socket 127.0.0.1:5555 is not working."
echo "Please enter the password for the root user that you set during the Proxmox installation."

ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1  2>&1  | grep -v 'Warning: Permanently added '
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1  -C exit  2>&1  | grep -v 'Warning: Permanently added '



# Run enabled plugins
for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
    run_plugin "$plugin"
done

kill $bg_pid