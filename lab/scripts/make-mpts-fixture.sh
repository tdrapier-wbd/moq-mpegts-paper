#!/usr/bin/env bash
# Build a DVB multiplex fixture of N services on top of a single-programme clip.
#
# The SI half of a distribution multiplex, grafted onto a contribution feed's media: the source's
# SDT and NIT are replaced by ones describing N services and an M-transport network, and an EPG
# whose present/following event rolls on a fixed boundary is injected on PID 0x0012.
#
# This exists to price carried SI against service count, for
# [#2882](https://github.com/moq-dev/moq/issues/2882). No capture we hold has more than one
# service, so the scaling question cannot be answered from real content — but a real SPTS carved
# out of a distribution mux does carry its whole multiplex's SDT, NIT and EIT, so a one-programme
# media side with whole-multiplex SI is the shape the lane actually meets, not a contrivance.
#
# SI replaces existing PID content rather than stealing stuffing, so the output stays at the
# source mux rate; the EIT is taken from stuffing, as in make-eit-fixture.sh.
#
# Usage: make-mpts-fixture.sh <source.ts> <out.ts> <services> [transports] [event_seconds] [events]

set -euo pipefail

SRC="${1:?usage: make-mpts-fixture.sh <source.ts> <out.ts> <services> [transports] [event_seconds] [events]}"
OUT="${2:?output path}"
SERVICES="${3:?service count}"
TRANSPORTS="${4:-8}"
STEP="${5:-90}"
EVENTS="${6:-4}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -r "$SRC" ]] || {
	echo "source clip not readable: $SRC" >&2
	exit 1
}

python3 "$HERE/make-mpts-si.py" "$SERVICES" "$TRANSPORTS" "$WORK/mux"
python3 "$HERE/make-mpts-epg.py" "$SERVICES" "$STEP" "$EVENTS" "$WORK/epg.xml"
tstabcomp -c "$WORK/mux.sdt.xml" -o "$WORK/sdt.bin"
tstabcomp -c "$WORK/mux.nit.xml" -o "$WORK/nit.bin"

# --wait-first-batch: the EPG must be loaded before injection starts, or the head of the output
# carries no EIT and a short run sees nothing.
tsp -I file "$SRC" \
	-P inject "$WORK/sdt.bin=2000" --pid 0x0011 --replace \
	-P inject "$WORK/nit.bin=10000" --pid 0x0010 --replace \
	-P eitinject --files "$WORK/epg.xml" --wait-first-batch --actual-pf \
	-O file "$OUT"

echo
echo "==> $OUT: $SERVICES services, ${TRANSPORTS}-transport NIT, p/f rolling every ${STEP}s"
tsp -I file "$OUT" -P analyze --normalized -O drop 2>/dev/null \
	| awk -F: '/^ts:/ { for (i=1;i<=NF;i++) if ($i ~ /^(bitrate|pid-count)=/) printf "%s ", $i; print "" }'
tsp -I file "$OUT" -P continuity -O drop
