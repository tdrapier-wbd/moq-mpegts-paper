#!/usr/bin/env bash
# Find the commit between `fd4f5d82e` and `5d0991b9` after which `moq export ts` no longer rides a
# session teardown. In T28's 30 s outage cell the session times out on every build, the idle
# timeout being 30 s on both ends; the oldest build's exporter resubscribes once the client has
# reconnected, and every later build exits `json: dropped` first. This drives `git bisect run` over
# that range's first-parent history in the build tree: per step, REPS (2) runs of the 30 s outage
# cell in the `netns`/`cake` rig, with the relay on `delay`.
#
# It is a race on both sides, so the cell matters. At 40 s the reconnect waits ~10 s for the path,
# and the oldest build exits the same way in one replicate of two; at 30 s the path is back before
# the reconnect, the window is ~1 s, and the builds separate cleanly (3 of 3 survive on the oldest,
# none on any later build).
#
#   good  in every replicate, after the session closes, the subscriber resubscribes to the catalog
#   bad   in any replicate, after the session closes, the subscriber exits with an error
#   skip  the build fails, the relay does not start, or a log shows no teardown to judge
#
# Usage: t2831-idle-bisect.sh [outroot]        (needs passwordless sudo; the rig is shared, so
#                                               never beside another rig)
# The build tree is returned to the commit it was on; `target/release` holds the last step's build.
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
ROOT=${1:-$HOME/t2831-idle-bisect}
SRC=${SRC:-$HOME/moq-main}
GOOD=${GOOD:-fd4f5d82e}
BAD=${BAD:-5d0991b9}
CELL=${CELL:-outage-30s}
REPS=${REPS:-2}
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
export PATH="$HOME/.cargo/bin:$PATH"

build() { # <package> <binary>
	nice -n 19 cargo build --release -q -p "$1" --bin "$2" --no-default-features \
		--features "quinn,websocket" >>"$ROOT/build.log" 2>&1 ||
		nice -n 19 cargo build --release -q -p "$1" --bin "$2" >>"$ROOT/build.log" 2>&1
}

step() {
	cd "$SRC" || exit 125
	local sha out log closed rep verdict=good
	sha=$(git rev-parse --short=9 HEAD)
	echo "--- $(date -u +%FT%TZ) $sha $(git log -1 --format=%s | cut -c1-90)" >>"$ROOT/build.log"
	build moq-cli moq || exit 125
	build moq-relay moq-relay || exit 125
	mkdir -p "$ROOT/bin"
	cp target/release/moq target/release/moq-relay "$ROOT/bin/"
	for rep in $(seq 1 "$REPS"); do
		out="$ROOT/$sha-r$rep"
		sudo env CLIP="$HOME/clip120.ts" NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py" \
			CONTENT="$HOME/t28-content-lost.py" LATENCY="$HOME/t18-latency.py" \
			MOQ="$ROOT/bin/moq" RELAY="$ROOT/bin/moq-relay" OUT="$out" MOQ_CC=delay \
			bash "$HERE/t28-t31-moq-ladder.sh" "$CELL" >"$out.log" 2>&1
		log="$out/$CELL.sub.log"
		[[ -f "$log" ]] || exit 125
		grep -q "DID NOT START" "$out.log" && exit 125
		closed=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -n -m1 "session closed" | cut -d: -f1)
		[[ -n "$closed" ]] || { echo "$sha r$rep skip: no teardown" >>"$ROOT/verdicts.txt"; exit 125; }
		if sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -n "+$closed" | grep -q "subscribe started.*catalog.json"; then
			echo "$sha r$rep good" >>"$ROOT/verdicts.txt"
		elif sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -n "+$closed" | grep -q "^Error:"; then
			echo "$sha r$rep bad: $(grep -m1 '^Error:' "$log")" >>"$ROOT/verdicts.txt"
			verdict=bad
		else
			echo "$sha r$rep skip: no resubscribe and no error" >>"$ROOT/verdicts.txt"
			exit 125
		fi
	done
	[[ "$verdict" == good ]] && exit 0
	exit 1
}

if [[ "${1:-}" == "--step" ]]; then
	ROOT=$2
	step
fi

mkdir -p "$ROOT"
cd "$SRC" || exit 1
git bisect reset >/dev/null 2>&1
git bisect start --first-parent "$BAD" "$GOOD" >>"$ROOT/bisect.log" 2>&1
git bisect run bash "$SELF" --step "$ROOT" >>"$ROOT/bisect.log" 2>&1
git bisect log >"$ROOT/bisect-final.log" 2>&1
grep -m1 "is the first bad commit" -A6 "$ROOT/bisect.log"
git bisect reset >/dev/null 2>&1
echo "=== $(date -u +%FT%TZ) idle bisect done ==="
