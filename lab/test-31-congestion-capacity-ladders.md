# Test 31 — Congestion and capacity: the step ladders, both planes

**State: both step-capacity ladders are run — the MoQ one in the `netns`/`cake` rig, the segmented
one in T20's loopback/`netem` rig — and the latency-max × contention matrix is not. The two ladders
are in different rigs and their figures are not interchangeable; see *The segmented ladder is in a
different rig* below before reading them side by side.**
[T8b](test-8b-congestion-control.md) settled which controller wins under which provisioning and queue
discipline, and attributed the MoQ lane's shared-bottleneck collapse to per-subscriber deadline
shedding at `--latency-max`. This experiment asks a different question — how much impairment each
lane absorbs before programme is lost — and extends T8b with step-capacity ladders on both planes
plus the withheld segmented C2 cells.

**Headline: the MoQ lane absorbs a mild sustained shortfall entirely, and sheds in proportion to
severity beyond it.** Against a 9.95 Mb/s stream, sixty seconds at **0.9× stream rate costs no
programme at all**, and neither does a five-second transient at 0.8×. A chronic 0.8× sheds, and 0.5×
sheds about three times as much. **0 continuity errors in every cell on every rung**, so the ladder's
integrity invariant (criterion 3) holds throughout — this lane discards whole groups on a deadline
rather than corrupting packets.

**Second headline: the segmented lane absorbs one rung deeper, and when it does break it breaks by a
different mechanism.** Over HTTP/3 it delivers the 0.9×-for-60 s and 0.8×-transient rungs
**byte-identically to its own headroom control**, and carries chronic 0.8× at **zero continuity
errors and a 24.95 ms worst-case PCR interval** while running 12.7 % behind the live edge. It fails
at 0.5×, and not by shedding: the receiver falls far enough behind that the origin has already
deleted the segment it asks for, and it takes a 404. **Under-provision costs this lane latency until
the availability window runs out, and then it costs it the programme** — a cliff where the MoQ lane
has a slope.

**The substrate was never missing, and that was this file's error.** The rig is `t8b-netns.sh` — two
network namespaces joined by a veth — which is Linux-only, and the campaign's workstation is macOS.
But both EC2 Linux hosts have `netem` and namespaces and had already used them for
[T8b](test-8b-congestion-control.md), [T5](test-5-network-impairment.md) and
[T20](test-20-segmented-http3.md). The ladder ran on the **EC2 secondary**, sharing its rig setup with
[T28](test-28-failure-injection-matrix.md)'s transport axis exactly as planned. Re-basing on macOS
dummynet would still have been wrong, for the comparability reason, and was not done.

The media-domain grading half is no longer missing: [T28](test-28-failure-injection-matrix.md)'s
`t28-media-lost.py` is built and validated against known answers, and is the scorer for "how much
programme is lost" on these ladders too.

Registered as [P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior),
sustained capacity degradation. Extends [T8b](test-8b-congestion-control.md); does not re-run C1–C6.

## Objective

Characterise **sustained capacity degradation** for a permanent fixed-rate trunk: given a shaped
bottleneck stepped through short and long shortfalls, what is the maximum impairment duration and
severity each data plane absorbs **without losing programme**?

The headline output is one number per lane — the longest impairment absorbed with zero media lost —
with a secondary read on whether recovery returns to the pre-impairment operating point or to a
permanently deeper buffer (a latency regression that survives the fault). This is the sizing question
operators provision against ([`docs/problem.md`](../docs/problem.md) R4, R5), distinct from T8b's
controller comparison.

## What is already known, and precisely what it leaves open

**T8b C3 named the shedding mechanism but not the knee.** Under shared contention at `n=2`, MoQ's
aggregate delivery tracks the subscriber's `--latency-max` budget — [T8b](test-8b-congestion-control.md)
measured 4.29 Mb/s at 500 ms rising to 10.35 Mb/s at 30 s at 0 continuity errors throughout — and the
sweep is already at **62 % of cap by 8 s**, but where the knee sits relative to RTT, group duration, or
relay buffering is unsettled. A finer ladder at 1, 3, 4 and 6 s at `n=2` and `n=3` is the operator-facing
residue T8b's Next steps recorded.

**T8b C1–C6 do not answer the step-ladder question.** They grade controllers under under-provisioned
caps, transient competing flows, fairness, AQM, and permanence — not a **stepped** capacity curve on
both planes scored on worst-case programme survival.

**Four segmented C2 cells ran in T8b and are withheld, not absent.** Their delivery collapse matches
the mechanism C1 identified (ordered fetch falling behind the availability window), but standing RTT on
those cells (p95 178–183 ms) contradicts every other cell in the same condition (554–584 ms), so the
queue experienced cannot be shown to be the queue specified. Re-running them with the competing flow's
own throughput recorded per cell is part of this experiment ([T8b § C2 withheld](test-8b-congestion-control.md#the-segmented-rows-of-c2-are-withheld-pending-a-re-run)).

**Additional C3 replicates were deprioritised.** The planning record ([P2-e](planned-experiments.md#p2--completeness))
notes that per-flow splits do not reproduce and the qualitative C3 result is already clear at one sample
per cell; two more replicates would only tighten error bars on numbers this experiment supersedes with
the capacity ladder. Replicate work on C3 aggregates is explicitly **not** in scope here unless a ladder
cell lands in the shedding regime and needs confirmation.

**The segmented comparative half is new.** T8b's MoQ arms used the namespace rig throughout; the same
bandwidth ladders against the segmented lane — scored on what an operator needs, which is programme
survival rather than average throughput — have not been run ([P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)).

## Environment

| | |
|---|---|
| Primary rig | T8b namespace harness (`t8b-netns.sh`): two netns joined by veth, bottleneck downstream, base RTT emulated both ways. Same class as [T8b](test-8b-congestion-control.md) — reproducible on any Linux host without shared-host SSH risk. |
| Queue discipline | `cake` at the bottleneck so bufferbloat is not the variable ([P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior), [method-notes](method-notes.md) on pairing figures with conditions). |
| Source | ~10 Mb/s CBR fixture, loop-publisher stopped during cells that only need downstream contention ([P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) Group B: ~20 minutes for the MoQ half alone). |
| MoQ lane | `moq import ts` → relay → `moq export ts` + `mpegts-pacer`; pin build and `--server-quic-congestion-control` per [T8b](test-8b-congestion-control.md). Controller choice follows T8b's provisioning conclusion (BBRv1 on a sized link unless an arm explicitly varies it). |
| Segmented lane | HLS origin → `tsp -I hls` and the minimal re-anchoring client from [T6](test-6-relay-resilience.md)/[T8b](test-8b-congestion-control.md), both clients where the ladder compares lane behaviour rather than one implementation. |
| C2 re-run cells | Identical shaping to T8b C2: 15 Mb/s cap, greedy TCP bulk flow 40–80 s into a 120 s window; **add** competing-flow throughput sampled per second so delivery collapse can be attributed to the impairment. |
| Placeholders | `<EC2_IP>` / `<subscriber-home-ip>` only if a corroborating real-path variant is added; not required for the primary ladder. |

## Procedure

**Step-capacity ladders (both planes).** Apply the same shaped bottleneck sequence identically to MoQ
and segmented arms:

Rungs are **multiples of the stream's own rate**, derived from the fixture at run time, for the
reason in *The rungs had to be re-based* below; the provisioned rate is 20 Mb/s throughout.

1. **1.2× for 60 s** — headroom, the negative control for the ladder.
2. **0.9× for 60 s** — mild sustained shortfall, the commonest real under-provision.
3. **0.8× for 5 s** — brief deep shortfall.
4. **0.8× permanently** — chronic under-provision.
5. **0.5× for 60 s** — severe sustained shortfall.

For MoQ, repeat the ladder at `--latency-max` ∈ {1 s, 3 s, 4 s, 6 s} with `n ∈ {2, 3}` contending
subscribers on the shared bottleneck — the knee C3's mechanism implies but did not locate ([P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior), [T8b Next steps](test-8b-congestion-control.md#next-steps)).

Run one complete ladder per lane × client combination. Grade each step as its own cell; do not average
phases away ([method-notes](method-notes.md): latency and conformance need the same bytes).

**Withheld segmented C2 re-runs (four cells).** Re-execute the T8b C2 segmented condition with competing-flow
throughput logged alongside receiver delivery. Publish only if standing RTT and competing-flow share
prove the specified queue formed; otherwise record as rig-invalid per T8b's withholding rule.

**Order.** Cheap namespace cells first (MoQ ladders, then segmented); C2 re-runs can share a session with
ladder cells that use the same harness. Grading is per-cell aggregate (`t8b-c3-span.py` or equivalent),
not a timing comparison — safe to interleave with non-timing work in the same window ([P1-d, bundling](planned-experiments.md#what-to-bundle-because-prompt-count-is-the-scarce-resource)).

## Metrics

Per cell, per lane:

- **Media lost** — programme time in holes above 100 ms; delivered span versus wall time (`keep_up`).
- **Continuity errors** — TSDuck on groomed egress (MoQ) or receiver output (segmented); 0 is the
  broadcast-domain pass/fail.
- **Backlog and buffer occupancy** — MoQ: exporter/groomer buffer series where available; segmented:
  client buffer or segment lag behind live edge.
- **Latency growth and recovery** — standing RTT (`t8b-rtt-probe.sh`) and post-step return to
  pre-impairment delivery rate (first second with three consecutive seconds ≥ 95 % of pre-step rate,
  same definition as [T8b C2](test-8b-congestion-control.md)).
- **Resource growth during impairment** — relay RSS, subscriber RSS; a lane that absorbs shortfall only
  by buffering is spending memory ([P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)).
- **C2 attribution** — competing-flow throughput Mb/s per second; receiver standing RTT p50/p95.

## Measured — the MoQ step-capacity ladder

**Environment.** EC2 secondary, 8 vCPU / 15 GB, Ubuntu 26.04 — the primary's 2 vCPU cannot carry a
relay, a publisher and a subscriber without the knee being the host's. Two network namespaces joined
by veth (`t8b-netns.sh`), `cake` at the bottleneck, 100 ms base RTT (50 ms each way). Source a 120 s
~9.95 Mb/s CBR slice of `CNNiEMEA2.ts` paced with `tsp regulate --pcr-synchronous`. Build
**`84b34f54`** (noq), `--latency-max 3s`, n = 1 subscriber, **no groomer in the path**. Rig
[`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh) with `STREAM_MBIT=9.95`; graded with
[`t28-media-lost.py`](scripts/t28-media-lost.py) in the **wire** domain, at **P1**, one sample per
cell — except the chronic 0.8× rung, which has ten across three builds, for the reason below. Steps are re-shaped with `tc qdisc change` so the queue is not torn down and re-added, which
would itself drop the backlog and be scored as the impairment.

**The rungs are multiples of the stream's own rate, not absolute rates.** `STREAM_MBIT=9.95` is the
fixture's measured rate and the script derives each rung from it, for the reason in *The rungs had to
be re-based* below. The table gives the multiple, the shaped rate it computes to, and the shortfall
that leaves against the programme.

| Step | Shaped rate | Shortfall vs stream | Media lost | Holes | Largest hole | Duplicated | Continuity errors |
|---|---|---|---|---|---|---|---|
| none (control) | 20 Mb/s | — | **0.000 s** | 0 | — | 0.000 s | 0 |
| 1.2× for 60 s | 11.94 Mb/s | **none: +20 % headroom** | **0.000 s** | 0 | — | 0.000 s | 0 |
| 0.9× for 60 s | 8.96 Mb/s | −10 % | **0.000 s** | 0 | — | 1.575 s | 0 |
| 0.8× for 5 s | 7.96 Mb/s | −20 %, transient | **0.000 s** | 0 | — | 0.725 s | 0 |
| 0.8× permanent (45 s) | 7.96 Mb/s | −20 %, chronic | **1.000 s** ‡ | 1 | 1.000 s | 14.225 s | 0 |
| 0.5× for 60 s | 4.97 Mb/s | −50 % | **3.100 s** | 3 | 1.800 s | 17.350 s | 0 |

‡ One draw from a cell that straddles the absorption threshold: nine further replicates span
0.000–0.850 s, four of them losing nothing. See *The chronic rung straddles the absorption
threshold* below. Treat this rung as bimodal, not as a 1.000 s cost.

**A mild sustained shortfall is absorbed entirely, and that is the cell the ladder existed to
measure.** Sixty seconds at 0.9× stream rate is a real and sustained deficit — about 60 Mbit of
programme the link cannot carry in the window — and none of it was lost. The `cake` queue plus the
3 s latency budget covered a shortfall four times longer than the transient rung. **The lane's
absorption is therefore bounded by depth rather than by duration** over the range tested: a 60 s
−10 % costs nothing where a 45 s −20 % costs programme.

**Beyond that the lane sheds in proportion to severity, cleanly.** 1.000 s at −20 % chronic and
3.100 s at −50 %, in one and three holes respectively. The lane does not degrade gracefully into a
lower-rate version of the programme — it cannot, because the stream is CBR and the bitrate is not
the lane's to change — so it discards whole groups on a deadline and keeps the rest current. That is
the deadline-shedding mechanism [T8b](test-8b-congestion-control.md) attributed, measured here as
programme cost rather than as delivered fraction.

**Duplication rises with severity and is not attributed.** 0.000 s clean, 1.575 s at −10 %, 14.225 s
at −20 % chronic and 17.350 s at −50 %. This is the same unattributed signal
[T28](test-28-failure-injection-matrix.md) records on the same grader and the same rig, and nothing
above rests on it; it is reported because suppressing a column that moves monotonically with the
impairment would be worse than admitting it is unexplained.

### The chronic rung straddles the absorption threshold, and the QUIC backend is not why

The absolute-rate ladder had measured **7.050 s in six holes** at 8 Mb/s chronic where this one
measures 1.000 s in one hole at 7.96 Mb/s — the same shortfall to within 0.5 %, a factor of seven
apart. Two things had changed between those runs and one sample each could not separate them: the
build (`0.11.0-fd4f5d82e` → `84b34f54`) and, inside it, the **quinn → noq QUIC backend**. Three arms
of three replicates each separate them, because commit `5d0991b9` builds on both backends and is
therefore the clean instrument for the backend alone.

| Arm | Build | QUIC backend | Control | Chronic 0.8× replicates | Range |
|---|---|---|---|---|---|
| A | `5d0991b9` | quinn | 0.000 s | 0.000, 0.000, 0.775 s | 0.000–0.775 s |
| B | `5d0991b9` | noq | 0.000 s | 0.000, 0.550, 0.300 s | 0.000–0.550 s |
| C | `84b34f54` | noq | 0.000 s | 0.850, 0.000, 0.250 s | 0.000–0.850 s |

**Neither the backend nor the build explains the disagreement.** A and B are the same source commit
and differ only in QUIC stack; their distributions overlap completely. B and C share a backend and
differ by build; those overlap too. All **nine replicates fall between 0.000 and 0.850 s**, and no
arm produced anything within a factor of eight of 7.050 s. The absolute-rate ladder's chronic figure
is therefore **withdrawn as unreproduced** rather than explained: whatever produced it was not the
QUIC stack and was not the build, and it did not recur in ten samples at that shortfall across three
builds.

**What the replicates do establish is that the chronic −20 % rung sits on the absorption threshold.**
Ten samples at one impairment span 0.000 s to 1.000 s, and four of them lost nothing at all. That is
not measurement noise around a central value; it is a cell where the queue plus the 3 s budget
sometimes covers the deficit for the whole window and sometimes does not. **The single 1.000 s in
the table above is one draw from that spread, not the rung's cost**, and no sizing claim should be
made from it. The rungs that carry this experiment's headline — 1.2×, 0.9× and the 0.8× transient,
all at zero — are unaffected, and 0.9× for 60 s losing nothing is the more robust of the two
boundaries because it is zero rather than a number near one.

## Measured — the segmented step-capacity ladder

**Environment.** EC2 secondary, 8 vCPU / 15 GB. Source the same ~9.95 Mb/s CBR slice of
`CNNiEMEA2.ts`, packaged by `tsp -O hls` to nginx and pulled over **HTTP/3** by
[`hls-verbatim-recv.py`](scripts/hls-verbatim-recv.py), the byte-faithful receiver — an FFmpeg
receiver re-muxes and would grade itself rather than the wire ([T42](test-42-h3-receiver-fidelity.md)).
Provisioned rate 20 Mb/s, rungs derived from `STREAM_MBIT=9.95` exactly as the MoQ ladder derives
them. Rig [`t28-t31-segmented-ladder.sh`](scripts/t28-t31-segmented-ladder.sh) over
[`t20-h3-arm.sh`](scripts/t20-h3-arm.sh), one sample per cell, **wire** domain, at **P1**.

**Delivery is quoted against the ladder's own headroom control, not against 1.0.** The receiver
joins by fetching the segments already in the playlist, so it captures about 6.6 s of backlog beyond
its window and every healthy cell reads above unity. The 60 s cells are referenced to the 20 Mb/s
control and the 90 s cells to the 1.2× rung, which the procedure already nominates as the ladder's
negative control.

| Step | Shaped rate | Delivered bytes | Of control | Media lost | Continuity errors | PCR max | Carriage |
|---|---|---|---|---|---|---|---|
| none (control, 60 s) | 20 Mb/s | 82,851,600 | — | **0.000 s** | 0 | 24.95 ms | yes |
| 1.2× for 60 s (control, 90 s) | 11.94 Mb/s | 118,560,320 | — | **0.000 s** | 0 | 24.95 ms | yes |
| 0.9× for 60 s | 8.96 Mb/s | 118,560,320 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| 0.8× for 5 s | 7.96 Mb/s | 82,851,600 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| 0.8× permanent | 7.96 Mb/s | 97,653,216 | 82.4 % | **0.000 s** | 0 | 24.95 ms | yes |
| 0.5× for 60 s | 4.97 Mb/s | 96,203,924 | 81.1 % | **17.979 s** | 32 | 8,471 ms | no: 404, receiver exited 1 |

**The two absorbed rungs are absorbed exactly, not approximately.** 0.9×-for-60 s returns
118,560,320 bytes and the headroom control returns 118,560,320 bytes; 0.8×-for-5 s returns
82,851,600 and its control returns 82,851,600. These are not close figures, they are the same
figure — the shortfall is carried entirely inside the origin's segment store and the receiver never
observes it. That is the same property [T20](test-20-segmented-http3.md) measures under loss, seen
from the capacity side: **an HTTP lane converts a rate deficit into a fetch that takes longer, and a
fetch that takes longer is invisible until something else runs out.**

**Chronic 0.8× is the interesting cell, because it costs delivery without costing programme.** The
receiver ends 12.7 % of a 90 s window behind — 78.5 s of media where the control carried 95.3 s —
and the bytes it did get are clean: 0 continuity errors, 24.95 ms worst-case PCR interval, 0.00 %
of intervals above the 40 ms gate, no holes, carriage valid. **The lane is not degrading, it is
lagging**, and an operator watching programme integrity would see nothing wrong while an operator
watching the live edge would see the stream drifting away from it. Both instruments are needed;
either alone misreads this cell.

**At 0.5× the lag becomes a loss, and the mechanism is the availability window.** The receiver's
fetch of `seg-000025.ts` returns **404**: it had fallen so far behind that the origin's rolling
playlist had already evicted the segment. What follows is 17.979 s of lost programme in three holes
and 32 continuity errors — the first non-zero continuity count anywhere in the segmented ladder, and
it appears only once the receiver has been forced to skip. This is the failure
[T8b C1](test-8b-congestion-control.md) named as ordered fetch falling behind the availability
window, measured here as programme cost. **The lane's ceiling is therefore set by the origin's
retention, not by its throughput**, which is the same conclusion the outage cell reaches in
[T28](test-28-failure-injection-matrix.md) from the other direction.

**The byte counts at 0.8× chronic and 0.5× are nearly equal and mean opposite things**, which is
the trap in reading this table on delivery alone. 82.4 % and 81.1 % of control, 1.3 points apart —
but the first is 78.5 s of unbroken programme arriving late, and the second is 95.3 s of span with
17.979 s missing out of the middle of it. A lane that skips forward recovers its *span* by
abandoning its *content*, so delivered bytes alone cannot distinguish the cell that is merely
behind from the cell that has given up. The media-lost and continuity columns are what separate
them, and neither cell is legible without the other two.

**Where the knee sits is bounded but not located.** Absorption is complete at 0.9× sustained and at
0.8× transient, costs 17.6 % of delivery but no programme at 0.8× chronic, and breaks somewhere
between 0.8× and 0.5×. No rung was run in that gap and no duration beyond 60 s at 0.9×, so the
usable margin is a band rather than a number — the same limitation the MoQ ladder carries, and for
the same reason.

### The segmented ladder is in a different rig, and the two columns must not be subtracted

The MoQ ladder above ran in `t8b-netns.sh`: two namespaces joined by a veth, `cake` at the
bottleneck, 100 ms base RTT. The segmented ladder cannot run there, because it needs an HTTP origin
with both a TCP and a QUIC listener and the only one this campaign has is T20's nginx pair on the
host. It therefore runs on **loopback with `netem`, no added RTT, and a token bucket rather than an
AQM**. That is a materially easier path in one respect and a materially harsher one in another, and
neither difference is small.

The size of it is measurable, because the segmented rig also carries a MoQ arm. Re-run in the
loopback rig on the same rungs in the same session, **the MoQ lane loses programme at 0.9×, where
the `netns`/`cake` ladder records 0.000 s**; its delivered video falls to 76.2 % of source at that
rung and 64.1 % at chronic 0.8×. The `netem` token bucket at `limit 1000` has no AQM and a shallow
queue, and a controller that probes in bursts pays for that in a way it does not pay `cake`. **The
disagreement is a property of the shaper, not of the lane**, which is precisely why the two ladders
are reported as two ladders.

What follows for reading them:

- **The segmented column is sound against its own controls**, which ran in the same rig in the same
  session, and every claim above is of that form.
- **The MoQ column from the loopback rig is reported only to size the rig difference.** It is not a
  re-measurement of the MoQ ladder and does not supersede it.
- **No rung-for-rung ranking of the two lanes is supportable from this experiment.** The arm that
  would support one is the segmented ladder inside the `netns` rig, which needs an origin reachable
  from inside the namespace; that is a rig change, not a re-run.

### The rungs had to be re-based, and the earlier ladder is superseded

The procedure originally called a 20 → 12 Mb/s step a "sustained moderate shortfall". Against this
campaign's ~9.95 Mb/s fixture, 12 Mb/s carries **20 % headroom** — it is not a shortfall at all, which
is why that cell returned zero and why its zero said nothing about capacity. The rungs were written
as absolute rates while the result depends on the rate *relative to the stream*, so the ladder had a
hole exactly where the commonest real under-provision sits: between "absorbed entirely" at a
transient −20 % and programme loss at a chronic −20 %, nothing measured a *mild* sustained shortfall.

Re-basing closed it. [`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh) now takes
`STREAM_MBIT` and derives each rung as a multiple of it, so the ladder follows the fixture instead of
being re-specified whenever the fixture changes. **The figures in this section supersede the
absolute-rate ladder entirely**, and the method rule is in
[method-notes](method-notes.md) § *An impairment rung has to be expressed in the units the result
depends on*.

## Pass criteria, fixed before running

This is a characterisation, not a gate. "Pass" marks cells that meet the programme-survival bar; any
failure mode is a finding.

1. **Headline — zero media lost.** For each lane, report the **longest impairment step** (by duration
   and severity) absorbed with **zero media lost** and **0 continuity errors** after the groomer (MoQ) or
   at the receiver output (segmented). Steps that lose programme define the ceiling; steps that do not
   extend it.
2. **Recovery operating point.** After each step that meets (1), recovery within 60 s either returns
   delivery to within 5 % of the pre-step rate **and** buffer occupancy to within 10 % of pre-step, or
   the cell records a **permanent regression** (deeper buffer or lower sustained rate) — a finding even
   if (1) held during the step.
3. **MoQ integrity invariant.** Any non-zero continuity error on the MoQ lane during a ladder cell fails
   that cell regardless of delivered fraction ([T8b](test-8b-congestion-control.md) pass criterion 3).
4. **C2 re-run validity.** A segmented C2 cell is **withheld** unless competing-flow throughput and
   standing RTT show the bottleneck queue filled (RTT p95 within the same band as MoQ/SRT cells in T8b
   C2, and competing flow consuming a measurable share of cap). Invalid cells are discarded, not averaged
   into lane conclusions.
5. **Latency-max ladder (MoQ only).** Report the smallest `--latency-max` at each `n` for which the
   aggregate stays above 95 % of uncontended single-flow delivery through the **permanent 8 Mb/s** step,
   or record that no budget in {1, 3, 4, 6 s} suffices — falsifying deployment at that contention level.

## Limits, stated in advance

- **Namespace primary; wide-area corroboration optional.** Results bound behaviour at a controlled
  bottleneck, not internet-scale fan-out ([T26](test-26-cross-host-fanout.md) retires co-resident
  subscriber artefacts only for fan-out, not for this rig).
- **Controller pinned, not swept.** This experiment inherits T8b's conclusion that no single condition
  ranks controllers; arms use one pinned controller unless explicitly comparing shedding at two budgets.
- **Segmented lane is client-dependent.** Two clients are required where the question is lane versus
  receiver policy ([T8b C1](test-8b-congestion-control.md)); conclusions split by client.
- **Not a replicate study of T8b C3 aggregates.** Additional C3 replicates ([P2-e](planned-experiments.md#p2--completeness))
  were deprioritised in favour of this ladder; only ladder cells in active shedding may warrant a
  duplicate run.
- **PCR interval columns are not Gate 2.** Intervals above 40 ms on MoQ may reflect the exporter cadence
  characterised in [T18](test-18-delivery-latency.md), not the capacity step; continuity and programme
  survival decide the headline.

## Verdict against the pass criteria

| # | Criterion | Verdict |
|---|---|---|
| 1 | Longest step absorbed with zero media lost and 0 continuity errors | **Reported for both lanes, in different rigs.** MoQ (`netns`/`cake`): 60 s at 0.9×, absorbed completely, and a 5 s transient at 0.8×. Segmented (loopback/`netem`): the same two rungs byte-identically to its own control, **and chronic 0.8× as well** — 0 continuity errors and a 24.95 ms PCR maximum at 82.4 % of control delivery, so it meets this criterion one rung deeper than the MoQ lane meets it. All are **lower bounds rather than ceilings**: no rung between 0.9× and 0.8× was run on either lane, no rung between 0.8× and 0.5× on the segmented one, and no duration beyond 60 s. The rigs differ, so the two columns are not subtracted |
| 2 | Recovery operating point | **Not measured.** Delivery returned (subsequent cells were clean through the same rig) but buffer occupancy was not instrumented, so neither the 5 % rate nor the 10 % buffer test was applied |
| 3 | MoQ integrity invariant — any non-zero continuity error fails the cell | **Pass on every cell on every rung.** 0 throughout, including the two that lost programme |
| 4 | C2 re-run validity | **Not run.** The withheld segmented C2 cells remain withheld |
| 5 | Latency-max ladder at n ∈ {2, 3} | **Not run at contention.** The budget axis was exercised only at n = 1, and only against an outage rather than a capacity step — recorded in [T28](test-28-failure-injection-matrix.md), where it produced a non-monotonic result that this criterion's phrasing assumes cannot happen |

Criterion 5 deserves a note rather than a bare "not run": it asks for the *smallest* budget that keeps
aggregate delivery above 95 %, which presumes delivery improves monotonically with the budget. T28
measured the opposite against an outage at n = 1. Whether that survives at contention is exactly what
this criterion should settle, but the criterion as written cannot express the answer if it does.

## What remains

The rig tears down and rebuilds from `t8b-netns.sh` on the EC2 secondary, and nothing here waits on
a third party.

- **Rungs between 0.9× and 0.8×, and a duration beyond 60 s at 0.9×**, to turn criterion 1's lower
  bound into a ceiling. This is now the most valuable outstanding cell: the absorption boundary lies
  between the two rungs, and the replicates show 0.8× chronic is already *on* it, so the boundary is
  somewhere in a 10 % band and the lane's usable headroom margin is not yet stated.
- **Enough replicates to characterise the chronic rung's bimodality rather than bound it.** Ten
  samples establish the spread is real and that neither backend nor build causes it; they do not say
  what decides which mode a run lands in, and that mechanism is the interesting part.
- **The latency-max × contention matrix** (criterion 5) at n ∈ {2, 3}, against capacity steps rather
  than outages, and phrased so a non-monotonic answer is expressible.
- **Buffer and RSS instrumentation** for criterion 2, which the current rig does not collect.
- ~~**The segmented ladder**, using T20's HTTP/3 and HLS apparatus on the same host.~~ **Run** — see
  §*Measured — the segmented step-capacity ladder*. It leaves the lane-versus-lane comparison still
  undrawn, because it is in a different rig.
- **The segmented ladder inside the `netns`/`cake` rig**, which is now the single most valuable
  outstanding cell in this experiment: it is what turns two ladders into one comparison, and the
  MoQ arm's disagreement between the rigs at 0.9× shows the gap is large enough to matter. It needs
  an HTTP origin reachable from inside the namespace, which is a rig change rather than a re-run.
- **A rung between 0.8× and 0.5× on the segmented lane.** Chronic 0.8× costs delivery but no
  programme and 0.5× costs 17.979 s, so the availability-window cliff is somewhere in that band and
  its position is what an operator provisioning retention would size against.
- **The withheld C2 cells** remain unpublished until the competing-flow instrumentation this protocol
  adds is in place — publishing them without it was judged worse than silence
  ([T8b § C2 withheld](test-8b-congestion-control.md#the-segmented-rows-of-c2-are-withheld-pending-a-re-run)).
