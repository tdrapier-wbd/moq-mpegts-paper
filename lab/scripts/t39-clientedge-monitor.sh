#!/bin/bash
# T39 Part A -- can a standalone process at the client-edge position read the delivered signal,
# with no groomer involvement and no groomer changes?
#
# The topology under test is the deployed one: publisher and relay are ours, the subscriber and
# groomer are the client's hardware. The question is what the client edge can observe about the
# media it is actually receiving, using a process that is not the groomer and does not touch it.
#
# Three consumers run off the same relay at the same time:
#
#   1. the GROOMER subscription -- `moq export ts | mpegts-pacer`, exactly as T12 onwards runs it,
#      with no flags added and no code changed. This is here to show the monitor is additive:
#      the constraint is that telemetry never becomes a groomer patch.
#   2. the MONITOR subscription -- an independent `moq export ts` into `ts-liveness.py`. This is
#      the tier-3 detector, on its own subscription, reading the delivered signal.
#   3. the relay's own stats broadcast, read with `--stats-enabled`. This is the tier-2 view, and
#      the point of including it is to show what it cannot see.
#
# The fault is T24-class: the MPEG-1 audio PID stops while video and PCR continue. The wire stays
# P1-conformant and bytes keep flowing, so tier 2 has nothing to report. If the monitor catches it
# and the relay's counters do not, the tier split the design rests on is demonstrated rather than
# assumed.
#
# Usage: t39-clientedge-monitor.sh [pre_s] [post_s]

set -u
PRE="${1:-20}"
POST="${2:-20}"

W=/tmp/t39a
R=/Users/tdrapier/moq-mpegts-paper/lab/scripts
M=~/bin-3529/moq
PT=$(cd ~/mpegts-pacer && cargo metadata --format-version 1 --no-deps 2>/dev/null |
	python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')/release
PACER=$PT/mpegts-pacer
PORT=9745
HTTP=9782
AUDIO_PID=121

rm -rf $W
mkdir -p $W/logs $W/out
cd $W
[ -x "$PACER" ] || {
	echo "no pacer at $PACER"
	exit 1
}

# --- the fault, built offline so its instant is known ---------------------------------------
# Two slices of one clip concatenated: the second has the audio PID removed entirely. Video and
# PCR are untouched across the join, which is what makes this a T24-class fault rather than a
# stall -- the clock keeps advancing over a service that has lost its audio.
# Slicing a file by time needs --pcr-based. `until --milli-seconds` is wall-clock by default, so
# reading a file at disk speed it expires only after 20 s of *reading*, by which point the whole
# 372 MB clip has gone through: two earlier attempts produced a "20 second" part 1 that was the
# entire clip and a part 2 of zero packets, and the monitor then correctly raised no alarm about
# a fault that had never been built. `--seconds` does not exist on this plugin at all, and the
# first attempt suppressed that error with 2>/dev/null. Errors are not suppressed here.
echo "building source: ${PRE}s with audio, then ${POST}s without PID $AUDIO_PID"
tsp -I file ~/CNNiEMEA.ts -P until --pcr-based --milli-seconds $((PRE * 1000)) \
	-O file $W/p1.ts || exit 1
N1=$(($(stat -f%z $W/p1.ts) / 188))
tsp -I file ~/CNNiEMEA.ts -P skip --packets "$N1" \
	-P until --pcr-based --milli-seconds $((POST * 1000)) \
	-P filter --negate --pid $AUDIO_PID -O file $W/p2.ts || exit 1
cat $W/p1.ts $W/p2.ts >$W/src.ts
N2=$(($(stat -f%z $W/p2.ts) / 188))
echo "source: $(stat -f%z $W/src.ts) bytes, part1 $N1 packets, part2 $N2 packets"
# A part that is the whole clip, or empty, means the slicing failed rather than the lane.
if [ "$N2" -lt 10000 ] || [ "$N1" -gt 400000 ]; then
	echo "SLICING FAILED: part1 $N1 / part2 $N2 packets are not two comparable slices"
	exit 1
fi
# The fault must be present in the source before anything downstream is asked about it.
A1=$(tsp -I file $W/p1.ts -P count --pid $AUDIO_PID -O drop 2>&1 | rg -o '[0-9,]+ packets' | head -1)
A2=$(tsp -I file $W/p2.ts -P count --pid $AUDIO_PID -O drop 2>&1 | rg -o '[0-9,]+ packets' | head -1)
echo "audio PID $AUDIO_PID in part1: ${A1:-none}; in part2: ${A2:-none}"
case "${A2:-none}" in
none | "0 packets") ;;
*)
	echo "FAULT NOT BUILT: part2 still carries the audio PID"
	exit 1
	;;
esac

$M-relay --server-bind 127.0.0.1:$PORT --tls-generate localhost --server-quic-gso=false \
	--web-http-listen 127.0.0.1:$HTTP --auth-public "" \
	--stats-enabled --stats-interval 1 --stats-node edge1 --log-level info \
	>$W/logs/relay.log 2>&1 &
RELAY=$!
trap 'kill $RELAY 2>/dev/null; pkill -f "127\.0\.0\.1:$PORT/" 2>/dev/null' EXIT
sleep 4
FP=$(curl -s --max-time 4 http://127.0.0.1:$HTTP/certificate.sha256)
[ -z "$FP" ] && {
	echo "relay did not start"
	tail -5 $W/logs/relay.log
	exit 1
}
C="--client-tls-fingerprint $FP --client-quic-gso=false"

# --- consumer 2: the standalone client-edge monitor -----------------------------------------
# Started before the publisher so it sees the stream from its first group.
#
# Thresholds are given explicitly rather than learned. Learning over this lane set every PID to
# 8,400 ms, because the learning window contains the join transient and the threshold is a
# multiple of the worst spacing seen in it -- a detector armed at 8.4 s is not a detector. The
# explicit values are generous against the clip's measured cadences and the point here is the
# tier split, not the detection latency, which T27 already measured properly.
($M --client-connect "https://127.0.0.1:$PORT/" $C --broadcast cnn export ts 2>$W/logs/mon-sub.log |
	python3 $R/ts-liveness.py - --gap "111:1000,121:1500,123:1500" --jsonl \
		>$W/out/liveness.jsonl 2>$W/logs/mon.log) &

# --- consumer 1: the groomer, unmodified ----------------------------------------------------
($M --client-connect "https://127.0.0.1:$PORT/" $C --broadcast cnn export ts 2>$W/logs/groom-sub.log |
	$PACER - auto >$W/out/groomed.ts 2>$W/logs/pacer.log) &

# --- consumer 3: the relay's own view, i.e. tier 2 ------------------------------------------
# The relay is started with --stats-enabled, but its stats are published as MoQ broadcasts of
# JSON tracks under --stats-prefix, and the shipped `moq` CLI has no JSON sink -- every `export`
# target is a media container. So the tier-2 view is read from the relay's log and from the
# schema in the source rather than by subscribing to it. That is itself a finding and is recorded
# as one; it is not a limitation of this harness that could be coded around here.
sleep 3

tsp -I file $W/src.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
	$M --client-connect "https://127.0.0.1:$PORT/" $C --broadcast cnn import ts \
		>$W/logs/pub.log 2>&1 &
PUB=$!
T0=$(python3 -c 'import time;print(repr(time.time()))')
echo "publish started at $T0; audio stops about ${PRE}s in"

sleep $((PRE + POST + 12))
pkill -f "127\.0\.0\.1:$PORT/" 2>/dev/null
sleep 4
kill $PUB $RELAY 2>/dev/null
sleep 1

# --- what each tier saw ---------------------------------------------------------------------
python3 - "$W" "$T0" "$AUDIO_PID" "$PRE" <<'PY'
import json, os, re, sys
w, t0, apid, pre = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])

print("\n--- tier 3: the standalone client-edge monitor ---")
events = []
for line in open(f"{w}/out/liveness.jsonl"):
    line = line.strip()
    if not line:
        continue
    try:
        events.append(json.loads(line))
    except Exception:
        pass
alarms = [e for e in events if e.get("event") in ("stall", "alarm", "gap")]
thresholds = [e for e in events if e.get("event") in ("threshold", "learned")]
if thresholds:
    print(f"thresholds learned for {len(thresholds)} event(s)")
if not alarms:
    print("NO ALARM RAISED -- the monitor did not catch the fault")

# An alarm on every watched PID at once is the source stopping, not a fault in the service. Only
# an alarm with other PIDs still healthy behind it localises anything, and localisation is the
# property being tested: a detector that fires when everything stops is the cheap clock-progression
# layer T24 already showed to be insufficient.
def when(a):
    return a.get("media_time", a.get("t")) or 0.0

last = max((when(a) for a in alarms), default=0.0)
for a in sorted(alarms, key=when)[:8]:
    pid, at = a.get("pid"), when(a)
    kind = "end of stream" if last - at < 0.25 else "localised -- other PIDs still delivering"
    print(f"  {a.get('event')} pid={pid} at media t={at:.3f}  [{kind}]"
          f"{'  <-- the suppressed PID' if pid == apid else ''}")

localised = [a for a in alarms if last - when(a) >= 0.25]
caught = any(a.get("pid") == apid for a in localised)
print(f"\ncaught the suppressed audio PID, with the rest of the service still healthy: "
      f"{'YES' if caught else 'NO'}")
if caught:
    ta = min(when(a) for a in localised if a.get("pid") == apid)
    print(f"it was the only PID alarming at media t={ta:.3f}; the next alarm is {last - ta:.2f}s "
          f"later and is every remaining PID at once, i.e. the source ending")

print("\n--- tier 2: the relay's own view ---")
log = open(f"{w}/logs/relay.log").read()
# What matters is not the counter values but whether anything in the relay's account of itself
# changed when the audio died. Bytes, groups and frames all continue: the payload is opaque to it.
print(f"relay log lines mentioning an error or close: "
      f"{len(re.findall(r'ERROR|WARN|closed', log))}")
print("stats were enabled but could not be subscribed to: the relay publishes them as JSON")
print("tracks and the shipped CLI has no JSON sink. The schema is read from the source instead.")
print("the relay publishes announced/broadcasts/subscriptions/bytes/frames/groups/datagrams")
print("per broadcast path, and sessions per auth root. None of those fields is per-PID, so a")
print("service that loses one elementary stream is not expressible in them.")

print("\n--- the groomer, which was not modified or instrumented ---")
g = f"{w}/out/groomed.ts"
sz = os.path.getsize(g) if os.path.exists(g) else 0
print(f"groomed output: {sz} bytes ({sz // 188} packets)")
print(f"pacer log tail: {open(f'{w}/logs/pacer.log').read().strip().splitlines()[-1:]}")
print("the monitor ran on its own subscription; the groomer took no flags it does not")
print("already take and no patch.")

if sz == 0:
    print("\nHARNESS FAILURE: the groomer produced nothing, so concurrency is not demonstrated")
    sys.exit(1)
if not events:
    print("\nHARNESS FAILURE: the monitor produced no events at all")
    sys.exit(1)
PY
