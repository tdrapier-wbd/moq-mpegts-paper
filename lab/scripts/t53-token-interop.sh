#!/bin/bash
# T53: one entitlement estate in front of moq-relay and moqx, on loopback
# (lab/test-53-token-interop.md).
#
# Usage: t53-token-interop.sh setup | config | start | stop | part-a | part-b | part-c
#   MOQ=<moq and moq-relay from main, a dir>  M6=<moq from #6177's branch, a dir>
#   MOQX=<moqx release dir: bin/moqx, bin/moqx-issuer>  OMP=<openmoq-publisher>
#   FIXTURE=<the synthetic TS fixture, made with DURATION=1200: `moq import ts` exits when a
#            looped file's timestamps wrap, so a part must finish within one pass>
#   CLIP=<an MP4, for openmoq-publisher>
# Keys, secrets and tokens live in $W (mode 700) and are never printed. Each arm appends one
# line to $W/results.tsv: arm, draft, relay, payload bytes at the receiver, client exit, the
# client's last error line.
#
# moqx serves five paths: /t0 and /t16 need a setup token of Token Type 0 or 16; /pg needs a
# CAT to publish and lets anyone subscribe (the receiver that counts a publisher arm's bytes);
# /h4 grants by anonymous_claim alone, publish under [bcast] and subscribe under [bcast, ch1],
# so its namespace matcher is measured with ordinary moq subscribers. moq opens with a
# root-wide SUBSCRIBE_NAMESPACE, so /h4 lets anyone subscribe to namespaces; /h4n scopes that
# to [bcast, ch1] as well.
set -euo pipefail
W=${W:-/tmp/t53}
MOQ=${MOQ:?dir holding moq and moq-relay from main}
M6=${M6:?dir holding moq from #6177}
MOQX=${MOQX:?moqx release dir}
OMP=${OMP:?openmoq-publisher}
FIXTURE=${FIXTURE:-$W/fixture.ts}
CLIP=${CLIP:-$W/clip.mp4}
DUR=${DUR:-8}
# once <bin dir>: the flags for one dial attempt with that build. Before #6529 that is --connect-once.
# Since, CLI dials always reconnect: a 1 ms retry budget starts no second walk of the one address, and
# the 1 s first retry delay outlasts it after a session ends.
once() { case "$("$1/moq" --help 2>&1)" in *--connect-once*) echo --connect-once ;; *) echo --connect-backoff-timeout 1ms ;; esac; }
read -r -a ONCE <<<"$(once "$M6")"
read -r -a ONCE_MOQ <<<"$(once "$MOQ")"
P_RELAY=15443 P_AUTH=15440 P_MOQX=15433 P_ADMIN=15480
RU=moqt://127.0.0.1:$P_RELAY
XU=moqt://127.0.0.1:$P_MOQX
ISSUE=("$MOQX/bin/moqx-issuer" --config "$W/moqx.yaml" --auth_service t16)
cd "$W" 2>/dev/null || true

now() { date +%s; }
size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
lasterr() { grep -a -i -E "error|refus|denied|unauth|forbid|closed|reset" "$1" 2>/dev/null | tail -1 | tr '\t' ' ' | cut -c1-160; }
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$W/results.tsv"; echo "  $1 d$2 $3: bytes=$4 exit=$5"; }
startbg() { # startbg <name> <cmd...>: in its own session, so it outlives the shell that started it
	local n=$1; shift
	nohup python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" \
		> "$W/logs/bg-$n.log" 2>&1 &
	echo $! > "$W/pids/$n"
}
stopbg() { local f="$W/pids/$1"; [ -f "$f" ] || return 0; pkill -INT -P "$(cat "$f")" 2>/dev/null || true; kill -INT "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; }
waitport() { for _ in $(seq 50); do lsof -nP -i"$1":"$2" >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "port $1:$2 not up" >&2; return 1; }

cat_tok() { # cat_tok <out> <key id> <actions> <namespace> [ttl]: raw CWT bytes; base64 text beside it
	"${ISSUE[@]}" --auth_key_id "$2" --auth_actions "$3" --auth_namespace "$4" \
		--auth_ttl_seconds "${5:-7200}" --auth_output raw > "cat/$1.cwt"
	"${ISSUE[@]}" --auth_key_id "$2" --auth_actions "$3" --auth_namespace "$4" \
		--auth_ttl_seconds "${5:-7200}" --auth_output base64 > "cat/$1.b64"
}

moqx_config() { # moqx_config [omit-key-id]
	local omit=${1:-} keys="" id
	for id in bcast rival wd; do
		[ "$id" = "$omit" ] && continue
		keys="$keys{id: $id, secret: \"$(cat "keys/moqx-$id.secret")\"}, "
	done
	keys="[${keys%, }]"
	umask 077
	cat > moqx.yaml <<-EOF
	listeners:
	  - name: main
	    udp: {socket: {address: "127.0.0.1", port: $P_MOQX}}
	    tls: {insecure: true}
	    endpoint: /moq-relay
	    moqt_versions: [16, 18]
	service_defaults:
	  auth: {max_tokens_per_message: 4}
	  cache: {enabled: true, max_tracks: 100, max_groups_per_track: 10}
	services:
	  t0:
	    match: [{authority: {any: true}, path: {prefix: "/t0"}}]
	    auth: {enabled: true, token_type: 0, hmac_keys: $keys, require_setup_token: true}
	  t16:
	    match: [{authority: {any: true}, path: {prefix: "/t16"}}]
	    auth: {enabled: true, token_type: 16, hmac_keys: $keys, require_setup_token: true}
	  pg:
	    match: [{authority: {any: true}, path: {exact: "/pg"}}]
	    auth:
	      enabled: true
	      token_type: 16
	      hmac_keys: $keys
	      require_setup_token: false
	      anonymous_claim:
	        - actions: [subscribe, subscribe_namespace, fetch, track_status]
	  h4:
	    match: [{authority: {any: true}, path: {exact: "/h4"}}]
	    auth:
	      enabled: true
	      hmac_keys: $keys
	      require_setup_token: false
	      anonymous_claim:
	        - actions: [publish_namespace, publish]
	          namespace_match: {prefix: ["bcast"]}
	        - actions: [subscribe_namespace]
	        - actions: [subscribe, fetch, track_status]
	          namespace_match: {prefix: ["bcast", "ch1"]}
	  h4n:
	    match: [{authority: {any: true}, path: {exact: "/h4n"}}]
	    auth:
	      enabled: true
	      hmac_keys: $keys
	      require_setup_token: false
	      anonymous_claim:
	        - actions: [publish_namespace, publish]
	          namespace_match: {prefix: ["bcast"]}
	        - actions: [subscribe, subscribe_namespace, fetch, track_status]
	          namespace_match: {prefix: ["bcast", "ch1"]}
	admin: {address: "127.0.0.1", port: $P_ADMIN, plaintext: true, track_metrics_enabled: true}
	EOF
}

setup() {
	umask 077
	mkdir -p "$W"/{keys,pub,tok,cat,logs,out,pids}
	chmod 700 "$W"
	cd "$W"
	: > results.tsv
	local exp=$(( $(now) + 7200 )) past=$(( $(now) - 60 )) M=$MOQ/moq
	# moq-relay: one ES256 key per broadcaster, scoped to its root; one HS256 key, for the
	# like-for-like arm against moqx's HMAC and for Part C's withdrawal.
	local sc=(--publish '**' --subscribe '**')
	$M auth generate --algorithm ES256 --id bcast --root bcast "${sc[@]}" --out keys/bcast.jwk --public pub/bcast.jwk
	$M auth generate --algorithm ES256 --id rival --root rival "${sc[@]}" --out keys/rival.jwk --public pub/rival.jwk
	$M auth generate --algorithm HS256 --id hs --root bcast "${sc[@]}" --out keys/hs.jwk
	cp keys/hs.jwk pub/hs.jwk
	# moqx: one HMAC secret per broadcaster, and one ("wd") for Part C's withdrawal.
	for id in bcast rival wd; do openssl rand -hex 32 > "keys/moqx-$id.secret"; done
	moqx_config
	"$MOQX/bin/moqx" validate-config --config moqx.yaml

	# The estate, rendered to JWTs as subtree grants (`ch1/**`): on draft 17 and later the relay
	# reports a session's grant in AUTH_OK, which carries prefixes only, and closes a session
	# whose grant is narrower (arm A1x keeps the exact form). Publishers:
	for ch in ch1 ch1-intl ch2 nobody; do
		$M auth sign --key keys/bcast.jwk --root bcast --publish "$ch/**" --expires $exp > "tok/pub-$ch.jwt"
	done
	$M auth sign --key keys/rival.jwk --root rival --publish 'ch1/**' --expires $exp > tok/pub-rival-ch1.jwt
	# Affiliates: A {ch1}, B {ch1, ch2}, C {ch2}; ch1-intl and nobody licensed by nobody.
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'ch1/**' --expires $exp > tok/affa.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'ch1/**' --subscribe 'ch2/**' --expires $exp > tok/affb.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'ch2/**' --expires $exp > tok/affc.jwt
	$M auth sign --key keys/hs.jwk --root bcast --subscribe 'ch1/**' --expires $exp > tok/affa-hs.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe ch1 --expires $exp > tok/affa-exact.jwt
	# Arm credentials.
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'ch1/**' --expires $past > tok/affa-expired.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'a7/**' --expires $exp > tok/subonly-a7.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --publish 'ch1/**' --expires $exp > tok/pubonly.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe '**' --expires $exp > tok/parent.jwt
	$M auth sign --key keys/bcast.jwk --root bcast --publish 'a5/**' --expires $exp > tok/pub-a5.jwt
	# A3k: the rival's key signing a grant under bcast. The CLI refuses a scoped key a broader
	# token, so the scope is stripped from a copy of the private key; the verifier keeps it.
	python3 - keys/rival.jwk > keys/rival-unscoped.jwk <<-'PY'
	import base64, json, sys
	raw = open(sys.argv[1]).read().strip()
	k = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
	k = {f: v for f, v in k.items() if f in ("alg", "crv", "d", "k", "key_ops", "kid", "kty", "x", "y")}
	print(base64.urlsafe_b64encode(json.dumps(k).encode()).decode().rstrip("="))
	PY
	$M auth sign --key keys/rival-unscoped.jwk --root bcast --subscribe 'ch1/**' --expires $exp > tok/rival-for-bcast.jwt 2> logs/a3k-sign.log \
		|| echo "A3k: the CLI would not sign with the unscoped copy (logs/a3k-sign.log)"
	# A6: malformed variants of affa's token.
	local v; v=$(cat tok/affa.jwt)
	printf '%s' "${v:0:${#v}-12}" > tok/mal-truncated.jwt
	printf '%s' "$v" | sed 's/.$/X/' > tok/mal-badsig.jwt
	python3 - "$v" > tok/mal-widened.jwt <<-'PY'
	import base64, json, sys
	h, p, s = sys.argv[1].split(".")
	d = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
	e = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")
	c = json.loads(d(p))
	for k, val in list(c.items()):
	    if val == ["ch1/**"]:
	        c[k] = ["**"]
	sys.stdout.write(f"{h}.{e(json.dumps(c).encode())}.{s}")
	PY
	# openmoq-publisher sends a token file's bytes as they are, newline included.
	tr -d '\n' < tok/pub-a5.jwt > tok/pub-a5.raw

	# The same records, rendered to CATs. moqx-issuer emits exact namespace grants only.
	local pa=client_setup,publish_namespace,publish sa=client_setup,subscribe_namespace,subscribe,fetch,track_status
	cat_tok pub-ch1 bcast $pa bcast/ch1
	cat_tok affa bcast $sa bcast/ch1
	cat_tok affa-expired bcast $pa bcast/ch1 1
	cat_tok subonly-a7 bcast $sa bcast/a7
	cat_tok rival-for-bcast rival $pa bcast/ch1
	cat_tok pub-rival-ch1 rival $pa rival/ch1
	cat_tok wd-ch1 wd $pa bcast/ch1
	cat_tok wd-ch2 wd $pa bcast/ch2
	python3 - <<-'PY'
	raw = open("cat/pub-ch1.cwt", "rb").read()
	open("cat/mal-truncated.cwt", "wb").write(raw[:-12])
	open("cat/mal-badsig.cwt", "wb").write(raw[:-1] + bytes([raw[-1] ^ 0x01]))
	i = raw.find(b"ch1")
	assert i > 0, "namespace bytes not found"
	open("cat/mal-retargeted.cwt", "wb").write(raw[:i] + b"ch2" + raw[i + 3:])
	PY
	echo "setup: keys, JWTs and CATs in $W (not printed); moqx config $W/moqx.yaml"
}

start_moqx() {
	startbg moqx "$MOQX/bin/moqx" --config "$W/moqx.yaml" --logtostderr -v=1
	waitport UDP $P_MOQX
}

start() {
	cd "$W"
	startbg auth "$MOQ/moq" --log-level debug auth serve --listen 127.0.0.1:$P_AUTH --key-dir pub \
		--revalidate 5s --expires 1h
	waitport TCP $P_AUTH
	startbg relay "$MOQ/moq-relay" --listen 127.0.0.1:$P_RELAY --listen-tls-generate localhost \
		--auth-url http://127.0.0.1:$P_AUTH --log-level debug
	waitport UDP $P_RELAY
	start_moqx
	# The fixture on moq-relay, each publisher with its broadcaster's token in the URL.
	local root ch
	for rc in bcast/ch1 bcast/ch1-intl bcast/ch2 bcast/nobody rival/ch1; do
		root=${rc%%/*} ch=${rc#*/}
		local t=tok/pub-$ch.jwt; [ "$root" = rival ] && t=tok/pub-rival-ch1.jwt
		startbg "pub-$root-$ch" bash -c "tsp -I file '$FIXTURE' --infinite -P regulate -O file 2>/dev/null \
			| '$MOQ/moq' --connect-tls-insecure --connect '$RU/$root?jwt=$(cat "$t")' \
			--connect-version moq-transport-18 --broadcast '$ch' import ts"
	done
	h4pubs
	echo "started: auth server, moq-relay, moqx, 5 publishers on moq-relay, 4 on moqx /h4, 1 on /h4n"
}

# The fixture on moqx's /h4 and /h4n, under the anonymous publish floor; ch1/sub is a child of ch1.
h4pubs() {
	local b
	for b in h4/ch1 h4/ch1-intl h4/ch1/sub h4/ch2 h4n/ch1; do
		stopbg "${b//\//_}"
		startbg "${b//\//_}" bash -c "tsp -I file '$FIXTURE' --infinite -P regulate -O file 2>/dev/null \
			| '$MOQ/moq' --connect-tls-insecure --connect '$XU/${b%%/*}' --connect-version moq-transport-18 \
			--broadcast 'bcast/${b#*/}' import ts"
	done
	sleep 3
}

stop() {
	local f
	for f in "$W"/pids/*; do [ -f "$f" ] && stopbg "$(basename "$f")"; done
	sleep 1
	pkill -f "[t]sp -I file $FIXTURE" 2>/dev/null || true
	pkill -f "[m]oqx --config $W/moqx.yaml" 2>/dev/null || true
	echo stopped
}

# sub <arm> <draft> <relay> <bin dir> <url> <broadcast> [token file for SETUP]: export ts for DUR s.
sub() {
	local arm=$1 d=$2 rl=$3 bin=$4 url=$5 bc=$6 tf=${7:-} out="$W/out/$1-$2.ts" log="$W/logs/$1-$2.log" rc=0
	local -a once=("${ONCE[@]}")
	if [ "$bin" = "$MOQ" ]; then once=("${ONCE_MOQ[@]}"); fi
	if [ -n "$tf" ]; then
		MOQ_CONNECT_TOKEN=$(cat "$tf") timeout "$DUR" "$bin/moq" --connect-tls-insecure --connect "$url" \
			--connect-version "moq-transport-$d" "${once[@]}" --broadcast "$bc" export ts > "$out" 2> "$log" || rc=$?
	else
		timeout "$DUR" "$bin/moq" --connect-tls-insecure --connect "$url" --connect-version "moq-transport-$d" \
			"${once[@]}" --broadcast "$bc" export ts > "$out" 2> "$log" || rc=$?
	fi
	record "$arm" "$d" "$rl" "$(size "$out")" "$rc" "$(lasterr "$log")"
}

# xfetch <arm> <draft> <url> <broadcast> [token file for SETUP]: one group of openmoq's video track.
xfetch() {
	local arm=$1 d=$2 url=$3 bc=$4 tf=${5:-} out="$W/out/$1-$2.bin" log="$W/logs/$1-$2.log" rc=0 bin=$M6
	if [ -n "$tf" ]; then
		MOQ_CONNECT_TOKEN=$(cat "$tf") timeout "$DUR" "$bin/moq" --connect-tls-insecure --connect "$url" \
			--connect-version "moq-transport-$d" "${ONCE[@]}" --broadcast "$bc" fetch vide_1 > "$out" 2> "$log" || rc=$?
	else
		timeout "$DUR" "$bin/moq" --connect-tls-insecure --connect "$url" --connect-version "moq-transport-$d" \
			"${ONCE[@]}" --broadcast "$bc" fetch vide_1 > "$out" 2> "$log" || rc=$?
	fi
	record "$arm" "$d" moqx "$(size "$out")" "$rc" "$(lasterr "$log")"
}

# omp <name> <draft> <url path> <namespace> <token type> [token file]: openmoq-publisher, looping.
omp() {
	local n=$1 d=$2 p=$3 ns=$4 tt=$5 tf=${6:-} a=()
	[ -n "$tf" ] && a=(--auth-profile moqx-compat --auth-token-type "$tt" --auth-token-file "$tf")
	startbg "omp-$n-$d" "$OMP" --input "$CLIP" --transport raw --draft "$d" --endpoint "$XU$p" \
		--namespace "$ns" --forward 1 --loop --paced --publish-catalog --insecure "${a[@]}"
	sleep 3
}
omp_stop() { stopbg "omp-$1-$2"; sleep 0.5; }
omp_said() { lasterr "$W/logs/bg-omp-$1-$2.log"; }

# xstate <arm> <draft> <service> <namespace>: moqx's own record of a publisher it admitted,
# for the services where no receiver can present a CAT.
xstate() {
	local f="$W/out/state-$1-$2.json"
	curl -s "http://127.0.0.1:$P_ADMIN/state" > "$f" || true
	local n
	n=$(python3 - "$f" "$3" "$4" <<-'PY'
	import json, sys
	try:
	    s = json.load(open(sys.argv[1]))["services"][sys.argv[2]]
	except Exception:
	    print("state-unreadable"); sys.exit()
	ns = sys.argv[3].split("/")
	subs = [x for x in s["subscriptions"] if x["namespace"] == ns and x.get("is_publish")]
	node = s["namespace_tree"]
	for seg in ns:
	    node = node.get("children", {}).get(seg, {})
	print(f"namespace={'yes' if node.get('publisher') else 'no'} publications={len(subs)}")
	PY
	)
	record "$1" "$2" moqx "$n" - "$(omp_said "$1" "$2")"
}

# pgarm <arm> <draft> <publish namespace> [cat file]: a fresh moqx, openmoq publishing with the
# CAT on /pg, an anonymous receiver on the same namespace.
pgarm() {
	local arm=$1 d=$2 ns=$3 tf=${4:-}
	stopbg moqx; sleep 0.5; start_moqx
	omp "$arm" "$d" /pg "$ns" 16 "$tf"
	xfetch "$arm" "$d" "$XU/pg" "$ns"
	echo "    publisher said: $(omp_said "$arm" "$d")"
	omp_stop "$arm" "$d"
}

part_a() {
	local d
	for d in 16 18; do
		echo "Part A, draft $d"
		sub C1 $d moq-relay "$MOQ" "$RU/bcast?jwt=$(cat tok/affa.jwt)" ch1
		sub C1hs $d moq-relay "$MOQ" "$RU/bcast?jwt=$(cat tok/affa-hs.jwt)" ch1
		sub C2 $d moq-relay "$M6" "$RU/bcast" ch1 tok/affa.jwt
		# moqx's own control in each Token Type: openmoq-publisher with a CAT. No receiver here
		# presents a CAT, so on /t0 and /t16 admission is read from the publisher and moqx's
		# /state; C4pg repeats C4 on /pg, where an anonymous receiver counts the bytes.
		stopbg moqx; sleep 0.5; start_moqx
		omp C4 $d /t16 bcast/ch1 16 cat/pub-ch1.cwt
		omp C4t0 $d /t0 bcast/ch1 0 cat/pub-ch1.cwt
		xstate C4 $d t16 bcast/ch1
		xstate C4t0 $d t0 bcast/ch1
		# C3: the CAT as text (moq holds tokens as strings), Type 0, to /t0, where C4t0 publishes.
		xfetch C3 $d "$XU/t0" bcast/ch1 cat/affa.b64
		xfetch C6 $d "$XU/t0" bcast/ch1 tok/affa.jwt
		xfetch C9 $d "$XU/t0?jwt=$(tr -d '\n' < cat/affa.b64 | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=""))')" bcast/ch1
		xfetch C10 $d "$XU/t16" bcast/ch1 cat/affa.b64
		omp_stop C4 $d; omp_stop C4t0 $d
		pgarm C4pg $d bcast/ch1 cat/pub-ch1.cwt
		sub C7 $d moq-relay "$M6" "$RU/bcast" ch1 cat/affa.b64
		sub C8 $d moq-relay "$MOQ" "$RU/bcast?jwt=$(tr -d '\n' < cat/affa.b64 | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=""))')" ch1
		# C5: a JWT from openmoq-publisher, Type 0, to moq-relay. It pushes every track with
		# PUBLISH, which moq-relay does not take, so admission is read from the namespace
		# reaching a subscriber that holds the parent grant.
		startbg "c5-$d" "$OMP" --input "$CLIP" --transport raw --draft "$d" --endpoint "$RU/bcast" \
			--namespace a5 --forward 0 --loop --paced --publish-catalog --insecure --timeout 20 \
			--auth-profile moqx-compat --auth-token-type 0 --auth-token-file tok/pub-a5.raw
		sleep 1
		MOQ_CONNECT_TOKEN=$(cat tok/parent.jwt) timeout 4 "$M6/moq" --connect-tls-insecure --connect "$RU/bcast" \
			--connect-version "moq-transport-$d" "${ONCE[@]}" announced > "out/C5-$d.txt" 2> "logs/C5-$d.log" || true
		sleep 2
		record C5 $d moq-relay "announced=$(grep -c -w a5 "out/C5-$d.txt")" - "$(lasterr "logs/bg-c5-$d.log")"
		stopbg "c5-$d"
	done
}

part_b() {
	local d a
	for d in 16 18; do
		echo "Part B on moq-relay, draft $d (SETUP, Type 0)"
		sub A1 $d moq-relay "$M6" "$RU/bcast" ch1 tok/affa.jwt
		sub A2 $d moq-relay "$M6" "$RU/bcast" ch2 tok/affa.jwt
		sub A3 $d moq-relay "$M6" "$RU/rival" ch1 tok/affa.jwt
		[ -s tok/rival-for-bcast.jwt ] && sub A3k $d moq-relay "$M6" "$RU/bcast" ch1 tok/rival-for-bcast.jwt
		sub A4 $d moq-relay "$M6" "$RU/bcast" ch1 tok/affa-expired.jwt
		sub A5 $d moq-relay "$M6" "$RU/bcast" ch1
		sub A6a $d moq-relay "$M6" "$RU/bcast" ch1 tok/mal-truncated.jwt
		sub A6b $d moq-relay "$M6" "$RU/bcast" ch1 tok/mal-badsig.jwt
		sub A6c $d moq-relay "$M6" "$RU/bcast" ch1 tok/mal-widened.jwt
		# A7: the subscribe-only grant for a7 publishing to a7; the parent grant receives.
		startbg "a7-$d" bash -c "tsp -I file '$FIXTURE' --infinite -P regulate -O file 2>/dev/null \
			| MOQ_CONNECT_TOKEN='$(cat tok/subonly-a7.jwt)' '$M6/moq' --connect-tls-insecure --connect '$RU/bcast' \
			--connect-version moq-transport-$d ${ONCE[*]} --broadcast a7 import ts"
		sleep 2
		sub A7 $d moq-relay "$M6" "$RU/bcast" a7 tok/parent.jwt
		echo "    A7 publisher said: $(lasterr "logs/bg-a7-$d.log")"
		stopbg "a7-$d"
		sub A8 $d moq-relay "$M6" "$RU/bcast" ch1 tok/pubonly.jwt
		sub A9 $d moq-relay "$M6" "$RU/bcast" ch1-intl tok/affa.jwt
		sub A10 $d moq-relay "$M6" "$RU/bcast" ch2 tok/parent.jwt
		sub A1x $d moq-relay "$M6" "$RU/bcast" ch1 tok/affa-exact.jwt
		for a in affa affb affc; do
			MOQ_CONNECT_TOKEN=$(cat "tok/$a.jwt") timeout 5 "$M6/moq" --connect-tls-insecure --connect "$RU/bcast" \
				--connect-version "moq-transport-$d" "${ONCE[@]}" announced > "out/disc-$a-$d.txt" 2> "logs/disc-$a-$d.log" || true
			echo "    disclosure $a: $(tr '\n' ' ' < "out/disc-$a-$d.txt")"
		done

		echo "Part B on moqx /h4, draft $d (anonymous_claim: subscribe prefix [bcast, ch1])"
		h4pubs
		sub H4a $d moqx "$M6" "$XU/h4" bcast/ch1
		sub H4b $d moqx "$M6" "$XU/h4" bcast/ch1-intl
		sub H4c $d moqx "$M6" "$XU/h4" bcast/ch1/sub
		sub H4d $d moqx "$M6" "$XU/h4" bcast/ch2
		sub H4n $d moqx "$M6" "$XU/h4n" bcast/ch1
		timeout 5 "$M6/moq" --connect-tls-insecure --connect "$XU/h4" --connect-version "moq-transport-$d" \
			"${ONCE[@]}" announced > "out/disc-h4-$d.txt" 2> "logs/disc-h4-$d.log" || true
		echo "    disclosure /h4: $(tr '\n' ' ' < "out/disc-h4-$d.txt")"

		echo "Part B on moqx /pg, draft $d (publisher arms: openmoq-publisher, Type 16)"
		pgarm P1 $d bcast/ch1 cat/pub-ch1.cwt
		pgarm P2 $d bcast/ch2 cat/pub-ch1.cwt
		pgarm P3 $d rival/ch1 cat/pub-ch1.cwt
		pgarm P3k $d bcast/ch1 cat/rival-for-bcast.cwt
		pgarm P4 $d bcast/ch1 cat/affa-expired.cwt
		pgarm P5 $d bcast/ch1
		pgarm P6a $d bcast/ch1 cat/mal-truncated.cwt
		pgarm P6b $d bcast/ch1 cat/mal-badsig.cwt
		pgarm P6c $d bcast/ch1 cat/mal-retargeted.cwt
		pgarm P6cc $d bcast/ch2 cat/mal-retargeted.cwt
		pgarm P7 $d bcast/a7 cat/subonly-a7.cwt
		pgarm P9 $d bcast/ch1-intl cat/pub-ch1.cwt
	done
}

# Part C: expiry and withdrawal, draft 18. Prints a timeline; the receiver's byte count is read
# once a second.
watch_bytes() { # watch_bytes <file> <seconds> <t0>: seconds after t0 at which the file stopped growing
	local f=$1 n=$2 t0=$3 last=-1 cur still=0
	for _ in $(seq "$n"); do
		sleep 1
		cur=$(size "$f")
		if [ "$cur" = "$last" ]; then still=$((still + 1)); else still=0; fi
		last=$cur
		if [ $still -ge 3 ]; then echo "stopped growing at +$(( $(now) - 3 - t0 ))s, $cur bytes"; return; fi
	done
	echo "still growing after ${n}s, $cur bytes"
}

part_c() {
	local M=$MOQ/moq exp t0
	echo "Part C on moq-relay: a 30 s token"
	exp=$(( $(now) + 30 ))
	$M auth sign --key keys/bcast.jwk --root bcast --subscribe 'ch1/**' --expires $exp > tok/affa-30s.jwt
	MOQ_CONNECT_TOKEN=$(cat tok/affa-30s.jwt) "$M6/moq" --connect-tls-insecure --connect "$RU/bcast" \
		--connect-version moq-transport-18 "${ONCE[@]}" --broadcast ch1 export ts > out/C-exp-relay.ts 2> logs/C-exp-relay.log &
	echo "  expiry at +30s: $(watch_bytes out/C-exp-relay.ts 60 $(( exp - 30 )))"
	kill -INT $! 2>/dev/null || true

	echo "Part C on moq-relay: withdrawal, the HS256 key deleted from the auth server's key dir"
	MOQ_CONNECT_TOKEN=$(cat tok/affa-hs.jwt) "$M6/moq" --connect-tls-insecure --connect "$RU/bcast" \
		--connect-version moq-transport-18 "${ONCE[@]}" --broadcast ch1 export ts > out/C-wd-relay.ts 2> logs/C-wd-relay.log &
	local sp=$!
	sleep 5
	mv pub/hs.jwk keys/hs-withdrawn.jwk
	t0=$(now)
	echo "  key deleted: $(watch_bytes out/C-wd-relay.ts 40 "$t0")"
	kill -INT $sp 2>/dev/null || true
	mv keys/hs-withdrawn.jwk pub/hs.jwk

	echo "Part C on moqx /pg: a 30 s CAT on a live publisher"
	stopbg moqx; sleep 0.5; start_moqx
	cat_tok pub-30s bcast client_setup,publish_namespace,publish bcast/ch1 30
	t0=$(now)
	omp Cexp 18 /pg bcast/ch1 16 cat/pub-30s.cwt
	for _ in 1 2 3 4 5 6 7; do
		sleep 10
		xfetch "Cexp+$(( $(now) - t0 ))" 18 "$XU/pg" bcast/ch1
		xstate "Cexp+$(( $(now) - t0 ))" 18 pg bcast/ch1
	done
	echo "  publisher said: $(omp_said Cexp 18)"
	omp_stop Cexp 18

	part_c_moqx_wd
}

# moqx v0.3.6 handles SIGTERM and SIGINT only: the documented SIGHUP reload is not in the
# release, and SIGHUP ends the process (nohup, which startbg uses, would ignore it). So a key is
# withdrawn by a restart without it, which ends every session on the relay.
part_c_moqx_wd() {
	echo "Part C on moqx: SIGHUP on a moqx not started under nohup"
	sed "s/port: $P_MOQX/port: $((P_MOQX + 1))/; s/port: $P_ADMIN/port: $((P_ADMIN + 1))/" moqx.yaml > moqx-hup.yaml
	python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
		"$MOQX/bin/moqx" --config moqx-hup.yaml --logtostderr > logs/hup.log 2>&1 &
	local hp=$!
	sleep 2
	kill -HUP $hp
	sleep 1
	if kill -0 $hp 2>/dev/null; then echo "  survived SIGHUP"; kill -TERM $hp; else echo "  exited on SIGHUP"; fi
	rm -f moqx-hup.yaml
	echo "Part C on moqx: the key removed and moqx restarted; a new session with its CAT"
	moqx_config wd
	stopbg moqx; sleep 0.5; start_moqx
	omp Cwdnew 18 /pg bcast/ch2 16 cat/wd-ch2.cwt
	xfetch Cwdnew 18 "$XU/pg" bcast/ch2
	echo "  publisher said: $(omp_said Cwdnew 18)"
	omp_stop Cwdnew 18
	echo "  control, a key still configured: bcast's CAT"
	omp Cwdctl 18 /pg bcast/ch1 16 cat/pub-ch1.cwt
	xfetch Cwdctl 18 "$XU/pg" bcast/ch1
	omp_stop Cwdctl 18
	moqx_config
	stopbg moqx; sleep 0.5; start_moqx
}

case "${1:-}" in
	setup) setup ;;
	config) moqx_config && "$MOQX/bin/moqx" validate-config --config moqx.yaml ;;
	start) start ;;
	stop) stop ;;
	part-a) part_a ;;
	part-b) part_b ;;
	part-c) part_c ;;
	part-c-moqx-wd) part_c_moqx_wd ;;
	*) sed -n '2,16p' "$0"; exit 2 ;;
esac
