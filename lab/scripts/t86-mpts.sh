#!/usr/bin/env bash
# T86 P2-v: a multi-programme stream through a live MoQ pair, loopback.
# usage: t86-mpts.sh <out-dir> <A|M> <U|P>
#   U  the multiplex unmodified: A moq2ts-cli --unmodified -> moq-relay -> moq2ts-receiver;
#      M import ts --passthrough -> moq-relay -> export ts --passthrough. Writes out.ts.
#   P  per programme: A moq2ts-cli --config (each of PROGRAMS, all DVB SI) -> moq-relay ->
#      moq2ts-receiver --track program-<n>; M import ts --program all -> moq-relay -> export ts of
#      each programme's broadcast. Writes egress-<n>.ts.
# The receivers start first; tsp releases CLIP once at its PCR rate into the publisher's stdin, and
# the receivers get TAIL_S more seconds. M runs on moq-lite-07 (MVER), clear of moq#9081.
# env: MOQ (moq-dev bin dir), CLI, RECV (moq2ts), CLIP, PORT (default 4433), DRAFT (default 22),
#      PROGRAMS (default "1 2 3"), SEG (cell U's moq2ts-cli object bytes, default 621528: 250 ms of
#      a 19.9 Mb/s multiplex), TAIL_S (default 15), JOIN_AT (receivers start this many s after the
#      source rather than before it; P2-u). events.log: the source's and each receiver's start.
set -u
OUT=$1 ARM=$2 CELL=$3
MOQ=${MOQ:?} CLI=${CLI:?} RECV=${RECV:?} CLIP=${CLIP:?}
PORT=${PORT:-4433} DRAFT=${DRAFT:-22} PROGRAMS=${PROGRAMS:-1 2 3} TAIL_S=${TAIL_S:-15} JOIN_AT=${JOIN_AT:-0}
TAP="$(cd "$(dirname "$0")" && pwd)/t67p-tap.py"
mkdir -p "$OUT" && cd "$OUT" || exit 1
url="moqt://127.0.0.1:$PORT" ver="moq-transport-$DRAFT" name=t86v.msf
if [ "$ARM" = M ]; then
	url="https://127.0.0.1:$PORT" ver=${MVER:-moq-lite-07-wip} name=t86v.hang
	export MOQ_LISTEN_VERSION=$ver
fi
# A glob build reads `**` as everything; a prefix build (before the globs, and again from #9251) `""`.
pub='**'
"$MOQ/moq-relay" --help 2>&1 | grep -A3 -- '--auth-public <' | grep -q Patterns || pub=''
printf '[log]\nlevel = "info"\n\n[listen]\nbind = "127.0.0.1:%s"\ntls.generate = ["localhost"]\n\n[auth]\npublic = "%s"\n' \
	"$PORT" "$pub" >relay.toml
{
	cat "$MOQ.sha" 2>/dev/null
	echo "arm $ARM cell $CELL clip $CLIP $(md5 -q "$CLIP" 2>/dev/null || md5sum "$CLIP" | cut -d' ' -f1)"
} >build.txt
secs=$(($(python3 -c "import os; print(int(os.path.getsize('$CLIP') * 8 / 19.9e6))") + TAIL_S + 5))
moq=("$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version "$ver")

"$MOQ/moq-relay" relay.toml --quic-gso=false >relay.log 2>&1 &
relay=$!
sleep 1

log() { echo "$(python3 -c 'import time; print(f"{time.time():.3f}")') $*" >>events.log; }

# moq2ts-receiver exits at once while no catalog exists: retry until its output has a byte. Each
# receiver's output is tapped every 100 ms into arrivals-<label>.csv.
rx() { # <out.ts> <label> [--track <name>]
	local out=$1 label=$2 tries=0
	shift 2
	log "receiver $label start"
	while [ "$tries" -lt 100 ]; do
		tries=$((tries + 1))
		"$RECV" --url "$url" --namespace "$name" "$@" --out - --duration "$((secs - JOIN_AT))" --insecure \
			--draft "$DRAFT" --stats-json "stats-$label.json" 2>>"recv-$label.log" |
			python3 "$TAP" "arrivals-$label.csv" --tee --interval 0.1 >"$out"
		[ -s "$out" ] && break
		sleep 0.2
	done
	echo "$out: $tries attempts" >>attempts.txt
}
ex() { # <out.ts> <label> <broadcast> [--passthrough]
	local out=$1 label=$2 bc=$3
	shift 3
	log "receiver $label start"
	timeout "$((secs - JOIN_AT))" "${moq[@]}" --broadcast "$bc" export ts "$@" 2>"recv-$label.log" |
		python3 "$TAP" "arrivals-$label.csv" --tee --interval 0.1 >"$out"
}

recv=()
start_receivers() {
	if [ "$CELL" = U ]; then
		if [ "$ARM" = M ]; then ex out.ts u "$name" --passthrough & else rx out.ts u & fi
		recv+=($!)
	else
		for n in $PROGRAMS; do
			if [ "$ARM" = M ]; then ex "egress-$n.ts" "$n" "t86v/$n.hang" & else rx "egress-$n.ts" "$n" --track "program-$n" & fi
			recv+=($!)
		done
	fi
}
if [ "$JOIN_AT" = 0 ]; then
	start_receivers
	sleep 1
fi

if [ "$ARM" = A ] && [ "$CELL" = P ]; then
	python3 - "$url" "$name" "$DRAFT" "$PROGRAMS" >config.json <<'EOF'
import json, sys
url, ns, draft, progs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4].split()
print(json.dumps({
    "relay": {"endpoint": url, "namespace": ns, "draft": draft, "insecure": True},
    "ingest": {"path": "/dev/stdin"},
    "programs": [{"number": int(n), "si": ["all"]} for n in progs],
}, indent=2))
EOF
fi
case $ARM$CELL in
AU) pub=("$CLI" --endpoint "$url" --namespace "$name" --video /dev/stdin --unmodified --draft "$DRAFT" --insecure
	--no-reconnect --fragment-ms 250 --segment-bytes "${SEG:-621528}") ;;
AP) pub=("$CLI" --config config.json) ;;
MU) pub=("${moq[@]}" --broadcast "$name" import ts --passthrough) ;;
MP) pub=("${moq[@]}" --broadcast "$name" import ts --program all) ;;
*) echo "unknown arm or cell: $ARM $CELL" >&2 && exit 2 ;;
esac
date -u +"source start %T" >>build.txt
log "source start"
tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>tsp.log | "${pub[@]}" >send.log 2>&1 &
send=$!
if [ "$JOIN_AT" != 0 ]; then
	sleep "$JOIN_AT"
	start_receivers
fi
wait "${recv[@]}"
echo "receivers done; publisher $(kill -0 "$send" 2>/dev/null && echo running || echo exited)" >>build.txt
kill "$send" 2>/dev/null
pkill -P $$ 2>/dev/null
kill "$relay" 2>/dev/null
wait 2>/dev/null
ls -l ./*.ts >>build.txt
