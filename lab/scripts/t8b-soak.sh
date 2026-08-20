#!/usr/bin/env bash
#
# T8b condition C6 — the permanence soak, on a provisioned path.
#
#   sudo t8b-soak.sh <label> [hours]
#
# C1–C5 run for a minute or two each, and a permanent trunk is not a minute long. C6 asks
# the only question those cannot: does anything drift, leak, or abort over hours to days on a
# path that is *not* short of capacity. Nothing here is a rate comparison — the rate is
# already known from C5 — so the instrument is a time series of the things a short window
# cannot show: continuity events with timestamps on them, per-role RSS, and a restart count.
#
# NOTHING IS STORED. A 15 Mb/s feed is 162 GB a day and this host has 5 GB free, so the
# stream is graded in flight: `tsp -P continuity` logs an event whenever one occurs and
# `-P count --total --interval` stamps a running packet total, both to a log measured in
# kilobytes. A soak that fills the disk at hour four has measured the disk.
#
# `count --interval` counts PACKETS, NOT SECONDS. At `--interval 10` this logged 53,557 lines
# in the first 90 seconds — about 3.5 GB over fourteen hours, which would have filled the disk
# and ended the run somewhere around hour ten. 100,000 packets is ~16 s at this rate, so the
# series stays ~3,200 lines for the whole soak.
#
# THE CONTROLLER IS BBRv1 ON THE CURRENT quinn BUILD, deliberately. C1's one unexplained
# result was BBRv1's bimodality — two replicates at ~230 ms of queue and one at 591 ms — and a
# controller that is occasionally something else is exactly what a short run cannot rule on
# and a long one can. quinn is also the default backend, so this soaks the configuration
# someone would actually deploy, on a build carrying the current wrap fixes rather than the
# July per-backend binaries kept for the C1/C4 controller comparison.
#
# The source loops every ~600 s, so a multi-hour run crosses the wrap dozens of times. That is
# a feature: the wrap is where `moq import` historically died, and a soak that never wraps
# would not test it. The importer is restarted automatically if it exits, and every restart is
# counted — an unexplained restart count is the result, not a rig failure to be hidden.
set -uo pipefail

LABEL=${1:?label}
HOURS=${2:-14}
CAP_MBIT=${CAP_MBIT:-15}
QDISC=${QDISC:-bloat}
CC=${CC:-delay}
SAMPLE=${SAMPLE:-60}

MOQ=${MOQ:-/home/ubuntu/bin-main-eab96019/moq}
RELAY=${RELAY:-/home/ubuntu/bin-main-eab96019/moq-relay}
CLIP=${CLIP:-/home/ubuntu/CNNiEMEA2.ts}
NETNS=${NETNS:-/home/ubuntu/t8b/t8b-netns.sh}
DIR=${DIR:-/home/ubuntu/t8b/soak}

PUBIP=10.99.0.1
SECS=$((HOURS * 3600))
[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}

RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t8b.soak.$LABEL"
CSV=$RUN/soak.csv
KIDS=()

# Refuse to start behind a leaked relay rather than attaching to it and mislabelling the run.
# Checked before the trap is installed, so a refusal cannot tear down whatever is already there.
if pgrep -f "[m]oq-relay --server-bind $PUBIP:4443" >/dev/null 2>&1; then
	echo "a relay is already bound to $PUBIP:4443 — kill it before starting" >&2
	exit 1
fi

# Killing the recorded PIDs is not enough: a backgrounded `ip netns exec` may be a shell that
# outlives the binary it started, and a relay left bound to the port makes the *next* run
# silently attach to the wrong process. Kill by signature as well as by PID.
cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay --server-bind $PUBIP:4443" 2>/dev/null
	bash "$NETNS" down >/dev/null 2>&1
	true
}
trap cleanup EXIT

bash "$NETNS" up >/dev/null 2>&1
RATE_MBIT=$CAP_MBIT QUEUE_MS=${QUEUE_MS:-500} DELAY_MS=${DELAY_MS:-50} \
	bash "$NETNS" "$QDISC" >"$RUN/shape.log" 2>&1

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

pub "$RELAY" --server-bind $PUBIP:4443 --tls-generate localhost --auth-public "" \
	--server-quic-congestion-control "$CC" >"$RUN/relay.log" 2>&1 &
RELAY_PID=$!
KIDS+=("$RELAY_PID")
sleep 2

# Publisher and subscriber both respawn. A permanent trunk is defined by what it does over
# time, so an exit is an event to count and recover from rather than the end of the run — but
# each respawn is logged with its wall time so a rate anomaly can be checked against it
# instead of being explained away.
pub bash -c "while :; do
    echo \"\$(date -Is) publisher start\" >> $RUN/respawn.log
    tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file - \
      | $MOQ --client-tls-disable-verify --client-connect https://$PUBIP:4443/anon \
          --broadcast $BCAST import ts
    echo \"\$(date -Is) publisher exit rc=\$?\" >> $RUN/respawn.log
    sleep 2
  done" >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 5

sub bash -c "while :; do
    echo \"\$(date -Is) subscriber start\" >> $RUN/respawn.log
    $MOQ --client-tls-disable-verify --client-connect https://$PUBIP:4443/anon \
      --broadcast $BCAST export ts --latency-max 2s \
      | tsp -I file - -P continuity -P count --total --interval 100000 -O drop
    echo \"\$(date -Is) subscriber exit rc=\$?\" >> $RUN/respawn.log
    sleep 2
  done" >"$RUN/grade.log" 2>&1 &
KIDS+=("$!")

echo "t=0 label=$LABEL hours=$HOURS cap=${CAP_MBIT}Mb/s cc=$CC bcast=$BCAST" >"$RUN/meta.txt"
echo "epoch,elapsed_s,relay_rss_kb,import_rss_kb,export_rss_kb,pkts_total,cc_events,respawns,rtt_ms,avail_mb" >"$CSV"

# A multi-line or empty field silently shifts every later column of the row, and a soak is
# exactly where that would not be noticed until the run is over. Every field goes through this.
one() { # <value> <default> -> first line only, or the default when blank
	local v
	v=$(printf '%s' "$1" | head -1 | tr -d '[:space:]')
	echo "${v:-$2}"
}

rss_of() { # <pattern> -> summed RSS of matching processes
	local total=0 p
	for p in $(pgrep -f "$1" 2>/dev/null); do
		total=$((total + $(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)))
	done
	echo "$total"
}

START=$(date +%s)
while :; do
	NOW=$(date +%s)
	EL=$((NOW - START))
	[ "$EL" -ge "$SECS" ] && break
	# `count` prints "total: 1,234,567 packets" with thousands separators.
	PKTS=$(grep -oE 'total: [0-9,]+ packets' "$RUN/grade.log" 2>/dev/null | tail -1 |
		grep -oE '[0-9,]+' | tr -d ,)
	# `grep -c` prints its 0 and *then* exits non-zero, so `|| echo 0` appends a second
	# line and corrupts the CSV row. `|| true` keeps the count and drops the status.
	CCE=$(grep -cE 'missing .* packets|discontinuity' "$RUN/grade.log" 2>/dev/null || true)
	RESP=$(grep -c 'exit' "$RUN/respawn.log" 2>/dev/null || true)
	RTT=$(sub ping -n -c 3 -i 0.3 -q $PUBIP 2>/dev/null |
		awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$NOW" "$EL" \
		"$(one "$(rss_of "[m]oq-relay --server-bind $PUBIP")" 0)" \
		"$(one "$(rss_of "$BCAST import")" 0)" \
		"$(one "$(rss_of "$BCAST export")" 0)" \
		"$(one "${PKTS:-}" 0)" "$(one "${CCE:-}" 0)" "$(one "${RESP:-}" 0)" \
		"$(one "${RTT:-}" NA)" \
		"$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)" >>"$CSV"
	sleep "$SAMPLE"
done

echo "soak complete: $EL s" >>"$RUN/meta.txt"
