# Test 26 — Cross-host fan-out: the scaling model, and whose limit the knee is

**State: complete, three arms. The relay's marginal cost per subscriber is small, constant and
linear, and the first resource to bind is the relay's own CPU — at a point the model predicts.**
Driving the subscribers from a second host retires the caveat on every fan-out figure in this paper:
[T9](test-9-performance.md)'s knee at N = 55 was the *box*, and cross-host the same relay class
carries **150 subscribers at 1,426 Mb/s aggregate** with per-subscriber delivery flat within 1.5 %.

The model, fitted over the points that held delivery and identical in shape across all three arms:

| Per additional subscriber | Cost | Fit |
|---|---|---|
| Relay CPU | **0.806 % of a core** (0.719 % pinned) | linear, r² = 0.998 |
| Relay RSS | **1.39 MB** | linear, r² = 0.9997 |
| Relay egress | **9.84 Mb/s — a full copy** | linear, r² = 0.9996 |

Three findings matter more than the maximum:

- **The binding resource is relay CPU, proven rather than assumed.** All four of EC2's interface
  allowance counters stayed at **zero** through every arm, the subscriber host was at 39–65 % busy at
  each cliff, and pinning the relay to one core moved the cliff to exactly where the slope said it
  would be — collapsing with the relay at **99.9 % of its single core**.
- **Saturation is a collapse, not a degradation.** Past the cliff aggregate throughput *falls* —
  1,184 → 528 Mb/s in one arm, 964 → 46 Mb/s in another — while relay CPU stays pinned at its limit
  and relay RSS balloons 2.5×. Nobody is thinned fairly; everybody is broken together.
- **"Near-zero marginal cost fan-out" is false as stated, and the true statement is still good.**
  Each subscriber costs a full copy of the stream on the wire. What is nearly free is *state*:
  1.39 MB per subscriber against ~10 Mb/s of delivery means the group cache is genuinely shared, and
  nothing in the curve is superlinear.

Specified as the MoQ half of [P1-f](planned-experiments.md#p1--establishes-where-one-architecture-is-superior). Rigs:
[`f5-relay-side.sh`](scripts/f5-relay-side.sh), [`f5-sub-side.sh`](scripts/f5-sub-side.sh),
[`f5-reset.sh`](scripts/f5-reset.sh), graded by [`f5-grade.py`](scripts/f5-grade.py). Raw samples in
[`results/f5/`](results/f5).

## Objective

Establish the shape of the relay's cost curve as remote subscriber count rises, identify the first
resource that binds, and separate that from the limits of the host and of the test rig.

The question is not the maximum N. [`economics.md`](../docs/economics.md) rests on a claim about
*marginal* cost per receiver, and a maximum observed once on one box does not support or refute it.
What supports it is a slope with a stated confidence and a named binding resource.

## What was already known, and precisely what it left open

[T9](test-9-performance.md) measured fan-out twice and both times on one host with the subscribers
co-resident with the relay. It found a knee at N = 55 and then did the work to disown it: attributing
CPU three ways showed the subscriber processes cost **118 % of a core against the relay's 48 %**, so
the rig hit 94 % of both cores while the relay was using under half of one. Its own conclusion was
that *"any loopback fan-out rig therefore measures the box, not the relay"*, and it carried forward an
estimate — ~0.089 % of a core per Mb/s, one core ≈ 1.1 Gb/s ≈ 110–120 sessions — explicitly as an
extrapolation.

So what was open was not the direction but three specific things: whether the relay has a knee of its
own and where, whether the loopback *slope* survives a real network stack, and what a subscriber costs
when it is not stealing the relay's cores.

## Topology

```
  primary — c6in.large, 2 vCPU, 4 GB, 3.125 Gb/s sustained NIC
    moq-relay ALONE  (0.0.0.0:4443)

        ▲ 11 Mb/s ingress                    ▼ N × 9.6 Mb/s egress
        │                                    │
  secondary — c6in.2xlarge, 8 vCPU, 16 GB
    ts-continuous-source.py │ tsp regulate │ moq import ts
    N × moq export ts   (2 of them graded in-stream by tsp -P continuity)
```

**The publisher runs on the subscriber host, not beside the relay.** The source chain costs an
appreciable fraction of a core, and on a 2-vCPU relay host that fraction comes off exactly the
resource whose ceiling is being measured. Moving it costs one 11 Mb/s ingress stream and buys a relay
host whose CPU is the relay's alone — which is the entire point of the arm.

The two hosts are in separate VPCs in one AWS region — `eu-west-1a` and `eu-west-1b` — so the path is
a real network stack with real QUIC, real TLS and a real NIC. **RTT is 0.72 ms** (mean TCP handshake
over five samples, max 0.81 ms; ICMP is blocked between them, so ping is not available). **It is not a
wide-area path**, and §Limits says what that forbids concluding.

Both hosts were checked before each run by `f5-reset.sh`, which kills prior processes and then
*verifies* none survived. The relay host also carries standing CNN services costing a steady
**12.8–13.3 % of its two cores**; these were left running, measured, and recorded in each run's
`meta.txt`. Per-process accounting keeps them out of the relay's own CPU figure, but they do move the
box's saturation point earlier, which is why the relay's own utilisation is reported beside the box's
rather than instead of it.

## Procedure

Subscribers are added to a live relay in an additive ramp — never torn down between points, so no N
is a fresh warm-up — with **0.15 s between arrivals**. The pacing is deliberate:
[T25](test-25-isolation-under-abuse.md) established that subscribers *arriving and leaving* cost the
relay an order of magnitude more than being present, and this experiment is about presence. At each N,
45 s to settle then 45 s to measure.

Per-subscriber delivered rate is a `/proc/<pid>/io` `wchar` delta — the receiver's own account of what
arrived, not the relay's claim about what it sent. The reference rate is **measured at the first
schedule point** rather than declared: a subscriber here is `moq export ts` with no pacer behind it,
so what arrives is the exporter's ~9.6 Mb/s media stream, not the 11 Mb/s CBR wire the pacer emits in
[T19](test-19-pcr-grid-verification.md)/[T21](test-21-permanence-soak.md).

Media integrity is graded **in-stream**: two subscribers pipe through `tsp -P continuity -P count`,
which counts errors and packets and discards the bytes. `continuity` is silent when nothing is wrong,
so `count` runs beside it — otherwise an empty log means both "no errors" and "no bytes".

### Stopping conditions, fixed before the runs

Each names which side is responsible, because a ramp ending is not a finding unless it says what ended
it: per-subscriber delivery below **95 %** of the N = 1 rate; the subscriber host above **85 %** busy
(*the harness is the limit, not the relay*); any subscriber exiting; the publisher exiting.

## Results

Relay-side and subscriber-side samples are collected by separate scripts on their own hosts and joined
on wall clock, so both halves of a row describe the same 45 s.

### Arm A — GSO disabled, relay on both cores

The configuration this campaign inherited. Delivery is flat to N = 100 and then collapses.

| N | per-sub | % of N=1 | aggregate | relay CPU | relay/box | relay RSS | egress | kpps | allowance | subs cores | sub box |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9.58 M | 100.0 % | 10 | 3.2 % | 17.3 % | 87.7 MB | 11 | 1.3 | 0 | 0.03 | 3.2 % |
| 5 | 9.57 M | 99.9 % | 48 | 8.9 % | 20.6 % | 98.2 MB | 50 | 5.4 | 0 | 0.16 | 5.1 % |
| 10 | 9.56 M | 99.7 % | 96 | 15.8 % | 24.4 % | 103.4 MB | 99 | 10.7 | 0 | 0.34 | 7.5 % |
| 25 | 9.56 M | 99.8 % | 239 | 33.6 % | 33.7 % | 119.5 MB | 249 | 26.5 | 0 | 0.84 | 14.3 % |
| 50 | 9.57 M | 99.9 % | 478 | 61.1 % | 48.6 % | 158.9 MB | 490 | 51.7 | 0 | 1.72 | 26.0 % |
| 100 | 9.64 M | 100.7 % | **964** | 116.6 % | 75.0 % | 228.8 MB | 997 | 103.6 | 0 | 3.65 | 52.5 % |
| 150 | **0.31 M** | **3.2 %** | **46** | 165.4 % | **99.6 %** | 342.2 MB | 1337 | 136.2 | **0** | 4.40 | 65.3 % |

Relay CPU = 3.71 + **1.135**·N % of a core (linear r² = 0.9993; a quadratic adds nothing and its x²
term is *negative*, so there is no superlinearity to find). The collapse is the relay **host** out of
CPU — 99.6 % of two cores — while the subscriber host sat at 65 % and all 150 sessions stayed alive.

### Arm B — GSO enabled, relay on both cores

`--server-quic-gso=false` is carried through this campaign's start commands, and the reason on record
is that *GSO stalls on macOS loopback*. These hosts are Linux. Enabling it is not a tuning
optimisation but a correction: arm A measured a deliberately handicapped relay.

| N | per-sub | % of N=1 | aggregate | relay CPU | relay/box | relay RSS | egress | kpps | allowance | subs cores | sub box |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9.58 M | 100.0 % | 10 | 2.6 % | 16.9 % | 83.8 MB | 10 | 1.2 | 0 | 0.03 | 3.2 % |
| 25 | 9.59 M | 100.1 % | 240 | 23.4 % | 28.2 % | 118.1 MB | 246 | 26.2 | 0 | 0.73 | 12.8 % |
| 50 | 9.61 M | 100.3 % | 480 | 46.1 % | 40.3 % | 153.3 MB | 498 | 53.0 | 0 | 1.56 | 23.9 % |
| 100 | 9.46 M | 98.8 % | 946 | 86.6 % | 60.5 % | 219.3 MB | 1007 | 106.4 | 0 | 3.26 | 47.4 % |
| 150 | 9.51 M | 99.2 % | **1,426** | 122.3 % | 78.9 % | 292.1 MB | 1468 | 154.2 | 0 | 5.18 | 72.5 % |
| 200 | 5.10 M | 53.2 % | 964 | 99.2 % | 66.4 % | 350.9 MB | 1157 | 120.1 | **0** | 3.46 | 66.7 % |

Relay CPU = 3.63 + **0.806**·N % of a core (r² = 0.9980) — **29 % cheaper per subscriber than arm A**,
for one flag. N = 150 that collapsed to 46 Mb/s in arm A now delivers **1,426 Mb/s at 99.2 %**.

**N = 200 is the harness failing, and the log says so exactly.** Eleven subscribers were SIGKILLed;
`dmesg` on the subscriber host shows `tokio-rt-worker invoked oom-killer` and
`Out of memory: Killed process … (moq)`. Client memory in this ramp (45 s per point — **not** current
finding on per-process cost):

| N | `moq export ts` RSS (45 s snapshot†) |
|---:|---:|
| 1 | **95.6 MB** |
| 150 | **103.3 MB** |

†Early fill on the time axis, not steady state — [T27](test-27-liveness-detector.md) held N fixed and
measured the same process **49.0 → 119.1 MB over 703 s**, plateau **116–122 MB** with drawdowns (a
cache, not a fixed cost); a per-N ramp cannot measure a time-varying quantity. Even on the early axis,
150 clients occupy 15.1 GB of the box's 15.7 GB, so the client's footprint, not the relay, sets this
rig's ceiling. **~120 MB, not ~96 MB, is the figure to plan against** — see [Corrections](#corrections).

### Arm C — GSO enabled, relay pinned to one core

Arm B leaves the relay's own ceiling out of reach: the slope projects ~248 subscribers on two cores
and the harness dies at ~150. Pinning the relay with `taskset -c 0` halves the prediction to ~124 and
brings the cliff inside range. **This is the arm that turns a fitted slope into a tested one.**

| N | per-sub | % of N=1 | aggregate | relay CPU | relay/box | relay RSS | egress | kpps | allowance | subs cores | sub box |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 25 | 9.58 M | 100.0 % | 240 | 16.4 % | 24.8 % | 114.5 MB | 247 | 26.2 | 0 | 0.71 | 12.5 % |
| 50 | 9.61 M | 100.3 % | 481 | 31.2 % | 32.7 % | 151.2 MB | 485 | 51.3 | 0 | 1.53 | 23.5 % |
| 75 | 9.63 M | 100.5 % | 722 | 47.3 % | 40.6 % | 183.9 MB | 733 | 77.8 | 0 | 2.52 | 36.6 % |
| 100 | 9.69 M | 101.1 % | 969 | 65.0 % | 49.4 % | 216.0 MB | 988 | 104.1 | 0 | 3.57 | 51.0 % |
| 125 | 9.48 M | 98.9 % | **1,184** | 89.3 % | 60.7 % | 256.6 MB | 1246 | 129.4 | 0 | 4.75 | 68.4 % |
| 150 | **3.52 M** | **36.7 %** | 528 | **99.9 %** | 61.0 % | **646.6 MB** | 246 | 25.6 | **0** | 2.71 | 38.7 % |

**The prediction held.** 0.719 % of a core per subscriber projects a single-core ceiling of ~139;
delivery is clean at 125 and collapses at 150, with the relay at **99.9 % of its one core** while its
host is only 61 % busy, the subscriber host is 38.7 % busy, and all 150 sessions are alive. There is
no other candidate left standing.

Note the relay's RSS at the cliff: **256.6 → 646.6 MB**, a 2.5× jump as queues back up behind a CPU
that cannot drain them.

### What the three arms agree on

The per-subscriber **memory** cost is the most stable number in the experiment — **1.404, 1.388 and
1.396 MB** across arms A, B and C, against fixed costs of 88.1, 82.9 and 79.8 MB. Egress is
9.84–10.00 Mb/s per subscriber, i.e. one full copy, with no thinning at any N that held. Relay
**threads** stayed at 3 (2 when pinned) and **file descriptors at 11**, unchanged from N = 1 to
N = 200 — every QUIC connection shares one UDP socket, so fd exhaustion is not a fan-out failure mode
here.

### Media integrity, and an incidental verification

Across arms B and C the in-stream graders counted **2,720,637 of 2,720,637** and **3,245,214 of
3,245,214** packets with **zero continuity errors**, spanning fan-out from 1 to 200 subscribers *and
two collapse events*. No subscriber log in any arm contains a single error line.

That last fact also retests [#3491](https://github.com/moq-dev/moq/issues/3491), closed overnight by
[#3515](https://github.com/moq-dev/moq/pull/3515) — a group consumer now answering for its own read
cursor, so an evicted group skips instead of ending the export. These runs put **450 subscriber
sessions** through sustained deep lag, including two episodes where per-subscriber delivery fell to
3–37 % of nominal for 45 s, which is exactly the eviction pressure that produced
`Error: hang: moq error: old`. **No session exited with that error, or any error.** The only exits
anywhere were the kernel's OOM kills on the subscriber host. This is incidental rather than a designed
regression test, and it is the strongest evidence available here that #3515 holds under load.

## What this establishes

1. **A scaling model with a named binding resource.** Relay cost is linear in subscribers on all three
   axes, at 0.806 % of a core, 1.39 MB and one stream copy each. CPU binds first, at **124–139
   subscribers per core** ≈ **1.2–1.34 Gb/s of egress per core** at this bitrate.
2. **T9's knee was the test topology, and its slope was not.** The N = 55 knee does not survive
   moving the subscribers off the box. But T9's extrapolated ~110–120 sessions per core, measured with
   co-resident subscribers, brackets the 124–139 measured here — so the loopback rig was estimating the
   relay's *rate* of cost correctly even while its ceiling was an artefact.
3. **Fan-out does not degrade delivery until it breaks it.** Per-subscriber rate held within 1.5 %
   from N = 1 to the last clean point in every arm; the relay serves every subscriber the whole feed
   rather than thinning under load.
4. **Configuration outweighs everything else measured.** One flag moves per-subscriber CPU by 29 % and
   the usable ceiling by 50 %. Any capacity number for this lane is a number about a *configuration*.
5. **Neither the NIC nor session management is close to binding.** 154 kpps and 1.47 Gb/s on a
   3.125 Gb/s interface with all four allowance counters at zero; threads and fds flat across a 200×
   fan-out.

## What it does not establish

- **Nothing about a wide-area path.** Two hosts, one region, 0.72 ms RTT, no loss, no competing traffic,
  and one RTT for every subscriber. Real fan-out has diverse RTTs and congestion control doing real
  work, and per-subscriber CPU is likely a function of both. This is a *relay capacity* result, not an
  internet-scale one, and it must not be quoted as the latter.
- **Nothing about the CBR wire at scale.** Subscribers here are `moq export ts` with no pacer, so what
  is graded is delivery and continuity, not conformance. The conformant-wire result remains
  T19/T21's, at N = 1.
- **No absolute capacity for a production relay.** A 2-vCPU host carrying 13 % of standing load is the
  instrument, not a recommendation. The transferable results are the slope and the per-core figure.
- **Nothing about channel count.** One broadcast, one publisher throughout. Whether cost grows with
  channels as it grows with audience is untested here, and T9's reading that it grows with channels
  rather than audience is *not* what this measured.
- **Nothing beyond 45 s at any N.** This is a capacity curve, not a soak. Permanence at high fan-out —
  in particular whether the relay's logarithmic memory growth from [T21](test-21-permanence-soak.md)
  holds when 150 subscriptions are attached to it — is not settled here.
  [T27](test-27-liveness-detector.md) holds N = 60 for 90 minutes, which is a start and not a
  permanence claim.
- **The client's per-process memory is characterised but not attributed.**
  [T27](test-27-liveness-detector.md) establishes the shape — a cache filling to 116–122 MB, with
  memory given back along the way — but not what occupies it. `--latency-max 3s` here against
  T21's 500 ms is the obvious suspect and is untested.

## How this reads against T25

The two results are complementary rather than in tension, and together they say relay memory has three
regimes:

| Regime | Cost | Source |
|---|---|---|
| **Presence** — subscribers attached and served | 1.39 MB each, linear | this test |
| **Churn** — subscribers arriving and abandoning | up to 1.9 GB transient, set by the QUIC idle timeout | [T25](test-25-isolation-under-abuse.md) |
| **Saturation** — CPU exhausted, queues backing up | 2.5× the steady-state working set | this test, arm C |

The scaling curve is therefore a **floor**, and deliberately so: the ramp paces arrivals 0.15 s apart
precisely to exclude T25's effect. Capacity planning needs the sum — size for presence, keep headroom
for churn × idle timeout, and never run near the CPU limit, because the third regime arrives at the
same moment as the collapse and a memory-constrained relay would meet the OOM killer rather than
merely slow down.

## Corrections

**Believed:** `--server-quic-gso=false` is the correct relay configuration on Linux EC2.
**True:** the flag entered the campaign for *macOS loopback* GSO stalls; on Linux it handicaps the relay
by 29 % per subscriber and half the ceiling — arm A was run before this was noticed.
**Rule:** a flag that works around a platform defect must record which platform, and be re-tested when
the platform changes.

**Believed:** the reference delivery rate for `moq export ts` subscribers is 11 Mb/s (the pacer's CBR
figure).
**True:** subscribers here have no pacer; the first run "failed" at N = 1 by 18 % on the instrument
rather than the relay.
**Rule:** the reference rate is measured at the first schedule point, not asserted from a different
stage's wire rate.

**Believed:** `moq export ts` client memory is essentially fixed per process (~96 MB), barely moving
with N.
**True:** [T27](test-27-liveness-detector.md) shows it fills to a **116–122 MB** plateau over time; the
95.6 / 103.3 MB readings here are 45 s snapshots of an early fill.
**Rule:** pin the variable under test — a per-N ramp cannot characterise a quantity that varies with
time; see [method notes](method-notes.md).

**Believed:** a cleanup over ssh with `pkill -f "broadcast f5.fanout.hang"` clears the prior publisher.
**True:** the pattern matches the remote shell's own command line and kills it before the next statement;
a stale publisher survived and the run read as source failure at N = 1.
**Rule:** kill patterns belong in a script file, never in an ssh command line, and a reset must verify
that nothing survived — what `f5-reset.sh` exists to do.
