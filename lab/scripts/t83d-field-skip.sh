#!/bin/bash
# moq#9081 replay: relay + `import ts --program 1` of a paced 50 s capture + `export ts --delay 2s`
# for 40 s, on loopback, then count what the export delivered.
# usage: [CONNECT_EXTRA="--connect-version moq-lite-07-wip"] t83d-field-skip.sh <bindir> <worktree> <run-dir> [clip]
set -u
B=$1 WT=$2 RUN=$3 CLIP=${4:-$HOME/contrib-10m.ts}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$RUN" || exit 1
PORT=$((20000 + RANDOM % 20000))
SHA=$(head -1 "$B.sha" 2>/dev/null)
git -C "$WT" show "${SHA:-HEAD}:demo/relay/localhost.toml" | sed "s/\[::\]:4443/[::]:$PORT/g" > "$RUN/relay.toml" || exit 1
C="--connect-tls-insecure --connect https://localhost:$PORT/anon --quic-gso=false --broadcast t.hang ${CONNECT_EXTRA:-}"
cat "$B.sha" > "$RUN/build.txt" 2>/dev/null
echo "port $PORT clip $CLIP" >> "$RUN/build.txt"
cd "$WT" || exit 1
"$B/moq-relay" "$RUN/relay.toml" --quic-gso=false > "$RUN/relay.log" 2>&1 &
RELAY=$!
sleep 2
tsp -I file "$CLIP" -P until --seconds 50 -P regulate --pcr-synchronous -O file - 2>/dev/null \
	| "$B/moq" $C import ts --program 1 > "$RUN/import.log" 2>&1 &
IMPORT=$!
sleep 3
"$B/moq" $C export ts --delay 2s > "$RUN/out.ts" 2> "$RUN/export.log" &
EXPORT=$!
sleep 40
kill $EXPORT $IMPORT 2>/dev/null
kill -9 $RELAY 2>/dev/null
pkill -P $$ 2>/dev/null
wait 2>/dev/null
python3 "$HERE/t83d-field-skip-count.py" "$RUN/out.ts" "$RUN/export.log" | tee "$RUN/count.txt"
