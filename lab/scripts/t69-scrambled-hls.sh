#!/usr/bin/env bash
# T69 part S — a scrambled multiplex through `tsp -O hls`, the receiver, and a descrambler after it.
#
#   t69-scrambled-hls.sh <pacer> <clip.ts> <out-dir> [seconds=130]
#
# Rebuilds T66's stimulus by its recipe (seed 66: BISS-CA's CA_system_id in the PMT naming ECM PID
# 0x200, a CAT naming EMM PID 0x201, one private section on each at 16 kb/s, DVB-CISSA in 10 s
# crypto-periods over 120 s of the clip) and grades it with t66-grade.py control. Then, for each
# packager variant in turn (`intra`: --intra-close; `pes`: without it), on loopback:
#   tsp --realtime scr.ts -> -O hls (2 s, live 6 + 3) -> nginx 127.0.0.1:$PORT
#   -> b8-hls-recv.py -> r.ts (tee) -> tsp -P descrambler (the same words)
#   -> mpegts-pacer --stream-clock -> UDP 127.0.0.1:$UDP -> tsp -I ip -> c.ts
# A keeper copies every segment and playlist the packager writes into keep/ before the window
# drops it. Grades into <variant>/grade.txt with t69-grade.py and t66-grade.py.
# env: PORT (18690), UDP (18691), RATE (11000000), LAT_MS (4000), NGINX (nginx on PATH)

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PACER=${1:?mpegts-pacer binary}
CLIP=${2:?clip}
OUT=${3:?out dir}
SECS=${4:-130}
PORT=${PORT:-18690}
UDP=${UDP:-18691}
RATE=${RATE:-11000000}
LAT_MS=${LAT_MS:-4000}
NGINX=${NGINX:-nginx}
PIDS_SCR=(--pid 111 --pid 121 --pid 123 --pid 131)
G66="$HERE/t66-grade.py"
G69="$HERE/t69-grade.py"
ID="$HERE/ts-passthrough-identity.py"

rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$OUT" || exit 1
{
	echo "pacer=$("$PACER" --version 2>&1 | head -1) tsduck=$(tsp --version 2>&1 | head -1) nginx=$("$NGINX" -v 2>&1)"
	echo "clip=$CLIP secs=$SECS rate=$RATE lat_ms=$LAT_MS"
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
python3 "$G66" control clear.ts scr.ts descr.ts | tee control.txt
grep -q 'control PASS' control.txt || {
	echo "the stimulus is void (criterion 6); nothing else runs" >&2
	exit 1
}
python3 "$G69" strip scr.ts scr-np.ts
python3 "$G69" strip descr.ts descr-np.ts

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	[ -f ngx/ngx.pid ] && kill "$(cat ngx/ngx.pid)" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	true
}
trap cleanup EXIT

run_variant() { # name [packager options]
	local v=$1
	shift
	mkdir -p "$OUT/$v/www" "$OUT/$v/keep" "$OUT/$v/ngx/tmp"
	cd "$OUT/$v" || return 1
	cat >ngx/nginx.conf <<EOF
worker_processes 1;
pid ngx.pid;
error_log error.log warn;
events { worker_connections 256; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	access_log access.log;
	client_body_temp_path tmp; proxy_temp_path tmp; fastcgi_temp_path tmp; uwsgi_temp_path tmp; scgi_temp_path tmp;
	server {
		listen 127.0.0.1:$PORT;
		root $OUT/$v/www;
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1"; }
	}
}
EOF
	"$NGINX" -p "$OUT/$v/ngx" -c "$OUT/$v/ngx/nginx.conf" -e "$OUT/$v/ngx/error.log" || return 1
	PIDS=()
	tsp --realtime -I file "$OUT/scr.ts" -P regulate --pcr-synchronous \
		-O hls "$OUT/$v/www/seg.ts" --playlist "$OUT/$v/www/index.m3u8" \
		--duration 2 --live 6 --live-extra-segments 3 "$@" >pack.log 2>&1 &
	PIDS+=($!)
	(
		n=0
		while :; do
			if [ -e www/index.m3u8 ] && ! cmp -s www/index.m3u8 keep/last.m3u8 2>/dev/null; then
				cp www/index.m3u8 keep/last.m3u8
				n=$((n + 1))
				cp keep/last.m3u8 "keep/pl-$(printf %05d "$n").m3u8"
				for s in $(grep -v '^#' keep/last.m3u8); do
					[ -e "keep/$s" ] || cp "www/$s" keep/ 2>/dev/null
				done
			fi
			sleep 0.3
		done
	) &
	PIDS+=($!)
	for _ in $(seq 1 60); do
		n=$(grep -c '\.ts' www/index.m3u8 2>/dev/null)
		[ "${n:-0}" -ge 2 ] && break
		sleep 0.5
	done
	tsp -I ip --local-address 127.0.0.1 "$UDP" -O file c.ts 2>cap.log &
	local cap=$!
	echo "receiver from $(date -u +%T)"
	python3 "$HERE/b8-hls-recv.py" "http://127.0.0.1:$PORT/index.m3u8" - --seconds "$SECS" --poll 250 \
		--log recv.jsonl 2>recv.err |
		tee r.ts |
		tsp --initial-input-packets 7 --max-input-packets 7 --max-flushed-packets 7 \
			-P descrambler "${PIDS_SCR[@]}" --dvb-cissa --cw-file "$OUT/cw.txt" 2>descr.log |
		"$PACER" "127.0.0.1:$UDP" "$RATE" --stream-clock --latency-ms "$LAT_MS" --max-latency-ms 14000 \
			--stall-ms 3000 --on-stall mute 2>pacer.log
	sleep 2
	kill "$cap" 2>/dev/null
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	kill "$(cat ngx/ngx.pid)" 2>/dev/null
	sleep 1
	{
		echo "--- criterion 7, cutting ($v: $*)"
		python3 "$G69" segs keep
		echo "--- criterion 8, carriage: receiver output against the stimulus, PIDs 0 and 0x64 removed"
		python3 "$G69" strip r.ts r-np.ts
		python3 "$ID" "$OUT/scr-np.ts" r-np.ts --span-out r-span.ts --json r-id.json
		python3 "$G66" ca r-span.ts r-np.ts
		python3 "$G69" pmt r.ts
		echo "--- criterion 9, descrambled: groomed capture against the offline-descrambled control"
		python3 "$G69" strip c.ts c-np.ts
		python3 "$ID" "$OUT/descr-np.ts" c-np.ts --groomed --json c-id.json
		python3 "$G66" checks c-np.ts
		echo "checks on c.ts, the packager's PAT and PMT included:"
		python3 "$G66" checks c.ts
		python3 "$G69" span "$OUT/descr.ts" c.ts c-clear-span.ts "$OUT/clear.ts"
		echo "ffmpeg on c.ts:"
		ffmpeg -hide_banner -nostats -v error -i c.ts -map 0:v -map 0:a -f null - 2>&1 |
			sed -E 's/ @ 0x[0-9a-f]+//' | sort | uniq -c | sort -rn | tee c-ffmpeg.txt
		echo "ffmpeg on the clear stimulus over c.ts's span:"
		ffmpeg -hide_banner -nostats -v error -i c-clear-span.ts -map 0:v -map 0:a -f null - 2>&1 |
			sed -E 's/ @ 0x[0-9a-f]+//' | sort | uniq -c | sort -rn | tee c-clear-ffmpeg.txt
		echo "pacer: $(grep -E 'done\.' pacer.log | tail -n 1)"
		echo "packager: $(grep -ciE 'error|warning' pack.log) error or warning lines"; grep -iE 'error|warning' pack.log | sort | uniq -c | head -5
	} 2>&1 | tee grade.txt
	cd "$OUT" || return 1
}

run_variant intra --intra-close
run_variant pes
trap - EXIT
echo "finished=$(date -u +%FT%TZ)" | tee -a meta.txt
