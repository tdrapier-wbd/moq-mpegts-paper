#!/usr/bin/env bash
# T18 WAN — delivery latency over a real path: source on the origin, receiver here.
#
#   ORIGIN_IP=<host> PEM=<ssh-key> PACER=<mpegts-pacer> \
#     t18-wan.sh <out-dir> <capture-seconds> <arm> [cushion-ms]
#
# ORIGIN_IP, PEM and PACER are required and have no defaults, so this script
# carries no site-specific address. HOST defaults to ubuntu@$ORIGIN_IP and
# RELAY_URL to https://$ORIGIN_IP:443/anon; override either for a different origin.
#
# **The loopback sweep prices the buffers; this prices the path.** On loopback SRT
# and RIST cost exactly their configured jitter buffer and nothing else, which is a
# statement about a lossless link rather than about either protocol. Here the same
# instrument runs over the open internet, so what the tunnels' buffers are *for* is
# in play, and the question is whether the ordering the loopback sweep established
# survives a path with real RTT, real jitter and occasional loss.
#
# **The topology has to invert, and that is forced rather than chosen.** This
# receiver is behind NAT, so it cannot be called: on every arm the origin listens
# (or publishes to the relay) and the receiver calls. That is the arrangement the
# loopback rig could not use, because there the receive stage starts last and a
# listening source is never called inside SRT's connect timeout. Here the origin's
# source is started first over SSH and persists, so calling into it is correct.
#
# **Two clocks means the offset is part of the measurement.** A delivery latency
# taken from a timestamp on the origin and one here inherits whatever the two clocks
# disagree by, so the probe runs *before and after* every cell: the mean corrects the
# figure and the drift between them bounds it. A cell whose clock moved by more than
# it can tolerate is reported rather than quietly averaged.
set -euo pipefail

OUT=${1:?output dir}
SECS=${2:?capture seconds}
ARM=${3:?arm: srt|rist|moq|hls, or clock-up / clock-down}
CUSHION=${4:-1000}

ORIGIN_IP=${ORIGIN_IP:?set ORIGIN_IP to the origin host address}
HOST=${HOST:-ubuntu@$ORIGIN_IP}
PEM=${PEM:?set PEM to the SSH private key for the origin}
REMOTE_DIR=${REMOTE_DIR:-/home/ubuntu/t18}
REMOTE_SRC=${REMOTE_SRC:-/home/ubuntu/CNNiEMEA2.ts}
RELAY_URL=${RELAY_URL:-https://$ORIGIN_IP:443/anon}
BCAST=${BCAST:-t18.wan.hang}
MOQ=${MOQ:-$HOME/bin-main/moq}

VPID=${VPID:-111}
RATE=${RATE:-10000000}
BUFMS=${BUFMS:-1000}
MOQLAT=${MOQLAT:-3s}
SEGDUR=${SEGDUR:-2}
CAP=${CAP:-$((CUSHION + 500))}
STALL=${STALL:-$((CUSHION + 2000))}
SETTLE=${SETTLE:-30}
CLOCKPORT=${CLOCKPORT:-9010}
SSRC=${SSRC:-538968071}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACER=${PACER:?set PACER to the mpegts-pacer binary}

mkdir -p "$OUT"

# The clock reference is a *fixture*: started once by `clock-up`, reused by every
# cell, and only ever *probed* by a cell.
#
# **An SSH invocation does not return until the remote process it started has exited,
# whatever `nohup` and `setsid` are asked to do about it.** Launching a long-lived
# server from inside a cell therefore does not race — it hangs the cell for the
# server's whole lifetime, which is how an hour-long fixture stalled this script
# indefinitely. So the launch runs from a *locally* backgrounded SSH, where waiting is
# harmless, and it is a deliberate setup step rather than something a measurement does
# implicitly.
clock_up() {
	python3 "$SCRIPTS/t18-latency.py" clock-client "$ORIGIN_IP" "$CLOCKPORT" --samples 4 \
		>/dev/null 2>&1
}

clock_offset() {
	python3 "$SCRIPTS/t18-latency.py" clock-client "$ORIGIN_IP" "$CLOCKPORT" --samples 30 2>/dev/null
}

case "$ARM" in
srt) PORT=${PORT:-9011} ;;
rist) PORT=${PORT:-9012} ;;
moq) PORT=443 ;;
hls) PORT=${PORT:-8080} ;;
clock-up | clock-down) PORT=0 ;;
*)
	echo "unknown arm: $ARM" >&2
	exit 1
	;;
esac

SSH=(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -i "$PEM" "$HOST")
SCRIPTS_REMOTE="$REMOTE_DIR"

if [ "$ARM" = clock-down ]; then
	"${SSH[@]}" "pkill -f 't18-latency.py clock-server' && echo 'clock reference stopped' \
		|| echo 'no clock reference running'"
	exit 0
fi

if [ "$ARM" = clock-up ]; then
	scp -q -o BatchMode=yes -i "$PEM" "$SCRIPTS/t18-latency.py" "$HOST:$SCRIPTS_REMOTE/"
	if clock_up; then
		echo "clock reference already answering on $ORIGIN_IP:$CLOCKPORT"
		clock_offset
		exit 0
	fi
	# Backgrounded here, because the SSH will not return until the server exits.
	"${SSH[@]}" "cd $SCRIPTS_REMOTE && exec python3 t18-latency.py clock-server $CLOCKPORT \
		--seconds ${CLOCK_LIFETIME:-5400}" >"$OUT/clock.log" 2>&1 &
	for _ in $(seq 1 20); do
		sleep 1
		clock_up && break
	done
	clock_up || {
		echo "clock reference did not come up; see $OUT/clock.log" >&2
		exit 1
	}
	echo "clock reference up on $ORIGIN_IP:$CLOCKPORT for ${CLOCK_LIFETIME:-5400}s"
	clock_offset
	exit 0
fi

TAG="$ARM-c$CUSHION"
SRCCSV="$OUT/$TAG-source.csv"
EGCSV="$OUT/$TAG-egress.csv"
EPORT=${EPORT:-18305}

if pgrep -f 't18-latency.py tap' >/dev/null 2>&1; then
	echo "a t18 tap is already running locally; clear it first:" >&2
	pgrep -lf 't18-latency.py tap' >&2
	exit 1
fi

PIDS=()
set -m
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
	done
	# The origin's stages are killed by the process group the source script recorded,
	# never by name: the standing relay and publishers on that box are `moq` and `tsp`
	# processes too.
	"${SSH[@]}" "bash $REMOTE_DIR/t18-wan-source.sh $ARM $PORT $SECS $REMOTE_SRC $REMOTE_DIR stop" \
		>/dev/null 2>&1 || true
	wait 2>/dev/null || true
}
trap cleanup EXIT

echo "==> $ARM, cushion ${CUSHION} ms, ${SECS}s, over the WAN from $ORIGIN_IP"

# Sync the rig to the origin every run: a stale copy there is indistinguishable from
# a rig change here, and only one of the two is under version control.
scp -q -o BatchMode=yes -i "$PEM" \
	"$SCRIPTS/t18-latency.py" "$SCRIPTS/t18-wan-source.sh" "$HOST:$REMOTE_DIR/"

echo "--- clock, before ---"
clock_up || {
	echo "no clock reference on $ORIGIN_IP:$CLOCKPORT — an absolute two-host latency" >&2
	echo "cannot be quoted. Start one first:  t18-wan.sh $OUT 0 clock-up" >&2
	exit 1
}
BEFORE=$(clock_offset)
echo "$BEFORE"
OFF1=$(echo "$BEFORE" | awk '/offset_s/{print $2}')
UNC1=$(echo "$BEFORE" | awk '/uncertainty_s/{print $2}')
[ -n "${OFF1:-}" ] || {
	echo "clock probe failed; cannot quote an absolute latency" >&2
	exit 1
}

echo "--- starting the origin's source ---"
"${SSH[@]}" "VPID=$VPID BUFMS=$BUFMS SEGDUR=$SEGDUR RELAY_URL=$RELAY_URL BCAST=$BCAST \
	bash $REMOTE_DIR/t18-wan-source.sh $ARM $PORT $SECS $REMOTE_SRC $REMOTE_DIR start"

case "$ARM" in
srt) RECEIVE=(tsp --realtime -I srt --caller "$ORIGIN_IP:$PORT" --latency "$BUFMS" -O file -) ;;
rist) RECEIVE=(tsp --realtime -I rist --profile main "rist://$ORIGIN_IP:$PORT?buffer=$BUFMS" -O file -) ;;
moq)
	RECEIVE=("$MOQ" --client-tls-disable-verify --client-connect "$RELAY_URL"
		--broadcast "$BCAST" export ts --latency-max "$MOQLAT")
	;;
hls)
	# `tsp -I hls` exits on an empty playlist, so wait for the origin's live window.
	for _ in $(seq 1 60); do
		curl -sf --max-time 3 "http://$ORIGIN_IP:$PORT/index.m3u8" 2>/dev/null | grep -qc 'seg.*\.ts' && break
		sleep 1
	done
	RECEIVE=(tsp --realtime -I hls --live "http://$ORIGIN_IP:$PORT/index.m3u8" -O file -)
	;;
esac

groom=(
	"$PACER" "127.0.0.1:$EPORT" "$RATE" --rtp --ssrc "$SSRC"
	--latency-ms "$CUSHION" --max-latency-ms "$CAP"
	--stall-ms "$STALL" --on-stall mute
)

python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$EGCSV" --udp "$EPORT" --rtp --seconds "$SECS" \
	--save "$OUT/$TAG-egress.ts" >"$OUT/$TAG-tap.log" 2>&1 &
TAP=$!
PIDS+=("$TAP")
sleep 1

set +e
timeout "$((SECS + 2))" "${RECEIVE[@]}" 2>"$OUT/$TAG-receive.log" |
	"${groom[@]}" >"$OUT/$TAG-groom.log" 2>&1
wait "$TAP" 2>/dev/null
set -e

echo "--- clock, after ---"
AFTER=$(clock_offset)
echo "$AFTER"
OFF2=$(echo "$AFTER" | awk '/offset_s/{print $2}')
OFF2=${OFF2:-$OFF1}
OFFSET=$(python3 -c "print(f'{(($OFF1)+($OFF2))/2:.6f}')")
DRIFT=$(python3 -c "print(f'{abs(($OFF2)-($OFF1))*1000:.2f}')")
echo "    offset used ${OFFSET}s, drift across the cell ${DRIFT} ms, probe uncertainty $(python3 -c "print(f'{($UNC1)*1000:.2f}')") ms"

echo "--- fetching the origin's source timestamps ---"
scp -q -o BatchMode=yes -i "$PEM" "$HOST:$REMOTE_DIR/$ARM-source.csv" "$SRCCSV"

echo
echo "=== wire conformance of the same bytes ==="
if [ -s "$OUT/$TAG-egress.ts" ]; then
	CC=$(tsp -I file "$OUT/$TAG-egress.ts" -P continuity -O drop 2>&1 | grep -c 'discontinuity' || true)
	JIT=$(tsp -I file "$OUT/$TAG-egress.ts" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		sed -n 's/.*OK, *\([0-9,]*\) with jitter.*/\1/p' | tr -d ',')
	tsp -I file "$OUT/$TAG-egress.ts" -P pcrextract --pcr --csv \
		-o "$OUT/$TAG-pcr.csv" -O drop >/dev/null 2>&1 || true
	REP=$(awk -F, 'NR>1 && $4=="PCR"{c=$6;if(p!=""){d=(c-p)/27000;n++;if(d>40)o++;if(d>mx)mx=d}p=c}
		END{printf "%d,%d,%.1f", o+0, n+0, mx+0}' "$OUT/$TAG-pcr.csv")
	REP_OVER=${REP%%,*}
	REP_MAX=${REP##*,}
	REP_TOTAL=$(echo "$REP" | cut -d, -f2)
	echo "   continuity errors $CC, PCR jitter >481 ns ${JIT:-?}," \
		"repetition >40 ms ${REP_OVER}/${REP_TOTAL}, max ${REP_MAX} ms"
else
	echo "   no egress stream captured"
fi

echo
echo "=== delivery latency: $ARM at a ${CUSHION} ms cushion, over the WAN ==="
python3 "$SCRIPTS/t18-latency.py" report "$SRCCSV" "$EGCSV" \
	--label "$ARM c=${CUSHION}ms wan" --clock-offset "$OFFSET" --settle "$SETTLE" \
	--kv "$OUT/$TAG.kv"

SUMMARY="$OUT/summary.csv"
[ -s "$SUMMARY" ] || echo "arm,cushion_ms,cap_ms,matched,seen,shift,lat_min,lat_median,lat_p95,lat_max,trend_head,trend_tail,window_s,cc_errors,pcr_jitter_over,rep_over,rep_total,rep_max_ms,clock_offset_s,clock_drift_ms,clock_unc_ms" >"$SUMMARY"
if [ -s "$OUT/$TAG.kv" ]; then
	# shellcheck source=/dev/null
	. "$OUT/$TAG.kv"
	# shellcheck disable=SC2154
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$ARM" "$CUSHION" "$CAP" "$matched" "$seen" "$shift" \
		"$lat_min" "$lat_median" "$lat_p95" "$lat_max" \
		"$trend_head" "$trend_tail" "$window" \
		"${CC:-}" "${JIT:-}" "${REP_OVER:-}" "${REP_TOTAL:-}" "${REP_MAX:-}" \
		"$OFFSET" "$DRIFT" "$(python3 -c "print(f'{($UNC1)*1000:.2f}')")" \
		>>"$SUMMARY"
fi

echo
echo "artefacts in $OUT: $TAG-*"
