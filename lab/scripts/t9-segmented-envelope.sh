#!/usr/bin/env bash
# T9, segmented-HTTP arm — the per-role resource envelope, and the origin's fan-out knee.
#
#   t9-segmented-envelope.sh [outdir]
#
# T9 characterises the MoQ lane role by role: publisher, relay, subscriber, each with a
# steady-state CPU and RSS figure and a fan-out knee. The segmented lane had none of that.
# Its carriage overhead was measured (1.036x source TS) and nothing else was, so the cost
# comparison in the paper priced one lane for resources and the other for bytes.
#
# Three roles here, mapped onto the MoQ ones so the columns mean the same thing:
#
#   packager   tsp -O hls          the publisher-equivalent: takes a paced TS, writes segments
#   origin     nginx | python3     the relay-equivalent: the serving node, fanning one input out
#   client     tsp -I hls          the subscriber-equivalent: playlist -> reassembled TS
#
# TWO MEASUREMENTS, because they need different clients, and conflating them is how T9's
# first fan-out sweep measured the host instead of the relay:
#
#   A. steady state at N=1. All three roles at once, CPU attributed per process from
#      /proc/<pid>/stat, RSS from /proc/<pid>/status, plus fds and threads. This is the
#      row that goes beside the MoQ numbers.
#
#   B. the origin's fan-out knee, with cheap clients. A tsp -I hls client costs several
#      times what serving it costs, so a sweep driven by real clients saturates two vCPUs
#      long before the origin bends and the knee you measure belongs to the box. Arm B
#      drives the same origin with curl loops instead: they fetch the identical bytes at
#      the identical rate and cost almost nothing, so what bends is the origin.
#
# TWO ORIGINS, because that is the open question rather than a detail. Every segmented
# figure in this campaign was served by `python3 -m http.server`, which is single-threaded,
# synchronous, and not what anyone deploys. nginx is. Running both at the same fan-out
# prices the implementation, and the difference is the part worth publishing.
#
# BYTES ARE COUNTED AT THE CLIENT, not at the origin. Both origins serve with sendfile, and
# sendfile bytes do not appear in /proc/<pid>/io `wchar` — measured, delta 67 B for a 20 MB
# transfer, and sudo does not change it. So each fetcher records curl's own
# %{size_download} and the arm sums those. The ratio of what arrived to n x the source rate
# is then the knee: an origin that is keeping up delivers 1.0, and one that is not cannot.
#
# The standing services are left alone: the relay is idle without subscribers (measured, one
# CPU tick per five seconds) and the loop publisher is a wrap regression test whose uptime
# is worth more than the noise it adds. Whole-box CPU is recorded alongside every per-role
# figure so contention is visible rather than assumed.
set -uo pipefail

OUT=${1:-$HOME/t9seg-env}
SRC=${SRC:-$HOME/CNNiEMEA2.ts}
SEGSECS=${SEGSECS:-2}
SETTLE=${SETTLE:-25}
WINDOW=${WINDOW:-60}
PORT=${PORT:-18300}
STEPS=${STEPS:-"1 5 10 25 50"}
MIN_AVAIL_MB=${MIN_AVAIL_MB:-500}
SOURCE_BPS=${SOURCE_BPS:-9945951}
ORIGINS=${ORIGINS:-"python nginx"}

HZ=$(getconf CLK_TCK)
mkdir -p "$OUT"
RESULTS=$OUT/results.txt
: >"$RESULTS"

command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}
[ -r "$SRC" ] || {
	echo "no source: $SRC" >&2
	exit 1
}

PIDS=()
NGINX_CONF=""
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	[ -n "$NGINX_CONF" ] && nginx -c "$NGINX_CONF" -s quit 2>/dev/null
	pkill -9 -f "[t]sp -I hls http://127\.0\.0\.1:$PORT" 2>/dev/null
	true
}
trap cleanup EXIT

# --- process accounting -------------------------------------------------------
# `pgrep -P`, not `pstree -p`. pstree lists a process's THREADS alongside its children as
# {name}(tid), and /proc/<pid>/stat already aggregates the thread group — so summing what
# pstree prints multiplies both CPU and RSS by the thread count. Measured: a six-thread tsp
# reported 272 MB where it holds 45 MB. pgrep -P returns child processes only.
descendants() { # <pid> -> pid and every descendant process, threads excluded
	local queue=("$1") out=() p kid
	while [ ${#queue[@]} -gt 0 ]; do
		p=${queue[0]}
		queue=("${queue[@]:1}")
		out+=("$p")
		for kid in $(pgrep -P "$p" 2>/dev/null); do queue+=("$kid"); done
	done
	echo "${out[@]}"
}
cpu_ticks() {
	local total=0 t p
	for p in $(descendants "$1"); do
		t=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null) || continue
		total=$((total + ${t:-0}))
	done
	echo "$total"
}
rss_kb() {
	local total=0 t p
	for p in $(descendants "$1"); do
		t=$(awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null) || continue
		total=$((total + ${t:-0}))
	done
	echo "$total"
}
count_fd() {
	local total=0 p
	for p in $(descendants "$1"); do
		total=$((total + $(ls "/proc/$p/fd" 2>/dev/null | wc -l)))
	done
	echo "$total"
}
count_thr() {
	local total=0 p
	for p in $(descendants "$1"); do
		total=$((total + $(ls "/proc/$p/task" 2>/dev/null | wc -l)))
	done
	echo "$total"
}
box_busy() { awk '/^cpu /{print $2+$3+$4+$6+$7+$8}' /proc/stat; }
box_total() { awk '/^cpu /{s=0; for(i=2;i<=8;i++)s+=$i; print s}' /proc/stat; }

# --- the origin ---------------------------------------------------------------
start_origin() { # <kind> <docroot>
	local kind=$1 root=$2
	case "$kind" in
	python)
		(cd "$root" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
			>"$OUT/origin.log" 2>&1 &
		ORIGIN_PID=$!
		sleep 1
		;;
	nginx)
		NGINX_CONF=$OUT/nginx.conf
		mkdir -p "$OUT/nginx"
		# One worker on purpose. The question is what serving this costs, and a
		# worker-per-core origin answers it only for this box's core count; a single
		# worker gives a per-worker figure that scales explicitly. sendfile and
		# tcp_nopush stay on because that is how static segments are served, and
		# turning them off would price a configuration nobody runs.
		cat >"$NGINX_CONF" <<EOF
worker_processes 1;
daemon on;
pid $OUT/nginx/nginx.pid;
error_log $OUT/nginx/error.log warn;
events { worker_connections 4096; }
http {
    access_log off;
    sendfile on;
    tcp_nopush on;
    types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
    default_type application/octet-stream;
    server {
        listen 127.0.0.1:$PORT;
        root $root;
        location / { add_header Cache-Control "no-cache"; }
    }
}
EOF
		nginx -c "$NGINX_CONF" -e "$OUT/nginx/error.log" 2>>"$OUT/origin.log" || {
			echo "nginx failed to start; see $OUT/nginx/error.log" >&2
			return 1
		}
		sleep 1
		ORIGIN_PID=$(cat "$OUT/nginx/nginx.pid")
		;;
	esac
	PIDS+=("$ORIGIN_PID")
}

stop_origin() {
	case "$1" in
	python) kill "$ORIGIN_PID" 2>/dev/null ;;
	nginx) nginx -c "$NGINX_CONF" -s quit 2>/dev/null || kill "$ORIGIN_PID" 2>/dev/null ;;
	esac
	sleep 1
}

start_packager() { # <docroot> <logfile>
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-O hls "$1/seg.ts" --playlist "$1/index.m3u8" \
		--duration "$SEGSECS" --live 6 --live-extra-segments 3 \
		--intra-close --align-first-segment >"$2" 2>&1 &
	PKG_PID=$!
	PIDS+=("$PKG_PID")
}

wait_playlist() {
	local i
	for i in $(seq 1 180); do
		if [ -f "$1/index.m3u8" ] &&
			[ "$(grep -c '^seg.*\.ts$' "$1/index.m3u8" 2>/dev/null || echo 0)" -ge 3 ]; then
			return 0
		fi
		sleep 1
	done
	return 1
}

# =============================================================================
# ARM A — steady state, N=1, all three roles at once
# =============================================================================
arm_a() { # <origin-kind>
	local kind=$1 dir=$OUT/a-$kind root=$OUT/a-$kind/hls
	rm -rf "$dir"
	mkdir -p "$root"

	start_packager "$root" "$dir/pkg.log"
	start_origin "$kind" "$root" || return 1
	wait_playlist "$root" || {
		echo "no playlist for arm A/$kind" >&2
		return 1
	}
	local pkg=$PKG_PID org=$ORIGIN_PID

	tsp --realtime -I hls "http://127.0.0.1:$PORT/index.m3u8" --live \
		-O drop >"$dir/cli.log" 2>&1 &
	local cli=$!
	PIDS+=("$cli")

	sleep "$SETTLE"
	local cp0 co0 cc0 b0 t0
	cp0=$(cpu_ticks "$pkg") co0=$(cpu_ticks "$org") cc0=$(cpu_ticks "$cli")
	b0=$(box_busy) t0=$(box_total)
	sleep "$WINDOW"
	local cp1 co1 cc1 b1 t1
	cp1=$(cpu_ticks "$pkg") co1=$(cpu_ticks "$org") cc1=$(cpu_ticks "$cli")
	b1=$(box_busy) t1=$(box_total)

	local role pid d
	for role in packager origin client; do
		case $role in
		packager)
			pid=$pkg
			d=$((cp1 - cp0))
			;;
		origin)
			pid=$org
			d=$((co1 - co0))
			;;
		client)
			pid=$cli
			d=$((cc1 - cc0))
			;;
		esac
		printf 'ARM=a origin=%s role=%s cpu_pct=%.2f cpu_s=%.2f rss_kb=%s fds=%s threads=%s window_s=%s\n' \
			"$kind" "$role" \
			"$(awk -v d="$d" -v hz="$HZ" -v w="$WINDOW" 'BEGIN{print d/hz/w*100}')" \
			"$(awk -v d="$d" -v hz="$HZ" 'BEGIN{print d/hz}')" \
			"$(rss_kb "$pid")" "$(count_fd "$pid")" "$(count_thr "$pid")" "$WINDOW" |
			tee -a "$RESULTS"
	done
	printf 'ARM=a origin=%s role=box cpu_pct=%.2f window_s=%s\n' "$kind" \
		"$(awk -v b="$((b1 - b0))" -v t="$((t1 - t0))" 'BEGIN{print b/t*100}')" "$WINDOW" |
		tee -a "$RESULTS"

	kill "$cli" "$pkg" 2>/dev/null
	stop_origin "$kind"
	sleep 2
}

# =============================================================================
# ARM B — the origin's fan-out knee, driven by cheap clients
# =============================================================================
# Each virtual client reloads the playlist every segment period and fetches whatever it has
# not seen, discarding the body but recording its size. That is the origin's exact workload;
# what it is not is a client, which is the point.
fetcher() { # <url> <tallyfile>
	local url=$1 tally=$2 seen="" s
	while :; do
		for s in $(curl -s --max-time 5 "$url/index.m3u8" | grep '^seg.*\.ts$'); do
			case " $seen " in
			*" $s "*) continue ;;
			esac
			curl -s -o /dev/null --max-time 10 -w '%{size_download}\n' "$url/$s" >>"$tally"
			seen="$seen $s"
		done
		sleep "$SEGSECS"
	done
}

tally_sum() { cat "$1"/* 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

arm_b() { # <origin-kind>
	local kind=$1 dir=$OUT/b-$kind root=$OUT/b-$kind/hls tally=$OUT/b-$kind/tally
	rm -rf "$dir"
	mkdir -p "$root" "$tally"

	start_packager "$root" "$dir/pkg.log"
	start_origin "$kind" "$root" || return 1
	wait_playlist "$root" || {
		echo "no playlist for arm B/$kind" >&2
		return 1
	}
	local org=$ORIGIN_PID pkg=$PKG_PID

	local url="http://127.0.0.1:$PORT" running=0 fpids=() n
	for n in $STEPS; do
		local avail
		avail=$(awk '/^MemAvailable/{print int($2/1024)}' /proc/meminfo)
		if [ "$avail" -lt "$MIN_AVAIL_MB" ]; then
			printf 'ARM=b origin=%s n=%s SKIPPED avail_mb=%s\n' "$kind" "$n" "$avail" |
				tee -a "$RESULTS"
			break
		fi
		while [ "$running" -lt "$n" ]; do
			running=$((running + 1))
			fetcher "$url" "$tally/$running" >/dev/null 2>&1 &
			fpids+=("$!")
			PIDS+=("$!")
		done
		sleep "$SETTLE"

		local c0 b0 t0 y0 c1 b1 t1 y1
		c0=$(cpu_ticks "$org") b0=$(box_busy) t0=$(box_total) y0=$(tally_sum "$tally")
		sleep "$WINDOW"
		c1=$(cpu_ticks "$org") b1=$(box_busy) t1=$(box_total) y1=$(tally_sum "$tally")

		printf 'ARM=b origin=%s n=%s org_cpu_pct=%.2f org_cpu_per_client_pct=%.3f rss_kb=%s fds=%s threads=%s served_mbps=%.2f expected_mbps=%.2f delivered_frac=%.3f box_cpu_pct=%.2f\n' \
			"$kind" "$n" \
			"$(awk -v d="$((c1 - c0))" -v hz="$HZ" -v w="$WINDOW" 'BEGIN{print d/hz/w*100}')" \
			"$(awk -v d="$((c1 - c0))" -v hz="$HZ" -v w="$WINDOW" -v n="$n" 'BEGIN{print d/hz/w*100/n}')" \
			"$(rss_kb "$org")" "$(count_fd "$org")" "$(count_thr "$org")" \
			"$(awk -v d="$((y1 - y0))" -v w="$WINDOW" 'BEGIN{print d*8/w/1e6}')" \
			"$(awk -v n="$n" -v s="$SOURCE_BPS" 'BEGIN{print n*s/1e6}')" \
			"$(awk -v d="$((y1 - y0))" -v w="$WINDOW" -v n="$n" -v s="$SOURCE_BPS" 'BEGIN{print (d*8/w)/(n*s)}')" \
			"$(awk -v b="$((b1 - b0))" -v t="$((t1 - t0))" 'BEGIN{print b/t*100}')" |
			tee -a "$RESULTS"
	done

	for p in ${fpids+"${fpids[@]}"}; do kill -9 "$p" 2>/dev/null; done
	kill "$pkg" 2>/dev/null
	stop_origin "$kind"
	sleep 2
}

echo "=== T9 segmented envelope: settle ${SETTLE}s, window ${WINDOW}s, steps: $STEPS"
for kind in $ORIGINS; do
	echo "--- arm A, origin=$kind"
	arm_a "$kind"
	echo "--- arm B, origin=$kind"
	arm_b "$kind"
done
echo
echo "results in $RESULTS"
cat "$RESULTS"
