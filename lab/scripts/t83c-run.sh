#!/usr/bin/env bash
# T83 Part C: the shadow of srt-send.sh's four lanes on one receiving host, graded as it runs
# (t83c-shadow.py), storing no media. Each lane is called on loopback (rx 9190, ma 9191, pt 9192,
# seg 9193, the lanes started as listeners), through TSDuck's TR 101 290 counters into the
# grader's unit parser. rx is also teed to the controls: rxcopy (rx against itself) and rxcut
# (rx through the dropper, which removes units at known places).
#
#   t83c-run.sh OUT HOURS [WARMUP_S]          run in the foreground, under nohup setsid
#
# Env: INFLUX (18390), LAT_MS (1000, each caller's SRT latency), RX_ADDR (127.0.0.1:9190, rx's listener;
#   across a path, the source host's), RX_LAT_MS (LAT_MS), RX_OPTS (more tsp -I srt options for rx, such
#   as --rcvbuf and --ffs for a latency whose bytes exceed SRT's default buffer), EVERY (997), BLACKOUT_EVERY (1800),
#   BLACKOUT (2), HOLD (60), ALLOW_APT (0; 1 starts with the host's upgrade timer enabled).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:?OUT}
HOURS=${2:?HOURS}
WARMUP=${3:-120}
INFLUX=${INFLUX:-18390}
LAT_MS=${LAT_MS:-1000}
RX_ADDR=${RX_ADDR:-127.0.0.1:9190}
RX_LAT_MS=${RX_LAT_MS:-$LAT_MS}
RX_OPTS=${RX_OPTS:-}
EVERY=${EVERY:-997}
BLACKOUT_EVERY=${BLACKOUT_EVERY:-1800}
BLACKOUT=${BLACKOUT:-2}
HOLD=${HOLD:-60}
if [ "${ALLOW_APT:-0}" != 1 ] && systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
	echo "t83c-run: apt-daily-upgrade.timer is enabled; its upgrades restart the lanes mid-run." >&2
	echo "  sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer, or ALLOW_APT=1" >&2
	exit 1
fi
S="python3 $HERE/t83c-shadow.py"
mkdir -p "$OUT"
for f in rxcopy rxcut; do
	[ -p "$OUT/$f.fifo" ] || mkfifo "$OUT/$f.fifo"
done

recv() {
	local leg=$1 addr=$2 lat=${3:-$LAT_MS} opts=${4:-}
	echo "tsp --buffer-size-mb 4 -I srt --caller $addr --transtype live --latency $lat $opts" \
		"-P influx --tr-101-290 --host-url http://127.0.0.1:$INFLUX --org lab --bucket $leg --token none" \
		"--interval 10 -O file - 2>>$OUT/$leg.tsp.log"
}

RX="$(recv rx "$RX_ADDR" "$RX_LAT_MS" "$RX_OPTS") | tee -p >($S units > $OUT/rxcopy.fifo) \
>($S drop --log $OUT/drop.log --every $EVERY --blackout-every $BLACKOUT_EVERY --blackout $BLACKOUT \
| $S units > $OUT/rxcut.fifo) | $S units"

{
	date -u +%FT%TZ
	echo "hours=$HOURS warmup=$WARMUP hold=$HOLD lat_ms=$LAT_MS rx=$RX_ADDR rx_lat_ms=$RX_LAT_MS rx_opts=$RX_OPTS every=$EVERY blackout=$BLACKOUT/$BLACKOUT_EVERY"
	tsp --version 2>&1 | head -1
	sha1sum "$HERE/t83c-shadow.py" "$HERE/t83c-run.sh"
} >"$OUT/meta.txt"

exec $S match --out "$OUT" --ref rx --influx "$INFLUX" --hold "$HOLD" --warmup "$WARMUP" --hours "$HOURS" \
	--log-units rxcopy,rxcut \
	--leg "rx=$RX" \
	--leg "rxcopy=@$OUT/rxcopy.fifo" \
	--leg "rxcut=@$OUT/rxcut.fifo" \
	--leg "ma=$(recv ma 127.0.0.1:9191) | $S units" \
	--leg "pt=$(recv pt 127.0.0.1:9192) | $S units" \
	--leg "seg=$(recv seg 127.0.0.1:9193) | $S units"
