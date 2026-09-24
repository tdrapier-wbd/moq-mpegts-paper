#!/usr/bin/env bash
#
# Summarise a T20 run tree on the metric that survives this build, and say why the obvious one
# does not.
#
# `delivered_ratio` counts output bytes against the source's rate. On `ffa5b81b` that stopped
# measuring delivered content on the MoQ arm: `moq export ts` now pads to the `mpegts.muxRate`
# the catalog recorded, so a capture is up to 55 % null packets and the ratio rises above 1.0
# under impairments that lose programme. The byte-faithful HLS receiver moves the other way,
# keeping the stuffing and the NIT/TDT the old re-muxing receiver discarded (+11.6 %). Neither
# is wrong; they are simply no longer the same scale, and no cross-lane conclusion should rest
# on them.
#
# `media_lost_s` is taken from the PCR timeline by `t28-media-lost.py` -- the same grader and
# the same `wire` domain as the MoQ ladder in T28/T31 -- and is unaffected by padding, because
# stuffing carries no PCR and moves no clock.
#
# Usage: t20-grade-cells.sh <run-root>       (e.g. ~/t20v)

set -u

ROOT="${1:?usage: t20-grade-cells.sh <run-root>}"
GRADER="${GRADER:-$HOME/t28-media-lost.py}"
[ -r "$GRADER" ] || {
	echo "FAIL: missing $GRADER" >&2
	exit 1
}

printf '%-18s %-4s %11s %8s %6s %11s %10s %7s  %s\n' \
	CELL ARM BYTES RATIO CC MEDIA_LOST LARGEST NULL_PCT CARRIAGE

for res in "$ROOT"/*/*.result; do
	[ -e "$res" ] || continue
	dir=$(dirname "$res")
	arm=$(basename "$res" .result)
	cell=$(basename "$dir")

	bytes=$(sed -n 's/^bytes=\([0-9]*\).*/\1/p' "$res" | head -1)
	ratio=$(sed -n 's/.*delivered_ratio=\([0-9.]*\).*/\1/p' "$res" | head -1)
	cc=$(sed -n 's/^cc_errors=\([0-9]*\).*/\1/p' "$res" | head -1)
	valid=$(sed -n 's/^carriage_valid=//p' "$res" | head -1)

	lost='-' largest='-'
	csv="$dir/${arm}_pcr.csv"
	if [ -s "$csv" ] && python3 "$GRADER" --csv "$csv" --json "$dir/$arm.grade.json" >/dev/null 2>&1; then
		lost=$(python3 -c 'import json,sys;print("%.3f"%json.load(open(sys.argv[1]))["media_lost_s"])' "$dir/$arm.grade.json")
		largest=$(python3 -c 'import json,sys;print("%.3f"%json.load(open(sys.argv[1]))["largest_hole_s"])' "$dir/$arm.grade.json")
	fi

	# Stuffing share, because it is what makes the byte ratio unreadable on this build.
	nullpct='-'
	if [ -s "$dir/$arm.ts" ]; then
		nullpct=$(tsp -I file "$dir/$arm.ts" -P analyze --normalized -O drop 2>/dev/null |
			awk -F: '/^pid:pid=8191/{for(i=1;i<=NF;i++)if($i~/^packets=/)sub("packets=","",$i)&&n=$i}
				/^ts:/{for(i=1;i<=NF;i++)if($i~/^packets=/){sub("packets=","",$i);t=$i}}
				END{printf "%.1f", t? n/t*100 : 0}')
	fi

	printf '%-18s %-4s %11s %8s %6s %11s %10s %7s  %s\n' \
		"$cell" "$arm" "${bytes:-?}" "${ratio:-?}" "${cc:-?}" "$lost" "$largest" "$nullpct" "$valid"
done
