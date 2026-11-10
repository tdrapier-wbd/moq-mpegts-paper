#!/usr/bin/env bash
# How long does `moq import ts` take to start a low-rate audio-only source that carries no random
# access indicator? moq2ts#41, asked of moq-dev (lab/cross-check.md). Loopback only.
#
# Fixtures, from the clip's first audio track (SECS of it), remuxed alone by ffmpeg, which puts the
# PCR on the audio PID: rai.ts keeps the indicators ffmpeg writes (the control), norai.ts has every
# random_access_indicator cleared. Each is fed paced at its own rate by `tsp -P regulate`.
# Runs, one each: {media, passthrough} x {rai, norai}. A subscriber (`export ts`, relaunched until
# the broadcast exists) waits first; then the import starts at t0. Prints the time after t0 of the
# output's first audio PES start (export's default 1 s delay included), or "none" by the run's end.
#
# Usage: xc-audio-start.sh OUT        env: MOQ (bin dir), CLIP, SECS (60)

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?OUT}
MOQ=${MOQ:-$HOME/bin-cd560bde-thin} CLIP=${CLIP:-$HOME/contrib-10m.ts} SECS=${SECS:-60}
M=$MOQ/moq R=$MOQ/moq-relay
# shellcheck source=moq-cli-flags.sh
. "$HERE/moq-cli-flags.sh"
moq_cli_detect "$M" "$R"
mkdir -p "$OUT" && cd "$OUT" || exit 1
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

ffmpeg -nostdin -loglevel error -y -t "$SECS" -i "$CLIP" -map 0:a:0 -c copy -f mpegts rai.ts || exit 1
python3 - <<'EOF' || exit 1
d = bytearray(open("rai.ts", "rb").read())
n = 0
for i in range(0, len(d) - 187, 188):
    if d[i + 3] & 0x20 and d[i + 4] > 0 and d[i + 5] & 0x40:
        d[i + 5] &= ~0x40
        n += 1
open("norai.ts", "wb").write(d)
print(f"fixture bytes={len(d)} rai_cleared={n}")
EOF
BITRATE=$(python3 -c "import os; print(int(os.path.getsize('rai.ts') * 8 / $SECS))")
echo "build=$(head -1 "$MOQ.sha" 2>/dev/null || echo unknown) secs=$SECS bitrate=$BITRATE" | tee meta.txt

P=$((20000 + RANDOM % 20000))
CONNECT=${MOQ_DIAL[${#MOQ_DIAL[@]} - 1]}
INSECURE=("${MOQ_DIAL[@]:0:${#MOQ_DIAL[@]}-1}")
URL="https://localhost:$P/anon"
moq_relay_public "[::]:$P" localhost --log-level info
"$R" "${RELAY_ARGV[@]}" >relay.log 2>&1 &
RP=$!
trap 'kill "$RP" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 1

run() { # <lane> <fixture>
	local lane=$1 fx=$2 name="$1-$2" bc imp=() exp=() t0 sub ip first
	bc="xc-$name"
	[ "$lane" = passthrough ] && imp=(--passthrough) exp=(--passthrough)
	rm -f "$name.first"
	(
		end=$(($(date +%s) + SECS + 15))
		while [ "$(date +%s)" -lt "$end" ] && [ ! -s "$name.first" ]; do
			RUST_LOG=info "$M" "${INSECURE[@]}" "$CONNECT" "$URL" --broadcast "$bc" export ts "${exp[@]}" 2>>"$name.export.log" |
				python3 -c 'import sys, time
f = sys.stdin.buffer
while len(p := f.read(188)) == 188:
    o = 4 + (1 + p[4] if p[3] & 0x20 else 0)
    if p[1] & 0x40 and o < 184 and p[o:o + 3] == b"\0\0\1" and 0xC0 <= p[o + 3] <= 0xDF:
        open(sys.argv[1], "w").write("%.3f\n" % time.time())
        break' "$name.first"
			sleep 0.2
		done
	) &
	sub=$!
	sleep 2
	t0=$(now)
	tsp -I file "$fx.ts" -P regulate --bitrate "$BITRATE" 2>/dev/null |
		RUST_LOG=info "$M" "${INSECURE[@]}" "$CONNECT" "$URL" --broadcast "$bc" import ts "${imp[@]}" \
			>/dev/null 2>"$name.import.log" &
	ip=$!
	wait "$sub"
	kill "$ip" 2>/dev/null
	wait "$ip" 2>/dev/null
	first=none
	[ -s "$name.first" ] && first=$(python3 -c "print(round($(cat "$name.first") - $t0, 2))")
	printf '%s\t%s\tfirst_audio_s=%s\texport_launches=%s\n' "$lane" "$fx" "$first" \
		"$(grep -c 'connected version=' "$name.export.log")" | tee -a results.tsv
}

for lane in media passthrough; do
	for fx in rai norai; do run "$lane" "$fx"; done
done
