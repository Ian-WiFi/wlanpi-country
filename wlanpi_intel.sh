#!/bin/bash
# Usage: ./run_lar_test.sh <CountryCode> (e.g., ./run_lar_test.sh BZ)

if [ -z "$1" ]; then
  echo "Error: Please supply a 2-letter Country Code (e.g., ./run_lar_test.sh BZ)"
  exit 1
fi

COUNTRY=$1

# 1. Grab Intel model from lspci (PCIe card)
intel_model=$(lspci | grep -iE 'Intel.*(Wi-Fi|Wireless|BE200|AX210|AX211)' | awk '{print $NF}')
intel_model=${intel_model:-"Intel_BE200"}

# Ensure target folder exists
mkdir -p "$intel_model"
echo "[+] Target Folder: $intel_model"

# 2. Reset the correct AP interface (wlan2 = MediaTek Comfast)
echo "[+] Resetting wlan2 interface..."
sudo ip link set wlan2 down 2>/dev/null
sudo ip link set wlan2 up 2>/dev/null

# 3. Dynamic hostapd.conf creation
cp ./hostapd-script.conf ./hostapd-script.conf.bak
echo "country_code=${COUNTRY}" > ./hostapd-script.conf
tail -n +2 ./hostapd-script.conf.bak >> ./hostapd-script.conf

# 4. Launch hostapd in background on wlan2
echo "[+] Starting hostapd for Country: ${COUNTRY}..."
sudo hostapd ./hostapd-script.conf > /dev/null 2>&1 &
HOSTAPD_PID=$!

# Give hostapd 4 seconds to initialize the 802.11d beacon on Ch 36
sleep 4

# 5. Capture LAR response data
OUTPUT_FILE="./${intel_model}/wlanpi-${intel_model}-${COUNTRY}.txt"

{
  echo "=================================================="
  echo " LAR TEST RESULTS FOR COUNTRY CODE: ${COUNTRY}"
  echo " Date: $(date)"
  echo "=================================================="

  echo -e "\n--- Hardware Info ---"
  lspci -v | grep -A 10 -i "Network controller"

  echo -e "\n--- Intel Firmware (dmesg) ---"
  dmesg | grep -i ucode | tail -n 10

  echo -e "\n--- Triggering Active Probe Scan on wlan0 (Ch 36 / 5180MHz) ---"
  # Target channel 36 specifically to hit hostapd's beacon
  sudo iw dev wlan0 scan freqs 5180 > /dev/null 2>&1
  sleep 2

  echo -e "\n--- Intel LAR Kernel Log Output ---"
  dmesg | grep -i lar | tail -n 15

  echo -e "\n--- Current Active Regulatory Domain (iw reg get) ---"
  iw reg get

  echo -e "\n--- Channel Capabilities (iw phy phy0 info) ---"
  iw phy0 info

} | tee "$OUTPUT_FILE"

# 6. Clean up hostapd
echo "[+] Test complete for ${COUNTRY}. Stopping hostapd..."
sudo kill -9 $HOSTAPD_PID 2>/dev/null
sudo pkill -f "hostapd ./hostapd-script.conf" 2>/dev/null

echo "[+] Results saved to: $OUTPUT_FILE"
