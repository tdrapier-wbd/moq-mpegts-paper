#!/usr/bin/env bash
# Build a real multi-programme transport stream from three single-programme clips (T10).
#
# Unlike make-mpts-fixture.sh, which grafts a multiplex's SI onto ONE programme's media, every
# programme here carries its own media, PMT and PCR PID: three services, three PMTs, three clocks,
# one PAT and one SDT listing all three, and EIT present/following for each.
#
#   make-real-mpts.sh <out.ts> [seconds]
#
# Programme 1 is the base mux, untouched apart from the null padding that makes room for the other
# two: the real contribution feed (service 1, its own PIDs, TSID/ONID, NIT, TDT and SCTE-35).
# Programmes 2 and 3 are renumbered to services 2 and 3 and moved to PIDs 0x02xx and 0x03xx, then
# merged into the padding by `-P merge`, which restamps their PCRs to their new positions. Their
# PAT and SDT entries are added to the base mux's own tables in place by `-P pat` and `-P sdt`.
#
# Five things each broke an earlier attempt at this file:
#
# - The base is padded by exactly one null packet per input packet, so every one of its packets
#   lands at twice its original index and its PCRs stay exact at the doubled rate. A fractional
#   ratio puts up to half a packet of position error on every base PCR, which the 13-tick
#   pcrverify gate sees and would charge to whichever lane is graded against this file.
# - `--acceleration-threshold 0` on each merge. Reading a file, the merge subprocess fills the
#   queue at once, the queue crosses the default threshold (half its size), and insertion falls back
#   to "as soon as nulls are free": a 60 s mux then carries ~145 s of a merged programme, with ~1 s
#   PCR steps. With acceleration off, insertion follows each programme's own PCR.
# - Programme 3's source (vbr120.ts) carries a PCR every 80 ms, which fails the 40 ms criterion
#   before any lane touches it. It is remuxed by stream copy at a constant 1 Mb/s with a 20 ms PCR
#   period; the media is unchanged.
# - `--no-psi-merge`. Merge's own PSI merging removes the base's TDT (PID 0x14) although the help
#   text says only the merged stream's PIDs 0x00-0x1F are dropped, which leaves eitinject with no
#   clock and the fixture with no EIT; it also costs a continuity jump on the PAT and SDT when it
#   switches to its regenerated tables.
# - Merge takes a few seconds to start inserting. The first LEAD_S seconds are cut, so the fixture
#   opens with all three programmes present.
#
# The EPG is anchored to CNNiEMEA2.ts's own TDT epoch (see make-mpts-epg.py) and eitinject follows
# the TDT in the stream, so P1 must be that clip from its start or the p/f table is empty.
#
# By default the three programmes keep their own, unrelated clocks, as programmes from independent
# encoders do: programme 1's PCR starts near 25,631 s and the other two near 3 s. P2_OFFSET and
# P3_OFFSET (seconds) re-time programme 2 or 3 onto another clock by stream-copy remux with
# ffmpeg's -output_ts_offset, which shifts PTS, DTS and PCR together. With the values below the
# three clocks start within a second of each other, the common-clock variant T10 uses as a
# discriminator:
#
#   P2_OFFSET=25630.87 P3_OFFSET=25628.83 make-real-mpts.sh <out.ts> 60
#
# Tighter alignment is not reachable this way: when merge starts inserting varies by up to ~0.8 s
# from build to build, so the same offsets land a programme's clock anywhere in that window. For the
# same reason two builds are not byte-identical, even with identical arguments; the recipe
# reproduces the structure, and a run is identified by its fixture's md5.
#
# Env: P1, P2, P3 (source clips), P2_OFFSET, P3_OFFSET, LEAD_S (default 6), EPG_STEP (seconds per
# EIT event; default 20, so p/f rolls inside a one-minute window), EPG_EVENTS (default 8).

set -euo pipefail

OUT="${1:?usage: make-real-mpts.sh <out.ts> [seconds]}"
SECS="${2:-60}"
P1="${P1:-$HOME/CNNiEMEA2.ts}"
P2="${P2:-$HOME/t12_2mbps_vidonly.ts}"
P3="${P3:-$HOME/vbr120.ts}"
LEAD_S="${LEAD_S:-6}"
EPG_STEP="${EPG_STEP:-20}"
EPG_EVENTS="${EPG_EVENTS:-8}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "$(dirname "$OUT")/.mkmpts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for f in "$P1" "$P2" "$P3"; do
	[[ -r "$f" ]] || {
		echo "source clip not readable: $f" >&2
		exit 1
	}
done
command -v ffmpeg >/dev/null || {
	echo "ffmpeg is needed to re-grid programme 3's PCR" >&2
	exit 1
}

R1=$(tsp -I file "$P1" -P until --packets 200000 -P analyze --normalized -O drop 2>/dev/null |
	sed -n 's/^ts:.*:pcrbitrate=\([0-9]*\):.*/\1/p' | head -1)
[[ -n "$R1" ]] || {
	echo "could not derive the PCR bitrate of $P1" >&2
	exit 1
}
LEAD=$((2 * R1 * LEAD_S / 8 / 188))
NPKT=$((2 * R1 * SECS / 8 / 188))
echo "P1 ${R1} b/s; padded mux $((2 * R1)) b/s; ${SECS}s = ${NPKT} packets after a ${LEAD_S}s lead-in"

# Stage 1: the base, padded 1:1 and cut to length, so stage 2 reads a file whose PCR-derived rate
# is the padded one rather than trusting tsp to account for input stuffing.
tsp --add-input-stuffing 1/1 -I file "$P1" -P until --packets $((LEAD + NPKT)) -O file "$WORK/base.ts"

# Programme 3 on a 20 ms PCR grid. ffmpeg keeps PMT 0x1000 and ES 0x0100/0x0101, as remapped below.
ffmpeg -v error -y -i "$P3" -t $((LEAD_S + SECS + 10)) -map 0 -c copy \
	-f mpegts -muxrate 1000000 -pcr_period 20 ${P3_OFFSET:+-output_ts_offset "$P3_OFFSET"} "$WORK/p3.ts"

if [[ -n "${P2_OFFSET:-}" ]]; then
	ffmpeg -v error -y -i "$P2" -t $((LEAD_S + SECS + 10)) -map 0 -c copy \
		-f mpegts -muxrate 2100000 -pcr_period 20 -output_ts_offset "$P2_OFFSET" "$WORK/p2.ts"
	P2="$WORK/p2.ts"
fi

python3 "$HERE/make-mpts-epg.py" 3 "$EPG_STEP" "$EPG_EVENTS" "$WORK/epg.xml"

# Stage 2: merge programmes 2 and 3 (svrename sets the program_number in each PMT), list them in
# the base's PAT and SDT with EIT p/f flagged for all three, drop the lead-in, inject EIT p/f from
# the remaining padding, and cut to length.
tsp -I file "$WORK/base.ts" \
	-P merge --no-psi-merge --acceleration-threshold 0 \
	"tsp -I file $P2 -P svrename 1 --id 2 -P remap 0x1000=0x0200 0x0100=0x0211" \
	-P merge --no-psi-merge --acceleration-threshold 0 \
	"tsp -I file $WORK/p3.ts -P svrename 1 --id 3 -P remap 0x1000=0x0300 0x0100=0x0311 0x0101=0x0312" \
	-P pat --add-service 2/0x0200 --add-service 3/0x0300 \
	-P sdt --service-id 1 --eit-pf 1 \
	-P sdt --service-id 2 --name 'T10 Video-only' --provider 'T10 Lab' --type 1 --eit-pf 1 --running-status 4 \
	-P sdt --service-id 3 --name 'T10 AV' --provider 'T10 Lab' --type 1 --eit-pf 1 --running-status 4 \
	-P skip "$LEAD" \
	-P eitinject --files "$WORK/epg.xml" --wait-first-batch --actual-pf \
	-P until --packets "$NPKT" \
	-O file "$OUT"

echo
echo "==> $OUT"
tsp -I file "$OUT" -P analyze --normalized -O drop 2>/dev/null |
	awk -F: '/^ts:/ { for (i = 1; i <= NF; i++) if ($i ~ /^(services|pcrpids|pids|bitrate|pcrbitrate)=/) printf "%s ", $i; print "" }
		/^service:/ { for (i = 1; i <= NF; i++) if ($i ~ /^(id|pmtpid|pcrpid|pidlist|name)=/) printf "%s ", $i; print "" }'
echo "continuity events: $(tsp -I file "$OUT" -P continuity -O drop 2>&1 | grep -c 'missing [0-9]* packets' || true)"
tsp -I file "$OUT" -P pcrverify --absolute --jitter-max 13 -O drop 2>&1 | tail -1
