# Test 43 — Fan-out on the current build: the slope, channel count, a two-tier relay, and an hour

**State: S1–S3 run, S1 with GSO on and off; S4, the hour, deferred. The current build does not
reproduce T26's model: it costs 1.26 % of a core and 2.6 MB per subscriber with GSO on, against
0.806 % and 1.39 MB on T26's quinn build. GSO is not the difference: it saves 25 % of the CPU slope
here and 29 % on T26's build, and the gap between the builds is about half again with it off as on.
Each carried channel adds about 2 % of a core and 60–69 MB at the relay's default 30 s retention, and
the memory is that retention: at 5 s, twelve channels hold 196 MB instead of 766 MB. A clustered edge
costs what a lone relay does, and its origin sends one copy whatever the audience.** Measured at P1,
cross-host in one region, on `ffa5b81b` (`moq-relay` 0.15.1, noq, BBRv3), GSO on unless stated.

[T26](test-26-cross-host-fanout.md)'s scaling model — 0.806 % of a core, 1.39 MB and one full stream
copy per remote subscriber — was measured on `moq-relay` 0.14.15, on quinn. Upstream has since deleted
the quinn backend, so every current build runs on noq and the build that model describes no longer
exists. T26 also states three limits of its own: one broadcast throughout (*"Nothing about channel
count"*), one relay, and 45 s per point. This test re-measures the slope on the current build and
takes each of those limits as far as the existing two hosts reach: channel count, a second relay
tier, and an hour at N = 100.

## Objective

1. **The slope on the current build.** Does T26's per-subscriber relay CPU, RSS and egress hold on
   `ffa5b81b` (noq), and does the relay still bind on its own CPU?
2. **Channel count.** At a fixed audience, does relay cost grow with the number of broadcasts it
   carries, or only with the number of subscribers?
3. **A two-tier relay.** With the edge relay clustered to an origin relay, is the edge's
   per-subscriber cost unchanged, and does the origin carry one copy whatever the edge's audience?
4. **An hour at N = 100.** Does delivery, continuity and the relay's working set hold still when the
   fan-out is held rather than ramped?

## Environment

T26's topology: the relay under test alone on the 2-vCPU primary (standing services left running on
their own ports and measured in `meta.txt`), publishers and subscribers on the 8-vCPU secondary, the
two hosts in separate availability zones of one region, 0.72 ms apart. GSO on, `delay` controller
(BBRv3 on noq). Both hosts run `ffa5b81b`. The clip is `CNNiEMEA2.ts` through the continuous source
generator, as in T26.

## Procedure

Rigs: [`f5-relay-side.sh`](scripts/f5-relay-side.sh), [`f5-sub-side.sh`](scripts/f5-sub-side.sh),
[`f5-reset.sh`](scripts/f5-reset.sh), graded by [`f5-grade.py`](scripts/f5-grade.py). T26's additive
ramp, 0.15 s between arrivals, 45 s settle and 45 s measure, with T26's stopping conditions, plus one
the soak taught (the subscriber host below 2.5 GB available, [`f5-soak-side.sh`](scripts/f5-soak-side.sh)).

| Arm | Relay under test | Publishers | Schedule (subscribers) |
|---|---|---|---|
| **S1** slope | `ffa5b81b` on the primary | one, to the relay under test | 1, 5, 10, 25, 50, 75, 100, 125, 150 |
| **S1, GSO off** | the same, `GSO=false` (`--server-quic-gso=false`) | the same | 1–75, then 1 and 100, as S1 was run |
| **S2** channels | the same | C = 1, 4 and 12, one run each; subscribers dealt across them in turn | 0, 12, 48 |
| **S2, 5 s retention** | the same, `RELAY_EXTRA="--cache-duration 5s"` | C = 12 | 0, 12 |
| **S3** two-tier | the same, as an edge with `--cluster-connect` to an origin relay on the secondary | one, to the origin | 1, 10, 50, 100 |
| **S4** soak | `ffa5b81b` on the primary | one | 100, held for 3,600 s, sampled every 20 s |

The 0 point in S2 measures the relay with only its publishers attached. In S3 the origin is sampled by
its own `f5-relay-side.sh` on the secondary. S4 runs on [`f5-soak-side.sh`](scripts/f5-soak-side.sh):
one subscriber graded for continuity, one by the per-stream liveness detector, and the run stops if
the subscriber host falls below 2.5 GB available, because the first high-fan-out soak recorded that
host's memory exhaustion as a delivery collapse.

## Pass criteria, fixed before running

- **S1: the model transfers** if the fitted per-subscriber relay CPU and RSS are each within ±20 % of
  T26's GSO-on arm, with the relay's own CPU the binding resource and the EC2 allowance counters at
  zero. Otherwise the current build has a different cost and the new figure replaces T26's for any
  sizing claim about current builds.
- **S2: cost follows the audience, not the channels,** if relay CPU at 48 subscribers differs by no
  more than 20 % between C = 1 and C = 12 once the 0-point ingest cost is subtracted. The ingest cost
  per channel is reported either way.
- **S3: the tree holds** if the edge's per-subscriber CPU slope is within ±20 % of S1's and the
  origin's CPU and egress at 100 subscribers are within 20 % of their values at 1 subscriber.
- **S4: an hour holds** if all 100 subscribers stay alive, the graded subscriber shows no continuity
  error and the liveness detector no alarm, and per-subscriber delivery stays at or above 95 % of its
  first sample throughout. The relay's RSS over the hour is reported as a trend, not graded, because
  T21 found its growth logarithmic and an hour cannot separate that from a plateau. A stop on the
  subscriber host's memory is a harness result and is reported as one.

## Limits, stated in advance

- One region, 0.72 ms apart: nothing here is about a wide-area path, as in T26.
- Subscribers are `moq export ts` without a pacer, so delivery and continuity are graded, not the CBR
  wire.
- The ramps hold each point for 45 s, and the soak holds for an hour: neither is a permanence claim.
- A two-tier cluster on two hosts has one edge; how cost behaves across many edges is not measured.

## What the run could not do as specified

- **No publisher on this build outlives one pass of the clip.** The continuous source generator's
  first join, about 596 s in, ends `moq import ts` with *frame timestamp is below the live edge*, the
  defect [T40](test-40-continuous-join-through-srt.md) found and [T41](test-41-import-reanchor-coverage.md)
  re-measured on this build. It ended the first S1 ramp at N = 100, taking 41 subscribers with it.
  The standing looped publisher on the primary shows the same failure. S1 was therefore run as two
  ramps, each inside one publisher lifetime: 1–75, then 1 and 100.
- **The subscriber host holds about 100 exporters, not 150.** At N = 100 it had 2.2–2.5 GB available
  and the ramp stopped on its memory guard after the point was measured. N = 125 and 150 were not
  reached, so the relay's ceiling on this build is extrapolated, not measured.
- **S2's 0 point measures no ingest.** The relay pulls a broadcast only when something subscribes to
  it, so at N = 0 no media reaches it: 0.2–1.0 % of a core and 19–29 MB whatever the channel count.
  The subtraction the criterion specifies is of nothing, and the channel comparison includes each
  channel's ingest.
- **S3's origin egress is a port counter, not the NIC.** On the secondary the subscribers'
  acknowledgements to the edge share the interface with the origin's copy and outweigh it, so the
  origin's traffic to the edge was counted by an iptables rule on its source port
  ([`udp-port-acct.sh`](scripts/udp-port-acct.sh)).
- **S4 is not run.** Both limits above bind it: a clip-fed publisher would end it at ten minutes, and
  100 exporters leave the host at its memory guard before they have grown. A live-encoder source with
  no lap ([`ts-testsrc-live.sh`](scripts/ts-testsrc-live.sh), `SOURCE=` on the soak side) removes the
  first. The second needs a subscriber host with more memory, or fewer exporters per host.

Both hosts run with `net.core.rmem_max` and `wmem_max` at 4 MB, and the relay asks for 8 MB and warns.
That was true of every arm here; whether it was true in T26 is not recorded.

## Results

### S1 — the slope on the current build

| N | per-sub | relay CPU (% of a core) | relay/box | relay RSS | egress Mb/s | kpps | allowance |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9.93 M | 3.9 % | 17.4 % | 88.5 MB | 14 | 1.6 | 0 |
| 5 | 9.93 M | 8.9 % | 20.2 % | 125.6 MB | 50 | 5.4 | 0 |
| 10 | 9.91 M | 14.9 % | 23.6 % | 143.4 MB | 99 | 10.6 | 0 |
| 25 | 9.93 M | 33.0 % | 31.7 % | 173.1 MB | 249 | 26.5 | 0 |
| 50 | 9.95 M | 65.1 % | 50.2 % | 242.2 MB | 507 | 53.5 | 0 |
| 75 | 9.98 M | 97.0 % | 66.3 % | 296.2 MB | 747 | 78.2 | 0 |
| 100 ¹ | 10.02 M | 128.4 % | 82.1 % | 346.4 MB | 988 | 103.3 | 0 |

*¹ From the second ramp. Standing load on the relay host 12.4–13.3 % of its two cores before each
ramp.*

Fitted over 1–75: relay CPU = 2.32 + **1.258**·N % of a core (r² = 0.9999), RSS = 105.7 + **2.62**·N MB
(r² = 0.979), egress **9.99 Mb/s** per subscriber, a full copy. The N = 100 point from the second ramp
lands on the line: 128.1 % predicted, 128.4 % measured. Delivery is flat at 99.8–101.0 % of N = 1
throughout, both graded subscribers in each ramp counted every packet with no continuity error, and
the four EC2 allowance counters stayed at zero.

Against T26's GSO-on arm the CPU slope is **56 % higher** and the RSS slope **89 % higher**. At N = 100
the relay uses 128.4 % of a core against T26's 86.6 %, and 346 MB against 219 MB. The GSO-off arm
below shows that GSO is not the cause; what remains is the backend and the build, which no available
build separates, because none carries both the current code and quinn. By CPU alone the fit puts the
relay's own ceiling near 159 subscribers on two cores. The box, which also carries the standing load,
reaches 100 % near 127 by extrapolation of its own column. Neither is measured with GSO on.

### S1 with GSO off

The same build, host pair and schedule, with the relay started `--server-quic-gso=false`: 1–75 in one
ramp, then 1 and 100 in a second, each inside one publisher lifetime.

| N | per-sub | relay CPU (% of a core) | relay/box | relay RSS | egress Mb/s | kpps | allowance |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9.95 M | 4.4 % | 17.7 % | 85.2 MB | 13 | 1.6 | 0 |
| 5 | 9.94 M | 11.4 % | 22.2 % | 122.9 MB | 52 | 5.6 | 0 |
| 10 | 9.90 M | 19.4 % | 26.1 % | 136.2 MB | 99 | 10.6 | 0 |
| 25 | 9.93 M | 45.2 % | 39.9 % | 172.0 MB | 251 | 26.7 | 0 |
| 50 | 9.95 M | 87.1 % | 61.9 % | 240.2 MB | 496 | 52.0 | 0 |
| 75 | 9.99 M | 129.1 % | 81.0 % | 305.1 MB | 757 | 78.4 | 0 |
| 100 ³ | — | 164.2 % | 99.7 % | 1,300.6 MB | 726 | 73.2 | 0 |

*³ From the second ramp, and past the knee: see below. Standing load on the relay host 10.4–13.2 % of
its two cores before each ramp.*

Fitted over 1–75: relay CPU = 2.80 + **1.686**·N % of a core (r² = 1.0000), RSS = 100.2 + **2.77**·N MB
(r² = 0.986), egress 10.03 Mb/s per subscriber. Delivery is flat at 99.5–100.5 % of N = 1 through
N = 75, and both graded subscribers counted every packet with no continuity error.

- **GSO takes effect on noq and saves 25 % of the CPU slope** (1.686 % off, 1.258 % on), against 29 %
  on T26's quinn build (1.135 % and 0.806 %). The RSS slope does not move with it (2.77 MB off,
  2.62 MB on).
- **The gap to T26 is not GSO.** With GSO off on both builds the current one is 49 % higher on CPU,
  against 56 % with it on.
- **N = 100 is this host's knee with GSO off, measured.** The relay reached 164.2 % of a core with the
  box at 99.7 %, sent 726 Mb/s against the 995 Mb/s its hundred subscribers needed (73 %), and grew to
  1,300.6 MB, three and a half times the line's prediction. The plain subscriber skipped 19 evicted audio groups;
  the two graded subscribers counted every packet they received with no continuity error, and the
  exporters' output rate of 109 % of N = 1 is their catch-up after stalls, not surplus delivery. The
  fit, with the standing load subtracted, predicts the relay's own ceiling at about 101 subscribers,
  which is where it failed. With GSO on, the same host held 100 at 128.4 % of a core, so on a
  2-vCPU relay the offload is the difference between about 100 subscribers and, extrapolated, about
  127–159.

### S2 — channel count at a fixed audience

| Channels | relay CPU, N = 12 | relay RSS, N = 12 | relay CPU, N = 48 | relay RSS, N = 48 |
|---:|---:|---:|---:|---:|
| 1 | 17.8 % | 100.8 MB | 60.2 % | 229.4 MB |
| 4 | 23.3 % | 308.0 MB | 67.3 % | 489.3 MB |
| 12 | 39.7 % | 766.1 MB | 88.0 % ² | 1,373.6 MB ² |

*² The subscriber host was 86.2 % busy, above T26's 85 % limit, twelve publisher chains taking 57 %
of it before any subscriber; per-subscriber delivery 98.2 %. The ramp stopped there, on that
condition.*

Subscribers were dealt across the channels in turn, so at N = 12 with twelve channels each channel
has one subscriber. **Each carried channel adds about 1.8–2.0 % of a core and 60–69 MB** at N = 12
(from one channel to four, and from one to twelve). At N = 48 twelve channels cost 46 % more CPU than
one, against the ≤ 20 % the criterion allowed. Per-subscriber delivery was 98.2–100.4 % in every run,
and the graded subscribers counted no continuity error.

The memory term is the larger for sizing: at 60–69 MB a channel, an edge carrying a hundred 10 Mb/s
channels would hold 6–7 GB before its first subscriber on each. It is not the per-group stream-slot
retention of [evidence §3.6](../docs/evidence.md), which at about 9 KiB a group comes to under 2 MB for
a channel connected for three minutes.

**What holds it is the relay's media retention.** From the code at `ffa5b81b`: every media track the
TS importer publishes declares a 30 s retention (`MAX_AGE`, `rs/hang/src/container/mod.rs:13`, applied
to media tracks and not to the catalog, per the tests in `rs/hang/src/container/frame.rs:181–203`),
and the relay's group cache keeps a non-latest group until it has gone unread for its LRU window,
30 s by default (`DEFAULT_EXPIRY`, `rs/moq-net/src/model/cache.rs:83`, applied at
`rs/moq-relay/src/cache.rs:106–112`). `--cache-duration` sets that window and clamps each track's own
retention to it (`rs/moq-relay/src/cache.rs:46–62`); `--cache-capacity` bounds bytes instead and is
unbounded by default. Thirty seconds of a 10 Mb/s channel is 37.5 MB of payload before the per-group
and allocator overhead, so the code predicts most of the per-channel figure and predicts that a
shorter window cuts it in proportion.

| C = 12, N = 12 | relay CPU | relay RSS | per-sub | continuity | evicted groups |
|---|---:|---:|---:|---:|---:|
| default retention (30 s) | 39.7 % | 766.1 MB | within 98.2–100.4 % | 0 errors | not counted |
| `--cache-duration 5s` | 40.8 % | 195.8 MB | 9.93 M, 100.0 % | 0 errors, both graded subscribers | 0 |

The relay confirmed the ceiling at start (`cache duration ceiling set duration=5s`). **The shorter
window released 570 MB, 47.5 MB a channel**, against 31 MB of payload for 25 s less of a 9.95 Mb/s
stream: a ratio of about 1.5 between memory held and payload retained, which also accounts for the
60–69 MB a channel at 30 s. CPU did not move. So the cost of a carried channel is set by
configuration, at roughly 1.5 × bitrate × retention window, derived from one reduction on one build.
What the window buys is history: it bounds how far back a late joiner, a segmented egress's fetch or a
subscriber recovering from a stall can reach at the relay, and
[T12](test-12-dual-path-handoff.md) measures what 5 s does to a 25 s stall. The ~200 MB long-run budget
per ingested channel in [architecture §8.3](../docs/architecture.md) is growth above a baseline in a
different structure, the QUIC library's stream slots, where this term is present from the first
minute, so the two add; that is reasoned, and they have not been measured together.

### S3 — an edge clustered to an origin

The origin ran on the secondary with the publisher on loopback. The edge ran on the primary with
`--cluster-connect` to the origin, and the subscribers connected to the edge.

| N | per-sub | edge CPU | edge RSS | origin CPU | origin RSS | origin → edge |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 9.95 M | 3.6 % | 80.4 MB | 4.1 % | 89.1 MB | 9.66 Mb/s |
| 10 | 9.91 M | 16.3 % | 130.3 MB | 4.7 % | 95.3 MB | 9.65 Mb/s |
| 50 | 9.74 M | 64.4 % | 234.3 MB | 5.4 % | 94.7 MB | 9.40 Mb/s |
| 100 | 9.84 M | 126.2 % | 344.1 MB | 6.2 % | 96.8 MB | 9.66 Mb/s |

The edge's slope is 1.231 % of a core per subscriber (r² = 0.9999) and 2.57 MB, **about 2 % below
S1's on both**, and at N = 100 it matches a lone relay (126.2 % against 128.4 %; 344 against 346 MB). The
origin sends **one copy** whatever the edge's audience, 9.40–9.66 Mb/s from 1 subscriber to 100. Its
RSS rises 9 %, and its CPU rises from 4.1 % to 6.2 % of a core, **51 %**, which fails the criterion's
20 %. In absolute terms that is 2.1 points on a host whose subscribers had it 64 % busy. Whether it is
contention there or work the edge's audience causes at the origin is not separated. The arm that
separates them is the origin on a third host. Delivery 97.9–100 %, no continuity error.

## Against the pass criteria

| Arm | Criterion | Result |
|---|---|---|
| S1 | CPU and RSS slopes within ±20 % of T26's GSO-on arm; relay CPU binding; allowance counters zero | **Fails.** +56 % CPU and +89 % RSS. Allowance counters zero; with GSO on the ceiling is not reached, and with GSO off it is reached at N = 100 on the relay's own CPU with the counters still at zero. T26's model does not describe the current build |
| S2 | CPU at N = 48 within 20 % between one and twelve channels | **Fails.** +46 %, with the twelve-channel point at the harness's limit; +123 % at N = 12, where it is not |
| S3 | Edge slope within ±20 % of S1's; origin CPU and egress at N = 100 within 20 % of N = 1 | **Edge passes** (−2 %). **Origin egress passes** (one copy). **Origin CPU fails** (+51 %, 2.1 points, unattributed) |
| S4 | An hour at N = 100 holds | **Not run** (§ *What the run could not do as specified*) |

The GSO-off and 5 s-retention arms were characterisations with no criterion fixed in advance.

## Conclusions

- **Sizing on current builds uses 1.26 % of a core and 2.6 MB per subscriber with GSO on**, not T26's
  figures, which describe a quinn build that no longer exists. Egress is unchanged: one full copy per
  subscriber. With GSO off the CPU slope is 1.69 %, and a 2-vCPU relay reaches its knee at about 100
  subscribers, measured. GSO does not explain the difference from T26.
- **Channel count is a cost of its own.** Each carried channel adds about 2 % of a core and, at the
  default 30 s retention, 60–69 MB, so a relay's cost is a function of channels and audience, not
  audience alone. The memory is the retention window, about 1.5 × bitrate × window, and is set by
  `--cache-duration` against the history the relay can serve.
- **A two-tier tree costs the edge no more than a lone relay, and the origin sends one copy.** That is the
  property a distribution tree needs, measured with one edge; many edges are not.
- **The limits that stopped this test are the client's, not the relay's:** the importer's exit at the
  clip's first lap, and `moq export ts`'s memory per process.

## What remains

- **The ceiling with GSO on**, N = 125–200, which needs a second subscriber host or a lighter
  subscriber. The GSO-off knee is measured.
- **What separates the current build from T26's**, now that GSO is excluded. The backend and the
  build change together in every available build, so only a profile of the relay's send path on
  the current build can say where the extra half goes.
- **The origin's CPU on a third host**, which separates the origin's own work from contention with
  the subscribers.
- **S4**, on a live-encoder source, with a subscriber host that holds 100 exporters for an hour.
