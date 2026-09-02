#!/usr/bin/env bash
# T19 time-domain arm: grade `moq export ts` release timing, not byte layout.
#
#   t19-arrival.sh <moq> <moq-relay> <relay.toml> <src.ts> <out-dir> <seconds>
#
# Same rig as t19-pcr-grid.sh, but the export is piped live into the arrival
# oracle rather than captured to a file. #3006 paces stdout writes on each
# frame's timestamp; a file capture flattens exactly the timing it creates, so
# the file-domain rig cannot grade it either way.
set -uo pipefail

MOQ=${1:?moq binary}
RELAY=${2:?moq-relay binary}
TOML=${3:?relay toml}
SRC=${4:?source .ts}
OUT=${5:?output dir}
SECS=${6:-60}

BCAST=${BCAST:-t19.arrival.hang}
MOQLAT=${MOQLAT:-3s}
WAITMIN=${WAITMIN:-5}

mkdir -p "$OUT"

set -m
PIDS=()
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
	done
	sleep 0.5
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -KILL -- "-$p" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

cp "$TOML" "$OUT/relay.toml"
(cd "$OUT" && exec "$RELAY" relay.toml --server-quic-gso=false) >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
PIDS+=("$RELAY_PID")

FP=""
for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[ -n "$FP" ] && break
	sleep 0.25
done
[ -n "$FP" ] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	exit 1
}
kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "our relay exited but :4443 answered: another relay holds the port." >&2
	exit 1
}

C=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)

# Publisher first here: the arrival oracle must not spend its window waiting for
# the catalog, because its clock starts on the first byte it reads.
(tsp --realtime -I file "$SRC" --infinite \
	-P regulate --pcr-synchronous --wait-min "$WAITMIN" -O file - |
	"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
PUB=$!
PIDS+=("$PUB")
sleep 4
kill -0 "$PUB" 2>/dev/null || {
	echo "publisher exited early:" >&2
	cat "$OUT/import.log" >&2
	exit 1
}

echo "=== $(basename "$OUT"): $("$MOQ" --version) / $("$RELAY" --version) ==="
timeout "$((SECS + 20))" "$MOQ" "${C[@]}" --broadcast "$BCAST" export ts --latency-max "$MOQLAT" \
	2>"$OUT/export.log" |
	python3 "$(dirname "$0")/t19-pcr-arrival.py" "$SECS"
echo
echo "artefacts in $OUT"
