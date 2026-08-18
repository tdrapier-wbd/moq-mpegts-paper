#!/usr/bin/env bash
# What each transport does to the clock it carries.
#
# The source is re-stamped by `tsp -P timeref --start system`, so every TDT it
# transmits asserts the true UTC of its own transmission. Whatever the receiver
# then reads is the transport's contribution, and the statistic that separates the
# designs is the *spread*, not the median: a pipe that forwards sections at a
# constant delay is late by that delay with almost no spread, while anything that
# caches a section and re-emits it on its own schedule spreads out to the gap
# between source sections.
#
# Legs mirror T15's, so the roles and orderings are the ones already known to work
# here (publisher first in all three; RIST wants the publisher listening on
# `rist://@` and the receiver calling).
#
# Reading the numbers, because two of the three columns are instrument and not
# transport:
#
#   - Inter-section arrival gaps are the transport result. Identical gaps mean the
#     transport reproduced the source's section cadence and added no variance.
#   - Growing staleness within a leg is `timeref --start`, which advances its
#     reference over packets/bitrate. When the replay rate and the assumed bitrate
#     disagree the asserted clock slides against wall time at that error, the same
#     on every leg. It is a fair illustration of what media-derived time does, but
#     it is not the transport's doing.
#   - The absolute offset is *not* the configured buffer. A publisher whose output
#     blocks until its peer connects has already anchored `timeref`, so the stall
#     shows up as a constant lateness for the rest of the run. Compare legs by
#     spread and by gaps, not by median.
#
# Usage: tdt-transports.sh <src.ts> <out-dir> [seconds] [leg...]

set -uo pipefail

SRC=${1:?usage: tdt-transports.sh <src.ts> <out-dir> [seconds] [leg...]}
OUT=${2:?output dir}
SECS=${3:-75}
shift 3 || true
LEGS=("$@")
[[ ${#LEGS[@]} -gt 0 ]] || LEGS=(udp srt rist-main)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUFMS=1000 # matched across SRT and RIST so the buffer is not the variable
BASE=19700

[[ -r "$SRC" ]] || {
	echo "not readable: $SRC" >&2
	exit 1
}
mkdir -p "$OUT"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
}
trap cleanup EXIT

# The source, paced to real time and carrying a true clock. `regulate` first so
# stream time tracks wall time; `timeref` then advances the reference over the
# stream, which is the same value either way but reads in the order it happens.
publish_to() {
	tsp --realtime -I file "$SRC" --infinite \
		-P regulate --pcr-synchronous \
		-P timeref --start system \
		"$@" >"$OUT/$LEG.pub.log" 2>&1 &
	PIDS+=($!)
}

for LEG in "${LEGS[@]}"; do
	case "$LEG" in
	udp) PORT=$((BASE + 0)) ;;
	srt) PORT=$((BASE + 10)) ;;
	rist-main) PORT=$((BASE + 20)) ;;
	*)
		echo "unknown leg: $LEG" >&2
		exit 1
		;;
	esac

	echo "=== $LEG (port $PORT)"
	case "$LEG" in
	udp)
		publish_to -O ip "127.0.0.1:$PORT"
		RECEIVE=(tsp --realtime -I ip "$PORT" -O file -)
		;;
	srt)
		publish_to -O srt --listener "127.0.0.1:$PORT" --latency "$BUFMS"
		RECEIVE=(tsp --realtime -I srt --caller "127.0.0.1:$PORT" --latency "$BUFMS" -O file -)
		;;
	rist-main)
		publish_to -O rist --profile main "rist://@127.0.0.1:$PORT?buffer=$BUFMS"
		RECEIVE=(tsp --realtime -I rist --profile main "rist://127.0.0.1:$PORT?buffer=$BUFMS" -O file -)
		;;
	esac

	sleep 4
	timeout "$SECS" "${RECEIVE[@]}" 2>"$OUT/$LEG.rx.log" |
		timeout $((SECS + 5)) python3 "$HERE/tdt-staleness.py" | tee "$OUT/$LEG.tdt.txt"
	cleanup
	PIDS=()
	sleep 2
	echo
done

echo "=== summary"
for LEG in "${LEGS[@]}"; do
	printf '%-12s %s\n' "$LEG" "$(tail -1 "$OUT/$LEG.tdt.txt" 2>/dev/null || echo 'no result')"
done
