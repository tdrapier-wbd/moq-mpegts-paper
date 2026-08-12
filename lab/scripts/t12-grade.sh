#!/usr/bin/env bash
# T12 — grade one captured run: receiver-side reconstruction plus a TSDuck verdict.
#
# Reads only the capture, so a whole campaign can be re-graded from the pcaps when
# the oracle changes. Appends one row per run to summary.csv and one row per
# failover threshold to select.csv.
#
# Usage: ./t12-grade.sh <run-dir> [summary.csv] [select.csv]
set -euo pipefail

RUN=${1:?usage: $0 <run-dir> [summary.csv] [select.csv]}
RUN=${RUN%/}
SUMMARY=${2:-$(dirname "$RUN")/summary.csv}
SELECT=${3:-$(dirname "$RUN")/select.csv}
K_MS=${K_MS:-50,100,250,500}
HERE=$(cd "$(dirname "$0")" && pwd)

LABEL=$(basename "$RUN")
CAP="$RUN/$LABEL.pcap"
[ -f "$CAP" ] || { echo "no capture in $RUN" >&2; exit 1; }
ARM=$(python3 -c "import json;print(json.load(open('$RUN/meta.json'))['arm'])")
INJECT=$(python3 -c "import json;print(json.load(open('$RUN/meta.json'))['inject'])")

[ -f "$SUMMARY" ] || echo "arm,inject,delay_b,leg_a_dgrams,leg_b_dgrams,seq_offset,mergeable,align_yield_pct,merge_dgrams,merge_covered_by_b,merge_lost_dgrams,merge_lost_ts_packets,merge_longest_gap_ms,merge_content_pct,merge_conflicts,merge_cc_errors,merge_pcrs,merge_pcr_over40_pct,merge_pcr_gt100ms,merge_pcr_backward,merge_pcr_accuracy_fail,skew_abs_max_ms,leg_a_silence_max_ms,leg_a_carrier_after_content_s" >"$SUMMARY"
[ -f "$SELECT" ] || echo "arm,inject,delay_b,k_ms,switches,max_switch_gap_ms,cc_errors,pcr_gt100ms,pcr_backward" >"$SELECT"

(cd "$RUN" && python3 "$HERE/t12-merge-oracle.py" --pcap "$LABEL.pcap" \
	--k-ms "$K_MS" --json "$LABEL.json" --meta meta.json) | head -24 | sed 's/^/    /'

MERGED="$RUN/$LABEL.seqmerge.ts"
CC_MERGE=$(tsp -I file "$MERGED" -P continuity -O drop 2>&1 | grep -c . || true)
tsp -I file "$MERGED" -P pcrextract --pcr --csv -o "$RUN/pcr.csv" -O drop 2>/dev/null || true
OVER40=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;n++;if(d>40)o++}p=c}
	END{if(n)printf "%.4f", (o/n)*100; else printf "0"}' "$RUN/pcr.csv")
# A pair whose legs each regenerate their own PCR would be continuity-clean across a
# switch but not clock-clean, so count clock damage separately from lost packets: long
# intervals, and backward steps (a genuine discontinuity) apart from each other.
GT100=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000; if(d>100)j++}p=c}
	END{printf "%d", j+0}' "$RUN/pcr.csv")
BACK=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000; if(d<0)j++}p=c}
	END{printf "%d", j+0}' "$RUN/pcr.csv")
PCRS=$(( $(wc -l <"$RUN/pcr.csv") - 1 ))
PCRV=$(tsp -I file "$MERGED" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 \
	| tr -d ',' | grep -oE '[0-9]+ with jitter' | awk '{print $1}' | head -1)

python3 - "$RUN/$LABEL.json" "$CC_MERGE" "$OVER40" "$ARM" "$INJECT" "${GT100:-0}" "${PCRV:-0}" \
	"${PCRS:-0}" "${BACK:-0}" >>"$SUMMARY" <<'PY'
import json, sys
path, cc_merge, over40, arm, inject, gt100, pcrverify_bad, pcrs, backward = sys.argv[1:10]
d = json.load(open(path))
merge = d.get("seq_merge") or {}
skew = d.get("skew") or {}
align = d.get("alignment") or {}
silence = d["leg_a"].get("silence") or {}
print(",".join(str(x) for x in [
    arm, inject, (d.get("meta") or {}).get("delay_b", 0),
    d["leg_a"]["datagrams"], d["leg_b"]["datagrams"],
    d.get("sequence_offset"), d.get("standard_receiver_mergeable"),
    round(align.get("yield_pct", 0), 4),
    merge.get("datagrams", ""), merge.get("covered_by_b", ""),
    merge.get("lost_datagrams", ""), merge.get("lost_ts_packets", ""),
    merge.get("longest_gap_ms", ""), merge.get("content_pct", ""), merge.get("conflicts", ""),
    cc_merge, pcrs, over40, gt100, backward, pcrverify_bad,
    round(skew.get("abs_max_ms", 0), 3), round(silence.get("max_ms", 0), 1),
    d["leg_a"].get("carrier_after_content_s"),
]))
PY
tail -1 "$SUMMARY" | sed 's/^/    -> /'

for ts in "$RUN/$LABEL.inputselect.k"*.ts; do
	[ -f "$ts" ] || continue
	k=$(basename "$ts" | sed 's/.*inputselect\.k\([0-9]*\)\.ts/\1/')
	cc=$(tsp -I file "$ts" -P continuity -O drop 2>&1 | grep -c . || true)
	tsp -I file "$ts" -P pcrextract --pcr --csv -o "$RUN/pcr_k$k.csv" -O drop 2>/dev/null || true
	jumps=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000; if(d>100)j++}p=c}
		END{printf "%d", j+0}' "$RUN/pcr_k$k.csv")
	back=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000; if(d<0)j++}p=c}
		END{printf "%d", j+0}' "$RUN/pcr_k$k.csv")
	python3 - "$RUN/$LABEL.json" "$k" "$cc" "$ARM" "$INJECT" "$jumps" "$back" >>"$SELECT" <<'PY' || true
import json, sys
path, k, cc, arm, inject, jumps, backward = sys.argv[1:8]
d = json.load(open(path))
for sel in d.get("input_select") or []:
    if int(sel["k_ms"]) == int(k):
        gap = max((e["gap_ms"] for e in sel["switch_events"]), default=0.0)
        print(",".join(str(x) for x in [
            arm, inject, (d.get("meta") or {}).get("delay_b", 0),
            k, sel["switches"], round(gap, 1), cc, jumps, backward,
        ]))
PY
	[ "${KEEP_TS:-0}" = 1 ] || rm -f "$ts"
done
[ "${KEEP_TS:-0}" = 1 ] || rm -f "$MERGED"
