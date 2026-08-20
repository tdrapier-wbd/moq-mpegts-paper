#!/usr/bin/env bash
# T7, segmented-HTTP arm — the four T1 clips through the segmented lane.
#
#   t7-segmented-sweep.sh [out-root] [capture-seconds]
#
# The clips are not interchangeable inputs and that is why all four are run: a
# synthetic exact-CBR reference, a 27.5 Mbps 4:2:2 broadcast mux, and two real
# contribution captures, differing in bitrate, GOP structure and native PCR
# cadence. On this lane the segment boundary is chosen by picture type, so GOP
# structure reaches the packager in a way it does not reach a media-aware importer.
set -uo pipefail

ROOT=${1:-$HOME/t7seg}
SECS=${2:-45}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$ROOT"
RESULTS="$ROOT/results.txt"

# Every cell binds the same port, so two sweeps at once do not collide loudly —
# they interleave, and each grades whichever clip is currently being served.
LOCK="$ROOT/sweep.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
	echo "a sweep is already running (holding $LOCK); refusing to start a second" >&2
	exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

clips=(
	"$HOME/testloop_clean.ts"
	"$HOME/testloop.ts"
	"$HOME/CNNiEMEA.ts"
	"$HOME/CNNiEMEA2.ts"
)

for src in "${clips[@]}"; do
	name=$(basename "$src" .ts)
	[ -f "$src" ] || { echo "RESULT clip=$name arm=- status=MISSING_CLIP" | tee -a "$RESULTS"; continue; }
	echo "=== $name ==="
	bash "$HERE/t7-segmented-clip.sh" "$src" "$ROOT/$name" "$SECS" 2>/dev/null |
		tee -a "$RESULTS"
	# The captures are large and every graded number is already on the result line.
	rm -f "$ROOT/$name"/*.ts
	rm -rf "$ROOT/$name/hls"
done

echo
echo "=== all results ==="
grep -E '^(RESULT|INFO)' "$RESULTS"
