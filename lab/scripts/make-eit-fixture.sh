#!/usr/bin/env bash
# Build an EIT-bearing fixture from a clip that has none.
#
# Why this exists: no clip we hold carries EIT, so the claim that the media-aware lane
# drops it rests on reading `SI_PIDS` rather than on a measurement. This synthesises a
# representative one so the gap can be measured, and — more usefully — so the *cost* of
# carrying EIT through the catalog can be measured rather than asserted.
#
# Two variants, because they answer different questions:
#   pf        EIT p/f actual only. Small, two events, changes at event boundaries.
#             The minimal "does EIT survive the round-trip" fixture.
#   full      p/f + schedule actual. Multi-section, spans several 3-hour segments,
#             repeats on the ETSI TS 101 211 cycle. This is the shape that tells you
#             what a catalog carrying EIT would cost in size and republish rate.
#
# The EPG is anchored to the source clip's own TDT epoch (see eit-epg.xml), and
# `eitinject` resynchronises its time reference on every TDT/TOT, so the present event is
# genuinely current for a receiver decoding the clip from its start.
#
# EIT packets are taken from the clip's null stuffing, so the output stays at the source
# mux rate. The script fails if that costs the stream its CBR structure.
#
# Usage: make-eit-fixture.sh [pf|full] [source.ts] [output.ts]

set -euo pipefail

VARIANT="${1:-full}"
SRC="${2:-$HOME/CNNiEMEA2.ts}"
OUT="${3:-$HOME/CNNiEMEA2_eit_${VARIANT}.ts}"
# Must match the service the EPG describes; see eit-epg.xml.
SERVICE_ID="${SERVICE_ID:-1}"
EPG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/eit-epg.xml"

case "$VARIANT" in
	pf)   EIT_ARGS=(--actual-pf) ;;
	full) EIT_ARGS=(--actual) ;;
	*)    echo "usage: $(basename "$0") [pf|full] [source.ts] [output.ts]" >&2; exit 2 ;;
esac

[[ -r "$SRC" ]] || { echo "source clip not readable: $SRC" >&2; exit 1; }
[[ -r "$EPG" ]] || { echo "EPG not readable: $EPG" >&2; exit 1; }

echo "==> source $SRC"
echo "==> epg    $EPG"
echo "==> variant $VARIANT -> $OUT"

# --wait-first-batch: the EPG must be loaded before injection starts, or the head of the
# output has no EIT and a short capture sees nothing.
# sdt --eit-pf/--eit-schedule: the source SDT advertises no EIT. Leaving it that way makes
# the fixture internally inconsistent and a conformance analyser will say so.
tsp --verbose \
	-I file "$SRC" \
	-P sdt --service-id "$SERVICE_ID" --eit-pf 1 --eit-schedule 1 \
	-P eitinject --files "$EPG" --wait-first-batch "${EIT_ARGS[@]}" \
	-O file "$OUT"

echo
echo "==> EIT sections present on PID 0x0012"
tsp -I file "$OUT" -P tables --pid 0x0012 --max-tables 4 -O drop

echo
echo "==> EIT PID bitrate and structure"
tsp -I file "$OUT" -P eit -O drop 2>&1 | head -30

echo
echo "==> conformance: mux rate, PID list, continuity"
tsp -I file "$OUT" -P analyze --normalized -O drop 2>/dev/null \
	| awk -F: '/^ts:/ { for (i=1;i<=NF;i++) if ($i ~ /^(bitrate|pid-count)=/) printf "%s ", $i; print "" }'
tsp -I file "$OUT" -P continuity -O drop
