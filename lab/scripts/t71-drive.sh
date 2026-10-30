#!/usr/bin/env bash
# T71's matrix: three rounds, each the conditions in order and within each the three lanes in an
# order rotated per round, one cell at a time. Resumable: a cell whose record is complete is skipped;
# a failed cell is reported and the matrix goes on.
#
#   ORIGIN_IP=<addr> ORIGIN=<ssh alias> FAR=<ssh alias> t71-drive.sh [seconds] [losses...]
set -uo pipefail

SECS=${1:-120}
shift || true
LOSSES=("$@")
[ ${#LOSSES[@]} -gt 0 ] || LOSSES=(0 0.1 1)
LOG=${LOG:-$HOME/t71runs}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TO=${TO:-$(command -v gtimeout || command -v timeout)}
LANES=(srt opaque aware)

relay_alive() {
	# shellcheck disable=SC2016
	"$TO" 30 ssh -o BatchMode=yes "$ORIGIN" 'kill -0 "$(cat t71/fix/relay.pgid)" 2>/dev/null' </dev/null
}

for r in 1 2 3; do
	for loss in "${LOSSES[@]}"; do
		for k in 0 1 2; do
			lane=${LANES[$(((k + r - 1) % 3))]}
			cell=r$r-$lane-l$loss
			if [ -s "$LOG/$cell/cell.txt" ]; then
				echo "skip $cell"
				continue
			fi
			if [ "$lane" != srt ] && ! relay_alive; then
				echo "FAILED $cell: the origin's relay is not running"
				continue
			fi
			bash "$HERE/t71-cell.sh" "$cell" "$lane" "$loss" "$SECS" || echo "FAILED $cell"
		done
	done
done
echo "matrix done $(date -u +%H:%M:%S)"
