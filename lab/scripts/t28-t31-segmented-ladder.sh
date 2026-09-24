#!/usr/bin/env bash
#
# T28's impairment shapes and T31's step-capacity rungs on the SEGMENTED lane.
#
# The MoQ halves of both experiments ran in the T8b namespace rig -- veth, `cake`, 100 ms base RTT
# ([`t28-t31-moq-ladder.sh`](t28-t31-moq-ladder.sh)). This does **not** reproduce that environment
# and does not try to: the segmented lane needs an HTTP origin with both a TCP and a QUIC listener,
# and the one this campaign has is the T20 nginx pair on the host rather than anything that exists
# inside those namespaces. So the comparison this rig supports is *within itself* -- it runs the
# segmented arms and a MoQ arm through one loopback lane, on one clip, in one session -- and its
# figures are not interchangeable with the netns ladder's. State the rig with any figure from it.
#
# What that costs is the 100 ms RTT and `cake`; what it buys is that all three lanes see the same
# shaper on the same host at the same moment, which is the property the architecture comparison
# actually needs and the one the netns ladder cannot offer, having no segmented arm at all.
#
# Grading is `t28-media-lost.py` on the PCR timeline, the same grader and the same `wire` domain as
# the MoQ ladder, re-graded from the CSV each arm already writes. Delivered ratio is reported
# beside it because a continuity or PCR column alone cannot express magnitude (method-notes:
# "A continuity count detects loss and cannot measure it").
#
# Usage: t28-t31-segmented-ladder.sh [cell ...]
# Env:   ARMS   arms per cell   (default "h3 moq"; add h1 where the substrate is in question)
#        ROOT   run directory   (default ~/t2831seg)
#        STREAM_MBIT  fixture rate, the base every T31 rung is a multiple of (default 9.95)

set -u

ROOT="${ROOT:-$HOME/t2831seg}"
ARMS="${ARMS:-h3 moq}"
STREAM_MBIT="${STREAM_MBIT:-9.95}"
PROV_MBIT="${PROV_MBIT:-20}"
GRADER="${GRADER:-$HOME/t28-media-lost.py}"
ARM_RIG="${ARM_RIG:-$HOME/t20-h3-arm.sh}"
export RECV="${RECV:-verbatim}"

for f in "$GRADER" "$ARM_RIG"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

mkdir -p "$ROOT"
SUMMARY="$ROOT/summary.csv"
[ -s "$SUMMARY" ] || echo "cell,experiment,arm,impairment,window_s,bytes,delivered_ratio,media_lost_s,media_dup_s,holes,largest_hole_s,continuity_events,carriage_valid" >"$SUMMARY"

# T31's rungs are multiples of the stream's own rate, because a shortfall is only a shortfall
# relative to the stream -- the same correction that re-based the MoQ ladder.
rate_for() { awk -v s="$STREAM_MBIT" -v m="$1" 'BEGIN{printf "%.2fmbit", s*m}'; }

# cell | experiment | window | env assignments, ';'-separated
cells() {
	cat <<-EOF
		control|both|60|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit
		step-1.2x-60s|T31|90|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit;DIP_RATE=$(rate_for 1.2);DIP_S=60;DIP_AT=20
		step-0.9x-60s|T31|90|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit;DIP_RATE=$(rate_for 0.9);DIP_S=60;DIP_AT=20
		step-0.8x-5s|T31|60|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit;DIP_RATE=$(rate_for 0.8);DIP_S=5;DIP_AT=20
		step-0.8x-perm|T31|90|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit;DIP_RATE=$(rate_for 0.8);DIP_S=perm;DIP_AT=20
		step-0.5x-60s|T31|90|IMPAIR=rate ${PROV_MBIT}mbit;RATE_BASE=${PROV_MBIT}mbit;DIP_RATE=$(rate_for 0.5);DIP_S=60;DIP_AT=20
		outage-5s|T28|75|OUTAGE_S=5;OUTAGE_AT=15
		outage-30s|T28|75|OUTAGE_S=30;OUTAGE_AT=15
		sustained-loss-5|T28|60|IMPAIR=loss 5%
		sustained-loss-10|T28|60|IMPAIR=loss 10%
		reorder-25|T28|60|IMPAIR=delay 30ms reorder 25% 50%
	EOF
}

want=("$@")
selected() {
	[ ${#want[@]} -eq 0 ] && return 0
	local c
	for c in "${want[@]}"; do [ "$c" = "$1" ] && return 0; done
	return 1
}

# Pull one key out of an arm's result block. The block is this rig's own flat key=value output,
# so a grep is honest here; it is not parsing somebody else's format.
rkey() { sed -n "s/^.*\b$2=\([^ ]*\).*$/\1/p" "$1" | head -1; }

grade_cell() {
	local cell="$1" exp="$2" arm="$3" impair="$4" window="$5"
	local dir="$ROOT/$cell" res="$ROOT/$cell/$arm.result" csv="$ROOT/$cell/${arm}_pcr.csv"
	local bytes ratio cc valid lost dup holes largest

	if [ ! -s "$res" ]; then
		echo "$cell,$exp,$arm,\"$impair\",$window,0,0,VOID,VOID,VOID,VOID,VOID,\"no result\"" >>"$SUMMARY"
		return
	fi
	bytes=$(rkey "$res" bytes)
	ratio=$(rkey "$res" delivered_ratio)
	cc=$(rkey "$res" cc_errors)
	valid=$(sed -n 's/^carriage_valid=//p' "$res" | head -1)

	lost=VOID dup=VOID holes=VOID largest=VOID
	if [ -s "$csv" ]; then
		# --csv re-grades the PCR timeline without re-running tsp, and the grader takes its
		# nominal rate from the median interval so the holes cannot move their own reference.
		if python3 "$GRADER" --csv "$csv" --json "$dir/$arm.grade.json" >/dev/null 2>&1; then
			read -r lost dup holes largest < <(python3 -c "
import json,sys
g=json.load(open(sys.argv[1]))
print(g['media_lost_s'], g['media_duplicated_s'], g['hole_count'], g['largest_hole_s'])
" "$dir/$arm.grade.json")
		fi
	fi
	echo "$cell,$exp,$arm,\"$impair\",$window,$bytes,$ratio,$lost,$dup,$holes,$largest,$cc,\"$valid\"" >>"$SUMMARY"
}

run_cell() {
	local cell="$1" exp="$2" window="$3" envs="$4" arm
	for arm in $ARMS; do
		echo
		echo "########## $cell ($exp) / $arm ##########"
		(
			local IFS=';'
			for kv in $envs; do export "${kv?}"; done
			OUTDIR="$ROOT/$cell" timeout 400 bash "$ARM_RIG" "$cell" "$arm" "$window"
		) 2>&1 | tail -8
		grade_cell "$cell" "$exp" "$arm" "$(printf '%s' "$envs" | tr ';' ' ')" "$window"
		sleep 3
	done
}

while IFS='|' read -r cell exp window envs; do
	[ -z "$cell" ] && continue
	selected "$cell" || continue
	run_cell "$cell" "$exp" "$window" "$envs"
done < <(cells)

echo
echo "== summary =="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
