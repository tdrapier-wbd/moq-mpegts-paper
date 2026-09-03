#!/usr/bin/env bash
# T12 — the clean 1+1 arm across two hosts, so the legs do not share a clock.
#
# Arm D on one box proves two stream-clocked groomers agree about stream position.
# It cannot prove they would agree on *independent oscillators*, because co-resident
# legs also share wall time, and the whole determinism claim rests on placement
# being a function of the stream rather than of the emitter's clock. This runs one
# leg per host, in two availability zones, and grades the pair for byte identity.
#
# One role per host, launched separately, overlapping in time:
#
#   ROLE=a  the publisher and leg A. Publishes SRC to the relay and grooms one leg.
#   ROLE=b  leg B only. Subscribes to the same broadcast from the other host.
#
# OWN_UPSTREAM=1 changes what is shared. By default the two roles share one relay fed by
# one importer, so the arm grades two egress legs on independent clocks and nothing above
# them. With OWN_UPSTREAM=1 each host runs its *own* relay and its *own* publisher against
# its own copy of the same source file, and subscribes over loopback -- so the two chains
# have no component in common at all, and the arm grades path diversity above the egress.
# Both roles then need SRC, and the two copies must be byte-identical or the comparison
# grades the files rather than the pipeline.
#
# Both roles must agree on RATE, SSRC and SEQ_SEED, or the legs lock different
# grids and the comparison is meaningless rather than negative. The legs need not
# start together: t12-rtpcmp.py pairs datagrams by RTP timestamp, which under
# --stream-clock is a function of the output slot, so any overlapping window works.
#
# Each host records its own leg from a local socket, so neither recording carries
# the other's network path. Sending both legs to one capture point would put the
# inter-AZ path on leg B alone, and a divergence could then be the clocks or the
# network -- which is the confound the arm exists to remove.
#
# Both roles take the same absolute START_AT (epoch seconds) and hold their leg until
# it. Do not try to align the two hosts by launching them a fixed delay apart: a
# backgrounded remote command does not return when it has started, so the delay you
# sleep on the operator's machine is not the delay the hosts see, and a leg that
# joins after the other role's publisher has exited records a stall rather than a
# pair. START_AT removes the orchestration from the measurement.
#
# This uses wall clock only to make the two recording windows overlap. It is not
# what the arm grades: byte identity is a property of stream position, so a few ms
# of NTP disagreement between the hosts cannot manufacture or hide it.
#
# Usage: ROLE=a|b START_AT=<epoch> ./t12-dual-host.sh <label>
set -uo pipefail

LABEL=${1:?usage: ROLE=a|b $0 <label>}
ROLE=${ROLE:?set ROLE to a or b}

MOQ=${MOQ:?set MOQ to the moq client binary}
PACER=${PACER:?set PACER to the directory holding the pacer egress binary}

# A relay and a publisher per host, rather than one of each shared between them.
OWN_UPSTREAM=${OWN_UPSTREAM:-0}
RELAY_PORT=${RELAY_PORT:-4443}
if [ "$OWN_UPSTREAM" = 1 ]; then
	RELAY_BIN=${RELAY_BIN:?OWN_UPSTREAM=1 needs RELAY_BIN}
	RELAY_URL=${RELAY_URL:-https://127.0.0.1:$RELAY_PORT/anon}
fi
RELAY_URL=${RELAY_URL:?set RELAY_URL, e.g. https://<host>:443/anon}
BCAST=${BCAST:-t12.dualhost}
SECS=${SECS:-90}
SETTLE=${SETTLE:-8}

# Arm D refuses an auto rate: it is measured from one process's arrival window, so
# two hosts would derive two different grids from the same stream.
RATE=${RATE:?set RATE explicitly (bits/s)}
# The campaign's SSRC throughout, decimal: the pacer parses it as base 10, and a
# hex literal fails at startup with a bare ParseIntError that reaches the log
# before any pacing happens.
SSRC=${SSRC:-538968071} # 0x20220007
SEQ_SEED=${SEQ_SEED:-0} # identical on both legs: the offset is a property of the pair
LATENCY_MAX=${LATENCY_MAX:-500ms}
PACER_LAT=${PACER_LAT:-1500}
PACER_MAXLAT=${PACER_MAXLAT:-8000}
PACER_STALL=${PACER_STALL:-1000}
PACER_ONSTALL=${PACER_ONSTALL:-mute}

OUT=${OUT:-$HOME/t12dh/$LABEL-$ROLE}
PORT=${PORT:-5100}
mkdir -p "$OUT"

EGRESS="$PACER/moq_egress"
for candidate in mpegts-pacer ts_egress moq_egress; do
	[ -x "$PACER/$candidate" ] && EGRESS="$PACER/$candidate"
done

set -m
PIDS=()
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
	done
	sleep 0.5
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null || true; done
	wait 2>/dev/null || true
}
trap cleanup EXIT

echo "==> $LABEL role $ROLE: $("$MOQ" --version), relay $RELAY_URL, ${RATE} b/s, seed $SEQ_SEED"

# Recorder first, so no egress is missed. Large socket buffer: a groomed leg is a
# steady datagram train and a drop here silently shrinks the compared set.
python3 - "$PORT" "$OUT/leg.rtp" <<'PY' &
import socket, struct, sys

port, path = int(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
with open(path, "wb") as f:
    try:
        while True:
            data = s.recv(65535)
            # Length-prefixed, so datagram boundaries survive into the file.
            f.write(struct.pack("<H", len(data)) + data)
    except (KeyboardInterrupt, SystemExit):
        pass
PY
REC=$!
PIDS+=("$REC")
sleep 1

C=(--client-tls-disable-verify --client-connect "$RELAY_URL")

# This host's own relay, when the arm is grading independent upstreams. It binds loopback
# only: with a publisher and a subscriber per host there is no cross-host traffic left, so
# exposing it would add a path the arm does not use and a security group it does not need.
if [ "$OWN_UPSTREAM" = 1 ]; then
	"$RELAY_BIN" --server-bind "127.0.0.1:$RELAY_PORT" --tls-generate localhost \
		--auth-public "" >"$OUT/relay.log" 2>&1 &
	RLY=$!
	PIDS+=("$RLY")
	for _ in $(seq 1 30); do
		ss -lun 2>/dev/null | grep -q ":$RELAY_PORT" && break
		sleep 0.5
	done
	kill -0 "$RLY" 2>/dev/null || {
		echo "relay exited early:" >&2
		head -20 "$OUT/relay.log" >&2
		exit 1
	}
	echo "==> own relay up on 127.0.0.1:$RELAY_PORT"
fi

# Role a always publishes. Under OWN_UPSTREAM both roles do, each against its own copy of
# the source, because the point of the arm is that no stage is shared.
if [ "$ROLE" = a ] || [ "$OWN_UPSTREAM" = 1 ]; then
	SRC=${SRC:?this role needs SRC}
	WAITMIN=${WAITMIN:-5}
	(tsp --realtime -I file "$SRC" --infinite \
		-P regulate --pcr-synchronous --wait-min "$WAITMIN" -O file - |
		"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
	PUB=$!
	PIDS+=("$PUB")
	sleep 3
	kill -0 "$PUB" 2>/dev/null || {
		echo "publisher exited early:" >&2
		cat "$OUT/import.log" >&2
		exit 1
	}
	echo "==> publisher up"
fi

# Hold here so both legs start together regardless of when each host was launched.
if [ -n "${START_AT:-}" ]; then
	NOW=$(date +%s)
	WAIT=$((START_AT - NOW))
	if [ "$WAIT" -gt 0 ]; then
		echo "==> holding ${WAIT}s until START_AT=$START_AT"
		sleep "$WAIT"
	else
		echo "WARNING: START_AT already passed by $((-WAIT))s; windows may not overlap" >&2
	fi
else
	sleep "$SETTLE"
fi

# The groomed leg. --stream-clock moves placement off the pacer's emit clock and
# onto the stream, which is the property under test; --sequence-seed pins the
# numbering epoch so two independently started legs share one.
# `set -m` already gives each background job its own process group whose id is the
# job's pid, so teardown can signal the whole pipeline. Deliberately *not* setsid:
# under setsid `$!` is the setsid process, which exits as soon as it has spawned the
# session leader, so every liveness check on it reports a healthy leg as dead.
bash -c "'$MOQ' --client-tls-disable-verify \
	--client-connect '$RELAY_URL' --broadcast '$BCAST' \
	export ts --latency-max $LATENCY_MAX \
	| '$EGRESS' 127.0.0.1:$PORT $RATE --rtp --ssrc $SSRC \
	  --latency-ms $PACER_LAT --max-latency-ms $PACER_MAXLAT \
	  --stall-ms $PACER_STALL --on-stall $PACER_ONSTALL \
	  --stream-clock --sequence-seed $SEQ_SEED" \
	>"$OUT/leg.log" 2>&1 </dev/null &
LEG=$!
PIDS+=("$LEG")

# Fail fast on a leg that never started. A bad pacer argument surfaces as one line
# at the top of leg.log and nothing else, and without this check the run spends its
# whole window recording an empty file and reports a null result that looks like a
# measurement. The test is that datagrams are arriving, not that a pid exists: the
# pacer can be up and still be emitting nothing.
sleep 5
if [ ! -s "$OUT/leg.rtp" ]; then
	echo "leg produced no datagrams in 5s:" >&2
	head -3 "$OUT/leg.log" >&2
	exit 1
fi

# Per-process CPU, because a 1+1 result measured on a resource-bound leg is void
# rather than negative, and on a 2-vCPU host that is a live risk.
# Cumulative CPU time of the leg's whole process group, in clock ticks. `ps -o %cpu`
# cannot do this: -p reads the wrapper shell, which burns nothing and reports 0.0 for a
# leg that is saturating a core, and neither -g nor --pgid selects by process group id on
# procps-ng. The pgrp is field 5 of /proc/<pid>/stat and utime/stime are 14 and 15, but
# comm is parenthesised and may contain spaces, so the fields are counted from after the
# last ") " rather than split from the start of the line.
group_ticks() {
	awk -v pg="$1" '
		{ p = 0
		  for (j = 1; j <= length($0) - 1; j++) if (substr($0, j, 2) == ") ") p = j
		  if (p == 0) next
		  n = split(substr($0, p + 2), f, " ")
		  if (n >= 13 && f[3] == pg) t += f[12] + f[13] }
		END { print t + 0 }' /proc/[0-9]*/stat 2>/dev/null
}

(
	echo "t,load1,leg_cpu_pct,idle_pct,avail_mb"
	# The leg's own cost beside whole-box idle. The leg figure says what the groomer
	# took; the idle figure says whether there was any left to take, and a 1+1 null
	# is only a result if there was.
	HZ=$(getconf CLK_TCK)
	PREV_T=$(group_ticks "$LEG")
	read -r _ u nn s PREV_IDLE rest </proc/stat
	PREV_BUSY=$((u + nn + s))
	for r in $rest; do PREV_BUSY=$((PREV_BUSY + r)); done
	for _ in $(seq 1 "$((SECS / 5))"); do
		sleep 5
		L=$(awk '{print $1}' /proc/loadavg)
		T=$(group_ticks "$LEG")
		P=$(awk -v d="$((T - PREV_T))" -v hz="$HZ" 'BEGIN{printf "%.1f", 100*d/hz/5}')
		PREV_T=$T
		read -r _ u nn s IDLE rest </proc/stat
		BUSY=$((u + nn + s))
		for r in $rest; do BUSY=$((BUSY + r)); done
		DI=$((IDLE - PREV_IDLE))
		DB=$((BUSY - PREV_BUSY))
		I=$(awk -v i="$DI" -v b="$DB" 'BEGIN{t=i+b; printf "%.1f", (t>0)? 100*i/t : 0}')
		PREV_IDLE=$IDLE
		PREV_BUSY=$BUSY
		A=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
		echo "$(date +%s),$L,$P,$I,$A"
	done
) >"$OUT/resource.csv" 2>/dev/null &
PIDS+=("$!")

echo "==> recording ${SECS}s to $OUT/leg.rtp"
sleep "$SECS"

kill -TERM "$REC" 2>/dev/null || true
sleep 1
echo "==> leg $(wc -c <"$OUT/leg.rtp") bytes -> $OUT/leg.rtp"
tail -3 "$OUT/resource.csv" 2>/dev/null
