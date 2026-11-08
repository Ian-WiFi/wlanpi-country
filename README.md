# wlanpi-country

Capture and compare what Intel Wi-Fi cards report as their **own regulatory domain** (LAR, location-aware regulatory) for every country code, using a WLAN Pi (or any Linux box with the right hardware).

> **Read [DISCLAIMER.md](DISCLAIMER.md) before running anything.** These scripts run as root, reload kernel drivers and make a Wi-Fi radio transmit. They are provided as is, for use at your own risk, in an isolated lab setup.

## What it does

Intel cards with LAR do not follow `iw reg set`. They learn the country from 802.11d Country information elements in the beacons they hear. For each country code, this project:

1. reloads the Intel driver (so cached LAR state is cleared),
2. starts a test access point on a second radio that announces that country,
3. scans from the Intel card,
4. checks that the test AP's beacon and Country IE were seen, and only then
5. captures the card's own regdomain, channel table and capabilities into a text file.

`lar_compare.py` then groups the countries whose card data is identical, flags countries where the card only gave world-domain (`00`) data, and compares two cards or two firmware versions.

## What you need

| Item | Notes |
|---|---|
| Intel Wi-Fi card using `iwlwifi` | tested: BE200, AX210 |
| A second Wi-Fi radio that can run an AP | tested: MediaTek MT7921 USB (`mt7921u`) |
| Linux, run as root | tested: WLAN Pi OS 26.10 (Debian 13), kernel 7.3.0-rc5-v8-wlanpi+ |
| `bash`, `iw`, `hostapd`, `ethtool`, `lspci`, `flock`, `timeout` | tested with iw 6.17, hostapd 2.12 |
| `python3` | for `lar_compare.py` (standard library only; tested with 3.13) |
| `tmux` or `screen` | recommended for the full sweep |
| A wired connection for SSH | the sweep unloads the Wi-Fi driver on every country |
| RF isolation | see below |

**RF isolation.** In the tested setup the Pi with the card under test sits inside a Faraday cage and the AP radio is outside it, so the card hears only the test AP (roughly -66 to -80 dBm at the card). In my testing a very strong signal at the card was associated with firmware crashes, so keep the AP weak at the card. Neighbouring networks will otherwise leak in and can influence the card's result; every capture records the Country IEs heard, so you can check.

The AP radio must be able to announce each country. If the Linux regulatory database on your machine has no usable rules for a code, hostapd refuses to start and that country is recorded as `HOSTAPD_FAIL`.

## Quick start

```bash
git clone https://github.com/Ian-WiFi/wlanpi-country.git
cd wlanpi-country
chmod +x wlanpi_intel.sh wlanpi_intel_auto.sh

# Optional: change the SSID or passphrase in hostapd-script.conf.
# The script sets country, interface and channel itself.

# 1. Try one country first
sudo ./wlanpi_intel.sh US

# 2. Run the full sweep (resumable) inside tmux
tmux new -s lar
sudo ./wlanpi_intel_auto.sh

# 3. Analyse the results folder
python3 lar_compare.py <MODEL>/<kernel>__ucode_<version>/
```

The card model, firmware and kernel are detected automatically, and results go to `<MODEL>/<kernel>__ucode_<version>/`. A new kernel or firmware gets its own folder.

### Useful options

```bash
sudo ./wlanpi_intel_auto.sh --only "US JP"      # just these countries
sudo ./wlanpi_intel_auto.sh --failed-only       # retry only what did not finish OK
sudo ./wlanpi_intel_auto.sh --list my-list.txt  # another country list
sudo ./wlanpi_intel_auto.sh --no-baseline       # skip the 00 world-domain baseline
sudo ./wlanpi_intel.sh DE --resume              # skip if DE already finished OK
```

Interrupted? Run the same command again; countries already finished OK are skipped.

### Tunables (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `AP_CHANNELS` | `a:36 a:149 g:6` | beacon channels tried in order (`<hw_mode>:<channel>`) |
| `AP_IFACE` | auto | force the AP radio interface |
| `LINK_SETTLE` / `AP_SETTLE` | 5 / 2 | seconds to wait before scanning |
| `RELOAD_WAIT` / `HOSTAPD_WAIT` | 30 / 15 | max seconds to wait for the card / for `AP-ENABLED` |
| `SCAN_TIMEOUT` / `CMD_TIMEOUT` | 60 / 60 | hang protection for `iw` commands |
| `MAX_ATTEMPTS` | 2 | one retry for crash, timeout or no beacon |
| `MAX_CONSEC_FAIL` | 10 | the sweep stops after this many failures in a row (0 = never) |
| `OUT_ROOT` | script folder | where result folders are created |

## Output

```
<MODEL>/<kernel>__ucode_<version>/
  wlanpi-<MODEL>-<CC>.txt           raw capture for one country
  wlanpi-<MODEL>-<CC>.<STATUS>.txt  small triage file for a country that failed
  manifest.txt                      environment (kernel, tools, modules, processes)
  results.tsv                       one line per run
  status/<CC>.status                final status, AP channel, country IEs heard, card country, CPU temperature
  logs/                             dmesg and hostapd logs
  sweep_*.log, sweep_summary.txt    sweep output
  analysis/                         lar_groups.txt, lar_matrix.csv
```

Status values: `OK`, `NO_BEACON`, `HOSTAPD_FAIL`, `CRASH` (firmware error in the kernel log), `TIMEOUT`, `ENV_FATAL` (card or AP radio missing; fix and rerun).

Inside a raw capture, the card's own regdomain is the `phyN (self-managed)` block of the `iw reg get` section, and its channel table is the `iw <phy> channels` section. The `global` block belongs to the AP radio and the machine's regulatory database, not to the card.

## Analysis

```bash
python3 lar_compare.py RUN_A/                      # groups, world-baseline check
python3 lar_compare.py RUN_A/ --diff US JP         # differences between two countries
python3 lar_compare.py RUN_A/ --compare RUN_B/     # per-country changes between two runs
python3 lar_compare.py RUN_A/ --cards RUN_B/       # side-by-side summary of two cards
```

A card reporting the requested country label does not by itself mean it has country-specific rules. `lar_groups.txt` lists the countries whose rules are identical to the `00` baseline; those have no country-specific data.

## Example results

Run on a WLAN Pi M4, kernel 7.3.0-rc5-v8-wlanpi+. These describe one card, firmware and kernel under specific conditions; they are observations, not regulatory information. See `results/` if present.

| | BE200 (ucode 106.c88d33af.0) | AX210 (ucode 89.f7dcb3ee.0) |
|---|---|---|
| Captures | 250 (249 country codes + `00`) | 250 (249 country codes + `00`) |
| Distinct rule sets | 29 | 20 |
| Countries with only world-domain data | AN | 56 |

Of 249 countries in both: 55 have only world-domain data on the AX210 but country-specific data on the BE200 (none the other way); 14 have 6 GHz channels on the BE200 and none on the AX210; enabled 5 GHz channel counts differ for 20. The two cards run different firmware lines, so a difference can come from the card or from the firmware version.

## Known limitations

- `TG` (Togo) is not in `country-codes.txt`: the AP radio used here disallows AP mode on every channel under that code, so the beacon could not be created. `AN` is a retired code and is kept.
- The beacon channel varies by country (5 GHz channel 36 where allowed, else 149, else 2.4 GHz channel 6); each status file records it. A DE control run gave identical card data over 2.4 GHz and 5 GHz (one country only).
- The "LAR lines" section of each capture is empty on the tested kernel; no LAR messages appear in the kernel log at its default level.
- During development a system hang occurred during a driver reload and the card was not seen again until after a power cycle. The cause was not confirmed. Results are flushed to disk after each country so a hang loses little.
- Captures include MAC addresses and the hostname. If you share your own raw captures, remove them first.

## Contributing

Issues and pull requests are welcome, especially results from other Intel cards, firmware versions and kernels. Please say which hardware, firmware and kernel you used.

## License

See [LICENSE](LICENSE). Use is also subject to [DISCLAIMER.md](DISCLAIMER.md).
