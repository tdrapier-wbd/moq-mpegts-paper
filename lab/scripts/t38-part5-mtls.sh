#!/opt/homebrew/bin/bash
# T38 Part 5 on the redesigned relay: a certificate as a fact, the matrix through a per-certificate
# router, withdrawal, narrowing, rotation and key handling. Criteria are in the test file.
# usage: t38-part5-mtls.sh <out-dir>
#   One relay (--listen-tls-root, the affiliate CA) on loopback; five publishers present tokens;
#   each subscriber is one passthrough export presenting one affiliate certificate, graded on
#   payload bytes in an 8 s window. Arms 2 and 3 ask `moq auth serve` directly; arms 4 to 6 ask
#   t38-cert-router.py, which forwards by certificate fingerprint to one `moq auth serve` per
#   affiliate.
# env: MOQ (bin dir: moq, moq-relay), CLIP (~/contrib-10m.ts), OPENSSL (openssl@3),
#      BASE (4910): relay BASE+1, internal BASE+2, router BASE+10, auth servers BASE+11 to +31.
# Certificate rules are subtrees (`bcast/ch1/**`): `moq auth serve` refuses an exact one.
# Writes cells.csv, arms.txt, router.jsonl and logs/; deletes keys, tokens and captures on exit.
set -u
OUT=$1
MOQ=${MOQ:?bin dir}
M=$MOQ/moq
CLIP=${CLIP:-$HOME/contrib-10m.ts}
OPENSSL=${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}
BASE=${BASE:-4910}
RPORT=$((BASE + 1)) IPORT=$((BASE + 2)) ROUTER=$((BASE + 10))
T_ALONE=$((BASE + 11)) T_REF=$((BASE + 12)) T_TOK=$((BASE + 13))
A_A=$((BASE + 21)) A_B=$((BASE + 22)) A_C=$((BASE + 23)) A_F=$((BASE + 24)) A_BN=$((BASE + 25))
T_ROT=$((BASE + 31))
HERE=$(cd "$(dirname "$0")" && pwd)
WINDOW=8
TARGETS=(bcast/ch1 bcast/ch1-intl bcast/ch2 bcast/nobody rival/ch1)
mkdir -p "$OUT"/{logs,out,pki,kd,kr,priv} && cd "$OUT" || exit 1
: >arms.txt
: >router.jsonl
echo "arm,credential,target,bytes,verdict" >cells.csv
exp=$(($(date +%s) + 7200))
size() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; }
verdict() { if [ "$1" -gt 1000000 ]; then echo deliver; elif [ "$1" -eq 0 ]; then echo refuse; else echo partial; fi; }
note() { echo "$*" | tee -a arms.txt; }
cc() { tsp -I file "$1" -P continuity -O drop 2>&1 | grep -c 'missing [0-9]* packets'; }
stop_pids() { # <pid ...>: SIGINT, which the moq CLI stops on; SIGKILL what is left after 3 s
	[ $# -gt 0 ] || return 0
	kill -INT "$@" 2>/dev/null
	for _ in $(seq 1 30); do
		kill -0 "$@" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$@" 2>/dev/null
	wait "$@" 2>/dev/null
}
wait_port() { for _ in $(seq 1 100); do (echo >"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.05; done; return 1; }

# --- the affiliate PKI, and a second CA the relay does not trust --------------------------------
ca() { # <name> <cn>
	$OPENSSL req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "pki/$1.key" \
		-out "pki/$1.pem" -days 2 -subj "/CN=$2" -addext basicConstraints=critical,CA:TRUE \
		-addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
}
leaf() { # <ca> <name>
	$OPENSSL req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "pki/$2.key" \
		-out "pki/$2.csr" -subj "/CN=$2" 2>/dev/null
	printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:%s\n' \
		"$2" >"pki/$2.ext"
	$OPENSSL x509 -req -in "pki/$2.csr" -CA "pki/$1.pem" -CAkey "pki/$1.key" -CAcreateserial \
		-out "pki/$2.pem" -days 2 -extfile "pki/$2.ext" 2>/dev/null
}
fp() { $OPENSSL x509 -in "pki/$1.pem" -outform DER | shasum -a 256 | cut -d' ' -f1; }
ca ca "Affiliate PKI Root"
ca other "Another PKI Root"
for a in a b c f; do leaf ca "affiliate-$a"; done
leaf other intruder
for a in a b c f intruder; do
	n=$a
	[ "$a" = intruder ] || n=affiliate-$a
	echo "$n $(fp "$n")" >>fingerprints.txt
done
FP_A=$(fp affiliate-a) FP_B=$(fp affiliate-b) FP_C=$(fp affiliate-c) FP_F=$(fp affiliate-f)

# --- keys: HS256 for arms 2 to 5; ES256, public halves only in kr/, for arm 6 ----------------------
"$M" auth generate --id pub --out kd/pub.jwk 2>>logs/keys.log
"$M" auth generate --id sub --out kd/sub.jwk 2>>logs/keys.log
for root in bcast rival; do
	"$M" auth sign --key kd/pub.jwk --root "$root" --publish '**' --expires "$exp" >"pub-$root.jwt"
done
"$M" auth sign --key kd/sub.jwk --root bcast --subscribe ch1 --expires "$exp" >sub-ch1.jwt
for k in pub6 k1 k2; do
	"$M" auth generate --algorithm ES256 --id "$k" --out "priv/$k.jwk" --public-dir kr 2>>logs/keys.log
done
for root in bcast rival; do
	"$M" auth sign --key priv/pub6.jwk --root "$root" --publish '**' --expires "$exp" >"pub6-$root.jwt"
done
"$M" auth sign --key priv/k1.jwk --root bcast --subscribe ch1 --expires "$exp" >k1.jwt
"$M" auth sign --key priv/k2.jwk --root bcast --subscribe ch1 --expires "$exp" >k2.jwt

# --- processes --------------------------------------------------------------------------------
cat >relay.toml <<EOF
[log]
level = "info"

[listen]
bind = "127.0.0.1:$RPORT"
tls.generate = ["localhost"]
EOF
relay=""
relay_start() { # [flags...]: 0 if the relay is still running 2 s later
	"$MOQ/moq-relay" relay.toml --quic-gso=false --internal-listen "127.0.0.1:$IPORT" "$@" >>logs/relay.log 2>&1 &
	relay=$!
	sleep 2
	kill -0 "$relay" 2>/dev/null
}
relay_stop() {
	[ -n "$relay" ] && stop_pids "$relay"
	relay=""
	sleep 0.5
}
auths=()
serve() { # <port> [serve flags...]
	local p=$1
	shift
	"$M" auth serve --listen "127.0.0.1:$p" "$@" >>"logs/auth-$p.log" 2>&1 &
	auths+=($!)
	wait_port "$p" || {
		note "auth server on $p did not listen: $(tail -1 "logs/auth-$p.log" | cut -c1-200); stopping"
		exit 1
	}
}
auth_stop() {
	stop_pids ${auths[@]+"${auths[@]}"}
	auths=()
}
table() { # <token backend> [fingerprint=port ...]
	python3 - "$@" >table.json.tmp <<'PY'
import json, sys
t = {"token": int(sys.argv[1]), "certs": {}}
for kv in sys.argv[2:]:
    k, v = kv.split("=")
    t["certs"][k] = int(v)
print(json.dumps(t))
PY
	mv table.json.tmp table.json
}
pubs=()
publish() { # <token prefix>: (re)start the five publishers; every arm is shorter than the clip
	local t root name
	pkill -P $$ tsp 2>/dev/null
	stop_pids ${pubs[@]+"${pubs[@]}"}
	pubs=()
	for t in "${TARGETS[@]}"; do
		root=${t%%/*} name=${t#*/}
		tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
			"$M" --connect-tls-insecure --quic-gso=false \
				--connect "moqt://127.0.0.1:$RPORT/$root?jwt=$(cat "$1-$root.jwt")" \
				--broadcast "$name" import ts --passthrough >>"logs/pub-$root-$name.log" 2>&1 &
		pubs+=($!)
	done
	sleep 4
}
sub="" sub_pids=()
subscribe() { # <capture> <target> <cert:NAME | jwt:FILE | both:NAME,FILE>
	local cap=$1 target=$2 cred=$3 url args=() c j
	url="moqt://127.0.0.1:$RPORT/${target%%/*}"
	case $cred in
	cert:*) c=${cred#cert:} ;;
	jwt:*) j=${cred#jwt:} ;;
	both:*)
		c=${cred#both:}
		j=${c#*,}
		c=${c%%,*}
		;;
	esac
	[ -n "${c:-}" ] && args=(--connect-tls-cert "pki/$c.pem" --connect-tls-key "pki/$c.key")
	[ -n "${j:-}" ] && url="$url?jwt=$(cat "$j")"
	"$M" --connect-tls-insecure --quic-gso=false ${args[@]+"${args[@]}"} --connect "$url" \
		--broadcast "${target#*/}" export ts --passthrough >"$cap" 2>>"logs/sub-$(basename "$cap" .ts).log" &
	sub=$!
	sub_pids+=("$sub")
}
reap() {
	stop_pids ${sub_pids[@]+"${sub_pids[@]}"}
	sub_pids=()
}
cell() { # <arm> <credential label> <target> <capture>
	local b
	b=$(size "$4")
	echo "$1,$2,$3,$b,$(verdict "$b")" >>cells.csv
}
matrix() { # <arm> [extra "label|target|cred" ...]: the twenty certificate cells, concurrently
	local arm=$1 a t x caps=()
	shift
	for a in a b c f; do
		for t in "${TARGETS[@]}"; do
			subscribe "out/$arm-$a-${t/\//_}.ts" "$t" "cert:affiliate-$a"
			caps+=("affiliate-$a|$t|out/$arm-$a-${t/\//_}.ts")
		done
	done
	for x in "$@"; do
		IFS='|' read -r label t cred <<<"$x"
		subscribe "out/$arm-$label.ts" "$t" "$cred"
		caps+=("$label|$t|out/$arm-$label.ts")
	done
	sleep "$WINDOW"
	reap
	for x in "${caps[@]}"; do
		IFS='|' read -r label t cap <<<"$x"
		cell "$arm" "$label" "$t" "$cap"
	done
}
# watch <seconds> <t0> <label=capture ...>: seconds from t0 to each capture's last growth
watch() {
	local secs=$1 t0=$2 kv s i
	shift 2
	declare -A prev last
	for kv in "$@"; do
		prev[$kv]=$(size "${kv#*=}")
		last[$kv]=$t0
	done
	for ((i = 0; i < secs * 10; i++)); do
		sleep 0.1
		for kv in "$@"; do
			s=$(size "${kv#*=}")
			if [ "$s" -gt "${prev[$kv]}" ]; then
				prev[$kv]=$s
				last[$kv]=$EPOCHREALTIME
			fi
		done
	done
	for kv in "$@"; do
		echo "${kv%%=*} $(python3 -c "import sys;print(f'{float(sys.argv[2])-float(sys.argv[1]):.2f}')" "$t0" "${last[$kv]}")"
	done
}
until_bytes() { for _ in $(seq 1 200); do [ "$(size "$1")" -gt 300000 ] && return; sleep 0.05; done; }
cleanup() {
	reap
	pkill -P $$ tsp 2>/dev/null
	stop_pids ${pubs[@]+"${pubs[@]}"}
	relay_stop
	auth_stop
	[ -n "${router:-}" ] && stop_pids "$router"
	rm -rf priv kd kr pki/*.key ./*.jwt out/*.ts
	sed -E -i '' 's/eyJ[A-Za-z0-9._-]+/<T>/g; s/jwt=[^ "&]+/jwt=<T>/g' logs/* 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- arm 1: start-up refusals -----------------------------------------------------------------
for variant in public none; do
	extra=()
	[ "$variant" = public ] && extra=(--auth-public '**')
	if relay_start --listen-tls-root pki/ca.pem ${extra[@]+"${extra[@]}"}; then
		note "arm 1, CA with $variant auth: STARTED (fails criterion 1)"
		relay_stop
	else
		wait "$relay" 2>/dev/null
		note "arm 1, CA with $variant auth: refused to start, exit $?; $(grep -i -E 'error|refus' logs/relay.log | tail -1 | cut -c1-260)"
		relay=""
	fi
done

# --- arm 2: a certificate alone, `moq auth serve` with keys and no certificate rule --------------
serve "$T_ALONE" --key-dir kd
relay_start --listen-tls-root pki/ca.pem --auth-url "http://127.0.0.1:$T_ALONE" ||
	{ note "arm 2: the relay did not start; stopping"; exit 1; }
publish pub
matrix alone "token-sub-ch1|bcast/ch1|jwt:sub-ch1.jwt"
relay_stop
auth_stop

# --- arm 3, reported: the reference server's single certificate rule -----------------------------
serve "$T_REF" --key-dir kd --mtls-subscribe 'bcast/ch1/**'
relay_start --listen-tls-root pki/ca.pem --auth-url "http://127.0.0.1:$T_REF" ||
	{ note "arm 3: the relay did not start; stopping"; exit 1; }
publish pub
matrix reference
relay_stop
auth_stop

# --- arm 4: the matrix through the router; another CA; a certificate with a token -----------------
rv=(--revalidate 2s --expires 1h)
serve "$T_TOK" --key-dir kd "${rv[@]}"
serve "$A_A" --mtls-subscribe 'bcast/ch1/**' "${rv[@]}"
serve "$A_B" --mtls-subscribe 'bcast/ch1/**' --mtls-subscribe 'bcast/ch2/**' "${rv[@]}"
serve "$A_C" --mtls-subscribe 'bcast/ch2/**' "${rv[@]}"
serve "$A_F" --mtls-subscribe 'bcast/ch1-intl/**' "${rv[@]}"
serve "$A_BN" --mtls-subscribe 'bcast/ch1/**' "${rv[@]}"
table "$T_TOK" "$FP_A=$A_A" "$FP_B=$A_B" "$FP_C=$A_C" "$FP_F=$A_F"
python3 "$HERE/t38-cert-router.py" "$ROUTER" table.json router.jsonl >>logs/router.log 2>&1 &
router=$!
wait_port "$ROUTER" || note "router did not listen"
relay_start --listen-tls-root pki/ca.pem --auth-url "http://127.0.0.1:$ROUTER" ||
	{ note "arm 4: the relay did not start; stopping"; exit 1; }
publish pub
matrix router "intruder|bcast/ch1|cert:intruder" "a-with-token|bcast/ch1|both:affiliate-a,sub-ch1.jwt"
note "arm 4, router requests carrying a certificate: $(grep -c '"tls_fp": "' router.jsonl); naming the intruder: $(grep -c intruder router.jsonl)"

# --- arm 5: withdrawing B's certificate; then narrowing B under the same certificate --------------
publish pub
subscribe out/wd-a-ch1.ts bcast/ch1 cert:affiliate-a
subscribe out/wd-b-ch1.ts bcast/ch1 cert:affiliate-b
subscribe out/wd-b-ch2.ts bcast/ch2 cert:affiliate-b
until_bytes out/wd-b-ch2.ts
sleep 3
t_w=$EPOCHREALTIME
table "$T_TOK" "$FP_A=$A_A" "$FP_C=$A_C" "$FP_F=$A_F"
watch 15 "$t_w" a-ch1=out/wd-a-ch1.ts b-ch1=out/wd-b-ch1.ts b-ch2=out/wd-b-ch2.ts |
	sed 's/^/arm 5, withdraw B, last growth after the withdrawal (s): /' | tee -a arms.txt
note "arm 5, withdraw: A ch1 continuity errors $(cc out/wd-a-ch1.ts); B subscribers alive: $(for p in "${sub_pids[@]:1}"; do kill -0 "$p" 2>/dev/null && echo -n 'yes ' || echo -n 'no '; done)"
reap
table "$T_TOK" "$FP_A=$A_A" "$FP_B=$A_B" "$FP_C=$A_C" "$FP_F=$A_F"
publish pub
subscribe out/nw-b-ch1.ts bcast/ch1 cert:affiliate-b
subscribe out/nw-b-ch2.ts bcast/ch2 cert:affiliate-b
until_bytes out/nw-b-ch2.ts
sleep 3
t_n=$EPOCHREALTIME
table "$T_TOK" "$FP_A=$A_A" "$FP_B=$A_BN" "$FP_C=$A_C" "$FP_F=$A_F"
watch 15 "$t_n" b-ch1=out/nw-b-ch1.ts b-ch2=out/nw-b-ch2.ts |
	sed 's/^/arm 5, narrow B to ch1, last growth after the narrowing (s): /' | tee -a arms.txt
note "arm 5, narrow: B ch1 continuity errors $(cc out/nw-b-ch1.ts)"
reap

# --- arm 6: rotation on ES256 keys whose public halves alone are served; key handling ------------
serve "$T_ROT" --key-dir kr "${rv[@]}"
table "$T_ROT"
publish pub6
subscribe out/rot-k1.ts bcast/ch1 jwt:k1.jwt
subscribe out/rot-k2.ts bcast/ch1 jwt:k2.jwt
until_bytes out/rot-k1.ts
until_bytes out/rot-k2.ts
sleep 3
t_d=$EPOCHREALTIME
rm -f kr/k1.jwk
watch 15 "$t_d" k1=out/rot-k1.ts k2=out/rot-k2.ts |
	sed 's/^/arm 6, delete k1, last growth after the deletion (s): /' | tee -a arms.txt
note "arm 6: k2 continuity errors $(cc out/rot-k2.ts)"
reap
subscribe out/rot-k1-new.ts bcast/ch1 jwt:k1.jwt
sleep "$WINDOW"
reap
cell rotation k1-after-deletion bcast/ch1 out/rot-k1-new.ts
note "arm 6: a new session on k1's token after the deletion: $(size out/rot-k1-new.ts) bytes"
note "arm 6, key handling: $(python3 - kr <<'PY'
import base64, json, os, sys
d = sys.argv[1]
n = priv = 0
algs = set()
for f in sorted(os.listdir(d)):
    raw = open(os.path.join(d, f)).read().strip()
    try:
        jwk = json.loads(raw)
    except ValueError:
        jwk = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    n += 1
    priv += "d" in jwk
    algs.add(jwk.get("alg"))
print(f"{n} keys served, {priv} with a private scalar; algorithms {sorted(algs)}")
PY
)"
note "arm 6, the relay's arguments: $(ps -o args= -p "$relay" | sed -E "s#$OUT/?##g")"
echo "done"
