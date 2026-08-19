#!/usr/bin/env bash
# T16 — grooming a segmented-HTTP egress, on the same chain T14 arm B1 measured.
#
#   t16-groom-segmented.sh <src.ts> <out-dir> <capture-seconds> [segment-seconds]
#
# T14 measured what `tsp -I hls` hands a groomer and stopped there: the measurement
# point was the *ungroomed* egress, deliberately, because measurement 2 was about
# burst granularity. That left the paper admitting that the equivalent
# grooming pass on a segmented-HTTP egress is unmeasured. This closes it, on the
# same publisher, origin, receiver and instrument, so the before and after are the
# same chain with one stage inserted:
#
#   tsp -O hls -> HTTP origin -> tsp -I hls -> [mpegts-pacer] -> instrument
#
# Five arms, captured in sequence off one publisher. C, D and E are three points in
# the parameter space T14 proposed adjusting, so that "a configuration finding" is
# tested rather than argued about:
#
#   A  ungroomed          the T14 arm B1 measurement point, reproduced as the control
#   B  groomed, adaptive  the pacer sizing its own buffer from the arrival pattern
#   C  MoQ depths         the depths T13 ran on the MoQ lane, unchanged
#   D  stall only         T14's literal proposal: the same depths, timeout raised
#   E  every flag         both depths raised to what arm B derived, so the only
#                         remaining difference from B is when output starts
#
# Arm A is timestamped on a pipe (as T14 did) and the groomed arms on a loopback UDP
# socket (as T13 did for the MoQ lane), because that is where each stage's output
# actually goes and because it keeps each column comparable with the campaign that
# produced it.
#
# Background processes do not survive between tool invocations in this environment,
# so publisher, origin and captures are all started and torn down here.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?capture seconds}
SEGSECS=${4:-2}
PORT=${PORT:-18081}
UDP_B=${UDP_B:-19081}
UDP_C=${UDP_C:-19082}
UDP_D=${UDP_D:-19083}
UDP_E=${UDP_E:-19084}
PACER=${PACER_REPO:-$HOME/mpegts-pacer}
# Headroom over the content rate, matching mpegts-pacer's own auto default. The
# rate is pinned rather than left to `auto` so all three arms are graded against
# the same byte clock.
HEADROOM=${HEADROOM:-1.15}
# The pacer holds output back until it has a cushion, which on a segmented feed is
# a couple of segment periods. Give the receiver that much extra so the capture
# window is full-length rather than truncated by the startup wait.
STARTUP=${STARTUP:-25}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for tool in tsp python3 cargo; do
	command -v "$tool" >/dev/null || {
		echo "$tool not found" >&2
		exit 1
	}
done
[ -d "$PACER" ] || {
	echo "mpegts-pacer not found at $PACER; set PACER_REPO" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT/hls" "$OUT/graded"

# --- the groomer ---------------------------------------------------------------
# The egress adapter graduated from an example to the crate's binary after this test
# ran, so it now builds as --bin and lands in release/ rather than release/examples/.
# Build whichever this checkout has, and take the first that exists: the numbers below
# were produced by `examples/ts_egress`, which is the same code under its old name.
echo "building mpegts-pacer..."
(cd "$PACER" && { cargo build --release --bin mpegts-pacer ||
	cargo build --release --example ts_egress; }) >"$OUT/build.log" 2>&1 || {
	cat "$OUT/build.log" >&2
	exit 1
}
TARGET=$(cd "$PACER" && cargo metadata --format-version 1 --no-deps |
	sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')
EGRESS=""
for candidate in "$TARGET/release/mpegts-pacer" "$TARGET/release/examples/ts_egress"; do
	if [ -x "$candidate" ]; then
		EGRESS="$candidate"
		break
	fi
done
[ -n "$EGRESS" ] || {
	echo "no pacer binary under $TARGET/release" >&2
	exit 1
}

# The content rate carried by the source, from its own PCR timeline: a segmented
# egress has no declared mux rate either, for the same reason a MoQ egress does not.
CONTENT=$(python3 "$SCRIPTS/t13-grade.py" rate "$SRC")
RATE=$(python3 -c "print(int($CONTENT * $HEADROOM))")
echo "source content rate ${CONTENT} b/s, target mux rate ${RATE} b/s"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- publisher and origin: identical to t14-b1.sh -------------------------------
tsp --realtime \
	-I file "$SRC" --infinite \
	-P regulate --pcr-synchronous \
	-O hls "$OUT/hls/seg.ts" \
	--playlist "$OUT/hls/index.m3u8" \
	--duration "$SEGSECS" \
	--live 6 --live-extra-segments 3 \
	--intra-close --align-first-segment \
	>"$OUT/publish.log" 2>&1 &
PIDS+=($!)

(cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
PIDS+=($!)

echo "waiting for the publisher to fill the live window..."
for _ in $(seq 1 120); do
	if [ -f "$OUT/hls/index.m3u8" ] &&
		[ "$(grep -c '^seg.*\.ts$' "$OUT/hls/index.m3u8" || true)" -ge 3 ]; then
		break
	fi
	sleep 1
done
[ -f "$OUT/hls/index.m3u8" ] || {
	echo "no playlist produced; see $OUT/publish.log" >&2
	exit 1
}
cp "$OUT/hls/index.m3u8" "$OUT/playlist-sample.m3u8"

URL="http://127.0.0.1:$PORT/index.m3u8"

# --- arm A: ungroomed, the T14 measurement point --------------------------------
echo
echo "=== arm A: ungroomed egress, ${SECS}s ==="
set +e
tsp --realtime \
	-I hls "$URL" --live \
	-P until --seconds "$SECS" \
	-O file - 2>"$OUT/receive-a.log" |
	python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/graded/0-ungroomed" "$SECS"
set -e

# --- arms B onward: groomed ------------------------------------------------------
# `-P until` bounds the receiver so the pacer sees a clean end of stream, flushes
# what it holds and prints its closing stats, rather than being killed mid-run.
groom() {
	local name=$1 udp=$2
	shift 2
	echo
	echo "=== arm $name: groomed egress, ${SECS}s ($*) ==="
	python3 "$SCRIPTS/t13-cadence.py" capture "$udp" "$OUT/graded/$name" "$SECS" \
		>"$OUT/capture-$name.log" 2>&1 &
	local capture=$!
	sleep 1
	set +e
	tsp --realtime \
		-I hls "$URL" --live \
		-P until --seconds "$((SECS + STARTUP))" \
		-O file - 2>"$OUT/receive-$name.log" |
		"$EGRESS" "127.0.0.1:$udp" "$RATE" "$@" 2>&1 | tee "$OUT/pacer-$name.log"
	set -e
	wait "$capture" 2>/dev/null || true
	cat "$OUT/capture-$name.log"
}

# Adaptive: no depth flags at all, which is the claim under test.
groom 1-groomed-adaptive "$UDP_B"

# Pinned to what a MoQ egress needs, which is what T14 called a configuration
# finding. If it holds up, the finding was right and this arm looks like arm B.
groom 2-groomed-moq-depths "$UDP_C" \
	--latency-ms 200 --max-latency-ms 2000 --stall-ms 1000

# T14's literal proposal: the mechanism is right and "the timeouts documented for
# leg A are an order of magnitude too tight". So raise only the timeout, and leave
# the depths alone.
groom 3-groomed-stall-only "$UDP_D" \
	--latency-ms 200 --max-latency-ms 2000 --stall-ms 9000

# Every depth a flag can reach, set to what arm B derived: a cushion the buffer can
# physically hold and a timeout past the worst gap. What no flag reaches is *when*
# output starts, which under an explicit latency is 200 ms after the first packet.
# This arm is the difference between the two.
groom 4-groomed-flags-only "$UDP_E" \
	--latency-ms 8000 --max-latency-ms 16000 --stall-ms 9000

# --- reports ---------------------------------------------------------------------
echo
echo "=== playlist as published ==="
cat "$OUT/playlist-sample.m3u8"

echo
echo "=== wire cadence: ungroomed against groomed ==="
python3 "$SCRIPTS/t13-cadence.py" report "$OUT"/graded/*.csv

echo
echo "=== IRD grading (structural columns relative to the ungroomed egress) ==="
python3 "$SCRIPTS/t13-grade.py" grade "$OUT/graded" "$OUT/graded/0-ungroomed.ts"

echo
echo "=== what each groomer reported about its own input ==="
for log in "$OUT"/pacer-*.log; do
	echo "--- $(basename "$log")"
	grep -E 'mpegts-pacer: (done|arrival|SOURCE)' "$log" || true
done

echo
echo "artefacts in $OUT: graded/*.ts graded/*.csv pacer-*.log publish.log receive-*.log"
