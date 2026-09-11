# Test 28 — Failure-injection and recovery matrix

**State: specified, not run.** Infrastructure and transport failures have been probed one at a time in
[T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md), usually reported as recovery
*time*; what a distributor buys is programme continuity, and the two are not the same number. This
experiment would apply one media-domain grader across a full matrix on both lanes; it has not run
because the shared harness and ranked scoring ladder do not yet exist — [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)
groups it with [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) and defers it behind
cheaper decisive cells.

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

## Why this has not run

The campaign prioritised cheap decisive gates first (transparency, timing file-domain, partial
resilience drills). [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md) were
run as individual experiments with session-centric metrics; consolidating them requires building the
shared grader once ([planned-experiments.md](planned-experiments.md) Group D: P1-1 shares a harness
with P0-4). Until that exists, quoting T6 recovery times as programme-loss figures remains
methodologically out of bounds — which is exactly the gap this test is meant to close.
