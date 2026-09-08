#!/usr/bin/env bash
# F5 relay side — the relay ALONE on this host, sampled once a second.
#
#   f5-relay-side.sh <label> <total-seconds> [rate_bps]
#
# Runs on the host under test. Every previous fan-out figure in this campaign was measured with the
# subscribers co-resident, so [T9](../test-9-performance.md) found a knee at N = 55 that turned out to
# be the box running out of cores: the subscriber processes cost 2.4x the relay's own CPU, and the rig
# hit 94 % of both cores while the relay was using under half of one. Putting the subscribers on
# another machine is the whole point — this script therefore measures only what runs here, and the
# subscriber side is measured by its own script on its own host.
#
# **The publisher runs on the subscriber host, not here.** It is tempting to keep the source next to
# the relay, but the source chain (a Python rewriter, `tsp regulate` and an importer) costs an
# appreciable fraction of a core, and on a 2-vCPU relay host that fraction is subtracted from exactly
# the resource whose ceiling this experiment is trying to find. Sending the feed up from the other
# host costs one 11 Mb/s ingress stream and buys a relay host whose CPU is the relay's alone.
#
# This host also carries standing CNN services which are deliberately left running: they cost a
# steady ~13 % of the two cores, they are recorded in meta.txt, and per-process accounting means they
# do not enter the relay's own CPU figure. They *do* move the box's saturation point earlier, which is
# why the relay's own utilisation is reported alongside the box's rather than instead of it.
#
# The instrument that matters most is the last one. `ethtool -S ens5` on a Nitro instance exposes the
# counters AWS increments when it throttles the interface, so "the relay stopped scaling" and "EC2
# started policing the NIC" are separable by direct evidence rather than by argument. A c6in.large
# sustains 3.125 Gb/s, which is ~280 subscribers at 11 Mb/s, so these should stay at zero — but a
# fan-out experiment that cannot prove that is not worth running.
set -uo pipefail

LABEL=${1:?label}
TOTAL=${2:?total seconds}
RATE=${3:-11000000}

RELAY=${RELAY:?set RELAY to the moq-relay binary}
BCAST=${BCAST:-f5.fanout.hang}
PORT=${PORT:-4443}
OUT=${OUT:-$HOME/f5}/$LABEL
# UDP GSO lets one syscall carry many datagrams, so on an egress-bound relay it is
# the single largest term in cost per subscriber. This campaign's start commands
# carry `--server-quic-gso=false`, but the reason recorded for that flag is that
# *GSO stalls on macOS loopback* — and these hosts are Linux. Left off here it
# would quietly measure a handicapped relay, so it is a knob with both settings
# run, and the deployable configuration is the one with it on.
GSO=${GSO:-true}
# Optionally pin the relay to a subset of cores. This is how the scaling model gets
# tested rather than merely fitted: the GSO-enabled slope says one core serves about
# 124 subscribers, and the subscriber host runs out of memory at about 150 clients,
# so the relay's own two-core ceiling sits just beyond what the harness can reach.
# Pinning to one core halves the prediction and brings the cliff inside range, which
# turns "extrapolated ceiling" into a number the rig can either hit or miss.
CPUSET=${CPUSET:-}

NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
NIC=${NIC:-ens5}

[ -x "$RELAY" ] || {
	echo "f5: missing binary $RELAY" >&2
	exit 1
}

if ss -ulnp 2>/dev/null | grep -q ":$PORT "; then
	echo "f5: something is already bound to UDP $PORT — its numbers would not be ours" >&2
	exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
KIDS=()
cleanup() {
	for p in "${KIDS[@]+${KIDS[@]}}"; do
		kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
	done
	sleep 1
	for p in "${KIDS[@]+${KIDS[@]}}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[m]oq-relay --server-bind 0.0.0.0:$PORT" 2>/dev/null || true
}
trap cleanup EXIT

# ---- relay ------------------------------------------------------------------
# Bound on all interfaces because the subscribers are on another host, which is
# the one thing this experiment changes relative to every earlier fan-out cell.
PIN=()
[ -n "$CPUSET" ] && PIN=(taskset -c "$CPUSET")
"${PIN[@]}" "$RELAY" --server-bind "0.0.0.0:$PORT" --tls-generate "$(hostname -I | awk '{print $1}')" \
	--auth-public "" "--server-quic-gso=$GSO" \
	>"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
KIDS+=("$RELAY_PID")
sleep 2
kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "f5: relay died — see $OUT/relay.log" >&2
	exit 1
}

relay_pid() { pgrep -f "[m]oq-relay --server-bind 0.0.0.0:$PORT" | head -1; }

RP=$(relay_pid)
echo "f5 relay side: label=$LABEL relay_pid=$RP nic=$NIC rate=$RATE total=${TOTAL}s"

# The standing load, measured rather than assumed, so the box column can be read
# against it later. Taken before any subscriber connects.
read -r BT0 BI0 <<<"$(awk '/^cpu /{i=$5+$6; t=0; for(j=2;j<=NF;j++)t+=$j; print t, i}' /proc/stat)"
sleep 5
read -r BT1 BI1 <<<"$(awk '/^cpu /{i=$5+$6; t=0; for(j=2;j<=NF;j++)t+=$j; print t, i}' /proc/stat)"
IDLE_BUSY=$(awk -v dt=$((BT1 - BT0)) -v di=$((BI1 - BI0)) 'BEGIN{printf "%.1f", (dt>0? (dt-di)/dt*100 : 0)}')

{
	echo "label=$LABEL rate=$RATE total=$TOTAL nic=$NIC port=$PORT bcast=$BCAST"
	echo "relay=$("$RELAY" --version 2>&1 | head -1) relay_pid=$RP"
	echo "host=$(hostname) cores=$(nproc) started=$(date -u +%FT%T%z)"
	echo "publisher=remote (on the subscriber host) role=relay-only"
	echo "server_quic_gso=$GSO cpuset=${CPUSET:-all}"
	echo "standing_box_busy_pct_before_subscribers=$IDLE_BUSY"
} >"$OUT/meta.txt"
echo "  standing load on this host, before any subscriber: ${IDLE_BUSY}% of $(nproc) cores"

cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
rss_kb() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
nthr() { awk '/^Threads/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
nfd() { ls "/proc/$1/fd" 2>/dev/null | wc -l; }
nic_stat() { cat "/sys/class/net/$NIC/statistics/$1" 2>/dev/null || echo 0; }
allow() { ethtool -S "$NIC" 2>/dev/null | awk -v k="$1:" '$1==k{print $2}'; }
box_busy() { awk '/^cpu /{i=$5+$6; t=0; for(j=2;j<=NF;j++)t+=$j; print t, i}' /proc/stat; }

CSV="$OUT/relay.csv"
echo "epoch,relay_cpu_ticks,relay_rss_kb,relay_thr,relay_fd,box_total,box_idle,tx_bytes,tx_packets,rx_bytes,bw_out_exc,bw_in_exc,pps_exc,conntrack_exc,udp_socks" >"$CSV"

END=$(($(date +%s) + TOTAL))
while [ "$(date +%s)" -lt "$END" ]; do
	read -r BT BI <<<"$(box_busy)"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$(date +%s)" \
		"$(cpu_ticks "$RP")" "$(rss_kb "$RP")" "$(nthr "$RP")" "$(nfd "$RP")" \
		"$BT" "$BI" \
		"$(nic_stat tx_bytes)" "$(nic_stat tx_packets)" "$(nic_stat rx_bytes)" \
		"$(allow bw_out_allowance_exceeded)" "$(allow bw_in_allowance_exceeded)" \
		"$(allow pps_allowance_exceeded)" "$(allow conntrack_allowance_exceeded)" \
		"$(ss -uan 2>/dev/null | grep -c ":$PORT ")" \
		>>"$CSV"
	# A relay that dies mid-ramp invalidates every later row, and a ramp that
	# keeps sampling a dead pid records plausible zeros instead.
	kill -0 "$RP" 2>/dev/null || {
		echo "f5: RELAY DIED at $(date -u +%FT%T)" | tee -a "$OUT/events.log" >&2
		break
	}
	sleep 1
done

echo "finished=$(date -u +%FT%T%z) rows=$(($(wc -l <"$CSV") - 1))" >>"$OUT/meta.txt"
echo "f5 relay side done: $CSV"
