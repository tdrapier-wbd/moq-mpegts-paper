#!/usr/bin/env bash
# T78's origin sampler (lab/test-78-*.md), on the origin, every 5 s until killed: one line of unix
# time; CPU ticks of the pathway's nginx (master and workers, by its pid file), segmenter and guard
# (by theirs); the host's idle and total ticks; ens5's transmitted bytes. Only the rig's processes
# are read, never the standing units'.
#
#   t78-sample.sh OUT [P59]
OUT=${1:?usage: t78-sample.sh OUT [P59]}
P59=${2:-$HOME/p59}
ticks() {
	local s=0 p f
	for p in "$@"; do
		read -ra f <"/proc/$p/stat" 2>/dev/null && s=$((s + f[13] + f[14]))
	done
	echo "$s"
}
while :; do
	m=$(cat "$P59/ngx/ngx.pid" 2>/dev/null)
	# shellcheck disable=SC2046 # one PID per word
	ngx=$(ticks "$m" $(pgrep -P "${m:-0}"))
	seg=$(ticks "$(cat "$P59/seg.pid" 2>/dev/null)")
	guard=$(ticks "$(cat "$P59/guard.pid" 2>/dev/null)")
	read -ra c </proc/stat
	tot=0
	for x in "${c[@]:1:8}"; do tot=$((tot + x)); done
	tx=$(awk '/ens5:/ {print $10}' /proc/net/dev)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$EPOCHREALTIME" "$ngx" "$seg" "$guard" "${c[4]}" "$tot" "$tx" >>"$OUT"
	sleep 5
done
