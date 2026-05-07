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
  echo -e "  ${CYAN}./install.sh --install ${RESET}[options]\n"
  echo -e "${YELLOW}Options${RESET}"
  echo -e "  ${CYAN}--slowdown${RESET}      make pve-firewall update every 1200s instead of its default 10s"
  echo -e "  ${CYAN}--no-input${RESET}      do not block on the INPUT chain   (host traffic)"
  echo -e "  ${CYAN}--no-forward${RESET}    do not block on the FORWARD chain (VM/CT traffic)"
  echo -e "  ${CYAN}--no-output${RESET}     do not block on the OUTPUT chain  (outbound traffic)\n"
  echo -e "${RED}This will overwrite your firewall configuration. A backup is made.${RESET}\n"
}

ACTION=0
SLOWDOWN=0
BLOCK_INPUT=1
BLOCK_FORWARD=1
BLOCK_OUTPUT=1

for i in "$@"; do
  case $i in
    -i|--install)
      ACTION=install
      echo "Installing..."
      shift
      ;;
    --slowdown)
      SLOWDOWN=1
      shift
      ;;
    --no-input)
      BLOCK_INPUT=0; shift ;;
    --no-forward)
      BLOCK_FORWARD=0; shift ;;
    --no-output)
      BLOCK_OUTPUT=0; shift ;;
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

apt -qq -y install iprange ipset

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

# Build the chain restore lines based on selected options
CHAIN_EXECS=""
if [[ $BLOCK_INPUT == 1 ]]; then
	CHAIN_EXECS+="ExecStart=/bin/sh -c 'ipset list zzzblacklist4 >/dev/null 2>&1 && { iptables -C INPUT -m set --match-set zzzblacklist4 src -j DROP 2>/dev/null || iptables -I INPUT -m set --match-set zzzblacklist4 src -j DROP; } || true'\n"
fi
if [[ $BLOCK_FORWARD == 1 ]]; then
	CHAIN_EXECS+="ExecStart=/bin/sh -c 'ipset list zzzblacklist4 >/dev/null 2>&1 && { iptables -C FORWARD -m set --match-set zzzblacklist4 src -j DROP 2>/dev/null || iptables -I FORWARD -m set --match-set zzzblacklist4 src -j DROP; } || true'\n"
fi
if [[ $BLOCK_OUTPUT == 1 ]]; then
	CHAIN_EXECS+="ExecStart=/bin/sh -c 'ipset list zzzblacklist4 >/dev/null 2>&1 && { iptables -C OUTPUT -m set --match-set zzzblacklist4 dst -j DROP 2>/dev/null || iptables -I OUTPUT -m set --match-set zzzblacklist4 dst -j DROP; } || true'\n"
fi

cat > $SYSTEMD_SERVICE << EOF
[Unit]
Description=Restore ipset blacklists and iptables DROP rules (zzzblacklist4)
Before=pve-firewall.service network.target
After=netfilter-persistent.service iptables.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -file $IPSET_SAVE
$(echo -e "$CHAIN_EXECS")
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
