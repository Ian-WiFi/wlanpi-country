#!/bin/bash
# wlanpi_intel.sh - capture Intel LAR / regulatory data for ONE country code.
#
# Usage (run as root, e.g. with sudo):
#   sudo ./wlanpi_intel.sh <CC>              run one country (US, JP, ...)
#   sudo ./wlanpi_intel.sh 00                baseline: cold-start world domain, no AP beacon
#   sudo ./wlanpi_intel.sh <CC> --resume     skip if this country already finished OK
#   sudo ./wlanpi_intel.sh --print-rundir    print the output folder for this kernel/ucode and exit
# Options:
#   --model NAME   override the auto-detected card model (BE200, AX210, ...)
#   (old style "sudo ./wlanpi_intel.sh BZ BE200" still works)
#
# Per country it: reloads the Intel driver (clears cached LAR/MCC state),
# starts a hostapd AP for that country, scans from the DUT, CONFIRMS the AP's
# beacon + Country IE were seen, and only then captures everything.
#
# Exit codes: 0 OK/skipped | 2 usage | 3 environment fatal (stop the sweep)
#             10 NO_BEACON | 11 HOSTAPD_FAIL | 12 CRASH | 13 TIMEOUT
set -uo pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- tunables (override with environment variables) ----
OUT_ROOT="${OUT_ROOT:-$SCRIPT_DIR}"                          # results go to $OUT_ROOT/<MODEL>/<kernel>__ucode_<ver>/
HOSTAPD_TEMPLATE="${HOSTAPD_TEMPLATE:-$SCRIPT_DIR/hostapd-script.conf}"
SYS_NET="${SYS_NET:-/sys/class/net}"
UPTIME_FILE="${UPTIME_FILE:-/proc/uptime}"                   # used to mark where each run starts in the kernel log
AP_CHANNELS="${AP_CHANNELS:-a:36 a:149 g:6}"                 # tried in order: <hw_mode>:<channel>
AP_IFACE="${AP_IFACE:-}"                                     # force the AP radio interface if auto-detect is wrong
LINK_SETTLE="${LINK_SETTLE:-5}"                              # seconds after bringing the DUT up, before scanning
AP_SETTLE="${AP_SETTLE:-2}"                                  # seconds after AP-ENABLED, before scanning
RELOAD_WAIT="${RELOAD_WAIT:-30}"                             # max seconds to wait for the DUT after a driver reload
HOSTAPD_WAIT="${HOSTAPD_WAIT:-15}"                           # max seconds to wait for AP-ENABLED
SCAN_TIMEOUT="${SCAN_TIMEOUT:-60}"
CMD_TIMEOUT="${CMD_TIMEOUT:-60}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"                            # 1 try + 1 retry for CRASH / TIMEOUT / NO_BEACON
CRASH_RE='ADVANCED_SYSASSERT|NMI_INTERRUPT|Microcode SW error|Start IWL Error Log|Hardware error detected|Firmware error|SYSASSERT|Failed to start RT ucode|Failed to run INIT ucode|Unable to initialize device'

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; }
fatal() {
    echo "ERROR: $*" >&2
    if [ -n "${run_dir:-}" ] && [ -d "${run_dir:-}/status" ] && [ -n "${country:-}" ]; then
        write_status "ENV_FATAL" "$*" "${attempt:-0}"
    fi
    exit 3
}

# ---------------------------------------------------------------- arguments
country=""; model_override=""; resume=0; print_rundir=0
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
        --model)        model_override="${2:-}"; shift 2 ;;
        --resume)       resume=1; shift ;;
        --print-rundir) print_rundir=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        -*)             echo "Unknown option: $1" >&2; usage; exit 2 ;;
        *)              positional+=("$1"); shift ;;
    esac
done
[ "${#positional[@]}" -ge 1 ] && country="${positional[0]}"
[ "${#positional[@]}" -ge 2 ] && [ -z "$model_override" ] && model_override="${positional[1]}"
country="$(printf '%s' "$country" | tr -d '\r' | tr '[:lower:]' '[:upper:]')"

if [ "$print_rundir" -eq 0 ]; then
    if ! [[ "$country" =~ ^[A-Z]{2}$ || "$country" == "00" ]]; then
        echo "ERROR: need a two-letter country code (or 00 for the baseline), got '$country'" >&2
        usage; exit 2
    fi
fi

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo ./wlanpi_intel.sh ...)" >&2; exit 3; }
missing=()
for c in iw hostapd modprobe lsmod lspci timeout dmesg awk grep sed ip flock mktemp; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
[ "${#missing[@]}" -eq 0 ] || { echo "ERROR: missing required commands: ${missing[*]}" >&2; exit 3; }
[ -r "$HOSTAPD_TEMPLATE" ] || { echo "ERROR: hostapd template not found: $HOSTAPD_TEMPLATE" >&2; exit 3; }

exec 9>/tmp/wlanpi_intel.lock
flock -n 9 || { echo "ERROR: another wlanpi_intel run is active" >&2; exit 3; }

hostapd_pid=""; hostapd_log=""; conf=""; run_dir=""; attempt=0
RESULT_STATUS=""; RESULT_DETAIL=""; CAP_TIMEOUT=0; dmesg_mark="0"
ap_iface=""; ap_driver=""; ap_mac=""; ap_hw=""; ap_chan=""
beacon_cc=""; beacon_freq=""; lar_cc=""; scan_out=""; scan_rc=0; run_t0=$(date +%s)

stop_hostapd() {
    if [ -n "$hostapd_pid" ] && kill -0 "$hostapd_pid" 2>/dev/null; then
        kill "$hostapd_pid" 2>/dev/null
        for _ in 1 2 3 4 5; do kill -0 "$hostapd_pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$hostapd_pid" 2>/dev/null
        wait "$hostapd_pid" 2>/dev/null
    fi
    hostapd_pid=""
}
fix_ownership() {   # runs as root via sudo: give the results back to the person who ran sudo
    [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ -n "${model:-}" ] && [ -d "$OUT_ROOT/$model" ] \
        && chown -R "$SUDO_USER:" "$OUT_ROOT/$model" 2>/dev/null
    return 0
}
cleanup() {
    fix_ownership
    stop_hostapd
    [ -n "$conf" ] && rm -f "$conf"
    [ -n "$hostapd_log" ] && rm -f "$hostapd_log"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
command -v pkill >/dev/null 2>&1 && pkill -f 'hostapd /tmp/lar_hostapd\.' 2>/dev/null || true

# ---------------------------------------------------------------- device discovery
driver_of() {   # iface -> kernel driver name (empty if none)
    local p="$SYS_NET/$1/device/driver"
    [ -e "$p" ] && basename "$(readlink -f "$p")"
}

find_dut_iface() {   # Intel wireless netdev; prefers wlanN over helper interfaces like wlanpi0
    local n i first=""
    for n in "$SYS_NET"/*; do
        [ -e "$n" ] || continue
        i="$(basename "$n")"
        [ "$(driver_of "$i")" = "iwlwifi" ] || continue
        [ -e "$n/phy80211" ] || continue
        [ -z "$first" ] && first="$i"
        if [[ "$i" =~ ^wlan[0-9]+$ ]]; then echo "$i"; return 0; fi
    done
    [ -n "$first" ] && { echo "$first"; return 0; }
    return 1
}

list_ap_ifaces() {   # wireless netdevs that are NOT iwlwifi
    local n i d
    for n in "$SYS_NET"/*; do
        [ -e "$n" ] || continue
        i="$(basename "$n")"
        [ -e "$n/phy80211" ] || [ -e "$n/wireless" ] || continue
        d="$(driver_of "$i")"
        [ -n "$d" ] && [ "$d" != "iwlwifi" ] && echo "$i"
    done
}

reload_intel_driver() {
    log "Reloading Intel driver stack (clears cached LAR/MCC state)..."
    stop_hostapd
    local n i t=0
    for n in "$SYS_NET"/*; do
        [ -e "$n" ] || continue
        i="$(basename "$n")"
        [ "$(driver_of "$i")" = "iwlwifi" ] && ip link set "$i" down 2>/dev/null
    done
    modprobe -r iwlmld 2>/dev/null
    modprobe -r iwlmvm 2>/dev/null
    modprobe -r iwlwifi 2>/dev/null
    sleep 1
    if lsmod | grep -q '^iwlwifi'; then
        log "iwlwifi would not unload (something is holding it); LAR state cannot be cleared."
        return 1
    fi
    modprobe iwlwifi || return 1
    while [ "$t" -lt "$RELOAD_WAIT" ]; do
        if find_dut_iface >/dev/null 2>&1; then sleep 2; return 0; fi
        sleep 1; t=$((t + 1))
    done
    return 1
}

ensure_dut() {
    find_dut_iface >/dev/null 2>&1 && return 0
    log "No Intel interface found - one driver reload to recover from the boot probe race..."
    reload_intel_driver
}

detect_context() {   # sets dut_iface dut_phy bus_id fw_full ucode_ver pci_id model kernel_* run_dir
    local eth sub
    dut_iface="$(find_dut_iface)" || return 1
    dut_phy="$(iw dev "$dut_iface" info 2>/dev/null | awk '/wiphy/{print "phy"$2; exit}')"
    [ -n "$dut_phy" ] || return 1
    bus_id=""; fw_full=""
    if command -v ethtool >/dev/null 2>&1; then
        eth="$(ethtool -i "$dut_iface" 2>/dev/null)"
        bus_id="$(printf '%s\n' "$eth" | awk -F': ' '/^bus-info/{print $2; exit}')"
        fw_full="$(printf '%s\n' "$eth" | awk -F': ' '/^firmware-version/{print $2; exit}')"
    fi
    [ -n "$bus_id" ] || bus_id="$(basename "$(readlink -f "$SYS_NET/$dut_iface/device")")"
    ucode_ver="$(printf '%s' "$fw_full" | awk '{print $1}')"
    if [ -z "$ucode_ver" ]; then
        ucode_ver="$(dmesg | grep -i 'loaded firmware version' | tail -n1 | sed -E 's/.*loaded firmware version ([^ ]+).*/\1/')"
        fw_full="$ucode_ver (from dmesg)"
    fi
    ucode_ver="$(printf '%s' "${ucode_ver:-unknown_ucode}" | sed 's/[^A-Za-z0-9._-]/_/g')"
    pci_id="$(lspci -s "$bus_id" -nn 2>/dev/null | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' | tail -n1 | tr -d '[]')"
    sub="$(lspci -s "$bus_id" -v 2>/dev/null | awk -F': ' '/Subsystem:/{print $2; exit}')"
    model="$model_override"
    [ -n "$model" ] || model="$(printf '%s' "$sub" | grep -oE '(BE|AX|AC)[0-9]{3,4}' | head -n1)"
    if [ -z "$model" ]; then model="UNKNOWN"; log "WARN: could not identify the card model (subsystem: '$sub'); pass --model NAME"; fi
    model="$(printf '%s' "$model" | sed 's/[^A-Za-z0-9._-]/_/g')"
    kernel_raw="$(uname -r)"
    kernel_ver="$(printf '%s' "$kernel_raw" | sed 's/[^A-Za-z0-9._+-]/_/g')"
    run_dir="$OUT_ROOT/$model/${kernel_ver}__ucode_${ucode_ver}"
    return 0
}

# ---------------------------------------------------------------- hostapd / AP
build_hostapd_conf() {   # $1=hw_mode $2=channel ; template lines for these keys are replaced
    [ -n "$conf" ] && rm -f "$conf"
    conf="$(mktemp /tmp/lar_hostapd.XXXXXX)"
    {
        echo "country_code=$country"
        echo "interface=$ap_iface"
        echo "hw_mode=$1"
        echo "channel=$2"
        tr -d '\r' < "$HOSTAPD_TEMPLATE" | grep -v -E '^(country_code|interface|hw_mode|channel)='
    } > "$conf"
}

launch_hostapd() {
    [ -n "$hostapd_log" ] && rm -f "$hostapd_log"
    hostapd_log="$(mktemp /tmp/lar_hostapd_log.XXXXXX)"
    hostapd "$conf" > "$hostapd_log" 2>&1 9>&- &
    hostapd_pid=$!
    local i
    for i in $(seq 1 "$HOSTAPD_WAIT"); do
        sleep 1
        grep -q 'AP-ENABLED' "$hostapd_log" 2>/dev/null && return 0
        kill -0 "$hostapd_pid" 2>/dev/null || return 1
    done
    return 1
}

start_ap() {   # tries each AP_CHANNELS entry until hostapd reports AP-ENABLED
    local spec hw ch
    ap_hw=""; ap_chan=""
    for spec in $AP_CHANNELS; do
        hw="${spec%%:*}"; ch="${spec##*:}"
        build_hostapd_conf "$hw" "$ch"
        log "Starting hostapd: country=$country on $ap_iface ($hw ch $ch)"
        if launch_hostapd; then ap_hw="$hw"; ap_chan="$ch"; return 0; fi
        { echo "--- attempt $attempt, $hw ch $ch ---"; cat "$hostapd_log"; } >> "$run_dir/logs/$country.hostapd_fail.log"
        log "hostapd did not come up on $hw ch $ch"
        stop_hostapd
    done
    return 1
}

# ---------------------------------------------------------------- scan + beacon check
run_scan() {
    local a
    scan_out=""; scan_rc=0
    for a in 1 2 3; do
        scan_out="$(timeout "$SCAN_TIMEOUT" iw dev "$dut_iface" scan 2>&1)"; scan_rc=$?
        [ "$scan_rc" -eq 124 ] && return 0
        if printf '%s\n' "$scan_out" | grep -qiE 'scan aborted|resource busy'; then
            log "scan attempt $a aborted/busy; retrying"
            sleep 2
            continue
        fi
        break
    done
}

extract_bss_block() {   # $1=bssid (lowercase, or empty)  $2=ssid (or empty)
    printf '%s\n' "$scan_out" | awk -v want_bssid="$1" -v want_ssid="$2" '
        function flush() { if (blk != "" && hit && !found) { found = 1; printf "%s", blk } }
        /^BSS / {
            flush()
            blk = $0 "\n"; hit = 0
            b = $2; sub(/\(.*/, "", b)
            if (want_bssid != "" && tolower(b) == want_bssid) hit = 1
            next
        }
        {
            blk = blk $0 "\n"
            if (want_ssid != "" && $0 ~ /^[ \t]+SSID: /) {
                s = $0; sub(/^[ \t]+SSID: /, "", s)
                if (s == want_ssid) hit = 1
            }
        }
        END { flush() }'
}

check_beacon() {   # 0 = our AP seen with the right Country IE
    local ssid block=""
    beacon_cc=""; beacon_freq=""
    ssid="$(sed -n 's/^ssid=//p' "$conf" | head -n1 | tr -d '\r')"
    [ -n "$ap_mac" ] && block="$(extract_bss_block "$ap_mac" "")"
    [ -z "$block" ] && [ -n "$ssid" ] && block="$(extract_bss_block "" "$ssid")"
    if [ -z "$block" ]; then
        if printf '%s\n' "$scan_out" | grep -q '^BSS '; then
            RESULT_DETAIL="ap_not_seen (scan returned other networks only)"
        else
            RESULT_DETAIL="ap_not_seen (no scan results: $(printf '%s\n' "$scan_out" | head -n1))"
        fi
        return 1
    fi
    beacon_cc="$(printf '%s\n' "$block" | awk '/^[ \t]+Country: /{print $2; exit}')"
    beacon_freq="$(printf '%s\n' "$block" | awk '/^[ \t]+freq: /{print $2; exit}')"
    if [ -z "$beacon_cc" ]; then RESULT_DETAIL="ap_seen_but_no_country_ie"; return 1; fi
    if [ "$beacon_cc" != "$country" ]; then
        RESULT_DETAIL="country_ie_mismatch (wanted $country, beacon says $beacon_cc)"
        return 1
    fi
    return 0
}

cpu_temp() {   # CPU temperature, e.g. "58.1C" (or n/a); useful for spotting heat problems inside the cage
    local t
    t="$(cat "${THERMAL_FILE:-/sys/class/thermal/thermal_zone0/temp}" 2>/dev/null)"
    if [ -n "$t" ]; then awk -v t="$t" 'BEGIN { printf "%.1fC", t / 1000 }'; else echo "n/a"; fi
}

lar_result_cc() {   # the country the DUT's own (self-managed) regdomain actually settled on
    iw reg get 2>/dev/null | awk -v p="phy#${dut_phy#phy}" '$1 == p { f = 1; next } f && /^country / { c = $2; sub(/:.*/, "", c); print c; exit }'
}

scan_country_summary() {   # e.g. "US=3 AU=1": every Country IE heard in the scan (ambient check)
    printf '%s\n' "$scan_out" | awk '/^[ \t]+Country: /{c[$2]++} END{for (k in c) printf "%s=%d ", k, c[k]}' | sed 's/ $//'
}

# ---------------------------------------------------------------- dmesg helpers / crash detection
# Kernel-log lines since this attempt began, selected by timestamp (not line count,
# because the ring buffer wraps during a long sweep and line counts would break).
mark_dmesg() { dmesg_mark="$(awk '{printf "%.2f", $1 - 2}' "$UPTIME_FILE")"; }
dmesg_delta() {
    dmesg | awk -v t="$dmesg_mark" '
        { line = $0
          if (match(line, /^\[ *[0-9]+\.[0-9]+\]/)) {
              s = substr(line, 2, RLENGTH - 2); gsub(/ /, "", s); keep = ((s + 0) >= (t + 0))
          }
          if (keep) print line }'
}
crash_hits()  { dmesg_delta | grep -E "$CRASH_RE" | head -n 5; }

# ---------------------------------------------------------------- output helpers
section() { printf '\n===== %s =====\n' "$*"; }

run_section() {   # run_section "title" cmd args...   (with timeout; marks CAP_TIMEOUT on hang)
    local title="$1" rc
    shift
    section "$title"
    echo "\$ $*"
    timeout "$CMD_TIMEOUT" "$@" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then echo "!! TIMEOUT after ${CMD_TIMEOUT}s"; CAP_TIMEOUT=1
    elif [ "$rc" -ne 0 ]; then echo "!! exit code $rc"; fi
    return 0
}

header_lines() {
    echo "This is for the Country code of $country"
    echo "== Run: $(date -Is) | attempt $attempt of $MAX_ATTEMPTS | script v$SCRIPT_VERSION =="
    echo "== DUT model: $model | iface: $dut_iface | phy: $dut_phy | bus: $bus_id | PCI ID: ${pci_id:-?} =="
    echo "== Secondary AP: ${ap_iface:-none} | driver: ${ap_driver:-n/a} | MAC: ${ap_mac:-n/a} | beacon channel used: ${ap_hw:-n/a}:${ap_chan:-n/a} =="
    echo "== Firmware: $ucode_ver ($fw_full) | Kernel: $kernel_raw | CPU temp: $(cpu_temp) =="
}

capture_all() {   # $1 = output file
    CAP_TIMEOUT=0
    {
        header_lines
        if [ "$country" = "00" ]; then
            echo "== BASELINE: world-domain cold start, no test AP =="
        else
            echo "== Beacon check: PASS (AP seen on ${beacon_freq:-?} MHz, Country IE '$beacon_cc') =="
        fi
        echo "== Country IEs heard in scan: $(scan_country_summary) =="

        section "lsusb";                        command -v lsusb >/dev/null 2>&1 && lsusb
        run_section "lspci (DUT)"               lspci -s "$bus_id" -vnn
        run_section "ethtool -i $dut_iface"     ethtool -i "$dut_iface"
        run_section "iw dev"                    iw dev
        run_section "ip -br link"               ip -br link
        command -v rfkill >/dev/null 2>&1 && run_section "rfkill list" rfkill list

        section "dmesg | grep ucode (this attempt)"; dmesg_delta | grep ucode
        section "iw $dut_iface scan (LAR trigger)"; printf '%s\n' "$scan_out"
        sleep 2   # let the firmware finish updating its self-managed regdomain
        run_section "iw reg get (LAR result)"   iw reg get
        section "DUT regdomain is self-managed"
        if iw reg get 2>/dev/null | grep -q "^phy#${dut_phy#phy} (self-managed)"; then echo "yes"; else echo "NO - check that $dut_phy really is the Intel phy"; fi
        section "dmesg: LAR lines (this attempt only)"
        lar_lines="$(dmesg_delta | grep -E -i 'get_regdomain|alpha2|\bLAR\b|\bMCC\b')"
        if [ -n "$lar_lines" ]; then printf '%s\n' "$lar_lines"; else echo "(no matching lines in the kernel log)"; fi
        run_section "iw list"                   iw list
        run_section "iw $dut_phy info"          iw "$dut_phy" info
        run_section "iw $dut_phy channels"      iw "$dut_phy" channels
        section "firmware-crash patterns in this attempt's dmesg"
        crash_lines="$(crash_hits)"
        if [ -n "$crash_lines" ]; then printf '%s\n' "$crash_lines"; else echo "(none)"; fi
        echo "Execution time was $(( $(date +%s) - run_t0 )) seconds."
    } > "$1" 2>&1
}

write_triage_file() {   # $1=status : small diagnostic file for a failed country
    local f="$run_dir/wlanpi-$model-$country.$1.txt"
    {
        header_lines
        echo "== TRIAGE: status=$1 detail=$RESULT_DETAIL =="
        echo "== Country IEs heard in scan: $(scan_country_summary) =="
        section "iw $dut_iface scan";           printf '%s\n' "$scan_out"
        section "hostapd log";                  [ -n "$hostapd_log" ] && cat "$hostapd_log"
        section "hostapd failed attempts";      cat "$run_dir/logs/$country.hostapd_fail.log" 2>/dev/null
        section "dmesg (this attempt)";         dmesg_delta
        echo "Execution time was $(( $(date +%s) - run_t0 )) seconds."
    } > "$f.partial" 2>&1
    mv "$f.partial" "$f"
}

write_status() {   # $1=STATUS $2=DETAIL $3=ATTEMPTS
    local d
    d="$(printf '%s' "$2" | tr '\t\r\n' '   ')"
    {
        echo "STATUS=$1"
        echo "DETAIL=$d"
        echo "ATTEMPTS=$3"
        echo "TIMESTAMP=$(date -Is)"
        echo "AP_CHANNEL=${ap_hw:-}:${ap_chan:-}"
        echo "BEACON_COUNTRY=${beacon_cc:-}"
        echo "COUNTRY_IES_HEARD=$(scan_country_summary)"
        echo "LAR_COUNTRY=${lar_cc:-}"
        echo "CPU_TEMP=$(cpu_temp)"
        echo "UCODE=${ucode_ver:-}"
        echo "KERNEL=${kernel_ver:-}"
    } > "$run_dir/status/$country.status.tmp" && mv "$run_dir/status/$country.status.tmp" "$run_dir/status/$country.status"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$country" "$1" "$3" "$d" "${lar_cc:-}" >> "$run_dir/results.tsv"
    sync   # a hard crash or power loss must not lose results that were already reported as finished
}

write_manifest() {   # once per run folder: records the environment this data was captured in
    local m="$run_dir/manifest.txt"
    [ -e "$m" ] && return 0
    {
        echo "created: $(date -Is)"
        echo "script_version: $SCRIPT_VERSION"
        echo "hostname: $(hostname)"
        echo "kernel: $(uname -a)"
        echo "os: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
        echo "iw: $(iw --version 2>&1 | head -n1)"
        echo "hostapd: $(hostapd -v 2>&1 | head -n1)"
        echo "dut_model: $model"
        echo "dut_pci_id: ${pci_id:-?}"
        echo "dut_bus: $bus_id"
        echo "dut_firmware: $fw_full"
        echo "dut_iface: $dut_iface (the phy number changes on every driver reload; see each capture header)"
        echo "tunables: AP_CHANNELS='$AP_CHANNELS' LINK_SETTLE=$LINK_SETTLE AP_SETTLE=$AP_SETTLE MAX_ATTEMPTS=$MAX_ATTEMPTS"
        echo
        echo "--- loaded intel modules ---";   lsmod | grep -E '^iwl'
        echo "--- lsusb ---";                  command -v lsusb >/dev/null 2>&1 && lsusb
        echo "--- iw dev ---";                 iw dev
        echo "--- ip -br link ---";            ip -br link
        echo "--- rfkill ---";                 command -v rfkill >/dev/null 2>&1 && rfkill list
        echo "--- processes that could touch the radios ---"
        ps -eo comm 2>/dev/null | grep -E 'NetworkManager|wpa_supplicant|hostapd|dhcpcd|wlanpi' | sort | uniq -c
    } > "$m" 2>&1
}

# ---------------------------------------------------------------- one attempt
run_once() {
    attempt="$1"
    RESULT_STATUS="OK"; RESULT_DETAIL=""; CAP_TIMEOUT=0
    ap_hw=""; ap_chan=""; beacon_cc=""; beacon_freq=""; lar_cc=""; scan_out=""; scan_rc=0
    run_t0="$(date +%s)"
    mark_dmesg
    log "$country: attempt $attempt of $MAX_ATTEMPTS"

    if ! reload_intel_driver; then
        RESULT_STATUS="ENV_FATAL"; RESULT_DETAIL="Intel driver reload failed or the DUT did not come back (a reboot may be needed)"; return 0
    fi
    if ! detect_context; then
        RESULT_STATUS="ENV_FATAL"; RESULT_DETAIL="DUT not usable after driver reload"; return 0
    fi
    ip link set "$dut_iface" up 2>/dev/null || log "WARN: could not bring $dut_iface up (rfkill?)"
    sleep "$LINK_SETTLE"

    if [ "$country" != "00" ]; then
        if ! start_ap; then
            RESULT_STATUS="HOSTAPD_FAIL"; RESULT_DETAIL="hostapd never reached AP-ENABLED (tried: $AP_CHANNELS); see logs/$country.hostapd_fail.log"
            write_triage_file "$RESULT_STATUS"; return 0
        fi
        sleep "$AP_SETTLE"
    fi

    log "$country: scanning from $dut_iface"
    run_scan
    if [ "$scan_rc" -eq 124 ]; then
        RESULT_STATUS="TIMEOUT"; RESULT_DETAIL="iw scan hung for ${SCAN_TIMEOUT}s"
        write_triage_file "$RESULT_STATUS"; return 0
    fi
    local hits
    hits="$(crash_hits)"
    if [ -n "$hits" ]; then
        RESULT_STATUS="CRASH"; RESULT_DETAIL="firmware error during scan: $(printf '%s' "$hits" | head -n1)"
        write_triage_file "$RESULT_STATUS"; return 0
    fi
    if [ "$country" != "00" ] && ! check_beacon; then
        RESULT_STATUS="NO_BEACON"
        write_triage_file "$RESULT_STATUS"; return 0
    fi

    local partial="$run_dir/wlanpi-$model-$country.txt.partial"
    if [ "$country" = "00" ]; then log "$country: capturing baseline"; else log "$country: beacon confirmed - capturing"; fi
    capture_all "$partial"
    hits="$(crash_hits)"
    if [ -n "$hits" ]; then
        RESULT_STATUS="CRASH"; RESULT_DETAIL="firmware error during capture: $(printf '%s' "$hits" | head -n1)"
        mv "$partial" "$run_dir/wlanpi-$model-$country.CRASH.txt"; return 0
    fi
    if [ "$CAP_TIMEOUT" -eq 1 ]; then
        RESULT_STATUS="TIMEOUT"; RESULT_DETAIL="a capture command hung for ${CMD_TIMEOUT}s"
        mv "$partial" "$run_dir/wlanpi-$model-$country.TIMEOUT.txt"; return 0
    fi
    mv "$partial" "$run_dir/wlanpi-$model-$country.txt"
    RESULT_STATUS="OK"
    local foreign="" notes=""
    foreign="$(scan_country_summary | tr ' ' '\n' | grep -v "^$country=" | grep -v '^$' | tr '\n' ' ')"
    [ -n "$foreign" ] && notes="other Country IEs heard in scan: ${foreign% } (ambient networks? check RF isolation)"
    lar_cc="$(lar_result_cc)"
    if [ -n "$lar_cc" ] && [ "$lar_cc" != "$country" ]; then
        notes="${notes:+$notes; }the card's own regdomain is $lar_cc, requested $country"
    fi
    [ -n "$notes" ] && RESULT_DETAIL="note: $notes"
    return 0
}

save_attempt_logs() {
    dmesg_delta > "$run_dir/logs/$country.a$attempt.dmesg_delta.txt" 2>/dev/null
    [ -n "$hostapd_log" ] && [ -s "$hostapd_log" ] && cp "$hostapd_log" "$run_dir/logs/$country.a$attempt.hostapd.log"
}

# ---------------------------------------------------------------- main
ensure_dut || fatal "No Intel (iwlwifi) interface even after a driver reload. Check the card, rfkill and dmesg."
detect_context || fatal "Could not read the Intel device (iw dev / ethtool failed)."

if [ "$print_rundir" -eq 1 ]; then echo "$run_dir"; exit 0; fi

mkdir -p "$run_dir/logs" "$run_dir/status"
write_manifest
status_file="$run_dir/status/$country.status"

if [ "$resume" -eq 1 ] && grep -qx 'STATUS=OK' "$status_file" 2>/dev/null; then
    log "$country: already OK in $run_dir - skipping"
    exit 0
fi

if [ "$country" != "00" ]; then
    if [ -n "$AP_IFACE" ]; then
        ap_iface="$AP_IFACE"
    else
        ap_iface="$(list_ap_ifaces | head -n1)"
        if [ -z "$ap_iface" ]; then
            log "No secondary AP radio found - re-enumerating network devices..."
            udevadm trigger --subsystem-match=net 2>/dev/null; sleep 3
            ap_iface="$(list_ap_ifaces | head -n1)"
        fi
        [ "$(list_ap_ifaces | wc -l)" -gt 1 ] && log "WARN: more than one non-Intel Wi-Fi radio present; using $ap_iface (set AP_IFACE to override)"
    fi
    [ -n "$ap_iface" ] || fatal "No secondary (non-Intel) Wi-Fi radio found for the test AP. Is the USB adapter plugged in?"
    ap_driver="$(driver_of "$ap_iface")"
    ap_mac="$(tr 'A-F' 'a-f' < "$SYS_NET/$ap_iface/address" 2>/dev/null)"
fi

attempt=1
while :; do
    run_once "$attempt"
    stop_hostapd
    save_attempt_logs
    case "$RESULT_STATUS" in
        CRASH|TIMEOUT|NO_BEACON)
            if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
                log "$country: $RESULT_STATUS ($RESULT_DETAIL) - retrying once after a fresh driver reload"
                attempt=$((attempt + 1)); continue
            fi ;;
    esac
    break
done

[ -n "$hostapd_log" ] && [ -s "$hostapd_log" ] && cp "$hostapd_log" "$run_dir/logs/$country.hostapd.log"
dmesg > "$run_dir/logs/$country.dmesg_full.txt" 2>/dev/null
[ "$RESULT_STATUS" = "OK" ] && rm -f "$run_dir/wlanpi-$model-$country".*.txt   # drop stale failure files from earlier runs
write_status "$RESULT_STATUS" "$RESULT_DETAIL" "$attempt"
log "$country: $RESULT_STATUS${RESULT_DETAIL:+ - $RESULT_DETAIL} [CPU $(cpu_temp)]"

case "$RESULT_STATUS" in
    OK)           exit 0 ;;
    NO_BEACON)    exit 10 ;;
    HOSTAPD_FAIL) exit 11 ;;
    CRASH)        exit 12 ;;
    TIMEOUT)      exit 13 ;;
    *)            exit 3 ;;
esac
