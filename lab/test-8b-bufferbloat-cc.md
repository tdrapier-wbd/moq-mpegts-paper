# T8b — congestion control under a real bottleneck (bufferbloat)

> **NOT YET RUN.** This file is the executable protocol: objective, environment, procedure and
> pass criteria fixed *before* the numbers are known. Every Results cell is `TBM`. Do not cite it
> as evidence until it carries measurements.

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

**TBM — not yet run.** Tables below are the intended shape.

### 6a — Bufferbloat (headline), 5 Mb/s cap, 100 ms base RTT, 500 ms queue

| Controller | Goodput (Mb/s) | % of cap | Standing RTT p50 | p95 | CC errors |
|---|---|---|---|---|---|
| CUBIC (quinn) | TBM | TBM | TBM | TBM | TBM |
| BBRv1 (quinn) | TBM | TBM | TBM | TBM | TBM |
| BBRv2 (quiche) | TBM | TBM | TBM | TBM | TBM |
| BBRv3 (noq) | TBM | TBM | TBM | TBM | TBM |
| SRT | TBM | TBM | TBM | TBM | TBM |

### 6b — AQM counterfactual (`fq_codel` / `cake` at the same bottleneck)

| Controller | Queue | Goodput (% of cap) | Standing RTT p50 | Δ vs 6a |
|---|---|---|---|---|
| CUBIC | fq_codel | TBM | TBM | TBM |
| CUBIC | cake | TBM | TBM | TBM |
| BBRv1 | fq_codel | TBM | TBM | TBM |

### 6c — Cap below source (CBR vs adaptive)

| Cap | Source | Controller | Goodput (% of cap) | Standing RTT p50 | Failure mode |
|---|---|---|---|---|---|
| 5 Mb/s | CBR | TBM | TBM | TBM | TBM |
| 5 Mb/s | ABR | TBM | TBM | TBM | TBM |
| 3 Mb/s | CBR | TBM | TBM | TBM | TBM |
| 3 Mb/s | ABR | TBM | TBM | TBM | TBM |

### 6d — Fairness (N flows sharing one 5 Mb/s class)

| Controller | N | Per-flow rates | Jain's index | Standing RTT p50 |
|---|---|---|---|---|
| BBRv1 | 2 | TBM | TBM | TBM |
| BBRv1 | 3 | TBM | TBM | TBM |
| CUBIC | 2 | TBM | TBM | TBM |

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

TBM.

## Conclusion

TBM. On completion: promote the validated finding to [`docs/evidence.md`](../docs/evidence.md) §6,
lift the "non-congestive impairment only" scope caveat from
[test-8](test-8-srt-vs-moq.md), and update the default-controller recommendation in
[`docs/transport.md`](../docs/transport.md) §3.1 and [`docs/relay.md`](../docs/relay.md) §5 to rest on
this measurement rather than upstream's.

## References

- Extends [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) (over-provisioned matrix, CC knob, backends).
- Impairment method and SSH-safe lane: [test-5-network-impairment.md](test-5-network-impairment.md).
- Upstream: [#2432](https://github.com/moq-dev/moq/pull/2432) (CC knob and methodology guidance),
  [#2468](https://github.com/moq-dev/moq/pull/2468) (backend-specific defaults),
  [noq #768](https://github.com/n0-computer/noq/issues/768) (BBRv3 panic).
- Findings destination: [`docs/evidence.md`](../docs/evidence.md) §6.
