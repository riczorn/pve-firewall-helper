# PVE Firewall helper
## Proxmox firewall configuration helper

Generic Cluster and CT/VM Firewall Rules for Proxmox PVE Firewall
Includes update and insert of abuseipdb 30 days rules.
By Riccardo Zorn
License: GPL 2.0
fasterweb.net

- [Project Home][pve-firewall-helper]
- [IP worst IPv4 & IPv6 offenders][abuseipdb]

[pve-firewall-helper]: https://github.com/riczorn/pve-firewall-helper
[abuseipdb]: https://github.com/borestad/blocklist-abuseipdb/

#### Please be careful. When you enable the firewall, you may block yourself out.

## Description

This set of scripts aims at making installation of a datacenter and node firewall easier on
Proxmox, including a script to update a massive blacklist of abuseipdb into the firewall rules.

## Installation

The install.sh makes a copy of your current configuration in /tmp/firewall-backup-date.tar.gz
then proceeds to create a firewall configuration for the Datacenter, and a firewall configuration for each of the containers and virtual machines installed, based on the files cluster.fw and generic.fw included.

It also invokes `apt install zip iprange`: replace it with your favourite package manager but make sure you have both installed, else the ip range will be empty.

Clone the repo with your favourite method i.e.

```
[/opt]# git clone https://github.com/riczorn/pve-firewall-helper.git
```
or just this once:

```bash
wget https://github.com/riczorn/pve-firewall-helper/archive/refs/heads/main.zip
unzip main.zip
rm main.zip
mv pve-firewall-helper-main pve-firewall-helper
```

## Syntax

```bash
./install.sh --install
```

or

```bash
./install.sh --install --slowdown
```

to make pve-firewall only update every 1200 seconds instead of 10.

## `/etc/pve/firewall/cluster.fw`

### Description

The default cluster-level firewall, which also defines the three sets used in the Virtual Machines (VM) and Containers (CT).

- dc/admins, (this should be your ips)
- dc/ovh,    (in case you use OVH's server monitoring)
- zzzblacklist4  (a placeholder for the set of IPv4 addresses from abuseipdb)
- zzzblacklist6  (a placeholder for the set of IPv6 addresses from abuseipdb)


    The names start with zzz as Proxmox interface
    is keen on sorting the IPSets, this way they
    stay last before the [RULES].

The sets are mostly empty, and the initial configuration is to allow all traffic.

### Enable the rules

After running `install.sh` please open your Proxmox interface, and double check all the configurations at the datacenter level; in particular, enable any control panels and extra services you may have running on the Proxmox host. Most standard services are listed for your convenience, but they are disabled by default, since usually the Proxmox server does nothing else.

Once you are satisfied, open another `ssh` connection to the datacenter (just in case you block yourself out) and be sure to have your root password on hand in case you need to access from a recovery / kvm console.

### Test the rules

Now it's the first moment of truth: from the interface, enable the firewall at the datacenter level.

Test if you can open a new ssh connection, and that you can connect to Proxmox.

If not, you're out of luck: use the other console you have open, or if it's stuck go to your host's control panel and use KVM / remote keyboard to access the machine, and STOP the firewall with

```bash
pve-firewall stop
```

Keep the console open as you may need it again.

### DO NOT RUN `update-ip-blacklist.sh` yet!

If everything is fine at the datacenter level, you might want to make a backup of your initial configuration files in /etc/pve/firewall.

## `/etc/pve/firewall/101.fw`

This is the default file that is created for each of the CTs and VMs, using the `generic.fw` included. Each VM's firewall is enabled by default, but it is set to ALLOW all traffic, except for the blacklist. Some typical LAMP + mail services are enabled, other less common services are created for your convenience but they are not enabled.

This is meant to assist you in quickly creating a set of firewall rules that is meaningful for your machine from the Proxmox interface.

## If you use NAT - Network Address Translation

In case you make use of NAT in your virtual servers configuration, you will need to allow the NAT traffic.

This example is based on OVH standard Proxmox configuration, where vmbr0 is the public bridge and vmbr1 is the private bridge, and assumes 192.168.63.0/24 is your IPv4 network.

You may insert the rules directly in `/etc/network/interfaces` in the vmbr1 section:

```bash
auto vmbr1
iface vmbr1 inet static
  address 192.168.63.1/24
  bridge_ports none
  bridge_stp off
  bridge_fd 0
  post-up echo 1 > /proc/sys/net/ipv4/ip_forward
  post-up   iptables -t nat -A POSTROUTING -s '192.168.63.0/24' -o vmbr0 -j MASQUERADE
  post-down iptables -t nat -D POSTROUTING -s '192.168.63.0/24' -o vmbr0 -j MASQUERADE
post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

References
- [running with NAT on OVH][nat-ovh]
- [NAT and Firewall][nat-fw]

[nat-ovh]: https://bobcares.com/blog/setup-nat-on-proxmox/
[nat-fw]: https://forum.proxmox.com/threads/no-more-nat-masquerading-after-firewall-usage.63459/

## Updating the abuseipdb list

```bash
./update-ip-blacklist.sh
```

is the script that will download the updated abuseipdb list(s),
and update the `/etc/pve/firewall/cluster.fw`'s `blocklist4-6` `IPSET`s.

### Syntax

  (update IPv4 rules only - quick)
  ```bash
  ./update-ip-blacklist.sh
  ```

### Command line options
```
  --all          will update IPv4 AND IPv6 rules
  --clusterfile=/etc/pve/firewall/cluster.fw
                 location of the cluster.fw file
```

## How it works
If only IPv4 rules are required, only abuseipdb-s100-30d.ipv4, a 1MB download.

If IPv6 rules are included (--all) then the full zip from the repo is downloaded, then the individual days sorted, in order to extract the latest 30 days's worth of IPv6 to block. This takes longer as currently the repo is 90MB and goes all the way back to 2022.

In July 2024, the 30-days list of IPv4 addresses was 75,000 addresses, which iprange grouped in 70,000 CIDR ranges, and only 170 IPv6 hosts

## Scheduling

Since the IPv6 addresses are very few, and quite irrelevant at the moment, you may schedule a weekly download of the full archive, and quick daily updates of just the IPv4 database.

### With symbolic links
```bash
ln -s /opt/pve-firewall-helper/update-ip-blacklist.sh /etc/cron.daily/update_ip_blacklist

```

### Edit Crontab file

`nano /etc/crontab`

```js
20 4 * * 7	root	/opt/pve-firewall-helper/update-ip-blacklist.sh --all > /var/log/pve-firewall-helper_log
40 4 * * *	root	/opt/pve-firewall-helper/update-ip-blacklist.sh >> /var/log/pve-firewall-helper_log
```
