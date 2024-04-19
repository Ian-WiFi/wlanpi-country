#!/bin/bash

startA=`date +%s`


# Define the input file
INFILE=./country.txt


# Read the input file line by line
while read -r LINE
do

start=`date +%s`

sudo ip link set wlan0 down
sudo ip link set wlan0 up

{
echo "This is for the Country code of $LINE"

echo "lsusb"
lsusb
echo "lspci -v"
lspci -v
echo "dmesg | grep ucode"
dmesg | grep ucode
echo "sudo iw wlan0 scan"
sudo iw wlan0 scan
echo "sudo iw reg set "$1
sudo iw reg set $1
echo "iw reg get"
iw reg get
echo "iw list"
iw list
echo "iw phy0 info"
iw phy0 info
echo "iw phy0 channels"
iw phy0 channels

end=`date +%s`
echo Execution time was `expr $end - $start` seconds.


} | tee -a ./wlanpi-be200-$LINE.txt

time sleep 5

end=`date +%s`
echo Execution time was `expr $end - $start` seconds.


done < "$INFILE"

endA=`date +%s`
echo Total Execution time was `expr $endA - $startA` seconds.
