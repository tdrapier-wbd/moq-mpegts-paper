#!/usr/bin/env bash
# cluster-failover-table.sh — one pipe-separated row per cluster-failover.sh run under <outdir>:
# the verdict's timings for all three subscribers, then which media tracks completed to sub1 and
# which pubB was asked for after the event, which is what separates the clean-end outcomes.
#
# Usage: cluster-failover-table.sh <outdir>      (cluster-failover-arms.sh's outdir)
set -uo pipefail
OUT=${1:?outdir}
f() { sed -nE "s/.*$2=([^ ]*).*/\1/p" <<<"$1"; }
printf '%s\n' "run|event t|relayA closed pubA (t, err)|relayA re-subscribed video|sub1 resumed / stall / alive|sub2 resumed / stall / alive|sub3 resumed / stall / alive|sub1 error|sub3 error|pubA media subs pre/join/post|pubB media subs pre/join/post|pubA last video group|pubB first video group after|tracks completed to sub1|tracks pubB served after event|verdict"
for d in "$OUT"/*/; do
	r=$(basename "$d")
	v="$d/verdict.txt"
	[ -f "$v" ] || continue
	head=$(sed -n 2p "$v")
	ev=$(f "$head" event)
	cl=$(sed -nE 's/.*relayA_closed_pubA=([^ ]+) \(([^)]*)\).*/\1 (\2)/p' <<<"$head" | sed 's/transport: connection error: //')
	row="$r|$ev|$cl|$(f "$head" relayA_resubscribed_video)"
	for s in sub1 sub2 sub3; do
		l=$(grep "^$s:" "$v")
		row+="|$(f "$l" resumed) / $(f "$l" stall_after_event) / $(f "$l" alive_until)"
	done
	for s in sub1 sub3; do
		e=$(grep "^$s:" "$v" | sed -nE 's/.*error=(.*)$/\1/p')
		row+="|${e:--}"
	done
	pa=$(grep '^pubA:' "$v")
	pb=$(grep '^pubB:' "$v")
	row+="|$(f "$pa" after-event)|$(f "$pb" after-event)|$(f "$pa" last-before)|$(f "$pb" first-after)"
	comp=$(grep 'subscribe complete' "$d/sub1.log" | grep -v 'track=catalog' | sed -nE 's/.*track=([^ ]+).*/\1/p' | sort | paste -sd, -)
	t0=$(f "$head" t0)
	cut=$(date -u -d "@$(awk -v a="$(date -u -d "$t0" +%s.%N)" -v b="$ev" 'BEGIN { printf "%.6f", a + b }')" +%Y-%m-%dT%H:%M:%S.%6NZ)
	after=$(awk -v c="$cut" '$1 >= c && /subscribed started/ && !/catalog/' "$d/pubB.log" | sed -nE 's/.*track=([^ ]+).*/\1/p' | sort -u | paste -sd, -)
	verdict=$(grep -E '^CHECK' "$v" | sed -E 's/ —.*//; s/ \([^)]*\)//' | paste -sd';' -)
	printf '%s\n' "$row|${comp:-none}|${after:-none}|$verdict"
done
