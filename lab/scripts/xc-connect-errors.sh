#!/usr/bin/env bash
# How does `moq import ts` meet a relay it can never reach? moq2ts#45's three permanent errors and
# moq2ts#21's bracketed IPv6 endpoint, asked of moq-dev (lab/cross-check.md). Loopback only.
#
# Cases, each one `moq import ts` of the clip under a SECS timeout:
#   ok       https://localhost:P/anon, certificate check off (the control: it connects)
#   v6       https://[::1]:P/anon, certificate check off
#   dns      https://nonexistent.invalid:P/anon
#   cert     https://localhost:P/anon, certificate check on (the relay's certificate is self-signed)
#   version  https://localhost:P2/anon, a relay that accepts only moq-lite-07-wip, which the client
#            does not offer by default
# Prints per case: exit code (124: still running at the timeout), seconds, dial attempts, sessions
# connected, and the log's last line.
#
# Usage: xc-connect-errors.sh OUT        env: MOQ (bin dir), CLIP, SECS (30), TIMEOUT

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-cd560bde-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts} SECS=${SECS:-30}
TIMEOUT=${TIMEOUT:-timeout}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
P1=$((20000 + RANDOM % 20000))
P2=$((P1 + 1))
CONNECT=${MOQ_DIAL[${#MOQ_DIAL[@]} - 1]}
INSECURE=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}")

moq_relay_public "[::]:$P1" localhost --log-level info
"$R" "${RELAY_ARGV[@]}" >relay1.log 2>&1 &
R1=$!
moq_relay_public "[::]:$P2" localhost --log-level info --listen-version moq-lite-07-wip
"$R" "${RELAY_ARGV[@]}" >relay2.log 2>&1 &
R2=$!
trap 'kill "$R1" "$R2" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) secs=$SECS" | tee meta.txt

run() { # <case> <url> [client flags ...]
	local name=$1 url=$2 t0 rc
	shift 2
	t0=$(date +%s)
	RUST_LOG=info "$TIMEOUT" "$SECS" "$M" "$@" "$CONNECT" "$url" --broadcast xc import ts \
		<"$CLIP" >/dev/null 2>"$name.log"
	rc=$?
	printf '%s\trc=%s\ts=%s\tattempts=%s\tconnected=%s\tlast=%s\n' "$name" "$rc" "$(($(date +%s) - t0))" \
		"$(grep -c 'connecting peer=' "$name.log")" "$(grep -c 'connected version=' "$name.log")" \
		"$(grep -v '^[[:space:]]*$' "$name.log" | tail -1 | cut -c1-200)" | tee -a results.tsv
}

run ok "https://localhost:$P1/anon" "${INSECURE[@]}"
run v6 "https://[::1]:$P1/anon" "${INSECURE[@]}"
run dns "https://nonexistent.invalid:$P1/anon" "${INSECURE[@]}"
run cert "https://localhost:$P1/anon"
run version "https://localhost:$P2/anon" "${INSECURE[@]}"
