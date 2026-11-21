#!/usr/bin/env bash
# Generate every input of the T86 kit, synthetic, so nothing recorded or rights-encumbered is needed.
# usage: make-fixtures.sh <dir>
# Needs ffmpeg (libx264), TSDuck and Python 3. About five minutes on a laptop; ~2.5 GB.
#
#   base.ts         120 s, the shape of a 10 Mb/s contribution: 1080p25 H.264 8.3 Mb/s CBR, B-frames,
#                   1.2 s GOP, MP2 (PID 121) and AC-3 (123) beside the video (111), PMT 100, NIT,
#                   SDT and a TDT, muxed at 9,945,951 b/s, its clock starting near 25,630 s
#   s-A.ts … s-F.ts T23's PCR events on base.ts, 45 s in: A back 1 s, B back 600 s, C forward 30 s
#                   (flagged), D the 33-bit rollover, E an encoder restart to zero, F the control
#   switch-back.ts, switch-forward.ts
#                   T64's unflagged encoder switch of the whole multiplex, 30 s into 60 s at 6 Mb/s
#   loop.ts         base.ts's first 30 s, five times over: four unflagged wraps
#   mpts3.ts, mpts3-cc.ts
#                   60 s of three programmes on independent clocks (base.ts; video only, 2 Mb/s;
#                   video and audio, VBR), and the same on one clock
#   live.ts         120 s at 25 Mb/s, 1080p25 H.264 22 Mb/s, the audio in long, unaligned PES
#   live-splice.ts  T64's switch back at live.ts's rates: an unflagged splice to a second encode
#                   16,844.5 s behind, 30 s in
# Each fixture is checked (continuity events, PCR accuracy on TSDuck's pcrverify, and its timestamps'
# drift against its PCR, which flags a programme its mux rate cannot carry) and hashed into
# fixtures.sha256. Two runs of different ffmpeg builds need not give the same bytes; the hashes
# name what a run used.
set -euo pipefail
OUT=${1:?usage: make-fixtures.sh <dir>}
KIT=$(cd "$(dirname "$0")" && pwd)
LAB=$(cd "$KIT/../../scripts" && pwd)
for t in ffmpeg tsp python3; do command -v "$t" >/dev/null || {
	echo "make-fixtures: $t not found" >&2
	exit 1
}; done
mkdir -p "$OUT" && cd "$OUT"

# enc <out> <secs> <video b/s> <mux b/s> <pes payload bytes> [extra ffmpeg output options]
enc() {
	local out=$1 secs=$2 vrate=$3 mux=$4 pes=$5
	shift 5
	ffmpeg -nostdin -hide_banner -loglevel error -y \
		-t "$secs" -f lavfi -i "testsrc2=size=1920x1080:rate=25,noise=alls=8:allf=t" \
		-t "$secs" -f lavfi -i "sine=frequency=1000:sample_rate=48000" \
		-t "$secs" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
		-map 0:v -map 1:a -map 2:a \
		-c:v libx264 -preset veryfast -profile:v high -pix_fmt yuv420p -threads 1 \
		-g 30 -keyint_min 30 -sc_threshold 0 -bf 3 \
		-b:v "$vrate" -maxrate "$vrate" -bufsize "$vrate" -x264-params nal-hrd=cbr \
		-c:a:0 mp2 -b:a:0 192k -c:a:1 ac3 -b:a:1 192k \
		-streamid 0:111 -streamid 1:121 -streamid 2:123 \
		-f mpegts -muxrate "$mux" -pcr_period 20 -pes_payload_size "$pes" \
		-mpegts_flags +nit -mpegts_service_id 1 -mpegts_pmt_start_pid 100 \
		-metadata service_provider=synthetic -metadata service_name=t86 "$@" "$out"
}

echo "base.ts"
enc base0.ts 120 8300000 9945951 0 -output_ts_offset 25630
python3 "$KIT/ts-add-tdt.py" base0.ts base.ts && rm base0.ts

for arm in A B C D E F; do
	echo "s-$arm.ts"
	python3 "$LAB/t23-pcr-stimuli.py" base.ts "s-$arm.ts" --arm "$arm" --at-seconds 45 >/dev/null
done

for dir in back forward; do
	echo "switch-$dir.ts"
	python3 "$LAB/t64-switch.py" "switch-$dir.ts" "$dir" >/dev/null
done

echo "loop.ts"
# by packets: without pacing, `until --seconds` does not stop on a file
tsp -I file base.ts -P until --packets $((9945951 * 30 / 8 / 188)) -O file cut30.ts 2>/dev/null
cat cut30.ts cut30.ts cut30.ts cut30.ts cut30.ts >loop.ts && rm cut30.ts

echo "mpts3.ts, mpts3-cc.ts"
ffmpeg -nostdin -hide_banner -loglevel error -y -t 120 -f lavfi -i "testsrc2=size=1280x720:rate=25" \
	-c:v libx264 -preset veryfast -pix_fmt yuv420p -threads 1 -g 50 -keyint_min 50 -sc_threshold 0 -bf 0 \
	-b:v 1800000 -maxrate 1800000 -bufsize 1800000 -x264-params nal-hrd=cbr \
	-f mpegts -muxrate 2000000 -pcr_period 20 p2.ts
ffmpeg -nostdin -hide_banner -loglevel error -y -t 120 -f lavfi -i "testsrc2=size=960x540:rate=25" \
	-t 120 -f lavfi -i "sine=frequency=660:sample_rate=48000" \
	-c:v libx264 -preset veryfast -pix_fmt yuv420p -threads 1 -b:v 600k -maxrate 700k -bufsize 1400k -g 50 -bf 2 \
	-c:a aac -b:a 96k -f mpegts p3.ts
P1=base.ts P2=p2.ts P3=p3.ts bash "$LAB/make-real-mpts.sh" mpts3.ts 60 >mpts3.log 2>&1
# one clock: programmes 2 and 3 re-timed onto programme 1's. Its clock reads 25,636.6 s at the
# fixture's first packet, after the lead-in, where unshifted the other two read 0.7 and 1.9 s.
P1=base.ts P2=p2.ts P3=p3.ts P2_OFFSET=25635.9 P3_OFFSET=25634.7 \
	bash "$LAB/make-real-mpts.sh" mpts3-cc.ts 60 >mpts3-cc.log 2>&1
rm p2.ts p3.ts

echo "live.ts"
enc live.ts 120 22000000 25000000 2930

echo "live-splice.ts"
SIZE=1920x1080 VRATE=22000000 MUXRATE=25000000 python3 "$LAB/t64-switch.py" live-splice.ts back >/dev/null

echo
printf '%-18s %8s %6s %9s %s\n' fixture seconds cc 'lead ppm' pcrverify
for f in base.ts s-?.ts switch-*.ts loop.ts mpts3.ts mpts3-cc.ts live.ts live-splice.ts; do
	cc=$(tsp -I file "$f" -P continuity -O drop 2>&1 | grep -c 'missing\|discontinuity' || true)
	pv=$(tsp -I file "$f" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 | tail -1 | sed 's/.*pcrverify: //')
	secs=$(tsp -I file "$f" -P analyze --normalized -O drop 2>/dev/null | sed -n 's/^ts:.*:duration=\([0-9]*\):.*/\1/p' | head -1)
	lead=$(python3 "$KIT/ts-dts-lead.py" "$f" | sed -n 's/^worst \([0-9]*\) ppm/\1/p')
	[ "$lead" -gt 10000 ] && lead="$lead BAD"
	printf '%-18s %8s %6s %9s %s\n' "$f" "${secs:-?}" "$cc" "$lead" "$pv"
done
shasum -a 256 base.ts s-?.ts switch-*.ts loop.ts mpts3.ts mpts3-cc.ts live.ts live-splice.ts >fixtures.sha256
echo "hashes in $OUT/fixtures.sha256"
