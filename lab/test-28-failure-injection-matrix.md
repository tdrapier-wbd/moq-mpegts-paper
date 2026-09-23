# Test 28 — Failure-injection and recovery matrix

**State: run in part, 2026-09-11. The MoQ lane's outage ladder is measured; the segmented lane and
the infrastructure axis are not.** Infrastructure and transport failures have been probed one at a
time in [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md), usually reported as
recovery *time*; what a distributor buys is programme continuity, and the two are not the same number.
This experiment applies one media-domain grader across a full matrix on both lanes.

**Headline: an outage shorter than the subscriber's latency budget costs nothing, and the programme
cost of a longer one scales with the budget rather than with the outage.** That is the opposite of the
intuition the register was built on, and it is the result an operator sizes against. Every cell
returned **0 continuity errors**: when this lane loses programme it loses whole groups cleanly, and a
receiver sees absence rather than corruption.

**What changed.** The reason this test had never run was that its shared grader did not exist, so no
cell could be scored in the media domain. **That grader now exists and has been validated against
known answers** — `lab/scripts/t28-media-lost.py`, with `lab/scripts/t28-grader-selftest.sh` as its
oracle. That discharges pass criterion 1 and removes the blocker the file previously named.

**The substrate was never missing.** The matrix needs `netem`/`tc` and Linux network namespaces,
which the campaign's macOS workstation does not have — but both EC2 Linux hosts do, and both had
already used them for [T5](test-5-network-impairment.md),
[T8b](test-8b-congestion-control.md) and [T20](test-20-segmented-http3.md). The transport axis now
runs on the **EC2 secondary** (8 vCPU / 15 GB, `eu-west-1b`), chosen over the primary because a
2 vCPU host cannot carry a relay, a publisher and a subscriber without the knee being the host's.
Substituting macOS dummynet would still be wrong, for the comparability reason, and was not done.
The method rule this cost is in [method-notes](method-notes.md) § Rig hygiene.

**Grader validation, measured.** Five cells, one command, `CNNiEMEA.ts` as the source:

| Cell | Injected | Measured lost | Measured duplicated | Continuity errors |
|---|---|---|---|---|
| control (unimpaired 80,000-packet slice) | — | **0.000 s** | 0.000 s | 0 |
| hole, 2,000 packets excised | 0.302435 s | **0.302435 s** | 0.000 s | 37 |
| hole, 10,000 packets excised | 1.512173 s | **1.512173 s** | 0.000 s | 62 |
| hole, 50,000 packets excised | 7.560866 s | **7.560866 s** | 0.000 s | 84 |
| repeat, 20,000 packets duplicated | 3.024345 s | 0.000 s | **3.024346 s** | 98 |

The control is clean and every injection is recovered inside the 100 ms margin criterion 1 fixes. The
duplication cell is there because duplication is a separate code path and a separate column: a stream
that loses five seconds and repeats five seconds has not broken even, and the grader is required not to
net them off. It does not.

**How much this validates, stated precisely.** The agreement is exact rather than merely within
tolerance because the oracle derives the injected duration from the clip's PCR timeline using the same
median-rate arithmetic the grader uses. That is a strong check on the *implementation* — it would have
caught a wrong CSV column, a PCR wrap bug, a sign error, or a rate reference moved by the holes being
measured, which are the failures this campaign has actually hit — but it is **not** an independent
check on the *method*. The independent corroboration is the continuity-error column, which comes from
a different tool and rises from 0 to 37–98 exactly where an excision or repeat was made, confirming
each capture was damaged as intended.

**The grader needed a second reference before it could score a live capture, and finding that out is
part of this result.** The validated arithmetic above compares elapsed PCR time against the bytes
between two PCR samples, which assumes a constant byte rate. That holds for a clip or a groomed
egress — the file domain, which is what the self-test exercises — and fails on a raw
`moq export ts` capture, because the exporter emits PCR-bearing packets in clusters
([T19](test-19-pcr-grid-verification.md)'s positional finding): the median packet gap between adjacent PCR
samples measured **6 packets** rather than the ~150 a CBR stream gives, so the rate estimate
collapsed to **0.361 Mb/s against a true 8.595 Mb/s** and the grader reported **1,254 s of
duplication in a 55 s capture**. The hole figure survived that corruption, because a hole is
dominated by its time term, but a grader that is right in one column and silently wrong in another is
not usable. `t28-media-lost.py` now takes `--domain {file,wire}`; `wire` references the stream's own
PCR cadence and ignores byte positions. **Both domains are validated against the same five known
answers** (`DOMAIN=wire bash t28-grader-selftest.sh`), the wire domain carrying a systematic offset
of one PCR cadence, well inside the 100 ms margin. Everything below is graded `wire`.

## Measured — the transport axis, MoQ lane

**Environment.** EC2 secondary, 8 vCPU / 15 GB, Ubuntu 26.04. Two network namespaces joined by veth
(`t8b-netns.sh`), `cake` at the bottleneck provisioned at 20 Mb/s, 100 ms base RTT (50 ms each way),
source a 120 s ~9.95 Mb/s CBR slice of `CNNiEMEA2.ts` paced with `tsp regulate --pcr-synchronous`.
Build `moq` 0.11.0-`fd4f5d82e`. `moq import ts` → relay → `moq export ts`, **no groomer in the
path**, captured at the subscriber. Rig: [`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh).
Outage = 100 % loss applied at the bottleneck for a fixed duration, 20 s after delivery settles.
Domain **wire**, measurement point **P1**, one sample per cell.

| Outage | `--latency-max` | Media lost | Holes | Largest hole | Continuity errors |
|---|---|---|---|---|---|
| none (control) | 3 s | **0.000 s** | 0 | — | 0 |
| 0.5 s | 3 s | **0.000 s** | 0 | — | 0 |
| 5 s | 3 s | **2.075 s** | 2 | 1.200 s | 0 |
| 30 s | 3 s | **30.125 s** | 2 | 29.625 s | 0 |
| 5 s | 1 s | **1.250 s** | 2 | 0.725 s | 0 |
| 5 s | 6 s | **0.000 s** | 0 | — | 0 |

**A 0.5 s outage is free**, and a 5 s outage costs nothing at all provided the latency budget exceeds
it — the relay's cache replays what the subscriber waited for. This is the operationally useful half:
the budget is a straightforward purchase of outage immunity up to its own length.

**Beyond the budget, loss falls as the budget rises — the opposite of what the two cells above
suggested, and the replication is what settles it.** Those two cells (1 s losing 1.250 s, 3 s losing
2.075 s) were read as the *larger* budget losing *more* programme, and a sizing rule was drawn from
them: that an intermediate budget is the worst choice. **Three replicates across six budgets do not
support it** — see *The budget ladder replicated* below. The direction reverses, and the reason the
original reading was available at all is that the scatter at budgets shorter than the outage is a
factor of seven, so any two single samples can be ordered either way.

**The 30 s cell is a different failure and should not be read as the ladder's top rung.** It lost
30.125 s — *more* than the outage — where the budget model predicts 27 s. 30 s is also
`DEFAULT_IDLE_TIMEOUT`, so this cell straddles the point where the QUIC session dies rather than
starving, and what it measures is teardown and re-establishment rather than a gap. Attributing it
needs cells either side of the timeout (20 s and 40 s) and the idle timeout moved explicitly; not run.

**0 continuity errors in every cell, including the 30 s one**, is a broadcast-domain result in its own
right and it is not what an impaired TS path normally does. Loss on this lane presents as missing
media with the continuity counters intact, not as corrupt packets, so a downstream analyser will flag
absence rather than errors. Pass criterion 4's 0-continuity-error requirement is met on every cell
run.

### The budget ladder replicated, and the nominal budget is not a latency setting

Run as the MoQ half of [P1-m](planned-experiments.md), whose purpose is a matched-buffer comparison
against SRT. **The SRT arm of that comparison has not produced a cell** — see *Open* below — so
nothing here ranks the two architectures. What it does deliver is the replication T28 owed, and a
measured result that changes how the comparison has to be set up.

**Environment.** As above, but build `moq` 0.11.2-`5d0991b9`, rig
[`t28-t31-srt-ladder.sh`](scripts/t28-t31-srt-ladder.sh), and an inline PES-timestamp tap
(`t18-latency.py`) on both sides of the lane so delivery latency is measured rather than assumed.
Both namespaces are on one host, so the two taps share a clock and the offset is 0. 5 s total outage,
three replicates per budget, `cake` at 20 Mb/s, 100 ms base RTT. Domain **wire**, point **P1**.

Media lost against the same 5 s outage, in seconds:

| `--max-age` | rep 1 | rep 2 | rep 3 | median | control (unimpaired) |
|---|---:|---:|---:|---:|---:|
| 0.5 s | 2.925 | 2.475 | 0.875 | 2.475 | **1.050 — not clean** |
| 1 s | 2.675 | 4.300 | 0.600 | 2.675 | 0.000 |
| 2 s | 1.025 | 1.375 | 2.025 | 1.375 | 0.000 |
| 3 s | 0.200 | 0.300 | 0.200 | **0.200** | 0.000 |
| 4 s | 0.625 | 0.450 | 0.900 | 0.625 | 0.000 |
| 6 s | 0.200 | 0.200 | 1.275 | **0.200** | 0.000 |

`cc = 0` in all 18 impaired cells and all 6 controls.

**The controls license the grading for budgets ≥ 1 s and disqualify the 0.5 s row.** Five of six
unimpaired cells grade at exactly 0.000 s lost, which is what makes the wire domain usable here. The
0.5 s cell loses 1.050 s *with no impairment at all*, so a 500 ms release deadline is below what this
path costs (100 ms base RTT, 20 Mb/s `cake`) and its impaired cells cannot separate the outage from
the budget. Recorded, not used.

**Loss falls with the budget, and the previously reported non-monotonicity does not replicate.** From
1 s upward the medians are 2.675, 1.375, 0.200, 0.625, 0.200 — a fall of better than an order of
magnitude between 1 s and 3 s. **The sizing rule stated earlier in this file is therefore withdrawn:**
an intermediate budget is not the worst choice, and the ordinary reading is the right one — a budget
at or beyond the expected outage buys near-immunity, and below it the cost rises as the budget
shrinks.

**What survives of the non-monotonicity is much smaller and reproducible: the 4 s cell is
consistently worse than the 3 s cell** (0.450–0.900 against 0.200–0.300, in all three replicates).
That is a real bump, not scatter, and it is unexplained. It is also not the effect originally
claimed.

**The scatter below the outage length is the methodological finding.** At a 1 s budget the three
replicates span 0.600 to 4.300 s — a factor of seven — while at 3 s and 6 s they span 0.200 to 0.300.
So the lane's behaviour is tightly determined once the budget covers the outage and close to
arbitrary when it does not. **This is why the original two-point reading was available**: any two
single samples drawn from the short-budget distribution can be ordered either way, and the pair that
was drawn happened to order against the trend. Quoting a single sample from a budget shorter than the
impairment is not a measurement of that budget.

#### `--max-age` does not set delivery latency on a healthy path, which invalidates the obvious way to match buffers

This is the result P1-m was built to establish before comparing anything, and it is negative.

| `--max-age` (nominal) | measured median latency, unimpaired | measured median latency, post-outage (3 reps) |
|---|---:|---|
| 0.5 s | 1943 ms | 2550 / 3180 / 5838 ms |
| 1 s | 1654 ms | 5521 / 6433 / 6444 ms |
| 2 s | 1985 ms | 1581 / 1803 / 7407 ms |
| 3 s | 1899 ms | 9069 / 7781 / 8995 ms |
| 4 s | 1418 ms | 9399 / 8975 / 9758 ms |
| 6 s | 1661 ms | 10823 / 10857 / 10723 ms |

**Unimpaired, a twelve-fold change in the nominal budget produces no trend in delivered latency** —
every cell lands between 1.42 s and 1.98 s, and 4 s is the *fastest* of the six. **After the outage,
latency scales with the budget**, from ~2.5–5.8 s at 0.5 s to a very tight ~10.7–10.9 s at 6 s.

So `--max-age` is not an end-to-end delay budget in the sense SRT's `--latency` is. It is the amount
of *recovery* delay the subscriber will accept before it gives up on a group, and on a healthy path it
is not spent at all: the lane delivers at its own floor whatever the number says. SRT's `--latency`,
by contrast, is a fixed delay inside which retransmission may complete, and it is spent continuously.

**Consequently, setting `--max-age 2s` against `--latency 2000` is not a matched comparison, and an
SRT arm built that way would produce a ranking that looks like a result and is not one.** The correct
design — and what the SRT arm must use — is to set SRT's `--latency` to the MoQ lane's *measured*
unimpaired delivery latency, then compare programme loss against the same outage. That is a change to
the experiment, and it is the main thing this run bought.

Two qualifications on the absolute figures. They are **rig-inclusive**: the ~1.4–2.0 s floor contains
`tsp regulate --pcr-synchronous`, two inline tap stages and their pipes, so it is not a figure for the
lane alone and must not be quoted as one. What is robust to a constant offset is the **invariance
across budgets** and the **post-outage scaling**, and those are the findings.

#### The SRT lane's budget *is* its delivered latency, and the arm is still not comparable

The SRT lane now produces cells, at budgets {1, 2, 3} s. Its latency behaviour is the exact complement
of the MoQ lane's:

| SRT `--latency` | measured median delivery latency | spread across the window |
|---|---:|---:|
| 1 s | **1050.2 ms** | 74 ms |
| 2 s | **2050.3 ms** | 74 ms |
| 3 s | **3050.2 ms** | 74 ms |

Nominal plus one-way path delay, to a tenth of a millisecond, every time. **So the two lanes'
"latency" parameters are different quantities**: SRT's is a fixed end-to-end delay that is always
spent, MoQ's is a recovery allowance that is spent only on failure. Equating the two numbers — the
obvious way to build this comparison, and the way it was originally specified — compares a lane
running at 2.05 s against a lane running at 1.9 s *and* holding 2 s of recovery headroom. That is not
one buffer measured twice.

**The loss figures from this arm are nevertheless void, and the reason is the instrument.** The SRT
controls do not grade clean: unimpaired cells lost 4.196–5.391 s with 5,704–8,930 continuity errors.
Re-run through the identical netns path **with the inline tap removed**, the same lane graded
**0.000 s lost, 0 holes, 0 continuity errors** over a 27.7 s span. A pass-through tap was corrupting
the transport stream — **the source-side one, as the next section establishes; the egress tap is
harmless** — and **the MoQ lane never showed it** because `moq export ts` re-synthesises the stream at
egress and regenerates the continuity counters, laundering any upstream damage. Had the SRT
controls been omitted, this rig would have reported SRT as catastrophically worse than MoQ on entirely
fabricated evidence. Method rule in [method-notes](method-notes.md) § *An inline instrument damaged
one lane and was invisible on the other*.

**What the SRT arm needs before it can rank anything**: a latency tap that mirrors rather than passes
through, and then SRT's `--latency` set to the MoQ lane's *measured* unimpaired delivery latency
rather than to its nominal budget. Both are changes to the rig, not to the question. **The first is
now built and validated** — see below; the second is outstanding.

#### The artefact attributed: it is the source-side tap alone, and a mirroring tap removes it

The paragraph above named "the pass-through tap" without saying *which* of the two the rig ran. There
were two — one between `regulate` and the SRT sender, one on the egress — and they do not behave
alike. Five arms on one clean SRT lane, differing only in how the stream is observed
([`t18-tap-perturbation.sh`](scripts/t18-tap-perturbation.sh), `53f8aa99d` host, netns at 20 Mb/s and
100 ms RTT, `--latency 2000`, 60 s per arm):

| arm | what observes the stream | media lost | continuity errors | pictures seen |
|---|---|---:|---:|---:|
| `none` | nothing — the reference | **0.000 s** | **0** | — |
| `inline` | egress tap, in the path | **0.000 s** | **0** | 2,099 |
| `mirror` | egress tap, off a `tsp -P fork` copy | **0.000 s** | **0** | 2,099 |
| `src-inline` | **source** tap, in the path | **4.693 / 4.563 s** | **6,001 / 6,493** | 2,206 |
| `src-mirror` | **source** tap, off a `tsp -P fork` copy | **0.000 / 0.000 s** | **0 / 0** | 2,154 |

*Two cells are quoted twice because the source arms were replicated; the two runs agree on the
picture counts exactly and on the loss to within 0.13 s.*

**The egress tap is innocent and the source tap is the whole artefact.** `src-inline` lands inside the
originally observed 4.196–5.391 s and 5,704–8,930 continuity errors, so the defect is reproduced
rather than merely hypothesised; `inline` sits at zero on the same rig in the same session. The
mechanism follows from where each one sits: the source tap is a Python reader between a
`regulate`-paced sender and a real-time SRT transmitter, so whatever it costs is paid as backpressure
on a stage that cannot wait, while the egress tap has only a file behind it and can lag freely.

**The fix is `tsp -P fork --nowait --ignore-abort`**, which hands the tap a *copy* of each packet
while the main chain continues to its output, so the graded capture never passes through Python.
`src-mirror` grades identically to the untouched reference while still seeing 2,154 pictures against
`src-inline`'s 2,206 — the instrument survives the change, which is the half that makes it a fix
rather than a removal.

*One run per arm for the egress three; the two source arms replicated. Domain: file, on the
subscriber's capture. This validates the instrument only — it re-opens the SRT arm rather than
grading it, and no loss figure in this experiment's tables is restored by it. The second rig change
the arm needs, matching SRT's `--latency` to the MoQ lane's measured delivery latency, is still
outstanding.*

One incidental rig defect worth keeping, because it cost a whole pass: TSDuck's `tsp` does not start
its output plugin until the `regulate` input stage has filled, which takes **~8 s** with this source,
and TSDuck's SRT caller does not retry. A 3 s sleep between starting the listener and starting the
caller voided every SRT cell in the first pass, with nothing in the publisher's log to say why. The
rig now polls for the bound port and marks a cell `nobind` if it never appears.

## Objective

For each defined failure on each lane, measure how much *programme* is lost or corrupted before
continuous delivery is restored — not how quickly a session reconnects. Rank outcomes by media lost,
because a 30 s outage that costs 30 s of programme is a worse result than a 60 s outage that costs
none, and the ladder exists to find where each lane crosses from the second behaviour to the first.

This closes the single largest comparative gap called out as [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior):
the campaign has substantial partial evidence ([T5](test-5-network-impairment.md),
[T6](test-6-relay-resilience.md)) but no unified matrix scored in the broadcast domain.

## What is already known, and precisely what it leaves open

**Loss and reordering ladders exist on both lanes.** [T5](test-5-network-impairment.md) graded loss,
reordering and jitter with `netem`/`tc` at P1; its reordering separation was later corrected by
[T20](test-20-segmented-http3.md) on a substrate-matched arm. What is missing is the *outage* ladder
(500 ms, 5 s, 30 s, 5 min blackouts) and simultaneous injections.

**Infrastructure failures were probed individually, reported as times.** [T6](test-6-relay-resilience.md)
characterised origin restart, relay return, dual-source failover and the segmented lane's shared-store
behaviour — including the structural asymmetry that MoQ reselects while segmented HTTP needs no merge.
Those drills establish starting points (for example, that MoQ exporter resume skips to the live edge
while a retrying segmented client may refetch) but they do not apply one grader or one ranking metric
across all cells. Recovery-time figures from T6 must not be quoted as programme-loss figures without
this matrix.

**Availability windows are measured for segmented HTTP under loss.** [T5](test-5-network-impairment.md)
established the edge of the window at roughly 7.7–12.2 % applied loss; behaviour past that boundary
is lane-specific and was not scored as seconds of media lost in a comparative table.

**Dual failures and combined transport-plus-infrastructure cells are untested.** Killing two
components at once — publisher and path, relay and packager — is specified here and has no designed
record.

## Environment

| | |
|---|---|
| Lanes | Media-aware MoQ (`moq import ts` → relay → `moq export ts` → groomed egress) and segmented HTTP (`tsp -O hls` → origin → receiver → groomed egress), topologies aligned with [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md) so existing drills are reused, not re-run for their own sake. |
| Impairment point | `netem`/`tc` at the same logical hop on both lanes — the path between source node and serving node — per [method-notes](method-notes.md) on matching substrate and controller variables. |
| Source | Looped `<CLIP>` at known CBR, paced with `tsp -P regulate --pcr-synchronous`; segmented packager flags unchanged from [T6](test-6-relay-resilience.md) segmented arm. |
| Hosts | Loopback for v1 matrix; cross-host variant optional once the grader is stable. Placeholder `<EC2_IP>` when remote. |
| Grader | One script pair: inject failure → capture egress → emit **seconds of media lost**, continuity-error count, PCR discontinuity count, PTS regressions, wall-clock time to first byte after fault, time to *stable* operation (defined below), and whether operator intervention was required. Built once for [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) and shared with silent-failure arms ([P0-f](planned-experiments.md#p0--could-change-a-viability-conclusion)). |
| Receivers (segmented) | At minimum `t6-hls-pull.py` as the protocol-capable control; `tsp -I hls` and FFmpeg as shelf behaviour columns, because [T6](test-6-relay-resilience.md) showed receiver choice changes failover outcome without changing lane specification. |

**Role equivalences to declare in the report**, not to paper over:

| Concept | MoQ lane | Segmented lane |
|---|---|---|
| Source node | publisher (`moq import ts`) | packager (`tsp -O hls`) |
| Mid-path node | relay | origin / cache |
| Session state | subscription on relay | none on origin |
| Asymmetry | reselect after detection interval | shared namespace, no merge |

## Procedure

Two axes, applied identically where the lane has an equivalent role.

**Transport axis** — at the shared impairment point, in separate runs:

- Random loss steps (reuse [T5](test-5-network-impairment.md) ladder where still current; extend only
  where gaps remain).
- Reordering and jitter (reuse T5 cells; do not duplicate substrate-matched work already in
  [T20](test-20-segmented-http3.md) unless the grader adds the media-lost column).
- Bandwidth reduction (step down from provisioned rate).
- **Outage ladder** — 100 % loss for **500 ms, 5 s, 30 s and 5 min**, then restore; grade the whole
  window including recovery tail.

**Infrastructure axis** — kill and restart, one component per run unless noted:

- Source node (MoQ publisher; segmented packager).
- Mid-path node (MoQ relay; segmented origin — cache/edge where applicable).
- Receiver-side process without killing the transport (exporter stall, groomer stall).
- Network path reset (flush `netem`, restart interface — simulates route change).
- **Dual failures** — two components, e.g. publisher + path, relay + packager, chosen from pairs that
  production 1+1 is meant to survive.

Each cell: baseline capture → inject at known wall time → capture through stable recovery → grade.
MoQ idle-timeout and reselect tuning (`--server-quic-idle-timeout`, `--client-quic-idle-timeout`)
are explicit parameters recorded per cell because [T6](test-6-relay-resilience.md) showed they move
detection interval without moving media-skip behaviour.

**Stable operation** is defined before the run: delivered byte rate within 95 % of pre-fault rate for
30 consecutive seconds *and* 0 new continuity errors in that window. First byte after fault may arrive
earlier; stable operation is the criterion for "recovered".

## Metrics

Per injection, per lane, at groomed P1 egress (file):

- **Media lost (headline)** — seconds of programme time missing or duplicated, computed from PCR/PTS
  timeline holes and regressions, not from session logs.
- **Continuity errors** — TSDuck count during fault and recovery windows ([method-notes](method-notes.md)).
- **PCR discontinuities** — count and maximum jump.
- **PTS regressions** — count.
- **Wall-clock recovery** — time to first post-fault byte; time to stable operation (secondary).
- **Operator intervention** — boolean; automatic recovery only passes without it.
- **Transport narrative** — what the session/API reported throughout (HTTP 200s with frozen media,
  QUIC reconnect, etc.); recorded to show disconnect from media-domain outcome, not scored as pass/fail.

Rank cells **by media lost ascending**; recovery time breaks ties only for equal media lost.

## Pass criteria, fixed before running

These are criteria on the *experiment's deliverable*, not on the lanes — neither lane is assumed to
pass every cell.

1. **Grader validity.** A control run with no injection reports 0 s media lost and 0 continuity errors
   on both lanes; a synthetic hole injected in post produces the injected duration ± 100 ms.
2. **Matrix completeness.** Every transport outage duration {500 ms, 5 s, 30 s, 5 min} × both lanes;
   every infrastructure single-failure row × both lanes; ≥ 4 dual-failure pairs × both lanes. A cell
   skipped for missing apparatus is listed as blocked, not omitted silently.
3. **Ranking published.** Final table sorted by media lost; no cell reported only as recovery time.
4. **Comparability.** Same source clip, same provisioned rate, same groomer configuration within a
   lane across all cells unless the cell explicitly tests configuration (then labelled).
5. **Segmented receiver axis.** Where [T6](test-6-relay-resilience.md) showed receiver-dependent
   outcomes, at least two receivers are graded for origin-restart and outage-5 s cells; divergence is
   a finding, not a rig error.

**Lane-level interpretation (fixed before running):** a lane is *superior on resilience* for a given
failure class if its median media lost across three repeats is lower than the other lane's at matched
ingress rate and matched conformance of pre-fault bytes. A tie within ± 0.5 s programme time is
reported as tied.

## Limits, stated in advance

- **P1 file egress only in v1.** Wire timing (P2) and hardware IRD merge are out of scope; outage
  behaviour on a hardware IRD may differ from file PCR arithmetic.
- **`netem` is an emulator.** Results complement, not replace, the public-internet path from
  [T4](test-4-remote-e2e-srt.md).
- **Reuse, don't repeat.** Cells that duplicate [T5](test-5-network-impairment.md) or
  [T6](test-6-relay-resilience.md) verbatim add only the media-lost column; their session-level
  narratives are cross-referenced, not re-measured for a second publication.
- **1+1 merge is out of scope.** Hitless dual-path behaviour belongs to [T12](test-12-dual-path-handoff.md);
  this matrix grades single-path recovery unless extended later.
- **Silent misconfiguration** (time-travel that passes continuity checks) is graded under
  [T30](test-30-segmented-distributed-resilience.md) for segmented pairs; only noted here if a
  transport outage exposes the same class.

## Verdict against the pass criteria

| # | Criterion | Verdict |
|---|---|---|
| 1 | Grader validity: a control reports 0 s lost and 0 continuity errors **on both lanes**; a synthetic hole reproduces the injected duration ± 100 ms | **Pass on the MoQ lane, fail on the SRT lane — and the criterion is what caught it.** MoQ: 0.000 s and 0 continuity errors in five of six controls (the 0.5 s budget is disqualified, see above); three holes and one repeat recovered within the margin. SRT: controls graded 4.196–5.391 s lost, traced to the inline tap corrupting the stream, so every SRT cell run so far is void |
| 2 | Matrix completeness | **Partial.** The MoQ lane's outage ladder is run and replicated (four outage durations; six latency budgets × three repeats at 5 s). The loss/reorder/bandwidth steps, the infrastructure axis, the SRT lane and the segmented lane are not |
| 3 | Ranking published | **Not met, deliberately.** One lane cannot be ranked against a lane that has not run; publishing a half matrix as a ranked table is the failure this experiment exists to avoid |
| 4 | Comparability | **Pass on the cells run.** One host, one rig, one build, one clip, one grader and one domain across every cell, with an unimpaired control through the same path |
| 5 | Segmented receiver axis | **Not run.** The apparatus is on the same host (T20's HTTP/3 and HLS lane), so this is now a session's work rather than a blocker |

## What remains

Nothing here is blocked on a third party, a loan or an account. The apparatus, the clips, the binaries
and the grader are all on the EC2 secondary, which has 29 GB free — the disk objection this file used
to record was against a stale figure.

- ~~**Replicate the latency-budget non-monotonicity.**~~ **Done — it did not replicate**, and the
  sizing rule drawn from it is withdrawn; see *The budget ladder replicated*. What remains of it is a
  small reproducible bump at 4 s, unexplained.
- **Make the SRT arm comparable**: a mirroring latency tap, and SRT matched on measured rather than
  nominal buffer. Until then nothing in T28 ranks the two architectures.
- **Bracket the idle timeout.** 20 s and 40 s outages with `--server-quic-idle-timeout` set
  explicitly, to separate a starved session from a dead one.
- **The remaining transport steps** — loss, reorder and bandwidth — on the rig as it stands.
- **The infrastructure axis**: kill and restart a publisher, a relay and an exporter. This needs no
  emulator and could equally run on the macOS workstation.
- **The segmented lane**, using T20's HTTP/3 and HLS apparatus already built on the same host. Until
  it runs there is no ranking, which is criterion 3.

Quoting [T6](test-6-relay-resilience.md) recovery times as programme-loss figures remains
methodologically out of bounds, but the MoQ lane now has real programme-loss figures of its own for
the outage row.

