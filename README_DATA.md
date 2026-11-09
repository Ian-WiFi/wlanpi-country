# Intel LAR regulatory captures: data package

Raw captures of what two Intel Wi-Fi cards (BE200 and AX210) report as their **own regulatory domain** (LAR, location-aware regulatory) for each country code, plus analysis files that group the countries by identical card data.

Method, scripts and analysis tool: https://github.com/Ian-WiFi/wlanpi-country

Please read `DISCLAIMER.md`. The results are observations of specific hardware, firmware and kernel versions, not regulatory information.

## What is in this package

```
BE200/<kernel>__ucode_<version>/     results for the BE200
AX210/<kernel>__ucode_<version>/     results for the AX210
  wlanpi-<MODEL>-<CC>.txt            raw capture for one country (the main data)
  wlanpi-<MODEL>-<CC>.<STATUS>.txt   small triage file for a country that failed (if any)
  manifest.txt                       test environment
  results.tsv                        one line per run: time, country, status, attempts, detail, card country
  status/<CC>.status                 final status, AP channel used, country IEs heard, card country, CPU temperature
  sweep_*.log, sweep_summary.txt     sweep output
  analysis/                          lar_groups.txt, lar_matrix.csv
results/                             the analysis files again, plus the BE200 vs AX210 comparison
DISCLAIMER.md, LICENSE, SCRUBBED.txt
```

Identifying details of the test device (MAC addresses, hostname and similar) were masked before sharing; see `SCRUBBED.txt`. Full kernel logs were left out.

## Suggested way to review

1. `results/BE200/lar_groups.txt` and `results/AX210/lar_groups.txt`: countries that share identical card data, and the countries where the card only gave world-domain (`00`) data.
2. `results/cards_summary.txt`: BE200 and AX210 side by side.
3. `lar_matrix.csv` (open in a spreadsheet): one row per country with channel counts per band, DFS channel count and the AP channel used.
4. One raw capture, for example `BE200/.../wlanpi-BE200-US.txt` (see "Reading one capture").
5. `status/*.status` and `results.tsv` for anything unusual (retries, notes).

## Test setup

| Item | Value |
|---|---|
| Test device | WLAN Pi M4, WLAN Pi OS 26.10 (Debian 13) |
| Kernel | 7.3.0-rc5-v8-wlanpi+ |
| Tools | iw 6.17, hostapd 2.12 |
| Card under test | BE200 (PCI 8086:272b), ucode 106.c88d33af.0 |
| Card under test | AX210 (PCI 8086:2725), ucode 89.f7dcb3ee.0 |
| Test access point | MediaTek MT7921 USB adapter (driver mt7921u), outside the cage |
| RF isolation | The Pi with the card sits inside a Faraday cage; the access point is outside it |

The two cards run different firmware lines (106 and 89), so a difference between them can come from the card or from the firmware version; this data cannot separate the two.

## Method (one country)

1. Reload the Intel driver so cached LAR state is cleared.
2. Start a test access point announcing that country (802.11d Country IE): 5 GHz channel 36, else 149, else 2.4 GHz channel 6, depending on what the AP radio allows.
3. Scan from the card.
4. Confirm the test AP's beacon was seen with the right Country IE; only then capture everything.
5. One retry (after a fresh driver reload) for crash, timeout or no beacon.

`00` is the world-domain baseline: the same cold start with no access point.

Status values: `OK`, `NO_BEACON`, `HOSTAPD_FAIL` (AP radio could not announce the country), `CRASH`, `TIMEOUT`, `ENV_FATAL`.

## Reading one capture

Sections, in order: header (country, card, firmware, kernel, AP details, CPU temperature), beacon check, Country IEs heard, `lsusb`, `lspci`, `ethtool -i`, `iw dev`, `ip -br link`, `rfkill list`, kernel-log ucode lines, the scan, `iw reg get`, self-managed check, kernel-log LAR lines, `iw list`, `iw <phy> info`, `iw <phy> channels`, crash-pattern check.

- **The card's own regdomain** is the `phyN (self-managed)` block inside the `iw reg get` section. That block and the `iw <phy> channels` table are the data to use.
- The `global` block in the same output belongs to the access point's radio and the Pi's regulatory database, not to the card.
- `iw list` also describes the access point's radio. Use `iw <phy> info` for the card.
- The "LAR lines" section is empty: no LAR messages appear in the kernel log on this kernel.

## Results

| | BE200 (ucode 106.c88d33af.0) | AX210 (ucode 89.f7dcb3ee.0) |
|---|---|---|
| Captures | 250 (249 country codes + `00`) | 250 (249 country codes + `00`) |
| Distinct rule sets | 29 | 20 |
| Countries with only world-domain data | AN | 56 (52 reported as `00`, plus BJ, BY, DZ, UA) |

BE200 vs AX210, 249 countries in both:

- 55 countries have only world-domain data on the AX210 but country-specific data on the BE200 (including CN, UA, BY, IR, KP, CU, SY, IQ, UZ, MO); none is the other way round.
- For 14 countries the BE200 enables 6 GHz channels and the AX210 enables none (never the reverse): BF, GM, GQ, HT, IQ, MO, MZ, SC, SL, SZ, TT, TZ, UZ, ZW.
- Enabled 5 GHz channel counts differ for 20 countries. For the US family and CA the BE200 has 28 and the AX210 has 25; for AL, AO, KM, OM, RS, TR, ZA, BY and RU the AX210 has more.
- 167 of the 249 countries have the same data type and the same 5 GHz and 6 GHz channel counts on both cards. Equal counts do not mean identical rules (for example, the AX210 rules carry `NO-320MHZ`).

Both cards report `00` for `AN` (a retired country code).

## Notes and limitations

- `TG` (Togo) is not included: the AP radio's regulatory data disallows AP mode on every channel under TG, so the test beacon could not be created.
- The beacon channel varies by country; `AP_CHANNEL` in each status file records it. A control run for DE (2.4 GHz beacon vs 5 GHz beacon) gave identical card data; it was checked for one country only.
- Signal strength at the card inside the cage was roughly -80 dBm (BE200) and -66 dBm (AX210).
- One interruption on the BE200: the Pi hung during a driver reload part-way through the sweep and the card was not seen again until after a power cycle. Countries finished before the hang were kept; two whose results had not reached disk were captured again. The cause was not confirmed.
- The first BE200 captures (the ten-country pilot) were taken with earlier builds of the capture script. The format is the same, but their status files may lack later fields such as the card country and CPU temperature.
- A card reporting the requested country label does not by itself mean it has country-specific rules; compare against the `00` baseline, as `lar_groups.txt` does.

## Analysing the data yourself

`lar_compare.py` from the repository works on this package (standard-library Python):

```
python3 lar_compare.py BE200/<run folder>/                        # groups, world-baseline check
python3 lar_compare.py BE200/<run folder>/ --diff US JP           # differences between two countries
python3 lar_compare.py BE200/<run folder>/ --cards AX210/<run folder>/   # side-by-side summary of two cards
```
