#!/usr/bin/env bash
# The arm matrix for cluster-failover.sh: shared hop against fresh identities, a hard kill against
# a clean end of input, three replicates of each at a 6 s relay idle timeout and one at the default,
# then two join-offset diagnostics. Replicates are interleaved across arms, so a drift on the host
# cannot line up with one arm. One RESULT line per run lands in <outdir>/summary.txt.
#
# Usage: cluster-failover-arms.sh <bin-dir> <outdir>
set -uo pipefail
BIN=${1:?bin dir}
OUT=${2:?output directory}
RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster-failover.sh"
mkdir -p "$OUT"
mkdir "$OUT/.lock" 2>/dev/null || { echo "another matrix holds $OUT/.lock"; exit 1; }
trap 'rmdir "$OUT/.lock"' EXIT
run() { # <label> <env...>
	local label=$1
	shift
	echo "$(date -u +%FT%TZ) start $label" >>"$OUT/progress.log"
	env "$@" bash "$RIG" "$BIN" "$OUT/$label" >"$OUT/$label.out" 2>&1
	grep '^RESULT' "$OUT/$label.out" | sed "s/^/$label /" >>"$OUT/summary.txt"
}
for r in 1 2 3; do
	run "shared-kill-6s-r$r" HOP=424242 SIDLE=6s EVENT=kill
	run "fresh-kill-6s-r$r" HOP= SIDLE=6s EVENT=kill
	run "shared-eof-6s-r$r" HOP=424242 SIDLE=6s EVENT=eof
	run "fresh-eof-6s-r$r" HOP= SIDLE=6s EVENT=eof
done
run shared-kill-30s-r1 HOP=424242 EVENT=kill
run fresh-kill-30s-r1 HOP= EVENT=kill
run shared-eof-30s-r1 HOP=424242 EVENT=eof
run fresh-eof-30s-r1 HOP= EVENT=eof
# The standby's lag behind the active, in seconds of groups, is JOIN + 4 at the kill.
run diag-shared-kill-6s-join0 HOP=424242 SIDLE=6s EVENT=kill JOIN=0 EVENT_AT=22
run diag-shared-kill-6s-join20 HOP=424242 SIDLE=6s EVENT=kill JOIN=20 EVENT_AT=22
echo "$(date -u +%FT%TZ) done" >>"$OUT/progress.log"
