#!/usr/bin/env bash
# Install the standing live-ingest chain on an EC2 host: an SRT listener that a
# contribution encoder calls, and a MoQ publisher that reads the result.
#
# The two stages are deliberately separate processes joined by a local multicast
# group rather than one fused pipeline:
#
#   stage 1  tsp -I srt --listener  ->  udp/multicast 239.255.0.1:5000 on lo
#   stage 2  tsp -I ip (that group) ->  moq import ts  ->  relay
#
# Three reasons, all of which a fused `ffmpeg | moq` or `moq import srt --listen`
# pipeline forfeits:
#
#   1. Restarting the MoQ side does not disturb the SRT session. Every experiment
#      restarts stage 2; the contribution encoder never sees it.
#   2. Stage 2's input is UDP now and can be real multicast later, so moving the
#      source from SRT to a multicast feed is a change to stage 1 only -- and when
#      the publisher sits inside the multicast domain, stage 1 disappears entirely.
#   3. The group is a tap point. A reference recorder or a TSDuck analyser can join
#      it without opening a second SRT session or perturbing the publisher.
#
# tsp is used in front of MoQ, never ffmpeg: `ffmpeg -c copy -f mpegts` re-muxes and
# its default stream selection silently discards the DVB tables, the second audio,
# teletext and every SCTE-35 PID. See lab/method-notes.md.
#
# Usage:  sudo -E ./live-srt-ingest.sh
# Env:    MOQ_BIN BROADCAST RELAY_URL SRT_PORT MCAST RCV_LATENCY TSP

set -euo pipefail

MOQ_BIN="${MOQ_BIN:?set MOQ_BIN to the moq binary this host should publish with}"
BROADCAST="${BROADCAST:?set BROADCAST to the broadcast name this host publishes}"
RELAY_URL="${RELAY_URL:-https://localhost:443/anon}"
SRT_PORT="${SRT_PORT:-9000}"
MCAST="${MCAST:-239.255.0.1:5000}"
# Our receive-latency floor. SRT uses max(our rcv-latency, caller's peer-latency),
# so the caller can raise this but not lower it. It is a floor on end-to-end delay
# and must be attributed as such in any latency figure taken downstream.
RCV_LATENCY="${RCV_LATENCY:-2000}"
TSP="${TSP:-/usr/bin/tsp}"

echo "installing live ingest: srt/:$SRT_PORT -> $MCAST -> $BROADCAST @ $RELAY_URL"

# ---------------------------------------------------------------- stage 1: SRT in
cat > /etc/systemd/system/srt-ingest.service <<UNIT
[Unit]
Description=Live SRT ingest (listener) -> local multicast, byte-faithful via tsp
Documentation=https://github.com/tdrapier/moq-mpegts-paper lab/test-4-remote-e2e-srt.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
# --multiple: when the sender peer disconnects, wait for another one and continue.
# This is what makes the listener survive an encoder restart without systemd help.
ExecStart=$TSP --realtime \\
	-I srt --listener 0.0.0.0:$SRT_PORT --multiple --transtype live \\
	       --rcv-latency $RCV_LATENCY --udp-rcvbuf 16777216 \\
	       --statistics-interval 300000 \\
	-O ip $MCAST --local-address 127.0.0.1 --enforce-burst
Restart=always
RestartSec=2
# A 24/7 unit must not be able to fill the disk through the journal.
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200

[Install]
WantedBy=multi-user.target
UNIT

# ------------------------------------------------------- stage 2: MoQ publisher
cat > /etc/systemd/system/moq-live-publisher.service <<UNIT
[Unit]
Description=MoQ publisher for the live feed (reads local multicast)
Documentation=https://github.com/tdrapier/moq-mpegts-paper lab/test-4-remote-e2e-srt.md
After=network-online.target srt-ingest.service moq-relay.service
Wants=network-online.target srt-ingest.service moq-relay.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu
ExecStart=/bin/sh -c '$TSP --realtime -I ip $MCAST --local-address 127.0.0.1 -O file - | $MOQ_BIN --client-tls-disable-verify --client-connect $RELAY_URL --broadcast $BROADCAST import ts'
Restart=always
RestartSec=5
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200

[Install]
WantedBy=multi-user.target
UNIT

# Cap the journal so a year of uptime cannot exhaust the root volume.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/cap.conf <<'JCONF'
[Journal]
SystemMaxUse=1G
JCONF
systemctl restart systemd-journald || true

systemctl daemon-reload
systemctl enable --now srt-ingest.service
systemctl enable --now moq-live-publisher.service

sleep 2
systemctl --no-pager --no-legend is-active srt-ingest.service moq-live-publisher.service
echo "installed."
