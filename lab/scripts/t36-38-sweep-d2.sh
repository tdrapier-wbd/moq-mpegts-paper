#!/bin/bash
# T37 D2: withdraw the grant, swept across the re-check cadence.
#
# The decision instant is given a RANDOM sub-cadence offset. Without it the
# settle time is an integer and the decision lands at a fixed phase of the poll
# schedule, which produces five identical readings that look like a tight
# distribution and are actually one measurement repeated. Revocation latency is
# expected to be roughly uniform on [0, cadence]; only a randomised phase can
# show that.
W=/tmp/t36
cd $W
REPS="${REPS:-6}"
: > $W/sweep-d2.tsv

for cad in 1 2 5 10 30; do
  obs=$(python3 -c "print(int($cad)+8)")
  for r in $(seq 1 $REPS); do
    id="S-c${cad}-r${r}"
    off=$(python3 -c "import random;print(round(random.uniform(0,$cad),3))")
    python3 $W/mkstate.py --cache-control "max-age=$cad" --mark "reset $id" > /dev/null
    sleep 1
    OFFSET=$off ./dartm.sh "$id" 6 "$obs" --cache-control "max-age=$cad" \
        --enable "wbdkey,rivalkey,affbkey,affckey" > $W/logs/sweep-$id.txt 2>&1
    python3 - "$id" "$cad" "$off" >> $W/sweep-d2.tsv <<'PY'
import json, sys
W="/tmp/t36"; mark, cad, off = sys.argv[1], sys.argv[2], sys.argv[3]
dec=[d for d in (json.loads(l) for l in open(f"{W}/decisions.jsonl")) if d.get("mark")==mark]
lbs={r["mark"]: r for r in (json.loads(l) for l in open(f"{W}/lastbyte.jsonl"))}
auth=[json.loads(l) for l in open(f"{W}/authlog.jsonl")]
if dec:
    t0=dec[-1]["wall"]
    a=lbs.get(f"{mark}-A"); c=lbs.get(f"{mark}-C")
    ta = (a["last_write"]-t0) if a and a.get("last_write") else float("nan")
    tc = (c["last_write"]-t0) if c and c.get("last_write") else float("nan")
    st = a["first_write"] if a and a.get("first_write") else t0
    reqs=[r for r in auth if r.get("kid")=="affakey" and st <= r["wall"] <= t0]
    dur=max(t0-st,1e-9)
    # collateral continuity: did the uninvolved affiliate lose anything?
    print(f"{cad}\t{mark}\t{off}\t{ta:.3f}\t{tc:.3f}\t{len(reqs)}\t{dur:.3f}\t{len(reqs)/dur:.3f}")
PY
    echo "  $id (phase offset ${off}s) done"
  done
done
echo "sweep -> $W/sweep-d2.tsv"
