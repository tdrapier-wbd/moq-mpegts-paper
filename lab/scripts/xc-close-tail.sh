#!/usr/bin/env bash
# Does a file's last group survive `moq import ts --passthrough` closing at its end? moq2ts#85: a
# publisher that closed once its data was acknowledged lost its tail at `moq-relay`, which drops
# what it has not read when a connection closes. One relay on loopback; an `export ts --passthrough`
# subscribed before the publisher starts; the publisher fed a clip either paced (`tsp -P regulate`)
# or unpaced (`cat`, so it closes about as soon as it has sent). A run passes when the export's
# output ends with the clip's last TAIL bytes, byte-identical.
#
# Usage: xc-close-tail.sh OUT        env: MOQ (bin dir), CLIP, PACKETS (133000), RUNS (3), TAIL (65536)

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-ed3a2697-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts}
PACKETS=${PACKETS:-133000} RUNS=${RUNS:-3} TAIL=${TAIL:-65536}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
P=$((20000 + RANDOM % 20000))
CONNECT=${MOQ_DIAL[${#MOQ_DIAL[@]} - 1]}
DIAL=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}" "$CONNECT" "https://localhost:$P/anon")

head -c $((188 * PACKETS)) "$CLIP" >clip.ts
tail -c "$TAIL" clip.ts >clip-tail.bin
moq_relay_public "[::]:$P" localhost --log-level info
"$R" "${RELAY_ARGV[@]}" >relay.log 2>&1 &
RP=$!
trap 'kill "$RP" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) packets=$PACKETS tail=$TAIL port=$P" | tee meta.txt

run() { # <mode> <n>
	local name=$1-$2 b=xc-$1-$2 rc_e rc_i
	timeout 90 "$M" "${DIAL[@]}" --broadcast "$b" export ts --passthrough --delay 2s >"$name.ts" 2>"$name.export.log" &
	local ep=$!
	sleep 1
	if [ "$1" = paced ]; then
		tsp -I file clip.ts -P regulate --pcr-synchronous -O file - 2>/dev/null
	else
		cat clip.ts
	fi | RUST_LOG=info timeout 90 "$M" "${DIAL[@]}" --broadcast "$b" import ts --passthrough 2>"$name.import.log"
	rc_i=$?
	wait "$ep"
	rc_e=$?
	local got tailok
	got=$(wc -c <"$name.ts" | tr -d ' ')
	if cmp -s clip-tail.bin <(tail -c "$TAIL" "$name.ts"); then tailok=yes; else tailok=no; fi
	printf '%s\timport_rc=%s\texport_rc=%s\tin=%s\tout=%s\ttail=%s\n' "$name" "$rc_i" "$rc_e" \
		"$(wc -c <clip.ts | tr -d ' ')" "$got" "$tailok" | tee -a results.tsv
}

for n in $(seq 1 "$RUNS"); do
	run unpaced "$n"
	run paced "$n"
done
