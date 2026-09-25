#!/usr/bin/env bash
# Attribution arms for three of T28's unattributed MoQ results, run one after another in the
# `netns`/`cake` rig (the rigs share namespaces, so never beside another).
#
#   reorder  Why 20 % reorder defeats every build. One factor per arm on `ffa5b81b`, relay `delay`:
#            the relay's send window (the transport send buffer), the subscriber's receive windows,
#            the exporter's release budget, and the bottleneck's headroom. If the lane is spending the
#            link on retransmissions of packets it wrongly declared lost, headroom rescues it and the
#            buffers do not; a qlog of the relay counts what it declared lost. The quinn build with
#            headroom says whether the loss-blind stack is rescued the same way.
#   qlog     The same reorder cell with the relay writing qlog, from `$HOME/bin-ffa5b81b-qlog`: a
#            relay built with `--features qlog` beside the release `moq`.
#   cubic    Whether the QUIC stack adds to the outage cost. `5d0991b9` on quinn and on noq, both
#            pinned to CUBIC, which both implement: the 3 s ladder (outage 5 s and 0.9x for 60 s),
#            then the 2 s matched cell under both controllers.
#   idle     Whether `fd4f5d82e` survives an outage at the idle timeout because it reconnects: an
#            outage well past the timeout.
#
# Usage: t2831-attrib.sh [outroot] [phase...]   (phases: reorder qlog cubic idle; default all but qlog)
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
ROOT=${1:-$HOME/t2831-attrib}
shift || true
PHASES=${*:-reorder cubic idle}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT"
COMMON=(CLIP="$HOME/clip120.ts" NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py"
	CONTENT="$HOME/t28-content-lost.py" LATENCY="$HOME/t18-latency.py")

matched() { # <label> <bindir> [VAR=value ...]
	local label=$1 bin=$2
	shift 2
	echo "=== $(date -u +%FT%TZ) matched $label ==="
	sudo env "${COMMON[@]}" BIN="$bin" OUT="$ROOT" LANES=moq BUDGETS=2 "$@" \
		bash "$HERE/t28-t31-srt-ladder.sh" "$label" >"$ROOT/$label.log" 2>&1
	sudo python3 "$HERE/t2831-conservation.py" "$ROOT/$label" --csv "$ROOT/$label/conservation.csv" 2>/dev/null |
		sed "s/^/  $label /"
}
ladder() { # <label> <bindir> <cc> <cells...>
	local label=$1 bin=$2 cc=$3
	shift 3
	echo "=== $(date -u +%FT%TZ) ladder $label ==="
	sudo env "${COMMON[@]}" MOQ="$bin/moq" RELAY="$bin/moq-relay" OUT="$ROOT/$label" MOQ_CC="$cc" \
		bash "$HERE/t28-t31-moq-ladder.sh" "$@" >"$ROOT/$label.log" 2>&1
	sudo python3 "$HERE/t2831-conservation.py" "$ROOT/$label" --csv "$ROOT/$label/conservation.csv" 2>/dev/null |
		sed "s/^/  $label /"
	grep -h "DID NOT START" "$ROOT/$label.log" | sed "s/^/  $label /"
}

FFA=$HOME/bin-ffa5b81b
Q5D=$HOME/bin-5d0991b9
N5D=$HOME/bin-5d0991b9-noq
R2=(IMPAIRS="none reorder20" REPS=2 MOQ_MUX_RATE=0)

for phase in $PHASES; do
	case "$phase" in
	reorder)
		matched r-base "$FFA" "${R2[@]}"
		matched r-sendwin-256k "$FFA" "${R2[@]}" RELAY_EXTRA="--quic-send-window 262144"
		matched r-sendwin-64m "$FFA" "${R2[@]}" RELAY_EXTRA="--quic-send-window 67108864"
		matched r-strwin-64k "$FFA" "${R2[@]}" SUB_EXTRA="--quic-stream-receive-window 65536"
		matched r-rwin-64m "$FFA" "${R2[@]}" \
			SUB_EXTRA="--quic-receive-window 67108864 --quic-stream-receive-window 16777216"
		matched r-budget-8s "$FFA" "${R2[@]}" EXPORT_BUDGET=8
		matched r-cap-100 "$FFA" "${R2[@]}" CAP_MBIT=100
		matched r-cap-100-quinn "$Q5D" IMPAIRS="none reorder20" REPS=2 CAP_MBIT=100
		;;
	qlog)
		# The relay needs the `qlog` feature, which release builds leave out; without it the flag
		# errors at init and every cell reads NA.
		[ -x "$FFA-qlog/moq-relay" ] || { echo "no $FFA-qlog/moq-relay (build with --features qlog)"; continue; }
		sudo mkdir -p "$ROOT/qlog"
		matched r-qlog "$FFA-qlog" IMPAIRS="none reorder20" REPS=1 MOQ_MUX_RATE=0 \
			RELAY_EXTRA="--quic-qlog $ROOT/qlog"
		;;
	cubic)
		for rep in 1 2 3; do
			ladder "c-quinn-loss-r$rep" "$Q5D" loss control outage-5s step-0.9x-60s
			ladder "c-noq-loss-r$rep" "$N5D" loss control outage-5s step-0.9x-60s
		done
		for cc in loss delay; do
			matched "c-quinn-$cc-b2" "$Q5D" IMPAIRS="none outage" REPS=3 MOQ_CC=$cc
			matched "c-noq-$cc-b2" "$N5D" IMPAIRS="none outage" REPS=3 MOQ_CC=$cc
		done
		;;
	idle)
		for rep in 1 2; do
			ladder "i-fd4f5d82e-r$rep" "$HOME/bin-3529" delay control outage-40s
		done
		;;
	esac
done
echo "=== $(date -u +%FT%TZ) attrib done ==="
