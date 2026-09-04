#!/usr/bin/env bash
# T20 -- substrate-matched segmented-HTTP impairment lane.
#
# Runs ONE arm per invocation and grades it. Publisher, origin, impairment lane,
# receiver and grading all start and stop inside a single invocation, because
# backgrounded processes do not survive between tool calls.
#
# Arms (the transport is the only intended difference between h1 and h3):
#   h1   HLS over HTTP/1.1 + TLS 1.3 over TCP   -- nginx vhost :8443 (no QUIC listener)
#   h3   HLS over HTTP/3 over QUIC              -- nginx vhost :8444 (no TCP listener)
#   moq  MoQ over QUIC                          -- loopback moq-relay
#
# Both HLS arms use the same client binary (ffmpeg built --enable-libcurl against a
# libcurl with ngtcp2/nghttp3), the same origin process, the same segment files and
# the same grading, so a difference between them is a transport difference and not a
# client or packager difference. The h3 origin has no TCP listener at all, so an H3
# arm cannot silently complete over HTTP/1.1: it would fail instead.
#
# Usage: t20-h3-arm.sh <label> <h1|h3|moq> [window_s]
# Env:   SRC       source clip                  (default ~/CNNiEMEA2.ts)
#        IMPAIR    netem spec, empty = clean    (e.g. "delay 30ms reorder 25% 50%")
#        SEGDUR    HLS target segment duration  (default 2)
#        OUTDIR    run directory                (default ~/t20/<label>)
#        SOURCE_BPS  nominal source rate        (default 9945951, the clip's CBR)
#        PCAP=1    take a packet capture of the receive path
#
# The lane normalises loopback so the two transports see comparable packets: `lo`
# defaults to MTU 65536 with offloads on, which would give TCP 64 kB super-packets
# while QUIC sends ~1200 B datagrams, and "reorder 25%" would then mean two entirely
# different impairments. See lab/method-notes.md.

set -u

LABEL="${1:?usage: t20-h3-arm.sh <label> <h1|h3|moq> [window_s]}"
ARM="${2:?arm: h1|h3|moq}"
WINDOW="${3:-60}"

SRC="${SRC:-$HOME/CNNiEMEA2.ts}"
IMPAIR="${IMPAIR:-}"
SEGDUR="${SEGDUR:-2}"
OUTDIR="${OUTDIR:-$HOME/t20/$LABEL}"
SOURCE_BPS="${SOURCE_BPS:-9945951}"
PCAP="${PCAP:-0}"

FFMPEG="${FFMPEG:-$HOME/h3/bin/ffmpeg}"
CURL="${CURL:-$HOME/h3/bin/curl}"
MOQ="${MOQ:-$HOME/bin-3006/moq}"
MOQ_RELAY="${MOQ_RELAY:-$HOME/bin-3006/moq-relay}"
HLS_DIR="${HLS_DIR:-/srv/hls}"
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/h3lab.log}"

H1_PORT=8443
H3_PORT=8444
MOQ_PORT=4443

mkdir -p "$OUTDIR"
OUT="$OUTDIR/${ARM}.ts"
LOG="$OUTDIR/${ARM}.log"
: >"$LOG"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ---------------------------------------------------------------- impairment lane
# Shape only the origin->client direction (source port = the origin's), matching T5's
# forward-path-only convention, and leave every other flow (ssh on ens5) untouched.
lane_up() {
	sudo tc qdisc del dev lo root 2>/dev/null
	sudo tc qdisc add dev lo root handle 1: prio bands 4 \
		priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
	# shellcheck disable=SC2086
	sudo tc qdisc add dev lo parent 1:4 handle 40: netem ${1:-delay 0ms}
	for spec in "6 $H1_PORT" "17 $H3_PORT" "17 $MOQ_PORT"; do
		# shellcheck disable=SC2086  # the split into protocol and port is the point
		set -- $spec
		sudo tc filter add dev lo parent 1: protocol ip prio 1 u32 \
			match ip protocol "$1" 0xff match ip sport "$2" 0xffff flowid 1:4
	done
}
lane_down() {
	sudo tc qdisc del dev lo root 2>/dev/null
	true
}

# The shaper's own counters, read from the netem band while it still exists. T5's rule
# is that a cell reports the impairment the shaper *applied*, not the one it was
# commanded, so this has to be sampled before lane_down or the qdisc is already gone.
lane_stats() {
	sudo tc -s qdisc show dev lo |
		awk '/qdisc netem 40:/{f=1} f&&/Sent/{print "sent_pkts="$4" dropped="$7; exit}' |
		tr -d ','
}

# Make the two transports comparable at the packet level. NORM_LO=0 leaves loopback
# at its 65536 MTU with offloads on, which is the shape the earlier T5 runs used and
# is retained only as a control for that comparison.
norm_lo() {
	[ "${NORM_LO:-1}" = "1" ] || return 0
	sudo ip link set lo mtu 1500
	sudo ethtool -K lo tso off gso off gro off 2>/dev/null
}
restore_lo() {
	sudo ip link set lo mtu 65536
	sudo ethtool -K lo tso on gso on gro on 2>/dev/null
}

cleanup() {
	[ -n "${PUB:-}" ] && kill "$PUB" 2>/dev/null
	[ -n "${RELAY:-}" ] && kill "$RELAY" 2>/dev/null
	[ -n "${TCPD:-}" ] && sudo kill "$TCPD" 2>/dev/null
	pkill -f 't20\.bench\.hang' 2>/dev/null
	lane_down
	restore_lo
	sleep 0.5
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------- publisher
start_hls_publisher() {
	rm -rf "${HLS_DIR:?}"/*
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous \
		-O hls --live 6 --live-extra-segments 3 --duration "$SEGDUR" --intra-close \
		--align-first-segment --playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/seg.ts" \
		>>"$LOG" 2>&1 &
	PUB=$!
	for _ in $(seq 1 90); do
		# shellcheck disable=SC2012  # the packager names these itself; they are always seg-NNNNNN.ts
		[ "$(ls "$HLS_DIR"/seg*.ts 2>/dev/null | wc -l)" -ge 4 ] && return 0
		sleep 1
	done
	log "FATAL: live window never filled"
	return 1
}

start_moq() {
	"$MOQ_RELAY" --server-bind "127.0.0.1:$MOQ_PORT" --tls-generate localhost \
		--auth-public "" --server-quic-gso=false >>"$LOG" 2>&1 &
	RELAY=$!
	sleep 3
	tsp --realtime -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>>"$LOG" |
		"$MOQ" --client-tls-disable-verify \
			--client-connect "https://127.0.0.1:$MOQ_PORT/anon" \
			--client-quic-gso=false --broadcast t20.bench.hang import ts >>"$LOG" 2>&1 &
	PUB=$!
	sleep 6
}

# ------------------------------------------------------------------------ receive
recv_hls() {
	local port="$1" ver="$2"
	timeout --signal=INT "$WINDOW" "$FFMPEG" -hide_banner -loglevel warning -nostdin \
		-prefer_libcurl 1 -http_version "$ver" -tls_verify 0 \
		-i "https://127.0.0.1:$port/index.m3u8" \
		-c copy -f mpegts -y "$OUT" >>"$LOG" 2>&1
}

recv_moq() {
	timeout --signal=INT "$WINDOW" "$MOQ" --client-tls-disable-verify \
		--client-connect "https://127.0.0.1:$MOQ_PORT/anon" --client-quic-gso=false \
		--broadcast t20.bench.hang export ts >"$OUT" 2>>"$LOG"
}

# ------------------------------------------------------------------------ grading
grade() {
	local bytes cc pcrmax over ratio pcrspan
	bytes=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
	ratio=$(python3 -c "print(f'{$bytes*8/($SOURCE_BPS*$WINDOW):.3f}')")

	cc=$(tsp -I file "$OUT" -P continuity -O drop 2>&1 | grep -c 'TS:' || true)

	tsp -I file "$OUT" -P pcrextract --pcr --csv -o "$OUTDIR/${ARM}_pcr.csv" -O drop \
		>/dev/null 2>&1
	read -r pcrmax over pcrspan < <(awk -F, 'NR>1{c=$7; if(p!=""){d=(c-p)/27000; n++;
		if(d>m)m=d; if(d>40)o++} if(f=="")f=c; p=c}
		END{printf "%.2f %.4f %.1f", m+0, (n?o/n*100:0), (p-f)/27000000}' \
		"$OUTDIR/${ARM}_pcr.csv")

	cat >"$OUTDIR/${ARM}.result" <<-EOF
		label=$LABEL arm=$ARM window=$WINDOW impair='${IMPAIR:-none}'
		bytes=$bytes delivered_ratio=$ratio
		cc_errors=$cc pcr_max_ms=$pcrmax pcr_over40_pct=$over media_seconds=$pcrspan
		lane_applied='${LANE_APPLIED:-unsampled}'
	EOF
	cat "$OUTDIR/${ARM}.result" | tee -a "$LOG"
}

# --------------------------------------------------------------------------- main
log "arm=$ARM label=$LABEL window=${WINDOW}s impair='${IMPAIR:-none}' src=$SRC"
norm_lo

case "$ARM" in
h1 | h3) start_hls_publisher || exit 1 ;;
moq) start_moq ;;
*)
	log "unknown arm $ARM"
	exit 2
	;;
esac

sudo truncate -s 0 "$NGINX_LOG" 2>/dev/null
lane_up "${IMPAIR:-delay 0ms}"
log "lane: $(sudo tc qdisc show dev lo | grep netem || echo none)"

if [ "$PCAP" = "1" ]; then
	# shellcheck disable=SC2024  # the log is user-owned and the redirect is the caller's, which is intended
	sudo tcpdump -i lo -s 96 -w "$OUTDIR/${ARM}.pcap" \
		"port $H1_PORT or port $H3_PORT or port $MOQ_PORT" >>"$LOG" 2>&1 &
	TCPD=$!
	sleep 1
fi

# A total outage is a mid-window interruption of the shaped band only, so the arm has
# to re-establish delivery inside the same measurement window. OUTAGE_S=0 disables it.
if [ "${OUTAGE_S:-0}" != "0" ]; then
	(
		sleep "${OUTAGE_AT:-15}"
		sudo tc qdisc change dev lo parent 1:4 handle 40: netem loss 100%
		echo "[outage] down for ${OUTAGE_S}s" >>"$LOG"
		sleep "$OUTAGE_S"
		# shellcheck disable=SC2086
		sudo tc qdisc change dev lo parent 1:4 handle 40: netem ${IMPAIR:-delay 0ms}
		echo "[outage] restored" >>"$LOG"
	) &
fi

# Capacity degradation: hold the band at DIP_RATE for DIP_S seconds and then restore
# it. DIP_S=perm never restores, which is the sustained-insufficiency scenario.
if [ -n "${DIP_RATE:-}" ]; then
	(
		sleep "${DIP_AT:-20}"
		sudo tc qdisc change dev lo parent 1:4 handle 40: netem rate "$DIP_RATE"
		echo "[capacity] $DIP_RATE for ${DIP_S}s" >>"$LOG"
		if [ "$DIP_S" != "perm" ]; then
			sleep "$DIP_S"
			sudo tc qdisc change dev lo parent 1:4 handle 40: netem rate "${RATE_BASE:-20mbit}"
			echo "[capacity] restored to ${RATE_BASE:-20mbit}" >>"$LOG"
		fi
	) &
fi

log "receiving for ${WINDOW}s"
case "$ARM" in
h1) recv_hls "$H1_PORT" 1.1 ;;
h3) recv_hls "$H3_PORT" 3only ;;
moq) recv_moq ;;
esac

[ -n "${TCPD:-}" ] && sudo kill "$TCPD" 2>/dev/null && sleep 1
LANE_APPLIED="$(lane_stats)"
lane_down

# Transport proof, straight from the origin's own log rather than from the client.
if [ "$ARM" != "moq" ]; then
	sudo cp "$NGINX_LOG" "$OUTDIR/${ARM}_nginx.log" 2>/dev/null
	sudo chown "$USER" "$OUTDIR/${ARM}_nginx.log" 2>/dev/null
	{
		echo "requests_total=$(wc -l <"$OUTDIR/${ARM}_nginx.log")"
		echo "by_protocol:"
		awk '{print "  ", $2, $4, $5}' "$OUTDIR/${ARM}_nginx.log" | sort | uniq -c
	} | tee -a "$LOG"
fi

grade
