#!/usr/bin/env bash
# T60 start trials, driven from the workstation (lab/test-60-aligned-leg-start.md).
#
#   t60-trials.sh ARM N [FIRST]   ARM: same (both legs on pathway A), cross (A and B), control
#                                 (cross, unaligned); g-h, y-z (T61's origin group under two paths
#                                 cached apart); x, pdt-x (T63: g and h, leg B's namespace pinned
#                                 to another edge; pdt-x releases on the program date-time);
#                                 trials are numbered from FIRST (1)
#
# Each trial records both legs, starts leg A, starts leg B a random 3-25 s later, lets both emit
# together for at least 20 s, kills them and grades the pcap with t60-skew.py on the receiver
# host, then deletes it. One JSON line per trial is appended to $P59_HOME/runs/t60-ARM.jsonl.
# Env: ALIGN_MS (30000), PACER (the receiver host's 2eea651 build), RX (moq-tertiary),
# RELEASE_MS (pdt-x's hold, 1500).

set -uo pipefail
ARM=${1:?usage: t60-trials.sh same|cross|control N}
N=${2:?usage: t60-trials.sh same|cross|control N}
RX=${RX:-moq-tertiary}
P59_HOME=${P59_HOME:-$HOME/p59-local}
. "$P59_HOME/cf.env"
URL=https://$CF_DOMAIN
PACER=${PACER:-/home/ubuntu/pacer-2eea651/mpegts-pacer}
ALIGN_MS=${ALIGN_MS:-30000}
OUT=$P59_HOME/runs/t60-$ARM.jsonl
mkdir -p "$P59_HOME/runs"

A_PATH=a
RELEASE=
case $ARM in
same) B_PATH=a ALIGN=$ALIGN_MS ;;
cross) B_PATH=b ALIGN=$ALIGN_MS ;;
control) B_PATH=b ALIGN= ;;
g-h | y-z) A_PATH=${ARM%-*} B_PATH=${ARM#*-} ALIGN=$ALIGN_MS ;;
x) A_PATH=g B_PATH=h ALIGN=$ALIGN_MS ;;
pdt-x) A_PATH=g B_PATH=h ALIGN=$ALIGN_MS RELEASE=${RELEASE_MS:-1500} ;;
*) echo "unknown arm $ARM" >&2; exit 2 ;;
esac
WAIT=$((${ALIGN:-0} / 1000 + 12 + 20))

rx() { ssh -o BatchMode=yes "$RX" "cd ~/p59 && sudo PACER=$PACER ALIGN_MS=$ALIGN RELEASE_MS=$RELEASE bash t59-legs.sh $*"; }

FIRST=${3:-1}
for trial in $(seq "$FIRST" $((FIRST + N - 1))); do
	offset=$((3 + RANDOM % 23))
	run=/home/ubuntu/p59/runs/t60-$ARM-$trial-$(date -u +%Y%m%dT%H%M%SZ)
	rx rec-start "$run" >/dev/null
	rx leg-start a "$run" "$URL/$A_PATH/index.m3u8" 300 >/dev/null
	sleep "$offset"
	rx leg-start b "$run" "$URL/$B_PATH/index.m3u8" 300 >/dev/null
	sleep "$WAIT"
	rx leg-kill a "$run" >/dev/null
	rx leg-kill b "$run" >/dev/null
	rx rec-stop "$run" >/dev/null
	line=$(ssh -o BatchMode=yes "$RX" "python3 ~/p59/t60-skew.py $run/legs.pcap")
	gain=$(ssh -o BatchMode=yes "$RX" "for l in a b; do grep -o 'align_gain_us=[0-9]*' $run/pacer-\$l.log | tail -n 1; done | tr '\n' ' '")
	ssh -o BatchMode=yes "$RX" "rm -f $run/legs.pcap"
	echo "{\"arm\":\"$ARM\",\"trial\":$trial,\"offset_s\":$offset,\"gain\":\"$gain\",\"run\":\"$run\",\"grade\":$line}" | tee -a "$OUT"
done
