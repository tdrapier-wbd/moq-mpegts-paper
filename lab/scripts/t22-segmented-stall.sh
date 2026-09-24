#!/usr/bin/env bash
# T22 / P0-f, the segmented half — when the feed stops, what does the segmented lane say?
#
# [T22](../test-22-silent-media-plane-failure.md) measured this on the media-aware lane and found
# the transport silent: with the source frozen for 120 s, publisher, relay and exporter logged
# nothing at all, and only the media plane noticed. The segmented lane has never been asked, and
# it could not be until P0-e's byte-faithful receiver existed, because the previous receiver
# re-muxes and would have manufactured a continuous stream out of a stalled one.
#
# The mechanism is deliberately identical to T22's: `SIGSTOP` on the source. The process exists,
# its sockets stay open, nothing is closed and nothing errors — which is the point, because a
# crash is the easy case and every alarm already catches it.
#
# Arms:
#   control   the source runs untouched for the whole window     -- the null
#   input     the packager's source freezes for stall_s          -- T22's `input` arm
#   origin    nginx is stopped for stall_s                       -- transport failure, for contrast
#
# What is being counted, at four observation points, because the question is *which layer notices*:
#   origin    does nginx log anything other than 200s?
#   playlist  does the media sequence stop advancing, and how soon is that visible?
#   receiver  does the byte-faithful receiver error, or return a short stream quietly?
#   media     does the delivered stream actually stop carrying programme?
#
# Usage: t22-segmented-stall.sh <label> <control|input|origin> [stall_s] [window_s]
set -u

LABEL="${1:?usage: t22-segmented-stall.sh <label> <control|input|origin> [stall_s] [window_s]}"
ARM="${2:?arm: control|input|origin}"
STALL="${3:-30}"
WINDOW="${4:-70}"

SRC="${SRC:-$HOME/CNNiEMEA2.ts}"
HLS_DIR=/srv/hls/t22seg
URLBASE=t22seg
RUN="$HOME/t22seg/$LABEL-$ARM"
CURL="${CURL:-$HOME/h3/bin/curl}"
RECV="${RECV:-$HOME/hls-verbatim-recv.py}"
NGINX_LOG=/var/log/nginx/h3lab.log
H3=8444
STALL_AT="${STALL_AT:-20}"
SEGDUR=2

mkdir -p "$RUN"
LOG="$RUN/run.log"
: >"$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

cleanup() {
	# A SIGSTOPped process cannot be killed, so continue everything before killing it.
	pkill -CONT -f "t22seg[.]pack" 2>/dev/null
	pkill -9 -f "t22seg[.]pack" 2>/dev/null
	sudo systemctl start nginx 2>/dev/null
}
trap cleanup EXIT INT TERM

if pgrep -f "t22seg[.]pack" >/dev/null 2>&1; then
	echo "FAIL: a packager from a previous pass is still running" >&2
	pgrep -af "t22seg[.]pack" >&2
	exit 1
fi

sudo mkdir -p "$HLS_DIR"
sudo chown "$(id -u):$(id -g)" "$HLS_DIR"
rm -f "${HLS_DIR:?}"/*
sudo systemctl start nginx 2>/dev/null
sudo truncate -s 0 "$NGINX_LOG" 2>/dev/null

log "arm=$ARM stall=${STALL}s at t=${STALL_AT}s window=${WINDOW}s"

# The tag `t22seg.pack` is only there to be matched by pgrep without matching this script.
tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
	-O hls --live 6 --live-extra-segments 3 --duration "$SEGDUR" --intra-close \
	--align-first-segment --playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/t22seg.pack.ts" \
	>>"$LOG" 2>&1 &
PACK=$!

for _ in $(seq 1 90); do
	[ "$(find "$HLS_DIR" -name 't22seg.pack*.ts' | wc -l)" -ge 4 ] && break
	sleep 1
done
if ! kill -0 "$PACK" 2>/dev/null; then
	log "FATAL: packager died before the window filled"
	exit 2
fi
log "live window filled; packager pid=$PACK"

# --- observer: sample the playlist once a second, independently of the receiver ------------
# The receiver is one consumer's view. The playlist is what every consumer sees, so it is
# sampled separately: an operator watching for liveness would watch this, not a decoder.
(
	while :; do
		now=$(date +%s.%N)
		body=$("$CURL" -ks --http3-only --max-time 3 "https://127.0.0.1:$H3/$URLBASE/index.m3u8" 2>/dev/null)
		rc=$?
		seq=$(printf '%s' "$body" | sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9]*\)/\1/p')
		nseg=$(printf '%s' "$body" | grep -c '^[^#]' || true)
		echo "$now rc=$rc seq=${seq:--1} segs=$nseg" >>"$RUN/playlist.log"
		sleep 1
	done
) &
OBS=$!

python3 "$RECV" "https://127.0.0.1:$H3/$URLBASE/index.m3u8" -o "$RUN/out.ts" \
	--http-version 3 --curl "$CURL" --insecure --seconds "$WINDOW" \
	--summary "$RUN/recv.json" >"$RUN/recv.log" 2>&1 &
RX=$!

sleep "$STALL_AT"
# Recorded so the playlist samples can be aligned to the injection after the fact.
echo "stall_injected_at=$(date +%s.%N)" >>"$RUN/playlist.log"
case "$ARM" in
control) log "control: nothing injected" ;;
input)
	log "SIGSTOP the packager"
	kill -STOP "$PACK"
	sleep "$STALL"
	kill -CONT "$PACK"
	log "SIGCONT the packager after ${STALL}s"
	;;
origin)
	log "stopping nginx"
	sudo systemctl stop nginx
	sleep "$STALL"
	sudo systemctl start nginx
	log "nginx restarted after ${STALL}s"
	;;
*)
	log "unknown arm $ARM"
	exit 2
	;;
esac

wait "$RX" 2>/dev/null
RXRC=$?
kill "$OBS" 2>/dev/null

# --- grading ---------------------------------------------------------------------------------
bytes=$(stat -c%s "$RUN/out.ts" 2>/dev/null || echo 0)
cc=$(tsp -I file "$RUN/out.ts" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
media=$(tsp -I file "$RUN/out.ts" -P pcrextract --pcr --csv -o "$RUN/pcr.csv" -O drop >/dev/null 2>&1
awk -F, 'NR>1{c=$7; if(f=="")f=c; p=c} END{printf "%.1f", (p-f)/27000000}' "$RUN/pcr.csv" 2>/dev/null || echo 0)
holes=$(python3 -c "import json;print(len(json.load(open('$RUN/recv.json'))['holes']))" 2>/dev/null || echo -1)

# Did the origin say anything that was not a success? That is the question T22 asked of the
# MoQ transport and got silence for.
nonok=$(sudo awk '{for(i=1;i<=NF;i++) if($i ~ /^status=/ && $i !~ /^status=200/) print}' "$NGINX_LOG" 2>/dev/null | wc -l)
total=$(sudo grep -c . "$NGINX_LOG" 2>/dev/null || echo 0)

# How long did the playlist's media sequence stay frozen? This is the segmented lane's
# equivalent of "time until something observable changed".
#
# Everything before the FIRST advance is discarded. While the live window is still filling,
# nothing has rolled off yet and the media sequence legitimately sits at 0 — 8.1 s of it on this
# packager. Counting that as a freeze puts an 8.1 s floor under the control and makes a real
# 30 s stall look like a 3.8x change instead of the step it is. Steady-state cadence is the
# only meaningful baseline.
frozen=$(awk '
	{
		ts=$1; q=-1; rc=0
		for(i=1;i<=NF;i++){ if($i ~ /^seq=/){ split($i,s,"="); q=s[2]+0 } if($i ~ /^rc=/){ split($i,r,"="); rc=r[2]+0 } }
		if(rc!=0) err++
		if(q<0) next
		if(prev==""){ prev=q; next }
		if(q!=prev){ started=1; if(fs!=""){ d=ts-fs; if(d>maxd) maxd=d } fs=ts; prev=q; next }
		if(started && fs=="") fs=ts
	}
	END{ printf "%.1f %d", maxd+0, err+0 }' "$RUN/playlist.log" 2>/dev/null)

{
	echo "label=$LABEL arm=$ARM stall_s=$STALL window_s=$WINDOW"
	echo "bytes=$bytes media_seconds=$media cc_errors=$cc"
	echo "recv_rc=$RXRC recv_holes=$holes"
	echo "origin_requests=$total origin_non200=$nonok"
	echo "playlist_frozen_s=${frozen% *} playlist_fetch_errors=${frozen#* }"
} | tee "$RUN/result" | tee -a "$LOG"
