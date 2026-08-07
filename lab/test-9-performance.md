# Test 9 — System performance & resource utilisation

**Pyramid (§6):** operational envelope. **Gate (§7):** feeds [operations](../docs/operations.md) and
[economics](../docs/economics.md) §3.1 and §8 (not a fidelity/resilience gate). **State:** largely run
(2026-08-07) — memory stability is answered for two builds; the **fan-out envelope, the bitrate
sweep, the bounded-cache control and protocol overhead are all measured on Linux**; the ≥ 24 h
multi-role soak is **running** and is the last open item.

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
  below are on that build. Note this also changed the standing relay's QUIC backend from quiche to
  quinn, because the deployed binary had been overwritten with a quiche build during T8 and the
  official release binary is the default (quinn) one.
- **Local (controlled probes)** on the **0.14.8 release** (`moq-relay` 0.14.8 / `moq-cli` 0.9.8 /
  `moq-net` 0.2.9, origin/main `c8b11b10` = release #2672), Darwin 25.5.0. Rigs in `~/t6-redundancy/`:
  `t9_soak.sh` (phased steady / subscriber-churn / publisher-churn), `leak_probe.sh` (publishers with
  **no** subscriber — the EC2 condition), `session_leak.sh` (retained memory per completed session).
- **EC2 rigs** in `~/t9/` on the box: `fanout_ec2.sh` (fan-out envelope), `fanout_cpu_ec2.sh` (the
  same sweep with CPU attributed to relay / subscribers / whole box), `bitrate_cache_ec2.sh` (bitrate
  sweep and the bounded-cache control), `overhead_ec2.sh` (`tcpdump` wire-vs-payload),
  `soak_ec2.sh` + `soak_report.sh` (the phased soak and its per-role slope fit).
- **Source:** `~/CNNiEMEA2.ts` looped via `tsp regulate --pcr-synchronous` (≈ 9.93 Mbps). For the
  bitrate sweep, `t9_2mbps.ts` and `t9_27mbps.ts` were encoded on the box from that clip
  (verified at 2.000 and 27.500 Mbps). Note `ffmpeg` needs `-nostdin` when invoked inside a
  heredoc-fed remote shell, or it consumes the rest of the script as input.
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

## ≥ 24 h multi-role soak: running (launched 2026-08-07 13:29 UTC)

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

**Known limitation of this run: there is no long-lived publisher to fit a slope against.** The
looped-file publishers die at every clip wrap (below), so the publisher role restarts roughly every
ten minutes and systemd replaces it. The relay slope — the decisive measurement, and the role that
actually failed on 0.13.7 — is unaffected, and the restarts are arguably a *better* test of it than a
quiet publisher would be: they reproduce the ~one-session-per-ten-minutes churn the leaking relay saw
(52 sessions in 9 hours). But a slow publisher-side leak is not excluded by this run. An attempt to
add a non-wrapping synthetic publisher was abandoned because it cost too much CPU to run alongside
the soak (below).

Also note the first ~15 minutes of the CSV are perturbed by the experiments that were still finishing
on the box (relay RSS briefly reached 124 MB). Fit past a generous warm-up — `WARMUP=3600` rather
than the default 900 — when analysing.

## Two publisher-side observations from building the soak (2026-08-07)

Neither was the object of the test, both are worth following up, and one of them is a plausible
upstream report.

**`moq import` aborts the process on a source discontinuity.** Every looped-file publisher on the box
dies at the clip boundary with `Error: missing MP2 frame sync`, taking the whole `ffmpeg | moq import`
pipeline with it (`status=1/FAILURE`, then a systemd restart). This is the same failure recorded as a
T8 gotcha, seen here as a *recurring* production behaviour rather than a one-off: it fires reliably
every ~600 s, i.e. once per wrap of the 600 s clip. It is a rig annoyance for a soak, but the
broadcast reading is less comfortable — a real contribution feed does glitch, and a publisher that
exits rather than resynchronising turns a momentary source defect into a full session teardown and
reconnect. Worth confirming against a deliberate mid-stream discontinuity before reporting, since a
looped file is an artificial discontinuity (the timeline jumps backwards, which a real feed does not).

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

- **The ≥ 24 h soak verdict**, once the run above completes (~2026-08-08 16:00 UTC). This is the
  last item standing between T9 and a pass. Pair a future repeat with the T7 ≥ 24 h PLL-lock soak so
  one run yields both verdicts.
- **Fan-out over a real path**, relay and subscribers on separate hosts. Both sweeps so far are
  loopback, and the Linux sweep showed why that matters: co-located subscribers cost 2.4x the relay,
  so the rig's knee is the host's. A cross-machine run would price the NIC and the network stack
  honestly and establish the relay's own knee, which neither sweep reached.
- **Overhead under loss.** The ~1.12x carriage figure is from a clean loopback path with no
  retransmission. The number that matters commercially is what it becomes over a real path with
  loss, and how it compares to the same measurement on SRT (T8 has the rig for this).
- **Per-role envelope for the groomer/pacer**, which the objective asks for and none of these runs
  covers.
- **A publisher-role slope**, which this soak cannot give (see the limitation above). Needs either a
  source long enough not to wrap inside the run, or the discontinuity-robustness question below
  resolved.
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
