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
FW_DIR='/etc/pve/firewall'
MAX_CHUNKS=5
CHUNK_SIZE=50000
RED="\033[38;5;198m"
GREEN="\033[38;5;043m"
BLACK="\033[48;5;232m"
RESET="\033[0m"


function showHelp {
  echo -e "Proxmox PVE Firewall Rules updater\n"
  echo -e "Syntax\n  ./update-ip-blacklist.sh "
  echo -e "      will update IPv4 rules only (quick)\n"
	echo -e "Command line options\n----------------------"
	echo -e "  --all          will update IPv4 AND IPv6 rules"
	echo -e "  --fwdir=/etc/pve/firewall"
	echo -e "                 location of the firewall directory"
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
	      shift
	      ;;
		-a|--all)
	      export MODE=all
	      shift
	      ;;
		-d=*|--fwdir=*)
	      export FW_DIR="${i#*=}"
	      shift
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

# Write one blacklist_N.fw file with the given IPSET name and content file
function writeChunkFw {
	local DEST="$1"
	local IPSET_NAME="$2"
	local CONTENT_FILE="$3"
	local WORK="${DEST}.tmp"
	{
		echo "[IPSET $IPSET_NAME]"
		echo ""
		cat "$CONTENT_FILE"
		echo ""
	} > "$WORK" || { showError "ERROR writing $WORK"; return 1; }
	cp "$WORK" "$DEST" || { showError "ERROR copying to $DEST"; rm -f "$WORK"; return 1; }
	rm -f "$WORK"
}

parseOptions $@ || exit 1
showInfo "------\n`date`\nUpdating from abuseipdb\n  \n# `pwd`/$0\n-----"

# Check required tools before doing anything
for TOOL in wget iprange split; do
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

# Combine the IPv4 addresses into CIDR ranges
iprange $FILEv4 > iprange.txt

# Ensure we downloaded enough entries
IPRANGELINES=$(wc -l < iprange.txt)
if [ "$IPRANGELINES" -lt "500" ]; then
	showError "ERROR IPv4 range only contains $IPRANGELINES lines"
	exit 1
fi

CIDR=$(wc -l < iprange.txt)
LINES=$(grep -c '^[0-9]' "$FILEv4")

# Split iprange.txt into chunks of CHUNK_SIZE lines
rm -f chunk_*.txt
split -l $CHUNK_SIZE iprange.txt chunk_
CHUNKS=( chunk_* )
if [[ ${#CHUNKS[@]} -gt $MAX_CHUNKS ]]; then
	showError "ERROR IPv4 list split into ${#CHUNKS[@]} chunks, exceeding MAX_CHUNKS=$MAX_CHUNKS"
	showError "Increase MAX_CHUNKS or CHUNK_SIZE in the script."
	exit 1
fi

# Write blacklist_N.fw for each chunk; clear any unused slots
for N in $(seq 1 $MAX_CHUNKS); do
	DEST="$FW_DIR/blacklist_$N.fw"
	IDX=$(( N - 1 ))
	if [[ $IDX -lt ${#CHUNKS[@]} ]]; then
		CHUNKFILE="${CHUNKS[$IDX]}"
		CHUNKLINES=$(wc -l < "$CHUNKFILE")
		showInfo "Writing blacklist_$N.fw ($CHUNKLINES CIDR ranges)..."
		writeChunkFw "$DEST" "zzzblacklist4_$N" "$CHUNKFILE" || exit 1
	else
		# Write an empty IPSET so PVE doesn't error on a missing referenced set
		printf "[IPSET zzzblacklist4_$N]\n\n" > "$DEST"
	fi
done

NCHUNKS=${#CHUNKS[@]}
showInfo "$LINES IPv4 addresses → $CIDR CIDR ranges → $NCHUNKS file(s) — $(date '+%Y-%m-%d')"

# Write blacklist_ipv6.fw
DEST_V6="$FW_DIR/blacklist_ipv6.fw"
WORK_V6="blacklist_ipv6.fw.tmp"
{
	echo "[IPSET zzzblacklist6]"
	echo ""
	if [[ -f "$FILEv6" ]]; then
		LINESv6=$(wc -l < "$FILEv6")
		if [[ "$LINESv6" -gt 5 ]]; then
			cat "$FILEv6" > iprange6.txt
			LINESip6=$(wc -l < iprange6.txt)
			cat iprange6.txt
			showInfo "$LINESip6 IPv6 addresses written to blacklist_ipv6.fw"
		fi
	fi
	echo ""
} > "$WORK_V6" || { showError "ERROR building $WORK_V6"; exit 1; }
cp "$WORK_V6" "$DEST_V6" || { showError "ERROR writing $DEST_V6"; rm -f "$WORK_V6"; exit 1; }
rm -f "$WORK_V6"

GREEN="\033[38;5;226m"
showInfo "Reloading PVE Firewall rules"
pve-firewall compile > /dev/null
pve-firewall restart
GREEN="\033[38;5;046m"
showInfo "------\nThe End.\n\n"

# you may delete the temporary folder at the end, but I keep it just in case I
# need to debug it later:
# rm -rf tmp/* 2> /dev/null
