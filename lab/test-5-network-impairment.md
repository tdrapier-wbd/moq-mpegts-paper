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
- **Availability-window ladder (segmented HTTP only).** Rig:
  [`t5-availability-ladder.sh`](scripts/t5-availability-ladder.sh). The same local chain, run to 40 %
  loss in **120 s** windows rather than 40 s, and instrumented for HTTP status, segment-fetch order,
  the client's lag behind the live edge and the maximum PCR interval — the four things the 40 s ladder
  was too short to see. Origin retention is `--live 6 --live-extra-segments 3` at 2 s segments, so nine
  segments, 18 s.

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

> **The two rate columns do not share a congestion controller: the segmented arm is TCP/CUBIC and the
> media-aware arm is QUIC/BBR.** The loss rows therefore compare controllers as much as lanes, and the
> matrix that separates them is in [T8](test-8-srt-vs-moq.md) — segmented HTTP given BBR reads 0.971 at
> 3 % and 1.040 at 10 % on this same rig. Read the reordering row as a lane result and the loss rows as
> a controller result.

| Condition | Applied loss (seg / MoQ) | Seg rate (CUBIC) | Seg CC | Seg PCR > 40 ms | MoQ rate (BBR) | MoQ CC | MoQ PCR > 40 ms |
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
| in-order jitter | 0 % / 0 % | *0.077* | *10 / 94* | *0.80 %* | *0.833* | 0 | 9.18 % |

*The jitter row is not a result about jitter. `slot` still meters the TCP lane even with
`packets`/`bytes` allowances set, so 0.077 is an instrument ceiling; the row is kept so the cell is not
silently missing. Its continuity errors and its 12,044 ms maximum PCR interval are real, and they are
not jitter damage either — they are the availability-window failure of the next section, reached by a
rate cap instead of by loss. A client held to 0.077 of source falls 18 s behind in under 20 s, so this
40 s cell crossed the window where the loss cells at the same duration could not. The lane's
completeness limit therefore depends on the size of the shortfall and not on what caused it, which is
the section's claim arrived at by a second route.*

**Replicates of the two decisive cells.** The segmented lane at commanded 5 % loss reads **0.448, 0.493
and 0.543** across three runs (2.8–3.2 % applied), and the media-aware lane under reordering reads
**0.192 and 0.150**. So the segmented loss figure carries roughly ±10 % of spread and should be read as
"about half rate", not as 0.45. Both reproduce well outside that spread — but only the reordering
figure is a lane result; the loss figure reproduces a *controller*, as the note above the table says.

**The delay rows overstate a steady-state effect, and a longer window says by how much.** At 120 s
rather than 40 s the segmented lane reads **0.992** at baseline and **0.932** at +200 ms, against 1.040
and 0.840 over 40 s. Most of the delay penalty is therefore a one-off join cost — a classic client
fetches serially, so a higher RTT delays the live edge it joins and the window never recovers the
difference — with a residual sustained penalty of about 6 % at +200 ms.

### Where the segmented lane stops losing time and starts losing bytes

The ladder above stops at 10 % commanded loss and records no HTTP non-200 anywhere, which is why this
experiment could say the lane sheds time rather than data. It could not say for how long. The origin
retains nine segments — `--live 6` plus `--live-extra-segments 3`, so 18 s at 2 s segments — and a
client delivering a fraction *f* of source rate falls behind at (1−*f*) × realtime, so a segment cannot
have expired before the client reaches it until 18/(1−*f*) seconds have passed. At 40 s per cell the
ladder was too short to reach its own boundary, and the zeros in the `http_non200` column recorded the
window length rather than the lane's resilience.

Run to 40 % loss over 120 s windows ([`t5-availability-ladder.sh`](scripts/t5-availability-ladder.sh)),
the boundary appears immediately — and the failure past it is not degradation. Segments fetched are
read from the origin's own access log, so the client's itinerary is visible rather than inferred:

| Commanded | Applied | Rate ratio | Segments the client fetched | HTTP 404 | CC events / packets | Max PCR interval | Content hole |
|---|---|---|---|---|---|---|---|
| 10 % | 7.67 % | 0.057 | 2, 3, 4, 5 — sequential | 1 | 0 / 0 | 24.95 ms | **none** |
| 15 % | 12.23 % | 0.037 | 2, **6**, 7 | 1 | 11 / 82 | **7,240 ms** | 3 segments |
| 20 % | 18.27 % | 0.035 | 2, **13**, 14 | 1 | 7 / 47 | **24,569 ms** | 10 segments |
| 30 % | 29.69 % | 0.020 | 2, **37** | **0** | 6 / 33 | **83,384 ms** | 34 segments |
| 40 % | 39.91 % | 0.008 | 2 | 0 | 0 / 0 | 24.95 ms | none — one segment in 120 s |

**The mechanism is a fetch that takes longer than a segment period.** At 7.7 % applied loss the client
completed four segment fetches in 120 s, averaging 30 s each against a 2.4 s segment — twelve segment
periods per segment. Once one fetch costs more than one period the client cannot catch up, so it drifts
back from the live edge at close to realtime, and the origin's retention depth decides only how many
periods of grace it gets before the segment it wants has been deleted. Nine retained segments is 18 s
of grace against a drift of nearly a second per second, which is why the crossing happens early in
every cell rather than progressively across the ladder.

*What that arithmetic does not explain is why the 10 % cell fetched 2, 3, 4 and 5 in sequence before
taking its 404, rather than being overtaken after the first.* Four consecutive segments should not have
survived 90 s of live-edge advance. Either the early fetches were much faster than the cell average —
plausible, since the client begins by pulling segments already on disk and TCP has not yet collapsed —
or the packager's retention is deeper in practice than `--live 6 --live-extra-segments 3` implies. The
cell is reported as measured and the discrepancy is not resolved; it does not affect the boundary,
which is bracketed by the two cells either side of it.

**Past the boundary the lane delivers holes, and the arithmetic closes on them.** `tsp -I hls` does not
stop; it re-anchors to the live edge, so the stream continues and is missing everything in between. At
a mean achieved segment of 2.4 s the three skips are 3, 10 and 34 segments — 7.2 s, 24 s and 82 s of
programme — against measured PCR gaps of 7.24 s, 24.57 s and 83.38 s. The hole is exactly the segments
that expired.

**Two cells crossed the boundary without an HTTP error, which is the part that matters
operationally.** A 404 only happens if the client asks for a segment that has just been deleted. Past
about 20 % loss it does not get the chance: it reloads the playlist, the segment it wanted is no longer
listed, and it re-anchors to what is. The 30 % cell skipped 82 s of programme having received **nothing
but 200s**. An origin's error rate is therefore not an instrument for this failure — the worst cell on
the ladder is the one with a clean HTTP log.

**The hole does register as continuity errors, and they cannot size it.** Each re-anchor breaks the
continuity counter on every PID that carries packets across it, which is where 11, 7 and 6 events come
from — one splice counted once per affected PID, not eleven splices. The clip has thirteen PIDs, and
how many register depends on which were mid-sequence at the cut. The packet totals (82, 47, 33) are the
*apparent*
gaps: a continuity counter is four bits, so a hole of 34 segments wraps it more than two thousand times
and it reports the remainder. The count detects the discontinuity and understates it by three orders of
magnitude. Only the PCR interval sizes it.

**The 40 % row is the one that looks like a pass and is not.** It records no 404s, no continuity errors
and a 24.95 ms maximum PCR interval — a perfect conformance record, over one segment delivered in two
minutes. The client was too slow ever to be overtaken, so it never fell out of the window and never had
to skip. A cell can post clean carriage precisely because it delivered almost nothing, which is why the
rate ratio has to be read beside the conformance columns and never instead of them.

**What this bounds.** "Segmented HTTP loses time, never bytes" holds, with the qualification that makes
it useful: *while the client stays inside the origin's availability window*. That is not a property of
the lane but a race between the delivered-rate shortfall and the retention depth, and it is losable —
here between 7.7 % and 12.2 % applied loss under CUBIC, with a 9-segment window and a client that
fetches serially. A deeper window, a smaller shortfall or a controller that does not collapse all move
it; the shape of the failure past it does not change. **The main ladder's jitter cell crosses the same
boundary without any loss at all** — held to 0.077 of source by a rate cap, it falls 18 s behind inside
a 40 s cell and posts 10 continuity events and a 12 s PCR gap — which is the clearest evidence that
what matters is the size of the shortfall rather than its cause. What does not survive the crossing is
the claim's second half: past the window this lane loses bytes, silently, in minutes.

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
5. **Reordering separates the two lanes; loss does not.** Under reordering segmented HTTP is untouched
   at 0.981 where the media-aware lane collapses to 0.192, and that comparison holds because both arms
   were run at a pinned controller. The loss column of this sweep is **not** a lane comparison: it ran
   the media-aware arm on BBR and the segmented arm on the system default, which is CUBIC. Completing
   the matrix ([T8](test-8-srt-vs-moq.md)) puts segmented HTTP at 0.971 at 3 % and 1.040 at 10 % once
   it too is given BBR, against the media-aware lane's 0.962 — indistinguishable. Under CUBIC both
   collapse together. So the loss figures below record what a *controller* does on each lane, and the
   inversion this experiment originally reported was half an artefact of its own asymmetry.
6. **The mechanism is the reliability model on the reordering side, and the congestion controller on
   the loss side.** QUIC's in-order stream delivery converts reordering into head-of-line blocking,
   which segment fetching does not suffer; that is structural and belongs to the lane. Loss is
   different: a loss-based controller reads a dropped packet as congestion and backs off on either
   lane, and a delay-based one does not, on either lane. TCP's retransmit-and-reassemble is why
   reordering costs the segmented lane nothing, but it is not why that lane loses throughput under
   loss — CUBIC is.
7. **Segmented HTTP loses time rather than bytes, for as long as it stays inside the availability
   window.** Across every *loss* condition in this ladder it recorded **0 continuity discontinuities
   and 0 PCR intervals above 40 ms**: the media that arrives carries the source's own bytes and its
   24.4 ms PCR grid, even in the cell where it delivered 17 % of the stream. The one cell that does
   record damage is the instrument-limited jitter row, and it records it because 0.077 of source rate
   put the client outside the window inside the 40 s cell — the same failure the next section reaches
   deliberately, not a different one. Within the
   window the lane's failure is that it falls behind the live edge, not that it corrupts, and for a
   downstream groomer that is the easier of the two problems — a bounded buffer absorbs late data and
   cannot repair damaged data. Past the window it becomes the harder problem: the client re-anchors and
   the buffer is asked to absorb an 82 s hole, which it cannot. The section above locates the crossing
   and observation 9 gives the arithmetic.
8. **The media-aware lane's PCR non-conformance is not an impairment effect.** It sits at 7.89–9.18 %
   of intervals above 40 ms in *every* cell including the unimpaired baseline, and does not move with
   loss, delay or reordering. That is the exporter defect isolated in [T18](test-18-delivery-latency.md)
   — the right *number* of PCRs emitted in sub-millisecond clusters with long gaps between them —
   showing up again on a third rig. Impairment neither causes it nor worsens it.
9. **The availability window is a real edge, and this ladder is on the safe side of it by
   construction.** `http_non200` stays at 0 up to 8 % loss across 40 s cells — but 40 s is shorter than
   the 18 s window divided by the shortfall, so the cell ends before a segment can expire. Run for
   120 s the same impairment reaches its first 404, and by 18.3 % applied loss the client is skipping
   24 s of programme at a time. The boundary is established: between 7.7 % and 12.2 % applied loss on
   this rig. Read every zero in the `http_non200` column of the main table as "not within this window",
   not as "does not happen" — and note that past the boundary that column stops working entirely, since
   the two worst cells took no HTTP errors at all.

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

**One impairment separates the two data planes, and it is reordering, not loss.** On one host under
one shaper the media-aware lane collapses to 0.15–0.19 of source rate under 25 % reordering while
segmented HTTP is untouched at 0.98 — a structural consequence of QUIC's in-order stream delivery
that segment fetching cannot suffer, and the one axis on which a route's choice of lane is a genuine
engineering decision. **Loss separates congestion controllers instead.** Given the same controller
both lanes behave the same way: on BBR both hold full rate through 10 % ([T8](test-8-srt-vs-moq.md)
completes the matrix at 1.040 segmented and 0.961 media-aware), and on CUBIC both collapse to 0.13–0.17.
The loss ladder in this experiment gave the two lanes different controllers, so the inversion it
originally reported was in part its own asymmetry.

**The specification-level expectation for segmented HTTP was right about content, untested about rate,
and bounded in a way the specification does not advertise.** Its availability window and idempotent
retry buy resilience *of content* while the client remains inside that window: across every loss
condition in the main ladder, including the ones delivering 17 % of source rate, the lane records 0
continuity discontinuities and 0 PCR intervals above 40 ms, so it sheds time rather than data and a bounded
downstream buffer is the mitigation. **The window is finite, reachable, and crossed without an error
being raised.** Once a single segment fetch costs more than a segment period the client cannot catch
up, and after nine segments of grace it re-anchors to the live edge — measured here between 7.7 % and
12.2 % applied loss under CUBIC, leaving 7–82 s holes that no downstream buffer can absorb, and in the
worst two cells leaving them while the origin's log shows nothing but 200s. Retry buys nothing for
resilience *of rate*,
which belongs to the controller underneath. The media-aware lane's failure under reordering is the one
that needs a second path ([T6](test-6-relay-resilience.md) / ST 2022-7) rather than a buffer or a
controller.

Operating envelope (media-aware, ungroomed, 5 s buffer): usable with 0 CC and maintained throughput
up to **~1 % random loss and ≥ 200 ms added latency**, with in-order jitter tolerated; **starvation**
sets in by ~3 % loss and **reordering** is the boundary condition. The loss half of that envelope is
a CUBIC default on either lane and is removed by BBR on either lane
([T8](test-8-srt-vs-moq.md)); **reordering is the part that is a property of the lane**. Recorded as
a permanent finding in [`docs/evidence.md`](../docs/evidence.md) §3.3.

**What would settle the part that is still open** is the same ladder against a real CDN edge rather
than a single unoptimised origin. The availability-window question is otherwise answered: the section
above reaches the boundary and characterises what is past it. One residual is worth an hour — the
10 % cell fetched four consecutive segments before its first 404, which nine segments of retention
should not have allowed, so either early fetches are much faster than the cell average or the
packager retains more than it is asked to. Timestamping each GET rather than counting them would
say which.

## Corrections

**Believed:** with the shaper, host, fixture and window held identical, the remaining difference
between the two arms is the data plane. **True:** the arms did not share a congestion controller. The
media-aware arm was pinned to BBR *deliberately* — on T8's finding that the controller decides a loss
result outright — and the segmented arm was left on the system default, which is CUBIC. The one
variable known to dominate the loss axis was therefore the one variable not controlled, and the
"disjoint weaknesses" conclusion inherited it: at a matched controller the loss ladder does not
separate the lanes at all ([T8](test-8-srt-vs-moq.md)). **Rule:** pinning a setting on one arm is
half a control; the pin has to be applied to every arm, including the arms where the equivalent knob
has a different name and lives in a different layer. A default is a choice that does not appear in
the command line, and an experiment that records only what it typed will not notice it.

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

**Believed:** the segmented arm recorded 0 continuity errors in every cell because nothing was lost.
**True:** the counter could not have reported anything else. The arm script grepped `tsp -P continuity`
output for the word `discontinuity`, which that plugin never prints — it prints `missing N packets` —
so the column was structurally zero and would have read zero against a deliberately corrupted file.
Re-graded, the cells that were genuinely clean are still clean, so the conclusion survives; it just was
not evidence before. **Rule:** a check that has only ever returned "clean" has not been shown to work.
Feed it something broken before publishing the zeros. The same defect was in five other scripts and is
recorded once in [method-notes.md](method-notes.md).

**Believed:** `http_non200 = 0` across the ladder showed the segmented lane never falls out of its
availability window. **True:** it showed the cell was shorter than the window. Nine retained segments
is 18 s of grace, and a client delivering a fraction *f* of source rate needs 18/(1−*f*) seconds to
consume it — longer than the 40 s cell at every loss level the ladder ran. The column was measuring the
experiment's own duration. **Rule:** before reporting that a bounded resource was never exhausted,
compute how long exhausting it would take and check the window is longer than that.

## References

- Congestion-control head-to-head that reframes the loss result: [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md).
- The exporter PCR defect that appears in every cell of the media-aware arm: [test-18-delivery-latency.md](test-18-delivery-latency.md).
- Rigs: [`t5-impair-arm.sh`](scripts/t5-impair-arm.sh), [`t5-impair-sweep.sh`](scripts/t5-impair-sweep.sh),
  [`t5-availability-ladder.sh`](scripts/t5-availability-ladder.sh).
- The segmented lane's congestion behaviour under a shaped bottleneck, where the same client dies
  rather than re-anchoring: [test-8b-congestion-control.md](test-8b-congestion-control.md).
- Shaper rules this experiment contributed: [method-notes.md](method-notes.md) §5.
- LEO/Starlink handover candidate profile (not yet run): [planned-experiments.md](planned-experiments.md).
- Findings: [`docs/evidence.md`](../docs/evidence.md) §3.3.
