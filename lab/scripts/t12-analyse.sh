#!/usr/bin/env bash
# T12 — TSDuck verdict on a merged/selected output.
#
# Both legs carry the same source mux, so the continuity counters make the merge
# check itself: a hitless reconstruction is continuity-clean and free of PCR
# discontinuities, while a break-before-make switch shows both.
#
# Usage: ./t12-analyse.sh <merged.ts>
set -euo pipefail

TS=${1:?usage: $0 <merged.ts>}
BASE=${TS%.ts}

echo "== $TS ($(du -h "$TS" | cut -f1)) =="

echo -n "continuity errors: "
tsp -I file "$TS" -P continuity -O drop 2>&1 | grep -c . || true

echo -n "pcrverify @ +/-500 ns: "
tsp -I file "$TS" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 | tail -1

tsp -I file "$TS" -P pcrextract --pcr --csv -o "${BASE}_pcr.csv" -O drop 2>/dev/null
awk -F, 'NR>1{cur=$7; if(prev!=""){d=(cur-prev)/27000; n++; sum+=d;
	if(d>max)max=d; if(min==""||d<min)min=d; if(d>40)over++; if(d<0)back++} prev=cur}
	END{if(n)printf "pcr intervals=%d min=%.2f mean=%.2f max=%.2f ms  >40ms=%d (%.4f%%)  backwards=%d\n",
	n, min, sum/n, max, over+0, (over/n)*100, back+0}' "${BASE}_pcr.csv"

tsp -I file "$TS" -P analyze --normalized -O drop 2>/dev/null \
	| grep '^ts:' | tr ':' '\n' | grep -E '^(bitrate|pcrbitrate|packets)=' | paste -sd' '
