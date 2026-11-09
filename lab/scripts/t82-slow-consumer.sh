#!/usr/bin/env bash
# T82, slow and unresponsive subscribers on one relay: is a healthy subscriber isolated, what does
# each unresponsive one cost the relay, and how does each recover? One cell per invocation.
# usage: t82-slow-consumer.sh <arm> <out-dir>
#   tsp regulate | moq import ts -> relay -> 2 victims + N abusers, every subscriber an
#   `export ts --delay 2s` drained by t82-reader.py. At T_EV the abusers are frozen (SIGSTOP on the
#   export: no reads, no ACKs), stopped (the export runs, its reader reads nothing) or slowed (the
#   reader drains at a fraction of the clip rate).
# arms: control healthy32 r1 r2 r3 slow slow150 stop freeze5 freeze30 r2x64f, and r2x32l r2x64
#   storm storm30, whose abusers are light (export to /dev/null, no reader); prefix pt- runs the
#   passthrough lane; suffixes: -l7 offers only moq-lite-07-wip, -f exports with a 10 s follow,
#   -fs the same follow with --stitch, -np with --mux-rate 0 (unpadded), -rs gives the relay a
#   stateless-reset secret, -tsp and -pacer put a1 behind a valve and that receiver, beside a
#   chain control k1 (PACER overrides the groomer binary).
# env: MOQ (bin dir with moq and moq-relay, default ~/bin-bad28cef-thin), CLIP (~/contrib-10m.ts),
#      PORT (4821), MPORT (internal listener, 4822), KEEP=1 keeps the captures.
# Writes meta.txt, pids.tsv, ps.tsv (RSS and state every 0.5 s), metrics.tsv (relay counters every
# 1 s), events.tsv, exits.tsv, cc.tsv and per subscriber <name>.csv and logs/<name>.log.
set -u
[ "${BASH_VERSINFO[0]}" -ge 5 ] || {
	echo "needs bash 5 (EPOCHREALTIME)" >&2
	exit 2
}
ARM=$1 OUT=$2
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MOQ=${MOQ:-$HOME/bin-bad28cef-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts}
PORT=${PORT:-4821} MPORT=${MPORT:-4822}
M=$MOQ/moq R=$MOQ/moq-relay
T_EV=45 T_END=170 RATE=9950000
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"

base=$ARM lane=media ver='' follow='' stitch='' pad='' rsec='' rx=''
case $base in pt-*) lane=pt base=${base#pt-} ;; esac
while :; do
	case $base in
	*-l7) ver=moq-lite-07-wip base=${base%-l7} ;;
	*-f) follow=10s base=${base%-f} ;;
	*-fs) follow=10s stitch=1 base=${base%-fs} ;;
	*-np) pad=0 base=${base%-np} ;;
	*-rs) rsec=1 base=${base%-rs} ;;
	*-tsp) rx=tsp base=${base%-tsp} ;;
	*-pacer) rx=pacer base=${base%-pacer} ;;
	*) break ;;
	esac
done
n=0 idle=10s win='' ev=none dur=0 frac='' light=0
case $base in
control) ;;
healthy32) n=32 ;;
r1) n=32 ev=freeze dur=40 ;;
r2) n=32 ev=freeze dur=40 idle=30s ;;
r3) n=32 ev=freeze dur=40 idle=30s win=16777216 ;;
slow) n=1 ev=slow dur=60 frac=0.5 ;;
slow150) n=1 ev=slow dur=150 frac=0.5 T_END=260 ;;
stop) n=1 ev=stop dur=60 ;;
freeze5) n=1 ev=freeze dur=5 ;;
freeze30) n=1 ev=freeze dur=30 ;;
r2x32l) n=32 ev=freeze dur=40 idle=30s light=1 T_END=300 ;;
r2x64) n=64 ev=freeze dur=40 idle=30s light=1 T_END=300 ;;
r2x64f) n=64 ev=freeze dur=40 idle=30s T_END=300 ;;
storm) n=40 ev=storm dur=60 light=1 ;;
storm30) n=40 ev=storm dur=60 idle=30s light=1 ;;
*)
	echo "unknown arm $ARM" >&2
	exit 2
	;;
esac
RXCMD=()
case $rx in
tsp) RXCMD=(tsp -P regulate --pcr-synchronous) ;;
pacer) RXCMD=("${PACER:-$HOME/bin-pacer-97f3a38/mpegts-pacer}" stdout 9950000 --latency-ms 1000
	--max-latency-ms 8000 --stall-ms 1000 --on-stall mute) ;;
esac
[ -n "$rx" ] && [ "$T_END" -lt 230 ] && T_END=230

mkdir -p "$OUT/logs" && cd "$OUT" || exit 1
rm -f ./*.fifo
now_ms() { echo $(((${EPOCHREALTIME/./} - T0US) / 1000)); }
stop_pids() { # <pid ...>: SIGINT, which the moq CLI stops on; SIGKILL what is left after 3 s
	[ $# -gt 0 ] || return 0
	kill -INT "$@" 2>/dev/null
	for _ in $(seq 1 30); do
		kill -0 "$@" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$@" 2>/dev/null
	wait "$@" 2>/dev/null
}
wait_port() { for _ in $(seq 1 100); do (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.05; done; return 1; }

QUIC=("${MOQ_GSO[@]}" --quic-congestion-control "${MOQ_CC:-delay}" --quic-idle-timeout "$idle")
CLIENT=("${MOQ_DIAL[@]}" "https://localhost:$PORT/anon" "${QUIC[@]}")
[ -n "$ver" ] && CLIENT+=(--connect-version "$ver")
EXPORT=(export ts --delay 2s)
IMPORT=(import ts)
[ "$lane" = pt ] && EXPORT+=(--passthrough) IMPORT+=(--passthrough)
[ -n "$follow" ] && EXPORT+=("${MOQ_FOLLOW[@]}" "$follow")
[ -n "$stitch" ] && EXPORT+=(--stitch)
[ -n "$pad" ] && EXPORT+=(--mux-rate "$pad")
moq_relay_public "[::]:$PORT" localhost --log-level info --internal-listen "127.0.0.1:$MPORT" \
	--quic-idle-timeout "$idle"
[ -n "$win" ] && RELAY_ARGV+=(--quic-send-window "$win")
if [ -n "$rsec" ]; then
	(umask 077 && openssl rand -hex 32 >reset.secret)
	RELAY_ARGV+=(--listen-reset-secret reset.secret)
fi

{
	echo "arm=$ARM lane=$lane abusers=$n event=$ev dur=${dur}s frac=${frac:-} idle=$idle send_window=${win:-default} version=${ver:-default} follow=${follow:-0s}${stitch:+ stitch} mux_rate=${pad:-catalog} reset_secret=${rsec:+set} rx=${rx:-none} light=$light"
	echo "build=$(cat "$MOQ.sha" 2>/dev/null || echo unknown) moq=$("$M" --version 2>&1 | head -1)"
	echo "clip=$(basename "$CLIP") bytes=$(stat -f %z "$CLIP") t_ev=$T_EV t_end=$T_END"
	echo "relay_args=${RELAY_ARGV[*]}"
	echo "client_args=${QUIC[*]} ${ver:+--connect-version $ver} | ${EXPORT[*]}"
	echo "host=$(sysctl -n hw.model) cpus=$(sysctl -n hw.ncpu) mem=$(($(sysctl -n hw.memsize) / 1073741824))GiB"
} >meta.txt

RUST_LOG=info "$R" "${RELAY_ARGV[@]}" >logs/relay.log 2>&1 &
RP=$!
wait_port "$MPORT" || printf '0\tNOPORT\t%s\n' "$MPORT" >>events.tsv
mkfifo pub.fifo
"$M" "${CLIENT[@]}" --broadcast t82 "${IMPORT[@]}" <pub.fifo >logs/pub.log 2>&1 &
PP=$!
tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - >pub.fifo 2>logs/tsp.log &
TP=$!
sleep 3

T0=$EPOCHREALTIME T0US=${EPOCHREALTIME/./}
echo "t0=$T0" >>meta.txt
python3 "$HERE/t82-footprint.py" --pid "$RP" --t0 "$T0" --out fp.tsv &
FPP=$!
declare -A EXP RDR VLV
NAMES=() ABUSERS=() RXP=()
sub() { # <name> <capture> [reader args ...]
	local name=$1 cap=$2
	shift 2
	mkfifo "$name.fifo"
	"$M" "${CLIENT[@]}" --broadcast t82 "${EXPORT[@]}" >"$name.fifo" 2>"logs/$name.log" &
	EXP[$name]=$!
	python3 "$HERE/t82-reader.py" --out "$cap" --log "$name.csv" --t0 "$T0" \
		--pid 111 --pid 121 --pid 123 "$@" <"$name.fifo" &
	RDR[$name]=$!
	NAMES+=("$name")
}
light() { # <name>: an abuser with no reader, its export writing to /dev/null
	"$M" "${CLIENT[@]}" --broadcast t82 "${EXPORT[@]}" >/dev/null 2>"logs/$1.log" &
	EXP[$1]=$!
	NAMES+=("$1")
}
chain() { # <name> [valve args ...]: export -> valve (a reader that forwards) -> receiver -> reader
	local name=$1
	shift
	mkfifo "$name.fifo" "$name.v.fifo" "$name.r.fifo"
	"$M" "${CLIENT[@]}" --broadcast t82 "${EXPORT[@]}" >"$name.fifo" 2>"logs/$name.log" &
	EXP[$name]=$!
	python3 "$HERE/t82-reader.py" --out "$name.v.fifo" --log "$name.csv" --t0 "$T0" \
		--pid 111 --pid 121 --pid 123 "$@" <"$name.fifo" &
	VLV[$name]=$!
	"${RXCMD[@]}" <"$name.v.fifo" >"$name.r.fifo" 2>"logs/$name-rx.log" &
	RXP+=($!)
	python3 "$HERE/t82-reader.py" --out "${name}r.ts" --log "${name}r.csv" --t0 "$T0" \
		--pid 111 --pid 121 --pid 123 <"$name.r.fifo" &
	RDR[$name]=$!
	NAMES+=("$name")
}
sub v1 v1.ts
sub v2 v2.ts
[ -n "$rx" ] && chain k1
THR=()
case $ev in
slow) THR=(--throttle "$T_EV:$((T_EV + dur)):$(awk -v f="$frac" -v r="$RATE" 'BEGIN { printf "%d", f * r }')") ;;
stop) THR=(--throttle "$T_EV:$((T_EV + dur)):0") ;;
esac
[ "$ev" = storm ] || for ((i = 1; i <= n; i++)); do
	if [ "$light" = 1 ]; then
		light "a$i"
	elif [ -n "$rx" ]; then
		chain "a$i" "${THR[@]}"
	else
		cap=/dev/null
		[ "$n" -eq 1 ] && cap=a1.ts
		sub "a$i" "$cap" "${THR[@]}"
	fi
	ABUSERS+=("${EXP[a$i]}")
done
{
	printf 'relay\t%s\npub\t%s\n' "$RP" "$PP"
	for k in "${NAMES[@]}"; do printf '%s\t%s\n' "$k" "${EXP[$k]}"; done
} >pids.tsv
PIDLIST=$(cut -f2 pids.tsv | paste -sd, -)

froze=0 thawed=0 next_ps=0 next_m=0 gen=0
STORM=()
while :; do
	ms=$(now_ms)
	[ "$ms" -ge $((T_END * 1000)) ] && break
	if [ "$ms" -ge "$next_ps" ]; then
		ps -o pid=,rss=,stat= -p "$PIDLIST" | awk -v t="$ms" '{ print t "\t" $1 "\t" $2 "\t" $3 }' >>ps.tsv
		next_ps=$((next_ps + 500))
	fi
	if [ "$ms" -ge "$next_m" ]; then
		curl -s -m 0.5 "http://127.0.0.1:$MPORT/metrics" |
			awk -v t="$ms" '/^moq_relay_(stale|sessions|bytes_total|groups_total|frames_total)/ { print t "\t" $0 }' >>metrics.tsv
		next_m=$((next_m + 1000))
	fi
	if [ "$ev" = freeze ] && [ "$froze" -eq 0 ] && [ "$ms" -ge $((T_EV * 1000)) ]; then
		kill -STOP "${ABUSERS[@]}"
		printf '%s\tSTOP\t%s\n' "$(now_ms)" "${#ABUSERS[@]}" >>events.tsv
		froze=1
	fi
	if [ "$ev" = freeze ] && [ "$thawed" -eq 0 ] && [ "$ms" -ge $(((T_EV + dur) * 1000)) ]; then
		kill -CONT "${ABUSERS[@]}"
		printf '%s\tCONT\t%s\n' "$(now_ms)" "${#ABUSERS[@]}" >>events.tsv
		thawed=1
	fi
	# A storm: every 5 s, SIGKILL the generation (no close reaches the relay) and start the next.
	if [ "$ev" = storm ] && [ $((gen * 5)) -le "$dur" ] && [ "$ms" -ge $(((T_EV + gen * 5) * 1000)) ]; then
		if [ ${#STORM[@]} -gt 0 ]; then
			kill -KILL "${STORM[@]}" 2>/dev/null
			wait "${STORM[@]}" 2>/dev/null
		fi
		STORM=()
		if [ $((gen * 5)) -lt "$dur" ]; then
			for ((i = 1; i <= n; i++)); do
				"$M" "${CLIENT[@]}" --broadcast t82 "${EXPORT[@]}" >/dev/null 2>/dev/null &
				STORM+=($!)
			done
		fi
		printf '%s\tSTORM\t%s\n' "$(now_ms)" "$gen" >>events.tsv
		gen=$((gen + 1))
	fi
	sleep 0.1
done

for k in "${NAMES[@]}"; do
	if ! kill -0 "${EXP[$k]}" 2>/dev/null; then
		wait "${EXP[$k]}"
		printf '%s\texited\t%s\n' "$k" "$?" >>exits.tsv
	else
		printf '%s\trunning\t-\n' "$k" >>exits.tsv
	fi
done
curl -s -m 1 "http://127.0.0.1:$MPORT/metrics" >metrics-final.txt
pids=()
for k in "${NAMES[@]}"; do pids+=("${EXP[$k]}"); done
kill -CONT "${pids[@]}" 2>/dev/null
stop_pids "${pids[@]}"
[ ${#RXP[@]} -gt 0 ] && stop_pids "${VLV[@]}" "${RXP[@]}"
for k in "${!RDR[@]}"; do wait "${RDR[$k]}" 2>/dev/null; done
stop_pids "$TP" "$PP"
stop_pids "$RP"
stop_pids "$FPP"
rm -f reset.secret
for c in v1.ts v2.ts a1.ts a1r.ts k1r.ts; do
	[ -f "$c" ] || continue
	printf '%s\t%s\t%s\n' "$c" "$(stat -f %z "$c")" \
		"$(tsp -I file "$c" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity')" >>cc.tsv
	[ "${KEEP:-0}" = 1 ] || rm -f "$c"
done
rm -f ./*.fifo
echo "cell $ARM done"
