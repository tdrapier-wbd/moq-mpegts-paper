#!/usr/bin/env bash
# P1-k -- does a key-per-entitlement estate scale?
#
# T38 established that de-provisioning at the grant level does not exist: narrowing one
# affiliate's entitlement means issuing a key per unit of entitlement, so the key estate is
# sized by the licensing matrix (affiliates x channels) rather than by the affiliate count.
# T38 § Open names the practical objection -- "hundreds of affiliates times tens of channels,
# each a key the endpoint must serve and the relay must cache" -- and leaves it untested.
#
# This measures the relay's side of that estate against estate size:
#
#   * time from launch to serving          -- does the relay load the estate eagerly?
#   * resident memory once serving         -- what does caching the estate cost?
#   * time to first media byte             -- does admission degrade with estate size?
#   * disk footprint of the key directory
#
# THE CONTROL COMES FIRST AND THE LADDER IS VOID WITHOUT IT. `moq token generate` costs a
# process spawn per key (0.284 s measured), so a 9,000-key estate would be 40 minutes of
# spawning; the estate here is minted directly instead, which is also how an operator would
# provision it. A minted key is only usable evidence if the relay actually accepts a token
# signed with one, so cell 0 signs with a minted key and requires admission before any
# ladder cell runs.
#
# Nothing below prints key or token material.
#
# Usage: t38-key-estate-scale.sh [estate sizes ...]      (default: 10 100 500 2000 9000)

set -u
M="${MOQ:-$HOME/bin-3529/moq}"
CLIP="${CLIP:-$HOME/t12_vidonly.ts}"
W="${W:-/tmp/p1k}"
PORT=9751
HTTP=9752
WINDOW=14 # seconds a cell is given to reach first byte

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10 100 500 2000 9000)

[ -x "$M" ] || { echo "FAIL: $M not executable" >&2; exit 1; }
[ -r "$CLIP" ] || { echo "FAIL: clip not readable: $CLIP" >&2; exit 1; }

rm -rf "$W" && mkdir -p "$W/logs" "$W/out" && cd "$W" || exit 1
SUMMARY="$W/summary.csv"
echo "estate_keys,affiliates,channels,keydir_bytes,mint_s,relay_start_s,relay_rss_kb,first_byte_s,bytes,verdict" >"$SUMMARY"

# Mint an estate shaped like a licensing matrix: one key per (affiliate, channel) pair, which
# is the unit T38 showed de-provisioning actually requires.
# NOTE: this heredoc is deliberately not indented. `<<-` strips leading tabs, which would
# flatten the Python nesting below into an IndentationError.
mint() { # <dir> <affiliates> <channels>
	python3 - "$1" "$2" "$3" <<'PY'
import base64, json, os, secrets, sys
d, naff, nchan = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
for a in range(naff):
    for c in range(nchan):
        kid = f"aff{a:04d}-ch{c:03d}"
        jwk = {"alg": "HS256", "key_ops": ["sign", "verify"], "kty": "oct",
               "k": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="),
               "kid": kid}
        blob = base64.urlsafe_b64encode(json.dumps(jwk).encode()).decode().rstrip("=")
        with open(os.path.join(d, kid + ".jwk"), "w") as f:
            f.write(blob)
PY
}

# Factor an estate size into a plausible affiliates x channels matrix.
factor() { python3 -c "
import math,sys
n=int(sys.argv[1])
c=min(30,max(1,int(math.isqrt(n)//2) or 1))
while n%c: c-=1
print(n//c,c)" "$1"; }

run_cell() { # <estate size>
	local N="$1" AFF CHAN KD T0 MINT START RSS FB BYTES VERDICT PUB SUB RELAY
	read -r AFF CHAN <<<"$(factor "$N")"
	KD="$W/kd$N"

	T0=$(python3 -c 'import time;print(time.time())')
	mint "$KD" "$AFF" "$CHAN"
	MINT=$(python3 -c "import time;print(f'{time.time()-$T0:.2f}')")
	local COUNT
	COUNT=$(find "$KD" -name '*.jwk' | wc -l | tr -d ' ')
	[ "$COUNT" -eq "$N" ] || { echo "  FAIL: minted $COUNT keys, wanted $N"; return 1; }

	# The token is signed with the LAST key in the estate, so any per-request linear scan over
	# the directory is exercised at its worst case rather than its best.
	local LASTKEY
	LASTKEY="$KD/aff$(printf '%04d' $((AFF - 1)))-ch$(printf '%03d' $((CHAN - 1))).jwk"
	[ -r "$LASTKEY" ] || { echo "  FAIL: no last key at $LASTKEY"; return 1; }
	local EXP=$(($(date +%s) + 3600))
	$M token sign --key "$LASTKEY" --root wbd --publish "" --subscribe "" \
		--expires "$EXP" >"$W/tok$N.jwt" 2>"$W/logs/sign$N.log" || {
		echo "  FAIL: could not sign with a minted key"
		return 1
	}

	T0=$(python3 -c 'import time;print(time.time())')
	$M-relay --server-bind "127.0.0.1:$PORT" --tls-generate localhost --server-quic-gso=false \
		--web-http-listen "127.0.0.1:$HTTP" --auth-key-dir "$KD" --log-level warn \
		>"$W/logs/relay$N.log" 2>&1 &
	RELAY=$!
	local FP=""
	for _ in $(seq 1 400); do
		FP=$(curl -s --max-time 2 "http://127.0.0.1:$HTTP/certificate.sha256" 2>/dev/null)
		[ -n "$FP" ] && break
		sleep 0.25
	done
	START=$(python3 -c "import time;print(f'{time.time()-$T0:.2f}')")
	if [ -z "$FP" ]; then
		echo "  $N keys: relay never served -- estate too large to load"
		kill $RELAY 2>/dev/null
		echo "$N,$AFF,$CHAN,$(du -sk "$KD" | cut -f1)000,$MINT,$START,,,0,RELAY_NEVER_SERVED" >>"$SUMMARY"
		return 0
	fi
	RSS=$(ps -o rss= -p $RELAY 2>/dev/null | tr -d ' ')

	local URL
	URL="https://127.0.0.1:$PORT/wbd?jwt=$(cat "$W/tok$N.jwt")"
	local CAP="$W/out/$N.ts"
	: >"$CAP"
	timeout $WINDOW "$M" --client-connect "$URL" --client-tls-fingerprint "$FP" \
		--client-quic-gso=false --backoff-timeout 5s --broadcast "estate$N" \
		export ts >"$CAP" 2>"$W/logs/sub$N.log" &
	SUB=$!
	sleep 1
	T0=$(python3 -c 'import time;print(time.time())')
	timeout $WINDOW tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		timeout $WINDOW "$M" --client-connect "$URL" --client-tls-fingerprint "$FP" \
			--client-quic-gso=false --backoff-timeout 4s --broadcast "estate$N" \
			import ts >"$W/logs/pub$N.log" 2>&1 &
	PUB=$!
	FB=""
	for _ in $(seq 1 $((WINDOW * 10))); do
		if [ "$(stat -f%z "$CAP" 2>/dev/null || echo 0)" -gt 20000 ]; then
			FB=$(python3 -c "import time;print(f'{time.time()-$T0:.2f}')")
			break
		fi
		sleep 0.1
	done
	wait $PUB 2>/dev/null
	kill $SUB $RELAY 2>/dev/null
	wait $SUB 2>/dev/null
	sleep 1

	BYTES=$(stat -f%z "$CAP" 2>/dev/null || echo 0)
	if [ -n "$FB" ]; then VERDICT=ok; else
		VERDICT=NO_MEDIA
		FB=""
	fi
	printf '  %6s keys (%s aff x %s ch): mint %ss, relay start %ss, RSS %s kB, first byte %ss -> %s\n' \
		"$N" "$AFF" "$CHAN" "$MINT" "$START" "${RSS:-?}" "${FB:-none}" "$VERDICT"
	echo "$N,$AFF,$CHAN,$(du -sk "$KD" | cut -f1)000,$MINT,$START,${RSS:-},${FB:-},$BYTES,$VERDICT" >>"$SUMMARY"
	rm -f "$CAP"
}

echo "== cell 0: does the relay accept a token signed with a minted key? (the ladder is void if not) =="
run_cell 10 || { echo "CONTROL FAILED -- minted keys are not equivalent to generated ones; stop."; exit 1; }
if ! tail -1 "$SUMMARY" | grep -q ',ok$'; then
	echo "CONTROL FAILED -- a minted key did not admit a session; the ladder would measure nothing."
	exit 1
fi
echo "  control holds: minted keys are accepted, so the estate can be provisioned programmatically"
echo
echo "== ladder =="
for N in "${SIZES[@]}"; do
	[ "$N" = 10 ] && continue
	run_cell "$N"
done

echo
echo "== summary =="
column -s, -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
