#!/usr/bin/env bash
# Audio silence and decode errors on the source, per PID, in the content domain: events only, no media.
#
#   audio-silence-watch.sh <events.log>
#
# Decodes the audio PIDs of the local feed group with ffmpeg's silencedetect and appends each
# silence_start / silence_end and each decoder error, prefixed with the host's UTC time, to the log.
# silence_start and silence_end are in the stream's own seconds; the prefix is when ffmpeg reported
# it, silence_start arriving DURATION after the silence began. ffmpeg is restarted 5 s after any exit.
# Env: GROUP (239.255.0.1:5000), LOCAL (127.0.0.1), PIDS ("0x79 0x7B"), NOISE (-50dB), DURATION (0.5).
set -u
OUT=${1:?events log}
GROUP=${GROUP:-239.255.0.1:5000}
LOCAL=${LOCAL:-127.0.0.1}
NOISE=${NOISE:--50dB}
DURATION=${DURATION:-0.5}
read -r -a PIDS <<<"${PIDS:-0x79 0x7B}"

graph="" maps=()
for i in "${!PIDS[@]}"; do
	graph+="[0:i:${PIDS[$i]}]silencedetect@pid$((PIDS[i]))=n=$NOISE:d=$DURATION[a$i];"
	maps+=(-map "[a$i]" -f null -)
done

stamp() {
	while IFS= read -r line; do
		printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$line"
	done
}

while :; do
	echo "start pids=${PIDS[*]} noise=$NOISE d=$DURATION" | stamp >>"$OUT"
	ffmpeg -nostdin -nostats -hide_banner -loglevel info \
		-i "udp://$GROUP?localaddr=$LOCAL&fifo_size=1000000&overrun_nonfatal=1" \
		-filter_complex "${graph%;}" "${maps[@]}" 2>&1 |
		grep --line-buffered -E 'silence_(start|end)|Error|error' | stamp >>"$OUT"
	echo "ffmpeg exited" | stamp >>"$OUT"
	sleep 5
done
