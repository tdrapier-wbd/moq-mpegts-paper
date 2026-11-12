#!/usr/bin/env bash
# T85's batch (lab/test-85-relay-controller-loss.md), as root: the demultiplexed lane through
# moq-relay on this host at T84's 5.91 s column, one arm per relay controller, each under
# t84-moq-drive.py, then every arm against the default.
#
# Usage: BIN=<bindir> t85-batch.sh <root> [arm ...]      arms: default none thr20 noloss
# Env:   BIN (moq and moq-relay at the commit under test; thr20 and noloss take their moq-relay from
#        <BIN>-thr20 and <BIN>-noloss), DELAY_MS (the first control's delay, 5750), SHAPES, and the
#        cell's (CLIP, SCRIPTS, ...)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=${1:?usage: BIN=<bindir> t85-batch.sh <root> [arm ...]}
shift
BIN=${BIN:?set BIN to the build under test}
export SCRIPTS=${SCRIPTS:-$HERE}
DELAY_MS=${DELAY_MS:-5750}
SHAPES=${SHAPES:-loss5,loss10,reorder20,step8,shallow15}
mkdir -p "$ROOT"

arm() {
	local name=$1 env=(--env "MOQ=$BIN/moq")
	case $name in
	default) ;;
	none) env+=(--env "RELAY_ARGS=--quic-congestion-control none") ;;
	thr20 | noloss) env+=(--env "RELAY_BIN=$BIN-$name/moq-relay") ;;
	*)
		echo "unknown arm $name" >&2
		return 2
		;;
	esac
	echo "$(date -u +%FT%TZ) arm $name start"
	python3 "$HERE/t84-moq-drive.py" run "$ROOT" --arm "$name" --relay local --lane demux \
		--delay-ms "$DELAY_MS" --target-ms 5910 --shapes "$SHAPES" "${env[@]}"
	local rc=$?
	echo "$(date -u +%FT%TZ) arm $name end rc=$rc"
}

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(default none thr20 noloss)
for a in "${ARMS[@]}"; do
	arm "$a"
done
python3 "$HERE/t84-moq-drive.py" compare-arms "$ROOT" default | tee "$ROOT/compare.jsonl"
echo "$(date -u +%FT%TZ) batch done"
