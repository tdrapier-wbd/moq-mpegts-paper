#!/usr/bin/env bash
# T28 pass criterion 1: validate the media-lost grader before any cell is graded with it.
#
# A grader that has only ever been shown a clean capture has not been shown to work. This
# builds captures whose answer is known in advance and checks the grader recovers it:
#
#   control   an unimpaired slice                  -> expect ~0 s lost
#   hole-N    a slice with N seconds excised       -> expect N s +/- 100 ms
#
# The excision is done by packet index, and the *true* hole is then read out of the clip's
# own PCR timeline rather than assumed from the requested duration -- the clip is not
# exactly CBR, so "cut 5 seconds' worth of packets" and "cut 5.000 s of programme" differ
# by a few milliseconds. Grading against the requested figure instead of the delivered one
# would charge the grader for the knife's error.
#
# Usage: t28-grader-selftest.sh [clip] [outdir]
set -euo pipefail

CLIP="${1:-$HOME/CNNiEMEA.ts}"
OUT="${2:-/tmp/t28-selftest}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRADER="$HERE/t28-media-lost.py"
# Both references are validated against the same known answers: DOMAIN=file (CBR, the default)
# and DOMAIN=wire (PCR cadence). A grader is only validated in the domain it was exercised in.
DOMAIN="${DOMAIN:-file}"
TOLERANCE_MS=100

[ -r "$CLIP" ] || { echo "FAIL: clip not readable: $CLIP" >&2; exit 1; }
[ -x "$GRADER" ] || [ -r "$GRADER" ] || { echo "FAIL: grader not found: $GRADER" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.ts "$OUT"/*.csv "$OUT"/*.json 2>/dev/null || true

# A window well clear of the clip's head, so the PCR timeline is established before the cut.
HEAD_PKTS=40000     # packets kept before the excision
TAIL_PKTS=40000     # packets kept after it
fail=0

echo "== building the control =="
tsp -I file "$CLIP" -P until --packets $((HEAD_PKTS + TAIL_PKTS)) -O file "$OUT/control.ts" >/dev/null 2>&1

echo "== control: expect ~0 s lost =="
python3 "$GRADER" --input "$OUT/control.ts" --domain "$DOMAIN" --tolerance-ms "$TOLERANCE_MS" \
	--label control --json "$OUT/control.json"
CONTROL_LOST=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["media_lost_s"])' "$OUT/control.json")
# The control must be clean to the same tolerance the cells are graded at.
if python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1])) <= $TOLERANCE_MS/1000.0 else 1)" "$CONTROL_LOST"; then
	echo "  PASS control: ${CONTROL_LOST}s lost, within ${TOLERANCE_MS}ms of zero"
else
	echo "  FAIL control: ${CONTROL_LOST}s lost on an unimpaired capture"
	fail=1
fi

# Excise a run of packets and measure what the cut actually removed, from the clip's own clock.
for CUT_PKTS in 2000 10000 50000; do
	NAME="hole-${CUT_PKTS}"
	echo "== building $NAME =="
	tsp -I file "$CLIP" -P until --packets "$HEAD_PKTS" -O file "$OUT/$NAME.head.ts" >/dev/null 2>&1
	tsp -I file "$CLIP" -P skip --packets $((HEAD_PKTS + CUT_PKTS)) \
		-P until --packets "$TAIL_PKTS" -O file "$OUT/$NAME.tail.ts" >/dev/null 2>&1
	cat "$OUT/$NAME.head.ts" "$OUT/$NAME.tail.ts" > "$OUT/$NAME.ts"
	rm -f "$OUT/$NAME.head.ts" "$OUT/$NAME.tail.ts"

	# Ground truth: the programme time between the last PCR kept and the first PCR kept
	# after the cut, minus what the surviving packets themselves account for.
	TRUTH=$(python3 - "$CLIP" "$HEAD_PKTS" "$CUT_PKTS" <<-'PY'
	import subprocess, sys, csv, tempfile, statistics, os
	clip, head, cut = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
	with tempfile.TemporaryDirectory() as t:
	    out = os.path.join(t, "p.csv")
	    subprocess.run(["tsp", "-I", "file", clip, "-P", "until", "--packets", str(head + cut + 200000),
	                    "-P", "pcrextract", "--output-file", out, "-O", "drop"],
	                   check=True, capture_output=True)
	    by = {}
	    with open(out, newline="") as fh:
	        r = csv.reader(fh); next(r)
	        for row in r:
	            if len(row) > 5 and row[3] == "PCR":
	                by.setdefault(int(row[0]), []).append((int(row[1]), int(row[5])))
	    s = max(by.values(), key=len)
	    s = [(i, v / 27_000_000) for i, v in s]
	    rates = [((i1 - i0) * 188 * 8) / (t1 - t0) for (i0, t0), (i1, t1) in zip(s, s[1:]) if t1 > t0]
	    bps = statistics.median(rates)
	    # Last sample at or before the cut, and first at or after its end.
	    before = [x for x in s if x[0] <= head]
	    after = [x for x in s if x[0] >= head + cut]
	    if not before or not after:
	        print("NA"); raise SystemExit
	    i0, t0 = before[-1]; i1, t1 = after[0]
	    # Programme time across the join, less the time the surviving packets in that
	    # span legitimately account for.
	    kept = (head - i0) + (i1 - (head + cut))
	    print(f"{(t1 - t0) - (kept * 188 * 8) / bps:.6f}")
	PY
	)
	[ "$TRUTH" = "NA" ] && { echo "  SKIP $NAME: no PCR either side of the cut"; continue; }

	python3 "$GRADER" --input "$OUT/$NAME.ts" --domain "$DOMAIN" --tolerance-ms "$TOLERANCE_MS" \
		--label "$NAME" --json "$OUT/$NAME.json"
	MEASURED=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["media_lost_s"])' "$OUT/$NAME.json")
	if python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= $TOLERANCE_MS/1000.0 else 1)" \
		"$MEASURED" "$TRUTH"; then
		echo "  PASS $NAME: injected ${TRUTH}s, measured ${MEASURED}s"
	else
		echo "  FAIL $NAME: injected ${TRUTH}s, measured ${MEASURED}s (outside ${TOLERANCE_MS}ms)"
		fail=1
	fi
done

# Duplication is a separate code path and a separate column, so it gets its own cell: a
# repeated run of packets, which must be reported as duplication and must NOT be netted
# against the loss column.
echo "== building dup-repeat =="
REPEAT_PKTS=20000
tsp -I file "$CLIP" -P until --packets "$HEAD_PKTS" -O file "$OUT/d.a.ts" >/dev/null 2>&1
tsp -I file "$CLIP" -P skip --packets "$HEAD_PKTS" -P until --packets "$REPEAT_PKTS" -O file "$OUT/d.b.ts" >/dev/null 2>&1
tsp -I file "$CLIP" -P skip --packets $((HEAD_PKTS + REPEAT_PKTS)) -P until --packets "$TAIL_PKTS" -O file "$OUT/d.c.ts" >/dev/null 2>&1
cat "$OUT/d.a.ts" "$OUT/d.b.ts" "$OUT/d.b.ts" "$OUT/d.c.ts" > "$OUT/dup-repeat.ts"
rm -f "$OUT/d.a.ts" "$OUT/d.b.ts" "$OUT/d.c.ts"

# The repeated run's own duration, measured the same way as the excisions above.
DUP_TRUTH=$(python3 - "$CLIP" "$HEAD_PKTS" "$REPEAT_PKTS" <<-'PY'
import subprocess, sys, csv, tempfile, statistics, os
clip, head, rep = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with tempfile.TemporaryDirectory() as t:
    out = os.path.join(t, "p.csv")
    subprocess.run(["tsp", "-I", "file", clip, "-P", "until", "--packets", str(head + rep + 200000),
                    "-P", "pcrextract", "--output-file", out, "-O", "drop"],
                   check=True, capture_output=True)
    by = {}
    with open(out, newline="") as fh:
        r = csv.reader(fh); next(r)
        for row in r:
            if len(row) > 5 and row[3] == "PCR":
                by.setdefault(int(row[0]), []).append((int(row[1]), int(row[5])))
    s = [(i, v / 27_000_000) for i, v in max(by.values(), key=len)]
    rates = [((i1 - i0) * 188 * 8) / (t1 - t0) for (i0, t0), (i1, t1) in zip(s, s[1:]) if t1 > t0]
    print(f"{(rep * 188 * 8) / statistics.median(rates):.6f}")
PY
)
python3 "$GRADER" --input "$OUT/dup-repeat.ts" --domain "$DOMAIN" --tolerance-ms "$TOLERANCE_MS" \
	--label dup-repeat --json "$OUT/dup-repeat.json"
DUP_MEASURED=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["media_duplicated_s"],d["media_lost_s"])' "$OUT/dup-repeat.json")
set -- $DUP_MEASURED
if python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= $TOLERANCE_MS/1000.0 and abs(float(sys.argv[3])) <= $TOLERANCE_MS/1000.0 else 1)" \
	"$1" "$DUP_TRUTH" "$2"; then
	echo "  PASS dup-repeat: repeated ${DUP_TRUTH}s, measured ${1}s duplicated and ${2}s lost"
else
	echo "  FAIL dup-repeat: repeated ${DUP_TRUTH}s, measured ${1}s duplicated and ${2}s lost"
	fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "GRADER SELFTEST PASS: control clean and every injected hole recovered within ${TOLERANCE_MS}ms"
else
	echo "GRADER SELFTEST FAIL: do not grade T28 cells with this build"
fi
exit "$fail"
