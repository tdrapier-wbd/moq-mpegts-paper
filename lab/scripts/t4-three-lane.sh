#!/usr/bin/env bash
# T4 three-lane arm — one MPEG-TS, one origin, one internet path, three data planes.
#
#   t4-three-lane.sh <moq|srt|hls> <out-dir> [media_seconds]
#
# Each lane carries the SAME clip from the SAME EC2 origin to this workstation,
# paced by the same `tsp regulate --pcr-synchronous`, bounded by the same packet
# count, and scored by the same instrument (t3-transparency.py). A side-by-side
# assembled from three separately-designed measurements is not a comparison, so
# the three lanes differ in exactly one thing: the transport between the two ends.
#
#   moq  media-aware lane: tsp -> moq import ts -> relay (UDP 443) -> moq export ts
#   srt  byte-faithful:    tsp -> tsp -O srt (UDP 9010) -> tsp -I srt
#   hls  segmented HTTP:   tsp -> tsp -O hls + static origin (TCP) -> tsp -I hls
#
# The measurement point is the UNGROOMED egress for every lane, matching T3. The
# question here is whether the mux survived the path, not whether it can be
# re-paced afterwards; T7/T13/T16 own the groomed versions.
#
# Bounded by PACKET COUNT, not wall clock. `tsp -I hls --live` drains the live
# window faster than real time before it settles, so equal wall-clock windows
# carry unequal amounts of media and no count taken in them can be compared
# across lanes. Each lane is captured generously and then trimmed to exactly
# NPKT packets, which is what makes the three columns commensurable.
#
# Environment (real values in INSTRUCTIONS.local.md §7 — never hardcode them here):
#   ORIGIN=user@host  PEM=<ssh key>  [REMOTE_MOQ] [REMOTE_CLIP] [LOCAL_MOQ]
#   [LOCAL_CLIP] [HLS_PORT] [SRT_PORT] [SEGSECS] [SETTLE]
#
# The remote sender is torn down by process GROUP, using the pid this script
# started. Never pkill by name on that box: the standing relay and both standing
# publishers are `tsp`/`moq`/`ffmpeg` processes too, and the campaign rule is to
# leave them exactly as found.
set -euo pipefail

LANE=${1:?lane: moq | srt | hls}
OUT=${2:?output dir}
SECS=${3:-30}

ORIGIN=${ORIGIN:?set ORIGIN=user@host (INSTRUCTIONS.local.md §7)}
PEM=${PEM:?set PEM=path to the ssh key}
HOST=${ORIGIN#*@}
REMOTE_MOQ=${REMOTE_MOQ:-/home/ubuntu/bin-main-eab96019/moq}
REMOTE_CLIP=${REMOTE_CLIP:-/home/ubuntu/CNNiEMEA2.ts}
LOCAL_MOQ=${LOCAL_MOQ:-$HOME/bin-main/moq}
LOCAL_CLIP=${LOCAL_CLIP:-$HOME/CNNiEMEA2.ts}
HLS_PORT=${HLS_PORT:-8080}
SRT_PORT=${SRT_PORT:-9010}
SEGSECS=${SEGSECS:-2}
SETTLE=${SETTLE:-8}
MOQ_LATENCY=${MOQ_LATENCY:-3s}
SRT_LATENCY=${SRT_LATENCY:-2000}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

case "$LANE" in
moq | srt | hls) ;;
*)
	echo "lane must be moq, srt or hls" >&2
	exit 1
	;;
esac
command -v tsp >/dev/null || {
	echo "tsp not found" >&2
	exit 1
}
[ -f "$LOCAL_CLIP" ] || {
	echo "no local reference clip: $LOCAL_CLIP" >&2
	exit 1
}

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$PEM" "$ORIGIN")
rm -rf "$OUT"
mkdir -p "$OUT"

# --- packet bound, from the clip's own PCR timeline ----------------------------
# Media rather than wall time, and taken from the local copy so the bound is
# identical for every lane regardless of which end computed it.
SRCBPS=$(tsp -I file "$LOCAL_CLIP" -P until --packets 200000 -P analyze --normalized -O drop 2>/dev/null |
	sed -n 's/^ts:.*:pcrbitrate=\([0-9]*\):.*/\1/p' | head -1)
[ -n "$SRCBPS" ] || {
	echo "could not derive source PCR bitrate" >&2
	exit 1
}
NPKT=$((SRCBPS * SECS / 8 / 188))
CAP_S=$((SECS + 60))
RMAX=$((SECS + 150))
echo "lane=$LANE source=${SRCBPS} b/s (PCR-derived) ${SECS}s = ${NPKT} packets"

# --- the remote sender --------------------------------------------------------
# A fresh broadcast name per run: restarting an import under a name the relay has
# already seen can leave a stale announce, and the subscriber then receives only
# catalog.json and stalls at zero bytes (INSTRUCTIONS.local.md §7).
BCAST="t4.3lane.$$.hang"
RTMP="/tmp/t4-3lane-$$"
PACE="tsp --realtime -I file $REMOTE_CLIP --infinite -P regulate --pcr-synchronous"

{
	echo '#!/usr/bin/env bash'
	echo 'set -euo pipefail'
	case "$LANE" in
	moq)
		echo "$PACE -O file - \\"
		echo "  | $REMOTE_MOQ --client-tls-disable-verify \\"
		echo "      --client-connect https://localhost:443/anon \\"
		echo "      --broadcast $BCAST import ts"
		;;
	srt)
		echo "$PACE \\"
		echo "  -O srt --listener 0.0.0.0:$SRT_PORT --transtype live --latency $SRT_LATENCY"
		;;
	hls)
		# --intra-close starts each segment on an I-frame; the plugin writes a
		# PAT/PMT pair at every segment head (the spec's Media Initialization
		# Section), which is the addition this lane is scored against. --live
		# bounds the directory so a long run cannot fill the box's 6 GB of free
		# disk.
		echo "D=$RTMP/hls"
		echo 'mkdir -p "$D"'
		echo "$PACE \\"
		echo '  -O hls "$D/seg.ts" --playlist "$D/index.m3u8" \'
		echo "  --duration $SEGSECS --live 6 --live-extra-segments 3 \\"
		echo "  --intra-close --align-first-segment &"
		echo 'cd "$D"'
		echo "exec python3 -m http.server $HLS_PORT --bind 0.0.0.0"
		;;
	esac
} >"$OUT/remote.sh"

RPID=""
cleanup() {
	if [ -n "$RPID" ]; then
		# Negative pid = the process group setsid created, so the paced reader,
		# the importer/segmenter and the origin all go together.
		"${SSH[@]}" "kill -TERM -$RPID 2>/dev/null || kill -TERM $RPID 2>/dev/null || true" || true
		scp -q -o ConnectTimeout=10 -i "$PEM" "$ORIGIN:$RTMP/send.log" "$OUT/send.log" 2>/dev/null || true
		"${SSH[@]}" "rm -rf $RTMP" 2>/dev/null || true
	fi
}
trap cleanup EXIT

"${SSH[@]}" "mkdir -p $RTMP"
scp -q -o ConnectTimeout=10 -i "$PEM" "$OUT/remote.sh" "$ORIGIN:$RTMP/remote.sh"
RPID=$("${SSH[@]}" "chmod +x $RTMP/remote.sh; setsid nohup timeout $RMAX $RTMP/remote.sh \
	>$RTMP/send.log 2>&1 </dev/null & echo \$!")
[ -n "$RPID" ] || {
	echo "remote sender did not start" >&2
	exit 1
}
PUB_START=$(date +%s)
echo "remote sender pid $RPID (group), broadcast $BCAST"

# --- wait until there is something to join ------------------------------------
if [ "$LANE" = hls ]; then
	# `tsp -I hls` exits on an empty playlist, so the live window has to be
	# filled before the receiver starts.
	echo "waiting for the live window to fill..."
	for _ in $(seq 1 90); do
		n=$(curl -sf --max-time 5 "http://$HOST:$HLS_PORT/index.m3u8" 2>/dev/null |
			grep -c '\.ts$' || true)
		[ "${n:-0}" -ge 3 ] && break
		sleep 1
	done
	curl -sf --max-time 5 "http://$HOST:$HLS_PORT/index.m3u8" >"$OUT/playlist-sample.m3u8" 2>/dev/null || true
	[ -s "$OUT/playlist-sample.m3u8" ] || {
		echo "no playlist reachable at http://$HOST:$HLS_PORT/ — is the TCP port open in the security group?" >&2
		exit 1
	}
	LAG_S=$((SEGSECS * 3))
else
	sleep "$SETTLE"
	case "$LANE" in
	moq) LAG_S=3 ;;
	srt) LAG_S=2 ;;
	esac
fi

# --- capture, generously, then trim to the packet bound -----------------------
JOIN=$(date +%s)
echo "capturing (bound ${NPKT} packets, ceiling ${CAP_S}s)..."
set +e
case "$LANE" in
moq)
	timeout "$CAP_S" "$LOCAL_MOQ" --client-tls-disable-verify \
		--client-connect "https://$HOST:443/anon" \
		--broadcast "$BCAST" export ts --latency-max "$MOQ_LATENCY" \
		>"$OUT/raw.ts" 2>"$OUT/receive.log"
	;;
srt)
	timeout "$CAP_S" tsp --realtime \
		-I srt --caller "$HOST:$SRT_PORT" --transtype live --latency "$SRT_LATENCY" \
		-P until --packets "$NPKT" \
		-O file "$OUT/raw.ts" >"$OUT/receive.log" 2>&1
	;;
hls)
	timeout "$CAP_S" tsp --realtime \
		-I hls "http://$HOST:$HLS_PORT/index.m3u8" --live \
		-P until --packets "$NPKT" \
		-O file "$OUT/raw.ts" >"$OUT/receive.log" 2>&1
	;;
esac
set -e

[ -s "$OUT/raw.ts" ] || {
	echo "no egress captured; see $OUT/receive.log and $OUT/send.log" >&2
	exit 1
}
GOT=$(($(wc -c <"$OUT/raw.ts") / 188))
echo "captured ${GOT} packets"
[ "$GOT" -ge "$NPKT" ] || {
	echo "short capture: ${GOT} < ${NPKT} packets — the window is not comparable with the other lanes" >&2
	exit 1
}
tsp -I file "$OUT/raw.ts" -P until --packets "$NPKT" -O file "$OUT/egress.ts" >/dev/null 2>&1

# --- source reference, aligned to the media the receiver actually joined ------
# A cut from position 0 is only a valid reference if the mux is homogeneous, and
# these clips are not (T3: testloop_clean carries 18.4 % stuffing over its first
# 60 s against 13.1-13.8 % later). The sender starts at position 0 and paces off
# the source PCR, so its position at the join is its elapsed run time, less the
# lane's own buffer or live window.
ELAPSED=$((JOIN - PUB_START))
REF_SKIP_S=$((ELAPSED - LAG_S))
[ "$REF_SKIP_S" -lt 0 ] && REF_SKIP_S=0
REF_SKIP=$((SRCBPS * REF_SKIP_S / 8 / 188))
echo "sender ran ${ELAPSED}s before the join; reference offset ${REF_SKIP_S}s (${REF_SKIP} packets)"
tsp -I file "$LOCAL_CLIP" \
	-P skip --packets "$REF_SKIP" \
	-P until --packets "$NPKT" \
	-O file "$OUT/source-ref.ts" >/dev/null 2>&1

{
	echo "lane=$LANE"
	echo "packets_requested=$NPKT"
	echo "packets_captured=$GOT"
	echo "source_pcrbitrate=$SRCBPS"
	echo "reference_skip_packets=$REF_SKIP"
	echo "reference_skip_seconds=$REF_SKIP_S"
	echo "join_lag_seconds=$LAG_S"
	[ "$LANE" = hls ] && echo "segment_target_s=$SEGSECS"
	[ "$LANE" = hls ] && echo "segment_mean_extinf_s=$(awk -F: '/^#EXTINF/ {gsub(/,.*/, "", $2); s += $2; n++}
		END {if (n) printf "%.3f", s / n}' "$OUT/playlist-sample.m3u8" 2>/dev/null || true)"
	echo "broadcast=$BCAST"
} >"$OUT/run.env"

echo
python3 "$SCRIPTS/t3-transparency.py" "$OUT/source-ref.ts" "$OUT/egress.ts" \
	--label "$LANE" --run-env "$OUT/run.env" | tee "$OUT/report.txt"

echo
echo "artefacts in $OUT: egress.ts source-ref.ts report.txt run.env"
