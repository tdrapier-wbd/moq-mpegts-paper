#!/usr/bin/env bash
# P1-h: dial each registered public relay that T11's sweep could not reach, at the draft and
# transport its interop-runner entry registers, and keep the client's debug log, so a failure can
# be placed at DNS, the QUIC or TLS handshake, ALPN, SETUP, or the first request.
#
# Each endpoint gets a short publish (`import ts --passthrough` from the first MB of the clip) and a
# discovery (`announced` on the empty prefix), both bounded by SECS.
#
#   BIN=<moq dir> CLIP=<ts file> p1h-relay-probe.sh <out dir>
#
# Env: SECS (15). CLIP must be synthetic (the runner's make-fixture.sh): a public relay announces
# what it carries to anyone. Endpoints are the runner's entries; edit ENDPOINTS when its registry
# moves.
set -uo pipefail

OUT=${1:?out dir}
BIN=${BIN:?set BIN to the moq binary dir}
CLIP=${CLIP:?set CLIP to the synthetic fixture}
SECS=${SECS:-15}
mkdir -p "$OUT"

# name | url | version | insecure (1 where the registry sets tls_disable_verify)
ENDPOINTS=(
	"moqtail-22-wt|https://relay.moqtail.dev:8244|moq-transport-22|0"
	"moqtail-22-quic|moqt://relay.moqtail.dev:8244|moq-transport-22|0"
	"moqtail-18-wt|https://relay.moqtail.dev|moq-transport-18|0"
	"moqtail-18-quic|moqt://relay.moqtail.dev:443|moq-transport-18|0"
	"quiche-18-wt|https://quichemoq.dev:443|moq-transport-18|0"
	"quicr-18-wt|https://us-west-2.relay.quicr.org:33437/relay|moq-transport-18|1"
	"quicr-18-quic|moqt://us-west-2.relay.quicr.org:33437|moq-transport-18|1"
)

"$BIN/moq" --version >"$OUT/build.txt" 2>&1
for e in "${ENDPOINTS[@]}"; do
	IFS='|' read -r name url version insecure <<<"$e"
	tls=()
	[ "$insecure" = 1 ] && tls=(--connect-tls-insecure)
	host=${url#*://}
	host=${host%%[:/]*}
	{
		echo "== $name $url $version"
		getent ahosts "$host" | awk '{print $1}' | sort -u | tr '\n' ' '
		echo
	} >"$OUT/$name.dns"
	head -c 1000000 "$CLIP" |
		RUST_LOG=debug timeout "$SECS" "$BIN/moq" "${tls[@]}" --connect "$url" --connect-version "$version" \
			--broadcast "p1h-probe-$$" import ts --passthrough >"$OUT/$name.publish.log" 2>&1
	echo "publish rc=$?" >>"$OUT/$name.dns"
	RUST_LOG=debug timeout "$SECS" "$BIN/moq" "${tls[@]}" --connect "$url" --connect-version "$version" \
		announced >"$OUT/$name.announced.log" 2>&1
	echo "announced rc=$?" >>"$OUT/$name.dns"
	cat "$OUT/$name.dns"
done
