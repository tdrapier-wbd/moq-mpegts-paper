#!/usr/bin/env bash
# T14 leg A — MoQ, the control for measurement 2, one invocation.
#
#   t14-a.sh <src.ts> <out-dir> <capture-seconds>
#
# tsp regulate -> moq import ts -> relay -> moq export ts -> cadence instrument.
#
# The measurement point is the *ungroomed* egress, the same point arm B1 measures,
# with the same instrument and the same read size: what the reassembly stage hands
# the groomer. The pacer is deliberately absent.
set -euo pipefail

SRC=${1:?source .ts}
OUT=${2:?output dir}
SECS=${3:?capture seconds}
NAME=${NAME:-t14a}
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Binaries: the cargo target directory is a per-session sandbox cache whose hash
# rotates, so a fresh session has no build in it and ~/moq-dev/target is stale.
# Prefer the stable stock-main build, fall back to the session target if present.
# TGT= in the environment overrides both.
if [ -z "${TGT:-}" ]; then
	TGT=$HOME/bin-main
	if [ ! -x "$TGT/moq" ]; then
		TGT=$(cd ~/moq-dev && cargo metadata --format-version 1 --no-deps |
			python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')/release
	fi
fi
[ -x "$TGT/moq" ] && [ -x "$TGT/moq-relay" ] || {
	echo "moq binaries not found under $TGT — build per INSTRUCTIONS.local.md §1" >&2
	exit 1
}
echo "binaries: $TGT ($("$TGT/moq" --version))"

rm -rf "$OUT"
mkdir -p "$OUT"

PIDS=()
cleanup() {
	for pid in ${PIDS+"${PIDS[@]}"}; do
		kill "$pid" 2>/dev/null || true
	done
	pkill -f "moq-relay" 2>/dev/null || true
	pkill -f "tsp -I file $SRC --infinite" 2>/dev/null || true
	wait 2>/dev/null || true
}
trap cleanup EXIT

# --- relay: documented local config, GSO off (it stalls on macOS loopback) ------
pkill -f "moq-relay" 2>/dev/null || true
sleep 1
(cd ~/moq-dev && exec "$TGT/moq-relay" demo/relay/localhost.toml --server-quic-gso=false) \
	>"$OUT/relay.log" 2>&1 &
PIDS+=($!)
sleep 3

# The http:// fingerprint bootstrap is broken in this build: connect over https://
# and pin the fingerprint explicitly.
FP=$(curl -s http://localhost:4443/certificate.sha256)
[ -n "$FP" ] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	exit 1
}
URL=https://localhost:4443

# --- subscriber first: catalog reservation gating publishes once tracks resolve -
echo "capturing ${SECS}s of ungroomed MoQ egress..."
set +e
"$TGT/moq" --client-tls-fingerprint "$FP" --client-connect "$URL" \
	--client-quic-gso=false --broadcast "$NAME.hang" export ts 2>"$OUT/sub.log" |
	python3 "$SCRIPTS/t13-cadence.py" pipe "$OUT/a-egress" "$SECS" &
CAPTURE=$!
PIDS+=("$CAPTURE")
sleep 1

# --- publisher: raw source, looped, PCR-paced so the wire is live-rate ----------
# WAITMIN is `regulate`'s release granularity and therefore the burstiness of the
# *source*: at TSDuck's 50 ms default this publisher emits ~92 kB every ~73 ms.
# The default is left alone so this arm stays the one T14 quotes; T15 re-runs it at
# WAITMIN=5 to establish whether MoQ's egress granularity follows its input or is a
# property of the object model.
(tsp -I file "$SRC" --infinite \
	-P regulate --pcr-synchronous --wait-min "${WAITMIN:-50}" \
	-O file - 2>"$OUT/tsp.log" |
	"$TGT/moq" --client-tls-fingerprint "$FP" --client-connect "$URL" \
		--client-quic-gso=false --broadcast "$NAME.hang" import ts) \
	>"$OUT/pub.log" 2>&1 &
PIDS+=($!)

wait "$CAPTURE"
set -e

echo
echo "=== cadence of the ungroomed egress ==="
python3 "$SCRIPTS/t13-cadence.py" report "$OUT/a-egress.csv"
echo
echo "artefacts in $OUT: a-egress.ts a-egress.csv relay.log sub.log pub.log"
