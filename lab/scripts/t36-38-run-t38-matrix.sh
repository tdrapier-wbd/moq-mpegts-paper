#!/bin/bash
# T38 Part 1: the WHOLE licensing matrix, every affiliate against every channel.
# Not a sample: a matrix enforced correctly on the diagonal and wrong in one
# off-diagonal cell is exactly the failure this is looking for.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
SECS="${SECS:-5}"
OUT=$W/matrix-results.tsv
: > $OUT

CHANNELS="cnn cnn-intl tnt nobody"
# affiliate label : token file : kid
AFFS="A:affa:affakey B:affb:affbkey C:affc:affckey D:affd:affdkey E-cnn:affe-cnn:affecnnkey E-tnt:affe-tnt:affetntkey F:afff:afffkey"

printf "  %-7s" "aff\\ch"; for c in $CHANNELS; do printf "%-11s" "$c"; done; echo
for spec in $AFFS; do
  lbl=$(echo $spec | cut -d: -f1); tok=$(echo $spec | cut -d: -f2); kid=$(echo $spec | cut -d: -f3)
  printf "  %-7s" "$lbl"
  for ch in $CHANNELS; do
    id="M-$lbl-$ch"
    timeout $SECS ~/bin-3529/moq --backoff-timeout 100ms \
      --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/$tok.jwt)" \
      --client-tls-fingerprint "$FP" export --broadcast "$ch" ts \
      > $W/out/$id.bin 2> $W/logs/$id.log
    b=$(stat -f%z $W/out/$id.bin 2>/dev/null || echo 0)
    if [ "$b" -gt 0 ]; then printf "%-11s" "DELIVER"; v=deliver; else printf "%-11s" "refuse"; v=refuse; fi
    printf "%s\t%s\t%s\t%s\t%s\n" "$lbl" "$kid" "$ch" "$v" "$b" >> $OUT
  done
  echo
done
echo
echo "matrix -> $OUT"
