#!/bin/bash

# Proxmox PVE Firewall Rules updater
# By Riccardo Zorn
# License: GPL 2.0
# fasterweb.net
# 2024/07/12
#
# https://github.com/riczorn/pve-firewall-helper
#
# when scheduling,
	# redirect output to /var/log/pve-firewall-helper_log i.e.
# /opt/pve-firewall-helper/update-ip-blacklist.sh >> /var/log/pve-firewall-helper_log

MODE=ipv4 # all | ipv4
CLUSTERFILE='/etc/pve/firewall/cluster.fw'
RED="\033[38;5;198m"
GREEN="\033[38;5;043m"
BLACK="\033[48;5;232m"
RESET="\033[0m"


function showHelp {
  echo -e "Proxmox PVE Firewall Rules updated\n"
  echo -e "Syntax\n  ./update-ip-blacklist.sh "
  echo -e "      will update IPv4 rules only (quick)\n"
	echo -e "Command line options\n----------------------"
#  echo -e "  --ipv4         will update IPv4 rules"
	echo -e "  --all          will update IPv4 AND IPv6 rules"
	echo -e "  --clusterfile=/etc/pve/firewall/cluster.fw"
	echo -e "                 location of the cluster.fw file"
}

function showError {
	echo -e "$RED$@$RESET"
}

function showInfo {
	echo -e "$GREEN$@$RESET"
}


function parseOptions {
	for i in "$@"; do
	  case $i in
	    -ipv4|-v4|--ipv4|--v4|--IPv4|-IPv4|--IPV4|-IPV4)
	      export MODE=ipv4
	      shift # past argument with no value
	      ;;
		-a|--all)
	      export MODE=all
	      shift # past argument with no value
	      ;;
		-c=*|--clusterfile=*)
	      export CLUSTERFILE="${i#*=}"
	      shift # past argument=value
	      ;;
		-h|--help)
				showHelp
				return 1
				;;
	    -*|--*)
	      showError "\nUnknown option $i\n\n"
				showHelp
	      return 1
	      ;;
	    *)
	      ;;
	  esac
	done
}

function buildIPv6 {
	cd "$1/db"
	# ls | sort -h | tail -n 30 | xargs -i  /usr/bin/ls "{}/{}.ipv6"
	# grab the last 30 days of ipv6 addresses. Add together, sort and uniq:
	SOURCE=abuseipdb-s100-30d.ipv6
	ls | sort -h | tail -n 30 | xargs -i  /usr/bin/cat "{}/{}.ipv6" > $SOURCE
	# now I'm the db folder; sort and uniq to the destination folder:
	DESTINATION="../abuseipdb-s100-30d.ipv6"
	cat "$SOURCE" | sort | uniq > "$DESTINATION"
	cd ../..
}

# echo -e "MODE: $MODE; Cluster file: $CLUSTERFILE"
parseOptions $@ || exit 1
showInfo "------\n`date`\nUpdating from abuseipdb\n  \n# `pwd`/$0\n-----"

rm -rf tmp/blocklist-abuseipdb-main 2> /dev/null
rm -f  tmp/abuseipdb* 2> /dev/null
mkdir tmp 2> /dev/null
cd tmp
GREEN="\033[38;5;120m"
echo "Download and extract the updated lists"

FILEv4=""
FILEv6=""
if [ "$MODE" == "ipv4" ]; then
	wget -q --show-progress https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4
	RETURN_VALUE=$?

	FILEv4=abuseipdb-s100-30d.ipv4
else
	wget -q --show-progress https://github.com/borestad/blocklist-ip/archive/refs/heads/main.zip
	unzip -q main.zip
	RETURN_VALUE=$?
	rm main.zip
	FILEv4=blocklist-abuseipdb-main/abuseipdb-s100-30d.ipv4
	buildIPv6 blocklist-abuseipdb-main/
	echo " IPv6 malicious hosts file created "
	FILEv6=blocklist-abuseipdb-main/abuseipdb-s100-30d.ipv6
fi

if [[ $RETURN_VALUE -ne 0 ]]; then
	showError "Error downloading to file `pwd`/$FILEv4"
	exit
fi

echo "File `pwd`/$FILEv4 downloaded"

# Validate the last line of the downloaded IPv4 file is a complete IP address.
# A truncated download (e.g. ending in "192.") would cause iprange to emit a
# broad CIDR like 192.0.0.0/8, banning an entire class-A block.
LASTLINE=$(tail -1 "$FILEv4")
if ! echo "$LASTLINE" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}'; then
	showError "ERROR last line of $FILEv4 is not a valid IPv4 address: '$LASTLINE'"
	showError "The file may be truncated. Aborting to protect the firewall."
	exit 1
fi

GREEN="\033[38;5;190m"
# make a backup
rm $CLUSTERFILE.bak 2> /dev/null
cp $CLUSTERFILE $CLUSTERFILE.bak

# Verify the cluster.fw contains the required markers
for MARKER in BEGIN_AUTOBLACKLIST4 END_AUTOBLACKLIST4 BEGIN_AUTOBLACKLIST6 END_AUTOBLACKLIST6; do
	if ! grep -q "# $MARKER" $CLUSTERFILE; then
		showError "ERROR $CLUSTERFILE is missing marker '# $MARKER'"
		showError "Add BEGIN_AUTOBLACKLIST4/END_AUTOBLACKLIST4 and BEGIN_AUTOBLACKLIST6/END_AUTOBLACKLIST6 comments inside the respective [IPSET] sections."
		exit 1
	fi
done

# Combine the IPv4 in CIDR ranges
iprange $FILEv4 > iprange.txt

# Ensure we downloaded enough entries
IPRANGELINES=`wc -l iprange.txt | tr -s ' ' | cut -f 1 -d ' '`
if [ "$IPRANGELINES" -lt "500" ]; then
	showError "ERROR IPv4 range only contains $IPRANGELINES lines"
	exit 1
fi

CIDR=`wc -l iprange.txt | tr -s ' ' | cut -f 1 -d ' '`
LINES=`wc -l $FILEv4 | tr -s ' ' | cut -f 1 -d ' '`

MSGv6=""
if [[ -f "$FILEv6" ]]; then
	LINESv6=`wc -l $FILEv6 | tr -s ' ' | cut -f 1 -d ' '`
	if [[ "$LINESv6" -gt 5 ]]; then
		cat $FILEv6 > iprange6.txt
		LINESip6=`wc -l iprange6.txt | tr -s ' ' | cut -f 1 -d ' '`
		MSGv6="plus $LINESip6 IPv6 addresses"
	fi
fi

# Build the replacement blocks (content only, markers are preserved in the file)
IPV4_BLOCK="$(cat iprange.txt)
# $LINES IPv4 addresses in $CIDR CIDR ranges $MSGv6 — updated $(date '+%Y-%m-%d')"

IPV6_BLOCK=""
if [[ -e "iprange6.txt" ]]; then
	IPV6_BLOCK="$(cat iprange6.txt)
# $MSGv6 — updated $(date '+%Y-%m-%d')"
fi

# Replace content between markers using awk; markers themselves are kept intact.
# This is resilient to section reordering and manual edits outside the markers.
awk -v ipv4="$IPV4_BLOCK" -v ipv6="$IPV6_BLOCK" '
	/# BEGIN_AUTOBLACKLIST4/ { print; print ipv4; skip=1; next }
	/# END_AUTOBLACKLIST4/   { skip=0 }
	/# BEGIN_AUTOBLACKLIST6/ { print; if (ipv6 != "") print ipv6; skip=1; next }
	/# END_AUTOBLACKLIST6/   { skip=0 }
	!skip { print }
' $CLUSTERFILE.bak > $CLUSTERFILE

showInfo "File created: `ls -lah $CLUSTERFILE`"

GREEN="\033[38;5;226m"
showInfo "Compile the PVE Firewall Rules: pve-firewall compile"
pve-firewall compile > /dev/null
printf "$BLACK"
for i in $(seq 20 6 240);
do
		printf "\033[38;5;${i}m."
		sleep 0.15
done

echo -e "$RESET\n"

showInfo "Restart the PVE Firewall"
pve-firewall restart
GREEN="\033[38;5;046m"
showInfo "------\nThe End.\n\n"

# you may delete the temporary folder at the end, but I keep it just in case I
# need to debug it later:
# rm -rf tmp/* 2> /dev/null
