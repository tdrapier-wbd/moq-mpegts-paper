# T8b — congestion control under a real bottleneck (bufferbloat)

> **Condition 6a run (first pass, 2026-07-30).** Headline bufferbloat matrix executed on the
> namespace rig; conditions 6b (AQM), 6c (adaptive source) and 6d (fairness) are **not yet run**.
> Results below are a first pass (2–3 replicates per controller); standing RTT is stable across
> replicates, delivered goodput is noisier. **Not yet promoted to `docs/evidence.md`** — see the
> regime caveat in Observations before citing.

## Objective

Measure **congestion control**, which the [T8](test-8-srt-vs-moq.md) matrix does not. T8 ran on an
over-provisioned path (~292 Mb/s raw TCP against a ~10 Mb/s stream), so a "100 %" cell there means
"the source fitted in the spare capacity," not "the controller behaved well." It characterises
resilience to *non-congestive* impairment.

The test that actually stresses a controller is **bufferbloat under a shaped bottleneck**: offer more
than the link can carry, put a deep queue behind it, and see whether the controller fills the queue
(high latency, nominal goodput) or paces to the bottleneck (high goodput, low latency). Both metrics
must be read **together** — goodput alone cannot tell a good controller from a bloated one.

Two things depend on this run:

1. **The default-controller recommendation.** T8 concludes that quinn + `delay` (BBRv1) is the
   pragmatic broadcast choice, and upstream made BBRv1 the quinn default in
   [#2468](https://github.com/moq-dev/moq/pull/2468). The evidence behind that flip is the
   *maintainer's* bufferbloat measurement (CUBIC p50 RTT ~558 ms vs BBRv1 ~90 ms), not ours. Until
   this runs we are borrowing someone else's number for our headline transport recommendation.
2. **Scope of the T8 ranking.** Until this runs, the T8 controller ranking is explicitly scoped to
   non-congestive impairment only.

This is a characterisation, not a gate: the thesis is decided by T7 (Gate 2).

## Environment

> Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
> `INSTRUCTIONS.local.md`.

### Rig — prefer the namespace rig

A bufferbloat test measures a **queue**, not a geography: the 100 ms base RTT is supplied by `netem`
either way. Running both endpoints in local network namespaces removes access-link variability and
makes the result reproducible on any Linux host, so it is the primary rig. The real-path rig is the
corroborating variant, not the reference.

| Rig | Script | Use |
|---|---|---|
| **Namespace (primary)** | [`scripts/t8b-netns.sh`](scripts/t8b-netns.sh) | Two netns joined by veth on one Linux host; bottleneck + queue downstream, base delay both ways. Fully controlled, no shared-host risk. |
| Real path (corroborating) | [`scripts/t8b-shaper.sh`](scripts/t8b-shaper.sh) | EC2 `<EC2_IP>` → `<subscriber-home-ip>`, shaping `ens5` egress. Media-only `prio`+`u32` lane so SSH stays clean. The real path RTT adds to the emulated base delay — record both. |
| RTT probe (both rigs) | [`scripts/t8b-rtt-probe.sh`](scripts/t8b-rtt-probe.sh) | Standing RTT sampled over the same window as the capture. |

### Profile (upstream's, so the numbers are comparable)

10 Mb/s source → rate-limited to **5 Mb/s**, **100 ms base RTT**, **500 ms of queue before dropping**
(= 312 500 B at 5 Mb/s). Report delivered rate as **% of the 5 Mb/s cap**, never as % of source.

### Controllers

Pin `--server-quic-congestion-control` / `--client-quic-congestion-control` on **every** run — the
resolved default is backend-specific and changed at #2468, and an unpinned run silently confounds the
A/B. The relay is the sender on the downstream hop, so the relay's flag is the one that governs.

| Controller | Backend | Build |
|---|---|---|
| CUBIC | quinn | default relay, `--server-quic-congestion-control loss` |
| BBRv1 | quinn | default relay, `--server-quic-congestion-control delay` |
| BBRv2 | quiche | single-backend relay (`--no-default-features --features quiche,websocket,uds`) |
| BBRv3 | noq | single-backend relay (`--features noq,…`) — see caveat |
| SRT | — | `tsp -O srt` / `tsp -I srt`, matched buffer, as the incumbent reference |

**BBRv3 caveat.** T8 could not trust noq/BBRv3 because of a subtract-overflow panic under high loss
([noq #768](https://github.com/n0-computer/noq/issues/768)). This profile is a *shaped bottleneck with
essentially no random loss*, so BBRv3 may well be runnable here — attempt it, and record an abort as a
result rather than omitting the controller.

### Source and buffers

- Source: `CNNiEMEA2.ts` paced with `tsp -I file … --infinite -P regulate --pcr-synchronous`
  (**not** `ffmpeg -re`, which mis-paces this TS).
- Matched buffers as in T8: MoQ `--latency-max 2s`, SRT `--latency 2000` on listener and caller.
- CBR replay exposes goodput and bloat but cannot back off. Condition 6c pairs one run with an
  adaptive source (`libx264` ABR chasing the send-rate estimate) to separate *overflow* from
  *back-off* as failure modes.

## Procedure

### 0. Calibrate the shaper before trusting any number

A `tc` chain that looks right can still queue in the wrong place. Confirm the rig reproduces the
intended profile first, and only then run the matrix.

```bash
sudo ./scripts/t8b-netns.sh up
sudo ./scripts/t8b-netns.sh bloat

# idle RTT should sit at the base (2 x 50 ms), not above it
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 20 idle.csv

# saturate with a bulk flow; RTT should climb to roughly base + queue depth (~600 ms)
sudo ./scripts/t8b-netns.sh pub iperf3 -s -D
sudo ./scripts/t8b-netns.sh sub iperf3 -c 10.99.0.1 -R -t 30 &
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 25 loaded.csv
./scripts/t8b-rtt-probe.sh summary idle.csv loaded.csv
```

Calibration passes when idle ≈ 100 ms and loaded ≈ 600 ms. If loaded RTT does not rise, the queue is
not where it is supposed to be and the qdisc chain must be fixed before proceeding.

### 1. Conditions

| # | Sub-condition | Shaper | What it isolates |
|---|---|---|---|
| 6a | Bufferbloat (headline) | `bloat` — htb 5 Mb/s + 100 ms RTT + bfifo ~500 ms | goodput → 5 Mb/s **and** standing RTT (100 ↔ 600 ms) |
| 6b | AQM counterfactual | `codel` / `cake` at the same 5 Mb/s | does modern AQM tame CUBIC's bloat? |
| 6c | Cap below source | `bloat` at 5 and 3 Mb/s, CBR vs adaptive source | failure mode: overflow (CBR) vs back-off (ABR) |
| 6d | Fairness | `bloat`, N ∈ {2,3} flows sharing one class | per-flow share (Jain's index); BBRv1 fairness |

### 2. Run each cell

Per controller per condition: start a **fresh** MoQ import on a unique broadcast name (`moq import`
crashes at the ~600 s source loop wrap, and reusing a name leaves a stale announce that stalls the
export at 0 bytes), then capture and probe over the same window.

```bash
# relay with the controller pinned (namespace rig; --features build for BBRv2/BBRv3)
sudo ./scripts/t8b-netns.sh pub "$TGT/moq-relay" demo/relay/localhost.toml \
  --server-quic-congestion-control delay

# publisher
sudo ./scripts/t8b-netns.sh pub bash -c \
  'tsp -I file ~/CNNiEMEA2.ts --infinite -P regulate --pcr-synchronous -O file - \
   | "$TGT/moq" --client-connect https://10.99.0.1:4443/anon \
       --broadcast t8b.bloat.bbr1.hang import ts'

# subscriber capture + RTT over the same 60 s window
sudo ./scripts/t8b-netns.sh sub bash -c \
  'timeout 60 "$TGT/moq" --client-connect https://10.99.0.1:4443/anon \
     --broadcast t8b.bloat.bbr1.hang export ts --latency-max 2s > t8b_bbr1.ts' &
sudo ./scripts/t8b-netns.sh sub ./scripts/t8b-rtt-probe.sh sample 10.99.0.1 60 rtt_bbr1.csv
```

Sixty seconds is ample to fill a 500 ms queue and read a standing RTT, and stays well clear of the
600 s wrap.

### 3. Measure

```bash
# delivered goodput as % of the 5 Mb/s cap (not % of source)
tsp -I file t8b_bbr1.ts -P analyze -O drop | grep -E 'bitrate|packets'
tsp -I file t8b_bbr1.ts -P continuity -O drop            # no output = 0 CC errors
./scripts/t8b-rtt-probe.sh summary idle.csv rtt_cubic.csv rtt_bbr1.csv rtt_bbr2.csv
```

Cross-check the ICMP standing RTT against the QUIC endpoints' own estimate
(`RUST_LOG=moq_net=debug`). ICMP is the transport-independent reference that the MoQ and SRT runs
share; the QUIC estimate is the corroboration.

## Results

Rig: two network namespaces on the EC2 host (the primary self-contained rig), 5 Mb/s `htb`
bottleneck, 100 ms base RTT (2 × 50 ms `netem`), 500 ms `bfifo` (312 500 B). Source
`CNNiEMEA2.ts` (~9.93 Mb/s CBR via `tsp regulate`) — i.e. ~2:1 over-subscription of the cap, a
non-backing-off broadcast workload. MoQ subscriber `--latency-max 2s`, SRT `--latency 2000`.
Each backend exercised with the matching relay build (quinn / quiche / noq); the CC family per
backend is `loss` = CUBIC, `delay` = BBRv1 (quinn) / BBRv2 (quiche) / BBRv3 (noq).

**Calibration (§0).** Idle RTT through the shaped path measured min 100.0 / avg 106.7 ms — at the
100 ms base. Under load CUBIC drives the queue to ~520–600 ms (base + ~500 ms queue), confirming
the bottleneck queue is where it is meant to be.

### 6a — Bufferbloat (headline), 5 Mb/s cap, 100 ms base RTT, 500 ms queue

Standing RTT p50 (ms) per replicate, delivered goodput as % of the 5 Mb/s cap, 45 s windows
(one 60 s window each for the first quiche/SRT runs). Base RTT = 100 ms; full bloat ≈ 600 ms.

| Controller (backend) | Standing RTT p50 (replicates) | Goodput (% of cap) | CC errors | Character |
|---|---|---|---|---|
| CUBIC (quinn) | 516 / 519 / 520 | 65–81 % | 0 | **stable full bloat** |
| BBRv1 (quinn) | 226 / **591** / 234 | 45–76 % | 0 | **bimodal** — low-latency 2/3, bloats 1/3 |
| CUBIC (quiche) | 562 / 566 | 62–63 % | 0 | stable full bloat |
| BBRv2 (quiche) | 291 / 225 (/ 265) | 67–69 % | 0 | **reliably ~½ CUBIC's RTT** |
| BBRv3 (noq) | 595 / 597 | **11–13 %** | 0 | **broken** — bloats *and* starves ([noq #768](https://github.com/n0-computer/noq/issues/768)) |
| SRT | 583 | 90 % | **4279** | most bytes, but bloats and damages the stream |

### 6b — AQM counterfactual (`fq_codel` / `cake` at the same bottleneck)

**Not yet run.** Rig supports it (`t8b-netns.sh codel` / `cake`).

### 6c — Cap below source (CBR vs adaptive)

**Not yet run — now the priority follow-up.** 6a used a non-backing-off CBR source, which is why no
controller reaches the 100 ms base and goodput never approaches the cap (see Observations). The
adaptive-source variant is what makes this comparable to the upstream greedy-flow bufferbloat number.

### 6d — Fairness (N flows sharing one 5 Mb/s class)

**Not yet run.** Rig supports it (N concurrent imports on one bottleneck class).

## Pass criteria (agreed in advance)

- **Healthy goodput** is ≈ 90–100 % of the 5 Mb/s **cap** — not of the source.
- **BBR holds standing RTT near the 100 ms base** while **CUBIC bloats toward ~600 ms** (base +
  queue). Reproducing the maintainer's ~558 → ~90 ms delta on our own rig is what validates the
  #2468 default flip for this platform.
- **AQM pulls CUBIC back down** (6b), confirming the bloat is the dumb FIFO rather than the
  controller alone.
- **Endorse a default only if it shares a bottleneck acceptably** (6d). BBRv1's inter-flow fairness
  is the thing to watch: a controller that wins single-flow but starves its neighbours is not a
  broadcast default.
- A controller that reports nominal goodput **and** a bloated standing RTT has **failed**, not
  passed — that is the whole point of measuring both together.

## Observations

- **CUBIC bloats, reliably.** Both backends fill the FIFO to ~520–570 ms standing RTT on every
  replicate — the textbook bufferbloat signature, and the stable reference the other controllers are
  judged against.
- **BBR halves standing latency — but the generation and stability matter more than the label.**
  BBRv2 (quiche) is the *most reliable* latency win here (~225–291 ms, ~½ CUBIC, every run). BBRv1
  (quinn) is **bimodal**: it hit ~230 ms in two of three runs but bloated to 591 ms in the third —
  the latency benefit is real but not dependable under this workload. BBRv3 (noq) is unusable: it
  both bloats *and* collapses goodput to ~12 %, consistent with the known #768 defect.
- **This complicates, rather than confirms, the "quinn + BBRv1 as the default" recommendation.** In
  this broadcast-relevant regime the reliable low-latency controller was **quiche BBRv2**, not quinn
  BBRv1. That does not overturn T8 (whose ranking was about loss/reorder resilience), but the
  default-controller story cannot simply inherit the upstream greedy-flow result.
- **Regime caveat — this is not the upstream greedy-flow test.** The upstream ~558 → ~90 ms figure
  is measured with a *backing-off* flow; a good controller there paces to the bottleneck and keeps
  the queue near-empty. Our source is a **non-backing-off CBR broadcast mux at ~2:1
  over-subscription**, so (a) no controller reaches the 100 ms base (best is BBRv2 at ~225 ms, ~125 ms
  of residual queue) and (b) delivered goodput never approaches the cap because the excess offered
  rate must be shed somewhere. This characterises the *broadcast* case, which is arguably the more
  relevant one for this project, but it means the number is **not** a like-for-like reproduction of
  the #2468 evidence. Condition 6c (adaptive source) is the apples-to-apples comparison and is the
  priority follow-up.
- **MoQ and SRT fail differently under the same bottleneck** — the T8 finding, now seen under
  congestion too. MoQ sheds *whole groups* and emits a syntactically clean TS (0 CC errors, 45–81 %
  of cap delivered); SRT delivers more bytes (90 %) but its ARQ cannot keep up under sustained
  over-subscription, so the output carries **4279 CC errors** — a damaged rather than a thinned
  stream. Neither is strictly better; they trade completeness for integrity in opposite directions.
- **Goodput is noisy, standing RTT is stable.** Across replicates RTT p50 varied by a few ms within
  a controller, while goodput swung 20+ points — so the latency conclusions are firmer than the
  goodput ones on this replicate count.

## Conclusion

First-pass 6a establishes the rig and the qualitative picture: **CUBIC reliably bloats; BBR can
roughly halve standing latency but only BBRv2 (quiche) does so dependably here, BBRv1 (quinn) is
bimodal, and BBRv3 (noq) is broken by #768.** No controller reaches the base RTT with a
non-backing-off CBR source, and MoQ trades delivered volume for a clean stream where SRT does the
reverse.

This is **not yet promoted to [`docs/evidence.md`](../docs/evidence.md)** and the
default-controller recommendation in [`docs/transport.md`](../docs/transport.md) §3.1 /
[`docs/relay.md`](../docs/relay.md) §5 is **not** changed on the strength of it: the result complicates
that recommendation and needs (a) condition 6c with an adaptive source for a like-for-like comparison
with the upstream number, and (b) more replicates for goodput confidence intervals, before it is a
settled finding. Until then the T8 controller ranking remains scoped to non-congestive impairment,
with this file the first congestion-regime data point.

## Next steps

- Run **6c (adaptive source)** — the priority: an ABR encoder that backs off to the send-rate
  estimate, to compare like-for-like with the upstream greedy-flow bufferbloat number.
- Run **6b (AQM)** — does `fq_codel` / `cake` tame CUBIC's bloat, and does it help the CBR case?
- Run **6d (fairness)** — BBRv1/BBRv2 inter-flow share before endorsing any default.
- Add **replicates** (≥ 5) for goodput confidence intervals; RTT is already stable at 2–3.

## References

- Extends [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (over-provisioned matrix, CC knob, backends).
- Impairment method and SSH-safe lane: [test-5-network-impairment.md](test-5-network-impairment.md).
- Upstream: [#2432](https://github.com/moq-dev/moq/pull/2432) (CC knob and methodology guidance),
  [#2468](https://github.com/moq-dev/moq/pull/2468) (backend-specific defaults),
  [noq #768](https://github.com/n0-computer/noq/issues/768) (BBRv3 panic).
- Findings destination: [`docs/evidence.md`](../docs/evidence.md) §6.
