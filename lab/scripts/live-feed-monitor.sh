#!/usr/bin/env bash
# Long-running health log for the standing live ingest on an EC2 host; records no media.
# Writes to $OUT (default ~/livemon/<UTC start>/):
#   tsp.log      continuity errors and bitrate alarms on the local group, timestamped by tsp
#   sample.csv   once a minute: load, CPU % of the publisher's moq and of the relay over the
#                minute, available memory, unit restart counts, MoQ bytes off the relay
#                (a 10 s subscription every EGRESS_EVERY minutes, else empty)
#   srt.log      at the end: the SRT ingest's own 5-minute statistics for the window
#
# Usage: live-feed-monitor.sh [hours]      (default 12)

set -uo pipefail

HOURS="${1:-12}"
MCAST="${MCAST:-239.255.0.1:5000}"
MIN_BPS="${MIN_BPS:-24000000}"
MAX_BPS="${MAX_BPS:-26000000}"
EGRESS_EVERY="${EGRESS_EVERY:-15}"
OUT="${OUT:-$HOME/livemon/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
START=$(date -u '+%Y-%m-%d %H:%M:%S')
END_EPOCH=$(($(date +%s) + HOURS * 3600))

MOQ_BIN=$(grep -ho "$HOME/bin-[a-zA-Z0-9._-]*/moq" /etc/systemd/system/moq-live-publisher.service | head -1)
BCAST=$(grep -ho -- '--broadcast [^ ]*' /etc/systemd/system/moq-live-publisher.service | awk '{print $2}' | head -1)
ORIGIN=$(grep -ho -- '--listen-tls-generate [^ ]*' /etc/systemd/system/moq-relay.service | awk '{print $2}' | head -1)
# A relay closed to anonymous sessions (live-auth.sh) admits the host's probe token, passed in the
# environment so that it stays out of the process list.
URL="https://$ORIGIN:443/anon"
PROBE_JWT=${PROBE_JWT:-$HOME/.moq-live/probe.jwt}
[ -r "$PROBE_JWT" ] && URL="$URL?jwt=$(cat "$PROBE_JWT")"
HZ=$(getconf CLK_TCK)

timeout "$((HOURS * 3600))" tsp --timed-log -I ip "$MCAST" --local-address 127.0.0.1 --buffer-size 8388608 \
	-P continuity \
	-P bitrate_monitor --min "$MIN_BPS" --max "$MAX_BPS" --periodic-bitrate 60 \
	-O drop >"$OUT/tsp.log" 2>&1 &
TSP_PID=$!

ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
pub_moq() { pgrep -P "$(systemctl show moq-live-publisher -p MainPID --value)" -x moq | head -1; }
restarts() { systemctl show "$1" -p NRestarts --value; }

echo "utc,load1,pub_moq_cpu_pct,relay_cpu_pct,mem_avail_mb,srt_restarts,pub_restarts,relay_restarts,egress_bytes_10s" >"$OUT/sample.csv"
PUB=$(pub_moq)
RELAY=$(systemctl show moq-relay -p MainPID --value)
P0=$(ticks "$PUB")
R0=$(ticks "$RELAY")
N=0
while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
	sleep 60
	N=$((N + 1))
	PUB_NOW=$(pub_moq)
	[ "$PUB_NOW" != "$PUB" ] && { PUB=$PUB_NOW; P0=$(ticks "$PUB"); }
	P1=$(ticks "$PUB")
	R1=$(ticks "$RELAY")
	EGRESS=""
	if [ $((N % EGRESS_EVERY)) -eq 0 ]; then
		EGRESS=$(MOQ_CONNECT=$URL timeout 10 "$MOQ_BIN" --connect-tls-insecure \
			--broadcast "$BCAST" export ts --max-age 2s 2>/dev/null | wc -c)
	fi
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$(cut -d' ' -f1 /proc/loadavg)" \
		"$(awk -v d=$((P1 - P0)) -v hz="$HZ" 'BEGIN{printf "%.1f", d / hz / 60 * 100}')" \
		"$(awk -v d=$((R1 - R0)) -v hz="$HZ" 'BEGIN{printf "%.1f", d / hz / 60 * 100}')" \
		"$(awk '/MemAvailable/{printf "%d", $2 / 1024}' /proc/meminfo)" \
		"$(restarts srt-ingest)" "$(restarts moq-live-publisher)" "$(restarts moq-relay)" "$EGRESS" >>"$OUT/sample.csv"
	P0=$P1
	R0=$R1
done

wait "$TSP_PID"
# shellcheck disable=SC2024 # reading the journal needs root; the log is ours
sudo journalctl -u srt-ingest --since "$START" --no-pager >"$OUT/srt.log"
echo "done" >"$OUT/done"
