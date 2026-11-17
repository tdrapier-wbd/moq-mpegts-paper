#!/usr/bin/env bash
# T83 Part D: Part B's switch (t83-mixed-switch.sh) with its source and receiving halves on two hosts,
# every leg crossing the path between them.
#
#   ROLE=src (publishing host): the clip paced to a UDP port and tapped with arrival times (live1);
#     the SRT sender (tsp -O srt --listener on SRTPORT, as Part C's: the receiving host's group
#     admits nothing from outside) and, for LEGB=moq, the importer and its relay
#     on PORT, or, for LEGB=seg, t61-epochseg.py's packager behind an HTTP origin on HTTPPORT.
#   ROLE=rcv (receiving host, root): the SRT caller (leg a, restarted 1 s after it exits) and the export from PEER's relay or the
#     HLS receiver from PEER's origin (leg b), into T80's switch, its groomer and the recorder (sub1).
#
# Both halves run on one wall clock: the source starts at T0 (epoch seconds), the receiver's leg b at
# T0 + 2, and each fault at T0 + KILL_AT and its return BACK s later, then both end at T0 + SECS. A
# kill is the source half's (the SRT sender, the importer or the packager); an outage is the
# receiving half's, the serving leg's flow from PEER dropped both ways on its interface; a cut is the
# switch's. Each half writes events.txt in its own OUT; t83d-batch.sh merges them. The source half
# also leaves live1-si, live1 cut to its PSI/SI and SCTE-35 packets for t83-tables.py, and tap.json,
# the tap's continuity check, and deletes live1 itself.
#
#   ROLE=src|rcv T0=<epoch> PEER=<other host> CELL=... SERVE=a|b BIN=<moq dir> PACER=<mpegts-pacer> \
#     [SRC=<ts>] t83d-switch.sh <label>
#
# Env as t83-mixed-switch.sh: LEGB (moq | seg), SRT_LAT (1000), SRT_INIT (), IDLE (6), KILL_AT (30),
#   BACK (15), SECS (75), DELAY (2s), FOLLOW (10s), RATE (11000000), PORT (4810), SRTPORT (9483), UDP
#   (5810), HTTPPORT (18483), SEG_MS (3000), OUT (/tmp/t83d); BIND (the source half's listen address,
#   the first of `hostname -I`).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"

LABEL=${1:?label}
ROLE=${ROLE:?ROLE must be src or rcv}
T0=${T0:?set T0 to the source start, epoch seconds}
PEER=${PEER:?set PEER to the other host}
CELL=${CELL:-none}
SERVE=${SERVE:-a}
LEGB=${LEGB:-moq}
SRT_LAT=${SRT_LAT:-1000}
SRT_INIT=${SRT_INIT:-}
BIN=${BIN:?set BIN to the moq binary dir}
PACER=${PACER:-}
SRC=${SRC:-}
IDLE=${IDLE:-6}
KILL_AT=${KILL_AT:-30}
BACK=${BACK:-15}
SECS=${SECS:-75}
DELAY=${DELAY:-2s}
FOLLOW=${FOLLOW:-10s}
RATE=${RATE:-11000000}
PORT=${PORT:-4810}
SRTPORT=${SRTPORT:-9483}
UDP=${UDP:-5810}
HTTPPORT=${HTTPPORT:-18483}
SEG_MS=${SEG_MS:-3000}
OUT=${OUT:-/tmp/t83d}/$LABEL
BC=t83d.$LABEL

case $ROLE in src | rcv) ;; *)
	echo "ROLE must be src or rcv" >&2
	exit 1
	;;
esac
case $CELL in none | outage | kill | cut) ;; *)
	echo "CELL must be none, outage, kill or cut" >&2
	exit 1
	;;
esac
case $SERVE in a | b) ;; *)
	echo "SERVE must be a or b" >&2
	exit 1
	;;
esac
case $LEGB in moq | seg) ;; *)
	echo "LEGB must be moq or seg" >&2
	exit 1
	;;
esac
if [ "$ROLE" = rcv ] && [ "$(id -u)" -ne 0 ]; then
	echo "run the receiving half as root (sudo): iptables" >&2
	exit 1
fi
need=("$BIN/moq")
[ "$ROLE" = src ] && need+=("$BIN/moq-relay" "$SRC")
[ "$ROLE" = rcv ] && need+=("$PACER")
for f in "${need[@]}"; do [ -e "$f" ] || {
	echo "missing $f" >&2
	exit 1
}; done
RELAYBIN=; [ "$ROLE" = src ] && RELAYBIN=$BIN/moq-relay
moq_cli_detect "$BIN/moq" $RELAYBIN
KEEP=$(python3 -c "print(f'{$IDLE / 3:g}s')")
QUIC=(--quic-idle-timeout "${IDLE}s" --quic-keep-alive "$KEEP")
EXP=(export ts --stitch --follow "$FOLLOW" --delay "$DELAY")
GSW=(--silence-ms 202 --lookback-ms 2000)
GROOM=(--rtp --latency-ms 1000 --max-latency-ms 8000 --stall-ms 1000 --on-stall mute --stats-interval-ms 1000)

rm -rf "$OUT"
mkdir -p "$OUT"
set -m
PIDS=()
DARK=()
now() { python3 -c 'import time; print(f"{time.time():.6f}")'; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
until_t() { python3 -c "import time; time.sleep(max(0.0, $1 - time.time()))"; }
# The serving leg's flow from PEER, dropped both ways on the receiving host: <add|del> <port> <udp|tcp>
# <local|remote>, the side of the flow the port is on.
flow() {
	local op=$1 p=$2 pr=$3 side=$4 a=-I
	[ "$op" = del ] && a=-D
	if [ "$side" = local ]; then
		iptables "$a" INPUT -s "$PEER" -p "$pr" --dport "$p" -j DROP 2>/dev/null
		iptables "$a" OUTPUT -d "$PEER" -p "$pr" --sport "$p" -j DROP 2>/dev/null
	else
		iptables "$a" INPUT -s "$PEER" -p "$pr" --sport "$p" -j DROP 2>/dev/null
		iptables "$a" OUTPUT -d "$PEER" -p "$pr" --dport "$p" -j DROP 2>/dev/null
	fi
}
cleanup() {
	for f in ${DARK+"${DARK[@]}"}; do
		IFS=/ read -r p pr side <<<"$f"
		flow del "$p" "$pr" "$side"
	done
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	pkill -f "[t]ail -c 0 -f $OUT/" 2>/dev/null
	wait 2>/dev/null
}
trap cleanup EXIT

{
	echo "=== $(date -u +%FT%TZ) t83d-switch $LABEL ($ROLE, peer $PEER): cell $CELL, serving $SERVE first, leg b $LEGB"
	moq_record_build "$BIN/moq" $RELAYBIN
	head -2 "$BIN.sha" 2>/dev/null || echo "sha: no sidecar for $BIN"
	[ -n "$PACER" ] && echo "pacer $("$PACER" --version 2>&1 | head -1); sha256 $(sha256sum "$PACER" | cut -c1-12)"
	echo "t80-vswitch.py sha256 $(sha256sum "$H/t80-vswitch.py" | cut -c1-12)"
	tsp --version 2>&1 | head -1
	echo "src ${SRC:-on the source half}; leg a srt --latency $SRT_LAT, sender initial load ${SRT_INIT:-default}; idle ${IDLE}s; export: ${EXP[*]}"
	[ "$LEGB" = seg ] && echo "leg b segmented: t61-epochseg.py --duration 2 --pdt (sha256 $(sha256sum "$H/t61-epochseg.py" | cut -c1-12)), origin :$HTTPPORT; b8-hls-recv.py --release-ms 1500 (sha256 $(sha256sum "$H/b8-hls-recv.py" | cut -c1-12)); pacer --stream-clock --latency-ms $SEG_MS"
	echo "switch ${GSW[*]}; groomer $RATE ${GROOM[*]}; fault at ${KILL_AT}s, back ${BACK}s later; ${SECS}s; T0 $T0"
} | tee "$OUT/build.txt"

# Each half's fault at KILL_AT and its return at KILL_AT + BACK; `end` at SECS.
schedule() { # <fault fn> <return fn>
	until_t "$T0 + $KILL_AT"
	"$1"
	until_t "$T0 + $KILL_AT + $BACK"
	"$2"
	until_t "$T0 + $SECS"
}

if [ "$ROLE" = src ]; then
	BIND=${BIND:-$(hostname -I | awk '{print $1}')}
	IMPPID=
	PKGPID=
	if [ "$LEGB" = moq ]; then
		moq_relay_public "$BIND:$PORT" "$BIND" "${QUIC[@]}" --log-level info
		"$BIN/moq-relay" "${RELAY_ARGV[@]}" >>"$OUT/relayb.log" 2>&1 &
		PIDS+=("$!")
	fi
	tsp --max-flushed-packets 7 -I ip "$UDP" -O file - 2>>"$OUT/tsp-live.log" | python3 "$H/t56-stamp.py" "$OUT/live1" &
	PIDS+=("$!")
	importer() {
		tail -c 0 -f "$OUT/live1.ts" |
			"$BIN/moq" "${MOQ_DIAL[@]}" "https://$BIND:$PORT/anon" "${QUIC[@]}" \
				--broadcast "$BC.b" import ts >>"$OUT/importb.log" 2>&1 &
		IMPPID=$!
		PIDS+=("$!")
		stamp impb_start
	}
	srt_sender() {
		bash -c "echo \$\$ >'$OUT/a-send.pid'; while :; do tail -c 0 -f '$OUT/live1.ts' | tsp ${SRT_INIT:+--initial-input-packets $SRT_INIT} -I file - -O srt --listener $BIND:$SRTPORT --latency $SRT_LAT 2>>'$OUT/srt-send.log'; echo \"srt_send_exit \$(date +%s.%N)\" >>'$OUT/events.txt'; sleep 1; done" \
			>/dev/null 2>&1 </dev/null &
		PIDS+=("$!")
		stamp srt_send_start
	}
	packager() {
		mkdir -p "$OUT/hls"
		bash -c "tail -c 0 -f '$OUT/live1.ts' | python3 '$H/t65-epochseg-stdin.py' '$OUT/hls' --duration 2 --pdt 2>>'$OUT/pkg.log'" \
			>/dev/null 2>&1 </dev/null &
		PKGPID=$!
		PIDS+=("$!")
		stamp pkg_start
	}
	origin() {
		mkdir -p "$OUT/hls"
		python3 -c 'import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
http.server.ThreadingHTTPServer((sys.argv[3], int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()' \
			"$HTTPPORT" "$OUT/hls" "$BIND" 2>>"$OUT/origin.log" &
		PIDS+=("$!")
	}
	fault() {
		[ "$CELL" = kill ] || return 0
		if [ "$SERVE" = a ]; then
			L=$(cat "$OUT/a-send.pid")
			# shellcheck disable=SC2046
			kill -KILL "$L" $(pgrep -P "$L") $(pgrep -f "[t]sp -I file - -O srt --listener $BIND:$SRTPORT") 2>/dev/null
		elif [ "$LEGB" = seg ]; then
			kill -KILL -- "-$PKGPID" 2>/dev/null
		else
			kill -KILL "$IMPPID" 2>/dev/null
		fi
		stamp "kill_$SERVE"
	}
	back() {
		[ "$CELL" = kill ] || return 0
		if [ "$SERVE" = a ]; then
			srt_sender
		elif [ "$LEGB" = seg ]; then
			packager
		else
			importer
		fi
		stamp "arrive_$SERVE"
	}
	sleep 1
	until_t "$T0"
	stamp src_start
	tsp -I file "$SRC" -P regulate --pcr-synchronous -O ip "127.0.0.1:$UDP" 2>>"$OUT/tsp-src.log" &
	PIDS+=("$!")
	sleep 0.5
	if [ "$LEGB" = seg ]; then
		origin
		packager
	else
		importer
	fi
	srt_sender
	schedule fault back
	stamp src_end
	cleanup
	trap - EXIT
	python3 "$H/t6-switch-grade.py" "$OUT/live1.ts" >"$OUT/tap.json" 2>/dev/null
	python3 - "$OUT/live1" "$OUT/live1-si" <<'PY'
import sys
src, dst = sys.argv[1:]
data = open(src + ".ts", "rb").read()
rows = [tuple(map(float, r.split(","))) for r in open(src + ".idx") if r.strip()]
pmts, keep = set(), {0, 0x10, 0x11, 0x12, 0x14}


def section(p):
    off = 4 + (1 + p[4] if (p[3] >> 4) & 2 else 0)
    return p[off + 1 + p[off]:] if off < 188 else b""


for i in range(0, len(data) - 187, 188):
    p = data[i:i + 188]
    pid = (p[1] & 0x1F) << 8 | p[2]
    if not p[1] & 0x40 or (pid != 0 and pid not in pmts):
        continue
    s = section(p)
    try:
        if pid == 0:
            for j in range(8, 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4, 4):
                if s[j] << 8 | s[j + 1]:
                    pmts.add((s[j + 2] & 0x1F) << 8 | s[j + 3])
        else:
            j, end = 12 + ((s[10] & 0x0F) << 8 | s[11]), 3 + ((s[1] & 0x0F) << 8 | s[2]) - 4
            while j < end:
                if s[j] == 0x86:
                    keep.add((s[j + 1] & 0x1F) << 8 | s[j + 2])
                j += 5 + ((s[j + 3] & 0x0F) << 8 | s[j + 4])
    except IndexError:
        pass
keep |= pmts
k, r = 0, 0
with open(dst + ".ts", "wb") as ts, open(dst + ".idx", "w") as idx:
    for i in range(0, len(data) - 187, 188):
        while r + 1 < len(rows) and rows[r + 1][0] <= i:
            r += 1
        p = data[i:i + 188]
        if p[0] == 0x47 and ((p[1] & 0x1F) << 8 | p[2]) in keep:
            ts.write(p)
            idx.write(f"{k},{rows[r][1]:.6f}\n")
            k += 188
print(f"live1-si: {k // 188} of {len(data) // 188} packets, PIDs {sorted(keep)}")
PY
	rm -f "$OUT/live1.ts"
	exit 0
fi

# The receiving half.
until_t "$T0 - 6"
tsp -I ip "$((UDP + 1))" -O file - 2>>"$OUT/tsp-rec.log" | python3 "$H/t56-stamp.py" "$OUT/sub1" &
PIDS+=("$!")
rm -f "$OUT/a.fifo" "$OUT/b.fifo"
mkfifo "$OUT/a.fifo" "$OUT/b.fifo"
exec 7<>"$OUT/a.fifo" 8<>"$OUT/b.fifo"
if [ "$SERVE" = a ]; then IN=("$OUT/a.fifo" "$OUT/b.fifo"); else IN=("$OUT/b.fifo" "$OUT/a.fifo"); fi
python3 "$H/t80-vswitch.py" "${IN[@]}" --events "$OUT/events.txt" "${GSW[@]}" 2>>"$OUT/vswitch.log" |
	tee >(python3 "$H/t56-stamp.py" "$OUT/sw") |
	"$PACER" "127.0.0.1:$((UDP + 1))" "$RATE" "${GROOM[@]}" --ssrc 1083 2>>"$OUT/pacer.log" &
PIDS+=("$!")
sleep 0.5
SWPID=$(pgrep -n -f "t80-vswitch.py $OUT/")
leg_out() { # <a|b> <command...>
	local l=$1
	shift
	(
		while :; do
			"$@"
			echo "${l}_exit_$? $(now)" >>"$OUT/events.txt"
			sleep 1
		done | tee >(python3 "$H/t56-stamp.py" "$OUT/l$l") >"$OUT/$l.fifo"
	) &
	PIDS+=("$!")
	stamp "leg${l}_start"
}
leg_out a tsp -I srt --caller "$PEER:$SRTPORT" --latency "$SRT_LAT" -O file -
until_t "$T0 + 2"
if [ "$LEGB" = seg ]; then
	# shellcheck disable=SC2016
	leg_out b bash -c 'python3 "$1" "$2" - --seconds 0 --edge 1 --poll 100 --release-ms 1500 --log "$3/b-recv.jsonl" 2>>"$3/b-recv.err" |
		"$4" stdout "$5" --stream-clock --latency-ms "$6" --max-latency-ms 14000 --stall-ms 1000 --on-stall mute \
			--stats-interval-ms 1000 2>>"$3/b-pacer.log"' _ \
		"$H/b8-hls-recv.py" "http://$PEER:$HTTPPORT/index.m3u8" "$OUT" "$PACER" "$RATE" "$SEG_MS"
else
	leg_out b "$BIN/moq" "${MOQ_DIAL[@]}" "https://$PEER:$PORT/anon" "${QUIC[@]}" --broadcast "$BC.b" "${EXP[@]}"
fi
# The serving leg's flow: the SRT sender's port, the relay's or the origin's (TCP), all on PEER.
fault_flow() {
	if [ "$SERVE" = a ]; then
		echo "$SRTPORT/udp/remote"
	elif [ "$LEGB" = seg ]; then
		echo "$HTTPPORT/tcp/remote"
	else
		echo "$PORT/udp/remote"
	fi
}
fault() {
	case $CELL in
	outage)
		IFS=/ read -r p pr side <<<"$(fault_flow)"
		flow add "$p" "$pr" "$side"
		DARK+=("$(fault_flow)")
		stamp "outage_$SERVE"
		;;
	cut) kill -USR1 "$SWPID" ;;
	esac
}
back() {
	case $CELL in
	outage)
		IFS=/ read -r p pr side <<<"$(fault_flow)"
		flow del "$p" "$pr" "$side"
		DARK=()
		stamp "light_$SERVE"
		;;
	cut) kill -USR1 "$SWPID" ;;
	esac
}
schedule fault back
stamp end
cleanup
trap - EXIT
chown -R "${SUDO_USER:-root}": "$OUT" 2>/dev/null
