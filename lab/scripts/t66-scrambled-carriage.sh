#!/usr/bin/env bash
# T66 — a scrambled multiplex through the opaque lane, the groomer and a descrambling receiver.
#
#   t66-scrambled-carriage.sh <bin-dir> <pacer> <clip.ts> <out-dir> [seconds]
#
# Builds the stimulus from the clip's first 120 s: a CA_descriptor for BISS-CA's CA_system_id in the
# PMT naming ECM PID 0x200, a new CAT naming EMM PID 0x201, one private section on each, then
# DVB-CISSA on the service with 13 control words in 10 s crypto-periods (sections and words from a
# fixed seed). Grades it (criterion 1), then, on one loopback relay:
#   A  import ts --passthrough -> export ts --passthrough --delay 1s            -> a.ts
#   B  a second such export -> pacer -> UDP -> tsp -I ip                       -> b.ts
#   C  a third, through tsp's descrambler on the same words -> pacer -> UDP    -> c.ts
#   D  the file again into import ts (no passthrough) -> export ts --delay 2s  -> d.ts
#   E  the file again into t65-epochseg-stdin.py                               -> e/
# and grades each arm into grade.txt.
#
# env: PORT (4443), RELAY_TOML (a build tree's demo/relay/localhost.toml), UDP_B (18681),
#      UDP_C (18682), RATE (11000000)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${1:?bin dir with moq and moq-relay}
PACER=${2:?mpegts-pacer binary}
CLIP=${3:?clip}
OUT=${4:?out dir}
SECS=${5:-130}
PORT=${PORT:-4443}
RELAY_TOML=${RELAY_TOML:-$HOME/moq-wt/main-f13283b3/demo/relay/localhost.toml}
UDP_B=${UDP_B:-18681}
UDP_C=${UDP_C:-18682}
RATE=${RATE:-11000000}
MOQ=$BIN/moq
RELAY=$BIN/moq-relay
BP=t66.p.hang
BM=t66.m.hang
PIDS_SCR=(--pid 111 --pid 121 --pid 123 --pid 131)
GRADE="$HERE/t66-grade.py"
ID="$HERE/ts-passthrough-identity.py"
PACE=(--latency-ms 1000 --max-latency-ms 2500 --stall-ms 1000 --on-stall mute)

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$MOQ" "$RELAY"

rm -rf "$OUT"
mkdir -p "$OUT/e"
cd "$OUT" || exit 1
{
	moq_record_build "$MOQ" "$RELAY"
	echo "pacer=$("$PACER" --version 2>&1 | head -1) tsduck=$(tsp --version 2>&1 | head -1)"
	echo "clip=$CLIP secs=$SECS rate=$RATE"
	echo "started=$(date -u +%FT%TZ)"
} | tee meta.txt

python3 - <<'PY'
import random
r = random.Random(66)
for name, tid in (("ecm", 0x80), ("emm", 0x82)):
	payload = r.randbytes(64).hex().upper()
	open(f"{name}.xml", "w").write(
		f'<?xml version="1.0" encoding="UTF-8"?>\n<tsduck>\n  <generic_short_table table_id="0x{tid:02X}" '
		f'private="true">\n    {payload}\n  </generic_short_table>\n</tsduck>\n'
	)
open("cw.txt", "w").write("".join(r.randbytes(16).hex().upper() + "\n" for _ in range(13)))
PY
tstabcomp -o ecm.bin ecm.xml && tstabcomp -o emm.bin emm.xml || exit 1
tsp -I file "$CLIP" -P until --packets 793560 \
	-P pmt --service 1 --add-ca-descriptor 0x2610/0x200 \
	-P cat --create --add-ca-descriptor 0x2610/0x201 \
	-P inject ecm.bin --pid 0x200 --bitrate 16000 \
	-P inject emm.bin --pid 0x201 --bitrate 16000 \
	-O file clear.ts || exit 1
tsp -I file clear.ts -P scrambler 1 --dvb-cissa --subtitles --cw-file cw.txt --cp-duration 10 \
	-O file scr.ts || exit 1
tsp -I file scr.ts -P descrambler "${PIDS_SCR[@]}" --dvb-cissa --cw-file cw.txt -O file descr.ts || exit 1
python3 "$GRADE" control clear.ts scr.ts descr.ts | tee control.txt
grep -q 'control PASS' control.txt || {
	echo "the stimulus is void (criterion 1); nothing else runs" >&2
	exit 1
}

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	pkill -f "[t]sp --realtime.* -I file scr.ts" 2>/dev/null
	pkill -f "[t]sp -I ip --local-address 127.0.0.1 ($UDP_B|$UDP_C)" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	true
}
trap cleanup EXIT

cp "$RELAY_TOML" relay.toml
"$RELAY" relay.toml "${RELAY_GSO[@]}" >relay.log 2>&1 &
RELAY_PID=$!
PIDS+=("$RELAY_PID")
for _ in $(seq 1 40); do
	FP="$(curl -s "http://localhost:$PORT/certificate.sha256" 2>/dev/null || true)"
	[ -n "$FP" ] && break
	sleep 0.25
done
if [ -z "${FP:-}" ] || ! kill -0 "$RELAY_PID" 2>/dev/null; then
	echo "relay did not come up, or another holds :$PORT; see relay.log" >&2
	exit 1
fi
C=("${MOQ_FP[@]}" "$FP" "${MOQ_DIAL[1]}" "https://localhost:$PORT" "${MOQ_GSO[@]}")

tsp -I ip --local-address 127.0.0.1 "$UDP_B" -O file b.ts 2>b-cap.log &
PIDS+=($!)
tsp -I ip --local-address 127.0.0.1 "$UDP_C" -O file c.ts 2>c-cap.log &
PIDS+=($!)
"$MOQ" "${C[@]}" --broadcast "$BP" export ts --passthrough --delay 1s >a.ts 2>a.log &
PIDS+=($!)
("$MOQ" "${C[@]}" --broadcast "$BP" export ts --passthrough --delay 1s 2>b.log |
	"$PACER" "127.0.0.1:$UDP_B" "$RATE" "${PACE[@]}" 2>b-pacer.log) &
PIDS+=($!)
("$MOQ" "${C[@]}" --broadcast "$BP" export ts --passthrough --delay 1s 2>c.log |
	tsp --max-input-packets 7 --max-flushed-packets 7 \
		-P descrambler "${PIDS_SCR[@]}" --dvb-cissa --cw-file cw.txt 2>c-descr.log |
	"$PACER" "127.0.0.1:$UDP_C" "$RATE" "${PACE[@]}" 2>c-pacer.log) &
PIDS+=($!)
"$MOQ" "${C[@]}" --broadcast "$BM" export ts --delay 2s >d.ts 2>d.log &
PIDS+=($!)
sleep 1
(tsp --realtime -I file scr.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
	"$MOQ" "${C[@]}" --broadcast "$BP" import ts --passthrough) >import-p.log 2>&1 &
PIDS+=($!)
(tsp --realtime -I file scr.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
	"$MOQ" "${C[@]}" --broadcast "$BM" import ts) >import-m.log 2>&1 &
PIDS+=($!)
(tsp --realtime --max-flushed-packets 7 -I file scr.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
	python3 "$HERE/t65-epochseg-stdin.py" e --pdt) >e.log 2>&1 &
PIDS+=($!)
sleep "$SECS"
cleanup
trap - EXIT
echo "finished=$(date -u +%FT%TZ)" | tee -a meta.txt

ffmpeg_errors() {
	ffmpeg -hide_banner -nostats -v error -i "$1" -map 0:v -map 0:a -f null - 2>&1 |
		sed -E 's/ @ 0x[0-9a-f]+//' | sort | uniq -c | sort -rn
}
{
	echo "--- criterion 1, the control"
	cat control.txt
	echo "--- A: identity against the scrambled fixture"
	python3 "$ID" scr.ts a.ts --span-out a-span.ts --json a-id.json
	python3 "$GRADE" ca a-span.ts a.ts
	python3 "$GRADE" checks a.ts
	echo "--- B: groomed identity against the scrambled fixture"
	python3 "$ID" scr.ts b.ts --groomed --json b-id.json
	python3 "$GRADE" checks b.ts
	echo "--- C: groomed identity against the offline-descrambled control"
	python3 "$ID" descr.ts c.ts --groomed --json c-id.json
	python3 "$GRADE" checks c.ts
	python3 "$GRADE" span descr.ts c.ts c-clear-span.ts --write clear.ts
	echo "ffmpeg on c.ts:"
	ffmpeg_errors c.ts | tee c-ffmpeg.txt
	echo "ffmpeg on the clear fixture over c.ts's span:"
	ffmpeg_errors c-clear-span.ts | tee c-clear-ffmpeg.txt
	echo "--- D: the media-aware lane"
	sed 's/\x1b\[[0-9;]*m//g' import-m.log | grep -iE 'error|warn|track|catalog' | head -12
	sed 's/\x1b\[[0-9;]*m//g' d.log | grep -iE 'error|warn' | head -6
	ls -l d.ts
	tsp -I file d.ts -P analyze --normalized -O drop 2>/dev/null | grep '^pid:' |
		sed -E 's/^pid:pid=([0-9]+):.*:packets=([0-9]+):.*scrambled=([0-9]+).*/pid \1: \2 packets, \3 scrambled/'
	echo "ffmpeg on d.ts:"
	ffmpeg_errors d.ts | head -8
	echo "--- E: the segmenter"
	find e -type f | sort | head -20
	sed 's/\x1b\[[0-9;]*m//g' e.log | tail -12
} 2>&1 | tee grade.txt
