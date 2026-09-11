#!/bin/bash
# T33 Part A item 2: source-clock drift, measured as a slope rather than waited for.
#
# The criterion as originally written -- "buffer occupancy remains bounded over >= 30 min at
# +/-30 ppm without underrun storm" -- cannot be graded by running it. At 30 ppm against a
# 1000 ms cushion the buffer moves 30 us per second, so the rail is 1000/30e-6 = 9.3 hours
# away and a 30-minute run sees 54 ms of movement: indistinguishable from the burstiness the
# arrival process already has. A run that cannot reach its own failure mode returns a null
# whatever the mechanism does.
#
# So measure the mechanism instead. Mis-rate the replay across a ladder wide enough for the
# slope to be resolvable, confirm the occupancy slope tracks the imposed offset, and derive
# the +/-30 ppm time-to-rail from the fitted slope. That converts an unrunnable soak into a
# measurement plus one line of arithmetic, and it states which half is which.
#
# `--on-stall fail` is deliberate: with `mute` the pacer keeps emitting for its whole timeout
# after the source ends, and that muted tail lands in the counters as thousands of underruns
# that have nothing to do with drift. `--stall-ms` has to clear the *startup* gap as well as
# the end of source, though -- at 2000 ms the groomer declares the source dead while it is
# still waiting for the publisher to connect, and the run ends in Priming with no output.
#
# Usage: t33-drift-ladder.sh <source.ts> <out-dir> [seconds] [ppm ...]

set -u
SRC="${1:?source .ts}"
OUT="${2:?out dir}"
SECS="${3:-120}"
shift 3 2>/dev/null || shift $#
PPMS=("$@")
[ ${#PPMS[@]} -eq 0 ] && PPMS=(0 1000 5000 20000)

W=/tmp/t33
MOQ=${MOQ:-$HOME/bin-3529/moq}
PACER=${PACER:?set PACER}
RELAY_URL=${RELAY_URL:-https://127.0.0.1:9543/t33}
FP=$(cat $W/fp.txt)
mkdir -p "$OUT"

NOM=$(tsp -I file "$SRC" -P analyze --normalized -O drop 2>/dev/null |
	tr ':' '\n' | awk -F= '/^pcrbitrate=/{print $2; exit}')
[ -z "${NOM:-}" ] && NOM=2000000

for PPM in "${PPMS[@]}"; do
	RATE=$(python3 -c "print(int(round($NOM*(1+$PPM/1e6))))")
	RUN="$OUT/ppm$PPM"
	mkdir -p "$RUN"
	BCAST="t33d${PPM//-/m}.hang"
	echo "### ppm=$PPM  nominal=$NOM  replay=$RATE"

	timeout $((SECS + 25)) "$MOQ" --client-connect "$RELAY_URL" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --broadcast "$BCAST" export ts --latency-max 3s 2>"$RUN/export.log" |
		"$PACER" - "$NOM" --latency-ms 1000 --max-latency-ms 8000 \
			--stall-ms 6000 --on-stall fail --stats-interval-ms 1000 \
			>"$RUN/groomed.ts" 2>"$RUN/pacer.log" &
	GRM=$!
	sleep 3

	# The groomer runs at the *nominal* rate; the publisher is the thing mis-rated. That is
	# what a drifting source does to a fixed-rate sink, and the reverse would measure the
	# groomer's own clock instead.
	tsp -I file "$SRC" -P regulate --bitrate "$RATE" -O file 2>"$RUN/tsp.log" |
		timeout $((SECS + 20)) "$MOQ" --client-connect "$RELAY_URL" --client-tls-fingerprint "$FP" \
			--client-quic-gso=false --broadcast "$BCAST" import ts >"$RUN/import.log" 2>&1

	wait $GRM 2>/dev/null
	echo "  $(grep -c . "$RUN/pacer.log") stderr lines, groomed $(($(stat -f%z "$RUN/groomed.ts" 2>/dev/null || echo 0) / 188)) pkts"
done
echo "ladder done"
