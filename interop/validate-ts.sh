#!/usr/bin/env bash
# The validation oracle for media-level interop: decide whether a received MPEG-TS is intact,
# using only the received bytes plus (optionally) the fixture that was sent.
#
# The point of using MPEG-TS as the fixture container is that most of this needs no reference at
# all. Continuity counters make loss, duplication and reordering self-detecting, and PSI/SI makes
# the structure checkable. That removes the "capture frames from a player" problem.
#
# Emits one machine-parseable line per check:
#     CHECK <name> <pass|fail|info> <detail>
# Exit 0 if every hard check passed, 1 otherwise.
set -uo pipefail

RECEIVED=""
REFERENCE=""
REQUIRE_IDENTICAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --reference) REFERENCE=$2; shift 2 ;;
    --require-identical) REQUIRE_IDENTICAL=1; shift ;;
    -*) echo "validate-ts: unknown option $1" >&2; exit 2 ;;
    *) RECEIVED=$1; shift ;;
  esac
done

[ -n "$RECEIVED" ] || { echo "usage: validate-ts.sh <received.ts> [--reference <fixture.ts>] [--require-identical]" >&2; exit 2; }
command -v tsp >/dev/null || { echo "validate-ts: tsp (TSDuck) not found" >&2; exit 2; }

failed=0
check() { # name status detail
  echo "CHECK $1 $2 $3"
  [ "$2" = fail ] && failed=1
  return 0
}

# --- 1. the file is a transport stream at all ---------------------------------------------------
if [ ! -s "$RECEIVED" ]; then
  check received-nonempty fail "no data received"
  echo "RESULT fail"
  exit 1
fi
bytes=$(wc -c <"$RECEIVED" | tr -d ' ')
check received-nonempty pass "${bytes}bytes"

if [ $((bytes % 188)) -ne 0 ]; then
  check packet-alignment fail "${bytes} is not a multiple of 188"
else
  check packet-alignment pass "$((bytes / 188))packets"
fi

analysis=$(tsp -I file "$RECEIVED" -P analyze --normalized -O drop 2>/dev/null)
if [ -z "$analysis" ]; then
  check analysable fail "TSDuck could not analyse the received data"
  echo "RESULT fail"
  exit 1
fi

field() { # <line-prefix> <key>  -> value
  echo "$analysis" | grep "^$1" | head -1 | tr ':' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

# --- 2. no sync loss or transport errors --------------------------------------------------------
invalidsyncs=$(field "ts:" invalidsyncs)
transporterrors=$(field "ts:" transporterrors)
[ "${invalidsyncs:-0}" = 0 ] \
  && check sync-bytes pass "0 invalid sync bytes" \
  || check sync-bytes fail "${invalidsyncs} invalid sync bytes"
[ "${transporterrors:-0}" = 0 ] \
  && check transport-errors pass "0 TEI flags set" \
  || check transport-errors fail "${transporterrors} packets with TEI set"

# --- 3. continuity: the reason TS is a good fixture ---------------------------------------------
# Silent output means every PID's continuity counter advanced by exactly one, with no duplicates
# and no reordering. No reference stream, no decoder, no player required.
cc=$(tsp -I file "$RECEIVED" -P continuity -O drop 2>&1)
if [ -z "$cc" ]; then
  check continuity pass "0 continuity errors"
else
  check continuity fail "$(echo "$cc" | wc -l | tr -d ' ')discontinuities"
  echo "$cc" | head -5 | sed 's/^/# /'
fi

# --- 4. PSI/SI survived --------------------------------------------------------------------------
echo "$analysis" | grep -q "^table:pid=0:tid=0:" \
  && check pat-present pass "PAT on PID 0" \
  || check pat-present fail "no PAT"
pmtpids=$(echo "$analysis" | grep -c ":pmt:")
[ "$pmtpids" -ge 1 ] \
  && check pmt-present pass "${pmtpids}PMT" \
  || check pmt-present fail "no PMT"

services=$(field "ts:" services)
[ "${services:-0}" -ge 1 ] \
  && check services pass "${services}service(s)" \
  || check services fail "no services"

# --- 5. elementary streams --------------------------------------------------------------------
nvideo=$(echo "$analysis" | grep '^pid:' | grep -c ':video:')
naudio=$(echo "$analysis" | grep '^pid:' | grep -c ':audio:')
[ "$nvideo" -ge 1 ] && check video-stream pass "${nvideo}video PID(s)" \
                    || check video-stream fail "no video PID"
[ "$naudio" -ge 1 ] && check audio-stream pass "${naudio}audio PID(s)" \
                    || check audio-stream fail "no audio PID"

# --- 6. comparisons against the fixture that was sent -------------------------------------------
if [ -n "$REFERENCE" ] && [ -s "$REFERENCE" ]; then
  ref=$(tsp -I file "$REFERENCE" -P analyze --normalized -O drop 2>/dev/null)
  rvideo=$(echo "$ref" | grep '^pid:' | grep -c ':video:')
  raudio=$(echo "$ref" | grep '^pid:' | grep -c ':audio:')
  rservices=$(echo "$ref" | grep "^ts:" | head -1 | tr ':' '\n' | grep '^services=' | cut -d= -f2)

  [ "$nvideo" = "$rvideo" ] && [ "$naudio" = "$raudio" ] \
    && check stream-inventory pass "video=${nvideo} audio=${naudio} match source" \
    || check stream-inventory fail "video=${nvideo}/${rvideo} audio=${naudio}/${raudio} differ from source"
  [ "${services:-0}" = "${rservices:-0}" ] \
    && check service-count pass "${services} matches source" \
    || check service-count fail "${services} vs ${rservices} in source"

  # Byte-identity is the transparent-carriage property. A media-aware pipeline demuxes and remuxes,
  # so it is expected to differ; report it either way and only fail when the caller asked for it.
  if cmp -s "$RECEIVED" "$REFERENCE"; then
    check byte-identical pass "received is byte-identical to source"
  elif [ "$REQUIRE_IDENTICAL" = 1 ]; then
    check byte-identical fail "received differs from source"
  else
    rbytes=$(wc -c <"$REFERENCE" | tr -d ' ')
    check byte-identical info "differs from source (${bytes} vs ${rbytes} bytes) - expected for a media-aware pipeline"
  fi
fi

[ "$failed" = 0 ] && echo "RESULT pass" || echo "RESULT fail"
exit "$failed"
