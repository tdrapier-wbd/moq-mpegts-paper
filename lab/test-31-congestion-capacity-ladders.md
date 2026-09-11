# Test 31 — Congestion and capacity: the step ladders, both planes

**State: the MoQ step-capacity ladder is run, 2026-09-11; the segmented ladder and the latency-max ×
contention matrix are not.** [T8b](test-8b-congestion-control.md) settled which controller wins under
which provisioning and queue discipline, and attributed the MoQ lane's shared-bottleneck collapse to
per-subscriber deadline shedding at `--latency-max`. This experiment asks a different question — how
much impairment each lane absorbs before programme is lost — and extends T8b with step-capacity
ladders on both planes plus the withheld segmented C2 cells.

**Headline: the MoQ lane absorbs a transient shortfall of any depth tested and sheds steadily under a
chronic one.** A 5 s drop to 8 Mb/s against a 9.95 Mb/s stream — a shortfall of 20 % of stream rate,
below the rate the programme needs — cost nothing at all. The same shortfall left in place cost 7.05 s
of programme in 45 s, in six separate holes. **0 continuity errors in every cell**, so the ladder's
integrity invariant (criterion 3) holds throughout.

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

## Measured — the MoQ step-capacity ladder

**Environment.** EC2 secondary, 8 vCPU / 15 GB, Ubuntu 26.04 — the primary's 2 vCPU cannot carry a
relay, a publisher and a subscriber without the knee being the host's. Two network namespaces joined
by veth (`t8b-netns.sh`), `cake` at the bottleneck, 100 ms base RTT (50 ms each way). Source a 120 s
~9.95 Mb/s CBR slice of `CNNiEMEA2.ts` paced with `tsp regulate --pcr-synchronous`. Build `moq`
0.11.0-`fd4f5d82e`, `--latency-max 3s`, n = 1 subscriber, **no groomer in the path**. Rig
[`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh); graded with
[`t28-media-lost.py`](scripts/t28-media-lost.py) in the **wire** domain, at **P1**, one sample per
cell. Steps are re-shaped with `tc qdisc change` so the queue is not torn down and re-added, which
would itself drop the backlog and be scored as the impairment.

| Step | Shortfall vs stream | Media lost | Holes | Largest hole | Continuity errors |
|---|---|---|---|---|---|
| none (control) | — | **0.000 s** | 0 | — | 0 |
| 20 → 8 Mb/s for 5 s | −20 % of stream rate | **0.000 s** | 0 | — | 0 |
| 20 → 12 Mb/s for 60 s | **none: 12 > 9.95** | **0.000 s** | 0 | — | 0 |
| 20 → 8 Mb/s permanent (45 s) | −20 % of stream rate | **7.050 s** | 6 | 3.225 s | 0 |

**The transient step is absorbed completely.** Five seconds at 8 Mb/s against a stream needing
9.95 Mb/s is a real shortfall of about 10 Mbit of programme, and none of it was lost: the `cake` queue
plus the 3 s latency budget covered it. This is the ceiling criterion 1 asks for, and on the durations
tested the transient ceiling was not reached.

**The chronic step sheds, and sheds repeatedly rather than once.** Six holes in 45 s, the largest
3.225 s, totalling 7.05 s. The lane does not degrade gracefully into a lower-rate version of the
programme — it cannot, because the stream is CBR and the bitrate is not the lane's to change — so it
discards whole groups on a deadline and keeps the rest current. That is the deadline-shedding
mechanism [T8b](test-8b-congestion-control.md) attributed, now measured as programme cost rather than
as delivered fraction.

### The specified 12 Mb/s cell does not test what it was specified to test

The procedure calls the 20 → 12 Mb/s step a "sustained moderate shortfall". Against this campaign's
~9.95 Mb/s fixture, 12 Mb/s carries **20 % headroom** — it is not a shortfall at all, which is why the
cell returned zero and why its zero means nothing about capacity. The ladder's rungs were written as
absolute rates while the result depends on the rate *relative to the stream*. **Re-base the ladder on
multiples of stream rate** — 1.2×, 0.9×, 0.8×, 0.5× — before any further cells are run, or the
sustained-moderate rung will keep returning a null for arithmetic reasons. The gap this leaves is
real: between "absorbed entirely" at a transient −20 % and "7.05 s lost" at a chronic −20 %, nothing
measures a *mild* sustained shortfall, which is the commonest real under-provision.

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
| 1 | Longest step absorbed with zero media lost and 0 continuity errors | **Reported for the MoQ lane**: a 5 s transient at −20 % of stream rate, absorbed completely. The transient ceiling was not reached, so it is a lower bound rather than a ceiling. No figure for the segmented lane, which has not run |
| 2 | Recovery operating point | **Not measured.** Delivery returned (subsequent cells were clean through the same rig) but buffer occupancy was not instrumented, so neither the 5 % rate nor the 10 % buffer test was applied |
| 3 | MoQ integrity invariant — any non-zero continuity error fails the cell | **Pass on every cell run.** 0 throughout, including the chronic step that lost 7.05 s |
| 4 | C2 re-run validity | **Not run.** The withheld segmented C2 cells remain withheld |
| 5 | Latency-max ladder at n ∈ {2, 3} | **Not run at contention.** The budget axis was exercised only at n = 1, and only against an outage rather than a capacity step — recorded in [T28](test-28-failure-injection-matrix.md), where it produced a non-monotonic result that this criterion's phrasing assumes cannot happen |

Criterion 5 deserves a note rather than a bare "not run": it asks for the *smallest* budget that keeps
aggregate delivery above 95 %, which presumes delivery improves monotonically with the budget. T28
measured the opposite against an outage at n = 1. Whether that survives at contention is exactly what
this criterion should settle, but the criterion as written cannot express the answer if it does.

## What remains

The rig is up on the EC2 secondary and nothing here waits on a third party.

- **Re-base the rungs on stream rate** (1.2×, 0.9×, 0.8×, 0.5×) and re-run, for the reason in the
  measured section. The absolute-rate rungs cannot express a mild sustained shortfall against a
  10 Mb/s fixture.
- **The latency-max × contention matrix** (criterion 5) at n ∈ {2, 3}, against capacity steps rather
  than outages, and phrased so a non-monotonic answer is expressible.
- **Buffer and RSS instrumentation** for criterion 2, which the current rig does not collect.
- **The segmented ladder**, using T20's HTTP/3 and HLS apparatus on the same host. Without it there is
  no lane-versus-lane comparison, which is the experiment's point.
- **The withheld C2 cells** remain unpublished until the competing-flow instrumentation this protocol
  adds is in place — publishing them without it was judged worse than silence
  ([T8b § C2 withheld](test-8b-congestion-control.md#the-segmented-rows-of-c2-are-withheld-pending-a-re-run)).
