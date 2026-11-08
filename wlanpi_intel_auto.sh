#!/bin/bash
# wlanpi_intel_auto.sh - sweep every country code by calling wlanpi_intel.sh once per country.
#
# Usage (run as root, e.g. with sudo):
#   sudo ./wlanpi_intel_auto.sh                   full sweep: baseline (00) + every code in country-codes.txt
#   sudo ./wlanpi_intel_auto.sh --only "US JP"    just these countries
#   sudo ./wlanpi_intel_auto.sh --failed-only     re-run only countries whose last status was not OK
#   sudo ./wlanpi_intel_auto.sh --list FILE       use a different country list
#   sudo ./wlanpi_intel_auto.sh --no-baseline     skip the 00 world-domain baseline
#   sudo ./wlanpi_intel_auto.sh --model NAME      override the auto-detected card model
#
# Resume: countries already finished OK for this kernel/ucode are skipped, so after a
# crash, reboot or Ctrl-C just run the same command again and it picks up where it stopped.
# Tip: run inside tmux/screen so an SSH drop does not kill the sweep.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE="${SINGLE:-$SCRIPT_DIR/wlanpi_intel.sh}"
LIST="$SCRIPT_DIR/country-codes.txt"
MAX_CONSEC_FAIL="${MAX_CONSEC_FAIL:-10}"     # stop if this many countries in a row fail (0 = never stop)

only=""; failed_only=0; baseline=1; model_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --only)        only="${2:-}"; shift 2 ;;
        --failed-only) failed_only=1; shift ;;
        --list)        LIST="${2:-}"; shift 2 ;;
        --no-baseline) baseline=0; shift ;;
        --model)       model_args=(--model "${2:-}"); shift 2 ;;
        -h|--help)     sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo ./wlanpi_intel_auto.sh)" >&2; exit 3; }
[ -r "$SINGLE" ] || { echo "ERROR: $SINGLE not found" >&2; exit 3; }

# ---- build the country list (strip CR, comments, blanks; uppercase; de-duplicate) ----
if [ -n "$only" ]; then
    codes_raw="$(printf '%s\n' $only)"
    baseline=0
else
    [ -r "$LIST" ] || { echo "ERROR: country list not found: $LIST" >&2; exit 3; }
    codes_raw="$(cat "$LIST")"
fi
mapfile -t codes < <(printf '%s\n' "$codes_raw" | tr -d '\r' | sed 's/#.*//' | tr -d ' \t' | tr '[:lower:]' '[:upper:]' \
                     | grep -E '^[A-Z]{2}$' | awk '!seen[$0]++')
[ "$baseline" -eq 1 ] && codes=("00" "${codes[@]}")

# ---- find (and create) this boot's output folder ----
rundir="$(bash "$SINGLE" --print-rundir "${model_args[@]}")" || { echo "ERROR: could not determine the run folder (DUT missing?)" >&2; exit 3; }
mkdir -p "$rundir/logs" "$rundir/status"
own_results() { [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && chown -R "$SUDO_USER:" "$rundir" 2>/dev/null; return 0; }
trap own_results EXIT
exec > >(tee -a "$rundir/sweep_$(date +%Y%m%d_%H%M%S).log") 2>&1

status_of() { sed -n 's/^STATUS=//p' "$rundir/status/$1.status" 2>/dev/null | head -n1; }

if [ "$failed_only" -eq 1 ]; then
    todo=()
    for cc in "${codes[@]}"; do
        st="$(status_of "$cc")"
        [ -n "$st" ] && [ "$st" != "OK" ] && todo+=("$cc")
    done
    codes=("${todo[@]}")
fi

total="${#codes[@]}"
echo "=========================================================="
echo " LAR sweep: $total countries  |  output: $rundir"
echo "=========================================================="
[ "$total" -eq 0 ] && { echo "Nothing to do."; exit 0; }

start_all="$(date +%s)"
pass=0; fail=0; skip=0; consec=0; fatal=0; idx=0
failed=()

for cc in "${codes[@]}"; do
    idx=$((idx + 1))
    if [ "$(status_of "$cc")" = "OK" ]; then
        echo "[$idx/$total] $cc: already OK - skipping"
        skip=$((skip + 1)); continue
    fi
    echo "----------------------------------------------------------"
    echo "[$idx/$total] $cc"
    echo "----------------------------------------------------------"
    bash "$SINGLE" "${model_args[@]}" "$cc"
    rc=$?
    case "$rc" in
        0)  pass=$((pass + 1)); consec=0 ;;
        3)  fatal=1
            echo "!! Environment problem (see messages above). Fix it - or reboot - then run the same command to resume."
            break ;;
        *)  fail=$((fail + 1)); consec=$((consec + 1))
            failed+=("$cc: $(status_of "$cc")")
            if [ "$MAX_CONSEC_FAIL" -gt 0 ] && [ "$consec" -ge "$MAX_CONSEC_FAIL" ]; then
                echo "!! $consec countries failed in a row - something is probably wrong with the setup (AP radio, RF isolation, firmware). Stopping."
                fatal=1; break
            fi ;;
    esac
done

end_all="$(date +%s)"
{
    echo "=========================================================="
    echo " Sweep finished: $pass passed, $fail failed, $skip skipped (already OK)"
    if [ "${#failed[@]}" -gt 0 ]; then
        echo " Needs attention:"
        for f in "${failed[@]}"; do echo "   - $f"; done
        echo " Re-run only these with: sudo $0 --failed-only"
    fi
    mism=()
    for sf in "$rundir"/status/*.status; do
        [ -e "$sf" ] || continue
        c="$(basename "$sf" .status)"
        l="$(sed -n 's/^LAR_COUNTRY=//p' "$sf" | head -n1)"
        [ -n "$l" ] && [ "$l" != "$c" ] && mism+=("$c->$l")
    done
    [ "${#mism[@]}" -gt 0 ] && echo " Card settled on a different country than requested (requested->card): ${mism[*]}"
    [ "$fatal" -eq 1 ] && echo " NOTE: the sweep stopped early - run the same command again to continue."
    echo " Total time: $((end_all - start_all)) seconds"
    echo " Results: $rundir"
    echo "=========================================================="
} | tee "$rundir/sweep_summary.txt"

[ "$fatal" -eq 1 ] && exit 3
[ "$fail" -gt 0 ] && exit 1
exit 0
