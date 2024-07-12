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

echo -e "------\n`date`\nUpdating from abuseipdb\n  # $0\n-----"

rm -rf tmp/* 2> /dev/null
mkdir tmp 2> /dev/null
cd tmp

echo "Scarico ed esplodo i nuovi"

FILEv4="will download file"
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
	FILEv6=blocklist-abuseipdb-main/db/abuseipdb-s100-latest.ipv6
fi

if [[ $RETURN_VALUE -ne 0 ]]; then
	echo "Error downloading to file `pwd`/$FILEv4"
	exit
fi

echo "File `pwd`/$FILEv4 downloaded"

# Extract the top and bottom portions of $CLUSTERFILE
rm $CLUSTERFILE.bak
cp $CLUSTERFILE $CLUSTERFILE.bak

cat $CLUSTERFILE | grep -B 1000000 '\[IPSET blacklist6\]' > pre.txt

cat $CLUSTERFILE | grep -A 1000000 '\[RULES\]' > post.txt
PRELINES=`wc -l pre.txt | tr -s ' ' | cut -f 1 -d ' '`
POSTLINES=`wc -l post.txt | tr -s ' ' | cut -f 1 -d ' '`

if [ "$PRELINES" -lt "5" ] || [ "$POSTLINES" -lt "5" ]; then
	echo "ERROR $CLUSTERFILE is not in a recognized format, exiting"
	exit
fi

iprange  $FILEv4  > iprange.txt

IPRANGELINES=`wc -l iprange.txt | tr -s ' ' | cut -f 1 -d ' '`
if [ "$IPRANGELINES" -lt "500" ]; then
	echo "ERROR IPv4 range only contains $IPRANGELINES lines"
	exit
fi

CIDR=`wc -l iprange.txt | tr -s ' ' | cut -f 1 -d ' '`
LINES=`wc -l $FILEv4 | tr -s ' ' | cut -f 1 -d ' '`

echo '# this will be filled with the updated blacklist all the way down to the [ RULES ] below.' >> pre.txt
echo -e "# $LINES IPv4 addresses added in $CIDR CIDR ranges by $0\n" >> iprange.txt


cat pre.txt > $CLUSTERFILE

if [[ -e "$FILEv6" ]]; then
	cat $FILEv6 >> $CLUSTERFILE
else
	echo "2001:470:1:332::37" >> $CLUSTERFILE
fi

echo -e "\n[IPSET blacklist4]\n" >> $CLUSTERFILE
cat iprange.txt >> $CLUSTERFILE
cat post.txt >> $CLUSTERFILE

echo "File creato: `ls -lah $CLUSTERFILE`"


echo "Compile the fw"
pve-firewall compile
sleep 10
echo "Restart the PVE firewall"
pve-firewall restart
echo -e "------\nEnd\n\n"
# rm -rf tmp/* 2> /dev/null
