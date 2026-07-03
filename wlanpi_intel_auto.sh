#!/bin/bash
#used for calculating total time
startTotalTime=`date +%s`

# Define the input file
INFILE=./country-codes.txt

#grabbing the model from lspci
intel_model=$(lspci | grep -E -i 'AX210|BE200' | awk -F ': ' '{print $2}' | grep -oE 'AX210|BE200' | head -n 1)

# Check if the folder exists
if [ ! -d "$intel_model" ]; then
  # If the folder doesn't exist, create it
  mkdir -p "$intel_model"
  echo "Folder created: $intel_model"
else
  echo "Folder already exists: $intel_model"
fi

# Read the input file line by line
while read -r LINE
do

#storing current time, used for calculating time at the start of the loop for 1 country
LINE=$(echo "$LINE" | tr -d '\r')
  if [ -z "$LINE" ] || [[ "$LINE" == \#* ]]; then continue; fi
  startTime=$(date +%s)

#reset of interfaces, I cant remember why
sudo ip link set wlan1 down
sudo ip link set wlan1 up

# After hostapd starts (Clears the Intel client card):
sleep 3
sudo ip link set wlan0 down
sudo ip link set wlan0 up

#copy the current conf for hostapd save it as a backup
cp ./hostapd-script.conf ./hostapd-script.conf.bak
#add the country code used as an input to the script to a new hostapd conf
echo 'country_code='$LINE> ./hostapd-script.conf
#add everything from old file to a new one starting from second line
cat ./hostapd-script.conf.bak |tail -n+2>> ./hostapd-script.conf

#Launch hostapd
sudo hostapd ./hostapd-script.conf &
HOSTAPD_PID=$!
echo "hostapd started with PID: $HOSTAPD_PID"

#this is used for putting the entire output of into a file.
{
#displays what country code is being used
echo "This is for the Country code of $LINE"

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
echo "sudo iw reg set "$LINE
sudo iw reg set $LINE

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

#getting ending time inside of loop
endTime=`date +%s`
#used for calculating and displaying time at the end of the loop for 1 country
echo Execution time was `expr $endTime - $startTime` seconds.

#stores all of the output into a file based on model and country code
} | tee ./$intel_model/wlanpi-$intel_model-$LINE.txt

#pauses for 1 seconds
time sleep 1

# Terminate all hostapd processes related to the specific config file
echo "Killing all hostapd processes related to ./hostapd-script.conf"
sudo pkill -f "hostapd ./hostapd-script.conf"

#pauses for 1 seconds
time sleep 1

#getting ending time outside of loop
endTime=`date +%s`
#used for calculating and displaying time at the end of the script for 1 country
echo Execution time was `expr $endTime - $startTime` seconds.

#used for repeating the read loop on the next file?
done < "$INFILE"

#getting total ending time
endTotalTime=`date +%s`
#used for calculating and displaying the total time at the end of the script
echo Total Execution time was `expr $endTotalTime - $startTotalTime` seconds.
