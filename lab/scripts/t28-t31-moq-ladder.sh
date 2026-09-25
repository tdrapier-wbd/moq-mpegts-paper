#!/usr/bin/env bash
# T28's outage ladder and T31's step-capacity ladder on the MoQ lane, in the T8b namespace rig.
#
# Both experiments want the same thing from the same apparatus — a shaped bottleneck between a
# publisher and a subscriber, with programme loss graded in the media domain — so they share one
# rig setup here rather than paying for it twice. T31 steps the *capacity*; T28 removes it
# entirely for a fixed duration. The grader is the same for both: `t28-content-lost.py`, validated
# by `t28-content-selftest.sh`, with `t2831-conservation.py` run over the summary afterwards
# because a picture that stops before the window closes leaves no hole to count.
#
# Linux only: it needs network namespaces and `tc`. Run on a host with passwordless sudo.
#
# The control is the point. A ladder cell that reports "media lost" has to be read against an
# unimpaired cell through the same rig, on the same clip, at the same provisioned rate -- the
# netns path and the exporter's own behaviour both contribute a floor, and without the control
# that floor is indistinguishable from the impairment's cost.
#
# Usage: sudo t28-t31-moq-ladder.sh [cell ...]        (default: all)
#   cells: control step-0.8x-5s step-1.2x-60s step-0.9x-60s step-0.5x-60s step-0.8x-perm
#          outage-0.5s outage-5s outage-20s outage-30s outage-40s
#          step-<m>x-60s for any multiple m, e.g. step-1.0x-60s, step-0.95x-60s
#
# T31's rungs are multiples of STREAM_MBIT, the fixture's own rate, because a shortfall is only
# a shortfall relative to the stream. 0.9x is the mild sustained case the absolute-rate ladder
# could not express; 1.2x is the headroom control that ladder mistook for one.
#
# The 20s/30s/40s outages bracket `--quic-idle-timeout`, which defaults to 30s on both the relay and
# the client. A 30s outage therefore lands exactly on the boundary and cannot distinguish a starved
# session from a dead one. Set MOQ_QUIC_IDLE_TIMEOUT (honoured by both binaries, and inherited
# through `ip netns exec`) to move the boundary and run the same three outages either side of it.
# Use a separate OUT per idle-timeout setting rather than adding a column: the summary schema is
# positional and has already cost one wrong results table.
#
# **Grade on content, not on the clock.** `t28-media-lost.py` reads the PCR timeline, and
# `export ts` keeps writing PCR across the video groups it evicts while audio carries on, so on
# a congested cell it reports a fraction of what the picture lost -- padded or not. Every cell is
# graded by `t28-content-lost.py` too, on video and audio PTS; the PCR column is kept so the two
# can be compared, and is not the result.
#
# Two knobs this ladder ran without, and which every MoQ figure must now name:
#   MOQ_CC        the relay's congestion controller, `delay` (what an unset flag resolves to:
#                 BBRv3 on noq builds, BBRv1 on quinn builds) or `loss` (CUBIC). The relay sends
#                 into the bottleneck, so its controller is the lane's.
#   MOQ_MUX_RATE  passed to `export ts --mux-rate`. `0` suppresses the padding builds from
#                 moq-dev #3831 onward apply by default; unset leaves the build's default.
#   KEEP_TS=1     keeps every capture for re-grading, not just the lossy ones.
#   SUPERVISE=1   restarts the exporter whenever it exits, appending to the same capture, as a
#                 process supervisor on a standing egress would; each exit is logged to
#                 `<cell>.restarts`.

set -u

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

NETNS="${NETNS:-$HOME/t8b-netns.sh}"
MOQ="${MOQ:-$HOME/bin-3529/moq}"
moq_cli_detect "$MOQ" "${RELAY:-${RELAY_BIN:-}}"
RELAY="${RELAY:-$HOME/bin-3529/moq-relay}"
CLIP="${CLIP:-$HOME/clip120.ts}"
GRADER="${GRADER:-$HOME/t28-media-lost.py}"
CONTENT="${CONTENT:-$HOME/t28-content-lost.py}"
OUT="${OUT:-$HOME/t28t31}"
MOQ_CC="${MOQ_CC:-delay}"
MUX=()
[ -n "${MOQ_MUX_RATE:-}" ] && MUX=(--mux-rate "$MOQ_MUX_RATE")

PROV_MBIT=20    # provisioned rate: comfortably above the clip
# T31's rungs are multiples of the *stream* rate, not absolute rates. Written as absolute
# rates they measured something else: against this campaign's ~9.95 Mb/s fixture the specified
# "sustained moderate shortfall" of 12 Mb/s carries 20 % headroom and is not a shortfall at
# all, so the cell returned zero for arithmetic reasons and its zero said nothing about
# capacity. Set STREAM_MBIT to the fixture's own rate and the ladder follows it.
STREAM_MBIT="${STREAM_MBIT:-9.95}"
# Multiple of stream rate -> shaped bandwidth in Mb/s, to two decimals so a 0.9x rung does not
# round into headroom.
rate_for() { awk -v s="$STREAM_MBIT" -v m="$1" 'BEGIN{printf "%.2f", s*m}'; }
DELAY_MS=50     # 100 ms base RTT, as T8b
LATMAX="${LATMAX:-3s}"
SETTLE=20       # seconds of clean delivery before the impairment
RECOVER=35      # seconds after it is lifted; must exceed one QUIC idle/recovery cycle
PORT=4443
IP_PUB=10.99.0.1

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
for f in "$NETNS" "$MOQ" "$RELAY" "$CLIP" "$GRADER" "$CONTENT"; do
	[ -r "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
command -v tsp >/dev/null || { echo "FAIL: tsp not found" >&2; exit 1; }

# A survivor from a previous pass still holds :$PORT in the t8b-pub namespace, so this run's relay
# dies at bind while the old one answers the subscriber and the cell silently measures the wrong
# relay. Refuse to start rather than produce that. One replicate is one invocation of this script:
# the teardown that releases the port runs on exit, not between cells.
if pgrep -f "t28t31[.]bench" >/dev/null 2>&1; then
	echo "FAIL: a t28t31.bench process from a previous pass is still running:" >&2
	pgrep -af "t28t31[.]bench" >&2
	echo "kill it and let $PORT clear before re-running" >&2
	exit 1
fi

CELLS=("$@")
[ ${#CELLS[@]} -eq 0 ] && CELLS=(control step-0.8x-5s step-1.2x-60s step-0.9x-60s step-0.5x-60s step-0.8x-perm outage-0.5s outage-5s outage-30s)

mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"
echo "cell,experiment,impairment,window_s,capture_bytes,media_lost_s,media_dup_s,holes,largest_hole_s,continuity_errors,video_lost_s,video_largest_s,audio_lost_s,null_pct,cc,mux_rate" >"$SUMMARY"
{
	moq_record_build "$MOQ" "$RELAY"
	cat "$(dirname "$MOQ").sha" 2>/dev/null || echo "sha: no sidecar for $(dirname "$MOQ")"
	echo "relay controller: $MOQ_CC; export mux-rate: ${MOQ_MUX_RATE:-build default}"
} | tee "$OUT/build.txt"

# Re-shape the live bottleneck without tearing the qdisc down: `change` keeps the queue in
# place, where a del/add would itself drop the backlog and be scored as the impairment.
set_rate() { ip netns exec t8b-pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${1}mbit" >/dev/null 2>&1; }
set_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${PATH_DELAY_MS:-$DELAY_MS}ms" loss "${1}%" limit 100000 >/dev/null 2>&1; }
clear_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${PATH_DELAY_MS:-$DELAY_MS}ms" limit 100000 >/dev/null 2>&1; }

# Some relay builds drain their sessions on SIGTERM for longer than a second (`5d0991b9` does), and
# the next cell's relay then fails to bind :$PORT while the old one answers the subscriber. Wait for
# the relay to exit, and force it after 10 s.
cleanup_procs() {
	# The subscriber first: under SUPERVISE it is the supervisor, which would restart its exporter.
	[ -n "${SUB_PID:-}" ] && kill "$SUB_PID" 2>/dev/null
	pkill -f "t28t31.bench" 2>/dev/null
	[ -n "${PUB_PID:-}" ] && kill "$PUB_PID" 2>/dev/null
	if [ -n "${RELAY_PID:-}" ]; then
		kill "$RELAY_PID" 2>/dev/null
		local _
		for _ in $(seq 10); do
			kill -0 "$RELAY_PID" 2>/dev/null || break
			sleep 1
		done
		kill -9 "$RELAY_PID" 2>/dev/null
	fi
	RELAY_PID=""
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "== bringing the rig up =="
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up || exit 1
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake || exit 1

run_cell() {
	local cell="$1"
	local exp impair window mult
	case "$cell" in
	control)      exp=both;  impair="none";                      window=$((SETTLE + 10 + RECOVER)) ;;
	step-0.8x-5s)   exp=T31; impair="rate -> 0.8x stream for 5s";      window=$((SETTLE + 5 + RECOVER)) ;;
	step-1.2x-60s)  exp=T31; impair="rate -> 1.2x stream for 60s";     window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.9x-60s)  exp=T31; impair="rate -> 0.9x stream for 60s";     window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.5x-60s)  exp=T31; impair="rate -> 0.5x stream for 60s";     window=$((SETTLE + 60 + RECOVER)) ;;
	step-0.8x-perm) exp=T31; impair="rate -> 0.8x stream permanent";   window=$((SETTLE + 45 + 10)) ;;
	outage-0.5s)  exp=T28;   impair="100% loss for 0.5s";         window=$((SETTLE + 1 + RECOVER)) ;;
	outage-5s)    exp=T28;   impair="100% loss for 5s";           window=$((SETTLE + 5 + RECOVER)) ;;
	outage-20s)   exp=T28;   impair="100% loss for 20s";          window=$((SETTLE + 20 + RECOVER)) ;;
	outage-30s)   exp=T28;   impair="100% loss for 30s";          window=$((SETTLE + 30 + RECOVER)) ;;
	outage-40s)   exp=T28;   impair="100% loss for 40s";          window=$((SETTLE + 40 + RECOVER)) ;;
	step-*x-60s)  exp=T31;   mult=${cell#step-}; mult=${mult%x-60s}
	              impair="rate -> ${mult}x stream for 60s";       window=$((SETTLE + 60 + RECOVER)) ;;
	*) echo "unknown cell $cell"; return 1 ;;
	esac

	local cap="$OUT/$cell.ts" log="$OUT/$cell"
	# A fresh broadcast name per cell: a reused name can attach to the previous cell's retained
	# announce and the capture then contains the wrong run.
	local BC="t28t31.bench.${cell//./x}.hang"
	echo
	echo "== $cell ($exp) — $impair, ${window}s window =="

	set_rate $PROV_MBIT; clear_loss

	ip netns exec t8b-pub "$RELAY" "${RELAY_BIND[@]}" "$IP_PUB:$PORT" "${RELAY_TLS[@]}" "$IP_PUB" \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" "$RELAY_CC_FLAG" "$MOQ_CC" --log-level warn >"$log.relay.log" 2>&1 &
	RELAY_PID=$!
	sleep 3
	kill -0 "$RELAY_PID" 2>/dev/null || echo "   RELAY DID NOT START ($(tail -1 "$log.relay.log")) — this cell is void"

	# Subscriber first: reservation gating publishes the catalog once tracks resolve.
	if [ "${SUPERVISE:-0}" = 1 ]; then
		: >"$cap"
		(
			while :; do
				ip netns exec t8b-sub "$MOQ" "${MOQ_DIAL[0]}" \
					"${MOQ_DIAL[1]}" "https://$IP_PUB:$PORT" --broadcast "$BC" \
					export ts "${MOQ_LAT[@]}" "$LATMAX" "${MUX[@]}" >>"$cap" 2>>"$log.sub.log"
				rc=$?
				echo "$(date +%s.%N) exit $rc" >>"$log.restarts"
				sleep 1
			done
		) &
	else
		ip netns exec t8b-sub "$MOQ" "${MOQ_DIAL[0]}" \
			"${MOQ_DIAL[1]}" "https://$IP_PUB:$PORT" --broadcast "$BC" \
			export ts "${MOQ_LAT[@]}" "$LATMAX" "${MUX[@]}" >"$cap" 2>"$log.sub.log" &
	fi
	SUB_PID=$!
	sleep 2

	ip netns exec t8b-pub bash -c \
		"tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
		 | '$MOQ' ${MOQ_DIAL[*]} 'https://$IP_PUB:$PORT' \
		     --broadcast '$BC' import ts" >"$log.pub.log" 2>&1 &
	PUB_PID=$!

	sleep "$SETTLE"
	local t_impair
	t_impair=$(date +%s.%N)
	case "$cell" in
	control)     sleep 10 ;;
	step-0.8x-5s)   set_rate "$(rate_for 0.8)"; sleep 5;  set_rate $PROV_MBIT ;;
	step-1.2x-60s)  set_rate "$(rate_for 1.2)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.9x-60s)  set_rate "$(rate_for 0.9)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.5x-60s)  set_rate "$(rate_for 0.5)"; sleep 60; set_rate $PROV_MBIT ;;
	step-0.8x-perm) set_rate "$(rate_for 0.8)"; sleep 45 ;;
	outage-0.5s) set_loss 100; sleep 0.5; clear_loss ;;
	outage-5s)   set_loss 100; sleep 5;   clear_loss ;;
	outage-20s)  set_loss 100; sleep 20;  clear_loss ;;
	outage-30s)  set_loss 100; sleep 30;  clear_loss ;;
	outage-40s)  set_loss 100; sleep 40;  clear_loss ;;
	step-*x-60s) set_rate "$(rate_for "$mult")"; sleep 60; set_rate $PROV_MBIT ;;
	esac
	echo "   impairment applied at $t_impair, now recovering for ${RECOVER}s"
	case "$cell" in
	step-0.8x-perm) sleep 10 ;;
	*) sleep "$RECOVER" ;;
	esac

	cleanup_procs
	[ "${SUPERVISE:-0}" = 1 ] && echo "   exporter exits under supervision: $( (wc -l <"$log.restarts") 2>/dev/null || echo 0)"
	local bytes
	bytes=$(stat -c%s "$cap" 2>/dev/null || echo 0)
	if [ "$bytes" -lt 200000 ]; then
		echo "   CELL VOID: only ${bytes}B captured — the lane did not deliver"
		echo "$cell,$exp,\"$impair\",$window,$bytes,VOID,VOID,VOID,VOID,VOID,VOID,VOID,VOID,VOID,$MOQ_CC,${MOQ_MUX_RATE:-default}" >>"$SUMMARY"
		return 0
	fi

	python3 "$GRADER" --input "$cap" --domain wire --label "$cell" --json "$log.grade.json" 2>&1 | tail -2
	# Graded from 8 s in, past the join hole every capture opens with, as the latency tap is.
	python3 "$CONTENT" --input "$cap" --from-s 8 --label "$cell" --json "$log.content.json" 2>&1 | tail -1
	python3 - "$log.grade.json" "$log.content.json" "$cell" "$exp" "$impair" "$window" "$bytes" \
		"$MOQ_CC" "${MOQ_MUX_RATE:-default}" "$SUMMARY" <<-'PY'
	import json, sys
	g = json.load(open(sys.argv[1]))
	try:
	    c = json.load(open(sys.argv[2]))
	except (OSError, ValueError):
	    c = {}
	row = [sys.argv[3], sys.argv[4], f'"{sys.argv[5]}"', sys.argv[6], sys.argv[7],
	       g["media_lost_s"], g["media_duplicated_s"], g["hole_count"],
	       g["largest_hole_s"], g.get("continuity_errors", "na"),
	       c.get("content_lost_s", "NA"), c.get("largest_hole_s", "NA"), c.get("audio_lost_s", "NA"),
	       c.get("null_pct", "NA"), sys.argv[8], sys.argv[9]]
	open(sys.argv[10], "a").write(",".join(str(x) for x in row) + "\n")
	PY
	# Keep the capture if the *picture* lost anything; the PCR column cannot make that call.
	if [ "${KEEP_TS:-0}" != 1 ] &&
		python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))['content_lost_s']<=0.1 else 1)" "$log.content.json" 2>/dev/null; then
		rm -f "$cap"
	fi
}

for c in "${CELLS[@]}"; do run_cell "$c"; done

echo
echo "== summary =="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
