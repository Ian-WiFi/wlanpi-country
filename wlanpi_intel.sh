#!/bin/bash
sudo ip link set wlan0 down
sudo ip link set wlan0 up


cp ./hostapd-script.conf ./hostapd-script.conf.bak
echo 'country_code='$1> ./hostapd-script.conf
#add everything from old file starting from second line
cat ./hostapd-script.conf.bak |tail -n+2>> ./hostapd-script.conf


sudo hostapd ./hostapd-script.conf



{
echo "This is for the Country code of $1"




echo "lsusb"
lsusb
echo "sudo lspci -v"
sudo lspci -v
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
} | tee -a ./wlanpi-be200-$1.txt


sudo service hostapd stop
