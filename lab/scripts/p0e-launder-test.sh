#!/usr/bin/env bash
# P0-e, second half — does the old receiver launder carriage defects?
#
# The byte-fidelity test (p0e-validate-receiver.sh) shows the verbatim receiver reproduces the
# origin's bytes and that `ffmpeg -c copy -f mpegts` does not. That establishes the receivers
# differ; it does not establish that the difference *changes a grade*, because that fixture is
# clean at the origin, so every arm scores zero continuity errors and zero is uninformative.
#
# This is the test that decides it. The origin is deliberately damaged: a whole number of
# 188-byte packets is excised from the middle of one segment, which is exactly the shape of a
# real carriage loss and leaves the file still packet-aligned. The origin therefore has a known,
# non-zero continuity error count, and the question becomes:
#
#   does a receiver REPORT the damage that is on the wire, or REPAIR it before grading?
#
# A receiver that repairs it makes the segmented lane ungradeable for carriage: cc_errors=0 then
# means "the receiver rebuilt the counters", not "the wire was clean", and no amount of care in
# the rest of the rig recovers the distinction.
#
# Expected: damaged origin > 0; verbatim == origin; tsp == origin; ffmpeg reports fewer.
set -u

SRC="${SRC:-$HOME/clip30.ts}"
HLS_DIR=/srv/hls/p0e-dmg
URLBASE=p0e-dmg
OUT="$HOME/p0e-launder"
CURL="$HOME/h3/bin/curl"
FFMPEG="$HOME/h3/bin/ffmpeg"
RECV="$HOME/hls-verbatim-recv.py"
H1=8443
H3=8444
SEGDUR=2
EXCISE_PACKETS="${EXCISE_PACKETS:-10}"

# tsp -P continuity reports one line per event, worded "missing N packets" -- not
# "discontinuity", which is what an earlier version of this script grepped for and why it
# scored a known-damaged origin as clean. The plugin exits 0 either way, so these lines are
# the only signal. Report both the event count and the total packets missing: excising a run
# of packets usually straddles PIDs, so one excision produces several events.
cc_count() {
	tsp -I file "$1" -P continuity -O drop 2>&1 | grep -c "continuity:" || true
}
cc_missing() {
	tsp -I file "$1" -P continuity -O drop 2>&1 |
		sed -n 's/.*missing \([0-9]*\) packets.*/\1/p' |
		awk '{s+=$1} END {print s+0}'
}

rm -rf "$OUT"
mkdir -p "$OUT"
sudo rm -rf "${HLS_DIR:?}"
sudo mkdir -p "$HLS_DIR"
sudo chown "$(id -u):$(id -g)" "$HLS_DIR"

echo "=== packaging a clean VOD fixture ==="
tsp -I file "$SRC" -O hls --duration "$SEGDUR" --intra-close --align-first-segment \
	--playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/seg.ts" >"$OUT/pack.log" 2>&1
grep -v '^#' "$HLS_DIR/index.m3u8" | sed "s|^|$HLS_DIR/|" >"$OUT/order.txt"
nseg=$(wc -l <"$OUT/order.txt")
echo "segments: $nseg"
[ "$nseg" -ge 4 ] || {
	echo "FATAL: only $nseg segments"
	exit 2
}

echo "=== damaging the origin: excising $EXCISE_PACKETS packets from mid-segment ==="
# Middle segment, middle of the file, on a 188-byte boundary so the result is still a valid
# packet sequence -- the damage is a gap in continuity counters, not a byte-alignment break.
victim=$(sed -n "$((nseg / 2))p" "$OUT/order.txt")
vsize=$(stat -c%s "$victim")
vpkts=$((vsize / 188))
cut_at=$(((vpkts / 2) * 188))
echo "victim: $(basename "$victim")  ${vpkts} packets, cutting ${EXCISE_PACKETS} at byte ${cut_at}"
dd if="$victim" of="$OUT/head.bin" bs=188 count=$((cut_at / 188)) status=none
dd if="$victim" of="$OUT/tail.bin" bs=188 skip=$((cut_at / 188 + EXCISE_PACKETS)) status=none
cat "$OUT/head.bin" "$OUT/tail.bin" >"$victim"
echo "victim now $(stat -c%s "$victim") bytes ($(($(stat -c%s "$victim") / 188)) packets)"

# Ground truth: what a byte-faithful receiver MUST produce and MUST grade.
xargs cat <"$OUT/order.txt" >"$OUT/origin.ts"
ORIGIN_CC=$(cc_count "$OUT/origin.ts")
ORIGIN_MISS=$(cc_missing "$OUT/origin.ts")
ORIGIN_SHA=$(sha256sum "$OUT/origin.ts" | cut -d' ' -f1)
echo
echo "damaged origin: $(stat -c%s "$OUT/origin.ts") bytes, $ORIGIN_CC continuity event(s), $ORIGIN_MISS packet(s) missing"
if [ "$ORIGIN_CC" -eq 0 ]; then
	echo "FATAL: excision produced no continuity error, so the test cannot discriminate."
	echo "       raise EXCISE_PACKETS and re-run."
	exit 2
fi
echo

printf '%-26s %-9s %12s %7s %8s  %s\n' RECEIVER TRANSPORT BYTES EVENTS MISSING VERDICT
printf '%-26s %-9s %12s %7s %8s  %s\n' "origin (packager)" "--" \
	"$(stat -c%s "$OUT/origin.ts")" "$ORIGIN_CC" "$ORIGIN_MISS" "ground truth"

grade() {
	local name="$1" transport="$2" file="$3"
	if [ ! -s "$file" ]; then
		printf '%-26s %-9s %12s %7s %8s  %s\n' "$name" "$transport" 0 "-" "-" "PRODUCED NOTHING"
		return
	fi
	local sz cc miss sha verdict
	sz=$(stat -c%s "$file")
	cc=$(cc_count "$file")
	miss=$(cc_missing "$file")
	sha=$(sha256sum "$file" | cut -d' ' -f1)
	if [ "$sha" = "$ORIGIN_SHA" ]; then
		verdict="byte-identical: grades the wire"
	elif [ "$miss" -lt "$ORIGIN_MISS" ]; then
		verdict="LAUNDERED: hides $((ORIGIN_MISS - miss)) of $ORIGIN_MISS lost packets"
	else
		verdict="differs from origin"
	fi
	printf '%-26s %-9s %12s %7s %8s  %s\n' "$name" "$transport" "$sz" "$cc" "$miss" "$verdict"
}

python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -o "$OUT/v1.ts" \
	--http-version 1 --curl "$CURL" --insecure --seconds 90 >"$OUT/v1.log" 2>&1
grade "hls-verbatim-recv.py" "HTTP/1.1" "$OUT/v1.ts"

python3 "$RECV" "https://127.0.0.1:$H3/$URLBASE/index.m3u8" -o "$OUT/v3.ts" \
	--http-version 3 --curl "$CURL" --insecure --seconds 90 >"$OUT/v3.log" 2>&1
grade "hls-verbatim-recv.py" "HTTP/3" "$OUT/v3.ts"

tsp -I hls "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -O file "$OUT/tsp.ts" >"$OUT/tsp.log" 2>&1
grade "tsp -I hls" "HTTP/1.1" "$OUT/tsp.ts"

"$FFMPEG" -hide_banner -nostdin -loglevel warning -prefer_libcurl 1 -http_version 3only \
	-tls_verify 0 -i "https://127.0.0.1:$H3/$URLBASE/index.m3u8" \
	-map 0 -c copy -f mpegts -y "$OUT/ff.ts" >"$OUT/ff.log" 2>&1
grade "ffmpeg -c copy -f mpegts" "HTTP/3" "$OUT/ff.ts"

echo
echo "artefacts in $OUT"
