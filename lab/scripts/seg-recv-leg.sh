#!/usr/bin/env bash
# One receiver leg of the segmented lane: b8-hls-recv.py fetches the playlist's segments in order
# and hands them, through a pipe, to mpegts-pacer, which sends stream-clocked RTP. Two legs with the
# same SSRC and sequence seed make an ST 2022-7 pair. Run by seg-recv@.service from
# /etc/seg/recv-<leg>.env, or by hand with the same variables set.
#
#   SEG_URL       the media playlist (required)
#   SEG_HEADER    one request header, 'Name: value' (a CDN's viewer secret)
#   SEG_DEST      host:port the RTP goes to (127.0.0.1:5100)
#   SEG_RATE      the pacer's output rate, b/s (26000000)
#   SEG_LAT_MS, SEG_CAP_MS   the pacer's latency and its ceiling (8000, 14000)
#   SEG_RELEASE_MS  hold each dated segment to its program date-time plus this (unset: no hold)
#   SEG_ALIGN_MS    watch the input this long before starting the output clock (unset: start at once)
#   SEG_SSRC      the RTP SSRC, the same on both legs (538968071)
#   PACER, B8     the binaries (/opt/seg/mpegts-pacer, /opt/seg/b8-hls-recv.py)
#
# Either process ending ends the leg, so its unit restarts both, and the fetcher rejoins at the
# live edge. Logs go to stderr (the journal under systemd).
set -euo pipefail

: "${SEG_URL:?SEG_URL is required}"
B8=${B8:-/opt/seg/b8-hls-recv.py}
PACER=${PACER:-/opt/seg/mpegts-pacer}

fetch=(python3 "$B8" "$SEG_URL" - --seconds 0)
[ -n "${SEG_HEADER:-}" ] && fetch+=(--header "$SEG_HEADER")
[ -n "${SEG_RELEASE_MS:-}" ] && fetch+=(--release-ms "$SEG_RELEASE_MS")

pace=("$PACER" "${SEG_DEST:-127.0.0.1:5100}" "${SEG_RATE:-26000000}" --rtp --ssrc "${SEG_SSRC:-538968071}"
	--stream-clock --sequence-seed 0 --latency-ms "${SEG_LAT_MS:-8000}" --max-latency-ms "${SEG_CAP_MS:-14000}"
	--stall-ms 1000 --on-stall mute --stats-interval-ms 10000)
[ -n "${SEG_ALIGN_MS:-}" ] && pace+=(--align-ms "$SEG_ALIGN_MS")

"${fetch[@]}" | "${pace[@]}"
