#!/usr/bin/env bash
# T71: one cell, driven from the workstation across both hosts.
#
#   [BUFMS=1000 DELAY=1s] ORIGIN_IP=<addr> ORIGIN=<ssh alias> FAR=<ssh alias> \
#     t71-cell.sh <cell> <srt|opaque|aware|seg> <loss> [seconds]
#
# BUFMS is SRT's latency and the segmented lane's cushion, DELAY the MoQ export's; <loss> is a
# percentage, or ge:<p>,<r> for t71-far.sh's Gilbert model.
#
# The impairment, both clocks, the origin's source, the receive stage for <seconds>, both clocks
# again, the source stopped, netem's counters read and the impairment cleared; then the origin's
# source tap and clock reads are copied to the receiver, which grades every cell after the matrix.
# Remote work runs from ~/t71/scripts on each host, and a cell lands in ~/t71/runs/<cell> on both,
# with a copy of the small files in $LOG/<cell> here. One ssh call per step, so a failure names it;
# the source is stopped and the impairment cleared on any exit.
set -euo pipefail

CELL=${1:?cell name}
LANE=${2:?lane: srt, opaque or aware}
LOSS=${3:?loss %, 0 for clean}
SECS=${4:-120}
ORIGIN_IP=${ORIGIN_IP:?set ORIGIN_IP to the origin address the receiver dials}
ORIGIN=${ORIGIN:?set ORIGIN to the origin host ssh alias}
FAR=${FAR:?set FAR to the receiver host ssh alias}
LOG=${LOG:-$HOME/t71runs}
TO=${TO:-$(command -v gtimeout || command -v timeout)}
R=t71/runs/$CELL
BUFMS=${BUFMS:-1000}
DELAY=${DELAY:-1s}
FENV="ORIGIN_IP=$ORIGIN_IP BUFMS=$BUFMS DELAY=$DELAY"
OENV="BUFMS=$BUFMS"
BCAST="t71.$CELL.$(date +%s)"
mkdir -p "$LOG/$CELL"

on() {
	local h=$1 t=$2
	shift 2
	"$TO" "$t" ssh -o BatchMode=yes "$h" "$@" </dev/null
}
put() { "$TO" 60 ssh -o BatchMode=yes "$1" "cat > $2" <"$3"; }
step() { echo "$(date -u +%H:%M:%S) $CELL: $*"; }

cleanup() {
	on "$ORIGIN" 30 "bash t71/scripts/t71-origin.sh stop $R" >/dev/null 2>&1 || true
	on "$FAR" 30 "sudo $FENV bash t71/scripts/t71-far.sh clear" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -z "$(on "$FAR" 30 "ls $R/egress.ts 2>/dev/null")" ] || {
	echo "$R already holds a capture; choose another cell name" >&2
	trap - EXIT
	exit 1
}

step "impair $LOSS %, $LANE, ${SECS}s"
on "$FAR" 30 "sudo $FENV bash t71/scripts/t71-far.sh impair $LOSS"
on "$ORIGIN" 30 "mkdir -p $R && cp t71/fix/relay-build.txt $R/ && { echo '== before'; chronyc -n tracking; } >> $R/clock-origin.txt"
on "$FAR" 60 "$FENV bash t71/scripts/t71-far.sh clock $R before"

step "source"
on "$ORIGIN" 30 "$OENV bash t71/scripts/t71-origin.sh start $R $LANE $SECS $BCAST"

step "receive"
on "$FAR" "$((SECS + 120))" "$FENV bash t71/scripts/t71-far.sh recv $R $LANE $SECS $BCAST"

step "clocks after, stop, counters"
on "$FAR" 60 "$FENV bash t71/scripts/t71-far.sh clock $R after"
on "$ORIGIN" 30 "{ echo '== after'; chronyc -n tracking; } >> $R/clock-origin.txt; bash t71/scripts/t71-origin.sh stop $R"
on "$FAR" 30 "echo 'loss=$LOSS' > $R/impair.txt; sudo $FENV bash t71/scripts/t71-far.sh counters $R/impair.txt"
on "$FAR" 30 "sudo $FENV bash t71/scripts/t71-far.sh clear"

step "collect"
on "$ORIGIN" 60 "cd $R && tar -cf - source.csv clock-origin.txt relay-build.txt source.log \$(ls segmenter.log ngx/access.log 2>/dev/null)" >"$LOG/$CELL/origin.tar"
tar -xf "$LOG/$CELL/origin.tar" -C "$LOG/$CELL"
put "$FAR" "$R/origin.tar" "$LOG/$CELL/origin.tar"
on "$FAR" 60 "tar -xf $R/origin.tar -C $R && rm $R/origin.tar && cd $R && tar -cf - clock-far.txt impair.txt recv-events.log receive.log \$(ls recv.jsonl recv.err pacer.log 2>/dev/null)" |
	tar -xf - -C "$LOG/$CELL"
rm "$LOG/$CELL/origin.tar"
echo "lane=$LANE loss=$LOSS secs=$SECS bufms=$BUFMS delay=$DELAY broadcast=$BCAST" >"$LOG/$CELL/cell.txt"

trap - EXIT
step "done: $(on "$FAR" 30 "stat -c %s $R/egress.ts") egress bytes; $(grep -c . "$LOG/$CELL/source.csv") source rows; $(tr '\n' ' ' <"$LOG/$CELL/impair.txt")"
