#!/usr/bin/env bash
# F5 reset — clear any previous F5 processes on this host and prove it worked.
#
#   f5-reset.sh [broadcast]
#
# This exists because of a specific way the ramp failed. Cleanup was being done by passing `pkill -f
# "broadcast f5.fanout.hang"` over ssh, and the broadcast name is then part of the remote shell's own
# command line, so pkill matched the shell that was running it and killed itself before reaching the
# next statement. A stale publisher survived, a second publisher announced the same broadcast, and the
# relay terminated one of the two sessions about a minute in — which read, in the results, as the
# source spontaneously failing at n=1.
#
# Two rules follow, and they are the reason this is a file rather than a line:
#   1. Kill patterns live in a script, never in the ssh command line.
#   2. A reset that does not verify is not a reset. This one counts survivors and fails loudly,
#      because the alternative is a scaling curve contaminated by the previous run's processes.
set -uo pipefail

B=${1:-f5.fanout.hang}
PORT=${PORT:-4443}

# Bracketed so the pattern cannot match this script's own pgrep/pkill invocations.
PATTERNS=(
	"[f]5-sub-side.sh"
	"[f]5-relay-side.sh"
	"[t]s-continuous-source.py"
	"[m]oq-relay --server-bind 0.0.0.0:${PORT}"
	# Bracketed like the rest: unbracketed, this matched any shell whose command
	# line merely contained the string — including the ssh invocation that called
	# this script, which then killed its own caller before doing anything else.
	"[e]xport ts --latency-max"
)
# The broadcast name is built at runtime so it never appears literally in an argv
# that an operator might paste into a remote shell.
PATTERNS+=("$(printf '[%s]%s' "${B:0:1}" "${B:1}")")

for sig in TERM KILL; do
	for p in "${PATTERNS[@]}"; do pkill -"$sig" -f "$p" 2>/dev/null || true; done
	sleep 1
done

# tsp instances belonging to F5 only: the graded readers and the source regulator.
pkill -9 -f "[t]sp -I file .*fifo" 2>/dev/null || true
pkill -9 -f "[t]sp -I file - -P regulate" 2>/dev/null || true
rm -f "$HOME"/f5/*/fifo.* 2>/dev/null || true

sleep 1
LEFT=0
for p in "${PATTERNS[@]}"; do
	# `pgrep -c` already prints 0 and exits non-zero when nothing matches, so an
	# `|| echo 0` fallback appends a second zero and the comparison then fails.
	n=$(pgrep -cf "$p" 2>/dev/null | head -1)
	n=${n:-0}
	[ "$n" -gt 0 ] && {
		echo "f5-reset: STILL RUNNING ($n): $p" >&2
		LEFT=$((LEFT + n))
	}
done

if [ "$LEFT" -gt 0 ]; then
	echo "f5-reset: FAILED — $LEFT process(es) survived; do not start a run" >&2
	exit 1
fi
echo "f5-reset: clean on $(hostname) (broadcast $B, port $PORT)"
