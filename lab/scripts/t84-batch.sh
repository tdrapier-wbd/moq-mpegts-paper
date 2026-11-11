#!/usr/bin/env bash
# T84's batch (lab/test-84-moq-cdn-relay-impairment.md), as root: both MoQ lanes at T72's two
# columns, through the CDN relay first and then through moq-relay on this host, one arm at a time
# (t84-moq-drive.py). The node's arms come first, inside the operator's slot.
#
# Usage: URL=<the node's moqt URL> t84-batch.sh <root> [arm ...]
# Env:   DELAYS (each relay and lane's first delay at each column, from the pilots: the export runs
#        at its delay plus a join-time offset), QLOG_MOQ (~/bin-d66c8928-qlog/moq), and the cell's
#        (MOQ, CLIP, ...)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${1:?usage: t84-batch.sh <root> [arm ...]}
shift
UHOME=$(getent passwd "${SUDO_USER:-ubuntu}" | cut -d: -f6)
QLOG_MOQ=${QLOG_MOQ:-$UHOME/bin-d66c8928-qlog/moq}
DELAYS=${DELAYS:-node-demux:5600:11560 node-passthrough:5630:11590 local-demux:5750:11710 local-passthrough:5750:11710}
ALL="outage,loss5,loss10,reorder5,reorder20"
[ -n "${URL:-}" ] || { echo "set URL" >&2; exit 2; }
mkdir -p "$ROOT"

delay() { # relay-lane column(a|b)
	local d
	for d in $DELAYS; do
		[ "${d%%:*}" = "$1" ] || continue
		case $2 in a) echo "$d" | cut -d: -f2 ;; b) echo "$d" | cut -d: -f3 ;; esac
	done
}
arm() { # relay lane column
	local name="$1-$2-$3" shapes=outage,loss5,loss10 target=11870 q=()
	if [ "$3" = a ]; then
		shapes=$ALL
		target=5910
		[ "$1-$2" = node-demux ] && q=(--qlog loss5 --qlog-moq "$QLOG_MOQ")
	fi
	echo "$(date -u +%FT%TZ) arm $name start"
	python3 "$HERE/t84-moq-drive.py" run "$ROOT" --arm "$name" --relay "$1" --lane "$2" \
		--delay-ms "$(delay "$1-$2" "$3")" --target-ms "$target" --shapes "$shapes" "${q[@]}"
	echo "$(date -u +%FT%TZ) arm $name end rc=$?"
}

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(node-demux-a node-demux-b node-passthrough-a node-passthrough-b
	local-demux-a local-demux-b local-passthrough-a local-passthrough-b)
for a in "${ARMS[@]}"; do
	IFS=- read -r relay lane column <<<"$a"
	arm "$relay" "$lane" "$column"
done
echo "$(date -u +%FT%TZ) batch done"
