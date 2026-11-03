#!/usr/bin/env bash
# The withdrawal rule's offline test (lab/test-76-*.md): t61-epochseg.py with and without --peer on
# a 40 s cut of the clip, clean and with a run of packets removed mid-stream, as T62's breaks were.
#
#   t76-withdraw-test.sh [CLIP] [WORK]      exit 0 when every case holds
#
# Cases: legacy (no --peer: the error withdraws), shared (both pathways cut the damaged stream:
# both publish, every segment identical), unshared (the peer cut the clean stream: this pathway
# deletes its damaged segment and withdraws; the clean one never asks), unreachable (no peer:
# published, unverified).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
CLIP=${1:-$HOME/contrib-10m.ts}
W=${2:-/tmp/t76w}
SEG=$H/t61-epochseg.py
rm -rf "$W" && mkdir -p "$W"
head -c $((188 * 264000)) "$CLIP" >"$W/clean.ts"
python3 - "$W/clean.ts" "$W/damaged.ts" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
cut = 120000 * 188
open(sys.argv[2], "wb").write(data[:cut] + data[cut + 600 * 188:])
EOF
fail=0
check() { # <label> <condition...>
	local label=$1
	shift
	if "$@"; then echo "ok   $label"; else echo "FAIL $label"; fail=1; fi
}
run() { # <dir> <input> [args...]
	local dir=$1 in=$2
	shift 2
	python3 "$SEG" "$W/$dir" --file "$W/$in" --extra 1000 "$@" 2>"$W/$dir.log"
}
segs() { (cd "$W/$1" && for f in seg-*.ts; do echo "$f $(shasum "$f" | cut -c1-40)"; done | sort); }
has() { grep -q "$2" "$W/$1.log"; }

run legacy damaged.ts
check "legacy: the error withdraws" has legacy "reset cc pid="

run shared-b damaged.ts --peer "file://$W/shared-a/" --peer-wait 1
run shared-a damaged.ts --peer "file://$W/shared-b/" --peer-wait 1
k=$(sed -n 's/.* damaged k=\([0-9]*\) .*/\1/p' "$W/shared-a.log" | head -1)
check "shared: a segment is cut across the damage (k=$k)" test -n "$k"
check "shared: the later pathway finds the same digest" has shared-a "shared k=$k"
check "shared: the earlier finds none and publishes" has shared-b "unverified k=$k missing"
check "shared: neither withdraws" test "$(grep -c ' reset ' "$W/shared-a.log" "$W/shared-b.log" | awk -F: '{s+=$2} END {print s}')" = 2
check "shared: the two pathways' segments are identical" cmp -s <(segs shared-a) <(segs shared-b)
listed() { awk -v k="$2" '/ shared k=/ {s=1} s && / playlist msn=/ {split($3, m, "="); if (m[2] <= k && k < m[2] + 6) f=1} END {exit !f}' "$W/$1.log"; }
check "shared: the next playlist lists the damaged segment" listed shared-a "$k"

run unshared-clean clean.ts --peer "file://$W/unshared-damaged/" --peer-wait 1
run unshared-damaged damaged.ts --peer "file://$W/unshared-clean/" --peer-wait 1
check "unshared: the clean pathway never asks" bash -c "! grep -q damaged '$W/unshared-clean.log'"
check "unshared: the damaged pathway finds a different digest" has unshared-damaged "unshared k=$k"
check "unshared: and withdraws" has unshared-damaged "reset unshared damage k=$k"
check "unshared: its damaged segment is deleted" test ! -e "$W/unshared-damaged/seg-$k.ts"
check "unshared: the peer's copy is there to fail over to" test -e "$W/unshared-clean/seg-$k.ts"
check "unshared: every segment it kept is the peer's" bash -c "comm -23 <(cd '$W/unshared-damaged' && for f in seg-*.ts; do echo \"\$f \$(shasum \"\$f\" | cut -c1-40)\"; done | sort) <(cd '$W/unshared-clean' && for f in seg-*.ts; do echo \"\$f \$(shasum \"\$f\" | cut -c1-40)\"; done | sort) | grep -q . && exit 1 || exit 0"

run unreachable damaged.ts --peer http://127.0.0.1:9/ --peer-wait 1
check "unreachable: published, unverified" has unreachable "unverified k=$k unreachable"
check "unreachable: no withdrawal" test "$(grep -c ' reset ' "$W/unreachable.log")" = 1

exit $fail
