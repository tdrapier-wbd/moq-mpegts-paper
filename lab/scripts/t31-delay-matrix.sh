#!/usr/bin/env bash
# T31 criteria 6, 7 and 9 (P1-d, P2-e): n MoQ feeds on one shared bottleneck at a release delay,
# every subscriber timed and graded on content.
#
# T8b C3 found the media-aware lane's aggregate falling as feeds were added, and traced it to each
# subscriber shedding against its own budget. Criterion 7 asks where that knee sits on a `--delay`
# build, across n feeds, the delay and the base RTT. Each feed is its own publisher, broadcast and
# subscriber through one relay, as in C3, so the shaped class is shared and nothing else is.
#
# The class is held at CAP_X x n x the stream's rate for the whole window, as C3 held its class:
# CAP_X 0.8 is the rung, 2 the unimpaired control each subscriber is read against. Every feed has the
# matched ladder's taps (source mirrored, egress inline, one host clock), so its delivery latency is
# measured (criterion 6), and every capture is graded on content from 8 s in, with the export's
# late-drop count (criterion 7).
#
#   sudo env BIN=/home/ubuntu/bin-b581c27e bash t31-delay-matrix.sh <label>
#
# Env: NS ("2 3"), DELAYS ("1 2 4 6" s), RTTS ("20 100 200" ms), CAP_XS ("2 0.8"), REPS (3), REP_FROM (1),
#      SECS (80), STREAM_MBIT (9.95), CLIP, VPID, NETNS, CONTENT, LATENCY, OUT,
#      MOQ_CC (relay controller, `delay` = BBRv3 | `loss` = CUBIC), KEEP_TS=1 (keep captures).
# Output: <OUT>/<label>/summary.csv, one row per subscriber per cell.
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
OUT=${OUT:-/home/ubuntu/p1d}/$LABEL
MOQ_CC=${MOQ_CC:-delay}
NS=${NS:-"2 3"}
DELAYS=${DELAYS:-"1 2 4 6"}
RTTS=${RTTS:-"20 100 200"}
CAP_XS=${CAP_XS:-"2 0.8"}
REPS=${REPS:-3}
SECS=${SECS:-80}
STREAM_MBIT=${STREAM_MBIT:-9.95}
PORT=4443
PUBIP=10.99.0.1

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
for f in "$NETNS" "$CLIP" "$CONTENT" "$LATENCY" "$BIN/moq" "$BIN/moq-relay"; do
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
SUMMARY=$OUT/summary.csv
echo "n,rtt_ms,delay_s,cap_x,cap_mbit,rep,flow,capture_bytes,video_lost_s,video_largest_s,audio_lost_s,lat_median_ms,lat_p95_ms,matched_pictures,late_video,late_all,clock_dropped,clock_drift_ppm,clock_out_of_tolerance" >"$SUMMARY"

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

# Patterns match the workers, never the launcher: this script runs as `sudo env … bash …`, so a
# pattern naming a path the environment also names would kill the run itself.
cleanup_procs() {
	pkill -9 -f "[m]oq-relay.*$PUBIP:$PORT" 2>/dev/null
	pkill -9 -f "t31dm[.]" 2>/dev/null
	pkill -9 -f "[t]sp -I file $CLIP" 2>/dev/null
	pkill -9 -f "python3 .*t18-latency\.py tap" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "=== $(date -u) t31-delay-matrix $LABEL ==="
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	cat "$BIN.sha" 2>/dev/null || cat "$BIN/.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	echo "relay controller: $MOQ_CC; n: $NS; delays: $DELAYS; rtts: $RTTS; cap_x: $CAP_XS; secs: $SECS; stream: $STREAM_MBIT Mb/s"
	tsp --version 2>&1 | head -1
} | tee "$OUT/build.txt"

# $1 n, $2 rtt (ms), $3 delay (s), $4 cap multiple, $5 rep
run_cell() {
	local n=$1 rtt=$2 delay=$3 capx=$4 rep=$5
	local name="n$n-r$rtt-d$delay-x$capx-$rep"
	local d="$OUT/$name" cap i
	mkdir -p "$d"
	cleanup_procs
	cap=$(awk -v s="$STREAM_MBIT" -v x="$capx" -v n="$n" 'BEGIN{printf "%.2f", s*x*n}')
	echo
	echo "== $name: $n feeds, RTT ${rtt} ms, --delay ${delay}s, class ${cap} Mb/s =="
	# `t8b-netns.sh` sizes its queue in integer shell arithmetic, so the class comes up at a whole
	# rate and is set to the exact one before any traffic, as the ladders' `set_rate` does.
	if ! { RATE_MBIT=20 DELAY_MS=$((rtt / 2)) bash "$NETNS" up &&
		RATE_MBIT=20 DELAY_MS=$((rtt / 2)) bash "$NETNS" cake &&
		pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${cap}mbit" &&
		pub tc qdisc show dev veth-pub; } >"$d/shape.log" 2>&1; then
		echo "   VOID: shaping failed ($(tail -1 "$d/shape.log"))"
		return 0
	fi
	echo "cell_start_ns $(date +%s%N)" >"$d/events.txt"

	pub "$BIN/moq-relay" "${RELAY_BIND[@]}" "$PUBIP:$PORT" "${RELAY_TLS[@]}" "$PUBIP" \
		"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" "$RELAY_CC_FLAG" "$MOQ_CC" --log-level warn >"$d/relay.log" 2>&1 &
	sleep 3
	pgrep -f "[m]oq-relay.*$PUBIP:$PORT" >/dev/null || {
		echo "   VOID: relay did not start ($(tail -1 "$d/relay.log"))"
		return 0
	}
	# A broadcast name unique to the cell and the feed, so no subscriber attaches to a retained
	# announce from an earlier cell.
	local bc="t31dm.$name.$$"
	for i in $(seq 1 "$n"); do
		sub bash -c "timeout $((SECS + 3)) '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' \
                --broadcast '$bc.$i' export ts ${MOQ_LAT[*]} ${delay}s \
              | python3 '$LATENCY' tap $VPID '$d/eg.$i.csv' --pipe --seconds $((SECS + 5)) --save '$d/out.$i.ts' > /dev/null" \
			>"$d/sub.$i.log" 2>&1 &
	done
	sleep 2
	for i in $(seq 1 "$n"); do
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous \
                -P fork --nowait --ignore-abort \"python3 '$LATENCY' tap $VPID '$d/src.$i.csv' --pipe --seconds $((SECS + 5)) > /dev/null\" \
                -O file - 2>/dev/null \
              | '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' --broadcast '$bc.$i' import ts" \
			>"$d/pub.$i.log" 2>&1 &
	done
	sleep "$SECS"
	cleanup_procs
	bash "$NETNS" down >/dev/null 2>&1

	for i in $(seq 1 "$n"); do
		local bytes late_v late_all lat_median=NA lat_p95=NA matched=NA clock
		bytes=$(stat -c%s "$d/out.$i.ts" 2>/dev/null || echo 0)
		# The export's once-a-second release-clock line: its drop counter and drift estimate.
		clock=$(sed 's/\x1b\[[0-9;]*m//g' "$d/sub.$i.log" | grep "release clock" | tail -n 1 |
			sed -E 's/.*dropped=([0-9]+).*drift_ppm=Some\(([-0-9.]+)\).*out_of_tolerance=([0-9]+).*/\1,\2,\3/;t;s/.*/NA,NA,NA/')
		[ -n "$clock" ] || clock=NA,NA,NA
		late_all=$(sed 's/\x1b\[[0-9;]*m//g' "$d/sub.$i.log" | grep -c "missed its deadline" || true)
		late_v=$(sed 's/\x1b\[[0-9;]*m//g' "$d/sub.$i.log" | grep "missed its deadline" |
			grep -cE 'track=[^ ]*(avc|hev|h26)' || true)
		if [ "$bytes" -lt 200000 ]; then
			echo "   flow $i VOID: ${bytes}B captured"
			echo "$n,$rtt,$delay,$capx,$cap,$rep,$i,$bytes,VOID,VOID,VOID,NA,NA,NA,$late_v,$late_all,$clock" >>"$SUMMARY"
			continue
		fi
		python3 "$CONTENT" --input "$d/out.$i.ts" --from-s 8 --label "$name.$i" \
			--json "$d/content.$i.json" >/dev/null 2>&1
		python3 "$LATENCY" report "$d/src.$i.csv" "$d/eg.$i.csv" --label "$name.$i" \
			--clock-offset 0 --settle 8 --kv "$d/lat.$i.kv" >"$d/lat.$i.txt" 2>&1 || true
		# shellcheck disable=SC1090
		[ -r "$d/lat.$i.kv" ] && . "$d/lat.$i.kv"
		python3 - "$d/content.$i.json" <<-PY >>"$SUMMARY"
			import json, sys
			try:
			    c = json.load(open(sys.argv[1]))
			except (OSError, ValueError):
			    c = {}
			row = ["$n", "$rtt", "$delay", "$capx", "$cap", "$rep", "$i", "$bytes",
			       c.get("content_lost_s", "NA"), c.get("largest_hole_s", "NA"), c.get("audio_lost_s", "NA"),
			       "$lat_median", "$lat_p95", "$matched", "$late_v", "$late_all", "$clock"]
			print(",".join(str(x) for x in row))
		PY
		tail -n 1 "$SUMMARY" | awk -F, '{printf "   flow %s: video lost %s s, latency %s ms, late video %s\n", $7, $9, $12, $15}'
		[ "${KEEP_TS:-0}" = 1 ] || rm -f "$d/out.$i.ts"
	done
}

# Interleaved so a drift in host load lands on every arm, not on one.
for rep in $(seq "${REP_FROM:-1}" "$REPS"); do
	for rtt in $RTTS; do
		for n in $NS; do
			for delay in $DELAYS; do
				for capx in $CAP_XS; do
					run_cell "$n" "$rtt" "$delay" "$capx" "$rep"
				done
			done
		done
	done
done

echo
echo "=== $(date -u) done: $OUT ==="
