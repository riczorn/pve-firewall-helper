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

function showHelp {
  echo -e "Proxmox PVE Firewall Rules installer\n"
  echo -e "Syntax\n  ./install.sh --install "
  echo -e "      will copy firewall files to $PVE_FW_DIR\n"
  echo -e "  ./install.sh --install --slowdown"
  echo -e "      will make Proxmox firewall rules update every 1200 seconds "
  echo -e "      instead of 10\n"
  echo -e "This will overwrite your firewall configuration. A backup is made\n"
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

apt -qq -y install zip unzip iprange

echo "Backup the initial configuration files of $PVE_FW_DIR" > $LOG

BACKUPFILE="/tmp/firewall-backup-$(date +%y-%m-%d).tar.gz"
echo "  to $BACKUPFILE" >> $LOG
tar czf $BACKUPFILE $PVE_FW_DIR/*.fw 2>/dev/null || true

if [ "$SLOWDOWN" == "1" ]; then
  # Force updating the firewall rules every 1200 seconds instead of 10:
  sed -i 's/updatetime = 10;/updatetime = 1200;/g' /usr/share/perl5/PVE/Service/pve_firewall.pm
fi

# Copy cluster.fw and all blacklist templates
echo "Copying cluster.fw and blacklist templates to $PVE_FW_DIR/" >> $LOG
cp "$FW_SRC/cluster.fw" "$PVE_FW_DIR/"
for BL in "$FW_SRC"/blacklist_*.fw; do
	cp "$BL" "$PVE_FW_DIR/"
	echo "  copied $(basename $BL)" >> $LOG
done

# Copy generic.fw for CTs and VMs that don't have a config yet;
# patch IN REJECT blacklist rules into all existing *.fw files.
REJECT_BLOCK="IN REJECT -source +zzzblacklist4_1 -log warning
IN REJECT -source +zzzblacklist4_2 -log warning
IN REJECT -source +zzzblacklist4_3 -log warning
IN REJECT -source +zzzblacklist4_4 -log warning
IN REJECT -source +zzzblacklist4_5 -log warning
IN REJECT -source +zzzblacklist6 -log warning"

function patchRejectRules {
	local FILE="$1"
	# Remove any existing zzzblacklist REJECT lines
	sed -i '/IN REJECT -source +zzzblacklist/d' "$FILE"
	# Insert the full block after the [RULES] line
	sed -i "/^\[RULES\]/a $( echo "$REJECT_BLOCK" | sed 's/$/\\n/' | tr -d '\n' )" "$FILE"
}

for P in $(/usr/bin/lxc-ls 2>/dev/null); do
	DEST="$PVE_FW_DIR/$P.fw"
	if [[ ! -f "$DEST" ]]; then
		echo "  Copy initial firewall rules for CT $P" >> $LOG
		cp "$FW_SRC/generic.fw" "$DEST"
	else
		echo "  Patching CT $P" >> $LOG
		patchRejectRules "$DEST"
	fi
done

for P in $(/usr/sbin/qm list 2>/dev/null | grep -v 'VMID' | tr -s ' ' | cut -d ' ' -f 2); do
	DEST="$PVE_FW_DIR/$P.fw"
	if [[ ! -f "$DEST" ]]; then
		echo "  Copy initial firewall rules for VM $P" >> $LOG
		cp "$FW_SRC/generic.fw" "$DEST"
	else
		echo "  Patching VM $P" >> $LOG
		patchRejectRules "$DEST"
	fi
done

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
echo -e "------\nNow check the rules and enable the firewall as explained in README.md\n\n" >> $LOG
