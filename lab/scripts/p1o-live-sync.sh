#!/usr/bin/env bash
# P1-o — `moq export ts --sync` legs of the live feed across two hosts (T50 arm L).
#
#   p1o-live-sync.sh origin <bin-dir> <out-dir> <seconds>                       # ingesting host
#   p1o-live-sync.sh leg <bin-dir> <out.ts> <seconds> <origin-host> <fingerprint>
#
# origin: a relay of this build on :$PORT and `import ts` (the demultiplexed lane) reading the
# standing ingest's loopback multicast group; writes the relay's fingerprint to <out>/fp.txt and
# stops after <seconds>.
# leg: one `export ts --sync` leg for <seconds>; start the second leg LATE s after the first.
#
# env: RATE (30000000), DELAY (1s), PORT (4443), GROUP (239.255.0.1:5000), RCVBUF (16777216),
#      RELAY_TOML (origin), BCAST
set -uo pipefail

ROLE=${1:?origin or leg}
BIN=${2:?bin dir with moq and moq-relay}
OUT=${3:?out dir or file}
SECS=${4:?seconds}
RATE=${RATE:-30000000}
DELAY=${DELAY:-1s}
PORT=${PORT:-4443}
GROUP=${GROUP:-239.255.0.1:5000}
RCVBUF=${RCVBUF:-16777216}
BCAST=${BCAST:-p1o.live.sync.hang}
MOQ=$BIN/moq

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	sleep 1
	for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
	true
}
trap cleanup EXIT

case "$ROLE" in
origin)
	rm -rf "$OUT"
	mkdir -p "$OUT"
	cp "${RELAY_TOML:?relay toml}" "$OUT/relay.toml"
	{
		echo "build=$(cat "$BIN/.sha" 2>/dev/null || "$MOQ" --version)"
		echo "group=$GROUP rcvbuf=$RCVBUF secs=$SECS"
		echo "started=$(date -u +%FT%TZ)"
	} >"$OUT/meta.txt"
	(cd "$OUT" && exec "$BIN/moq-relay" relay.toml) >"$OUT/relay.log" 2>&1 &
	RELAY_PID=$!
	PIDS+=("$RELAY_PID")
	for _ in $(seq 1 40); do
		FP="$(curl -s "http://localhost:$PORT/certificate.sha256" 2>/dev/null || true)"
		[ -n "$FP" ] && break
		sleep 0.25
	done
	[ -n "${FP:-}" ] && kill -0 "$RELAY_PID" 2>/dev/null || {
		echo "relay did not come up, or another holds :$PORT" >&2
		exit 1
	}
	(tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size "$RCVBUF" -O file - 2>"$OUT/pub-tsp.log" |
		"$MOQ" --connect-tls-fingerprint "$FP" --connect "https://localhost:$PORT/anon" \
			--broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
	PIDS+=($!)
	echo "$FP" >"$OUT/fp.txt"
	sleep "$SECS"
	ps -o pid,pcpu,rss,etime,args -C moq-relay,moq,tsp >"$OUT/ps.txt" 2>&1
	cleanup
	trap - EXIT
	echo "finished=$(date -u +%FT%TZ)" >>"$OUT/meta.txt"
	touch "$OUT/done"
	;;
leg)
	HOST=${5:?origin host}
	FP=${6:?fingerprint}
	echo "started=$(date -u +%FT%TZ) rate=$RATE delay=$DELAY" >"${OUT%.ts}.meta"
	timeout "$SECS" "$MOQ" --connect-tls-fingerprint "$FP" --connect "https://$HOST:$PORT/anon" \
		--broadcast "$BCAST" export ts --sync --mux-rate "$RATE" --delay "$DELAY" \
		>"$OUT" 2>"${OUT%.ts}.log"
	rc=$?
	echo "finished=$(date -u +%FT%TZ) rc=$rc" >>"${OUT%.ts}.meta"
	trap - EXIT
	;;
*)
	echo "unknown role $ROLE" >&2
	exit 2
	;;
esac
