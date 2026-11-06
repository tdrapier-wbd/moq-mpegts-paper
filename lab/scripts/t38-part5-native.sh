#!/opt/homebrew/bin/bash
# T38 Part 5 on upstream's own server: per-certificate rules in `moq auth serve`'s TOML file, in the
# place of t38-part5-mtls.sh's router. Criteria are in the test file; this prints a verdict for each.
# usage: t38-part5-native.sh <out-dir>
#   One relay (--listen-tls-root, the affiliate root) and one `moq auth serve <file>` on loopback;
#   five publishers present tokens; each subscriber is one passthrough export presenting one
#   certificate (a chain for g1, g2 and H+G), graded on payload bytes in an 8 s window. The file is
#   replaced by atomic rename, as an editor or cert-manager does.
# env: MOQ (bin dir: moq, moq-relay), CLIP (~/contrib-10m.ts), OPENSSL (openssl@3),
#      BASE (4950): relay BASE+1, internal BASE+2, auth server BASE+11.
# Writes cells.csv, arms.txt, verdicts.txt and logs/; deletes keys, tokens and captures on exit.
set -u
OUT=$1
MOQ=${MOQ:?bin dir}
M=$MOQ/moq
CLIP=${CLIP:-$HOME/contrib-10m.ts}
OPENSSL=${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}
BASE=${BASE:-4950}
RPORT=$((BASE + 1)) IPORT=$((BASE + 2)) AUTH=$((BASE + 11))
WINDOW=8
TARGETS=(bcast/ch1 bcast/ch1-intl bcast/ch2 bcast/nobody rival/ch1)
mkdir -p "$OUT"/{logs,out,pki,kd,rules} && cd "$OUT" || exit 1
: >arms.txt
: >verdicts.txt
echo "arm,credential,target,bytes,verdict" >cells.csv
exp=$(($(date +%s) + 7200))
size() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; }
verdict() { if [ "$1" -gt 1000000 ]; then echo deliver; elif [ "$1" -eq 0 ]; then echo refuse; else echo partial; fi; }
note() { echo "$*" | tee -a arms.txt; }
grade() { echo "$1 $2: $3" | tee -a verdicts.txt; }
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

# --- the affiliate PKI: a root, an intermediate G under it, and leaves ----------------------------
ca() { # <name> <cn>
	$OPENSSL req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "pki/$1.key" \
		-out "pki/$1.pem" -days 2 -subj "/CN=$2" -addext basicConstraints=critical,CA:TRUE \
		-addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
}
issue() { # <ca> <name> <extensions>
	$OPENSSL req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "pki/$2.key" \
		-out "pki/$2.csr" -subj "/CN=$2" 2>/dev/null
	printf '%b' "$3" >"pki/$2.ext"
	$OPENSSL x509 -req -in "pki/$2.csr" -CA "pki/$1.pem" -CAkey "pki/$1.key" -CAcreateserial \
		-out "pki/$2.pem" -days 2 -extfile "pki/$2.ext" 2>/dev/null
}
leaf() { issue "$1" "$2" "basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:$2\n"; }
fp() { $OPENSSL x509 -in "pki/$1.pem" -outform DER | shasum -a 256 | cut -d' ' -f1; }
ca ca "Affiliate PKI Root"
issue ca group-g "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
for a in a b c f h; do leaf ca "affiliate-$a"; done
for g in g1 g2; do
	leaf group-g "$g"
	cat "pki/$g.pem" pki/group-g.pem >"pki/$g-chain.pem"
done
cat pki/affiliate-h.pem pki/group-g.pem >pki/h-plus-g.pem
cp pki/affiliate-h.key pki/h-plus-g.key
cp pki/g1.key pki/g1-chain.key
cp pki/g2.key pki/g2-chain.key
for n in affiliate-a affiliate-b affiliate-c affiliate-f affiliate-h group-g g1 g2; do
	echo "$n $(fp "$n")" >>fingerprints.txt
done
FP_A=$(fp affiliate-a) FP_B=$(fp affiliate-b) FP_C=$(fp affiliate-c) FP_F=$(fp affiliate-f)
FP_G=$(fp group-g) FP_G2=$(fp g2)

# --- keys: publishers' tokens only; no subscriber holds one -------------------------------------
"$M" auth generate --id pub --out kd/pub.jwk 2>>logs/keys.log
for root in bcast rival; do
	"$M" auth sign --key kd/pub.jwk --root "$root" --publish '**' --expires "$exp" >"pub-$root.jwt"
done

# --- the rules file, replaced by atomic rename --------------------------------------------------
rules() { # <full | no-b | narrow-b | bad>
	local f=rules/auth.toml
	if [ "$1" = bad ]; then
		printf '[mtls.certificates.%s\nsubscribe = ["bcast/ch1/**"\n' "$FP_B" >"$f.tmp"
	else
		{
			printf '[mtls.certificates.%s] # affiliate A\nsubscribe = ["bcast/ch1/**"]\n\n' "$FP_A"
			case $1 in
			full) printf '[mtls.certificates.%s] # affiliate B\nsubscribe = ["bcast/ch1/**", "bcast/ch2/**"]\n\n' "$FP_B" ;;
			narrow-b) printf '[mtls.certificates.%s] # affiliate B, narrowed\nsubscribe = ["bcast/ch1/**"]\n\n' "$FP_B" ;;
			esac
			printf '[mtls.certificates.%s] # affiliate C\nsubscribe = ["bcast/ch2/**"]\n\n' "$FP_C"
			printf '[mtls.certificates.%s] # affiliate F\nsubscribe = ["bcast/ch1-intl/**"]\n\n' "$FP_F"
			printf '[mtls.certificates.%s] # intermediate G: what it issued\nsubscribe = ["bcast/ch2/**"]\n\n' "$FP_G"
			printf '[mtls.certificates.%s] # g2 under G, revoked\npublish = []\nsubscribe = []\n' "$FP_G2"
		} >"$f.tmp"
	fi
	mv "$f.tmp" "$f"
}

# --- processes ----------------------------------------------------------------------------------
cat >relay.toml <<EOF
[log]
level = "info"

[listen]
bind = "127.0.0.1:$RPORT"
tls.generate = ["localhost"]
EOF
relay="" auth=""
rules full
"$M" auth serve --listen "127.0.0.1:$AUTH" --key-dir kd --revalidate 2s --expires 1h rules/auth.toml \
	>>logs/auth.log 2>&1 &
auth=$!
wait_port "$AUTH" || {
	note "auth server did not listen: $(tail -1 logs/auth.log | cut -c1-200); stopping"
	exit 1
}
"$MOQ/moq-relay" relay.toml --quic-gso=false --internal-listen "127.0.0.1:$IPORT" \
	--listen-tls-root pki/ca.pem --auth-url "http://127.0.0.1:$AUTH" >>logs/relay.log 2>&1 &
relay=$!
sleep 2
kill -0 "$relay" 2>/dev/null || {
	note "the relay did not start; stopping"
	exit 1
}
pubs=()
publish() { # (re)start the five publishers; every arm is shorter than the clip
	local t root name
	pkill -P $$ tsp 2>/dev/null
	stop_pids ${pubs[@]+"${pubs[@]}"}
	pubs=()
	for t in "${TARGETS[@]}"; do
		root=${t%%/*} name=${t#*/}
		tsp -I file "$CLIP" -P regulate --pcr-synchronous -O file - 2>/dev/null |
			"$M" --connect-tls-insecure --quic-gso=false \
				--connect "moqt://127.0.0.1:$RPORT/$root?jwt=$(cat "pub-$root.jwt")" \
				--broadcast "$name" import ts --passthrough >>"logs/pub-$root-$name.log" 2>&1 &
		pubs+=($!)
	done
	sleep 4
}
sub_pids=()
subscribe() { # <capture> <target> <certificate file stem in pki/>
	"$M" --connect-tls-insecure --quic-gso=false --connect-tls-cert "pki/$3.pem" --connect-tls-key "pki/$3.key" \
		--connect "moqt://127.0.0.1:$RPORT/${2%%/*}" --broadcast "${2#*/}" export ts --passthrough \
		>"$1" 2>>"logs/sub-$(basename "$1" .ts).log" &
	sub_pids+=($!)
}
reap() {
	stop_pids ${sub_pids[@]+"${sub_pids[@]}"}
	sub_pids=()
}
batch() { # <arm> <"label|target|stem" ...>: concurrently, one window
	local arm=$1 x label t stem caps=()
	shift
	for x in "$@"; do
		IFS='|' read -r label t stem <<<"$x"
		subscribe "out/$arm-$label-${t/\//_}.ts" "$t" "$stem"
		caps+=("$label|$t|out/$arm-$label-${t/\//_}.ts")
	done
	sleep "$WINDOW"
	reap
	for x in "${caps[@]}"; do
		IFS='|' read -r label t cap <<<"$x"
		b=$(size "$cap")
		echo "$arm,$label,$t,$b,$(verdict "$b")" >>cells.csv
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
expect() { # <arm> <label> <target> <deliver|refuse>: 0 if the cell's verdict is the expected one
	grep -q "^$1,$2,$3,[0-9]*,$4\$" cells.csv
}
le() { python3 -c "import sys; sys.exit(not float(sys.argv[1]) <= float(sys.argv[2]))" "$1" "$2"; }
cleanup() {
	reap
	pkill -P $$ tsp 2>/dev/null
	stop_pids ${pubs[@]+"${pubs[@]}"}
	[ -n "$relay" ] && stop_pids "$relay"
	[ -n "$auth" ] && stop_pids "$auth"
	rm -rf kd pki/*.key ./*.jwt out/*.ts
	sed -E -i '' 's/eyJ[A-Za-z0-9._-]+/<T>/g; s/jwt=[^ "&]+/jwt=<T>/g' logs/* 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- criteria 1 and 2: the matrix, then the chain cells -----------------------------------------
publish
cells=()
for a in a b c f; do for t in "${TARGETS[@]}"; do cells+=("$a|$t|affiliate-$a"); done; done
batch matrix "${cells[@]}"
cells=()
for t in "${TARGETS[@]}"; do cells+=("g1|$t|g1-chain" "g2|$t|g2-chain"); done
cells+=("h|bcast/ch2|affiliate-h" "h-plus-g|bcast/ch2|h-plus-g")
batch chain "${cells[@]}"

ok=1
declare -A licensed=([a]="bcast/ch1" [b]="bcast/ch1 bcast/ch2" [c]="bcast/ch2" [f]="bcast/ch1-intl")
for a in a b c f; do
	for t in "${TARGETS[@]}"; do
		want=refuse
		[[ " ${licensed[$a]} " == *" $t "* ]] && want=deliver
		expect matrix "$a" "$t" "$want" || { ok=0; note "criterion 1: $a on $t is not $want"; }
	done
done
grade 1 "the matrix holds through the file" "$([ $ok = 1 ] && echo PASS || echo FAIL)"
ok=1
for t in "${TARGETS[@]}"; do
	want=refuse
	[ "$t" = bcast/ch2 ] && want=deliver
	expect chain g1 "$t" "$want" || { ok=0; note "criterion 2: g1 on $t is not $want"; }
	expect chain g2 "$t" refuse || { ok=0; note "criterion 2: g2 on $t is not refused"; }
done
for h in h h-plus-g; do expect chain "$h" bcast/ch2 refuse || { ok=0; note "criterion 2: $h on bcast/ch2 is not refused"; }; done
grade 2 "a chain scopes, and a presented certificate claims nothing" "$([ $ok = 1 ] && echo PASS || echo FAIL)"

# --- criterion 3: withdrawing B's rule --------------------------------------------------------------
publish
subscribe out/wd-a-ch1.ts bcast/ch1 affiliate-a
subscribe out/wd-b-ch1.ts bcast/ch1 affiliate-b
subscribe out/wd-b-ch2.ts bcast/ch2 affiliate-b
until_bytes out/wd-b-ch2.ts
sleep 3
t_w=$EPOCHREALTIME
rules no-b
mapfile -t w < <(watch 15 "$t_w" a-ch1=out/wd-a-ch1.ts b-ch1=out/wd-b-ch1.ts b-ch2=out/wd-b-ch2.ts)
for x in "${w[@]}"; do note "withdraw B, last growth after the rename (s): $x"; done
cc_a=$(cc out/wd-a-ch1.ts)
note "withdraw B: A ch1 continuity errors $cc_a"
reap
read -r _ s_a <<<"${w[0]}"
read -r _ s_b1 <<<"${w[1]}"
read -r _ s_b2 <<<"${w[2]}"
grade 3 "withdrawal by edit" "$(le "$s_b1" 3 && le "$s_b2" 3 && le 14 "$s_a" && [ "$cc_a" = 0 ] && echo PASS || echo FAIL)"

# --- criteria 4 and 5: narrowing B, then a file that does not parse -------------------------------
rules full
sleep 3
publish
subscribe out/nw-b-ch1.ts bcast/ch1 affiliate-b
subscribe out/nw-b-ch2.ts bcast/ch2 affiliate-b
until_bytes out/nw-b-ch2.ts
sleep 3
t_n=$EPOCHREALTIME
rules narrow-b
mapfile -t w < <(watch 15 "$t_n" b-ch1=out/nw-b-ch1.ts b-ch2=out/nw-b-ch2.ts)
for x in "${w[@]}"; do note "narrow B to ch1, last growth after the rename (s): $x"; done
read -r _ s_b1 <<<"${w[0]}"
read -r _ s_b2 <<<"${w[1]}"
t_x=$EPOCHREALTIME
rules bad
mapfile -t w < <(watch 10 "$t_x" b-ch1=out/nw-b-ch1.ts)
note "bad edit, B ch1 last growth after the rename (s): ${w[0]#* }"
cc_b=$(cc out/nw-b-ch1.ts)
note "narrow and bad edit: B ch1 continuity errors $cc_b"
reap
kept=$(grep -c 'keeping the last valid policy' logs/auth.log)
note "bad edit: the server logged keeping the last valid policy $kept time(s): $(grep 'keeping the last valid policy' logs/auth.log | tail -1 | sed -E 's/^.*(keeping)/\1/' | cut -c1-200)"
grade 4 "narrowing by edit" "$(le "$s_b2" 3 && le 14 "$s_b1" && [ "$cc_b" = 0 ] && echo PASS || echo FAIL)"
grade 5 "a bad edit changes nothing" "$(le 9.5 "${w[0]#* }" && [ "$kept" -ge 1 ] && echo PASS || echo FAIL)"
echo "done"
