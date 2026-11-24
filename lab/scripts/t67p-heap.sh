#!/usr/bin/env bash
# T67 — the shadow's memory growth, profiled: two shadows side by side on the live feed.
#
# usage: t67p-heap.sh <jemalloc bin dir> <control bin dir> <out dir> [hours]
#
# Arm J runs t67p-shadow.sh on a build with upstream's `jemalloc` feature (moq-relay/jemalloc,
# moq-cli/jemalloc), profiling from startup; arm G runs it on the same commit's default build, the
# allocator the growth was seen on. Both join the same group, each with its own relay. Every hour,
# and two minutes before the end, each arm-J process gets SIGUSR1 and dumps a heap profile into
# J/heap/ (logged in dumps.txt). Signals go only to processes whose executable path is the jemalloc
# bin dir: SIGUSR1 ends a build without the handler.
#
# env: PORT_J (4824), PORT_G (4825), LG_PROF_SAMPLE (16, upstream's bench); the rest as t67p-shadow.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
JBIN=${1:?jemalloc bin dir}
GBIN=${2:?control bin dir}
OUT=${3:?out dir}
HOURS=${4:-24}
mkdir -p "$OUT/J/heap" "$OUT/G"
now() { date +%s.%N | cut -c1-14; }

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

MALLOC_CONF="prof:true,prof_active:true,lg_prof_sample:${LG_PROF_SAMPLE:-16},prof_prefix:$OUT/J/heap/jeprof" \
	PORT=${PORT_J:-4824} bash "$HERE/t67p-shadow.sh" "$JBIN" "$OUT/J" "$HOURS" >"$OUT/J.out" 2>&1 &
PIDS+=($!)
PORT=${PORT_G:-4825} bash "$HERE/t67p-shadow.sh" "$GBIN" "$OUT/G" "$HOURS" >"$OUT/G.out" 2>&1 &
PIDS+=($!)

dump() {
	local p
	for p in $(pgrep -f -- "^$JBIN/moq(-relay)? "); do
		kill -USR1 "$p" && echo "$(now) $1 $p $(tr '\0' ' ' </proc/"$p"/cmdline | cut -c1-80)" >>"$OUT/dumps.txt"
	done
}

start=$(date +%s)
for k in $(seq 1 "$HOURS"); do
	at=$((start + k * 3600))
	[ "$k" -lt "$HOURS" ] || at=$((at - 120))
	d=$((at - $(date +%s)))
	[ "$d" -le 0 ] || sleep "$d"
	dump "h$k"
done
wait
