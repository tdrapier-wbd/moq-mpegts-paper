#!/usr/bin/env bash
# Whether the rig's delay placement moves the lanes' figures. `t8b-netns.sh` puts half the RTT in
# front of the bottleneck by default, which costs TCP CUBIC its slow start (`rig-capacity.sh`: a
# 3 MB transfer at 5.9 Mb/s through 20 Mb/s, against 15.3 Mb/s with the RTT on the acknowledgement
# path), while paced UDP passes the configured rate either way. QUIC's controllers are ack-clocked
# as TCP's are and SRT's sender is paced, so the rig could be biased between the lanes.
#
# These arms re-run the cells the comparison rests on with the whole RTT on the acknowledgement
# path (PATH_DELAY_MS=0 ACK_DELAY_MS=100), on `ffa5b81b` with padding off and the relay on `delay`,
# to be read against the published figures from the default placement:
#   ladder   control, 5 s outage, 1.0x and 0.9x for 60 s, 3 s budget, two replicates
#   matched  MoQ and SRT at a 2 s budget: none, 5 s outage, 5 % loss, two replicates
# Reorder is left out: `netem` reorders by delaying, so it needs the data-path delay.
#
# Usage: t2831-topology.sh [outroot]      (needs passwordless sudo; never beside another rig)
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
ROOT=${1:-$HOME/t2831-topology}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFA=$HOME/bin-ffa5b81b
mkdir -p "$ROOT"
COMMON=(CLIP="$HOME/clip120.ts" NETNS="$HOME/t8b-netns.sh" GRADER="$HOME/t28-media-lost.py"
	CONTENT="$HOME/t28-content-lost.py" LATENCY="$HOME/t18-latency.py"
	PATH_DELAY_MS=0 ACK_DELAY_MS=100 MOQ_CC=delay MOQ_MUX_RATE=0)

conserve() { # <dir> <label>
	sudo python3 "$HERE/t2831-conservation.py" "$1" --csv "$1/conservation.csv" 2>/dev/null |
		sed "s/^/  $2 /"
}

for rep in 1 2; do
	echo "=== $(date -u +%FT%TZ) ladder r$rep ==="
	sudo env "${COMMON[@]}" MOQ="$FFA/moq" RELAY="$FFA/moq-relay" OUT="$ROOT/ladder-r$rep" \
		bash "$HERE/t28-t31-moq-ladder.sh" control outage-5s step-1.0x-60s step-0.9x-60s \
		>"$ROOT/ladder-r$rep.log" 2>&1
	conserve "$ROOT/ladder-r$rep" "ladder-r$rep"
	grep -h "DID NOT START" "$ROOT/ladder-r$rep.log" | sed "s/^/  ladder-r$rep /"
	sleep 5
done

echo "=== $(date -u +%FT%TZ) matched ==="
sudo env "${COMMON[@]}" BIN="$FFA" OUT="$ROOT" LANES="moq srt" BUDGETS=2 REPS=2 \
	IMPAIRS="none outage loss5" bash "$HERE/t28-t31-srt-ladder.sh" matched >"$ROOT/matched.log" 2>&1
conserve "$ROOT/matched" matched
echo "=== $(date -u +%FT%TZ) topology done ==="
