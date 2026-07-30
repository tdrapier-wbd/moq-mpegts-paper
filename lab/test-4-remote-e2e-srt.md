# T4 — Remote relay end-to-end + SRT contribution (public internet)

## Objective

Put the path over the **public internet** with a cloud relay on AWS EC2 and exercise the full live
contribution chain — local TS → FFmpeg SRT → EC2 SRT-receiver → MoQ publisher (EC2) → MoQ relay
(EC2) → MoQ subscriber (local) → TSDuck/ffplay. Confirm (a) the relay is reachable over a real QUIC
path (loss, jitter, RTT) rather than loopback, and (b) a live SRT contribution feed can traverse the
whole chain to a conformant local egress — the bridge between "works on localhost" (T2/T3) and
"works on the wire" (T7).

> The EC2 host IP is `<EC2_IP>` throughout (real value in `INSTRUCTIONS.local.md`).

## Environment

- **Deployed cloud path = the `moq-dev` media-aware lane, not the opaque lane.** SSH inspection
  established this as a material fact: the relay is `moq-relay` (moq-lite-04, UDP 443) and both
  publishers use `moq import ts` (a loop and the SRT-fed live broadcast). The opaque `moq_publisher`
  is present on the box but its systemd service line is commented out.
- EC2 services (already running; relay never restarted during this test):
  - `moq-relay.service` → `moq-relay --server-bind 0.0.0.0:443 --tls-generate … --auth-public`
  - `moq-publisher.service` → `ffmpeg -i "srt://0.0.0.0:9000?mode=listener&latency=6000…" -c copy -f
    mpegts - | moq … import ts --broadcast cnn.international.emea.live.hang`
- Local: `moq-dev` `moq` client; SRT-capable FFmpeg is the local `~/FFmpeg` build (not OS FFmpeg);
  TSDuck 3.44-4676. Run 2026-07-22.
- TLS verification disabled (`--client-tls-disable-verify`) for the relay's self-signed cert — a lab
  convenience, not a production posture.

## Procedure

```bash
# A. remote subscribe — media-aware loop (T2 over the wire), captured for TSDuck
./moq --client-tls-disable-verify --client-connect https://<EC2_IP>:443/anon \
  --broadcast cnn.international.emea.loop.hang export ts --latency-max 5s > remote_ma_out.ts
tsp -I file remote_ma_out.ts -P analyze -O drop   # + continuity, pcrextract per lab/README.md

# B. full SRT contribution chain. Local ~/FFmpeg transcodes to a rate that fits the home uplink
#    (2 Mbps stable; 3.5 Mbps saturated it), pushes SRT to the EC2 receiver → EC2 media-aware
#    publisher → cnn.…live.hang. Match SRT latency to the listener (6000 ms).
~/FFmpeg/ffmpeg -re -i ~/testloop_clean.ts -map 0:v:0 -map 0:a:0 \
  -c:v h264_videotoolbox -b:v 2000k -maxrate 2000k -bufsize 2000k -profile:v high -g 50 -bf 0 -realtime 1 \
  -c:a copy -f mpegts "srt://<EC2_IP>:9000?mode=caller&latency=6000&peerlatency=6000&sndbuf=8388608"

# subscribe back locally to the live SRT-fed broadcast, capture for TSDuck
./moq --client-tls-disable-verify --client-connect https://<EC2_IP>:443/anon \
  --broadcast cnn.international.emea.live.hang export ts --latency-max 5s > t4_live_out.ts
tsp -I file t4_live_out.ts -P analyze -O drop     # + continuity, pcrextract per lab/README.md

# C. opaque remote (T3 over the wire) — NOT runnable on this EC2: the opaque publisher is not
#    deployed there, so this leg was not executed:
# moq_subscriber --output-protocol tcp --playout-bind 127.0.0.1:5002 --no-pacing \
#   --broadcast mpegts --track ts https://<EC2_IP>:443/anon
```

## Results

Three SRT runs were taken. Run 1 (3.5 Mbps) delivered ~3.3 MB then the home uplink dropped the SRT
link (`code=24`) — the access-link constraint, not the transport. Run 3 (2 Mbps, matched SRT
latency) was stable; figures below are from run 3.

| Metric | Media-aware loop subscribe (T2 over wire) | Live SRT chain → media-aware (T4) |
|---|---|---|
| Relay reachable over internet | yes (moq-lite-04; connect ~125 ms RTT) | yes (same relay/service) |
| Broadcast | `cnn.…loop.hang` (catalog + `0.avc3` + `0.mp2`) | `cnn.…live.hang` (catalog + `0.avc3` + `0.aac`) |
| SRT contribution leg (local → EC2:9000) | n/a | **works** — caller connected, feed delivered end-to-end |
| Captured egress | 24.2 MB / ~22 s | **10.3 MB / ~48 s** |
| Continuity-counter errors (P1) | **0** | **0** |
| Transport Stream Id | 0x0001 | 0x0001 |
| Service name / SI | lost (unknown/Undefined; SDT/NIT/TDT dropped) | lost (unknown/Undefined) |
| PMT PID | renumbered → 0x1000 | renumbered → 0x1000 |
| PCR PID | 0x0100 | 0x0100 |
| Egress bitrate | ~2.5 Mbps | ~1.66 Mbps (transcoded feed) |
| Encoded PCR interval min/mean/max | 33 / 34.98 / 319.98 ms | **40.00 / 40.00 / 40.00 ms** |
| PCR intervals > 40 ms | 13.21 % | **0 %** (n=1235) |

A live SRT contribution feed traversed the whole chain with **0 CC errors** and the media-aware
fingerprint intact (SI stripped, PMT → 0x1000, service Undefined). QUIC carried the media losslessly;
the non-transparency is the *lane*, not the network, exactly as local T2 predicted. This EC2 build
predates PR #2440, so the SI/PMT/TSID rows reflect the pre-#2440 media-aware lane.

Full-rate confirmation is in [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (clean path): the same
media-aware lane pulled the full ~9.93 Mbps `CNNiEMEA2.ts` loop home over QUIC at **9.48 Mbps
sustained for 4 min, 0 CC** — the low Mbps here was the source (SRT-latency/uplink-limited), not the
transport.

## Observations

- **On PCR cadence:** the media-aware lane transports whatever PCR spacing the encoder produced — it
  neither adds nor corrects broadcast-grade cadence. The CNN loop's native variable PCR came through
  with 13.2 % of intervals > 40 ms; our regular-GOP transcode produced a flat 40 ms grid (0 %).
  Neither is evidence of the lane *fixing* timing; both reflect the source. Timing conformance is a
  groomer/egress responsibility (T7), not something the transport supplies.
- **The opaque lane is not deployed on EC2** (its service unit line is commented out), so
  T3-over-the-wire was not runnable — a **deployment** gap, not a transport gap. Because the opaque
  lane is byte-transparent on loopback (T3) and QUIC is lossless over the wire here (0 CC), the
  opaque-remote result is expected to match T3.
- **Home uplink < 10 Mbps sustained**, so a full-rate mux cannot be *published* from the local end;
  the SRT leg was transcoded (`h264_videotoolbox`). 3.5 Mbps dropped after ~30 s; 2 Mbps was stable.
  Publish-side figures are bounded by the access link, and the SRT transcode is not byte-transparent
  (that is T3's claim, not T4's).
- **EC2 restored as found.** Relay service never stopped (same PID throughout); the SRT publisher
  auto-restarts on SRT EOF (normal) and was left active. No processes left running by this test.

## Conclusion

The media-aware end-to-end chain over the public internet is **complete**: live SRT contribution →
EC2 → MoQ publish → relay → local subscribe, 0 CC. This closes the "works on the wire" milestone for
the deployed lane. Opaque-remote (T3 over the wire) is a deployment step, not a code gap. Recorded as
a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §1.

## References

- Deployed cloud path and end-to-end result: [`docs/evidence.md`](../docs/evidence.md) §1.
- Full-rate confirmation: [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md).
- Media-aware fingerprint origin: [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md).
