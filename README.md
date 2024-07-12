# Proxmox firewall configuration helper
Generic Cluster and CT/VM Firewall Rules for Proxmox PVE Firewall
Includes update and insert of abuseipdb 60 days rules.
By Riccardo Zorn
License: GPL 2.0
fasterweb.net

## Please be careful. When you enable the firewall, you may block yourself out.

# Description

This set of scripts aims at making installation of a datacenter and node firewall easier on
Proxmox, including a script to update a massive blacklist of abuseipdb into the firewall rules.

# Installation

The script has a hardcoded path.

The install.sh makes a copy of your current configuration in /tmp/firewall-backup-date.tar.gz
then proceeds to create a firewall configuration for the Datacenter, and a firewall configuration for each of the containers and virtual machines installed.

## /etc/pve/firewall/cluster.fw

### Description

The default cluster-level firewall, which also defines the three sets used in the Virtual Machines (VM) and Containers (CT).

This file defines three sets/aliases for use by the VMs & CTs:
- dc/admins,
- dc/ovh,
- blacklist

The sets are mostly empty, and the initial configuration is to allow all traffic.

### Enable the rules

After running `install.sh` please open your Proxmox interface, and double check all the configurations at the datacenter level; in particular, enable any control panels and extra services you may have running on the Proxmox host. Most standard services are listed for your convenience, but disabled as usually the Proxmox host usually does not host customer services.

Once you are satisfied, open another ssh connection to the datacenter (just in case you block yourself out) and be sure to have your root password on hand in case you need to access from a recovery / kvm console.

### Test the rules

Now it's the first moment of truth: from the interface, enable the firewall at the datacenter level.

Test if you can open a new ssh connection, and that you can connect to proxmox.

If not, you're out of luck: use the other console you have open, or go to your host's control panel and use KVM / remote keyboard to access the machine, and STOP the firewall with
`pve-firewall stop`

Keep the console open as you may need it again.

### DO NOT RUN `update-ip-blacklist.sh` yet!

If everything is fine at the datacenter level, you want to copy your configuration back to the pre- and post- files so it will be restored after each change.

## /etc/pve/firewall/101.fw

This is the default file that is created for each of the CTs and VMs: it contains useful rules but it is disabled by default. It is meant to assist you in quickly creating a set of firewall rules that is meaningful for your machine.

