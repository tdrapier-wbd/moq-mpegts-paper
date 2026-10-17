#!/usr/bin/env bash
# T49: a closed origin (`--auth-url`, no anonymous grant) and an edge that dials it with a
# subscribe-only token and admits recipients by their own keys. All on loopback, one run, ~110 s:
#   arms 1-2 publish side (no real publisher yet) for 8 s; then the publisher, and 3 s later the
#   subscriber-side refusals (arms 1-2, 4) and the long sessions; arm 5 (recipient revoked) 21 s
#   later; arm 6 (origin auth server down 20 s) 15 s after that; arm 7 (the edge's key revoked at the
#   origin for 12 s, then restored) 15 s after the restart.
# env: MOQ (bin dir: moq, moq-relay), CLIP (>= 120 s TS), OUT (run dir), OPORT (4911), EPORT (4912)
# Grade with t49-grade.py <run dir>.
set -u
MOQ=${MOQ:?bin dir} CLIP=${CLIP:?clip} OUT=${OUT:?run dir}
OPORT=${OPORT:-4911} EPORT=${EPORT:-4912}
M="$MOQ/moq"
mkdir -p "$OUT"/{keys,okeys,ekeys,cap,logs} || exit 1
cd "$OUT" || exit 1
mark() { echo "$(date +%s.%N) $1" >>events.txt; }
trap 'trap - EXIT TERM; kill 0' EXIT TERM # run under setsid: the group is this rig's

# Keys: publisher, edge and a stranger at the origin; three recipients and a stranger at the edge.
gen() { "$M" auth generate --algorithm ES256 --id "$1" --out "keys/$1.jwk" --public-dir "$2" >/dev/null; }
for k in pub edge osub ostranger; do gen "$k" okeys; done
for k in r1 r2 r3 estranger; do gen "$k" ekeys; done
cp okeys/edge.jwk edge.pub.jwk
sign() { "$M" auth sign --key "keys/$1.jwk" "${@:2}"; }
sign pub --publish live.a >tok.pub
sign ostranger --publish live.b --subscribe live.b >tok.ostranger
sign edge --subscribe live.a >tok.edge
sign osub --subscribe live.a --subscribe live.x >tok.osub
for r in r1 r2 r3; do sign "$r" --subscribe live.a >"tok.$r"; done
sign estranger --subscribe live.b >tok.estranger

auth() { # name keydir
	rm -f "$OUT/$1.sock"
	"$M" auth serve --listen "unix:$OUT/$1.sock" --key-dir "$2" --expires 1h --revalidate 5s \
		>>"logs/$1.log" 2>&1 &
	echo $! >"$1.pid"
}
auth oauth okeys
auth eauth ekeys
sleep 0.5
"$MOQ/moq-relay" --listen "127.0.0.1:$OPORT" --listen-tls-generate localhost --quic-gso=false \
	--auth-url "unix://$OUT/oauth.sock" >logs/origin.log 2>&1 &
"$MOQ/moq-relay" --listen "127.0.0.1:$EPORT" --listen-tls-generate localhost --quic-gso=false \
	--auth-url "unix://$OUT/eauth.sock" --connect-tls-insecure \
	--cluster-connect "https://127.0.0.1:$OPORT/" --cluster-token "$OUT/tok.edge" \
	>logs/edge.log 2>&1 &
sleep 1
mark start

o() { echo "https://127.0.0.1:$OPORT/${1:+?jwt=$(cat "tok.$1")}"; }
e() { echo "https://127.0.0.1:$EPORT/${1:+?jwt=$(cat "tok.$1")}"; }
pub() { # name url broadcast
	tsp -I file "$CLIP" -P regulate -O file - 2>>"logs/$1.tsp.log" |
		"$M" --connect-tls-insecure --connect "$2" --broadcast "$3" import ts >>"logs/$1.log" 2>&1
	local rc=$?
	echo "$(date +%s.%N) exit-$1 $rc" >>events.txt
}
sub() { # name url broadcast seconds
	timeout "$4" "$M" --connect-tls-insecure --connect "$2" --broadcast "$3" export ts \
		>"cap/$1.ts" 2>>"logs/$1.log"
	local rc=$?
	echo "$(date +%s.%N) exit-$1 $rc" >>events.txt
}

# Arms 1-2, publish side: no real publisher yet, so anything an authorised subscriber receives on
# live.a or live.x came from a publisher the origin should have refused.
pub anonpub "$(o)" live.x &
pub wrongpub "$(o ostranger)" live.a &
sleep 2
sub o_probe_a "$(o osub)" live.a 6 &
sub o_probe_x "$(o osub)" live.x 6
pkill -f "broadcast live.a import ts"
mark probes-done
sleep 1

pub publisher "$(o pub)" live.a &
sleep 3
mark subscribers
if [ "${MODE:-arms}" = control ]; then # arm 3's control: two exports on the origin, one on the edge
	sub origin "$(o osub)" live.a 60 &
	sub origin2 "$(o osub)" live.a 60 &
	sub r1 "$(e r1)" live.a 60
	sleep 1
	mark end
	exit 0
fi
sub origin "$(o osub)" live.a 100 &
sub r1 "$(e r1)" live.a 100 &
sub r2 "$(e r2)" live.a 100 &
sub o_anon "$(o)" live.a 10 &
sub o_wrong "$(o ostranger)" live.a 10 &
sub e_anon "$(e)" live.a 10 &
sub e_wrong "$(e estranger)" live.a 10 &

# Capture sizes every 0.1 s, for last-byte times.
(while :; do
	printf '%s' "$(date +%s.%N)"
	for c in origin r1 r2 r3; do printf ' %s' "$(stat -c %s "cap/$c.ts" 2>/dev/null || echo 0)"; done
	echo
	sleep 0.1
done) >sizes.txt &

sleep 21
rm ekeys/r2.jwk
mark arm5-r2-key-deleted
sleep 15
kill "$(cat oauth.pid)"
mark arm6-origin-auth-stopped
sleep 20
auth oauth okeys
mark arm6-origin-auth-restarted
sleep 15
rm okeys/edge.jwk
mark arm7-edge-key-deleted
sleep 12
cp edge.pub.jwk okeys/edge.jwk
mark arm7-edge-key-restored
sleep 3
sub r3 "$(e r3)" live.a 15 &
sleep 16
mark end
