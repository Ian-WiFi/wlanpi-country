#!/bin/bash
#used for calculating total time
startTotalTime=`date +%s`

# Define the input file
INFILE=./country-codes.txt

#grabbing the model from lspci
# Safely detect the Intel model from the PCIe bus
intel_model=$(lspci | grep -oE -i 'AX210|BE200' | tr '[:lower:]' '[:upper:]' | head -n 1)

# Bulletproof fallback: If the command above is somehow still blank, default to BE200
if [ -z "$intel_model" ]; then
  intel_model="BE200"
fi

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
  LINE=$(echo "$LINE" | tr -d '\r')
  if [ -z "$LINE" ] || [[ "$LINE" == \#* ]]; then continue; fi
  startTime=$(date +%s)

  echo "=========================================="
  echo "Processing Country Code: $LINE"
  echo "=========================================="

  # 1. KILL EXISTING HOSTAPD PROCESSES FIRST
  # This frees up the driver so it can actually be unloaded
  echo "Stopping any running hostapd processes..."
  sudo pkill -f "hostapd ./hostapd-script.conf" 2>/dev/null
  sleep 1

  # 2. BRING INTERFACES DOWN (Crucial for freeing the module)
  echo "Bringing wireless interfaces down..."
  sudo ip link set wlan0 down 2>/dev/null
  sudo ip link set wlan1 down 2>/dev/null
  sleep 1

  # 3. RESET INTEL DRIVER (Forces LAR to clear cache)
  # Unloading iwlmvm first ensures iwlwifi isn't blocked by its child module
  echo "Resetting iwlwifi driver..."
  sudo modprobe -r iwlmvm 2>/dev/null
  sudo modprobe -r iwlwifi 2>/dev/null
  sleep 1.5
  sudo modprobe iwlwifi
  sleep 3 # Let the driver settle and recreate the interfaces

  # Bring interfaces back up so hostapd/iw can use them
  sudo ip link set wlan0 up 2>/dev/null
  sudo ip link set wlan1 up 2>/dev/null
  sleep 1

  # 4. PREPARE NEW HOSTAPD CONFIG
  # copy the current conf for hostapd save it as a backup
  cp ./hostapd-script.conf ./hostapd-script.conf.bak
  # add the country code used as an input to the script to a new hostapd conf
  echo 'country_code='$LINE > ./hostapd-script.conf
  # add everything from old file to a new one starting from second line
  tail -n+2 ./hostapd-script.conf.bak >> ./hostapd-script.conf

  # 5. LAUNCH HOSTAPD IN BACKGROUND
  sudo hostapd ./hostapd-script.conf &
  HOSTAPD_PID=$!
  echo "hostapd started with PID: $HOSTAPD_PID"

  # Give hostapd time to start broadcasting and clear Intel's LAR cache
  sleep 5

  # 6. GATHER LOGS AND METADATA
  # This is used for putting the entire output into a file.
  {
    #displays what country code is being used
    echo "This is for the Country code of $LINE"

    #displays what model of WIFI card is connected
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
    echo "sudo iw reg set $LINE"
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
    echo "Execution time was $(expr $endTime - $startTime) seconds."

    #stores all of the output into a file based on model and country code
  } | tee ./$intel_model/wlanpi-$intel_model-$LINE.txt

  # 7. CLEANUP AT END OF LOOP
  echo "Tearing down hostapd for $LINE..."
  sudo pkill -f "hostapd ./hostapd-script.conf"
  sudo ip link set wlan0 down 2>/dev/null
  sudo ip link set wlan1 down 2>/dev/null
  sleep 1

  #getting ending time outside of loop
  endTime=`date +%s`
  echo "Loop execution time for $LINE was $(expr $endTime - $startTime) seconds."

done < "$INFILE"

#getting total ending time
endTotalTime=`date +%s`
#used for calculating and displaying the total time at the end of the script
echo "Total Execution time was $(expr $endTotalTime - $startTotalTime) seconds."
