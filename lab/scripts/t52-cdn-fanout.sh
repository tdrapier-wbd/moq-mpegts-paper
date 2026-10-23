#!/usr/bin/env bash
# T52 — fan-out of the live feed through a CDN-hosted relay (lab/test-52-cdn-relay-fanout.md).
#
#   t52-cdn-fanout.sh pub <bin-dir> <out-dir> <lane> <seconds>     # the ingesting host
#   t52-cdn-fanout.sh ramp <bin-dir> <out-dir> <lane> [schedule]   # the subscriber host
#   t52-cdn-fanout.sh soak <bin-dir> <out-dir> <lane> <subscribers> <seconds>
#
# <lane> is demux (`import ts` / `export ts --delay 1s`) or passthrough (`--passthrough` both ends).
# pub: one publisher reading the standing ingest's loopback multicast group, restarted on exit with
#   each exit logged; its input bytes (`rchar`, the TS it consumed) sampled each second.
# ramp: subscribers added to each step of the schedule, settled SETTLE s and measured MEASURE s. The
#   first NCAP are graded in flight by t21-pcr-monitor.py through a FIFO, so `$!` stays the
#   subscriber's pid; every subscriber's delivered bytes are the bytes this host received on its
#   QUIC socket (an nftables counter per port; sudo): its `wchar` is no measure on the
#   demultiplexed lane, whose export writes its constant rate in stuffing whatever arrives (kept
#   as `min_out_bps`). Each step starts one more
#   subscriber that only times its join (first byte; first random-access packet) and exits. The
#   host's CPU, network and memory are sampled each second. The ramp stops at a subscriber exit, a
#   subscriber under MIN_KEEP of step 1's per-subscriber rate, or the host past BOX_LIMIT % busy,
#   half its NIC rate or under MIN_AVAIL_MB free; the step's verdict against the publisher's bytes
#   is computed afterwards from both hosts' logs.
# soak: a fixed count of subscribers, each under a supervisor that restarts it on exit and logs the
#   exit, its code and its last log line; NCAP graded as in the ramp, every one's received bytes
#   (summed over its restarts) and `wchar` sampled each minute. The relay's host does not answer ICMP or TCP, so the path's loss and RTT are pinged
#   each second at PROBE, the last hop that answers.
#
# env: URL (the relay, required), VER (moq-transport-18), PREFIX (moq-test/p1j), GROUP
#      (239.255.0.1:5000), RCVBUF (16777216), SETTLE (60), MEASURE (120), NCAP (4), MIN_KEEP (0.98),
#      BOX_LIMIT (70), NIC_BPS (the NIC's rate, for the half-rate rule; 0 skips it), MIN_AVAIL_MB
#      (1024), ANCHOR (0; 1 opens the subscription with an uncounted subscriber first), JOIN_S (10),
#      JOIN_TRIES (3)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE=${1:?pub, ramp or soak}
BIN=${2:?bin dir with moq}
OUT=${3:?out dir}
LANE=${4:?demux or passthrough}
URL=${URL:?set URL to the relay}
VER=${VER:-moq-transport-18}
PREFIX=${PREFIX:-moq-test/p1j}
GROUP=${GROUP:-239.255.0.1:5000}
RCVBUF=${RCVBUF:-16777216}
MOQ=$BIN/moq
BCAST=$PREFIX/$LANE
CONN=(--connect "$URL" --connect-version "$VER" --broadcast "$BCAST")
case "$LANE" in
demux)
	IMP=(import ts)
	EXP=(export ts --delay 1s)
	;;
passthrough)
	IMP=(import ts --passthrough)
	EXP=(export ts --passthrough)
	;;
*)
	echo "lane is demux or passthrough" >&2
	exit 2
	;;
esac

PIDS=()
# The subscriber that opens the relay's upstream subscription to a broadcast never receives its
# catalog's one object (openmoq/moqx#795); ANCHOR=1 opens it with a subscriber that is not counted.
anchor() {
	[ "${ANCHOR:-0}" = 1 ] || return 0
	"$MOQ" "${CONN[@]}" "${EXP[@]}" >/dev/null 2>"$OUT/anchor-$LANE.log" &
	PIDS+=($!)
	sleep 5
}
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	# Matches only this run's broadcast under PREFIX, never the standing units'.
	pkill -f "[-]-broadcast $BCAST ${EXP[0]}" 2>/dev/null
	pkill -f "[-]-broadcast $BCAST ${IMP[0]}" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	rm -f "$OUT"/fifo.* 2>/dev/null
	[ "$ROLE" = pub ] || "${NFT[@]}" delete table inet "$TABLE" 2>/dev/null
	true
}
trap cleanup EXIT
now() { date +%s.%N; }
rchar() { awk -F': *' '/^rchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }
wchar() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }
# A subscriber's received bytes are an nftables input counter on its QUIC socket's port: `rchar`
# does not count recvmsg, and the demultiplexed export's `wchar` is mostly stuffing.
NFT=(sudo -n nft)
TABLE=t52_$LANE
count_init() {
	"${NFT[@]}" delete table inet "$TABLE" 2>/dev/null
	"${NFT[@]}" add table inet "$TABLE" &&
		"${NFT[@]}" add chain inet "$TABLE" in '{ type filter hook input priority 0; policy accept; }'
}
# count <index> <pid>: count the pid's QUIC port as subscriber <index>, once its socket exists. The
# QUIC socket is the unconnected one: a connected socket is the resolver's lookup of the relay.
count() {
	local i=$1 p=$2 port k
	for k in $(seq 1 50); do
		port=$(ss -Huanp 2>/dev/null | awk -v p="pid=$p," 'index($0, p) && $5 ~ /:\*$/ {n = split($4, a, ":"); print a[n]; exit}')
		[ -n "$port" ] && break
		sleep 0.1
	done
	[ -n "$port" ] && "${NFT[@]}" add rule inet "$TABLE" in udp dport "$port" counter comment "\"s$i\""
}
# rx_snapshot: "<index> <bytes>" for every counted subscriber, summed over its sockets.
rx_snapshot() {
	"${NFT[@]}" list chain inet "$TABLE" in 2>/dev/null | awk '$NF ~ /^"s[0-9]+"$/ {
		c = $NF; gsub(/[^0-9]/, "", c)
		for (k = 1; k < NF; k++) if ($k == "bytes") s[c] += $(k + 1)
	} END {for (c in s) printf "%s %.0f\n", c, s[c]}'
}

mkdir -p "$OUT"
{
	echo "role=$ROLE lane=$LANE bcast=$BCAST ver=$VER moq=$("$MOQ" --version 2>&1 | head -1)"
	echo "host=$(hostname) cores=$(nproc) started=$(date -u +%FT%TZ)"
} >>"$OUT/meta-$ROLE-$LANE.txt"

case "$ROLE" in
pub)
	SECS=${5:?seconds}
	END=$(($(date +%s) + SECS))
	(while [ "$(date +%s)" -lt "$END" ]; do
		p=$(pgrep -f -- "^$MOQ .*--broadcast $BCAST import ts" | head -1)
		echo "$(now) ${p:-0} $([ -n "$p" ] && rchar "$p" || echo 0)"
		sleep 1
	done) >>"$OUT/pub-$LANE.io" &
	PIDS+=($!)
	while [ "$(date +%s)" -lt "$END" ]; do
		t0=$(now)
		left=$((END - $(date +%s)))
		tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size "$RCVBUF" -O file - 2>>"$OUT/pub-$LANE-tsp.log" |
			timeout "$left" "$MOQ" "${CONN[@]}" "${IMP[@]}" 2>>"$OUT/pub-$LANE.log"
		rc=${PIPESTATUS[1]}
		echo "$(now) exit rc=$rc started=$t0" >>"$OUT/pub-$LANE.exits"
		[ "$(date +%s)" -lt "$END" ] && sleep 1
	done
	;;
ramp)
	SCHEDULE=${5:-1,2,4,8,16,24,32,40,48,64}
	SETTLE=${SETTLE:-60}
	MEASURE=${MEASURE:-120}
	NCAP=${NCAP:-4}
	MIN_KEEP=${MIN_KEEP:-0.98}
	BOX_LIMIT=${BOX_LIMIT:-70}
	NIC_BPS=${NIC_BPS:-0}
	MIN_AVAIL_MB=${MIN_AVAIL_MB:-1024}
	NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
	ulimit -n 65536 2>/dev/null || true
	(while :; do
		read -r _ u n s i w q sq st _ </proc/stat
		echo "$(now) $((u + n + s + q + sq + st)) $((i + w)) $(cat "/sys/class/net/$NIC/statistics/rx_bytes") $(awk '/^MemAvailable/{print $2}' /proc/meminfo)"
		sleep 1
	done) >"$OUT/host-$LANE.log" &
	PIDS+=($!)
	JOIN_S=${JOIN_S:-10}
	JOIN_TRIES=${JOIN_TRIES:-3}
	SUBS=()
	# spawn <index>: start subscriber <index>, or restart it in place.
	spawn() {
		local i=$1
		if [ "$i" -le "$NCAP" ]; then
			local f="$OUT/fifo.$i"
			rm -f "$f"
			mkfifo "$f"
			python3 "$HERE/t21-pcr-monitor.py" --window 10 <"$f" >>"$OUT/mon-$LANE.$i.log" 2>&1 &
			PIDS+=($!)
			"$MOQ" "${CONN[@]}" "${EXP[@]}" >"$f" 2>>"$OUT/sub-$LANE.$i.log" &
		else
			"$MOQ" "${CONN[@]}" "${EXP[@]}" >/dev/null 2>>"$OUT/sub-$LANE.$i.log" &
		fi
		SUBS[i - 1]=$!
		PIDS+=($!)
		count "$i" "$!"
	}
	# A subscriber that ends within JOIN_S s of starting failed its join (the node loses a group's
	# head at a join): logged to joins-<lane>.log and restarted, JOIN_TRIES times at most.
	retry_joins() {
		local first=$1 last=$2 try k
		for try in $(seq 1 "$JOIN_TRIES"); do
			sleep "$JOIN_S"
			local failed=0
			for k in $(seq "$first" "$last"); do
				kill -0 "${SUBS[k - 1]}" 2>/dev/null && continue
				failed=1
				echo "$(now) n=$last i=$k try=$try last=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/sub-$LANE.$k.log" | grep -v 'UDP \(receive\|send\)' | grep -E 'WARN|ERROR|Error' | tail -2 | cut -c1-200 | tr '\n' ' ')" >>"$OUT/joins-$LANE.log"
				[ "$try" -lt "$JOIN_TRIES" ] && spawn "$k"
			done
			[ "$failed" = 0 ] && return 0
		done
		return 1
	}
	join_probe() {
		local n=$1
		(
			for t in $(seq 1 "$JOIN_TRIES"); do
				timeout 30 "$MOQ" "${CONN[@]}" "${EXP[@]}" 2>>"$OUT/join-$LANE.$n.log" | python3 -c "$JOINPY" >"$OUT/join-$LANE.$n.txt" 2>&1
				grep -q "first_byte_s=None" "$OUT/join-$LANE.$n.txt" || break
				echo "$(now) n=$n probe try=$t" >>"$OUT/joins-$LANE.log"
			done
			echo "tries=$t" >>"$OUT/join-$LANE.$n.txt"
		) &
	}
	JOINPY='
import sys, time
t0 = time.monotonic(); first = rap = None; buf = b""
src = sys.stdin.buffer
while rap is None:
    b = src.read(188 * 64)
    if not b:
        break
    if first is None:
        first = time.monotonic() - t0
    buf += b
    while len(buf) >= 188:
        p, buf = buf[:188], buf[188:]
        if p[0] == 0x47 and p[3] & 0x20 and p[4] > 0 and p[5] & 0x40:
            rap = time.monotonic() - t0
            break
print("first_byte_s=%s first_rap_s=%s" % (first and round(first, 3), rap and round(rap, 3)))
'
	count_init || exit 1
	anchor
	echo "n,alive,t0,t1,min_rx_bps,median_rx_bps,max_rx_bps,min_frac,min_out_bps" >"$OUT/steps-$LANE.csv"
	REF=0
	STOP=""
	for N in $(echo "$SCHEDULE" | tr ',' ' '); do
		FIRST=$((${#SUBS[@]} + 1))
		while [ "${#SUBS[@]}" -lt "$N" ]; do
			spawn "$((${#SUBS[@]} + 1))"
			sleep 0.15
		done
		join_probe "$N"
		if ! retry_joins "$FIRST" "$N"; then
			STOP="a subscriber failed its join $JOIN_TRIES times at n=$N"
			break
		fi
		echo "$(now) n=$N spawned" >>"$OUT/phases-$LANE.log"
		sleep "$SETTLE"
		declare -A R0=() R1=() W0=()
		for p in "${SUBS[@]}"; do W0[$p]=$(wchar "$p"); done
		T0=$(now)
		while read -r k b; do R0[$k]=$b; done < <(rx_snapshot)
		sleep "$MEASURE"
		while read -r k b; do R1[$k]=$b; done < <(rx_snapshot)
		T1=$(now)
		RATES=()
		OUTS=()
		ALIVE=0
		for j in "${!SUBS[@]}"; do
			p=${SUBS[$j]}
			k=$((j + 1))
			if kill -0 "$p" 2>/dev/null; then
				ALIVE=$((ALIVE + 1))
				RATES+=("$(awk -v a="${R0[$k]:-0}" -v b="${R1[$k]:-0}" -v t0="$T0" -v t1="$T1" 'BEGIN{printf "%.0f", (b-a)*8/(t1-t0)}')")
				OUTS+=("$(awk -v a="${W0[$p]}" -v b="$(wchar "$p")" -v t0="$T0" -v t1="$T1" 'BEGIN{printf "%.0f", (b-a)*8/(t1-t0)}')")
			fi
		done
		read -r MIN MED MAX <<<"$(printf '%s\n' "${RATES[@]:-0}" | sort -n | awk '{v[NR]=$1} END{print v[1], v[int((NR+1)/2)], v[NR]}')"
		MINOUT=$(printf '%s\n' "${OUTS[@]:-0}" | sort -n | head -1)
		[ "$REF" = 0 ] && REF=$MED
		FRAC=$(awk -v m="$MIN" -v r="$REF" 'BEGIN{printf "%.4f", (r>0? m/r : 0)}')
		echo "$N,$ALIVE,$T0,$T1,$MIN,$MED,$MAX,$FRAC,$MINOUT" >>"$OUT/steps-$LANE.csv"
		echo "$(now) n=$N measured alive=$ALIVE min_frac=$FRAC" >>"$OUT/phases-$LANE.log"
		BUSY=$(awk -v t0="$T0" -v t1="$T1" '$1>=t0 && $1<=t1 {if(!s){b0=$2;i0=$3;r0=$4;s0=$1;s=1} b1=$2;i1=$3;r1=$4;s1=$1}
			END{db=b1-b0; di=i1-i0; printf "%.1f %.0f", (db+di>0? db/(db+di)*100 : 0), (s1>s0? (r1-r0)*8/(s1-s0) : 0)}' "$OUT/host-$LANE.log")
		read -r BOX RXBPS <<<"$BUSY"
		echo "$(now) n=$N host_busy=$BOX% rx_bps=$RXBPS" >>"$OUT/phases-$LANE.log"
		if [ "$ALIVE" -lt "$N" ]; then
			STOP="a subscriber exited at n=$N"
		elif awk -v f="$FRAC" -v m="$MIN_KEEP" 'BEGIN{exit !(f<m)}'; then
			STOP="a subscriber fell to $FRAC of step 1's rate at n=$N"
		elif awk -v b="$BOX" -v l="$BOX_LIMIT" 'BEGIN{exit !(b>l)}'; then
			STOP="this host reached $BOX% busy at n=$N: the harness's limit"
		elif [ "$NIC_BPS" -gt 0 ] && awk -v r="$RXBPS" -v n="$NIC_BPS" 'BEGIN{exit !(r>n/2)}'; then
			STOP="this host passed half its NIC rate at n=$N: the harness's limit"
		elif [ "$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)" -lt "$MIN_AVAIL_MB" ]; then
			STOP="this host's MemAvailable fell under $MIN_AVAIL_MB MB at n=$N: the harness's limit"
		fi
		[ -n "$STOP" ] && break
	done
	echo "stop=${STOP:-schedule completed} finished=$(date -u +%FT%TZ)" >>"$OUT/meta-$ROLE-$LANE.txt"
	;;
soak)
	COUNT=${5:?subscribers}
	SECS=${6:?seconds}
	NCAP=${NCAP:-4}
	PROBE=${PROBE:?set PROBE to the last hop that answers ICMP on the path to the relay}
	END=$(($(date +%s) + SECS))
	NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
	ulimit -n 65536 2>/dev/null || true
	ping -D -i 1 -W 2 -w "$SECS" "$PROBE" >"$OUT/ping-$LANE.log" 2>&1 &
	PIDS+=($!)
	(while [ "$(date +%s)" -lt "$END" ]; do
		read -r _ u n s i w q sq st _ </proc/stat
		echo "$(now) $((u + n + s + q + sq + st)) $((i + w)) $(cat "/sys/class/net/$NIC/statistics/rx_bytes") $(awk '/^MemAvailable/{print $2}' /proc/meminfo)"
		sleep 10
	done) >"$OUT/host-$LANE.log" &
	PIDS+=($!)
	supervise() {
		local i=$1 t0 p rc
		while [ "$(date +%s)" -lt "$END" ]; do
			t0=$(now)
			if [ "$i" -le "$NCAP" ]; then
				rm -f "$OUT/fifo.$i"
				mkfifo "$OUT/fifo.$i"
				python3 "$HERE/t21-pcr-monitor.py" --window 60 <"$OUT/fifo.$i" >>"$OUT/mon-$LANE.$i.log" 2>&1 &
				"$MOQ" "${CONN[@]}" "${EXP[@]}" >"$OUT/fifo.$i" 2>>"$OUT/sub-$LANE.$i.log" &
			else
				"$MOQ" "${CONN[@]}" "${EXP[@]}" >/dev/null 2>>"$OUT/sub-$LANE.$i.log" &
			fi
			p=$!
			echo "$p" >"$OUT/pid.$i"
			count "$i" "$p"
			wait "$p"
			rc=$?
			[ "$(date +%s)" -ge "$END" ] && break
			echo "$(now) i=$i rc=$rc started=$t0 last=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/sub-$LANE.$i.log" | tail -1 | cut -c1-240)" >>"$OUT/exits-$LANE.log"
			sleep 1
		done
	}
	count_init || exit 1
	anchor
	for i in $(seq 1 "$COUNT"); do
		supervise "$i" &
		PIDS+=($!)
		sleep 0.2
	done
	while [ "$(date +%s)" -lt "$END" ]; do
		declare -A RX=()
		while read -r k b; do RX[$k]=$b; done < <(rx_snapshot)
		for i in $(seq 1 "$COUNT"); do
			p=$(cat "$OUT/pid.$i" 2>/dev/null)
			echo "$(now) $i ${p:-0} ${RX[$i]:-0} $([ -n "$p" ] && wchar "$p" || echo 0)"
		done >>"$OUT/io-$LANE.log"
		sleep 60
	done
	echo "finished=$(date -u +%FT%TZ)" >>"$OUT/meta-$ROLE-$LANE.txt"
	;;
*)
	echo "unknown role $ROLE" >&2
	exit 2
	;;
esac
