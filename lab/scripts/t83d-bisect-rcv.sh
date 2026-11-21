#!/usr/bin/env bash
# The receiving side of `t83d-bisect.sh`: runs each job the board posts as `t83d-skip.sh`'s rcv role,
# grades it with `t83d-evict.py`, and uploads the grade and the run's logs. On "done", or past
# DEADLINE, it ends, and with HALT=1 stops the host unless KEEP exists.
#
#   (root) JOBS=<board host:port> PEER=<relay's host> BIN=<moq dir> DEADLINE=<epoch s> \
#     t83d-bisect-rcv.sh <out dir>
#
# Env: HALT (1), KEEP (/home/ubuntu/keep-running), POLL (10 s).
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:?out dir}
JOBS=${JOBS:?board host:port}
PEER=${PEER:?relay host}
BIN=${BIN:?moq dir}
DEADLINE=${DEADLINE:?epoch seconds}
HALT=${HALT:-1}
KEEP=${KEEP:-/home/ubuntu/keep-running}
POLL=${POLL:-10}
mkdir -p "$OUT"
log() { echo "$(date -u +%FT%TZ) $*"; }

last=
while :; do
	now=$(date +%s)
	if [ "$now" -gt "$DEADLINE" ]; then
		log "deadline"
		break
	fi
	job=$(curl -fsS --max-time 10 "http://$JOBS/job" 2>/dev/null) || job=
	if [ "$job" = "done" ]; then
		log "done"
		break
	fi
	read -r label t0 delays bursts reps control <<<"$job"
	if [ -n "${control:-}" ] && [ "$label" != "$last" ] && [ "$t0" -gt "$((now + 5))" ]; then
		last=$label
		log "run $label at $t0"
		QLOG='' DELAYS=$delays BURSTS=${bursts//,/ } REPS=$reps CONTROL=$control OUT=$OUT T0=$t0 \
			ROLE=rcv PEER=$PEER BIN=$BIN bash "$H/t83d-skip.sh" "$label" >"$OUT/$label.log" 2>&1
		python3 "$H/t83d-evict.py" "$OUT/$label" >"$OUT/$label.txt" 2>&1
		(cd "$OUT" && tar -czf "$label.tgz" "$label.log" "$label.txt" "$label"/*.log "$label"/*.txt)
		curl -fsS --max-time 60 -T "$OUT/$label.tgz" "http://$JOBS/result/$label.tgz"
		curl -fsS --max-time 30 -T "$OUT/$label.txt" "http://$JOBS/result/$label.txt"
		log "sent $label: $(head -1 "$OUT/$label.txt")"
	fi
	sleep "$POLL"
done
if [ "$HALT" = 1 ] && [ ! -e "$KEEP" ]; then
	log "halting"
	shutdown -h +1
fi
