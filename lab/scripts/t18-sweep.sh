#!/usr/bin/env bash
# T18 — the latency/conformance curve: every arm at every cushion, one cell at a time.
#
#   t18-sweep.sh <src.ts> <out-dir> <seconds-per-cell> [arm ...]
#
# The experiment's answer is a *curve*, not a number, so this is the entry point
# rather than `t18-arm.sh`: what it reports per arm is the shallowest cushion whose
# wire passes, and the latency that cushion costs. Set `CUSHIONS` to override the
# ladder, which follows [T8](../test-8-srt-vs-moq.md)'s B ∈ {250, 500, 1000, 2000} ms.
#
# The segmented arm gets its own, deeper ladder. It cannot be run at the shallow end
# at all — measured silences reach 4.01 s, two segment periods, so a groomer given a
# 250 ms cushion mutes rather than paces — and [T16](../test-16-grooming-segmented-http.md)
# only reached a clean wire at 8 s. Sweeping it over the same ladder as the tunnels
# would therefore report failures that are the ladder's rather than the plane's.
#
# **Cells run strictly one at a time, and that is a measurement decision.** This host
# has been shown to make MoQ legs skip groups when a relay, two exporters and two
# groomers share it at ~10 Mb/s, and a latency rig is exactly as vulnerable: the
# figure would be the laptop's scheduling rather than the transport's. Nothing else
# demanding should run on the box while a sweep is in flight.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?seconds per cell}
shift 3
ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(udp srt rist moq hls)

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CUSHIONS=${CUSHIONS:-"250 500 1000 2000"}
HLS_CUSHIONS=${HLS_CUSHIONS:-"2000 4000 8000"}

mkdir -p "$OUT"
echo "==> sweep: arms ${ARMS[*]}, ${SECS}s per cell, into $OUT"

for arm in "${ARMS[@]}"; do
	ladder=$CUSHIONS
	[ "$arm" = hls ] && ladder=$HLS_CUSHIONS
	for cushion in $ladder; do
		echo
		echo "######## $arm at ${cushion} ms ########"
		# One failing cell must not abandon the sweep: a cushion too shallow for an
		# arm is a result, and the row it does not write is the finding.
		if ! bash "$SCRIPTS/t18-arm.sh" "$SRC" "$OUT" "$SECS" "$arm" "$cushion"; then
			echo "!! $arm at ${cushion} ms did not complete; see $OUT/$arm-c$cushion-*.log" >&2
		fi
		sleep 3
	done
done

echo
echo "=== summary ==="
[ -s "$OUT/summary.csv" ] && column -s, -t "$OUT/summary.csv"
echo
echo "full table: $OUT/summary.csv"
