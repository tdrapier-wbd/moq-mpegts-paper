#!/usr/bin/env bash
#
# T8b conditions C2–C5 — the matrix, one cell at a time.
#
#   sudo t8b-provisioned-matrix.sh [c2] [c3] [c4] [c5] ...
#
# Cells are run strictly in series. Two congestion cells sharing two vCPUs measure each
# other, and this box has two.
#
#   C2  transient congestion   a greedy TCP flow arrives 40 s into a 120 s window and leaves
#                              at 80 s, on a cap provisioned at 1.5x the feed. The priority
#                              condition: the realistic threat to a provisioned trunk is not
#                              a permanent shortfall but a temporary one.
#   C3  coexistence            N media flows of the same transport share one provisioned
#                              class. Only the transports that can be run N-up are in it.
#   C4  AQM counterfactual     C1's under-provisioned cap again, with fq_codel and cake in
#                              place of the deep FIFO, so the C1 ranking can be read as a
#                              property of the transports rather than of one queue.
#   C5  provisioning margin    the cap swept 1.5x / 1.2x / 1.1x / 1.0x the feed, to find
#                              where each transport begins to lose content. This is the
#                              economics input: it prices the headroom each one needs.
#
# Replicates are not uniform, and the reason is C1: it found one bimodal controller (BBRv1,
# two replicates at ~230 ms of queue and one at 591 ms), so a single replicate cannot be
# trusted where the output is a *ranking*. C2 and C4 rank, and take two. C5 sweeps a ladder,
# where adjacent rungs corroborate each other and a second replicate buys less than a third
# cap would — so it takes one. BBRv3 is known broken (noq #768) and is carried only in C4,
# where the question "does AQM rescue it" is worth one cell each way rather than repeated
# everywhere.
set -uo pipefail

NETNS=${NETNS:-/home/ubuntu/t8b/t8b-netns.sh}
CELL=${CELL:-/home/ubuntu/t8b/t8b-provisioned.sh}
DIR=${DIR:-/home/ubuntu/t8b/prov}
FEED_MBIT=${FEED_MBIT:-9.95}
ALL=${ALL:-"cubic bbr1 bbr2 srt seg segpull"}
NOBBR3=${NOBBR3:-"cubic bbr1 bbr2 srt seg segpull"}

[ "$(id -u)" -eq 0 ] || {
	echo "run as root" >&2
	exit 1
}
mkdir -p "$DIR"

bash "$NETNS" up >/dev/null 2>&1 || {
	echo "netns up failed" >&2
	exit 1
}
trap 'bash "$NETNS" down >/dev/null 2>&1' EXIT

run() { # <label> <env assignments...>
	local label=$1
	shift
	echo "--- $label  ($*)"
	env "$@" bash "$CELL" "$label" 2>&1 | grep -E '^RESULT|error|failed' || true
	sleep 5
}

cond_c2() {
	local r t
	for r in 1 2; do
		for t in $NOBBR3; do
			run "c2-$t-r$r" TRANSPORT="$t" CAP_MBIT=15 QDISC=bloat SECS=120 COMPETE=40-80
		done
	done
}

cond_c3() {
	local t n
	for n in 2 3; do
		for t in cubic bbr1 srt; do
			run "c3-$t-n$n" TRANSPORT="$t" CAP_MBIT=15 QDISC=bloat SECS=90 NFLOWS="$n"
		done
	done
}

cond_c4() {
	local r t q
	for q in codel cake; do
		for r in 1 2; do
			for t in $NOBBR3; do
				run "c4-$t-$q-r$r" TRANSPORT="$t" CAP_MBIT=5 QDISC="$q" SECS=60
			done
		done
		run "c4-bbr3-$q" TRANSPORT=bbr3 CAP_MBIT=5 QDISC="$q" SECS=60
	done
}

cond_c5() {
	local t c
	for c in 15 12 11 10; do
		for t in $NOBBR3; do
			run "c5-$t-cap$c" TRANSPORT="$t" CAP_MBIT="$c" QDISC=bloat SECS=60
		done
	done
}

for cond in "$@"; do
	echo "=== $cond  (feed ~${FEED_MBIT} Mb/s)"
	case "$cond" in
	c2) cond_c2 ;;
	c3) cond_c3 ;;
	c4) cond_c4 ;;
	c5) cond_c5 ;;
	*) echo "unknown condition '$cond'" >&2 ;;
	esac
done

echo
echo "=== all results"
cat "$DIR/results.txt"
