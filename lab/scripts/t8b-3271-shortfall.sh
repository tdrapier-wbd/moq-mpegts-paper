#!/usr/bin/env bash
# Isolate the condition under which #3271 kills `moq export ts`.
#
# The replicate sweep found that the post-#3271 client terminates with
#
#   Error: hang: moq error: old
#
# in 5 of 9 contended cells, where the pre-#3271 client did so in 0 of 10. The
# log gives the mechanism: the consumer skips 36 evicted groups
# ("current group evicted; skipping to next buffered group error=Hang(Moq(Old))"),
# then cancels all eight track subscriptions as idle, then exits. #3271's design
# is to wait for a late group within the latency budget instead of skipping it on
# arrival order, so on a link that cannot carry the feed, waiting guarantees the
# relay evicts the very group being waited for. The pre arm skipped immediately,
# never fell behind, and never evicted.
#
# If that mechanism is right, two flows are incidental: what matters is that the
# receiver cannot keep up. This cell tests exactly that with **one** publisher
# and **one** subscriber, and the cap as the only variable:
#
#   CAP >= source rate   no shortfall   -> expect both arms to survive
#   CAP <  source rate   shortfall      -> expect the post arm to die
#
# A single-subscriber repro on a rate-limited link is also a far better artefact
# for an upstream report than a two-flow contention rig, because it removes
# fairness, scheduling and the second publisher from the story entirely.
#
# Longer than the 90 s default: the deaths clustered at 54-57 s, so a 90 s window
# leaves little room to distinguish "survived" from "had not died yet". 150 s
# gives roughly three times the observed time-to-death.
set -uo pipefail

DIR=/home/ubuntu/t8b/prov
NETNS=/home/ubuntu/t8b/t8b-netns.sh
CELL=/home/ubuntu/t8b/t8b-provisioned.sh
SPAN=/home/ubuntu/t8b/t8b-c3-span.py

PRE=${PRE:-/home/ubuntu/bin-3271pre/moq}
POST=${POST:-/home/ubuntu/bin-3271post/moq}
REPS=${REPS:-3}
SECS=${SECS:-150}
# The clip is 9.95 Mb/s CBR. 8 Mb/s is a real shortfall; 15 Mb/s is the
# no-shortfall control at the same cap C3 used.
CAPS=${CAPS:-"8 15"}
SUMMARY=${SUMMARY:-/home/ubuntu/t8b/c3short.csv}

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

[ -f "$SUMMARY" ] || echo "rep,arm,cap_mbit,agg_mbps,cc,pcr_over40,span_s,keep_up,died,exit_error,evictions" >"$SUMMARY"

cell() {
	local rep=$1 arm=$2 bin=$3 cap=$4
	local label="c3short-$rep-$arm-cap$cap"
	local run="$DIR/$label"
	echo "=== $(date -u +%FT%TZ) $label ==="
	local out
	out=$(sudo env QDISC=cake CAP_MBIT="$cap" SECS="$SECS" QUEUE_MS=500 DELAY_MS=50 \
		TRANSPORT=cubic NFLOWS=1 LATMAX=2s DIR="$DIR" \
		MOQ="$bin" bash "$CELL" "$label" 2>&1 | grep -E "^RESULT" | tail -1)
	echo "$out"

	local agg cc o40
	agg=$(sed -E 's/.*agg_mbps=([0-9.]+).*/\1/' <<<"$out")
	cc=$(sed -E 's/.*[^_]cc=([0-9]+).*/\1/' <<<"$out")
	o40=$(sed -E 's/.*pcr_over40=([0-9]+).*/\1/' <<<"$out")

	sudo chown -R "$(id -u):$(id -g)" "$run" 2>/dev/null

	# The subscriber is run under `timeout $SECS`, so a clean run is killed by
	# the timeout and writes no "Error:" line. An "Error:" line therefore means
	# it exited on its own, which is the event under test.
	local died err evict
	if grep -q "^Error:" "$run/sub.log" 2>/dev/null; then
		died=yes
		err=$(sed -e 's/\x1b\[[0-9;]*m//g' "$run/sub.log" | grep -m1 "^Error:" | cut -c1-60 | tr ',' ';')
	else
		died=no
		err=""
	fi
	# `grep -c` prints 0 and exits 1 when there is no match, so `|| echo 0`
	# emits a second 0 on its own line and corrupts the CSV. Swallow the
	# status instead of substituting a value.
	evict=$(grep -c "current group evicted" "$run/sub.log" 2>/dev/null) || evict=0

	local span keep
	read -r span keep < <(python3 "$SPAN" "$SECS" "$run/out.ts" 2>/dev/null |
		sed -nE 's/.*span=([0-9.]+)s window=[0-9]+s keep_up=([0-9.]+).*/\1 \2/p')

	echo "  died=$died evictions=$evict span=${span:-NA}s keep_up=${keep:-NA} ${err:+[$err]}"
	echo "$rep,$arm,$cap,$agg,$cc,$o40,${span:-NA},${keep:-NA},$died,${err:-none},$evict" >>"$SUMMARY"

	rm -f "$run"/out*.ts
	sleep 5
}

for rep in $(seq 1 "$REPS"); do
	for cap in $CAPS; do
		cell "$rep" pre "$PRE" "$cap"
		cell "$rep" post "$POST" "$cap"
	done
done

echo "=== $(date -u +%FT%TZ) done ==="
column -s, -t "$SUMMARY"
