#!/bin/bash
# T33 Part C: grade a source BEFORE it becomes an input, and refuse it if it fails.
#
# Every campaign figure to date comes from a looped file whose conformance was established
# once. A live feed is different: it arrives graded by nobody, and the first result taken from
# it is a lane verdict on an ungraded source unless something stops that happening. This is
# that something -- a gate, run automatically on any new capture, that exits non-zero rather
# than letting an unconformant source into a measurement.
#
# What it deliberately does NOT do is pass or fail the *lane*. It characterises the input, so
# that a later egress figure can be read as a delta against a known source rather than as an
# absolute.
#
# Capture chain, with placeholders only -- the real values live in INSTRUCTIONS.local.md:
#
#   <SOURCE_INGEST>  the physical or IP point where the live feed arrives
#        |
#        +-- tsp -I <input plugin> -O file <capture>.ts     capture at ingress, unmodified
#        |
#        +-- t33-source-gate.sh <capture>.ts                 THIS GATE, before any publish
#        |
#        +-- moq import ts                                   only if the gate passed
#
# Usage: t33-source-gate.sh <capture.ts> [--json]

set -u
SRC="${1:?capture .ts}"
JSON=""
[ "${2:-}" = "--json" ] && JSON=1

[ -f "$SRC" ] || {
	echo "no such capture: $SRC" >&2
	exit 2
}
SZ=$(stat -f%z "$SRC" 2>/dev/null || stat -c%s "$SRC")
PKTS=$((SZ / 188))
[ "$PKTS" -lt 1000 ] && {
	echo "capture is $PKTS packets; too short to grade" >&2
	exit 2
}

python3 - "$SRC" "$JSON" <<'PY'
import json, os, re, subprocess, sys
src, as_json = sys.argv[1], bool(sys.argv[2])

def sh(cmd):
    r = subprocess.run(cmd, capture_output=True)
    return r.stdout + r.stderr

# Continuity, matched on the plugin's DATA and never on the word "discontinuity", which the
# plugin prints only in --help. That matcher read structurally zero in six earlier rigs.
cc = re.findall(rb"missing ([\d,]+) packet",
                sh(["tsp", "-I", "file", src, "-P", "continuity", "-O", "drop"]))
cc_events = len(cc)
cc_missing = sum(int(x.replace(b",", b"")) for x in cc)

# TEI and sync: a live feed is where these actually happen.
blob = open(src, "rb").read()
n = len(blob) // 188
bad_sync = sum(1 for i in range(n) if blob[i*188] != 0x47)
tei = sum(1 for i in range(n) if blob[i*188] == 0x47 and (blob[i*188+1] & 0x80))
signalled = sum(1 for i in range(n)
                if blob[i*188] == 0x47 and (blob[i*188+3] & 0x20)
                and blob[i*188+4] >= 1 and (blob[i*188+5] & 0x80))

# PCR interval distribution and the TR 101 290 repetition limit.
csv = src + ".srcgate.csv"
subprocess.run(["tsp", "-I", "file", src, "-P", "pcrextract", "--pcr", "--csv", "-o", csv, "-O", "drop"],
               capture_output=True)
vals, pids = [], set()
try:
    with open(csv) as fh:
        next(fh, None)
        for line in fh:
            f = line.split(",")
            if len(f) > 5 and f[5].strip().isdigit():
                vals.append(int(f[5]))
                pids.add(f[0])
except OSError:
    pass
MOD = (1 << 33) * 300
d = [((b - a) % MOD) / 27000.0 for a, b in zip(vals, vals[1:])]
over40 = sum(1 for x in d if x > 40.0)
# An interval past the limit is only an error when the jump is NOT signalled (ISO 13818-1
# 2.4.3.4), so a legal splice does not fail a source.
over40_unsignalled = max(0, over40 - signalled)

# Service presence: a source with no PMT cannot be imported at all, which is worth catching
# here rather than as a silent no-op publish later.
an = sh(["tsanalyze", src]).decode(errors="replace")
m = re.search(r"Services: \.*\s*(\d+)", an)
services = int(m.group(1)) if m else 0
m = re.search(r"Selected reference bitrate: \.*\s*([\d,]+) b/s", an)
bitrate = int(m.group(1).replace(",", "")) if m else 0

checks = [
    ("sync",            bad_sync == 0,               f"{bad_sync} packets with a bad sync byte"),
    ("transport_error", tei == 0,                    f"{tei} packets with transport_error_indicator"),
    ("continuity",      cc_events == 0,              f"{cc_events} events, {cc_missing} packets missing"),
    ("services",        services >= 1,               f"{services} service(s); 0 cannot be imported"),
    ("pcr_present",     len(vals) > 0,               f"{len(vals)} PCR samples on {len(pids)} PID(s)"),
    ("pcr_single_pid",  len(pids) <= 1,              f"PCR on {len(pids)} PID(s)"),
    ("pcr_repetition",  over40_unsignalled == 0,     f"{over40_unsignalled} unsignalled intervals over 40 ms "
                                                     f"({over40} total, {signalled} signalled)"),
]
ok = all(c[1] for c in checks)
res = {
    "source": src, "packets": n, "bitrate_bps": bitrate, "services": services,
    "pcr_samples": len(vals), "pcr_pids": sorted(pids),
    "pcr_interval_ms": {"min": round(min(d), 3), "mean": round(sum(d)/len(d), 3), "max": round(max(d), 3)} if d else None,
    "continuity_events": cc_events, "continuity_missing": cc_missing,
    "signalled_discontinuities": signalled,
    "checks": {k: v for k, v, _ in checks},
    "verdict": "PASS" if ok else "FAIL",
}
if as_json:
    print(json.dumps(res, indent=2))
else:
    print(f"### source gate - {os.path.basename(src)}")
    print(f"  {n} packets, {bitrate:,} b/s, {services} service(s), {len(vals)} PCR on {sorted(pids)}")
    if d:
        print(f"  PCR interval min {min(d):.2f} / mean {sum(d)/len(d):.2f} / max {max(d):.2f} ms")
    for k, v, detail in checks:
        print(f"  {'PASS' if v else 'FAIL'}  {k:<16} {detail}")
    print(f"\n  {res['verdict']} - "
          + ("safe to use as a measurement input" if ok
             else "DO NOT publish this as an input; a lane figure taken from it grades the source"))
sys.exit(0 if ok else 1)
PY
