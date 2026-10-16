#!/usr/bin/env bash
# T11c direction 1: `moq import ts` through moq5-relay into `moq export ts`, on loopback.
# usage: t11c-d1.sh <out-dir> <draft: 16|18|22> <passthrough|demux>
# env: MOQ (moq-dev bin dir), RELAY (moq5-relay binary), CLIP (source TS), PORT (default 4433)
set -u
OUT=$1 DRAFT=$2 MODE=$3
PORT=${PORT:-4433}
mkdir -p "$OUT" && cd "$OUT" || exit 1

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
relay=$!
sleep 1

dial=(--connect-tls-insecure --connect "moqt://127.0.0.1:$PORT" --connect-version "moq-transport-$DRAFT")
flags=()
[ "$MODE" = passthrough ] && flags=(--passthrough)

tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>tsp.log |
	RUST_LOG=info "$MOQ/moq" "${dial[@]}" --broadcast t11c import ts "${flags[@]}" >import.log 2>&1 &
import=$!
sleep 3
RUST_LOG=info "$MOQ/moq" "${dial[@]}" --broadcast t11c export ts >out.ts 2>export.log &
export=$!

wait "$import"
echo "IMPORT_RC=$?" >rc.txt
sleep 5
kill "$export" 2>/dev/null
wait "$export" 2>/dev/null
kill "$relay" 2>/dev/null
wait "$relay" 2>/dev/null
ls -l out.ts >>rc.txt
