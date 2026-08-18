# T12 — End-to-end 1+1 dual-path delivery and hand-off

## Objective

Grade what a broadcast head-end actually receives at a contribution or distribution hand-off: **two
complete, concurrently live delivery legs carrying one programme**, terminated by a receiver that
selects between them — hitlessly by RTP sequence number (ST 2022-7) or by input failover on leg
loss. The metric is what the *receiver* sees, not when a leg resumes.

**Why this is not [T6](test-6-relay-resilience.md).** Every redundancy number measured before this
was a single-leg recovery time — how long until bytes resumed on the one output being watched, which
is break-before-make by construction. T6 ran two legs and compared them byte-wise, and characterised
groomer determinism offline, on files. It stopped before RTP packetisation, before any receiver, and
before skew. T12 adds the four things a 1+1 claim needs: a dual RTP egress, a receiver that selects,
a switch metric denominated in lost packets rather than seconds, and a measured differential-delay
window.

## Environment

- One EC2 host (2 vCPU, 3.8 GB, Ubuntu, no swap), everything on loopback. `moq` 0.9.9 /
  `moq-relay` 0.14.9 release binaries, `mpegts-pacer` 0.1.0, TSDuck 3.44, negotiated wire
  `moq-lite-05`.
- Source: a **video-only, tightly VBV-constrained 2 Mbps** remux of the 600 s reference clip
  (300 s, H.264 1080i25, 2 s GOP, no B-frames, `vbv-bufsize=500` kbit, CBR TS at exactly
  2.000 Mbps, PCR every ~20 ms, 0 continuity errors). Video-only because `moq import` aborts on
  the audio frame-sync loss at a loop wrap ([T9](test-9-performance.md)); tight VBV because a
  loose one puts I-frame excursions, not transport behaviour, into the PCR statistics (see
  [Corrections](#corrections)).
- Egress CBR rate 4 Mbps for a 1.9 Mbps feed (55–60 % stuffing) — headroom, not realism: the
  groomer drops content when the target rate does not exceed the arriving content rate.
- The groomer runs with stall detection on: `--stall-ms 1000 --on-stall mute`, so a leg whose
  content stops arriving stops transmitting one second later while its output byte clock keeps
  running. Grooming otherwise decouples carrier liveness from content liveness, and every
  failure-detection scheme in this campaign keys on the carrier (see [Corrections](#corrections)).
- Rig: [`t12-dual-leg.sh`](scripts/t12-dual-leg.sh), receiver
  [`t12-merge-oracle.py`](scripts/t12-merge-oracle.py), grading
  [`t12-grade.sh`](scripts/t12-grade.sh), matrix [`t12-matrix.sh`](scripts/t12-matrix.sh),
  divergence analysis [`t12-conflict-anatomy.py`](scripts/t12-conflict-anatomy.py), resume
  behaviour [`t12-resume.py`](scripts/t12-resume.py). The later re-run against candidate exporter
  fixes uses a second, smaller rig on a laptop —
  [`t12-armd-join-local.sh`](scripts/t12-armd-join-local.sh) with
  [`t12-rtpcmp.py`](scripts/t12-rtpcmp.py) — which drops to one publisher and one relay so that the
  only asymmetry between the legs is when each exporter tuned in; its sources are stated with its
  results. Grading reads only the capture, so the whole
  campaign is re-graded from the pcaps whenever the receiver changes — which it did, four times. The
  standing loop publisher is stopped for the duration so CPU is attributable.

**Topology.** One source, fanned by `tee` into two *independent* chains — no cluster peering, so the
legs are disjoint by construction and relay reselect cannot mask a receiver-side result:

```
                       ┌─ moq import ts ─ relay A ─ moq export ts ─ egress A ─ RTP/UDP :5100 ─┐
source (one feed) ─fan─┤                                                                      ├─ one capture ─ oracle
                       └─ moq import ts ─ relay B ─ moq export ts ─ egress B ─ RTP/UDP :5200 ─┘
```

Both legs are captured by a single `tcpdump` on one interface, so the two arrival timestamps share a
clock and skew is exact. The receiver is offline: a reference implementation of the two selection
rules, computed over the same capture pair, so the policies are graded against identical inputs.

## Procedure

**Arms** differ only in how each leg turns delivered MoQ objects into RTP:

| Arm | Egress per leg | What it tests |
|---|---|---|
| A — no pacer | `moq export ts` → `tsp --buffer-size-mb 1 -O ip <dest> --rtp --enforce-burst --packet-burst 7 --start-sequence-number 0 --ssrc-identifier <fixed>` | the ungroomed control: with RTP framing pinned identically on both legs, does content identity alone yield alignment? |
| B — one pacer per leg | `mpegts-pacer` `moq_egress <dest> 4000000 --rtp --ssrc <fixed>` on each leg | the two-gateway topology of [architecture](../docs/architecture.md) §5.1, as the pacer is built today |
| C — one pacer, duplicated | one groom, identical datagrams to both destinations (`dual_rtp`) | **positive control.** The standard ST 2022-7 sender pattern; must be hitless or the rig is invalid |
| D — one *stream-clocked* pacer per leg | `moq_egress <dest> 4000000 --rtp --ssrc <fixed> --stream-clock --sequence-seed 0` on each leg | arm B's topology with the placement decision moved off the pacer's emit clock and onto the stream: can two independently groomed legs be a pair? |

Arm C grooms once, so it has a single upstream chain and only ever protects the **last hop**: it is
graded against the path injections, and the upstream ones do not apply — killing its publisher takes
the whole arm down, which is the honest result, not a rig failure. That asymmetry is the
architectural finding in miniature.

Arm D is arm B with one change of principle. Under `--stream-clock` the pacer places every packet on
the absolute output slot its source PCR implies at the locked mux rate, and derives the emitted PCR,
the RTP sequence number and the RTP timestamp from that slot, so what a leg sends is a function of
the stream rather than of when the process started or when the OS ran its timer. It requires an
explicit mux rate (an auto rate is measured from one process's arrival window) and regenerated PCR;
both legs carry the same `--sequence-seed`.

Three further comparisons are made for arm D, because a conflict at the receiver does not say which
stage produced it, and because the oracle cannot grade a pair that is not byte-identical (below).
[`t12-maskcmp.py`](scripts/t12-maskcmp.py) compares the legs datagram by datagram at equal sequence
numbers with the continuity counter masked; [`t12-seqskew.py`](scripts/t12-seqskew.py) measures
differential arrival at equal sequence numbers, without correlating; and
[`t12-placement.py`](scripts/t12-placement.py) strips stuffing and asks where a leg's programme sits
in its partner's output. Between them they separate *the groomer placed different bytes* from *an
earlier stage renumbered the same bytes*.

**Selector policies**, both computed over the same capture:

1. **Seq-merge (ST 2022-7).** Emit the payload for each RTP sequence number from whichever leg
   supplied it; a gap on one leg is covered by the other with no output discontinuity.
2. **Input-select (IRD-style input failover).** Follow one leg, switch after `k` ms of silence.
   Swept at `k` = 50, 100, 250, 500 ms.

**Injections**, each applied to leg A at t+30 s of a 60 s capture window: RTP-path blackout (100 %
loss), path loss at 1 % and 3 %, differential delay (10 / 50 / 200 ms), publisher `SIGKILL`,
publisher `SIGTERM` (the graceful-exit path that terminates a *single* exporter), relay kill,
egress kill, and a 15 s QUIC blackout that is then *cleared* — the one injection a leg is expected
to survive, and the only way to observe a groomer resuming rather than merely stopping. Impairment
is applied per leg through a `prio` + `u32` lane keyed on that leg's UDP
port, the SSH-safe pattern of [T5](test-5-network-impairment.md), with a watchdog that removes the
lane unattended. One further condition is a *start-order* rather than a failure: leg B's egress held
back 20 s, the mid-stream join a restarted leg would perform.

**Metrics.** Alignment yield (fraction of sequence numbers whose payloads are identical on both legs,
after cross-correlating for a constant sequence offset); lost TS packets and gap duration at the
merged output; skew (differential arrival of matching sequence numbers); merged-stream conformance
(TSDuck continuity, PCR interval distribution, `pcrverify` at ±500 ns); switch count and switch time
per `k`. The first and third have a shared dependency worth stating up front: the sequence offset is
recovered by voting on payload identity, and the skew is measured between datagrams paired through
it, so both degrade to noise on a pair whose datagrams differ in *any* field. The oracle reports its
vote share as a confidence, and arm D's join and recovery cells are where that matters.

**Pass criteria (fixed in advance).**

- **Arm C is a gate on the rig, not on MoQ:** 100 % alignment yield, and across every path injection
  0 lost TS packets, 0 continuity errors and no PCR degradation against its own clean control. If arm
  C is not hitless, no other arm's result may be reported.
- **Arms A, B and D** are graded as *feasible* only at 100 % alignment yield. Below that, the
  deliverable is the measured mechanism and the divergence onset, not a partial score.
- **Graceful exit** — with two legs live, a `SIGTERM` to publisher A must produce **zero** lost
  packets at the merged output under seq-merge.
- **Input-select** — bounded and reported, not pass/fail: a break-before-make switch has an artefact
  by definition.
- **Skew** — reported as measured, against the differential-delay window of a named IRD once one is
  chosen for Gate 2. No threshold asserted here.

## Results

42 cells, each a 60 s capture of both legs, graded from the pcaps: [`t12-summary.csv`](results/t12-summary.csv)
(one row per cell) and [`t12-input-select.csv`](results/t12-input-select.csv) (one row per cell per
`k`). Every number below is from those two files, except the datagram comparisons and the
equal-sequence skew, which come from the two scripts named above and are marked where they appear.

### Arm C — one groomer, duplicated: the rig gate passes

The positive control is hitless under every path injection, so receiver-side results from the other
arms can be believed.

| Injection | Yield | Covered by B | Lost TS packets | CC errors | PCR > 40 ms | PCR accuracy fails | Skew \|max\| |
|---|---|---|---|---|---|---|---|
| none (control) | 100 % | 0 | 0 | 0 | 1.386 % | 0 / 2598 | 0.18 ms |
| blackout on A | 100 % | 11 388 | **0** | 0 | 1.504 % | 0 / 2594 | 0.34 ms |
| 1 % loss on A | 100 % | 104 | **0** | 0 | 1.506 % | 0 / 2590 | 0.20 ms |
| 3 % loss on A | 100 % | 331 | **0** | 0 | 1.582 % | 0 / 2593 | 0.19 ms |
| +10 ms on A | 100 % | 3 | **0** | 0 | 1.466 % | 0 / 2593 | 13.13 ms |
| +50 ms on A | 100 % | 20 | **0** | 0 | 1.504 % | 0 / 2595 | 50.06 ms |
| +200 ms on A | 100 % | 76 | **0** | 0 | 1.425 % | 0 / 2598 | 200.02 ms |

A total blackout of one leg costs nothing: leg B supplies 11 388 datagrams, the merged output loses
none, and continuity and PCR are indistinguishable from the clean control. PCR intervals above 40 ms
sit at 1.4–1.6 % in *every* cell including the control, so that is the rig's floor, not switch damage
(see [Corrections](#corrections)); no interval in any arm C cell is negative, i.e. the switch leaves
no PCR discontinuity to absorb. Measured skew tracks injected delay to within 60 µs at 50 and 200 ms; the
10 ms cell reads 13.1 ms, which is `netem`'s timer granularity, not stream behaviour.

The gate's cost is its scope. Arm C grooms once, so its two legs share one publisher, one relay and
one exporter: it protects the **last hop only**, and the upstream injections do not apply because
they take the whole arm down.

### Arm A — no pacer: mergeable, and not presentable

The prediction was that two independently packetised legs would diverge in phase. They do not. With
RTP framing pinned identically on both legs (fixed SSRC, sequence seed, 7-packet bursts) and both
legs started together, alignment is exact in all 12 cells:

| Injection | Offset | Yield | Covered by B | Lost TS packets | CC errors | Skew \|max\| |
|---|---|---|---|---|---|---|
| none ×3 (controls) | 0 | 100.0000 % | 0 | **0** | 0 | 2.9–6.1 ms |
| publisher `SIGKILL` | 0 | 100 % | 5 339 | **0** | 0 | 3.4 ms |
| publisher `SIGTERM` | 0 | 100 % | 5 339 | **0** | 0 | 3.6 ms |
| relay kill | 0 | 100 % | 5 339 | **0** | 0 | 2.7 ms |
| egress kill | 0 | 100 % | 5 339 | **0** | 0 | 3.0 ms |
| blackout on A | 0 | 100 % | 5 339 | **0** | 0 | 3.7 ms |
| 1 % / 3 % loss on A | 0 | 100 % | 27 / 170 | **0** | 0 | 4.4 / 2.8 ms |
| +50 / +200 ms on A | 0 | 100 % | 0 / 21 | **0** | 0 | 52.9 / 202.9 ms |

Every upstream failure at t+30 s stops leg A dead at 5 503 datagrams; leg B covers the remaining
5 339 and the merged output loses **nothing**. This includes the graceful-exit case that single-leg
failover cannot cover at all ([T6](test-6-relay-resilience.md)): a `SIGTERM` to publisher A is
invisible at the receiver. The pass criterion fixed in advance — zero lost packets under seq-merge on
graceful exit — is met.

What fails is conformance, not the merge. The merged stream carries 1 524 PCRs, of which **1 523 fall
outside ±500 ns** of where a constant-rate transport would put them, because the ungroomed egress is
not a constant-rate transport: it is the exporter's VBR packet sequence with no stuffing, so no single
bitrate makes its PCRs accurate. (PCR *intervals* are clean — 0 % above 40 ms — because the interval
is the encoder's own 20 ms grid.) An IRD recovers its clock from those PCRs, which is why
[T7](test-7-timing-integrity.md) requires grooming. Arm A is therefore *mergeable but not
presentable*: it satisfies ST 2022-7 and fails TR 101 290.

It is also fragile in a way arm C is not. The ungroomed leg is bursty — median inter-datagram gap
0 ms, p99 ≈ 60 ms, **max 242 ms** — and that burstiness sets the failure-detection floor discussed
below.

### Arm B — one pacer per leg: detectable, still not mergeable

No cell reaches alignment. Yield is 30–53 %, the recovered sequence offset is unstable
(−1, 0, +1), and 5 622–12 485 sequence numbers carry conflicting payloads:

| Injection | Offset | Yield | Conflicts | CC errors | PCR > 40 ms | Backward PCR |
|---|---|---|---|---|---|---|
| none | −1 | 46.1 % | 12 485 | 0 | 1.582 % | 0 |
| blackout on A | +1 | 52.3 % | 5 622 | 1 | 1.505 % | 0 |
| 1 % loss on A | 0 | 53.4 % | 10 748 | 82 | 1.540 % | 0 |
| 3 % loss on A | −1 | 49.4 % | 11 561 | 240 | 2.210 % | **7** |
| +50 ms on A | 0 | 51.8 % | 11 172 | 1 | 1.507 % | 0 |

Merging an unmergeable pair is worse than not merging it: the 3 % cell produces 240 continuity errors
and seven *backward* PCR steps — a clock discontinuity no IRD will absorb — from two legs that are
individually healthy.

**Why they diverge is not PCR re-stamping.** The standing assumption (and this file's earlier
prediction) was that two groomers would agree on content and differ only in the PCR bytes each
stamped for itself, which a receiver could in principle ignore. Sampling 400 conflicting datagrams
([`t12-conflict-anatomy.py`](scripts/t12-conflict-anatomy.py)) refutes it: **0 %** differ only in the
PCR field, 100 % differ beyond it, only 60.5 % even carry the same PIDs in the same order, and 28.2 %
carry a different number of null packets. The differing bytes cluster at offset 3 (continuity counter
and adaptation-field control), across the PCR field at 6–11, and in the payload at 15, 24 and 187.
Two independent groomers do not produce the same transport with different timestamps; they produce
*different transports*. The divergence is structural — each groomer strips the arriving nulls, decides
its own content/stuffing interleave against its own emit clock, and numbers its own nulls — so it
cannot be patched at the receiver.

**Upstream failure stops the leg.** With stall detection on, a groomer whose content stops arriving
mutes one second later, and every upstream kill produces a leg that visibly dies:

| Injection to leg A | Leg A datagrams | Carrier after last content | Covered by B | Lost | Merged content |
|---|---|---|---|---|---|
| none (control) | 23 175 | 0.61 s (end of run) | 2 | **0** | 48.1 % |
| publisher `SIGKILL` | 13 271 | **0.0 s** | 9 906 | **0** | 51.7 % |
| publisher `SIGTERM` | 13 271 | **0.0 s** | 9 903 | **0** | 51.8 % |
| relay kill | 13 271 | **0.0 s** | 9 903 | **0** | 51.7 % |
| egress kill | 11 781 | **0.0 s** | 11 393 | **0** | 48.1 % |

Leg A stops at 13 271 datagrams instead of running the full 23 175, and the interval between its
last programme packet and its last datagram is zero: the carrier ends with the content rather than
outliving it. Leg B covers the remainder and the merged output loses nothing. Programme content at
the merged output holds at ~52 % of datagrams across the failure — the second half of the window is
leg B's real programme, not leg A's stuffing — against 48 % in the clean control.

That is what makes the leg *detectable*, which is the property input-select needs: every upstream
kill produces exactly **one switch at every threshold** (50, 100, 250, 500 ms), at a cost of 1–3
continuity errors, with the switch taken after ≈ `k` ms of silence.

It does not make the pair *mergeable*. Conflicts stand at 5 978–7 910 and yield at 40–49 % in these
cells: the two groomers emit different transports, and stall detection governs *when* a leg
transmits, not *what* it transmits. Arm B fails the alignment criterion either way.

### Recovery under arm B: a resumed leg does not rejoin the pair

Stopping is only half of a failover. The 15 s QUIC blackout is the condition where leg A is expected
to come back — every process stays alive, and only delivery is interrupted — so it measures the
return path that the kill cells cannot.

Leg A muted and resumed: a **23.0 s** silence, then 1 149 datagrams over the remaining 3.0 s, 496 of
them carrying programme. Detection and recovery both work at the transport level. But the numbering
does not survive the gap ([`t12-resume.py`](scripts/t12-resume.py)):

```
leg a: outage 23049 ms, then 1149 datagrams over 3.0 s
  own sequence advanced   +1 across its own outage
  partner emitted         8757 datagrams in the same window
  numbering deficit       8756 datagrams (resumes misnumbered)
```

Leg A resumes at the next sequence number it would have sent, having sent nothing for 23 s, while
leg B advanced 8 757. The resumed leg is behind by the entire outage and no constant offset
reconciles the pair afterwards — the same failure as a mid-stream join, arrived at from a leg that
was aligned to begin with. The merged output records it as 3 continuity errors and **2 backward PCR
steps**, the only cells in the campaign outside arm B's 3 % loss cell to show a clock discontinuity.

Under arm D the same cell resumes with a numbering deficit of **0**; the mechanism and what remains
are below.

### Arm D — one stream-clocked pacer per leg: two groomers, one transport

This is the arm arm B's failure asked for, and it works. Two groomers that share no process, no
clock and no messages emit the same bytes under the same numbers, because both compute placement
from the stream instead of from themselves. The co-started control is **byte-identical on every
datagram**: 23 175 on each leg, sequence offset 0, 100.00 % alignment yield, 0 conflicts, 0
continuity errors, skew |max| 8.8 ms. Arm B's clean control, from the same topology, was 46.1 %.

That identity survives every injection, including the upstream-chain failures arm C — the positive
control — cannot be subjected to at all, because arm C has only one upstream chain to fail:

| Injection on leg A | A's datagrams | Yield | Identical | Lost | CC | Covered by B | Skew \|max\| |
|---|---:|---:|---:|---:|---:|---:|---:|
| none (control) | 23 175 | 100 % | 100 % | 0 | 0 | 1 | 8.8 ms |
| `SIGKILL` publisher A | 12 334 | 100 % | 100 % | 0 | 0 | 10 841 | 2.4 ms |
| `SIGTERM` publisher A | 12 333 | 100 % | 100 % | 0 | 0 | 10 842 | 3.1 ms |
| kill relay A | 12 334 | 100 % | 100 % | 0 | 0 | 10 840 | 4.0 ms |
| kill exporter A | 11 781 | 100 % | 100 % | 0 | 0 | 11 390 | 10.8 ms |
| total blackout of leg A | 11 788 | 100 % | 100 % | 0 | 0 | 11 387 | 2.4 ms |
| 1 % loss on leg A | 23 045 | 100 % | 100 % | 0 | 0 | 130 | 8.3 ms |
| 3 % loss on leg A | 22 848 | 100 % | 100 % | 0 | 0 | 326 | 2.6 ms |
| 50 ms differential delay | 23 155 | 100 % | 100 % | 0 | 0 | 16 | 46.9 ms |

*Identical* is every datagram the two legs both sent, compared byte for byte
([`t12-maskcmp.py`](scripts/t12-maskcmp.py)); *covered by B* is how many of the merged output's
datagrams came only from leg B. Leg A dies where the injection says it should, leg B covers the
remainder, and the merged output loses nothing and gains no continuity error. A groomed, TR 101
290-conformant pair now protects the whole chain — publisher, relay and exporter — and not just the
last hop. The 50 ms cell also confirms the pair is not merely co-timed: delay one leg by 50 ms and
the bytes still match, because they were never a function of when they were sent.

#### Recovery: the leg comes back into the numbering, and into the programme

The 15 s QUIC blackout, where arm B returned 8 756 datagrams short, resumes exactly
([`t12-resume.py`](scripts/t12-resume.py)):

```
leg a: outage 13650 ms, then 5658 datagrams over 14.9 s
  own sequence advanced   +5186 across its own outage
  partner emitted         5186 datagrams in the same window
  numbering deficit       0 datagrams (rejoins the pair)
  programme after resume  5526 of 5658 datagrams carry content
```

Both halves matter and they were fixed separately. The numbering rejoins because a muted slot still
consumes its place on the grid. The *programme* rejoins because a returning leg reads its source's
forward PCR jump against the time it spent silent: an earlier build treated a jump larger than the
5 s discontinuity threshold as a splice, re-anchored the grid to where its last run had ended, and
placed everything it then received in slots that had already been transmitted. That leg came back
with perfect numbering and **0 of 1 155 datagrams carrying programme** — a failure invisible to every
metric except asking whether the carrier had anything in it.

#### What remains is upstream of the groomer, and most of it is a continuity counter

The recovery cell scores 68.6 % alignment yield and the mid-stream join 0.08 %, which reads like
arm B until the conflicts are opened up. Masking the continuity counter
([`t12-maskcmp.py`](scripts/t12-maskcmp.py)):

| Cell | Identical | Identical bar CC | Skew at equal sequence, median |
|---|---|---|---|
| none (co-started) | 100.00 % | 100.00 % | −1.7 ms |
| relay kill on A | 100.00 % | 100.00 % | 2.6 ms |
| 15 s QUIC blackout, cleared | 68.56 % | **98.22 %** | 3.2 ms |
| leg B joins 20 s late | 0.09 % | **97.10 %** | 10.4 ms |
| leg B joins 20 s late, 500 ms pacer latency | 0.07 % | **97.17 %** | −25.7 ms |

The skew column is measured at equal sequence numbers
([`t12-seqskew.py`](scripts/t12-seqskew.py)), not taken from the oracle, for a reason the last
section of this arm explains.

A leg that joined 20 s after its partner puts the same programme in the same slots under the same
RTP sequence numbers, and 97 % of its datagrams differ from its partner's in one field: byte 3. The
offset is **constant for the whole run** — +2 on the video PID, +8 on PAT and PMT — and it is
produced upstream of the groomer. `moq export ts` reconstructs the transport stream from media
objects and numbers each PID's continuity counter from its own process state, so two exporters that
did not start together are permanently offset, and no groomer downstream can correct it without
rewriting a field it was handed. Each leg is internally continuous — TSDuck reports 0 continuity
errors on either — so this is invisible until the two are compared.

The counter is the largest of three exporter values minted per process rather than derived from the
broadcast, and it accounts for the whole of the gap between the two columns. Filed as
[moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779). It is not the whole of the row: the
2.90 % that survives the mask is the second of the three, and is
[attributed below](#three-values-the-exporter-mints-per-process-and-what-a-groomed-pair-sees-of-each).

#### A leg that joins 20 s late lands in phase, and the tooling said otherwise

The oracle grades the mid-stream join at 0.08 % yield and 12 011 ms of skew, which reads as a leg
sending the right bytes twelve seconds too late — content-aligned and still unusable, since no
2022-7 receiver has that much differential buffer. Both figures are artefacts of the same field.

The oracle recovers the sequence offset between the legs by voting on **payload identity**, and
derives skew by pairing datagrams through that offset. When the continuity counter differs there is
almost nothing to vote with: 15 identical datagrams out of 23 175, confidence 0.188, and the winning
offset of 4 559 datagrams is noise. The 12 s is that offset expressed in time — 4 559 datagrams at
2.6 ms each — rather than a measurement of when anything was sent. Comparing arrival times at
**equal sequence numbers** instead, which needs no correlator
([`t12-seqskew.py`](scripts/t12-seqskew.py)), a leg joining 20 s late sends the same sequence number
a median of **10.4 ms** after its partner, over 23 171 sequence numbers the two legs share. At a
500 ms pacer release latency it is −25.7 ms and at 2 000 ms it is −29.8 ms: pacer buffering shifts
the phase by tens of milliseconds, and nothing in that range approaches a differential-delay budget.

So a stream-clocked leg joining a running broadcast lands in phase as well as in numbering. Its
groomer counters agree that nothing dramatic happened: `start_backlog` ≈ 3.5 s, `resyncs` 0,
`dropped` 3. The whole of its remaining disagreement with its partner is the continuity counter
above.

Two guards were added to the groomer for delivery shapes it *can* fix, and both are unit-tested: a
leg starts at the live edge of whatever the relay hands it rather than at the head of it, and it
moves its clock to the live edge if it ever finds itself holding more than `max_latency` of stream
(`resyncs`). Neither fires in this rig, because the exporter feeds a joining leg at media rate rather
than bursting a backlog at it. They are guards against a delivery shape this rig does not produce.

### Selection policy: seq-merge and input-select are not interchangeable

Both policies were computed over the same captures, so the comparison is exact.

| | Isolated loss on one leg | Total leg loss | Upstream content failure behind a groomer |
|---|---|---|---|
| **Seq-merge** (2022-7) | repaired: 0 lost, 0 CC (arms A, C and D at 1 %/3 %) | hitless: 0 lost | 0 lost, and under arm D the pair stays byte-identical through it |
| **Input-select** | *not* repaired: 27 CC at 1 %, 170 CC at 3 % (arm A, k ≥ 250 ms) | 1 switch, ≈ 4 CC errors, gap ≈ k | 1 switch, 1–3 CC errors, gap ≈ k |

Input-select cannot repair packet loss by construction — it selects a leg, it does not merge — so a
1 % path costs 27 continuity errors that seq-merge removes entirely. On total leg loss it works, at a
bounded price: one switch, a gap of about `k`, and roughly 4 continuity errors.

The third column is only answerable because the groomer mutes. A groomed leg whose content source
has failed is indistinguishable from a healthy one by loss, continuity or PCR — it is a perfect
carrier with no programme in it — so a selector keyed on packet arrival sees nothing to act on. What
converts that into a detectable failure is the groomer declining to transmit, not anything the
receiver can compute.

The viable threshold depends entirely on whether the leg is groomed:

| Arm | Max inter-datagram gap (clean / under 3 % loss) | k = 50 ms | k = 100 ms | k = 250 ms |
|---|---|---|---|---|
| A (ungroomed) | 242 ms / 242 ms | 413–446 spurious switches | 12–20 spurious switches | 0 in control, 1 real |
| B, C, D (groomed CBR) | 3.8–4.3 ms / 8.3–8.4 ms | 0 in control, 1 real | 0 in control, 1 real | 0 in control, 1 real |

An ungroomed MoQ leg needs `k` ≥ 250 ms — anything faster mistakes its natural burstiness for failure
— so failure detection cannot be quicker than ~300 ms. The groomed leg's gaps stay an order of
magnitude below the smallest threshold tested, so `k` = 50 ms is safe and detection is 5× faster. **The pacer is what makes prompt failover
detection possible**, independently of its TR 101 290 role.

One subtlety worth keeping: in the three co-started arm A controls, flapping 413–446 times at
`k` = 50 ms causes **zero** continuity errors, because the legs are packet-identical and
sequence-aligned — switching between identical streams is free. In the mid-stream-join run the same
flapping causes 543. Spurious switching is only harmless while the pair is aligned.

### Start order: what it costs, and what fixes it

Under arms A and B, bringing leg B up 20 s late destroys mergeability outright. Arm A goes from a 0
offset and 100 % yield to an offset of −3 542 datagrams and **0.42 %** yield; arm B, already
unmergeable, degrades further (offset 4 591, 30.1 %). Nothing recovers this at the receiver: the two
legs are numbering the same programme differently and no constant offset reconciles them. Under
those arms a 1+1 pair must be **started together**, and a leg that restarts alone re-enters as an
unaligned stream that only input-select can use.

Their recovery cells show that this is not really a property of start *order*. A leg that was
aligned, muted and came back is misnumbered by its outage exactly as a late-joining leg is
misnumbered by its start delay: one defect, that RTP numbering counts what the groomer sent rather
than where it is in the stream. Arm D removes that defect. A leg that joins 20 s late, or that mutes
and returns, comes back on its partner's numbering, in its partner's slots and within tens of
milliseconds of its partner's timing; what still separates the pair is upstream of the groomer
entirely, and that is below.

### Three values the exporter mints per process, and what a groomed pair sees of each

`moq export ts` renders three things from its own process state rather than from the broadcast. Each
is a separate defect, and grooming does not absorb any of them — it only changes which ones a given
source can expose.

**1. The continuity counter** is a constant per-PID offset between two exporters that did not start
together (+2 video, +8 PSI above). It is masked out of every figure in this section and filed as
[#2779](https://github.com/moq-dev/moq/issues/2779).

**2. The SI cadence was anchored to process start.** `export.rs` decided when to re-emit a table by
measuring forward from its own last emission, so two legs put the tables on different frames.
Measured at the exporter with the groomer removed ([`export-determinism.sh`](scripts/export-determinism.sh),
`CNNiEMEA2.ts`, second subscriber joining 20 s late),
[`ts-table-anchor.py`](scripts/ts-table-anchor.py) tags each emission with the PTS of the frame that
triggered it and reports frames where both legs emitted over frames where either did:

| | PAT/PMT | SDT | NIT |
|---|---|---|---|
| before [#2825](https://github.com/moq-dev/moq/pull/2825) | 95.51 % | **0.00 %** | **0.00 %** |
| with #2825 | 96.36 % | 92.74 % | 95.71 % |

PAT and PMT largely escape it because they are also re-emitted at every video keyframe, a boundary
both legs share; SDT and NIT have no such anchor and, over a 45 s overlap, never once landed on a
common frame.

**This is exactly what the 2.90 % residue in the arm D join cell is**, and it is visible in the
original capture: re-grading it with a PID census ([`t12-maskcmp.py`](scripts/t12-maskcmp.py)) shows
both legs emitting the same tables — PAT 123/123, PMT 123/123, SDT 31/31 — while **31 of the 31 SDT
emissions land on a slot where the other leg has video**, and PAT and PMT disagree on 16 of 123. A
misplaced table displaces everything after it by one packet, which is the 2 561 video packets and
1 351 video/stuffing swaps that make up the rest of the residue. The groomer places by stream
position, so it faithfully carries the displacement rather than hiding it.

**3. The audio/video interleave is a function of arrival timing.** `pick_next_track` takes the
smallest timestamp among tracks that *currently hold* a frame, and a track only holds one once its
own read has returned — so the exporter emits the earliest *available* frame, not the earliest frame.
Two legs with different arrival timing order the same media differently. Comparing raw exporter
outputs packet by packet ([`ts-legcmp.py`](scripts/ts-legcmp.py)) the longest run they share is
**32 packets** even with the counter masked. Filed as
[#2829](https://github.com/moq-dev/moq/issues/2829).

**Consequence for 1+1.** A byte-identical pair needs all three. Grooming is what makes the pair
comparable at all — it rebuilds placement from stream position, so the legs share a slot grid — but
it neither creates nor conceals these differences. Which of them a run exposes depends on the
source: a single-track feed cannot show the interleave, and a feed carrying no standalone SI can
barely show the cadence.

### What the fixes are worth, measured on the pair

The arm D join cell re-run against candidate fixes, on
[`t12-armd-join-local.sh`](scripts/t12-armd-join-local.sh): the same topology reduced to one
publisher and one relay, so the only asymmetry left is when each exporter tuned in, graded by
[`t12-rtpcmp.py`](scripts/t12-rtpcmp.py). Builds are upstream `main` (`6d3c51d7`), #2825 as proposed,
and #2825 with `!=` → `>` in `due` — the one-character change from the review, which stops a
backwards timestamp counting as a new slot. **#2825 merged in the `>` form**, so the last column is
what `main` does today and the middle one is a build that never shipped. Slots identical with the
continuity counter masked, leg B joining 20 s late:

| Source | pre-merge `main` | #2825 as proposed (`!=`) | monotonic `due` (`>`) | stock `main` today |
|---|---|---|---|---|
| video-only 2 Mb/s, 1.8 s GOP | 96.43 % | **100.00 %** | 100.00 % | **100.00 %** |
| video-only 2 Mb/s, 2 s GOP | 100.00 % | 100.00 % | — | — |
| `CNNiEMEA2.ts` — 2 audio, B-frames, SDT + NIT | 87.75 % | 89.72 % | **95.62 %** | **94.09 %** |

The first three columns are hand-built approximations (upstream `6d3c51d7` plus the patch under
review); the last is a stock build of `main` at `eab960192`, which is the one to quote. The
multi-track pair moves between 94 % and 96 % from run to run because what it is now measuring is
the interleave, which is a race; the single-track pair is 100 % every time.

- **On single-track content #2825 closes the pair.** The two legs become byte-identical bar the
  counter, which is what the arm D cell was one defect short of. The 2 s GOP row is not a rule —
  the campaign's own source has a 2 s GOP and scores 97.10 % — it is the reminder that two legs
  coinciding is incidental, so a source that shows nothing proves nothing.
- **On multi-track content it does not**, and the shortfall is not about joining late: with both legs
  co-started the residue is 4.82 %, against 4.38 % for the late joiner. Over 62 073 shared slots the
  tables agree exactly (PAT 111/111, PMT 111/111, SDT 22/22, NIT 5/5) while the legs place different
  numbers of media packets — video +19, the two audio PIDs −72 and −51. That is [#2829](https://github.com/moq-dev/moq/issues/2829).
- **The PSI inflation in the form first proposed reaches the receiver**, which is why it was changed
  before merging. Over the same span it emits PAT
  1 959/1 946 and SDT 818/803 across the two legs, where the monotonic variant emits 111/111 and
  22/22 — so the surplus tables are not only overhead, they land inconsistently and cost 5.9 points
  of agreement.
- **The publisher is not implicated.** Running the same cell with two importers fed by one `tee`,
  the topology the campaign used, gives 100.00 % on the single-track source, unchanged.

### Whether a leg ever drops media the other keeps

A pair graded on field identity is only an upper bound until the legs are known to be carrying the
same media, and the exporter's consumer is free to abandon a group whose data is late. Neither leg
ever did so here. The per-PID census agrees to within one packet over 16 660 shared slots on the
single-track source and 62 418 on the multi-track one; a group is a whole GOP, thousands of
packets, and cannot hide in that. Dropping `--latency-max` from 500 ms to 0 changes nothing — on
loopback no group is ever late, so the budget is never the binding constraint.

More useful is what happens when a leg is made to fall behind. [`ts-stall.py`](scripts/ts-stall.py)
stops one leg consuming for 8 s and then 25 s, which blocks its exporter on the write:

- **A slow leg does not skip a group. It lags, without bound.** The export loop reads a frame and
  then writes it, so a blocked output stops the consumer reading — but the skip test is only
  reached when the current group cannot yield a frame, and a consumer that is merely behind has
  frames in hand. It drains them in order and the delay accumulates. The media the stalled leg
  lost (72 packets at 8 s, 221 at 25 s) was discarded by the groomer's own release ceiling
  downstream, not by the exporter.
- **What bites is relay retention, not the latency budget** — and it does not cause a skip either.
  `--cache-duration` is unbounded unless set; at 5 s, the same 25 s stall ends with the exporter
  exiting on `hang: moq error: old`. For a 1+1 pair that is the better failure, since a leg that
  dies is visible and can be restarted, where one that silently diverges is not.

### Renumbering the counter from the stream, prototyped

The remaining defect ([#2779](https://github.com/moq-dev/moq/issues/2779)) is the continuity
counter, and the fix proposed upstream is to restart it at each video keyframe and pad every PID's
span to a multiple of 16 so the restart stays continuous.
[`ts-keyframe-pad.py`](scripts/ts-keyframe-pad.py) does that between the exporter and the groomer,
which prices it without waiting for it to be built. Same cell, and now graded on **raw** identity
rather than with the counter masked:

| Source | identical, stock `main` | identical, padded | masked ceiling |
|---|---|---|---|
| video-only 2 Mb/s, 1.8 s GOP | 0.37 % | **99.92 %** | 100.00 % |
| `CNNiEMEA2.ts` | 24.61 % | **93.57 %** | 93.79 % |

- **The counter stops being a defect**, on both sources: raw identity arrives within 0.2 points of
  the masked ceiling. What is left below 100 % on the multi-track source is the interleave.
- **The groomer absorbs the filler.** Both groomed legs report zero continuity errors under TSDuck,
  the constant bitrate holds, and the pair still aligns slot for slot.
- **The cost is real and regressive.** 1.72 % of packets on the 4-PID single-track service
  (47 kb/s) and 1.49 % on the 11-PID service (136 kb/s) — but per PID it is 10–18 kb/s almost
  regardless of what that PID carries, because a PID emitting one or two packets per GOP is
  nearly always 14 or 15 short of a multiple of 16. The 10 Mb/s video PID pays 9.6 kb/s, PAT pays
  16.4 kb/s, and each low-rate data PID pays ~18 kb/s, several times its own payload.
- **A joining leg pays a one-off**: it emits a full SI set at tune-in, so for that one span it
  renders 15 filler packets its partner does not (visible as +15 on the NIT PID). It does not
  recur.
- **It is conditional on the interleave.** The counter becomes an index within the span, so
  wherever the legs order media differently the renumbering diverges with it. On multi-track
  content this fix cannot land alone; it needs [#2829](https://github.com/moq-dev/moq/issues/2829).

### Verdict against the pass criteria

| Criterion (fixed in advance) | Result |
|---|---|
| Arm C: 100 % yield, and 0 lost / 0 CC / no PCR degradation across every path injection | **pass** — rig valid |
| Arm A feasible only at 100 % yield | **pass** when co-started (12/12 cells); fails on mid-stream join |
| Arm B feasible only at 100 % yield | **fail** — 30–53 %; mechanism measured and structural |
| Arm D feasible only at 100 % yield | **pass** co-started, including across every upstream-chain failure. A leg that joins or recovers separately reached 97–98 % when the campaign ran, and what blocked 100 % was upstream of the groomer: the continuity counter accounted for all but 2.90 %, the SI cadence for the rest. [#2825](https://github.com/moq-dev/moq/pull/2825) has since merged and the same cell reaches 100 % on a single-track source, with the counter masked |
| Graceful exit: `SIGTERM` to publisher A, 0 lost packets under seq-merge | **pass** (arms A and D). Arm B's merged output also loses nothing, but the pair is not mergeable, so the criterion does not apply to it |
| Input-select: bounded and reported | reported: 1–4 CC errors, gap ≈ `k`, and `k` ≥ 250 ms on ungroomed legs |
| Skew: reported as measured | 0.23 ms clean; injected delay tracked to 60 µs up to 200 ms; a stream-clocked leg joining 20 s late lands a median 10 ms from its partner, and −26 to −30 ms as its release latency is varied |

### What this rig cannot tell you

- **One host, loopback.** There is no path diversity: skew is injected, not natural, and the
  correlated-failure question a real 1+1 deployment asks is out of scope. It also means the two legs
  share a wall clock, which is exactly what arm D's identity claim should not depend on — the two-host
  variant in [planned-experiments.md](planned-experiments.md) is what settles that, and it is waiting
  on a second EC2 in another availability zone.
- **The source is video-only, so a whole class of defect cannot appear.** The interleave
  ([#2829](https://github.com/moq-dev/moq/issues/2829)) needs a second media track to be visible at
  all; on multi-track content it holds an otherwise-fixed pair to 95.6 %. Every 100 % in this file is
  a statement about a single-track feed.
- **The receiver is a reference implementation, not an IRD.** It grades what a conforming 2022-7
  receiver would reconstruct; it does not prove a specific IRD accepts the result. That is Gate 2.
- **The PCR-interval floor is unexplained.** 1.4 % of PCR intervals exceed 40 ms in the clean
  control, where [T7](test-7-timing-integrity.md) measured 0 % at a carrier rate matched to the
  content. This rig runs 4 Mbps of carrier for 1.9 Mbps of content, so the leading hypothesis is
  stuffing landing between PCR-bearing packets at an inflated rate — untested, and a matched-rate
  re-run would settle it. Until then no absolute PCR-interval claim is made here; every PCR result is
  stated against arm C's own control.
- **The oracle cannot grade a pair that is not byte-identical.** Its sequence offset is voted by
  payload identity and its skew is derived from that offset, so a single upstream field differing —
  the continuity counter here — leaves it voting on a handful of datagrams and reporting a spurious
  offset and a spurious skew. Every arm D join and recovery figure quoted above from the oracle
  carries that caveat; the numbers that do not are the mask comparison and the equal-sequence skew,
  neither of which correlates.
- **Arm D's two live-edge guards are unexercised here.** Both are unit-tested in the pacer, and
  neither fires in this rig, because the exporter feeds a joining leg at media rate rather than
  bursting a backlog at it. A delivery path that does burst would exercise them; this one does not.
- **Recovery is measured at two outage lengths, one per arm.** Arm B's 15 s blackout produced a 23 s
  mute, arm D's a 13.6 s mute. How a resumed leg behaves at outages shorter than the pacer's cushion,
  or longer than the QUIC idle timeout that would force a fresh session, is untested.
- **The continuity-counter offset's origin is now confirmed, not inferred.** `Export` holds a
  per-PID counter map seeded empty at process start, so two exporters are offset by however many
  packets the older one emitted first. Read from the source and confirmed upstream on
  [#2779](https://github.com/moq-dev/moq/issues/2779).
- **One run per cell**, 60 s each; only the arm A clean control was repeated (three times, all
  identical at 100 % yield and offset 0). Enough to establish mechanism, not distribution tails.

## Corrections

> Every general method rule this experiment produced is in [method-notes.md](method-notes.md), with
> the rest of the campaign's. What follows is the specific record of what T12 got wrong, kept because
> each item changed a number that had already been written down.

- **Believed:** the exporter's continuity counter was the single remaining obstacle to a
  byte-identical 1+1 pair. **True:** it is one of three values the exporter mints per process,
  alongside the SI cadence and the audio/video interleave. The evidence for the second defect was in
  the arm D capture from the day it was taken — 2.90 % of datagrams still differed after masking the
  counter — but the comparison reported only a percentage, so "what remains is a continuity counter"
  was written over a measurement that said otherwise.
- **Believed:** the groomer concealed the other two defects by rebuilding packet placement from stream
  position. **True:** it concealed neither. Placing by stream position is what makes two legs
  comparable at all, and it carries a displaced table faithfully rather than absorbing it.
- **Believed:** two independent groomers would produce the same transport differing only in
  re-stamped PCR, so a receiver could merge them by ignoring the PCR field. **True:** none of the 400
  sampled conflicts differs only in PCR; 39.5 % do not even agree on PID order and 28.2 % carry a
  different number of nulls. The fix implied by the wrong mechanism would not have worked.
- **Believed:** two independently packetised ungroomed legs would fail alignment on phase, making arm
  A a negative control. **True:** with RTP framing pinned and both legs co-started, arm A aligns
  exactly in all 12 cells; it fails on *conformance* instead.
- **Believed:** a leg carrying no loss and no continuity errors is a healthy leg. **True:** a groomer
  asked only to hold a rate will hold it against a dead source indefinitely — 26 s in the run that
  found this, limited only by the capture — emitting a byte-perfect CBR carrier with zero programme in
  it, and minting the PCR that makes it look conformant. Both selection policies read that as health.
  The content check must also exclude the groomer's own adaptation-only PCR packets, which is what the
  first version of this metric got wrong.
- **Believed:** a groomer that stops when its source dies is enough for a leg to fail over and come
  back. **True:** stopping and rejoining are separate properties. The resumed leg came back 8,756
  datagrams behind its partner because its RTP sequence counts datagrams *sent*, so a silence cost it
  numbers rather than consuming them.
- **Believed:** a stream-clocked leg's alignment problems after an outage were about headroom.
  **True:** doubling the rate to 8 Mb/s changed the join cell by nothing measurable (0.21 % against
  0.08 %), and the real cause was a returning leg reading its own outage as a source splice.
- **Believed:** a payload conflict between two legs means the groomers placed different bytes.
  **True:** in arm D's recovery and join cells 97–98 % of conflicting datagrams differ in one field,
  the continuity counter, minted per process upstream of both groomers.
- **Believed:** a joining stream-clocked leg was sending the right bytes twelve seconds late.
  **True:** there is no twelve seconds. The oracle's sequence offset is voted by payload identity, and
  with the counter differing it had 15 votes out of 23,175 (confidence 0.19). Measured at equal
  sequence numbers the joining leg is a median 10 ms from its partner. Two hypotheses, two groomer
  changes and three runs were spent on an artefact whose confidence figure was on the screen
  throughout.
- **Believed:** the merged output should be graded over the window where both legs are live. **True:**
  that truncates the analysis at the blackout it is meant to measure, scoring a covered outage as no
  outage.
- **A metric that conflates two faults hides both.** Counting PCR intervals above 100 ms together with
  negative intervals reported "16 jumps" in arm C's clean control, implying switch damage where there
  was none; split apart, arm C has zero backward steps anywhere and arm B's 3 % cell has seven.
- **Two rig faults produced phantom results.** A 2.0 Mb/s egress target for a 1.9 Mb/s feed leaves the
  groomer no stuffing headroom and it drops content (4,011 packets, 11 continuity errors) — which is
  why this rig runs 4 Mb/s. And the receiver's arrival-ordered selector sorted whole
  `(time, leg, payload)` tuples, so microsecond-tied datagrams were ordered by payload bytes and one
  leg's own packets were scrambled into 207 phantom continuity errors.

## References

- Full result tables: [`results/t12-summary.csv`](results/t12-summary.csv),
  [`results/t12-input-select.csv`](results/t12-input-select.csv).
- Remaining conditions (independent restart of one leg, two-host): [planned-experiments.md](planned-experiments.md).
- The exporter's continuity counters: [moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779).
- Redundancy model: [`docs/architecture.md`](../docs/architecture.md) §8.4–§6; [`docs/architecture.md`](../docs/architecture.md) §5 (ST 2022-7 §5.1).
- Single-leg failover and the determinism precondition: [T6](test-6-relay-resilience.md).
- Grooming and TR 101 290 P1: [T7](test-7-timing-integrity.md).
