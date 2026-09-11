#!/bin/bash
# T33 Part A: one boundary condition through the full media-aware lane, graded at P1.
#
#   source.ts -> tsp regulate -> moq import ts -> relay -> moq export ts
#                                                       -> mpegts-pacer -> groomed.ts
#
# Everything starts and stops inside one invocation, because background processes do not
# survive between tool calls here (INSTRUCTIONS.local.md §2).
#
# Two egress captures are kept per arm, which is what lets a failure be attributed rather than
# argued about:
#
#   exported.ts  what `moq export ts` handed out    -- MoQ alone, no groomer
#   groomed.ts   what the groomer emitted           -- the lane's egress
#
# A condition that survives to exported.ts and dies in groomed.ts is ours; one that dies in
# exported.ts is upstream. Grading only the last of the two cannot tell them apart.
#
# Usage: t33-partA-arm.sh <source.ts> <label> <seconds> [ppm_offset]
#   ppm_offset mis-rates the replay by that many parts per million, which is Part A item 2's
#   source-clock drift arm (ISO 13818-1 permits +/-30 ppm on the 27 MHz clock). A non-zero
#   value replaces `--pcr-synchronous` with an explicit `--bitrate`, because pacing off the
#   source's own PCR is exactly what a drift arm must not do.

set -u
SRC="${1:?source .ts}"
LABEL="${2:?label}"
SECS="${3:-20}"
PPM="${4:-0}"

W=/tmp/t33
MOQ=${MOQ:-$HOME/bin-3529/moq}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
RELAY_URL=${RELAY_URL:-https://127.0.0.1:9543/t33}
FP=$(cat $W/fp.txt)
RUN=$W/out/$LABEL
mkdir -p "$RUN"

# The clip's own CBR rate, from TSDuck rather than from arithmetic on the file size, then
# shifted by PPM. `pcrbitrate` is the rate the stream's own clock implies.
NOM=$(tsp -I file "$SRC" -P analyze --normalized -O drop 2>/dev/null |
	tr ':' '\n' | awk -F= '/^pcrbitrate=/{print $2; exit}')
[ -z "${NOM:-}" ] && NOM=2000000
RATE=$(python3 -c "print(int(round($NOM*(1+$PPM/1e6))))")
echo "arm $LABEL: src=$(basename "$SRC") secs=$SECS ppm=$PPM pcrbitrate=$NOM replay=$RATE"

BCAST="t33$LABEL.hang"

# Subscribers first: reservation gating publishes the catalog once tracks resolve, so a
# subscriber joining late on a short clip can miss the run.
timeout $((SECS + 20)) "$MOQ" --client-connect "$RELAY_URL" --client-tls-fingerprint "$FP" \
	--client-quic-gso=false --broadcast "$BCAST" export ts --latency-max 3s \
	>"$RUN/exported.ts" 2>"$RUN/export.log" &
SUB=$!

timeout $((SECS + 20)) "$MOQ" --client-connect "$RELAY_URL" --client-tls-fingerprint "$FP" \
	--client-quic-gso=false --broadcast "$BCAST" export ts --latency-max 3s 2>"$RUN/export2.log" |
	"$PACER" - "$RATE" --latency-ms 1000 --max-latency-ms 8000 --stall-ms 3000 --on-stall mute \
		>"$RUN/groomed.ts" 2>"$RUN/pacer.log" &
GRM=$!
sleep 3

if [ "$PPM" = "0" ]; then
	PACE=(-P regulate --pcr-synchronous)
else
	PACE=(-P regulate --bitrate "$RATE")
fi
tsp -I file "$SRC" "${PACE[@]}" -O file 2>"$RUN/tsp.log" |
	timeout $((SECS + 16)) "$MOQ" --client-connect "$RELAY_URL" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --broadcast "$BCAST" import ts >"$RUN/import.log" 2>&1
echo "  import rc=$?"

wait $SUB 2>/dev/null
wait $GRM 2>/dev/null

cp "$SRC" "$RUN/source.ts"
for f in source exported groomed; do
	sz=$(stat -f%z "$RUN/$f.ts" 2>/dev/null || echo 0)
	printf "  %-9s %10s B  %7d pkts\n" "$f" "$sz" "$((sz / 188))"
done
