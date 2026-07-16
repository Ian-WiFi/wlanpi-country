#!/bin/bash
# Used for calculating total time
startTotalTime=`date +%s`

# Define the input file
INFILE=./country-codes.txt

# Grab the model from lspci
intel_model=$(lspci | grep -oE -i 'AX210|BE200' | tr '[:lower:]' '[:upper:]' | head -n 1)
if [ -z "$intel_model" ]; then
  intel_model="BE200"
fi

# Check if the folder exists
if [ ! -d "$intel_model" ]; then
  mkdir -p "$intel_model"
  echo "Folder created: $intel_model"
else
  echo "Folder already exists: $intel_model"
fi

# ==========================================================
# 1. PRE-SCRIPT PREPARATION: Stop services holding the driver
# ==========================================================
echo "Stopping system wireless services to free the driver..."
sudo systemctl stop wpa_supplicant 2>/dev/null
sudo systemctl stop NetworkManager 2>/dev/null
sudo systemctl stop wlanpi-profiler 2>/dev/null
sleep 2

# Helper function to bring down interfaces and force driver reload
reset_intel_driver() {
  echo "Bringing wireless interfaces down..."
  sudo ip link set wlan0 down 2>/dev/null
  sudo ip link set wlan1 down 2>/dev/null
  sleep 2

  echo "Unloading iwlwifi driver..."
  sudo modprobe -r iwlmvm 2>/dev/null
  sudo modprobe -r iwlwifi 2>/dev/null
  # Crucial: Give the PCIe bus host bridge plenty of time to clear active states
  sleep 4 

  echo "Reloading iwlwifi driver..."
  sudo modprobe iwlwifi
  # Crucial: Give the driver and PCIe link ample time to settle/renegotiate
  sleep 6 
}

# Read the input file line by line
while read -r LINE
do
  LINE=$(echo "$LINE" | tr -d '\r')
  if [ -z "$LINE" ] || [[ "$LINE" == \#* ]]; then continue; fi
  startTime=$(date +%s)

  echo "=========================================="
  echo "Processing Country Code: $LINE"
  echo "=========================================="

  # Clean up any lingering hostapd processes from previous runs
  sudo pkill -f "hostapd ./hostapd-script.conf" 2>/dev/null
  sleep 1

  # Force driver reset to wipe Intel LAR cache completely
  reset_intel_driver

  # Bring interfaces up post-reload
  sudo ip link set wlan0 up 2>/dev/null
  sudo ip link set wlan1 up 2>/dev/null
  sleep 2

  # Check if we should skip hostapd (for '00' world safe mode)
  if [ "$LINE" = "00" ]; then
    echo "Country code is '00'. Skipping hostapd startup to prevent errors."
    HOSTAPD_ACTIVE="no"
  else
    HOSTAPD_ACTIVE="yes"
    # Prepare new hostapd config
    cp ./hostapd-script.conf ./hostapd-script.conf.bak
    echo 'country_code='$LINE > ./hostapd-script.conf
    tail -n+2 ./hostapd-script.conf.bak >> ./hostapd-script.conf

    # Launch hostapd in the background
    sudo hostapd ./hostapd-script.conf &
    HOSTAPD_PID=$!
    echo "hostapd started with PID: $HOSTAPD_PID"
    
    # Give hostapd time to issue beacons and force LAR update
    sleep 5
  fi

  # Gather logs and capabilities
  {
    echo "This is for the Country code of $LINE"
    echo "lsusb"
    lsusb
    echo "sudo lspci -v"
    sudo lspci -v
    echo "dmesg | grep ucode"
    dmesg | grep ucode | tail -n 10
    echo "sudo iw wlan0 scan"
    sudo iw wlan0 scan
    echo "sudo iw reg set $LINE"
    sudo iw reg set $LINE
    echo "iw reg get"
    iw reg get
    
    # NOTE: 'iw list' has been omitted here to prevent system lockups. 
    # Using safer, device-targeted alternatives:
    echo "iw phy0 info"
    iw phy0 info
    echo "iw phy0 channels"
    iw phy0 channels

    endTime=`date +%s`
    echo "Execution time was $(expr $endTime - $startTime) seconds."
  } | tee ./$intel_model/wlanpi-$intel_model-$LINE.txt

  # Cleanup at end of this country's loop iteration
  if [ "$HOSTAPD_ACTIVE" = "yes" ]; then
    echo "Tearing down hostapd for $LINE..."
    sudo pkill -f "hostapd ./hostapd-script.conf"
  fi
  
  sudo ip link set wlan0 down 2>/dev/null
  sudo ip link set wlan1 down 2>/dev/null
  sleep 2

  endTime=`date +%s`
  echo "Loop execution time for $LINE was $(expr $endTime - $startTime) seconds."

done < "$INFILE"

# ==========================================================
# 2. POST-SCRIPT CLEANUP: Restore background services
# ==========================================================
echo "Restoring system wireless services..."
sudo systemctl start NetworkManager 2>/dev/null
sudo systemctl start wpa_supplicant 2>/dev/null

endTotalTime=`date +%s`
echo "Total Execution time was $(expr $endTotalTime - $startTotalTime) seconds."
