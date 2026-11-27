#!/usr/bin/env bash
# Does a receiver reached through two relays survive losing one? moq2ts#72 sends identical Objects
# to several relays so that a receiver subscribed through two does. `moq` reaches several relays as
# a cluster node (`--cluster-connect`). Two independent relays on loopback; one `import ts
# --passthrough` and one `export ts --passthrough` each clustered to both; the clip fed paced; one
# relay killed KILL_AT s after the import starts, A and B in turn. The killed relay carried the route
# if the export's output stops growing between 3 and 8 s after the kill. A run `survives`
# when the export reaches the clip's end and its output is the clip, byte-identical and whole;
# `hole` when it reaches the end with packets missing; `ends` otherwise; `void` with no output
# before the kill.
#
# Usage: xc-two-relays.sh OUT    env: MOQ (bin dir), CLIP, PACKETS (133000), KILL_AT (10), DELAY (2s),
#                                      VICTIMS (A B A B), EXPORT_ARGS (e.g. "--follow 10s --stitch")

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-ed3a2697-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts}
PACKETS=${PACKETS:-133000} KILL_AT=${KILL_AT:-10} DELAY=${DELAY:-2s}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
head -c $((188 * PACKETS)) "$CLIP" >clip.ts
INSECURE=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}")
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) packets=$PACKETS kill_at=$KILL_AT delay=$DELAY export_args=${EXPORT_ARGS:-}" | tee meta.txt

n=0
for victim in ${VICTIMS:-A B A B}; do
	n=$((n + 1))
	name=run$n-kill$victim
	PA=$((20000 + RANDOM % 20000))
	PB=$((PA + 1))
	PEERS="https://localhost:$PA/anon,https://localhost:$PB/anon"
	moq_relay_public "[::]:$PA" localhost --log-level info
	"$R" "${RELAY_ARGV[@]}" >"$name.relayA.log" 2>&1 &
	RA=$!
	moq_relay_public "[::]:$PB" localhost --log-level info
	"$R" "${RELAY_ARGV[@]}" >"$name.relayB.log" 2>&1 &
	RB=$!
	sleep 1
	b=xc-two-$n
	RUST_LOG=info timeout 90 "$M" "${INSECURE[@]}" --cluster-connect "$PEERS" --broadcast "$b" \
		export ts --passthrough --delay "$DELAY" ${EXPORT_ARGS:-} >"$name.ts" 2>"$name.export.log" &
	EP=$!
	sleep 1
	tsp -I file clip.ts -P regulate --pcr-synchronous -O file - 2>/dev/null |
		RUST_LOG=info timeout 90 "$M" "${INSECURE[@]}" --cluster-connect "$PEERS" --broadcast "$b" \
			import ts --passthrough 2>"$name.import.log" &
	IP=$!
	sleep "$KILL_AT"
	before=$(wc -c <"$name.ts" | tr -d ' ')
	if [ "$victim" = A ]; then kill -9 "$RA"; else kill -9 "$RB"; fi
	sleep 3
	at3=$(wc -c <"$name.ts" | tr -d ' ')
	sleep 5
	carried=yes
	[ "$(wc -c <"$name.ts" | tr -d ' ')" -gt "$at3" ] && carried=no
	wait "$IP"
	wait "$EP"
	erc=$?
	kill "$RA" "$RB" 2>/dev/null
	wait 2>/dev/null
	python3 - "$name" "$before" "$erc" "$carried" <<'EOF' | tee -a results.tsv
import sys
name, before, erc, carried = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
P = 188
clip, out = open("clip.ts", "rb").read(), open(f"{name}.ts", "rb").read()
start = clip.find(out[:P * 20]) if len(out) >= P * 20 else -1
whole = start >= 0 and clip[start:start + len(out)] == out
end_ok = out.endswith(clip[-P * 400:])
if before == 0 or start < 0:
    verdict = "void"
elif whole and end_ok:
    verdict = "survives"
elif end_ok:
    verdict = "hole"
else:
    verdict = "ends"
print(f"{name}\tcarried_route={carried}\tbefore_kill={before}\tout={len(out)}\tstart_packet={start // P if start >= 0 else -1}"
      f"\twhole={whole}\treached_end={end_ok}\texport_rc={erc}\t{verdict}")
EOF
done
