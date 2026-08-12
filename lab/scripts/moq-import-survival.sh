#!/usr/bin/env bash
# Does `moq import ts` survive this source? One arm of a before/after demuxer comparison.
#
# Starts a private relay, attaches a subscriber, feeds the source through an importer, and
# reports whether the importer was still alive at the deadline - plus its exit status and
# first error line, which is what distinguishes "died on the source" from "reached EOF".
#
# Built for moq-dev/moq#2751 (audio resync). The useful shape is to run it twice, once per
# binary, against a source damaged by ts-corrupt-header.py:
#
#   MOQ=/path/to/0.9.4/moq bash moq-import-survival.sh pre  damaged.ts once 45
#   MOQ=/path/to/0.9.5/moq bash moq-import-survival.sh post damaged.ts once 45
#
# `loop` feeds the source with `--infinite`, which is how a wrap that lands mid-frame gets
# exercised; `once` plays it through and exits, so "exited at the clip length with rc=0" is
# a pass rather than a failure.
#
# usage: moq-import-survival.sh <label> <source.ts> [once|loop] [seconds]
# env:   MOQ, RELAY (binary paths), PORT, OUT
set -uo pipefail
LABEL=$1; SRC=$2; LOOP=${3:-once}; SECS=${4:-60}
: "${MOQ:?set MOQ to the moq binary under test}"
: "${RELAY:?set RELAY to the moq-relay binary}"
PORT=${PORT:-7861}
OUT=${OUT:-/tmp/moq-import-survival}; mkdir -p "$OUT"
BCAST="survival.$LABEL.hang"
URL="https://localhost:$PORT/anon"

SUB_PID=""; PUB_PID=""; RELAY_PID=""
cleanup(){ for p in $SUB_PID $PUB_PID $RELAY_PID; do
    [ -n "${p:-}" ] && { pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; }; done; }
trap cleanup EXIT INT TERM

# --*-quic-gso=false is required on macOS loopback and harmless elsewhere.
"$RELAY" --server-bind 127.0.0.1:$PORT --tls-generate localhost --auth-public "" \
  --server-quic-gso=false >"$OUT/$LABEL.relay.log" 2>&1 & RELAY_PID=$!
sleep 3

"$MOQ" --client-tls-disable-verify --client-quic-gso=false --client-connect "$URL" \
  --broadcast "$BCAST" export ts >"$OUT/$LABEL.sub.ts" 2>"$OUT/$LABEL.sub.log" & SUB_PID=$!
sleep 2

if [ "$LOOP" = loop ]; then FEED=(tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file -)
else FEED=(tsp -I file "$SRC" -P regulate --pcr-synchronous -O file -); fi

# Both stages in one subshell so the status recorded is the importer's, not tsp's.
( "${FEED[@]}" 2>"$OUT/$LABEL.tsp.log" \
  | "$MOQ" --client-tls-disable-verify --client-quic-gso=false --client-connect "$URL" \
      --broadcast "$BCAST" import ts >"$OUT/$LABEL.pub.log" 2>&1
  echo "${PIPESTATUS[1]}" > "$OUT/$LABEL.rc" ) & PUB_PID=$!

START=$(date +%s)
while :; do
  el=$(( $(date +%s) - START ))
  [ "$el" -ge "$SECS" ] && { VERDICT="survived ${SECS}s"; break; }
  kill -0 "$PUB_PID" 2>/dev/null || { VERDICT="import exited at ${el}s"; break; }
  sleep 1
done

sleep 1
RC=$(cat "$OUT/$LABEL.rc" 2>/dev/null || echo "-")
ERR=$(grep -E "^Error|error:|missing .* sync|never regained" "$OUT/$LABEL.pub.log" 2>/dev/null | head -1)
SUBSZ=$(wc -c <"$OUT/$LABEL.sub.ts" 2>/dev/null | tr -d ' ')
printf '%-18s %-22s rc=%-4s sub=%10s B  %s\n' "$LABEL" "$VERDICT" "$RC" "${SUBSZ:-0}" "${ERR:-—}"
