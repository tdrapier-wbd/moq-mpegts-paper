#!/usr/bin/env bash
#
# T19: two synthetic CBR contribution sources that differ only in burst profile.
#
#   t19-make-burst-sources.sh <out-dir> [seconds]
#
# The question they exist to answer is whether the downstream groomer's buffering
# requirement is a property of the lane or a property of the content. Answering it
# needs sources whose *mean* rate is identical and whose *instantaneous* rate is
# not, because it is the peak that the media-aware export delivers as one burst.
#
# So both are 1080p25, both encode video at exactly 9.4 Mb/s CBR into an 11 Mb/s
# mux with a 20 ms PCR, and everything that could move the mean is held equal.
# What differs is the peak-to-mean ratio, controlled by three knobs pushed the
# same way:
#
#   moderate   0.5 s GOP, no B-frames, a 100 ms VBV, and smooth low-detail
#              content. A tight VBV forces the rate control to spend about the
#              same number of bits on every picture, so the I-frames are barely
#              larger than the P-frames.
#   high       2 s GOP, 3 B-frames, a 3 s VBV, and static high-entropy noise.
#              Noise is incompressible intra and free inter, so an I-frame costs
#              a GOP's worth of bits and the P-frames that follow cost almost
#              nothing. This is the pathological case for a lane that carries
#              coded frames rather than a mux schedule.
#
# Both get an MP2 audio track, so the media-aware export demuxes more than one
# elementary stream, as a real contribution feed does.
set -euo pipefail

OUT=${1:?output directory}
SECS=${2:-120}
mkdir -p "$OUT"

VRATE=9400k
MUXRATE=11000000
# `nal-hrd=cbr` is not optional here. Without it x264 treats `-minrate` as advice
# and lets easy content fall to whatever it compresses to: the low-detail arm came
# out at 0.53 Mb/s against a 9.4 Mb/s target, which would have made the comparison
# a rate comparison rather than a burst one. With it the encoder pads to the rate,
# so both arms carry the same number of bits per second and differ only in how
# unevenly those bits are spread across the pictures.
COMMON=(
	-c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p
	-x264-params "nal-hrd=cbr:force-cfr=1"
	-b:v "$VRATE" -minrate "$VRATE" -maxrate "$VRATE"
	-c:a mp2 -b:a 192k -ar 48000 -ac 2
	-muxrate "$MUXRATE" -pcr_period 20 -pat_period 0.1 -sdt_period 0.5
	-mpegts_service_id 1 -mpegts_pmt_start_pid 0x100 -mpegts_start_pid 0x111
	-f mpegts -y
)

echo "==> moderate-burst: 0.5 s GOP, no B-frames, 100 ms VBV, low-detail content"
ffmpeg -hide_banner -loglevel error \
	-f lavfi -i "smptehdbars=size=1920x1080:rate=25:duration=$SECS" \
	-f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=$SECS" \
	-vf "hue=H=2*PI*t/20" \
	-g 12 -keyint_min 12 -sc_threshold 0 -bf 0 -bufsize 940k \
	"${COMMON[@]}" "$OUT/burst-moderate.ts"

echo "==> high-burst: 2 s GOP, 3 B-frames, 3 s VBV, static high-entropy content"
# A still frame of noise: incompressible intra, nothing to predict inter. The
# `loop` filter re-emits one generated frame so every GOP codes the same picture
# and the peak is reproducible rather than a property of the noise seed drift.
ffmpeg -hide_banner -loglevel error \
	-f lavfi -i "nullsrc=size=1920x1080:rate=25,noise=alls=100:allf=t+u:all_seed=1,loop=loop=-1:size=1:start=0,trim=duration=$SECS,setpts=N/25/TB" \
	-f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=$SECS" \
	-g 50 -keyint_min 50 -sc_threshold 0 -bf 3 -bufsize 28200k \
	"${COMMON[@]}" "$OUT/burst-high.ts"

for f in "$OUT/burst-moderate.ts" "$OUT/burst-high.ts"; do
	echo
	echo "=== $(basename "$f") ==="
	echo "  bytes: $(wc -c <"$f")"
	tsp -I file "$f" -P analyze --normalized -O drop 2>/dev/null |
		grep '^ts:' | tr ':' '\n' | grep -E '^(packets|bitrate|pcrbitrate|services)=' | sed 's/^/  /'
	echo "  continuity errors: $(tsp -I file "$f" -P continuity -O drop 2>&1 | grep -c 'TS:')"
	tsp -I file "$f" -P pcrextract --pcr --csv -o "${f%.ts}-pcr.csv" -O drop >/dev/null 2>&1
	awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;n++;if(d>m)m=d;if(d>40)o++}p=c}
		END{printf "  reference PCR: n=%d >40ms=%d worst=%.1f ms\n",n,o,m}' "${f%.ts}-pcr.csv"
	echo -n "  reference PCR accuracy: "
	tsp -I file "$f" -P pcrverify --absolute --jitter-max 13 --bitrate "$MUXRATE" -O drop 2>&1 | tail -1
	# The figure the whole comparison turns on: how many transport packets the
	# largest coded picture occupies, and so how long a burst the media-aware
	# export hands the groomer in one go.
	python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t19-frame-burst.py" "$f" | sed 's/^/  /'
done
