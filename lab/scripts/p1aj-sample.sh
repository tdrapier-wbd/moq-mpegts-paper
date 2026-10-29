#!/usr/bin/env bash
# One resource line per role per minute, for a soak (P1-aj): "epoch role pid rss_kb cpu_ticks",
# and the root file system's free space as role "disk".
#
#   p1aj-sample.sh OUT ROLE=REGEX...      e.g. seg='^python3 .*t61-epochseg'
#
# Anchor each REGEX at the start of the command line, so it cannot match this sampler's own.

set -uo pipefail
OUT=${1:?usage: p1aj-sample.sh OUT ROLE=REGEX...}
shift
while :; do
	t=$(date +%s)
	{
		for spec in "$@"; do
			for p in $(pgrep -f -- "${spec#*=}"); do
				rss=$(awk '/^VmRSS/ {print $2}' "/proc/$p/status" 2>/dev/null)
				ticks=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null)
				echo "$t ${spec%%=*} $p ${rss:-0} ${ticks:-0}"
			done
		done
		echo "$t disk 0 $(df -k / | awk 'NR == 2 {print $4}') 0"
	} >>"$OUT"
	sleep 60
done
