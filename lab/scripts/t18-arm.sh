#!/usr/bin/env bash
# T18 — delivery latency at equal conformance, one arm at one cushion.
#
#   t18-arm.sh <src.ts> <out-dir> <capture-seconds> <arm> [cushion-ms]
#
#     udp     plain UDP, no reliable transport — the instrument's control
#     srt     TSDuck srt plugin, matched jitter buffer
#     rist    TSDuck rist plugin, RIST Main profile, matched jitter buffer
#     moq     the media-aware lane: relay, importer, exporter
#     hls     classic segmented HTTP: tsp -O hls -> HTTP -> tsp -I hls
#
# **Latency without a conformance level is not a comparison.** The planes do not
# cost the same amount of buffering to reach the same wire: [T13](../test-13-downstream-grooming.md)
# measured the MoQ lane failing the 40 ms PCR repetition gate on the wire at the
# cushion it runs, while [T16](../test-16-grooming-segmented-http.md) reached zero
# on a segmented egress only at an 8 s cushion. Quoting one number per transport
# would therefore rank a non-conformant arm against a conformant one and call the
# difference transport. So the cushion is an argument here, every arm is graded at
# each step of a sweep, and what the experiment reports is the pair — the latency
# and whether the wire passed — rather than either alone.
#
# The chain is deliberately the same shape on every arm, and the same shape as
# [T15](../test-15-point-to-point-cadence.md): the file's own bytes paced off
# their own PCR, one tap, a network hop, a reassembly stage, one groomer, and the
# same tap again on the groomed egress. Only the middle changes. The `udp` arm has
# no jitter buffer, no retransmission and no pacing of its own, so whatever it
# shows is the *rig's* latency rather than a protocol's, and no other arm means
# anything until it has been run.
#
# Both taps key on the presentation timestamp, which is what lets one instrument
# grade a byte-transparent tunnel and a remultiplexer: see `t18-latency.py`.
#
# Background processes do not survive between tool invocations in this
# environment, so every stage starts and stops inside one run.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?capture seconds}
ARM=${4:?arm: udp|srt|rist|moq|hls}
CUSHION=${5:-1000}

# Each arm gets its own port block: a listener from the previous arm can still be
# held when the next starts, and the failure mode is a publisher exiting with
# "Address already in use" while the receiver waits for it forever.
case "$ARM" in
udp) OFFSET=0 ;;
srt) OFFSET=10 ;;
rist) OFFSET=20 ;;
moq) OFFSET=30 ;;
hls) OFFSET=40 ;;
*)
	echo "unknown arm: $ARM" >&2
	exit 1
	;;
esac
PORT=${PORT:-$((18200 + OFFSET))}
EPORT=$((PORT + 5)) # groomer -> egress tap

VPID=${VPID:-111}      # the video PID the taps key on
RATE=${RATE:-10000000} # groomer output mux rate; must exceed content rate
BUFMS=${BUFMS:-1000}   # SRT/RIST jitter buffer
MOQLAT=${MOQLAT:-3s}   # moq export ts --latency-max
WAITMIN=${WAITMIN:-5}  # regulate release granularity
SEGDUR=${SEGDUR:-2}    # hls segment duration
# The cap, not the cushion, is what a latency measurement ends up quoting. A
# groomer that ever runs ahead settles at whatever depth it is allowed to hold and
# stays there, so a generous cap becomes the standing latency: measured, a 1000 ms
# cushion under a 4000 ms cap delivered a flat 4.2 s, which is the cap and tells
# you nothing about the transport. Keep the headroom small and deliberate.
CAP=${CAP:-$((CUSHION + 500))}
STALL=${STALL:-$((CUSHION + 2000))}
SETTLE=${SETTLE:-10} # seconds of startup discarded before the distribution is quoted
SSRC=${SSRC:-538968071}
CLOCK_OFFSET=${CLOCK_OFFSET:-0}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACER=${PACER:?set PACER to the mpegts-pacer binary}

command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}

mkdir -p "$OUT"
# A tap left behind by an earlier run holds the egress port, and the tell is a
# measurement that reads as "the transport delivered nothing" rather than as a
# collision. Refuse up front instead.
if pgrep -f 't18-latency.py tap' >/dev/null 2>&1; then
	echo "a t18 tap is already running; clear it before starting:" >&2
	pgrep -lf 't18-latency.py tap' >&2
	exit 1
fi

TAG="$ARM-c$CUSHION"
SRCCSV="$OUT/$TAG-source.csv"
EGCSV="$OUT/$TAG-egress.csv"

# Job control, so every background stage becomes its own process group and teardown
# can kill the group rather than the group leader. Without it a `( a | b | c ) &` is
# reaped by its subshell's pid alone, the three real processes survive, and the next
# cell then refuses to start because a stray tap still holds the egress port — or
# worse, competes for the CPU that is being measured.
set -m

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
	done
	sleep 0.5
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill -KILL -- "-$pid" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

# The source half is identical on every arm: the file's own bytes, paced off their
# own PCR, tapped once before anything transport-specific sees them. Every arm
# therefore shares one definition of "when this picture left".
source_into() {
	(
		sleep "${PUBLISH_DELAY:-0}"
		tsp --realtime -I file "$SRC" --infinite \
			-P regulate --pcr-synchronous --wait-min "$WAITMIN" \
			-O file - |
			python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$SRCCSV" --pipe --seconds "$SECS" |
			"$@"
	) >"$OUT/$TAG-send.log" 2>&1 &
	SENDER=$!
	PIDS+=("$SENDER")
}

require_sender() {
	kill -0 "$SENDER" 2>/dev/null || {
		echo "sender exited before the capture started:" >&2
		cat "$OUT/$TAG-send.log" >&2
		exit 1
	}
}

# The groomer is the stage the conformance gate applies to, so its depths are the
# swept variable and everything else about it is fixed.
groom=(
	"$PACER" "127.0.0.1:$EPORT" "$RATE" --rtp --ssrc "$SSRC"
	--latency-ms "$CUSHION" --max-latency-ms "$CAP"
	--stall-ms "$STALL" --on-stall mute
)

case "$ARM" in
udp)
	# `-I ip` takes a bare port for unicast; an address there means multicast.
	source_into tsp --realtime -I file - -O ip "127.0.0.1:$PORT"
	sleep 3
	require_sender
	RECEIVE=(tsp --realtime -I ip "$PORT" -O file -)
	;;
srt | rist)
	# The receiver listens and the source calls, on both tunnels. The other way round
	# cannot work here: this rig's receive stage is the *foreground* command and starts
	# last, so a source that listens is never called within SRT's 3 s connect timeout
	# and the run reports a timed-out handshake rather than a latency. Delaying the
	# source instead lets the listener be up first, which is also how T15 arranges its
	# RIST simple leg.
	PUBLISH_DELAY=${PUBLISH_DELAY:-5}
	if [ "$ARM" = srt ]; then
		source_into tsp --realtime -I file - -O srt --caller "127.0.0.1:$PORT" --latency "$BUFMS"
		RECEIVE=(tsp --realtime -I srt --listener "127.0.0.1:$PORT" --latency "$BUFMS" -O file -)
	else
		source_into tsp --realtime -I file - \
			-O rist --profile main "rist://127.0.0.1:$PORT?buffer=$BUFMS"
		RECEIVE=(tsp --realtime -I rist --profile main "rist://@127.0.0.1:$PORT?buffer=$BUFMS" -O file -)
	fi
	;;
moq)
	MOQ=${MOQ:-$HOME/bin-main/moq}
	RELAY=${RELAY:-$HOME/bin-main/moq-relay}
	BCAST=${BCAST:-t18.latency.hang}
	# `exec` so the recorded pid is the relay itself: without it teardown kills only
	# the subshell and the relay survives to hold the port into the next run.
	cp "${RELAY_TOML:-$HOME/moq-dev/demo/relay/localhost.toml}" "$OUT/relay.toml"
	(cd "$OUT" && exec "$RELAY" relay.toml --server-quic-gso=false) >"$OUT/$TAG-relay.log" 2>&1 &
	RELAY_PID=$!
	PIDS+=("$RELAY_PID")
	for _ in $(seq 1 40); do
		FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
		[ -n "$FP" ] && break
		sleep 0.25
	done
	[ -n "${FP:-}" ] || {
		echo "relay did not come up; see $OUT/$TAG-relay.log" >&2
		exit 1
	}
	# A fingerprint proves *a* relay is on the port, not that it is ours.
	kill -0 "$RELAY_PID" 2>/dev/null || {
		echo "our relay exited but :4443 answered: another relay holds the port." >&2
		exit 1
	}
	C=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)
	# Subscriber first: reservation gating publishes the catalog once tracks resolve.
	RECEIVE=("$MOQ" "${C[@]}" --broadcast "$BCAST" export ts --latency-max "$MOQLAT")
	source_into "$MOQ" "${C[@]}" --broadcast "$BCAST" import ts
	sleep 3
	require_sender
	;;
hls)
	HDIR="$OUT/hls"
	HPORT=$((PORT + 1))
	rm -rf "$HDIR" && mkdir -p "$HDIR"
	(cd "$HDIR" && exec python3 -m http.server "$HPORT" --bind 127.0.0.1) \
		>"$OUT/$TAG-http.log" 2>&1 &
	PIDS+=($!)
	source_into tsp --realtime -I file - \
		-O hls --live 6 --live-extra-segments 3 --duration "$SEGDUR" \
		--intra-close --align-first-segment \
		--playlist "$HDIR/index.m3u8" "$HDIR/seg.ts"
	# `tsp -I hls` exits on an empty playlist, so wait for the live window to fill.
	for _ in $(seq 1 120); do
		[ "$(find "$HDIR" -name 'seg*.ts' | wc -l)" -ge 3 ] && break
		sleep 0.5
	done
	require_sender
	RECEIVE=(tsp --realtime -I hls --live "http://127.0.0.1:$HPORT/index.m3u8" -O file -)
	;;
esac

# The egress tap binds before the groomer sends, or the first datagrams are lost
# and the measured minimum is whatever survived the race.
python3 "$SCRIPTS/t18-latency.py" tap "$VPID" "$EGCSV" --udp "$EPORT" --rtp --seconds "$SECS" \
	--save "$OUT/$TAG-egress.ts" >"$OUT/$TAG-tap.log" 2>&1 &
TAP=$!
PIDS+=("$TAP")
sleep 1

echo "==> $ARM, cushion ${CUSHION} ms, cap ${CAP} ms, ${SECS}s, rate ${RATE} b/s"
# `timeout`, and in the foreground. A receive stage blocked on a socket whose sender
# has gone never notices that its own output pipe closed, so killing the pipeline by
# `$!` reaps the groomer and leaves the receiver running — and the script's `wait`
# then blocks on it for ever.
set +e
timeout "$((SECS + 2))" "${RECEIVE[@]}" 2>"$OUT/$TAG-receive.log" |
	"${groom[@]}" >"$OUT/$TAG-groom.log" 2>&1
# The tap owns the egress log, so let it finish before reading it. Without this the
# report can win the race and grade an unflushed file.
wait "$TAP" 2>/dev/null
set -e

echo
echo "=== delivery latency: $ARM at a ${CUSHION} ms cushion ==="
python3 "$SCRIPTS/t18-latency.py" report "$SRCCSV" "$EGCSV" \
	--label "$ARM c=${CUSHION}ms" --clock-offset "$CLOCK_OFFSET" --settle "$SETTLE" \
	--kv "$OUT/$TAG.kv"
# The other half of the pair. A latency figure is only comparable across arms at a
# stated conformance level, so grade the same bytes: PCR accuracy at the TR 101 290
# gate (±500 ns is 13.5 units of the 27 MHz clock, hence 13), PCR repetition, and
# continuity. These are *wire* readings — the domain in which T13 found the MoQ lane
# failing at the cushion it runs, where the same stream passes as a file.
echo
echo "=== wire conformance of the same bytes ==="
if [ -s "$OUT/$TAG-egress.ts" ]; then
	CC=$(tsp -I file "$OUT/$TAG-egress.ts" -P continuity -O drop 2>&1 | grep -c 'discontinuity' || true)
	# pcrverify prints one summary line; take the count out of it rather than counting
	# lines, which merely matches the word "jitter" in the summary itself.
	JIT=$(tsp -I file "$OUT/$TAG-egress.ts" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 |
		sed -n 's/.*OK, *\([0-9,]*\) with jitter.*/\1/p' | tr -d ',')
	# `-o -` writes nothing, so the CSV needs a real file. The PCR value is column 6;
	# column 7 is the same series expressed as an offset from the first PCR, so
	# consecutive differences agree — either works, and 6 is the one that reads true.
	tsp -I file "$OUT/$TAG-egress.ts" -P pcrextract --pcr --csv \
		-o "$OUT/$TAG-pcr.csv" -O drop >/dev/null 2>&1 || true
	REP=$(awk -F, 'NR>1 && $4=="PCR"{c=$6;if(p!=""){d=(c-p)/27000;n++;if(d>40)o++;if(d>mx)mx=d}p=c}
		END{printf "%d,%d,%.1f", o+0, n+0, mx+0}' "$OUT/$TAG-pcr.csv")
	REP_OVER=${REP%%,*}
	REP_MAX=${REP##*,}
	REP_TOTAL=$(echo "$REP" | cut -d, -f2)
	echo "   continuity errors $CC, PCR jitter >481 ns ${JIT:-?}," \
		"repetition >40 ms ${REP_OVER}/${REP_TOTAL}, max ${REP_MAX} ms"
else
	echo "   no egress stream captured"
fi

# One row per cell, both halves together: the sweep's table is the experiment, and a
# latency column without its conformance column beside it is the thing this
# experiment exists to avoid quoting.
SUMMARY="$OUT/summary.csv"
[ -s "$SUMMARY" ] || echo "arm,cushion_ms,cap_ms,matched,seen,shift,lat_min,lat_median,lat_p95,lat_max,trend_head,trend_tail,window_s,cc_errors,pcr_jitter_over,rep_over,rep_total,rep_max_ms" >"$SUMMARY"
if [ -s "$OUT/$TAG.kv" ]; then
	# shellcheck source=/dev/null
	. "$OUT/$TAG.kv"
	# The latency fields come from the file just sourced, which shellcheck cannot see.
	# shellcheck disable=SC2154
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$ARM" "$CUSHION" "$CAP" "$matched" "$seen" "$shift" \
		"$lat_min" "$lat_median" "$lat_p95" "$lat_max" \
		"$trend_head" "$trend_tail" "$window" \
		"${CC:-}" "${JIT:-}" "${REP_OVER:-}" "${REP_TOTAL:-}" "${REP_MAX:-}" \
		>>"$SUMMARY"
fi

echo
echo "artefacts in $OUT: $TAG-{source,egress}.csv $TAG-egress.ts $TAG-*.log"
