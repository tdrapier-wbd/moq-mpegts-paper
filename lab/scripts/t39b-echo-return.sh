#!/bin/bash
# T39 Part B -- does the subscriber's health report, carried back over the same relay on the same
# credential, tell the publisher side which fault the client edge is seeing, and how soon?
#
# The return path is upstream's: the importer solicits feedback in its catalog
# (`import --echo-path`), a subscriber's `export --echo <name>` publishes `<name>.echo` there once a
# second with what it received (per-PID `units` and `quiet`, the release clock), and a reader at the
# publisher side follows it with `export echo`. The importer's own report (`import --report`, read
# with `export report`) is recorded beside it as tier 1.
#
# One relay behind `moq auth serve`, ES256, root `bcast`. Four tokens, none ever printed:
#   pub   publishes ch1/**                                   the publisher
#   affa  subscribes ch1/**, publishes telemetry/affa.echo/** the client edge: ONE credential
#   noc   subscribes telemetry/**                            the publisher side's feedback reader
#   rep   subscribes ch1/**                                  the publisher side's tier-1 reader
#
# Arms (test file, Part B): control | audio | video | stall | relay. The audio and video stimuli
# are built offline by ts-partial-stall.py, and their onset is the byte where they first differ
# from the control as it passes into the importer (t39b-tap.py bytes). stall SIGSTOPs the
# regulator; relay SIGSTOPs the relay. Part A's detector reads the subscriber's output as the
# client-edge comparator. Every reader line is stamped with wall time on arrival.
#
# Usage: MOQ=<bin dir> CLIP=<clip> t39b-echo-return.sh <out dir> ["arms"] [trials]
# Then:  python3 t39b-grade.py run <out dir>
# Laptop loopback, outside the sandbox, as one background invocation: about 100 s a trial.

set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$R/moq-cli-flags.sh"

OUT=${1:?usage: t39b-echo-return.sh <out dir> [arms] [trials]}
ARMS=${2:-control audio video stall relay}
TRIALS=${3:-2}
MOQ=${MOQ:-$HOME/bin-419b799c-thin}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
P_RELAY=${P_RELAY:-9845}
P_AUTH=${P_AUTH:-9846}
SLICE_S=75
AT=20
FOR=30
FREEZE=20
GAPS="111:1000,121:1500,123:1500"
# The comparator arms after --warmup plus --learn media seconds (5 + 20 by default), after this
# rig's 20 s onset: `LIVENESS_ARGS="--warmup 2 --learn 0"` arms it first, so its latency is one.
read -r -a LARGS <<<"${LIVENESS_ARGS:-}"
M=$MOQ/moq

moq_cli_detect "$M" "$MOQ/moq-relay"
mkdir -p "$OUT/src"
OUT=$(cd "$OUT" && pwd)
A=$OUT/auth
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

cleanup() {
	pkill -f "127\.0\.0\.1:$P_RELAY/bcast" 2>/dev/null
	pkill -f "auth serve --listen 127\.0\.0\.1:$P_AUTH" 2>/dev/null
	pkill -CONT -f "moq-relay --listen 127\.0\.0\.1:$P_RELAY" 2>/dev/null
	pkill -f "moq-relay --listen 127\.0\.0\.1:$P_RELAY" 2>/dev/null
	pkill -CONT -f "tsp -I file $OUT/src/" 2>/dev/null
	pkill -f "tsp -I file $OUT/src/" 2>/dev/null
	rm -rf "$A"
}
trap cleanup EXIT

[ -f "$CLIP" ] || {
	echo "no clip at $CLIP"
	exit 1
}
if [ -f "$MOQ.sha" ]; then
	echo "build: $(head -1 "$MOQ.sha")"
fi

# --- credentials, created under umask 077 and deleted on exit --------------------------------
(
	umask 077
	mkdir -p "$A/keys" "$A/pub" "$A/tok"
)
EXP=$(($(date +%s) + 7200))
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
echo "tokens: pub, affa (subscribe ch1/** + publish telemetry/affa.echo/**), noc, rep"

# --- stimuli, built once; each fault verified present before anything is asked about it -------
S=$OUT/src
if [ ! -s "$S/control.ts" ]; then
	tsp -I file "$CLIP" -P until --pcr-based --milli-seconds $((SLICE_S * 1000)) \
		-O file "$S/slice.ts" || exit 1
	python3 "$R/ts-partial-stall.py" --mode control "$S/slice.ts" >"$S/control.ts" || exit 1
	# Its audio discovery also takes teletext (131); the arm is the two audio streams only.
	python3 "$R/ts-partial-stall.py" --mode audio --audio-pid 121 --audio-pid 123 --at $AT --for $FOR \
		"$S/slice.ts" >"$S/audio.ts" || exit 1
	python3 "$R/ts-partial-stall.py" --mode video --at $AT --for $FOR "$S/slice.ts" >"$S/video.ts" || exit 1
	rm -f "$S/slice.ts"
fi
python3 "$R/t39b-grade.py" stim "$S/control.ts" "$S/audio.ts" --pids 121,123 --for $FOR >"$S/audio.stim" || {
	echo "AUDIO FAULT NOT BUILT"
	cat "$S/audio.stim"
	exit 1
}
python3 "$R/t39b-grade.py" stim "$S/control.ts" "$S/video.ts" --pids 111 --for $FOR >"$S/video.stim" || {
	echo "VIDEO FAULT NOT BUILT"
	cat "$S/video.stim"
	exit 1
}
echo "stimuli: audio $(cat "$S/audio.stim"); video $(cat "$S/video.stim")"

# A client under its token: pidfile, then the command. The token rides MOQ_CONNECT_TOKEN, never
# argv, and `sh -c ... exec` keeps the pidfile's PID the client's own.
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
sigint() { # pidfiles...
	local f
	for f in "$@"; do
		[ -s "$f" ] && kill -INT "$(cat "$f")" 2>/dev/null
	done
}

trial() { # arm n
	local arm=$1 n=$2 d stim marks=()
	d=$OUT/$arm-$n
	rm -rf "$d"
	mkdir -p "$d"
	echo "$arm" >"$d/arm"
	stim=control
	case $arm in
	audio | video)
		stim=$arm
		read -r on off _ <"$S/$arm.stim"
		marks=(--mark "onset:$on" --mark "end:$off")
		;;
	esac

	"$M" auth serve --listen 127.0.0.1:$P_AUTH --key-dir "$A/pub" >"$d/auth.log" 2>&1 &
	local auth=$!
	sleep 1
	moq_relay_authed 127.0.0.1:$P_RELAY localhost --auth-url http://127.0.0.1:$P_AUTH --log-level info
	"$MOQ/moq-relay" "${RELAY_ARGV[@]}" >"$d/relay.log" 2>&1 &
	local relay=$!
	sleep 2
	kill -0 $relay 2>/dev/null || {
		echo "$arm-$n: relay did not start"
		tail -3 "$d/relay.log"
		kill $auth
		return 1
	}

	client noc "$d/noc.pid" --broadcast telemetry export echo 2>"$d/noc.log" |
		python3 "$R/t39b-tap.py" lines >"$d/echo.tsv" &
	client rep "$d/rep.pid" --broadcast ch1 export report 2>"$d/rep.log" |
		python3 "$R/t39b-tap.py" lines >"$d/report.tsv" &
	client affa "$d/sub.pid" --broadcast ch1 export --echo affa ts "${MOQ_LAT[@]}" 2s 2>"$d/sub.log" |
		python3 "$R/ts-liveness.py" - --gap "$GAPS" ${LARGS[@]+"${LARGS[@]}"} --jsonl --quiet 2>"$d/live.err" |
		python3 "$R/t39b-tap.py" lines >"$d/live.tsv" &
	sleep 2

	sh -c 'echo $$ >"$0"; exec "$@"' "$d/tsp.pid" \
		tsp -I file "$S/$stim.ts" -P regulate --pcr-synchronous -O file - 2>"$d/tsp.log" |
		python3 "$R/t39b-tap.py" bytes --log "$d/marks.tsv" ${marks[@]+"${marks[@]}"} |
		client pub "$d/pub.pid" --broadcast ch1 import --report --echo-path telemetry --linger 0s ts \
			>"$d/pub.log" 2>&1 &
	waitfor "$d/marks.tsv" first 10 || echo "$arm-$n: the source never started"

	case $arm in
	stall)
		sleep $AT
		kill -STOP "$(cat "$d/tsp.pid")"
		printf '%s\tonset\tSIGSTOP regulator\n' "$(now)" >>"$d/events.tsv"
		sleep $FOR
		kill -CONT "$(cat "$d/tsp.pid")"
		printf '%s\tend\tSIGCONT regulator\n' "$(now)" >>"$d/events.tsv"
		;;
	relay)
		sleep $AT
		kill -STOP $relay
		printf '%s\tonset\tSIGSTOP relay\n' "$(now)" >>"$d/events.tsv"
		sleep $FREEZE
		kill -CONT $relay
		printf '%s\tend\tSIGCONT relay\n' "$(now)" >>"$d/events.tsv"
		;;
	esac
	waitfor "$d/marks.tsv" eof $((SLICE_S + FOR + 30)) || echo "$arm-$n: the source did not end"
	# The tail: the 2 s export delay, the last snapshot, and the reader's drain.
	sleep 8
	sigint "$d/sub.pid" "$d/noc.pid" "$d/rep.pid" "$d/pub.pid"
	sleep 3
	local f
	for f in "$d"/*.pid; do
		kill -0 "$(cat "$f")" 2>/dev/null && echo "$arm-$n: $(basename "$f" .pid) ignored SIGINT" &&
			kill -9 "$(cat "$f")" 2>/dev/null
	done
	kill $relay $auth 2>/dev/null
	wait 2>/dev/null
	echo "$arm-$n: $(wc -l <"$d/echo.tsv" | tr -d ' ') feedback lines, $(wc -l <"$d/report.tsv" | tr -d ' ') report lines, $(wc -l <"$d/live.tsv" | tr -d ' ') comparator events"
}

for n in $(seq 1 "$TRIALS"); do
	for arm in $ARMS; do
		trial "$arm" "$n"
	done
done
echo "done: python3 $R/t39b-grade.py run $OUT"
