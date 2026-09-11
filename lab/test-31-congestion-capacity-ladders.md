# Test 31 — Congestion and capacity: the step ladders, both planes

**State: specified, not run; blocked on a Linux host.** [T8b](test-8b-congestion-control.md) settled
which controller wins under which provisioning and queue discipline, and attributed the MoQ lane's
shared-bottleneck collapse to per-subscriber deadline shedding at `--latency-max`. This experiment asks
a different question — how much impairment each lane absorbs before programme is lost — and extends
T8b with step-capacity ladders on both planes plus the withheld segmented C2 cells.

**Why it has not run, corrected.** This was previously recorded as deprioritised behind Gate 2 and
observability work, with the note that "the namespace rig and grading scripts already exist". They do
exist, but the rig is `t8b-netns.sh` — two network namespaces joined by a veth — which is **Linux-only,
and the workstation this campaign runs on is macOS**. The ladders cannot be run here at all, and
re-basing them on macOS `dnctl`/`pfctl` dummynet would put them on a different emulator from
[T8b](test-8b-congestion-control.md), [T5](test-5-network-impairment.md) and
[T20](test-20-segmented-http3.md), so the step ladders could not be compared with the results they are
meant to extend. It needs no live source and no third party — it needs a Linux host, which is the same
blocker as [T28](test-28-failure-injection-matrix.md)'s transport axis and should be resolved once for
both.

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

1. **20 → 8 Mb/s for 5 s** — brief deep shortfall.
2. **20 → 12 Mb/s for 60 s** — sustained moderate shortfall.
3. **20 → 8 Mb/s permanently** — chronic under-provision.

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

## Why this has not run

The rig and grading exist from [T8b](test-8b-congestion-control.md); the MoQ half of [P1-d](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)
is estimated at ~20 minutes and needs no new apparatus. It has not been scheduled because the campaign
reorganised around permanence, Gate 2 preparation, and observability families where a negative result
would change immediate engineering priority. The withheld C2 cells remain unpublished until the
competing-flow instrumentation this protocol adds is in place — publishing them without it was judged
worse than silence ([T8b § C2 withheld](test-8b-congestion-control.md#the-segmented-rows-of-c2-are-withheld-pending-a-re-run)).
