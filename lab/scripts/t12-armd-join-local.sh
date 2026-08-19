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
# Both legs run their exporter with the container consumer at debug, and the run reports how
# many groups each leg skipped. A leg that drops a group the other kept is a content
# divergence no amount of field determinism repairs, so a pair graded without that number is
# only ever an upper bound. LATENCY_MAX is exposed so the counter can be shown to fire:
# LATENCY_MAX=0ms is the positive control.
#
# FILTER runs between the exporter and the groomer on both legs (e.g. ts-keyframe-pad.py),
# for pricing a change to the emitted packet count against the groomer downstream of it.
# FILTER_B replaces it on leg B alone, which is how the legs are made to diverge on purpose
# (ts-stall.py stops one leg consuming until its budget expires).
#
# PUB_CHAIN replaces the publisher's `tsp` plugin chain, which by default only paces the file.
# It is what lets the pair be graded on a stream carrying service information: an SI table is
# emitted by the exporter from a snapshot its *own* subscription delivered, so a table whose
# bytes advance — a clock above all — is a candidate for divergence that a static mux cannot
# show. Pair `-P inject` with `-P timeref --start system` so each section is unique and true at
# the moment it is sent; two legs emitting the same section then means they agree, rather than
# meaning the source repeated itself.
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
LATENCY_MAX="${LATENCY_MAX:-500ms}"
PACER_LAT=1000
PACER_MAXLAT=8000
PACER_STALL=1000
PORT_A=5100
PORT_B=5200
BCAST="t12d-$LABEL.hang"
OUT="$HOME/t12d_$LABEL"

# The pacer's egress adapter was moq_egress, then ts_egress, and is now the crate's
# binary `mpegts-pacer`. Accept any of the three, so this rig runs against the build it
# was written for and against current heads.
EGRESS="$PACER/moq_egress"
for candidate in mpegts-pacer ts_egress moq_egress; do
	if [[ -x "$PACER/$candidate" ]]; then
		EGRESS="$PACER/$candidate"
		break
	fi
done

for f in "$MOQ" "$RELAY" "$EGRESS"; do
	[[ -x "$f" ]] || { echo "not executable: $f" >&2; exit 1; }
done
[[ -r "$SRC" ]] || { echo "no such source: $SRC" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"

# The dial-side flags were renamed `--client-*` -> `--connect-*` and the per-direction QUIC
# knobs merged into one `--quic-*` set, so the relay's `--server-quic-gso` moved with them.
# The rename is on `dev` and not on `main`, and a build from the middle of it accepted the old
# names, warned, and applied nothing — which on macOS loopback leaves GSO on and the session
# stalls with nothing logged. Detect the surface rather than assuming either.
if "$MOQ" --connect https://localhost --help >/dev/null 2>&1; then
	FLAGS_NEW=1
	RELAY_GSO=(--quic-gso=false)
else
	FLAGS_NEW=0
	RELAY_GSO=(--server-quic-gso=false)
fi

# Word-split deliberately: this is a tsp plugin chain, not one argument.
# shellcheck disable=SC2206
PUB_CHAIN_ARGS=(${PUB_CHAIN:--P regulate --pcr-synchronous})

echo "==> $LABEL: $(basename "$MOQ"), src $(basename "$SRC"), join +${JOIN}s, window ${WINDOW}s, ${RATE} b/s"
echo "==> flags $([[ $FLAGS_NEW == 1 ]] && echo '--connect-*' || echo '--client-*'), publisher chain: ${PUB_CHAIN_ARGS[*]}"

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
# RELAY_ARGS reaches the cache: retention is unbounded unless `--cache-duration` is set, and
# with nothing ever expiring a leg that falls behind is never forced to skip. It is what
# decides whether a stalled leg lags or loses media.
# The config is copied out so a relay from a worktree build is not made to read, or to be
# blamed for, whatever branch ~/moq-dev happens to be sitting on.
cp ~/moq-dev/demo/relay/localhost.toml "$OUT/relay.toml"
# `exec` so the recorded pid is the relay itself. Without it `$!` is the subshell, teardown
# kills only that, and the relay survives to hold :4443 into the next run.
# shellcheck disable=SC2086
( cd "$OUT" && exec "$RELAY" relay.toml "${RELAY_GSO[@]}" ${RELAY_ARGS:-} ) >"$OUT/relay.log" 2>&1 &
RELAY_PID="$!"
PIDS+=("$RELAY_PID")
for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[[ -n "$FP" ]] && break
	sleep 0.25
done
[[ -n "${FP:-}" ]] || { echo "relay did not come up; see $OUT/relay.log" >&2; exit 1; }

# A fingerprint proves *a* relay is on the port, not that it is ours. A previous run whose
# teardown lost the process leaves one bound, this one fails with `Address already in use`,
# and the fingerprint poll then succeeds against the survivor — so the run silently grades a
# relay of unknown build and unknown remaining lifetime, and reads as a mid-run collapse when
# the stranger exits. Refuse instead.
if ! kill -0 "$RELAY_PID" 2>/dev/null; then
	echo "our relay exited but :4443 answered: another relay holds the port." >&2
	echo "  see $OUT/relay.log; clear it with pkill -f moq-relay" >&2
	exit 1
fi

if [[ $FLAGS_NEW == 1 ]]; then
	CONNECT=(--connect-tls-fingerprint "$FP" --connect https://localhost:4443 --quic-gso=false)
else
	CONNECT=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)
fi

BCAST_A="$BCAST"
BCAST_B="${TWO_PUB:+${BCAST}b}"
BCAST_B="${BCAST_B:-$BCAST}"

export_ts() { # broadcast logfile
	# The whole crate rather than the consumer module: "starting track" then appears on every
	# run, so a run with no skip lines is one where the filter was demonstrably live, rather
	# than one where the directive silently failed to match.
	RUST_LOG="${RUST_LOG:-warn,moq_mux=debug}" \
		"$MOQ" "${CONNECT[@]}" --broadcast "$1" export ts --latency-max "$LATENCY_MAX" 2>>"$2"
}

# SC2094: every stage appends to the one log; none of them reads it.
# shellcheck disable=SC2094
leg() { # rtp_port broadcast logfile [filter]
	local groom=(
		"$EGRESS" "127.0.0.1:$1" "$RATE" --rtp --ssrc "$SSRC"
		--latency-ms "$PACER_LAT" --max-latency-ms "$PACER_MAXLAT"
		--stall-ms "$PACER_STALL" --on-stall mute
		--stream-clock --sequence-seed "$SEQ_SEED"
	)
	if [[ -n "${4:-}" ]]; then
		# Unquoted: a filter carries its arguments (ts-stall.py takes two).
		# shellcheck disable=SC2086
		export_ts "$2" "$3" | python3 $4 2>>"$3" | "${groom[@]}" >>"$3" 2>&1
	else
		export_ts "$2" "$3" | "${groom[@]}" >>"$3" 2>&1
	fi
}

publish() { # fifo broadcast logfile
	"$MOQ" "${CONNECT[@]}" --broadcast "$2" import ts <"$1" >"$3" 2>&1
}

leg "$PORT_A" "$BCAST_A" "$OUT/leg-a.log" "${FILTER:-}" &
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
	tsp -I file "$SRC" --infinite "${PUB_CHAIN_ARGS[@]}" -O file - 2>/dev/null |
		tee "$OUT/fa" >"$OUT/fb" &
	PIDS+=("$!")
else
	tsp -I file "$SRC" --infinite "${PUB_CHAIN_ARGS[@]}" -O file - 2>"$OUT/tsp.log" |
		"$MOQ" "${CONNECT[@]}" --broadcast "$BCAST" import ts >"$OUT/pub.log" 2>&1 &
	PIDS+=("$!")
fi

echo "==> leg A running; leg B joins in ${JOIN}s"
sleep "$JOIN"
leg "$PORT_B" "$BCAST_B" "$OUT/leg-b.log" "${FILTER_B:-${FILTER:-}}" &
PIDS+=("$!")

echo "==> capturing ${WINDOW}s"
sleep "$WINDOW"
cleanup
trap - EXIT
sleep 1

echo "==> leg A $(wc -c <"$OUT/a.rtp") bytes, leg B $(wc -c <"$OUT/b.rtp") bytes -> $OUT"

# The exporter logs every group it abandons, so the pair's grade can be qualified rather
# than assumed. "slow" is the latency budget expiring; "old" and "evicted" are a group
# arriving behind the cursor or having aged out of the relay. Any of them means the legs
# stopped carrying the same media, which no field-level determinism repairs.
for l in a b; do
	log="$OUT/leg-$l.log"
	printf '    leg %s: %s slow, %s old, %s evicted (--latency-max %s)\n' "$l" \
		"$(grep -c 'skipping slow groups' "$log" || true)" \
		"$(grep -c 'skipping old group' "$log" || true)" \
		"$(grep -c 'current group evicted' "$log" || true)" "$LATENCY_MAX"
done
