#!/usr/bin/env bash
# T11c directions 2-4, and the harness's own loop, on loopback.
# usage: t11c-arm.sh <out-dir> <loop|d2|d3|d4> <draft: 16|18|22> [passthrough|demux]
#   loop  t11c-moq5-ts send -> moq5-relay -> t11c-moq5-ts recv
#   d2    t11c-moq5-ts send -> moq-relay  -> t11c-moq5-ts recv
#   d3    moq import ts     -> moq-relay  -> t11c-moq5-ts recv (passthrough or demux)
#   d4    t11c-moq5-ts send -> moq-relay  -> moq export ts
# env: MOQ (moq-dev bin dir: moq, moq-relay), RELAY (moq5-relay, loop only),
#      TS (t11c-moq5-ts binary), CLIP (source TS), PORT (default 4433),
#      LOG (moq-dev's RUST_LOG, default info), RLOG (moq-relay's log level, default info),
#      NAME (broadcast name, default t11c; moq-dev reads a `.msf` suffix as an MSF catalog),
#      HOLD=1 (the moq5 sender queues pre-subscriber media instead of dropping it)
set -u
OUT=$1 DIR=$2 DRAFT=$3 MODE=${4:-passthrough}
PORT=${PORT:-4433} LOG=${LOG:-info} RLOG=${RLOG:-info} NAME=${NAME:-t11c}
mkdir -p "$OUT" && cd "$OUT" || exit 1
url="moqt://127.0.0.1:$PORT"
dial=(--connect-tls-insecure --connect "$url" --connect-version "moq-transport-$DRAFT")

if [ "$DIR" = loop ]; then
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
		-keyout key.pem -out cert.pem -subj /CN=localhost \
		-addext subjectAltName=IP:127.0.0.1,DNS:localhost 2>/dev/null
	cat >relay.json <<EOF
{
  "listener": { "host": "127.0.0.1", "port": $PORT, "versions": [$DRAFT], "lanes": 1,
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
	"$RELAY" serve --config relay.json >relay.log 2>&1 &
else
	cat >relay.toml <<EOF
[log]
level = "$RLOG"

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

paced() { tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>tsp.log; }
case $DIR in
d3)
	flags=()
	[ "$MODE" = passthrough ] && flags=(--passthrough)
	paced | RUST_LOG=$LOG "$MOQ/moq" "${dial[@]}" --broadcast "$NAME" import ts "${flags[@]}" >send.log 2>&1 &
	;;
*)
	hold=()
	[ "${HOLD:-0}" = 1 ] && hold=(--hold)
	paced | "$TS" send "$url" "$NAME" ts --draft "$DRAFT" "${hold[@]}" >send.log 2>&1 &
	;;
esac
send=$!
sleep 3
case $DIR in
d4) RUST_LOG=$LOG "$MOQ/moq" "${dial[@]}" --broadcast "$NAME" export ts >out.ts 2>recv.log & ;;
*) "$TS" recv "$url" "$NAME" --draft "$DRAFT" --log objects.csv >out.ts 2>recv.log & ;;
esac
recv=$!

wait "$send"
echo "SEND_RC=$?" >rc.txt
sleep 5
kill "$recv" 2>/dev/null
wait "$recv"
echo "RECV_RC=$?" >>rc.txt
kill "$relay" 2>/dev/null
wait "$relay" 2>/dev/null
ls -l out.ts >>rc.txt
