#!/usr/bin/env bash
# T77's cell on a receiving host (lab/test-77-*.md): the multi-programme segments through CloudFront.
# Fetches the playlist, then every listed segment twice with the viewer header, and writes OUT/:
# fetches.tsv (fetch, segment, HTTP code, bytes, SHA-1, Content-Type, Content-Encoding, X-Cache,
# time to first byte in ms), egress.ts (the first fetches concatenated) and, given the origin's
# digests (ORIGIN_SHA1: "SHA-1  seg-K.ts" lines), mismatches.txt.
#
#   t77-mpts-cell.sh URL KEY_FILE OUT [ORIGIN_SHA1]
set -uo pipefail
URL=${1:?usage: t77-mpts-cell.sh URL KEY_FILE OUT [ORIGIN_SHA1]}
KEY_FILE=$2
OUT=$3
ORIGIN=${4:-}
mkdir -p "$OUT"
hdr="X-P59-Key: $(cat "$KEY_FILE")"
base=${URL%/*}/
curl -s -H "$hdr" "$URL" >"$OUT/index.m3u8"
mapfile -t segs < <(grep -E '^seg-[0-9]+\.ts$' "$OUT/index.m3u8")
echo "${#segs[@]} segments listed"
: >"$OUT/fetches.tsv"
: >"$OUT/egress.ts"
for pass in 1 2; do
	for s in "${segs[@]}"; do
		w=$(curl -s -H "$hdr" -D "$OUT/h.txt" -o "$OUT/body.ts" -w '%{http_code}\t%{size_download}\t%{time_starttransfer}' "$base$s")
		sha=$(sha1sum "$OUT/body.ts" | cut -d' ' -f1)
		ct=$(grep -i '^content-type:' "$OUT/h.txt" | cut -d' ' -f2- | tr -d '\r')
		ce=$(grep -i '^content-encoding:' "$OUT/h.txt" | cut -d' ' -f2- | tr -d '\r')
		xc=$(grep -i '^x-cache:' "$OUT/h.txt" | cut -d' ' -f2- | tr -d '\r')
		IFS=$'\t' read -r code size ttfb <<<"$w"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.1f\n' "$pass" "$s" "$code" "$size" "$sha" "$ct" "${ce:--}" "$xc" \
			"$(awk -v t="$ttfb" 'BEGIN {print t * 1000}')" >>"$OUT/fetches.tsv"
		[ "$pass" = 1 ] && cat "$OUT/body.ts" >>"$OUT/egress.ts"
	done
done
rm -f "$OUT/h.txt" "$OUT/body.ts"
if [ -n "$ORIGIN" ]; then
	awk -F'\t' 'NR == FNR {o[$2] = $1; next} o[$2] != $5 {print "fetch " $1 " " $2 ": " $5 " vs origin " o[$2]}' \
		<(awk '{print $1 "\t" $2}' "$ORIGIN") "$OUT/fetches.tsv" >"$OUT/mismatches.txt"
	echo "mismatches: $(wc -l <"$OUT/mismatches.txt")"
fi
awk -F'\t' '{n[$1]++; b[$1] += $4; if ($3 != 200) e[$1]++; if ($7 != "-") enc[$1]++; c[$1 " " $8]++}
	END {for (p in n) printf "fetch %s: %d segments, %d bytes, %d not 200, %d encoded\n", p, n[p], b[p], e[p], enc[p];
		for (k in c) print "  X-Cache " k ": " c[k]}' "$OUT/fetches.tsv"
