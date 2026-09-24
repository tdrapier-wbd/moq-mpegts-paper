#!/usr/bin/env bash
# P0-e validation — does the verbatim receiver reproduce the origin's own bytes, and can it fail?
#
# A receiver used to grade carriage is only worth having if its output is the packager's output.
# That is directly testable and needs no reference implementation: the packager writes segments
# to disk, so `cat seg*.ts` IS the ground truth for what a byte-faithful receiver must produce.
# Everything here is a comparison against that hash.
#
# The fixture is VOD, not live: a finite playlist with #EXT-X-ENDLIST gives a deterministic
# segment set, so a hash mismatch is a receiver defect and never a race with the live window.
#
# Arms:
#   disk      sha256 of cat seg*.ts                        -- ground truth
#   verbatim1 hls-verbatim-recv.py over HTTP/1.1           -- must equal disk
#   verbatim3 hls-verbatim-recv.py over HTTP/3             -- must equal disk
#   tsp       tsp -I hls -O file  (byte-faithful, h1 only) -- expected to equal disk
#   ffmpeg    ffmpeg -c copy -f mpegts (the current H3 receiver) -- expected to DIFFER
#
# The last two arms are the point. `tsp` equalling disk shows the test can pass against an
# independent byte-faithful implementation; `ffmpeg` differing shows the test can fail, and
# measures how much of the segmented lane's carriage grade was previously the receiver's work.
#
# Negative controls (a test that cannot fail proves nothing):
#   corrupt   one segment byte flipped on disk -- verbatim must produce a DIFFERENT hash
#   h3-on-tcp --http-version 3 against the TCP-only vhost -- must fail, not fall back
#   fmp4      a playlist carrying #EXT-X-MAP  -- must refuse
#   hole      a segment removed from the origin -- must report a hole and exit non-zero
set -u

SRC="${SRC:-$HOME/bbb.ts}"
# A subdirectory of the existing T20 document root, so this neither needs an nginx
# change nor disturbs the live rig that owns /srv/hls itself.
HLS_DIR=/srv/hls/p0e
URLBASE=p0e
OUT="$HOME/p0e-out"
CURL="$HOME/h3/bin/curl"
FFMPEG="$HOME/h3/bin/ffmpeg"
RECV="$HOME/hls-verbatim-recv.py"
H1=8443
H3=8444
SEGDUR=2
NSEG=6

pass=0
fail=0

ok() {
	echo "  PASS  $1"
	pass=$((pass + 1))
}
no() {
	echo "  FAIL  $1"
	fail=$((fail + 1))
}

rm -rf "$OUT"
mkdir -p "$OUT"
sudo rm -rf "${HLS_DIR:?}"
sudo mkdir -p "$HLS_DIR"
sudo chown "$(id -u):$(id -g)" "$HLS_DIR"

[ -f "$SRC" ] || {
	echo "FATAL: no source clip at $SRC"
	exit 2
}

echo "=== building a VOD HLS fixture ($NSEG x ${SEGDUR}s) ==="
# No --live: the playlist keeps every segment and gets #EXT-X-ENDLIST, so the set is fixed.
tsp -I file "$SRC" -P until --seconds $((NSEG * SEGDUR)) \
	-O hls --duration "$SEGDUR" --intra-close --align-first-segment \
	--playlist "$HLS_DIR/index.m3u8" "$HLS_DIR/seg.ts" >"$OUT/pack.log" 2>&1
segs=$(find "$HLS_DIR" -name 'seg*.ts' | wc -l)
echo "segments on disk: $segs"
[ "$segs" -ge 3 ] || {
	echo "FATAL: packager produced $segs segments"
	tail -20 "$OUT/pack.log"
	exit 2
}
grep -q "EXT-X-ENDLIST" "$HLS_DIR/index.m3u8" || echo "NOTE: no ENDLIST in playlist"

# Ground truth: the packager's bytes, in playlist order.
# Read the order from the playlist rather than trusting shell glob collation.
grep -v '^#' "$HLS_DIR/index.m3u8" | sed "s|^|$HLS_DIR/|" >"$OUT/order.txt"
xargs cat <"$OUT/order.txt" >"$OUT/disk.ts"
DISK=$(sha256sum "$OUT/disk.ts" | cut -d' ' -f1)
echo "disk ground truth: $DISK  ($(stat -c%s "$OUT/disk.ts") bytes)"
echo

echo "=== arm: verbatim receiver over HTTP/1.1 ==="
python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -o "$OUT/v1.ts" \
	--http-version 1 --curl "$CURL" --insecure --seconds 60 \
	--summary "$OUT/v1.json" >"$OUT/v1.log" 2>&1
v1rc=$?
V1=$(sha256sum "$OUT/v1.ts" 2>/dev/null | cut -d' ' -f1)
echo "  rc=$v1rc sha=$V1"
if [ -n "$V1" ] && [ "$V1" = "$DISK" ]; then
	ok "verbatim/h1 is byte-identical to the packager's output"
else
	no "verbatim/h1 differs from disk"
fi

echo "=== arm: verbatim receiver over HTTP/3 ==="
python3 "$RECV" "https://127.0.0.1:$H3/$URLBASE/index.m3u8" -o "$OUT/v3.ts" \
	--http-version 3 --curl "$CURL" --insecure --seconds 60 \
	--summary "$OUT/v3.json" >"$OUT/v3.log" 2>&1
v3rc=$?
V3=$(sha256sum "$OUT/v3.ts" 2>/dev/null | cut -d' ' -f1)
echo "  rc=$v3rc sha=$V3"
if [ -n "$V3" ] && [ "$V3" = "$DISK" ]; then
	ok "verbatim/h3 is byte-identical to the packager's output"
else
	no "verbatim/h3 differs from disk"
fi
grep -c "http3=1" /var/log/nginx/h3lab.log >/dev/null 2>&1 &&
	echo "  nginx h3 requests logged: $(sudo grep -c 'http3=1' /var/log/nginx/h3lab.log 2>/dev/null || echo '?')"

echo "=== arm: tsp -I hls (independent byte-faithful implementation, h1 only) ==="
# tsp -I hls has no --insecure and does not honour CURL_CA_BUNDLE, so the lab cert must be
# in the system trust store or this arm fails on the self-signed certificate alone.
if [ ! -f /usr/local/share/ca-certificates/h3lab.crt ]; then
	sudo cp /etc/nginx/h3/cert.pem /usr/local/share/ca-certificates/h3lab.crt
	sudo update-ca-certificates >/dev/null 2>&1
fi
tsp -I hls "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -O file "$OUT/tsp.ts" >"$OUT/tsp.log" 2>&1
TSP=$(sha256sum "$OUT/tsp.ts" 2>/dev/null | cut -d' ' -f1)
echo "  sha=$TSP"
if [ "$TSP" = "$DISK" ]; then
	ok "tsp -I hls also reproduces disk -- the comparison is sound, not self-fulfilling"
else
	echo "  NOTE tsp differs from disk ($(stat -c%s "$OUT/tsp.ts" 2>/dev/null || echo 0) bytes);"
	echo "       see $OUT/tsp.log -- this is information about tsp, not a receiver failure"
fi

echo "=== arm: ffmpeg -c copy -f mpegts (the receiver P0-e exists to replace) ==="
"$FFMPEG" -hide_banner -nostdin -loglevel warning \
	-prefer_libcurl 1 -http_version 3only -tls_verify 0 \
	-i "https://127.0.0.1:$H3/$URLBASE/index.m3u8" -map 0 -c copy -f mpegts -y "$OUT/ff.ts" \
	>"$OUT/ff.log" 2>&1
FF=$(sha256sum "$OUT/ff.ts" 2>/dev/null | cut -d' ' -f1)
echo "  sha=$FF  ($(stat -c%s "$OUT/ff.ts" 2>/dev/null || echo 0) bytes vs $(stat -c%s "$OUT/disk.ts") on disk)"
if [ -s "$OUT/ff.ts" ] && [ "$FF" != "$DISK" ]; then
	ok "ffmpeg's output is NOT the wire -- the test can fail, and this is why P0-e was needed"
elif [ ! -s "$OUT/ff.ts" ]; then
	echo "  NOTE ffmpeg produced nothing; see $OUT/ff.log"
else
	no "ffmpeg matched disk, which contradicts the premise -- re-check the re-mux claim"
fi
echo

echo "=== negative control: a corrupted segment must change the hash ==="
victim=$(head -1 "$OUT/order.txt")
cp "$victim" "$OUT/victim.bak"
# Flip one byte in the payload of the second packet, away from any sync byte.
printf '\xff' | dd of="$victim" bs=1 seek=200 count=1 conv=notrunc status=none
python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -o "$OUT/corrupt.ts" \
	--http-version 1 --curl "$CURL" --insecure --seconds 60 >"$OUT/corrupt.log" 2>&1
C=$(sha256sum "$OUT/corrupt.ts" 2>/dev/null | cut -d' ' -f1)
if [ -n "$C" ] && [ "$C" != "$DISK" ]; then
	ok "one flipped byte changes the receiver's output"
else
	no "corrupting a segment did not change the output -- the receiver is not byte-faithful"
fi
cp "$OUT/victim.bak" "$victim"

echo "=== negative control: --http-version 3 must not fall back to TCP ==="
python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -o "$OUT/nofall.ts" \
	--http-version 3 --curl "$CURL" --insecure --seconds 10 >"$OUT/nofall.log" 2>&1
nf=$?
if [ "$nf" -ne 0 ] && [ ! -s "$OUT/nofall.ts" ]; then
	ok "H3 against the TCP-only vhost fails instead of silently measuring TCP"
else
	no "H3 arm fell back to TCP (rc=$nf) -- substrate claims would be unsound"
fi

echo "=== negative control: an fMP4 playlist must be refused ==="
{
	echo "#EXTM3U"
	echo "#EXT-X-TARGETDURATION:2"
	echo '#EXT-X-MAP:URI="init.mp4"'
	echo "#EXTINF:2.0,"
	echo "seg0.m4s"
	echo "#EXT-X-ENDLIST"
} >"$HLS_DIR/fmp4.m3u8"
python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/fmp4.m3u8" -o "$OUT/fmp4.ts" \
	--http-version 1 --curl "$CURL" --insecure --seconds 10 >"$OUT/fmp4.log" 2>&1
if grep -qi "fMP4" "$OUT/fmp4.log"; then
	ok "refuses fMP4 rather than emitting non-TS bytes"
else
	no "did not refuse an fMP4 playlist"
fi

echo "=== negative control: a missing segment must be reported as a hole ==="
gone=$(sed -n 2p "$OUT/order.txt")
mv "$gone" "$OUT/gone.bak"
python3 "$RECV" "https://127.0.0.1:$H1/$URLBASE/index.m3u8" -o "$OUT/hole.ts" \
	--http-version 1 --curl "$CURL" --insecure --seconds 30 \
	--summary "$OUT/hole.json" >"$OUT/hole.log" 2>&1
hrc=$?
holes=$(python3 -c "import json;print(len(json.load(open('$OUT/hole.json'))['holes']))" 2>/dev/null || echo 0)
bf=$(python3 -c "import json;print(json.load(open('$OUT/hole.json'))['byte_faithful'])" 2>/dev/null || echo "?")
if [ "$hrc" -ne 0 ] && [ "$holes" -ge 1 ] && [ "$bf" = "False" ]; then
	ok "a missing segment is reported as a hole ($holes) and marks the run not byte-faithful"
else
	no "a missing segment was concatenated over silently (rc=$hrc holes=$holes faithful=$bf)"
fi
mv "$OUT/gone.bak" "$gone"

echo
echo "================ $pass passed, $fail failed ================"
echo "artefacts in $OUT"
[ "$fail" -eq 0 ]
