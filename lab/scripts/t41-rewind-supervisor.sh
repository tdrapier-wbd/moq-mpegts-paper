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
# env: PORT (4475, the local relay, UDP), SRT_PORT (9147), MCAST (239.255.0.47:5047), LAT (1s),
#      LINGER (30s), VPID (111), MOQ_CONNECT_VERSION and MOQ_LISTEN_VERSION (moq-lite-07-wip).
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
export MOQ_CONNECT_VERSION=${MOQ_CONNECT_VERSION:-moq-lite-07-wip}
export MOQ_LISTEN_VERSION=${MOQ_LISTEN_VERSION:-moq-lite-07-wip}
BCAST="t41.rewind.$$.hang"

# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$BIN/moq" "$BIN/moq-relay"

mkdir -p "$OUT"
rm -f "$OUT"/source.done "$OUT"/supervisor.txt "$OUT"/export-*.exit
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
{
	moq_record_build "$BIN/moq" "$BIN/moq-relay"
	echo "arm=$ARM stimulus=$STIM secs=$SECS lat=$LAT linger=$LINGER version=$MOQ_CONNECT_VERSION host=$(hostname)"
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
	("$BIN/moq" "${C[@]}" export ts "${MOQ_LAT[@]}" "$LAT" --linger "$LINGER" 2>"$OUT/export-$leg.log"
		echo "$? $(now)" >"$OUT/export-$leg.exit") |
		python3 "$HERE/t18-latency.py" tap "$VPID" "$OUT/egress-$leg.csv" --pipe --seconds $((SECS + 20)) \
			>"$OUT/egress-$leg.ts" &
	PIDS+=($!)
done
sleep 1

# Restart the importer each time it exits, until the source has ended.
supervise() {
	local k=0 rc
	while :; do
		echo "start $k $(now)" >>"$OUT/supervisor.txt"
		"$@" >"$OUT/import-$k.log" 2>&1
		rc=$?
		echo "exit $k $rc $(now)" >>"$OUT/supervisor.txt"
		[ -e "$OUT/source.done" ] && break
		k=$((k + 1))
		[ "$k" -ge 20 ] && break
	done
}

PLAY=(tsp --realtime -I file "$STIM" -P regulate --pcr-synchronous -P until --seconds "$SECS" -O file -)
TAPSRC=(python3 "$HERE/t18-latency.py" tap "$VPID" "$OUT/source.csv" --pipe --seconds "$((SECS + 5))")
case "$ARM" in
pipe)
	{
		"${PLAY[@]}" 2>"$OUT/source.log"
		touch "$OUT/source.done"
	} | "${TAPSRC[@]}" | supervise "$BIN/moq" "${C[@]}" import ts &
	PIDS+=($!)
	;;
srt)
	tsp -I srt --listener "127.0.0.1:$SRT_PORT" --multiple --transtype live \
		--rcv-latency 2000 --udp-rcvbuf 16777216 \
		-O ip "$MCAST" --local-address 127.0.0.1 >"$OUT/stage1.log" 2>&1 &
	PIDS+=($!)
	sleep 2
	supervise bash -c "tsp -I ip $MCAST --local-address 127.0.0.1 -O file - 2>>'$OUT/stage2.log' \
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
