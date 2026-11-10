#!/usr/bin/env bash
# T83 Part A's cells in one pass: the controls, then every cell at each SRT latency, each graded as it
# ends (t12-merge-oracle.py, ts-passthrough-identity.py --groomed, tsp continuity) into summary.csv.
#
#   sudo BIN=<moq dir> PACER=<pacer dir> t83a-batch.sh <label>
#
# Env: LATS (SRT latencies, ms: "1000 2022"), CELLS, REPS (3), SECS (90), CONTROLS (1: T12's opaque pair
#      and the arrival-clocked pair first), KEEP (0: a clean run's pcap, reference and merge are
#      deleted once graded; a run that lost, conflicted or broke continuity keeps them). OUT
#      (/home/ubuntu/t83a) holds one directory per run and the summary.
set -uo pipefail

LABEL=${1:?label}
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${BIN:?set BIN}
PACER=${PACER:?set PACER}
LATS=${LATS:-"1000 2022"}
CELLS=${CELLS:-"control dark-a dark-b kill-a kill-b late-a late-b sender relay"}
REPS=${REPS:-3}
SECS=${SECS:-90}
CONTROLS=${CONTROLS:-1}
KEEP=${KEEP:-0}
OUT=${OUT:-/home/ubuntu/t83a}
U=${SUDO_USER:-ubuntu}
SUM=$OUT/$LABEL.summary.csv
[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
mkdir -p "$OUT"
chown "$U": "$OUT"
[ -s "$SUM" ] || echo "run,rig,srt_ms,clock,cell,rep,a_dgrams,b_dgrams,offset,confidence,mergeable,matched,mismatched,ts_identical_pct,lost,conflicts,longest_gap_ms,from_b,skew_med_ms,skew_min_ms,skew_max_ms,id_gaps,id_foreign,cc_errors" >"$SUM"

grade() { # $1 run dir, $2 run name, $3 rig, $4 srt_ms, $5 clock, $6 cell, $7 rep
	local d=$1 cc
	(
		cd "$d" || exit 1
		timeout 300 python3 "$H/t12-merge-oracle.py" --pcap legs.pcap --leg-a-port 5100 --leg-b-port 5200 \
			--k-ms 50 --out-prefix merged --json oracle.json >oracle.txt 2>&1
		timeout 200 python3 "$H/ts-passthrough-identity.py" ref.ts merged.seqmerge.ts --groomed \
			--json identity.json >identity.txt 2>&1
		tsp -I file merged.seqmerge.ts -P continuity -O drop >continuity.txt 2>&1
	)
	cc=$(grep -c '^\* continuity:' "$d/continuity.txt")
	local clean=1
	python3 - "$d" "$2" "$3" "$4" "$5" "$6" "$7" "$cc" >>"$SUM" <<'PY' || clean=0
import json, sys
d, run, rig, srt, clock, cell, rep, cc = sys.argv[1:]
def load(name):
    try:
        return json.load(open(f"{d}/{name}"))
    except (OSError, ValueError):
        return {}
o, i = load("oracle.json"), load("identity.json")
al, sm, sk = o.get("alignment", {}), o.get("seq_merge", {}), o.get("skew", {})
def f(x, n=1):
    return "" if x is None else (f"{x:.{n}f}" if isinstance(x, float) else str(x))
print(",".join([run, rig, srt, clock, cell, rep,
    f(o.get("leg_a", {}).get("datagrams")), f(o.get("leg_b", {}).get("datagrams")),
    f(o.get("sequence_offset")), f(o.get("offset_confidence"), 3), f(o.get("standard_receiver_mergeable")),
    f(al.get("matched")), f(al.get("mismatched")), f(al.get("rtp_timestamp_identical_pct"), 2),
    f(sm.get("lost_datagrams")), f(sm.get("conflicts")), f(sm.get("longest_gap_ms")), f(sm.get("from_b")),
    f(sk.get("median_ms")), f(sk.get("min_ms")), f(sk.get("max_ms")),
    f(i.get("gaps")), f(i.get("foreign")), cc]))
sys.exit(0 if sm.get("lost_datagrams") == 0 and sm.get("conflicts") == 0 and cc == "0" else 1)
PY
	tail -1 "$SUM"
	[ "$KEEP" = 1 ] || [ "$clean" = 0 ] || rm -f "$d/legs.pcap" "$d/ref.ts" "$d/merged.seqmerge.ts"
}

echo "=== $(date -u) t83a-batch $LABEL: LATS=$LATS REPS=$REPS SECS=$SECS ==="
if [ "$CONTROLS" = 1 ]; then
	for rep in $(seq 1 "$REPS"); do
		n="pos-$rep"
		CELL=control SECS=$SECS BIN=$BIN PACER=$PACER OUT=$OUT/$LABEL bash "$H/t12-opaque-late.sh" "$n" >"$OUT/$LABEL.$n.log" 2>&1
		grade "$OUT/$LABEL/$n-control" "$n" t12 - stream control "$rep"
		n="neg-$rep"
		CELL=control CLOCK=arrival SECS=$SECS BIN=$BIN PACER=$PACER OUT=$OUT/$LABEL bash "$H/t83-mixed-merge.sh" "$n" >"$OUT/$LABEL.$n.log" 2>&1
		grade "$OUT/$LABEL/$n-control" "$n" t83 1000 arrival control "$rep"
	done
fi
for lat in $LATS; do
	for cell in $CELLS; do
		for rep in $(seq 1 "$REPS"); do
			n="s$lat-r$rep"
			CELL=$cell SRT_LAT=$lat SECS=$SECS BIN=$BIN PACER=$PACER OUT=$OUT/$LABEL bash "$H/t83-mixed-merge.sh" "$n" \
				>"$OUT/$LABEL.$n-$cell.log" 2>&1
			grade "$OUT/$LABEL/$n-$cell" "$n" t83 "$lat" stream "$cell" "$rep"
		done
	done
done
chown -R "$U": "$OUT"
echo "=== $(date -u) t83a-batch $LABEL done: $SUM ==="
