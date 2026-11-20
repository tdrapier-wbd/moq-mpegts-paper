#!/usr/bin/env bash
# T86 P2-t: kill one component of a live MoQ pair and let a supervisor restart it, loopback.
# usage: t86-restart.sh <out-dir> <A|M> <none|pub|relay|recv>
#   A  moq2ts-cli --unmodified (live, from stdin) -> moq-relay -> moq2ts-receiver
#   M  moq import ts --passthrough -> moq-relay -> moq export ts --passthrough, on moq-lite-07
# The source is tsp playing CLIP once at its PCR rate to 127.0.0.1:UDP; each publisher instance reads
# that port through its own tsp, so a killed publisher takes nothing upstream with it. The publisher,
# the relay and the receiver each run under a loop that restarts them 0.5 s after they exit; at
# KILL_AT s after the source starts (the publisher starts with it, joining a running source), the
# cell's component gets SIGKILL. The receivers' output feeds t67p-tap.py (release.csv, one row a
# second); out.ts joins each receiver instance's part in whole packets. events.log: each start,
# exit and the kill, in unix seconds.
# env: MOQ (moq-dev bin dir), CLI, RECV (moq2ts), CLIP, PORT (default 4433), UDP (default 5600),
#      KILL_AT (default 60), DRAFT (default 22), SEG (moq2ts-cli object bytes, default 310764),
#      KEEP_PARTS (keep each receiver instance's part beside out.ts), RELAY_LOG (its filter, default info)
set -u
OUT=$1 ARM=$2 CELL=$3
MOQ=${MOQ:?} CLI=${CLI:?} RECV=${RECV:?} CLIP=${CLIP:?}
PORT=${PORT:-4433} UDP=${UDP:-5600} KILL_AT=${KILL_AT:-60} DRAFT=${DRAFT:-22}
TAP=$(dirname "$0")/t67p-tap.py
mkdir -p "$OUT" && cd "$OUT" || exit 1
url="moqt://127.0.0.1:$PORT" ver="moq-transport-$DRAFT" name=t86.msf
if [ "$ARM" = M ]; then
	url="https://127.0.0.1:$PORT" ver=moq-lite-07-wip name=t86.hang
	export MOQ_LISTEN_VERSION=$ver
fi
printf '[log]\nlevel = "%s"\n\n[listen]\nbind = "127.0.0.1:%s"\ntls.generate = ["localhost"]\n\n[auth]\npublic = "**"\n' \
	"${RELAY_LOG:-info}" "$PORT" >relay.toml

log() { echo "$(python3 -c 'import time; print(f"{time.time():.3f}")') $*" >>events.log; }

relay() { "$MOQ/moq-relay" relay.toml --quic-gso=false >>relay.log 2>&1; }
publisher() {
	if [ "$ARM" = M ]; then
		tsp -I ip --local-address 127.0.0.1 "$UDP" -O file - 2>>tsp-in.log |
			"$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version "$ver" \
				--broadcast "$name" import ts --passthrough >>send.log 2>&1
	else
		tsp -I ip --local-address 127.0.0.1 "$UDP" -O file - 2>>tsp-in.log |
			"$CLI" --endpoint "$url" --namespace "$name" --video /dev/stdin --unmodified --draft "$DRAFT" \
				--insecure --fragment-ms 250 --segment-bytes "${SEG:-310764}" >>send.log 2>&1
	fi
}
# each receiver instance also writes its own part, so a kill mid-packet cannot misalign out.ts
receiver() {
	local part
	part=$(printf 'part-%03d.ts' "$(find . -maxdepth 1 -name 'part-*.ts' | wc -l)")
	if [ "$ARM" = M ]; then
		"$MOQ/moq" --connect-tls-insecure --connect "$url" --connect-version "$ver" \
			--broadcast "$name" export ts --passthrough 2>>recv.log | tee "$part"
	else
		"$RECV" --url "$url" --namespace "$name" --out - --duration 3600 --insecure --draft "$DRAFT" 2>>recv.log |
			tee "$part"
	fi
}

# supervise <role>: run the role until stop exists, recording each start and exit, the pid in <role>.pid
supervise() {
	local role=$1 pid rc
	while [ ! -e stop ]; do
		log "start $role"
		"$role" &
		pid=$!
		echo "$pid" >"$role.pid"
		wait "$pid"
		rc=$?
		log "exit $role rc=$rc"
		[ -e stop ] || sleep 0.5
	done
}

supervise relay &
sup_relay=$!
sleep 1
supervise receiver | python3 "$TAP" release.csv >/dev/null 2>tap.log &
sup_recv=$!
log "source start"
tsp -I file "$CLIP" -P regulate --pcr-synchronous -O ip "127.0.0.1:$UDP" 2>tsp-src.log &
src=$!
supervise publisher &
sup_pub=$!

# a role's pid is its subshell's; the kill goes to its binary (moq2ts-*, moq or moq-relay)
leaf() {
	local v
	v=$(pgrep -P "$(cat "$1.pid")" -f "moq2ts-|/moq |/moq-relay" | head -n 1)
	echo "${v:-$(cat "$1.pid")}"
}
if [ "$CELL" != none ]; then
	sleep "$KILL_AT"
	case $CELL in
	pub) target=publisher ;;
	recv) target=receiver ;;
	relay) target=relay ;;
	*) echo "unknown cell $CELL" >&2 && exit 2 ;;
	esac
	victim=$(leaf "$target")
	kill -9 "$victim" && log "kill $target pid=$victim"
fi
wait "$src"
log "source end"
sleep 15
touch stop
for role in publisher receiver relay; do
	pkill -9 -P "$(cat "$role.pid")" 2>/dev/null
	kill -9 "$(cat "$role.pid")" 2>/dev/null
done
wait "$sup_pub" "$sup_relay" "$sup_recv" 2>/dev/null
python3 -c '
import glob, sys
with open("out.ts", "wb") as out:
    for p in sorted(glob.glob("part-*.ts")):
        b = open(p, "rb").read()
        out.write(b[: len(b) - len(b) % 188])
' && { [ -n "${KEEP_PARTS:-}" ] || rm -f part-*.ts; }
log "done"
