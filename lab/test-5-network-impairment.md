# T5 — Network impairment

## Objective

Characterise end-to-end behaviour — throughput, recovery, continuity, timing — as a function of
controlled latency, loss, jitter and reordering injected with Linux `tc`/`netem`, on both lanes, and
identify the operating envelope within which each lane stays usable. A second aim: establish *which
metric actually reveals damage* on each lane, since the two fail very differently.

## Environment

- **Media-aware lane over the real EC2→home internet path.** Impairment applied on the EC2 `ens5`
  egress, filtered to the QUIC media flow only (UDP sport 443 → the subscriber's home IP), so the SSH
  control channel is never impaired. Media-aware lane uses the standing EC2 loop
  (`cnn.international.emea.loop.hang`, `moq export ts --latency-max 5s`).
- **Opaque lane built/deployed on the EC2 and measured on a controlled loopback path** (2026-07-17).
  The `moq-publisher-subscriber` source was compiled on EC2 (`aws-lc-rs` backend, `moq-transport`
  0.14.2; a 4 GB swap file added to survive the build on the 2-vCPU host, ~8 min). An opaque
  `moq_relay` + `moq_publisher` fed a PCR-paced infinite loop of `~/CNNiEMEA2.ts`.
- All services restored and every `netem` qdisc + swap removed afterward. The opaque source binaries
  were left under `~/moq-publisher-subscriber`; port 443, the moq-lite services and network config
  restored exactly as found.

> The subscriber home IP is `<subscriber-home-ip>` throughout.

## Procedure

Impairment lives on a dedicated `prio` band so only the QUIC media egress is shaped and interactive
SSH (TCP) is untouched; a watchdog removes all shaping after 30 min even if the control session drops:

```bash
# on EC2 — SSH-safe netem lane (all default traffic → band 1; netem on band 4)
IFACE=ens5; SUBIP=<subscriber-home-ip>
sudo tc qdisc add dev $IFACE root handle 1: prio bands 4 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
sudo tc qdisc add dev $IFACE parent 1:4 handle 40: netem delay 0ms
sudo tc filter add dev $IFACE parent 1:0 protocol ip prio 1 u32 \
  match ip protocol 17 0xff match ip sport 443 0xffff match ip dst $SUBIP/32 flowid 1:4
sudo bash -c "nohup sh -c 'sleep 1800; tc qdisc del dev $IFACE root' >/dev/null 2>&1 &"  # watchdog

# change the condition per row, e.g.
sudo tc qdisc change dev $IFACE parent 1:4 handle 40: netem delay 100ms
sudo tc qdisc change dev $IFACE parent 1:4 handle 40: netem loss 1%
sudo tc qdisc change dev $IFACE parent 1:4 handle 40: netem delay 30ms 20ms distribution normal  # jitter (also reorders)
sudo tc qdisc change dev $IFACE parent 1:4 handle 40: netem delay 30ms reorder 25% 50%           # pure reordering
sudo tc qdisc del dev $IFACE root                                                                # remove all
```

For each condition the subscriber captured a fixed 22 s window; TSDuck reported delivered bitrate
(bytes·8/window), continuity discontinuities, transport errors, and PCR-interval statistics. For the
opaque loopback path, `netem` was applied to the loopback QUIC flow on the EC2 and the verbatim
egress captured/analysed on the box.

## Results

### Media-aware lane over the real EC2 path

Baseline (no impairment): **9.2–9.4 Mbps, 0 CC discontinuities, 0 transport errors**, PCR mean
~31 ms / max ~320 ms, ~12 % of intervals > 40 ms — i.e. the inherent media-aware burstiness from T2.

Latency (`--latency-max 5s`):

| Added delay | Delivered Mbps | CC disc. | Transport err | Verdict |
|---|---|---|---|---|
| +20 ms | 9.10 | 0 | 0 | no effect |
| +50 ms | 9.38 | 0 | 0 | no effect |
| +100 ms | 8.90 | 0 | 0 | no effect |
| +200 ms | 8.31 | 0 | 0 | no effect |

Packet loss (netem Bernoulli/uncorrelated):

| Loss | Delivered Mbps | CC disc. | PCR max (ms) | Verdict |
|---|---|---|---|---|
| 0.1 % | 9.47 | 0 | 320 | fully recovered |
| 1 % | 6.2–9.2 | 0 | 320–1200 | recovered; throughput dips |
| 3 % | 3.29 | 0 | 1400 | **starvation** (rate < stream rate) |
| 5 % | 2.49 | 0 | 2400 | severe starvation |

Jitter and reordering:

| Condition | Delivered Mbps | CC disc. | Verdict |
|---|---|---|---|
| In-order jitter (delay 60 ± 30 ms, rate-serialised) | 9.04 | 0 | **absorbed** |
| netem jitter (delay 30 ± 20 ms, reorders) | 0.16–0.22 | 0 | **collapse** |
| netem jitter (delay 60 ± 50 ms) | ~0 | – | collapse |
| Explicit reordering (25 %) | 0.97 | 0 | **collapse** |

Buffer sensitivity: at 1 % loss, `--latency-max` 500 ms vs 5 s both delivered ~8.7–9.2 Mbps with
0 CC — no cliff at this loss level.

### Opaque lane (EC2 loopback)

Baseline (no impairment): **10.16 Mbps, 0 CC, 0 transport errors, PCR mean/max 24.5 ms, 0 % > 40 ms**,
full source identity preserved verbatim (service "CNNI EMEA HD" / WBD, NIT present, TSID 0x0000, PMT
0x0064, PCR 0x006F). Byte-faithful and IRD-shaped (CBR) exactly as in T3.

| Condition (loopback) | Delivered Mbps | CC disc. | PCR % > 40 ms | Egress transparency |
|---|---|---|---|---|
| +50 ms delay | 8.64 | 0 | 0.0 | full SI, CBR |
| +100 ms delay | 9.43 | 0 | 0.0 | full SI, CBR |
| 0.1 % loss | 10.09 | 0 | 0.0 | full SI, CBR |
| 3 % loss | 10.10 | 0 | 0.0 | full SI, CBR |
| 5 % loss | 10.11 | 0 | 0.0 | full SI, CBR |
| reorder 25 % | ~0 (collapse) | – | – | – |

At near-0 RTT, QUIC recovered loss to 5 % with no throughput penalty and 0 CC, and the recovered
egress stayed **byte-transparent** (0 % PCR > 40 ms, full PSI/SI, CBR). Reordering collapsed
throughput, as on the media-aware lane. Adding realistic RTT (120 ms) on top of loss did collapse
opaque throughput at ≥ 1 %, but that run impaired *both* QUIC hops at once and used a different QUIC
stack and buffer than the media-aware run — **not** a controlled loss comparison.

### Real internet path (opaque, 443-swap)

The moq-lite stack was briefly stopped, the opaque relay took port 443, and the local subscriber
connected over the public internet. It subscribed and received at ~10 Mbps — the opaque lane works
end-to-end over the wire — but the older local subscriber build could not hand the TCP egress to a
capture tool cleanly, so no local TSDuck file was produced.

## Observations

1. **QUIC is robust to latency and moderate random loss.** Added delay to +200 ms and Bernoulli loss
   to ~1 % produced 0 continuity errors on the media-aware lane — the media arrived intact, just
   later.
2. **On the media-aware lane, loss shows up as *starvation*, not CC errors.** The subscriber re-muxes
   a fresh TS from whatever media objects arrive, so output continuity counters are always sequential
   — **CC-error count does not reveal loss for this lane**. The true health metric is *delivered
   bitrate vs source bitrate*: at ≥ 3 % loss the delivered rate collapsed below the stream rate,
   which in a real decoder is buffering/stall, not a clean error.
3. **Reordering — not delay variation — is QUIC's weak point.** In-order jitter of ± 30 ms was fully
   absorbed (9.04 Mbps), but packet reordering (which netem's naive "jitter" injects) collapsed
   throughput by ~40× because QUIC treats reordering as loss and backs off. Real networks reorder far
   less than netem's model, so this is a pessimistic bound.
4. **Impairment does not change either lane's *character*.** Whenever data was delivered, the
   media-aware egress stayed bursty (~13 % PCR > 40 ms; on this pre-#2440 build also SI-stripped) and
   the opaque egress stayed IRD-shaped (0 % > 40 ms, full SI, CBR). The property that decides
   broadcast usability is set by the lane and downstream grooming, not by impairment.

## Limitations

- CC-error is a weak damage metric for the media-aware lane (see obs. 2); a stronger metric
  (frame/GOP loss, decode errors, or the opaque lane's verbatim CC) is needed to quantify picture
  impact — a key reason the opaque lane matters for impairment testing.
- Absolute Mbps reflects the subscriber's home download path (varies); the *shape* of the degradation
  (recovery vs starvation vs collapse) is the robust finding.
- `netem` models are approximations: loss here is Bernoulli (uncorrelated), while real congestion
  loss is bursty and RTT-coupled; netem "jitter" reorders.
- `--latency-max 5s` is a large buffer favouring recovery; an IRD-facing egress runs a much smaller
  buffer. The small-buffer envelope is the more broadcast-relevant number.
- P1 only (CC/PCR/bitrate at the capture point, not a decoder verdict — that is T7).
- The opaque run is **not** a controlled loss comparison to the media-aware run (EC2 loopback, ~0 RTT,
  both QUIC hops impaired, different QUIC stack/buffer). A single-host, single-buffer, same-path
  head-to-head across both lanes and vs SRT is [T8](test-8-srt-vs-moq.md).

## Conclusion

Operating envelope (media-aware, ungroomed, 5 s buffer): usable with 0 CC and maintained throughput
up to **~1 % random loss and ≥ 200 ms added latency**, with in-order jitter tolerated; **starvation**
sets in by ~3 % loss and **reordering** is the boundary condition. Loss behaviour is graceful and
bounded (proportionate throughput reduction, recovery observed), not catastrophic — except under
heavy reordering, where the redundancy path (T6 / ST 2022-7) is the mitigation, not the transport
alone. Recorded as a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §6 (the
congestion-control head-to-head in [T8](test-8-srt-vs-moq.md) later showed the loss collapse is a
CUBIC default, removed by BBR).

## References

- Congestion-control head-to-head that reframes the loss result: [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md).
- LEO/Starlink handover candidate profile (not yet run): [planned-experiments.md](planned-experiments.md).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §6.
