#!/usr/bin/env bash
# One step of a `git bisect run` over the client build, for the pass-join exporter stall.
#
#   cd ~/moq-dev && git bisect start HEAD <good-sha> && git bisect run ~/f5/t27-bisect-step.sh
#
# Builds the CLI at the commit under test, then crosses several content-loop joins with two
# subscribers: the candidate and a known-good binary as an in-run control. The clip is a ~30 s
# truncation of the full one, so a join arrives every ~30 s instead of every 600 s and a step costs
# minutes; the discriminator does not depend on the pass length, only on the join.
#
# Exit 0 good, 1 bad, 125 skip (build failed, or the control also stalled and the run is void).
set -uo pipefail

# `git bisect run` inherits a non-login shell, which on this host has no cargo on its PATH; without
# this every step exits 125 in a second and bisect reports every commit as a possible culprit.
PATH=$HOME/.cargo/bin:$PATH
export PATH

REPO=${REPO:-$HOME/moq-dev}
GOOD=${GOOD:-$HOME/bin-merged/moq}
RELAY_IP=${RELAY_IP:?set RELAY_IP}
CLIP=${CLIP:-$HOME/clip30.ts}
DUR=${DUR:-150}
# Ignore the first SETTLE seconds: a subscriber's first samples include its own attach transient.
SETTLE=${SETTLE:-50}
# A healthy lane sits near the clip rate; a stuck exporter emits only PSI and the surviving PIDs.
FLOOR=${FLOOR:-5.0}

SHA=$(git -C "$REPO" rev-parse --short HEAD)
LOG=$HOME/t27/bisect/$SHA
mkdir -p "$LOG"

echo "=== bisect $SHA: build"
if ! (cd "$REPO" && cargo build --release -p moq-cli) >"$LOG/build.log" 2>&1; then
	echo "=== bisect $SHA: BUILD FAILED -> skip"
	exit 125
fi
BIN=$LOG/moq
cp "$REPO/target/release/moq" "$BIN"

echo "=== bisect $SHA: run"
CLIP=$CLIP OUT=$LOG/run BCAST=t27bis.$SHA.hang \
	MOQ=$BIN "$HOME/f5/t27-join-control.sh" b "$RELAY_IP" "$DUR" \
	"3s@$BIN,3s@$GOOD" >"$LOG/run.log" 2>&1

CSV=$LOG/run/b/rates.csv
[ -s "$CSV" ] || {
	echo "=== bisect $SHA: no samples -> skip"
	exit 125
}

# Column 2 is the candidate, column 3 the control; report the worst post-settle sample of each.
read -r CAND CTRL < <(awk -F, -v s="$SETTLE" '
	NR>1 && $1>=s { if (n++==0 || $2<a) a=$2; if (m++==0 || $3<b) b=$3 }
	END { printf "%.2f %.2f\n", a, b }' "$CSV")

echo "=== bisect $SHA: worst candidate=${CAND} Mb/s  control=${CTRL} Mb/s  (floor ${FLOOR})"
awk -v c="$CTRL" -v f="$FLOOR" 'BEGIN{exit !(c<f)}' && {
	echo "=== bisect $SHA: CONTROL STALLED -> void, skip"
	exit 125
}
awk -v c="$CAND" -v f="$FLOOR" 'BEGIN{exit !(c<f)}' && {
	echo "=== bisect $SHA: BAD"
	exit 1
}
echo "=== bisect $SHA: GOOD"
exit 0
