#!/usr/bin/env bash
# T19 — verify upstream #2967 (the TS exporter's PCR grid) at the exporter's own
# output, with no groomer in the path.
#
#   t19-pcr-grid.sh <moq> <moq-relay> <relay.toml> <src.ts> <out-dir> <seconds>
#
# #2967 replaced the per-PES-unit PCR (sampled from the reordered decode clock,
# which is what T18 measurement 6 diagnosed) with adaptation-field-only PCR
# packets on an absolute 25 ms grid. The claim is a property of `moq export ts`,
# so it has to be graded on the exporter's *own* bytes: putting a groomer in the
# path measures the pair, and this campaign's groomer regenerates PCR, so it
# would mask or manufacture the result either way.
#
# What is graded here, all in the file domain on the captured export:
#   - PCR repetition interval distribution, against the 40 ms P1 gate
#   - whether the PCR now rides payload-less packets, and on which PID
#   - continuity, because the fix relies on ISO 13818-1 2.4.3.3 (a packet with
#     no payload must not advance the continuity counter) and a receiver that
#     disagrees sees the stream as broken
#   - the reserved-bit conformance the PR says it had to hand-write
#
# Background processes do not survive between tool invocations here, so the
# relay, publisher and subscriber all start and stop inside one run.
set -uo pipefail

MOQ=${1:?moq binary}
RELAY=${2:?moq-relay binary}
TOML=${3:?relay toml}
SRC=${4:?source .ts}
OUT=${5:?output dir}
SECS=${6:-60}

VPID=${VPID:-111}
WAITMIN=${WAITMIN:-5}
BCAST=${BCAST:-t19.grid.hang}
MOQLAT=${MOQLAT:-3s}

mkdir -p "$OUT"
CAP="$OUT/export.ts"

set -m
PIDS=()
cleanup() {
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
	done
	sleep 0.5
	for p in ${PIDS+"${PIDS[@]}"}; do
		kill -KILL -- "-$p" 2>/dev/null || true
	done
	wait 2>/dev/null || true
}
trap cleanup EXIT

cp "$TOML" "$OUT/relay.toml"
(cd "$OUT" && exec "$RELAY" relay.toml --server-quic-gso=false) >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
PIDS+=("$RELAY_PID")

FP=""
for _ in $(seq 1 40); do
	FP="$(curl -s http://localhost:4443/certificate.sha256 || true)"
	[ -n "$FP" ] && break
	sleep 0.25
done
[ -n "$FP" ] || {
	echo "relay did not come up; see $OUT/relay.log" >&2
	exit 1
}
# A fingerprint proves *a* relay holds the port, not that it is ours: a leaked
# relay from an earlier run would otherwise label this capture with the wrong
# build, which is the one error this experiment cannot survive.
kill -0 "$RELAY_PID" 2>/dev/null || {
	echo "our relay exited but :4443 answered: another relay holds the port." >&2
	exit 1
}

C=(--client-tls-fingerprint "$FP" --client-connect https://localhost:4443 --client-quic-gso=false)

# Subscriber first: reservation gating publishes the catalog once tracks resolve.
timeout "$((SECS + 5))" "$MOQ" "${C[@]}" --broadcast "$BCAST" export ts \
	--latency-max "$MOQLAT" >"$CAP" 2>"$OUT/export.log" &
SUB=$!
PIDS+=("$SUB")
sleep 2

(tsp --realtime -I file "$SRC" --infinite \
	-P regulate --pcr-synchronous --wait-min "$WAITMIN" -O file - |
	"$MOQ" "${C[@]}" --broadcast "$BCAST" import ts) >"$OUT/import.log" 2>&1 &
PUB=$!
PIDS+=("$PUB")

sleep 3
kill -0 "$PUB" 2>/dev/null || {
	echo "publisher exited early:" >&2
	cat "$OUT/import.log" >&2
	exit 1
}

echo "==> capturing ${SECS}s of exporter output to $CAP"
wait "$SUB" 2>/dev/null
sleep 1

[ -s "$CAP" ] || {
	echo "no export captured; see $OUT/export.log" >&2
	exit 1
}

echo
echo "=== $(basename "$OUT"): $("$MOQ" --version) ==="
# `wc -c` pads its output on BSD/macOS, so print it as a number rather than a string.
CAPBYTES=$(wc -c <"$CAP")
printf 'capture %d bytes (%d TS packets)\n' "$CAPBYTES" "$((CAPBYTES / 188))"

# Continuity. The fix depends on ISO 13818-1 2.4.3.3 -- a packet carrying no
# payload must not advance the continuity counter -- so a non-zero count here is
# either the exporter breaking that rule or the analyser disagreeing about it,
# and the two are distinguished by which PID the errors land on.
echo
echo "--- continuity ---"
tsp -I file "$CAP" -P continuity -O drop 2>&1 | grep -E 'missing .* packets|discontinuity' | head -8
CC=$(tsp -I file "$CAP" -P continuity -O drop 2>&1 | grep -cE 'missing .* packets|discontinuity' || true)
echo "continuity events: $CC"

# PCR repetition, the gate #2967 exists to clear.
tsp -I file "$CAP" -P pcrextract --pcr --csv -o "$OUT/pcr.csv" -O drop >/dev/null 2>&1 || true
echo
echo "--- PCR repetition (file domain) ---"
awk -F, 'NR>1 && $4=="PCR"{c=$6;if(p!=""){d=(c-p)/27000;n++;s+=d;
  if(d>40)o++; if(d>mx)mx=d; if(mn==""||d<mn)mn=d; if(d<1)sub1++;
  b=int(d/5); h[b]++}
  p=c}
END{printf "PCRs %d, mean %.3f ms, min %.3f, max %.1f ms\n", n+0, s/n, mn, mx;
  printf "intervals >40 ms: %d (%.2f%%)   <1 ms: %d (%.2f%%)\n", o+0, 100*o/n, sub1+0, 100*sub1/n;
  print "histogram (5 ms bins, count):";
  for(i=0;i<=12;i++) if(h[i]) printf "  [%2d-%2d ms) %d\n", i*5, i*5+5, h[i];
  }' "$OUT/pcr.csv"

# Does the PCR now ride payload-less packets, and only on the announced PID?
echo
echo "--- PCR carriage: PID and packet shape ---"
python3 - "$CAP" <<'PY'
import sys, collections
path = sys.argv[1]
pcr_pids = collections.Counter()
shape = collections.Counter()
cc_by_pid = {}
adapt_only_cc_advance = 0
with open(path, 'rb') as f:
    while True:
        p = f.read(188)
        if len(p) < 188 or p[0] != 0x47:
            break
        pid = ((p[1] & 0x1F) << 8) | p[2]
        afc = (p[3] >> 4) & 0x3
        cc = p[3] & 0x0F
        has_payload = afc in (1, 3)
        has_adapt = afc in (2, 3)
        pcr_here = False
        if has_adapt and p[4] > 0 and (p[5] & 0x10):
            pcr_here = True
        if pcr_here:
            pcr_pids[pid] += 1
            shape['adaptation-only (no payload)' if afc == 2 else 'adaptation+payload'] += 1
        # continuity discipline on payload-less packets
        if pid in cc_by_pid and not has_payload:
            if cc != cc_by_pid[pid]:
                adapt_only_cc_advance += 1
        if has_payload:
            cc_by_pid[pid] = cc
        elif pid not in cc_by_pid:
            cc_by_pid[pid] = cc
print("PCR packets by PID:", dict(pcr_pids))
print("PCR packet shape:", dict(shape))
print("payload-less packets that advanced the continuity counter:", adapt_only_cc_advance,
      "(ISO 13818-1 2.4.3.3 requires 0)")
PY

# The PR says the mpeg2ts serializer writes the six reserved PCR bits as zeros
# where ISO 13818-1 requires ones, and that it hand-writes them. Check the wire.
echo
echo "--- reserved bits in the PCR field (ISO 13818-1 requires all six set) ---"
python3 - "$CAP" <<'PY'
import sys, collections
path = sys.argv[1]
seen = collections.Counter()
with open(path, 'rb') as f:
    while True:
        p = f.read(188)
        if len(p) < 188 or p[0] != 0x47:
            break
        afc = (p[3] >> 4) & 0x3
        if afc not in (2, 3) or p[4] == 0 or not (p[5] & 0x10):
            continue
        # adaptation field: p[4]=len, p[5]=flags, PCR at p[6..12)
        # 33-bit base, 6 reserved bits, 9-bit extension
        b = p[6:12]
        reserved = ((b[4] & 0x7E) >> 1)
        seen['reserved=0x%02X' % reserved] += 1
print(dict(seen), '  (0x3F == all six set, conformant)')
PY

echo
echo "artefacts in $OUT"
