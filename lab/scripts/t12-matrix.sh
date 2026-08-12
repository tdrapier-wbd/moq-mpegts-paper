#!/usr/bin/env bash
# T12 — run the arm x injection matrix and summarise every cell.
#
# Each cell is one t12-dual-leg.sh run, followed by the receiver-side oracle and a
# TSDuck verdict on both selection policies. Arm c has one upstream chain, so it
# takes the path injections only; the upstream ones are not applicable to it and
# are skipped rather than reported as failures.
#
# Usage: ./t12-matrix.sh [arms] [injections]
#   ARMS=c ./t12-matrix.sh                     # one arm, all its injections
#   INJECTIONS="none blackout" ./t12-matrix.sh # one condition across all arms
set -euo pipefail

ARMS=${ARMS:-"c a b d"}
PATH_INJECTIONS=${PATH_INJECTIONS:-"none blackout loss1 loss3 delay50"}
CHAIN_INJECTIONS=${CHAIN_INJECTIONS:-"killpub termpub killrelay killegress quicloss_recover"}
SECS=${SECS:-60}
AT=${AT:-30}
K_MS=${K_MS:-50,100,250,500}
OUTDIR=${OUTDIR:-$HOME/t12/runs}
HERE=$(cd "$(dirname "$0")" && pwd)
SUMMARY=${SUMMARY:-$OUTDIR/summary.csv}
SELECT=${SELECT:-$OUTDIR/select.csv}

mkdir -p "$OUTDIR"

cell() { # arm inject [label]
	local arm=$1 inject=$2 label=${3:-"${1}_${2}"}
	echo "===== arm $arm / $inject ====="
	if ! ARM=$arm INJECT=$inject SECS=$SECS AT=$AT OUTDIR=$OUTDIR \
		"$HERE/t12-dual-leg.sh" "$label" >"$OUTDIR/$label.runlog" 2>&1; then
		echo "    CELL DID NOT RUN — see $OUTDIR/$label.runlog"
		tail -3 "$OUTDIR/$label.runlog" | sed 's/^/    /'
		return 0
	fi
	tail -2 "$OUTDIR/$label.runlog" | sed 's/^/    /'

	# Grading is one script so that a re-grade from the pcaps and a fresh run
	# produce the same columns; it reads meta.json for the arm and injection.
	K_MS=$K_MS "$HERE/t12-grade.sh" "$OUTDIR/$label" "$SUMMARY" "$SELECT"
	sleep 5
}

for arm in $ARMS; do
	for inject in $PATH_INJECTIONS; do
		cell "$arm" "$inject"
	done
	[ "$arm" = c ] && continue   # one upstream chain: chain injections are n/a
	for inject in $CHAIN_INJECTIONS; do
		cell "$arm" "$inject"
	done
done

echo; echo "===== alignment / seq-merge ====="; column -s, -t "$SUMMARY"
echo; echo "===== input-select sweep ====="; column -s, -t "$SELECT"
