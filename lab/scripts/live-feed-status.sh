#!/usr/bin/env bash
# One-command health check for the standing live ingest on an EC2 host.
# Answers, in order: is the SRT listener up, is a caller connected, is the local
# group carrying a stream, at what rate, with what PIDs, and is MoQ publishing it.
#
# Usage: ./live-feed-status.sh [seconds]      (default 10)

set -uo pipefail

SECS="${1:-10}"
MCAST="${MCAST:-239.255.0.1:5000}"
SRT_PORT="${SRT_PORT:-9000}"
TSP="${TSP:-/usr/bin/tsp}"

echo "=== units ==="
for u in srt-ingest moq-live-publisher moq-relay; do
	printf '  %-22s %-10s restarts=%s\n' "$u" \
		"$(systemctl is-active "$u" 2>/dev/null || echo absent)" \
		"$(systemctl show "$u" -p NRestarts --value 2>/dev/null || echo -)"
done

echo "=== srt listener ==="
if ss -lnup 2>/dev/null | grep -q ":$SRT_PORT "; then
	echo "  listening on udp/$SRT_PORT"
else
	echo "  NOT listening on udp/$SRT_PORT"
fi
# Whether a caller is attached is not visible in `ss`: libsrt multiplexes every
# session onto the one bound UDP socket, so a connected peer creates no second
# socket. Stream presence on the local group below is the liveness signal.

echo "=== local group $MCAST, sampling ${SECS}s ==="
CAP=$(mktemp /tmp/feedstat.XXXXXX.ts)
timeout "$((SECS + 3))" "$TSP" -I ip "$MCAST" --local-address 127.0.0.1 \
	-P until --seconds "$SECS" -O file "$CAP" >/dev/null 2>&1 || true

BYTES=$(stat -c%s "$CAP" 2>/dev/null || echo 0)
if [ "$BYTES" -lt 100000 ]; then
	echo "  NO STREAM on the group ($BYTES bytes in ${SECS}s)"
	rm -f "$CAP"
	exit 1
fi

echo "  captured $BYTES bytes in ${SECS}s => $(awk -v b="$BYTES" -v s="$SECS" 'BEGIN{printf "%.2f Mb/s", (b*8)/(s*1000000)}')"
echo "  PIDs: $("$TSP" -I file "$CAP" -P analyze --normalized -O drop 2>/dev/null |
	sed -nE 's/^pid:.*pid=([0-9]+).*/\1/p' | sort -n | tr '\n' ' ')"
echo "  continuity errors: $("$TSP" -I file "$CAP" -P continuity -O drop 2>&1 | grep -ci 'discontinuity' | head -1)"
echo "  services: $("$TSP" -I file "$CAP" -P analyze --normalized -O drop 2>/dev/null |
	sed -nE 's/^service:.*name=([^:]*).*/\1/p' | head -3 | tr '\n' ' ')"
rm -f "$CAP"
