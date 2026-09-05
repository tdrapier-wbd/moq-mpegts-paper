#!/usr/bin/env bash
#
# T21 — the permanence soak of the complete media-aware lane, groomer included.
#
#   t21-lane-soak.sh <label> [hours]
#
# Every conformance figure the media-aware lane has rests on a 300-second window, and the
# stage that produces it now contains a control loop -- the groomer's release rate is trimmed
# by its buffer's distance from the cushion. A loop that is stable for five minutes is not
# thereby stable for a week: it can drift, hunt, or settle onto a different set point once the
# transient it started in has decayed. That is what this run is for, and it is why the groomer
# is inside the measurement rather than downstream of it.
#
# THE GROOMER IS THE POINT. T8b's C6 soak graded `moq export ts` with `tsp count` behind it,
# and T9's soaks graded the relay; neither had the pacer in the path, so no long run has ever
# exercised the stage that makes this lane conformant. This one grades the CBR wire the
# groomer emits, which is what an IRD would receive.
#
# NOTHING IS STORED. A conformant 11 Mb/s wire is 119 GB a day and this host has a few GB
# free, so every check runs in flight: `tsp -P continuity` and `-P pcrverify` log violations,
# `t21-pcr-monitor.py` prints one PCR summary per minute, and the groomer prints its own
# counters on the same cadence. A soak that fills the disk at hour four has measured the disk.
#
# NO SHAPING AND NO NETNS, deliberately, so this needs no root. Impairment is a different
# experiment (T5, T8b); mixing the two would leave a drift unattributable between the loop and
# the path. The question here is whether a healthy lane stays healthy, which is the weaker
# question and the one that has never been asked.
#
# The source loops every ~665 s, so a multi-hour run crosses the wrap dozens of times. Each
# role respawns and every respawn is counted: an unexplained restart is the result, not a rig
# failure to be hidden.
set -uo pipefail

LABEL=${1:?label}
HOURS=${2:-12}
SAMPLE=${SAMPLE:-60}
RATE=${RATE:-11000000}
CUSHION_MS=${CUSHION_MS:-1000}
CAP_MS=${CAP_MS:-2500}
LATENCY_MAX=${LATENCY_MAX:-500ms}
PORT=${PORT:-4460}

MOQ=${MOQ:-$HOME/bin-main-eab96019/moq}
RELAY=${RELAY:-$HOME/bin-main-eab96019/moq-relay}
PACER=${PACER:-$HOME/pacer-64595f6/target/release/mpegts-pacer}
MONITOR=${MONITOR:-$HOME/t21/t21-pcr-monitor.py}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
DIR=${DIR:-$HOME/t21}

# `SECS` overrides the hours argument, which exists so the rig can be smoke-tested in a
# minute. A soak whose first run is the real one is a soak whose rig defects are discovered
# at hour nine.
SECS=${SECS:-$((HOURS * 3600))}
RUN=$DIR/$LABEL
mkdir -p "$RUN"
BCAST="t21.soak.$LABEL"
CSV=$RUN/soak.csv
KIDS=()

for f in "$MOQ" "$RELAY" "$PACER" "$MONITOR" "$CLIP"; do
	[ -e "$f" ] || {
		echo "missing: $f" >&2
		exit 1
	}
done

# Refuse to start behind a leaked relay rather than attaching to it and mislabelling the run.
if pgrep -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" >/dev/null 2>&1; then
	echo "a relay is already bound to 127.0.0.1:$PORT — kill it before starting" >&2
	exit 1
fi

cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[m]oq-relay --server-bind 127.0.0.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

"$RELAY" --server-bind "127.0.0.1:$PORT" --tls-generate localhost --auth-public "" \
	>"$RUN/relay.log" 2>&1 &
KIDS+=("$!")
sleep 2

bash -c "while :; do
    echo \"\$(date -Is) publisher start\" >> $RUN/respawn.log
    tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file - \
      | $MOQ --client-tls-disable-verify --client-connect https://127.0.0.1:$PORT/anon \
          --broadcast $BCAST import ts
    echo \"\$(date -Is) publisher exit rc=\$?\" >> $RUN/respawn.log
    sleep 2
  done" >"$RUN/pub.log" 2>&1 &
KIDS+=("$!")
sleep 5

# The graded chain. `pcrverify --bitrate` is passed the nominal rate explicitly: left to infer
# it, TSDuck derives the rate from the PCRs and then grades the PCRs against it, so an arm
# that has shed content fails every PCR and reads as a clock defect (method-notes §2).
bash -c "while :; do
    echo \"\$(date -Is) egress start\" >> $RUN/respawn.log
    $MOQ --client-tls-disable-verify --client-connect https://127.0.0.1:$PORT/anon \
      --broadcast $BCAST export ts --latency-max $LATENCY_MAX 2>> $RUN/export.log \
      | $PACER - $RATE --latency-ms $CUSHION_MS --max-latency-ms $CAP_MS \
          --stall-ms 1000 --on-stall mute --stats-interval-ms $((SAMPLE * 1000)) 2>> $RUN/pacer.log \
      | tsp -I file - -P continuity -P pcrverify --absolute --jitter-max 500 --bitrate $RATE \
            -P count --total --interval 100000 -O file - 2>> $RUN/grade.log \
      | python3 $MONITOR --window $SAMPLE >> $RUN/pcr.log 2>&1
    echo \"\$(date -Is) egress exit rc=\$?\" >> $RUN/respawn.log
    sleep 2
  done" >"$RUN/chain.log" 2>&1 &
KIDS+=("$!")

{
	echo "t=0 label=$LABEL hours=$HOURS rate=$RATE cushion=${CUSHION_MS}ms cap=${CAP_MS}ms"
	echo "latency_max=$LATENCY_MAX bcast=$BCAST sample=${SAMPLE}s"
	echo "moq=$($MOQ --version 2>&1 | head -1) relay=$($RELAY --version 2>&1 | head -1)"
	echo "pacer=$($PACER --version 2>&1 | head -1)"
	echo "clip=$CLIP md5=$(md5sum "$CLIP" | cut -d' ' -f1)"
	echo "started=$(date -Is)"
} >"$RUN/meta.txt"

echo "epoch,elapsed_s,relay_rss_kb,relay_thr,relay_fd,import_rss_kb,import_thr,import_fd,export_rss_kb,export_thr,export_fd,pacer_rss_kb,pacer_thr,pacer_fd,pkts_total,cc_events,pcr_jitter,respawns,avail_mb,load1" >"$CSV"

# A multi-line or empty field silently shifts every later column, and a soak is exactly where
# that would go unnoticed until the run is over. Every field goes through this.
one() {
	local v
	v=$(printf '%s' "$1" | head -1 | tr -d '[:space:]')
	echo "${v:-$2}"
}

# Summed RSS, thread count and fd count over every process matching a signature.
proc_of() {
	local total=0 thr=0 fd=0 p
	for p in $(pgrep -f "$1" 2>/dev/null); do
		total=$((total + $(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)))
		thr=$((thr + $(awk '/^Threads/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)))
		fd=$((fd + $(find "/proc/$p/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)))
	done
	echo "$total $thr $fd"
}

START=$(date +%s)
while :; do
	NOW=$(date +%s)
	EL=$((NOW - START))
	[ "$EL" -ge "$SECS" ] && break
	PKTS=$(grep -oE 'total: [0-9,]+ packets' "$RUN/grade.log" 2>/dev/null | tail -1 |
		grep -oE '[0-9,]+' | tr -d ,)
	# `grep -c` prints its 0 and then exits non-zero, so `|| echo 0` would append a
	# second line and corrupt the row. `|| true` keeps the count and drops the status.
	CCE=$(grep -cE 'missing .* packets|discontinuity' "$RUN/grade.log" 2>/dev/null || true)
	PCRV=$(grep -cE 'pcrverify' "$RUN/grade.log" 2>/dev/null || true)
	RESP=$(grep -c 'exit' "$RUN/respawn.log" 2>/dev/null || true)
	read -r RR RT RF <<<"$(proc_of "[m]oq-relay --server-bind 127.0.0.1:$PORT")"
	read -r IR IT IF <<<"$(proc_of "$BCAST import")"
	read -r ER ET EF <<<"$(proc_of "$BCAST export")"
	read -r PR PT PF <<<"$(proc_of "[m]pegts-pacer - $RATE")"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$NOW" "$EL" \
		"$(one "$RR" 0)" "$(one "$RT" 0)" "$(one "$RF" 0)" \
		"$(one "$IR" 0)" "$(one "$IT" 0)" "$(one "$IF" 0)" \
		"$(one "$ER" 0)" "$(one "$ET" 0)" "$(one "$EF" 0)" \
		"$(one "$PR" 0)" "$(one "$PT" 0)" "$(one "$PF" 0)" \
		"$(one "${PKTS:-}" 0)" "$(one "${CCE:-}" 0)" "$(one "${PCRV:-}" 0)" \
		"$(one "${RESP:-}" 0)" \
		"$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)" \
		"$(awk '{print $1}' /proc/loadavg)" >>"$CSV"
	sleep "$SAMPLE"
done

echo "finished=$(date -Is) elapsed_s=$EL" >>"$RUN/meta.txt"
