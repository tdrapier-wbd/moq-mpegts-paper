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
([T19](test-19-pcr-timing.md)'s positional finding): the median packet gap between adjacent PCR
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

**Beyond the budget, the cost tracks the budget, not the outage — which is counter-intuitive and is
the finding that most needs replication.** Against the same 5 s outage, a 1 s budget lost 1.250 s and
a 3 s budget lost 2.075 s: the *larger* budget lost *more* programme. The mechanism is consistent
with a subscriber that skips stale groups and resumes at the live edge, so the hole it takes is
bounded by how much staleness it was willing to tolerate (largest hole 0.725 s at 1 s, 1.200 s at
3 s). If that holds, the sizing rule is uncomfortable: **either buy a budget longer than the worst
outage you expect, or keep it short — an intermediate value is the worst of the three.** Each cell
here is a single sample and the non-monotonicity rests on two points, so this is *likely*, not
established. Three repeats per budget across {0.5, 1, 2, 3, 4, 6} s is the cheap confirmation and is
not yet run.

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
| 1 | Grader validity: a control reports 0 s lost and 0 continuity errors; a synthetic hole reproduces the injected duration ± 100 ms | **Pass.** Control 0.000 s and 0 continuity errors; three holes and one repeat all recovered within the margin. See the table above, and the limit on what that validates |
| 2 | Matrix completeness | **Partial.** The MoQ lane's outage ladder is run (four outage durations, three latency budgets). The loss/reorder/bandwidth steps, the infrastructure axis and the segmented lane are not |
| 3 | Ranking published | **Not met, deliberately.** One lane cannot be ranked against a lane that has not run; publishing a half matrix as a ranked table is the failure this experiment exists to avoid |
| 4 | Comparability | **Pass on the cells run.** One host, one rig, one build, one clip, one grader and one domain across every cell, with an unimpaired control through the same path |
| 5 | Segmented receiver axis | **Not run.** The apparatus is on the same host (T20's HTTP/3 and HLS lane), so this is now a session's work rather than a blocker |

## What remains

Nothing here is blocked on a third party, a loan or an account. The apparatus, the clips, the binaries
and the grader are all on the EC2 secondary, which has 29 GB free — the disk objection this file used
to record was against a stale figure.

- **Replicate the latency-budget non-monotonicity.** Three repeats against a 5 s outage at budgets
  {0.5, 1, 2, 3, 4, 6} s. This is the cheapest cell in the experiment and it is the one carrying the
  sizing claim, which currently rests on two single-sample points.
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

