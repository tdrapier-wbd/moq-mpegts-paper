#!/usr/bin/env bash
# T30 Cell 2 from the laptop (lab/test-30-segmented-distributed-resilience.md): packager A on one
# host and packager B on another write one NFS-exported namespace on a third, the store host, which
# also runs the origin; the receiver runs on HOST_R. One source on A's host feeds A over loopback
# multicast and B by a unicast copy, and both packagers start before it.
#
#   t30-cell2.sh setup | teardown
#   t30-cell2.sh calibrate <run>     the two packagers co-started into their own directories for
#                                    CAL_S s; their segments compared by name and hash
#   t30-cell2.sh control|kill-a|kill-b|partition <run>
#                                    T30's run: event at T_EVENT s after the receiver starts, run of
#                                    T_END s; kill-a and kill-b SIGKILL a packager, partition drops
#                                    A's NFS traffic for PARTITION_S s
#
# Env: HOST_A, HOST_B, HOST_S, HOST_R (ssh aliases; HOST_R is A's or B's, default B's), IP_A, IP_B,
#      IP_S (private addresses, required), T_EVENT (40), T_END (100), PARTITION_S (10), CAL_S (40),
#      TSP_OPTS (both packagers' tsp options; "--bitrate 9945951", the clip's PCR rate: without a
#      fixed input bitrate a packager reading the source across hosts cuts elsewhere than one on
#      its host; set it empty for the stock chain), KEEP_TS (keep the receiver's captures).
#      Records: ~/t30c2runs/<run>/.
set -u
HOST_A=${HOST_A:-moq-primary}
HOST_B=${HOST_B:-moq-secondary}
HOST_S=${HOST_S:-moq-tertiary}
HOST_R=${HOST_R:-$HOST_B}
IP_A=${IP_A:?set IP_A} IP_B=${IP_B:?set IP_B} IP_S=${IP_S:?set IP_S}
T_EVENT=${T_EVENT:-40}
T_END=${T_END:-100}
PARTITION_S=${PARTITION_S:-10}
CAL_S=${CAL_S:-40}
TSP_OPTS=${TSP_OPTS-"--bitrate 9945951"}
HERE=$(cd "$(dirname "$0")" && pwd)
TO=/opt/homebrew/bin/timeout
HS="bash t30c2/scripts/t30-cell2-host.sh"
MNT=/mnt/t30store
STORE=/srv/t30store

h() { # h <host> <command>
	local host=$1
	shift
	$TO 90 ssh -n -o ControlMaster=auto -o "ControlPath=/tmp/t30c2-%r@%h" -o ControlPersist=900 "$host" "$@"
}
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

case ${1:-} in
setup)
	for host in "$HOST_A" "$HOST_B" "$HOST_S"; do
		h "$host" 'mkdir -p ~/t30c2/scripts ~/t30c2/runs'
		$TO 60 scp -q -o "ControlPath=/tmp/t30c2-%r@%h" "$HERE"/t30-cell2-host.sh "$HERE"/t6-hls-pull.py \
			"$HERE"/t28-content-lost.py "$HERE"/t30-timeline.py "$HERE"/t30-regrade.py "$host:t30c2/scripts/"
	done
	h "$HOST_S" "$HS store-up $IP_A $IP_B"
	h "$HOST_A" "$HS mount $IP_S"
	h "$HOST_B" "$HS mount $IP_S"
	exit 0
	;;
teardown)
	h "$HOST_A" "$HS part-off; $HS umount"
	h "$HOST_B" "$HS umount"
	h "$HOST_S" "$HS store-down $IP_A $IP_B"
	exit 0
	;;
calibrate | control | kill-a | kill-b | partition) ;;
*)
	echo "usage: t30-cell2.sh setup | teardown | calibrate|control|kill-a|kill-b|partition <run>" >&2
	exit 2
	;;
esac

VARIANT=$1
RUN=${2:?run name}
L=~/t30c2runs/$RUN
[ -e "$L" ] && { echo "$L exists" >&2; exit 2; }
mkdir -p "$L"
R=t30c2/runs/$RUN
ev() { echo "$(now) $*" | tee -a "$L/events.log"; }

stop_all() {
	h "$HOST_A" "$HS part-off; $HS source-stop $R; $HS pack-stop $R"
	h "$HOST_B" "$HS pack-stop $R"
	[ "$VARIANT" = calibrate ] || h "$HOST_S" "$HS origin-stop $R" >"$L/origin.txt"
	ev stopped
}
trap stop_all EXIT

h "$HOST_S" "rm -rf $STORE/www $STORE/wA $STORE/wB; mkdir -p $STORE/www $R"
h "$HOST_A" "mountpoint -q $MNT && mkdir -p $R" || { echo "store not mounted on A" >&2; exit 2; }
h "$HOST_B" "mountpoint -q $MNT && mkdir -p $R" || { echo "store not mounted on B" >&2; exit 2; }
if [ "$VARIANT" = calibrate ]; then
	dA=$MNT/wA dB=$MNT/wB
else
	dA=$MNT/www dB=$MNT/www
	h "$HOST_S" "$HS origin-start $R $IP_S" || exit 1
fi
ev "start variant=$VARIANT t_event=$T_EVENT t_end=$T_END partition_s=$PARTITION_S tsp_opts='$TSP_OPTS'"
h "$HOST_A" "$HS pack-start $R A $dA $TSP_OPTS -I ip 239.255.0.30:5030 --local-address 127.0.0.1"
h "$HOST_B" "$HS pack-start $R B $dB $TSP_OPTS -I ip 5031"
bound() { # bound <host> <udp port>: a packager that misses the first PAT numbers its tables apart
	local _
	for _ in $(seq 1 50); do
		h "$1" "ss -Huln 'sport = :$2' | grep -q ." && return 0
		sleep 0.2
	done
	return 1
}
if ! bound "$HOST_A" 5030 || ! bound "$HOST_B" 5031; then
	ev "a packager never bound its input"
	exit 3
fi
sleep 1
h "$HOST_A" "$HS source-start $R $IP_B"
ev source-start

lists() {
	local n
	n=$(h "$HOST_S" "grep -c '\.ts\$' $STORE/$1/index.m3u8 2>/dev/null")
	echo "${n:-0}"
}
ok=0
for _ in $(seq 1 40); do
	if [ "$VARIANT" = calibrate ]; then
		[ "$(lists wA)" -ge 3 ] && [ "$(lists wB)" -ge 3 ] && { ok=1; break; }
	else
		[ "$(lists www)" -ge 3 ] && { ok=1; break; }
	fi
	sleep 1
done
[ "$ok" = 1 ] || { ev "playlist never listed three segments"; exit 3; }
ev playlist-ready

if [ "$VARIANT" = calibrate ]; then
	sleep "$CAL_S"
	h "$HOST_S" "$HS hashes $STORE/wA" >"$L/hashes-A.txt"
	h "$HOST_S" "$HS hashes $STORE/wB" >"$L/hashes-B.txt"
	ev hashed
	python3 - "$L" <<'EOF' | tee "$L/result.txt"
import sys
d = sys.argv[1]
def read(p):
	return {l.split()[0]: l.split()[1:] for l in open(p) if l.strip()}
a, b = read(f"{d}/hashes-A.txt"), read(f"{d}/hashes-B.txt")
common = sorted(set(a) & set(b))[:-1]  # the newest may still be being written
same = [n for n in common if a[n] == b[n]]
print(f"CALIBRATE names_a={len(a)} names_b={len(b)} compared={len(common)} identical={len(same)}"
      f" only_a={len(set(a) - set(b))} only_b={len(set(b) - set(a))}")
EOF
	exit 0
fi

URL="http://$IP_S:18300/index.m3u8"
h "$HOST_R" "cd $R; T_EVENT=$T_EVENT T_END=$T_END nohup setsid bash ~/t30c2/scripts/t30-cell2-host.sh recv ~/$R $URL > recv.out 2>&1 < /dev/null & echo \$! > ~/$R/recv.pid"
T0=$(now)
ev recv-start
at() { python3 -c "import time; time.sleep(max(0.0, $T0 + $1 - time.time()))"; }
case $VARIANT in
control)
	at "$T_EVENT"
	ev noop
	;;
kill-a)
	at "$T_EVENT"
	h "$HOST_A" "$HS pack-kill $R"
	ev kill-A
	;;
kill-b)
	at "$T_EVENT"
	h "$HOST_B" "$HS pack-kill $R"
	ev kill-B
	;;
partition)
	at "$T_EVENT"
	h "$HOST_A" "$HS part-on $IP_S"
	ev partition-on
	at $((T_EVENT + PARTITION_S))
	h "$HOST_A" "$HS part-off"
	ev partition-off
	;;
esac
at "$T_END"
for _ in $(seq 1 60); do
	h "$HOST_R" "test -f $R/recv.done" && break
	sleep 3
done
ev recv-done
stop_all
trap - EXIT
h "$HOST_R" "cat $R/result.txt" | tee "$L/result.txt"
fetch() { # fetch <host> <file under the run>...
	local host=$1 f
	shift
	for f in "$@"; do
		$TO 60 scp -q -o "ControlPath=/tmp/t30c2-%r@%h" "$host:$R/$f" "$L/" 2>/dev/null
	done
}
fetch "$HOST_R" pull.log pull.out pacer.log sizes.csv content.json timeline.json shelf.log
fetch "$HOST_S" playlist.csv ngx/access.log
fetch "$HOST_A" pack-A.log source.log
fetch "$HOST_B" pack-B.log
[ -n "${KEEP_TS:-}" ] || h "$HOST_R" "rm -f $R/groomed.ts $R/raw.ts $R/shelf.ts"
cat "$L/origin.txt"
