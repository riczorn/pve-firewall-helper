#!/bin/bash

# Proxmox PVE Firewall Rules updater
# By Riccardo Zorn
# License: GPL 2.0
# fasterweb.net
# 2024/07/12
#
# https://github.com/riczorn/pve-firewall-helper
#
# when scheduling, redirect output to /var/log/pve-firewall-helper_log i.e.
# /opt/pve-firewall-helper/update-ip-blacklist.sh >> /var/log/pve-firewall-helper_log

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TMP_DIR="$SCRIPT_DIR/tmp"
IPSET_SAVE="$TMP_DIR/blacklist-rules.save"

# URLS=("https://iplists.firehol.org/files/firehol_level1.netset" "https://iplists.firehol.org/files/firehol_level2.netset" "https://iplists.firehol.org/files/firehol_level3.netset" "https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4")
URLS=("https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/main/abuseipdb-s100-30d.ipv4")

FILE_DEST="$TMP_DIR/list.ipv4"
FILE_TMP="$TMP_DIR/list.tmp"

# Chains to enforce DROP rules on (all enabled by default)
BLOCK_INPUT=1
BLOCK_FORWARD=1
BLOCK_OUTPUT=1

RED="\033[38;5;198m"
GREEN="\033[38;5;043m"
LIGHTGREEN="\033[38;5;120m"
YELLOW="\033[38;5;226m"
BRIGHTGREEN="\033[38;5;046m"
BLACK="\033[48;5;232m"
RESET="\033[0m"
ENABLE_LOG=""


function showHelp {
	echo -e "${GREEN}Proxmox PVE Firewall Rules updater${RESET}\n"
	echo -e "${YELLOW}Syntax${RESET}"
	echo -e "  ./update-ip-blacklist.sh ${CYAN}[options]${RESET}\n"
	echo -e "${YELLOW}Options${RESET}"
	echo -e "  ${CYAN}--ipset-save=<path>${RESET}"
	echo -e "      location of the ipset save file"
	echo -e "      (default: $IPSET_SAVE)\n"
	echo -e "  ${CYAN}--no-input${RESET}    do not block on the INPUT chain   (host traffic)"
	echo -e "  ${CYAN}--no-forward${RESET}  do not block on the FORWARD chain (VM/CT traffic)"
	echo -e "  ${CYAN}--no-output${RESET}   do not block on the OUTPUT chain  (outbound traffic)"
	# echo -e "  ${GREEN}--enable-log${RESET}   log all actions to dmesg - /var/log/kern.log"
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
		-s=*|--ipset-save=*)
	      export IPSET_SAVE="${i#*=}"
	      shift
	      ;;
		--no-input)
		  BLOCK_INPUT=0; shift ;;
		--no-forward)
		  BLOCK_FORWARD=0; shift ;;
		--no-output)
		  BLOCK_OUTPUT=0; shift ;;
		# --enable-log)
		#   ENABLE_LOG='-m limit --limit 5/min -j LOG --log-prefix "PVE_FH: "'; shift ;;
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

# Load entries into a kernel ipset via bulk restore, then atomically swap with the live set.
# Using a temp set avoids any window where the live set is empty during the update.
function loadIpset {
	local IPSET_NAME="$1"
	local IPSET_TMP="${IPSET_NAME}_tmp"
	local FAMILY="$2"       # inet or inet6
	local SOURCE_FILE="$3"

	{
		echo "create $IPSET_TMP hash:net family $FAMILY hashsize 65536 maxelem 1048576"
		while IFS= read -r ENTRY; do
			[[ -z "$ENTRY" || "$ENTRY" == \#* ]] && continue
			echo "add $IPSET_TMP $ENTRY"
		done < "$SOURCE_FILE"
	} | ipset restore -exist

	ipset create $IPSET_NAME hash:net family $FAMILY hashsize 65536 maxelem 1048576 -exist
	ipset swap $IPSET_NAME $IPSET_TMP
	ipset destroy $IPSET_TMP
}

# Ensure DROP rules are in place for each enabled chain (idempotent: -C checks before -I inserts)
# INPUT:   traffic to the Proxmox host itself
# FORWARD: traffic routed to containers/VMs
# OUTPUT:  outbound traffic from the host and containers
function ensureDropRules {
	local IPSET_NAME="$1"
	[[ $BLOCK_INPUT   == 1 ]] && { iptables -C INPUT   -m set --match-set $IPSET_NAME src -j DROP 2>/dev/null || iptables -I INPUT   -m set --match-set $IPSET_NAME src -j DROP; }
	[[ $BLOCK_FORWARD == 1 ]] && { iptables -C FORWARD -m set --match-set $IPSET_NAME src -j DROP 2>/dev/null || iptables -I FORWARD -m set --match-set $IPSET_NAME src -j DROP; }
	[[ $BLOCK_OUTPUT  == 1 ]] && { iptables -C OUTPUT  -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null || iptables -I OUTPUT  -m set --match-set $IPSET_NAME dst -j DROP; }
	# Add logging logic
}

parseOptions $@ || exit 1
showInfo "------\n$(date)\nUpdating from abuseipdb\n# $0\n-----"

# Check required tools before doing anything
for TOOL in wget iprange ipset iptables; do
	if ! command -v $TOOL &>/dev/null; then
		showError "ERROR required tool '$TOOL' not found. Run: apt install $TOOL"
		exit 1
	fi
done

mkdir -p "$TMP_DIR"
GREEN="$LIGHTGREEN"
echo -e "$GREEN Download and extract the updated lists$RESET"

# Download IPv4 list
echo "" > $FILE_DEST
for F in ${URLS[@]}
do
rm $FILE_TMP
echo "Downloading $F..."
wget -q "$F" -O $FILE_TMP
if [[ $? -ne 0 ]]; then
	showError "Error downloading IPv4 list from $F"
	continue
fi
echo "... `wc -l $FILE_TMP` lines"
cat $FILE_TMP | sed -e 's/ \+#.*$//g'>> $FILE_DEST

done

FLENGTH=`wc -l < "$FILE_DEST"`
echo "IPv4 lists downloaded $FLENGTH addresses"

# Validate the last line of the downloaded IPv4 file is a complete IP address.
# A truncated download (e.g. ending in "192.") would cause iprange to emit a
# broad CIDR like 192.0.0.0/8, banning an entire class-A block.
LASTLINE=$(tail -1 "$FILE_DEST")
if ! echo "$LASTLINE" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}'; then
	showError "ERROR last line of $FILE_DEST is not a valid IPv4 address: '$LASTLINE'"
	showError "The file may be truncated. Aborting to protect the firewall."
	exit 1
fi

GREEN="\033[38;5;190m"

# Combine the IPv4 addresses into CIDR ranges
sort $FILE_DEST | uniq > $TMP_DIR/list.unique
iprange "$TMP_DIR/list.unique" > "$TMP_DIR/iprange.txt"

IPRANGELINES=$(wc -l < "$TMP_DIR/iprange.txt")
if [ "$IPRANGELINES" -lt "500" ]; then
	showError "ERROR IPv4 range only contains $IPRANGELINES lines"
	exit 1
fi

CIDR=$(wc -l < "$TMP_DIR/iprange.txt")
LINES=$(grep -c '^[0-9]' "$FILE_DEST")

showInfo "Loading $CIDR IPv4 CIDR ranges into kernel ipset zzzblacklist4..."
loadIpset "zzzblacklist4" "inet" "$TMP_DIR/iprange.txt"
ensureDropRules zzzblacklist4
showInfo "$LINES IPv4 addresses compressed to $CIDR CIDR ranges loaded — $(date '+%Y-%m-%d')"

# IPv6 source no longer maintained — destroy stale set if present
if ipset list zzzblacklist6 &>/dev/null; then
	ip6tables -D INPUT -m set --match-set zzzblacklist6 src -j DROP 2>/dev/null || true
	ipset destroy zzzblacklist6
	showInfo "Removed stale zzzblacklist6 ipset"
fi

# Persist ipsets so they survive reboots
showInfo "Saving ipsets to $IPSET_SAVE"
ipset save zzzblacklist4 > "$IPSET_SAVE"

GREEN="$YELLOW"
showInfo "Reloading PVE Firewall rules"
pve-firewall compile > /dev/null
pve-firewall restart
GREEN="$BRIGHTGREEN"
showInfo "------\nThe End.\n\n"

# you may delete the temporary folder at the end, but I keep it just in case I
# need to debug it later:
# rm -rf "$TMP_DIR"/* 2> /dev/null
