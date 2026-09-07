#!/usr/bin/env bash
# C3 replicates: is the deadline shed a measurement or a coin toss?
#
# The A/B of upstream #3271 (t8b-c3-latmax-ab.sh) returned a clean null where
# nothing sheds and chaos where something does:
#
#   cell            record (2 Sep)   pre arm (today)   post arm (today)
#   n=1, 2s              9.44             9.49              9.49
#   n=2, 30s            10.35            10.01              9.95
#   n=2, 500ms           4.29             8.82              7.26
#   n=2, 2s              5.50             7.30              1.37
#
# The two cells that reproduce are the two where the subscriber is not shedding
# — uncontended, or contended with a budget deep enough that nothing misses it.
# Every cell where the shed is active moved by 60-100 %, on the *same* binary
# and the same rig for the pre arm. That is not a #3271 effect; it says the
# instrument C3's conclusion rests on has a spread comparable to the effect it
# reported, and the sweep was one run per cell.
#
# So the question is no longer "did #3271 move C3" but "was there a stable
# number to move". Four cells, REPS replicates each, everything else pinned:
#
#   pre/post x {500ms, 2s} at n=2 under cake
#
# Replicates are interleaved rather than blocked — rep 1 of all four cells,
# then rep 2, and so on — so a drift in host load over the run cannot pool
# into one arm. Blocking would let a busy half-hour become a "result".
#
# Captures are graded in-script the moment the cell's writer has exited, and
# only then deleted: 20 cells at ~103 MB does not fit the margin, but the
# derived numbers are what the record needs and an ungraded capture deleted to
# save space is how four of the first C3 pass's six aggregates were lost.
# Grading a capture while its writer is still running is its own trap — it
# reported a healthy cell as 65 s of programme in a 90 s window during the A/B.
set -uo pipefail

DIR=/home/ubuntu/t8b/prov
NETNS=/home/ubuntu/t8b/t8b-netns.sh
CELL=/home/ubuntu/t8b/t8b-provisioned.sh
SPAN=/home/ubuntu/t8b/t8b-c3-span.py

PRE=${PRE:-/home/ubuntu/bin-3271pre/moq}
POST=${POST:-/home/ubuntu/bin-3271post/moq}
REPS=${REPS:-5}
SECS=${SECS:-90}
SUMMARY=${SUMMARY:-/home/ubuntu/t8b/c3reps.csv}

for b in "$PRE" "$POST"; do
	[ -x "$b" ] || {
		echo "missing arm: $b" >&2
		exit 1
	}
done

echo "=== arms ==="
echo "pre:  $("$PRE" --version 2>&1 | head -1)"
echo "post: $("$POST" --version 2>&1 | head -1)"

echo "=== $(date -u +%FT%TZ) stopping loop publisher ==="
sudo systemctl stop moq-publisher-cnn-loop

cleanup() {
	sudo bash "$NETNS" down >/dev/null 2>&1
	sudo systemctl start moq-publisher-cnn-loop
	echo "loop: $(systemctl is-active moq-publisher-cnn-loop)"
	df -h / | tail -1
}
trap cleanup EXIT

sudo bash "$NETNS" up

[ -f "$SUMMARY" ] || echo "rep,arm,latmax,agg_mbps,agg_pct_cap,cc,pcr_over40,pcr_max_ms,span_s,keep_up,holes,rewinds" >"$SUMMARY"

cell() {
	local rep=$1 arm=$2 bin=$3 lat=$4
	local label="c3rep-$rep-$arm-$lat"
	local run="$DIR/$label"
	echo "=== $(date -u +%FT%TZ) $label ==="
	local out
	out=$(sudo env QDISC=cake CAP_MBIT=15 SECS="$SECS" QUEUE_MS=500 DELAY_MS=50 \
		TRANSPORT=cubic NFLOWS=2 LATMAX="$lat" DIR="$DIR" \
		MOQ="$bin" bash "$CELL" "$label" 2>&1 | grep -E "^RESULT" | tail -1)
	echo "$out"

	local agg pct cc o40 pmax
	agg=$(sed -E 's/.*agg_mbps=([0-9.]+).*/\1/' <<<"$out")
	pct=$(sed -E 's/.*agg_pct_cap=([0-9]+).*/\1/' <<<"$out")
	cc=$(sed -E 's/.*[^_]cc=([0-9]+).*/\1/' <<<"$out")
	o40=$(sed -E 's/.*pcr_over40=([0-9]+).*/\1/' <<<"$out")
	pmax=$(sed -E 's/.*pcr_max_ms=([0-9.]+).*/\1/' <<<"$out")

	sudo chown -R "$(id -u):$(id -g)" "$run" 2>/dev/null

	# Delivered programme, and PCR monotonicity. keep_up separates "held the
	# live edge with holes in it" from "clean but falling behind", which the
	# byte count cannot and which is the axis #3271 acts on.
	local span keep holes rew
	read -r span keep holes < <(python3 "$SPAN" "$SECS" "$run/out.ts" 2>/dev/null |
		sed -nE 's/.*span=([0-9.]+)s window=[0-9]+s keep_up=([0-9.]+).*/\1 \2/p;s/.*holes>[0-9]+ms=([0-9]+).*/\1/p' |
		tr '\n' ' ')
	rew=$(python3 - "$run/pcr.csv" <<'EOF'
import csv,sys
try:
    v=[int(r["Value"]) for r in csv.DictReader(open(sys.argv[1])) if r.get("Type")=="PCR"]
except Exception:
    print("NA"); raise SystemExit
print(sum(1 for a,b in zip(v,v[1:]) if b<a))
EOF
	)
	echo "  span=${span:-NA}s keep_up=${keep:-NA} holes=${holes:-NA} rewinds=${rew:-NA}"
	echo "$rep,$arm,$lat,$agg,$pct,$cc,$o40,$pmax,${span:-NA},${keep:-NA},${holes:-NA},${rew:-NA}" >>"$SUMMARY"

	# pcr.csv and series.csv are the audit trail and are kept; the capture is
	# now fully graded, so it is the only thing that goes.
	rm -f "$run"/out*.ts
	sleep 5
}

for rep in $(seq 1 "$REPS"); do
	for lat in 500ms 2s; do
		cell "$rep" pre "$PRE" "$lat"
		cell "$rep" post "$POST" "$lat"
	done
done

echo "=== $(date -u +%FT%TZ) done — $SUMMARY ==="
column -s, -t "$SUMMARY"
