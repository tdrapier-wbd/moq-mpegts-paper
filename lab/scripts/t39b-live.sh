#!/bin/bash
# T39 Part B on the live feed for an hour, and T21's catalog rate after the import's fix.
#
# t39b-echo-return.sh's path with the clip replaced by the live multiplex, byte for byte from an
# HLS edge, into a local importer that solicits feedback
# (`import --report --echo-path telemetry`). No fault is injected. Readers and credentials are
# Part B's; one more token, `mux`, subscribes ch1/** for the second export:
#   sub  `export --echo affa ts --delay 2s` into ts-liveness, the client edge and its comparator
#   mux  `export ts --delay 1s` at the catalog's rate into t21-pcr-monitor.py, 10 s windows
# Both exports run in loops that log every exit (`*-exits.tsv`) and restart, so an export that
# ends on a missed deadline is counted rather than ending the run.
#
# The source starts at the playlist's first segment, about 12 s behind the live edge, into a 64 MB
# buffer, then the regulator: segments arrive whole and sometimes late, and at the live edge
# (`--live`) each late one stalls the regulator and reaches the importer as a burst.
#
# The first THIN packets are thinned (t39b-tap.py bytes --thin), so the import's first windows
# measure the multiplex short, as T21's restart did, and the fix has a low rate to raise. The
# live multiplex carries no null stuffing, so the loss comes from its two data PIDs.
#
# Usage: MOQ=<bin dir> HLS_URL_FILE=<0600 file holding the edge's signed playlist URL> \
#        [RUN_S=3700] [THIN=500:1000000:123,131] t39b-live.sh <out dir>
# Then:  python3 t39b-grade.py live <out dir>
# Laptop, one background invocation, beside nothing else that paces. The URL is a credential:
# it is never printed, and tsp's log is scrubbed of it on exit.

set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$R/moq-cli-flags.sh"

OUT=${1:?usage: t39b-live.sh <out dir>}
MOQ=${MOQ:-$HOME/bin-1a6ac473-thin}
URLF=${HLS_URL_FILE:?HLS_URL_FILE: a 0600 file holding the edge playlist URL}
RUN_S=${RUN_S:-3700}
THIN=${THIN:-500:1000000:123,131}
P_RELAY=${P_RELAY:-9855}
P_AUTH=${P_AUTH:-9856}
GAPS="111:1000,121:1500,123:1500"
M=$MOQ/moq

moq_cli_detect "$M" "$MOQ/moq-relay"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
A=$OUT/auth
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
event() { printf '%s\t%s\t%s\n' "$(now)" "$1" "${2:-}" >>"$OUT/events.tsv"; }

cleanup() {
	touch "$OUT/stop"
	[ -s "$OUT/tsp.pid" ] && kill "$(cat "$OUT/tsp.pid")" 2>/dev/null
	pkill -f "127\.0\.0\.1:$P_RELAY/bcast" 2>/dev/null
	pkill -f "auth serve --listen 127\.0\.0\.1:$P_AUTH" 2>/dev/null
	pkill -f "moq-relay --listen 127\.0\.0\.1:$P_RELAY" 2>/dev/null
	[ -f "$OUT/tsp.log" ] && sed -E -i '' 's#https?://[^ "]+#<url>#g' "$OUT/tsp.log"
	rm -rf "$A"
}
trap cleanup EXIT

[ -s "$URLF" ] || {
	echo "no URL file"
	exit 1
}
if [ -f "$MOQ.sha" ]; then
	echo "build: $(head -1 "$MOQ.sha")"
fi
rm -f "$OUT/stop"

# --- credentials, created under umask 077 and deleted on exit --------------------------------
(
	umask 077
	mkdir -p "$A/keys" "$A/pub" "$A/tok"
)
EXP=$(($(date +%s) + RUN_S + 3600))
"$M" auth generate --algorithm ES256 --id bcast --root bcast --publish '**' --subscribe '**' \
	--out "$A/keys/bcast.jwk" --public "$A/pub/bcast.jwk" >/dev/null 2>&1 || {
	echo "auth generate failed"
	exit 1
}
sign() { # name, then grant flags
	local name=$1
	shift
	(
		umask 077
		"$M" auth sign --key "$A/keys/bcast.jwk" --root bcast "$@" --expires "$EXP" >"$A/tok/$name.jwt"
	) || {
		echo "auth sign $name failed"
		exit 1
	}
}
sign pub --publish 'ch1/**'
sign affa --subscribe 'ch1/**' --publish 'telemetry/affa.echo/**'
sign noc --subscribe 'telemetry/**'
sign rep --subscribe 'ch1/**'
sign mux --subscribe 'ch1/**'
echo "tokens: pub, affa (subscribe ch1/** + publish telemetry/affa.echo/**), noc, rep, mux"

U="https://127.0.0.1:$P_RELAY/bcast"
client() { # token pidfile args...
	local tok=$1 pidf=$2
	shift 2
	MOQ_CONNECT_TOKEN=$(cat "$A/tok/$tok.jwt") sh -c 'echo $$ >"$0"; exec "$@"' "$pidf" \
		"$M" "${MOQ_DIAL[@]}" "$U" "${MOQ_GSO[@]}" "$@"
}
waitfor() { # file pattern seconds
	local i=0
	while [ $i -lt $(($3 * 10)) ]; do
		grep -q "$2" "$1" 2>/dev/null && return 0
		sleep 0.1
		i=$((i + 1))
	done
	return 1
}
reason() { # log: its last error line, colour codes stripped
	sed -E 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep -i 'error\|missed\|warn' | tail -1 | cut -c1-240
}

subloop() {
	local i=0
	while [ ! -e "$OUT/stop" ]; do
		i=$((i + 1))
		printf '%s\tstart\t%s\n' "$(now)" $i >>"$OUT/sub-exits.tsv"
		client affa "$OUT/sub.pid" --broadcast ch1 export --echo affa ts "${MOQ_LAT[@]}" 2s 2>"$OUT/sub-$i.log" |
			python3 "$R/ts-liveness.py" - --gap "$GAPS" --jsonl --quiet 2>>"$OUT/live.err" |
			python3 "$R/t39b-tap.py" lines >>"$OUT/live.tsv"
		printf '%s\tend\t%s\t%s\n' "$(now)" $i "$(reason "$OUT/sub-$i.log")" >>"$OUT/sub-exits.tsv"
		[ -e "$OUT/stop" ] || sleep 2
	done
}
muxloop() {
	local i=0
	while [ ! -e "$OUT/stop" ]; do
		i=$((i + 1))
		printf '%s\tstart\t%s\n' "$(now)" $i >>"$OUT/mux-exits.tsv"
		client mux "$OUT/mux.pid" --broadcast ch1 export ts "${MOQ_LAT[@]}" 1s 2>"$OUT/mux-$i.log" |
			python3 "$R/t21-pcr-monitor.py" --window 10 |
			python3 "$R/t39b-tap.py" lines >>"$OUT/mux-monitor.tsv"
		printf '%s\tend\t%s\t%s\n' "$(now)" $i "$(reason "$OUT/mux-$i.log")" >>"$OUT/mux-exits.tsv"
		[ -e "$OUT/stop" ] || sleep 2
	done
}

"$M" auth serve --listen 127.0.0.1:$P_AUTH --key-dir "$A/pub" >"$OUT/auth.log" 2>&1 &
AUTH=$!
sleep 1
moq_relay_authed 127.0.0.1:$P_RELAY localhost --auth-url http://127.0.0.1:$P_AUTH --log-level info
"$MOQ/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
RELAY=$!
sleep 2
kill -0 $RELAY 2>/dev/null || {
	echo "relay did not start"
	tail -3 "$OUT/relay.log"
	exit 1
}

client noc "$OUT/noc.pid" --broadcast telemetry export echo 2>"$OUT/noc.log" |
	python3 "$R/t39b-tap.py" lines >"$OUT/echo.tsv" &
client rep "$OUT/rep.pid" --broadcast ch1 export report 2>"$OUT/rep.log" |
	python3 "$R/t39b-tap.py" lines >"$OUT/report.tsv" &
subloop &
muxloop &
sleep 2

event start "run ${RUN_S}s thin $THIN"
sh -c 'echo $$ >"$0"; exec tsp --realtime --buffer-size-mb 64 -I hls "$(cat "$1")" -P regulate --pcr-synchronous -O file -' \
	"$OUT/tsp.pid" "$URLF" 2>"$OUT/tsp.log" |
	python3 "$R/t39b-tap.py" bytes --log "$OUT/marks.tsv" --thin "$THIN" |
	client pub "$OUT/pub.pid" --broadcast ch1 import --report --echo-path telemetry --linger 0s ts \
		>"$OUT/pub.log" 2>&1 &
waitfor "$OUT/marks.tsv" first 30 || {
	echo "the source never started"
	event abort "no first byte"
	exit 1
}
echo "source started; running ${RUN_S}s"

end=$(($(date +%s) + RUN_S))
while [ "$(date +%s)" -lt $end ]; do
	if ! kill -0 "$(cat "$OUT/tsp.pid")" 2>/dev/null; then
		event source_ended "tsp exited"
		echo "the source ended early"
		break
	fi
	sleep 5
done

event stop "teardown"
touch "$OUT/stop"
for f in sub mux noc rep pub; do
	[ -s "$OUT/$f.pid" ] && kill -INT "$(cat "$OUT/$f.pid")" 2>/dev/null
done
kill "$(cat "$OUT/tsp.pid")" 2>/dev/null
sleep 4
for f in "$OUT"/*.pid; do
	kill -0 "$(cat "$f")" 2>/dev/null && echo "$(basename "$f" .pid) ignored SIGINT" &&
		kill -9 "$(cat "$f")" 2>/dev/null
done
kill $RELAY $AUTH 2>/dev/null
wait 2>/dev/null
echo "done: $(wc -l <"$OUT/echo.tsv" | tr -d ' ') feedback lines, $(wc -l <"$OUT/report.tsv" | tr -d ' ') report lines," \
	"$(grep -c . "$OUT/mux-monitor.tsv" 2>/dev/null) monitor windows; python3 $R/t39b-grade.py live $OUT"
