#!/usr/bin/env bash
# A transport stream that never repeats, on stdout, for as long as it is read.
#
#   ts-testsrc-live.sh [ignored]      # e.g. SOURCE=ts-testsrc-live.sh f5-soak-side.sh …
#
# Every clip-based source ends or loops. On builds carrying #3798, `moq import ts` exits with *frame
# timestamp is below the live edge* at the first lap of a looped clip and at the first join of
# `ts-continuous-source.py` (T40, T41), so no clip-fed publisher outlives one pass of the clip
# (~600 s for CNNiEMEA2.ts). A live encoder has no lap and no join, which is what a run longer than
# the clip needs. It is not the clip: synthetic picture and tone, one H.264 video and one MP2 audio
# stream, a 1 s GOP with no B-frames. Set the video rate so the relay carries what the clip did.
#
# Knobs: SIZE (1920x1080), FPS (25), VBR (9500k), GOP (25), MUXRATE (11M).
set -euo pipefail

SIZE=${SIZE:-1920x1080}
FPS=${FPS:-25}
VBR=${VBR:-9500k}
GOP=${GOP:-25}
MUXRATE=${MUXRATE:-11M}

# Not exec'd: a named parent lets a reset find the chain by this script's name as well as by
# ffmpeg's arguments.
ffmpeg -hide_banner -loglevel error -re \
	-f lavfi -i "testsrc2=size=${SIZE}:rate=${FPS}" \
	-f lavfi -i "sine=frequency=1000:sample_rate=48000" \
	-c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
	-b:v "$VBR" -maxrate "$VBR" -bufsize "$VBR" -g "$GOP" -keyint_min "$GOP" -bf 0 \
	-c:a mp2 -b:a 192k \
	-f mpegts -muxrate "$MUXRATE" -mpegts_service_id 1 -
