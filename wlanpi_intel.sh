#!/bin/bash
# Usage: ./wlanpi_intel.sh <COUNTRY_CODE> [intel_model]
#   e.g. ./wlanpi_intel.sh BZ BE200
set -uo pipefail

country_code="${1:?Usage: $0 <COUNTRY_CODE> [intel_model]}"
intel_model="${2:-BE200}"   # swap this arg when you swap cards; full auto-ID needs a PCI subsystem-ID lookup table

# --- Locate the Intel DUT interface dynamically (don't hardcode wlan0/wlan1) ---
find_dut_iface() {
    for netdev in /sys/class/net/*; do
        iface=$(basename "$netdev")
        driver_path="$netdev/device/driver"
        if [ -e "$driver_path" ]; then
            driver=$(basename "$(readlink -f "$driver_path")")
            if [ "$driver" = "iwlwifi" ]; then
                echo "$iface"
                return 0
            fi
        fi
    done
    return 1
}

dut_iface=$(find_dut_iface || true)

# The BE200 sometimes loses a boot-time probe race on this hardware and never
# registers a wiphy at all (confirmed via dmesg: firmware loads and logs
# "base HW address", then nothing further — no wiphy/interface created).
# If that's happened, a clean driver reload fixes it. Self-heal once before
# giving up.
if [ -z "$dut_iface" ]; then
    echo "No iwlwifi interface found — attempting a driver reload (known boot-race issue on this hardware)..."
    sudo modprobe -r iwlmld 2>/dev/null
    sudo modprobe -r iwlmvm 2>/dev/null
    sudo modprobe -r iwlwifi 2>/dev/null
    sleep 1
    sudo modprobe iwlwifi
    sleep 5
    dut_iface=$(find_dut_iface || true)
fi

if [ -z "$dut_iface" ]; then
    echo "ERROR: no iwlwifi (Intel) interface found, even after a driver reload."
    echo "Check the card is seated and not rfkill-blocked (rfkill list), and check dmesg for real errors."
    exit 1
fi

dut_phy=$(iw dev "$dut_iface" info | awk '/wiphy/{print "phy"$2}')
echo "Using DUT interface: $dut_iface ($dut_phy)"

mkdir -p "$intel_model"

# Reset the DUT interface itself (not wlan1) to try to clear any stale scan cache.
# NOTE: this may NOT clear firmware-cached LAR/MCC state between runs. If you see
# a country "stick" from the previous test, you likely need to reload the driver:
#   sudo modprobe -r iwlwifi iwlmvm; sudo modprobe iwlwifi
sudo ip link set "$dut_iface" down
sudo ip link set "$dut_iface" up
sleep 1

# Build this run's hostapd conf.
# IMPORTANT: strip every existing country_code= line, wherever it appears,
# rather than just replacing line 1. A previous bug in this script (or a
# manual edit) can leave a stray/duplicate country_code line further down
# the file, which hostapd will not handle the way you expect. This grep -v
# approach is idempotent no matter how the file got into a bad state.
cp ./hostapd-script.conf ./hostapd-script.conf.bak
{ echo "country_code=$country_code"; grep -v '^country_code=' ./hostapd-script.conf.bak; } > ./hostapd-script.conf

# Sanity check: fail loudly if somehow more than one country_code line made it in.
cc_count=$(grep -c '^country_code=' ./hostapd-script.conf)
if [ "$cc_count" -ne 1 ]; then
    echo "ERROR: expected exactly 1 country_code line in hostapd-script.conf, found $cc_count. Aborting."
    cat ./hostapd-script.conf
    exit 1
fi

# Launch hostapd — send its own stdout/stderr to a temp file (not into the
# results folder) so we can check AP-ENABLED and print it on error, without
# leaving a permanent per-country hostapd log lying around.
hostapd_log=$(mktemp)
trap 'rm -f "$hostapd_log"' EXIT

sudo hostapd ./hostapd-script.conf > "$hostapd_log" 2>&1 &
hostapd_pid=$!
echo "hostapd started, pid $hostapd_pid"

# Give the AP time to come up, but actually verify it succeeded rather than
# just sleeping and hoping — a config error (like the duplicate country_code
# bug this script used to have) can make hostapd exit or fail to enable the
# AP, and a blind sleep would hide that completely.
ap_up=0
for i in $(seq 1 10); do
    sleep 1
    if grep -q "AP-ENABLED" "$hostapd_log" 2>/dev/null; then
        ap_up=1
        break
    fi
    if ! kill -0 "$hostapd_pid" 2>/dev/null; then
        echo "ERROR: hostapd process died. Log follows:"
        cat "$hostapd_log"
        exit 1
    fi
done

if [ "$ap_up" -ne 1 ]; then
    echo "ERROR: hostapd did not report AP-ENABLED within 10s. Log follows:"
    cat "$hostapd_log"
    sudo pkill -f "hostapd ./hostapd-script.conf" || true
    exit 1
fi
echo "hostapd confirmed up (AP-ENABLED seen in log)."

{
    echo "== Country code under test: $country_code =="
    echo "== DUT model: $intel_model  iface: $dut_iface  phy: $dut_phy =="

    echo "--- lspci -vnn (Intel is PCIe, not USB - lsusb won't show it) ---"
    sudo lspci -vnn | grep -A 10 -i network

    echo "--- dmesg | grep ucode ---"
    dmesg | grep ucode

    echo "--- iw $dut_iface scan (this is what should trigger LAR) ---"
    sudo iw "$dut_iface" scan

    # give firmware a moment to process scan results and update its self-managed reg domain
    sleep 2

    echo "--- iw reg get (this is your actual LAR result) ---"
    iw reg get

    echo "--- dmesg: iwl_mld_get_regdomain alpha2 log lines (driver's own LAR record) ---"
    dmesg | grep -i "get_regdomain\|alpha2" | tail -20

    echo "--- iw list ---"
    iw list

    echo "--- iw $dut_phy info ---"
    iw "$dut_phy" info

    echo "--- iw $dut_phy channels ---"
    iw "$dut_phy" channels
} | tee "./$intel_model/wlanpi-$intel_model-$country_code.txt"

sleep 1
echo "Killing hostapd"
sudo pkill -f "hostapd ./hostapd-script.conf" || true
