#!/usr/bin/env python3
"""Grade a T33 Part A arm at P1, on every capture it kept.

Continuity is counted by matching the TSDuck plugin's *data* -- `missing N packets` -- and
never the word "discontinuity", which the plugin prints only in its `--help`. That matcher was
structurally zero in six earlier rigs (`method-notes.md` §2), so it is written once here and
validated against a deliberately broken file before any zero from it is published.

PCR accuracy is taken at both gates the campaign uses, because they differ by three orders of
magnitude and quoting one as the other has happened:

  --absolute --jitter-max 13    481 ns, the TR 101 290 P2 gate
  --jitter-max 500              500 us, a pre-check only

  t33-grade.py <run-dir> [<run-dir> ...]
  t33-grade.py --selftest <clean.ts> <broken.ts>
"""

import argparse
import os
import re
import subprocess
import sys

MISSING = re.compile(rb"missing ([\d,]+) packet")
PCRVERIFY = re.compile(rb"([\d,]+) PCR OK, ([\d,]+) with jitter")


def _run(cmd):
    return subprocess.run(cmd, capture_output=True).stderr + subprocess.run(cmd, capture_output=True).stdout


def cc_errors(path):
    """Total packets reported missing by the continuity plugin, and the number of events."""
    out = _run(["tsp", "-I", "file", path, "-P", "continuity", "-O", "drop"])
    hits = MISSING.findall(out)
    return len(hits), sum(int(h.replace(b",", b"")) for h in hits)


def pcr_jitter(path, absolute, jitter_max):
    cmd = ["tsp", "-I", "file", path, "-P", "pcrverify"]
    if absolute:
        cmd += ["--absolute"]
    cmd += ["--jitter-max", str(jitter_max), "-O", "drop"]
    out = _run(cmd)
    m = PCRVERIFY.search(out)
    if not m:
        return None, None
    return int(m.group(1).replace(b",", b"")), int(m.group(2).replace(b",", b""))


def pcr_intervals(path):
    """min/mean/max PCR interval in ms and the count over 40 ms, from pcrextract."""
    csv = path + ".pcr.csv"
    subprocess.run(
        ["tsp", "-I", "file", path, "-P", "pcrextract", "--pcr", "--csv", "-o", csv, "-O", "drop"],
        capture_output=True,
    )
    vals = []
    try:
        with open(csv) as fh:
            next(fh, None)
            for line in fh:
                f = line.rstrip("\n").split(",")
                if len(f) > 5 and f[5].strip().isdigit():
                    vals.append(int(f[5]))
    except OSError:
        return None
    if len(vals) < 2:
        return None
    MOD = (1 << 33) * 300
    d = []
    wraps = 0
    for a, b in zip(vals, vals[1:]):
        delta = (b - a) % MOD  # modular, so a 33-bit wrap is not read as a backwards clock
        if b < a:
            wraps += 1
        d.append(delta / 27000.0)
    return {
        "n": len(vals),
        "min": min(d),
        "mean": sum(d) / len(d),
        "max": max(d),
        "over40": sum(1 for x in d if x > 40.0),
        "wraps": wraps,
        "backwards": sum(1 for x in d if x > 1000.0),  # a modular delta near the modulus
    }


def grade(path, label):
    if not os.path.exists(path) or os.path.getsize(path) < 188:
        print(f"  {label:<10} MISSING or empty")
        return None
    pkts = os.path.getsize(path) // 188
    ev, miss = cc_errors(path)
    ok481, j481 = pcr_jitter(path, True, 13)
    ok500, j500 = pcr_jitter(path, False, 500)
    iv = pcr_intervals(path)
    print(f"  {label:<10} {pkts:7d} pkts  cc_events={ev} cc_missing={miss}", end="")
    if iv:
        print(
            f"  pcr n={iv['n']} min={iv['min']:.2f} mean={iv['mean']:.2f} max={iv['max']:.2f} ms"
            f" >40ms={iv['over40']} wraps={iv['wraps']}",
            end="",
        )
    if ok481 is not None:
        print(f"  jitter481ns={j481}/{ok481 + j481}", end="")
    if ok500 is not None:
        print(f"  jitter500us={j500}/{ok500 + j500}", end="")
    print()
    return {"pkts": pkts, "cc_events": ev, "cc_missing": miss, "iv": iv, "j481": j481, "j500": j500}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--selftest", action="store_true", help="treat the two paths as clean, broken")
    args = ap.parse_args()

    if args.selftest:
        clean, broken = args.paths[0], args.paths[1]
        c_ev, c_miss = cc_errors(clean)
        b_ev, b_miss = cc_errors(broken)
        print(f"clean  {clean}: {c_ev} events, {c_miss} packets missing")
        print(f"broken {broken}: {b_ev} events, {b_miss} packets missing")
        ok = c_ev == 0 and b_ev > 0
        print("SELFTEST PASS -- the counter reads both ways" if ok else "SELFTEST FAIL -- do not trust a zero")
        return 0 if ok else 1

    for d in args.paths:
        print(f"\n### {os.path.basename(d.rstrip('/'))}")
        for f, lab in (("source.ts", "source"), ("exported.ts", "exported"), ("groomed.ts", "groomed")):
            grade(os.path.join(d, f), lab)
    return 0


if __name__ == "__main__":
    sys.exit(main())
