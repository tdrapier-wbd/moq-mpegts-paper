#!/usr/bin/env bash
# T41 / P1-r — a timestamp rewind carried as a new broadcast.
#
# Upstream ends a TS import at any backward timestamp step, flagged or not, so a source whose
# timeline legitimately steps back (an encoder restart, a switcher) is carried only by a supervisor
# that republishes it. Each `moq import ts` mints a fresh epoch, which on `moq-lite-07` replaces the
# old broadcast at the relay, and `export ts --linger` follows it. This measures what that costs:
# one stimulus from `t23-pcr-stimuli.py`, a supervisor that restarts the import each time it exits,
# and two co-started exports, captured with each picture's arrival stamped.
#
#   t41-rewind-supervisor.sh <bin-dir> <out-dir> <stimulus.ts> <pipe|srt> [seconds]
#
#   pipe  tsp -P regulate | supervisor { moq import ts }. A restarted importer reads the pipe where
#         the last one stopped, so only what the exiting importer had read and not published is lost.
#   srt   tsp -P regulate -O srt -> tsp -I srt -O ip <multicast> (the srt-ingest shape) and a
#         supervisor { tsp -I ip <multicast> | moq import ts } (the moq-live-publisher shape). A
#         restarted stage joins the group live, so what is multicast while it restarts is lost too.
#
# The supervisor restarts at once, with no back-off. Grade with t41-rewind-grade.py.
#
# PAIR=1 (pipe only) tees the source into a second supervised importer of the same broadcast, a 1+1
# ingest pair whose importers each mint their own epoch at every restart; the second leg logs to
# supervisor2.txt and import2-<k>.log. SKEW2 delays the second leg's feed by that many seconds, as
# two ingest paths of unequal latency would.
#
# env: PORT (4475, the local relay, UDP), SRT_PORT (9147), MCAST (239.255.0.47:5047), LAT (1s),
#      LINGER (30s), VPID (111), MOQ_CONNECT_VERSION and MOQ_LISTEN_VERSION (moq-lite-07-wip),
#      EXPORT_ARGS (extra `export ts` flags, word-split, e.g. `--stitch`), PAIR (0), SKEW2 (0).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN=${1:?bin dir with moq and moq-relay}
OUT=${2:?out dir}
STIM=${3:?stimulus clip}
ARM=${4:?pipe or srt}
SECS=${5:-90}
PORT=${PORT:-4475}
SRT_PORT=${SRT_PORT:-9147}
MCAST=${MCAST:-239.255.0.47:5047}
LAT=${LAT:-1s}
LINGER=${LINGER:-30s}
VPID=${VPID:-111}
PAIR=${PAIR:-0}
SKEW2=${SKEW2:-0}
export MOQ_CONNECT_VERSION=${MOQ_CONNECT_VERSION:-moq-lite-07-wip}
export MOQ_LISTEN_VERSION=${MOQ_LISTEN_VERSION:-moq-lite-07-wip}
BCAST="t41.rewind.$$.hang"

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

mkdir -p "$OUT"
rm -f "$OUT"/source.done "$OUT"/supervisor.txt "$OUT"/supervisor2.txt "$OUT"/export-*.exit
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	echo "arm=$ARM stimulus=$STIM secs=$SECS lat=$LAT linger=$LINGER version=$MOQ_CONNECT_VERSION pair=$PAIR skew2=$SKEW2 export_args=${EXPORT_ARGS:-} host=$(hostname)"
	echo "started=$(now)"
} >"$OUT/meta.txt"

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	pkill -f -- "--broadcast $BCAST" 2>/dev/null
	pkill -f -- "--listener 127.0.0.1:$SRT_PORT" 2>/dev/null
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

moq_relay_public "127.0.0.1:$PORT" 127.0.0.1 --log-level info
"$BIN/moq-relay" "${RELAY_ARGV[@]}" >"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 2
C=("${MOQ_DIAL[@]}" "https://127.0.0.1:$PORT" --broadcast "$BCAST")

for leg in a b; do
	# shellcheck disable=SC2086
	("$BIN/moq" "${C[@]}" export ts "${MOQ_LAT[@]}" "$LAT" --linger "$LINGER" ${EXPORT_ARGS:-} 2>"$OUT/export-$leg.log"
		echo "$? $(now)" >"$OUT/export-$leg.exit") |
		python3 "$HERE/t18-latency.py" tap "$VPID" "$OUT/egress-$leg.csv" --pipe --seconds $((SECS + 20)) \
			>"$OUT/egress-$leg.ts" &
	PIDS+=($!)
done
sleep 1

# Restart the importer each time it exits, until the source has ended. The first argument tags the
# leg's logs: empty for the first, 2 for PAIR's second.
supervise() {
	local tag=$1 k=0 rc
	shift
	while :; do
		echo "start $k $(now)" >>"$OUT/supervisor$tag.txt"
		"$@" >"$OUT/import$tag-$k.log" 2>&1
		rc=$?
		echo "exit $k $rc $(now)" >>"$OUT/supervisor$tag.txt"
		[ -e "$OUT/source.done" ] && break
		k=$((k + 1))
		[ "$k" -ge 20 ] && break
	done
}

PLAY=(tsp --realtime -I file "$STIM" -P regulate --pcr-synchronous -P until --seconds "$SECS" -O file -)
TAPSRC=(python3 "$HERE/t18-latency.py" tap "$VPID" "$OUT/source.csv" --pipe --seconds "$((SECS + 5))")
# Passes stdin through, each read released SKEW2 seconds after it arrived.
DELAY=(python3 -c '
import queue, sys, threading, time
d, q, i, o = float(sys.argv[1]), queue.Queue(), sys.stdin.buffer, sys.stdout.buffer
def rd():
    while True:
        b = i.read1(65536)
        q.put((time.monotonic(), b))
        if not b:
            return
threading.Thread(target=rd, daemon=True).start()
while True:
    t, b = q.get()
    time.sleep(max(0, t + d - time.monotonic()))
    if not b:
        break
    o.write(b)
    o.flush()
' "$SKEW2")
case "$ARM" in
pipe)
	if [ "$PAIR" = 1 ]; then
		{
			"${PLAY[@]}" 2>"$OUT/source.log"
			touch "$OUT/source.done"
		} | "${TAPSRC[@]}" | tee >("${DELAY[@]}" | supervise 2 "$BIN/moq" "${C[@]}" import ts) |
			supervise "" "$BIN/moq" "${C[@]}" import ts &
	else
		{
			"${PLAY[@]}" 2>"$OUT/source.log"
			touch "$OUT/source.done"
		} | "${TAPSRC[@]}" | supervise "" "$BIN/moq" "${C[@]}" import ts &
	fi
	PIDS+=($!)
	;;
srt)
	[ "$PAIR" = 1 ] && {
		echo "PAIR is pipe only" >&2
		exit 2
	}
	tsp -I srt --listener "127.0.0.1:$SRT_PORT" --multiple --transtype live \
		--rcv-latency 2000 --udp-rcvbuf 16777216 \
		-O ip "$MCAST" --local-address 127.0.0.1 >"$OUT/stage1.log" 2>&1 &
	PIDS+=($!)
	sleep 2
	supervise "" bash -c "tsp -I ip $MCAST --local-address 127.0.0.1 -O file - 2>>'$OUT/stage2.log' \
		| '$BIN/moq' $(printf '%q ' "${C[@]}") import ts" &
	PIDS+=($!)
	sleep 1
	{
		"${PLAY[@]}" 2>"$OUT/source.log" | "${TAPSRC[@]}" |
			tsp -I file - -O srt --caller "127.0.0.1:$SRT_PORT" --transtype live 2>>"$OUT/source.log"
		touch "$OUT/source.done"
	} &
	PIDS+=($!)
	;;
*)
	echo "arm must be pipe or srt" >&2
	exit 2
	;;
esac

sleep "$((SECS + 15))"
echo "finished=$(now)" >>"$OUT/meta.txt"
