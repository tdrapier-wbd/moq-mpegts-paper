#!/usr/bin/env bash
#
# T8b, conditions C2–C5 — one cell on a *provisioned* path, in the netns rig.
#
#   sudo t8b-provisioned.sh <label>
#
# C1 asked how each transport fails when the link cannot carry the feed. That is a failure
# mode, not an operating point: nobody provisions a permanent trunk at half the feed rate.
# C2–C5 ask the question that decides whether a transport can carry a 24/7/365 trunk — what
# happens on a link that *is* provisioned, when something else turns up on it.
#
# Env, one cell per invocation:
#
#   TRANSPORT   cubic | bbr1 | bbr2 | bbr3 | srt | seg | segpull
#   CAP_MBIT    bottleneck rate (default 15 — 1.5x the ~9.93 Mb/s feed)
#   QDISC       bloat | codel | cake   (the leaf queue at the bottleneck)
#   SECS        window (default 120)
#   COMPETE     none, or "<start>-<end>" seconds into the window for a greedy TCP flow
#   NFLOWS      concurrent media flows of the same transport (default 1) — C3
#
# THE INSTRUMENT IS A TIME SERIES, not a total. On a provisioned path the interesting
# quantity is not how much arrived but *when it stopped and whether it came back*, and a
# window total cannot express either. Every cell samples the receiver's output size once a
# second, so delivered rate is resolved per second and the transient can be scored as three
# phases — before, during, after — with a recovery time between the last two. A cell that
# delivers 100% of the feed over 120 s while stalling for 20 s in the middle is a failure
# this rig can see and a mean cannot.
#
# The competing flow is a greedy TCP bulk transfer (nc from /dev/zero) pub->sub, i.e. through
# the same bottleneck in the same direction as the media. iperf3 is not installed on this
# host and is not needed: what a competing flow has to be is greedy and loss-responsive, and
# a bulk TCP transfer is both by construction.
#
# Continuity is counted with `grep -cE 'missing .* packets|discontinuity'`. `tsp -P continuity`
# prints "missing N packets" and never the word "discontinuity", so a matcher on the latter
# alone reports zero forever — which is what six of this campaign's scripts did before it was
# found. Do not simplify this back.
set -uo pipefail

LABEL=${1:?label}
TRANSPORT=${TRANSPORT:-cubic}
CAP_MBIT=${CAP_MBIT:-15}
QDISC=${QDISC:-bloat}
SECS=${SECS:-120}
COMPETE=${COMPETE:-none}
NFLOWS=${NFLOWS:-1}
SEGSECS=${SEGSECS:-2}

MOQ=${MOQ:-/home/ubuntu/bin-main-eab96019/moq}
RELAY_QUINN=${RELAY_QUINN:-/home/ubuntu/moq-relay-quinn}
RELAY_QUICHE=${RELAY_QUICHE:-/home/ubuntu/moq-relay-quiche}
RELAY_NOQ=${RELAY_NOQ:-/home/ubuntu/moq-relay-noq}
CLIP=${CLIP:-/home/ubuntu/CNNiEMEA2.ts}
SOURCE_BPS=${SOURCE_BPS:-9945951}
NETNS=${NETNS:-/home/ubuntu/t8b/t8b-netns.sh}
DIR=${DIR:-/home/ubuntu/t8b/prov}

PUBIP=10.99.0.1
SUBIP=10.99.0.2
[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}
mkdir -p "$DIR"
RUN=$DIR/$LABEL
rm -rf "$RUN"
mkdir -p "$RUN"

pub() { ip netns exec t8b-pub "$@"; }
sub() { ip netns exec t8b-sub "$@"; }

# Refuse to start on a dirty rig rather than mislabel a cell. The failure this guards is
# silent by construction — a surviving relay serves the new cell's publisher perfectly well,
# under the old controller — so it has to be an error before the run, not a puzzle after it.
if pgrep -f "[m]oq-relay.*$PUBIP:4443" >/dev/null 2>&1; then
	echo "t8b-provisioned: a relay is already bound to $PUBIP:4443 — refusing to run." >&2
	echo "  a leaked relay would serve this cell under the previous cell's controller." >&2
	pgrep -af "[m]oq-relay.*$PUBIP:4443" >&2
	exit 1
fi

BCAST="t8b.prov.$LABEL.$$"
CAP=$RUN/out.ts
SERIES=$RUN/series.csv
RTT=$RUN/rtt.csv
KIDS=()

cleanup() {
	for p in ${KIDS+"${KIDS[@]}"}; do kill "$p" 2>/dev/null; done
	sleep 0.5
	for p in ${KIDS+"${KIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
	# Backgrounding a shell function runs it in a subshell, so `$!` can be the subshell
	# rather than the relay it exec's — and killing the subshell then leaves the relay
	# holding :4443. A leaked relay does not announce itself: the *next* cell's relay
	# fails to bind, its publisher connects to the survivor instead, and the cell reports
	# the previous cell's congestion controller under the new label. So the relay is
	# reaped by what it is rather than by which pid we think it had.
	pkill -9 -f "[m]oq-relay.*$PUBIP:4443" 2>/dev/null
	pkill -9 -f "$BCAST" 2>/dev/null
	pkill -9 -f "[t]sp -I file $CLIP" 2>/dev/null
	pkill -9 -f "[t]sp --realtime -I file $CLIP" 2>/dev/null
	pkill -9 -f "[p]ython3 -m http.server 8080" 2>/dev/null
	pkill -9 -f "[n]c $SUBIP 9999" 2>/dev/null
	pkill -9 -f "[n]c -l 9999" 2>/dev/null
	pkill -9 -f "[d]d if=/dev/zero bs=64k" 2>/dev/null
	true
}
trap cleanup EXIT

# ---- shape the path ---------------------------------------------------------
RATE_MBIT=$CAP_MBIT QUEUE_MS=${QUEUE_MS:-500} DELAY_MS=${DELAY_MS:-50} \
	bash "$NETNS" "$QDISC" >"$RUN/shape.log" 2>&1 ||
	{
		echo "shaping failed" >&2
		exit 1
	}

# ---- start the sender side --------------------------------------------------
relay_for() {
	case "$1" in
	cubic | bbr1) echo "$RELAY_QUINN" ;;
	bbr2) echo "$RELAY_QUICHE" ;;
	bbr3) echo "$RELAY_NOQ" ;;
	esac
}
cc_for() {
	case "$1" in
	cubic) echo loss ;;
	bbr1 | bbr2 | bbr3) echo delay ;;
	esac
}

HLS_DIR=$RUN/hls
case "$TRANSPORT" in
cubic | bbr1 | bbr2 | bbr3)
	pub "$(relay_for "$TRANSPORT")" --server-bind $PUBIP:4443 --tls-generate localhost \
		--auth-public "" --server-quic-congestion-control "$(cc_for "$TRANSPORT")" \
		>"$RUN/relay.log" 2>&1 &
	KIDS+=("$!")
	sleep 2
	# Assert the relay under test is the one running, by binary and by controller. Every
	# figure in this cell is a claim about that pair, and a bind failure is otherwise silent.
	if ! pgrep -af "[m]oq-relay.*$PUBIP:4443" |
		grep -q -- "$(basename "$(relay_for "$TRANSPORT")").*congestion-control $(cc_for "$TRANSPORT")"; then
		echo "t8b-provisioned: $TRANSPORT relay did not come up as asked — see $RUN/relay.log" >&2
		pgrep -af "[m]oq-relay.*$PUBIP:4443" >&2
		exit 1
	fi
	for i in $(seq 1 "$NFLOWS"); do
		pub bash -c "tsp -I file $CLIP --infinite -P regulate --pcr-synchronous -O file - \
      | $MOQ --client-tls-disable-verify --client-connect https://$PUBIP:4443/anon \
          --broadcast $BCAST.$i import ts" >"$RUN/pub.$i.log" 2>&1 &
		KIDS+=("$!")
	done
	sleep 4
	;;
srt)
	for i in $(seq 1 "$NFLOWS"); do
		pub bash -c "while :; do tsp -I file $CLIP --infinite -P regulate --pcr-synchronous \
        -O srt --listener 0.0.0.0:$((9010 + i)) --latency 2000; sleep 1; done" \
			>"$RUN/pub.$i.log" 2>&1 &
		KIDS+=("$!")
	done
	sleep 3
	;;
seg | segpull)
	mkdir -p "$HLS_DIR"
	pub bash -c "tsp --realtime -I file $CLIP --infinite -P regulate --pcr-synchronous \
      -O hls $HLS_DIR/seg.ts --playlist $HLS_DIR/index.m3u8 --duration $SEGSECS \
      --live 6 --live-extra-segments 3 --intra-close --align-first-segment" \
		>"$RUN/pub.1.log" 2>&1 &
	KIDS+=("$!")
	pub bash -c "cd $HLS_DIR && exec python3 -m http.server 8080 --bind $PUBIP" \
		>"$RUN/origin.log" 2>&1 &
	KIDS+=("$!")
	for i in $(seq 1 180); do
		[ "$(grep -c '^seg.*\.ts$' "$HLS_DIR/index.m3u8" 2>/dev/null || echo 0)" -ge 3 ] && break
		sleep 1
	done
	;;
esac

# ---- competing flow --------------------------------------------------------
# Greedy TCP, pub->sub, through the same bottleneck. Scheduled inside the window so the
# before/during/after phases are all in one capture and one clock.
C_START=0
C_END=0
if [ "$COMPETE" != none ]; then
	C_START=${COMPETE%%-*}
	C_END=${COMPETE##*-}
	sub bash -c "nc -l 9999 >/dev/null" >"$RUN/sink.log" 2>&1 &
	KIDS+=("$!")
	sleep 1
	(
		sleep "$C_START"
		pub bash -c "dd if=/dev/zero bs=64k 2>/dev/null | nc $SUBIP 9999" &
		sleep $((C_END - C_START))
		pkill -9 -f "[d]d if=/dev/zero bs=64k" 2>/dev/null
		pkill -9 -f "[n]c $SUBIP 9999" 2>/dev/null
	) >"$RUN/load.log" 2>&1 &
	KIDS+=("$!")
fi

# ---- receive ---------------------------------------------------------------
case "$TRANSPORT" in
cubic | bbr1 | bbr2 | bbr3)
	sub bash -c "timeout $SECS $MOQ --client-tls-disable-verify \
      --client-connect https://$PUBIP:4443/anon --broadcast $BCAST.1 export ts \
      --latency-max 2s > $CAP" >"$RUN/sub.log" 2>&1 &
	;;
srt)
	sub bash -c "timeout $SECS tsp -I srt --caller $PUBIP:9011 --latency 2000 \
      -O file $CAP" >"$RUN/sub.log" 2>&1 &
	;;
seg)
	sub bash -c "timeout $SECS tsp --realtime -I hls http://$PUBIP:8080/index.m3u8 --live \
      -O file $CAP" >"$RUN/sub.log" 2>&1 &
	;;
segpull)
	sub bash -c "timeout $SECS python3 /home/ubuntu/t8b/t6-hls-pull.py \
      http://$PUBIP:8080/index.m3u8 $CAP" >"$RUN/sub.log" 2>&1 &
	;;
esac
RECV=$!
KIDS+=("$RECV")

# For C3 the extra flows must actually be subscribed, or "N flows share the class" is a
# claim about one flow and N idle publishers.
for i in $(seq 2 "$NFLOWS"); do
	case "$TRANSPORT" in
	cubic | bbr1 | bbr2 | bbr3)
		sub bash -c "timeout $SECS $MOQ --client-tls-disable-verify \
        --client-connect https://$PUBIP:4443/anon --broadcast $BCAST.$i export ts \
        --latency-max 2s > $RUN/out.$i.ts" >"$RUN/sub.$i.log" 2>&1 &
		KIDS+=("$!")
		;;
	srt)
		sub bash -c "timeout $SECS tsp -I srt --caller $PUBIP:$((9010 + i)) --latency 2000 \
        -O file $RUN/out.$i.ts" >"$RUN/sub.$i.log" 2>&1 &
		KIDS+=("$!")
		;;
	esac
done

# ---- sample the receiver once a second -------------------------------------
: >"$SERIES"
(
	for t in $(seq 1 "$SECS"); do
		echo "$t,$(stat -c%s "$CAP" 2>/dev/null || echo 0)" >>"$SERIES"
		sleep 1
	done
) &
KIDS+=("$!")

: >"$RTT"
sub ping -n -D -i 0.2 -c $((SECS * 5)) $PUBIP 2>/dev/null |
	awk -F'time=' '/time=/{ts=$1;sub(/^\[/,"",ts);sub(/\].*/,"",ts);r=$2;sub(/ *ms.*/,"",r);print ts","r}' \
		>>"$RTT" &
KIDS+=("$!")

wait "$RECV" 2>/dev/null
sleep 2

# ---- grade -----------------------------------------------------------------
BYTES=$(stat -c%s "$CAP" 2>/dev/null || echo 0)
CCE=$(tsp -I file "$CAP" -P continuity -O drop 2>&1 |
	grep -cE 'missing .* packets|discontinuity' || true)
tsp -I file "$CAP" -P pcrextract --pcr --csv -o "$RUN/pcr.csv" -O drop >/dev/null 2>&1
PCRMAX=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;if(d>m)m=d}p=c} END{printf "%.1f", m+0}' \
	"$RUN/pcr.csv" 2>/dev/null)
PCROVER=$(awk -F, 'NR>1{c=$7;if(p!=""){d=(c-p)/27000;if(d>40)o++}p=c} END{print o+0}' \
	"$RUN/pcr.csv" 2>/dev/null)

read -r P50 P95 < <(awk -F, '$2!=""{v[n++]=$2+0} END{if(n){asort(v);
  printf "%.0f %.0f", v[int(n*0.5)], v[int(n*0.95)]} else print "NA NA"}' "$RTT" 2>/dev/null)

# Phase means from the per-second series. `before` is the pre-transient steady state and is
# the denominator for everything else: a rate is only meaningful here against what this cell
# was managing before anything competed with it.
read -r R_ALL R_PRE R_DUR R_POST RECOV < <(awk -F, -v cs="$C_START" -v ce="$C_END" -v n="$SECS" '
  {t[NR]=$1; b[NR]=$2}
  END{
    if (NR<3) {print "0 0 0 0 NA"; exit}
    for(i=2;i<=NR;i++) r[i]=(b[i]-b[i-1])*8/1e6          # Mb/s in second i
    all=(b[NR]-b[1])*8/(t[NR]-t[1])/1e6
    if (ce<=cs) { pre=all; dur=0; post=0; rec="NA" }
    else {
      np=0; nd=0; nq=0
      for(i=2;i<=NR;i++){
        if (t[i]<=cs)            { pre+=r[i];  np++ }
        else if (t[i]<=ce)       { dur+=r[i];  nd++ }
        else                     { post+=r[i]; nq++ }
      }
      pre = np?pre/np:0; dur = nd?dur/nd:0; post = nq?post/nq:0
      # recovery: first second past the transient with three consecutive seconds at
      # >= 95% of the pre-transient rate. Three, because one second at rate proves
      # nothing on a lane that delivers in segments or groups.
      rec="never"
      for(i=2;i<=NR-2;i++){
        if (t[i]>ce && r[i]>=0.95*pre && r[i+1]>=0.95*pre && r[i+2]>=0.95*pre) {
          rec=t[i]-ce; break
        }
      }
    }
    printf "%.2f %.2f %.2f %.2f %s", all, pre, dur, post, rec
  }' "$SERIES")

printf 'RESULT label=%s transport=%s cap_mbit=%s qdisc=%s nflows=%s compete=%s secs=%s bytes=%s mbps=%s pct_cap=%.0f pct_src=%.0f pre_mbps=%s dur_mbps=%s post_mbps=%s recover_s=%s cc=%s pcr_over40=%s pcr_max_ms=%s rtt_p50=%s rtt_p95=%s\n' \
	"$LABEL" "$TRANSPORT" "$CAP_MBIT" "$QDISC" "$NFLOWS" "$COMPETE" "$SECS" "$BYTES" \
	"$R_ALL" \
	"$(awk -v g="$R_ALL" -v c="$CAP_MBIT" 'BEGIN{print g/c*100}')" \
	"$(awk -v g="$R_ALL" -v s="$SOURCE_BPS" 'BEGIN{print g*1e6/s*100}')" \
	"$R_PRE" "$R_DUR" "$R_POST" "$RECOV" \
	"$CCE" "${PCROVER:-NA}" "${PCRMAX:-NA}" "${P50:-NA}" "${P95:-NA}" |
	tee -a "$DIR/results.txt"
