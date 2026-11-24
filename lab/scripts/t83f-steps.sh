#!/bin/bash
# T83 Part F (lab/test-83-mixed-plane-pair.md, criterion 14): the hand-off lanes' chains through
# an unflagged source clock step, on a private loopback group.
#
#   t83f-steps.sh capture DIR           120 s of GROUP into DIR/src.ts
#   t83f-steps.sh stim DIR              DIR/stepped.ts: +STEP1_MS at 40 s, STEP2_MS at 80 s (PCR, PTS, DTS)
#   t83f-steps.sh run DIR FILE LABEL    the ma, pt and seg chains on TGROUP, FILE played onto it at
#                                       RATE_IN, video gaps metered at their outputs; DIR/LABEL.txt.
#                                       SILENCE_S=N withholds FILE's N s from 40 s (criterion 15)
#
# Env: GROUP (239.255.0.1:5000), TGROUP (239.255.0.9:5009), RATE_IN (25000000), MA_BIN
#   (~/bin-9757807f), PT_BIN (~/bin-a843d23b), PT_PUBLIC (empty, its relay's grant), PACER
#   (~/pacer-97f3a38/mpegts-pacer), STEP1_MS (16845000), STEP2_MS (-20445000), SEG_ARGS (the
#   packager's options beyond --pdt). Run from a copy of
#   lab/scripts (ma-window.sh, t79-epochseg.py, b8-hls-recv.py and t83f-gaps.py beside it).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GROUP=${GROUP:-239.255.0.1:5000}
TGROUP=${TGROUP:-239.255.0.9:5009}
RATE_IN=${RATE_IN:-25000000}
MA_BIN=${MA_BIN:-$HOME/bin-9757807f}
PT_BIN=${PT_BIN:-$HOME/bin-a843d23b}
PT_PUBLIC=${PT_PUBLIC-}
PACER=${PACER:-$HOME/pacer-97f3a38/mpegts-pacer}
STEP1_MS=${STEP1_MS:-16845000}
STEP2_MS=${STEP2_MS:--20445000}
PKTS40=$((40 * RATE_IN / 8 / 188))

capture() {
	tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216 -P until --seconds 120 \
		-O file "$1/src.ts" 2>/dev/null
	ls -l "$1/src.ts"
}

edit() {
	tsp -I file - -P pcredit --unit millisecond --add-pcr "$1" --add-pts "$1" --add-dts "$1" -O file - 2>/dev/null
}

stim() {
	local d=$1
	{
		head -c $((PKTS40 * 188)) "$d/src.ts"
		tail -c +$((PKTS40 * 188 + 1)) "$d/src.ts" | head -c $((PKTS40 * 188)) | edit "$STEP1_MS"
		tail -c +$((2 * PKTS40 * 188 + 1)) "$d/src.ts" | edit "$STEP2_MS"
	} >"$d/stepped.ts"
	ls -l "$d/stepped.ts"
}

play() {
	tsp -I file "$1" -P regulate --bitrate "$RATE_IN" -O ip "$TGROUP" --local-address 127.0.0.1 2>/dev/null
}

run() {
	local d=$1 file=$2 label=$3 r=$1/$3 pids=() pid name dead=()
	mkdir -p "$r/www/g"
	BIN=$MA_BIN PORT=4497 RUN=$r/ma GROUP=$TGROUP PACER=$PACER bash "$HERE/ma-window.sh" up 5291 >/dev/null 2>&1
	setsid "$PT_BIN/moq-relay" --listen 127.0.0.1:4496 --listen-tls-generate localhost \
		--auth-public "$PT_PUBLIC" --quic-gso=false --log-level warn >"$r/pt-relay.log" 2>&1 &
	pids+=("pt-relay:$!")
	sleep 2
	setsid bash -c "tsp -I ip $TGROUP --local-address 127.0.0.1 --buffer-size 16777216 -O file - 2>/dev/null \
		| '$PT_BIN/moq' --connect-tls-insecure --connect https://127.0.0.1:4496/anon --quic-gso=false \
		--broadcast t83f.hang import ts --passthrough" >"$r/pt-import.log" 2>&1 &
	pids+=("pt-import:$!")
	setsid python3 "$HERE/t79-epochseg.py" "$r/www/g" --group "$TGROUP" --pdt ${SEG_ARGS:-} >"$r/seg-packager.log" 2>&1 &
	pids+=("seg-packager:$!")
	setsid python3 -m http.server 18779 --bind 127.0.0.1 --directory "$r/www" >/dev/null 2>&1 &
	pids+=("seg-http:$!")
	sleep 3
	setsid bash -c "'$PT_BIN/moq' --connect-tls-insecure --connect https://127.0.0.1:4496/anon --quic-gso=false \
		--broadcast t83f.hang export ts --passthrough --delay 2s 2>'$r/pt-export.log' \
		| tsp --realtime --buffer-size-mb 1 --max-input-packets 7 -I file - -O ip 127.0.0.1:5292" &
	pids+=("pt-export:$!")
	setsid bash -c "python3 '$HERE/b8-hls-recv.py' http://127.0.0.1:18779/g/index.m3u8 - --seconds 0 \
		--release-ms 1500 --log '$r/seg-recv.jsonl' \
		| '$PACER' 127.0.0.1:5293 26000000 --stream-clock --sequence-seed 0 --stall-ms 1000 --on-stall mute \
		--stats-interval-ms 10000 --latency-ms 8000 --max-latency-ms 14000 2>'$r/seg-pacer.log'" &
	pids+=("seg-recv:$!")
	python3 "$HERE/t83f-gaps.py" $((160 - ${SILENCE_S:-0})) 5291 5292 5293 >"$r/gaps.txt" &
	local meter=$!
	sleep 1
	echo "player starts $(date -u +%T.%N | cut -c1-12), meter started 1 s before" >"$d/$label.txt"
	if [ -n "${SILENCE_S:-}" ]; then
		head -c $((PKTS40 * 188)) "$file" | play -
		sleep "$SILENCE_S"
		tail -c +$(((PKTS40 + SILENCE_S * RATE_IN / 8 / 188) * 188 + 1)) "$file" | play -
	else
		play "$file"
	fi
	wait "$meter"
	for pid in "${pids[@]}"; do
		name=${pid%%:*}
		pgrep -g "${pid#*:}" >/dev/null || dead+=("$name")
	done
	for name in relay import export; do
		[ -f "$r/ma/$name.pid" ] && ! pgrep -g "$(cat "$r/ma/$name.pid")" >/dev/null && dead+=("ma-$name")
	done
	{
		echo "exited: ${dead[*]:-none}"
		sed 's/^port 5291/ma  (5291)/; s/^port 5292/pt  (5292)/; s/^port 5293/seg (5293)/' "$r/gaps.txt"
	} >>"$d/$label.txt"
	RUN=$r/ma bash "$HERE/ma-window.sh" down
	for pid in "${pids[@]}"; do kill -TERM -- "-${pid#*:}" 2>/dev/null; done
	cat "$d/$label.txt"
}

case ${1:-} in
capture) capture "$2" ;;
stim) stim "$2" ;;
run) run "$2" "$3" "$4" ;;
*) echo "usage: t83f-steps.sh capture DIR | stim DIR | run DIR FILE LABEL" >&2 && exit 2 ;;
esac
