# T8b — congestion control for a permanent fixed-rate trunk

> **State:** one under-provisioned *failure-mode* condition (C1) is executed on the namespace rig, at
> 2–3 replicates per controller; the provisioned-path conditions (C2–C6) are **not yet run**. The
> controller ranking below is therefore indicative and scoped to the under-provisioned case, which is
> why it is **not promoted to `docs/evidence.md`**. The upstream discussion this test came from, and
> where these numbers were reported, is [moq #2432](https://github.com/moq-dev/moq/pull/2432).

## Objective

Characterise **congestion-control behaviour for primary distribution**, which the
[T8](test-8-srt-vs-moq.md) matrix does not: T8 ran on an over-provisioned path (~292 Mb/s raw TCP
against a ~10 Mb/s stream), so a "100 %" cell there means "the source fitted in spare capacity," not
"the controller behaved well." It measures resilience to *non-congestive* impairment.

The use case is specific, and it sets the metric:

- The feed is a **fixed, non-congestion-responsive VBR** stream. On the media-aware lane MoQ carries
  the elementary essence (stuffing is stripped; CBR is rebuilt downstream by the pacer), so the
  transport sees VBR regardless of the source mux. The feed does **not** adapt its rate to the
  network — so this is *not* the adaptive-encoder / ABR case the CC knob
  ([#2432](https://github.com/moq-dev/moq/pull/2432)) was opened for.
- It must run **24/7/365, permanently**. That makes *stability over indefinite runtime* a first-class
  requirement: an intermittent or rare failure mode is disqualifying, because over continuous
  operation it will recur and eventually coincide with a transient.
- The value proposition versus SRT/Zixi is **relay-scaled distribution**, not glass-to-glass latency,
  and a downstream pacer rebuilds CBR/PCR at egress.

So the headline metric is **completeness and reconstructability** — delivered fraction, **0 continuity
errors after the pacer**, and session survival — **not** standing latency. Queuing delay matters only
where it (a) exceeds the receive buffer (`--latency-max`) and forces group drops, or (b) erodes the
buffer headroom that absorbs the next transient. This is why the "bufferbloat = latency" framing of
the upstream test does not map directly: that test optimises latency for a flow that can *fill* the
pipe; ours is fixed-rate with a re-groomer, so **completeness under contention** is the axis.

This is a characterisation, not a gate: the thesis is decided by T7 (Gate 2).

## Environment

> Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
> `INSTRUCTIONS.local.md`.

### Rig — prefer the namespace rig

Contention is a **queue**, not a geography: the base RTT is supplied by `netem` either way. Running
both endpoints in local network namespaces removes access-link variability and makes the result
reproducible on any Linux host, so it is the primary rig. The real-path rig is the corroborating
variant, not the reference.

The harnesses below are **kept local** (not published) — the invocation details live in
`INSTRUCTIONS.local.md` §7.

| Rig | Harness | Use |
|---|---|---|
| **Namespace (primary)** | `t8b-netns.sh` | Two netns joined by veth on one Linux host; bottleneck + queue downstream, base delay both ways. Fully controlled, no shared-host risk. |
| Real path (corroborating) | `t8b-shaper.sh` | EC2 `<EC2_IP>` → `<subscriber-home-ip>`, shaping `ens5` egress. Media-only `prio`+`u32` lane so SSH stays clean. The real-path RTT adds to the emulated base delay — record both. |
| RTT probe (both rigs) | `t8b-rtt-probe.sh` | Standing RTT sampled over the same window as the capture — used only as a buffer-headroom check, not as a QoE metric. |

### Controllers

Pin `--server-quic-congestion-control` / `--client-quic-congestion-control` on **every** run — the
resolved default is backend-specific and changed at #2468, and an unpinned run silently confounds the
comparison. The relay is the sender on the downstream hop, so the relay's flag is the one that
governs. The goal is **not** to pick a default but to identify the controller we can *pin and rely on*
for a permanent fixed-rate trunk.

| Controller | Backend | Build |
|---|---|---|
| CUBIC | quinn / quiche | `--server-quic-congestion-control loss` |
| BBRv1 | quinn | quinn relay, `--server-quic-congestion-control delay` |
| BBRv2 | quiche | single-backend relay (`--no-default-features --features quiche,websocket,uds`) |
| BBRv3 | noq | single-backend relay (`--features noq,…`) — see caveat |
| SRT | — | `tsp -O srt` / `tsp -I srt`, matched buffer, as the incumbent reference |

**BBRv3 caveat.** noq/BBRv3 carries a subtract-overflow panic under high loss
([noq #768](https://github.com/n0-computer/noq/issues/768)). A relay abort is an outage by definition
for a permanent feed, so record an abort or a collapse as a *result*, not a reason to omit the row.

### Source and buffers

- Source: a real broadcast feed (`CNNiEMEA2.ts`) carried media-aware, paced with
  `tsp -I file … --infinite -P regulate --pcr-synchronous` (**not** `ffmpeg -re`, which mis-paces this
  TS). Media-aware carriage strips stuffing, so the wire profile is VBR — the representative input.
- Matched buffers as in T8: MoQ `--latency-max 2s`, SRT `--latency 2000` on listener and caller.

## Procedure

### 0. Calibrate the shaper before trusting any number

A `tc` chain that looks right can still queue in the wrong place. Confirm the rig reproduces the
intended profile first.

```bash
sudo ./scripts/t8b-netns.sh up
sudo ./scripts/t8b-netns.sh bloat

# idle RTT should sit at the base (2 x the one-way netem delay), not above it
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 20 idle.csv
```

Calibration passes when idle ≈ base RTT. `iperf3` is not required (and was absent on the EC2 host): a
loss-based CUBIC run doubles as the greedy reference — it fills the FIFO, so if the CUBIC run drives
the queue to ~base + queue-depth the bottleneck is where it should be.

### 1. Conditions

The upstream shaped-bottleneck profile (10 Mb/s source → 5 Mb/s cap, base RTT, deep queue) is used,
but re-scoped: an *under-provisioned* cap is a failure-mode probe, while the operating point of
interest is a *provisioned* path under contention.

| # | Condition | Setup | What it isolates | State |
|---|---|---|---|---|
| C1 | Under-provisioned (failure mode) | `bloat`, cap < feed (~2:1) | how each CC/transport fails when the link cannot carry the feed | **run** |
| C2 | Transient congestion / competing flow **(priority)** | provisioned cap + a competing flow or brief dip below feed rate | does the feed stay complete, and how fast it recovers; post-transient bloat | not run |
| C3 | Coexistence / fairness | provisioned, N ∈ {2,3} flows share the class | does the feed hold its share (starvation → dropped content) | not run |
| C4 | AQM counterfactual | `codel` / `cake` at the same bottleneck | does AQM change the completeness/latency picture | not run |
| C5 | Provisioning margin | cap ≈ 1.5× / 1.1× feed | where content loss *begins* per controller (an economics input) | not run |
| C6 | Long-duration soak (permanence) | provisioned, hours→days | drift / leak / rare abort a short run misses | not run |

### 2. Run each cell

Per controller per condition: start a **fresh** MoQ import on a unique broadcast name (`moq import`
crashes at the ~600 s source loop wrap when replaying a looped *file* — a live permanent feed does not
wrap, but the test harness must keep windows short; reusing a name also leaves a stale announce that
stalls the export at 0 bytes), then capture completeness + probe over the same window.

```bash
# relay with the controller pinned (namespace rig; per-backend binary for BBRv1/BBRv2/BBRv3)
sudo ./scripts/t8b-netns.sh pub <relay-binary> --server-bind 10.99.0.1:4443 \
  --tls-generate localhost --auth-public "" --server-quic-congestion-control delay

# publisher (media-aware; stuffing stripped -> VBR on the wire)
sudo ./scripts/t8b-netns.sh pub bash -c \
  'tsp -I file ~/CNNiEMEA2.ts --infinite -P regulate --pcr-synchronous -O file - \
   | <moq> --client-tls-disable-verify --client-connect https://10.99.0.1:4443/anon \
       --broadcast t8b.c1.bbr1 import ts'

# subscriber capture + RTT over the same window
sudo ./scripts/t8b-netns.sh sub bash -c \
  'timeout 60 <moq> --client-tls-disable-verify --client-connect https://10.99.0.1:4443/anon \
     --broadcast t8b.c1.bbr1 export ts --latency-max 2s > t8b_bbr1.ts' &
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 60 rtt_bbr1.csv
```

### 3. Measure (completeness first)

```bash
# delivered content: bytes over the window, then continuity AFTER the pacer
tsp -I file t8b_bbr1.ts -P continuity -O drop          # no output = 0 CC errors = reconstructable
tsp -I file t8b_bbr1.ts -P analyze -O drop | grep -E 'bitrate|packets'
# queuing delay only as a buffer-headroom check
./scripts/t8b-rtt-probe.sh summary idle.csv rtt_cubic.csv rtt_bbr1.csv rtt_bbr2.csv
```

## Results

Rig: two network namespaces on the EC2 host, 5 Mb/s `htb` bottleneck, 100 ms base RTT (2 × 50 ms
`netem`), 500 ms `bfifo` (312 500 B). Source `CNNiEMEA2.ts` carried media-aware (VBR on the wire),
paced at ~9.93 Mb/s — i.e. ~2:1 over-subscription of the cap (condition **C1**, the failure mode).
MoQ `--latency-max 2s`, SRT `--latency 2000`. Each backend used its matching relay build (quinn /
quiche / noq); `loss` = CUBIC, `delay` = BBRv1 (quinn) / BBRv2 (quiche) / BBRv3 (noq).

**Calibration.** Idle RTT through the shaped path measured min 100.0 / avg 106.7 ms — at the base.
Under load CUBIC drives the queue to ~520–600 ms (base + ~500 ms queue), confirming the bottleneck
queue is where it should be.

### C1 — Under-provisioned (failure mode), 5 Mb/s cap, 100 ms base, 500 ms queue

Completeness first (delivered fraction of the cap, continuity after the pacer); queuing delay p50 per
replicate is a secondary buffer-headroom read. 2–3 replicates per controller, 45–60 s windows.

| Controller (backend) | Delivered (% of cap) | CC errors | Queuing delay p50 | Character |
|---|---|---|---|---|
| CUBIC (quinn) | 65–81 % | 0 | 516 / 519 / 520 ms | stable full bloat |
| CUBIC (quiche) | 62–63 % | 0 | 562 / 566 ms | stable full bloat |
| BBRv1 (quinn) | 45–76 % | 0 | 226 / **591** / 234 ms | **bimodal** — occasional full bloat |
| BBRv2 (quiche) | 67–69 % | 0 | 225 / 291 (/ 265) ms | **stable, ~½ CUBIC** |
| BBRv3 (noq) | **11–13 %** | 0 | 595 / 597 ms | **broken** — bloats *and* starves ([noq #768](https://github.com/n0-computer/noq/issues/768)) |
| SRT (reference) | 90 % | **4279** | 583 ms | most bytes, but a damaged (unreconstructable) stream |

### C2–C6 — not yet run

The rig supports all of them (`t8b-netns.sh {bloat,codel,cake}`, N concurrent imports, and long
windows). C2 (transient congestion) is the priority — it is the realistic threat to a provisioned
permanent trunk.

## Observations

- **CUBIC bloats, reliably** — both backends fill the FIFO to ~520–570 ms on every replicate. Stable,
  and (for us) irrelevant as a latency figure; it matters only that it does not damage the stream
  (0 CC).
- **For a permanent feed, stability decides it, not the best-case number.** BBRv2 (quiche) held
  ~½ CUBIC's delay and full delivery on *every* run. BBRv1 (quinn) is **bimodal**: ~230 ms on two of
  three runs but a full 591 ms bloat on the third. That intermittency is disqualifying for a 24/7/365
  feed — a bloat spike past the `--latency-max` buffer becomes dropped groups, and over continuous
  operation it *will* occur and eventually coincide with a transient. It is also consistent with the
  maintainer's own "quinn BBR is kind of bugged" note (asked upstream on #2432).
- **BBRv3 (noq) is out** — it both bloats and collapses delivery to ~12 %, the #768 overflow biting
  under sustained pressure. A controller that can abort the relay is an outage by definition here.
- **The controller that survives this condition best is BBRv2 on quiche** — stable, complete, no
  aborts on every replicate. **Read that at its actual strength: one condition, 2–3 replicates, and a
  delivered fraction that swings ~20 points.** It is enough to say the ranking under a shaped
  bottleneck is not the ranking under non-congestive loss; it is not enough to pin a controller for a
  24/7/365 feed, and C2 is what would be. The open question to the maintainer on #2432 is whether
  BBRv2 on quiche is a supported choice that can be run continuously.
- **MoQ and SRT fail in opposite directions** — the T8 finding, now under congestion too. MoQ sheds
  *whole groups* and emits a syntactically clean TS (0 CC, 45–81 % delivered) — thinned but
  reconstructable. SRT keeps 90 % of the bytes but its ARQ cannot hold under sustained
  over-subscription, so the output carries **4279 CC errors** — a damaged, unreconstructable stream.
  For reconstruction, clean-but-thinned wins.
- **Delivered fraction is noisy; the qualitative ordering is not.** With 2–3 replicates the goodput
  numbers swing ~20 points, so treat them as indicative; the completeness/stability *ranking* is the
  firm result.

## Pass criteria (agreed in advance)

For a permanent fixed-rate trunk, "pass" is about staying reconstructable, not about latency:

- **Complete and reconstructable:** on a provisioned path (C2–C5) the feed arrives with **0 continuity
  errors after the pacer** and no session drop, and recovers from a transient without a gap that
  breaks reconstruction.
- **Stable indefinitely (C6):** no drift, leak, or rare abort over a hours→days soak — an intermittent
  fault is a fail even if the median run looks fine.
- **Fails gracefully when under-provisioned (C1):** degradation is *thinning* (missing content, clean
  TS), not *damage* (continuity errors) or a session/relay abort.
- Queuing delay is judged **only** against the receive buffer: acceptable if it stays clear of
  `--latency-max` with headroom for a transient; a fail if it periodically approaches or exceeds it.

## Conclusion

C1 establishes the rig and the qualitative picture under a deliberately under-provisioned
cap: **CUBIC reliably bloats but stays clean; BBRv2 (quiche) is the stable, complete performer; BBRv1
(quinn) is bimodal on one replicate of three; BBRv3 (noq) is broken by #768; and MoQ thins where SRT
damages.** **No controller recommendation for a permanent fixed-rate trunk follows from one
under-provisioned condition** — the bimodality is a reason to run C2, not a disqualification. The
question is with the maintainer on [#2432](https://github.com/moq-dev/moq/pull/2432).

This is **not yet promoted to [`docs/evidence.md`](../docs/evidence.md)**, and the controller wording
in [`docs/architecture.md`](../docs/architecture.md) §8.5 / [`docs/architecture.md`](../docs/architecture.md) §8.4 is **not**
changed on the strength of it. The load-bearing follow-up is C2 (transient congestion on a provisioned
path), then the C6 soak — the two conditions that actually test a permanent trunk.

## Next steps

- Run **C2 (transient congestion / competing flow)** — the priority: does a competing flow or brief
  capacity dip cost the feed any content, and does it recover cleanly?
- Run **C3 (coexistence / fairness)** and **C4 (AQM)** on the provisioned path.
- Run **C5** — two provisioning points to find where content loss begins per controller.
- Run **C6 (long-duration soak)** — the permanence requirement; pair with the T9 resource soak.
- Add **replicates** (≥ 5) for delivered-fraction confidence; the delay/stability ranking is already
  clear at 2–3.

## References

- Upstream discussion this test came from, and where the C1 numbers were reported:
  [#2432](https://github.com/moq-dev/moq/pull/2432) (CC knob + methodology).
- Extends [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (over-provisioned matrix, CC knob, backends).
- Impairment method and SSH-safe lane: [test-5-network-impairment.md](test-5-network-impairment.md).
- Upstream: [#2468](https://github.com/moq-dev/moq/pull/2468) (backend-specific CC defaults),
  [noq #768](https://github.com/n0-computer/noq/issues/768) (BBRv3 panic).
- Findings destination (once settled): [`docs/evidence.md`](../docs/evidence.md) §3.3.
