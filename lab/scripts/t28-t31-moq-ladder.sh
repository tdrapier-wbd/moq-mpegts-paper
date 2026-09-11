#!/usr/bin/env bash
# T28's outage ladder and T31's step-capacity ladder on the MoQ lane, in the T8b namespace rig.
#
# Both experiments want the same thing from the same apparatus — a shaped bottleneck between a
# publisher and a subscriber, with programme loss graded in the media domain — so they share one
# rig setup here rather than paying for it twice. T31 steps the *capacity*; T28 removes it
# entirely for a fixed duration. The grader is the same for both, and it is the one validated
# against known answers by `t28-grader-selftest.sh`.
#
# Linux only: it needs network namespaces and `tc`. Run on a host with passwordless sudo.
#
# The control is the point. A ladder cell that reports "media lost" has to be read against an
# unimpaired cell through the same rig, on the same clip, at the same provisioned rate -- the
# netns path and the exporter's own behaviour both contribute a floor, and without the control
# that floor is indistinguishable from the impairment's cost.
#
# Usage: sudo t28-t31-moq-ladder.sh [cell ...]        (default: all)
#   cells: control step-8-5s step-12-60s step-8-perm outage-0.5s outage-5s outage-30s

set -u

NETNS="${NETNS:-$HOME/t8b-netns.sh}"
MOQ="${MOQ:-$HOME/bin-3529/moq}"
RELAY="${RELAY:-$HOME/bin-3529/moq-relay}"
CLIP="${CLIP:-$HOME/clip120.ts}"
GRADER="${GRADER:-$HOME/t28-media-lost.py}"
OUT="${OUT:-$HOME/t28t31}"

PROV_MBIT=20    # provisioned rate: comfortably above the ~9.95 Mb/s clip
DELAY_MS=50     # 100 ms base RTT, as T8b
LATMAX="${LATMAX:-3s}"
SETTLE=20       # seconds of clean delivery before the impairment
RECOVER=35      # seconds after it is lifted; must exceed one QUIC idle/recovery cycle
PORT=4443
IP_PUB=10.99.0.1

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
for f in "$NETNS" "$MOQ" "$RELAY" "$CLIP" "$GRADER"; do
	[ -r "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
command -v tsp >/dev/null || { echo "FAIL: tsp not found" >&2; exit 1; }

CELLS=("$@")
[ ${#CELLS[@]} -eq 0 ] && CELLS=(control step-8-5s step-12-60s step-8-perm outage-0.5s outage-5s outage-30s)

mkdir -p "$OUT"
SUMMARY="$OUT/summary.csv"
echo "cell,experiment,impairment,window_s,capture_bytes,media_lost_s,media_dup_s,holes,largest_hole_s,continuity_errors" >"$SUMMARY"

# Re-shape the live bottleneck without tearing the qdisc down: `change` keeps the queue in
# place, where a del/add would itself drop the backlog and be scored as the impairment.
set_rate() { ip netns exec t8b-pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${1}mbit" >/dev/null 2>&1; }
set_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" loss "${1}%" limit 100000 >/dev/null 2>&1; }
clear_loss() { ip netns exec t8b-pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" limit 100000 >/dev/null 2>&1; }

cleanup_procs() {
	pkill -f "t28t31.bench" 2>/dev/null
	[ -n "${SUB_PID:-}" ] && kill "$SUB_PID" 2>/dev/null
	[ -n "${PUB_PID:-}" ] && kill "$PUB_PID" 2>/dev/null
	[ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "== bringing the rig up =="
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up || exit 1
RATE_MBIT=$PROV_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake || exit 1

run_cell() {
	local cell="$1"
	local exp impair window
	case "$cell" in
	control)      exp=both;  impair="none";                      window=$((SETTLE + 10 + RECOVER)) ;;
	step-8-5s)    exp=T31;   impair="rate 20->8 Mb/s for 5s";     window=$((SETTLE + 5 + RECOVER)) ;;
	step-12-60s)  exp=T31;   impair="rate 20->12 Mb/s for 60s";   window=$((SETTLE + 60 + RECOVER)) ;;
	step-8-perm)  exp=T31;   impair="rate 20->8 Mb/s permanent";  window=$((SETTLE + 45 + 10)) ;;
	outage-0.5s)  exp=T28;   impair="100% loss for 0.5s";         window=$((SETTLE + 1 + RECOVER)) ;;
	outage-5s)    exp=T28;   impair="100% loss for 5s";           window=$((SETTLE + 5 + RECOVER)) ;;
	outage-30s)   exp=T28;   impair="100% loss for 30s";          window=$((SETTLE + 30 + RECOVER)) ;;
	*) echo "unknown cell $cell"; return 1 ;;
	esac

	local cap="$OUT/$cell.ts" log="$OUT/$cell"
	# A fresh broadcast name per cell: a reused name can attach to the previous cell's retained
	# announce and the capture then contains the wrong run.
	local BC="t28t31.bench.${cell//./x}.hang"
	echo
	echo "== $cell ($exp) — $impair, ${window}s window =="

	set_rate $PROV_MBIT; clear_loss

	ip netns exec t8b-pub "$RELAY" --server-bind "$IP_PUB:$PORT" --tls-generate "$IP_PUB" \
		--auth-public "" --log-level warn >"$log.relay.log" 2>&1 &
	RELAY_PID=$!
	sleep 3

	# Subscriber first: reservation gating publishes the catalog once tracks resolve.
	ip netns exec t8b-sub "$MOQ" --client-tls-disable-verify \
		--client-connect "https://$IP_PUB:$PORT" --broadcast "$BC" \
		export ts --latency-max "$LATMAX" >"$cap" 2>"$log.sub.log" &
	SUB_PID=$!
	sleep 2

	ip netns exec t8b-pub bash -c \
		"tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null \
		 | '$MOQ' --client-tls-disable-verify --client-connect 'https://$IP_PUB:$PORT' \
		     --broadcast '$BC' import ts" >"$log.pub.log" 2>&1 &
	PUB_PID=$!

	sleep "$SETTLE"
	local t_impair
	t_impair=$(date +%s.%N)
	case "$cell" in
	control)     sleep 10 ;;
	step-8-5s)   set_rate 8;  sleep 5;  set_rate $PROV_MBIT ;;
	step-12-60s) set_rate 12; sleep 60; set_rate $PROV_MBIT ;;
	step-8-perm) set_rate 8;  sleep 45 ;;
	outage-0.5s) set_loss 100; sleep 0.5; clear_loss ;;
	outage-5s)   set_loss 100; sleep 5;   clear_loss ;;
	outage-30s)  set_loss 100; sleep 30;  clear_loss ;;
	esac
	echo "   impairment applied at $t_impair, now recovering for ${RECOVER}s"
	case "$cell" in
	step-8-perm) sleep 10 ;;
	*) sleep "$RECOVER" ;;
	esac

	cleanup_procs
	local bytes
	bytes=$(stat -c%s "$cap" 2>/dev/null || echo 0)
	if [ "$bytes" -lt 200000 ]; then
		echo "   CELL VOID: only ${bytes}B captured — the lane did not deliver"
		echo "$cell,$exp,\"$impair\",$window,$bytes,VOID,VOID,VOID,VOID,VOID" >>"$SUMMARY"
		return 0
	fi

	python3 "$GRADER" --input "$cap" --domain wire --label "$cell" --json "$log.grade.json" 2>&1 | tail -2
	python3 - "$log.grade.json" "$cell" "$exp" "$impair" "$window" "$bytes" "$SUMMARY" <<-'PY'
	import json, sys
	g = json.load(open(sys.argv[1]))
	row = [sys.argv[2], sys.argv[3], f'"{sys.argv[4]}"', sys.argv[5], sys.argv[6],
	       g["media_lost_s"], g["media_duplicated_s"], g["hole_count"],
	       g["largest_hole_s"], g.get("continuity_errors", "na")]
	open(sys.argv[7], "a").write(",".join(str(x) for x in row) + "\n")
	PY
	# Keep the capture only if something was lost; a clean cell's 100+ MB is not worth the disk.
	if python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1]))['media_lost_s']<=0.1 else 1)" "$log.grade.json"; then
		rm -f "$cap"
	fi
}

for c in "${CELLS[@]}"; do run_cell "$c"; done

echo
echo "== summary =="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
