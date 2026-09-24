#!/usr/bin/env bash
# T41 — which MPEG-TS stream kinds survive an unflagged loop wrap, and how many wraps?
#
# `moq import ts` aborts with *frame timestamp is below the live edge* when a source's
# timestamps restart below the producer's live edge (#3798). Upstream's plan
# (`quest/m1/ts-import-reanchor.md`) states two things it has not reproduced in-tree:
#
#   1. Only `LegacyStream` (MPEG-1/2 audio) calls `reanchor`; H.264, H.265, AAC, Opus,
#      verbatim PES and sections abort on the first backward timestamp.
#   2. `LegacyStream::reanchor` sets `self.shift` once and never grows it, so a *second*
#      unflagged wrap lands below the edge again and aborts even the legacy path.
#
# Claim 2 decides whether the fix is "lift reanchor into every stream kind" or "lift it AND
# make it cumulative", so it is worth measuring rather than reading. This rig isolates one
# elementary stream per arm, loops it with `tsp --infinite` (an unflagged backward jump in
# both PCR and PTS), and records at which wrap the import dies.
#
#   t41-reanchor-coverage.sh [outdir]
#
# env: BIN (moq binary dir), PORT (4493), WRAPS (3), FIXTURES (space-separated basenames
#      of <name>.ts in $HOME, each a single-ES transport stream with its own PCR)
#
# Fixtures are built by `t41-make-fixtures.sh`. Each arm reports the wrap index it died on,
# which is what distinguishes claim 2 holding (legacy dies on wrap 2) from the shift being
# cumulative already (legacy survives every wrap).
set -uo pipefail

BIN="${BIN:?set BIN to the moq binary dir}"
PORT="${PORT:-4493}"
WRAPS="${WRAPS:-3}"
FIXTURES="${FIXTURES:-fx-h264 fx-legacy fx-ac3}"
OUT="${1:-$HOME/t41-reanchor}"

rm -rf "$OUT"
mkdir -p "$OUT"

setsid nohup "$BIN/moq-relay" --listen "127.0.0.1:$PORT" --listen-tls-generate 127.0.0.1 \
	--auth-public "**" --quic-gso=false --quic-congestion-control loss --log-level warn \
	>"$OUT/relay.log" 2>&1 </dev/null &
RELAY_PID=$!
trap 'kill "$RELAY_PID" 2>/dev/null' EXIT
sleep 3

printf '%-11s %9s %7s %8s  %s\n' fixture wrap_s died_at wrap_idx error

for fx in $FIXTURES; do
	src="$HOME/$fx.ts"
	[ -f "$src" ] || {
		printf '%-11s %9s %7s %8s  %s\n' "$fx" - - - "MISSING $src"
		continue
	}

	# One wrap period, from the fixture's own declared rate: the loop wrap happens when
	# `tsp --infinite` reaches the end, so the wrap interval is the fixture's duration.
	rate=$(tsp -I file "$src" -P analyze --normalized -O drop 2>/dev/null |
		grep -m1 '^ts:' | tr ':' '\n' | sed -n 's/^bitrate=//p')
	[ -n "${rate:-}" ] && [ "$rate" -gt 0 ] 2>/dev/null ||
		rate=$(tsp -I file "$src" -P analyze --normalized -O drop 2>/dev/null |
			grep -m1 '^ts:' | tr ':' '\n' | sed -n 's/^pcrbitrate=//p')
	bytes=$(stat -c%s "$src")
	wrap_s=$(awk -v b="$bytes" -v r="${rate:-0}" 'BEGIN{if(r>0)printf "%.1f", b*8/r; else print 0}')

	bcast="t41.$fx.hang"
	log="$OUT/$fx.log"

	tsp --realtime -I file "$src" --infinite -P regulate --pcr-synchronous -O file - 2>"$OUT/$fx.tsp.log" |
		"$BIN/moq" --connect-tls-insecure --connect "https://127.0.0.1:$PORT" \
			--broadcast "$bcast" import ts >"$log" 2>&1 &
	pipe=$!

	# Wait for birth before watching for death: absence is also what "not started yet"
	# looks like, and polling for it first scores every arm as an instant failure.
	born=""
	for _ in $(seq 1 30); do
		sleep 1
		if pgrep -f "t41[.]${fx}[.]hang" >/dev/null 2>&1; then
			born=$(date +%s.%N)
			break
		fi
	done
	if [ -z "$born" ]; then
		printf '%-11s %9s %7s %8s  %s\n' "$fx" "$wrap_s" - - "never published"
		kill "$pipe" 2>/dev/null
		sleep 2
		continue
	fi

	# Watch until it dies or we have seen WRAPS wraps with margin.
	budget=$(awk -v w="$wrap_s" -v n="$WRAPS" 'BEGIN{printf "%d", w*n+w/2+10}')
	died=""
	for _ in $(seq 1 "$budget"); do
		sleep 1
		pgrep -f "t41[.]${fx}[.]hang" >/dev/null 2>&1 || {
			died=$(date +%s.%N)
			break
		}
	done

	err=$(grep -m1 -E '^(Error|error):' "$log" | cut -c1-70)
	if [ -n "$died" ]; then
		el=$(awk -v a="$born" -v b="$died" 'BEGIN{printf "%.1f", b-a}')
		idx=$(awk -v e="$el" -v w="$wrap_s" 'BEGIN{if(w>0)printf "%.2f", e/w; else print "?"}')
		printf '%-11s %9s %6ss %8s  %s\n' "$fx" "$wrap_s" "$el" "$idx" "${err:-(none)}"
	else
		printf '%-11s %9s %7s %8s  %s\n' "$fx" "$wrap_s" "none" ">=$WRAPS" "survived — ${err:-no error}"
		pkill -f "t41[.]${fx}[.]hang" 2>/dev/null
	fi
	kill "$pipe" 2>/dev/null
	sleep 2
done
