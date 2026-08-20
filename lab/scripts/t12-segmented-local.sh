#!/usr/bin/env bash
# T12 arm D, asked of the segmented lane: can two independent segmented legs be merged
# by an ST 2022-7 receiver?
#
# Arm D's result is that two groomers sharing no process, no clock and no messages emit
# byte-identical RTP, because each computes placement from the stream rather than from
# itself. That is what makes a 1+1 pair mergeable at the receiver, and it is the
# broadcast-grade claim in this project that rests on the least obvious mechanism. It
# has only ever been established with MoQ carrying the two legs.
#
# The carriage should not matter — the groomer sees a transport stream either way — but
# "should not matter" is a hypothesis, and this lane has already produced two reasons to
# check. Its packager re-muxes rather than copying (T11), so the two legs' inputs are
# not verbatim copies of one source; and its delivery is bursty and window-quantised
# rather than continuous, so two clients can be carrying different parts of the
# programme at the same instant.
#
# Two topologies, because they are different claims:
#
#   two-packagers  Two disjoint chains from the source onwards — the arm D equivalent,
#                  and the one that protects the whole chain rather than the last hop.
#   one-packager   One packager, two origins serving the same objects. This is how HLS
#                  redundancy is actually deployed, and it should be trivially mergeable;
#                  it is here as the positive control that grades the rig.
#
# Recorded from the sockets rather than a pcap, so no privileges are needed. Grade with
# t12-rtpcmp.py, the same oracle arm D used.
#
# Usage: t12-segmented-local.sh <pacer-dir> <label> <source.ts> [window_s] [rate_bps]

# Not `set -e`. This rig is a dozen background pipelines and a poll loop, and a bare
# `[[ cond ]] && x=y` that is legitimately false reads as a failed command and takes the
# whole script down silently — which is exactly what it did on the first run.
set -uo pipefail

PACER="${1:?usage: t12-segmented-local.sh <pacer-dir> <label> <src.ts> [window_s] [rate]}"
LABEL="${2:?}"
SRC="${3:?}"
WINDOW="${4:-60}"
RATE="${5:-4000000}"

MODE="${MODE:-two-packagers}"
SEGDUR="${SEGDUR:-2}"

# Matched to t12-dual-leg.sh so these numbers sit on the campaign's scale.
SSRC=538968071
SEQ_SEED=0
# Overridable, because on this lane the cushion is the variable under test rather than a
# setting: a bursty source starves a CBR groomer, the groomer mutes when starved, and two
# legs that starve at different moments are not byte-identical however deterministic their
# placement is.
PACER_LAT="${PACER_LAT:-1000}"
PACER_MAXLAT="${PACER_MAXLAT:-8000}"
PACER_STALL="${PACER_STALL:-1000}"
PORT_A=5100
PORT_B=5200
HTTP_A="${HTTP_A:-8091}"
HTTP_B="${HTTP_B:-8092}"
OUT="$HOME/t12seg_$LABEL"

EGRESS="$PACER/moq_egress"
for candidate in mpegts-pacer ts_egress moq_egress; do
	if [[ -x "$PACER/$candidate" ]]; then
		EGRESS="$PACER/$candidate"
		break
	fi
done
[[ -x "$EGRESS" ]] || { echo "no pacer binary in $PACER" >&2; exit 1; }
[[ -r "$SRC" ]] || { echo "no such source: $SRC" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/origin-a" "$OUT/origin-b"

echo "==> $LABEL: mode $MODE, src $(basename "$SRC"), window ${WINDOW}s, ${RATE} b/s"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
	# Deliberately no bare `wait`: a `tee` blocked on a fifo whose reader has gone will
	# not return, and the teardown then hangs instead of the run finishing.
}
trap cleanup EXIT

# A port held by a previous run makes this one grade a stranger's output. Refuse.
for p in "$HTTP_A" "$HTTP_B" "$PORT_A" "$PORT_B"; do
	if lsof -nP -i ":$p" >/dev/null 2>&1; then
		echo "port $p is already in use; clear it before running" >&2
		exit 1
	fi
done

# Records both legs for the whole run, started before anything emits.
python3 - "$PORT_A" "$PORT_B" "$OUT/a.rtp" "$OUT/b.rtp" <<'PY' &
import socket, sys, struct, selectors

ports = (int(sys.argv[1]), int(sys.argv[2]))
paths = (sys.argv[3], sys.argv[4])
sel = selectors.DefaultSelector()
files = {}
for port, path in zip(ports, paths):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    files[s] = open(path, "wb")
    sel.register(s, selectors.EVENT_READ)
try:
    while True:
        for key, _ in sel.select():
            data = key.fileobj.recv(65535)
            files[key.fileobj].write(struct.pack("<H", len(data)) + data)
except (KeyboardInterrupt, SystemExit):
    pass
finally:
    for f in files.values():
        f.flush(); f.close()
PY
PIDS+=("$!")
sleep 1

package() { # dir logfile <stdin: TS>
	tsp --realtime -I file - -O hls "$1/seg.ts" --playlist "$1/index.m3u8" \
		--duration "$SEGDUR" --live 6 --live-extra-segments 3 \
		--intra-close --align-first-segment >"$2" 2>&1
}

origin() { # dir port logfile
	(cd "$1" && exec python3 -m http.server "$2" --bind 127.0.0.1) >"$3" 2>&1 &
	PIDS+=("$!")
}

leg() { # http_port rtp_port logfile
	tsp -I hls "http://127.0.0.1:$1/index.m3u8" --live -O file - 2>>"$3" |
		"$EGRESS" "127.0.0.1:$2" "$RATE" --rtp --ssrc "$SSRC" \
			--latency-ms "$PACER_LAT" --max-latency-ms "$PACER_MAXLAT" \
			--stall-ms "$PACER_STALL" --on-stall mute \
			--stream-clock --sequence-seed "$SEQ_SEED" >>"$3" 2>&1
}

case "$MODE" in
two-packagers)
	# `tee` rather than two readers of the file: two readers drift, and the pair would
	# then not be carrying one feed.
	mkfifo "$OUT/fa" "$OUT/fb"
	package "$OUT/origin-a" "$OUT/pkg-a.log" <"$OUT/fa" &
	PIDS+=("$!")
	package "$OUT/origin-b" "$OUT/pkg-b.log" <"$OUT/fb" &
	PIDS+=("$!")
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>"$OUT/src.log" |
		tee "$OUT/fa" >"$OUT/fb" &
	PIDS+=("$!")
	origin "$OUT/origin-a" "$HTTP_A" "$OUT/origin-a.log"
	origin "$OUT/origin-b" "$HTTP_B" "$OUT/origin-b.log"
	B_PORT="$HTTP_B"
	;;
one-packager)
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>"$OUT/src.log" |
		package "$OUT/origin-a" "$OUT/pkg-a.log" &
	PIDS+=("$!")
	# Two origins over one directory: the same objects, two serving nodes.
	origin "$OUT/origin-a" "$HTTP_A" "$OUT/origin-a.log"
	origin "$OUT/origin-a" "$HTTP_B" "$OUT/origin-b.log"
	B_PORT="$HTTP_B"
	;;
*)
	echo "unknown MODE: $MODE" >&2
	exit 2
	;;
esac

segcount() { grep -c '\.ts$' "$1/index.m3u8" 2>/dev/null || echo 0; }

echo "==> waiting for both playlists"
a=0
b=0
for _ in $(seq 1 90); do
	a=$(segcount "$OUT/origin-a")
	if [[ "$MODE" == two-packagers ]]; then
		b=$(segcount "$OUT/origin-b")
	else
		b=$a
	fi
	if [[ "$a" -ge 3 && "$b" -ge 3 ]]; then
		break
	fi
	sleep 1
done
if [[ "$a" -lt 3 || "$b" -lt 3 ]]; then
	echo "playlists not ready (a=$a b=$b); see $OUT/pkg-*.log" >&2
	exit 1
fi
echo "==> playlists ready (a=$a b=$b segments)"

leg "$HTTP_A" "$PORT_A" "$OUT/leg-a.log" &
PIDS+=("$!")
leg "$B_PORT" "$PORT_B" "$OUT/leg-b.log" &
PIDS+=("$!")

echo "==> capturing ${WINDOW}s"
sleep "$WINDOW"
cleanup
trap - EXIT
sleep 1

echo "==> leg A $(wc -c <"$OUT/a.rtp") bytes, leg B $(wc -c <"$OUT/b.rtp") bytes -> $OUT"
echo "    grade with: t12-rtpcmp.py $OUT/a.rtp $OUT/b.rtp"

# A 404 means a client fell out of the live window, which makes any identity figure a
# statement about a truncated leg rather than about the pair. Surface it here.
for l in a b; do
	n=$(grep -ci '404\|synchronization lost' "$OUT/leg-$l.log" 2>/dev/null || true)
	[[ "${n:-0}" -gt 0 ]] && echo "    WARNING leg $l: $n window/sync errors in its log"
done
exit 0
