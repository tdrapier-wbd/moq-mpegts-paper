#!/bin/bash
# Capture <seconds> of each of the given loopback UDP outputs at once, then count video PES and
# packets and the table repeat gaps. usage: ma-window-grade.sh <seconds> <port>...
set -u
S=$1
shift
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/ma-window/grade}
mkdir -p "$OUT"
for p in "$@"; do
	tsp -I ip "$p" --local-address 127.0.0.1 -P until --seconds "$S" -O file "$OUT/$p.ts" 2>/dev/null &
done
wait
for p in "$@"; do
	echo "== port $p"
	python3 "$HERE/t83d-field-skip-count.py" "$OUT/$p.ts" /dev/null | head -3
	python3 "$HERE/ts-table-gaps.py" "$OUT/$p.ts" | tail -4
done
