#!/usr/bin/env bash
# T73's matrix on T71's rig: three rounds, each the 2 s budget's conditions in order with the four
# lanes in an order rotated per round, then the segmented lane at T71's 1 s budget. One cell at a
# time; resumable: a cell whose record is complete is skipped, a failed one reported and passed.
#
#   ORIGIN_IP=<addr> ORIGIN=<ssh alias> FAR=<ssh alias> t73-drive.sh [seconds] [rounds...]
set -uo pipefail

SECS=${1:-120}
shift || true
ROUNDS=("$@")
[ ${#ROUNDS[@]} -gt 0 ] || ROUNDS=(1 2 3)
LOG=${LOG:-$HOME/t71runs}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TO=${TO:-$(command -v gtimeout || command -v timeout)}
LANES=(srt opaque aware seg)
BURST=ge:0.05,5

relay_alive() {
	# shellcheck disable=SC2016
	"$TO" 30 ssh -o BatchMode=yes "$ORIGIN" 'kill -0 "$(cat t71/fix/relay.pgid)" 2>/dev/null' </dev/null
}

loss_of() {
	case "$1" in
	clean) echo 0 ;;
	burst) echo "$BURST" ;;
	l*) echo "${1#l}" ;;
	esac
}

cell() {
	local name=$1 lane=$2 cond=$3 bufms=$4 delay=$5
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
	BUFMS=$bufms DELAY=$delay bash "$HERE/t71-cell.sh" "$name" "$lane" "$(loss_of "$cond")" "$SECS" ||
		echo "FAILED $name"
}

for r in "${ROUNDS[@]}"; do
	for cond in clean l1 burst; do
		for k in 0 1 2 3; do
			lane=${LANES[$(((k + r - 1) % 4))]}
			cell "r$r-$lane-$cond-b2" "$lane" "$cond" 2000 2s
		done
	done
	for cond in clean l0.1 l1; do
		cell "r$r-seg-$cond-b1" seg "$cond" 1000 1s
	done
done
echo "matrix done $(date -u +%H:%M:%S)"
