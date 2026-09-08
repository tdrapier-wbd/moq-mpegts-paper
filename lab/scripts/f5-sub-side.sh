#!/usr/bin/env bash
# F5 subscriber side — ramp N remote subscribers against a relay on another host.
#
#   f5-sub-side.sh <label> <relay-ip> <n-schedule> [settle] [measure]
#   e.g. f5-sub-side.sh ramp1 34.246.187.61 "1,5,10,25,50,100,150,200,250,300"
#
# Every subscriber runs here and the relay runs there, so the two costs are separated by *host*
# rather than by process accounting. That matters because process accounting is what
# [T9](../test-9-performance.md) had, and it still could not stop the subscribers' 118 % of a core
# from being the thing that ended the ramp at N = 55.
#
# **The stopping conditions are fixed here, before the run, and one of them is about this host.** A
# ramp that continues past the point where the subscriber box is saturated measures the subscriber
# box; the whole reason for two hosts is to be able to say which side ran out, so the run stops and
# says so rather than producing a curve whose tail belongs to the harness.
#
# Per-subscriber delivered rate comes from /proc/<pid>/io `wchar` — bytes the process has written to
# its stdout — which is the receiver's own view of what arrived, not the relay's claim about what it
# sent.
#
# **Media integrity is graded in-stream rather than captured.** A few of the subscribers pipe into
# `tsp -P continuity -O drop`, which counts continuity errors and discards the bytes: 300 captures at
# 11 Mb/s would fill this disk during the ramp, and the graded subscribers must run for the whole run
# rather than stopping at a byte cap, because a subscriber exiting is one of the stopping conditions
# and a self-inflicted exit would read as a capacity result.
set -uo pipefail

LABEL=${1:?label}
RELAY_IP=${2:?relay ip}
SCHEDULE=${3:-1,5,10,25,50,100,150,200,250,300}
SETTLE=${4:-45}
MEASURE=${5:-45}

MOQ=${MOQ:?set MOQ to the moq binary}
BCAST=${BCAST:-f5.fanout.hang}
PORT=${PORT:-4443}
LATMAX=${LATMAX:-3s}
NCAP=${NCAP:-2} # subscribers graded in-stream for continuity
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
SRCGEN=${SRCGEN:-$HOME/f5/ts-continuous-source.py}
OUT=${OUT:-$HOME/f5}/$LABEL
GSO=${GSO:-true} # see the note in f5-relay-side.sh; must match the relay's setting

# Stopping conditions, fixed in advance.
MIN_KEEP=${MIN_KEEP:-0.95} # per-subscriber rate as a fraction of the N=1 baseline
BOX_LIMIT=${BOX_LIMIT:-85} # this host's busy %, above which the harness is the limit
#
# The reference rate is *measured at the first schedule point*, not declared. A subscriber here is
# `moq export ts` with no pacer behind it, so what arrives is the exporter's media stream at whatever
# the clip's own rate is — not the 11 Mb/s CBR wire the pacer emits in T19/T21. Asserting the CBR
# figure as the target made the smoke run "fail" at N=1 by 18 %, which was the instrument being wrong
# rather than the relay. Calibrating on N=1 also makes the criterion the right one for this question:
# whether a subscriber at high N is served as well as a subscriber that has the relay to itself.
NOMINAL=${NOMINAL:-0} # 0 = calibrate from the first point

[ -x "$MOQ" ] || {
	echo "f5: missing $MOQ" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
CORES=$(nproc)
NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
NIC=${NIC:-ens5}

SUBS=()
cleanup() {
	for p in "${SUBS[@]+${SUBS[@]}}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[-]-broadcast $BCAST export ts" 2>/dev/null || true
	pkill -f "[-]-broadcast $BCAST import ts" 2>/dev/null || true
	pkill -f "[t]s-continuous-source.py" 2>/dev/null || true
	pkill -f "[t]sp -I file $OUT/fifo" 2>/dev/null || true
	rm -f "$OUT"/fifo.* 2>/dev/null || true
}
trap cleanup EXIT

# Raised because the ramp holds a pipe per graded subscriber and a child per
# subscriber; the default 1024 is comfortable at N=50 and not at N=300.
ulimit -n 65536 2>/dev/null || true

{
	echo "label=$LABEL relay=$RELAY_IP:$PORT schedule=$SCHEDULE settle=$SETTLE measure=$MEASURE"
	echo "moq=$("$MOQ" --version 2>&1 | head -1) latency_max=$LATMAX"
	echo "host=$(hostname) cores=$CORES nic=$NIC started=$(date -u +%FT%T%z)"
	echo "stop_if: per_sub<${MIN_KEEP} OR box_busy>${BOX_LIMIT}% OR a subscriber exits"
} >"$OUT/meta.txt"

CONN=(--client-tls-disable-verify --client-connect "https://$RELAY_IP:$PORT/anon"
	"--client-quic-gso=$GSO")
echo "f5 sub side: relay=$RELAY_IP:$PORT cores=$CORES client_gso=$GSO"
echo "client_quic_gso=$GSO" >>"$OUT/meta.txt"

# ---- publisher, here rather than on the relay host --------------------------
# The continuous generator, not `tsp --infinite`: a looped clip rewinds its PCR
# every lap and this run outlasts the clip. The lane survives that rewind since
# #3375, but it costs an exporter restart per lap, which would drop a recurring
# transient into the dwell windows this experiment averages over. A fan-out ramp
# is not the place to re-measure discontinuity recovery.
[ -f "$SRCGEN" ] || {
	echo "f5: missing source generator $SRCGEN" >&2
	exit 1
}
(python3 "$SRCGEN" "$CLIP" |
	tsp -I file - -P regulate --pcr-synchronous --wait-min 5 -O file - |
	"$MOQ" "${CONN[@]}" --broadcast "$BCAST" import ts) >"$OUT/publisher.log" 2>&1 &
PUB_PID=$!
sleep 8
kill -0 "$PUB_PID" 2>/dev/null || {
	echo "f5: publisher died — see $OUT/publisher.log" >&2
	exit 1
}
echo "  publisher up (pid $PUB_PID), feeding $BCAST to the remote relay"

cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
wchar() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }
rss_kb() { awk '/^VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
box_busy() { awk '/^cpu /{i=$5+$6; t=0; for(j=2;j<=NF;j++)t+=$j; print t, i}' /proc/stat; }
alive() {
	local n=0
	for p in "${SUBS[@]+${SUBS[@]}}"; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
	echo "$n"
}
sum_of() {
	local fn=$1 s=0 v
	for p in "${SUBS[@]+${SUBS[@]}}"; do
		v=$($fn "$p")
		s=$((s + ${v:-0}))
	done
	echo "$s"
}

CSV="$OUT/subs.csv"
echo "n_target,n_alive,window_s,sub_cpu_pct_core,sub_rss_kb,agg_bps,per_sub_bps,per_sub_frac,box_busy_pct,rx_bytes_delta,deaths,pub_cpu_pct_core,pub_rss_kb" >"$CSV"
PUB_IMPORT=$(pgrep -f "[-]-broadcast $BCAST import ts" | head -1)
: >"$OUT/phases.log"

spawn_one() {
	local idx=$1
	if [ "$idx" -le "$NCAP" ]; then
		# Graded: continuity counted as the bytes go past, nothing kept. Routed
		# through a FIFO rather than a shell pipeline so that `$!` is the
		# subscriber's own pid — in a pipeline it is tsp's, and every CPU and
		# delivery figure for this subscriber would then belong to the grader.
		# tsp opens the read end first because opening a FIFO to write blocks
		# until there is a reader.
		local f="$OUT/fifo.$idx"
		rm -f "$f"
		mkfifo "$f"
		# `count` alongside `continuity` so a clean run is distinguishable from a
		# grader that never ran: `continuity` is silent when there is nothing
		# wrong, and an empty log is then the same artefact for "no errors" and
		# "no bytes". The interval is in packets (~400k is about a minute here).
		tsp -I file "$f" -P continuity -P count --total --interval 400000 -O drop \
			>"$OUT/cont.$idx.log" 2>&1 &
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>"$f" 2>"$OUT/sub.$idx.log" &
		SUBS+=("$!")
	elif [ "$idx" -eq $((NCAP + 1)) ]; then
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>/dev/null 2>"$OUT/sub.plain.log" &
		SUBS+=("$!")
	else
		"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" \
			>/dev/null 2>/dev/null &
		SUBS+=("$!")
	fi
}

STOP_REASON=""
PREV=0
for N in $(echo "$SCHEDULE" | tr ',' ' '); do
	# Additive ramp against one relay and one publisher: tearing the whole set
	# down between points would make each N a fresh warm-up and hide any cost
	# that only appears once sessions have been established for a while.
	while [ "${#SUBS[@]}" -lt "$N" ]; do
		spawn_one "$((${#SUBS[@]} + 1))"
		# Paced so the ramp itself is not a subscription storm: T25 showed that
		# arriving and leaving in bursts costs the relay an order of magnitude
		# more than being present, and this experiment is about being present.
		sleep 0.15
	done
	echo "$(date +%s) n=$N spawned settle=${SETTLE}s" >>"$OUT/phases.log"
	sleep "$SETTLE"

	D0=$(alive)
	[ "$D0" -lt "$N" ] && echo "$(date +%s) n=$N WARNING only $D0 alive after settle" >>"$OUT/phases.log"

	C0=$(sum_of cpu_ticks)
	W0=$(sum_of wchar)
	PC0=$(cpu_ticks "$PUB_IMPORT")
	read -r BT0 BI0 <<<"$(box_busy)"
	RX0=$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)
	T0=$(date +%s)
	echo "$T0 n=$N measure_start" >>"$OUT/phases.log"

	sleep "$MEASURE"

	C1=$(sum_of cpu_ticks)
	W1=$(sum_of wchar)
	PC1=$(cpu_ticks "$PUB_IMPORT")
	read -r BT1 BI1 <<<"$(box_busy)"
	RX1=$(cat "/sys/class/net/$NIC/statistics/rx_bytes" 2>/dev/null || echo 0)
	T1=$(date +%s)
	NA=$(alive)

	WIN=$((T1 - T0))
	[ "$WIN" -lt 1 ] && WIN=1
	HZ=$(getconf CLK_TCK)
	SUBCPU=$(awk -v c=$((C1 - C0)) -v w="$WIN" -v hz="$HZ" 'BEGIN{printf "%.2f", c/hz/w*100}')
	AGG=$(awk -v b=$((W1 - W0)) -v w="$WIN" 'BEGIN{printf "%.0f", b*8/w}')
	PER=$(awk -v a="$AGG" -v n="$NA" 'BEGIN{printf "%.0f", (n>0? a/n : 0)}')
	if [ "$NOMINAL" -eq 0 ]; then
		NOMINAL=$PER
		echo "  reference per-subscriber rate calibrated at n=$N: $(awk -v p="$PER" 'BEGIN{printf "%.3f", p/1e6}') Mb/s"
		echo "reference_per_sub_bps=$NOMINAL (measured at n=$N)" >>"$OUT/meta.txt"
	fi
	FRAC=$(awk -v p="$PER" -v nom="$NOMINAL" 'BEGIN{printf "%.4f", (nom>0? p/nom : 0)}')
	BOX=$(awk -v dt=$((BT1 - BT0)) -v di=$((BI1 - BI0)) 'BEGIN{printf "%.1f", (dt>0? (dt-di)/dt*100 : 0)}')
	SUBRSS=$(sum_of rss_kb)
	PUBCPU=$(awk -v c=$((PC1 - PC0)) -v w="$WIN" -v hz="$HZ" 'BEGIN{printf "%.2f", c/hz/w*100}')
	PUBRSS=$(rss_kb "$PUB_IMPORT")

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$N" "$NA" "$WIN" "$SUBCPU" "$SUBRSS" "$AGG" "$PER" "$FRAC" "$BOX" \
		"$((RX1 - RX0))" "$((N - NA))" "$PUBCPU" "$PUBRSS" >>"$CSV"

	printf 'n=%-4s alive=%-4s per_sub=%s Mb/s (%s%% of N=1) agg=%s Mb/s subs_cpu=%s%% of a core (%s cores) box=%s%%\n' \
		"$N" "$NA" "$(awk -v p="$PER" 'BEGIN{printf "%.2f", p/1e6}')" \
		"$(awk -v f="$FRAC" 'BEGIN{printf "%.1f", f*100}')" \
		"$(awk -v a="$AGG" 'BEGIN{printf "%.0f", a/1e6}')" \
		"$SUBCPU" "$(awk -v s="$SUBCPU" 'BEGIN{printf "%.2f", s/100}')" "$BOX"

	# Stopping conditions. Each names which side is responsible, because "the
	# ramp ended here" is not a finding unless it says what ended it.
	if ! kill -0 "$PUB_PID" 2>/dev/null; then
		STOP_REASON="the PUBLISHER exited at n=$N — the source stopped, so nothing after this is a fan-out result"
		break
	fi
	if [ "$NA" -lt "$N" ]; then
		STOP_REASON="subscriber(s) exited at n=$N ($((N - NA)) of $N) — investigate, not a capacity result"
		break
	fi
	if awk -v f="$FRAC" -v m="$MIN_KEEP" 'BEGIN{exit !(f<m)}'; then
		STOP_REASON="per-subscriber delivery fell to $(awk -v f="$FRAC" 'BEGIN{printf "%.1f", f*100}')% of the N=1 rate at n=$N"
		break
	fi
	if awk -v b="$BOX" -v l="$BOX_LIMIT" 'BEGIN{exit !(b>l)}'; then
		STOP_REASON="THIS host (subscribers) reached ${BOX}% busy at n=$N — the harness is the limit, not the relay"
		break
	fi
	PREV=$N
done

echo "stop_reason=${STOP_REASON:-schedule completed}" | tee -a "$OUT/meta.txt"
echo "last_clean_n=$PREV" >>"$OUT/meta.txt"
echo "finished=$(date -u +%FT%T%z)" >>"$OUT/meta.txt"
echo "f5 sub side done: $CSV"
