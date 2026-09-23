#!/usr/bin/env bash
# P1-m — the SRT arm on T28's outage ladder, at latency budgets matched to the MoQ lane's.
#
# T28 and T31 measured programme loss on the MoQ lane only, so neither can rank the two
# architectures — which is what both exist to do. The question here is narrow and comparative:
# **for the same milliseconds of buffer, does MoQ lose more programme than SRT?** It is the
# result the FEC/ARQ position needs; without it any message to the working group is a reframing.
#
# ## The matched-buffer proof is the gate, and it is measured rather than asserted
#
# `--max-age 2s` and `--latency 2000` are not the same mechanism. MoQ's is a *release deadline*
# at the subscriber: a group that cannot be presented inside the budget is discarded whole. SRT's
# is a fixed end-to-end delay inside which retransmission may complete. Setting the two numbers
# equal is an assumption about what they cost, and an SRT arm at an unmatched buffer produces a
# ranking that looks like a result and is not one.
#
# So every budget is also run **unimpaired**, with `t18-latency.py` tapping the PES presentation
# timestamps on both sides of the lane. Both namespaces are on one host, so the two taps share a
# clock exactly and `--clock-offset` is 0. That yields the delivery latency each lane actually
# spends at each nominal budget. The ladder is then read against the *measured* latency, and if
# the two lanes do not track, that is the finding and the nominal budgets are not a matching.
#
# The tap sits inline on both lanes identically — between the pacer and the lane ingress, and
# between the lane egress and the capture — so whatever it costs, it costs both arms.
#
# ## What is graded, and in which domain
#
# `t28-media-lost.py --domain wire`, on both lanes. The file domain is unusable on a raw
# `moq export ts` capture (its PCRs are clustered, so the per-interval rate estimate collapses),
# and grading the two lanes in different domains would compare two different quantities. The
# wire domain references each stream against its own median PCR cadence and ignores byte
# positions, which both lanes support. **The control cells are what license this**: if a
# lane's unimpaired cell does not grade at ~0 lost, its domain is wrong and its impaired cells
# say nothing.
#
# Continuity errors are reported beside programme loss and never netted into it. The two lanes
# fail in opposite directions — MoQ sheds whole groups and stays syntactically clean, SRT keeps
# the bytes and damages them — so a single "loss" column would hide the entire distinction.
#
# **Session survival is a column.** A 5 s total outage is close to SRT's own peer-idle timeout,
# so the session may drop rather than degrade. A dropped session is a result, not a void cell,
# but it must not be read as programme loss on a comparable scale.
#
#   sudo t28-t31-srt-ladder.sh <label>
#
# Env: MOQ/RELAY (binary dir via BIN), BUDGETS, REPS, LANES, CAP_MBIT, OUTAGE, CLIP, VPID,
#      NETNS, GRADER, LATENCY, OUT.
set -uo pipefail

# Post-#3793 CLI flags, detected per binary rather than assumed.
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}

BIN=${BIN:?set BIN to the moq binary dir}
CLIP=${CLIP:-/home/ubuntu/clip120.ts}
VPID=${VPID:-111}
NETNS=${NETNS:-/home/ubuntu/t8b-netns.sh}
GRADER=${GRADER:-/home/ubuntu/t28-media-lost.py}
LATENCY=${LATENCY:-/home/ubuntu/t18-latency.py}
OUT=${OUT:-/home/ubuntu/p1m}/$LABEL

BUDGETS=${BUDGETS:-"0.5 1 2 3 4 6"}
REPS=${REPS:-3}
LANES=${LANES:-"moq srt"}
CAP_MBIT=${CAP_MBIT:-20} # provisioned: comfortably above the ~9.95 Mb/s clip
DELAY_MS=${DELAY_MS:-50} # 100 ms base RTT, as T8b and the MoQ ladder
OUTAGE=${OUTAGE:-5}      # T28's 5 s total outage, the cell being replicated
SETTLE=${SETTLE:-20}
RECOVER=${RECOVER:-35} # must exceed one QUIC idle/recovery cycle
PORT=4443
SRT_PORT=9010
PUBIP=10.99.0.1

[ "$(id -u)" -eq 0 ] || {
	echo "run as root (sudo)" >&2
	exit 1
}
for f in "$NETNS" "$CLIP" "$GRADER" "$LATENCY" "$BIN/moq" "$BIN/moq-relay"; do
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

rm -rf "$OUT"
mkdir -p "$OUT"
SUMMARY=$OUT/summary.csv
echo "lane,budget_s,srt_ms,matched_how,impair,rep,capture_bytes,media_lost_s,media_dup_s,holes,largest_hole_s,continuity_errors,lat_median_ms,lat_p95_ms,matched_pictures,session" >"$SUMMARY"

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

set_loss() { pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" loss "${1}%" limit 100000 >/dev/null 2>&1; }
clear_loss() { pub tc qdisc change dev veth-pub root handle 1: netem delay "${DELAY_MS}ms" limit 100000 >/dev/null 2>&1; }

# Every pattern here has to match the worker and nothing that merely *mentions* the worker.
# `[t]18-latency.py` looked safe — the bracket stops pkill matching its own command line — but
# this script is launched as `sudo env … LATENCY=/home/ubuntu/t18-latency.py bash …`, so the
# pattern matched the launcher's environment and SIGKILLed the whole run one cell in. Anchor on
# the interpreter and the subcommand, which only the actual tap process carries.
cleanup_procs() {
	pkill -9 -f "[m]oq-relay.*$PUBIP:$PORT" 2>/dev/null
	pkill -9 -f "p1mladder" 2>/dev/null
	pkill -9 -f "[t]sp .*$CLIP" 2>/dev/null
	pkill -9 -f "[t]sp -I srt" 2>/dev/null
	# The SRT *listener* matches neither of the above — its input is `-I file -`, not the clip —
	# so without this it survives the cell and holds the port, and every later SRT cell fails
	# to bind.
	pkill -9 -f "[t]sp -I file - -O srt" 2>/dev/null
	pkill -9 -f "python3 .*t18-latency\.py tap" 2>/dev/null
	sleep 1
}
trap 'cleanup_procs; bash "$NETNS" down >/dev/null 2>&1' EXIT

echo "=== $(date -u) p1m $LABEL ==="
"$BIN/moq" --version
tsp --version 2>&1 | head -1

RATE_MBIT=$CAP_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" up || exit 1
RATE_MBIT=$CAP_MBIT DELAY_MS=$DELAY_MS bash "$NETNS" cake || exit 1

# $1 lane, $2 budget (seconds), $3 impair (none|outage), $4 rep
run_cell() {
	local lane=$1 budget=$2 impair=$3 rep=$4
	local d="$OUT/$lane-b$budget-$impair-$rep"
	mkdir -p "$d"
	cleanup_procs
	clear_loss

	local window=$((SETTLE + OUTAGE + RECOVER))
	local budget_ms
	budget_ms=$(awk -v b="$budget" 'BEGIN{printf "%d", b*1000}')
	# **The matched-buffer correction, and the reason this arm exists.** SRT's `--latency` is a
	# fixed end-to-end delay that is always spent; MoQ's `--max-age` is a recovery allowance that
	# a healthy path does not spend at all. Setting one to the other compares a lane running at
	# 2.05 s against a lane running at its own floor *and* holding 2 s of headroom, which is not
	# one buffer measured twice. So SRT is given the MoQ lane's **measured** unimpaired delivery
	# latency at the same budget, read from MATCH_FILE ("<budget> <ms>" per line) produced by the
	# calibration pass. With no match file the arm falls back to the nominal budget and is
	# explicitly *not* the matched comparison — it says so in the log rather than pretending.
	local srt_ms=$budget_ms matched_how=nominal
	if [ -n "${MATCH_FILE:-}" ] && [ -r "$MATCH_FILE" ]; then
		local m
		m=$(awk -v b="$budget" '$1==b{printf "%d", $2}' "$MATCH_FILE")
		if [ -n "$m" ] && [ "$m" -gt 0 ]; then
			srt_ms=$m
			matched_how=measured
		fi
	fi
	local tap_secs=$((window + 5))
	echo
	if [ "$lane" = srt ]; then
		echo "== $lane budget=${budget}s srt_latency=${srt_ms}ms ($matched_how) impair=$impair rep=$rep (${window}s) =="
	else
		echo "== $lane budget=${budget}s impair=$impair rep=$rep (${window}s) =="
	fi

	# A broadcast name unique to the *cell*, not to the replicate. Keying it on `$rep` alone
	# let consecutive budgets share one name: the relay retains the previous cell's announce,
	# so two publishers and two subscribers ended up live on `p1mladder.1` at once and each
	# cell graded a capture contaminated by its predecessor. Include everything that varies.
	local BC="p1mladder.$lane.b$budget.$impair.$rep.$$"

	# The source, tapped on its way into the lane. Identical for both lanes so the tap is not
	# part of what separates them — and *mirrored*, never in the path. An inline tap here was
	# the whole of the 4.563-4.693 s artefact that voided the first SRT pass: it is a Python
	# reader between a `regulate`-paced sender and a real-time transmitter, so its cost is paid
	# as backpressure by a stage that cannot wait. `fork` hands it a copy instead. The same tap
	# on the *egress* is harmless and was never the problem; both are mirrored anyway, because
	# the instrument must be identical on both lanes for the comparison to mean anything.
	# **Position is selectable because the two taps fail differently, and both failures are
	# measured rather than assumed.** Inline at the *source* destroys the stream (4.563-4.693 s
	# lost); mirrored at the *egress* preserves the stream but reports the wrong time, because
	# `tsp` buffers between the pipe and the fork and the tap timestamps its copy on the far
	# side of that buffer. So the defensible rig is mirrored at the source and inline at the
	# egress, and these switches exist so that claim stays falsifiable.
	local TAP_SRC TAP_EG
	if [ "${SRC_TAP:-mirror}" = mirror ]; then
		TAP_SRC="-P fork --nowait --ignore-abort \
        \"python3 '$LATENCY' tap $VPID '$d/src.csv' --pipe --seconds $tap_secs > /dev/null\""
	else
		TAP_SRC=""
	fi
	if [ "${EG_TAP:-inline}" = mirror ]; then
		TAP_EG="-P fork --nowait --ignore-abort \
        \"python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $tap_secs > /dev/null\""
	else
		TAP_EG=""
	fi
	local SRC_INLINE="" EG_SINK EG_SRT_SINK
	[ "${SRC_TAP:-mirror}" = inline ] &&
		SRC_INLINE="| python3 '$LATENCY' tap $VPID '$d/src.csv' --pipe --seconds $tap_secs"
	if [ "${EG_TAP:-inline}" = mirror ]; then
		EG_SINK="tsp -I file - $TAP_EG -O file '$d/out.ts'"
		EG_SRT_SINK="-O file '$d/out.ts'"
	else
		EG_SINK="python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $tap_secs --save '$d/out.ts' > /dev/null"
		EG_SRT_SINK="-O file - | python3 '$LATENCY' tap $VPID '$d/eg.csv' --pipe --seconds $tap_secs --save '$d/out.ts' > /dev/null"
	fi


	case "$lane" in
	moq)
		# `RELAY_AUTH`, never a literal: `--auth-public` inverted at the CLI migration and the
		# wrong value delivers nothing without erroring anywhere.
		pub "$BIN/moq-relay" "${RELAY_BIND[@]}" "$PUBIP:$PORT" "${RELAY_TLS[@]}" "$PUBIP" \
			"${RELAY_AUTH[@]}" "${RELAY_GSO[@]}" --log-level warn >"$d/relay.log" 2>&1 &
		sleep 3
		# Subscriber first: reservation gating publishes the catalog once tracks resolve.
		sub bash -c "timeout $((window + 3)) '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' \
                --broadcast '$BC' export ts ${MOQ_LAT[*]} ${budget}s \
              | $EG_SINK" >"$d/sub.log" 2>&1 &
		sleep 2
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous $TAP_SRC \
                -O file - 2>/dev/null $SRC_INLINE \
              | '$BIN/moq' ${MOQ_DIAL[*]} 'https://$PUBIP:$PORT/anon' \
                --broadcast '$BC' import ts" >"$d/pub.log" 2>&1 &
		;;
	srt)
		# The publisher listens and the subscriber calls, so the media crosses the shaped
		# egress in the same direction as the MoQ lane's.
		pub bash -c "tsp -I file '$CLIP' --infinite -P regulate --pcr-synchronous $TAP_SRC \
                -O file - 2>/dev/null $SRC_INLINE \
              | tsp -I file - -O srt --listener '0.0.0.0:$SRT_PORT' \
                --transtype live --latency $srt_ms" >"$d/pub.log" 2>&1 &
		# Wait for the port, not for a guessed interval. `tsp` does not start its output
		# plugin until the `regulate` input stage has filled, which takes ~8 s with this
		# source — and TSDuck's SRT caller does not retry, so a 3 s sleep here made the
		# caller fail on its single attempt and voided every SRT cell in the first pass
		# with nothing in the publisher's log to say why.
		local bound=0
		for _ in $(seq 1 30); do
			if pub ss -lun 2>/dev/null | grep -q ":$SRT_PORT"; then
				bound=1
				break
			fi
			sleep 1
		done
		if [ "$bound" -ne 1 ]; then
			echo "   FAIL: SRT listener never bound :$SRT_PORT — cell abandoned"
			echo "$lane,$budget,$srt_ms,$matched_how,$impair,$rep,0,NOBIND,NOBIND,NOBIND,NOBIND,NOBIND,NOBIND,NOBIND,NOBIND,nobind" >>"$SUMMARY"
			return 0
		fi
		sub bash -c "timeout $((window + 3)) tsp -I srt --caller '$PUBIP:$SRT_PORT' \
                --transtype live --latency $srt_ms $TAP_EG $EG_SRT_SINK" \
			>"$d/sub.log" 2>&1 &
		;;
	esac

	sleep "$SETTLE"
	if [ "$impair" = outage ]; then
		set_loss 100
		sleep "$OUTAGE"
		clear_loss
	else
		sleep "$OUTAGE"
	fi
	sleep "$RECOVER"
	cleanup_procs

	# ---- grade ----
	local bytes
	bytes=$(stat -c%s "$d/out.ts" 2>/dev/null || echo 0)
	local session=alive
	grep -qiE "connection (lost|broken)|srt.*(error|timeout)|no data" "$d/sub.log" 2>/dev/null && session=dropped

	if [ "$bytes" -lt 200000 ]; then
		echo "   VOID: ${bytes}B captured — the lane delivered nothing"
		echo "$lane,$budget,$srt_ms,$matched_how,$impair,$rep,$bytes,VOID,VOID,VOID,VOID,VOID,VOID,VOID,VOID,$session" >>"$SUMMARY"
		return 0
	fi

	python3 "$GRADER" --input "$d/out.ts" --domain wire --label "$lane-b$budget-$impair-$rep" \
		--json "$d/grade.json" 2>&1 | tail -1

	# The matched-buffer half. `--settle 8` drops the join transient; a figure still moving
	# at the end of the window is a settling rig rather than a lane's latency, which is why
	# `report` prints the trend and this keeps it.
	python3 "$LATENCY" report "$d/src.csv" "$d/eg.csv" --label "$lane-b$budget" \
		--clock-offset 0 --settle 8 --kv "$d/lat.kv" >"$d/lat.txt" 2>&1 || true
	# shellcheck disable=SC1090
	lat_median=NA lat_p95=NA matched=NA
	[ -r "$d/lat.kv" ] && . "$d/lat.kv"

	python3 - "$d/grade.json" "$lane" "$budget" "$srt_ms" "$matched_how" "$impair" "$rep" "$bytes" \
		"${lat_median:-NA}" "${lat_p95:-NA}" "${matched:-NA}" "$session" "$SUMMARY" <<-'PY'
		import json, sys
		g = json.load(open(sys.argv[1]))
		row = sys.argv[2:8] + [
		       g["media_lost_s"], g["media_duplicated_s"], g["hole_count"],
		       g["largest_hole_s"], g.get("continuity_errors", "na")] + sys.argv[9:13]
		open(sys.argv[13], "a").write(",".join(str(x) for x in row) + "\n")
	PY
	grep -E "latency ms|trend" "$d/lat.txt" 2>/dev/null | sed 's/^/   /'
	rm -f "$d/out.ts" # the grade is the measurement; 70 MB a cell is not
}

for rep in $(seq 1 "$REPS"); do
	for lane in $LANES; do
		for b in $BUDGETS; do
			# The control is the point: without an unimpaired cell through the same rig at
			# the same budget, the netns path's own floor is indistinguishable from the
			# outage's cost — and the wire-domain grading is unlicensed.
			for im in ${IMPAIRS:-none outage}; do
				# The unimpaired control is run once per budget, not once per
				# replicate: it establishes the rig's floor, which does not move.
				[ "$im" = none ] && [ "$rep" != 1 ] && continue
				run_cell "$lane" "$b" "$im" "$rep"
			done
		done
	done
done

echo
echo "=== summary ==="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo "=== $(date -u) done: $OUT ==="
