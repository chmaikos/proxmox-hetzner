#!/bin/bash

skip_installer=false
no_shutdown=false
verbose=false
specified_iface_name=""
sshpass=""
PRIVATE_ADDRESS="10.1.0.2/24"
PUBLIC_CIDR="10.10.10.10/32"
VLAN_ID="4000"
VLAN_ADDRESS="10.100.0.2/24"

source ./plugins.sh

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "OPTIONS:"
    echo "  -v, --vnc-password PASSWORD   Set VNC password"
    echo "  -P, --port PORT               Change default SSH port"
    echo "  -k, --ssh-key SSH_KEY         Add SSH public key to authorized_keys"
    echo "  -e, --acme-email EMAIL        Set email for ACME account, required for register_acme_account plugin"
    echo "  --skip-installer              Skip Proxmox installer and boot directly from installed disks"
    echo "  --no-shutdown                 Do not shut down the virtual machine after finishing work"
    echo "  --disable PLUGIN1,PLUGIN2     Disable specified plugins"
    echo "  --list-ifaces                 List network interfaces and exit"
    echo "  --iface-name NAME             Specify the network interface name directly"
    echo "  --sshpass PASSWORD            Specify the account password for PVE"
    echo "  --private-addr CIDR           Specify the private network XXX.XXX.XXX.XXX/CIDR"
    echo "  --public-addr CIDR            Specify the subnet network First-Usable-IP/CIDR"
    echo "  --vlan-addr CIDR              Specify the VLAN network XXX.XXX.XXX.XXX/CIDR"
    echo "  --vlan-id ID                  Specify the VLAN ID of vSwitch"
    echo "  --verbose                     Enable extra log output"
    echo "  -h, --help                    Show this help message and exit"
    echo ""
    echo "Available plugins (default enabled):"
    for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
        echo "  $plugin: $(describe_plugin "$plugin")"
    done
}

describe_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            echo "Run additional post-installation tasks from https://tteck.github.io/Proxmox/"
            ;;
        "set_network")
            echo "Configure WAN network settings based on Hetzner rescue network"
            ;;
        "set_private_network")
            echo "Configure LAN network settings based on inputs"
            ;;
        "set_public_network")
            echo "Configure Hetzner Subnet based on inputs. Supply the first usable IP in the Subnet"
            ;;
        "set_vswitch_network")
            echo "Configure Hetzner vSwitch Network based on inputs. Setup vSwitch first"
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

run_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            run_tteck_post-pve-install
            ;;
        "set_network")
            set_network
            ;;
        "set_private_network")
            set_private_network
            ;;
        "set_public_network")
            set_public_network
            ;;
        "set_vswitch_network")
            set_vswitch_network
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

print_interface_names() {
    for iface in $(ls /sys/class/net | grep -v lo); do
        echo "Interface: $iface"
        echo "$(udevadm info -e | grep -m1 -A20 "^P.*${iface}" | grep 'ID_NET_NAME_PATH' | awk -F'=' '{print "  " $1 ": " $2}')"
        echo "$(udevadm info -e | grep -m1 -A20 "^P.*${iface}" | grep 'ID_NET_NAME_ONBOARD' | awk -F'=' '{print "  " $1 ": " $2}')"
    done
    exit 0
}

plugin_list="set_vswitch_network,set_public_network,set_private_network,update_locale_gen,set_network,run_tteck_post-pve-install,register_acme_account,disable_rpcbind,install_iptables_rule,add_ssh_key_to_authorized_keys,change_ssh_port"

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
        --no-shutdown)
            no_shutdown=true
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
        --list-ifaces)
            print_interface_names
            exit 0
            ;;
        --iface-name)
            specified_iface_name="$2"
            shift
            shift
            ;;
        --sshpass)
            sshpass="$2"
            shift
            shift
            ;;
        --private-addr)
            PRIVATE_ADDRESS="$2"
            shift
            shift
            ;;
        --public-addr)
            PUBLIC_CIDR="$2"
            shift
            shift
            ;;
        --vlan-id)
            VLAN_ID="$2"
            shift
            shift
            ;;
        --vlan-addr)
            VLAN_ADDRESS="$2"
            shift
            shift
            ;;
        --verbose)
            verbose=true
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

init_proxmox

if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
fi

echo "Waiting for the SSH server on Proxmox to start..."
check_ssh_server || echo "Fatal: Proxmox may not have started properly because SSH on socket 127.0.0.1:5555 is not working."
echo
apt install sshpass -y
if [ -n "$sshpass" ]; then
    echo "Automatically copying SSH public key to Proxmox using provided password..."
    sshpass -p "$sshpass" ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1  -C exit  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
else
    echo "No password provided for ssh-copy-id, manual password entry required."
    ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 127.0.0.1  -C exit  2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
fi

echo "Remember not to select the reboot option in the 'run_tteck_post-pve-install' plugin!"

for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
    run_plugin "$plugin"
done

if [ "$no_shutdown" = false ]; then
    echo "Shutting down the virtual machine..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 5555 root@127.0.0.1 "poweroff" 2>&1  | egrep -v '(Warning: Permanently added |Connection to 127.0.0.1 closed)'
fi
