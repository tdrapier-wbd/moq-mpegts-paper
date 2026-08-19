#!/usr/bin/env bash
# T18 WAN — the source half, run *on the origin host*.
#
#   t18-wan-source.sh <arm> <port> <seconds> <src.ts> <out-dir> start|stop
#
# **This exists as its own script because of how the origin has to be torn down.**
# The origin is a shared box running a standing relay and two standing publishers,
# all of which are `moq` and `tsp` and `ffmpeg` processes — so a teardown that
# matches on process name takes the deployment down with it. Every stage here is
# started under `setsid`, and `start` prints the resulting process-group id for the
# caller to keep; `stop` kills that group and nothing else.
#
# The source chain is identical to the loopback rig's: the file's own bytes paced
# off their own PCR, tapped once before anything transport-specific sees them, so
# both halves of the WAN measurement share one definition of "when this picture
# left". The tap writes the timestamps this host owns; the caller fetches them.
set -euo pipefail

ARM=${1:?arm}
PORT=${2:?port}
SECS=${3:?seconds}
SRC=${4:?source .ts}
OUT=${5:?output dir}
ACTION=${6:-start}

VPID=${VPID:-111}
WAITMIN=${WAITMIN:-5}
BUFMS=${BUFMS:-1000}
SEGDUR=${SEGDUR:-2}
RELAY_URL=${RELAY_URL:-}
BCAST=${BCAST:-t18.wan.hang}
MOQ=${MOQ:-/home/ubuntu/bin-main-eab96019/moq}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PGIDF="$OUT/$ARM.pgid"

if [ "$ACTION" = stop ]; then
	if [ -s "$PGIDF" ]; then
		PGID=$(cat "$PGIDF")
		# Negative pid means the group. Only ever the group this script created.
		kill -TERM -- "-$PGID" 2>/dev/null || true
		sleep 1
		kill -KILL -- "-$PGID" 2>/dev/null || true
		rm -f "$PGIDF"
		echo "stopped pgid $PGID"
	else
		echo "no pgid file; nothing to stop"
	fi
	exit 0
fi

mkdir -p "$OUT"
SRCCSV="$OUT/$ARM-source.csv"
rm -f "$SRCCSV"

# Runs a little past the receiver's window: a source that stops first turns the tail
# of the measurement into a drain rather than a steady state.
RUN=$((SECS + 25))

case "$ARM" in
srt)
	EGRESS=(tsp --realtime -I file - -O srt --listener "0.0.0.0:$PORT" --latency "$BUFMS")
	;;
rist)
	EGRESS=(tsp --realtime -I file - -O rist --profile main "rist://@0.0.0.0:$PORT?buffer=$BUFMS")
	;;
moq)
	: "${RELAY_URL:?set RELAY_URL to the relay, e.g. https://<EC2_IP>:443/anon}"
	EGRESS=("$MOQ" --client-tls-disable-verify --client-connect "$RELAY_URL"
		--broadcast "$BCAST" import ts)
	;;
hls)
	HDIR="$OUT/hls"
	rm -rf "$HDIR"
	mkdir -p "$HDIR"
	EGRESS=(tsp --realtime -I file - -O hls --live 6 --live-extra-segments 3
		--duration "$SEGDUR" --intra-close --align-first-segment
		--playlist "$HDIR/index.m3u8" "$HDIR/seg.ts")
	;;
*)
	echo "unknown arm: $ARM" >&2
	exit 1
	;;
esac

# Single-quoted on purpose: every value the inner shell needs is passed positionally,
# so the outer shell cannot mangle a path or a plugin argument on the way in.
# shellcheck disable=SC2016
setsid bash -c '
	set -o pipefail
	ARM="$1"; PORT="$2"; RUN="$3"; SRC="$4"; OUT="$5"; SRCCSV="$6"
	VPID="$7"; WAITMIN="$8"; SCRIPTS="$9"; shift 9
	if [ "$ARM" = hls ]; then
		( cd "$OUT/hls" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 ) \
			>"$OUT/$ARM-http.log" 2>&1 &
	fi
	timeout "$RUN" tsp --realtime -I file "$SRC" --infinite \
		-P regulate --pcr-synchronous --wait-min "$WAITMIN" \
		-O file - \
		| timeout "$RUN" python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$SRCCSV" \
			--pipe --seconds "$RUN" \
		| timeout "$RUN" "$@"
' _ "$ARM" "$PORT" "$RUN" "$SRC" "$OUT" "$SRCCSV" "$VPID" "$WAITMIN" "$SCRIPTS" \
	"${EGRESS[@]}" >"$OUT/$ARM-send.log" 2>&1 </dev/null &

PGID=$!
echo "$PGID" >"$PGIDF"
sleep 4
# A source that has already exited cannot be measured, and the failure is silent
# from the far end: the receiver simply waits.
if ! kill -0 "$PGID" 2>/dev/null; then
	echo "source exited immediately; log follows:" >&2
	cat "$OUT/$ARM-send.log" >&2
	exit 1
fi
echo "started pgid $PGID"
