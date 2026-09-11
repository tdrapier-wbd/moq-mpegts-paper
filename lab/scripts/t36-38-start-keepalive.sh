#!/bin/bash
# Hold a subscriber on each channel for the whole session.
#
# Between arms the last subscriber detaches, the relay cancels the upstream
# subscription as idle, and the broadcast that resumes when the next arm
# attaches did not reliably deliver — one D6 run recorded no media for that
# reason alone. A permanently attached subscriber keeps every channel hot so an
# arm measures its own lever and not the idle/resume path.
#
# It uses the broadcaster's own parent credential, so it is not one of the
# affiliates under test and cannot be revoked by an affiliate arm.
W=/tmp/t36
cd $W
FP=$(cat $W/fp.txt)
for ch in cnn tnt cnn-intl; do
  ~/bin-3529/moq --backoff-timeout 0 \
    --client-connect "https://127.0.0.1:9443/wbd?jwt=$(cat $W/tok/wbd-parent.jwt)" \
    --client-tls-fingerprint "$FP" export --broadcast "$ch" ts \
    > /dev/null 2> $W/logs/keepalive-$ch.log &
  echo "  keepalive on $ch (pid $!)"
done
wait
