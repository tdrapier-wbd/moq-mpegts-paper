#!/usr/bin/env bash
#
# Summarise the segmented T28/T31 ladder on the one delivery metric this build does not distort.
#
# The ladder's own summary.csv carries `delivered_ratio` and `media_lost_s`, and on `ffa5b81b`
# neither reads the MoQ arm correctly: `export ts` pads to the catalog's recorded mux rate, so the
# byte ratio counts stuffing and the PCR timeline advances through gaps the padding filled
# (method-notes: "A sender that can pad turns every byte-denominated and clock-denominated delivery
# metric into a measure of its padding"). Both columns are kept here, because they are correct on
# the segmented arms and their disagreement with the third column is the evidence for the rule.
#
# `delivered` is packets on the video PID against that PID's rate in the source over the window.
#
# Usage: t2831-seg-summary.sh <run-root> [video-pid] [source-video-bps]

set -u

ROOT="${1:?usage: t2831-seg-summary.sh <run-root> [video-pid] [source-video-bps]}"
VPID="${2:-111}"
VBPS="${3:-9021203}"

printf '%-18s %-4s %8s %9s %9s %10s %8s  %s\n' \
	CELL ARM WINDOW DELIVERED 'BYTE_RATIO' 'MEDIA_LOST' NULL_PCT CARRIAGE

for res in "$ROOT"/*/*.result; do
	[ -e "$res" ] || continue
	dir=$(dirname "$res")
	arm=$(basename "$res" .result)
	cell=$(basename "$dir")
	cap="$dir/$arm.ts"

	window=$(sed -n 's/.*window=\([0-9]*\).*/\1/p' "$res" | head -1)
	ratio=$(sed -n 's/.*delivered_ratio=\([0-9.]*\).*/\1/p' "$res" | head -1)
	valid=$(sed -n 's/^carriage_valid=//p' "$res" | head -1)

	delivered='-' nullpct='-'
	if [ -s "$cap" ]; then
		read -r vpkts tot nulls < <(tsp -I file "$cap" -P analyze --normalized -O drop 2>/dev/null |
			awk -F: -v p="pid=$VPID" '
				$0 ~ "^pid:"p":" {for(i=1;i<=NF;i++) if($i~/^packets=/){sub("packets=","",$i); v=$i}}
				/^pid:pid=8191:/ {for(i=1;i<=NF;i++) if($i~/^packets=/){sub("packets=","",$i); n=$i}}
				/^ts:/ {for(i=1;i<=NF;i++) if($i~/^packets=/){sub("packets=","",$i); t=$i}}
				END{print v+0, t+0, n+0}')
		delivered=$(awk -v v="$vpkts" -v b="$VBPS" -v w="$window" \
			'BEGIN{e=b*w/8/188; printf "%.3f", e? v/e : 0}')
		nullpct=$(awk -v n="$nulls" -v t="$tot" 'BEGIN{printf "%.1f", t? n/t*100 : 0}')
	fi

	lost='-'
	if [ -s "$dir/$arm.grade.json" ]; then
		lost=$(python3 -c 'import json,sys;print("%.3f"%json.load(open(sys.argv[1]))["media_lost_s"])' \
			"$dir/$arm.grade.json" 2>/dev/null || echo '-')
	fi

	printf '%-18s %-4s %8s %9s %9s %10s %8s  %s\n' \
		"$cell" "$arm" "${window:-?}" "$delivered" "${ratio:-?}" "$lost" "$nullpct" "$valid"
done
