# T5 — Network impairment

## Objective

Characterise end-to-end behaviour — throughput, recovery, continuity, timing — as a function of
controlled latency, loss, jitter and reordering injected with Linux `tc`/`netem`, and identify the
operating envelope within which each lane stays usable. A second aim: establish *which metric actually
reveals damage* on each lane, since the lanes fail very differently.

The segmented-HTTP arm was added last and is the one that changes a verdict. Until it ran, that lane's
recovery model — an availability window, an idempotent `GET`, retry and client-driven failover — was
argued from the specification and **never exercised under loss anywhere in this campaign**. It is the
one axis on which segmented HTTP was assumed ahead on paper, so it is the one worth measuring rather
than asserting. Its arm is run as a *controlled head-to-head* against the media-aware lane rather than
as a third table, for the reason given under Environment.

## Environment

- **Media-aware lane over the real EC2→home internet path.** Impairment applied on the EC2 `ens5`
  egress, filtered to the QUIC media flow only (UDP sport 443 → the subscriber's home IP), so the SSH
  control channel is never impaired. Media-aware lane uses the standing EC2 loop
  (`cnn.international.emea.loop.hang`, `moq export ts --latency-max 5s`).
- **Opaque lane built/deployed on the EC2 and measured on a controlled loopback path.**
  The `moq-publisher-subscriber` source was compiled on EC2 (`aws-lc-rs` backend, `moq-transport`
  0.14.2; a 4 GB swap file added to survive the build on the 2-vCPU host, ~8 min). An opaque
  `moq_relay` + `moq_publisher` fed a PCR-paced infinite loop of `~/CNNiEMEA2.ts`.
- All services restored and every `netem` qdisc + swap removed afterward. The opaque source binaries
  were left under `~/moq-publisher-subscriber`; port 443, the moq-lite services and network config
  restored exactly as found.
- **Controlled head-to-head (segmented HTTP against the media-aware lane), whole chain on the origin
  host.** Rigs: [`t5-impair-arm.sh`](scripts/t5-impair-arm.sh) and
  [`t5-impair-sweep.sh`](scripts/t5-impair-sweep.sh). Publisher, origin/relay and receiver are all
  local, so the impairment is the only variable; the fixture is `~/CNNiEMEA2.ts` (9,945,951 bps CBR) on
  both arms, in a 40 s window, with a 15 ms base delay applied to the payload direction in every cell
  including the baselines. The media-aware arm runs against a **private** relay on a high port with the
  congestion controller pinned to `delay` (BBR), never the standing `:443`.

> The subscriber home IP is `<subscriber-home-ip>` throughout.

**Why the head-to-head is run on one host, when the two older arms are not.** The media-aware numbers
below came off the real internet path on a pre-#2440 build, and the opaque numbers off a ~0 RTT
loopback with both QUIC hops shaped at once — so the two cannot be read against each other, and the
Limitations section has always said so. Nothing was gained by adding a third arm measured a fourth way.
One host, one shaper, one clip and one window is what makes a column comparison mean anything, and the
cost is that the constants are loopback constants.

**Three properties of the shaper are load-bearing, and each of them silently invalidated a first pass
of this sweep before it was fixed.** They are recorded in [method-notes](method-notes.md) §5 as rules;
in short: `lo`'s 65536-byte MTU makes a percentage loss model meaningless and is pinned to 1500;
segmentation offload (kernel *and* quinn's own) makes `netem` drop super-packets, which delivered
**7.8 % to the segmented lane and 2.5 % to the media-aware lane from one `loss 10%` command**; and an
uncancelled `tc` watchdog fires into a later cell and deletes its shaper, so that cell reports a clean
result for a condition it never experienced. Every cell below therefore carries the shaper's own
passed/dropped counters, a cell that finds no shaper at the end is failed rather than reported, and
**loss is tabulated as the fraction the shaper measured, not the fraction it was asked for.**

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

### Segmented HTTP against the media-aware lane, same host, same shaper

Rate is delivered bytes over the window against the fixture's 9.95 Mb/s, so 1.00 is "kept up". Applied
loss is what the shaper counted, not what it was commanded; the two columns differ because the arms
still offload slightly differently, and **the residual runs against the segmented lane's favour** — it
receives less loss than the media-aware lane in every cell and still degrades further.

| Condition | Applied loss (seg / MoQ) | Seg rate | Seg CC | Seg PCR > 40 ms | MoQ rate | MoQ CC | MoQ PCR > 40 ms |
|---|---|---|---|---|---|---|---|
| baseline (15 ms) | 0 % / 0 % | **1.040** | 0 | **0.00 %** | 0.962 | 0 | 8.83 % |
| +100 ms | 0 % / 0.04 % | 0.968 | 0 | 0.00 % | 0.934 | 0 | 8.89 % |
| +200 ms | 0 % / 0 % | 0.840 | 0 | 0.00 % | 0.890 | 0 | 8.79 % |
| loss 0.1 % | 0.01 % / 0.12 % | 0.968 | 0 | 0.00 % | 0.962 | 0 | 8.83 % |
| loss 1 % | 0.10 % / 0.95 % | 1.040 | 0 | 0.00 % | 0.962 | 0 | 8.83 % |
| loss 3 % | 1.44 % / 2.93 % | 0.838 | 0 | 0.00 % | **0.962** | 0 | 8.83 % |
| loss 5 % | 3.24 % / 5.05 % | **0.448** | 0 | 0.00 % | **0.961** | 0 | 8.83 % |
| loss 10 % | 8.04 % / 9.98 % | **0.170** | 0 | 0.00 % | **0.960** | 0 | 8.83 % |
| reorder 25 % | 0 % / 1.79 % | **0.981** | 0 | 0.00 % | **0.192** | 0 | 7.89 % |
| in-order jitter | 0 % / 0 % | *0.077* | 0 | 0.79 % | *0.833* | 0 | 9.18 % |

*The jitter row is not a result. `slot` still meters the TCP lane even with `packets`/`bytes`
allowances set, so 0.077 is an instrument ceiling; it is left in the table only so the cell is not
silently missing.*

**Replicates of the two decisive cells.** The segmented lane at commanded 5 % loss reads **0.448, 0.493
and 0.543** across three runs (2.8–3.2 % applied), and the media-aware lane under reordering reads
**0.192 and 0.150**. So the segmented loss figure carries roughly ±10 % of spread and should be read as
"about half rate", not as 0.45; both inversions reproduce comfortably outside that spread.

**The delay rows overstate a steady-state effect, and a longer window says by how much.** At 120 s
rather than 40 s the segmented lane reads **0.992** at baseline and **0.932** at +200 ms, against 1.040
and 0.840 over 40 s. Most of the delay penalty is therefore a one-off join cost — a classic client
fetches serially, so a higher RTT delays the live edge it joins and the window never recovers the
difference — with a residual sustained penalty of about 6 % at +200 ms.

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
5. **The two lanes' weaknesses are disjoint, and the ranking inverts between them.** Under loss the
   media-aware lane is flat — 0.960 at 10 % applied, indistinguishable from its own baseline — while
   segmented HTTP falls to 0.448 at 3.2 % and 0.170 at 8.0 %. Under reordering the positions swap
   exactly: segmented HTTP is untouched at 0.981 where the media-aware lane collapses to 0.192. Neither
   lane is "more robust"; each is robust to what the other is not, and a route's dominant impairment
   decides which one that favours.
6. **The mechanism is the reliability model, on both sides of the inversion.** TCP retransmits and
   reassembles in order, so reordering costs it nothing and loss costs it throughput through congestion
   response. QUIC with BBR does not read loss as congestion, so it holds rate through 10 % — the T8
   result, reproduced here on a different host and rig — but it does treat reordering as loss, and
   in-order stream delivery converts that into head-of-line blocking.
7. **Segmented HTTP loses time, never bytes — and that is the more useful failure mode.** Across every
   condition it recorded **0 continuity discontinuities and 0 PCR intervals above 40 ms**: the media
   that arrives is a byte-verbatim slice of the source carrying the source's own 24.4 ms PCR grid, even
   in the cell where it delivered 17 % of the stream. The lane's failure is that it falls behind the
   live edge, not that it corrupts. For a downstream groomer that is the easier of the two problems,
   because a bounded buffer absorbs late data and cannot repair damaged data.
8. **The media-aware lane's PCR non-conformance is not an impairment effect.** It sits at 7.89–9.18 %
   of intervals above 40 ms in *every* cell including the unimpaired baseline, and does not move with
   loss, delay or reordering. That is the exporter defect isolated in [T18](test-18-delivery-latency.md)
   — PCRs emitted too rarely and in clusters — showing up again on a third rig. Impairment neither
   causes it nor worsens it.
9. **`http_non200` stayed at 0 up to 8 % loss**, so nothing aged out of the availability window even
   when the client was delivering a sixth of the stream. The predicted segmented-lane failure — falling
   so far behind that segments expire and produce hard gaps — was not reached within this ladder, which
   is why the `cc_disc` column is 0 rather than large. Where that boundary sits is not established.

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

Limits specific to the segmented-vs-media-aware head-to-head:

- **Loopback, not a path.** One host, a 15 ms base delay in one direction, no competing traffic and no
  bottleneck. Treat the ordering and the shape of each curve as the result and the constants as
  indicative.
- **The origin is `python3 -m http.server`, which is the weakest part of the claim.** The segmented
  lane's whole commercial argument is that it is served by a tuned CDN edge with connection reuse,
  its own retry and multi-supplier failover; what was measured is a single unoptimised origin over
  HTTP/1.1 with no cache in front of it. A CDN could plausibly move the loss curve and cannot plausibly
  move the reordering result, which is a property of TCP rather than of the server.
- **One clip, one 40 s window, one replicate for most cells** (two for the two decisive ones). The
  jitter cell is instrument-limited and reports nothing.
- **The media-aware arm is BBR.** Pinned deliberately, since T8 showed the controller decides this
  lane's loss result outright; under CUBIC the loss column would look entirely different and the
  comparison would flatter segmented HTTP. The number quoted is the media-aware lane at its best.
- **The segmented lane received less loss than commanded**, by roughly a third, after both offload
  fixes. Rows are labelled with the measured fraction; the bias is conservative for the finding.
- P1 at the capture point on the ungroomed egress, as with the older arms — no decoder verdict, and no
  groomer downstream.

## Conclusion

**Neither data plane is the more robust one. Their weaknesses are disjoint, and which one a route
should prefer depends on whether that route loses packets or reorders them.** On one host under one
shaper, the media-aware lane on BBR holds 0.96 of source rate through 10 % applied loss and collapses
to 0.15–0.19 under 25 % reordering; segmented HTTP is untouched by the same reordering at 0.98 and
falls to 0.45 at 3 % loss and 0.17 at 8 %. Both directions reproduce, and the residual calibration
error runs against segmented HTTP's favour rather than for it.

**The specification-level expectation for segmented HTTP was wrong in one direction and right in
another.** Its availability window and idempotent retry did not buy resilience *of rate* under loss —
it degrades steeply where the media-aware lane does not. What they did buy is resilience *of content*:
across every condition the lane delivered 0 continuity discontinuities and 0 PCR intervals above 40 ms,
so it sheds time rather than data, and a bounded downstream buffer is the mitigation. The
media-aware lane's failure under reordering is the one that needs a second path
([T6](test-6-relay-resilience.md) / ST 2022-7) rather than a buffer.

Operating envelope (media-aware, ungroomed, 5 s buffer): usable with 0 CC and maintained throughput
up to **~1 % random loss and ≥ 200 ms added latency**, with in-order jitter tolerated; **starvation**
sets in by ~3 % loss and **reordering** is the boundary condition. That loss collapse is a CUBIC
default and is removed by BBR ([T8](test-8-srt-vs-moq.md)), which is what the head-to-head above
measures. Recorded as a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §3.3.

**What would settle the part that is still open** is the same ladder against a real CDN edge rather
than a single unoptimised origin, and a loss ladder pushed far enough to find the depth at which the
segmented lane falls out of its own availability window — the failure this rig predicted and never
reached.

## Corrections

**Believed:** a `netem` percentage is the loss the flow experiences, so two arms given the same command
are comparable. **True:** the drop decision lands on whatever buffer the qdisc is handed, which under
segmentation offload is a super-packet the stack splits afterwards — and TCP and QUIC offload
differently, so one `loss 10%` command delivered 7.8 % to the segmented lane and 2.5 % to the
media-aware one. The first pass of the head-to-head therefore "showed" the media-aware lane shrugging
off loss that it had largely not received. **Rule:** disable the kernel offloads *and* the
application's own (quinn coalesces its own datagrams), then label every row with the fraction the
shaper counted rather than the fraction it was commanded.

**Believed:** a safety watchdog that removes shaping after 30 minutes is free insurance. **True:** it
outlives its own cell and fires into a later one, deleting that cell's qdisc partway through; the cell
then completes and reports a plausible, clean result for a condition it never experienced. This is
invisible in the delivered numbers — it was caught only because the shaper's counters came back empty
against a root qdisc that was no longer there. **Rule:** cancel the watchdog at teardown, and fail any
cell whose shaper is missing at the end rather than reporting it.

**Believed:** `netem slot MIN MAX` emulates in-order jitter, per the note carried from T8. **True:**
bare `slot` releases one packet per slot, which at 30–90 ms is a ~200 kb/s rate cap; the segmented lane
read 0.077 of source rate and the cell was nearly written up as a collapse under jitter that was
entirely the instrument. Setting `packets`/`bytes` allowances did not fully free the TCP arm either, so
the jitter cell is reported as unresolved rather than as a number.

## References

- Congestion-control head-to-head that reframes the loss result: [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md).
- The exporter PCR defect that appears in every cell of the media-aware arm: [test-18-delivery-latency.md](test-18-delivery-latency.md).
- Rigs: [`t5-impair-arm.sh`](scripts/t5-impair-arm.sh), [`t5-impair-sweep.sh`](scripts/t5-impair-sweep.sh).
- Shaper rules this experiment contributed: [method-notes.md](method-notes.md) §5.
- LEO/Starlink handover candidate profile (not yet run): [planned-experiments.md](planned-experiments.md).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §3.3.
