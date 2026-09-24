#!/usr/bin/env bash
# Run the session's netns passes one after another, never two rigs at once: they share the
# t8b-pub/t8b-sub namespaces and the veth, and a second rig tears down the first one's.
#
#   1. the segmented ladder inside the netns rig        (t31-seg-netns.sh, ~20 min)
#   2. the cross-build bisection                         (t2831-build-bisect.sh, ~2.5 h)
#   3. replicates, then the absorption boundaries        (t2831-boundaries.sh, ~75 min)
#
# Waits for the re-run chain to finish and for the receiver-timing pass that follows it.
# Usage: t2831-queue.sh            (log: ~/t2831-queue.log)
# shellcheck disable=SC2024  # the logs belong to the invoking user, by intent
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while ! grep -q "chain done" "$HOME/t2831-rerun/chain.log" 2>/dev/null; do sleep 60; done
sleep 60
while pgrep -f "[t]20-recv-timing[.]sh" >/dev/null; do sleep 30; done

echo "=== $(date -u +%FT%TZ) segmented netns ladder ==="
sudo env OUT="$HOME/t31-seg-netns" bash "$HERE/t31-seg-netns.sh" >"$HOME/t31-seg-netns.log" 2>&1
echo "=== $(date -u +%FT%TZ) bisection ==="
bash "$HERE/t2831-build-bisect.sh" "$HOME/t2831-bisect" >"$HOME/t2831-bisect.log" 2>&1
echo "=== $(date -u +%FT%TZ) boundaries ==="
bash "$HERE/t2831-boundaries.sh" "$HOME/t2831-boundaries" >"$HOME/t2831-boundaries.log" 2>&1
echo "=== $(date -u +%FT%TZ) queue done ==="
