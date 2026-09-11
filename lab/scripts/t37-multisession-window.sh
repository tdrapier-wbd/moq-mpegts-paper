#!/bin/bash
# Does the revocation bound hold when more than one session shares the auth cache?
#
# T37 measured teardown = (cadence - phase) + 0.110 s on a SINGLE session, giving a worst case
# of one cadence plus 110 ms. The relay's own source says the deployed bound is larger:
#
#     "a re-check may be answered from an entry up to one `max-age` old, so the revocation
#      window is up to TWICE the endpoint's `max-age`. Size it accordingly."
#         -- rs/moq-relay/src/auth.rs, Auth::revalidate
#
# With one session there is no other session's cache entry to be served from, so the single-
# session rig cannot see this even in principle. This arm runs several sessions started at
# staggered times against one endpoint, revokes them all at one instant, and measures each
# session's last media byte. If the source comment is right, at least one session should tear
# down materially later than one cadence plus 110 ms.
#
# Zero of the measurement is the instant the state file flips, taken from the stub's own log,
# and the stop is the last TS packet the subscriber received -- never a relay log line.
#
# Usage: t37-multisession-window.sh [sessions] [cadence_s] [stagger_s] [settle_s]

set -u
N="${1:-6}"
CAD="${2:-5}"
STAG="${3:-1}"
SETTLE="${4:-25}"

W=/tmp/t37ms
R=/Users/tdrapier/moq-mpegts-paper/lab/scripts
M=~/bin-3529/moq
PORT=9743
HTTP=9780
APORT=9701
rm -rf $W
mkdir -p $W/keydir $W/tok $W/logs $W/out
cd $W

EXP=$(($(date +%s) + 7200))
$M token generate --algorithm HS256 --id affa --out-dir $W/keydir >/dev/null 2>&1
$M token generate --algorithm HS256 --id affb --out-dir $W/keydir >/dev/null 2>&1
$M token sign --key $W/keydir/affa.jwk --root wbd --subscribe cnn --expires $EXP >$W/tok/affa.jwt
$M token sign --key $W/keydir/affb.jwk --root wbd --subscribe cnn --expires $EXP >$W/tok/affb.jwt

# The stub holds the public verifying key, never a signing key.
python3 - "$W" <<'PY'
import base64, json, os, sys
w = sys.argv[1]
# HS256 is symmetric, so the stub is handed the same JWK the relay's key-dir holds. That is a
# property of the algorithm, not of the design; ES256 in T38 Part 5 exercised the split.
# `publish` is public but `subscribe` is NOT. The source under test has to reach the
# subscribers without a credential of its own, because the only per-session lever this stub
# offers for a blanket refusal (`mode: refuse`) 404s every request including the publisher's
# re-check -- which would stop media at the source and have every subscriber fall silent
# together, measuring the publisher's teardown rather than each subscriber's. Leaving
# `subscribe` off the public grant keeps the subscribers on the credential path, which is the
# path being measured.
state = {
    "mode": "up",
    "cache_control": None,   # filled in below
    "channels": ["cnn"],
    "affiliates": {
        "affa": {"enabled": True, "channels": ["cnn"], "key": f"{w}/keydir/affa.jwk"},
        # affb is never revoked. It is the control: if it falls silent alongside the subjects
        # then something other than affa's revocation stopped the media, and the run says
        # nothing about revocation latency.
        "affb": {"enabled": True, "channels": ["cnn"], "key": f"{w}/keydir/affb.jwk"},
    },
    "public": {"wbd": {"subscribe": [], "publish": ["cnn"]}},
    "alias": {}, "tier": None,
}
json.dump(state, open(f"{w}/state.json", "w"), indent=1)
PY
python3 -c "
import json,sys
s=json.load(open('$W/state.json')); s['cache_control']='max-age=$CAD'
json.dump(s,open('$W/state.json','w'),indent=1)"

python3 $R/t37-auth-stub.py --port $APORT --state $W/state.json --log $W/authlog.jsonl \
	>$W/logs/stub.log 2>&1 &
STUB=$!
sleep 2

$M-relay --server-bind 127.0.0.1:$PORT --tls-generate localhost --server-quic-gso=false \
	--web-http-listen 127.0.0.1:$HTTP --auth-api "http://127.0.0.1:$APORT/auth" --log-level info \
	>$W/logs/relay.log 2>&1 &
RELAY=$!
trap 'kill $STUB $RELAY 2>/dev/null; pkill -f "127.0.0.1:$PORT" 2>/dev/null' EXIT
sleep 4
FP=$(curl -s --max-time 4 http://127.0.0.1:$HTTP/certificate.sha256)
[ -z "$FP" ] && {
	echo "relay did not start"
	tail -5 $W/logs/relay.log
	exit 1
}
AJ=$(cat $W/tok/affa.jwt)
BJ=$(cat $W/tok/affb.jwt)

tsp -I file ~/t12_vidonly.ts --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
	$M --client-connect "https://127.0.0.1:$PORT/wbd" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --broadcast cnn import ts >$W/logs/pub.log 2>&1 &
PUB=$!
trap 'kill $STUB $RELAY $PUB 2>/dev/null' EXIT
sleep 5

# Staggered starts, so the sessions' re-check phases are spread across the cadence rather
# than aligned -- aligned sessions are one measurement repeated (method-notes §3).
#
# The session timeout deliberately outlasts the reporting window. A session that is killed by
# its own timeout would report a last byte at the kill instant, which is indistinguishable
# from a very late teardown; giving it room means a session still serving at the report point
# is visible AS still serving rather than mimicking a measurement.
echo "starting $N sessions, ${STAG}s apart, cadence ${CAD}s"
SPIDS=""
for i in $(seq 1 "$N"); do
	(timeout $((SETTLE + CAD * 12 + 60)) $M --client-connect "https://127.0.0.1:$PORT/wbd?jwt=$AJ" \
		--client-tls-fingerprint "$FP" --client-quic-gso=false --broadcast cnn export ts 2>$W/logs/s$i.log |
		python3 $R/t37-lastbyte.py --out $W/out/s$i.ts --record $W/out/s$i.json --mark "s$i") \
		>>$W/logs/lb.log 2>&1 &
	SPIDS="$SPIDS $!"
	sleep "$STAG"
done

# The control, started alongside the subjects on the affiliate that is never revoked.
(timeout $((SETTLE + CAD * 12 + 60)) $M --client-connect "https://127.0.0.1:$PORT/wbd?jwt=$BJ" \
	--client-tls-fingerprint "$FP" --client-quic-gso=false --broadcast cnn export ts 2>$W/logs/c.log |
	python3 $R/t37-lastbyte.py --out $W/out/c.ts --record $W/out/c.json --mark "c") \
	>>$W/logs/lb.log 2>&1 &
CPID=$!
SPIDS="$SPIDS $CPID"

sleep "$SETTLE"

echo "media check before revocation:"
for i in $(seq 1 "$N"); do printf "  s%s %s bytes\n" "$i" "$(stat -f%z $W/out/s$i.ts 2>/dev/null || echo 0)"; done

# The decision: withdraw THIS affiliate's licence, which is the targeted lever (the stub
# answers 200 without a key, KeyNotFound at the relay, a refusal). The blanket `mode: refuse`
# is deliberately not used -- see the state-file comment above.
T0=$(python3 -c "
import json,time
s=json.load(open('$W/state.json')); s['affiliates']['affa']['enabled']=False
t=time.time(); json.dump(s,open('$W/state.json','w'),indent=1); print(repr(t))")
echo "revoked at $T0"

sleep $((CAD * 6 + 10))
TKILL=$(python3 -c 'import time;print(repr(time.time()))')
echo "$TKILL" >$W/tkill
# Stop the SUBSCRIBING CLIENTS, not the recorders. The recorder writes its record when its
# stdin closes, so killing the subshell kills the recorder mid-stream and no record is written
# at all -- which is how the control silently produced no file on the first attempt. Killing
# only the client gives the recorder an EOF and it flushes normally. The subjects wrote records
# either way because their clients had already exited on their own after revocation; the
# control, still being served, had not.
# pkill -f takes an extended regex, so the '?' in the query string is a quantifier, not a
# literal: "wbd?jwt=" matches "wbjwt=" and "wbdjwt=" and never the actual command line.
pkill -f "127\.0\.0\.1:$PORT/wbd.jwt=" 2>/dev/null
sleep 4
for p in $SPIDS; do kill "$p" 2>/dev/null; done
kill $PUB 2>/dev/null
sleep 1
# `wait` is not used: the stub and the relay are children of this shell too, and neither exits.

python3 - "$W" "$T0" "$CAD" "$N" <<'PY'
import json, os, sys
w, t0, cad, n = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
tkill = float(open(f"{w}/tkill").read().strip())
print(f"\n{'session':<9}{'last byte':>12}{'bytes':>12}   verdict vs bounds")
single = cad + 0.110
double = 2 * cad + 0.110
rows, censored = [], 0
for i in range(1, n + 1):
    p = f"{w}/out/s{i}.json"
    if not os.path.exists(p):
        print(f"s{i:<8}{'no record':>12}")
        continue
    r = json.load(open(p))
    if not r.get("last_write") or not r.get("bytes"):
        print(f"s{i:<8}{'no media':>12}")
        continue
    # `last_write` is NOT the last media byte. When the relay closes the session the client
    # spends 10 s in its reconnect loop before exiting, and the pipe then flushes whatever was
    # still buffered -- a final small write ~10 s after delivery actually stopped. Reading
    # `last_write` directly reported teardowns of 14-18 s against a 5.1 s bound, which is the
    # instrument, not the relay. The last media byte is the end of the last unbroken run of
    # writes, so a gap far longer than the inter-write interval terminates the measurement.
    prof = r.get("profile") or []
    if len(prof) < 3:
        print(f"s{i:<8}{'too few writes':>14}")
        continue
    GAP = 2.0   # writes arrive every ~0.3 s at this rate; 2 s is ~6x that
    last = prof[0][0]
    for (ta, _), (tb, _) in zip(prof, prof[1:]):
        if tb - ta > GAP:
            break
        last = tb
    d = last - t0
    # A session still being written to when the harness stopped it is right-censored.
    if last >= tkill - 1.0:
        censored += 1
        print(f"s{i:<8}{d:>11.3f}s{r['bytes']:>12}   STILL SERVING at kill (censored)")
        continue
    rows.append(d)
    tag = "within 1x" if d <= single else ("EXCEEDS 1x" if d <= double else "EXCEEDS 2x")
    print(f"s{i:<8}{d:>11.3f}s{r['bytes']:>12}   {tag}")
print(f"\nsingle-session bound (cadence + 0.110)     = {single:.3f}s")
print(f"source's stated bound (2x cadence + 0.110) = {double:.3f}s")
if rows:
    print(f"n={len(rows)} measured  min {min(rows):.3f}s  median {sorted(rows)[len(rows)//2]:.3f}s  max {max(rows):.3f}s")
    over = sum(1 for d in rows if d > single)
    print(f"{over} of {len(rows)} measured sessions exceeded the single-session bound")
if censored:
    print(f"{censored} session(s) still serving at kill -- teardown exceeds "
          f"{tkill - t0:.1f}s, beyond this run's window")

# The control decides whether any of the above is a measurement at all.
cp = f"{w}/out/c.json"
ctrl_ok = False
if os.path.exists(cp):
    c = json.load(open(cp))
    prof = c.get("profile") or []
    if len(prof) >= 3:
        last = prof[0][0]
        for (ta, _), (tb, _) in zip(prof, prof[1:]):
            if tb - ta > 2.0:
                break
            last = tb
        cd = last - t0
        ctrl_ok = last >= tkill - 2.0
        print(f"\ncontrol (affb, never revoked): last media byte t0{cd:+.3f}s, "
              f"{'still serving at kill -- CONTROL HELD' if ctrl_ok else 'STOPPED EARLY -- CONTROL FAILED'}")
if not ctrl_ok:
    print("the control did not hold, so this run does not measure revocation latency")
    sys.exit(1)

if rows and not censored:
    print("=> the single-session figure UNDERSTATES a multi-session estate"
          if sum(1 for d in rows if d > single) else
          "=> no session exceeded the single-session bound in this run")
# A harness that measured nothing must not report success. The first version of this script
# exited 0 after every session failed to start, which reads identically to a clean null.
if not rows and not censored:
    print("\nHARNESS FAILURE: no session produced a usable record; nothing was measured")
    sys.exit(1)
PY
