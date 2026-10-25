#!/usr/bin/env bash
# P1-aa: source-to-egress media timing across hosts, on one clock (lab/test-57-cross-host-timing.md).
#
# ROLE=egress, on the secondary: stamps this host's own hand-off of the feed (the loopback group its
# srt-ingest publishes; kernel receive stamps) and its export of the primary's import (the pipe;
# application stamps), with p1aa-tap.py, which records no media. The export runs under a supervisor
# that restarts it when it exits; each start and exit goes to events.txt.
# ROLE=handoff, on the primary: stamps that host's hand-off alone, so the two hand-offs' offset can
# be read across two chrony-disciplined clocks.
# Both log `chronyc -c tracking` every minute to chrony.csv, and stop after HOURS.
#
#   ROLE=egress BIN=<moq dir> URL=https://<primary>:443/anon BCAST=<broadcast> p1aa-timing.sh <label> [hours]
#   ROLE=handoff p1aa-timing.sh <label> [hours]
#
# Env: GROUP (239.255.0.1), GPORT (5000), DELAY (2s, the export's --delay), OUT (~/p1aa).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LABEL=${1:?label}
HOURS=${2:-72}
ROLE=${ROLE:?egress or handoff}
GROUP=${GROUP:-239.255.0.1}
GPORT=${GPORT:-5000}
DELAY=${DELAY:-2s}
OUT=${OUT:-$HOME/p1aa}/$LABEL
SECS=$(python3 -c "print(int($HOURS * 3600))")

mkdir -p "$OUT"
PIDS=()
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	echo "end $EPOCHREALTIME" >>"$OUT/events.txt"
	touch "$OUT/done"
}
trap cleanup EXIT
set -m
{
	echo "=== $(date -u +%FT%TZ) p1aa-timing $LABEL: role $ROLE on $(hostname), ${HOURS} h"
	[ "$ROLE" = egress ] && "$BIN/moq" --version && sed -n 1p "$BIN.sha" 2>/dev/null
	echo "hand-off $GROUP:$GPORT; export --delay $DELAY"
	chronyc tracking | sed -n '1,3p;5p;11,12p'
} >"$OUT/build.txt" 2>&1
echo "start $EPOCHREALTIME" >>"$OUT/events.txt"

python3 "$H/p1aa-tap.py" udp "$GROUP" "$GPORT" "$OUT/handoff.csv" --secs "$SECS" &
PIDS+=("$!")

if [ "$ROLE" = egress ]; then
	: "${BIN:?} ${URL:?} ${BCAST:?}"
	(
		while :; do
			echo "export_start $EPOCHREALTIME" >>"$OUT/events.txt"
			"$BIN/moq" --connect-tls-insecure --connect "$URL" --broadcast "$BCAST" export ts --delay "$DELAY" \
				2>>"$OUT/export.log"
			echo "export_exit_$? $EPOCHREALTIME" >>"$OUT/events.txt"
			sleep 2
		done | python3 "$H/p1aa-tap.py" stdin "$OUT/export.csv" --secs "$SECS"
	) &
	PIDS+=("$!")
fi

# unix seconds, then chronyc's CSV: ref id, name, stratum, ref time, system offset, last offset, RMS
# offset, frequency, residual frequency, skew, root delay, root dispersion, update interval, leap.
for ((i = 0; i * 60 < SECS; i++)); do
	echo "$(date +%s),$(chronyc -c tracking | head -1)" >>"$OUT/chrony.csv"
	sleep 60
done
