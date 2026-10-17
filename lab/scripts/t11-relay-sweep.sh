#!/usr/bin/env bash
# T11a re-sweep: the runner proposal's two TS cases through each registered public relay, with
# `moq-dev` at both ends, over raw QUIC at the relay's highest registered draft.
#   carriage  the subscriber is up before the publisher and must receive the whole fixture
#   late      the subscriber joins 8.5 s into the 20 s fixture and must receive a decodable tail
# Both publishers run `import ts --passthrough`, paced by `tsp regulate --pcr-synchronous`.
#
#   BIN=<moq dir> FIXTURE=<fixture.ts> CHECK=<check-ts.py> t11-relay-sweep.sh <out dir> [name...]
#
# FIXTURE must be the synthetic fixture (the runner's make-fixture.sh): a public relay announces
# what it carries to anyone. Endpoints are the runner registry's raw-QUIC entries; edit ENDPOINTS
# when it moves. Names given after the out dir restrict the sweep to those endpoints.
#
# The importer writes its catalog only once the first group holds objects, so even the carriage
# subscriber subscribes after group 0 has begun, and a relay that starts a new subscription at the
# next group legitimately delivers from group 1. Each capture is therefore also graded as a tail
# (carriage-suffix.tap), which separates the join point from loss after it.
set -uo pipefail

OUT=${1:?out dir}
shift
BIN=${BIN:?set BIN to the moq binary dir}
FIXTURE=${FIXTURE:?set FIXTURE to the synthetic fixture}
CHECK=${CHECK:?set CHECK to check-ts.py}
mkdir -p "$OUT"

# name | url | version | insecure (1 where the registry sets tls_disable_verify)
ENDPOINTS=(
	"moq-dev|moqt://cdn.moq.dev:443/anon|moq-transport-20|0"
	"aiomoqt|moqt://moqarena.marzresearch.net:4443|moq-transport-22|0"
	"imquic|moqt://lminiero.it:9000|moq-transport-22|0"
	"libquicr|moqt://us-west-2.relay.quicr.org:33437|moq-transport-18|1"
	"moqtail-22|moqt://relay.moqtail.dev:8244|moq-transport-22|0"
	"moqtail-18|moqt://relay.moqtail.dev:443|moq-transport-18|0"
	"nokia-19|moqt://moqt.nokiaresearch.com:4443/moq|moq-transport-19|0"
	"nokia-22|moqt://moqt.nokiaresearch.com:8443/moq|moq-transport-22|0"
	"moqx|moqt://moqx-main.ci.openmoq.org:4433|moq-transport-18|0"
	"moxygen|moqt://fb.mvfst.net:9448/moq-relay|moq-transport-22|1"
	"red5|moqt://moq-relay.red5.net:4433|moq-transport-22|0"
	"stitcher|moqt://34-72-6-160.sslip.io:443|moq-transport-22|0"
	"cloudflare-18|moqt://draft-18-interop.cloudflare.mediaoverquic.com:443|moq-transport-18|0"
)

export RUST_LOG=${RUST_LOG:-info,moq_net=debug}
"$BIN/moq" --version >"$OUT/build.txt" 2>&1
printf '%-14s %-18s %-9s %-9s %-9s %s\n' relay negotiated carriage as-tail late bytes >"$OUT/summary.txt"

for e in "${ENDPOINTS[@]}"; do
	IFS='|' read -r name url version insecure <<<"$e"
	if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then
		continue
	fi
	d="$OUT/$name"
	mkdir -p "$d"
	c=(--connect "$url" --connect-version "$version")
	[ "$insecure" = 1 ] && c=(--connect-tls-insecure "${c[@]}")
	# anonymous publish on some relays is allowed only under a moq-test prefix
	b="moq-test/t11-$$-$name"

	timeout 45 "$BIN/moq" "${c[@]}" --broadcast "$b-carriage" export ts --passthrough \
		>"$d/carriage.ts" 2>"$d/carriage.log" &
	sub1=$!
	sleep 2
	(tsp -I file "$FIXTURE" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		timeout 60 "$BIN/moq" "${c[@]}" --broadcast "$b-carriage" import ts --passthrough \
			>"$d/pub-carriage.log" 2>&1) &
	pub1=$!
	(tsp -I file "$FIXTURE" -P regulate --pcr-synchronous -O file - 2>/dev/null |
		timeout 60 "$BIN/moq" "${c[@]}" --broadcast "$b-late" import ts --passthrough \
			>"$d/pub-late.log" 2>&1) &
	pub2=$!
	sleep 8.5
	timeout 35 "$BIN/moq" "${c[@]}" --broadcast "$b-late" export ts --passthrough \
		>"$d/late.ts" 2>"$d/late.log" &
	sub2=$!
	wait "$sub1" "$sub2"
	kill "$pub1" "$pub2" 2>/dev/null
	wait "$pub1" "$pub2" 2>/dev/null

	python3 "$CHECK" --fixture "$FIXTURE" --received "$d/carriage.ts" >"$d/carriage.tap" 2>&1
	rc1=$?
	python3 "$CHECK" --fixture "$FIXTURE" --received "$d/carriage.ts" --suffix >"$d/carriage-suffix.tap" 2>&1
	rc1s=$?
	python3 "$CHECK" --fixture "$FIXTURE" --received "$d/late.ts" --suffix >"$d/late.tap" 2>&1
	rc2=$?
	neg=$(sed 's/\x1b\[[0-9;]*m//g' "$d/pub-carriage.log" | grep -o 'connected version=moq[^ ]*' | head -1 | cut -d= -f2)
	verdict() { case $1 in 0) echo pass ;; 1) echo fail ;; *) echo "error$1" ;; esac; }
	printf '%-14s %-18s %-9s %-9s %-9s %s/%s\n' "$name" "${neg:-none}" "$(verdict $rc1)" "$(verdict $rc1s)" \
		"$(verdict $rc2)" "$(stat -c %s "$d/carriage.ts")" "$(stat -c %s "$d/late.ts")" >>"$OUT/summary.txt"
	tail -1 "$OUT/summary.txt"
done
