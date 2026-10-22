#!/usr/bin/env bash
# T28 criterion 9 (P1-a): the infrastructure axis. One component of a lane is killed and restarted,
# and the lane is graded on content, recovery time and latency, in the `netns` rig.
#
# A paced source writes the clip to UDP inside the publisher's namespace and is never killed, so a
# gateway's restart loses what a live encoder would go on sending. Each lane has three components,
# each under a loop that restarts it RESTART_S after it exits, as a process manager would:
#
#   moq  publisher  tsp -I ip | moq import ts                          (publisher's namespace)
#        relay      moq-relay                                          (publisher's namespace)
#        exporter   moq export ts --delay DELAY_S                      (subscriber's namespace)
#   srt  publisher  tsp -I ip -O srt, caller                           (publisher's namespace)
#        relay      tsp -I srt -O srt, listener both ways, --multiple  (publisher's namespace)
#        exporter   tsp -I srt, caller                                 (subscriber's namespace)
#
# The exporter's loop writes into one pipe that runs on across its restarts: a filter that
# resynchronises on packet boundaries (a killed writer can cut a packet), the egress tap, the
# capture. A sampler records the capture's size every 0.5 s, which gives the delivered rate. KILL
# names the component to SIGKILL KILL_AT s after the publisher starts; `none` is the control. Each
# loop logs its child's exits to <component>.exits, so a kill that takes others down is visible.
#
#   sudo env BIN=/home/ubuntu/bin-3c0daa21 bash t28-infra-axis.sh <label>
#
# Env: LANES ("moq srt"), KILLS ("none publisher relay exporter"), REPS (3), SECS (90), KILL_AT (30),
#      RESTART_S (1), DELAY_S (2), SRT_LATENCY_MS (unset: the first MoQ control's median latency),
#      SRT_HOP_MS (120, the first SRT hop's share of it), RTT_MS (20), RATE_MBIT (20), CLIP, VPID,
#      NETNS, CONTENT, LATENCY, GRADE (t28-infra-grade.py, beside t28-latency-return.py), OUT, MOQ_CC,
#      KEEP_TS=1, RELAY_EXTRA (more moq-relay flags, e.g. "--listen-reset-secret <file>").
# Output: <OUT>/<label>/<cell>/, each graded into grade.json before its capture is deleted.
set -uo pipefail

# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
BIN=${BIN:?set BIN to the moq binary dir}
CLIP=${CLIP:-/home/ubuntu/clip120.ts}
VPID=${VPID:-111}
NETNS=${NETNS:-/home/ubuntu/t8b-netns.sh}
CONTENT=${CONTENT:-/home/ubuntu/t28-content-lost.py}
LATENCY=${LATENCY:-/home/ubuntu/t18-latency.py}
GRADE=${GRADE:-/home/ubuntu/t28-infra-grade.py}
OUT=${OUT:-/home/ubuntu/t28ia}/$LABEL
MOQ_CC=${MOQ_CC:-delay}
RELAY_EXTRA=${RELAY_EXTRA:-}
LANES=${LANES:-"moq srt"}
KILLS=${KILLS:-"none publisher relay exporter"}
REPS=${REPS:-3}
SECS=${SECS:-90}
KILL_AT=${KILL_AT:-30}
RESTART_S=${RESTART_S:-1}
DELAY_S=${DELAY_S:-2}
SRT_HOP_MS=${SRT_HOP_MS:-120}
RTT_MS=${RTT_MS:-20}
RATE_MBIT=${RATE_MBIT:-20}
PORT=4443
PUBIP=10.99.0.1
UDP_PORT=5600
SRT_IN=9100
SRT_OUT=9101

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
for f in "$NETNS" "$CLIP" "$CONTENT" "$LATENCY" "$GRADE" "$BIN/moq" "$BIN/moq-relay"; do
	[ -r "$f" ] || {
		echo "FAIL: missing $f" >&2
		exit 1
	}
done
command -v tsp >/dev/null || {
	echo "FAIL: tsp not found" >&2
	exit 1
}
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
[ "${MOQ_LAT[0]}" = --delay ] || {
	echo "FAIL: $BIN/moq has no fixed-delay export (${MOQ_LAT[*]})" >&2
	exit 1
}

rm -rf "$OUT"
mkdir -p "$OUT"
RESYNC=$OUT/ts-resync.py
cat >"$RESYNC" <<-'PY'
	import sys
	r, w = sys.stdin.buffer, sys.stdout.buffer
	buf = b""
	while True:
	    chunk = r.read1(65536)
	    buf += chunk
	    out, i, n = bytearray(), 0, len(buf)
	    # A packet passes when the next one starts where it ends; at EOF the rest pass if aligned.
	    while i + (188 if not chunk else 376) <= n:
	        if buf[i] == 0x47 and (not chunk or buf[i + 188] == 0x47):
	            out += buf[i:i + 188]
	            i += 188
	        else:
	            i += 1
	    buf = buf[i:]
	    if out:
	        w.write(out)
	        w.flush()
	    if not chunk:
	        break
PY

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

# Patterns match the workers and their loops, never the launcher: every loop's command line ends in
# the rig's tag, and no worker's argv names this script.
cleanup_procs() {
	pkill -9 -f "t28ia[.]" 2>/dev/null
	pkill -9 -f "[m]oq-relay.*$PUBIP:$PORT" 2>/dev/null
	pkill -9 -f "[m]oq .*--broadcast t28ia" 2>/dev/null
	pkill -9 -f "[t]sp -I file $CLIP" 2>/dev/null
	pkill -9 -f "[t]sp -I ip $UDP_PORT" 2>/dev/null
	pkill -9 -f "[t]sp -I srt" 2>/dev/null
	pkill -9 -f "python3 .*t18-latency\.py tap" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

# kill_component <comm> <pattern>: SIGKILL the worker, never the loop around it (whose argv also
# matches the pattern, but whose comm is bash).
kill_component() {
	local comm=$1 pat=$2 p killed=
	for p in $(pgrep -f "$pat"); do
		[ "$(cat "/proc/$p/comm" 2>/dev/null)" = "$comm" ] || continue
		kill -9 "$p" 2>/dev/null && killed="$killed $p"
	done
	echo "${killed:- none}"
}

SRT_LATENCY_MS=${SRT_LATENCY_MS:-}

echo "=== $(date -u) t28-infra-axis $LABEL ==="
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	cat "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "lanes: $LANES; kills: $KILLS; reps: $REPS; secs: $SECS; kill at: $KILL_AT s; restart after: $RESTART_S s"
	echo "relay extra flags: ${RELAY_EXTRA:-none}"
	echo "moq --delay ${DELAY_S}s, relay controller $MOQ_CC; srt latency ${SRT_LATENCY_MS:-from the first moq control}, first hop $SRT_HOP_MS ms"
	echo "path: $RATE_MBIT Mb/s, RTT $RTT_MS ms"
	tsp --version 2>&1 | head -1
} | tee "$OUT/build.txt"

# $1 lane, $2 component to kill, $3 rep
run_cell() {
	local lane=$1 kill=$2 rep=$3
	local name="$lane-$kill-$rep" d bc tag l2
	d="$OUT/$name"
	bc="t28ia.$name.$$"
	tag="t28ia.$name"
	mkdir -p "$d"
	cleanup_procs
	echo
	echo "== $name =="
	if ! { RATE_MBIT=$RATE_MBIT DELAY_MS=$((RTT_MS / 2)) bash "$NETNS" up; } >"$d/shape.log" 2>&1; then
		echo "   VOID: netns failed ($(tail -1 "$d/shape.log"))"
		return 0
	fi
	echo "cell_start_ns $(date +%s%N)" >"$d/events.txt"

	# The source: paced, tapped, and written to UDP, so no reader holds it back.
	pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous \
            -P fork --nowait --ignore-abort \"python3 '$LATENCY' tap $VPID '$d/src.csv' --pipe --seconds $((SECS + 10)) > /dev/null\" \
            -O ip 127.0.0.1:$UDP_PORT 2>'$d/source.log' # $tag.source" &

	if [ "$lane" = moq ]; then
		pub bash -c "while :; do '$BIN/moq-relay' ${RELAY_BIND[*]} '$PUBIP:$PORT' ${RELAY_TLS[*]} '$PUBIP' \
                ${RELAY_AUTH[0]} '${RELAY_AUTH[1]}' ${RELAY_GSO[*]} $RELAY_CC_FLAG $MOQ_CC $RELAY_EXTRA --log-level warn >>'$d/relay.log' 2>&1; \
                echo \"exit \$(date +%s%N)\" >>'$d/relay.exits'; sleep $RESTART_S; done # $tag.relay" &
		sleep 3
		sub bash -c "{ while :; do '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' --broadcast '$bc' \
                export ts --delay ${DELAY_S}s 2>>'$d/sub.log'; echo \"exit \$(date +%s%N)\" >>'$d/exporter.exits'; sleep $RESTART_S; done; } \
              | python3 '$RESYNC' | python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $((SECS + 5)) --save '$d/out.ts' > /dev/null # $tag.exporter" &
		sleep 2
		pub bash -c "while :; do tsp -I ip $UDP_PORT -O file - 2>>'$d/gateway.log' \
              | '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' --broadcast '$bc' import ts >>'$d/pub.log' 2>&1; \
                echo \"exit \$(date +%s%N)\" >>'$d/publisher.exits'; sleep $RESTART_S; done # $tag.publisher" &
	else
		l2=$((SRT_LATENCY_MS - SRT_HOP_MS))
		pub bash -c "while :; do tsp -I srt --listener '$PUBIP:$SRT_IN' --multiple --latency $SRT_HOP_MS \
                -O srt --listener '$PUBIP:$SRT_OUT' --multiple --latency $l2 >>'$d/relay.log' 2>&1; \
                echo \"exit \$(date +%s%N)\" >>'$d/relay.exits'; sleep $RESTART_S; done # $tag.relay" &
		sleep 2
		sub bash -c "{ while :; do tsp -I srt --caller '$PUBIP:$SRT_OUT' --latency $l2 -O file - 2>>'$d/sub.log'; \
                echo \"exit \$(date +%s%N)\" >>'$d/exporter.exits'; sleep $RESTART_S; done; } \
              | python3 '$RESYNC' | python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $((SECS + 5)) --save '$d/out.ts' > /dev/null # $tag.exporter" &
		sleep 1
		pub bash -c "while :; do tsp -I ip $UDP_PORT -O srt --caller '$PUBIP:$SRT_IN' --latency $SRT_HOP_MS >>'$d/pub.log' 2>&1; \
                echo \"exit \$(date +%s%N)\" >>'$d/publisher.exits'; sleep $RESTART_S; done # $tag.publisher" &
	fi
	echo "publisher_start_ns $(date +%s%N)" >>"$d/events.txt"
	pub bash -c "while :; do printf '%s %s\n' \"\$(date +%s%N)\" \"\$(stat -c%s '$d/out.ts' 2>/dev/null || echo 0)\"; sleep 0.5; done # $tag.size" \
		>"$d/size.log" 2>/dev/null &

	if [ "$kill" != none ]; then
		sleep "$KILL_AT"
		local comm pat pids
		case "$lane/$kill" in
		moq/publisher) comm=moq pat="[m]oq .*--broadcast $bc import" ;;
		moq/relay) comm=moq-relay pat="[m]oq-relay.*$PUBIP:$PORT" ;;
		moq/exporter) comm=moq pat="[m]oq .*--broadcast $bc export" ;;
		srt/publisher) comm=tsp pat="[t]sp -I ip $UDP_PORT -O srt" ;;
		srt/relay) comm=tsp pat="[t]sp -I srt --listener" ;;
		srt/exporter) comm=tsp pat="[t]sp -I srt --caller" ;;
		esac
		echo "impair_start_ns $(date +%s%N)" >>"$d/events.txt"
		pids=$(kill_component "$comm" "$pat")
		echo "$lane $kill:$pids" >"$d/killed.txt"
		sleep "$RESTART_S"
		echo "impair_end_ns $(date +%s%N)" >>"$d/events.txt"
		echo "   killed $kill ($comm:$pids)"
		sleep $((SECS - KILL_AT - RESTART_S))
	else
		sleep "$SECS"
	fi
	cleanup_procs
	bash "$NETNS" down >/dev/null 2>&1

	local bytes
	bytes=$(stat -c%s "$d/out.ts" 2>/dev/null || echo 0)
	if [ "$bytes" -lt 200000 ]; then
		echo "   VOID: ${bytes}B captured"
		return 0
	fi
	python3 "$CONTENT" --input "$d/out.ts" --from-s 8 --label "$name" --json "$d/content.json" >/dev/null 2>&1
	python3 "$LATENCY" report "$d/src.csv" "$d/eg.csv" --label "$name" \
		--clock-offset 0 --settle 8 --kv "$d/lat.kv" >"$d/lat.txt" 2>&1 || true
	local lat_median=NA lost
	# shellcheck disable=SC1091
	[ -r "$d/lat.kv" ] && . "$d/lat.kv"
	lost=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('content_lost_s','NA'))" "$d/content.json" 2>/dev/null || echo NA)
	echo "   video lost $lost s, latency $lat_median ms, $bytes B, exits: publisher $(wc -l 2>/dev/null <"$d/publisher.exits" || echo 0) relay $(wc -l 2>/dev/null <"$d/relay.exits" || echo 0) exporter $(wc -l 2>/dev/null <"$d/exporter.exits" || echo 0)"
	python3 "$GRADE" --kill-at "$KILL_AT" --json "$d" 2>&1 | sed 's/^/   /'
	if [ "$lane/$kill" = moq/none ] && [ -z "$SRT_LATENCY_MS" ] && [ "$lat_median" != NA ]; then
		SRT_LATENCY_MS=$(printf '%.0f' "$lat_median")
		echo "   SRT latency set to $SRT_LATENCY_MS ms from this control"
		echo "srt latency: $SRT_LATENCY_MS ms (from $name)" >>"$OUT/build.txt"
	fi
	[ "${KEEP_TS:-0}" = 1 ] || rm -f "$d/out.ts"
}

# Interleaved so a drift in host load lands on every arm; the MoQ control runs first, since the SRT
# lane's latency is set from it.
for rep in $(seq 1 "$REPS"); do
	for lane in $LANES; do
		for kill in $KILLS; do
			if [ "$lane" = srt ] && [ -z "$SRT_LATENCY_MS" ]; then
				echo "== $lane-$kill-$rep: VOID, no SRT latency (set SRT_LATENCY_MS or run a MoQ control first) =="
				continue
			fi
			run_cell "$lane" "$kill" "$rep"
		done
	done
done

echo
echo "=== $(date -u) done: $OUT ==="
