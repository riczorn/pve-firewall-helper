#!/bin/bash

# Proxmox PVE Firewall Rules installer
# By Riccardo Zorn
# License: GPL 2.0
# fasterweb.net
# 2024/07/12
#
# https://github.com/riczorn/pve-firewall-helper

PVE_FW_DIR=/etc/pve/firewall

function showHelp {
  echo -e "Proxmox PVE Firewall Rules installer\n"
  echo -e "Syntax\n  ./install.sh --install "
  echo -e "      will copy firewall .cw files to $PVE_FW_DIR\n"
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
      shift # past argument with no value
      ;;
    -s|--slow|--slowdown)
      SLOWDOWN=1
      shift # past argument with no value
      ;;
    -h|--help)
			showhelp
			exit 0
      ;;
    -*|--*)
      echo "Unknown option $i"
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

LOG=pve-firewall-helper_install_log

touch $LOG
tail -f $LOG  2> /dev/null &

apt -qq -y install zip iprange

echo "Backup the initial configuration files of $PVE_FW_DIR" > $LOG

BACKUPFILE="/tmp/firewall-backup-$(date +%y-%m-%d).tar.gz"
echo "  to $BACKUPFILE" >> $LOG

tar czf $BACKUPFILE $PVE_FW_DIR/*.fw

if [ "$SLOWDOWN" == "1" ]; then
  echo "Installing"
  # Force updating the firewall rules every 1200 seconds instead of 10:
  sed -i 's/updatetime = 10;/updatetime = 1200;/g' /usr/share/perl5/PVE/Service/pve_firewall.pm
fi


echo "Copy initial cluster rules to $PVE_FW_DIR/" >> $LOG
cp cluster.fw $PVE_FW_DIR/

for P in `/usr/bin/lxc-ls`
do
        echo -e "  Copy intial firewall rules for the CT $P" >> $LOG
        cp generic.fw $PVE_FW_DIR/$P.fw
done

for P in `/usr/sbin/qm list | grep -v 'VMID' | tr -s ' ' | cut -d ' ' -f 2`
do
        echo -e "  Copy intial firewall rules for the VM $P" >> $LOG
        cp generic.fw $PVE_FW_DIR/$P.fw
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
