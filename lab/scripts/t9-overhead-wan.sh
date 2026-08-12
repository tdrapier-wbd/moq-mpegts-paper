#!/usr/bin/env bash
# T9 carriage overhead over a real WAN path — orchestrator (runs on the subscriber host).
#
# Origin (relay + publisher) is remote; the subscriber is local, so the capture on
# the origin's egress interface sees the datagrams a real path actually carries.
# The loopback rig cannot answer the datagram-size question at all: GSO coalesces
# sends into multi-kB segments there.
#
# Legs:
#   base     GSO off, MTU discovery off (the deployed default)  — the decisive histogram
#   mtu      GSO off, MTU discovery on at both ends             — the one-flag A/B
#   gso      GSO on,  MTU discovery off                         — control: does GSO move bytes?
#   vidonly  GSO off, MTU discovery off, video-only source      — isolates the ~100 streams/s
#                                                                 the importer opens for audio,
#                                                                 teletext and SCTE-35 sections
#
# usage: t9-overhead-wan.sh [leg ...]      (default: all four)
set -uo pipefail

ORIGIN=${ORIGIN:?set ORIGIN to user@host of the origin box}
PEM=${PEM:?set PEM to the ssh key}
PORT=${PORT:-443}
RELAY_BIN=${RELAY_BIN:?set RELAY_BIN to the moq-relay binary on the origin}
REMOTE_MOQ=${REMOTE_MOQ:-$(dirname "$RELAY_BIN")/moq}
TLS_NAME=${TLS_NAME:?set TLS_NAME to the origin address the relay generates a cert for}
MOQ=${MOQ:-$HOME/moq-dev/target/release/moq}
SRC_FULL=${SRC_FULL:?set SRC_FULL to the full-service source clip on the origin}
SRC_VID=${SRC_VID:?set SRC_VID to the video-only source clip on the origin}
WINDOW=${WINDOW:-40}
SETTLE=${SETTLE:-20}
OUT=${OUT:-$HOME/t9wan}
SSH=(ssh -i "$PEM" -o ConnectTimeout=15 "$ORIGIN")

mkdir -p "$OUT"
SUB_PID=""

remote() { "${SSH[@]}" 'bash -s'; }   # script over stdin: the remote cmdline is `bash -s`,
                                      # so a pkill pattern cannot match its own shell

cleanup() {
	[ -n "$SUB_PID" ] && kill -9 "$SUB_PID" 2>/dev/null
	remote <<-'EOF' || true
		pkill -9 -f 't9\.wan\.[a-z]+\.hang' 2>/dev/null
		sudo pkill -9 -f 'tcpdump.*t9_oh_' 2>/dev/null
		bash ~/t8run/cc_relay.sh off
	EOF
}
trap cleanup EXIT INT TERM

# The origin sees this host at its NAT address; capture must filter on that, not on
# anything this host believes about itself.
SUB_IP=$("${SSH[@]}" 'echo $SSH_CLIENT' | awk '{print $1}')
[ -z "$SUB_IP" ] && { echo "could not resolve this host's address as seen by the origin"; exit 1; }
echo "subscriber address as seen by origin: $SUB_IP"

run_leg() {
	local leg=$1 relay_args=$2 client_args=$3 src=$4
	local bcast="t9.wan.$leg.hang"
	local ts="$OUT/$leg.ts"

	echo; echo "================ leg $leg ================"
	echo "relay: [$relay_args]  client: [$client_args]  src: $src"

	remote <<-EOF
		set -e
		bash ~/t8run/cc_relay.sh on $RELAY_BIN $relay_args
	EOF

	remote <<-EOF
		pkill -9 -f 't9\.wan\.$leg\.hang' 2>/dev/null
		setsid bash -c "tsp -I file '$src' --infinite -P regulate --pcr-synchronous -O file - \
		  | $REMOTE_MOQ --client-tls-disable-verify \
		      --client-connect https://127.0.0.1:$PORT/anon --broadcast $bcast import ts" \
		  >/tmp/t9wan_pub_$leg.log 2>&1 </dev/null & disown
		sleep 1; echo "publisher launched"
	EOF

	rm -f "$ts"
	"$MOQ" --client-tls-disable-verify \
		--client-connect "https://$TLS_NAME:$PORT/anon" $client_args \
		--broadcast "$bcast" export ts --latency-max 3s >"$ts" 2>"$OUT/$leg.sub.log" &
	SUB_PID=$!

	sleep "$SETTLE"

	# The capture runs in the background so the local TS sample is bracketed by its own
	# timer. Comparing raw byte totals across two hosts is what went wrong first time
	# round: the remote call also spends time analysing the pcap, so a local delta taken
	# around it covers a longer window than the capture and inflates the payload side.
	# Both sides are therefore reduced to a rate over a duration each measures itself.
	remote <<-EOF >"$OUT/$leg.cap.txt" 2>&1 &
		bash ~/t9/t9-overhead-wan-cap.sh $SUB_IP $PORT $WINDOW $leg
	EOF
	local cap_pid=$!

	local s0 s1 t0 t1
	sleep 3
	s0=$(stat -f%z "$ts" 2>/dev/null || echo 0); t0=$(date +%s.%N)
	sleep $((WINDOW - 5))
	s1=$(stat -f%z "$ts" 2>/dev/null || echo 0); t1=$(date +%s.%N)
	wait "$cap_pid"

	kill -9 "$SUB_PID" 2>/dev/null; SUB_PID=""
	remote <<-EOF
		pkill -9 -f 't9\.wan\.$leg\.hang' 2>/dev/null
	EOF

	if [ "$s0" -eq 0 ] || [ "$s1" -le "$s0" ]; then
		echo "LEG $leg FAILED: subscriber delivered no TS during the window"
		tail -5 "$OUT/$leg.sub.log"
		return 1
	fi
	{
		echo "TS_BYTES_DELIVERED $((s1 - s0))"
		awk -v b=$((s1 - s0)) -v a="$t0" -v z="$t1" \
			'BEGIN { printf "TS_SAMPLE_S %.3f\nTS_DELIVERED_MBPS %.4f\n", z - a, b * 8 / (z - a) / 1e6 }'
	} >>"$OUT/$leg.cap.txt"
	grep -v '^ ' "$OUT/$leg.cap.txt"
}

for leg in "${@:-base mtu gso vidonly}"; do
	case $leg in
	base)    run_leg base    "--server-quic-gso=false" "" "$SRC_FULL" ;;
	mtu)     run_leg mtu     "--server-quic-gso=false --server-quic-mtu-discovery=true" \
	                         "--client-quic-mtu-discovery=true" "$SRC_FULL" ;;
	gso)     run_leg gso     "" "" "$SRC_FULL" ;;
	vidonly) run_leg vidonly "--server-quic-gso=false" "" "$SRC_VID" ;;
	*) echo "unknown leg: $leg" ;;
	esac
done

echo; echo "all legs done; per-leg output in $OUT/*.cap.txt"
