#!/bin/bash
# How long does a live session keep serving when the authorization endpoint goes down, if the
# endpoint never said how long that should be?
#
# The relay's source says two different things about this. `Auth::revalidate`'s doc comment:
#
#     "...or keeps failing for the whole staleness window, 3x the last max-age
#      ([`Expired::Stale`])."
#
# but `CacheHints::schedule` takes the window from the endpoint's `stale-if-error` or
# `stale-while-revalidate` and, absent both, falls back to a constant:
#
#     const DEFAULT_STALE: Duration = Duration::from_secs(60 * 60);
#
# 3x a 1-second max-age is 3 seconds. DEFAULT_STALE is 3600. The two readings differ by a
# factor of 1200, and they differ in the direction that matters: an operator who tightens
# `max-age` to shorten the revocation window would, on the first reading, also be tightening
# outage tolerance to a few seconds, and on the second reading would not be touching it at all.
#
# This arm distinguishes them. One session, `Cache-Control: max-age=1` and NO stale directive,
# endpoint taken down at a known instant. If the window is 3x max-age the session stops at
# about 3 s. If it is DEFAULT_STALE it is still serving when this script gives up.
#
# A pass/fail is not the point here; the reading is which of the two the relay does.
#
# Usage: t37-staleness-default.sh [watch_s]

set -u
WATCH="${1:-75}"

W=/tmp/t37st
R=/Users/tdrapier/moq-mpegts-paper/lab/scripts
M=~/bin-3529/moq
PORT=9744
HTTP=9781
APORT=9702
rm -rf $W
mkdir -p $W/keydir $W/tok $W/logs $W/out
cd $W

EXP=$(($(date +%s) + 7200))
$M token generate --algorithm HS256 --id affa --out-dir $W/keydir >/dev/null 2>&1
# `exp` is two hours out so the credential's own expiry cannot be what ends the session --
# otherwise a long staleness window and a short-lived token are indistinguishable.
$M token sign --key $W/keydir/affa.jwk --root wbd --subscribe cnn --expires $EXP >$W/tok/affa.jwt

python3 - "$W" <<'PY'
import json, sys
w = sys.argv[1]
json.dump({
    "mode": "up",
    # max-age only. Naming neither stale-if-error nor stale-while-revalidate is the whole
    # point: it is the default path that is under test.
    "cache_control": "max-age=1",
    "channels": ["cnn"],
    "affiliates": {"affa": {"enabled": True, "channels": ["cnn"], "key": f"{w}/keydir/affa.jwk"}},
    "public": {"wbd": {"subscribe": [], "publish": ["cnn"]}},
    "alias": {}, "tier": None,
}, open(f"{w}/state.json", "w"), indent=1)
PY

python3 $R/t37-auth-stub.py --port $APORT --state $W/state.json --log $W/authlog.jsonl \
	>$W/logs/stub.log 2>&1 &
STUB=$!
sleep 2
$M-relay --server-bind 127.0.0.1:$PORT --tls-generate localhost --server-quic-gso=false \
	--web-http-listen 127.0.0.1:$HTTP --auth-api "http://127.0.0.1:$APORT/auth" --log-level info \
	>$W/logs/relay.log 2>&1 &
RELAY=$!
trap 'kill $STUB $RELAY 2>/dev/null' EXIT
sleep 4
FP=$(curl -s --max-time 4 http://127.0.0.1:$HTTP/certificate.sha256)
[ -z "$FP" ] && {
	echo "relay did not start"
	exit 1
}

tsp -I file ~/t12_vidonly.ts --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
	$M --client-connect "https://127.0.0.1:$PORT/wbd" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --broadcast cnn import ts >$W/logs/pub.log 2>&1 &
PUB=$!
trap 'kill $STUB $RELAY $PUB 2>/dev/null' EXIT
sleep 5

AJ=$(cat $W/tok/affa.jwt)
(timeout $((WATCH + 60)) $M --client-connect "https://127.0.0.1:$PORT/wbd?jwt=$AJ" \
	--client-tls-fingerprint "$FP" --client-quic-gso=false --broadcast cnn export ts 2>$W/logs/s.log |
	python3 $R/t37-lastbyte.py --out $W/out/s.ts --record $W/out/s.json --mark s) \
	>>$W/logs/lb.log 2>&1 &
sleep 12

RQ=$(wc -l <$W/authlog.jsonl | tr -d ' ')
echo "re-checks logged before the outage: $RQ (cadence is 1s, so this confirms revalidation is armed)"

T0=$(python3 -c "
import json,time
s=json.load(open('$W/state.json')); s['mode']='unavailable'
t=time.time(); json.dump(s,open('$W/state.json','w'),indent=1); print(repr(t))")
echo "endpoint taken down at $T0; watching ${WATCH}s"

for t in $(seq 10 10 "$WATCH"); do
	sleep 10
	printf "  t0+%3ds  %s bytes delivered\n" "$t" "$(stat -f%z $W/out/s.ts 2>/dev/null || echo 0)"
done

TEND=$(python3 -c 'import time;print(repr(time.time()))')
echo "$TEND" >$W/tend
pkill -f "127\.0\.0\.1:$PORT/wbd.jwt=" 2>/dev/null
sleep 4
kill $PUB 2>/dev/null
sleep 1

python3 - "$W" "$T0" <<'PY'
import json, sys
w, t0 = sys.argv[1], float(sys.argv[2])
tend = float(open(f"{w}/tend").read().strip())
r = json.load(open(f"{w}/out/s.json"))
prof = r["profile"]
last = prof[0][0]
for (ta, _), (tb, _) in zip(prof, prof[1:]):
    if tb - ta > 2.0:
        break
    last = tb
served = last - t0
watched = tend - t0
# The stub's own log says whether the relay kept trying, which separates "still serving
# because it is tolerating an outage" from "still serving because it never noticed".
attempts = 0
for line in open(f"{w}/authlog.jsonl"):
    try:
        if json.loads(line).get("decision") == "unavailable-503":
            attempts += 1
    except Exception:
        pass
print(f"\nmedia continued for {served:.1f}s after the endpoint went down")
print(f"the run watched {watched:.1f}s")
print(f"the relay made {attempts} re-check attempts into the outage (all answered 503)")
print(f"\n'3x the last max-age' would predict   ~3.0s")
print(f"DEFAULT_STALE would predict           ~3600s (longer than this run)")
if served >= watched - 3.0:
    print(f"\n=> still serving when the run ended. The 3x-max-age reading is REFUTED;")
    print(f"   the window is the constant default, not a multiple of max-age.")
elif served < 10:
    print(f"\n=> stopped early; consistent with a window that scales with max-age")
else:
    print(f"\n=> stopped at {served:.1f}s, which matches neither reading; investigate")
PY
