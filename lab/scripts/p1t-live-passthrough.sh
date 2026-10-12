#!/usr/bin/env bash
# P1-t — the opaque lane on the live hand-off, across hosts (T48's criteria on a real feed).
#
#   p1t-live-passthrough.sh origin <bin-dir> <out-dir> <seconds>     # ingesting host
#   p1t-live-passthrough.sh sub <bin-dir> <out-dir> <seconds> <origin-host> <fingerprint>
#   p1t-live-passthrough.sh leg <bin-dir> <out.ts> <seconds> <origin-host> <fingerprint>
#
# origin: a relay of this build on :$PORT, the hand-off capture (the reference) and
# `import ts --passthrough`, both reading the standing ingest's loopback multicast group with the same
# receive buffer; writes the relay's fingerprint to <out>/fp.txt, counts the bytes the relay sends to
# each address in ACCT_DESTS (udp-port-acct.sh beside this script), and stops after <seconds>.
# sub: leg A from the start, teed into upstream's live PCR grader, and leg B joining LATE s later.
# leg: one more leg (the workstation's).
#
# env: DELAY (2s), LATE (8), PORT (4443), GROUP (239.255.0.1:5000), RCVBUF (16777216),
#      RELAY_TOML (origin), ACCT_DESTS (origin), TSC (sub: upstream's test/ts), BCAST
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLE=${1:?origin, sub or leg}
BIN=${2:?bin dir with moq and moq-relay}
OUT=${3:?out dir or file}
SECS=${4:?seconds}
DELAY=${DELAY:-2s}
LATE=${LATE:-8}
PORT=${PORT:-4443}
GROUP=${GROUP:-239.255.0.1:5000}
RCVBUF=${RCVBUF:-16777216}
BCAST=${BCAST:-p1t.live.passthrough.hang}
MOQ=$BIN/moq

PIDS=()
ACCT=()
cleanup() {
	# The counters remove their iptables rules in their own exit trap, which SIGKILL would skip.
	for p in "${ACCT[@]:-}"; do kill -TERM "$p" 2>/dev/null; done
	for p in "${ACCT[@]:-}"; do wait "$p" 2>/dev/null; done
	ACCT=()
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
		echo "build=$(cat "$BIN/.sha" 2>/dev/null)"
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
	for d in ${ACCT_DESTS:-}; do
		bash "$HERE/udp-port-acct.sh" "$PORT" "$d" "$OUT/acct-$d.csv" 5 &
		ACCT+=($!)
	done
	tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size "$RCVBUF" \
		-P continuity -O file "$OUT/src.ts" 2>"$OUT/capture.log" &
	PIDS+=($!)
	sleep 2
	(tsp -I ip "$GROUP" --local-address 127.0.0.1 --buffer-size "$RCVBUF" -O file - 2>"$OUT/pub-tsp.log" |
		"$MOQ" --connect-tls-fingerprint "$FP" --connect "https://localhost:$PORT/anon" \
			--broadcast "$BCAST" import ts --passthrough) >"$OUT/import.log" 2>&1 &
	PIDS+=($!)
	echo "$FP" >"$OUT/fp.txt"
	sleep "$SECS"
	ps -o pid,pcpu,rss,etime,args -C moq-relay,moq,tsp >"$OUT/ps.txt" 2>&1
	cleanup
	trap - EXIT
	echo "finished=$(date -u +%FT%TZ)" >>"$OUT/meta.txt"
	touch "$OUT/done"
	;;
sub)
	HOST=${5:?origin host}
	FP=${6:?fingerprint}
	TSC=${TSC:?upstream test/ts}
	DELAY_MS=$(python3 -c "import re,sys; v,u=re.fullmatch(r'([\d.]+)(ms|s)', sys.argv[1]).groups(); print(int(float(v)*(1 if u=='ms' else 1000)))" "$DELAY")
	rm -rf "$OUT"
	mkdir -p "$OUT"
	C=(--connect-tls-fingerprint "$FP" --connect "https://$HOST:$PORT/anon" --broadcast "$BCAST")
	echo "started=$(date -u +%FT%TZ) delay=$DELAY late=$LATE" >"$OUT/meta.txt"
	("$MOQ" "${C[@]}" export ts --passthrough --delay "$DELAY" 2>"$OUT/a.log" |
		tee "$OUT/a.ts" |
		python3 "$TSC/pcr-timing.py" --live --seconds $((SECS - 10)) --drift-ms "$DELAY_MS" \
			--report-json "$OUT/a-pcr.json" >"$OUT/a-pcr.txt" 2>&1) &
	PIDS+=($!)
	sleep "$LATE"
	"$MOQ" "${C[@]}" export ts --passthrough --delay "$DELAY" >"$OUT/b.ts" 2>"$OUT/b.log" &
	PIDS+=($!)
	sleep $((SECS - LATE))
	cleanup
	trap - EXIT
	echo "finished=$(date -u +%FT%TZ)" >>"$OUT/meta.txt"
	touch "$OUT/done"
	;;
leg)
	HOST=${5:?origin host}
	FP=${6:?fingerprint}
	"$MOQ" --connect-tls-fingerprint "$FP" --connect "https://$HOST:$PORT/anon" --broadcast "$BCAST" \
		export ts --passthrough --delay "$DELAY" >"$OUT" 2>"${OUT%.ts}.log" &
	PIDS+=($!)
	sleep "$SECS"
	cleanup
	trap - EXIT
	;;
*)
	echo "unknown role $ROLE" >&2
	exit 2
	;;
esac
