#!/usr/bin/env bash
# P0-m — the two halves [#3831](https://github.com/moq-dev/moq/pull/3831) left open.
#
# `t13-export-muxrate.sh` graded #3831 in the file domain: stuffing comes back at 4.93 % and the
# export declares a rate within 0.36 % of the source's. It could not speak to either of these:
#
#   1. **The wire.** Null padding changes what the stream is *made of*, not the instants at which
#      it is written. If the exporter now emits nulls to fill each PCR slot it may also be putting
#      a smoother stream on the socket — or it may be emitting the same bursts with more bytes in
#      them, which changes nothing a downstream groomer has to fix. A file capture cannot tell
#      these apart because writing to a file flattens release timing. Read live off a pipe instead:
#      a paced export gives PCR arrivals clustered near the 25 ms grid, an unpaced one gives
#      near-zero intervals inside a burst and then a stall.
#
#   2. **The absent-rate path.** #3831 publishes `mpegts.muxRate` only once the measurement is
#      stable across a window of PCR intervals. Filtering PID 0x1FFF out of a CBR clip was meant
#      to be the negative control and is not one: the PCR values are untouched, so the stream is
#      still paced to a *stable* rate, just a lower one, and import duly recorded it. Exercising
#      the omitted-field case needs a source whose rate genuinely varies, which this builds by
#      re-encoding at a fixed quality and no rate cap.
#
# Arms, three of them on one build so the padding is isolated from everything else that moved:
#
#   new-cbr   the CBR clip through the post-#3831 build. Padding should fire.
#   old-cbr   the same clip through a pre-#3831 build — the before, for the wire comparison.
#   new-vbr   a genuinely variable source through the post-#3831 build. Import should record
#             *no* rate, and export should then behave exactly as the old build does.
#
# Backend caveat: #3811 deleted quinn, so OLD and NEW differ in QUIC stack as well as in this
# feature. Both arms are loopback with no loss and the instrument is release timing at the
# subscriber's own pipe, so the stack is not a plausible cause of a cadence difference — but the
# `old` arm crosses the commit and the two `new` arms are the cleaner evidence.
#
#   t13-wire-padding.sh <label> [seconds]
#
# Env: NEW, OLD (binary dirs), CLIP, VBR (built if absent), PORT, ARRIVAL, OUT.
set -uo pipefail

# Post-#3793 CLI flags, detected per binary rather than assumed.
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
SECS=${2:-60}

NEW=${NEW:?set NEW to the post-#3831 binary dir}
OLD=${OLD:?set OLD to a pre-#3831 binary dir}
CLIP=${CLIP:-/home/ubuntu/clip120.ts}
VBR=${VBR:-/home/ubuntu/vbr120.ts}
ARRIVAL=${ARRIVAL:-/home/ubuntu/t19-pcr-arrival.py}
PORT=${PORT:-4462}
OUT=${OUT:-/home/ubuntu/t13-wire}/$LABEL

for f in "$CLIP" "$ARRIVAL" "$NEW/moq" "$OLD/moq"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done

rm -rf "$OUT"
mkdir -p "$OUT"

cleanup() {
	pkill -f "[m]oq-relay .*127.0.0.1:$PORT" 2>/dev/null
	pkill -f "t13wire" 2>/dev/null
	true
}
trap cleanup EXIT

echo "=== $(date -u) t13-wire-padding $LABEL ==="
"$NEW/moq" --version
"$OLD/moq" --version

# ---- the variable source -----------------------------------------------------------------
# Constant quality, no rate cap and no mux rate, so the multiplex rate follows the picture
# content instead of a target. That is the property the arm needs; the resolution is dropped
# only to keep the encode inside a minute, since nothing here grades the picture.
if [ ! -s "$VBR" ]; then
	echo "--- building a genuinely variable source at $VBR ---"
	ffmpeg -loglevel error -y -i "$CLIP" -t 120 \
		-vf scale=640:360 -c:v libx264 -preset veryfast -crf 30 -g 50 \
		-c:a copy -muxrate 0 -f mpegts "$VBR" || {
		echo "FAIL: could not build the VBR source" >&2
		exit 1
	}
fi
# State the variability rather than assume it: #3831 publishes a rate once four half-second
# samples agree within 2 %, so an arm claiming "no rate should be recorded" has to show its
# source moves by more than that.
echo "--- source rate variability, 0.5 s windows ---"
for f in "$CLIP" "$VBR"; do
	python3 - "$f" <<-'PY'
		import subprocess, sys, statistics
		# Bytes per half-second of PCR time, off the PCR PID, which is what import measures.
		out = subprocess.run(["tsp", "-I", "file", sys.argv[1], "-P", "pcrextract",
		                      "--output-file", "/dev/stdout", "-O", "drop"],
		                     capture_output=True, text=True).stdout
		rows = [l.split(",") for l in out.splitlines()[1:] if ",PCR," in l or l.count(",") > 5]
		s = [(int(r[1]), int(r[5])) for r in rows if len(r) > 5 and r[3] == "PCR"]
		if len(s) < 20:
		    print(f"  {sys.argv[1]}: too few PCRs"); raise SystemExit
		rates, i = [], 0
		while i < len(s) - 1:
		    j = i
		    while j < len(s) - 1 and (s[j][1] - s[i][1]) / 27e6 < 0.5:
		        j += 1
		    dt = (s[j][1] - s[i][1]) / 27e6
		    if dt > 0:
		        rates.append((s[j][0] - s[i][0]) * 188 * 8 / dt)
		    i = j
		m = statistics.median(rates)
		spread = (max(rates) - min(rates)) / m * 100
		print(f"  {sys.argv[1]}: median {m:,.0f} b/s, spread {spread:.1f} % of median "
		      f"over {len(rates)} half-second windows")
	PY
done

# ---- arms --------------------------------------------------------------------------------
# $1 arm, $2 binary dir, $3 source clip
run_arm() {
	local arm=$1 bin=$2 src=$3
	local d="$OUT/$arm"
	mkdir -p "$d"
	cleanup
	sleep 1

	moq_cli_detect "$bin/moq" "$bin/moq-relay"
	local bcast="t13wire-$arm.hang"

	"$bin/moq-relay" "${RELAY_BIND[@]}" "127.0.0.1:$PORT" "${RELAY_TLS[@]}" localhost \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" >"$d/relay.log" 2>&1 &
	sleep 2

	echo "--- arm $arm ($(basename "$bin"), $(basename "$src")) ---"
	# The subscriber's stdout goes straight into the arrival reader, never to a file: a file
	# write flattens exactly the release timing this arm exists to measure.
	setsid bash -c "RUST_LOG=moq_mux=debug,info '$bin/moq' ${MOQ_DIAL[*]} \
        'https://127.0.0.1:$PORT/anon' --quic-gso=false --broadcast '$bcast' \
        export ts ${MOQ_LAT[*]} 3s 2>'$d/export.log' \
      | python3 '$ARRIVAL' $((SECS - 5)) > '$d/arrival.txt' 2>&1" &
	sleep 2

	setsid bash -c "tsp --realtime -I file '$src' --infinite -P regulate --pcr-synchronous \
        --wait-min 5 -O file - 2>/dev/null \
      | RUST_LOG=moq_mux=debug,info '$bin/moq' ${MOQ_DIAL[*]} \
        'https://127.0.0.1:$PORT/anon' --quic-gso=false --broadcast '$bcast' import ts" \
		>"$d/import.log" 2>&1 &

	sleep "$SECS"
	pkill -f "t13wire-$arm" 2>/dev/null
	sleep 2

	echo "  recorded mux rate:"
	grep -ioE "mux.?rate[^,}]*" "$d/import.log" "$d/export.log" 2>/dev/null | sort -u | head -3 | sed 's/^/    /'
	grep -qioE "mux.?rate" "$d/import.log" || echo "    (none recorded on import)"
	echo "  wire cadence:"
	sed 's/^/    /' "$d/arrival.txt" 2>/dev/null | head -12
}

run_arm new-cbr "$NEW" "$CLIP"
run_arm old-cbr "$OLD" "$CLIP"
run_arm new-vbr "$NEW" "$VBR"

echo
echo "=== $(date -u) done: $OUT ==="
