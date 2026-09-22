#!/usr/bin/env bash
# T13 P1-n — can `mpegts-pacer` be retired now that #3006 and #3831 have landed?
#
# The question is not "has the exporter improved", which it plainly has, but "does anything a
# deployment needs still live only in the groomer". Three properties decide it, and they are
# independent: a stream can pass any one and fail the others.
#
#   1. CONFORMANCE. Is the egress a transport stream a receiver clocking off packet arrival can
#      take? #3831 made the exporter pad to the declared rate, so the *total* is now right. That
#      is not the same as the bytes being where the PCR says they are, which is what a P2 gate
#      grades and what [T13] measured as absent. Arms `export` and `pacer-arrival` here.
#
#   2. DETERMINISM. Can two independent egress processes of one broadcast be merged by an
#      ST 2022-7 receiver? This is the 1+1 requirement and it is binary: the legs are
#      byte-identical for the same media or the pair is not a pair. Arms `export` (two processes)
#      and `pacer-stream` (two processes) against `ts-pair-diff.py`.
#
#   3. LIVENESS. Does the egress distinguish a source that is late from a source that is gone?
#      A pacer whose upstream dies emits a byte-perfect carrier with no programme in it, and
#      every ordinary monitor reads it as healthy. Graded separately by `t13-liveness.sh`; this
#      rig only records whether the exporter has any equivalent.
#
# Why the pacer is in the path twice and in two modes. Its default `Arrival` clocking is the one
# every conformance figure in this campaign was taken through. `Stream` clocking is the mode the
# 1+1 requirement needs, and it is *also* an instrument: it can only place a packet on the slot
# its PCR implies if the source's PCR byte positions track its PCR values, so its
# `pcr_position_displacement` counter measures precisely the defect [T13] found in the exporter.
# A large displacement here is not a pacer fault — it is the exporter's residual, quantified by
# the one instrument that has to care about it.
#
# Fairness. Every arm subscribes to ONE broadcast from ONE publisher over ONE relay, concurrently,
# so no arm gets a different source, a different network or a different minute. The two processes
# of a determinism pair are started a few seconds apart deliberately: a pair that only matches
# when started simultaneously is not a redundancy pair, it is a coincidence.
#
#   t13-pacer-headtohead.sh <label> [seconds]
#
# Env: BIN (moq binary dir), PACER (mpegts-pacer binary), CLIP, PORT, RATE, LATENCY_MS, OUT.
set -uo pipefail

# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
SECS=${2:-120}

BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
CLIP=${CLIP:-$HOME/clip120.ts}
PORT=${PORT:-4471}
# The clip's own multiplex rate. Stream clocking requires an explicit rate — an auto rate is
# measured from one process's arrival window, so two legs would lock different grids.
RATE=${RATE:-9945951}
# And an explicit cushion, for the same reason: an adaptive one is measured per process.
LATENCY_MS=${LATENCY_MS:-200}
OUT=${OUT:-$HOME/t13-p1n}/$LABEL
# The second process of each pair joins this many seconds after the first.
STAGGER=${STAGGER:-8}

rm -rf "$OUT"; mkdir -p "$OUT"
BCAST="t13p1n-$$.hang"
PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	pkill -f "[m]oq .*$BCAST" 2>/dev/null || true
	pkill -f "[m]oq-relay.*127.0.0.1:$PORT" 2>/dev/null || true
	pkill -f "[m]pegts-pacer" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== $(date -u) t13-pacer-headtohead $LABEL ==="
# #3912 dropped the git-describe build script, so `--version` no longer names the commit. The
# build under test is the `.sha` sidecar the build script writes, not this string.
"$BIN/moq" --version
[ -f "$BIN.sha" ] && echo "build: $(cat "$BIN.sha")"
"$PACER" --version 2>/dev/null || true
echo "clip=$CLIP rate=$RATE latency=${LATENCY_MS}ms secs=$SECS stagger=${STAGGER}s"

moq_cli_detect "$BIN/moq" "$BIN/moq-relay"
moq_relay_public "127.0.0.1:$PORT" localhost
"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 2

# A subscriber, optionally through the pacer. $1 name, $2 pacer args ("" for the bare exporter).
sub() {
	local name=$1 pacer_args=${2:-}
	local sink="> '$OUT/$name.ts'"
	[ -n "$pacer_args" ] && sink="| '$PACER' - $RATE $pacer_args > '$OUT/$name.ts'"
	setsid bash -c "'$BIN/moq' ${MOQ_DIAL[*]} 'https://127.0.0.1:$PORT/anon' --quic-gso=false \
		--broadcast '$BCAST' export ts ${MOQ_LAT[*]} 3s $sink" 2>"$OUT/$name.err" &
	PIDS+=($!)
}

# Subscribers first: reservation gating publishes the catalog once tracks resolve, so a
# subscriber attaching afterwards can miss it and sit idle forever.
# Both depths are pinned, not just the cushion: two legs measuring their own arrival windows
# would start on different slots and hold different depths, spending skew budget a receiver
# needs. `Config::validate()` rejects the adaptive combination rather than emitting a pair that
# merges badly, so a misconfiguration here voids the arm loudly instead of quietly.
PACER_STREAM="--latency-ms $LATENCY_MS --max-latency-ms $((LATENCY_MS * 4)) --stream-clock"
sub export-a
sub pacer-arrival-a "--latency-ms $LATENCY_MS --max-latency-ms $((LATENCY_MS * 4))"
sub pacer-stream-a "$PACER_STREAM"
sleep 2

# The publisher. `regulate --pcr-synchronous` releases the file at its own PCR rate, so import
# sees the source's real pacing rather than disk speed — the rate measurement depends on it.
setsid bash -c "tsp --realtime -I file '$CLIP' -P regulate --pcr-synchronous --wait-min 5 -O file - \
	| '$BIN/moq' ${MOQ_DIAL[*]} 'https://127.0.0.1:$PORT/anon' --quic-gso=false \
	--broadcast '$BCAST' import ts" >"$OUT/import.log" 2>&1 &
PIDS+=($!)

# The second leg of each pair joins late, on purpose (see the header).
sleep "$STAGGER"
echo "--- second legs joining at +${STAGGER}s ---"
sub export-b
sub pacer-stream-b "$PACER_STREAM"

sleep "$SECS"
echo "--- stopping ---"
# Stop the exporters and let the pacers drain: each sees EOF on stdin, finishes its buffer and
# prints its closing `Stats` to stderr. Killing them instead would lose the counters that are
# half the point of the run, so they are only killed if they outlast the grace.
pkill -f "[m]oq .*$BCAST" 2>/dev/null || true
for _ in $(seq 20); do pgrep -f "[m]pegts-pacer" >/dev/null || break; sleep 1; done
pkill -f "[m]pegts-pacer" 2>/dev/null || true
sleep 1

echo
echo "=== captures ==="
ok=1
for f in "$OUT"/*.ts; do
	n=$(stat -c%s "$f" 2>/dev/null || echo 0)
	printf '  %-22s %12s B  %9s packets\n' "$(basename "$f")" "$n" "$((n / 188))"
	# A lane that silently delivers nothing grades as a confident null, so say so loudly.
	[ "$n" -lt 1000000 ] && { echo "    VOID: under the 1 MB floor — this arm grades nothing"; ok=0; }
done
[ "$ok" = 0 ] && echo "  (at least one arm is void; read no verdict from this run)"

echo
echo "=== pacer stats (the displacement is the exporter's residual, not the pacer's) ==="
for f in "$OUT"/pacer-*.err; do
	echo "--- $(basename "$f" .err)"
	grep -iE 'pcr_position|displacement|overrun|underrun|dropped|late_drop|null_ratio|stall|buffer_high|arrival_lead|output_packets|content_packets' "$f" | tail -20
done
echo
echo "graded with: pcr-residual.py <capture>   and   ts-pair-diff.py <a> <b>"
echo "=== $(date -u) done: $OUT ==="
