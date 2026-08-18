#!/usr/bin/env bash
# T15 — the point-to-point transports on T14's cadence instrument.
#
#   t15-cadence.sh <src.ts> <out-dir> <capture-seconds> [leg]
#
#     rist-main    (default) TSDuck rist plugin, RIST Main profile
#     rist-simple             TSDuck rist plugin, RIST Simple profile
#     srt                     TSDuck srt plugin, matched 1000 ms latency
#     librist                 libRIST ristsender/ristreceiver, default output
#     librist-cbr             the same, with the receiver's `cbr-output=1`
#     udp                     plain UDP, no reliable transport — the control
#
# Run the `udp` leg before believing any of the others. It is the same TSDuck
# receive stage over a transport with no jitter buffer, no retransmission and no
# pacing of its own, so whatever cadence it shows is the *instrument's* — tsp's
# output batching and the pipe — rather than the protocol's. A protocol leg is
# only interesting where it differs from this control.
#
# It differs from nothing: measured, `udp` and `rist-main` are the same stream to
# within a millisecond, both landing on 92.1 kB bursts every ~73 ms. **That is
# tsp's output batching, and it is the floor of this instrument.** Any transport
# whose own bursts are finer than 92 kB is therefore unresolvable through a `tsp
# … -O file -` pipe, which is why the libRIST legs instrument the receiver's UDP
# datagrams directly (`t13-cadence.py capture`) instead. T14's arms are
# unaffected — arm A came out of `moq export ts` rather than tsp, and arm B1's
# 2.95 MB bursts sit 32× above this floor.
#
# The chain is deliberately the same shape as T14 arms A and B1: a live-rate
# publisher, a network hop, a reassembly stage, and the *same* cadence
# instrument on the ungroomed egress, read at the same 64 kB chunk. Grooming is
# not applied — the question is what the receive stage hands the groomer.
#
# Why two implementations of the same protocol. The TSDuck legs are symmetric
# with B1 and so are the ones the comparison table quotes. The libRIST legs
# exist because libRIST's UDP output carries `cbr-output`, which "space[s]
# receiver output at the stream's measured rate" — i.e. RIST can be asked to
# pace its own egress, and the two settings answer different questions:
# `librist` measures what a RIST receiver does by default, `librist-cbr`
# measures what it does when told to pace. TSDuck exposes no equivalent knob.
#
# Background processes do not survive between tool invocations in this
# environment, so publisher, tunnel and receiver all start and stop here. The
# publisher listens and the receiver calls, on every leg, so the ordering is the
# same throughout.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?capture seconds}
LEG=${4:-rist-main}
# Each leg gets its own port block: a listener socket from the previous leg can
# still be held when the next one starts, and the failure mode is a publisher that
# exits with "Address already in use" while the receiver waits for it forever.
case ${4:-rist-main} in
rist-main) PORT_OFFSET=0 ;;
rist-simple) PORT_OFFSET=10 ;;
srt) PORT_OFFSET=20 ;;
librist) PORT_OFFSET=30 ;;
librist-cbr) PORT_OFFSET=40 ;;
udp) PORT_OFFSET=50 ;;
udp-datagram) PORT_OFFSET=60 ;;
*) PORT_OFFSET=0 ;;
esac
PORT=${PORT:-$((18100 + PORT_OFFSET))}
BUFMS=${BUFMS:-1000}
# `regulate --pcr-synchronous` accumulates for at least --wait-min before releasing,
# so the *source* arrives in bursts of that many milliseconds. 50 ms is TSDuck's
# default and what every T14 arm was published with, which is why it is the default
# here: it keeps these legs comparable with T14's columns. It also puts a floor of
# ~92 kB under the whole rig (see the `udp` control), so set WAITMIN=5 for a second
# condition that can resolve what a transport adds below that.
WAITMIN=${WAITMIN:-50}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}

mkdir -p "$OUT"
PREFIX="$OUT/$LEG-egress"
[ "$WAITMIN" = 50 ] || PREFIX="$OUT/$LEG-w$WAITMIN-egress"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# The source half is identical on every leg and identical to T14: the file's own
# bytes, paced off their own PCR, so the cadence measured downstream is the
# transport's and not the reader's.
publish_to() {
	(
		sleep "${PUBLISH_DELAY:-0}"
		exec tsp --realtime \
			-I file "$SRC" --infinite \
			-P regulate --pcr-synchronous --wait-min "$WAITMIN" \
			"$@"
	) >"$OUT/$LEG-publish.log" 2>&1 &
	PUBLISHER=$!
	PIDS+=("$PUBLISHER")
}

# A dead publisher leaves the receiver blocking forever on a socket nobody will
# connect to, so check before committing to a capture window.
require_publisher() {
	kill -0 "$PUBLISHER" 2>/dev/null || {
		echo "publisher exited before the capture started:" >&2
		cat "$OUT/$LEG-publish.log" >&2
		exit 1
	}
}

case "$LEG" in
rist-main)
	publish_to -O rist --profile main "rist://@127.0.0.1:$PORT?buffer=$BUFMS"
	sleep 3
	require_publisher
	echo "capturing ${SECS}s over RIST main profile (buffer ${BUFMS} ms)..."
	RECEIVE=(tsp --realtime
		-I rist --profile main "rist://127.0.0.1:$PORT?buffer=$BUFMS"
		-O file -)
	;;
rist-simple)
	# Simple profile is RTP plus RTCP retransmission and has no tunnel, so
	# libRIST supports only receiver-listens / sender-calls. Asking the sender to
	# listen fails with a misleading "Address already in use" on a free port.
	# The roles therefore invert here: the receiver is the listener, and the
	# publisher is delayed so the foreground receiver is up before it calls.
	PUBLISH_DELAY=4
	publish_to -O rist --profile simple "rist://127.0.0.1:$PORT?buffer=$BUFMS"
	echo "capturing ${SECS}s over RIST simple profile (buffer ${BUFMS} ms)..."
	RECEIVE=(tsp --realtime
		-I rist --profile simple "rist://@127.0.0.1:$PORT?buffer=$BUFMS"
		-O file -)
	;;
udp)
	# `-I ip` takes a bare port for unicast; an address there means multicast.
	publish_to -O ip "127.0.0.1:$PORT"
	sleep 2
	require_publisher
	echo "capturing ${SECS}s over plain UDP (instrument control)..."
	RECEIVE=(tsp --realtime -I ip "$PORT" -O file -)
	;;
srt)
	publish_to -O srt --listener "127.0.0.1:$PORT" --latency "$BUFMS"
	sleep 3
	require_publisher
	echo "capturing ${SECS}s over SRT (latency ${BUFMS} ms)..."
	RECEIVE=(tsp --realtime
		-I srt --caller "127.0.0.1:$PORT" --latency "$BUFMS"
		-O file -)
	;;
udp-datagram)
	# The floor of the datagram instrument, for the libRIST legs below.
	publish_to -O ip "127.0.0.1:$((PORT + 2))"
	sleep 2
	require_publisher
	echo "capturing ${SECS}s of plain UDP datagrams (instrument control)..."
	INSTRUMENT=datagram
	;;
librist | librist-cbr)
	for tool in ristsender ristreceiver; do
		command -v "$tool" >/dev/null || {
			echo "$tool not found" >&2
			exit 1
		}
	done
	UPORT=$((PORT + 1)) # tsp -> ristsender
	OPORT=$((PORT + 2)) # ristreceiver -> tsp
	CBR=""
	[ "$LEG" = "librist-cbr" ] && CBR="?cbr-output=1"

	# Receiver first here: libRIST's own binaries do not retry a listener that
	# is not yet up, and this pair is caller (sender) -> listener (receiver).
	ristreceiver -p 1 -i "rist://@127.0.0.1:$PORT?buffer=$BUFMS" \
		-o "udp://127.0.0.1:$OPORT$CBR" \
		>"$OUT/$LEG-receiver.log" 2>&1 &
	PIDS+=($!)
	sleep 2
	ristsender -p 1 -i "udp://@127.0.0.1:$UPORT" \
		-o "rist://127.0.0.1:$PORT?buffer=$BUFMS" \
		>"$OUT/$LEG-sender.log" 2>&1 &
	PIDS+=($!)
	sleep 2
	publish_to -O ip "127.0.0.1:$UPORT"
	sleep 3
	require_publisher
	echo "capturing ${SECS}s over libRIST main profile (cbr-output=${CBR:+1}${CBR:-0})..."
	INSTRUMENT=datagram
	;;
*)
	echo "unknown leg: $LEG" >&2
	exit 1
	;;
esac

set +e
if [ "${INSTRUMENT:-pipe}" = datagram ]; then
	python3 "$SCRIPTS/t13-cadence.py" capture "$((PORT + 2))" "$PREFIX" "$SECS"
else
	"${RECEIVE[@]}" 2>"$OUT/$LEG-receive.log" |
		python3 "$SCRIPTS/t13-cadence.py" pipe "$PREFIX" "$SECS"
fi
set -e

echo
echo "=== cadence of the ungroomed egress: $LEG ==="
python3 "$SCRIPTS/t13-cadence.py" report "$PREFIX.csv"
echo
echo "artefacts in $OUT: $LEG-egress.{ts,csv} $LEG-publish.log $LEG-receive.log"
