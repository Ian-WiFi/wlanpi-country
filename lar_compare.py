#!/usr/bin/env python3
"""
lar_compare.py - analyse the raw per-country captures written by wlanpi_intel.sh.

  python3 lar_compare.py BE200/<kernel>__ucode_<ver>/              group countries by identical card data
  python3 lar_compare.py RUN_A --compare RUN_B                      what changed per country between two ucode/kernel runs
  python3 lar_compare.py RUN_A --diff US JP                         line-level difference between two countries
  python3 lar_compare.py RUN_A --cards RUN_B                        side-by-side summary of two cards (e.g. BE200 vs AX210)

Reads only the standard library. Output goes to <RUN_DIR>/analysis/ (and a summary to the screen).

What it compares, per country file:
  * the card's own (self-managed) regdomain rules from `iw reg get`
  * the full per-channel table from `iw phyN channels` (enabled/disabled, power, No IR, radar/DFS, widths)
Volatile values (phy numbers, "usable (for N sec)" timers) are ignored so identical data hashes identically.
"""
import argparse, csv, difflib, hashlib, re, sys
from collections import OrderedDict, defaultdict
from pathlib import Path

FNAME = re.compile(r'^wlanpi-(?P<model>[A-Za-z0-9_.]+)-(?P<cc>[A-Z0-9]{2})\.txt$')
CH_HEADER = re.compile(r'^(?:=+ |-+ |\$ )?iw phy\d+ channels\b')


def digest(items):
    return hashlib.sha1("\n".join(items).encode()).hexdigest()[:10]


def band_of(freq):
    if 2400 <= freq < 2500:
        return "2g"
    if 5000 <= freq < 5925:
        return "5g"
    if freq >= 5925:
        return "6g"
    return "other"


def parse_file(path):
    lines = path.read_text(errors="replace").replace("\r", "").split("\n")
    rec = {"file": path.name, "lar_country": "", "dfs_region": "", "rules": [], "channels": OrderedDict()}

    # ---- the card's own regdomain (self-managed block of `iw reg get`)
    for i, line in enumerate(lines):
        if re.match(r"^phy#\d+ \(self-managed\)", line):
            j = i + 1
            m = re.match(r"^country (\S+?):\s*(\S*)", lines[j]) if j < len(lines) else None
            if m:
                rec["lar_country"], rec["dfs_region"] = m.group(1), m.group(2)
                j += 1
            while j < len(lines) and lines[j].strip():
                rec["rules"].append(re.sub(r"\s+", " ", lines[j].strip()))
                j += 1
            break

    # ---- per-channel table of `iw phyN channels`
    start = next((i + 1 for i, l in enumerate(lines) if CH_HEADER.match(l)), None)
    if start is not None:
        cur = None
        for line in lines[start:]:
            if line.startswith("====="):
                break
            m = re.match(r"^\s*\* (\d+) MHz \[(\d+)\](.*)$", line)
            if m:
                freq, ch, tail = int(m.group(1)), int(m.group(2)), m.group(3)
                cur = {"freq": freq, "ch": ch, "disabled": "(disabled)" in tail, "attrs": []}
                rec["channels"][(freq, ch)] = cur
            elif line.startswith("Band") or (line.strip() and not line.startswith("\t")):
                cur = None
            elif cur is not None and line.strip():
                attr = re.sub(r"\(for \d+ sec\)", "", line.strip())      # drop the DFS timer
                cur["attrs"].append(re.sub(r"\s+", " ", attr).strip())

    # ---- header facts
    head = "\n".join(lines[:15])
    for key, pat in (("firmware", r"Firmware: (\S+)"), ("beacon_channel", r"beacon channel used: (\S+)"),
                     ("ies_heard", r"Country IEs heard in scan: ([^=\n][^\n]*?) ==")):
        m = re.search(pat, head)
        rec[key] = m.group(1).strip() if m else ""

    # ---- fingerprints and metrics
    rec["rules_hash"] = digest(rec["rules"]) if rec["rules"] else ""
    canon = []
    counts = defaultdict(int)
    max_power = 0.0
    for (freq, ch), c in sorted(rec["channels"].items()):
        canon.append("%d|%d|%s|%s" % (freq, ch, "D" if c["disabled"] else "E", "|".join(c["attrs"])))
        if c["disabled"]:
            continue
        b = band_of(freq)
        counts[b + "_enabled"] += 1
        if "Radar detection" in c["attrs"]:
            counts["dfs"] += 1
        if "No IR" not in c["attrs"]:
            counts["active"] += 1
        for a in c["attrs"]:
            m = re.match(r"Maximum TX power: ([\d.]+) dBm", a)
            if m:
                max_power = max(max_power, float(m.group(1)))
    rec["canon"] = canon
    rec["channels_hash"] = digest(canon) if canon else ""
    rec["counts"] = counts
    rec["max_power"] = max_power
    return rec


def load_run(run_dir):
    run_dir = Path(run_dir)
    if not run_dir.is_dir():
        sys.exit("Folder not found: %s" % run_dir)
    recs = OrderedDict()
    for p in sorted(run_dir.glob("wlanpi-*.txt")):
        m = FNAME.match(p.name)
        if not m:
            continue                       # skips triage files like wlanpi-BE200-DE.NO_BEACON.txt
        rec = parse_file(p)
        rec["model"] = m.group("model")
        recs[m.group("cc")] = rec
    return recs


def number_groups(recs, field, prefix):
    """Group country codes by the value of `field`; biggest group = 1."""
    groups = defaultdict(list)
    for cc, r in recs.items():
        groups[r[field]].append(cc)
    ordered = sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[1][0]))
    label = {h: "%s%d" % (prefix, i + 1) for i, (h, _) in enumerate(ordered)}
    return ordered, label


def describe(r):
    c = r["counts"]
    return "2.4GHz:%d ch, 5GHz:%d ch (%d DFS), 6GHz:%d ch, max %.0f dBm, DFS-%s" % (
        c["2g_enabled"], c["5g_enabled"], c["dfs"], c["6g_enabled"], r["max_power"],
        r["dfs_region"].replace("DFS-", "") or "?")


def writable_dir(out_dir):
    """Create out_dir; if it is not writable (e.g. root-owned results), fall back to ./lar_analysis/<name>."""
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
        probe = out_dir / ".write_test"
        probe.write_text("x")
        probe.unlink()
        return out_dir
    except OSError:
        alt = Path.cwd() / "lar_analysis" / out_dir.parent.name
        alt.mkdir(parents=True, exist_ok=True)
        print("NOTE: %s is not writable (probably root-owned); writing to %s instead.\n"
              "      Fix once with: sudo chown -R $USER: <results folder>\n" % (out_dir, alt))
        return alt


def cmd_group(run_dir, baseline, out_dir):
    recs = load_run(run_dir)
    if not recs:
        sys.exit("No wlanpi-<MODEL>-<CC>.txt files found in %s" % run_dir)
    rgroups, rlabel = number_groups(recs, "rules_hash", "R")
    cgroups, clabel = number_groups(recs, "channels_hash", "C")
    base = recs.get(baseline)

    out_dir = writable_dir(out_dir)
    cols = ["country", "card_country", "label_matches", "rules_group", "channel_group", "same_rules_as_00",
            "same_channels_as_00", "dfs_region", "n_rules", "ch_2g", "ch_5g", "ch_6g", "dfs_channels",
            "active_channels", "max_power_dbm", "firmware", "beacon_channel", "country_ies_heard", "file"]
    with open(out_dir / "lar_matrix.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for cc, r in recs.items():
            c = r["counts"]
            w.writerow([cc, r["lar_country"], "yes" if r["lar_country"] == cc else "NO", rlabel[r["rules_hash"]],
                        clabel[r["channels_hash"]],
                        ("yes" if base and r["rules_hash"] == base["rules_hash"] else "no") if base else "",
                        ("yes" if base and r["channels_hash"] == base["channels_hash"] else "no") if base else "",
                        r["dfs_region"], len(r["rules"]), c["2g_enabled"], c["5g_enabled"], c["6g_enabled"],
                        c["dfs"], c["active"], "%.1f" % r["max_power"], r["firmware"], r["beacon_channel"],
                        r["ies_heard"], r["file"]])

    out = []
    p = out.append
    p("LAR capture analysis: %s" % Path(run_dir).resolve().name)
    p("countries analysed: %d   distinct rule sets: %d   distinct channel tables: %d" % (len(recs), len(rgroups), len(cgroups)))
    bad = [cc for cc, r in recs.items() if not r["rules"]]
    if bad:
        p("!! no self-managed rules found in: %s" % " ".join(bad))
    mism = [(cc, r["lar_country"]) for cc, r in recs.items() if r["rules"] and r["lar_country"] != cc]
    if mism:
        p("\nCard reported a different country label than requested: " + ", ".join("%s->%s" % m for m in mism))
    if base:
        same = [cc for cc, r in recs.items() if cc != baseline and r["rules_hash"] == base["rules_hash"]]
        p("\nCountries whose rules are IDENTICAL to the %s world-domain baseline (the card gave them no country-specific data): %s"
          % (baseline, " ".join(same) if same else "none"))
    else:
        p("\n(no %s baseline file found, so no world-domain comparison)" % baseline)
    p("\n=== Groups of countries with identical card regdomain rules ===")
    for h, members in rgroups:
        first = recs[members[0]]
        p("\n%s  (%d)  %s" % (rlabel[h], len(members), describe(first)))
        p("    %s" % " ".join(sorted(members)))
    p("\n=== Groups of countries with identical per-channel tables ===")
    for h, members in cgroups:
        p("%s (%d): %s" % (clabel[h], len(members), " ".join(sorted(members))))
    text = "\n".join(out) + "\n"
    (out_dir / "lar_groups.txt").write_text(text)
    print(text)
    print("Wrote %s and %s" % (out_dir / "lar_groups.txt", out_dir / "lar_matrix.csv"))


def cmd_compare(run_a, run_b, out_dir):
    a, b = load_run(run_a), load_run(run_b)
    if not a or not b:
        sys.exit("No wlanpi-<MODEL>-<CC>.txt captures found in %s" % (run_a if not a else run_b))
    common = [cc for cc in a if cc in b]
    out = []
    p = out.append
    p("A = %s" % Path(run_a).resolve().name)
    p("B = %s" % Path(run_b).resolve().name)
    p("countries in both: %d   only in A: %s   only in B: %s" % (
        len(common), " ".join(sorted(set(a) - set(b))) or "-", " ".join(sorted(set(b) - set(a))) or "-"))
    changed = [cc for cc in common if a[cc]["rules_hash"] != b[cc]["rules_hash"] or a[cc]["channels_hash"] != b[cc]["channels_hash"]]
    p("countries with ANY difference: %d   identical: %d" % (len(changed), len(common) - len(changed)))
    p("changed: %s\n" % (" ".join(changed) or "none"))
    for cc in changed:
        ra, rb = a[cc], b[cc]
        p("=== %s ===  A: %s" % (cc, describe(ra)))
        p("          B: %s" % describe(rb))
        removed = [x for x in ra["rules"] if x not in rb["rules"]]
        added = [x for x in rb["rules"] if x not in ra["rules"]]
        for x in removed[:8]:
            p("  rule only in A: %s" % x)
        for x in added[:8]:
            p("  rule only in B: %s" % x)
        if len(removed) > 8 or len(added) > 8:
            p("  ... (%d rules only in A, %d only in B in total)" % (len(removed), len(added)))
        ca, cb = {k: v for k, v in zip(ra["channels"].keys(), ra["canon"])}, {k: v for k, v in zip(rb["channels"].keys(), rb["canon"])}
        diffs = [k for k in sorted(set(ca) | set(cb)) if ca.get(k) != cb.get(k)]
        for k in diffs[:10]:
            p("  channel %d [%d]:  A: %s   B: %s" % (k[0], k[1], (ca.get(k) or "absent").split("|", 3)[-1], (cb.get(k) or "absent").split("|", 3)[-1]))
        if len(diffs) > 10:
            p("  ... %d channels differ in total" % len(diffs))
        p("")
    text = "\n".join(out) + "\n"
    out_dir = writable_dir(out_dir)
    (out_dir / "lar_changes.txt").write_text(text)
    print(text)
    print("Wrote %s" % (out_dir / "lar_changes.txt"))


def world_flag(rec, base, cc, baseline):
    """'world' = the card gave this country no country-specific data (same rules as the 00 baseline)."""
    if cc == baseline:
        return "baseline"
    if base and rec["rules_hash"] == base["rules_hash"]:
        return "world"
    if rec["lar_country"] == baseline:
        return "world"
    return "specific"


def cmd_cards(run_a, run_b, baseline, out_dir):
    a, b = load_run(run_a), load_run(run_b)
    if not a or not b:
        sys.exit("No wlanpi-<MODEL>-<CC>.txt captures found in %s" % (run_a if not a else run_b))
    na, nb = next(iter(a.values()))["model"], next(iter(b.values()))["model"]
    if na == nb:
        na, nb = na + "-A", nb + "-B"
    ba, bb = a.get(baseline), b.get(baseline)
    _, la = number_groups(a, "rules_hash", "R")
    _, lb = number_groups(b, "rules_hash", "R")

    def info(r, base, lab, cc):
        if not r:
            return None
        return {"flag": world_flag(r, base, cc, baseline), "g5": r["counts"]["5g_enabled"],
                "g6": r["counts"]["6g_enabled"], "grp": lab[r["rules_hash"]], "pwr": r["max_power"]}

    rows = []
    for cc in sorted(set(a) | set(b)):
        rows.append((cc, info(a.get(cc), ba, la, cc), info(b.get(cc), bb, lb, cc)))

    out_dir = writable_dir(out_dir)
    with open(out_dir / "cards_summary.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["country", na + "_data", na + "_5g_ch", na + "_6g_ch", na + "_group",
                    nb + "_data", nb + "_5g_ch", nb + "_6g_ch", nb + "_group", "6g_differs", "5g_differs"])
        for cc, x, y in rows:
            both = x and y
            w.writerow([cc,
                        x["flag"] if x else "-", x["g5"] if x else "", x["g6"] if x else "", x["grp"] if x else "",
                        y["flag"] if y else "-", y["g5"] if y else "", y["g6"] if y else "", y["grp"] if y else "",
                        ("yes" if both and x["g6"] != y["g6"] else "no") if both else "",
                        ("yes" if both and x["g5"] != y["g5"] else "no") if both else ""])

    both_rows = [(cc, x, y) for cc, x, y in rows if x and y and cc != baseline]
    out = []
    p = out.append
    p("Card comparison: %s = %s    %s = %s" % (na, Path(run_a).resolve().name, nb, Path(run_b).resolve().name))
    p("Each card runs its own firmware, so a difference can come from the card or from the ucode version; "
      "this view cannot separate the two.")
    p("countries in both: %d   only in %s: %s   only in %s: %s" % (
        len(both_rows), na, " ".join(sorted(set(a) - set(b))) or "-", nb, " ".join(sorted(set(b) - set(a))) or "-"))
    wa = sorted(cc for cc, x, y in both_rows if x["flag"] == "world")
    wb = sorted(cc for cc, x, y in both_rows if y["flag"] == "world")
    p("\n%s gives only world-domain data (no country-specific rules) for %d countries." % (na, len(wa)))
    p("%s gives only world-domain data for %d countries." % (nb, len(wb)))
    only_a = [cc for cc in wa if cc not in wb]
    only_b = [cc for cc in wb if cc not in wa]
    p("\nWorld on %s but country-specific on %s (%d): %s" % (na, nb, len(only_a), " ".join(only_a) or "none"))
    p("World on %s but country-specific on %s (%d): %s" % (nb, na, len(only_b), " ".join(only_b) or "none"))
    d6 = [(cc, x["g6"], y["g6"]) for cc, x, y in both_rows if x["g6"] != y["g6"]]
    p("\n6 GHz enabled-channel count differs (%d countries): %s" % (
        len(d6), " ".join("%s(%d/%d)" % t for t in d6) or "none"))
    d5 = [(cc, x["g5"], y["g5"]) for cc, x, y in both_rows if x["g5"] != y["g5"]]
    p("5 GHz enabled-channel count differs (%d countries): %s" % (
        len(d5), " ".join("%s(%d/%d)" % t for t in d5) or "none"))
    p("(numbers in brackets are %s/%s)" % (na, nb))
    same = [cc for cc, x, y in both_rows if x["flag"] == y["flag"] and x["g5"] == y["g5"] and x["g6"] == y["g6"]]
    p("\nSame data type and same 5 GHz / 6 GHz channel counts on both cards: %d of %d countries" % (len(same), len(both_rows)))
    text = "\n".join(out) + "\n"
    (out_dir / "cards_summary.txt").write_text(text)
    print(text)
    print("Wrote %s and %s" % (out_dir / "cards_summary.txt", out_dir / "cards_summary.csv"))


def cmd_diff(run_dir, c1, c2):
    recs = load_run(run_dir)
    for cc in (c1, c2):
        if cc not in recs:
            sys.exit("no capture for %s in %s" % (cc, run_dir))
    for title, x, y in (("self-managed regdomain rules", recs[c1]["rules"], recs[c2]["rules"]),
                        ("per-channel table", recs[c1]["canon"], recs[c2]["canon"])):
        print("=== %s: %s vs %s ===" % (title, c1, c2))
        d = list(difflib.unified_diff(x, y, c1, c2, lineterm="", n=0))
        print("\n".join(d) if d else "(identical)")
        print()


def main():
    ap = argparse.ArgumentParser(description="Analyse wlanpi_intel.sh captures")
    ap.add_argument("run_dir", help="folder like BE200/<kernel>__ucode_<ver>/")
    ap.add_argument("--compare", metavar="OTHER_RUN_DIR", help="compare against another run (e.g. a different ucode)")
    ap.add_argument("--diff", nargs=2, metavar=("CC1", "CC2"), help="show differences between two countries")
    ap.add_argument("--cards", metavar="OTHER_RUN_DIR", help="side-by-side summary against another card's run")
    ap.add_argument("--baseline", default="00", help="country code used as the world-domain baseline (default 00)")
    ap.add_argument("--out", help="output folder (default <run_dir>/analysis)")
    a = ap.parse_args()
    out_dir = Path(a.out) if a.out else Path(a.run_dir) / "analysis"
    if a.diff:
        cmd_diff(a.run_dir, *a.diff)
    elif a.cards:
        cmd_cards(a.run_dir, a.cards, a.baseline, out_dir)
    elif a.compare:
        cmd_compare(a.run_dir, a.compare, out_dir)
    else:
        cmd_group(a.run_dir, a.baseline, out_dir)


if __name__ == "__main__":
    main()
