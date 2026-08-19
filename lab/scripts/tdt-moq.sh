#!/usr/bin/env bash
# What the media-aware lane does to the clock it carries.
#
# The companion to `tdt-transports.sh`, which asked the same question of UDP, SRT and
# RIST and found all three transparent. Those are pipes; this lane is a remultiplexer,
# so it can only proxy the source's time table by storing a section and re-emitting it
# on its own schedule — and the interesting number is therefore not whether the table
# arrives but *which* time it asserts when it does.
#
# The source is re-stamped by `tsp -P timeref --start system`, so every TDT transmitted
# asserts the true UTC of its own transmission and any lateness downstream is the lane's.
#
# Three arms, because the answer depends on how the source's cadence sits against the
# exporter's re-emission interval (30s for table 0x70/0x73, the DVB maximum):
#
#   base  the clip's own TDT, every 15.1s. Faster than the exporter re-emits, so a new
#         section always lands between emissions and every emission should be fresh.
#   slow  TDT stripped and re-injected every ~45s, i.e. slower than the exporter emits.
#         The exporter must then either repeat a section it has already sent — asserting
#         a time it knows to be wrong, and stepping a trusting receiver's clock backwards
#         — or emit nothing. Which of the two it does is the point of the arm.
#   tot   TDT and a TOT carrying two regions' summer-time policy. A `local_time_offset`
#         descriptor is operator policy an exporter cannot invent, so it is the part of
#         the clock that most needs relaying rather than synthesising; this arm checks the
#         descriptor bytes survive, not merely that a 0x73 section does.
#
# `control` runs the same publisher chain straight into the instrument with no MoQ in the
# path. It is not a comparison, it is the proof that the source's clock is true: without
# it a null result cannot be told from a mis-stamped source.
#
# Usage: tdt-moq.sh <moq> <moq-relay> <relay.toml> <src.ts> <out-dir> [seconds] [arm...]

set -uo pipefail

MOQ=${1:?usage: tdt-moq.sh <moq> <moq-relay> <relay.toml> <src.ts> <out-dir> [seconds] [arm...]}
RELAY=${2:?moq-relay binary}
TOML=${3:?relay config}
SRC=${4:?source clip}
OUT=${5:?output dir}
SECS=${6:-240}
shift 6 2>/dev/null || shift $#
ARMS=("$@")
[[ ${#ARMS[@]} -gt 0 ]] || ARMS=(control base slow tot)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TDT_PID=0x14

for f in "$MOQ" "$RELAY"; do
	[[ -x "$f" ]] || {
		echo "not executable: $f" >&2
		exit 1
	}
done
[[ -r "$SRC" && -r "$TOML" ]] || {
	echo "not readable: $SRC or $TOML" >&2
	exit 1
}
mkdir -p "$OUT"

# Injection cadence is in packets, so it depends on the clip's rate. Derive it rather
# than hard-coding: a fixture at a different bitrate would otherwise silently inject at
# the wrong interval and the arm would test nothing in particular.
BPS=$(tsp -I file "$SRC" -P until --packets 200000 -P analyze --normalized -O drop 2>/dev/null |
	tr ':' '\n' | sed -n 's/^bitrate=//p' | head -1)
[[ -n "$BPS" && "$BPS" -gt 0 ]] 2>/dev/null || BPS=9945951
PPS=$((BPS / 8 / 188))
IP_SLOW=$((PPS * 45)) # one section every ~45s: slower than the exporter re-emits
IP_FAST=$((PPS * 10)) # two tables alternating: each every ~20s

# The two injectable sections. TDT is short-form and CRC-free, so it is lifted straight
# from the clip; TOT needs a descriptor loop and a CRC, so it is compiled from XML.
TDT_BIN="$OUT/tdt.bin"
TOT_BIN="$OUT/tot.bin"
python3 - "$SRC" "$TDT_BIN" <<'PY'
import sys

PACKET = 188
src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as fh:
	while pkt := fh.read(PACKET):
		if len(pkt) < PACKET or pkt[0] != 0x47:
			break
		if ((pkt[1] & 0x1F) << 8 | pkt[2]) != 0x0014 or not pkt[1] & 0x40:
			continue
		body = 4 + (1 + pkt[4] if pkt[3] & 0x20 else 0)
		sec = body + 1 + pkt[body]
		length = 3 + ((pkt[sec + 1] & 0x0F) << 8 | pkt[sec + 2])
		with open(dst, "wb") as out:
			out.write(pkt[sec : sec + length])
		sys.exit(0)
sys.exit("no TDT section on PID 0x0014 to lift")
PY
[[ -s "$TDT_BIN" ]] || exit 1

cat >"$OUT/tot.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<tsduck>
  <TOT UTC_time="2026-06-19 07:54:42">
    <local_time_offset_descriptor>
      <region country_code="GBR" country_region_id="0" local_time_offset="60"
              time_of_change="2026-10-25 02:00:00" next_time_offset="0"/>
      <region country_code="DEU" country_region_id="0" local_time_offset="120"
              time_of_change="2026-10-25 03:00:00" next_time_offset="60"/>
    </local_time_offset_descriptor>
  </TOT>
</tsduck>
XML
tstabcomp -c "$OUT/tot.xml" -o "$TOT_BIN" >/dev/null

# Flag surface: the dial-side options were renamed `--client-*` -> `--connect-*` and the
# per-direction QUIC knobs merged into one `--quic-*` set that covers dialed and accepted
# connections alike, so the relay's `--server-quic-gso` moved too. Builds in the middle of
# that rename accepted the old names, warned, and applied nothing (upstream #2913); the
# current head rejects them outright with the mapping. Detect the surface either way.
if "$MOQ" --connect https://localhost --help >/dev/null 2>&1; then
	FLAGS_NEW=1
	RELAY_GSO=(--quic-gso=false)
else
	FLAGS_NEW=0
	RELAY_GSO=(--server-quic-gso=false)
fi

PIDS=()
cleanup() {
	for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	PIDS=()
}
trap cleanup EXIT

# The publisher chain for an arm. `inject` sits ahead of `timeref` so an injected section
# is re-stamped like any other; `regulate` ahead of it so stream time tracks wall time.
publisher_chain() { # <arm>
	CHAIN=(tsp --realtime -I file "$SRC" --infinite)
	case "$1" in
	slow) CHAIN+=(-P filter --negate --pid "$TDT_PID" --stuffing
		-P inject "$TDT_BIN" --pid "$TDT_PID" --inter-packet "$IP_SLOW") ;;
	tot) CHAIN+=(-P filter --negate --pid "$TDT_PID" --stuffing
		-P inject "$TDT_BIN" "$TOT_BIN" --pid "$TDT_PID" --inter-packet "$IP_FAST") ;;
	esac
	CHAIN+=(-P regulate --pcr-synchronous -P timeref --start system -O file -)
}

echo "==> source ${BPS} bps (${PPS} pkt/s); inject every ${IP_SLOW}/${IP_FAST} packets"
echo "==> flags  $([[ $FLAGS_NEW == 1 ]] && echo '--connect-* (current)' || echo '--client-* (legacy)')"
echo

for ARM in "${ARMS[@]}"; do
	echo "=== $ARM"
	publisher_chain "$ARM"

	if [[ "$ARM" == control ]]; then
		# No MoQ: the publisher chain is the whole path, so what the instrument reads is
		# what the source transmitted.
		timeout "$SECS" "${CHAIN[@]}" 2>"$OUT/$ARM.pub.log" |
			tee "$OUT/$ARM.cap.ts" |
			timeout "$((SECS + 10))" python3 "$HERE/tdt-staleness.py" | tee "$OUT/$ARM.tdt.txt"
		cleanup
		sleep 1
		echo
		continue
	fi

	BCAST="tdt.$ARM.$$.hang"
	("$RELAY" "$TOML" "${RELAY_GSO[@]}") >"$OUT/$ARM.relay.log" 2>&1 &
	PIDS+=($!)
	FP=""
	for _ in $(seq 1 40); do
		FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
		[[ -n "$FP" ]] && break
		sleep 0.25
	done
	[[ -n "$FP" ]] || {
		echo "relay did not come up; see $OUT/$ARM.relay.log" >&2
		cleanup
		continue
	}
	if [[ $FLAGS_NEW == 1 ]]; then
		CF=(--connect-tls-fingerprint "$FP" --connect https://localhost:4443 --quic-gso=false)
	else
		CF=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)
	fi

	# Publisher first here, unlike the EIT rig: the instrument stamps arrival against wall
	# time, so a subscriber that waits for a publisher would book the wait as lateness.
	"${CHAIN[@]}" 2>"$OUT/$ARM.pub.log" |
		"$MOQ" "${CF[@]}" --broadcast "$BCAST" import ts >"$OUT/$ARM.import.log" 2>&1 &
	PIDS+=($!)
	sleep 4

	timeout "$SECS" "$MOQ" "${CF[@]}" --broadcast "$BCAST" export ts 2>"$OUT/$ARM.export.log" |
		tee "$OUT/$ARM.cap.ts" |
		timeout "$((SECS + 10))" python3 "$HERE/tdt-staleness.py" | tee "$OUT/$ARM.tdt.txt"
	cleanup
	sleep 2
	echo
done

echo "=== summary"
for ARM in "${ARMS[@]}"; do
	printf '%-9s %s\n' "$ARM" "$(tail -1 "$OUT/$ARM.tdt.txt" 2>/dev/null || echo 'no result')"
done
