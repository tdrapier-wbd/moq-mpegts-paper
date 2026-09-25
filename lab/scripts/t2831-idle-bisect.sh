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
# FIX=1 hunts the other way, for a range whose older end fails and newer end survives: GOOD is then
# the newer, surviving end, BAD the older, failing one, and git reports the first surviving commit.
# FIRST_PARENT=0 bisects every commit in the range, for a side branch with no runnable first-parent
# anchor. JUDGE=bytes grades what the lane delivered rather than what the log says: `dev` builds from
# late July resume without logging a resubscription, and stall at the teardown without logging an
# error. MIN_BYTES (40 MB) sits between the cell's two outcomes on the 120 s clip, about 63 MB when
# the exporter rides the teardown and about 22 MB when its output ends there. JUDGE=error hunts one
# failure among several: a step is bad if any replicate exits `Error: $BAD_ERROR`, good if none does
# and one survives by bytes, and skipped if every replicate fails some other way.
#
# JUDGE=missing bisects a cost rather than a survival: each replicate runs the control cell beside
# CELL in one invocation, conserves CELL against it (`t2831-conservation.py`), and the step is bad
# when any replicate's video missing at close exceeds MISSING_MAX s (MISSING_STAT=median judges the
# median instead). Any rather than the median, because a bad build can land in the good mode: on the
# 5 s outage cell at the ladder's 3 s budget the dev tip read 17.28, 8.82 and 17.56 s, while good builds read
# 3.9-9.1 s, so a median of three misjudges it about a quarter of the time and any-of-three about one
# time in thirty.
#
# Usage: t2831-idle-bisect.sh [outroot]        (needs passwordless sudo; the rig is shared, so
#                                               never beside another rig)
#        t2831-idle-bisect.sh --step <outroot>  (judge the build tree's current commit only)
# The build tree is returned to the commit it was on; `target/release` holds the last step's build.
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
ROOT=${1:-$HOME/t2831-idle-bisect}
SRC=${SRC:-$HOME/moq-main}
GOOD=${GOOD:-fd4f5d82e}
BAD=${BAD:-5d0991b9}
CELL=${CELL:-outage-30s}
REPS=${REPS:-2}
FIX=${FIX:-0}
FIRST_PARENT=${FIRST_PARENT:-1}
JUDGE=${JUDGE:-log}
MIN_BYTES=${MIN_BYTES:-40000000}
BAD_ERROR=${BAD_ERROR:-json: dropped}
MISSING_MAX=${MISSING_MAX:-12.5}
MISSING_STAT=${MISSING_STAT:-max}
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
export PATH="$HOME/.cargo/bin:$PATH"

build() { # <package> <binary>
	FEAT=quinn
	nice -n 19 cargo build --release -q -p "$1" --bin "$2" --no-default-features \
		--features "quinn,websocket" >>"$ROOT/build.log" 2>&1 && return
	FEAT=default
	nice -n 19 cargo build --release -q -p "$1" --bin "$2" >>"$ROOT/build.log" 2>&1
}

step() {
	cd "$SRC" || exit 125
	local sha out log closed rep n err survived=0 verdict=good m med
	local -a cells=("$CELL") missing=()
	[[ "$JUDGE" == missing ]] && cells=(control "$CELL")
	sha=$(git rev-parse --short=9 HEAD)
	echo "--- $(date -u +%FT%TZ) $sha $(git log -1 --format=%s | cut -c1-90)" >>"$ROOT/build.log"
	# A target directory grows by gigabytes per distant commit, and a full disk corrupts the bisect.
	(($(df --output=avail -k "$SRC" | tail -1) < 6000000)) && cargo clean -q
	build moq-cli moq || exit 125
	build moq-relay moq-relay || exit 125
	mkdir -p "$ROOT/bin"
	cp target/release/moq target/release/moq-relay "$ROOT/bin/"
	for rep in $(seq 1 "$REPS"); do
		out="$ROOT/$sha-r$rep"
		sudo env CLIP="$HOME/clip120.ts" NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py" \
			CONTENT="$HOME/t28-content-lost.py" LATENCY="$HOME/t18-latency.py" \
			MOQ="$ROOT/bin/moq" RELAY="$ROOT/bin/moq-relay" OUT="$out" MOQ_CC=delay \
			${LATMAX:+LATMAX="$LATMAX"} bash "$HERE/t28-t31-moq-ladder.sh" "${cells[@]}" >"$out.log" 2>&1
		log="$out/$CELL.sub.log"
		[[ -f "$log" ]] || exit 125
		grep -q "DID NOT START" "$out.log" && exit 125
		if grep -q "CELL VOID" "$out.log"; then
			echo "$sha r$rep skip: void, $(grep -m1 -E '^error' "$log")" >>"$ROOT/verdicts.txt"
			exit 125
		fi
		if [[ "$JUDGE" == missing ]]; then
			sudo python3 "$HERE/t2831-conservation.py" "$out" --csv "$out/conservation.csv" >/dev/null 2>&1
			m=$(awk -F, -v c="$CELL" '$1 == c { print $4 }' "$out/conservation.csv" 2>/dev/null)
			[[ "$m" =~ ^-?[0-9.]+$ ]] || { echo "$sha r$rep skip: no conserved figure" >>"$ROOT/verdicts.txt"; exit 125; }
			missing+=("$m")
			echo "$sha r$rep ${m}s missing ($FEAT)" >>"$ROOT/verdicts.txt"
			# The figure and the per-cell CSV are the record; a bisect's captures would otherwise fill the
			# disk before it converges.
			[[ "${KEEP_TS:-0}" == 1 ]] || sudo find "$out" -name '*.ts' -delete
			continue
		fi
		if [[ "$JUDGE" != log ]]; then
			# From the summary: the ladder deletes a capture whose content grades clean, and one that
			# ends at the teardown grades clean over its span.
			n=$(tail -1 "$out/summary.csv" 2>/dev/null | cut -d, -f5)
			[[ "$n" =~ ^[0-9]+$ ]] || n=0
			if [[ "$JUDGE" == error ]]; then
				err=$(grep -m1 '^Error:' "$log")
				if [[ "$err" == "Error: $BAD_ERROR"* ]]; then
					echo "$sha r$rep bad: ${n}B $err" >>"$ROOT/verdicts.txt"
					verdict=bad
				elif ((n >= MIN_BYTES)); then
					echo "$sha r$rep good: ${n}B" >>"$ROOT/verdicts.txt"
					survived=1
				else
					echo "$sha r$rep other: ${n}B ${err:-no error}" >>"$ROOT/verdicts.txt"
				fi
				continue
			fi
			if ((n >= MIN_BYTES)); then
				echo "$sha r$rep good: ${n}B" >>"$ROOT/verdicts.txt"
			else
				echo "$sha r$rep bad: ${n}B $(grep -m1 '^Error:' "$log")" >>"$ROOT/verdicts.txt"
				verdict=bad
			fi
			continue
		fi
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
	if [[ "$JUDGE" == missing ]]; then
		med=$(printf '%s\n' "${missing[@]}" | sort -g | awk -v s="$MISSING_STAT" '{ a[NR] = $1 } END {
			if (s == "max") print a[NR]; else print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }')
		awk -v m="$med" -v x="$MISSING_MAX" 'BEGIN { exit !(m > x) }' && verdict=bad
		echo "$sha $MISSING_STAT ${med}s: $verdict" >>"$ROOT/verdicts.txt"
	fi
	[[ "$JUDGE" == error && "$verdict" == good && "$survived" == 0 ]] && exit 125
	if [[ "$FIX" == 1 ]]; then
		[[ "$verdict" == good ]] && exit 1
		exit 0
	fi
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
fp=()
[[ "$FIRST_PARENT" == 1 ]] && fp=(--first-parent)
if [[ "$FIX" == 1 ]]; then
	git bisect start "${fp[@]}" --term-old=broken --term-new=fixed "$GOOD" "$BAD" >>"$ROOT/bisect.log" 2>&1
else
	git bisect start "${fp[@]}" "$BAD" "$GOOD" >>"$ROOT/bisect.log" 2>&1
fi
git bisect run bash "$SELF" --step "$ROOT" >>"$ROOT/bisect.log" 2>&1
git bisect log >"$ROOT/bisect-final.log" 2>&1
grep -m1 -E "is the first (bad|fixed) commit|only skipped commits left" -A6 "$ROOT/bisect.log"
git bisect reset >/dev/null 2>&1
echo "=== $(date -u +%FT%TZ) idle bisect done ==="
