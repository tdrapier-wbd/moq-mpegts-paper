#!/usr/bin/env bash
# T36 A11-A13: standalone FETCH and TRACK_STATUS against the licensing matrix, on loopback.
# usage: t36-fetch-status.sh <out-dir>
#   moq auth serve --key-dir answers the relay's --auth-url; publishers bc/news, bc/news-intl and
#   rival/news loop the clip; t36-probe asks, once per request, with affiliate A's credential
#   (licensed bc/news only) and, to learn each track's newest group, an operator credential.
# env: MOQ (moq-dev bin dir: moq, moq-relay), PROBE (t36-probe binary), CLIP (source TS),
#      PORT (default 4701), APORT (auth server, default 4702), DRAFT (default 16),
#      TRACKS (default catalog.json), NSPREFIX (prepended to each probed namespace, default empty)
# Writes probes.txt: one line per request, "<arm> <credential> <namespace> <track> <probe output>".
set -u
OUT=$1
PORT=${PORT:-4701} APORT=${APORT:-4702} DRAFT=${DRAFT:-16}
TRACKS=${TRACKS:-catalog.json} NSPREFIX=${NSPREFIX:-}
mkdir -p "$OUT/keys" "$OUT/tok" && cd "$OUT" || exit 1
exp=$(($(date +%s) + 7200))

for k in bc rival affa; do
	"$MOQ/moq" auth generate --id "$k" --out "keys/$k.jwk" || exit 1
done
sign() { # <key> <root> <grant flags...>
	local key=$1 root=$2
	shift 2
	"$MOQ/moq" auth sign --key "keys/$key.jwk" --root "$root" "$@" --expires "$exp"
}
sign bc bc --publish news >tok/pub-news.jwt
sign bc bc --publish news-intl >tok/pub-news-intl.jwt
sign rival rival --publish news >tok/pub-rival-news.jwt
sign affa bc --subscribe news >tok/affa.jwt
sign bc bc --subscribe '**' >tok/ops.jwt

"$MOQ/moq" auth serve --listen "127.0.0.1:$APORT" --key-dir keys >auth.log 2>&1 &
auth=$!
cat >relay.toml <<EOF
[log]
level = "info"

[listen]
bind = "127.0.0.1:$PORT"
tls.generate = ["localhost"]

[auth]
url = "http://127.0.0.1:$APORT"
EOF
"$MOQ/moq-relay" relay.toml --quic-gso=false >relay.log 2>&1 &
relay=$!
sleep 1

pubs=()
pub() { # <root> <channel> <token>
	tsp -I file "$CLIP" --infinite -P regulate --pcr-synchronous -O file - 2>/dev/null |
		"$MOQ/moq" --connect-tls-insecure --connect-version "moq-transport-$DRAFT" \
			--connect "moqt://127.0.0.1:$PORT/$1?jwt=$(cat "tok/$3")" \
			--broadcast "$2" import ts --passthrough >"pub-$1-$2.log" 2>&1 &
	pubs+=($!)
}
pub bc news pub-news.jwt
pub bc news-intl pub-news-intl.jwt
pub rival news pub-rival-news.jwt
sleep 8

probe() { # <arm> <credential> <namespace> <track> <status|fetch> [--group G]
	local arm=$1 cred=$2 ns=$3 track=$4
	shift 4
	printf '%s %s %s %s ' "$arm" "$cred" "$ns" "$track" >>probes.txt
	"$PROBE" "moqt://127.0.0.1:$PORT/bc?jwt=$(cat "tok/$cred.jwt")" "$NSPREFIX$ns" "$track" \
		"$@" --draft "$DRAFT" --timeout 8 >>probes.txt 2>>probe.err
}
newest() { # <namespace> <track>: the operator's view of a track's newest group
	"$PROBE" "moqt://127.0.0.1:$PORT/bc?jwt=$(cat tok/ops.jwt)" "$NSPREFIX$1" "$2" status \
		--draft "$DRAFT" --timeout 8 2>>probe.err | sed -n 's/.* largest=\([0-9]*\):.*/\1/p'
}

: >probes.txt
for t in $TRACKS; do
	g_news=$(newest news "$t")
	g_intl=$(newest news-intl "$t")
	echo "operator: $t newest group news=${g_news:-none} news-intl=${g_intl:-none}" >>probes.txt
	probe A12c affa news "$t" status
	probe A11c affa news "$t" fetch --group "${g_news:-0}"
	probe A12 affa news-intl "$t" status
	probe A11 affa news-intl "$t" fetch --group "${g_intl:-0}"
	probe A13 affa absent "$t" status
	probe A13 affa absent "$t" fetch --group 0
	probe A13 affa rival/news "$t" status
	probe A13 affa rival/news "$t" fetch --group 0
done

kill "${pubs[@]}" 2>/dev/null
pkill -P $$ tsp 2>/dev/null
kill "$relay" "$auth" 2>/dev/null
wait 2>/dev/null
cat probes.txt
