#!/usr/bin/env bash
# T83 Part D's skip test on one host, for bisecting the relay: a clip through a relay, subscribed by
# media-aware exports in a network namespace behind a veth pair with netem delay each way, while the
# namespace drops the relay's packets inbound in bursts. Prints, per export, the `Old` resets it
# logged during the bursts and outside them.
#
#   RELAY=<dir with moq-relay> CLIENT=<dir with moq> t83d-loop.sh <out dir>    (root: netns, tc, iptables)
#
# Env: CLIP (~/contrib-10m.ts), DELAYS ("5822ms"), BURSTS ("2 3 4"), REPS (2), CONTROL (20 s),
#      GAP (20 s), OWD (58.5ms, each way), PORT (4810), IMPORT_ARGS ("--program 1" for an MPTS),
#      QLOG (set: the relay writes qlog into OUT/qlog), NETEM_DOWN (more netem on the relay-to-export
#      direction, as "loss 0.2%"). MOQ_LISTEN_VERSION and MOQ_CONNECT_VERSION pass through.
set -uo pipefail

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:?out dir}
RELAY=${RELAY:?dir with moq-relay}
CLIENT=${CLIENT:?dir with moq}
CLIP=${CLIP:-$HOME/contrib-10m.ts}
read -ra DELAYS <<<"${DELAYS:-5822ms}"
read -ra BURSTS <<<"${BURSTS:-2 3 4}"
REPS=${REPS:-2}
CONTROL=${CONTROL:-20}
GAP=${GAP:-20}
OWD=${OWD:-58.5ms}
PORT=${PORT:-4810}
IMPORT_ARGS=${IMPORT_ARGS:-}
NETEM_DOWN=${NETEM_DOWN:-}
NS=t83loop
A=10.83.0.1
B=10.83.0.2
PIDS=()

[ "$(id -u)" -eq 0 ] || {
	echo "runs as root (netns, tc, iptables)" >&2
	exit 1
}
now() { date +%s.%N; }
stamp() { echo "$1 $(now)" >>"$OUT/events.txt"; }
drop() { ip netns exec "$NS" iptables "$1" INPUT -s "$A" -p udp --sport "$PORT" -j DROP; }
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null; done
	sleep 1
	for p in ${PIDS+"${PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; done
	wait 2>/dev/null
	ip netns del "$NS" 2>/dev/null
	ip link del t83a 2>/dev/null
}
trap cleanup EXIT

rm -rf "$OUT"
mkdir -p "$OUT${QLOG:+/qlog}"
cleanup
ip netns add "$NS"
ip link add t83a type veth peer name t83b
ip link set t83b netns "$NS"
ip addr add "$A/24" dev t83a
ip link set t83a up
ip netns exec "$NS" ip addr add "$B/24" dev t83b
ip netns exec "$NS" ip link set t83b up
ip netns exec "$NS" ip link set lo up
# shellcheck disable=SC2086
tc qdisc add dev t83a root netem delay "$OWD" limit 100000 $NETEM_DOWN
ip netns exec "$NS" tc qdisc add dev t83b root netem delay "$OWD" limit 100000

# shellcheck source=moq-cli-flags.sh
. "$H/moq-cli-flags.sh"
moq_cli_detect "$CLIENT/moq" "$RELAY/moq-relay"
{
	echo "=== $(date -u +%FT%TZ) t83d-loop, owd $OWD, netem+ ${NETEM_DOWN:-none}, delays ${DELAYS[*]}, bursts ${BURSTS[*]} s x $REPS every ${GAP}s after ${CONTROL}s"
	"$RELAY/moq-relay" --version 2>&1 | head -1
	sha256sum "$RELAY/moq-relay" "$CLIENT/moq" | cut -c1-16
} >"$OUT/build.txt" 2>&1

setsid "$RELAY/moq-relay" --listen "$A:$PORT" --listen-tls-generate "$A" "${RELAY_AUTH[@]}" \
	--quic-gso=false ${QLOG:+--quic-qlog "$OUT/qlog"} --log-level info >"$OUT/relay.log" 2>&1 &
PIDS+=("$!")
sleep 1
setsid bash -c "tsp --realtime -I file '$CLIP' -P regulate -O file - 2>>'$OUT/tsp.log' |
	'$CLIENT/moq' --connect-tls-insecure --connect 'https://$A:$PORT/anon' --broadcast loop \
	import ts $IMPORT_ARGS >>'$OUT/import.log' 2>&1" &
PIDS+=("$!")
sleep 2
setsid ip netns exec "$NS" tcpdump -i t83b -nn -s 64 -w "$OUT/cap.pcap" "udp and src host $A and src port $PORT" 2>"$OUT/tcpdump.log" &
PIDS+=("$!")
for d in "${DELAYS[@]}"; do
	setsid bash -c "ip netns exec '$NS' '$CLIENT/moq' --connect-tls-insecure --connect 'https://$A:$PORT/anon' \
		--broadcast loop export ts --delay '$d' 2>'$OUT/d$d.log' | python3 '$H/t83d-rate.py' >'$OUT/d$d.rate'" &
	PIDS+=("$!")
done
sleep "$CONTROL"
stamp control_end
for ((r = 1; r <= REPS; r++)); do
	for b in "${BURSTS[@]}"; do
		drop -I
		stamp "burst_on $b $r"
		sleep "$b"
		drop -D
		stamp "burst_off $b $r"
		sleep "$GAP"
	done
done
stamp end
sleep 1
kill -INT -- "-${PIDS[2]}" 2>/dev/null
sleep 1

tcpdump -r "$OUT/cap.pcap" -nn -tt 2>/dev/null | awk '{print $1}' >"$OUT/rx.times"
python3 - "$OUT/events.txt" "$OUT/rx.times" <<'EOF' | tee "$OUT/stall.txt"
import bisect, sys
ev = [l.split() for l in open(sys.argv[1])]
ts = [float(l) for l in open(sys.argv[2])]
out = []
for a, b in zip(ev, ev[1:]):
    if a[0] == "burst_on":
        i = bisect.bisect_right(ts, float(b[-1]))
        out.append(f"{a[1]}/{a[2]}:{ts[i] - float(a[-1]):.2f}" if i < len(ts) else f"{a[1]}/{a[2]}:-")
print("STALL first relay packet after the burst, from its start:", " ".join(out))
EOF

for d in "${DELAYS[@]}"; do
	awk -v d="$d" '$2 == 0 { z++; if (z > m) m = z; next } { z = 0; s++ } END { print "OUTPUT delay=" d " seconds_with_bytes=" s+0 " longest_silence_s=" m+0 }' "$OUT/d$d.rate"
	python3 - "$OUT/events.txt" "$OUT/d$d.log" "$d" <<'EOF'
import re, sys, datetime
ev = [l.split() for l in open(sys.argv[1])]
wins = [(float(a[-1]), float(b[-1]) + 6.0, a[1]) for a, b in zip(ev, ev[1:]) if a[0] == "burst_on"]
inside, outside, per = 0, 0, {}
for line in open(sys.argv[2], errors="replace"):
    if "Old" not in line:
        continue
    m = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z", line)
    t = datetime.datetime.fromisoformat(m.group(1)).replace(tzinfo=datetime.timezone.utc).timestamp() if m else None
    w = next((w for w in wins if t is not None and w[0] <= t <= w[1]), None)
    if w:
        inside += 1
        per[w[2]] = per.get(w[2], 0) + 1
    else:
        outside += 1
print(f"RESULT delay={sys.argv[3]} old_in_bursts={inside} old_outside={outside} by_burst={per}")
EOF
done | tee "$OUT/result.txt"
