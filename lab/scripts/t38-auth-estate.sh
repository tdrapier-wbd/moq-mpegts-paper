#!/usr/bin/env bash
# T38, the estate behind an auth server: the key ladder, then provision, withdraw and isolation.
# usage: t38-auth-estate.sh <out-dir> [estate sizes ...]      (default: 10 100 500 2000 9000 20000)
#   publisher -> origin relay (anonymous) -> edge relay (--auth-url, --cluster-connect to the origin)
#   -> affiliates. The relays run throughout; each rung restarts only `moq auth serve --key-dir` on
#   that rung's directory, one key per affiliate-channel pair, minted directly. The rung's token is
#   signed with its last key; the 10-key rung is the control and a refused control stops the run.
#   The arms run on the 9,000-key directory.
# env: MOQ (bin dir: moq, moq-relay), CLIP, OPORT (4801), EPORT (4802), APORT (auth, 4803),
#      IPORT (edge internal listener, 4804), WINDOW (s a subscriber is given, 14)
# Writes summary.csv (one row per rung) and arms.txt. Prints no key or token material.
set -u
OUT=$1
shift
SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10 100 500 2000 9000 20000)
M=$MOQ/moq
OPORT=${OPORT:-4801} EPORT=${EPORT:-4802} APORT=${APORT:-4803} IPORT=${IPORT:-4804}
WINDOW=${WINDOW:-14}
mkdir -p "$OUT/logs" "$OUT/out" && cd "$OUT" || exit 1
exp=$(($(date +%s) + 7200))
now() { date +%s.%N; }
since() { python3 -c "import sys;print(f'{float(sys.argv[2])-float(sys.argv[1]):.2f}')" "$1" "$(now)"; }
size() { stat -c %s "$1" 2>/dev/null || echo 0; }

# NOTE: not indented, so `<<` keeps the Python nesting.
mint() { # <dir> <affiliates> <channels>
python3 - "$1" "$2" "$3" <<'PY'
import base64, json, os, secrets, sys
d, naff, nchan = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
os.makedirs(d, exist_ok=True)
for a in range(naff):
    for c in range(nchan):
        kid = f"aff{a:04d}-ch{c:03d}"
        jwk = {"alg": "HS256", "key_ops": ["sign", "verify"], "kty": "oct",
               "k": base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="), "kid": kid}
        with open(os.path.join(d, kid + ".jwk"), "w") as f:
            f.write(base64.urlsafe_b64encode(json.dumps(jwk).encode()).decode().rstrip("="))
PY
}
factor() { python3 -c "
import math,sys
n=int(sys.argv[1]); c=min(30,max(1,int(math.isqrt(n)//2) or 1))
while n%c: c-=1
print(n//c,c)" "$1"; }
sign() { # <key file> <grant flags...>
	local key=$1
	shift
	"$M" auth sign --key "$key" --root bc "$@" --expires "$exp"
}

auth="" start_s=""
auth_start() { # <key dir> [serve flags...]: sets $auth and $start_s, the seconds to listening
	local kd=$1 t0
	shift
	t0=$(now)
	"$M" auth serve --listen "127.0.0.1:$APORT" --key-dir "$kd" "$@" >>logs/auth.log 2>&1 &
	auth=$!
	for _ in $(seq 1 600); do
		(echo >"/dev/tcp/127.0.0.1/$APORT") 2>/dev/null && break
		sleep 0.05
	done
	start_s=$(since "$t0")
}
auth_stop() { kill "$auth" 2>/dev/null; wait "$auth" 2>/dev/null; auth=""; }

subscribe() { # <token file> <channel> <capture>: background subscriber at the edge, pid in $sub
	"$M" --connect-tls-insecure --connect "moqt://127.0.0.1:$EPORT/bc?jwt=$(cat "$1")" \
		--broadcast "$2" export ts --passthrough >"$3" 2>>"logs/sub-$2.log" &
	sub=$!
}
first_byte() { # <capture> <t0>: seconds to 20 kB, or empty
	for _ in $(seq 1 $((WINDOW * 20))); do
		[ "$(size "$1")" -gt 20000 ] && { since "$2"; return; }
		sleep 0.05
	done
}

cat >origin.toml <<EOF
[log]
level = "warn"

[listen]
bind = "127.0.0.1:$OPORT"
tls.generate = ["localhost"]

[auth]
public = "**"
EOF
cat >edge.toml <<EOF
[log]
level = "info"

[listen]
bind = "127.0.0.1:$EPORT"
tls.generate = ["localhost"]

[auth]
url = "http://127.0.0.1:$APORT"
EOF
"$MOQ/moq-relay" origin.toml --quic-gso=false >logs/origin.log 2>&1 &
origin=$!
"$MOQ/moq-relay" edge.toml --quic-gso=false --connect-tls-insecure \
	--cluster-connect "https://127.0.0.1:$OPORT/" --internal-listen "127.0.0.1:$IPORT" \
	>logs/edge.log 2>&1 &
edge=$!
sleep 1
# The passthrough importer exits where the looped clip's PCR goes back, so every rung and arm, each
# shorter than the clip, starts on freshly started publishers.
pubs=()
publish() {
	[ ${#pubs[@]} -gt 0 ] && kill "${pubs[@]}" 2>/dev/null
	pubs=()
	sleep 0.5
	for ch in ch000 ch001; do
		tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
			"$M" --connect-tls-insecure --connect "moqt://127.0.0.1:$OPORT/bc" --broadcast "$ch" \
				import ts --passthrough >>"logs/pub-$ch.log" 2>&1 &
		pubs+=($!)
	done
	sleep 4
}

echo "estate_keys,affiliates,channels,keydir_kb,mint_s,auth_start_s,auth_rss_kb,first_byte_s,verdict" >summary.csv
rung() { # <estate size>
	local n=$1 aff chan kd t0 mint_s start rss fb last
	read -r aff chan <<<"$(factor "$n")"
	kd=$OUT/kd$n
	t0=$(now)
	mint "$kd" "$aff" "$chan"
	mint_s=$(since "$t0")
	last=$kd/aff$(printf '%04d' $((aff - 1)))-ch$(printf '%03d' $((chan - 1))).jwk
	sign "$last" --subscribe '**' >"tok$n.jwt" 2>>logs/sign.log || return 1
	publish
	auth_start "$kd"
	start=$start_s
	t0=$(now)
	subscribe "tok$n.jwt" ch000 "out/$n.ts"
	fb=$(first_byte "out/$n.ts" "$t0")
	rss=$(ps -o rss= -p "$auth" | tr -d ' ')
	kill "$sub" 2>/dev/null
	wait "$sub" 2>/dev/null
	auth_stop
	echo "$n,$aff,$chan,$(du -sk "$kd" | cut -f1),$mint_s,$start,$rss,${fb:-},$([ -n "$fb" ] && echo ok || echo NO_MEDIA)" >>summary.csv
	rm -f "out/$n.ts"
	[ "$n" = 9000 ] || rm -rf "$kd"
}

rung 10
tail -1 summary.csv | grep -q ',ok$' || {
	echo "CONTROL REFUSED: a minted key did not admit a session; the ladder would measure nothing" | tee arms.txt
	kill "${pubs[@]}" "$edge" "$origin" 2>/dev/null
	exit 1
}
for n in "${SIZES[@]}"; do
	[ "$n" = 10 ] || rung "$n"
done
[ -d kd9000 ] || rung 9000

kd=$OUT/kd9000
: >arms.txt
# Provision: a key written while both processes serve admits a new session; no restart.
publish
auth_start "$kd"
pids0="$edge $auth"
"$M" auth generate --id provisioned --out "$kd/provisioned.jwk" 2>>logs/sign.log
sign "$kd/provisioned.jwk" --subscribe ch000 >tok-prov.jwt
t0=$(now)
subscribe tok-prov.jwt ch000 out/prov.ts
fb=$(first_byte out/prov.ts "$t0")
kill "$sub" 2>/dev/null
wait "$sub" 2>/dev/null
echo "provision: first byte ${fb:-none} s; edge and auth pids before $pids0, after $edge $auth (alive: $(kill -0 "$edge" "$auth" 2>/dev/null && echo yes || echo no))" >>arms.txt
auth_stop

# Withdraw: delete the key under a live subscription; time from deletion to the last payload byte.
withdraw() { # <label> [serve flags...]
	local label=$1 t_del last_t s prev out
	shift
	publish
	auth_start "$kd" "$@"
	"$M" auth generate --id "wd-$label" --out "$kd/wd-$label.jwk" 2>>logs/sign.log
	sign "$kd/wd-$label.jwk" --subscribe ch000 >"tok-wd-$label.jwt"
	out=out/wd-$label.ts
	subscribe "tok-wd-$label.jwt" ch000 "$out"
	for _ in $(seq 1 200); do [ "$(size "$out")" -gt 200000 ] && break; sleep 0.05; done
	sleep 3
	t_del=$(now)
	rm -f "$kd/wd-$label.jwk"
	[ "$label" = revalidate ] && "$M" auth revalidate --internal-url "http://127.0.0.1:$IPORT" \
		--path 'bc/**' >>"logs/revalidate.log" 2>&1
	prev=$(size "$out")
	last_t=$t_del
	stalled=0
	for _ in $(seq 1 250); do
		sleep 0.1
		s=$(size "$out")
		if [ "$s" -gt "$prev" ]; then
			last_t=$(now)
			prev=$s
			stalled=0
		else
			stalled=$((stalled + 1))
		fi
	done
	if [ "$stalled" -lt 10 ]; then
		echo "withdraw $label: still delivering when observation ended, about 25 s after the deletion" >>arms.txt
	else
		echo "withdraw $label: last payload byte $(python3 -c "import sys;print(f'{float(sys.argv[2])-float(sys.argv[1]):.2f}')" "$t_del" "$last_t") s after the deletion (polled every 0.1 s); subscriber $(kill -0 "$sub" 2>/dev/null && echo still running || echo ended)" >>arms.txt
	fi
	kill "$sub" 2>/dev/null
	wait "$sub" 2>/dev/null
	auth_stop
}
withdraw none
withdraw interval --revalidate 5s --expires 1h
withdraw revalidate

# Isolation: affiliates holding different subsets on the same edge each receive exactly theirs.
publish
auth_start "$kd"
sign "$kd/aff0000-ch000.jwk" --subscribe ch000 >tok-x.jwt
sign "$kd/aff0001-ch001.jwk" --subscribe ch001 >tok-y.jwt
sign "$kd/aff0002-ch000.jwk" --subscribe ch000 --subscribe ch001 >tok-z.jwt
for a in x y z; do
	for ch in ch000 ch001; do
		subscribe "tok-$a.jwt" "$ch" "out/iso-$a-$ch.ts"
		sleep 8
		kill "$sub" 2>/dev/null
		wait "$sub" 2>/dev/null
		echo "isolation $a $ch: $(size "out/iso-$a-$ch.ts") bytes" >>arms.txt
	done
done
auth_stop

kill "${pubs[@]}" "$edge" "$origin" 2>/dev/null
pkill -P $$ tsp 2>/dev/null
wait 2>/dev/null
rm -rf "$kd" out/*.ts
column -s, -t summary.csv
cat arms.txt
