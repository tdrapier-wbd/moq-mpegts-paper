#!/usr/bin/env bash
# T30 Cell 2's per-host actions (lab/test-30-segmented-distributed-resilience.md), driven from the
# laptop by t30-cell2.sh. Each host runs its own part:
#
#   store host     store-up A_IP B_IP | store-down A_IP B_IP | origin-start RUN BIND | origin-stop RUN
#                  | watch PLAYLIST | hashes DIR
#   packager hosts mount STORE_IP | umount | pack-start RUN NAME DIR <tsp -I ip args...> | pack-kill RUN
#                  | pack-stop RUN | part-on STORE_IP | part-off
#   source host    source-start RUN B_IP | source-stop RUN
#   receiver host  recv RUN URL (foreground: receiver, groomer, shelf column, then T30's grade)
#
# Every process it starts is its own session, stopped by the PID it records, never by a pattern.
# The store is mounted for the run only (no fstab entry); store-down and umount leave the NFS
# server and rpcbind stopped and disabled.
set -u
STORE_DIR=/srv/t30store
MNT=/mnt/t30store
PORT=18300
GROUP=239.255.0.30:5030
UNI_PORT=5031
SRC=${SRC:-$HOME/contrib-10m.ts}
PACER=${PACER:-$HOME/pacer/mpegts-pacer}
RATE=${RATE:-11438000}
T_EVENT=${T_EVENT:-40}
T_END=${T_END:-100}
PULL_RETRY=${PULL_RETRY:-500}
LOOP_S=${LOOP_S:-578.88}
DIR=$(cd "$(dirname "$0")" && pwd)

sz() { stat -c%s "$1" 2>/dev/null || echo 0; }
stop_session() { # pid file: SIGTERM, then SIGKILL, the session it names
	local f=$1 g
	[ -f "$f" ] || return 0
	g=$(cat "$f")
	kill -TERM -- "-$g" 2>/dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 -- "-$g" 2>/dev/null || break
		sleep 0.2
	done
	kill -KILL -- "-$g" 2>/dev/null
	rm -f "$f"
}

cmd=${1:?command}
shift
case $cmd in
store-up)
	a=${1:?A_IP} b=${2:?B_IP}
	sudo mkdir -p "$STORE_DIR/www"
	sudo chown -R "$(id -u):$(id -g)" "$STORE_DIR"
	grep -q "^$STORE_DIR " /etc/exports ||
		echo "$STORE_DIR $a(rw,sync,no_subtree_check,no_root_squash) $b(rw,sync,no_subtree_check,no_root_squash)" |
		sudo tee -a /etc/exports >/dev/null
	sudo systemctl start nfs-server
	sudo exportfs -ra
	sudo exportfs -v | grep -c "^$STORE_DIR"
	;;
store-down)
	a=${1:?A_IP} b=${2:?B_IP}
	sudo exportfs -u "$a:$STORE_DIR" 2>/dev/null
	sudo exportfs -u "$b:$STORE_DIR" 2>/dev/null
	sudo sed -i "\#^$STORE_DIR #d" /etc/exports
	sudo systemctl disable --now nfs-server rpcbind.socket rpcbind.service >/dev/null 2>&1
	sudo rm -rf "$STORE_DIR"
	echo "nfs-server $(systemctl is-active nfs-server), rpcbind $(systemctl is-active rpcbind.socket)"
	;;
mount)
	sudo mkdir -p "$MNT"
	mountpoint -q "$MNT" || sudo mount -t nfs4 -o hard,timeo=600,retrans=2 "${1:?STORE_IP}:$STORE_DIR" "$MNT"
	findmnt -n -o SOURCE,OPTIONS "$MNT" | sed -E 's/^[^:]+:/<store>:/'
	;;
umount)
	mountpoint -q "$MNT" && sudo umount "$MNT"
	sudo rmdir "$MNT" 2>/dev/null
	sudo systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1
	echo "mounted $(mountpoint -q "$MNT" && echo yes || echo no), rpcbind $(systemctl is-active rpcbind.socket)"
	;;
origin-start)
	run=${1:?RUN} bind=${2:?BIND}
	pfx=$run/ngx
	mkdir -p "$pfx/tmp"
	cat >"$pfx/nginx.conf" <<EOF
daemon off;
master_process off;
worker_processes 1;
pid ngx.pid;
error_log error.log info;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format t30 '\$msec \$remote_addr \$status \$request_uri \$body_bytes_sent \$request_time';
	access_log access.log t30;
	client_body_temp_path tmp/body;
	proxy_temp_path tmp/proxy;
	fastcgi_temp_path tmp/fastcgi;
	uwsgi_temp_path tmp/uwsgi;
	scgi_temp_path tmp/scgi;
	sendfile on;
	server {
		listen $bind:$PORT;
		root $STORE_DIR/www;
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1" always; }
		location ~ \.ts\$ { add_header Cache-Control "max-age=60" always; }
	}
}
EOF
	setsid nginx -p "$pfx" -c "$pfx/nginx.conf" -e "$pfx/error.log" >"$pfx/stdout.log" 2>&1 </dev/null &
	echo $! >"$run/origin.pid"
	setsid bash "$0" watch "$STORE_DIR/www/index.m3u8" >"$run/playlist.csv" 2>/dev/null </dev/null &
	echo $! >"$run/watch.pid"
	for _ in $(seq 1 50); do
		ss -ltn "sport = :$PORT" | grep -q LISTEN && exit 0
		sleep 0.1
	done
	echo "origin failed to listen" >&2
	exit 2
	;;
origin-stop)
	stop_session "${1:?RUN}/watch.pid"
	stop_session "$1/origin.pid"
	awk '{c++; if($3!=200)e++; b+=$5} END{printf "origin_reqs=%d origin_non200=%d origin_bytes=%d\n", c, e+0, b}' \
		"$1/ngx/access.log" 2>/dev/null
	;;
watch) # the playlist as the origin serves it, once a second: media sequence, first and last name
	echo "t,media_sequence,first,last"
	while :; do
		awk -v t="$(date +%s.%N)" -F: '/^#EXT-X-MEDIA-SEQUENCE:/{s=$2} /\.ts$/{if(!f)f=$0; l=$0}
			END{printf "%s,%s,%s,%s\n", t, s, f, l}' "${1:?PLAYLIST}" 2>/dev/null
		sleep 1
	done
	;;
hashes)
	cd "${1:?DIR}" || exit 1
	for f in seg-*.ts; do echo "$f $(sha1sum <"$f" | cut -c1-16) $(sz "$f")"; done
	;;
pack-start)
	run=${1:?RUN} name=${2:?NAME} dir=${3:?DIR}
	shift 3
	mkdir -p "$run" "$dir"
	setsid tsp "$@" --buffer-size 16777216 -O hls "$dir/seg.ts" --playlist "$dir/index.m3u8" \
		--duration 2 --live 6 --live-extra-segments 3 --intra-close --align-first-segment \
		>"$run/pack-$name.log" 2>&1 </dev/null &
	echo $! >"$run/pack.pid"
	;;
pack-kill)
	kill -KILL "$(cat "${1:?RUN}/pack.pid")"
	;;
pack-stop)
	stop_session "${1:?RUN}/pack.pid"
	;;
part-on)
	sudo nft add table inet t30p
	sudo nft add chain inet t30p out '{ type filter hook output priority 0; policy accept; }'
	sudo nft add chain inet t30p in '{ type filter hook input priority 0; policy accept; }'
	sudo nft add rule inet t30p out ip daddr "${1:?STORE_IP}" tcp dport 2049 drop
	sudo nft add rule inet t30p in ip saddr "$1" tcp sport 2049 drop
	;;
part-off)
	sudo nft delete table inet t30p 2>/dev/null
	true
	;;
source-start)
	run=${1:?RUN} b=${2:?B_IP}
	mkdir -p "$run"
	setsid tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-P fork --nowait --ignore-abort "tsp -O ip $b:$UNI_PORT --enforce-burst" \
		-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$run/source.log" 2>&1 </dev/null &
	echo $! >"$run/source.pid"
	;;
source-stop)
	stop_session "${1:?RUN}/source.pid"
	;;
recv)
	run=${1:?RUN} url=${2:?URL}
	mkdir -p "$run"
	cd "$run" || exit 1
	mkfifo pull.fifo
	(tee raw.ts <pull.fifo | "$PACER" stdout "$RATE" 2>pacer.log >groomed.ts) &
	GROOM=$!
	python3 "$DIR/t6-hls-pull.py" "$url" pull.fifo --seconds "$T_END" --retry "$PULL_RETRY" \
		--log pull.log >pull.out 2>&1 &
	PULL=$!
	tsp --realtime -I hls "$url" --live -O file shelf.ts >shelf.log 2>&1 &
	SHELF=$!
	(
		echo "t,groomed_bytes,raw_bytes,event"
		for t in $(seq 0 "$T_END"); do
			printf "%s,%s,%s,\n" "$t" "$(sz groomed.ts)" "$(sz raw.ts)"
			sleep 1
		done
	) >sizes.csv &
	SAMP=$!
	wait "$PULL"
	for _ in $(seq 1 40); do
		kill -0 "$GROOM" 2>/dev/null || break
		sleep 0.5
	done
	SHELF_ALIVE=0
	kill -0 "$SHELF" 2>/dev/null && SHELF_ALIVE=1
	kill "$SHELF" 2>/dev/null
	wait "$SAMP"
	G=groomed.ts
	kv() { python3 -c "import json,sys; d=json.load(open('$1')); print(' '.join(f'{k}={d.get(k)}' for k in sys.argv[1:]))" "${@:2}" 2>/dev/null; }
	PULL_LINE=$(grep '^PULL' pull.out | sed 's/^PULL //')
	SEG_FAIL=$(grep -c 'segment fetch failed' pull.log 2>/dev/null || true)
	CONTENT="content=ungraded"
	TIMELINE="timeline=ungraded"
	CC=na
	if [ "$(sz "$G")" -gt 1000000 ]; then
		python3 "$DIR/t28-content-lost.py" --input "$G" --json content.json >content.txt 2>&1 &&
			CONTENT=$(kv content.json content_lost_s holes largest_hole_s content_dup_s discontinuities)
		python3 "$DIR/t30-timeline.py" --input "$G" --loop-s "$LOOP_S" --json timeline.json >timeline.txt 2>&1 &&
			TIMELINE=$(kv timeline.json back_steps back_max_s fwd_steps fwd_max_s silent_time_travel)
		CC=$(tsp -I file "$G" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
	fi
	RAW_CC=na
	[ "$(sz raw.ts)" -gt 1000000 ] &&
		RAW_CC=$(tsp -I file raw.ts -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
	SHELF="shelf_bytes=$(sz shelf.ts) shelf_alive=$SHELF_ALIVE"
	if [ "$(sz shelf.ts)" -gt 1000000 ]; then
		python3 "$DIR/t28-content-lost.py" --input shelf.ts --json shelf-content.json >/dev/null 2>&1 &&
			SHELF="$SHELF shelf_$(kv shelf-content.json content_lost_s)"
	fi
	PACER_LINE=$(grep -E 'mpegts-pacer: done' pacer.log | tail -1 |
		grep -oE '(late_drops|resyncs|underruns|stalls|muted|max_content_gap)=[0-9]+' | tr '\n' ' ')
	OUTAGE=$(python3 "$DIR/t30-regrade.py" . --rate "$RATE" --window "$T_EVENT" $((T_EVENT + 30)) | cut -d' ' -f2-)
	echo "RESULT $PULL_LINE seg_fetch_failed=$SEG_FAIL $CONTENT $TIMELINE $OUTAGE cc_groomed=$CC" \
		"cc_raw=$RAW_CC $SHELF pacer=[$PACER_LINE]" >result.txt
	rm -f pull.fifo
	touch recv.done
	;;
*)
	echo "unknown command $cmd" >&2
	exit 2
	;;
esac
