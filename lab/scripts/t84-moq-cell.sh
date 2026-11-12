#!/usr/bin/env bash
# T84: one cell of a MoQ lane through a relay under T28's path faults
# (lab/test-84-moq-cdn-relay-impairment.md).
#
#   tsp regulate on the host replays the synthetic fixture (video PTS tapped by a fork, T28's tap)
#     -> moq import ts [--passthrough], a broadcast new to each cell, to the relay
#     == anchor: one uncounted subscriber on the host, first (openmoq/moqx#795)
#     == impaired leg, ns t72i (the shape on v72i's netem), and control leg, ns t72c, each
#        moq export ts [--passthrough] --delay DELAY_MS -> t18-latency.py tap -> out.ts
#
# RELAY=node: the CDN relay at URL, reached through T72's paths (t72-net.sh, its name pinned in both
# namespaces). RELAY=local: moq-relay from MOQ's directory on this host, on PORT, without GSO so the
# netem drops single packets; the publisher and anchor reach it on loopback, the legs on their
# gateways. The cell's clock starts at the impaired leg's first output: SETTLE s clean, then the
# shape, then the rest of the window, as t72-cdn-cell.sh's.
#
# Usage: t84-moq-cell.sh <out-dir> <shape>      (as root)
#   shapes: none | outage | loss<P> | reorder<P> | step<Mbit> (the path's cake at that rate) |
#           shallow<Mbit> (the cake replaced by a token bucket of TBF_BURST and TBF_LIMIT bytes)
# Env:   RELAY (node | local), URL (node), VER (moq-transport-18), LANE (demux | passthrough),
#        DELAY_MS, MOQ (~/bin-d66c8928/moq), RELAY_BIN (moq-relay beside MOQ), RELAY_ARGS (more
#        flags for the local relay), QLOG_MOQ (a moq built with qlog: the impaired leg's client, its
#        traces in qlog/), CLIP (~/fixture-10m.ts), SCRIPTS (~/t84/scripts), PREFIX (moq-test/p1ao),
#        PORT (18443), SETTLE, OUTAGE, HELD, WINDOW, PATH_DELAY_MS, REORDER_DELAY_MS, RATE_MBIT (the
#        path's cake, 20, restored after a step or shallow shape), TBF_BURST (3000), TBF_LIMIT
#        (15000), KEEP_TS
# Output: events.log, src.csv, eg.csv, sub.log, pub.log, anchor.log, relay.log (local), the same leg
#        files in ctl/ for the control leg, qdisc-before.txt and qdisc.txt (the impaired netem's
#        counters), bottleneck.txt (step and shallow: the path's queues as the shape ends), grade.json in each leg (t84-moq-grade.py); out.ts deleted unless KEEP_TS.
set -uo pipefail

OUT=${1:?usage: t84-moq-cell.sh <out-dir> <shape>}
SHAPE=${2:?shape: none|outage|loss<P>|reorder<P>|step<Mbit>|shallow<Mbit>}
UHOME=$(getent passwd "${SUDO_USER:-ubuntu}" | cut -d: -f6)
RELAY=${RELAY:?set RELAY, node or local}
VER=${VER:-moq-transport-18}
LANE=${LANE:?set LANE, demux or passthrough}
DELAY_MS=${DELAY_MS:?set DELAY_MS, the export delay}
MOQ=${MOQ:-$UHOME/bin-d66c8928/moq}
RELAY_BIN=${RELAY_BIN:-$(dirname "$MOQ")/moq-relay}
read -r -a RARGS <<<"${RELAY_ARGS:-}"
QLOG_MOQ=${QLOG_MOQ:-}
CLIP=${CLIP:-$UHOME/fixture-10m.ts}
SCRIPTS=${SCRIPTS:-$UHOME/t84/scripts}
PREFIX=${PREFIX:-moq-test/p1ao}
PORT=${PORT:-18443}
SETTLE=${SETTLE:-20}
OUTAGE=${OUTAGE:-5}
HELD=${HELD:-40}
case "$SHAPE" in
none | outage) WINDOW=${WINDOW:-60} ;;
loss* | reorder* | step* | shallow*) WINDOW=${WINDOW:-95} ;;
*) echo "unknown shape $SHAPE" >&2; exit 2 ;;
esac
PATH_DELAY_MS=${PATH_DELAY_MS:-50}
REORDER_DELAY_MS=${REORDER_DELAY_MS:-50}
RATE_MBIT=${RATE_MBIT:-20}
TBF_BURST=${TBF_BURST:-3000}
TBF_LIMIT=${TBF_LIMIT:-15000}
VPID=111
TAP_S=$((60 + 2 * DELAY_MS / 1000 + WINDOW))

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
[ -e "$OUT" ] && { echo "$OUT exists; refusing to overwrite a cell" >&2; exit 2; }
for f in "$CLIP" "$MOQ" "$SCRIPTS/t18-latency.py" "$SCRIPTS/t28-content-lost.py" \
	"$SCRIPTS/t68-netns-grade.py" "$SCRIPTS/t84-moq-grade.py"; do
	[ -r "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
[ -z "$QLOG_MOQ" ] || [ -x "$QLOG_MOQ" ] || { echo "missing: $QLOG_MOQ" >&2; exit 2; }
case "$LANE" in
demux)
	IMP=(import ts)
	EXP=(export ts --delay "${DELAY_MS}ms")
	;;
passthrough)
	IMP=(import ts --passthrough)
	EXP=(export ts --passthrough --delay "${DELAY_MS}ms")
	;;
*) echo "LANE is demux or passthrough" >&2; exit 2 ;;
esac
case "$RELAY" in
node)
	[ -n "${URL:-}" ] || { echo "node needs URL" >&2; exit 2; }
	CONN_H=(--connect "$URL" --connect-version "$VER")
	CONN_I=("${CONN_H[@]}")
	CONN_C=("${CONN_H[@]}")
	;;
local)
	[ -x "$RELAY_BIN" ] || { echo "missing: $RELAY_BIN" >&2; exit 2; }
	if ss -lnu "sport = :$PORT" | grep -q ":$PORT"; then
		echo "port $PORT in use" >&2
		exit 2
	fi
	TLS=(--connect-tls-insecure --connect-version "$VER")
	CONN_H=(--connect "moqt://127.0.0.1:$PORT" "${TLS[@]}")
	CONN_I=(--connect "moqt://10.72.1.1:$PORT" "${TLS[@]}")
	CONN_C=(--connect "moqt://10.72.2.1:$PORT" "${TLS[@]}")
	;;
*) echo "RELAY is node or local" >&2; exit 2 ;;
esac
ip netns list | grep -q '^t72i' && ip netns list | grep -q '^t72c' || { echo "paths not up" >&2; exit 2; }
mkdir -p "$OUT/ctl"
OUT=$(cd "$OUT" && pwd)
BC="$PREFIX/$(basename "$OUT")-$(date +%s)"
ev() { echo "$EPOCHREALTIME $*" >>"$OUT/events.log"; }
netem() { tc qdisc change dev v72i root handle 1: netem "$@" limit 100000; }
# A replace keeps a handle's kind: the token bucket takes its own handle, so each swap is a graft.
bottleneck() { tc qdisc replace dev v72i parent 1:1 "$@"; }
restore_cake() { bottleneck handle 10: cake bandwidth "${RATE_MBIT}mbit"; }
ev "start shape=$SHAPE relay=$RELAY lane=$LANE delay_ms=$DELAY_MS ver=$VER window=$WINDOW settle=$SETTLE path_delay_ms=$PATH_DELAY_MS qlog=${QLOG_MOQ:+1} relay_bin=$RELAY_BIN relay_args=$(IFS=,; echo "${RARGS[*]}")"

GROUPS_=()
RELAY_PID=
in_group() { pgrep -g "$1" -f "$2" 2>/dev/null; }
stop_legs() {
	local g
	for g in "${LEGS[@]:-}"; do
		[ -n "$g" ] && kill -TERM $(in_group "$g" "[-]-broadcast $BC") 2>/dev/null
	done
}
cleanup() {
	local g
	stop_legs
	netem delay "${PATH_DELAY_MS}ms" 2>/dev/null
	case "$SHAPE" in step* | shallow*) restore_cake 2>/dev/null ;; esac
	for g in "${GROUPS_[@]:-}"; do [ -n "$g" ] && kill -TERM -- "-$g" 2>/dev/null; done
	sleep 1
	for g in "${LEGS[@]:-}" "${GROUPS_[@]:-}"; do [ -n "$g" ] && kill -KILL -- "-$g" 2>/dev/null; done
	if [ -n "$RELAY_PID" ]; then
		kill "$RELAY_PID" 2>/dev/null
		for _ in $(seq 10); do kill -0 "$RELAY_PID" 2>/dev/null || break; sleep 1; done
		kill -9 "$RELAY_PID" 2>/dev/null
	fi
}
LEGS=()
trap cleanup EXIT
udp() { ip netns exec "$1" grep '^Udp:' /proc/net/snmp >"$2"; }
netem delay "${PATH_DELAY_MS}ms"
tc -s qdisc show dev v72i >"$OUT/qdisc-before.txt" 2>&1
udp t72i "$OUT/udp-before.txt"
udp t72c "$OUT/ctl/udp-before.txt"

if [ "$RELAY" = local ]; then
	"$RELAY_BIN" --listen "0.0.0.0:$PORT" --listen-tls-generate localhost \
		--auth-public '**' --quic-gso=false "${RARGS[@]}" --log-level warn >"$OUT/relay.log" 2>&1 &
	RELAY_PID=$!
	for _ in $(seq 50); do ss -lnu "sport = :$PORT" | grep -q ":$PORT" && break; sleep 0.1; done
	kill -0 "$RELAY_PID" 2>/dev/null || { echo "relay did not start: $(tail -1 "$OUT/relay.log")" >&2; exit 1; }
fi

setsid bash -c "tsp --realtime -I file '$CLIP' -P regulate --pcr-synchronous \
	-P fork --nowait --ignore-abort 'python3 $SCRIPTS/t18-latency.py tap $VPID $OUT/src.csv --pipe --seconds $TAP_S > /dev/null' \
	-O file - 2>'$OUT/source.log' | '$MOQ' ${CONN_H[*]} --broadcast '$BC' ${IMP[*]} 2>'$OUT/pub.log'" &
GROUPS_+=($!)
ev "publisher-start"
sleep 2
setsid "$MOQ" "${CONN_H[@]}" --broadcast "$BC" "${EXP[@]}" >/dev/null 2>"$OUT/anchor.log" &
GROUPS_+=($!)
ev "anchor-start"
sleep 5

leg() { # moq connect-args dir qlog-args
	echo "'$1' $4 $2 --broadcast '$BC' ${EXP[*]} 2>$3/sub.log \
	| python3 $SCRIPTS/t18-latency.py tap $VPID $3/eg.csv --pipe --seconds $TAP_S --save $3/out.ts > /dev/null"
}
QARGS=""
MOQ_I=$MOQ
if [ -n "$QLOG_MOQ" ]; then
	mkdir -p "$OUT/qlog"
	MOQ_I=$QLOG_MOQ
	QARGS="--quic-qlog $OUT/qlog"
fi
setsid ip netns exec t72i bash -c "$(leg "$MOQ_I" "${CONN_I[*]}" "$OUT" "$QARGS")" 2>"$OUT/egress.err" &
LEGS+=($!)
setsid ip netns exec t72c bash -c "$(leg "$MOQ" "${CONN_C[*]}" "$OUT/ctl" "")" 2>"$OUT/ctl/egress.err" &
LEGS+=($!)
ev "legs-start"

first=0
for _ in $(seq 1 $((2 * DELAY_MS / 50 + 600))); do
	[ -s "$OUT/out.ts" ] && { first=1; break; }
	sleep 0.05
done
[ "$first" = 1 ] || { echo "the impaired leg never wrote; see $OUT/sub.log" >&2; exit 1; }
t0=$EPOCHREALTIME
ev "first-output"
for _ in $(seq 1 400); do
	[ -s "$OUT/ctl/out.ts" ] && { ev "ctl-first-output"; break; }
	sleep 0.05
done
at() { sleep "$(python3 -c "print(max(0.0, $t0 + $1 - $EPOCHREALTIME))")"; }

case "$SHAPE" in
outage)
	at "$SETTLE"
	netem delay "${PATH_DELAY_MS}ms" loss 100%
	ev "impair-start loss=100"
	at "$((SETTLE + OUTAGE))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
loss*)
	at "$SETTLE"
	netem delay "${PATH_DELAY_MS}ms" loss "${SHAPE#loss}%"
	ev "impair-start loss=${SHAPE#loss}"
	at "$((SETTLE + HELD))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
reorder*)
	at "$SETTLE"
	netem delay "${REORDER_DELAY_MS}ms" reorder "${SHAPE#reorder}%" 50%
	ev "impair-start reorder=${SHAPE#reorder}"
	at "$((SETTLE + HELD))"
	netem delay "${PATH_DELAY_MS}ms"
	ev "impair-end"
	;;
step*)
	at "$SETTLE"
	bottleneck handle 10: cake bandwidth "${SHAPE#step}mbit" || exit 1
	ev "impair-start rate=${SHAPE#step}"
	at "$((SETTLE + HELD))"
	tc -s qdisc show dev v72i >"$OUT/bottleneck.txt" 2>&1
	restore_cake
	ev "impair-end"
	;;
shallow*)
	at "$SETTLE"
	bottleneck handle 20: tbf rate "${SHAPE#shallow}mbit" burst "$TBF_BURST" limit "$TBF_LIMIT" || exit 1
	ev "impair-start shallow=${SHAPE#shallow} burst=$TBF_BURST limit=$TBF_LIMIT"
	at "$((SETTLE + HELD))"
	tc -s qdisc show dev v72i >"$OUT/bottleneck.txt" 2>&1
	restore_cake
	ev "impair-end"
	;;
esac
at "$WINDOW"
# A leg whose subscriber is gone before the stop ended early: its session closed or it exited.
[ -n "$(in_group "${LEGS[0]}" "[-]-broadcast $BC")" ] || touch "$OUT/ended-early"
[ -n "$(in_group "${LEGS[1]}" "[-]-broadcast $BC")" ] || touch "$OUT/ctl/ended-early"
stop_legs
ev "stop"
for _ in $(seq 1 100); do
	pgrep -f "[t]18-latency.py tap $VPID $OUT/(ctl/)?eg.csv" >/dev/null || break
	sleep 0.1
done
tc -s qdisc show dev v72i >"$OUT/qdisc.txt" 2>&1
udp t72i "$OUT/udp.txt"
udp t72c "$OUT/ctl/udp.txt"
trap - EXIT
cleanup
ev "end"

# The control leg's events: the impaired leg's, its own first output in place of that leg's.
awk '$2 == "first-output" {next} $2 == "ctl-first-output" {$2 = "first-output"} {print}' \
	"$OUT/events.log" >"$OUT/ctl/events.log"
ln -s ../src.csv "$OUT/ctl/src.csv"
python3 "$SCRIPTS/t84-moq-grade.py" "$OUT/ctl" >"$OUT/ctl/grade.line"
python3 "$SCRIPTS/t84-moq-grade.py" "$OUT" | tee "$OUT/grade.line"
[ -n "${KEEP_TS:-}" ] || rm -f "$OUT/out.ts" "$OUT/ctl/out.ts"
