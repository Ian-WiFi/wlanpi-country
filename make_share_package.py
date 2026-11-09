#!/usr/bin/env python3
"""
make_share_package.py - build a shareable copy of result folders with identifying details masked.

  python3 make_share_package.py BE200/<run>/ AX210/<run>/ --readme README_DATA.md \
          --extra DISCLAIMER.md LICENSE results --zip

What it does (the originals are never changed):
  * copies each result folder into <out>/<MODEL>/<run>/
  * masks MAC addresses (keeps the first three bytes, which only identify the chip vendor)
  * masks this machine's hostname and the "WLAN Pi <suffix>" SSID derived from it
  * masks private IPv4 addresses and /home/<user> paths
  * leaves out the large kernel logs in logs/ unless you pass --with-logs
  * checks the result for anything it should have masked, and writes SCRUBBED.txt
  * optionally zips the package (--zip)

Standard library only. Run it on the machine that produced the captures so the
hostname is detected, or pass --hostname NAME.
"""
import argparse
import re
import shutil
import socket
import sys
import zipfile
from pathlib import Path

MAC_RE = re.compile(r"(?<![0-9A-Fa-f:])([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?![0-9A-Fa-f:])")
IP_RE = re.compile(r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b")
HOME_RE = re.compile(r"/home/(?!user\b)[A-Za-z0-9._-]+")
SKIP_SUFFIXES = (".partial", ".tmp", ".bak")


class Scrubber:
    def __init__(self, hostname):
        self.counts = {"mac": 0, "hostname": 0, "ssid": 0, "ip": 0, "home": 0}
        self.host = hostname
        self.suffix = hostname[len("wlanpi-"):] if hostname.startswith("wlanpi-") else ""
        self.host_masked = "wlanpi-xxx" if self.suffix else "host-xxx"

    def text(self, s):
        def mac(m):
            self.counts["mac"] += 1
            return ":".join(m.group(1).lower().split(":")[:3] + ["xx", "xx", "xx"])

        s = MAC_RE.sub(mac, s)
        if self.suffix:
            ssid = "WLAN Pi " + self.suffix
            self.counts["ssid"] += s.count(ssid)
            s = s.replace(ssid, "WLAN Pi xxx")
        if self.host:
            self.counts["hostname"] += s.count(self.host)
            s = s.replace(self.host, self.host_masked)
        s, n = IP_RE.subn("x.x.x.x", s)
        self.counts["ip"] += n
        s, n = HOME_RE.subn("/home/user", s)
        self.counts["home"] += n
        return s

    def leftovers(self, s):
        found = []
        if any(m.group(1).split(":")[3:] != ["xx", "xx", "xx"] for m in MAC_RE.finditer(s)):
            found.append("unmasked MAC address")
        if self.host and self.host in s:
            found.append("hostname")
        if self.suffix and ("WLAN Pi " + self.suffix) in s:
            found.append("SSID suffix")
        if IP_RE.search(s):
            found.append("private IP address")
        if HOME_RE.search(s):
            found.append("/home path")
        return found


def copy_file(src, dst, scrub):
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        text = src.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError:
        text = src.read_text(encoding="utf-8", errors="replace")
    dst.write_text(scrub.text(text), encoding="utf-8")


def copy_tree(src, dst, scrub, with_logs):
    n = 0
    for p in sorted(src.rglob("*")):
        if not p.is_file() or p.name.endswith(SKIP_SUFFIXES):
            continue
        rel = p.relative_to(src)
        if rel.parts[0] == "logs" and not with_logs:
            continue
        copy_file(p, dst / rel, scrub)
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description="Build a shareable copy of result folders with identifying details masked")
    ap.add_argument("run_dirs", nargs="+", help="result folders such as BE200/<kernel>__ucode_<ver>/")
    ap.add_argument("--out", default="share_package", help="output folder (default share_package)")
    ap.add_argument("--readme", help="a file to put in the package root as README.md")
    ap.add_argument("--extra", nargs="*", default=[], help="extra files or folders to include (for example DISCLAIMER.md LICENSE results)")
    ap.add_argument("--with-logs", action="store_true", help="also include logs/ (large kernel logs, masked)")
    ap.add_argument("--hostname", default=socket.gethostname(), help="hostname to mask (default: this machine's)")
    ap.add_argument("--zip", action="store_true", help="also write <out>.zip")
    a = ap.parse_args()

    out = Path(a.out)
    if out.exists():
        sys.exit("%s already exists; remove it or choose another --out" % out)
    scrub = Scrubber(a.hostname)
    out.mkdir(parents=True)

    total = 0
    for rd in a.run_dirs:
        src = Path(rd.rstrip("/"))
        if not src.is_dir():
            sys.exit("Folder not found: %s" % rd)
        dst = out / src.resolve().parent.name / src.resolve().name
        n = copy_tree(src, dst, scrub, a.with_logs)
        print("copied %4d files  %s" % (n, dst.relative_to(out)))
        total += n

    if a.readme:
        r = Path(a.readme)
        if r.is_file():
            copy_file(r, out / "README.md", scrub)
            print("added README.md (from %s)" % r)
        else:
            print("WARNING: --readme file not found: %s" % r)
    for e in a.extra:
        p = Path(e)
        if p.is_file():
            copy_file(p, out / p.name, scrub)
            print("added %s" % p.name)
        elif p.is_dir():
            n = copy_tree(p, out / p.name, scrub, True)
            print("added %s/ (%d files)" % (p.name, n))
        else:
            print("WARNING: extra not found, skipped: %s" % e)

    c = scrub.counts
    (out / "SCRUBBED.txt").write_text(
        "This package was prepared with make_share_package.py.\n"
        "To avoid publishing details that identify the test device, the following were masked:\n"
        "  - MAC addresses: the last three bytes are replaced with xx (the first three bytes, which only identify the chip vendor, are kept)\n"
        "  - the device hostname and the SSID derived from it\n"
        "  - private IPv4 addresses and /home/<user> paths\n"
        "Full kernel logs (logs/) are %s.\n"
        "Nothing else was changed. The captures are otherwise exactly as recorded.\n"
        "Counts: %d MAC addresses, %d hostnames, %d SSIDs, %d IP addresses, %d home paths.\n"
        % ("included (masked)" if a.with_logs else "left out", c["mac"], c["hostname"], c["ssid"], c["ip"], c["home"]))

    # verify: nothing identifying is left
    bad = []
    nfiles = 0
    for p in sorted(out.rglob("*")):
        if not p.is_file():
            continue
        nfiles += 1
        found = scrub.leftovers(p.read_text(encoding="utf-8", errors="replace"))
        if found:
            bad.append((p.relative_to(out), found))
    size = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    print("\n%d files, %.1f MB. Masked: %d MAC addresses, %d hostnames, %d SSIDs, %d IPs, %d home paths."
          % (nfiles, size / 1e6, c["mac"], c["hostname"], c["ssid"], c["ip"], c["home"]))
    if bad:
        print("\nVERIFICATION FAILED, these files still contain identifying details:")
        for rel, found in bad:
            print("  %s: %s" % (rel, ", ".join(found)))
        sys.exit(1)
    print("Verification: no identifying details found.")

    if a.zip:
        zpath = Path(str(out) + ".zip")
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(out.rglob("*")):
                if p.is_file():
                    z.write(p, Path(out.name) / p.relative_to(out))
        print("Wrote %s (%.1f MB)" % (zpath, zpath.stat().st_size / 1e6))


if __name__ == "__main__":
    main()
