#!/usr/bin/env bash
# T61 pathway control, run on a packager host (lab/test-61-origin-group-failover.md).
#
# The interchangeable pathway is the epoch-locked segmenter writing ~/p59/www/g/ and the staleness
# guard watching its playlist, both detached and niced; T59's nginx origin (t59-pathway.sh
# origin-start) serves them as /g/. The rest are the failure injections, each logged to events.log.
#
#   t61-origin.sh start | stop | status
#   t61-origin.sh seg-kill | seg-start                 the packager dies, and restarts
#   t61-origin.sh seg-freeze | seg-thaw                the packager freezes, and resumes
#   t61-origin.sh ngx-freeze | ngx-thaw                the origin accepts and never answers
#   t61-origin.sh block | unblock                      the origin's port drops every packet
#
# Env: P59 (~/p59), PORT (18310), STALE (4, the guard's seconds), SEG_ARGS (the segmenter's
# options, as the last start left them in $P59/seg.args unless set; T63: --pdt).

set -uo pipefail
P59=${P59:-$HOME/p59}
PORT=${PORT:-18310}
STALE=${STALE:-4}
DIR=$P59/www/g
NGX=$P59/ngx

ev() { echo "$EPOCHREALTIME $1" >>"$P59/events.log"; echo "$1"; }
pids() { [ -f "$P59/$1.pid" ] && cat "$P59/$1.pid"; }
ngx_pids() { pgrep -f "nginx: .*-p $NGX" ; pgrep -f "nginx: worker process" -P "$(cat "$NGX/ngx.pid" 2>/dev/null || echo 0)"; }

seg_start() {
	local args=${SEG_ARGS-$(cat "$P59/seg.args" 2>/dev/null)}
	mkdir -p "$DIR"
	echo "$args" >"$P59/seg.args"
	# shellcheck disable=SC2086 # options, split on purpose
	setsid nohup nice -n 10 python3 "$P59/t61-epochseg.py" "$DIR" $args >>"$P59/seg.log" 2>&1 </dev/null &
	echo $! >"$P59/seg.pid"
}

start() {
	seg_start
	# T60's follow-up reads the same objects under paths CloudFront caches apart.
	for p in h y z; do ln -sfn g "$P59/www/$p"; done
	setsid nohup nice -n 5 python3 "$P59/t61-guard.py" "$DIR/index.m3u8" --stale "$STALE" \
		>>"$P59/guard.log" 2>&1 </dev/null &
	echo $! >"$P59/guard.pid"
	ev "t61-start seg=$(pids seg) guard=$(pids guard)"
}

stop() {
	local p
	for p in seg guard; do
		[ -n "$(pids $p)" ] && kill -CONT "$(pids $p)" 2>/dev/null && kill "$(pids $p)" 2>/dev/null
		rm -f "$P59/$p.pid"
	done
	unblock >/dev/null
	ngx_thaw >/dev/null
	ev "t61-stop"
}

ngx_thaw() { local p; for p in $(ngx_pids); do kill -CONT "$p"; done; ev "ngx-thaw"; }

block() {
	sudo iptables -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null ||
		sudo iptables -I INPUT -p tcp --dport "$PORT" -j DROP
	ev "block"
}

unblock() {
	while sudo iptables -C INPUT -p tcp --dport "$PORT" -j DROP 2>/dev/null; do
		sudo iptables -D INPUT -p tcp --dport "$PORT" -j DROP
	done
	ev "unblock"
}

case "${1:-}" in
start) start ;;
stop) stop ;;
seg-start) seg_start && ev "seg-start seg=$(pids seg)" ;;
seg-kill) kill "$(pids seg)" && rm -f "$P59/seg.pid" && ev "seg-kill" ;;
seg-freeze) kill -STOP "$(pids seg)" && ev "seg-freeze" ;;
seg-thaw) kill -CONT "$(pids seg)" && ev "seg-thaw" ;;
ngx-freeze)
	for p in $(ngx_pids); do kill -STOP "$p"; done
	ev "ngx-freeze"
	;;
ngx-thaw) ngx_thaw ;;
block) block ;;
unblock) unblock ;;
status)
	for p in seg guard; do
		echo "$p: $(pids $p) $(ps -o stat= -p "$(pids $p)" 2>/dev/null)"
	done
	echo "nginx: $(ngx_pids | tr '\n' ' ')"
	sudo iptables -S INPUT | grep -- "--dport $PORT" || echo "port $PORT open"
	ls "$DIR" 2>/dev/null | tail -n 3
	tail -n 2 "$P59/seg.log" "$P59/guard.log" 2>/dev/null
	;;
*)
	echo "usage: t61-origin.sh start|stop|status|seg-kill|seg-freeze|seg-thaw|ngx-freeze|ngx-thaw|block|unblock" >&2
	exit 2
	;;
esac
