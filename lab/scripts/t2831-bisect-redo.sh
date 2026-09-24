#!/usr/bin/env bash
# Re-run the bisection cells that `5d0991b9` voided. Its relay drains for longer than the ladder's
# old one-second teardown, so the cell after every successful one found :4443 still bound and
# captured nothing (outage-5s and step-0.9x-60s, on both backends, every replicate). The ladder now
# waits for the relay to exit; this repeats phase 1 for those two builds with the same settings, in
# the same cell order, so the cells line up with the other builds' rows.
#
# Waits for the netns queue to finish: the rigs share namespaces.
# Usage: t2831-bisect-redo.sh [root]        (~40 min; log: ~/t2831-bisect-redo.log)
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=${1:-$HOME/t2831-bisect}
CELLS=${CELLS:-"control outage-5s outage-30s step-0.9x-60s"}
REPS=${REPS:-3}

while pgrep -f "[t]2831-queue[.]sh" >/dev/null; do sleep 60; done

for bin in bin-5d0991b9 bin-5d0991b9-noq; do
	for rep in $(seq 1 "$REPS"); do
		out="$ROOT/$bin-redo-r$rep"
		echo "=== $(date -u +%FT%TZ) $bin redo rep $rep ==="
		# shellcheck disable=SC2086  # CELLS is a list
		sudo env MOQ="$HOME/$bin/moq" RELAY="$HOME/$bin/moq-relay" CLIP="$HOME/clip120.ts" \
			NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py" CONTENT="$HOME/t28-content-lost.py" \
			OUT="$out" MOQ_CC=delay bash "$HERE/t28-t31-moq-ladder.sh" $CELLS >"$out.log" 2>&1
		[ "$rep" -gt 1 ] && sudo rm -f "$out"/*.ts
		sudo python3 "$HERE/t2831-conservation.py" "$out" --csv "$out/conservation.csv" >/dev/null
		grep -H "RELAY DID NOT START" "$out.log"
		sleep 5
	done
done

echo
echo "== video missing at close (s), replicates in order =="
for bin in bin-5d0991b9 bin-5d0991b9-noq; do
	for cell in $CELLS; do
		vals=$(for rep in $(seq 1 "$REPS"); do
			awk -F, -v c="$cell" '$1==c{printf "%s ", $4}' "$ROOT/$bin-redo-r$rep/conservation.csv" 2>/dev/null
		done)
		printf '%-18s %-22s %s\n' "$bin" "$cell" "$vals"
	done
done
echo "=== $(date -u +%FT%TZ) redo done ==="
