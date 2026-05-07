#!/bin/bash

# Proxmox PVE Firewall Rules installer
# By Riccardo Zorn
# License: GPL 2.0
# fasterweb.net
# 2024/07/12
#
# https://github.com/riczorn/pve-firewall-helper

PVE_FW_DIR=/etc/pve/firewall
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_SRC="$INSTALL_DIR/pve"

RED="\033[38;5;198m"
GREEN="\033[38;5;043m"
YELLOW="\033[38;5;226m"
CYAN="\033[38;5;051m"
RESET="\033[0m"

function showHelp {
  echo -e "${GREEN}Proxmox PVE Firewall Rules installer${RESET}\n"
  echo -e "${YELLOW}Syntax${RESET}"
  echo -e "  ${CYAN}./install.sh --install${RESET}"
  echo -e "      will copy firewall files to ${CYAN}$PVE_FW_DIR${RESET}\n"
  echo -e "  ${CYAN}./install.sh --install --slowdown${RESET}"
  echo -e "      will make Proxmox firewall rules update every 1200 seconds"
  echo -e "      instead of 10\n"
  echo -e "${RED}This will overwrite your firewall configuration. A backup is made.${RESET}\n"
}

ACTION=0
SLOWDOWN=0

for i in "$@"; do
  case $i in
    -i|--install)
      ACTION=install
      echo "Installing..."
      shift
      ;;
    -s|--slow|--slowdown)
      SLOWDOWN=1
      shift
      ;;
    -h|--help)
			showHelp
			exit 0
      ;;
    -*|--*)
      echo "Unknown option $i"
      showHelp
      exit 1
      ;;
    *)
      ;;
  esac
done

if [ "$ACTION" != "install" ]; then
  showHelp
  exit 0
fi

LOG=/var/log/pve-firewall-helper_install_log

touch $LOG
tail -f $LOG  2> /dev/null &

apt -qq -y install zip unzip iprange ipset

echo "Backup the initial configuration files of $PVE_FW_DIR" > $LOG

BACKUPFILE="/tmp/firewall-backup-$(date +%y-%m-%d).tar.gz"
echo "  to $BACKUPFILE" >> $LOG
tar czf $BACKUPFILE $PVE_FW_DIR/*.fw 2>/dev/null || true

if [ "$SLOWDOWN" == "1" ]; then
  # Force updating the firewall rules every 1200 seconds instead of 10:
  sed -i 's/updatetime = 10;/updatetime = 1200;/g' /usr/share/perl5/PVE/Service/pve_firewall.pm
fi

echo "Copying cluster.fw to $PVE_FW_DIR/" >> $LOG
cp "$FW_SRC/cluster.fw" "$PVE_FW_DIR/"

# Copy generic.fw for new CTs/VMs; patch existing ones with current REJECT rules
for P in $(/usr/bin/lxc-ls 2>/dev/null); do
	DEST="$PVE_FW_DIR/$P.fw"
	if [[ ! -f "$DEST" ]]; then
		echo "  Copy initial firewall rules for CT $P" >> $LOG
		cp "$FW_SRC/generic.fw" "$DEST"
	else
		echo "  Skipping CT $P — $DEST already exists" >> $LOG
	fi
done

for P in $(/usr/sbin/qm list 2>/dev/null | grep -v 'VMID' | tr -s ' ' | cut -d ' ' -f 2); do
	DEST="$PVE_FW_DIR/$P.fw"
	if [[ ! -f "$DEST" ]]; then
		echo "  Copy initial firewall rules for VM $P" >> $LOG
		cp "$FW_SRC/generic.fw" "$DEST"
	else
		echo "  Skipping VM $P — $DEST already exists" >> $LOG
	fi
done

echo "Installing ipset-blacklist restore service..." >> $LOG

IPSET_SAVE="$INSTALL_DIR/tmp/blacklist-rules.save"
SYSTEMD_SERVICE=/etc/systemd/system/blacklist-rules.service

# Create an empty save file if it doesn't exist yet (update-ip-blacklist.sh will populate it)
mkdir -p "$INSTALL_DIR/tmp"
touch "$IPSET_SAVE"

cat > $SYSTEMD_SERVICE << EOF
[Unit]
Description=Restore ipset blacklists and iptables DROP rules (zzzblacklist4, zzzblacklist6)
Before=pve-firewall.service network.target
# Re-run after iptables/netfilter is restarted so DROP rules are always restored
After=netfilter-persistent.service iptables.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -file $IPSET_SAVE
ExecStart=/bin/sh -c 'ipset list zzzblacklist4 >/dev/null 2>&1 && { iptables -C INPUT -m set --match-set zzzblacklist4 src -j DROP 2>/dev/null || iptables -I INPUT -m set --match-set zzzblacklist4 src -j DROP; } || true'
ExecStart=/bin/sh -c 'ipset list zzzblacklist6 >/dev/null 2>&1 && { ip6tables -C INPUT -m set --match-set zzzblacklist6 src -j DROP 2>/dev/null || ip6tables -I INPUT -m set --match-set zzzblacklist6 src -j DROP; } || true'
ExecStop=/sbin/ipset save -file $IPSET_SAVE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable blacklist-rules.service
echo "blacklist-rules.service installed and enabled." >> $LOG

echo -e "All rules have been created. \nNow press any key to continue restarting the firewall"
echo -e "or press CTRL-C to do it yourself later.\n"
echo "In that case, you will need to run:"
echo "   pve-firewall compile"
echo "   pve-firewall restart"

read -p "Press Enter to continue or CTRL-C to stop now." </dev/tty
echo ""
echo "Compiling the fw" >> $LOG
pve-firewall compile >> $LOG
sleep 10
echo "Restarting the fw" >> $LOG
pve-firewall restart >> $LOG

echo -e "------\nDone\n" >> $LOG
echo -e "------\nNow run update-ip-blacklist.sh to populate the blacklists, then check the rules and enable the firewall as explained in README.md\n\n" >> $LOG
