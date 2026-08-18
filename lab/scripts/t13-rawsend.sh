#!/usr/bin/env bash
# T13, wire domain: where `rawsendmpeg2ts` sits.
#
# https://github.com/EDIS-mx/rawsendmpeg2ts is a datagram sender, not a groomer: it
# takes a *CBR, null-stuffed* transport stream, derives the mux rate from bytes per
# PCR, and puts seven packets per datagram on the wire against absolute
# CLOCK_MONOTONIC deadlines. It rewrites nothing. So it cannot be scored against
# T13's four criteria as a grooming stage; it occupies the egress slot *after* one,
# and the question it answers is criterion 4 alone — is the wire rate-controlled.
#
# Five legs, so that the sender's own contribution is separable from its input's:
#
#   golden-rawsend     the sender on a true CBR file — its best case, and its
#                      primary documented use
#   golden-tsp         a conventional TSDuck sender on the same file, default
#                      `regulate` (this is what the T15 source cadence was)
#   golden-tsp-fine    the same with --wait-min 5, because the default batches at
#                      ~50 ms and would otherwise be read as the sender's floor
#   moq-ffmpeg-rawsend the chain the tool's README documents for MoQ:
#                      `export ts | ffmpeg -muxrate | rawsendmpeg2ts --stdin`
#   moq-ffmpeg-udp     the same groomer with ffmpeg's own UDP egress, which
#                      isolates what the sender changes and nothing else
#
# Given a pacer binary, two more legs put the campaign's control on the same host,
# at the rawsend chain's rate and at the source's nominal rate, because the 10 ms
# quantisation floor moves with the rate and a cross-rate comparison would read that
# as a difference between tools.
#
# This runs on Linux. The tool does not build on macOS: `clock_nanosleep` with
# TIMER_ABSTIME does not exist there, and that call *is* the pacing mechanism, so a
# shimmed build would measure the shim. Hence the box, and hence every control here
# re-measured on the box rather than compared against T13's macOS figures.
#
# It uses the standing relay and the standing loop publisher rather than starting
# its own, so it disturbs nothing; both are left as found.
#
# Usage: t13-rawsend.sh <rawsendmpeg2ts> <moq> <source.ts> [window_s] [pacer]

set -uo pipefail

RAWSEND="${1:?usage: t13-rawsend.sh <rawsendmpeg2ts> <moq> <src.ts> [window_s] [pacer]}"
MOQ="${2:?}"
SRC="${3:?}"
WINDOW="${4:-25}"
PACER="${5:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HOME/t13_rawsend"
BCAST="cnn.international.emea.loop.hang"
RELAY="https://localhost:443/anon"
SETTLE=6

# The rate ffmpeg is told to pace at, from the tool's own README recipe. It is
# above the source's 9.946 Mb/s nominal, which is the point: a groomer must pad to
# something, and 11M is what the documented chain pads to.
MUXRATE=11000000

for f in "$RAWSEND" "$MOQ"; do
	[[ -x "$f" ]] || {
		echo "not executable: $f" >&2
		exit 1
	}
done
[[ -r "$SRC" ]] || {
	echo "not readable: $SRC" >&2
	exit 1
}

rm -rf "$OUT" && mkdir -p "$OUT"
cd "$OUT" || exit 1

KIDS=()
cleanup() {
	for p in "${KIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	reap
	wait 2>/dev/null
}
trap cleanup EXIT

# Killing a backgrounded *pipeline* by `$!` reaps only its last stage, so a
# subscriber at the head of one survives its own leg and keeps pulling the
# broadcast through every leg that follows — on a two-core box that is load the
# later legs pay for and the earlier ones do not. Two defences: every subscriber
# runs under `timeout`, so it cannot outlive its window whatever the shell does with
# process groups, and `reap` sweeps by command line afterwards. The bracket in the
# pattern stops it matching the sweeping shell's own command line, and matching
# `export ts` leaves the standing publishers (`import ts`) alone.
reap() {
	pkill -f -- "--broadcast $BCAST [e]xport ts" 2>/dev/null
	return 0
}

subscribe() { # subscribe <seconds>
	timeout "$1" "$MOQ" --client-tls-disable-verify --client-connect "$RELAY" \
		--broadcast "$BCAST" export ts
}

# The structural reference: what the exporter emitted, before any groomer. Named so
# that it sorts first, which is how t13-grade.py picks the reference.
echo "=== 0-ungroomed (structural reference)"
subscribe 12 >"$OUT/0-ungroomed.ts" 2>"$OUT/0-ungroomed.log"
reap
printf '  %s bytes\n' "$(stat -c %s "$OUT/0-ungroomed.ts" 2>/dev/null || echo 0)"

# run_leg <name> <port> <feed|nofeed> <command...>
#
# `feed` pipes a MoQ export into the command's stdin; `nofeed` lets the command
# read the source itself. The capture starts first either way, so nothing is
# already in flight when the window opens.
run_leg() {
	local name=$1 port=$2 mode=$3
	shift 3
	echo "=== $name (port $port)"

	python3 "$HERE/t13-cadence.py" capture "$port" "$OUT/$name" "$WINDOW" \
		>"$OUT/$name.cap.log" 2>&1 &
	local capture=$!
	KIDS+=("$capture")
	sleep 1

	local chain
	if [[ $mode == feed ]]; then
		subscribe "$((WINDOW + 4))" 2>"$OUT/$name.sub.log" |
			"$@" >"$OUT/$name.leg.log" 2>&1 &
	else
		"$@" >"$OUT/$name.leg.log" 2>&1 &
	fi
	chain=$!
	KIDS+=("$chain")

	wait $capture
	kill $chain 2>/dev/null
	reap
	sleep "$SETTLE"
	cat "$OUT/$name.cap.log"
}

# The sender on a true CBR file: no groomer in the chain at all, so what the socket
# shows is the sender's own pacing and nothing else.
run_leg golden-rawsend 5101 nofeed \
	"$RAWSEND" "$SRC" 127.0.0.1:5101

# A conventional TSDuck sender on the same file, as shipped: `regulate` waits 50 ms
# by default, so this leg is a control for the *instrument*, not a rival.
run_leg golden-tsp 5102 nofeed \
	tsp -I file "$SRC" -P regulate --pcr-synchronous \
	-O ip 127.0.0.1:5102 --enforce-burst --packet-burst 7

run_leg golden-tsp-fine 5103 nofeed \
	tsp -I file "$SRC" -P regulate --pcr-synchronous --wait-min 5 \
	-O ip 127.0.0.1:5103 --enforce-burst --packet-burst 7

# The documented MoQ chain. `-map 0:v:0 -map 0:a:0` is the README's own selection:
# it keeps one video and one audio and drops everything else, which the PID census
# will show.
FFMPEG_GROOM=(ffmpeg -hide_banner -loglevel warning -i pipe:0
	-map 0:v:0 -map 0:a:0 -c copy -muxrate "$MUXRATE" -pcr_period 20 -f mpegts)

run_leg moq-ffmpeg-rawsend 5104 feed \
	sh -c "$(printf '%q ' "${FFMPEG_GROOM[@]}") pipe:1 | $(printf '%q ' "$RAWSEND") --stdin 127.0.0.1:5104"

# The same groomer, ffmpeg's own egress: the difference between this leg and the
# one above is the sender, and only the sender.
run_leg moq-ffmpeg-udp 5105 feed \
	"${FFMPEG_GROOM[@]}" "udp://127.0.0.1:5105?pkt_size=1316"

# The README's `-map 0:v:0 -map 0:a:0` keeps one video and one audio by choice, which
# says nothing about what ffmpeg *can* carry. This leg is T13's pinned form — every
# stream mapped and every PID pinned back — so the carriage that survives is
# ffmpeg's best effort and not a selection artefact. Same rate as the legs above, so
# the cadence columns stay comparable.
run_leg moq-ffmpegpin-rawsend 5108 feed \
	sh -c "ffmpeg -hide_banner -loglevel error -f mpegts -i pipe:0 \
		-map 0 -copy_unknown -c copy -muxrate $MUXRATE -pcr_period 20 \
		-mpegts_pmt_start_pid 4096 \
		-streamid 0:111 -streamid 1:121 -streamid 2:123 -streamid 3:131 \
		-streamid 4:141 -streamid 5:142 -streamid 6:143 \
		-f mpegts pipe:1 | $(printf '%q ' "$RAWSEND") --stdin 127.0.0.1:5108"

# The campaign's control, on this host, one tool doing both jobs. Plain UDP rather
# than --rtp so the datagram is 1316 bytes on every leg: an RTP header would change
# the payload the instrument sees and the quantisation with it.
if [[ -n "$PACER" && -x "$PACER" ]]; then
	run_leg moq-pacer-11m 5106 feed \
		"$PACER" 127.0.0.1:5106 "$MUXRATE" --stall-ms 1000 --on-stall mute

	run_leg moq-pacer-nominal 5107 feed \
		"$PACER" 127.0.0.1:5107 9945951 --stall-ms 1000 --on-stall mute
fi

echo
python3 "$HERE/t13-cadence.py" report "$OUT"/*.csv
echo
echo "captures in $OUT; grade the received streams with:"
echo "  python3 $HERE/t13-grade.py grade $OUT"
