#!/usr/bin/env bash
# One T59 cell, driven from the workstation (lab/test-59-segmented-1plus1-cloudfront.md).
#
#   t59-cell.sh CELL [SECONDS]      CELL: clean pack-kill pack-freeze origin-down recv-restart loss inject
#                                   T61's: seg-kill seg-freeze ngx-hang block (and clean, origin-down)
#
# Leg A's receiver starts at 0 and leg B's at 20 s; the cell's event strikes pathway A at 120 s.
# Each event is stamped by the host that performs it, so events.txt is on the hosts' clocks.
# The packagers are not started here: they run across cells (`inject` expects both restarted
# without --slice-only beforehand). Hosts by ssh alias: PA (pathway A), PB, RX (receivers).
# LEG_PATH puts both legs on one path (T61: g, the origin group); ALIGN_MS reaches the groomers,
# SETTLE (s, 40) the grader's b-settled cut.

set -uo pipefail
CELL=${1:?usage: t59-cell.sh CELL [SECONDS]}
SECS=${2:-300}
PA=${PA:-moq-primary}
RX=${RX:-moq-tertiary}
P59_HOME=${P59_HOME:-$HOME/p59-local}
. "$P59_HOME/cf.env"
RUN=/home/ubuntu/p59/runs/$CELL-$(date -u +%Y%m%dT%H%M%SZ)
URL=https://$CF_DOMAIN
LOCAL=$P59_HOME/runs/$(basename "$RUN")
mkdir -p "$LOCAL"
# One connection per host, reused: a fresh ssh costs about a second, which would land each event late.
SSH=(-o BatchMode=yes -o ControlMaster=auto -o "ControlPath=/tmp/p59-cm-%r@%h:%p" -o ControlPersist=900)
ssh "${SSH[@]}" "$PA" true
T0=$EPOCHREALTIME

PACER=${PACER:-/home/ubuntu/pacer-5626c88/mpegts-pacer}
LEG_A=${LEG_PATH:-a}
LEG_B=${LEG_PATH:-b}
rx() { ssh "${SSH[@]}" "$RX" "cd ~/p59 && sudo PACER=$PACER ALIGN_MS=${ALIGN_MS:-} bash t59-legs.sh $*"; }
pa() { ssh "${SSH[@]}" "$PA" "cd ~/p59 && NS=a bash t59-pathway.sh $*"; }
# Run an event on a host and stamp it there: "name epoch_ns" lines, as t55-grade.py reads them.
ev() {
	local name=$1 host=$2
	shift 2
	ssh "${SSH[@]}" "$host" "$* >/dev/null; t=\$EPOCHREALTIME; echo $name \${t/./}000" >>"$LOCAL/events.txt"
	echo "$(date -u +%T) $name"
}
at() {
	local d
	d=$(awk -v t0="$T0" -v n="$1" -v now="$EPOCHREALTIME" 'BEGIN { print t0 + n - now }')
	awk -v d="$d" 'BEGIN { exit !(d > 0) }' && sleep "$d"
}

echo "cell $CELL, $SECS s, t0 $T0, run $RUN"
rx rec-start "$RUN"
rx leg-start a "$RUN" "$URL/$LEG_A/index.m3u8" "$SECS"
at 20
rx leg-start b "$RUN" "$URL/$LEG_B/index.m3u8" "$((SECS - 20))"

L="cd ~/p59 && sudo PACER=$PACER ALIGN_MS=${ALIGN_MS:-} bash t59-legs.sh"
P="cd ~/p59 && NS=a bash t59-pathway.sh"
G="cd ~/p59 && bash t61-origin.sh"
at 120
case $CELL in
clean | inject) ;;
pack-kill)
	ev pack-kill "$PA" "$P pack-kill"
	at 130
	ev pack-start "$PA" "$P pack-start"
	;;
pack-freeze)
	ev pack-freeze "$PA" "$P pack-freeze"
	at 130
	ev pack-thaw "$PA" "$P pack-thaw"
	;;
origin-down)
	ev origin-down "$PA" "$P origin-stop"
	at 150
	ev origin-up "$PA" "$P origin-start"
	;;
recv-restart)
	ev recv-kill "$RX" "$L leg-kill a $RUN"
	at 130
	ev recv-start "$RX" "$L leg-start a $RUN $URL/$LEG_A/index.m3u8 $((SECS - 130))"
	;;
seg-kill | seg-freeze | ngx-hang | block)
	declare -A undo=([seg-kill]=seg-start [seg-freeze]=seg-thaw [ngx-hang]=ngx-thaw [block]=unblock)
	declare -A act=([seg-kill]=seg-kill [seg-freeze]=seg-freeze [ngx-hang]=ngx-freeze [block]=block)
	ev "${act[$CELL]}" "$PA" "$G ${act[$CELL]}"
	at 150
	ev "${undo[$CELL]}" "$PA" "$G ${undo[$CELL]}"
	;;
loss)
	ev loss-on "$RX" "$L netem a \"loss 2% delay 20ms\""
	at 180
	ev loss-off "$RX" "$L netem a off"
	;;
*) echo "unknown cell $CELL" >&2 ;;
esac

# The fetchers stop at SECS; each groomer then drains its cushion and prints its closing report.
at $((SECS + 14))
rx rec-stop "$RUN"
[ -f "$LOCAL/events.txt" ] && scp -q "$LOCAL/events.txt" "$RX:$RUN/events.txt"
ssh "${SSH[@]}" "$RX" "SETTLE=${SETTLE:-40} bash ~/p59/t59-grade.sh $RUN $SECS" | tee "$LOCAL/grade.txt"
echo "$CELL done; local events in $LOCAL"
