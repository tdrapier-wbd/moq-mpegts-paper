#!/usr/bin/env bash
# P1-aj's soak on the receiver host, as root (lab/test-62-origin-group-soak.md): T61's design for
# HOURS. Two receivers of the origin group (t59-legs.sh legs, aligned, B joining 20 s after A),
# merged live by p1aj-merge.py, whose output is graded in flight by t21-pcr-monitor.py and tsp's
# continuity check. Nothing is stored but logs and counters.
#
#   p1aj-soak.sh start DIR HOURS URL [URL_B] | stop DIR | status DIR
#
# URL_B (default URL) is leg B's playlist. Env: PACER, ALIGN_MS (30000), RELEASE_MS, as
# t59-legs.sh.

set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
export ALIGN_MS=${ALIGN_MS:-30000}

start() {
	local dir=$1 hours=$2 url=$3 url_b=${4:-$3} secs
	secs=$((hours * 3600))
	mkdir -p "$dir"
	chown ubuntu: "$dir"
	setsid bash -c "python3 '$H/p1aj-merge.py' 2>>'$dir/merge.jsonl' |
		tee >(python3 '$H/t21-pcr-monitor.py' --window 60 >>'$dir/pcr.log' 2>&1) |
		tsp -I file - -P continuity -O drop >>'$dir/cc.log' 2>&1" </dev/null >/dev/null 2>&1 &
	echo $! >"$dir/merge.pid"
	sleep 1
	bash "$H/t59-legs.sh" leg-start a "$dir" "$url" "$secs"
	sleep 20
	bash "$H/t59-legs.sh" leg-start b "$dir" "$url_b" "$((secs - 20))"
	setsid bash "$H/p1aj-sample.sh" "$dir/resources.txt" b8='^python3 .*b8-hls-recv' \
		pacer='^\S*mpegts-pacer ' merge='^python3 .*p1aj-merge' pcr='^python3 .*t21-pcr-monitor' \
		tsp='^tsp -I file -' </dev/null >/dev/null 2>&1 &
	echo $! >"$dir/sample.pid"
	echo "$EPOCHREALTIME soak-start hours=$hours release=${RELEASE_MS:-none}" >>"$dir/events.log"
}

stop() {
	local dir=$1
	bash "$H/t59-legs.sh" leg-kill a "$dir"
	bash "$H/t59-legs.sh" leg-kill b "$dir"
	sleep 2
	kill -TERM -- "-$(cat "$dir/merge.pid")" "-$(cat "$dir/sample.pid")" 2>/dev/null
	echo "$EPOCHREALTIME soak-stop" >>"$dir/events.log"
}

status() {
	local dir=$1
	tail -n 1 "$dir/merge.jsonl" "$dir/pcr.log"
	grep -c . "$dir/cc.log"
	tail -n 1 "$dir/pacer-a.log" "$dir/pacer-b.log" | cut -c1-240
}

case "${1:-}" in
start) start "${2:?DIR}" "${3:?HOURS}" "${4:?URL}" "${5:-}" ;;
stop) stop "${2:?DIR}" ;;
status) status "${2:?DIR}" ;;
*)
	echo "usage: p1aj-soak.sh start DIR HOURS URL [URL_B] | stop DIR | status DIR" >&2
	exit 2
	;;
esac
