#!/usr/bin/env bash
# T86 P2-u: a live MoQ pair with the receiver's hop shaped by t86-lossy-udp.py, loopback.
# usage: t86-loss.sh <out-dir> <A|M>
#   A  moq2ts-cli --unmodified (live, from stdin) -> moq-relay -> shaper -> moq2ts-receiver, draft 22
#   M  moq import ts --passthrough -> moq-relay -> shaper -> moq export ts --passthrough, moq-lite-07
# tsp releases CLIP once at its PCR rate into the publisher's stdin. The receiver starts first, or
# JOIN_AT s after the source; its output is tapped every 100 ms (arrivals.csv) into out.ts.
# events.log: the source's start and end and each receiver attempt, in unix seconds.
# env: MOQ (moq-dev bin dir), CLI, RECV (moq2ts), CLIP, PORT (default 4433; the shaper listens on
#      PORT+1), LOSS (percent, default 0), DELAY_MS (default 15), JOIN_AT (default 0), DRAFT (22),
#      SEG (moq2ts-cli object bytes, default 310764: 250 ms of 9.95 Mb/s), TAIL_S (default 15),
#      RELAY_CC (the relay's congestion controller, default bbr)
set -u
OUT=$1 ARM=$2
MOQ=${MOQ:?} CLI=${CLI:?} RECV=${RECV:?} CLIP=${CLIP:?}
PORT=${PORT:-4433} LOSS=${LOSS:-0} DELAY_MS=${DELAY_MS:-15} JOIN_AT=${JOIN_AT:-0} DRAFT=${DRAFT:-22}
TAIL_S=${TAIL_S:-15}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT" && cd "$OUT" || exit 1
SPORT=$((PORT + 1))
url="moqt://127.0.0.1:$PORT" rurl="moqt://127.0.0.1:$SPORT" ver="moq-transport-$DRAFT" name=t86u.msf
if [ "$ARM" = M ]; then
	url="https://127.0.0.1:$PORT" rurl="https://127.0.0.1:$SPORT" ver=moq-lite-07-wip name=t86u.hang
	export MOQ_LISTEN_VERSION=$ver
fi
# A glob build reads `**` as everything; a prefix build (before the globs, and again from #9251) `""`.
pub='**'
"$MOQ/moq-relay" --help 2>&1 | grep -A3 -- '--auth-public <' | grep -q Patterns || pub=''
printf '[log]\nlevel = "info"\n\n[listen]\nbind = "127.0.0.1:%s"\ntls.generate = ["localhost"]\n\n[auth]\npublic = "%s"\n' \
	"$PORT" "$pub" >relay.toml
{
	cat "$MOQ.sha" 2>/dev/null
	echo "arm $ARM relay_cc ${RELAY_CC:-bbr} loss $LOSS delay_ms $DELAY_MS join_at $JOIN_AT clip $CLIP"
} >build.txt
secs=$(($(python3 -c "import os; print(int(os.path.getsize('$CLIP') * 8 / 9.945951e6))") + TAIL_S + 5))
log() { echo "$(python3 -c 'import time; print(f"{time.time():.3f}")') $*" >>events.log; }

"$MOQ/moq-relay" relay.toml --quic-gso=false --quic-congestion-control "${RELAY_CC:-bbr}" >relay.log 2>&1 &
relay=$!
python3 "$HERE/t86-lossy-udp.py" --listen "127.0.0.1:$SPORT" --to "127.0.0.1:$PORT" --loss "$LOSS" \
	--delay-ms "$DELAY_MS" --stats shaper.json 2>shaper.log &
shaper=$!
sleep 1

# moq2ts-receiver exits at once while no catalog exists: retry until its output has a byte
receive() {
	local tries=0 left
	if [ "$ARM" = M ]; then
		log "receiver start 1"
		timeout "$secs" "$MOQ/moq" --connect-tls-insecure --connect "$rurl" --connect-version "$ver" \
			--quic-gso=false --broadcast "$name" export ts --passthrough 2>recv.log |
			python3 "$HERE/t67p-tap.py" arrivals.csv --tee --interval 0.1 >out.ts
		return
	fi
	while [ "$tries" -lt 150 ]; do
		tries=$((tries + 1))
		log "receiver start $tries"
		left=$((secs - JOIN_AT))
		"$RECV" --url "$rurl" --namespace "$name" --out - --duration "$left" --insecure --draft "$DRAFT" \
			--stats-json stats.json 2>>recv.log |
			python3 "$HERE/t67p-tap.py" arrivals.csv --tee --interval 0.1 >out.ts
		[ -s out.ts ] && break
		sleep 0.2
	done
}

publish() {
	if [ "$ARM" = M ]; then
		"$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version "$ver" --quic-gso=false \
			--broadcast "$name" import ts --passthrough
	else
		"$CLI" --endpoint "$url" --namespace "$name" --video /dev/stdin --unmodified --draft "$DRAFT" \
			--insecure --no-reconnect --fragment-ms 250 --segment-bytes "${SEG:-310764}"
	fi
}

if [ "$JOIN_AT" = 0 ]; then
	receive &
	recv=$!
	sleep 1
fi
log "source start"
(
	tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>tsp.log | publish >send.log 2>&1
	log "publisher exit"
) &
send=$!
if [ "$JOIN_AT" != 0 ]; then
	sleep "$JOIN_AT"
	receive &
	recv=$!
fi
wait "$recv"
log "receiver done"
kill "$send" 2>/dev/null
pkill -P $$ 2>/dev/null
kill "$relay" "$shaper" 2>/dev/null
wait 2>/dev/null
ls -l out.ts >>build.txt
