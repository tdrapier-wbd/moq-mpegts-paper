#!/usr/bin/env bash
# T13, wire domain: run each candidate grooming stage live and measure the
# cadence it puts on the socket, because a stream that is constant-rate *in the
# file* is not the same thing as a wire an IRD can lock to.
#
# One relay serves the whole run. Each variant gets its own port, its own
# broadcast and a fresh publisher, so a leg cannot inherit another's backlog, and
# the legs run one at a time so that CPU contention is not measured as jitter.
#
# Everything runs inside one invocation: background processes do not survive
# across separate shell invocations in this environment.
#
# Usage: t13-cadence.sh <moq> <moq-relay> <pacer-dir> <relay.toml> <source.ts> [window_s]

set -uo pipefail

MOQ="${1:?usage: t13-cadence.sh <moq> <moq-relay> <pacer-dir> <relay.toml> <src.ts> [window_s]}"
RELAY="${2:?}"
PACER_DIR="${3:?}"
RELAY_CONF="${4:?}"
SRC="${5:?}"
WINDOW="${6:-25}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/t13_cadence"
NOMINAL=9945951
SETTLE=6

# The pacer's egress adapter was renamed moq_egress -> ts_egress when it learned to
# groom a segmented-HTTP arrival pattern as well as a MoQ one (T16), then graduated from
# an example to the crate's binary, `mpegts-pacer`. Accept any of the three, so this rig
# runs against the build it was written for and against current heads.
PACER="$PACER_DIR/mpegts-pacer"
for candidate in mpegts-pacer ts_egress moq_egress; do
	if [[ -x "$PACER_DIR/$candidate" ]]; then
		PACER="$PACER_DIR/$candidate"
		break
	fi
done

for f in "$MOQ" "$RELAY" "$PACER"; do
	[[ -x "$f" ]] || {
		echo "not executable: $f" >&2
		exit 1
	}
done

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$RELAY_CONF" "$OUT/relay.toml"
cd "$OUT" || exit 1

RELAY_PID=""
PUBLISHER=""
CONTENT=""
cleanup() {
	[[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT

# --server-quic-gso=false is required on macOS loopback, where GSO stalls.
"$RELAY" relay.toml --server-quic-gso=false >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
sleep 4

FP=$(curl -s http://localhost:4443/certificate.sha256)
[[ -n "$FP" ]] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	exit 1
}
echo "relay up, fingerprint ${FP:0:16}..."

# The http:// fingerprint bootstrap is broken in these builds: connect over
# https:// and pin the fingerprint explicitly.
subscribe() {
	"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
		--client-quic-gso=false --broadcast "$1" export ts
}

publish() { # publish <broadcast> <logprefix>
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - \
		2>"$2.tsp.log" |
		"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
			--client-quic-gso=false --broadcast "$1" import ts \
			>"$2.pub.log" 2>&1 &
	PUBLISHER=$!
}

# The rate a groomer must pace at is the rate the egress actually carries, which is
# the source's mux rate less the stuffing MoQ does not send. Measure it here, from
# an ungroomed capture: taking it from a groomed leg reads back that leg's target,
# and pacing at the nominal rate makes a leg drain its join backlog for the whole
# window instead of reaching a steady state.
measure_content() {
	local bcast="t13-content.hang"
	publish "$bcast" "$OUT/content"
	sleep 2
	subscribe "$bcast" >"$OUT/content.ts" 2>"$OUT/content.sub.log" &
	local sub=$!
	sleep 12
	kill $sub "$PUBLISHER" 2>/dev/null
	pkill -f "broadcast $bcast" 2>/dev/null
	sleep "$SETTLE"
	CONTENT=$(python3 "$HERE/t13-grade.py" rate "$OUT/content.ts" 2>/dev/null)
	[[ -n "$CONTENT" && "$CONTENT" -gt 0 ]] || {
		echo "could not measure the egress content rate" >&2
		exit 1
	}
	echo "egress content rate: $CONTENT b/s (nominal $NOMINAL)"
}

run_variant() { # run_variant <name> <port> <rtp|udp> <groomer...>
	local name=$1 port=$2 kind=$3
	shift 3
	local bcast="t13-$port.hang"
	echo "=== $name (port $port)"

	python3 "$HERE/t13-cadence.py" capture "$port" "$OUT/$name" "$WINDOW" \
		"$([[ $kind == rtp ]] && echo rtp)" >"$OUT/$name.cap.log" 2>&1 &
	local capture=$!
	sleep 1

	subscribe "$bcast" 2>"$OUT/$name.sub.log" | "$@" >"$OUT/$name.groom.log" 2>&1 &
	local chain=$!
	sleep 2

	publish "$bcast" "$OUT/$name"

	wait $capture
	kill "$PUBLISHER" $chain 2>/dev/null
	pkill -f "broadcast $bcast" 2>/dev/null
	sleep "$SETTLE"
	cat "$OUT/$name.cap.log"
}

measure_content

# ffmpeg: constant-rate output, PIDs pinned back to the source assignment.
run_variant ffmpeg 5001 udp \
	ffmpeg -loglevel error -f mpegts -i pipe:0 -map 0 -copy_unknown -c copy \
	-muxrate "$NOMINAL" -mpegts_pmt_start_pid 4096 \
	-streamid 0:111 -streamid 1:121 -streamid 2:123 -streamid 3:131 \
	-streamid 4:141 -streamid 5:142 -streamid 6:143 \
	-f mpegts "udp://127.0.0.1:5001?pkt_size=1316"

# GStreamer: mpegtsmux pads to a constant rate, alignment=7 fills a 1316-byte
# datagram, and udpsink synchronises to the clock by default, so this leg tests
# whether that amounts to a paced wire.
GST_BRANCHES=()
while IFS= read -r token; do GST_BRANCHES+=("$token"); done < <(
	python3 "$HERE/t13-grade.py" gstbranches "$SRC" 2>/dev/null
)

run_variant gst 5004 udp \
	gst-launch-1.0 -q fdsrc fd=0 ! tsdemux name=d \
	mpegtsmux name=m bitrate="$NOMINAL" alignment=7 \
	! udpsink host=127.0.0.1 port=5004 \
	"${GST_BRANCHES[@]}"

# TSDuck: re-stamp PCR against the content rate, then pace at that rate.
run_variant tsduck 5002 udp \
	tsp --bitrate "$CONTENT" -I file - \
	-P pcradjust --bitrate "$CONTENT" \
	-P regulate --bitrate "$CONTENT" \
	-O ip 127.0.0.1:5002 --enforce-burst --packet-burst 7

# Control: the pacer's live path.
run_variant pacer 5003 rtp \
	"$PACER" 127.0.0.1:5003 "$NOMINAL" --rtp \
	--stall-ms 1000 --on-stall mute

echo
python3 "$HERE/t13-cadence.py" report "$OUT"/*.csv
echo
echo "captures in $OUT; grade the received streams with:"
echo "  python3 $HERE/t13-grade.py grade $OUT"
