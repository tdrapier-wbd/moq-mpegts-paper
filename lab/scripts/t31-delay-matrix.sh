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
# DIP_S > 0 makes each rung a transient instead (criterion 10): the class runs at BASE_X x n and
# drops to CAP_X x n for DIP_S seconds from DIP_AT into the window; the BASE_X cell is its control.
# Every cell samples the shaper's queue (bytes sent, drops, backlog) every 0.5 s.
#
#   sudo env BIN=/home/ubuntu/bin-b581c27e bash t31-delay-matrix.sh <label>
#   sudo env BIN=… DIP_S=5 DELAYS="1 2 6" RTTS="20 200" bash t31-delay-matrix.sh <label>
#
# Env: NS ("2 3"), DELAYS ("1 2 4 6" s), RTTS ("20 100 200" ms), CAP_XS ("2 0.8"), REPS (3), REP_FROM (1),
#      SECS (80), STREAM_MBIT (9.95), DIP_S (0), DIP_AT (30 s), BASE_X (2), CLIP, VPID, NETNS, CONTENT,
#      LATENCY, OUT, MOQ_CC (relay controller, `delay` = BBRv3 | `loss` = CUBIC), KEEP_TS=1 (keep captures).
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
DIP_S=${DIP_S:-0}
DIP_AT=${DIP_AT:-30}
BASE_X=${BASE_X:-2}
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
echo "n,rtt_ms,delay_s,cap_x,cap_mbit,rep,flow,capture_bytes,video_lost_s,video_largest_s,audio_lost_s,lat_median_ms,lat_p95_ms,matched_pictures,late_video,late_all,clock_dropped,clock_drift_ppm,clock_out_of_tolerance,base_mbit,dip_at_s,dip_s,q_drops,q_drops_dip,q_backlog_max_bytes,q_mem_max_bytes,wire_mbit_all,wire_mbit_pre,wire_mbit_dip,wire_mbit_post" >"$SUMMARY"

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
	[ "$DIP_S" = 0 ] || echo "transient: class at ${BASE_X}x n, ${DIP_S} s at cap_x n from ${DIP_AT} s"
	tsp --version 2>&1 | head -1
} | tee "$OUT/build.txt"

# $1 n, $2 rtt (ms), $3 delay (s), $4 cap multiple, $5 rep
run_cell() {
	local n=$1 rtt=$2 delay=$3 capx=$4 rep=$5
	local name="n$n-r$rtt-d$delay-x$capx-$rep"
	local d cap base dip_s=0 dip_at=0 i
	cap=$(awk -v s="$STREAM_MBIT" -v x="$capx" -v n="$n" 'BEGIN{printf "%.2f", s*x*n}')
	base=$cap
	if [ "$DIP_S" != 0 ] && [ "$capx" != "$BASE_X" ]; then
		base=$(awk -v s="$STREAM_MBIT" -v x="$BASE_X" -v n="$n" 'BEGIN{printf "%.2f", s*x*n}')
		dip_s=$DIP_S dip_at=$DIP_AT
		name="n$n-r$rtt-d$delay-x${capx}t$DIP_S-$rep"
	fi
	d="$OUT/$name"
	mkdir -p "$d"
	cleanup_procs
	echo
	if [ "$dip_s" != 0 ]; then
		echo "== $name: $n feeds, RTT ${rtt} ms, --delay ${delay}s, class ${base} Mb/s, ${cap} for ${dip_s} s from ${dip_at} s =="
	else
		echo "== $name: $n feeds, RTT ${rtt} ms, --delay ${delay}s, class ${cap} Mb/s =="
	fi
	# `t8b-netns.sh` sizes its queue in integer shell arithmetic, so the class comes up at a whole
	# rate and is set to the exact one before any traffic, as the ladders' `set_rate` does.
	if ! { RATE_MBIT=20 DELAY_MS=$((rtt / 2)) bash "$NETNS" up &&
		RATE_MBIT=20 DELAY_MS=$((rtt / 2)) bash "$NETNS" cake &&
		pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${base}mbit" &&
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
	# The trailing comment carries the cell's `t31dm.` tag, so cleanup_procs ends the sampler too.
	pub bash -c "while :; do printf '%s ' \"\$(date +%s%N)\"; tc -s -j qdisc show dev veth-pub | tr -d '\n'; echo; sleep 0.5; done # t31dm.qdisc" \
		>"$d/qdisc.log" 2>/dev/null &
	local dipper=
	if [ "$dip_s" != 0 ]; then
		(
			sleep "$dip_at"
			pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${cap}mbit" &&
				echo "impair_start_ns $(date +%s%N)" >>"$d/events.txt"
			sleep "$dip_s"
			pub tc qdisc change dev veth-pub parent 1:1 handle 10: cake bandwidth "${base}mbit" &&
				echo "impair_end_ns $(date +%s%N)" >>"$d/events.txt"
		) &
		dipper=$!
	fi
	sleep "$SECS"
	[ -z "$dipper" ] || kill "$dipper" 2>/dev/null
	cleanup_procs
	bash "$NETNS" down >/dev/null 2>&1

	local q_drops=NA q_drops_dip=NA q_backlog_max_bytes=NA q_mem_max_bytes=NA
	local wire_mbit_all=NA wire_mbit_pre=NA wire_mbit_dip=NA wire_mbit_post=NA
	# The shaper's own counters: wire rate through it over the graded window and, for a transient,
	# the 5 s before the dip, the dip and the 5 s after; drops over the dip and its drain.
	python3 - "$d/qdisc.log" "$d/events.txt" <<-'PY' >"$d/qdisc.kv" 2>/dev/null
		import json, sys
		rows = []
		for line in open(sys.argv[1]):
		    t, _, js = line.partition(" ")
		    try:
		        q = next(q for q in json.loads(js) if q.get("kind") == "cake")
		    except (ValueError, StopIteration):
		        continue
		    rows.append((int(t), q["bytes"], q["drops"], q["backlog"], q.get("memory_used", 0)))
		ev = {}
		for line in open(sys.argv[2]):
		    k, _, v = line.strip().partition(" ")
		    ev[k] = int(v)
		def window(a, b):
		    return [r for r in rows if a <= r[0] <= b]
		def rate(w):
		    if len(w) < 2:
		        return "NA"
		    return "%.2f" % ((w[-1][1] - w[0][1]) * 8 / ((w[-1][0] - w[0][0]) / 1e9) / 1e6)
		out = {}
		if rows:
		    graded = window(rows[0][0] + 8_000_000_000, rows[-1][0])
		    out["q_drops"] = rows[-1][2] - rows[0][2]
		    out["q_backlog_max_bytes"] = max(r[3] for r in rows)
		    out["q_mem_max_bytes"] = max(r[4] for r in rows)
		    out["wire_mbit_all"] = rate(graded)
		s, e = ev.get("impair_start_ns"), ev.get("impair_end_ns")
		if rows and s and e:
		    out["wire_mbit_pre"] = rate(window(s - 5_000_000_000, s))
		    out["wire_mbit_dip"] = rate(window(s, e))
		    out["wire_mbit_post"] = rate(window(e, e + 5_000_000_000))
		    drain = window(s, e + 5_000_000_000)
		    out["q_drops_dip"] = drain[-1][2] - drain[0][2] if len(drain) > 1 else "NA"
		for k, v in out.items():
		    print("%s=%s" % (k, v))
	PY
	# shellcheck disable=SC1091
	[ -s "$d/qdisc.kv" ] && . "$d/qdisc.kv"

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
			echo "$n,$rtt,$delay,$capx,$cap,$rep,$i,$bytes,VOID,VOID,VOID,NA,NA,NA,$late_v,$late_all,$clock,$base,$dip_at,$dip_s,$q_drops,$q_drops_dip,$q_backlog_max_bytes,$q_mem_max_bytes,$wire_mbit_all,$wire_mbit_pre,$wire_mbit_dip,$wire_mbit_post" >>"$SUMMARY"
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
			       "$lat_median", "$lat_p95", "$matched", "$late_v", "$late_all", "$clock",
			       "$base", "$dip_at", "$dip_s", "$q_drops", "$q_drops_dip", "$q_backlog_max_bytes",
			       "$q_mem_max_bytes", "$wire_mbit_all", "$wire_mbit_pre", "$wire_mbit_dip", "$wire_mbit_post"]
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
