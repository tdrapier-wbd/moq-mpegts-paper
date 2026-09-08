#!/usr/bin/env bash
# Inject a partial media-plane failure at the publisher and detect it at the far end of a
# cross-host MoQ lane, with the detector running live rather than grading a capture.
#
#   t27-liveness-inlane.sh <arm> <relay-ip> [at] [for] [total]
#   e.g. t27-liveness-inlane.sh video 34.246.187.61 60 60 180
#
# [T24](../test-24-partial-media-plane-stall.md) established per-PID access-unit liveness as the
# only detector that caught every partial-failure arm, and did so with an offline grader over a
# capture on one host. Two things were therefore left unproven, and both are the ones that decide
# whether the recommendation is usable.
#
# **That the signal survives the lane.** T24 measured the delivered stream, so it knew the outage
# arrived; it did not run a detector across a relay on another machine, through the exporter's PCR
# regeneration and a CBR groomer, and ask whether the *evidence a detector needs* is still there at
# the monitoring point. Access-unit spacing is exactly the kind of fine structure that a
# store-and-forward hop is entitled to rearrange.
#
# **That the detector holds its own threshold in a real lane.** Thresholds here are learned from
# observed spacing, and the delivered stream's spacing is far more variable than a file's. A
# detector whose threshold is set by lane jitter rather than by media cadence is either insensitive
# or false-positive prone, and only a real lane can say which.
#
# The measurement point is deliberately **after the groomer**, because that is where an operator
# monitors and because the exporter's raw output is not a groomed wire: measured directly on
# `moq export ts`, the same content learns thresholds around 2 s where the groomed wire learns 1 s,
# so the placement changes the sensitivity by a factor of two and has to be stated.
set -uo pipefail

ARM=${1:?arm: control|video|audio}
RELAY_IP=${2:?relay ip}
AT=${3:-60}
DUR=${4:-60}
TOTAL=${5:-180}

MOQ=${MOQ:?set MOQ to the moq binary}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
STIM=${STIM:-$HOME/f5/ts-partial-stall.py}
LIVENESS=${LIVENESS:-$HOME/f5/ts-liveness.py}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
# One broadcast name per arm. Sharing a name across back-to-back arms fails: T25 showed the relay
# retains an abandoned session until the QUIC idle timeout, so the next arm's subscriber attaches to
# the previous arm's broadcast and is dropped the moment the new publisher replaces it — which cost
# one run here, with the exporter exiting on `json: dropped`.
BCAST=${BCAST:-t27.$ARM.hang}
PORT=${PORT:-4443}
LATMAX=${LATMAX:-500ms}
GSO=${GSO:-true}
OUT=${OUT:-$HOME/t27}/$ARM

for f in "$MOQ" "$PACER"; do
	[ -x "$f" ] || {
		echo "t27: missing $f" >&2
		exit 1
	}
done
for f in "$STIM" "$LIVENESS"; do
	[ -f "$f" ] || {
		echo "t27: missing $f" >&2
		exit 1
	}
done

rm -rf "$OUT"
mkdir -p "$OUT"

# Every pattern here is scoped to *this* run. An unscoped `pkill -f ts-liveness.py` killed a
# detector belonging to a different experiment on the same host, which broke that experiment's
# subscriber pipe and ended its run — the cleanup has to name the run, not the tool.
cleanup() {
	pkill -f "[-]-broadcast $BCAST" 2>/dev/null || true
	pkill -f "[t]s-partial-stall.py --mode $ARM" 2>/dev/null || true
	pkill -f "[t]s-liveness.py --warmup 5 --learn 20 --jsonl" 2>/dev/null || true
}
trap cleanup EXIT

CONN=(--client-tls-disable-verify --client-connect "https://$RELAY_IP:$PORT/anon"
	"--client-quic-gso=$GSO")

{
	echo "arm=$ARM relay=$RELAY_IP:$PORT inject_at=${AT}s for=${DUR}s total=${TOTAL}s"
	echo "moq=$("$MOQ" --version 2>&1 | head -1) latency_max=$LATMAX client_quic_gso=$GSO"
	echo "measurement_point=after the CBR groomer (P1), which is where an operator monitors"
	echo "started=$(date -u +%FT%T%z)"
} >"$OUT/meta.txt"

echo "t27/$ARM: publishing a $ARM-mode stimulus, detecting at the far end"

# Subscriber first, so the detector is already learning when the outage is injected rather than
# joining mid-fault. Its chain is the operator's chain: exporter, groomer, detector.
(
	"$MOQ" "${CONN[@]}" --broadcast "$BCAST" export ts --latency-max "$LATMAX" 2>"$OUT/export.log" |
		"$PACER" - 11000000 --latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 \
			--on-stall mute 2>"$OUT/pacer.log" |
		python3 "$LIVENESS" --warmup 5 --learn 20 --jsonl >"$OUT/liveness.jsonl" 2>"$OUT/liveness.err"
) &
SUB=$!

sleep 2
(python3 "$STIM" --mode "$ARM" --at "$AT" --for "$DUR" "$CLIP" |
	tsp -I file - -P regulate --pcr-synchronous --wait-min 5 -O file - |
	"$MOQ" "${CONN[@]}" --broadcast "$BCAST" import ts) >"$OUT/publisher.log" 2>&1 &
PUB=$!

sleep 6
kill -0 "$PUB" 2>/dev/null || {
	echo "t27: publisher died — see $OUT/publisher.log" >&2
	exit 1
}
echo "  publisher up; injecting at t=${AT}s in media time for ${DUR}s"

sleep "$TOTAL"
kill "$PUB" 2>/dev/null || true
sleep 3
kill "$SUB" 2>/dev/null || true
pkill -f "[t]s-liveness.py" 2>/dev/null || true
sleep 2

echo "finished=$(date -u +%FT%T%z)" >>"$OUT/meta.txt"
echo "t27/$ARM: events ->"
grep -E '"event": *"(alarm|clear|armed)"' "$OUT/liveness.jsonl" 2>/dev/null || cat "$OUT/liveness.jsonl"
grep -oE "underruns=[0-9]+|stalls=[0-9]+|muted=[0-9]+|resyncs=[0-9]+|dropped=[0-9]+" \
	"$OUT/pacer.log" 2>/dev/null | tr '\n' ' '
echo
