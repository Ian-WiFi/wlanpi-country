#!/bin/bash
#Currently this takes a single command (Country Code) as input.

#Need to automate grabbing the model from lsusb
intel_model="BE200"

#reset of interfaces, I cant remember why
sudo ip link set wlan0 down
sudo ip link set wlan0 up

#copy the current conf for hostapd save it as a backup
cp ./hostapd-script.conf ./hostapd-script.conf.bak
#add the country code used as an input to the script to a new hostapd conf
echo 'country_code='$1> ./hostapd-script.conf
#add everything from old file to a new one starting from second line
cat ./hostapd-script.conf.bak |tail -n+2>> ./hostapd-script.conf

#Launch hostapd
sudo hostapd ./hostapd-script.conf &
HOSTAPD_PID=$!
echo "hostapd started with PID: $HOSTAPD_PID"

#this is used for putting the entire output of into a file.
{
#displays what country code is being used
echo "This is for the Country code of $1"

#dispays what model of WIFI card is connected
echo "lsusb"
lsusb

#displays details of the wireless card
echo "sudo lspci -v"
sudo lspci -v

#displays what intel firmware is being used
echo "dmesg | grep ucode"
dmesg | grep ucode

#displays capabilities of the wireless card
echo "sudo iw wlan0 scan"
sudo iw wlan0 scan

#sets the country code
echo "sudo iw reg set "$1
sudo iw reg set $1

#displays the frequency list
echo "iw reg get"
iw reg get

#displays capabilities based on country code
echo "iw list"
iw list

#displays more capabilities based on country code
echo "iw phy0 info"
iw phy0 info

#displays detailed info about the channels
echo "iw phy0 channels"
iw phy0 channels

#stores all of the output into a file based on model and country code
} | tee ./$intel_model/wlanpi-$intel_model-$1.txt

# Wait for some time if needed (or perform other tasks)
sleep 1  # Adjust this as necessary for your use case

# Terminate all hostapd processes related to the specific config file
echo "Killing all hostapd processes related to ./hostapd-script.conf"
sudo pkill -f "hostapd ./hostapd-script.conf"

#stops hostapd
#sudo service hostapd stop
