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
	local DIR="$1"
	if [[ ! -d "$DIR/db" ]]; then
		showError "ERROR buildIPv6: directory $DIR/db not found"
		return 1
	fi
	cd "$DIR/db"
	SOURCE=abuseipdb-s100-30d.ipv6
	ls | sort -h | tail -n 30 | xargs -i /usr/bin/cat "{}/{}.ipv6" > "$SOURCE"
	DESTINATION="../abuseipdb-s100-30d.ipv6"
	sort < "$SOURCE" | uniq > "$DESTINATION"
	cd ../..
}

# echo -e "MODE: $MODE; Cluster file: $CLUSTERFILE"
parseOptions $@ || exit 1
showInfo "------\n`date`\nUpdating from abuseipdb\n  \n# `pwd`/$0\n-----"

# Check required tools before doing anything
for TOOL in wget iprange; do
	if ! command -v $TOOL &>/dev/null; then
		showError "ERROR required tool '$TOOL' not found. Run: apt install $TOOL"
		exit 1
	fi
done
if [[ "$MODE" == "all" ]] && ! command -v unzip &>/dev/null; then
	showError "ERROR 'unzip' not found (required for --all mode). Run: apt install unzip"
	exit 1
fi

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
	if [[ $? -ne 0 ]]; then
		showError "Error downloading IPv4 list"
		exit 1
	fi
	FILEv4=abuseipdb-s100-30d.ipv4
else
	wget -q --show-progress https://github.com/borestad/blocklist-ip/archive/refs/heads/main.zip
	if [[ $? -ne 0 ]]; then
		showError "Error downloading main.zip"
		exit 1
	fi
	unzip -q main.zip
	if [[ $? -ne 0 ]]; then
		showError "Error extracting main.zip"
		rm -f main.zip
		exit 1
	fi
	rm main.zip
	FILEv4=blocklist-abuseipdb-main/abuseipdb-s100-30d.ipv4
	if ! buildIPv6 blocklist-abuseipdb-main/; then
		showError "ERROR building IPv6 list. Aborting."
		exit 1
	fi
	echo " IPv6 malicious hosts file created "
	FILEv6=blocklist-abuseipdb-main/abuseipdb-s100-30d.ipv6
fi

echo "File $(pwd)/$FILEv4 downloaded"

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

# Verify the cluster.fw contains the required markers.
# If the live file is missing markers (e.g. corrupted by a prior failed run),
# restore it from the repo copy next to this script before aborting.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_CLUSTERFILE="$SCRIPT_DIR/cluster.fw"
for MARKER in BEGIN_AUTOBLACKLIST4 END_AUTOBLACKLIST4 BEGIN_AUTOBLACKLIST6 END_AUTOBLACKLIST6; do
	if ! grep -q "# $MARKER" $CLUSTERFILE; then
		if [[ -f "$REPO_CLUSTERFILE" ]] && grep -q "# $MARKER" "$REPO_CLUSTERFILE"; then
			showError "WARNING $CLUSTERFILE is missing marker '# $MARKER' — restoring from $REPO_CLUSTERFILE"
			cp "$REPO_CLUSTERFILE" "$CLUSTERFILE"
			break
		fi
		showError "ERROR $CLUSTERFILE is missing marker '# $MARKER'"
		showError "Add BEGIN_AUTOBLACKLIST4/END_AUTOBLACKLIST4 and BEGIN_AUTOBLACKLIST6/END_AUTOBLACKLIST6 comments inside the respective [IPSET] sections."
		exit 1
	fi
done

# Combine the IPv4 addresses into CIDR ranges
iprange $FILEv4 > iprange.txt

# Ensure we downloaded enough entries
IPRANGELINES=`wc -l iprange.txt | tr -s ' ' | cut -f 1 -d ' '`
if [ "$IPRANGELINES" -lt "500" ]; then
	showError "ERROR IPv4 range only contains $IPRANGELINES lines"
	exit 1
fi

CIDR=$(wc -l < iprange.txt)
LINES=$(grep -c '^[0-9]' "$FILEv4")

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
cat iprange.txt > ipv4_block.txt
echo "# $LINES IPv4 addresses in $CIDR CIDR ranges $MSGv6 — updated $(date '+%Y-%m-%d')" >> ipv4_block.txt

> ipv6_block.txt
if [[ -e "iprange6.txt" ]]; then
	cat iprange6.txt > ipv6_block.txt
	echo "# $MSGv6 — updated $(date '+%Y-%m-%d')" >> ipv6_block.txt
fi

# Replace content between markers using head/tail to avoid awk stdout size limits.
# Each section (IPv4, IPv6) is handled in a separate pass so order doesn't matter.
# All work is done on temp files; cluster.fw is only overwritten on full success.
# The bind mount (pve-firewall-mount.service) ensures cluster.fw lives on the regular
# filesystem with no size limit, while PVE reads it from /etc/pve/firewall/ as normal.

function replaceBlock {
	local FILE="$1"
	local BEGIN_MARKER="$2"
	local END_MARKER="$3"
	local BLOCK_FILE="$4"
	local OUT="$5"

	local BEGIN_LINE END_LINE TOTAL
	BEGIN_LINE=$(grep -n "# $BEGIN_MARKER" "$FILE" | cut -d: -f1)
	END_LINE=$(grep -n "# $END_MARKER" "$FILE" | cut -d: -f1)
	TOTAL=$(wc -l < "$FILE")

	if [[ -z "$BEGIN_LINE" || -z "$END_LINE" ]]; then
		showError "ERROR markers $BEGIN_MARKER / $END_MARKER not found in $FILE"
		return 1
	fi

	# lines before and including the BEGIN marker
	head -n "$BEGIN_LINE" "$FILE" > "$OUT"        || { showError "ERROR head failed for $BEGIN_MARKER"; return 1; }
	# the new block content
	cat "$BLOCK_FILE" >> "$OUT"                   || { showError "ERROR cat failed for $BLOCK_FILE"; return 1; }
	# lines from the END marker to the end of file
	tail -n $(( TOTAL - END_LINE + 1 )) "$FILE" >> "$OUT" || { showError "ERROR tail failed for $END_MARKER"; return 1; }
}

WORK1="cluster.fw.tmp"
WORK2="cluster.fw.tmp2"

function cleanupTmp {
	rm -f "$WORK1" "$WORK2"
}

cp "$CLUSTERFILE" "$WORK1"

if ! replaceBlock "$WORK1" "BEGIN_AUTOBLACKLIST4" "END_AUTOBLACKLIST4" "ipv4_block.txt" "$WORK2"; then
	showError "ERROR failed to update IPv4 block. cluster.fw was not modified."
	cleanupTmp
	exit 1
fi
mv "$WORK2" "$WORK1"

if ! replaceBlock "$WORK1" "BEGIN_AUTOBLACKLIST6" "END_AUTOBLACKLIST6" "ipv6_block.txt" "$WORK2"; then
	showError "ERROR failed to update IPv6 block. cluster.fw was not modified."
	cleanupTmp
	exit 1
fi

# Both passes succeeded — copy result to cluster.fw
cp "$WORK2" "$CLUSTERFILE" || { showError "ERROR writing cluster.fw failed, original is intact. Temp files left: $(pwd)/$WORK2"; exit 1; }
cleanupTmp

showInfo "File updated: `ls -lah $CLUSTERFILE`"

GREEN="\033[38;5;226m"
showInfo "Reloading PVE Firewall rules"
pve-firewall compile > /dev/null
pve-firewall restart
GREEN="\033[38;5;046m"
showInfo "------\nThe End.\n\n"

# you may delete the temporary folder at the end, but I keep it just in case I
# need to debug it later:
# rm -rf tmp/* 2> /dev/null
