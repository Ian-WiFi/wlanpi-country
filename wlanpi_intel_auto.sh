#!/bin/bash
# Loops wlanpi_intel.sh's logic over every country code in country-codes.txt.
# Usage: ./wlanpi_intel_auto.sh [intel_model]
set -uo pipefail

INFILE=./country-codes.txt
intel_model="${1:-BE200}"   # swap this arg when you swap cards; full auto-ID needs a PCI subsystem-ID lookup table

mkdir -p "$intel_model"

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

# Find the DUT once, self-healing if it lost the boot-time probe race, before
# starting the loop. Same logic as wlanpi_intel.sh.
dut_iface=$(find_dut_iface || true)

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

startTotalTime=$(date +%s)
pass_count=0
fail_count=0
failed_countries=()

while read -r LINE; do
    # Skip blank lines and comments in country-codes.txt
    [ -z "$LINE" ] && continue
    case "$LINE" in \#*) continue ;; esac

    startTime=$(date +%s)
    echo "=========================================="
    echo " Starting LAR test for country: $LINE"
    echo "=========================================="

    # Re-check the DUT is still present each iteration (cheap safety net —
    # the boot-race issue is boot-time only, but this catches it if the
    # card ever drops mid-run during a long unattended sweep). Self-heal
    # the same way as before if it's gone missing.
    dut_iface=$(find_dut_iface || true)
    if [ -z "$dut_iface" ]; then
        echo "DUT interface disappeared mid-run — attempting driver reload..."
        sudo modprobe -r iwlmld 2>/dev/null
        sudo modprobe -r iwlmvm 2>/dev/null
        sudo modprobe -r iwlwifi 2>/dev/null
        sleep 1
        sudo modprobe iwlwifi
        sleep 5
        dut_iface=$(find_dut_iface || true)
    fi
    if [ -z "$dut_iface" ]; then
        echo "ERROR: DUT interface still missing for $LINE. Skipping this country."
        fail_count=$((fail_count + 1))
        failed_countries+=("$LINE (no DUT interface)")
        continue
    fi
    dut_phy=$(iw dev "$dut_iface" info | awk '/wiphy/{print "phy"$2}')

    # Reset the DUT interface to try to clear any stale scan cache.
    sudo ip link set "$dut_iface" down
    sudo ip link set "$dut_iface" up
    sleep 1

    # Build this run's hostapd conf. Strip every existing country_code= line,
    # wherever it appears, rather than just replacing line 1 — prevents the
    # duplicate/stray country_code bug from ever accumulating across a long
    # unattended sweep.
    cp ./hostapd-script.conf ./hostapd-script.conf.bak
    { echo "country_code=$LINE"; grep -v '^country_code=' ./hostapd-script.conf.bak; } > ./hostapd-script.conf

    cc_count=$(grep -c '^country_code=' ./hostapd-script.conf)
    if [ "$cc_count" -ne 1 ]; then
        echo "ERROR: expected exactly 1 country_code line in hostapd-script.conf, found $cc_count. Skipping $LINE."
        cat ./hostapd-script.conf
        fail_count=$((fail_count + 1))
        failed_countries+=("$LINE (bad hostapd config)")
        continue
    fi

    # hostapd's own log goes to a temp file — used for the AP-ENABLED check
    # and printed on error, then deleted, rather than left in the results folder.
    hostapd_log=$(mktemp)

    sudo hostapd ./hostapd-script.conf > "$hostapd_log" 2>&1 &
    hostapd_pid=$!
    echo "hostapd started, pid $hostapd_pid"

    ap_up=0
    for i in $(seq 1 10); do
        sleep 1
        if grep -q "AP-ENABLED" "$hostapd_log" 2>/dev/null; then
            ap_up=1
            break
        fi
        if ! kill -0 "$hostapd_pid" 2>/dev/null; then
            break
        fi
    done

    if [ "$ap_up" -ne 1 ]; then
        echo "ERROR: hostapd did not come up for $LINE within 10s. Log follows:"
        cat "$hostapd_log"
        rm -f "$hostapd_log"
        sudo pkill -f "hostapd ./hostapd-script.conf" || true
        fail_count=$((fail_count + 1))
        failed_countries+=("$LINE (hostapd failed to start)")
        continue
    fi
    echo "hostapd confirmed up (AP-ENABLED seen in log)."

    {
        echo "== Country code under test: $LINE =="
        echo "== DUT model: $intel_model  iface: $dut_iface  phy: $dut_phy =="

        echo "--- lspci -vnn (Intel is PCIe, not USB - lsusb won't show it) ---"
        sudo lspci -vnn | grep -A 10 -i network

        echo "--- dmesg | grep ucode ---"
        dmesg | grep ucode

        echo "--- iw $dut_iface scan (this is what should trigger LAR) ---"
        scan_output=""
        for attempt in 1 2 3; do
            scan_output=$(sudo iw "$dut_iface" scan 2>&1)
            if ! echo "$scan_output" | grep -q "scan aborted"; then
                break
            fi
            echo "Scan attempt $attempt aborted, retrying..."
            sleep 2
        done
        echo "$scan_output"

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

        endTime=$(date +%s)
        echo "Execution time was $((endTime - startTime)) seconds."
    } | tee "./$intel_model/wlanpi-$intel_model-$LINE.txt"

    sleep 1
    echo "Killing hostapd"
    sudo pkill -f "hostapd ./hostapd-script.conf" || true
    rm -f "$hostapd_log"
    sleep 1

    pass_count=$((pass_count + 1))
    endTime=$(date +%s)
    echo "Execution time for $LINE was $((endTime - startTime)) seconds."
done < "$INFILE"

endTotalTime=$(date +%s)
echo "=========================================="
echo " Sweep complete: $pass_count passed, $fail_count failed"
if [ "$fail_count" -gt 0 ]; then
    echo " Failed countries:"
    for f in "${failed_countries[@]}"; do
        echo "   - $f"
    done
fi
echo " Total execution time was $((endTotalTime - startTotalTime)) seconds."
echo "=========================================="
