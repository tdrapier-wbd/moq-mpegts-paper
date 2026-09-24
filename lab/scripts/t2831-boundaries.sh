#!/usr/bin/env bash
# Replicates of the shedding rungs, then the absorption boundary on each lane, both in the
# `netns`/`cake` rig and both conserved against a clean cell of the same invocation.
#
# Graded on content, the MoQ lane sheds at every sustained shortfall and is clean at 1.2x, so its
# boundary is somewhere in 1.2x-0.9x -- and whether it sits at or above 1.0x decides whether the
# lane can be provisioned at the stream's own rate. In the netns rig the segmented lane is clean at
# 0.9x for 60 s and sheds at chronic 0.8x and at 0.5x for 60 s, so SEG_BOUNDARY walks 0.8x-0.6x.
#
# A third phase re-runs the segmented cells the default receiver policy voids in this rig: a fetch
# caught by the 30 s outage, and every fetch under 5 % and 10 % loss at 100 ms RTT, outlasts the 15 s
# timeout and the truncated segment ends the run. With truncation recorded as a hole and a 60 s
# timeout the receiver keeps going, as a player would, and the cell measures what the lane delivers.
#
# One replicate is one invocation of each ladder, each with its own control, because the
# conservation offset is per invocation. MoQ on `ffa5b81b`, unpadded, relay controller `delay`.
#
# Usage: t2831-boundaries.sh [outroot]
# Env:   MOQ_BIN (~/bin-ffa5b81b), REPS (3), SEG_REPS (2), MOQ_REPL, SEG_REPL, MOQ_BOUNDARY, SEG_BOUNDARY,
#        SEG_HOLE
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail

ROOT=${1:-$HOME/t2831-boundaries}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOQ_BIN=${MOQ_BIN:-$HOME/bin-ffa5b81b}
REPS=${REPS:-3}
SEG_REPS=${SEG_REPS:-2}
MOQ_REPL=${MOQ_REPL:-"control step-0.9x-60s step-0.8x-5s step-0.8x-perm step-0.5x-60s"}
SEG_REPL=${SEG_REPL:-"control step-0.9x-60s step-0.8x-5s step-0.8x-perm step-0.5x-60s"}
MOQ_BOUNDARY=${MOQ_BOUNDARY:-"control step-1.1x-60s step-1.0x-60s step-0.95x-60s"}
SEG_BOUNDARY=${SEG_BOUNDARY:-"control step-0.8x-60s step-0.7x-60s step-0.6x-60s"}
SEG_HOLE=${SEG_HOLE:-"control outage-30s loss5 loss10"}
mkdir -p "$ROOT"

moq() { # <outdir> <cells...>
	local out="$1"
	shift
	sudo env MOQ="$MOQ_BIN/moq" RELAY="$MOQ_BIN/moq-relay" CLIP="$HOME/clip120.ts" NETNS="$HOME/t8b-netns.sh" \
		GRADER="$HOME/t28-media-lost.py" CONTENT="$HOME/t28-content-lost.py" OUT="$out" \
		MOQ_CC=delay MOQ_MUX_RATE=0 bash "$HERE/t28-t31-moq-ladder.sh" "$@" >"$out.log" 2>&1
	sudo python3 "$HERE/t2831-conservation.py" "$out" --csv "$out/conservation.csv" >/dev/null 2>&1
}
seg() { # <outdir> <cells...>; RECV_TRUNCATED / RECV_TIMEOUT pass through
	local out="$1"
	shift
	sudo env OUT="$out" RECV_TRUNCATED="${RECV_TRUNCATED:-abort}" RECV_TIMEOUT="${RECV_TIMEOUT:-15}" \
		bash "$HERE/t31-seg-netns.sh" "$@" >"$out.log" 2>&1
}

for phase in repl boundary; do
	if [ "$phase" = repl ]; then mc=$MOQ_REPL sc=$SEG_REPL; else mc=$MOQ_BOUNDARY sc=$SEG_BOUNDARY; fi
	for rep in $(seq 1 "$REPS"); do
		echo "=== $(date -u +%FT%TZ) $phase moq rep $rep ==="
		# shellcheck disable=SC2086  # a list of cells
		moq "$ROOT/$phase-moq-r$rep" $mc
		sleep 5
	done
	for rep in $(seq 1 "$SEG_REPS"); do
		echo "=== $(date -u +%FT%TZ) $phase segmented rep $rep ==="
		# shellcheck disable=SC2086
		seg "$ROOT/$phase-seg-r$rep" $sc
		sleep 5
	done
done
for rep in $(seq 1 "$SEG_REPS"); do
	echo "=== $(date -u +%FT%TZ) seghole segmented rep $rep ==="
	# shellcheck disable=SC2086
	RECV_TRUNCATED=hole RECV_TIMEOUT=60 seg "$ROOT/seghole-seg-r$rep" $SEG_HOLE
	sleep 5
done

echo
echo "== video: holes / missing at close (s), replicates in order =="
for phase in repl boundary seghole; do
	for lane in moq seg; do
		case "$phase/$lane" in
		repl/moq) cells=$MOQ_REPL ;;
		repl/seg) cells=$SEG_REPL ;;
		boundary/moq) cells=$MOQ_BOUNDARY ;;
		boundary/seg) cells=$SEG_BOUNDARY ;;
		seghole/seg) cells=$SEG_HOLE ;;
		*) continue ;;
		esac
		for cell in $cells; do
			vals=$(for d in "$ROOT/$phase-$lane-r"*/; do
				awk -F, -v c="$cell" '$1==c{printf "%s/%s ", $2, $4}' "$d/conservation.csv" 2>/dev/null
			done)
			printf '%-9s %-4s %-16s %s\n' "$phase" "$lane" "$cell" "$vals"
		done
	done
done
