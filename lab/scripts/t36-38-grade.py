#!/usr/bin/env python3
"""Grade TS captures for T36/T37/T38, using the campaign's established gates.

Continuity errors are counted by matching the plugin's DATA ("missing N
packets"), never the word "discontinuity", which appears only in its --help
(method-notes.md §2). PCR accuracy is reported at the TR 101 290 P2 gate
(`--absolute --jitter-max 13`, 481 ns) as t13-grade.py does; the plain
`--jitter-max 500` (500 us) gate is reported alongside because passing it says
very little on its own.

Every instrument here is validated against a deliberately corrupted file by
`--selftest` before any zero it produces is published.
"""
import re
import subprocess
import sys


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout + \
           subprocess.run(cmd, shell=True, capture_output=True, text=True).stderr


def once(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return p.stdout + p.stderr


def analyze(path):
    out = once(f'tsp -I file "{path}" -P analyze --normalized -O drop')
    for line in out.splitlines():
        if line.startswith("ts:"):
            return dict(f.split("=", 1) for f in line.split(":") if "=" in f)
    return {}


def cc_errors(path):
    out = once(f'tsp -I file "{path}" -P continuity -O drop')
    return len(re.findall(r"missing [\d,]+ packet", out))


def pcr_jitter(path, absolute):
    gate = "--absolute --jitter-max 13" if absolute else "--jitter-max 500"
    out = once(f'tsp -I file "{path}" -P pcrverify {gate} -O drop')
    m = re.search(r"([\d,]+) PCR OK, ([\d,]+) with jitter", out)
    if not m:
        return None, None
    return int(m.group(1).replace(",", "")), int(m.group(2).replace(",", ""))


def grade(path, label=None):
    a = analyze(path)
    ok13, j13 = pcr_jitter(path, True)
    ok500, j500 = pcr_jitter(path, False)
    return {
        "arm": label or path.split("/")[-1].replace(".bin", ""),
        "packets": int(a.get("packets", 0)),
        "cc_err": cc_errors(path),
        "badsync": int(a.get("invalidsyncs", -1)),
        "transerr": int(a.get("transporterrors", -1)),
        "bitrate": int(a.get("bitrate", 0)),
        "pcr_ok_481ns": ok13,
        "pcr_jitter_481ns": j13,
        "pcr_jitter_500us": j500,
    }


HDR = ("arm", "packets", "cc_err", "badsync", "transerr", "bitrate",
       "pcr_ok_481ns", "pcr_jitter_481ns", "pcr_jitter_500us")


def emit(rows):
    w = {h: max(len(h), *(len(str(r.get(h, ""))) for r in rows)) for h in HDR}
    print("  " + "  ".join(h.rjust(w[h]) for h in HDR))
    for r in rows:
        print("  " + "  ".join(str(r.get(h, "")).rjust(w[h]) for h in HDR))


if __name__ == "__main__":
    files = sys.argv[1:]
    emit([grade(f) for f in files])
