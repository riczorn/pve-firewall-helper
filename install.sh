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

LOG=pve-firewall-helper_install_log

touch $LOG
tail -f $LOG  2> /dev/null &

apt -qq -y install zip unzip iprange

echo "Backup the initial configuration files of $PVE_FW_DIR" > $LOG

BACKUPFILE="/tmp/firewall-backup-$(date +%y-%m-%d).tar.gz"
echo "  to $BACKUPFILE" >> $LOG

tar czf $BACKUPFILE $PVE_FW_DIR/*.fw

if [ "$SLOWDOWN" == "1" ]; then
  echo "Installing"
  # Force updating the firewall rules every 1200 seconds instead of 10:
  sed -i 's/updatetime = 10;/updatetime = 1200;/g' /usr/share/perl5/PVE/Service/pve_firewall.pm
fi


INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_STORE="$INSTALL_DIR/pve-firewall"
SYSTEMD_SERVICE=/etc/systemd/system/pve-firewall-mount.service

# Seed the local firewall store: start from any existing /etc/pve/firewall files,
# then overlay cluster.fw and generic.fw from this repo.
echo "Seeding $FW_STORE from $PVE_FW_DIR and repo files..." >> $LOG
mkdir -p "$FW_STORE"
cp $PVE_FW_DIR/*.fw "$FW_STORE/" 2>/dev/null || true

echo "Copy initial cluster rules to $FW_STORE/" >> $LOG
cp cluster.fw "$FW_STORE/"

for P in `/usr/bin/lxc-ls`
do
        echo -e "  Copy initial firewall rules for the CT $P" >> $LOG
        cp generic.fw "$FW_STORE/$P.fw"
done

for P in `/usr/sbin/qm list | grep -v 'VMID' | tr -s ' ' | cut -d ' ' -f 2`
do
        echo -e "  Copy initial firewall rules for the VM $P" >> $LOG
        cp generic.fw "$FW_STORE/$P.fw"
done

echo "Setting up bind-mount of $FW_STORE over $PVE_FW_DIR..." >> $LOG

# Write the systemd unit that bind-mounts our folder over /etc/pve/firewall after pmxcfs
cat > $SYSTEMD_SERVICE << EOF
[Unit]
Description=Bind-mount $FW_STORE over $PVE_FW_DIR
# pve-cluster mounts pmxcfs (/etc/pve); we must run after it so the mountpoint exists
After=pve-cluster.service
Requires=pve-cluster.service
# pve-firewall must start after our mount is in place
Before=pve-firewall.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --bind $FW_STORE $PVE_FW_DIR
ExecStop=/bin/umount $PVE_FW_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pve-firewall-mount.service
systemctl start pve-firewall-mount.service
echo "pve-firewall-mount.service installed, enabled and started." >> $LOG

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
