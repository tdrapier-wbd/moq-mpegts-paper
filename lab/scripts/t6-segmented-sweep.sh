#!/usr/bin/env bash
# T6, segmented-HTTP arm — the drill set, one cell after another.
#
#   t6-segmented-sweep.sh [out-root]
#
# Cells are (drill, client) pairs. The client is varied deliberately on the
# serving-node drill: `tsp -I hls` and ffmpeg both abandon the stream on a failed
# playlist reload, so running only those grades their error handling rather than
# the lane. `pull` is a minimal client whose only feature is retrying, and it is
# what establishes the protocol-level bound.
set -uo pipefail

ROOT=${1:-$HOME/t6seg}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$ROOT"
RESULTS="$ROOT/results.txt"

cells=(
	"baseline pull"
	"origin-restart tsp"
	"origin-restart ffmpeg"
	"origin-restart pull"
	"dual-source pull"
	"dual-source-align pull"
	"graceful-exit pull"
	"graceful-exit tsp"
	"determinism pull"
)

for cell in "${cells[@]}"; do
	drill=${cell%% *}
	recv=${cell##* }
	dir="$ROOT/$drill-$recv"
	echo "=== $drill / $recv ==="
	RECV=$recv bash "$HERE/t6-segmented-arm.sh" "$drill" "$dir" 2>/dev/null |
		tee -a "$RESULTS" | grep '^RESULT' || echo "RESULT drill=$drill recv=$recv status=CELL_FAILED" | tee -a "$RESULTS"
	# Captures are large and the graded numbers are already on the RESULT line.
	rm -f "$dir/receive.ts"
	rm -rf "$dir/www"
done

echo
echo "=== all results ==="
grep '^RESULT' "$RESULTS"
