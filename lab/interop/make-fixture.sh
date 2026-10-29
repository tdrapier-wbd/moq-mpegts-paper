#!/usr/bin/env bash
# Generate the synthetic MPEG-TS fixture used by the media-level interop tests.
#
# Synthetic and generated rather than committed: no rights encumbrance, no large binary in the
# repo, and the structure is pinned here in one place where a reviewer can see it. Intended to run
# at container build time.
#
# The fixture is deliberately boring: constant bitrate, fixed GOP, closed GOP, no B-pyramid, one
# video and one audio elementary stream on fixed PIDs. Every property a test asserts should be a
# property this script sets explicitly.
set -euo pipefail

OUT=${1:-fixture.ts}
DURATION=${DURATION:-20}
WIDTH=${WIDTH:-640}
HEIGHT=${HEIGHT:-360}
FPS=${FPS:-25}
GOP=${GOP:-$FPS}              # 1 s GOP => a random access point every second
VBPS=${VBPS:-1500k}
ABPS=${ABPS:-128k}
MUXRATE=${MUXRATE:-2000000}   # CBR: makes packet count a function of duration
SERVICE_ID=${SERVICE_ID:-1}
PMT_PID=${PMT_PID:-0x1000}
START_PID=${START_PID:-0x0100}

command -v ffmpeg >/dev/null || { echo "make-fixture: ffmpeg not found" >&2; exit 1; }

# -flags +bitexact and -fflags +bitexact keep encoder version strings and other build-dependent
# metadata out of the output, so the same ffmpeg build reproduces the same bytes.
ffmpeg -nostdin -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=${DURATION}" \
  -flags +bitexact -fflags +bitexact \
  -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
    -g "$GOP" -keyint_min "$GOP" -sc_threshold 0 -bf 0 \
    -b:v "$VBPS" -minrate "$VBPS" -maxrate "$VBPS" -bufsize "$VBPS" \
  -c:a aac -b:a "$ABPS" -ar 48000 -ac 2 \
  -muxrate "$MUXRATE" -pcr_period 20 \
  -mpegts_service_id "$SERVICE_ID" \
  -mpegts_pmt_start_pid "$PMT_PID" \
  -mpegts_start_pid "$START_PID" \
  -f mpegts "$OUT"

bytes=$(wc -c <"$OUT" | tr -d ' ')
if [ $((bytes % 188)) -ne 0 ]; then
  echo "make-fixture: $OUT is not a whole number of 188-byte TS packets" >&2
  exit 1
fi

# A fixture that does not pass the oracle we are about to apply to received data is not a fixture.
if command -v tsp >/dev/null; then
  if ! cc=$(tsp -I file "$OUT" -P continuity -O drop 2>&1) || [ -n "$cc" ]; then
    echo "make-fixture: generated fixture has continuity errors:" >&2
    echo "$cc" >&2
    exit 1
  fi
fi

echo "make-fixture: $OUT  ${bytes} bytes  $((bytes / 188)) packets  ${DURATION}s @ ${MUXRATE}bps"
