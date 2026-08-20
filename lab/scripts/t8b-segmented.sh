#!/usr/bin/env bash
# T8b, segmented-HTTP arm — one condition through the shaped netns rig.
#
#   sudo ./t8b-segmented.sh <label> [secs]
#
# T8b's C1 asks what a fixed, non-congestion-responsive feed does when the pipe is
# half its size, and the answer has so far been two distinct shapes: MoQ thins the
# stream (drops whole groups, 0 continuity errors, 45-81 % of the cap) and SRT keeps
# the bytes but damages them (90 % of the cap, 4,279 continuity errors). Segment
# fetching cannot do either. It has no group to drop and no packet to lose; what it
# has is a live window, and a client that cannot keep up walks backwards through it
# until segments expire.
#
# So the metric that matters here is not only the delivered fraction. It is **how far
# behind the live edge the client is** and **whether it lost whole segments getting
# there** — the sequence numbers in the playlist say both, and neither a continuity
# check nor a rate figure can. The origin's own log is the record of which segments
# were asked for, so a gap in the fetched sequence is a segment the client skipped
# because it had already expired.
#
# Same rig, cap, base delay, queue, clip and window as every other T8b arm.
set -uo pipefail

LABEL="${1:-seg}"
SECS="${2:-60}"

CLIP=${CLIP:-/home/ubuntu/CNNiEMEA2.ts}
PUBIP=${PUBIP:-10.99.0.1}
DIR=${DIR:-/home/ubuntu/t8b/out}
PORT=${PORT:-8099}
SEGSECS=${SEGSECS:-2}
CAP_MBIT=${CAP_MBIT:-5}
SRC_BPS=${SRC_BPS:-9945951}

RUN="$DIR/$LABEL"
CAP="$RUN.ts"
RTT="$RUN.rtt.csv"
HLS="$DIR/$LABEL.hls"

rm -rf "$HLS"
mkdir -p "$HLS" "$DIR"

cleanup() {
	kill "${PUB:-}" "${ORIGIN:-}" "${PROBE:-}" 2>/dev/null
	wait 2>/dev/null || true
}
trap cleanup EXIT

# Publisher and origin both live in the pub namespace, so the only path between the
# packager and the client is the shaped one.
ip netns exec t8b-pub bash -c \
	"tsp -I file $CLIP --infinite -P regulate --pcr-synchronous \
	 -O hls $HLS/seg.ts --playlist $HLS/index.m3u8 --duration $SEGSECS \
	 --live 6 --live-extra-segments 3 --intra-close --align-first-segment" \
	>"$RUN.pub.log" 2>&1 &
PUB=$!

ip netns exec t8b-pub bash -c \
	"cd $HLS && exec python3 -m http.server $PORT --bind $PUBIP" \
	>"$RUN.origin.log" 2>&1 &
ORIGIN=$!

for _ in $(seq 1 90); do
	[ -f "$HLS/index.m3u8" ] &&
		[ "$(grep -c '\.ts$' "$HLS/index.m3u8" 2>/dev/null || echo 0)" -ge 3 ] && break
	sleep 1
done
[ -f "$HLS/index.m3u8" ] || { echo "$LABEL: no playlist; see $RUN.pub.log" >&2; exit 1; }

# The live edge as the client joins, so the lag at the end can be measured against it.
FIRST_MEDIA_SEQ=$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9]*\)/\1/p' "$HLS/index.m3u8" | tail -1)
: "${FIRST_MEDIA_SEQ:=0}"

: >"$RTT"
ip netns exec t8b-sub ping -n -D -i 0.2 -c $((SECS * 5)) "$PUBIP" 2>/dev/null |
	awk -F"time=" '/time=/{ts=$1;sub(/^\[/,"",ts);sub(/\].*/,"",ts);r=$2;sub(/ *ms.*/,"",r);print ts","r}' >>"$RTT" &
PROBE=$!

# RECV separates the lane from the client. `tsp` is the off-the-shelf reading and it
# dies on the first 404; `pull` is T6's minimal client, whose only real feature is
# that it retries and re-anchors to the live edge — which is the degradation this
# lane is entitled to under the specification and does not get from either shipped
# client.
case ${RECV:-tsp} in
pull)
	ip netns exec t8b-sub python3 "${PULL:-/home/ubuntu/t8b/t6-hls-pull.py}" \
		"http://${PUBIP}:${PORT}/index.m3u8" "$CAP" --seconds "$SECS" \
		>"$RUN.sub.log" 2>&1
	;;
*)
	ip netns exec t8b-sub bash -c \
		"tsp -I hls http://${PUBIP}:${PORT}/index.m3u8 --live -P until --seconds $SECS -O file $CAP" \
		>"$RUN.sub.log" 2>&1
	;;
esac

LAST_MEDIA_SEQ=$(sed -n 's/^#EXT-X-MEDIA-SEQUENCE:\([0-9]*\)/\1/p' "$HLS/index.m3u8" | tail -1)
: "${LAST_MEDIA_SEQ:=0}"
cp "$HLS/index.m3u8" "$RUN.playlist.m3u8" 2>/dev/null

kill "$PUB" "$ORIGIN" "$PROBE" 2>/dev/null
sleep 0.5

BYTES=$(stat -c%s "$CAP" 2>/dev/null || echo 0)
GP=$(awk -v b="$BYTES" -v s="$SECS" 'BEGIN{printf "%.2f", b*8/s/1e6}')
PCT=$(awk -v g="$GP" -v c="$CAP_MBIT" 'BEGIN{printf "%.0f", g/c*100}')
SRCPCT=$(awk -v b="$BYTES" -v s="$SECS" -v r="$SRC_BPS" 'BEGIN{printf "%.0f", (b*8/s)/r*100}')
CCE=$(tsp -I file "$CAP" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
: "${CCE:=0}"

PCR="pcr_max_ms=0 pcr_over40=0"
tsp -I file "$CAP" -P pcrextract --pcr --csv -o "$RUN.pcr.csv" -O drop >/dev/null 2>&1
[ -s "$RUN.pcr.csv" ] && PCR=$(awk -F, 'NR>1 && $6!=""{c=$6+0; if(p!=""){d=(c-p)/27000;
	if(d>0){n++; if(d>mx)mx=d; if(d>40)o++}} p=c}
	END{printf "pcr_max_ms=%.2f pcr_over40=%d", mx, o}' "$RUN.pcr.csv")

# Which segments the client actually *got*, counting only the requests the origin
# served. A 404 here is the failure mode specific to this lane: the client has fallen
# so far behind that the segment it is asking for has already been deleted from the
# live window. No rate figure and no continuity check can see that coming.
served() { grep '"GET' "$RUN.origin.log" 2>/dev/null | grep ' 200 -$'; }
SEGS_OK=$(served | grep -oE 'seg-[0-9]+\.ts' | sort -u | wc -l)
SEG_FIRST=$(served | grep -oE 'seg-[0-9]+\.ts' | grep -oE '[0-9]+' | sort -n | head -1)
SEG_LAST=$(served | grep -oE 'seg-[0-9]+\.ts' | grep -oE '[0-9]+' | sort -n | tail -1)
: "${SEGS_OK:=0}" "${SEG_FIRST:=0}" "${SEG_LAST:=0}"
# Segment names are zero-padded, which the shell reads as octal — and `09` is not
# even valid octal, so this fails loudly on some runs and silently on others.
SEG_FIRST=$((10#$SEG_FIRST))
SEG_LAST=$((10#$SEG_LAST))
SEG_SPAN=$((SEG_LAST - SEG_FIRST + 1))
SEG_GAPS=$((SEG_SPAN - SEGS_OK))
[ "$SEG_GAPS" -lt 0 ] && SEG_GAPS=0

HTTP_404=$(grep '"GET /seg' "$RUN.origin.log" 2>/dev/null | grep -c ' 404 -$' || true)
: "${HTTP_404:=0}"

# When the window outran the client, in seconds from its first served segment. The
# origin's log is the clock: it is the only party that sees both the request and the
# fact that the file was already gone.
SURVIVED=$(python3 - "$RUN.origin.log" <<-'PY'
	import re, sys, datetime
	first_ok = first_404 = None
	for line in open(sys.argv[1], errors="ignore"):
	    m = re.search(r'\[(\d+/\w+/\d+ \d+:\d+:\d+)\].*"GET /seg[^"]*" (\d+)', line)
	    if not m:
	        continue
	    t = datetime.datetime.strptime(m.group(1), "%d/%b/%Y %H:%M:%S")
	    if m.group(2) == "200" and first_ok is None:
	        first_ok = t
	    if m.group(2) == "404" and first_404 is None:
	        first_404 = t
	print(int((first_404 - first_ok).total_seconds()) if first_ok and first_404 else -1)
PY
)
: "${SURVIVED:=-1}"

# How far the client ended up behind the edge, in segments the publisher moved on by.
PUBLISHED=$((LAST_MEDIA_SEQ - FIRST_MEDIA_SEQ))
LAG_SEGS=$((LAST_MEDIA_SEQ - SEG_LAST))
[ "$LAG_SEGS" -lt 0 ] && LAG_SEGS=0
LAG_S=$((LAG_SEGS * SEGSECS))

RP50=$(awk -F, '$2!=""{v[n++]=$2+0} END{if(n){asort(v);printf "%.0f",v[int(n*0.5)]}else print "NA"}' "$RTT")
RP95=$(awk -F, '$2!=""{v[n++]=$2+0} END{if(n){asort(v);printf "%.0f",v[int(n*0.95)]}else print "NA"}' "$RTT")

echo "RESULT arm=segmented recv=${RECV:-tsp} label=$LABEL secs=$SECS cap_mbit=$CAP_MBIT bytes=$BYTES mbps=$GP" \
	"pct_of_cap=$PCT pct_of_source=$SRCPCT cc_disc=$CCE $PCR segs_ok=$SEGS_OK seg_span=$SEG_SPAN" \
	"seg_gaps=$SEG_GAPS segs_published=$PUBLISHED lag_segs=$LAG_SEGS lag_s=$LAG_S" \
	"http_404=$HTTP_404 survived_s=$SURVIVED rtt_p50=$RP50 rtt_p95=$RP95"
