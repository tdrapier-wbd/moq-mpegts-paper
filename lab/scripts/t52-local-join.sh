#!/opt/homebrew/bin/bash
# T52, the opener's join on a local moqx: one release in one configuration, a run of trials.
# usage: t52-local-join.sh <out-dir> <moqx release dir> <config: N|Q|D> <trials>
#   N: threads 1, use_relay_thread, use_local_forwarders (the node's single thread)
#   Q: threads 4, use_relay_thread, use_local_forwarders (moqx#883's report)
#   D: the default, no local forwarders (the attribution control)
#   A trial is a fresh broadcast: `moq import ts --passthrough` of FIXTURE, whose catalog is
#   published once; 4 s later the opener exports for 8 s; 2.5 s after it, a joiner for 6 s.
#   Raw QUIC, moq-transport draft 18, loopback.
# env: MOQ (bin dir holding moq), FIXTURE (the synthetic fixture, 20 s), PORT (15533)
# Appends to <out-dir>/trials.csv: release, config, trial, role, payload bytes, whether the
# client logged its joining FETCH refused, and moqx's "Session not found" lines in the trial.
set -u
OUT=$1 MOQX=$2 CFG=$3 N=$4
MOQ=${MOQ:?bin dir holding moq}
FIXTURE=${FIXTURE:?the synthetic fixture}
PORT=${PORT:-15533}
TO=/opt/homebrew/bin/timeout
REL=$(cat "$MOQX/VERSION")
mkdir -p "$OUT/logs" "$OUT/out" && cd "$OUT" || exit 1
[ -f trials.csv ] || echo "release,config,trial,role,bytes,fetch_refused,relay_session_not_found" >trials.csv
size() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; }

case $CFG in
N) top="threads: 1
use_relay_thread: true
use_local_forwarders: true" ;;
Q) top="threads: 4
use_relay_thread: true
use_local_forwarders: true" ;;
D) top="" ;;
*)
	echo "config N, Q or D" >&2
	exit 2
	;;
esac
cfg=moqx-$REL-$CFG.yaml
cat >"$cfg" <<EOF
$top
listeners:
  - name: main
    udp: {socket: {address: "127.0.0.1", port: $PORT}}
    tls: {insecure: true}
    endpoint: /moq-relay
    moqt_versions: [16, 18]
service_defaults:
  cache: {enabled: true, max_tracks: 100, max_groups_per_track: 10}
  max_subscription_buffer_kb: 51200
services:
  open:
    match: [{authority: {any: true}, path: {prefix: "/"}}]
EOF
"$MOQX/bin/moqx" validate-config --config "$cfg" >"logs/validate-$REL-$CFG.log" 2>&1 ||
	{
		echo "config refused: $(tail -2 "logs/validate-$REL-$CFG.log")"
		exit 1
	}
xlog=logs/moqx-$REL-$CFG.log
"$MOQX/bin/moqx" --config "$cfg" --logtostderr -v=1 >"$xlog" 2>&1 &
mx=$!
for _ in $(seq 1 50); do lsof -nP -iUDP:"$PORT" >/dev/null 2>&1 && break; sleep 0.2; done
kill -0 "$mx" 2>/dev/null || {
	echo "moqx exited: $(tail -2 "$xlog")"
	exit 1
}

url=moqt://127.0.0.1:$PORT/moq-relay
cli=(--connect-tls-insecure --connect "$url" --connect-version moq-transport-18 --log-level debug)
refused() { grep -a -i -E 'fetch' "$1" | grep -a -c -i -E 'refus|error|not found|does not exist|no active subscribe'; }
for k in $(seq 1 "$N"); do
	b=jt/${REL//./}-$CFG-$k-$$
	base=$(wc -l <"$xlog")
	tsp -I file "$FIXTURE" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		"$MOQ/moq" "${cli[@]}" --broadcast "$b" import ts --passthrough >"logs/pub-$REL-$CFG-$k.log" 2>&1 &
	pub=$!
	sleep 4
	"$TO" 8 "$MOQ/moq" "${cli[@]}" --broadcast "$b" export ts --passthrough \
		>"out/open-$REL-$CFG-$k.ts" 2>"logs/open-$REL-$CFG-$k.log" &
	op=$!
	sleep 2.5
	"$TO" 6 "$MOQ/moq" "${cli[@]}" --broadcast "$b" export ts --passthrough \
		>"out/join-$REL-$CFG-$k.ts" 2>"logs/join-$REL-$CFG-$k.log" &
	jn=$!
	wait "$op" "$jn" 2>/dev/null
	kill -INT "$pub" 2>/dev/null
	pkill -P $$ tsp 2>/dev/null
	wait "$pub" 2>/dev/null
	snf=$(tail -n +"$((base + 1))" "$xlog" | grep -a -c 'Session not found')
	for role in open join; do
		echo "$REL,$CFG,$k,$role,$(size "out/$role-$REL-$CFG-$k.ts"),$(refused "logs/$role-$REL-$CFG-$k.log"),$snf" >>trials.csv
	done
	rm -f "out/open-$REL-$CFG-$k.ts" "out/join-$REL-$CFG-$k.ts"
	sleep 1
done
kill -INT "$mx" 2>/dev/null
for _ in $(seq 1 30); do kill -0 "$mx" 2>/dev/null || break; sleep 0.1; done
kill -KILL "$mx" 2>/dev/null
wait "$mx" 2>/dev/null
grep "^$REL,$CFG," trials.csv | awk -F, '$4=="open"{n++; if ($5==0) z++} END {printf "%s %s: %d openers, %d with no payload\n", "'"$REL"'", "'"$CFG"'", n, z}'
