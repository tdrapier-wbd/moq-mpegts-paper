#!/usr/bin/env bash
# T3 opaque `m2ts` lane — one clip, one invocation, ungroomed egress captured.
#
#   t3-opaque-lane.sh <src.ts> <out-dir> [media_seconds]
#
# tsp regulate -> moq_publisher (TCP ingest) -> moq_relay -> moq_subscriber
# -> TCP playout -> file.
#
# T3's opaque arm was originally hand-run from a documented command sequence, which
# is why its P2 PCR-accuracy cell could not simply be re-graded: the private
# checkout had gone and no capture survived. This rig exists so that arm is
# reproducible from the source tree rather than from a shell history.
#
# !! DOES NOT YET PRODUCE A CAPTURE — the MoQ half works and the egress half does
# !! not. The publisher, relay and subscriber all connect, the subscriber accepts
# !! the playout reader and reports `bytes_out` climbing at ~10 Mb/s, and **zero
# !! bytes arrive at the reader**. Reproduced four ways on a macOS build of the
# !! EC2 source at its own `Cargo.lock`: TCP passthrough with `--no-pacing`, TCP
# !! passthrough paced, UDP passthrough, and TCP `--egress-profile broadcast
# !! --mux-rate 12000000`. `lsof` confirms a single ESTABLISHED pair and the
# !! subscriber logs no write error; the reader sees EOF only when the stream ends.
# !! Not yet attributed: it could be a defect in this build or something specific
# !! to building it on macOS, and the discriminator is to run the same chain with
# !! the Linux binaries already on EC2. Until then the ordering and capture logic
# !! below is the useful part, and the P2 cell stays open.
#
# The measurement point is the *ungroomed* egress, matching both the segmented-HTTP
# arm and T3's original opaque runs, which used `--no-pacing` because `tsp regulate`
# already delivers the source in real time and the subscriber's own pacer would
# double-pace it.
#
# Bounded by PACKET COUNT, not wall clock, and by the same count the segmented arm
# uses. That matters more than it looks: the headline figure here is a *maximum*
# (the tightest clean `pcrverify --absolute` bound), and a maximum over more media
# can only grow — so a figure taken over a different window is not comparable with
# the source reference or with the other lanes.
#
# Background processes do not survive between tool invocations in this environment,
# so relay, subscriber, listener and publisher are all started and torn down here.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:-60}
BIN=${BIN:-/tmp/opaque-target/release}
INGEST_PORT=${INGEST_PORT:-5001}
PLAYOUT_PORT=${PLAYOUT_PORT:-5002}
RELAY_PORT=${RELAY_PORT:-4443}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for b in moq_relay moq_publisher moq_subscriber; do
	[ -x "$BIN/$b" ] || {
		echo "missing $BIN/$b — build with: cd ~/moq-opaque && \\" >&2
		echo "  CARGO_TARGET_DIR=/tmp/opaque-target cargo build --release --locked" >&2
		exit 1
	}
done
[ -f "$SRC" ] || {
	echo "no such source: $SRC" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"

# --- window: how many packets is $SECS of this clip, on its own PCR timeline? ---
SRCBPS=$(tsp -I file "$SRC" -P until --packets 200000 -P analyze --normalized -O drop 2>/dev/null |
	sed -n 's/^ts:.*:pcrbitrate=\([0-9]*\):.*/\1/p' | head -1)
[ -n "$SRCBPS" ] || {
	echo "could not derive source PCR bitrate" >&2
	exit 1
}
NPKT=$((SRCBPS * SECS / 8 / 188))
echo "source ${SRCBPS} b/s (PCR-derived); ${SECS}s = ${NPKT} packets"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- relay -------------------------------------------------------------------
# Its own config is copied into the run dir so the source tree stays untouched.
cp ~/moq-opaque/relay.toml "$OUT/relay.toml"
sed -i '' "s/4443/$RELAY_PORT/g" "$OUT/relay.toml"
(cd "$OUT" && exec "$BIN/moq_relay" relay.toml) >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 3

FP=$(curl -s "http://localhost:$RELAY_PORT/certificate.sha256" || true)
[ -n "$FP" ] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	tail -5 "$OUT/relay.log" >&2
	exit 1
}
echo "relay up on $RELAY_PORT (fingerprint ${FP:0:16}...)"

# --- subscriber, before the publisher ----------------------------------------
# Reservation gating publishes the catalog once tracks resolve, so a subscriber
# that joins first sees the whole broadcast rather than only a catalog.
#
# On TCP playout the subscriber is the *server*: it binds the playout port and
# waits for a reader ("listening for FFplay"). So the capture connects to it, and
# a listener of our own on the same port only fights it for the bind.
"$BIN/moq_subscriber" "https://localhost:$RELAY_PORT/anon" \
	--broadcast mpegts --track ts \
	--output-protocol tcp \
	--output-host 127.0.0.1 --output-port "$PLAYOUT_PORT" \
	--no-pacing --no-log \
	>"$OUT/sub.log" 2>&1 &
PIDS+=($!)
sleep 2

# --- publisher ----------------------------------------------------------------
"$BIN/moq_publisher" "https://localhost:$RELAY_PORT/anon" \
	--ingest-bind "127.0.0.1:$INGEST_PORT" \
	--broadcast mpegts --track ts \
	>"$OUT/pub.log" 2>&1 &
PIDS+=($!)
sleep 2

# --- feed the RAW source, PCR-paced, into the publisher's TCP ingest ----------
# Backgrounded, because the three stages gate each other in a fixed order that
# cost several empty captures to establish: the publisher does not announce until
# its ingest source connects, the subscriber does not accept a reader until it has
# an announced track, and the reader must be attached before the subscriber will
# emit. So the feed has to start first and the reader attaches into a live chain.
#
# Not an ffmpeg remux: `ffmpeg -c copy` regenerates the container, strips null
# padding and rewrites PCR cadence, and would be measured as the lane's doing.
echo "feeding ${NPKT} packets..."
(tsp -I file "$SRC" -P regulate --pcr-synchronous -P until --packets "$NPKT" -O file - \
	2>"$OUT/tsp.log" | nc 127.0.0.1 "$INGEST_PORT") >"$OUT/feed.log" 2>&1 &
PIDS+=($!)

# --- wait until the subscriber is actually waiting for a reader ----------------
# A reader that connects while the subscriber is still resolving the broadcast is
# accepted and then dropped when its loop resets, so `recv` returns EOF at once and
# the capture is silently empty. Waiting for this line puts the connect inside the
# window where it is served.
echo "waiting for the subscriber to reach its accept..."
for _ in $(seq 1 60); do
	if rg -q 'Waiting for local FFplay to connect' "$OUT/sub.log" 2>/dev/null; then
		break
	fi
	sleep 1
done
rg -q 'Waiting for local FFplay to connect' "$OUT/sub.log" 2>/dev/null || {
	echo "subscriber never reached its accept; see $OUT/sub.log" >&2
	exit 1
}

# --- egress capture, connected BEFORE the feed starts -------------------------
# The subscriber holds output until a reader attaches, so a capture started after
# the feed loses the head of the stream. TCP playout is always 188-aligned;
# TSDuck's UDP `ip` input silently drops non-aligned datagrams, which is why this
# arm captures over TCP.
#
# Read with python rather than `nc`: BSD `nc` also forwards its own stdin, and in
# the background stdin is at EOF, so it tears the connection down and discards the
# socket data — the subscriber logs a clean hand-off and 12 MB sent while the
# capture file stays 0 bytes. This reader also stops at an exact packet count,
# which is what makes the window comparable with the other arms.
# Writes unbuffered and stops on an idle timeout as well as on the packet target:
# an exact byte target alone deadlocks if the lane delivers one packet fewer than
# asked, and a buffered writer killed at teardown loses everything it held.
python3 -c '
import socket, sys
host, port, path, want = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
s = socket.create_connection((host, port))
# Generous, because the subscriber does not emit the moment it accepts: it holds a
# decoder start gate (256 frames) and an output buffer that defaults to 1000 ms, so
# a short idle timeout expires during normal startup and reports an empty capture.
s.settimeout(20.0)
got = 0
with open(path, "wb", buffering=0) as f:
    while got < want * 188:
        try:
            b = s.recv(1 << 16)
        except socket.timeout:
            print("idle 20s, stopping at %d packets" % (got // 188), file=sys.stderr)
            break
        if not b:
            break
        f.write(b)
        got += len(b)
print("captured %d packets (%d bytes)" % (got // 188, got), file=sys.stderr)
s.close()
' 127.0.0.1 "$PLAYOUT_PORT" "$OUT/egress.ts" "$NPKT" 2>"$OUT/capture.log" &
CAP_PID=$!
PIDS+=("$CAP_PID")

# Let the reader drain to its packet target before teardown. The bound is the media
# window plus the subscriber's own buffer, not a fixed few seconds.
for _ in $(seq 1 $((SECS + 60))); do
	kill -0 "$CAP_PID" 2>/dev/null || break
	sleep 1
done
cleanup
trap - EXIT

{
	echo "source_pcrbitrate=$SRCBPS"
	echo "packets_fed=$NPKT"
	echo "media_seconds=$SECS"
	echo "egress_packets=$(($(stat -f%z "$OUT/egress.ts") / 188))"
} >"$OUT/run.env"

[ -s "$OUT/egress.ts" ] || {
	echo "no egress captured; see $OUT/sub.log and $OUT/pub.log" >&2
	exit 1
}
echo "egress: $(stat -f%z "$OUT/egress.ts") bytes"

# --- source reference over the SAME packet count -----------------------------
tsp -I file "$SRC" -P until --packets "$NPKT" -O file "$OUT/source-ref.ts" >/dev/null 2>&1

echo
python3 "$SCRIPTS/t3-transparency.py" "$OUT/source-ref.ts" "$OUT/egress.ts" \
	--label "$(basename "$SRC" .ts) (opaque)" --run-env "$OUT/run.env" | tee "$OUT/report.txt"

echo
echo "artefacts in $OUT: egress.ts source-ref.ts report.txt run.env"
