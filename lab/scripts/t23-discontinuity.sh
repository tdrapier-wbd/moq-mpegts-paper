#!/usr/bin/env bash
# T23 — run one deterministic PCR-timeline stimulus through the whole media-aware lane and
# capture the timeline at all three points it can be read.
#
#   t23-discontinuity.sh <moq> <moq-relay> <relay.toml> <stimulus.ts> <out-dir> [seconds] [bps]
#
# T21 found the exporter's clock stopping at a source discontinuity, but its only stimulus
# was `tsp --infinite` looping a clip, which is one event of one class arriving by accident.
# That cannot say which discontinuities recover, and a maintainer could fairly read it as an
# artefact of the looper. This feeds a stimulus whose event is placed on purpose, one per
# run, and reads the same quantity at the source, after the round trip, and after grooming.
#
# Deliberately NOT `--infinite`. The loop wrap is itself a discontinuity, so looping would
# put a second, uncontrolled event of the very class under test into every arm, including
# the control. The clip is played once and the window is sized to fit inside it.
set -uo pipefail

MOQ=${1:?moq binary}
RELAY=${2:?moq-relay binary}
TOML=${3:?relay toml}
SRC=${4:?stimulus .ts}
OUT=${5:?output dir}
SECS=${6:-105}
BPS=${7:-4000000}

BCAST=${BCAST:-t23.disc.hang}
MOQLAT=${MOQLAT:-3s}
PACER=${PACER:?set PACER to the mpegts-pacer binary}
# Extra groomer flags, for the arm that sweeps the hard cap against the recovery burst.
read -r -a PACER_ARGS <<<"${PACER_ARGS:-}"

mkdir -p "$OUT"

set -m
PIDS=()
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
	done
	sleep 0.5
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -KILL -- "-$p" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

cp "$TOML" "$OUT/relay.toml"
(cd "$OUT" && exec "$RELAY" relay.toml --server-quic-gso=false) >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
PIDS+=("$RELAY_PID")

FP=""
for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[ -n "$FP" ] && break
	sleep 0.25
done
[ -n "$FP" ] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	exit 1
}
kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "our relay exited but :4443 answered: another relay holds the port." >&2
	exit 1
}

C=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)

# Subscriber first (reservation gating), and the export is teed rather than captured so the
# groomer sees the live arrival timing. Writing it to a file and pacing the file afterwards
# would flatten exactly the arrival jitter the groomer exists to absorb.
(timeout "$((SECS + 5))" "$MOQ" "${C[@]}" --broadcast "$BCAST" export ts \
	--latency-max "$MOQLAT" 2>"$OUT/export.log" |
	tee "$OUT/export.ts" |
	"$PACER" - "$BPS" --stats-interval-ms 1000 ${PACER_ARGS+"${PACER_ARGS[@]}"} \
		2>"$OUT/pacer.log" >"$OUT/paced.ts") &
SUB=$!
PIDS+=("$SUB")
sleep 2

(tsp --realtime -I file "$SRC" \
	-P regulate --pcr-synchronous --wait-min 5 -O file - |
	tee "$OUT/source.ts" |
	"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
PUB=$!
PIDS+=("$PUB")

sleep 3
kill -0 "$PUB" 2>/dev/null || {
	echo "publisher exited early:" >&2
	cat "$OUT/import.log" >&2
	exit 1
}

echo "==> $(basename "$OUT"): ${SECS}s, stimulus $(basename "$SRC")"
wait "$SUB" 2>/dev/null
sleep 1

for f in source.ts export.ts paced.ts; do
	[ -s "$OUT/$f" ] || echo "WARNING: $OUT/$f is empty" >&2
done
printf 'source %d pkts, export %d pkts, paced %d pkts\n' \
	"$(($(wc -c <"$OUT/source.ts") / 188))" \
	"$(($(wc -c <"$OUT/export.ts") / 188))" \
	"$(($(wc -c <"$OUT/paced.ts") / 188))"
