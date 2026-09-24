#!/usr/bin/env bash
# T25 / P2-b, the segmented half — can one abusive client degrade the others on an HLS origin?
#
# [T25](../test-25-isolation-under-abuse.md) asked this of the MoQ relay and found the media plane
# isolated, with the cost showing up instead as relay memory: abandoned sessions retained until the
# QUIC idle timeout drove RSS from 87 MB to 1.9 GB. The segmented lane has never been asked. It
# could not be graded before P0-e, because a victim's continuity is the measurement and the
# previous receiver reported zero continuity errors regardless of what arrived (T42).
#
# The arms are chosen to map onto T25's rather than to be exhaustive, so the two lanes answer the
# same question:
#
#   control  three victims, nothing else                      -- the reference
#   churn    connections opened and killed 0.3 s later        -- T25's `churn`: abandoned state
#   slow     clients that read one byte a second and stall    -- T25's `slow`: backpressure
#   flood    unthrottled parallel segment fetches             -- bandwidth contention, no MoQ analogue
#
# A victim is graded on exactly what T25 graded: delivered bytes against the control, continuity
# errors, and holes. The origin is graded on RSS, which is where T25's cost actually appeared.
#
# Usage: t25-segmented-abuse.sh <label> <control|churn|slow|flood> [window_s]
set -u

LABEL="${1:?usage: t25-segmented-abuse.sh <label> <control|churn|slow|flood> [window_s]}"
ARM="${2:?arm: control|churn|slow|flood}"
WINDOW="${3:-60}"

SRC="${SRC:-$HOME/CNNiEMEA2.ts}"
HLS_DIR=/srv/hls/t25seg
URLBASE=t25seg
RUN="$HOME/t25seg/$LABEL-$ARM"
CURL="${CURL:-$HOME/h3/bin/curl}"
RECV="${RECV:-$HOME/hls-verbatim-recv.py}"
H3=8444
VICTIMS=3
ABUSERS="${ABUSERS:-12}"
SEGDUR=2

mkdir -p "$RUN"
LOG="$RUN/run.log"
: >"$LOG"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

KIDS=()
cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	pkill -9 -f "t25seg[.]abuse" 2>/dev/null
	pkill -9 -f "t25seg[.]pack" 2>/dev/null
}
trap cleanup EXIT INT TERM

if pgrep -f "t25seg[.]pack" >/dev/null 2>&1; then
	echo "FAIL: a packager from a previous pass is still running" >&2
	exit 1
fi

sudo mkdir -p "$HLS_DIR"
sudo chown "$(id -u):$(id -g)" "$HLS_DIR"
rm -f "${HLS_DIR:?}"/*

log "arm=$ARM window=${WINDOW}s victims=$VICTIMS abusers=$ABUSERS"

tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
	-O hls --live 6 --live-extra-segments 3 --duration "$SEGDUR" --intra-close \
	--align-first-segment --playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/t25seg.pack.ts" \
	>>"$LOG" 2>&1 &
PACK=$!
KIDS+=("$PACK")
for _ in $(seq 1 90); do
	[ "$(find "$HLS_DIR" -name 't25seg.pack*.ts' | wc -l)" -ge 4 ] && break
	sleep 1
done
kill -0 "$PACK" 2>/dev/null || {
	log "FATAL: packager died"
	exit 2
}

nginx_rss() { ps -o rss= -C nginx 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s/1024}'; }
RSS0=$(nginx_rss)

URL="https://127.0.0.1:$H3/$URLBASE/index.m3u8"

# --- victims: the measurement ----------------------------------------------------------------
VICTIM_PIDS=()
for v in $(seq 1 $VICTIMS); do
	python3 "$RECV" "$URL" -o "$RUN/victim$v.ts" --http-version 3 --curl "$CURL" \
		--insecure --seconds "$WINDOW" --summary "$RUN/victim$v.json" \
		>"$RUN/victim$v.log" 2>&1 &
	VICTIM_PIDS+=("$!")
	KIDS+=("$!")
done

# --- abuse ------------------------------------------------------------------------------------
# Every abuser is tagged t25seg.abuse so cleanup can find it without matching this script.
start_abuse() {
	case "$ARM" in
	control) log "control: no abuse" ;;
	churn)
		for _ in $(seq 1 "$ABUSERS"); do
			(
				exec -a "t25seg.abuse-churn" bash -c '
					while :; do
						'"$CURL"' -ks --http3-only --max-time 30 "'"$URL"'" >/dev/null 2>&1 &
						p=$!; sleep 0.3; kill -9 $p 2>/dev/null
					done'
			) &
			KIDS+=("$!")
		done
		log "churn: $ABUSERS loops opening and killing connections every 0.3 s"
		;;
	slow)
		for _ in $(seq 1 "$ABUSERS"); do
			(
				exec -a "t25seg.abuse-slow" "$CURL" -ks --http3-only --limit-rate 1 \
					--max-time "$((WINDOW + 30))" "$URL" >/dev/null 2>&1
			) &
			KIDS+=("$!")
		done
		log "slow: $ABUSERS clients rate-limited to 1 B/s"
		;;
	flood)
		for _ in $(seq 1 "$ABUSERS"); do
			(
				exec -a "t25seg.abuse-flood" bash -c '
					while :; do '"$CURL"' -ks --http3-only --max-time 10 "'"$URL"'" >/dev/null 2>&1; done'
			) &
			KIDS+=("$!")
		done
		log "flood: $ABUSERS unthrottled fetch loops"
		;;
	*)
		log "unknown arm $ARM"
		exit 2
		;;
	esac
}
start_abuse

RSSMAX=$RSS0
END=$(($(date +%s) + WINDOW + 5))
while [ "$(date +%s)" -lt "$END" ]; do
	r=$(nginx_rss)
	awk -v a="$r" -v b="$RSSMAX" 'BEGIN{exit !(a>b)}' && RSSMAX=$r
	sleep 1
done

# Wait on the victims only. A bare `wait` also waits for the packager, which runs --infinite,
# and for the abuse loops, which are `while :` -- so it never returns. That hung a whole pass.
for p in "${VICTIM_PIDS[@]}"; do wait "$p" 2>/dev/null; done
RSS1=$(nginx_rss)

# --- grading ------------------------------------------------------------------------------------
{
	echo "label=$LABEL arm=$ARM window=$WINDOW victims=$VICTIMS abusers=$ABUSERS"
	for v in $(seq 1 $VICTIMS); do
		b=$(stat -c%s "$RUN/victim$v.ts" 2>/dev/null || echo 0)
		cc=$(tsp -I file "$RUN/victim$v.ts" -P continuity -O drop 2>&1 |
			grep -cE 'missing .* packets|discontinuity' || true)
		h=$(python3 -c "import json;print(len(json.load(open('$RUN/victim$v.json'))['holes']))" 2>/dev/null || echo -1)
		echo "victim$v bytes=$b cc_errors=$cc holes=$h"
	done
	echo "nginx_rss_start_mb=$RSS0 nginx_rss_peak_mb=$RSSMAX nginx_rss_end_mb=$RSS1"
} | tee "$RUN/result" | tee -a "$LOG"
