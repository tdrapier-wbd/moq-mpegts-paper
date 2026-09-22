#!/usr/bin/env bash
# Cross a continuous-source pass join with subscribers differing in exactly one setting.
#
#   t27-join-control.sh <label> <relay-ip> <duration-s> <arm-list>
#   e.g. t27-join-control.sh joinctl <EC2_IP> 800 "500ms,500ms,3s,3s"
#        t27-join-control.sh ver <EC2_IP> 1400 "500ms@/home/u/bin-a/moq,500ms@/home/u/bin-b/moq"
#
# An arm is `latmax` or `latmax@binary`, so one run can vary the buffer setting or the client build
# while every subscriber shares a publisher, a relay and a join.
#
# A 90 min N = 60 soak lost every subscriber's video at the source's first pass join — 600 s in, at
# the point `ts-continuous-source.py` restarts the clip's content on a continuous timeline. The
# exporters did not exit: they kept *receiving* ~570 Mb/s and emitting 0.31 Mb/s, indefinitely, and a
# subscriber joining afterwards was served perfectly. So the relay and publisher were fine and the
# incumbent exporters were stuck.
#
# [T21](../test-21-permanence-soak.md) crossed about 144 of these joins in 24 h without a mark, which
# makes the difference between the two runs the whole question. T21 was N = 1, loopback,
# `"${MOQ_LAT[@]}" 500ms`, with a pacer draining the exporter; the soak was N = 60, cross-host,
# `"${MOQ_LAT[@]}" 3s`, draining to `/dev/null`.
#
# This varies **one** of those — `--latency-max` — at a fan-out low enough that the relay cannot be
# the constraint, with every subscriber attached to the same publisher and crossing the same join.
# Per-subscriber emitted rate comes from `/proc/<pid>/io` `wchar`, sampled either side of the join.
# If the 500 ms subscribers cross it and the 3 s subscribers stall, the buffer setting is the
# discriminator; if all of them cross it, fan-out is, and that is the next run rather than this one.
set -uo pipefail

# Post-#3793 CLI flags (dual old/new binaries).
# shellcheck source=moq-cli-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/moq-cli-flags.sh"

LABEL=${1:?label}
RELAY_IP=${2:?relay ip}
DURATION=${3:-800}
LATLIST=${4:-500ms,500ms,3s,3s}

MOQ=${MOQ:?set MOQ to the moq binary}
moq_cli_detect "$MOQ" "${RELAY:-${RELAY_BIN:-}}"
BCAST=${BCAST:-t27join.hang}
PORT=${PORT:-4443}
CLIP=${CLIP:-$HOME/CNNiEMEA2.ts}
SRCGEN=${SRCGEN:-$HOME/f5/ts-continuous-source.py}
GSO=${GSO:-true}
SAMPLE=${SAMPLE:-10}
OUT=${OUT:-$HOME/t27}/$LABEL

rm -rf "$OUT"
mkdir -p "$OUT"

SUBS=()
LATS=()
cleanup() {
	for p in "${SUBS[@]+${SUBS[@]}}"; do kill -9 "$p" 2>/dev/null || true; done
	pkill -f "[-]-broadcast $BCAST" 2>/dev/null || true
	pkill -f "[t]s-continuous-source.py $CLIP" 2>/dev/null || true
}
trap cleanup EXIT

CONN=("${MOQ_DIAL[@]}" "https://$RELAY_IP:$PORT/anon"
	"--quic-gso=$GSO")

{
	echo "label=$LABEL relay=$RELAY_IP:$PORT duration=${DURATION}s latmax=$LATLIST"
	echo "moq=$("$MOQ" --version 2>&1 | head -1) client_quic_gso=$GSO"
	echo "source=ts-continuous-source.py on $(basename "$CLIP") — pass join near 600 s of media"
	echo "started=$(date -u +%FT%T%z)"
} >"$OUT/meta.txt"

(python3 "$SRCGEN" "$CLIP" |
	tsp -I file - -P regulate --pcr-synchronous --wait-min 5 -O file - |
	"$MOQ" "${CONN[@]}" --broadcast "$BCAST" import ts) >"$OUT/publisher.log" 2>&1 &
PUB_PID=$!
sleep 8
kill -0 "$PUB_PID" 2>/dev/null || {
	echo "t27-join: publisher died" >&2
	exit 1
}
echo "t27-join: publisher up; subscribers at $LATLIST"

i=0
for A in $(echo "$LATLIST" | tr ',' ' '); do
	i=$((i + 1))
	L=${A%%@*}
	BIN=$MOQ
	TAG=$L
	case $A in
	*@*)
		BIN=${A#*@}
		TAG="$L-$(basename "$(dirname "$BIN")")"
		;;
	esac
	"$BIN" "${CONN[@]}" --broadcast "$BCAST" export ts "${MOQ_LAT[@]}" "$L" \
		>/dev/null 2>"$OUT/sub.$i.$TAG.log" &
	SUBS+=("$!")
	LATS+=("$TAG")
	sleep 0.3
done

wchar() { awk -F': *' '/^wchar/{print $2}' "/proc/$1/io" 2>/dev/null || echo 0; }

CSV="$OUT/rates.csv"
{
	printf 't_s'
	for n in $(seq 1 ${#SUBS[@]}); do printf ',mbps_%s_%s' "$n" "${LATS[$((n - 1))]}"; done
	printf ',alive\n'
} >"$CSV"

PREV=()
for p in "${SUBS[@]}"; do PREV+=("$(wchar "$p")"); done
T0=$(date +%s)
TP=$T0

while :; do
	sleep "$SAMPLE"
	NOW=$(date +%s)
	EL=$((NOW - T0))
	WIN=$((NOW - TP))
	[ "$WIN" -lt 1 ] && WIN=1
	LINE="$EL"
	ALIVE=0
	for n in $(seq 0 $((${#SUBS[@]} - 1))); do
		p=${SUBS[$n]}
		kill -0 "$p" 2>/dev/null && ALIVE=$((ALIVE + 1))
		c=$(wchar "$p")
		LINE="$LINE,$(awk -v a="${PREV[$n]}" -v b="$c" -v w="$WIN" 'BEGIN{printf "%.2f", (b-a)*8/w/1e6}')"
		PREV[$n]=$c
	done
	echo "$LINE,$ALIVE" >>"$CSV"
	TP=$NOW
	[ $((EL % 60)) -lt "$SAMPLE" ] && echo "  t=${EL}s  $(tail -1 "$CSV")"
	[ "$EL" -ge "$DURATION" ] && break
done

echo "finished=$(date -u +%FT%T%z)" >>"$OUT/meta.txt"
echo "t27-join done: $CSV"
