#!/usr/bin/env bash
# P0-j — what a real backward step on the live feed costs a subscriber, and what the step is.
#
#   p0j-step-watch.sh ring <out-dir> <hours>                                   # ingesting host
#   p0j-step-watch.sh watch <bin-dir> <out-dir> <hours> <origin> <broadcast>   # subscriber host
#
# ring: keeps the last RING_S seconds of the hand-off in RAM (TSDuck's rotating file output under
#   /dev/shm, SEG_S s a file) and writes nothing else. When the standing publisher's restart counter
#   moves, it waits POST_S s, then copies the ring and the publisher's journal around the exit to
#   <out>/events/<UTC>/. It stops after <hours> or MAX_EVENTS events, so the feed reaches the disk
#   only around an exit.
# watch: a standing `export ts` of the standing broadcast piped into ts-liveness.py, its output
#   dropped, restarted whenever it ends; logs each export's start and end and every liveness event.
#
# env: GROUP (239.255.0.1:5000), RING_S (60), SEG_S (20), POST_S (20), MAX_EVENTS (10),
#      UNIT (moq-live-publisher), MAX_AGE (2s)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE=${1:?ring or watch}
shift
GROUP=${GROUP:-239.255.0.1:5000}
RING_S=${RING_S:-60}
SEG_S=${SEG_S:-20}
POST_S=${POST_S:-20}
MAX_EVENTS=${MAX_EVENTS:-10}
UNIT=${UNIT:-moq-live-publisher}
MAX_AGE=${MAX_AGE:-2s}

utc() { date -u +%FT%TZ; }

case $ROLE in
ring)
	OUT=${1:?out dir} HOURS=${2:?hours}
	SHM=/dev/shm/p0j-ring
	mkdir -p "$OUT/events" "$SHM"
	rm -f "$SHM"/*.ts
	tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size 16777216 \
		-O file "$SHM/ring.ts" --max-duration "$SEG_S" --max-files $((RING_S / SEG_S + 1)) \
		2>"$OUT/ring-tsp.log" &
	RING=$!
	trap 'kill $RING 2>/dev/null; rm -rf "$SHM"' EXIT
	trap 'exit 0' INT TERM
	end=$(($(date +%s) + HOURS * 3600))
	last=$(systemctl show -p NRestarts --value "$UNIT")
	echo "$(utc) start restarts=$last ring=${RING_S}s" >>"$OUT/ring.log"
	n=0
	while [ "$(date +%s)" -lt "$end" ] && [ "$n" -lt "$MAX_EVENTS" ]; do
		sleep 2
		kill -0 "$RING" 2>/dev/null || { echo "$(utc) ring tsp died" >>"$OUT/ring.log"; exit 1; }
		now=$(systemctl show -p NRestarts --value "$UNIT")
		[ "$now" = "$last" ] && continue
		seen=$(utc)
		sleep "$POST_S"
		n=$((n + 1))
		ev="$OUT/events/$seen"
		mkdir -p "$ev"
		cp "$SHM"/*.ts "$ev/"
		sudo journalctl -u "$UNIT" --since "-$((POST_S + 90))s" --no-pager -o short-iso |
			sed 's/\x1b\[[0-9;]*m//g' >"$ev/journal.txt"
		echo "$(utc) event $n restarts $last->$now seen=$seen" >>"$OUT/ring.log"
		last=$now
	done
	echo "$(utc) stop events=$n" >>"$OUT/ring.log"
	;;
watch)
	BIN=${1:?bin dir} OUT=${2:?out dir} HOURS=${3:?hours} ORIGIN=${4:?origin} BCAST=${5:?broadcast}
	mkdir -p "$OUT"
	end=$(($(date +%s) + HOURS * 3600))
	n=0
	while [ "$(date +%s)" -lt "$end" ]; do
		n=$((n + 1))
		echo "$(utc) start $n" >>"$OUT/exports.log"
		timeout -s INT $((end - $(date +%s))) "$BIN/moq" --connect-tls-insecure \
			--connect "https://$ORIGIN:443/anon" --broadcast "$BCAST" export ts --max-age "$MAX_AGE" \
			2>>"$OUT/export.log" |
			python3 "$HERE/ts-liveness.py" - --warmup 10 --learn 40 --jsonl \
				>>"$OUT/liveness.jsonl" 2>>"$OUT/liveness.err"
		echo "$(utc) end $n rc=${PIPESTATUS[0]}" >>"$OUT/exports.log"
		sleep 1
	done
	;;
*)
	echo "unknown role $ROLE" >&2
	exit 2
	;;
esac
