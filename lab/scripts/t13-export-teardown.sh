#!/usr/bin/env bash
# T13 (liveness, fourth arm) — how does `moq export ts` end when the broadcast ends?
#
# Two ways a publisher can stop, and they are not the same event:
#
#   clean   the source reaches end-of-file and `moq import ts` finishes its tracks and exits 0.
#   abrupt  the publisher is killed, so the tracks are dropped without finish().
#
# #3926 is filed against the abrupt case (`Error: json: dropped`, no `--linger`, nothing
# survives a publisher restart). The clean case has a different and undocumented outcome, and
# upstream's plan for #3926 (`quest/m1/export-linger.md`) specifies it as the *success* path:
# "0 when the catalog track finished cleanly, 1 when it was dropped or anything else failed".
# This rig measures both arms' exit status and error text so the two are not conflated.
#
#   t13-export-teardown.sh [outdir]
#
# env: BIN (moq binary dir), CLIP, PORT (4494), RUN_S (seconds before the abrupt kill)
set -uo pipefail

BIN="${BIN:?set BIN to the moq binary dir}"
CLIP="${CLIP:?set CLIP to a short transport stream}"
PORT="${PORT:-4494}"
RUN_S="${RUN_S:-20}"
OUT="${1:-$HOME/t13-teardown}"

rm -rf "$OUT"
mkdir -p "$OUT"

setsid nohup "$BIN/moq-relay" --listen "127.0.0.1:$PORT" --listen-tls-generate 127.0.0.1 \
	--auth-public "**" --quic-gso=false --quic-congestion-control loss --log-level warn \
	>"$OUT/relay.log" 2>&1 </dev/null &
RELAY_PID=$!
trap 'kill "$RELAY_PID" 2>/dev/null' EXIT
sleep 3

run_arm() { # arm, how-the-publisher-stops
	arm="$1"
	mode="$2"
	bcast="t13td.$arm.hang"

	"$BIN/moq" --connect-tls-insecure --connect "https://127.0.0.1:$PORT" \
		--broadcast "$bcast" export ts >"$OUT/$arm.ts" 2>"$OUT/$arm.export.log" &
	exp=$!
	sleep 2

	if [ "$mode" = clean ]; then
		# No --infinite: tsp reaches end-of-file, import finishes its tracks and exits 0.
		tsp --realtime -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
			"$BIN/moq" --connect-tls-insecure --connect "https://127.0.0.1:$PORT" \
				--broadcast "$bcast" import ts >"$OUT/$arm.import.log" 2>&1
		pub_status=$?
	else
		setsid bash -c "tsp --realtime -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O file - \
			| '$BIN/moq' --connect-tls-insecure --connect https://127.0.0.1:$PORT \
			  --broadcast '$bcast' import ts" >"$OUT/$arm.import.log" 2>&1 &
		sleep "$RUN_S"
		pkill -f "t13td[.]${arm}[.]hang.*import" 2>/dev/null
		pub_status="killed"
	fi

	# Give the exporter its own time to notice and end.
	for _ in $(seq 1 60); do
		kill -0 "$exp" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$exp" 2>/dev/null; then
		kill "$exp" 2>/dev/null
		exp_status="still running at +60s"
	else
		wait "$exp"
		exp_status=$?
	fi

	err=$(grep -m1 '^Error:' "$OUT/$arm.export.log" | cut -c1-78)
	printf '%-7s  publisher=%-7s  export_exit=%-20s  bytes=%-10s  %s\n' \
		"$arm" "$pub_status" "$exp_status" "$(stat -c%s "$OUT/$arm.ts")" "${err:-(no Error line)}"
	pkill -f "t13td[.]${arm}[.]hang" 2>/dev/null
	sleep 3
}

printf 'how the broadcast ended, and how `moq export ts` reported it\n\n'
run_arm clean clean
run_arm abrupt abrupt
