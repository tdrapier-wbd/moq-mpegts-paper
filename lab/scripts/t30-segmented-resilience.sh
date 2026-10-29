#!/usr/bin/env bash
# T30 single-host cells: classic segmented HTTP under distributed and partial failures.
# Linux host (GNU stat, nginx, tsp, python3); every port is loopback.
#
#   live source: tsp regulate -> UDP multicast on loopback (a packager can join it late)
#     -> packagers A [B] (tsp -I ip -O hls), one shared namespace unless the cell says otherwise
#     -> nginx origin [-> nginx edge cache, for the partial-failure rows]
#     -> t6-hls-pull.py (the retrying receiver) -> mpegts-pacer (groomer) -> groomed.ts
#     -> tsp -I hls --live (the shelf column, ungroomed)
#
# Usage: t30-segmented-resilience.sh <cell> <variant> <out-dir>
#   control   -                co-started shared-name pair; SIGKILL A at T_EVENT
#   join      naive|aligned    B joins A's namespace at T_EVENT; A SIGKILLed at T_EVENT+30.
#                              naive: B's own numbering. aligned: B's first name and media
#                              sequence continue A's playlist.
#   midwrite  -                co-started shared-name pair; torn-read probe for the whole run
#   partial   origin-down      edge in front; origin SIGKILLed at T_EVENT for 10 s
#             edge-stale       edge caches the playlist for 20 s, ignoring the origin's max-age=1
#             missing-seg      a newly listed segment deleted at T_EVENT, +15 s, +30 s
#             stale-playlist   playlist frozen for 10 s at T_EVENT while segments keep landing
#             early-delete     receiver paused 8 s at T_EVENT; at +6 s every listed segment but
#                              the newest is deleted
#             early-delete-ctl the same pause, nothing deleted
#             replica-disagree edge balances two origins; the second is fed by a source 20 s behind
#   misconfig independent-source  B packages its own copy of the clip from T_EVENT, same names
#             independent-aligned  the same, B's first name and media sequence continuing A's
#             names-offset         B co-started from the same source, numbering 5 segments ahead
#
# Environment: SRC (clip), PACER (groomer binary), RATE (groomer mux rate, b/s), T_EVENT and
# T_END (seconds after the receiver starts), PULL_RETRY (receiver poll, ms), PACK_EXTRA (extra
# -O hls arguments for packagers A and B, e.g. --slice-only).
# Output: one RESULT line on stdout; logs, captures and JSON grades under <out-dir>.
set -u

CELL=${1:?cell}
VARIANT=${2:--}
OUT=${3:?out-dir}
DIR=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HOME/contrib-10m.ts}
LOOP_S=${LOOP_S:-578.88}
PACER=${PACER:-$HOME/pacer/mpegts-pacer}
RATE=${RATE:-11438000}
T_EVENT=${T_EVENT:-40}
T_END=${T_END:-100}
PULL_RETRY=${PULL_RETRY:-500}
GROUP=${GROUP:-239.255.0.30:5030}
ORIGIN_PORT=${ORIGIN_PORT:-18300}
EDGE_PORT=${EDGE_PORT:-18301}
ORIGIN2_PORT=${ORIGIN2_PORT:-18302}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WWW=$OUT/www
WWW2=$OUT/www2
mkdir -p "$WWW" "$WWW2"
PIDS=()
declare -A EVENTS

cleanup() {
	for p in "${PIDS[@]}"; do
		pkill -KILL -P "$p" 2>/dev/null
		kill -KILL "$p" 2>/dev/null
	done
	wait 2>/dev/null
}
trap cleanup EXIT

port_free_or_die() {
	if ss -ltn "sport = :$1" | grep -q LISTEN; then
		echo "port $1 already in use" >&2
		exit 2
	fi
}
exec 9>"${TMPDIR:-/tmp}/t30-segmented.lock"
flock -n 9 || {
	echo "another t30 run is active" >&2
	exit 2
}
for p in "$ORIGIN_PORT" "$EDGE_PORT" "$ORIGIN2_PORT"; do port_free_or_die "$p"; done

sz() { stat -c%s "$1" 2>/dev/null || echo 0; }

# --- nginx -----------------------------------------------------------------------------

# One process, no master: SIGKILL takes the port down at once, as a crashed origin would.
nginx_start() {
	local name=$1 port=$2 body=$3
	local pfx=$OUT/ngx-$name
	mkdir -p "$pfx"
	cat >"$pfx/nginx.conf" <<EOF
daemon off;
master_process off;
worker_processes 1;
pid ngx.pid;
error_log error.log info;
events { worker_connections 1024; }
http {
	types { application/vnd.apple.mpegurl m3u8; video/mp2t ts; }
	log_format t30 '\$msec \$status \$request_uri \$body_bytes_sent \$request_time \$upstream_cache_status';
	access_log access.log t30;
	sendfile on;
	$body
}
EOF
	nginx -p "$pfx" -c "$pfx/nginx.conf" -e "$pfx/error.log" >"$pfx/stdout.log" 2>&1 &
	eval "NGX_${name}=$!"
	PIDS+=($!)
	for _ in $(seq 1 50); do
		ss -ltn "sport = :$port" | grep -q LISTEN && return 0
		sleep 0.1
	done
	echo "nginx $name failed to listen on $port" >&2
	exit 2
}

origin_body() {
	cat <<EOF
server {
		listen 127.0.0.1:$1;
		root $2;
		location ~ \.m3u8\$ { add_header Cache-Control "max-age=1" always; }
		location ~ \.ts\$ { add_header Cache-Control "max-age=60" always; }
	}
EOF
}

# A CDN-shaped edge: honours the origin's Cache-Control, caches errors for 10 s (CloudFront's
# default error-caching TTL), collapses concurrent misses, never marks an origin down.
edge_body() {
	local upstreams=$1 playlist_extra=$2
	cat <<EOF
proxy_cache_path cache levels=1:2 keys_zone=t30:10m max_size=1g inactive=10m use_temp_path=off;
	upstream origins { $upstreams }
	server {
		listen 127.0.0.1:$EDGE_PORT;
		proxy_cache t30;
		proxy_cache_lock on;
		proxy_cache_valid 404 10s;
		proxy_connect_timeout 1s;
		proxy_read_timeout 2s;
		proxy_next_upstream off;
		add_header X-Cache \$upstream_cache_status always;
		location ~ \.m3u8\$ { proxy_pass http://origins; $playlist_extra }
		location ~ \.ts\$ { proxy_pass http://origins; }
	}
EOF
}

# --- source and packagers --------------------------------------------------------------

source_start() {
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-O ip "$GROUP" --local-address 127.0.0.1 --enforce-burst >"$OUT/source.log" 2>&1 &
	SOURCE=$!
	PIDS+=("$SOURCE")
}

# pack <name> <www> <first-segment-name> <playlist-name> [input: live|file] [extra -O hls args]
pack() {
	local name=$1 www=$2 first=$3 pl=$4 input=${5:-live}
	shift 5
	local in=(-I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216)
	[ "$input" = file ] && in=(--realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous)
	# TSDuck refuses --align-first-segment beside --slice-only.
	local align=--align-first-segment
	case " ${PACK_EXTRA:-} " in *" --slice-only "*) align= ;; esac
	# shellcheck disable=SC2086 # $align and PACK_EXTRA are lists of arguments
	tsp "${in[@]}" -O hls "$www/$first" --playlist "$www/$pl" \
		--duration 2 --live 6 --live-extra-segments 3 --intra-close $align "$@" \
		${PACK_EXTRA:-} >"$OUT/pack-$name.log" 2>&1 &
	eval "PACK_${name}=$!"
	PIDS+=($!)
}

wait_playlist() {
	for _ in $(seq 1 40); do
		[ "$(grep -c '\.ts$' "$1" 2>/dev/null || echo 0)" -ge 3 ] && return 0
		sleep 0.5
	done
	echo "playlist $1 never reached three segments" >&2
	exit 3
}

# The next segment number a packager sharing this playlist would write.
next_number() {
	awk -F: '/^#EXT-X-MEDIA-SEQUENCE:/{s=$2} /\.ts$/{n++} END{print s+n}' "$1"
}

newest_segment() { grep '\.ts$' "$1" | tail -1; }

# --- receiver and groomer --------------------------------------------------------------

recv_start() {
	local url=$1 shelf_url=$2
	mkfifo "$OUT/pull.fifo"
	(tee "$OUT/raw.ts" <"$OUT/pull.fifo" | "$PACER" stdout "$RATE" 2>"$OUT/pacer.log" >"$OUT/groomed.ts") &
	GROOM=$!
	PIDS+=("$GROOM")
	python3 "$DIR/t6-hls-pull.py" "$url" "$OUT/pull.fifo" --seconds "$T_END" \
		--retry "$PULL_RETRY" --log "$OUT/pull.log" >"$OUT/pull.out" 2>&1 &
	PULL=$!
	PIDS+=("$PULL")
	tsp --realtime -I hls "$shelf_url" --live -O file "$OUT/shelf.ts" >"$OUT/shelf.log" 2>&1 &
	SHELF=$!
	PIDS+=("$SHELF")
}

sampler_start() {
	(
		echo "t,groomed_bytes,raw_bytes,event"
		for t in $(seq 0 "$T_END"); do
			printf "%s,%s,%s,%s\n" "$t" "$(sz "$OUT/groomed.ts")" "$(sz "$OUT/raw.ts")" "${EVENTS[$t]:-}"
			sleep 1
		done
	) >"$OUT/sizes.csv" &
	PIDS+=($!)
}

playlist_watch() {
	local pl=$1
	(
		echo "t,media_sequence,first,last"
		for t in $(seq 0 "$T_END"); do
			awk -v t="$t" -F: '/^#EXT-X-MEDIA-SEQUENCE:/{s=$2} /\.ts$/{if(!f)f=$0; l=$0}
				END{printf "%s,%s,%s,%s\n", t, s, f, l}' "$pl" 2>/dev/null
			sleep 1
		done
	) >"$OUT/playlist.csv" &
	PIDS+=($!)
}

at() { # at <seconds-after-receiver-start>: sleep until then
	local now
	now=$(($(date +%s) - T0))
	[ "$1" -gt "$now" ] && sleep $(($1 - now))
}

# --- topology per cell -----------------------------------------------------------------

PL=index.m3u8
URL=http://127.0.0.1:$ORIGIN_PORT/$PL
SHELF_URL=$URL
COPIER=

nginx_start origin "$ORIGIN_PORT" "$(origin_body "$ORIGIN_PORT" "$WWW")"

case $CELL/$VARIANT in
partial/stale-playlist)
	# The packager writes src.m3u8; the origin serves a copy renamed into place every 200 ms,
	# so the playlist can be frozen while segments keep landing.
	pack A "$WWW" seg.ts src.m3u8 live
	(while :; do
		[ -f "$WWW/src.m3u8" ] && cp "$WWW/src.m3u8" "$WWW/.idx.tmp" && mv -f "$WWW/.idx.tmp" "$WWW/$PL"
		sleep 0.2
	done) &
	COPIER=$!
	PIDS+=("$COPIER")
	;;
control/- | midwrite/- | join/naive | join/aligned | misconfig/independent-source | \
	misconfig/independent-aligned | partial/origin-down | partial/edge-stale | partial/missing-seg | partial/early-delete | \
	partial/early-delete-ctl | partial/replica-disagree)
	pack A "$WWW" seg.ts "$PL" live
	;;
misconfig/names-offset)
	pack A "$WWW" seg.ts "$PL" live
	pack B "$WWW" seg-000005.ts "$PL" live --start-media-sequence 5
	;;
*)
	echo "unknown cell/variant $CELL/$VARIANT" >&2
	exit 2
	;;
esac
case $CELL/$VARIANT in
control/- | midwrite/-) pack B "$WWW" seg.ts "$PL" live ;;
esac

if [ "$CELL" = partial ]; then
	extra=
	ups="server 127.0.0.1:$ORIGIN_PORT max_fails=0;"
	[ "$VARIANT" = edge-stale ] && extra="proxy_ignore_headers Cache-Control Expires; proxy_cache_valid 200 20s;"
	if [ "$VARIANT" = replica-disagree ]; then
		nginx_start origin2 "$ORIGIN2_PORT" "$(origin_body "$ORIGIN2_PORT" "$WWW2")"
		ups="$ups server 127.0.0.1:$ORIGIN2_PORT max_fails=0;"
	fi
	nginx_start edge "$EDGE_PORT" "$(edge_body "$ups" "$extra")"
	URL=http://127.0.0.1:$EDGE_PORT/$PL
	# The shelf column reads the origin directly, so it neither warms nor shields the edge.
	SHELF_URL=http://127.0.0.1:$ORIGIN_PORT/$PL
fi

sleep 1
source_start
if [ "$CELL/$VARIANT" = partial/replica-disagree ]; then
	(sleep 20 && exec tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-O hls "$WWW2/seg.ts" --playlist "$WWW2/$PL" --duration 2 --live 6 --live-extra-segments 3 \
		--intra-close --align-first-segment >"$OUT/pack-C.log" 2>&1) &
	PIDS+=($!)
	sleep 21
	wait_playlist "$WWW2/$PL"
fi
wait_playlist "$WWW/$PL"

T0=$(date +%s)
recv_start "$URL" "$SHELF_URL"
sampler_start
playlist_watch "$WWW/$PL"

HAMMER=
if [ "$CELL" = midwrite ]; then
	python3 "$DIR/t30-hammer.py" "$URL" --seconds $((T_END - 10)) --log "$OUT/hammer.csv" \
		--poll-ms 20 --refetch-ms 50,200,1000 >"$OUT/hammer.out" 2>&1 &
	HAMMER=$!
	PIDS+=("$HAMMER")
fi

# --- events ----------------------------------------------------------------------------

E=$T_EVENT
case $CELL/$VARIANT in
control/-)
	EVENTS[$E]=kill-A
	at "$E"
	kill -KILL "$PACK_A"
	;;
join/naive | join/aligned)
	EVENTS[$E]=B-joins
	EVENTS[$((E + 30))]=kill-A
	at "$E"
	if [ "$VARIANT" = aligned ]; then
		n=$(next_number "$WWW/$PL")
		printf -v first "seg-%06d.ts" "$n"
		echo "B first segment $first, media sequence $n" >"$OUT/join.txt"
		pack B "$WWW" "$first" "$PL" live --start-media-sequence "$n"
	else
		pack B "$WWW" seg.ts "$PL" live
	fi
	at $((E + 30))
	kill -KILL "$PACK_A"
	;;
misconfig/independent-source)
	EVENTS[$E]=B-starts
	at "$E"
	pack B "$WWW" seg.ts "$PL" file
	;;
misconfig/independent-aligned)
	EVENTS[$E]=B-starts
	at "$E"
	n=$(next_number "$WWW/$PL")
	printf -v first "seg-%06d.ts" "$n"
	echo "B first segment $first, media sequence $n" >"$OUT/join.txt"
	pack B "$WWW" "$first" "$PL" file --start-media-sequence "$n"
	;;
partial/origin-down)
	EVENTS[$E]=origin-down
	EVENTS[$((E + 10))]=origin-up
	at "$E"
	kill -KILL "$NGX_origin"
	at $((E + 10))
	nginx_start origin "$ORIGIN_PORT" "$(origin_body "$ORIGIN_PORT" "$WWW")"
	;;
partial/missing-seg)
	for k in 0 15 30; do
		EVENTS[$((E + k))]=delete-newest
	done
	for k in 0 15 30; do
		at $((E + k))
		before=$(newest_segment "$WWW/$PL")
		for _ in $(seq 1 250); do
			cur=$(newest_segment "$WWW/$PL")
			[ -n "$cur" ] && [ "$cur" != "$before" ] && break
			sleep 0.02
		done
		rm -f "$WWW/$cur"
		echo "$(date +%s.%N) deleted $cur" >>"$OUT/deleted.txt"
	done
	;;
partial/stale-playlist)
	EVENTS[$E]=freeze
	EVENTS[$((E + 10))]=thaw
	at "$E"
	kill -STOP "$COPIER"
	at $((E + 10))
	kill -CONT "$COPIER"
	;;
partial/early-delete | partial/early-delete-ctl)
	EVENTS[$E]=pause-receiver
	EVENTS[$((E + 8))]=resume-receiver
	at "$E"
	kill -STOP "$PULL"
	if [ "$VARIANT" = early-delete ]; then
		EVENTS[$((E + 6))]=delete-listed
		at $((E + 6))
		grep '\.ts$' "$WWW/$PL" | head -n -1 | while read -r s; do
			rm -f "$WWW/$s"
			echo "$(date +%s.%N) deleted $s" >>"$OUT/deleted.txt"
		done
	fi
	at $((E + 8))
	kill -CONT "$PULL"
	;;
esac

# --- wind down -------------------------------------------------------------------------

wait "$PULL" 2>/dev/null
for _ in $(seq 1 40); do
	kill -0 "$GROOM" 2>/dev/null || break
	sleep 0.5
done
SHELF_ALIVE=0
kill -0 "$SHELF" 2>/dev/null && SHELF_ALIVE=1
[ -n "$HAMMER" ] && wait "$HAMMER" 2>/dev/null
sleep 1

# --- grading ---------------------------------------------------------------------------

G=$OUT/groomed.ts
kv() { python3 -c "import json,sys; d=json.load(open('$1')); print(' '.join(f'{k}={d.get(k)}' for k in sys.argv[1:]))" "${@:2}" 2>/dev/null; }

PULL_LINE=$(grep '^PULL' "$OUT/pull.out" | sed 's/^PULL //')
SEG_FAIL=$(grep -c 'segment fetch failed' "$OUT/pull.log" 2>/dev/null || true)
CONTENT="content=ungraded"
TIMELINE="timeline=ungraded"
CC=na
if [ "$(sz "$G")" -gt 1000000 ]; then
	python3 "$DIR/t28-content-lost.py" --input "$G" --json "$OUT/content.json" >"$OUT/content.txt" 2>&1 &&
		CONTENT=$(kv "$OUT/content.json" content_lost_s holes largest_hole_s content_dup_s discontinuities)
	python3 "$DIR/t30-timeline.py" --input "$G" --loop-s "$LOOP_S" --json "$OUT/timeline.json" >"$OUT/timeline.txt" 2>&1 &&
		TIMELINE=$(kv "$OUT/timeline.json" back_steps back_max_s fwd_steps fwd_max_s silent_time_travel)
	CC=$(tsp -I file "$G" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
fi
RAW_CC=na
[ "$(sz "$OUT/raw.ts")" -gt 1000000 ] &&
	RAW_CC=$(tsp -I file "$OUT/raw.ts" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
SHELF="shelf_bytes=$(sz "$OUT/shelf.ts") shelf_alive=$SHELF_ALIVE"
if [ "$(sz "$OUT/shelf.ts")" -gt 1000000 ]; then
	python3 "$DIR/t28-content-lost.py" --input "$OUT/shelf.ts" --json "$OUT/shelf-content.json" >/dev/null 2>&1 &&
		SHELF="$SHELF shelf_$(kv "$OUT/shelf-content.json" content_lost_s)"
fi
PACER_LINE=$(grep -E 'mpegts-pacer: done' "$OUT/pacer.log" | tail -1 |
	grep -oE '(late_drops|resyncs|underruns|stalls|muted|max_content_gap)=[0-9]+' | tr '\n' ' ')

http_stats() { # name: non-200 count and bytes served
	local log=$OUT/ngx-$1/access.log
	[ -f "$log" ] || return 0
	awk -v n="$1" '{c++; if($2!=200)e++; b+=$4; if($6=="HIT")h++}
		END{printf "%s_reqs=%d %s_non200=%d %s_bytes=%d %s_hits=%d", n,c,n,e+0,n,b,n,h+0}' "$log"
}
HTTP="$(http_stats origin) $(http_stats edge) $(http_stats origin2)"
HAM=
[ -n "$HAMMER" ] && HAM=$(grep '^HAMMER' "$OUT/hammer.out" | sed 's/^HAMMER //')
TRUNC=$(cat "$OUT"/ngx-*/error.log 2>/dev/null | grep -c 'truncated' || true)
OUTAGE=$(python3 "$DIR/t30-regrade.py" "$OUT" --rate "$RATE" --window "$T_EVENT" $((T_EVENT + 30)) | cut -d' ' -f2-)

echo "RESULT cell=$CELL variant=$VARIANT $PULL_LINE seg_fetch_failed=$SEG_FAIL $CONTENT $TIMELINE" \
	"$OUTAGE cc_groomed=$CC cc_raw=$RAW_CC $SHELF $HTTP nginx_truncated=$TRUNC $HAM pacer=[$PACER_LINE]" |
	tee "$OUT/result.txt"
