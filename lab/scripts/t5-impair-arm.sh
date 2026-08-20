#!/usr/bin/env bash
# T5, segmented-HTTP arm — one impairment cell, start to finish, on the origin host.
#
#   t5-impair-arm.sh <arm: hls|moq> <"netem spec"|none> <seconds> <out-dir>
#
# Runs the whole lane on one Linux host so the impairment is controlled rather than
# inferred: publisher, origin/relay and receiver are all local, and `netem` sits on
# `lo` restricted to the lane under test. That restriction is the point. This box
# runs standing moq services that dial `localhost:443`, and a bare
# `tc qdisc add dev lo root netem …` would silently impair them too — so every cell
# builds a `prio` band and filters *one* flow into it:
#
#   hls  -> TCP, source port = the origin's port  (segment payload direction)
#   moq  -> UDP, source port = a private relay's port, never the standing :443
#
# Only the payload direction is shaped, so the base delay is the RTT, not half of it.
#
# The shaper's own passed/dropped counters are read back at the end of every cell and
# printed on the RESULT line. They are the only evidence the impairment reached the
# flow under measurement: a filter that matches nothing shapes nothing, and the cell
# then reads as "impairment made no difference" rather than as a rig failure.
#
# Prints one `RESULT ` line of key=value pairs, and leaves capture + logs in <out-dir>.
set -uo pipefail

ARM=${1:?arm: hls|moq}
SPEC=${2:?netem spec, or "none"}
SECS=${3:?capture seconds}
OUT=${4:?output dir}

SRC=${SRC:-$HOME/CNNiEMEA2.ts}
SEGSECS=${SEGSECS:-2}
PORT=${PORT:-18099}          # hls origin
RELAY_PORT=${RELAY_PORT:-4499} # private relay for the moq control arm
MOQ_BIN=${MOQ_BIN:-$HOME/bin-main-eab96019/moq}
MOQ_RELAY=${MOQ_RELAY:-$HOME/bin-main-eab96019/moq-relay}
CC=${CC:-delay} # `delay` = BBR, `loss` = CUBIC; see the moq arm below for why it is pinned
# The segmented lane's controller, which T5 left at the system default and therefore
# left unrecorded. That default is CUBIC, so T5's loss column compared QUIC/BBR
# against TCP/CUBIC and could not say how much of the difference was the lane and how
# much was the controller. Setting this pins the other half of that 2x2.
TCP_CC=${TCP_CC:-}
IFACE=lo

# Source rate of the fixture, for the delivered-vs-source comparison that is the
# health metric on a lane whose receiver re-muxes (T5 observation 2).
SRC_BPS=${SRC_BPS:-9945951}

# Two loopback defaults have to be undone before a percentage loss model means
# anything, and the second one silently invalidates a *comparison* rather than just
# coarsening a number.
#
# MTU: `lo` defaults to 65536, so `loss 1%` discards 1 % of ~37 kB super-packets
# rather than of wire-sized ones — each drop event tens of times larger and burstier
# than a real path produces. Pinned to 1500 for the run.
#
# Segmentation offload: netem makes its drop decision on the skb it is handed, which
# with TSO/GSO is a super-packet that the stack later splits into many wire packets.
# The commanded percentage is then applied to super-packets while the wire carries
# many times more, and — because TCP and QUIC offload differently — *the two arms
# receive different impairment from the same command*. Measured on the first pass of
# this sweep: at `loss 10%` the segmented lane really lost 7.8 % and the media-aware
# lane 2.5 %, so the arms were never comparable. Offloads are turned off for the run
# so one skb is one wire packet and the shaper's own counters agree with the command.
LO_MTU=${LO_MTU:-1500}
LO_MTU_ORIG=$(cat /sys/class/net/$IFACE/mtu)

set -m # own process group per background job, so teardown takes the children too
rm -rf "$OUT"
mkdir -p "$OUT"

PIDS=()
netem_clear() { sudo tc qdisc del dev $IFACE root 2>/dev/null || true; }
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
	# Kill the watchdog shell itself, not its children: killing its `sleep` would let
	# the shell fall straight through to the `tc` delete it was holding back.
	[ -s "$OUT/watchdog.pid" ] && sudo kill "$(cat "$OUT/watchdog.pid")" 2>/dev/null
	sudo pkill -f "sleep 900; tc qdisc del dev $IFACE root" 2>/dev/null
	netem_clear
	sudo ip link set dev $IFACE mtu "$LO_MTU_ORIG" 2>/dev/null || true
	sudo ethtool -K $IFACE tso on gso on gro on 2>/dev/null || true
	[ -n "$TCP_CC" ] &&
		sudo sysctl -qw net.ipv4.tcp_congestion_control="$TCP_CC_ORIG" 2>/dev/null
}
trap cleanup EXIT

TCP_CC_ORIG=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)
if [ -n "$TCP_CC" ]; then
	sudo modprobe "tcp_$TCP_CC" 2>/dev/null || true
	sudo sysctl -qw net.ipv4.tcp_congestion_control="$TCP_CC" || {
		echo "RESULT arm=$ARM spec=\"$SPEC\" status=tcp_cc_unavailable cc=$TCP_CC"
		exit 1
	}
fi

sudo ip link set dev $IFACE mtu "$LO_MTU"
sudo ethtool -K $IFACE tso off gso off gro off 2>/dev/null || true

# --- impairment lane ----------------------------------------------------------
# A watchdog removes all shaping after 30 min even if this script is killed
# uncleanly, so a dropped session cannot leave the box shaped.
netem_build() {
	local spec=$1 proto sport
	case $ARM in
	hls) proto=6; sport=$PORT ;;
	moq) proto=17; sport=$RELAY_PORT ;;
	esac
	netem_clear
	[ "$spec" = none ] && return 0
	sudo tc qdisc add dev $IFACE root handle 1: prio bands 4 \
		priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
	# shellcheck disable=SC2086
	sudo tc qdisc add dev $IFACE parent 1:4 handle 40: netem $spec
	sudo tc filter add dev $IFACE parent 1:0 protocol ip prio 1 u32 \
		match ip protocol $proto 0xff match ip sport "$sport" 0xffff flowid 1:4
	# A watchdog so a killed run cannot leave the box shaped — but it is cancelled at
	# teardown, and that matters more than it looks. An uncancelled watchdog outlives
	# its own cell and fires into a *later* one, deleting that cell's shaper partway
	# through; the run then reports a clean result for a condition it never
	# experienced. That is what happened on this sweep's first pass, and it is
	# undetectable from the delivered numbers alone — only the shaper's own counters
	# show it, as `sent_pkt=na` against a root qdisc that is no longer there.
	sudo bash -c "nohup sh -c 'sleep 900; tc qdisc del dev $IFACE root' >/dev/null 2>&1 & echo \$!" |
		tee "$OUT/watchdog.pid" >/dev/null || true
}

netem_counters() {
	# netem's own accounting for band 4, kept raw as well as parsed: these counters
	# are the only evidence the impairment reached the flow under measurement.
	tc -s qdisc show dev $IFACE >"$OUT/tc-stats.txt" 2>/dev/null
	python3 - "$OUT/tc-stats.txt" <<-'PY'
		import re, sys
		txt = open(sys.argv[1]).read()
		# the netem qdisc stanza, then the first Sent/dropped line under it
		m = re.search(r'qdisc netem\b.*?Sent (\d+) bytes (\d+) pkt \(dropped (\d+)', txt, re.S)
		print(f"sent_pkt={m.group(2)} dropped_pkt={m.group(3)}" if m
		      else "sent_pkt=na dropped_pkt=na")
	PY
}

netem_build "$SPEC"

CAP=$OUT/capture.ts

case $ARM in
# --- segmented HTTP: tsp -O hls -> HTTP origin -> tsp -I hls -----------------
hls)
	tsp --realtime \
		-I file "$SRC" --infinite \
		-P regulate --pcr-synchronous \
		-O hls "$OUT/seg.ts" \
		--playlist "$OUT/index.m3u8" \
		--duration "$SEGSECS" \
		--live 6 --live-extra-segments 3 \
		--intra-close --align-first-segment \
		>"$OUT/publish.log" 2>&1 &
	PIDS+=($!)

	(cd "$OUT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
		>"$OUT/origin.log" 2>&1 &
	PIDS+=($!)

	# The receiver needs a live edge to join: `tsp -I hls` exits on an empty
	# playlist, and without --live it starts at the playlist's first segment
	# rather than its last.
	for _ in $(seq 1 90); do
		[ -f "$OUT/index.m3u8" ] &&
			[ "$(grep -c '^seg.*\.ts$' "$OUT/index.m3u8" 2>/dev/null || echo 0)" -ge 3 ] && break
		sleep 1
	done
	[ -f "$OUT/index.m3u8" ] || { echo "RESULT arm=$ARM spec=\"$SPEC\" status=no_playlist"; exit 1; }
	cp "$OUT/index.m3u8" "$OUT/playlist-sample.m3u8"

	# A sysctl is a default for sockets opened after it, not a fact about the sockets
	# under measurement, so read the controller back off the origin's own connections
	# while they are carrying the run. A cell that cannot show its controller on the
	# wire is reporting a label, not a condition.
	# Sampled repeatedly rather than once: a segment fetch is a short-lived
	# connection, so a single snapshot usually lands between them and reports
	# nothing, which is indistinguishable from the setting not having applied.
	(
		for _ in $(seq 1 $((SECS * 3))); do
			ss -tin 2>/dev/null | grep -A1 ":$PORT"
			sleep 0.33
		done
	) >"$OUT/ss.txt" 2>&1 &
	SS_PID=$!
	PIDS+=("$SS_PID")

	timeout "$SECS" tsp --realtime \
		-I hls "http://127.0.0.1:$PORT/index.m3u8" --live \
		-O file "$CAP" >"$OUT/receive.log" 2>&1
	;;

# --- MoQ media-aware control, same host, same shaper -------------------------
moq)
	# The controller is pinned rather than left to resolve. It decides this lane's loss
	# result outright — T8 measured collapse above 2 % loss under `loss` (CUBIC) and
	# full rate under `delay` (BBR) — and the resolved default is backend-specific, so
	# an unpinned run records a number without recording what produced it. It goes on
	# the *relay*, which is the sender on the hop being shaped.
	# `--auth-public` takes a value on this build (the standing unit passes ""), and
	# omitting it fails the relay at argument parsing rather than at bind.
	# GSO off as well as the kernel offloads: quinn coalesces datagrams into one
	# `sendmsg` of its own, so `ethtool -K lo gso off` alone still leaves netem
	# dropping super-packets on this arm while the segmented arm gets wire-sized
	# ones — the same confound in a different layer.
	"$MOQ_RELAY" --server-bind "127.0.0.1:$RELAY_PORT" --tls-generate localhost \
		--server-quic-congestion-control "$CC" --server-quic-gso=false \
		--auth-public "" >"$OUT/relay.log" 2>&1 &
	PIDS+=($!)
	sleep 3
	grep -qiE '^error|error:' "$OUT/relay.log" 2>/dev/null &&
		{ echo "RESULT arm=$ARM spec=\"$SPEC\" status=relay_failed"; exit 1; }

	CONNECT=(--client-tls-disable-verify --client-connect "https://127.0.0.1:$RELAY_PORT/anon")
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - \
		2>"$OUT/publish.log" |
		"$MOQ_BIN" "${CONNECT[@]}" --broadcast t5.impair.hang import ts \
			>>"$OUT/publish.log" 2>&1 &
	PIDS+=($!)
	sleep 5

	timeout "$SECS" "$MOQ_BIN" "${CONNECT[@]}" \
		--broadcast t5.impair.hang export ts >"$CAP" 2>"$OUT/receive.log"
	;;
esac

COUNTERS=$(netem_counters)
# The fraction the shaper actually counted, which is the only loss figure two arms
# can be compared at. T5's first pass compared arms on the commanded percentage and
# was wrong by a factor of three for exactly this reason.
APPLIED=$(python3 -c "
import sys
d = dict(p.split('=') for p in '''$COUNTERS'''.split())
try:
    s, dr = int(d['sent_pkt']), int(d['dropped_pkt'])
    print('applied_loss=%.2f' % (100.0 * dr / (s + dr)) if s + dr else 'applied_loss=na')
except Exception:
    print('applied_loss=na')
" 2>/dev/null || echo applied_loss=na)
# A cell whose shaper is missing at the end did not run the condition on its label,
# whatever its delivered numbers look like. Say so on the result line rather than
# publishing a clean-looking row.
SHAPER_OK=yes
case "$COUNTERS" in *sent_pkt=na*) [ "$SPEC" != none ] && SHAPER_OK=NO_SHAPER_AT_END ;; esac
netem_clear

# --- analysis -----------------------------------------------------------------
BYTES=$(stat -c %s "$CAP" 2>/dev/null || echo 0)
MBPS=$(awk -v b="$BYTES" -v s="$SECS" 'BEGIN{printf "%.2f", b*8/s/1e6}')
RATIO=$(awk -v b="$BYTES" -v s="$SECS" -v r="$SRC_BPS" 'BEGIN{printf "%.3f", (b*8/s)/r}')

CCERR=0
PCR="min=0 mean=0 max=0 over40=0 pct40=0"
if [ "$BYTES" -gt 100000 ]; then
	# `continuity` prints one line per discontinuity; on this lane the segments are
	# byte-verbatim slices of the source, so a CC break really does mean lost data
	# — unlike the media-aware lane, where the receiver re-muxes and CC is always
	# sequential (T5 observation 2).
	CCERR=$(tsp -I file "$CAP" -P continuity -O drop 2>&1 | grep -c 'discontinuity' || true)
	tsp -I file "$CAP" -P pcrextract --pcr --csv -o "$OUT/pcr.csv" -O drop >/dev/null 2>&1 || true
	if [ -s "$OUT/pcr.csv" ]; then
		PCR=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;if(d>0){n++;s+=d;if(d>m)m=d;
			if(mn==""||d<mn)mn=d;if(d>40)o++}}p=c}
			END{if(n)printf "min=%.2f mean=%.2f max=%.2f over40=%d pct40=%.2f",mn,s/n,m,o,o/n*100;
			    else printf "min=0 mean=0 max=0 over40=0 pct40=0"}' "$OUT/pcr.csv")
	fi
fi

# Segment-level accounting: the failure mode that is specific to this lane is a
# segment ageing out of the availability window before the client fetches it, which
# shows up as a non-200 at the origin rather than as slow delivery.
# `grep -c` exits 1 on zero matches, so every count needs its own guard or the
# non-zero exit appends a second value and the RESULT line silently gains a field.
HTTP_GETS=$(grep -c '"GET' "$OUT/origin.log" 2>/dev/null || true)
HTTP_NON200=$(grep '"GET' "$OUT/origin.log" 2>/dev/null | grep -vc ' 200 -$' || true)
RECV_ERR=$(grep -ciE 'error|cannot|failed|restart' "$OUT/receive.log" 2>/dev/null || true)
: "${HTTP_GETS:=0}" "${HTTP_NON200:=0}" "${RECV_ERR:=0}"

if [ "$ARM" = moq ]; then
	ARMTAG="moq/cc=$CC"
	CCSEEN=$CC
else
	ARMTAG="hls${TCP_CC:+/cc=$TCP_CC}"
	# whichever controller `ss` named on the origin's sockets, not the one commanded
	CCSEEN=$(sed -n 's/.*[[:space:]]\(bbr\|cubic\|reno\)[[:space:]].*/\1/p' "$OUT/ss.txt" 2>/dev/null |
		sort -u | paste -sd, -)
	: "${CCSEEN:=unseen}"
fi
echo "RESULT arm=$ARMTAG spec=\"$SPEC\" secs=$SECS mtu=$LO_MTU bytes=$BYTES mbps=$MBPS rate_ratio=$RATIO" \
	"cc_disc=$CCERR $PCR http_gets=$HTTP_GETS http_non200=$HTTP_NON200" \
	"recv_log_errs=$RECV_ERR ${COUNTERS:-sent_pkt=na dropped_pkt=na} $APPLIED" \
	"shaper=$SHAPER_OK cc_seen=$CCSEEN"
