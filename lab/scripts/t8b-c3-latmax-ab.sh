#!/usr/bin/env bash
# C3 re-check: does upstream #3271 move the deadline-shedding collapse?
#
# C3 measured a media-aware aggregate that *falls* as feeds are added, and the
# --latency-max sweep attributed it to per-subscriber deadline shedding: each
# subscriber independently discards groups that missed its own budget, so the
# sum of what survives drops below what one unopposed subscriber delivered.
#
# #3271 (`fix(moq-mux): wait for late groups within the latency budget`, merged
# 2026-09-01, one file: rs/moq-mux/src/container/consumer.rs) rewrote the gate
# that decides exactly that. Before it, `Consumer::poll_read` skipped a missing
# lower group the moment any newer group was buffered, on the claim that the
# relay delivers in order — which under contention it does not, because groups
# ride independent QUIC streams and newer sequences hold higher priority. After
# it the gap is held until `max_timestamp - next_start >= latency`, i.e. until
# the budget itself expires. `moq export ts --latency-max` reaches that gate
# (subscribe.rs `run_ts` -> `ts::Export::with_latency`), so C3's mechanism sits
# squarely in the changed path and C3's numbers were taken before the change.
#
# The arms are the isolating pair built by t8b-build-3271-pair.sh:
#   pre   ~/bin-3271pre/moq    8206a35a6, #3271's merge-base
#   post  ~/bin-3271post/moq   bec7c4b59, #3271's merge
# They differ by one file, rs/moq-mux/src/container/consumer.rs, so nothing but
# the group-delivery gate varies. Both arms share ONE relay binary
# (~/moq-relay-quinn), so the client is the only variable at all.
#
# **Do not substitute a newer release for the post arm.** The first attempt did
# exactly that — 0.9.11-eab96019 against the 0.9.15 release — and the result is
# void, because #3006 ("pace the TS stdout export on each frame's timestamp")
# also lands between them. C3's instrument is bytes inside a fixed window, and
# #3006 changes when bytes leave the exporter: the older arm drains on arrival,
# the newer paces to media time. That moves a windowed byte count on its own,
# so the comparison measures the instrument rather than the subject. The
# isolating pair already carries #3006 on both sides.
#
# Interleaved arm-by-arm within each budget, never all of one arm then all of
# the other: this box is 2 vCPU and shared with a standing relay, so a drift in
# host load must land on both arms rather than on one.
#
# Usage:  sudo -v; bash t8b-c3-latmax-ab.sh
set -uo pipefail

DIR=/home/ubuntu/t8b/prov
NETNS=/home/ubuntu/t8b/t8b-netns.sh
CELL=/home/ubuntu/t8b/t8b-provisioned.sh

PRE=${PRE:-/home/ubuntu/bin-3271pre/moq}
POST=${POST:-/home/ubuntu/bin-3271post/moq}

for b in "$PRE" "$POST"; do
	[ -x "$b" ] || {
		echo "missing arm binary: $b" >&2
		exit 1
	}
done

echo "=== arms ==="
echo "pre:  $PRE  $("$PRE" --version 2>&1 | head -1)"
echo "post: $POST  $("$POST" --version 2>&1 | head -1)"

# The loop publisher's ffmpeg/tsp is CPU noise on a 2-core box, and C3's own
# cells were measured with it stopped. Restored on exit however we leave.
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

cell() {
	local arm=$1 bin=$2 transport=$3 nflows=$4 lat=$5
	local label="c3ab-$arm-$transport-n$nflows-$lat"
	echo "=== $(date -u +%FT%TZ) $label ==="
	sudo env QDISC=cake CAP_MBIT=15 SECS=90 QUEUE_MS=500 DELAY_MS=50 \
		TRANSPORT="$transport" NFLOWS="$nflows" LATMAX="$lat" DIR="$DIR" \
		MOQ="$bin" bash "$CELL" "$label" 2>&1 | tail -2
	# Keep the captures. The cell's own RESULT line reports bytes, and bytes
	# cannot distinguish "holding the live edge with holes in it" from "clean
	# but falling behind" — which is precisely the axis #3271 moves. Grade
	# them with t8b-c3-span.py afterwards. A cell is ~70 MB across both
	# flows, so ten cells cost well under a gigabyte; deleting them to
	# protect the disk is how four of the first C3 pass's six aggregates
	# were lost.
	sudo chown -R "$(id -u):$(id -g)" "$DIR/$label" 2>/dev/null
	du -sh "$DIR/$label" | sed 's/^/  kept: /'
	sleep 5
}

# n=2 is where C3's collapse lives, and the budget is the knob it tracked.
# 30s is the anchor: pre-#3271 it already showed no collapse, so it is the
# cell that must NOT move if the change is specific to late-group shedding.
for lat in 500ms 2s 30s; do
	cell pre "$PRE" cubic 2 "$lat"
	cell post "$POST" cubic 2 "$lat"
done

# The single-flow reference both n=2 figures are judged against. C3 borrowed
# it from C5's cell; measuring it per arm removes that borrow.
cell pre "$PRE" cubic 1 2s
cell post "$POST" cubic 1 2s

# A second controller at the tight budget: C3's claim is that the collapse is
# common to both QUIC controllers, so a fix should move both or neither.
cell pre "$PRE" bbr1 2 500ms
cell post "$POST" bbr1 2 500ms

echo "=== $(date -u +%FT%TZ) done ==="
