#!/usr/bin/env bash
# P1-t grading, on the host holding the hand-off capture and every leg (T48's criteria 1–4).
#
#   p1t-grade.sh <run-dir> [tsc-dir]
#
# <run-dir> holds src.ts (the hand-off capture), a.ts and a-pcr.txt (leg A), b.ts (leg B, joined late),
# w.ts (the third leg), and each leg's exporter log; ts-passthrough-identity.py sits beside this script.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:?run dir}
TSC=${2:-$HOME/tree-0da3a773/test/ts}
ID="$HERE/ts-passthrough-identity.py"

{
	echo "--- release timing, leg A (pcr-timing.py --live, exit 0 = every hard check passes)"
	tail -n 12 "$OUT/a-pcr.txt"
	for leg in a b w; do
		[ -e "$OUT/$leg.ts" ] || continue
		echo "--- identity, leg $leg against the hand-off capture"
		span=()
		[ "$leg" = a ] && span=(--span-out "$OUT/a-span.ts")
		python3 "$ID" "$OUT/src.ts" "$OUT/$leg.ts" --json "$OUT/$leg-id.json" "${span[@]}"
		echo "exporter: $(sed 's/\x1b\[[0-9;]*m//g' "$OUT/$leg.log" | grep 'passthrough release clock' | tail -1)"
	done
	echo "--- legs B and W against leg A over their overlap"
	python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
ids = {x: json.load(open(f"{out}/{x}-id.json")) for x in "abw" if os.path.exists(f"{out}/{x}-id.json")}
A = open(f"{out}/a.ts", "rb").read()
a = ids["a"]
for x in "bw":
    if x not in ids:
        continue
    o = ids[x]
    lo, hi = max(a["first_source_packet"], o["first_source_packet"]), min(a["end_source_packet"], o["end_source_packet"])
    X = open(f"{out}/{x}.ts", "rb").read()
    ra = A[(lo - a["first_source_packet"]) * 188 : (hi - a["first_source_packet"]) * 188]
    rx = X[(lo - o["first_source_packet"]) * 188 : (hi - o["first_source_packet"]) * 188]
    same = ra == rx and len(ra) == (hi - lo) * 188
    print(f"{x} vs a: overlap source packets {lo}..{hi} ({(hi - lo) * 188 / 1e6:.1f} MB): {'identical' if same else 'DIFFERENT'}")
PY
	for f in a a-span; do
		echo "--- compliance.py on $f.ts"
		python3 "$TSC/compliance.py" --ts "$OUT/$f.ts" --report-json "$OUT/$f-tsc.json" 2>&1 | grep -E 'tstd|PASS|FAIL|WARN' | head -20
	done
} 2>&1 | tee "$OUT/grade.txt"
