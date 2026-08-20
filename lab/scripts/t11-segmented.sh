#!/usr/bin/env bash
# T11, segmented-HTTP arm — does this lane's media survive everyone else's software?
#
#   ./t11-segmented.sh [outdir]
#
# T11 asks whether a MoQ relay is a neutral fabric by putting one fixture through
# nine other people's relays; eight return nothing. The same question has to be put
# to the other data plane, and it has to be put the same way — the same fixture, the
# same oracle, third-party software at every point where the MoQ arm found a wall.
#
# There are three of those points, and this script covers each:
#
#   the intermediary   Eight MOQT relays would not forward our media. An HTTP cache is
#                      the segmented lane's equivalent hop, so put a real one (nginx
#                      proxy_cache) in the path and re-grade what comes out.
#   the client         Every other experiment here reads the lane with TSDuck, the same
#                      toolkit that wrote it. FFmpeg, VLC and a plain `curl` loop are
#                      three independent readings, and the last of them is the honest
#                      floor: a shell script with no HLS implementation at all.
#   the judge          `validate-ts.sh` is our oracle grading our output. Apple's
#                      `mediastreamvalidator` is the reference implementation of the
#                      specification, and it has no stake in our conclusions.
#
# Every capture is graded by the T11 oracle against the T11 fixture, so the rows here
# and the rows in the MoQ table mean the same thing.
set -uo pipefail

OUT=${1:-/tmp/t11seg}
REPO=${REPO:-$HOME/moq-mpegts-paper}
FIXTURE=${FIXTURE:-$REPO/interop/fixture.ts}
ORACLE=${ORACLE:-$REPO/interop/validate-ts.sh}
PORT=${PORT:-8099}
CACHE_PORT=${CACHE_PORT:-8098}
SEGDUR=${SEGDUR:-2}

[ -s "$FIXTURE" ] || { echo "t11-segmented: no fixture at $FIXTURE" >&2; exit 2; }

ORIGIN_DIR="$OUT/origin"
RESULTS="$OUT/results.txt"
rm -rf "$OUT"
mkdir -p "$ORIGIN_DIR" "$OUT/cache"
: >"$RESULTS"

ORIGIN_PID=""
NGINX_CONF="$OUT/nginx.conf"

cleanup() {
	[ -n "$ORIGIN_PID" ] && kill "$ORIGIN_PID" 2>/dev/null
	[ -f "$NGINX_CONF" ] && nginx -c "$NGINX_CONF" -s quit 2>/dev/null
	wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say() { printf '\n=== %s\n' "$*"; }

# --- package -----------------------------------------------------------------------
# A complete playlist rather than a live window: every client then has the whole
# fixture available and the comparison against it is exact. The live case is measured
# in T6, T7 and T8b; what is under test here is interoperability, not liveness.
say "packaging the T11 fixture as HLS"
tsp -I file "$FIXTURE" -O hls "$ORIGIN_DIR/seg.ts" \
	--playlist "$ORIGIN_DIR/index.m3u8" --duration "$SEGDUR" \
	--intra-close --align-first-segment >"$OUT/package.log" 2>&1
SEGS=$(find "$ORIGIN_DIR" -name 'seg-*.ts' | wc -l | tr -d ' ')
echo "packaged $SEGS segments"
[ "$SEGS" -gt 0 ] || { echo "t11-segmented: packaging produced nothing" >&2; exit 1; }

# --- origin, and a third-party cache in front of it ---------------------------------
(cd "$ORIGIN_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$OUT/origin.log" 2>&1 &
ORIGIN_PID=$!

cat >"$NGINX_CONF" <<-EOF
	worker_processes 1;
	daemon on;
	pid $OUT/nginx.pid;
	error_log $OUT/nginx.error.log;
	events { worker_connections 64; }
	http {
	  # The default log format omits the one field this arm exists to measure.
	  log_format t11 '\$request \$status \$upstream_cache_status';
	  access_log $OUT/nginx.access.log t11;
	  proxy_cache_path $OUT/cache levels=1:2 keys_zone=t11:4m max_size=256m inactive=10m;
	  server {
	    listen 127.0.0.1:$CACHE_PORT;
	    location / {
	      proxy_pass http://127.0.0.1:$PORT;
	      proxy_cache t11;
	      proxy_cache_valid 200 10m;
	      add_header X-Cache-Status \$upstream_cache_status;
	    }
	  }
	}
EOF
nginx -c "$NGINX_CONF" 2>>"$OUT/nginx.error.log" && echo "nginx cache on :$CACHE_PORT" ||
	echo "nginx failed to start; the cache arm will be skipped"

for _ in $(seq 1 30); do
	curl -fsS "http://127.0.0.1:$PORT/index.m3u8" >/dev/null 2>&1 && break
	sleep 0.3
done

# --- grade one capture with the T11 oracle ------------------------------------------
grade() { # <arm> <received.ts> <note>
	local arm=$1 file=$2 note=${3:-}
	local verdict checks bytes ident

	if [ ! -s "$file" ]; then
		printf 'ROW %-14s %-8s %s\n' "$arm" "no-data" "$note" | tee -a "$RESULTS"
		return
	fi
	bash "$ORACLE" "$file" --reference "$FIXTURE" >"$OUT/$arm.oracle.txt" 2>&1
	verdict=$(grep '^RESULT' "$OUT/$arm.oracle.txt" | awk '{print $2}')
	checks=$(grep -c '^CHECK .* pass ' "$OUT/$arm.oracle.txt")
	local total
	total=$(grep -c '^CHECK ' "$OUT/$arm.oracle.txt")
	bytes=$(wc -c <"$file" | tr -d ' ')
	ident=$(cmp -s "$file" "$FIXTURE" && echo identical || echo differs)
	printf 'ROW %-14s %-8s %s/%s checks  %s bytes  %s  %s\n' \
		"$arm" "$verdict" "$checks" "$total" "$bytes" "$ident" "$note" | tee -a "$RESULTS"
}

BASE="http://127.0.0.1:$PORT/index.m3u8"

# --- arm 1: TSDuck, the control -----------------------------------------------------
say "arm tsp — the control (same toolkit that wrote the segments)"
tsp -I hls "$BASE" -O file "$OUT/tsp.ts" >"$OUT/tsp.log" 2>&1
grade tsp "$OUT/tsp.ts" "TSDuck reading TSDuck"

# --- arm 2: FFmpeg ------------------------------------------------------------------
say "arm ffmpeg — an independent HLS implementation"
ffmpeg -nostdin -y -loglevel error -i "$BASE" -c copy -f mpegts "$OUT/ffmpeg.ts" \
	>"$OUT/ffmpeg.log" 2>&1
grade ffmpeg "$OUT/ffmpeg.ts" "remuxes, so byte-identity is not expected"

# --- arm 3: VLC ---------------------------------------------------------------------
say "arm vlc — a third independent implementation"
VLC_BIN=${VLC_BIN:-/Applications/VLC.app/Contents/MacOS/VLC}
if [ -x "$VLC_BIN" ]; then
	"$VLC_BIN" -I dummy --no-video-title-show "$BASE" \
		--sout "#standard{access=file,mux=ts,dst=$OUT/vlc.ts}" vlc://quit \
		>"$OUT/vlc.log" 2>&1
	grade vlc "$OUT/vlc.ts" "remuxes, so byte-identity is not expected"
else
	printf 'ROW %-14s %-8s %s\n' vlc skipped "VLC not found at $VLC_BIN" | tee -a "$RESULTS"
fi

# --- arm 4: no HLS client at all ----------------------------------------------------
# The floor of the interop claim. If a playlist and a `curl` loop are enough to recover
# the media, then the lane's client requirement is "an HTTP client", which is the whole
# of its interoperability argument and is worth demonstrating rather than asserting.
say "arm curl — a shell loop with no HLS implementation"
: >"$OUT/curl.ts"
while read -r seg; do
	curl -fsS "http://127.0.0.1:$PORT/$seg" >>"$OUT/curl.ts" || break
done < <(grep -v '^#' "$ORIGIN_DIR/index.m3u8" | grep '\.ts$')
grade curl "$OUT/curl.ts" "verbatim segment bytes, concatenated"

# --- arm 5: through a third-party cache ---------------------------------------------
say "arm nginx-cache — an intermediary we did not write"
if curl -fsS "http://127.0.0.1:$CACHE_PORT/index.m3u8" >/dev/null 2>&1; then
	# Count the origin's segment GETs across just these two passes, not across the whole
	# script: every other arm fetches from the origin directly, so a running total would
	# credit the cache with work it never did.
	origin_gets() { grep -c '"GET /seg' "$OUT/origin.log" 2>/dev/null || echo 0; }
	G0=$(origin_gets)

	tsp -I hls "http://127.0.0.1:$CACHE_PORT/index.m3u8" -O file "$OUT/cached.ts" \
		>"$OUT/cached.log" 2>&1
	# A second client reads the same objects. Whether the origin sees that second read at
	# all is the property the entire CDN scaling argument rests on, so measure it rather
	# than assert it.
	tsp -I hls "http://127.0.0.1:$CACHE_PORT/index.m3u8" -O file "$OUT/cached2.ts" \
		>"$OUT/cached2.log" 2>&1
	G1=$(origin_gets)

	SEGHIT=$(grep '/seg-' "$OUT/nginx.access.log" 2>/dev/null | grep -c 'HIT$' || true)
	SEGMISS=$(grep '/seg-' "$OUT/nginx.access.log" 2>/dev/null | grep -c 'MISS$' || true)
	grade nginx-cache "$OUT/cached.ts" \
		"2 client passes cost the origin $((G1 - G0)) segment GETs; cache $SEGMISS miss / $SEGHIT hit"
	grade nginx-cache2 "$OUT/cached2.ts" "the second pass, read back through the cache"
else
	printf 'ROW %-14s %-8s %s\n' nginx-cache skipped "cache not reachable" | tee -a "$RESULTS"
fi

# --- arm 6: the reference judge ------------------------------------------------------
say "arm mediastreamvalidator — Apple's reference conformance tool"
if command -v mediastreamvalidator >/dev/null; then
	mediastreamvalidator --validation-data-path "$OUT/msv.json" "$BASE" \
		>"$OUT/msv.txt" 2>&1
	MSV_ERR=$(grep -ciE '^ *error|ERROR:' "$OUT/msv.txt" || true)
	MSV_WARN=$(grep -ciE '^ *warning|WARNING:' "$OUT/msv.txt" || true)
	printf 'ROW %-14s %-8s %s errors, %s warnings\n' \
		mediastreamvalidator "$([ "${MSV_ERR:-0}" -eq 0 ] && echo pass || echo fail)" \
		"${MSV_ERR:-0}" "${MSV_WARN:-0}" | tee -a "$RESULTS"
else
	printf 'ROW %-14s %-8s %s\n' mediastreamvalidator skipped "not installed" | tee -a "$RESULTS"
fi

say "results"
cat "$RESULTS"
echo
echo "artefacts in $OUT"
