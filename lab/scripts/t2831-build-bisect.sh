#!/usr/bin/env bash
# Which build changed what the media-aware lane delivers after an outage and under random loss?
#
# Graded on content, the retained `fd4f5d82e` capture of T28's 5 s outage lost 0.2 s of video;
# `ffa5b81b` loses 10-12.6 s of the same cell under either controller. At the idle timeout
# `fd4f5d82e` resumed after a 30 s outage and `ffa5b81b` does not. And on `ffa5b81b` the picture
# stops for most of a 60 s window under 5 % random loss at a 2 s budget -- a loss rate the
# published matched ladder, on older builds and PCR-graded, recorded as costing a few seconds.
# One plausible cause is the backend change at #3811, which moved the resolved `delay` controller
# from BBRv1 (quinn, loss-blind) to BBRv3 (noq, backs off above ~2 % loss); that is reasoned, and
# this run is what tests it.
#
# Phase 1, the outage/capacity ladder: control, 5 s and 30 s outages, 0.9x for 60 s.
# Phase 2, the matched ladder's MoQ lane at a 2 s budget: none, 5 s outage, 5 % loss, 20 % reorder
# -- the three shapes the published ranking against SRT rests on.
# Every build on the host that a published MoQ figure came from, in commit order.
#
# Held constant: the netns rig, clip, the relay's controller pinned to `delay` (what every one of
# these builds resolves an unset flag to), and no padding (`--mux-rate 0` where the build has the
# flag; the older builds do not pad). The backend is named per row, because it cannot be held.
# Graded by `t28-content-lost.py` and conserved against each invocation's own clean cell by
# `t2831-conservation.py`, because a picture that stops early leaves no hole to count.
#
# Captures are kept for each build's first replicate only; the host has ~9 GB free.
#
# Usage: t2831-build-bisect.sh [outroot]         (~2.7 h)
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail

ROOT=${1:-$HOME/t2831-bisect}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPS=${REPS:-3}
MREPS=${MREPS:-2}
CELLS=${CELLS:-"control outage-5s outage-30s step-0.9x-60s"}
MIMPAIRS=${MIMPAIRS:-"none outage loss5 reorder20"}
mkdir -p "$ROOT"

# bindir | backend | whether the build takes --mux-rate
BUILDS=(
	"bin-3529|quinn|no"
	"bin-5d0991b9|quinn|no"
	"bin-5d0991b9-noq|noq|no"
	"bin-53f8aa99|noq|yes"
	"bin-84b34f54|noq|yes"
	"bin-ffa5b81b|noq|yes"
)

mux_env() { [ "$1" = yes ] && echo MOQ_MUX_RATE=0; }

for spec in "${BUILDS[@]}"; do
	IFS='|' read -r bin backend mux <<<"$spec"
	for rep in $(seq 1 "$REPS"); do
		out="$ROOT/$bin-r$rep"
		echo "=== $(date -u +%FT%TZ) phase 1 $bin ($backend) rep $rep ==="
		# shellcheck disable=SC2086,SC2046  # CELLS is a list; the mux assignment is present or absent
		sudo env MOQ="$HOME/$bin/moq" RELAY="$HOME/$bin/moq-relay" CLIP="$HOME/clip120.ts" \
			NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py" CONTENT="$HOME/t28-content-lost.py" \
			OUT="$out" MOQ_CC=delay $(mux_env "$mux") \
			bash "$HERE/t28-t31-moq-ladder.sh" $CELLS >"$out.log" 2>&1
		echo "backend: $backend" | sudo tee -a "$out/build.txt" >/dev/null
		[ "$rep" -gt 1 ] && sudo rm -f "$out"/*.ts
		sleep 5
	done
	echo "=== $(date -u +%FT%TZ) phase 2 $bin ($backend) ==="
	# shellcheck disable=SC2046
	sudo env BIN="$HOME/$bin" OUT="$ROOT/matched" LANES=moq BUDGETS=2 REPS="$MREPS" \
		IMPAIRS="$MIMPAIRS" MOQ_CC=delay $(mux_env "$mux") \
		bash "$HERE/t28-t31-srt-ladder.sh" "$bin" >"$ROOT/matched-$bin.log" 2>&1
	sleep 5
done

echo
echo "== video missing at window close (s), conserved; replicates in order =="
for spec in "${BUILDS[@]}"; do
	IFS='|' read -r bin backend _ <<<"$spec"
	for rep in $(seq 1 "$REPS"); do
		sudo python3 "$HERE/t2831-conservation.py" "$ROOT/$bin-r$rep" --csv "$ROOT/$bin-r$rep/conservation.csv" >/dev/null
	done
	sudo python3 "$HERE/t2831-conservation.py" "$ROOT/matched/$bin" --csv "$ROOT/matched/$bin/conservation.csv" >/dev/null
	for cell in $CELLS; do
		vals=$(for rep in $(seq 1 "$REPS"); do
			awk -F, -v c="$cell" '$1==c{printf "%s ", $4}' "$ROOT/$bin-r$rep/conservation.csv" 2>/dev/null
		done)
		printf '%-18s %-6s %-22s %s\n' "$bin" "$backend" "$cell" "$vals"
	done
	for im in $MIMPAIRS; do
		vals=$(awk -F, -v c="moq-b2-$im-" 'index($1,c)==1{printf "%s ", $4}' "$ROOT/matched/$bin/conservation.csv" 2>/dev/null)
		printf '%-18s %-6s %-22s %s\n' "$bin" "$backend" "matched b2 $im" "$vals"
	done
done
