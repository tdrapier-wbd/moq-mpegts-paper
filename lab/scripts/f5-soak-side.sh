#!/usr/bin/env bash
# Hold a fixed fan-out for a long time and watch what moves.
#
#   f5-soak-side.sh <label> <relay-ip> <n> <duration-s> [sample-s]
#   e.g. f5-soak-side.sh rss10 34.246.187.61 10 2700 20
#
# [T26](../test-26-cross-host-fanout.md)'s instrument, `f5-sub-side.sh`, ramps N and measures each
# point once. That is the right shape for a knee and the wrong shape for anything that develops:
# every reading there has N and elapsed time moving together, so a cost that grows with time is
# indistinguishable from one that grows with N. The first attempt at a high-fan-out soak was run on
# that instrument and made exactly that mistake — it reported a delivery collapse at a fixed N=100
# that was actually this host running out of memory after nine minutes.
#
# So this holds N still and lets time be the only variable.
#
# **The stop condition is memory headroom on this host, and it is the point of the script.** The
# earlier run stopped on a *delivery* threshold, which is a symptom: by the time per-subscriber
# throughput fell, the kernel had already OOM-killed a subscriber and spent 38 M direct-reclaim
# scans, so the number the harness recorded was a measurement of its own thrashing. Watching
# `MemAvailable` stops the run while the readings still mean something, and names the harness as the
# reason rather than inferring a relay limit from a curve that bent.
#
# Per-process RSS is kept per sample, not just its sum, because "the total grew" cannot distinguish
# a set of processes that are each settling from a set that are each leaking, and those have
# opposite consequences for a 24/7 service.
set -uo pipefail

LABEL=${1:?label}
RELAY_IP=${2:?relay ip}
N=${3:?subscriber count}
DURATION=${4:-2700}
SAMPLE=${5:-20}

MOQ=${MOQ:?set MOQ to the moq binary}
BCAST=${BCAST:-f5.fanout.hang}
PORT=${PORT:-4443}
LATMAX=${LATMAX:-3s}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
SRCGEN=${SRCGEN:-$HOME/f5/ts-continuous-source.py}
LIVENESS=${LIVENESS:-$HOME/f5/ts-liveness.py}
OUT=${OUT:-$HOME/f5}/$LABEL
GSO=${GSO:-true}

# Stop while the readings are still trustworthy: 2.5 GB is comfortably more than the largest
# single subscriber plus the kernel's reclaim working set on this box.
MIN_AVAIL_MB=${MIN_AVAIL_MB:-2500}

[ -x "$MOQ" ] || {
	echo "f5-soak: missing $MOQ" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
NIC=${NIC:-ens5}

SUBS=()
cleanup() {
	for p in "${SUBS[@]+${SUBS[@]}}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[-]-broadcast $BCAST export ts" 2>/dev/null || true
	pkill -f "[-]-broadcast $BCAST import ts" 2>/dev/null || true
	pkill -f "[t]s-continuous-source.py" 2>/dev/null || true
	pkill -f "[t]sp -I file $OUT/fifo" 2>/dev/null || true
	pkill -f "[t]s-liveness.py $OUT/fifo" 2>/dev/null || true
	rm -f "$OUT"/fifo.* 2>/dev/null || true
}
trap cleanup EXIT
ulimit -n 65536 2>/dev/null || true

avail_mb() { awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo; }
cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
wchar() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }
rss_kb() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
box_busy() { awk '/^cpu /{i=$5+$6; t=0; for(j=2;j<=NF;j++)t+=$j; print t, i}' /proc/stat; }

{
	echo "label=$LABEL relay=$RELAY_IP:$PORT n=$N duration=${DURATION}s sample=${SAMPLE}s"
	echo "moq=$("$MOQ" --version 2>&1 | head -1) latency_max=$LATMAX client_quic_gso=$GSO"
	echo "host=$(hostname) cores=$(nproc) nic=$NIC mem_total_mb=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)"
	echo "started=$(date -u +%FT%T%z)"
	echo "stop_if: MemAvailable<${MIN_AVAIL_MB}MB OR a subscriber exits OR the publisher exits"
} >"$OUT/meta.txt"

CONN=(--client-tls-disable-verify --client-connect "https://$RELAY_IP:$PORT/anon"
	"--client-quic-gso=$GSO")
echo "f5 soak side: n=$N for ${DURATION}s, relay=$RELAY_IP:$PORT, stop below ${MIN_AVAIL_MB}MB free"

[ -f "$SRCGEN" ] || {
	echo "f5-soak: missing source generator $SRCGEN" >&2
	exit 1
}
(python3 "$SRCGEN" "$CLIP" |
	tsp -I file - -P regulate --pcr-synchronous --wait-min 5 -O file - |
	"$MOQ" "${CONN[@]}" --broadcast "$BCAST" import ts) >"$OUT/publisher.log" 2>&1 &
PUB_PID=$!
sleep 8
kill -0 "$PUB_PID" 2>/dev/null || {
	echo "f5-soak: publisher died — see $OUT/publisher.log" >&2
	exit 1
}
PUB_IMPORT=$(pgrep -f "[-]-broadcast $BCAST import ts" | head -1)
echo "  publisher up (import pid $PUB_IMPORT)"

# Subscriber 1 is graded for continuity, subscriber 2 for per-elementary-stream liveness. Both
# grade in-stream and keep nothing: a soak of this length would otherwise need disk in proportion
# to its own duration, which is the one resource a permanence test must not consume.
#
# The liveness detector is the T24 recommendation as an actual running process rather than an
# offline grader, so this run also serves as its first test against a real cross-host lane instead
# of a synthetic stimulus. Its own output is the evidence; a clean run must produce no alarm.
for i in $(seq 1 "$N"); do
	case $i in
	1)
		f="$OUT/fifo.1"
		rm -f "$f"
		mkfifo "$f"
		tsp -I file "$f" -P continuity -P count --total --interval 400000 -O drop \
			>"$OUT/continuity.log" 2>&1 &
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>"$f" 2>"$OUT/sub.1.log" &
		SUBS+=("$!")
		;;
	2)
		f="$OUT/fifo.2"
		rm -f "$f"
		mkfifo "$f"
		python3 "$LIVENESS" "$f" >"$OUT/liveness.log" 2>&1 &
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>"$f" 2>"$OUT/sub.2.log" &
		SUBS+=("$!")
		;;
	*)
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>/dev/null 2>/dev/null &
		SUBS+=("$!")
		;;
	esac
	sleep 0.15
done
echo "  $N subscribers up; 1 graded for continuity, 1 for per-PID liveness"

CSV="$OUT/soak.csv"
echo "t_s,n_alive,avail_mb,sub_rss_sum_kb,sub_rss_mean_kb,sub_rss_max_kb,sub_cpu_pct_core,per_sub_bps,box_busy_pct,rx_bytes_delta,pub_rss_kb" >"$CSV"
RSSCSV="$OUT/per-process-rss.csv"
echo "t_s,pid,rss_kb" >"$RSSCSV"

T_START=$(date +%s)
read -r BT0 BI0 <<<"$(box_busy)"
C0=0
W0=0
for p in "${SUBS[@]}"; do
	C0=$((C0 + $(cpu_ticks "$p")))
	W0=$((W0 + $(wchar "$p")))
done
RX0=$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)
TP0=$T_START
HZ=$(getconf CLK_TCK)
STOP_REASON=""

while :; do
	sleep "$SAMPLE"
	NOW=$(date +%s)
	EL=$((NOW - T_START))

	ALIVE=0
	SUM=0
	MAX=0
	C1=0
	W1=0
	for p in "${SUBS[@]}"; do
		if kill -0 "$p" 2>/dev/null; then
			ALIVE=$((ALIVE + 1))
			r=$(rss_kb "$p")
			r=${r:-0}
			SUM=$((SUM + r))
			[ "$r" -gt "$MAX" ] && MAX=$r
			echo "$EL,$p,$r" >>"$RSSCSV"
		fi
		C1=$((C1 + $(cpu_ticks "$p")))
		W1=$((W1 + $(wchar "$p")))
	done

	read -r BT1 BI1 <<<"$(box_busy)"
	RX1=$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)
	WIN=$((NOW - TP0))
	[ "$WIN" -lt 1 ] && WIN=1
	AV=$(avail_mb)
	PER=$(awk -v b=$((W1 - W0)) -v w="$WIN" -v n="$ALIVE" 'BEGIN{printf "%.0f", (n>0? b*8/w/n : 0)}')
	MEAN=$(awk -v s="$SUM" -v n="$ALIVE" 'BEGIN{printf "%.0f", (n>0? s/n : 0)}')

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$EL" "$ALIVE" "$AV" "$SUM" "$MEAN" "$MAX" \
		"$(awk -v c=$((C1 - C0)) -v w="$WIN" -v hz="$HZ" 'BEGIN{printf "%.2f", c/hz/w*100}')" \
		"$PER" \
		"$(awk -v dt=$((BT1 - BT0)) -v di=$((BI1 - BI0)) 'BEGIN{printf "%.1f", (dt>0? (dt-di)/dt*100 : 0)}')" \
		"$((RX1 - RX0))" "$(rss_kb "$PUB_IMPORT")" >>"$CSV"

	C0=$C1
	W0=$W1
	BT0=$BT1
	BI0=$BI1
	RX0=$RX1
	TP0=$NOW

	if [ $((EL % 300)) -lt "$SAMPLE" ]; then
		printf 't=%-6s alive=%-4s free=%-6sMB rss/sub=%s MB  max=%s MB  per_sub=%s Mb/s\n' \
			"$EL" "$ALIVE" "$AV" \
			"$(awk -v s="$SUM" -v n="$ALIVE" 'BEGIN{printf "%.1f", (n>0? s/n/1024 : 0)}')" \
			"$(awk -v m="$MAX" 'BEGIN{printf "%.1f", m/1024}')" \
			"$(awk -v p="$PER" 'BEGIN{printf "%.2f", p/1e6}')"
	fi

	if [ "$ALIVE" -lt "$N" ]; then
		STOP_REASON="a subscriber exited at t=${EL}s ($((N - ALIVE)) of $N gone) — see the logs, this is not a capacity result"
		break
	fi
	if ! kill -0 "$PUB_PID" 2>/dev/null; then
		STOP_REASON="the PUBLISHER exited at t=${EL}s — nothing after this is a fan-out result"
		break
	fi
	if [ "$AV" -lt "$MIN_AVAIL_MB" ]; then
		STOP_REASON="THIS host (subscribers) fell to ${AV}MB available at t=${EL}s — the harness is the limit, not the relay"
		break
	fi
	if [ "$EL" -ge "$DURATION" ]; then
		STOP_REASON="duration reached"
		break
	fi
done

echo "stop_reason=$STOP_REASON" | tee -a "$OUT/meta.txt"
echo "finished=$(date -u +%FT%T%z)" >>"$OUT/meta.txt"
echo "f5 soak side done: $CSV"
