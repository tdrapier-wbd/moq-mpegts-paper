#!/usr/bin/env bash
# Per-process resource sampler for a soak: one CSV row per process per sample, read from /proc only.
#
#   live-unit-sample.sh <out.csv> <hours> <sample_s> <target>...
#
# target: unit:<name>     every process in the systemd unit's cgroup, plus one `cgroup` row with the
#                         unit's memory.current and CPU time; `extra` is its InvocationID, so a
#                         restart shows in the series rather than as a fall in it
#         pidfile:<path>  the process whose PID the file holds, re-read every sample
# Columns: utc,target,pid,comm,rss_kb,pss_kb,anon_kb,swap_kb,threads,fds,cpu_ticks,extra.
# smaps_rollup's Pss and Anonymous tell heap growth from mapped files. Reading another user's
# smaps_rollup and fds needs root, so run it under sudo for system units. One `host` row per sample
# carries MemAvailable (kB, in rss_kb) and the 1-minute load (in extra).
set -uo pipefail

OUT=${1:?out csv} HOURS=${2:?hours} SAMPLE=${3:?sample seconds}
shift 3
[ $# -gt 0 ] || { echo "no targets" >&2; exit 2; }
[ -s "$OUT" ] || echo "utc,target,pid,comm,rss_kb,pss_kb,anon_kb,swap_kb,threads,fds,cpu_ticks,extra" >"$OUT"

proc_row() { # <utc> <target> <pid> <extra>
	local p=$3 comm status smaps ticks fds
	status=$(awk '/^VmRSS/{r=$2} /^Threads/{t=$2} END{print r+0","t+0}' "/proc/$p/status" 2>/dev/null) || return
	[ -n "$status" ] || return
	comm=$(tr -d ',\n' <"/proc/$p/comm" 2>/dev/null)
	smaps=$(awk '/^Pss:/{p=$2} /^Anonymous:/{a=$2} /^Swap:/{s=$2} END{print p+0","a+0","s+0}' \
		"/proc/$p/smaps_rollup" 2>/dev/null)
	# Fields after "pid (comm) ": utime and stime are the 12th and 13th.
	ticks=$(sed 's/^.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $12 + $13}')
	fds=$(find "/proc/$p/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
	echo "$1,$2,$p,$comm,${status%,*},${smaps:-,,},${status#*,},$fds,${ticks:-},$4"
}

end=$(($(date +%s) + HOURS * 3600))
while [ "$(date +%s)" -lt "$end" ]; do
	now=$(date -u +%FT%TZ)
	{
		for t in "$@"; do
			case $t in
			unit:*)
				u=${t#unit:}
				cg=/sys/fs/cgroup/system.slice/$u.service
				inv=$(systemctl show -p InvocationID --value "$u")
				mem=$(cat "$cg/memory.current" 2>/dev/null || echo)
				usec=$(awk '/^usage_usec/{print $2}' "$cg/cpu.stat" 2>/dev/null)
				echo "$now,$u,cgroup,cgroup,$((${mem:-0} / 1024)),,,,,,$((${usec:-0} / 10000)),$inv"
				for p in $(cat "$cg/cgroup.procs" 2>/dev/null); do proc_row "$now" "$u" "$p" "$inv"; done
				;;
			pidfile:*)
				f=${t#pidfile:}
				p=$(cat "$f" 2>/dev/null)
				[ -n "$p" ] && proc_row "$now" "$(basename "$f" .pid)" "$p" ""
				;;
			esac
		done
		echo "$now,host,,,$(awk '/^MemAvailable/{print $2}' /proc/meminfo),,,,,,,$(cut -d' ' -f1 /proc/loadavg)"
	} >>"$OUT"
	sleep $((SAMPLE - $(date +%s) % SAMPLE))
done
