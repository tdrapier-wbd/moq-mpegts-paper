#!/usr/bin/env bash
# T11d: moq2ts's headless publisher and console receiver against moq-dev, draft 22, loopback.
# usage: t11d-arm.sh <out-dir> <A|B|C|D> [passthrough|demux]
#   A  moq2ts-cli --unmodified -> moq-relay  -> moq2ts-receiver
#   B  moq2ts-cli --unmodified -> moq5-relay -> moq2ts-receiver
#   C  moq import ts           -> moq-relay  -> moq2ts-receiver (passthrough or demux)
#   D  moq2ts-cli --unmodified -> moq-relay  -> moq export ts
# env: MOQ (moq-dev bin dir: moq, moq-relay), RELAY5 (moq5-relay, B only), CLI (moq2ts-cli),
#      RECV (moq2ts-receiver), CLIP (source TS), PCRT (ts-pcr-timing.py), PORT (default 4433),
#      SECS (receiver window, default 130), SEG (moq2ts-cli object bytes, default 310764),
#      TRACK (names the receiver's track out of band, bypassing catalog discovery)
# The receiver's output is teed into ts-pcr-timing.py --live, which stamps arrivals.
set -u
OUT=$1 ARM=$2 MODE=${3:-passthrough}
MOQ=${MOQ:?} CLI=${CLI:?} RECV=${RECV:?} CLIP=${CLIP:?} PCRT=${PCRT:?}
PORT=${PORT:-4433} SECS=${SECS:-130} NAME=t11d.msf
mkdir -p "$OUT" && cd "$OUT" || exit 1
url="moqt://127.0.0.1:$PORT"

if [ "$ARM" = B ]; then
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
		-keyout key.pem -out cert.pem -subj /CN=localhost \
		-addext subjectAltName=IP:127.0.0.1,DNS:localhost 2>/dev/null
	cat >relay.json <<EOF
{
  "listener": { "host": "127.0.0.1", "port": $PORT, "versions": [22], "lanes": 1,
                "cert": "cert.pem", "key": "key.pem" },
  "budgets": { "max_tracks": 256, "max_subs": 1024, "max_bindings": 64,
               "log": { "max_groups": 8, "max_bytes": 8388608, "max_age_us": 0 },
               "log_max_subgroups": 16, "log_max_objects": 4096, "log_max_cursors": 64,
               "log_max_chunk_nodes": 8192,
               "cross_shard": { "demand_channel_entries": 64, "demand_channel_bytes": 8388608 } },
  "logging": { "format": "text" },
  "auth": { "mode": "allow_all" }
}
EOF
	"$RELAY5" serve --config relay.json >relay.log 2>&1 &
else
	cat >relay.toml <<EOF
[log]
level = "info"

[listen]
bind = "127.0.0.1:$PORT"
tls.generate = ["localhost"]

[auth]
public = "**"
EOF
	"$MOQ/moq-relay" relay.toml --quic-gso=false >relay.log 2>&1 &
fi
relay=$!
sleep 1

case $ARM in
C)
	flags=()
	[ "$MODE" = passthrough ] && flags=(--passthrough)
	tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>tsp.log |
		"$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version moq-transport-22 \
			--broadcast "$NAME" import ts "${flags[@]}" >send.log 2>&1 &
	;;
*)
	# --paced releases one object per --fragment-ms whatever it holds, so an object must hold
	# 250 ms of the clip: SEG = clip rate / 8 / 4, in whole packets (310,764 for 9.95 Mb/s).
	"$CLI" --endpoint "$url" --namespace "$NAME" --video "$CLIP" --unmodified --paced --draft 22 \
		--fragment-ms 250 --segment-bytes "${SEG:-310764}" >send.log 2>&1 &
	;;
esac
send=$!
sleep 3
case $ARM in
D)
	timeout "$SECS" "$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version moq-transport-22 \
		--broadcast "$NAME" export ts 2>recv.log | tee out.ts |
		python3 "$PCRT" --live --seconds "$SECS" --report-json release.json >release.txt 2>&1 &
	;;
*)
	track=()
	[ -n "${TRACK:-}" ] && track=(--track "$TRACK")
	"$RECV" --url "$url" --namespace "$NAME" "${track[@]}" --out - --duration "$SECS" --insecure \
		--stats-json stats.json 2>recv.log | tee out.ts |
		python3 "$PCRT" --live --seconds "$SECS" --report-json release.json >release.txt 2>&1 &
	;;
esac
recv=$!

if [ "$ARM" = A ] || [ "$ARM" = B ]; then
	wait "$send"
	echo "SEND_RC=$?" >rc.txt
	wait "$recv"
	echo "RECV_PIPE_RC=$?" >>rc.txt
else # a discovery arm: the subscriber's window decides, then the publisher is stopped
	wait "$recv"
	echo "RECV_PIPE_RC=$?" >rc.txt
	kill "$send" 2>/dev/null
	wait "$send"
	echo "SEND_RC=$? (stopped)" >>rc.txt
fi
kill "$relay" 2>/dev/null
wait "$relay" 2>/dev/null
ls -l out.ts >>rc.txt
