# Test 9 — System performance & resource utilisation

**Pyramid (§6):** operational envelope. **Gate (§7):** feeds [operations](../docs/operations.md) and
[economics](../docs/economics.md) §3.1 and §8 (not a fidelity/resilience gate). **State:** two ≥ 24 h
soaks run (2026-08-10). The **publisher and subscriber roles pass** (+0.03 and +0.15 MB/h). The
**relay is now the open question rather than the settled one**: it held 102.1 MB flat for 26 h on
0.14.8 under a lighter load, but climbed 106 → 226 MB on 0.14.9 under a heavier one, decaying to
+1.57 MB/h but not to zero, and did not release when sessions left. A controlled build A/B is running
to separate "0.14.9 regression" from "working set that ratchets with served load". The 0.13.7
OOM-kill leak remains not reproduced on either build. The fan-out envelope, bitrate sweep,
bounded-cache control and protocol overhead are all measured on Linux.

## Objective

Per role (publisher / relay / subscriber + groomer-pacer), establish the steady-state resource
envelope (CPU, RSS, fds, threads) and how it scales, prove **stability over long runs** (no memory
leak / unbounded growth — a production blocker, not a characterisation note), and record protocol
overhead. The priority dimension is a **hours→days soak** with an RSS-vs-time slope ≈ 0.

### Pass criteria (agreed in advance)

- RSS growth slope statistically ≈ 0 over the soak for **every** role (≥ 24 h, ideally 72 h).
- fd / socket / thread counts stable, returning to baseline after join/leave and relay-reconnect churn.
- Bounded CPU with documented headroom; per-core throughput and the fan-out knee documented.
- Per-hop wire overhead within budget (wire bytes vs TS payload over a fixed window).

## Environment

- **EC2 relay box** (`<EC2_IP>`, eu-west-1, 2 vCPU / 3.8 GB, **no swap**). The leak below was
  observed here on the *deployed* build `moq 0.8.7 / moq-relay 0.13.7 @ 5e0e98c1`, with two
  standing publishers and a default (unbounded) cache — a production-like standing service, not a
  controlled rig. **On 2026-08-07 the box was moved to the current stable release** (the official
  `moq-relay` 0.14.8 and `moq-cli` 0.9.7 Linux binaries rather than a local build), and the
  standing relay, SRT receiver and both publishers were restored on it. All the Linux measurements
  below are on that build, **including the completed soak**. Note this also changed the standing
  relay's QUIC backend from quiche to quinn, because the deployed binary had been overwritten with a
  quiche build during T8 and the official release binary is the default (quinn) one. **On 2026-08-08,
  after the soak finished, the box was moved again to `moq-relay` 0.14.9 / `moq-cli` 0.9.9 in
  `~/bin-0.14.9`** (services repointed, all restored). The 0.14.8 → 0.14.9 delta contains nothing
  touching relay memory (it is a clustering announce fix, a JS/mux batch and CI), so the soak verdict
  below carries over; the second soak runs on 0.14.9.
- **Local (controlled probes)** on the **0.14.8 release** (`moq-relay` 0.14.8 / `moq-cli` 0.9.8 /
  `moq-net` 0.2.9, origin/main `c8b11b10` = release #2672), Darwin 25.5.0. Rigs in `~/t6-redundancy/`:
  `t9_soak.sh` (phased steady / subscriber-churn / publisher-churn), `leak_probe.sh` (publishers with
  **no** subscriber — the EC2 condition), `session_leak.sh` (retained memory per completed session).
- **EC2 rigs** in `~/t9/` on the box: `fanout_ec2.sh` (fan-out envelope), `fanout_cpu_ec2.sh` (the
  same sweep with CPU attributed to relay / subscribers / whole box), `bitrate_cache_ec2.sh` (bitrate
  sweep and the bounded-cache control), `overhead_ec2.sh` (`tcpdump` wire-vs-payload),
  `soak_ec2.sh` + `soak_report.sh` (the phased soak and its per-role slope fit), and
  `soak2_ec2.sh` + `soak2_report.sh` (the publisher-role soak).
- **Source:** `~/CNNiEMEA2.ts` looped via `tsp regulate --pcr-synchronous` (≈ 9.93 Mbps). For the
  bitrate sweep, `t9_2mbps.ts` and `t9_27mbps.ts` were encoded on the box from that clip
  (verified at 2.000 and 27.500 Mbps). For the publisher-role soak, `t9_loop_vidonly.ts` — the same
  clip remuxed to **video only**, which is the one variant that survives a loop wrap (below). Note
  `ffmpeg` needs `-nostdin` when invoked inside a heredoc-fed remote shell, or it consumes the rest
  of the script as input.
- macOS lacks `pidstat`/`/proc`, so local sampling is `ps`/`lsof`; `/proc` and `journalctl` are used
  on EC2.

## The relay's cache is unbounded by default

Worth stating before any measurement, because it frames what "expected" memory looks like.
`moq-relay`'s group cache is **unbounded unless configured**: `CacheConfig` documents *"Unbounded when
unset"* for both `cache.capacity` and `cache.duration`, and resolves to `cache::Pool::unbounded()`
with a `Duration::MAX` age ceiling. With no knobs set, the only bound is each track's own retention
window, which defaults to `DEFAULT_LATENCY_MAX = 5 s`.

So a *healthy* relay should hold roughly five seconds of media per track — single-digit MB at
10 Mbps — and anything at the GB scale is anomalous rather than "the cache doing its job". That
distinction is what turned the observation below from a shrug into a finding. Operationally, bound
relay memory explicitly (`--cache-capacity`, or `--cache-headroom` for the governor) in any
deployment regardless.

## Confirmed: the deployed 0.13.7 relay leaks ~21 MB/hour to an OOM kill

**Correction to the 2026-08-06 entry below: the "flat plateau, no OOM" reading was wrong.** It was not
a plateau; it was a relay approaching the cliff. Roughly nine hours later the kernel killed it:

```
Aug 07 01:00:57 systemd[1]: moq-relay.service: The kernel OOM killer killed some processes in this unit.
Aug 07 01:00:57 systemd[1]: moq-relay.service: Main process exited, code=killed, status=9/KILL
Aug 07 01:00:57 systemd[1]: moq-relay.service: Failed with result 'oom-kill'.
Aug 07 01:00:57 systemd[1]: moq-relay.service: Consumed 16min 59.032s CPU time over
                            6d 18h 40min 56.947s wall clock time, 3.2G memory peak.
```

systemd restarted it, giving a fresh process and a second, independent growth measurement. **Three
measurements over different timescales agree on the rate:**

| Measurement | Elapsed | Growth | Rate |
|---|---|---|---|
| Lifetime to the OOM kill | 6 d 18 h 41 m | 3,208 MB peak | **19.7 MB/h** |
| Fresh process after restart | 9 h 03 m | 204 MB | **22.7 MB/h** |
| Live sampling (`/proc/<pid>/status`) | 40 s | 204736 → 204972 kB | **21.2 MB/h** |

A constant rate across three orders of magnitude of elapsed time is linear unbounded growth, not a
cache converging on a working set. Extrapolated, it kills a 3.8 GB box roughly weekly, which is what
happened.

**What the growth is *not* driven by**, which narrows it usefully:

- **Not media volume.** The relay served **zero subscriber sessions** (`journalctl | grep -c
  "role=Some(Subscriber)"` = 0). At 21 MB/h it is also three orders of magnitude below the ~4.5 GB/h
  of media the publishers represent, so it is not cached payload.
- **Not CPU / not the #2701 wedge.** 17 minutes of CPU over 6.8 days (~0.17 %). The
  [#2701](https://github.com/moq-dev/moq/pull/2701) livelock is a *spin* failure that burns 100 % CPU;
  this is a distinct, quiet memory failure.
- **Not fds or threads.** Steady at 10 fds and 3 threads throughout.
- **Not high session churn**, though sessions are the one thing that did accumulate: 52 sessions in
  9 hours, which works out at ~3.5 MB per session if the growth is charged to them.

## Not reproduced on 0.14.8 (2026-08-07)

Three controlled probes on the 0.14.8 release, sized so that the EC2 rate would be plainly visible.
**None reproduces it.**

| Probe | Condition | RSS behaviour | Verdict |
|---|---|---|---|
| `leak_probe.sh` | 2 publishers, **0 subscribers** (the EC2 condition), **60 min** | 15.39 → **12.98 MB** over the 300-3000 s window; **slope −2.68 MB/h** | no growth; EC2 rate predicts **+15.8 MB** |
| `t9_soak.sh` phase A | 1 publisher + 1 steady subscriber, 4 min | ramps to ~95 MB and holds (±6 MB) | bounded working set |
| `session_leak.sh` | 40 connect/disconnect subscriber sessions in 4 rounds | 100 → 151 → 162 → 181 → **149 MB** | oscillates and returns; no staircase |

The idle probe is the decisive one, because it replicates the exact EC2 condition — publishers
attached, nothing consuming — and because its baseline is rock steady (CPU 0.0, no media actually
flowing, since the relay only pulls a track once something subscribes). Against that quiet baseline a
21 MB/h leak would be unmissable: RSS held at **13.0 MB for 35 consecutive minutes** without moving,
where the old rate predicts a climb past 30 MB. (It then fell to 4.4 MB near the end as the OS
reclaimed pages under pressure from a concurrent test — reclaim, not signal, which is why the slope is
fitted over the flat window rather than the whole hour.)

The session probe is worth reading carefully, because at first glance round 1 looks like the ~3.5
MB/session the EC2 arithmetic suggests: +50.7 MB retained after ten completed sessions (5.07
MB/session). But it does not compound. Retained-per-session **decays** across rounds — 5.07, 3.10,
2.69, 1.23 MB — and round 4 came back *down* to 149 MB, below round 3's 181 MB. That is a bounded
working set being re-used, not memory lost per session. Throughout every probe, **fds held at 17 and
threads at 12**.

**The honest limit of this result.** These runs cannot exclude a ~20 MB/h leak in the *churn* regime,
where the band is ±30 MB and an hour of drift hides inside it. What they do establish is that the
specific 0.13.7 failure mode — steady linear growth in the idle, publisher-only regime — does not
occur on 0.14.8, and that is the regime the EC2 relay died in. Between the
two builds sit the cache and resume rewrites ([#2615](https://github.com/moq-dev/moq/pull/2615) media
retention and pool bounds, [#2657](https://github.com/moq-dev/moq/pull/2657)
`--cache-latency-default`, [#2666](https://github.com/moq-dev/moq/pull/2666), which explicitly pruned
unbounded segment accumulation), any of which is a plausible fix. Confirming the negative properly is
the ≥ 24 h soak below.

**Not reported upstream.** A leak that only reproduces on 0.13.7 — nine releases and two cache
rewrites behind `main` — is not actionable for maintainers; the evidence is recorded here instead. It
would become reportable if the ≥ 24 h soak on a current build shows a non-zero slope.

## Fan-out envelope on 0.14.8, macOS loopback (2026-08-07)

> **Superseded for absolute values by the Linux sweep below.** The *shape* recorded here (linear in
> egress, sublinear in memory, no thinning with N) held up on Linux. The absolute CPU constant did
> not: it is ~6x too pessimistic, because macOS loopback requires `--client-quic-gso=false` and
> so pays a syscall per packet. Kept per lab discipline, and because the 6x gap is itself the
> finding that host configuration dominates relay CPU.

`fanout.sh`: one relay, one ~9.9 Mbps publisher, N subscribers on the *same* broadcast. CPU is a
delta of cumulative CPU time over a fixed 20 s window (not `ps -o %cpu`, which on macOS is a decaying
average that lags a step change), taken after a 30 s settle at each step.

| N subscribers | Relay RSS | Relay CPU | Aggregate egress | Egress per subscriber |
|---:|---:|---:|---:|---:|
| 1 | 71.0 MB | 5.2 % | 9.5 Mbps | 9.50 Mbps |
| 5 | 86.2 MB | 27.9 % | 47.9 Mbps | 9.58 Mbps |
| 10 | 104.4 MB | 53.9 % | 96.5 Mbps | 9.65 Mbps |
| 25 | 122.4 MB | 143.6 % | 247.6 Mbps | 9.90 Mbps |

**No knee up to 25 subscribers / ~250 Mbps.** Three things to take from it:

- **CPU is the binding resource and it is strikingly linear.** Cost per Mbps of egress is
  0.547 / 0.583 / 0.559 / 0.580 % across the sweep — flat within noise, i.e. ~**0.57 % CPU per Mbps**,
  or ~5.5 % per 10 Mbps subscriber. Extrapolated, **one core sustains ~175 Mbps ≈ 17-18 subscribers**
  at this bitrate; the 143.6 % at N = 25 is ~1.4 cores. Relay sizing is therefore a straightforward
  egress-bitrate calculation, and fan-out capacity is a core count.
- **Memory scales sublinearly**, as a shared cache should: 71 → 122 MB across a 25× fan-out, a
  marginal ~2.1 MB per additional subscriber against a ~69 MB fixed cost. Memory is not the
  constraint for fan-out.
- **Delivery does not degrade with N.** Per-subscriber egress holds at 9.5-9.9 Mbps throughout, so the
  relay is serving every subscriber the full feed at 25× fan-out rather than thinning under load.

Caveats: loopback (no real network stack cost, no TLS-over-WAN, no congestion control doing real
work), a single broadcast, and macOS. Treat the *shape* (linear in egress, sublinear in memory) as the
result and the absolute constants as indicative.

## Fan-out on Linux: the knee is the host, not the relay (2026-08-07)

`~/t9/fanout_ec2.sh` on the EC2 box (2 vCPU, 0.14.8, one ~9.9 Mbps publisher, N subscribers on one
broadcast, all loopback). Linux gives `/proc`, so CPU is an exact `utime+stime` delta over a fixed
20 s window after a 30 s settle, and per-subscriber egress is a `/proc/<pid>/io` `wchar` delta.
CPU is expressed as percentage of **one** core; the box has two.

| N | Relay RSS | Relay CPU | Aggregate egress | Per subscriber |
|---:|---:|---:|---:|---:|
| 1 | 35.9 MB | 2.2 % | 9.5 Mbps | 9.50 Mbps |
| 5 | 44.4 MB | 5.2 % | 47.7 Mbps | 9.54 Mbps |
| 10 | 54.6 MB | 9.1 % | 94.9 Mbps | 9.49 Mbps |
| 25 | 80.9 MB | 21.2 % | 239.8 Mbps | 9.59 Mbps |
| 40 | 113.4 MB | 34.2 % | 386.1 Mbps | 9.65 Mbps |
| 55 | 130.3 MB | 46.5 % | 527.4 Mbps | 9.59 Mbps |
| 70 | 164.9 MB | 49.0 % | 558.9 Mbps | **7.98 Mbps** |

The knee is finally visible: per-subscriber egress holds between 9.49 and 9.65 Mbps all the way to
N = 55 and 527 Mbps aggregate, then falls to 7.98 Mbps at N = 70 while aggregate barely moves. But
the relay was using **under half of one core** to deliver 527 Mbps, which cannot be relay CPU
saturation on a 2-core box. A second sweep (`fanout_cpu_ec2.sh`) attributes the CPU three ways —
relay, the sum of all subscriber processes, and the whole box (percentage of both cores):

| N | Relay | Subscribers | Whole box (of 2 cores) | Aggregate | Per subscriber |
|---:|---:|---:|---:|---:|---:|
| 40 | 32.8 % | 80.2 % | 71.2 % | 386.7 Mbps | 9.67 Mbps |
| 55 | 48.4 % | 118.3 % | **93.7 %** | 541.4 Mbps | 9.84 Mbps |
| 70 | 83.2 % | 91.1 % | **97.7 %** | 84.6 Mbps | 1.21 Mbps |
| 85 | 81.5 % | 91.5 % | 96.8 % | 49.3 Mbps | 0.58 Mbps |

That settles it. **The knee is the host running out of cores, not the relay running out of
capacity.** The co-located subscriber processes cost 118 % of a core at N = 55 — about 2.4x the
relay's own 48 % — so the rig hits 94 % of both cores at N = 55 and collapses past it. The collapse
is not graceful: aggregate throughput falls from 541 to 85 Mbps, and relay CPU *rises* to 83 % while
delivering less, which is thrash (retransmission and scheduling) rather than work.

Two numbers to carry forward:

- **The relay costs ~0.089 % of a core per Mbps of egress at this bitrate — one core ≈ 1.1 Gbps,
  or ~110-120 subscriber sessions at 9.9 Mbps.** That is ~6x better than the macOS figure above,
  and the difference is host configuration (Linux with UDP GSO vs macOS loopback with GSO forced
  off), not code. For any capacity or cost model, host tuning outweighs anything else measured here.
- **A subscriber costs more CPU than the relay serving it** (~2.2 % of a core each at 9.9 Mbps,
  against the relay's ~0.9 %). Any loopback fan-out rig therefore measures the *box*, not the relay,
  once N is large — worth remembering before reading a knee as a relay limit.

Relay memory again scaled sublinearly and modestly: 35.9 MB at N = 1 to 130.3 MB at N = 55, a
marginal ~1.7 MB per subscriber. Memory is not the fan-out constraint on either platform.

## Bitrate sweep: cost per Mbps falls sharply as bitrate rises (2026-08-07)

`~/t9/bitrate_cache_ec2.sh`, N held at 10 subscribers so the box stays far from saturation, over
three sources: a 2 Mbps and a 27.5 Mbps clip encoded on the box from the standard CNN clip, plus the
clip itself at 9.95 Mbps.

| Case | Aggregate | Relay CPU | **CPU % per Mbps** | CPU per session | Relay RSS |
|---|---:|---:|---:|---:|---:|
| 2 Mbps × 10 | 20.1 Mbps | 3.35 % | **0.167** | 0.335 % | 39.5 MB |
| 10 Mbps × 10 | 95.7 Mbps | 8.65 % | **0.090** | 0.865 % | 49.0 MB |
| 27 Mbps × 10 | 241.1 Mbps | 11.75 % | **0.049** | 1.175 % | 94.6 MB |

**The per-Mbps constant does not hold across bitrates — it improves 3.4x from 2 to 27 Mbps.** Read
down the "CPU per session" column instead and the reason is clear: 12x the bitrate costs only 3.5x
the CPU per session, so most of a session's cost is fixed (per-connection and per-packet work,
amortised better as datagrams fill) rather than proportional to payload.

Two consequences. First, **relay cost tracks session count far more closely than bitrate**, so
capacity planning should count sessions, not gigabits. Second, and counter-intuitively for primary
distribution, **high-bitrate contribution feeds are the cheapest per Mbps to relay** — moving
up-market in bitrate improves relay compute economics. The expensive part of a high-bitrate always-on
feed is egress, not compute ([economics](../docs/economics.md) §3.1).

The 0.090 %/Mbps at 10 Mbps agrees with the fan-out sweep's 0.089 %/Mbps derived at N = 55, from a
completely different rig and subscriber count, which is a useful cross-check on both.

## Bounded cache costs nothing measurable (2026-08-07)

Same rig, re-run with `--cache-capacity 256MiB` against the unbounded default:

| Case | Aggregate | Relay CPU | Relay RSS |
|---|---:|---:|---:|
| 10 Mbps × 10, unbounded | 95.7 Mbps | 8.65 % | 49.0 MB |
| 10 Mbps × 10, `--cache-capacity 256MiB` | 95.7 Mbps | 8.65 % | 49.3 MB |
| 27 Mbps × 10, unbounded | 241.1 Mbps | 11.75 % | 94.6 MB |
| 27 Mbps × 10, `--cache-capacity 256MiB` | 242.9 Mbps | 11.75 % | 96.0 MB |

CPU is identical to the resolution measured and RSS differs by under 1.5 MB. That is the expected
result rather than a surprise — a healthy relay's working set is a few seconds of media per track,
far below a 256 MiB target, so the bound never binds and the governor never has to evict. The
operational point is what matters: **bounding the cache is free insurance, not a performance
trade-off**, so there is no reason to run a production relay unbounded (see the 0.13.7 OOM kill
above for the cost of doing so).

## Protocol overhead: ~1.12x the source TS rate on the wire (2026-08-07)

`~/t9/overhead_ec2.sh`: one publisher, one subscriber, `tcpdump` on the subscriber's UDP flow for a
20 s window, against the TS bytes that subscriber actually wrote in the same window.

| | 10 Mbps source | 27.5 Mbps source |
|---|---:|---:|
| TS delivered to subscriber | 9.55 Mbps | 25.98 Mbps |
| QUIC payload, downstream | +14.28 % over delivered TS | +15.72 % |
| Downstream IP wire at a 1200 B MTU | +16.94 % | +18.42 % |
| **Downstream IP wire vs the *source* TS rate** | **1.124x** | **1.119x** |
| Upstream (acknowledgements) | 0.70 % of TS | 0.31 % of TS |

Two denominators matter and they answer different questions. Against the **delivered** payload the
overhead is ~17-18 %; against the **source TS rate** it is ~12 %, because MoQ does not carry the
source's null/stuffing packets — it strips them on import and the exported TS is correspondingly
leaner. For capacity planning the second is the number to use: **a 9.95 Mbps service needs about
11.2 Mbps of IP capacity, and a 27.5 Mbps service about 30.8 Mbps** — call it 1.12x, plus well under
1 % on the return path. The ratio is essentially bitrate-independent across a 2.75x range.

Method caveat worth stating, because it is the reason the table has two wire rows. On loopback the
kernel coalesces datagrams via GSO: only 4,317 datagrams were captured for 27.3 MB, with a large
spike at 12,000 bytes (ten 1200-byte QUIC datagrams in one segment). Counting IP+UDP headers on what
`tcpdump` saw therefore *undercounts* headers badly. The "at a 1200 B MTU" row instead prices the
headers a real path would pay, analytically, from the payload volume. The QUIC-payload row needs no
such adjustment and is the platform-independent part of the measurement.

For context against the most comparable baseline, SRT carries seven TS packets per datagram and pays
a header on each, costing a few percent — so MoQ is materially more expensive in bandwidth for the
same service. Since bandwidth is the line most likely to dominate a cost comparison, that is
recorded as a real disadvantage rather than netted off against MoQ's compute efficiency
([economics](../docs/economics.md) §3.1).

## ≥ 24 h soak: the relay passes (2026-08-08)

**Verdict: no leak on 0.14.8.** The run completed its full 26.49 h (1,580 samples, 2026-08-07 13:29 →
2026-08-08 16:00 UTC) with **zero relay restarts**, which is the first thing to check — an OOM kill
and systemd restart would otherwise show up as a flat slope. Slopes fitted past a 1 h warm-up:

| Phase | Duration | Relay RSS | **Relay slope** | Threads / fds | Restarts |
|---|---:|---|---:|---|---:|
| 1 — steady | 18.98 h | 115.3 → 102.1 MB (range 102.1–116.2) | **−0.63 MB/h** | 3 / 11 | 0 |
| 2 — subscriber churn | 3.99 h | 102.1 MB (min = max) | **+0.00 MB/h** | 3 / 11 | 0 |
| 3 — steady again | 2.48 h | 102.1 MB (min = max) | **+0.00 MB/h** | 3 / 11 | 0 |

The margin is wide enough that the result does not turn on the fit. At the 0.13.7 rate of ~21 MB/h,
26.5 h predicts **+557 MB**; the measured phase-1 slope is *negative*, and the total excursion across
the whole run is 14 MB — a working set breathing, not a trend. Relay CPU averaged **2.85 % of one core**
over the run and `MemAvailable` never fell below 3,002 MB of 3,811.

Three details worth reading past the headline:

- **Churn does not ratchet.** Phase 2 subjected the relay to a subscriber join/leave every 120 s for
  four hours, and relay RSS did not move at all — min and max both 102.1 MB, to the 0.1 MB resolution
  sampled. Phase 3 then rejoined the phase-1 level with no step, so nothing was retained across the
  churn. This is the specific concern the earlier session probe could only bound at ±30 MB over an
  hour; four hours resolves it.
- **The negative phase-1 slope is reclaim, not shrinkage.** RSS settles from 115 MB to a 102 MB floor
  over the first hours and then sits on it. A relay whose cache is unbounded but whose retention
  window is 5 s per track should behave exactly like this.
- **fds and threads never moved** — 11 and 3 for 26.5 h across every phase, including the churn.

**This closes the leak question.** The 0.13.7 behaviour is a fixed historical defect, not a live risk,
and there is nothing to report upstream. The operational advice to bound the cache explicitly still
stands, but as cheap insurance (it is measured free, above) rather than as mitigation for a known bug.

**What this run does *not* establish is the publisher role**, for the reason recorded below: its
publishers restarted every ~10 minutes at the clip wrap, so the publisher column contains gaps and no
slope can be fitted through it. The subscriber aggregate is likewise not a clean per-role slope
because the set size changes with churn (phase slopes −0.04 / −0.69 / +0.19 MB/h are all ≈ 0, but the
denominator moves). A second soak addresses the publisher directly.

## Any audio stream losing frame sync kills `moq import` (2026-08-08)

Chasing a non-wrapping source for the publisher soak turned the earlier "MP2 frame sync" annoyance
into a sharper and more general finding. Three loop variants of the same clip were run through
`tsp -I file --infinite | moq import ts` across the ~601 s wrap:

| Loop variant | Result at the wrap |
|---|---|
| Full: H.264 + MP2 + AC3 + 3× SCTE-35 + teletext | **died** — `Error: missing MP2 frame sync` |
| H.264 + AC3 | **died** — `Error: missing AC-3 sync word` |
| H.264 video only | **survived**, ran on past 800 s |

So it is not an MP2 parser bug. **Every audio codec tried aborts the whole process when its
elementary stream loses frame sync, while the video path resynchronises through the very same
discontinuity.** That asymmetry is the finding: video is treated as resynchronisable and audio as
fatal.

For primary distribution that is the wrong way round to fail. A contribution feed does glitch, and a
publisher that exits on a momentary audio defect converts a few damaged frames into a full session
teardown, reconnect, and the ~4 s re-attach measured in T6.

The practical consequence for the rig: `t9_loop_vidonly.ts` is a source that loops indefinitely
without restarting the publisher.

### Confirmed with no timeline jump, and the root cause located (2026-08-10)

The one objection to reporting this was that a looped file jumps its timeline *backwards*, which a
real feed never does. **That objection is now dead.** A unit-level reproducer against `moq-mux`
0.9.4 — one valid MP2 frame, then a second frame with its sync word changed from `0xFF` to `0xFE`,
same PID, monotonic PTS, no loop and no timeline discontinuity of any kind — returns:

```
PROBE: one damaged header kills the whole import: missing MP2 frame sync
```

A single flipped bit is sufficient. `Import::decode` returns `Err`, and because `moq import`
propagates that, the process exits and every track in the broadcast goes with it.

The mechanism is a single line. In the legacy-audio PES loop
(`rs/moq-mux/src/container/ts/import.rs`, the `while offset + min_header_len <= data.len()` loop):

```rust
let header = (self.descriptor.parse)(&data[offset..])?;
```

The `?` propagates a header-parse failure straight out of the demuxer. There is no attempt to scan
forward for the next sync word, so a lost sync is unrecoverable by construction rather than by
policy. What makes this look like an oversight rather than a decision is that **the same codebase
already resynchronises everywhere else**:

- The **TS container layer** resyncs byte-wise and has three tests pinning it —
  `import_resyncs_after_byte_misalignment`, `resyncs_past_false_sync_byte`,
  `resyncs_across_chunk_boundaries`.
- The **video path** resyncs structurally: Annex-B parsing scans for start codes
  (`find_start_code` / `after_start_code`), so a damaged NAL is skipped rather than fatal. This is
  exactly why the video-only loop survives.

Legacy audio is the one layer that treats a lost sync as fatal. The module's own doc comment says
malformed input is *"rejected, never mis-described"* — and resyncing to the next valid frame honours
that principle exactly. Rejecting the damaged frame is right; killing the session is the part that
does not follow.

**View: this is reportable, and it is a strong report rather than a marginal one.** The evidence is a
deterministic minimal reproducer, a one-line root cause, a documented design principle the current
behaviour contradicts, and two in-repo precedents for the correct behaviour. There is also a close
precedent for it being accepted: [#2265](https://github.com/moq-dev/moq/issues/2265) ("one bad frame
fatally crashes the process") was treated as a bug and fixed.

**What is still missing before posting** — see the checklist in
[planned-experiments](planned-experiments.md) (T9 follow-ups):

1. **End-to-end on real content.** Bit-flip one MP2 frame header mid-file in `CNNiEMEA2.ts` (no loop),
   feed it through `moq import`, and capture the exit. Same file with a video NAL corrupted instead as
   the control. This is the broadcast-credible artifact; the unit test is the precise one.
2. **Blast radius, stated as measured.** Confirm the video and SCTE-35 tracks die with the audio, and
   that a subscriber sees the session drop rather than an audio-only gap.
3. **The design question**, which is why this should open as an **issue, not a PR**: resync policy is a
   choice, not a mechanical fix. How far should the parser scan before giving up? Should the skipped
   interval be signalled (a gap the exporter can reflect) or silently dropped? Should the track abort
   while the session survives, which is a middle option the current code structure already supports via
   `legacy::Import::abort`? Upstream's own guidance ([#2722](https://github.com/moq-dev/moq/pull/2722))
   recommends opening an issue first when the solution needs brainstorming, and this qualifies.
4. **A regression test in repo style**, which `Root Cause First` requires of any fix. The probe above is
   the seed but is written to assert the *broken* behaviour; the shipped version must assert the fixed
   behaviour (frame A and frame C both delivered, damaged frame B dropped).

Contribution mechanics, checked against the current `CONTRIBUTING.md`: this targets **`main`**, not
`dev` — the branch split is strictly about breaking a published API, and the guide explicitly places
"changing what a component does with input it *already* takes (e.g. recognizing a media pattern it used
to mishandle)" and "a parser accepting a broader set of inputs it previously rejected" on `main`.
Any GitHub prose needs the model-attribution marker.

## Publisher-role soak: publisher passes, but the relay raises a new question (2026-08-09)

`~/t9/soak2_ec2.sh` on **0.14.9**, 26.49 h (1,589 samples, 2026-08-08 20:24 → 2026-08-09 22:55 UTC),
steady throughout: a dedicated video-only loop publisher (which survives wraps) plus two steady
subscribers, against the standing relay. **Zero publisher respawns for the whole run** — the
video-only source did what it was chosen to do, so there is finally a continuous publisher to fit.

| Role | RSS over the run | **Slope (past 1 h warm-up)** | Verdict |
|---|---|---:|---|
| Publisher | 81.5 → 84.9 MB (min 81.5, max 92.3) | **+0.029 MB/h** | **pass** |
| Subscribers (2) | 164 → 190 MB | +0.610 MB/h overall, **+0.15 MB/h** in the final 8 h | pass |
| Relay | 105.7 → **226.0 MB** | **+3.200 MB/h** | **not a pass — see below** |

**The publisher role passes cleanly.** +0.029 MB/h is flat to any reasonable standard: extrapolated
over a year it is 254 MB, and the run's own peak-to-floor excursion (10.8 MB) is far larger than the
trend. It is also insensitive to the fit window — re-fitting past a 2 h warm-up gives +0.024 MB/h.
File descriptors held at 10 throughout, and CPU averaged 24.55 % of a core, matching the file-paced
figure measured independently below.

**One publisher caveat worth following up: thread count grew 22 → 86.** It decelerated (79 by 2 h,
83 by 14 h, 86 by 26 h) and never destabilised anything, so it reads like a work-stealing pool
converging rather than a leak. But it did not visibly stop, and threads are the one resource here that
only ever went up. A longer run, or a look at what the pool is sized against, would settle it.

### The relay result, which needs care

Read as a single linear fit, +3.2 MB/h looks alarming. It is not linear, and the shape matters:

| Window | Relay RSS | Slope |
|---|---|---:|
| 0–6 h | 77 → 176 MB | +16.47 MB/h |
| 6–12 h | 177 → 195 MB | +2.83 MB/h |
| 12–18 h | 195 → 211 MB | +2.49 MB/h |
| 18–26.5 h | 212 → 226 MB | +1.84 MB/h |
| 23–26.5 h (tail) | 221 → 226 MB | **+1.57 MB/h** |

So it is a decaying curve, and a straight line through it overstates the end state by roughly double.
But the decay **does not reach zero**: the last three and a half hours still add 1.57 MB/h, which
annualises to about 13.8 GB and would exhaust this 3.8 GB box in roughly three months. That is not
dismissible as settling.

Two further observations sharpen it, and they pull in opposite directions:

- **It did not release.** When the soak's publisher and two subscribers exited, relay RSS went 226 →
  224 MB over the following 11 hours. Memory acquired while serving was not returned. On its own this
  is weak evidence — allocators routinely keep pages — but it rules out "transient per-session
  buffers".
- **With no subscribers it is genuinely flat.** A 90-minute sampler on the same standing relay
  (`~/t9/relay_now.sh`) measured **+0.000 MB/h at 218.8 MB**. The relay only pulls a track when
  something subscribes, so this says the growth tracks *served* load rather than uptime — consistent
  with either a working set that ratchets up per served session, or a slow leak charged to serving.

**Why this is not yet a verdict, and what would make it one.** The comparison that suggests a
regression is soak #1 (0.14.8) holding **102.1 MB flat for 26 h** against soak #2 (0.14.9) climbing to
226 MB. But the two runs differ in *three* ways at once — build, one extra broadcast, and two extra
steady subscribers — so the build is only one candidate. The fan-out data says an extra broadcast plus
two sessions should cost roughly 40 MB, not 124 MB, which leaves an unexplained gap, but that
arithmetic is from a different rig. `~/t9/relay_ab.sh` (launched 2026-08-10 09:03 UTC) resolves it by
holding the workload fixed and varying only the binary: the same video-only publisher and four
subscribers against a **private** relay — no standing-service history and no session churn from the
looping publisher — for 2.5 h on 0.14.8 and then 2.5 h on 0.14.9, sampling every 30 s. If both builds
climb, this is load-dependent working-set behaviour and soak #1 simply ran a lighter workload; if only
0.14.9 climbs, it is a regression and reportable, with
[#2718](https://github.com/moq-dev/moq/pull/2718) (announcement-cursor registration per relay peer,
the one 0.14.9 change touching route/announce state) the first place to look.

**Representativeness limit of the publisher figure:** a video-only source exercises the import path
without audio, SCTE-35 or teletext, so this measures the publisher's *resource* behaviour rather than
its full-feed behaviour. Closing that gap needs the audio-resync fix below, not a rig change.

## The first soak as launched (2026-08-07 13:29 UTC)

`~/t9/soak_ec2.sh`, phased over 26.5 h, against the **standing** relay rather than a private one, so
what is under test is the real deployment in the role the 0.13.7 relay died in. Deliberately run
with the **default unbounded cache**: bounding it would mask exactly the failure being looked for.

- **Phase 1, 0-20 h — steady.** Standing publishers plus three steady subscribers. This is the
  decisive window: a long quiet stretch is what converts "not reproduced in an hour" into a slope.
- **Phase 2, 20-24 h — subscriber churn** every 120 s, to test whether RSS, fds and threads return
  to baseline after join/leave rather than ratcheting.
- **Phase 3, 24-26.5 h — steady again.** If churn retained memory, RSS rejoins the phase-1 trend at
  a step rather than on it.

Sampling every 60 s to `~/t9/soak.csv`: RSS, cumulative CPU, threads and fds for the relay, the
publisher and the subscriber set, plus `MemAvailable` and the relay's systemd restart count (so an
OOM kill and restart cannot be mistaken for a flat slope). `~/t9/soak_report.sh` fits a per-role,
per-phase slope past a warm-up cut-off.

Baseline at launch: relay 72.8 MB / 3 threads / 11 fds, publisher 40.4 MB, 3 subscribers,
3.1 GB available. A phased 3-minute dry run first verified all three phases, the CSV shape, and
subscriber teardown. Two details worth recording from that dry run: RSS rose 54 → 60 MB across a few
churn cycles and then held flat, which is the behaviour the 4 h churn phase is meant to resolve; and
the first version of the sampler resolved the publisher to its `/bin/sh` wrapper (1.9 MB) instead of
the `moq` process (38 MB), which would have produced a meaningless publisher slope.

**Why this run has no publisher slope:** its looped-file publishers die at every clip wrap (above), so
the publisher role restarted roughly every ten minutes and systemd replaced it. That does not weaken
the relay verdict — if anything it strengthens it, because the restarts reproduce the
~one-session-per-ten-minutes churn the leaking 0.13.7 relay actually saw (52 sessions in 9 hours), and
the relay still did not grow. An attempt to add a non-wrapping synthetic publisher alongside was
abandoned because live `lavfi` encoding cost too much CPU (below); the video-only remux found later
solved it properly.

Also note the first ~15 minutes of the CSV are perturbed by the experiments that were still finishing
on the box (relay RSS briefly reached 124 MB). Fit past a generous warm-up — `WARMUP=3600` rather
than the default 900 — when analysing.

## Publisher-side CPU on a trickle-fed live source (2026-08-07)

The other publisher-side observation from building the soak. (The first — `moq import` aborting on a
discontinuity — is now superseded by the three-variant result above, which localises it to the audio
parsers.)

**`moq import` costs ~3x more CPU on a trickle-fed live source than on a file-paced one, apparently
independent of bitrate.** Trying to build a publisher that never wraps, two live `lavfi` sources were
measured:

| Source into `moq import` | Bitrate | `moq import` CPU |
|---|---:|---:|
| `tsp regulate` from file (the standard rig) | 9.9 Mbps | ~22 % of a core |
| `lavfi testsrc2` 640×360 @ 25 fps, live encode | 1.8 Mbps | **60.9 %** of a core |
| `lavfi` black 320×180 @ 5 fps, live encode | 0.2 Mbps | **64.1 %** of a core |

Nine times *less* bitrate and a twentieth of the pixel rate cost three times *more* CPU, and the two
live cases agree with each other to within noise despite a 9x bitrate difference. That pattern —
cost invariant to the work, high whenever the input pipe trickles — looks like a spin or busy-read in
the import path rather than real processing, and it is the opposite of the efficient scaling the relay
showed. It also matters practically: a live encoder piping into `moq import` is the *normal*
contribution topology, and it is the case that measured worst. This needs isolating (a `perf` profile,
and a control with the same live source written to a file first) before it is worth raising upstream,
but it is recorded because it was reproducible on the first two attempts and it defeated the intended
soak design.

## Preliminary observation as recorded (2026-08-06) — superseded, kept per lab discipline

While assessing the box for T9, the standing `moq-relay` (build `0.13.7`, ~6 days uptime, two standing
publishers) was found at **VmRSS ≈ 3.2 GB** — ~84 % of the 3.8 GB box, with only 3 threads and 10 fds.
It was read at the time as an observation rather than a finding, on three grounds:

- **"Flat, not climbing."** Sampled over ~20 s it held at 3,208 MB (3208624 → 3208508 → 3208308 kB) and
  `dmesg` showed no OOM-kills, so it was read as a **plateau** — a default cache pool filling toward
  system memory. *This was the error: a 20 s window cannot distinguish a plateau from 21 MB/h, and the
  process was in fact ~9 hours from being OOM-killed.* The `dmesg` check was accurate but premature.
- **Old build, unknown history** — 0.13.7 predates the cache/retention work, so it could not be
  attributed to current code. *This part held up, and is now the leading explanation.*
- **It blocked the controlled test there** — ~116 MB free and no swap left no room for a fan-out sweep
  without risking the standing service. *Still true; the controlled probes were run locally instead.*

The lesson recorded: **sample a suspected leak over minutes, not seconds, and check `journalctl`/
systemd accounting rather than `dmesg` alone** (systemd logged both the OOM kill and the 3.2 GB peak
that `dmesg` did not surface).

## Still outstanding

- **Resolve the relay growth on 0.14.9** — the top open item, and the only one that could still make
  T9 fail its own pass criterion. `relay_ab.sh` answers the build question; if both builds climb, the
  follow-on is to characterise the ratchet (per-session retained memory at fixed N, then N=8/16) and
  to re-run with `--cache-capacity` set, which would show whether the governor bounds it. Pair a future
  repeat with the T7 ≥ 24 h PLL-lock soak so one run yields both verdicts.
- **The publisher thread count** (22 → 86 over 26 h, decelerating but not stopping). Cheap to check:
  a longer run plus what the pool is sized against.
- **Fan-out over a real path**, relay and subscribers on separate hosts. Both sweeps so far are
  loopback, and the Linux sweep showed why that matters: co-located subscribers cost 2.4x the relay,
  so the rig's knee is the host's. A cross-machine run would price the NIC and the network stack
  honestly and establish the relay's own knee, which neither sweep reached.
- **Overhead under loss.** The ~1.12x carriage figure is from a clean loopback path with no
  retransmission. The number that matters commercially is what it becomes over a real path with
  loss, and how it compares to the same measurement on SRT (T8 has the rig for this).
- **Per-role envelope for the groomer/pacer**, which the objective asks for and none of these runs
  covers.
- **Confirm the audio-sync abort against a *deliberate* mid-stream corruption** — a bit-flipped audio
  frame header with no timeline jump — which is the one control that would make it an upstream report.
  The video path surviving the same wrap already removes most of the "it is only an artificial
  loop discontinuity" objection.
- **Isolate the live-source `moq import` CPU cost** (~3x the file-paced case, bitrate-independent).
  Profile it and re-test with the live source staged through a file; if it holds up, it is an upstream
  report, and it affects the normal live contribution topology.

```bash
# soak (>= 24 h): coarse sampler + RSS-vs-time slope (slope ~0 = no leak)
while :; do printf '%s ' "$(date +%s)"; ps -o rss=,%cpu=,nlwp= -p <PID>; sleep 60; done > soak_<role>.log
awk '{n++;x=$1;y=$2;sx+=x;sy+=y;sxy+=x*y;sxx+=x*x}
  END{b=(n*sxy-sx*sy)/(n*sxx-sx*sx); printf "RSS slope = %.4f MB/hour\n", b*3600/1024}' soak_<role>.log
```

> **Fitting caveat learned here:** fit the slope only over samples *past* warm-up. A regression through
> the initial ramp (RSS reaching its working set in the first minute) manufactures a huge fake slope —
> an early phased run reported "+680 MB/hour" for a relay that was simply settling to ~95 MB.

## References

- Plan: [planned-experiments.md](planned-experiments.md) (T9), [README](README.md) roadmap.
- Reconnect/retention behaviour the soak interacts with: [evidence](../docs/evidence.md) §7,
  [#2469](https://github.com/moq-dev/moq/pull/2469), [#2647](https://github.com/moq-dev/moq/pull/2647),
  [#2615](https://github.com/moq-dev/moq/pull/2615).
- The distinct relay-wedge failure mode: [#2701](https://github.com/moq-dev/moq/pull/2701),
  [test-6](test-6-relay-resilience.md).
