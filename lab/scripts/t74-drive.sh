#!/usr/bin/env bash
# T74's and T75's matrices on T71's rig, one cell at a time; resumable: a cell whose record is
# complete is skipped, a failed one reported and passed.
#
#   ORIGIN_IP=<addr> ORIGIN=<ssh alias> FAR=<ssh alias> t74-drive.sh <t74|t75|p1ap|hedge> [seconds] [rounds...]
#
# T74: per round, {clean, time bursts} × the four lanes at the 2 s budget, the lanes rotated per round.
# P1-ap (DEADLINE_MS, CAPTURE=<origin NIC>): per round, the segmented lane under time bursts without
# and then with the fetch deadline, a header capture at the origin on each; round 1 adds a clean cell
# with the deadline. Hedge (HEDGE_MS, CAPTURE): the same with the re-request on a second open
# connection in place of the deadline.
# T75: per round at 2 s, RIST under {clean, 1 %, T73's Gilbert bursts, T74's time bursts} and SRT
# under {1 %, Gilbert}, then RIST and SRT at 1 % at the 1 s budget; T74's SRT cells complete the 2 s
# pairs. Round r's time bursts use seed 7400 + r in both matrices, so RIST meets SRT's timeline.
set -uo pipefail

WHICH=${1:?t74 or t75}
SECS=${2:-120}
shift 2 || shift $#
ROUNDS=("$@")
[ ${#ROUNDS[@]} -gt 0 ] || ROUNDS=(1 2 3)
export LOG=${LOG:-$HOME/t74runs}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TO=${TO:-$(command -v gtimeout || command -v timeout)}

relay_alive() {
	# shellcheck disable=SC2016
	"$TO" 30 ssh -o BatchMode=yes "$ORIGIN" 'kill -0 "$(cat t71/fix/relay.pgid)" 2>/dev/null' </dev/null
}

loss_of() {
	case "$1" in
	clean) echo 0 ;;
	ge) echo ge:0.05,5 ;;
	tb) echo "tb:20,1,$((7400 + $2))" ;;
	l*) echo "${1#l}" ;;
	esac
}

cell() {
	local name=$1 lane=$2 cond=$3 r=$4 bufms=$5 delay=$6 dl=${7:-} hg=${8:-}
	if [ -s "$LOG/$name/cell.txt" ]; then
		echo "skip $name"
		return
	fi
	if [ "$lane" = opaque ] || [ "$lane" = aware ]; then
		relay_alive || {
			echo "FAILED $name: the origin's relay is not running"
			return
		}
	fi
	BUFMS=$bufms DELAY=$delay DEADLINE_MS=$dl HEDGE_MS=$hg CAPTURE=${CAPTURE:-} \
		bash "$HERE/t71-cell.sh" "$name" "$lane" "$(loss_of "$cond" "$r")" "$SECS" ||
		echo "FAILED $name"
}

for r in "${ROUNDS[@]}"; do
	case "$WHICH" in
	t74)
		lanes=(srt opaque aware seg)
		for cond in clean tb; do
			for k in 0 1 2 3; do
				lane=${lanes[$(((k + r - 1) % 4))]}
				cell "t74-r$r-$lane-$cond" "$lane" "$cond" "$r" 2000 2s
			done
		done
		;;
	t75)
		for cond in clean l1 ge tb; do
			cell "t75-r$r-rist-$cond-b2" rist "$cond" "$r" 2000 2s
			case "$cond" in l1 | ge) cell "t75-r$r-srt-$cond-b2" srt "$cond" "$r" 2000 2s ;; esac
		done
		pair=(rist srt)
		[ $((r % 2)) -eq 0 ] && pair=(srt rist)
		for lane in "${pair[@]}"; do
			cell "t75-r$r-$lane-l1-b1" "$lane" l1 "$r" 1000 1s
		done
		;;
	p1ap)
		: "${DEADLINE_MS:?set DEADLINE_MS}" "${CAPTURE:?set CAPTURE to the origin NIC}"
		cell "p1ap-r$r-seg-tb" seg tb "$r" 2000 2s
		cell "p1ap-r$r-seg-tb-dl" seg tb "$r" 2000 2s "$DEADLINE_MS"
		[ "$r" != 1 ] || cell "p1ap-r$r-seg-clean-dl" seg clean "$r" 2000 2s "$DEADLINE_MS"
		;;
	hedge)
		: "${HEDGE_MS:?set HEDGE_MS}" "${CAPTURE:?set CAPTURE to the origin NIC}"
		hedge=$HEDGE_MS
		cell "hedge-r$r-seg-tb" seg tb "$r" 2000 2s
		cell "hedge-r$r-seg-tb-hg" seg tb "$r" 2000 2s "" "$hedge"
		[ "$r" != 1 ] || cell "hedge-r$r-seg-clean-hg" seg clean "$r" 2000 2s "" "$hedge"
		;;
	*)
		echo "unknown matrix: $WHICH" >&2
		exit 2
		;;
	esac
done
echo "matrix $WHICH done $(date -u +%H:%M:%S)"
