## Install Proxmox 7.4 on Hetzner Dedicated Server
- iso mode with UEFI
- 2 x NVMe SSD Drives

<img src="https://github.com/ariadata/proxmox-hetzner/raw/main/files/icons/proxmox.png" alt="Proxmox" height="48" /> <img src="https://github.com/ariadata/proxmox-hetzner/raw/main/files/icons/hetzner.png" alt="Hetzner" height="38" /> 

![](https://img.shields.io/github/stars/ariadata/proxmox-hetzner.svg)
![](https://img.shields.io/github/watchers/ariadata/proxmox-hetzner.svg)
![](https://img.shields.io/github/forks/ariadata/proxmox-hetzner.svg)
---

### Prepare the rescue from hetzner robot manager
* Select the Rescue tab for the specific server, via the hetzner robot manager
* * Operating system=Linux
* * Architecture=64 bit
* * Public key=*optional*
* --> Activate rescue system
* Select the Reset tab for the specific server,
* Check: Execute an automatic hardware reset
* --> Send
* Wait a few mins
* Connect via ssh/terminal to the rescue system running on your server

#### Install requirements and Install Proxmox:
```shell
wget https://github.com/WMP/proxmox-hetzner/raw/main/install-proxmox.sh
bash install-proxmox.sh --help
```

* Install Proxmox and attention to these :
  * choose `zfs` partition type
  * choose `lz4` in compress type of advanced partitioning
  * do not add real IP info in network configuration part (just leave defaults!)
  * close VNC window after system rebooted and waits for reconnect


* For `private subnet` append these lines to /etc/network/interface file  :
```apacheconf
auto vmbr1
iface vmbr1 inet static
    address 192.168.20.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '192.168.20.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '192.168.20.0/24' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1

iface vmbr1 inet6 static
	address 2a01:4f8:201:3315:1::1/80
```

* For `public subnet` append these lines to  /etc/network/interface file (first-Usable-IP/subnet) :
```apacheconf
auto vmbr2
iface vmbr2 inet static
    address 46.40.125.209/28
    bridge-ports none
    bridge-stp off
    bridge-fd 0

iface vmbr2 inet6 static
    address 2a01:4f8:201:3315:2::1/80
```

* For `vlan support` append these lines to  /etc/network/interface file  :
  * You have to create a vswitch with ID `4000` in your robot panel of hetzner. 
```apacheconf
auto vlan4000
iface vlan4000 inet static
    address 10.0.1.5/24
    mtu 1400
    vlan-raw-device vmbr0
    up ip route add 10.0.0.0/16 via 10.0.1.1 dev vlan4000
    down ip route del 10.0.0.0/16 via 10.0.1.1 dev vlan4000
```

* Reboot main `rescue` ssh :
```shell
reboot
```

* after a few minutes , login again to your proxmox server with ssh on port `22` or other if you change ssh port

### Post Install : 
* run this commands:
```shell
echo "nf_conntrack" >> /etc/modules
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-proxmox.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-proxmox.conf
echo "net.netfilter.nf_conntrack_max=1048576" >> /etc/sysctl.d/99-proxmox.conf
echo "net.netfilter.nf_conntrack_tcp_timeout_established=28800" >> /etc/sysctl.d/99-proxmox.conf

```

* Limit ZFS Memory Usage According to [This Link](https://pve.proxmox.com/wiki/ZFS_on_Linux#sysadmin_zfs_limit_memory_usage) :
```shell
echo "options zfs zfs_arc_min=$[6 * 1024*1024*1024]" >> /etc/modprobe.d/99-zfs.conf
echo "options zfs zfs_arc_max=$[12 * 1024*1024*1024]" >> /etc/modprobe.d/99-zfs.conf
update-initramfs -u
```

* Update system , ssh port and root password , add lxc templates ,then `reboot` your system!
```shell
apt update && apt -y upgrade && apt -y autoremove
bash <(curl -Ls https://gist.github.com/pcmehrdad/2fbc9651a6cff249f0576b784fdadef0/raw)
passwd
pveam update
reboot
```
#### Login to `Web GUI`:
**https://IP_ADDRESS:8006/**

#### Do other configs like this : 
> MASQUERADE and NAT rules, by using samples [example](https://github.com/ariadata/proxmox-hetzner/raw/main/files/iptables-sample) | 
[rules.v4](https://github.com/ariadata/proxmox-hetzner/blob/main/files/rules.v4) |
[rules.v6](https://github.com/ariadata/proxmox-hetzner/blob/main/files/rules.v6)
```bash
iptables -t nat -A PREROUTING -d 1234/32 -p tcp --dport 10001 -j DNAT --to 192.168.20.100:22
iptables -t nat -A PREROUTING -d 1.2.3.4/32 -p tcp -m multiport --dports 80,443,8181 -j DNAT --to-destination 192.168.1.2
```

#### Some useful links :
```
https://github.com/extremeshok/xshok-proxmox
https://github.com/extremeshok/xshok-proxmox/tree/master/hetzner
https://88plug.com/linux/what-to-do-after-you-install-proxmox/
https://gist.github.com/gushmazuko/9208438b7be6ac4e6476529385047bbb
https://github.com/johnknott/proxmox-hetzner-autoconfigure
https://github.com/CasCas2/proxmox-hetzner
https://github.com/west17m/hetzner-proxmox
https://github.com/SOlangsam/hetzner-proxmox-nat
https://github.com/HoleInTheSeat/ProxmoxStater
https://github.com/rloyaute/proxmox-iptables-hetzner
```

[Useful Helpers](https://tteck.github.io/Proxmox/)

[firewalld-cmd](https://computingforgeeks.com/how-to-install-and-configure-firewalld-on-debian/)

[proxmox-setup on blog](https://mehrdad.ariadata.co/notes/proxmox-setup-network-on-hetzner/)
