#!/usr/bin/env bash
# T12 arm D's mid-stream-join cell, reduced to the question it now has to answer.
#
# The full rig ([`t12-dual-leg.sh`](t12-dual-leg.sh)) fans one source into two disjoint
# publisher/relay/exporter chains. That is the right topology for grading a delivery pair,
# but for asking *what the exporter contributes to a late joiner's residue* it adds a
# variable: two publishers producing their own objects. This runs one publisher and one
# relay into two stream-clocked groomers, the second joining late, so the only asymmetry
# left is when each exporter tuned in.
#
# Set TWO_PUB=1 to put the publisher back: one source, `tee`d into two importers publishing
# two broadcasts, one leg subscribed to each. The relay process is shared, but nothing
# crosses between the broadcasts, so the pair is disjoint from the importer onwards and the
# difference from the default run is exactly the publisher's contribution.
#
# It records the RTP egress directly from the sockets rather than from a pcap, so it needs
# no privileges — the metric is the same one t12-maskcmp.py computes (identical, and
# identical with the continuity counter masked, at equal RTP sequence numbers).
#
# Everything runs inside one invocation: background processes do not survive across
# separate shell invocations in this environment.
#
# Usage: t12-armd-join-local.sh <moq> <moq-relay> <pacer-dir> <label> <source.ts> [join_s] [window_s] [rate_bps]

set -euo pipefail

MOQ="${1:?usage: t12-armd-join-local.sh <moq> <moq-relay> <pacer-dir> <label> <src.ts> [join_s] [window_s] [rate]}"
RELAY="${2:?}"
PACER="${3:?}"
LABEL="${4:?}"
SRC="${5:?}"
JOIN="${6:-20}"
WINDOW="${7:-45}"
RATE="${8:-4000000}"

# Matched to t12-dual-leg.sh so the numbers are comparable with the campaign.
SSRC=538968071
SEQ_SEED=0
LATENCY_MAX=500ms
PACER_LAT=1000
PACER_MAXLAT=8000
PACER_STALL=1000
PORT_A=5100
PORT_B=5200
BCAST="t12d-$LABEL.hang"
OUT="$HOME/t12d_$LABEL"

for f in "$MOQ" "$RELAY" "$PACER/moq_egress"; do
	[[ -x "$f" ]] || { echo "not executable: $f" >&2; exit 1; }
done
[[ -r "$SRC" ]] || { echo "no such source: $SRC" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
echo "==> $LABEL: $(basename "$MOQ"), src $(basename "$SRC"), join +${JOIN}s, window ${WINDOW}s, ${RATE} b/s"

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; }
trap cleanup EXIT

# Records both legs' datagrams for the whole run. Started first so no egress is missed,
# and given a large socket buffer because a groomed 4 Mb/s leg is a steady datagram train
# and a drop here would silently shrink the compared set.
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
    f = open(path, "wb")
    files[s] = f
    sel.register(s, selectors.EVENT_READ)
try:
    while True:
        for key, _ in sel.select():
            data = key.fileobj.recv(65535)
            # Length-prefixed, so datagram boundaries survive into the file.
            files[key.fileobj].write(struct.pack("<H", len(data)) + data)
except (KeyboardInterrupt, SystemExit):
    pass
finally:
    for f in files.values():
        f.flush(); f.close()
PY
PIDS+=("$!")
sleep 1

# GSO off: it stalls on macOS loopback. https:// + pinned fingerprint: the http://
# bootstrap is broken in these builds.
( cd ~/moq-dev && "$RELAY" demo/relay/localhost.toml --server-quic-gso=false ) >"$OUT/relay.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[[ -n "$FP" ]] && break
	sleep 0.25
done
[[ -n "${FP:-}" ]] || { echo "relay did not come up" >&2; exit 1; }

BCAST_A="$BCAST"
BCAST_B="${TWO_PUB:+${BCAST}b}"
BCAST_B="${BCAST_B:-$BCAST}"

leg() { # rtp_port broadcast logfile
	"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
		--client-quic-gso=false --broadcast "$2" export ts --latency-max "$LATENCY_MAX" 2>>"$3" |
		"$PACER/moq_egress" "127.0.0.1:$1" "$RATE" --rtp --ssrc "$SSRC" \
			--latency-ms "$PACER_LAT" --max-latency-ms "$PACER_MAXLAT" \
			--stall-ms "$PACER_STALL" --on-stall mute \
			--stream-clock --sequence-seed "$SEQ_SEED" >>"$3" 2>&1
}

publish() { # fifo broadcast logfile
	"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
		--client-quic-gso=false --broadcast "$2" import ts <"$1" >"$3" 2>&1
}

leg "$PORT_A" "$BCAST_A" "$OUT/leg-a.log" &
PIDS+=("$!")
sleep 2

if [[ -n "${TWO_PUB:-}" ]]; then
	# One source, two importers. `tee` so both see the same bytes at the same time: two
	# readers of the same file would drift and the legs would not be carrying one feed.
	mkfifo "$OUT/fa" "$OUT/fb"
	publish "$OUT/fa" "$BCAST_A" "$OUT/pub-a.log" &
	PIDS+=("$!")
	publish "$OUT/fb" "$BCAST_B" "$OUT/pub-b.log" &
	PIDS+=("$!")
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
		tee "$OUT/fa" >"$OUT/fb" &
	PIDS+=("$!")
else
	tsp -I file "$SRC" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
		"$MOQ" --client-tls-fingerprint "$FP" --client-connect https://localhost:4443 \
			--client-quic-gso=false --broadcast "$BCAST" import ts >"$OUT/pub.log" 2>&1 &
	PIDS+=("$!")
fi

echo "==> leg A running; leg B joins in ${JOIN}s"
sleep "$JOIN"
leg "$PORT_B" "$BCAST_B" "$OUT/leg-b.log" &
PIDS+=("$!")

echo "==> capturing ${WINDOW}s"
sleep "$WINDOW"
cleanup
trap - EXIT
sleep 1

echo "==> leg A $(wc -c <"$OUT/a.rtp") bytes, leg B $(wc -c <"$OUT/b.rtp") bytes -> $OUT"
