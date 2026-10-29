#!/usr/bin/env bash
# Grade one T59 run on the receiver host (lab/test-59-segmented-1plus1-cloudfront.md).
#
#   t59-grade.sh RUN_DIR SECONDS
#
# The last 12 s of a capture are the groomers draining after the fetchers stop at SECONDS, on both
# legs at once, so the graded span ends there ("tail"). Grades the pair at a Class C 450 ms window
# and again at a window covering the run's measured skew plus 500 ms (horizon 16,000 datagrams),
# checks the merged output's continuity up to the tail, and writes the per-leg report.

set -uo pipefail
RUN=${1:?usage: t59-grade.sh RUN_DIR SECONDS}
SECS=${2:?}
H=$(dirname "$0")
cd "$RUN" || exit 1
touch events.txt
t0=$(python3 -c '
import struct, sys
f = open("legs.pcap", "rb"); f.read(24); s, u, *_ = struct.unpack("<IIII", f.read(16)); print(int((s + u / 1e6) * 1e9))')
{
	cat events.txt
	echo "b-settled $((t0 + ${SETTLE:-40} * 10 ** 9))"
	echo "tail $((t0 + (SECS - 12) * 10 ** 9))"
} >cuts.txt
python3 "$H/t55-grade.py" legs.pcap --events cuts.txt --window-ms 450 --pair-s 5 --json g450.json --out /dev/null >/dev/null 2>grade.err
w=$(python3 -c 'import json; s = json.load(open("g450.json"))["skew_ms"]; print(int(max(abs(s[0]), abs(s[2])) + 500))')
python3 "$H/t55-grade.py" legs.pcap --events cuts.txt --window-ms "$w" --ahead 16000 --pair-s 5 \
	--json gwide.json --out merged.ts >/dev/null 2>>grade.err
# The merged stream starts at the first datagram; 26 Mb/s is 17,287 packets a second.
head -c $(((SECS - 12) * 17287 * 188)) merged.ts | tsp -I file - -P continuity -O drop >cc.txt 2>&1
rm -f merged.ts
python3 "$H/t59-leg-report.py" legs.pcap --json legs.json >/dev/null
python3 - "$w" <<'PY'
import json, sys
g4, gw, lg = (json.load(open(f)) for f in ("g450.json", "gwide.json", "legs.json"))
cc = sum(1 for l in open("cc.txt") if "continuity:" in l)
print("skew_ms", g4["skew_ms"])
print("identity", json.dumps([(x["name"], x["start"], x["matched"], x["mismatched"], x["unpaired"]) for x in g4["identity"]]))
for name, g in (("450", g4), (sys.argv[1], gw)):
	r = g["receiver"]
	print(f"merge@{name}ms lost={r['lost']} conflicts={r['conflicts']} ignored={r['ignored']} relocks={r['relocks']} skipped={r['skipped_on_relock']}")
print(f"merged_cc_to_tail={cc}")
for l in "ab":
	x = lg[l]
	print(f"leg {l}: start={lg[l + '_start_s'] if l + '_start_s' in lg else ''} holes={x['holes']} cc={x['cc_errors']}")
print("b_not_in_a", lg["b_not_in_a"][:6], "a_not_in_b", lg["a_not_in_b"][:6])
PY
for l in a b; do
	echo "pacer $l: $(grep -h 'done\.' pacer-$l.log | tail -n 1 | grep -o 'dropped=[0-9]* late_drops=[0-9]*.*' | cut -c1-200) $(grep -o 'pcr_rebases=[0-9]*' pacer-$l.log | tail -n 1)"
	echo "b8 $l: $(grep -c '"seg"' b8-$l.jsonl) segs, $(grep -c '"seg-retry"' b8-$l.jsonl) retries, $(grep -c '"seg-lost"' b8-$l.jsonl) lost, $(grep -c '"pl-fail"' b8-$l.jsonl) playlist failures, $(grep -c '"msn-skip"' b8-$l.jsonl) sequence skips, $(grep -c 'Hit from' b8-$l.jsonl) hits"
done
