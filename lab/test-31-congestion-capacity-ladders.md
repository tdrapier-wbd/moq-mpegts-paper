# Test 31 — Congestion and capacity: the step ladders, both planes

**State: both step-capacity ladders are run, replicated and graded on content in the `netns`/`cake`
rig — three replicates per MoQ rung, two to three per segmented rung — with each lane's absorption
boundary walked, and the segmented one also run in T20's loopback/`netem` rig, which carries a MoQ
arm. The delay × contention × RTT matrix is run in three replicates on the merged build: no release
delay up to 6 s absorbs a sustained 0.8× share, and against a 5 s dip to 0.8× only 6 s at 200 ms RTT
absorbs the video, with the shaper dropping nothing. Every MoQ figure in this file is graded by
[`t28-content-lost.py`](scripts/t28-content-lost.py); the PCR-graded MoQ figures this file used to
carry were an artefact of the exporter and are withdrawn (see *Corrections*).**
[T8b](test-8b-congestion-control.md) settled which controller wins under which provisioning and queue
discipline, and attributed the MoQ lane's shared-bottleneck collapse to per-subscriber deadline
shedding at `--latency-max`. This experiment asks a different question — how much impairment each
lane absorbs before programme is lost — and extends T8b with step-capacity ladders on both planes
plus the withheld segmented C2 cells.

**Headline: the MoQ lane loses picture at every rung below 1.1× of the stream's rate, including
1.0×, and keeps its sound.** Against a 9.95 Mb/s stream on `ffa5b81b`, sixty seconds at exactly the
stream's rate costs **7.3–9.6 s of video in holes** (10.3–12.6 s conserved), and at **0.9× it costs
13.4–18.4 s** across six samples, in holes of up to 2.4 s, while audio loses 0–1.7 s. Chronic 0.8×
costs 13.4–25.7 s of video and 0.5× costs 60.2–75.6 s — at 0.5× the picture stops for most of the
dip. These are the holes; each shedding cell is a further 1.5–9.4 s short when its window closes.
**1.1× is clean in all three replicates**, so the boundary lies between 1.0× and 1.1× of the
transport-stream rate. A 5 s transient at 0.8× costs 0–1.1 s in holes and is 1.6–4.3 s short at
close, which may be lag rather than loss.
The lane sheds more picture than the deficit it is short of — which, by reasoning rather than
measurement, follows from discarding whole groups on a deadline — and it sheds each track
separately: video is evicted while audio continues. Neither padding nor the
congestion controller changes these figures beyond single-sample scatter.

**Second headline: the segmented lane absorbs three rungs the MoQ lane does not, and when it does
break it breaks by a different mechanism.** Over HTTP/3 it delivers the 0.9×-for-60 s and
0.8×-transient rungs **byte-identically to its own headroom control**, and carries chronic 0.8× at
**zero content lost and a 24.95 ms worst-case PCR interval** while running 12.7 % behind the live
edge. It fails at 0.5×, and not by shedding: the receiver falls far enough behind that the origin has
already deleted the segment it asks for, and it takes a 404. **Under-provision costs this lane
latency until the availability window runs out, and then it costs it the programme; it costs the MoQ
lane picture from the first sustained rung.** In the loopback rig, where both lanes ran in the same
session, the ranking is direct: 0.000 s of video lost against the MoQ arm's 19.7 s at 0.9× and
34.6 s at chronic 0.8×. **The ranking holds in the `netns`/`cake` rig** at every rung, but there the
segmented lane's availability window runs out sooner: 0.9× for 60 s costs it one segment (2.4 s) in
two of three samples against the MoQ lane's 13–18 s, and every 60 s rung from 0.8× down sheds
(9.6 s in holes at 0.8×, 11.9–19.8 s at 0.7× and 0.6×). It is not a comparison at equal latency: the
segmented lane absorbs by lagging up to ~21 s, the MoQ lane holds a 2 s budget and discards. **Under
random loss at 100 ms RTT the segmented lane collapses outright** — two segments, then nothing, at
5 % — because its origin's QUIC sender is loss-based; its loopback immunity to loss does not survive
the RTT.

**The substrate was never missing, and that was this file's error.** The rig is `t8b-netns.sh` — two
network namespaces joined by a veth — which is Linux-only, and the campaign's workstation is macOS.
But both EC2 Linux hosts have `netem` and namespaces and had already used them for
[T8b](test-8b-congestion-control.md), [T5](test-5-network-impairment.md) and
[T20](test-20-segmented-http3.md). The ladder ran on the **EC2 secondary**, sharing its rig setup with
[T28](test-28-failure-injection-matrix.md)'s transport axis exactly as planned. Re-basing on macOS
dummynet would still have been wrong, for the comparability reason, and was not done.

**Programme lost is graded on content, per elementary stream.** On the MoQ lane that is
[`t28-content-lost.py`](scripts/t28-content-lost.py), which reads presentation timestamps; the PCR
grader `t28-media-lost.py` cannot be used there, because `moq export ts` keeps writing PCR across
the pictures it has lost ([method-notes](method-notes.md) § *The exporter manufactures bytes and
clock*). On the segmented lane the receiver is byte-faithful and the two graders agree to within
0.14 s on every retained capture, so the PCR figures in that table stand.

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
| MoQ lane | `moq import ts` → relay → `moq export ts`; build named per table. The relay's controller is pinned with `--quic-congestion-control` (`--server-quic-congestion-control` on pre-migration builds) to `delay` unless an arm varies it; that is also what every build tested resolves an unset flag to — BBRv1 on quinn builds, BBRv3 on noq builds ([method-notes](method-notes.md) § *The default congestion controller changed*). Padding is suppressed with `--mux-rate 0` on the builds that pad by default. |
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
not a timing comparison — safe to interleave with non-timing work in the same window ([P1-d, scheduling](planned-experiments.md#scheduling-constraints)).

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
**`ffa5b81b`** (noq), `--max-age 3s`, n = 1 subscriber, **no groomer in the path**. Rig
[`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh) with `STREAM_MBIT=9.95`; graded with
[`t28-content-lost.py`](scripts/t28-content-lost.py) on the exporter's output (**P1**, content
domain), the first 8 s excluded because every capture carries a ~0.9 s join hole that is not the
impairment. Three arms, one sample per cell each: padded with the controller at `delay` (BBRv3),
unpadded at `delay`, and unpadded at `loss` (CUBIC). Steps are re-shaped with `tc qdisc change` so
the queue is not torn down and re-added, which would itself drop the backlog and be scored as the
impairment.

**The rungs are multiples of the stream's own rate, not absolute rates.** `STREAM_MBIT=9.95` is the
fixture's measured rate and the script derives each rung from it, for the reason in *The rungs had to
be re-based* below. The table gives the multiple, the shaped rate it computes to, and the shortfall
that leaves against the programme.

Video lost in holes is given per arm, in the order padded at `delay` / unpadded at `delay` /
unpadded at `loss`; the other columns give the range across the three. **Short at close** is the
further video the cell had not delivered when its window ended, conserved against the same arm's
control by [`t2831-conservation.py`](scripts/t2831-conservation.py): a hole count sees only gaps
between pictures that arrived, so a picture that stops before the window does leaves nothing to
count. It is lost or late by up to the 3 s budget, and its resolution is about ±1 s — the clean
rungs read 0.0–0.9 s.

| Step | Shaped rate | Shortfall vs stream | Video lost in holes (three arms) | Short at close | Largest video hole | Audio lost | Continuity errors |
|---|---|---|---|---|---|---|---|
| none (control) | 20 Mb/s | — | **0.00 / 0.00 / 0.00 s** | reference | — | 0.00 s | 0 |
| 1.2× for 60 s | 11.94 Mb/s | **none: +20 % headroom** | **0.00 / 0.00 / 0.00 s** | 0.0–0.6 s | — | 0.00 s | 0 |
| 0.9× for 60 s | 8.96 Mb/s | −10 % | **16.00 / 16.28 / 13.40 s** | 1.5–5.9 s | 2.36–2.40 s | 0.00–1.73 s | 0 |
| 0.8× for 5 s | 7.96 Mb/s | −20 %, transient | **0.00 / 0.28 / 1.12 s** | 1.6–4.3 s | 0.28–1.12 s | 0.00 s | 0 |
| 0.8× permanent (45 s) | 7.96 Mb/s | −20 %, chronic | **13.44 / 22.76 / 24.84 s** | 2.3–9.4 s | 2.40–10.84 s | 0.29–1.30 s | 0 |
| 0.5× for 60 s | 4.97 Mb/s | −50 % | **65.12 / 69.84 / 75.64 s** | 2.4–3.0 s | 32.36–64.76 s | 0.00 s | 0 |

The continuity column is zero by construction and tests nothing on this lane: the exporter writes
its own continuity counters over whatever it re-muxes, so a discarded group leaves no gap in them
([method-notes](method-notes.md) § *A continuity count detects loss and cannot measure it*).

**Only headroom is clean.** Sixty seconds at 0.9× stream rate is a mild deficit — about 60 Mbit the
link cannot carry in the window — and it costs 13.4–16.3 s of picture, 22–27 % of the video in the
dip for a 10 % shortfall. It arrives as 11–14 holes of up to 2.4 s each, which is the shape of whole
groups discarded on a deadline. **The lane loses more picture than it is short of capacity.** That
follows, by reasoning rather than measurement, from discarding at group granularity: a group that
misses its deadline after being partly delivered spent link capacity on bytes that are then thrown
away. The deeper rungs scale the same way; at 0.5× the largest hole is 32–65 s and the picture is
effectively absent for the dip.

**The sound survives, because it is a different track.** Audio loses 0–1.7 s where video loses
13–25 s, and nothing at 0.5× where video loses 65–76 s. MoQ carries each elementary stream as its own
track and sheds each on its own deadline, so the small audio track keeps up while the video track's
groups are evicted. The broadcast consequence is a programme with continuous sound and a picture
that freezes or drops out, delivered as a transport stream with no continuity error and — because
the exporter keeps writing PCR across the missing pictures — a clean clock.

**Neither padding nor the controller decides these cells.** Padded against unpadded at `delay`:
16.00 against 16.28 s at 0.9×, 65.12 against 69.84 s at 0.5×. Padding is applied at the subscriber,
after the link, so it cannot change what was delivered, and it did not. BBRv3 against CUBIC, both
unpadded: 16.28 against 13.40, 22.76 against 24.84 and 69.84 against 75.64 s, no consistent
direction. The chronic rung's 13.44–24.84 s spread across three arms is single-sample scatter of the
same size as the retained replicates below; replicates are what would resolve a controller effect
smaller than that.

**Whether a transient is absorbed is not settled.** Five seconds at 0.8× costs 0.00–1.12 s of video
in holes, and the cell is a further 1.6–4.3 s short at close. That is within or just beyond the 3 s
budget, so it may be residual lag rather than loss; the arm that separates the two extends the
recovery period past the budget and conserves again.

### Replicated, and the boundary is between 1.0× and 1.1× of the stream's rate

The same ladder, three further invocations on `ffa5b81b`, unpadded, relay controller `delay`
(BBRv3), each with its own control, plus three rungs between 1.1× and 0.95× in three more
([`t2831-boundaries.sh`](scripts/t2831-boundaries.sh)). Video lost in holes, then missing at close
conserved against the invocation's control, replicates in order:

| Step | Video lost in holes | Missing at close (holes + short) |
|---|---|---|
| 1.1× for 60 s | 0.00, 0.00, 0.00 s | 0.60, −0.32, 0.28 s |
| 1.0× for 60 s | 9.64, 7.36, 7.32 s | 12.62, 12.16, 10.30 s |
| 0.95× for 60 s | 10.12, 10.60, 14.04 s | 13.10, 13.26, 18.54 s |
| 0.9× for 60 s | 16.52, 15.28, 18.44 s | 19.78, 18.82, 21.10 s |
| 0.8× for 5 s | 1.00, 0.00, 0.90 s | 1.72, 1.92, 3.70 s |
| 0.8× permanent (45 s) | 21.76, 20.20, 25.72 s | 24.90, 23.06, 28.66 s |
| 0.5× for 60 s | 64.52, 69.40, 60.16 s | 68.06, 72.10, 64.02 s |

**The replicates agree with the single-sample arms above** to within their scatter: 0.9× loses
15.3–18.4 s in holes against 13.4–16.3 s, chronic 0.8× 20.2–25.7 s against 13.4–24.8 s, 0.5×
60.2–69.4 s against 65.1–75.6 s. No rung moved in kind.

**The lane cannot be provisioned at the transport stream's own rate.** 1.1× is clean in all three
replicates, within the ±1 s conservation resolution; 1.0× loses 7.3–9.6 s of picture in holes, and
0.95× 10.1–14.0 s. Two qualifications travel with the boundary. The rungs are multiples of the TS
rate, while `cake` shapes on packet size, and QUIC, UDP and IP framing add a few per cent on the wire
(*reasoned*, not measured here) — so 1.0× of the TS rate is already a small shortfall at the
bottleneck, and what the rung shows is that the lane sheds at any wire shortfall rather than that it
carries unusual overhead. And the boundary is for one subscriber, one stream and 60 s at the rung;
[T8b](test-8b-congestion-control.md) measured the provisioning margin that holds under contention
separately, and it is wider.

### The chronic rung sheds every time; the earlier builds agree

Three earlier arms had replicated the chronic 0.8× rung to separate the QUIC backend from the build:
`5d0991b9` on quinn (A) and on noq (B), which isolates the backend, and `84b34f54` on noq (C). All
three ran with the controller unset, which on every one of these builds resolves to `delay`. The rig
then deleted any capture it graded as clean, so the replicates that survive to be graded on content
are the five below, plus the single chronic and 0.5× captures of the first `84b34f54` ladder.

| Arm | Build | QUIC backend | Video lost, retained chronic 0.8× captures | Largest hole | Audio lost |
|---|---|---|---|---|---|
| A | `5d0991b9` | quinn (BBRv1) | 36.36 s | 20.28 s | 0.84 s |
| B | `5d0991b9` | noq (BBRv3) | 14.08, 17.28 s | 2.40–3.84 s | 0.00 s |
| C | `84b34f54` | noq (BBRv3) | 18.36, 17.70 s | 2.52–3.16 s | 0.00 s |
| first ladder | `84b34f54` | noq (BBRv3) | 17.24 s | 2.88 s | 0.00 s |

**Every retained capture of the chronic rung lost 14–36 s of picture**, in line with the 13.4–24.8 s
the `ffa5b81b` arms lose on the same rung; the first ladder's 0.5× capture lost 66.92 s against
65.1–75.6 s. So the rung is not on an absorption threshold, and the lane's behaviour under a
sustained shortfall has not moved materially between `5d0991b9` and `ffa5b81b`. **What the retained
set cannot answer is the backend comparison the arms were built for**: which replicates were kept
was decided by the invalid grader, so the set is selected, and arm A has one survivor. Nor was A
against B ever the clean instrument for the backend it was designed as: `delay` is BBRv1 on quinn
and BBRv3 on noq, so the two arms varied the controller along with the stack. That arm, every capture
retained and both stacks pinned to CUBIC, has since run on the 0.9× rung (below), where the stacks do
shed differently; on the chronic rung it has not been run.

**The 0.9× rung does move with the build.** [T28](test-28-failure-injection-matrix.md)'s bisection
ran this ladder's 0.9×-for-60 s cell at the same 3 s budget, three replicates per build, controller
`delay`, every capture conserved: `fd4f5d82e` (quinn) misses 5.16–7.84 s, `5d0991b9` 9.86–13.90 s on
quinn with one replicate at 54.48 s, and 17.76–21.62 s on noq; `53f8aa99d`, `84b34f54` and
`ffa5b81b` (all noq) 18.02–34.62 s. So the lane sheds at 0.9× on every build, and the oldest sheds
about a third as much.

**It moves with the stack as well, and not with the controller.** With both stacks of `5d0991b9`
pinned to CUBIC, same cell and rig, three replicates each, every capture conserved, quinn misses
15.90, 20.88 and 19.18 s and noq 22.78, 38.46 and 25.74 s
([T28](test-28-failure-injection-matrix.md) § *The build bisection*). Under each stack's own `delay`
the ordering is the same, so the separation is the stack's. The 5 s outage on the same arms shows no
separation at all, which points to how each stack's sender behaves at a sustained ceiling rather than
to how it recovers from a break; that is reasoned, and what in the stack does it is not measured.

The absolute-rate ladder's chronic cell, on `fd4f5d82e` at 8 Mb/s, stays **withdrawn**, now for a
different reason: its retained capture spans only 19 s past the join, and a capture that stops
early grades as clean on any grader.

### No release delay up to 6 s absorbs a sustained 0.8× share, at either contention or any RTT

Criteria 6, 7 and 9 on `b581c27e` (moq 0.14.2, moq-relay 0.17.2, noq, controller `delay`), in the
`netns`/`cake` rig on the EC2 tertiary (replicate 1) and secondary (replicates 2–3), same build on
both: 48 cells × 3 replicates, 360 subscriber captures, none void, each graded on content.

**Criterion 6.** All 180 control subscribers lose 0.00 s, and none moves more than 100 ms between the
first and last third of its window, so none is excluded. Control latency stands at about twice the
delay: 1.83–2.87 s at 1 s (bimodal only at 20 ms RTT; 1.88–2.26 s at 100 and 200 ms), 3.68–4.84 s at
2 s, 7.84–7.94 s at 4 s and 11.82–12.14 s at 6 s.

**Criterion 7.** Video lost at 0.8× for 80 s, median and range over three replicates × n subscribers;
every control is 0.00 s:

| n | RTT | `--delay` 1 s | 2 s | 4 s | 6 s |
|---|---|---|---|---|---|
| 2 | 20 ms | 18.3 (18.1–19.2) | 18.1 (17.6–18.5) | 16.3 (15.6–18.2) | 15.3 (14.6–17.2) |
| 2 | 100 ms | 18.5 (17.8–19.8) | 18.4 (16.7–19.2) | 17.2 (14.0–18.4) | 15.4 (14.6–16.6) |
| 2 | 200 ms | 19.1 (18.0–21.7) | 18.5 (17.0–21.9) | 17.0 (16.0–18.4) | 16.0 (14.5–18.8) |
| 3 | 20 ms | 18.0 (17.4–18.9) | 17.9 (16.7–18.6) | 16.8 (15.7–17.4) | 15.3 (14.2–16.7) |
| 3 | 100 ms | 18.3 (16.8–19.6) | 18.0 (16.3–19.2) | 16.2 (15.6–17.1) | 15.6 (14.0–18.5) |
| 3 | 200 ms | 19.0 (17.2–19.9) | 18.5 (17.1–20.6) | 17.0 (15.4–21.4) | 15.8 (14.3–17.7) |

**No delay in the ladder brings any subscriber within ±1 s of its control**, at either n or any
RTT. The curve falls with the delay, by 2.7–3.2 s of median from 1 s to 6 s, so each second of delay
buys back about 0.6 s of picture for about 2 s of latency. Neither n nor RTT moves a median by more
than 1.1 s at a given delay. The picture goes in holes of 0.48–1.36 s; audio loses 0–0.16 s; the
export's late drops are 0–5 per subscriber, so the loss is not the release deadline's. The window's
20 % shortfall is 16 s at the stream's rate, and 15.4–15.5 s at the lane's own wire rate, 0.99× of
it (criterion 10's controls, below).

### A 6 s delay absorbs a 5 s dip's video at 200 ms RTT, and no delay up to 6 s does at 20 ms

Criterion 10 on the same build and rig, on the secondary: 72 cells (n ∈ {2, 3} × `--delay` {1, 2,
6 s} × RTT {20, 200 ms} × dip or control × three replicates), 180 subscriber captures, none void,
each graded on content. All 90 control subscribers lose 0.00 s of video and audio, with no frame
late.

Video lost in the dip cells, median and range over three replicates × n subscribers, then the
subscribers that absorb the dip:

| n | RTT | `--delay` 1 s | 2 s | 6 s |
|---|---|---|---|---|
| 2 | 20 ms | 1.10 (0.84–1.20); 0 of 6 | 0.78 (0.72–1.00); 0 of 6 | 0.40 (0.20–0.48); 0 of 6 |
| 2 | 200 ms | 0.72 (0.56–0.88); 0 of 6 | 0.34 (0.00–0.76); 1 of 6 | 0.00; **6 of 6** |
| 3 | 20 ms | 1.00 (0.72–1.16); 0 of 9 | 0.72 (0.48–1.16); 0 of 9 | 0.28 (0.24–0.36); 0 of 9 |
| 3 | 200 ms | 0.64 (0.12–1.12); 0 of 9 | 0.36 (0.00–0.64); 1 of 9 | 0.00; **9 of 9** |

**The smallest delay that absorbs the dip for every subscriber is 6 s at 200 ms RTT, at both n; at
20 ms none in the ladder does**, though 6 s cuts the loss to 0.20–0.48 s. The largest hole per
subscriber is 0.12–0.40 s, but 0.60 and 0.80 s in two, and no video frame is late in any cell, so the
loss is not the release deadline's.
Delivered latency in the dip cells is the controls' to within 0.14 s at the median: what is lost is
not carried as lag.

**Audio is lost too, as it was not under the sustained shortfall.** In each dip cell 5–11 of 15
subscribers lose more than 0.1 s of audio, up to 2.11 s at a 1 s delay and up to 0.86 s at 6 s and
200 ms RTT, where every subscriber's video is absorbed. Criterion 10 grades video, so "absorbs" is
video's alone.

**The bottleneck drops nothing.** The shaper's drop counter stays at 0 in every cell, dip included;
its backlog peaks at 0.17–0.35 MB at 20 ms RTT and 0.90–2.18 MB at 200 ms. During the dip the class
runs full (15.67–15.92 and 23.75–23.88 Mb/s), and after it runs above its pre-dip rate (19.98–23.13
against 19.51–19.70 Mb/s at n = 2, 29.75–34.45 against 29.18–29.52 at n = 3). What is lost is lost
before the shaper's queue, at the relay or its sender, which only criterion 8's instrumentation can
place. That the longer path absorbs more is consistent with it holding more of the backlog in flight
and in the shaper's queue, by reasoning rather than measurement.

**The lane's wire rate.** Unimpaired, each subscriber's flow averages 9.86–9.87 Mb/s at the shaper
(19.71–19.73 Mb/s for two, 29.57–29.60 for three), 0.99× the stream's 9.95 Mb/s, so the dip withholds
about 0.97 s of each subscriber's media, where the criterion assumed 1 s.

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

**Where the knee sits is bounded but not located in this rig.** Absorption is complete at 0.9×
sustained and at 0.8× transient, costs 17.6 % of delivery but no programme at 0.8× chronic, and
breaks somewhere between 0.8× and 0.5×. No rung was run in that gap on loopback; the boundary walk
was run in the `netns`/`cake` rig instead (next section but one).

### The loopback segmented ladder is in a different rig, and its column must not be subtracted

The MoQ ladder above ran in `t8b-netns.sh`: two namespaces joined by a veth, `cake` at the
bottleneck, 100 ms base RTT. The segmented ladder in the table above ran against T20's nginx pair on
the host instead, so on **loopback with `netem`, no added RTT, and a token bucket rather than an
AQM**; the same ladder inside the namespace rig is in the next section. That is a materially easier path in one respect and a materially harsher one in another, and
neither difference is small.

The size of it is measurable, because the segmented rig also carries a MoQ arm, run on the same
rungs in the same session on `ffa5b81b` and graded on content. The figures are video lost in
holes on both MoQ columns; the loopback rig has no per-window conservation, so they are lower
bounds there:

| Step | MoQ video lost, loopback/`netem` | MoQ video lost, `netns`/`cake` (three arms) | Segmented video lost, loopback/`netem` |
|---|---|---|---|
| none (control) | 0.00 s | 0.00 s | 0.00 s |
| 0.9× for 60 s | 19.74 s | 13.40–16.28 s | 0.00 s |
| 0.8× for 5 s | 0.88 s | 0.00–1.12 s | 0.00 s |
| 0.8× permanent | 34.64 s | 13.44–24.84 s | 0.00 s |
| 0.5× for 60 s | 57.16 s | 65.12–75.64 s | 17.84 s |

**The two rigs agree about the MoQ lane in kind and roughly in size.** Both lose picture from the
first sustained rung. The loopback rig costs more at 0.9× and chronic 0.8× and less at 0.5×, with one
sample against three, and the `netem` token bucket at `limit 1000` has no AQM and a shallow queue, so
some difference is expected. The loopback arm's audio loses 1.7–2.7 s on those rungs and 20.3 s at
0.5×, more than under `cake`. Its outage cells are not usable: their captures stop about 8 s after
the join, and a capture that stops early grades as clean.

What follows for reading them: **within the loopback rig the lanes are ranked directly**, same
rungs, same session, same grader — the segmented lane loses no picture on three rungs where the MoQ
lane loses 0.9–34.6 s, and less at 0.5× (17.84 against 57.16 s). The `netns`/`cake` ranking is below.

### In the `netns`/`cake` rig the ranking holds, and the segmented lane sheds at chronic 0.8× too

[`t31-seg-netns.sh`](scripts/t31-seg-netns.sh) puts an HTTP/3 origin inside the publisher namespace
— its own nginx on 10.99.0.1, QUIC only, `http3_stream_buffer_size 16m` — and the byte-faithful
receiver inside the subscriber namespace, holding **one connection for the run** as a player does.
Both settings are required: at nginx's 64k default the origin caps a stream at ~4.8 Mb/s at this RTT,
and a receiver that reconnects every cycle falls behind the live window on the unimpaired control
([T42](test-42-h3-receiver-fidelity.md) § *What the receiver costs in time*). Same veth, `cake` at
20 Mb/s, 100 ms RTT, the same rungs as multiples of 9.95 Mb/s and the same settle/recover timeline
as the MoQ ladder; content-graded from 8 s and conserved against the invocation's own control.
Packager `tsp -O hls --live 6 --live-extra-segments 3 --duration 2`, segments ~2.46 s. One sample
per cell, **wire** domain, **P1**, one host.

The first pass is one sample per cell; [`t2831-boundaries.sh`](scripts/t2831-boundaries.sh) then
replicated the shedding rungs twice, walked 0.8×–0.6× for 60 s, and re-ran the 30 s outage and the
loss cells with the receiver recording a truncated segment as a hole and a 60 s per-fetch timeout.
Video lost in holes, first pass then replicates:

| Step | Segmented video lost in holes | Holes (cause) | Lag max, first pass | MoQ video lost in holes, same rig |
|---|---|---|---:|---|
| none (control) | 0.00; 0.00, 0.00 s | 0 | 8.5 s | 0.00 s |
| 1.2× for 60 s | 0.00 s | 0 | 8.2 s | 0.00 s |
| 0.9× for 60 s | **0.00; 2.40, 2.40 s** | 0 or 1 (a segment evicted before it was fetched) | 21.4 s | 13.40–18.44 s |
| 0.8× for 5 s | 0.00; 0.00, 0.00 s | 0 | 6.9 s | 0.00–1.12 s |
| 0.8× for 60 s | 9.60, 9.60 s | 4 segments evicted | — | — |
| 0.7× for 60 s | 14.40, 11.88 s | evictions | — | — |
| 0.6× for 60 s | 19.80, 14.84 s | evictions | — | — |
| 0.8× permanent | **2.40; 2.40, 2.40 s**, and 12.4–14.8 s short at close | 1 eviction | 21.3 s | 13.44–25.72 s |
| 0.5× for 60 s | **20.36; 22.64, 23.08 s** | two 404s, then evictions | 21.9 s | 60.16–75.64 s |
| outage 5 s | 0.00 s | 0 | 18.5 s | 16.96–20.84 s missing ¹ |
| outage 30 s, truncation as a hole | **23.08, 23.08 s** | nine segments rolled out of the window during the outage | — | session ends ² |
| loss 5 %, whole window | **all but two segments** — 60.9–61.1 s missing of the window | every fetch after the second failed | — | — |
| loss 10 %, whole window | **one segment or none** | the first fetch truncated | — | — |

¹ Conserved (holes plus short at close) on the MoQ ladder's three arms. ² At the 30 s default idle
timeout ([T28](test-28-failure-injection-matrix.md) § *The 30 s cell was the QUIC idle timeout*).
Audio on the segmented lane tracks video to within 0.12 s on every cell, because a segment carries
both. Short at close is within the conservation's ±1.3 s resolution on every segmented cell except
chronic 0.8×, and is shown only there. The two replicates of a rung often agree exactly, because
the lane loses whole segments of ~2.46 s.

**The lane ranking survives the move to the AQM rig.** At every rung and at the 5 s outage the
segmented lane loses less picture than any MoQ arm: at most one segment where the MoQ lane loses
13–18 s at 0.9×, 2.4 s against 13–26 s at chronic 0.8×, 20–23 s against 60–76 s at 0.5×. **It is not
a comparison at equal latency.** The segmented lane absorbs a shortfall by falling behind — its lag
reaches 21–22 s on every shedding or near-shedding rung, against ~2.4 s median on the control — while
the MoQ lane holds its 2 s release budget and discards. Which currency a route can spend is the
requirement's question ([R4](../docs/problem.md)), not this table's.

**Under `cake` at 100 ms RTT the availability window is what the lane runs into, and 0.9× is on its
edge.** The packager keeps nine segments (~22 s); the lag a 60 s shortfall builds reaches 21 s at
0.9×, so one segment is evicted in two samples of three. Every 60 s rung below that sheds, in whole
segments, roughly in proportion to the shortfall. Chronic 0.8× lags until the window runs out, loses
one segment and is still 12.4–14.8 s short at close; on loopback it lost nothing and ran 12.7 %
behind. **The lane's cliff is the availability window in both rigs, and at 100 ms RTT it arrives
sooner**, so the segmented lane's margin is sized by retention against the lag a shortfall builds,
not by the shortfall alone.

**Under random loss the segmented lane collapses, and the cause is the origin's sender.** Across the
whole window at 5 % loss the receiver fetched two segments and then no fetch completed; at 10 % it
got one segment or none. The receiver held its connection throughout, with truncation recorded as a
hole and a 60 s per-fetch timeout, so this is what the lane delivers rather than when the receiver
gives up. nginx's QUIC sender is loss-based, and at 100 ms RTT random loss bounds a loss-based flow
to well under 1 Mb/s (the Mathis bound is ~0.5 Mb/s at 5 %; *reasoned*, not measured here) — the
same bound that stops the MoQ lane's noq builds under sustained loss
([T28](test-28-failure-injection-matrix.md) § *Sustained partial loss*). **The segmented lane's
"loss is invisible" result is a loopback result**: at near-zero RTT the bound is far above the
stream, which is why T28's loopback cells return bytes identical to the control. What would make this
lane ride loss is the same thing that makes the MoQ lane ride it — a sender that does not yield to
random loss — and the arm that would show it runs the origin with BBR.

**The 30 s outage costs 23.08 s, identically in both replicates**, because the nine segments
produced during it rolled out of the window before the path returned. On loopback the same cell cost
17.134 s; the difference is the lag the receiver already carried at 100 ms RTT.

The two 115 s loopback windows that lost nothing (1.2× and 0.9×) read 75 on the PCR grader's
continuity column and a PCR "duplication" of 119.9 s, with identical byte counts, where the content
grader reads one timestamp discontinuity and nothing lost. **Both are the 120 s clip's loop point.**
Graded with no impairment at all, the clip concatenated with itself reads a duplication of
119.92 s and 97 on the same column, and the same stream packaged by `tsp -O hls` reads 119.92 s and
83, with 10 continuity events, four of them inside the one segment that spans the loop. The column
sums missing packets across PIDs rather than counting events, so its value depends on where the loop
falls against the packets each PID has in flight; the order of magnitude and the duplication are the
signature. No window that crosses the loop can be graded on the PCR grader's continuity column.

### The rungs had to be re-based, and the earlier ladder is superseded

The procedure originally called a 20 → 12 Mb/s step a "sustained moderate shortfall". Against this
campaign's ~9.95 Mb/s fixture, 12 Mb/s carries **20 % headroom** — it is not a shortfall at all, which
is why that cell returned zero and why its zero said nothing about capacity. The rungs were written
as absolute rates while the result depends on the rate *relative to the stream*, so the ladder had a
hole exactly where the commonest real under-provision sits: between a transient −20 % and a chronic
−20 %, nothing measured a *mild* sustained shortfall.

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

**Restated for builds whose export takes `--delay` (P1-d, P2-e), fixed before they run.** `--delay` is
a release delay: each frame goes out at its timestamp plus the delay, and one arriving later is
dropped and counted, so it sets delivered latency where `--latency-max` bounded staleness. Criterion 5
is replaced on those builds by:

6. **Delivered latency is measured, not assumed.** Each subscriber's median delivery latency in its
   unimpaired control is quoted beside its `--delay`, and criterion 7 is read against both. A subscriber
   whose latency moves by more than 100 ms across that window (first third against last third) is
   reported, and its cell is not used for criterion 7. Re-fixed before any cell ran: the merged build
   stands at about twice the delay ([T28](test-28-failure-injection-matrix.md) § *The outage traced
   on the merged build*), so a test against the setting would exclude every subscriber.
7. **Delay × contention × RTT (MoQ).** T8b C3's shared bottleneck with n ∈ {2, 3} subscribers,
   `--delay` ∈ {1, 2, 4, 6 s}, base RTT ∈ {20, 100, 200 ms}, through the permanent 0.8× rung: the
   shared class is held at 0.8 × n × the stream's rate for the whole 80 s window, as C3 held its
   class, and each subscriber's unimpaired control is the same cell at 2 × n
   ([`t31-delay-matrix.sh`](scripts/t31-delay-matrix.sh)). Each subscriber is graded on content, with
   its late-drop count. For each (n, RTT) the result is video lost
   against delay as a curve, and the smallest delay at which every subscriber is within the method's
   ±1 s of its unimpaired control, or the record that none in the ladder is. A curve that rises with
   the delay is a finding, not a failed cell.
8. **Recovery operating point on `--delay` builds.** The export holds a fixed delay by construction, so
   criterion 2's buffer test reads the relay's per-subscriber queue (the instrumentation P1-d asks
   for); the rate test is unchanged.
9. **Error bars (P2-e).** Every aggregate quoted from criterion 7, and every ladder rung on either lane,
   rests on at least three replicates and is quoted as a range; rungs with fewer are re-run to three
   before they are quoted again.
10. **A release delay against a transient shortfall (P1-d).** Criterion 7's rig, subscribers and
    grading, with the shared class at 2 × n × the stream's rate except for 5 s at 0.8 × n, from 30 s
    into the 80 s window; the control is the same cell with no dip. n ∈ {2, 3}, `--delay` ∈ {1, 2,
    6 s}, base RTT ∈ {20, 200 ms}, three replicates, interleaved. The dip withholds at least 1 s of
    each subscriber's media, so 1 s is the shortest delay that could cover it. A subscriber
    **absorbs** the transient if it loses no video (no hole above 100 ms) and no video frame misses
    its deadline, in a cell whose control loses none. For each (n, RTT) the result is the smallest
    delay at which every subscriber absorbs it, or the record that none in the ladder does. The
    shaper's queue is sampled every 0.5 s (bytes sent, drops, backlog), so a loss can be placed at
    the bottleneck or behind it; that is the bottleneck's queue, not the relay's per-subscriber queue
    criterion 8 needs.

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
| 1 | Longest step absorbed with zero media lost and 0 continuity errors | **MoQ: no shortfall rung is absorbed**, in either rig, and neither is 1.0× of the stream's rate; 1.1× is clean in three replicates, so the boundary is between 1.0× and 1.1× of the TS rate. The 5 s transient at 0.8× costs 0.00–1.12 s of video in holes and is 1.6–4.3 s short at close, unresolved between lag and loss. **Segmented, loopback/`netem`: 0.9× for 60 s, the 0.8× transient and chronic 0.8×** — byte-identical to its own control on the first two, 0 content lost and a 24.95 ms PCR maximum at 82.4 % of control delivery on the third. **Segmented, `netns`/`cake`: the 0.8× transient and the 5 s outage**; 0.9× for 60 s loses one segment in two samples of three, and every 60 s rung from 0.8× down sheds. No duration beyond 60 s. The lanes are ranked directly in both rigs, not at equal latency |
| 2 | Recovery operating point | **Not measured.** Delivery returned (subsequent cells were clean through the same rig) but buffer occupancy was not instrumented, so neither the 5 % rate nor the 10 % buffer test was applied |
| 3 | MoQ integrity invariant — any non-zero continuity error fails the cell | **Passes, and tests nothing.** 0 throughout, including the cells that lost 65–76 s of picture, because the exporter writes its own continuity counters. The criterion was written on the assumption that the MoQ egress's counters could show loss; they cannot, and content lost is the only integrity measure on this lane |
| 4 | C2 re-run validity | **Not run.** The withheld segmented C2 cells remain withheld |
| 5 | Latency-max ladder at n ∈ {2, 3} | **Not run at contention; superseded by 6–7 on `--delay` builds.** The budget axis was exercised only at n = 1, and only against an outage rather than a capacity step — recorded in [T28](test-28-failure-injection-matrix.md), where it produced a non-monotonic result that this criterion's phrasing assumes cannot happen |
| 6 | Delivered latency on `--delay` builds | **Met.** About twice the delay; no subscriber drifts more than 100 ms, none excluded |
| 7 | Delay × contention × RTT | **No delay in {1, 2, 4, 6 s} suffices** at n ∈ {2, 3} or any RTT: 14.0–21.9 s of video lost against 0.00 s controls, falling 2.7–3.2 s in median from 1 s to 6 s |
| 8 | Recovery on `--delay` builds | **Not run**; the relay's per-subscriber queue is not instrumented |
| 9 | Error bars | **Met for criteria 7 and 10** (three replicates per cell, quoted as ranges); the segmented rungs with two replicates are not yet at three |
| 10 | A delay against a transient shortfall | **6 s at 200 ms RTT; none in {1, 2, 6 s} at 20 ms**, at n ∈ {2, 3}, on video. The shaper drops nothing; audio loses up to 2.11 s, which the criterion does not grade |

Criterion 5 deserves a note rather than a bare "not run": it asks for the *smallest* budget that keeps
aggregate delivery above 95 %, which presumes delivery improves monotonically with the budget. T28
measured the opposite against an outage at n = 1. Criterion 7 asks the question as a curve instead,
and at contention against a capacity step that curve falls with the delay.

## What remains

The rig tears down and rebuilds from `t8b-netns.sh` on the EC2 secondary, and nothing here waits on
a third party.

- **Whether the MoQ boundary is the lane's or the wire's.** On `b581c27e` the lane's mean wire rate
  is 0.99× the TS rate (criterion 10's controls), so mean framing overhead does not set the
  1.0×–1.1× boundary measured on `ffa5b81b`; its rate over a keyframe's span is not measured.
- **Buffer and RSS instrumentation** for criteria 2 and 8, which the current rig does not collect.
  Criterion 10 puts the transient's loss upstream of the shaper's queue, video and audio alike, so
  the relay's per-subscriber queue is where criterion 8 has to look.
- **The segmented lane under loss with a sender that does not yield to it** — the same origin with
  BBR — which would say whether the collapse at 100 ms RTT is the lane's or its origin's controller.
- **Durations beyond 60 s** on either lane's boundary rungs; the segmented lane's margin is set by
  retention against accumulated lag, so a longer dip at 0.9× is the cell an operator sizing
  retention needs.
- **The withheld C2 cells** remain unpublished until the competing-flow instrumentation this protocol
  adds is in place — publishing them without it was judged worse than silence
  ([T8b § C2 withheld](test-8b-congestion-control.md#the-segmented-rows-of-c2-are-withheld-pending-a-re-run)).

## Corrections

- **The MoQ ladder was graded on the exporter's clock, and it said the lane absorbed what it shed.**
  This file reported 0.9× for 60 s and the 0.8× transient as absorbed with 0.000 s lost, chronic
  0.8× as bimodal around 0.000–1.000 s, and 0.5× as 3.100 s, all from the PCR grader. Graded on
  content, 0.9× loses 13.4–16.3 s of video, chronic 0.8× loses 13–36 s on every retained capture, and
  0.5× loses 65–76 s. `moq export ts` keeps writing adaptation-only PCR packets across the pictures
  it has lost, so a PCR timeline sees continuous clock over a hole in the programme; the
  "duplication" the PCR grader reported rising with severity was the same artefact, and the content
  grader finds none. The PCR grader had passed its self-test because excising bytes removes clock and
  content together, which is not how this lane fails. Method rule: [method-notes](method-notes.md)
  § *The exporter manufactures bytes and clock*. The content grader's hole count is itself a lower
  bound, since a picture that stops before the window closes leaves no hole; the *Short at close*
  column conserves against the control for that reason ([method-notes](method-notes.md) § *A hole
  count sees only gaps between what arrived*).
