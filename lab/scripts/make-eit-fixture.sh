#!/usr/bin/env bash
# Build an EIT-bearing fixture from a clip that has none.
#
# Why this exists: no clip we hold carries EIT, so the claim that the media-aware lane
# drops it rests on reading `SI_PIDS` rather than on a measurement. This synthesises a
# representative one so the gap can be measured, and — more usefully — so the *cost* of
# carrying EIT through the catalog can be measured rather than asserted.
#
# Three variants, because they answer different questions:
#   pf        EIT p/f actual only. Small, two events, changes at event boundaries.
#             The minimal "does EIT survive the round-trip" fixture. 2 sections, 153 B.
#   full      p/f + schedule actual from the hand-written one-day EPG: table 0x4E plus a
#             single schedule table 0x50. Enough to show schedule survives, and already
#             sparse (7 sections against a last_section_number of 48), but under a day of
#             EPG and ~975 B in total — too small to price anything.
#   sched     p/f + schedule actual from a generated multi-day EPG (make-eit-epg.py),
#             sized to the DVB planning horizon: 8 days across three schedule tables
#             (0x50/0x51/0x52), 69 sections, ~30 kB. This is the variant to use when the
#             question is what SI carriage *costs* rather than whether it works.
#             `EPG_DAYS` (default 8) and `EPG_SERVICES` (default 1) size it.
#
# An EIT schedule sub-table is sparse: it declares a `last_section_number` covering its
# whole four-day range and transmits only the segment-boundary sections that hold events.
# So completeness cannot be decided by counting sections — and note that `tsp -P tables`
# will not print such a sub-table at all for the same reason. Census these fixtures with
# `--all-sections`, or schedule looks absent when it is present.
#
# The EPG is anchored to the source clip's own TDT epoch (see eit-epg.xml), and
# `eitinject` resynchronises its time reference on every TDT/TOT, so the present event is
# genuinely current for a receiver decoding the clip from its start. It also drops events
# already in the past, so an EPG anchored to wall clock injects nothing.
#
# EIT packets are taken from the clip's null stuffing, so the output stays at the source
# mux rate. The script fails if that costs the stream its CBR structure.
#
# Usage: make-eit-fixture.sh [pf|full|sched] [source.ts] [output.ts]

set -euo pipefail

VARIANT="${1:-full}"
SRC="${2:-$HOME/CNNiEMEA2.ts}"
OUT="${3:-$HOME/CNNiEMEA2_eit_${VARIANT}.ts}"
# Must match the service the EPG describes; see eit-epg.xml.
SERVICE_ID="${SERVICE_ID:-1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPG="$HERE/eit-epg.xml"

case "$VARIANT" in
	pf)   EIT_ARGS=(--actual-pf) ;;
	full) EIT_ARGS=(--actual) ;;
	sched)
		EIT_ARGS=(--actual)
		EPG="$(mktemp -t eit-epg-sched).xml"
		python3 "$HERE/make-eit-epg.py" --out "$EPG" \
			--days "${EPG_DAYS:-8}" --services "${EPG_SERVICES:-1}" \
			--first-service-id "$SERVICE_ID"
		;;
	*)    echo "usage: $(basename "$0") [pf|full|sched] [source.ts] [output.ts]" >&2; exit 2 ;;
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
echo "==> EIT sub-tables present on PID 0x0012"
# --all-sections, not --max-tables: an EIT schedule sub-table is sparse, so the section
# demux never completes it and `tables` alone prints nothing for exactly the table this
# fixture exists to carry.
tsp -I file "$OUT" -P tables --pid 0x0012 --all-sections -O drop 2>/dev/null \
	| grep -oE "TID 0x[0-9A-F]+" | sort | uniq -c

echo
echo "==> EIT PID bitrate and structure"
tsp -I file "$OUT" -P eit -O drop 2>&1 | head -30

echo
echo "==> conformance: mux rate, PID list, continuity"
tsp -I file "$OUT" -P analyze --normalized -O drop 2>/dev/null \
	| awk -F: '/^ts:/ { for (i=1;i<=NF;i++) if ($i ~ /^(bitrate|pid-count)=/) printf "%s ", $i; print "" }'
tsp -I file "$OUT" -P continuity -O drop
