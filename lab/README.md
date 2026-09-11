# Laboratory notebook — MoQ ⇄ MPEG-TS validation campaign

This directory is the **engineering laboratory notebook** for the MoQ MPEG-TS primary-distribution
evaluation. It is both the campaign **plan** (the objective, the gate mapping, and the pass criteria
agreed *before* the numbers were known) and the campaign **record** (what was actually done and
measured — objectives, environments, exact procedures, results, observations and conclusions) so that
an external engineer can follow the experiments and reproduce them. It is the executable companion to
[evidence](../docs/evidence.md) §1.2 (the validation pyramid and the acceptance gates).

It is deliberately distinct from the rest of the repository:

- **`lab/` (here) — "this is what we measured," plus the plan behind it.** The engineering record:
  objectives, environments, exact procedures, measured numbers and conclusions, together with the
  pass criteria fixed in advance. Where a result was later corrected, the per-test file states the
  current finding and records that the earlier reading was wrong and why — the correction is kept,
  the blow-by-blow is not.
- **`docs/` — "this is what we've learned."** The paper. [`docs/evidence.md`](../docs/evidence.md)
  is the results document — organised by *question*, not by experiment, with the limits of the
  evidence stated in one place; the other documents are the requirement, the comparison, the
  architecture and the economics. Where an observation here has become a permanent finding, this
  notebook cross-references `docs/evidence.md` rather than restating it.
- **[`method-notes.md`](method-notes.md)** — every measurement rule this campaign learned by getting
  something wrong, organised by theme rather than by experiment, because several of them bit more
  than once in different rigs. Per-test files point here rather than repeating them.
- **[`upstream-contributions.md`](upstream-contributions.md)** — what was found, reported and
  verified in other people's projects: defects and the fixes graded against before-and-after builds,
  test coverage and fixtures contributed, a review of the MSFTS carriage *specification*, and the
  requirements this campaign filed early and then withdrew on its own measurements. Kept separate
  because it is a contribution record rather than a measurement record, and it is a different argument
  from the one the paper makes.

> **On honesty.** The plan below is written to be *disproven*. Its value is the method and the pass
> criteria, fixed before the numbers are known; the numbers themselves — including results that
> reached the wrong conclusion at the time and were later corrected — are recorded in the per-test
> files, not pre-filled into the plan.

> Machine-specific reproduction detail (relay addresses, the EC2 host IP, absolute paths, TLS
> fingerprints, build locations, credentials) is **not** in this public notebook — it lives in the
> git-ignored `INSTRUCTIONS.local.md`. Public commands here use placeholders such as `<EC2_IP>`
> and `<subscriber-home-ip>`. Everything else, including every rig script, is committed.

## Objective

Validate whether MPEG-TS transported via MoQ can meet professional broadcast distribution
requirements — specifically, whether a groomed MoQ egress is **bit-transparent** to the transport
stream, **timing-conformant** to TR 101 290 P1/P2 on real hardware, and **resilient** under realistic
network impairment and infrastructure failure.

The thesis fails if any of the following holds and cannot be remedied:

- MoQ carriage is *not* bit-transparent (continuity errors, dropped signalling, or structural
  corruption survive a lossless path).
- Groomed egress cannot pass **TR 101 290 P1/P2 on a hardware IRD** (the make-or-break gate —
  [evidence](../docs/evidence.md) §1.2, Gate 2).
- Impairment or failure behaviour is qualitatively worse than the incumbent IP transports
  (SRT/Zixi/RIST) it would replace, at matched conditions.

This campaign does not attempt to prove economic superiority; that is a separate, route-specific
exercise ([economics](../docs/economics.md)). Its desk working — where the measured capacity
constants meet public list prices — is kept here as an analysis rather than an experiment
([cost-model.md](cost-model.md)).

**Ordering.** Run cheap-and-decisive first: T1 (reference) → T2 (media-aware fidelity) → T3 (opaque
fidelity, Gate 1) → T7 file-based, then T7 hardware (Gate 2, make-or-break) → T4/T5/T6 (real path,
impairment, resilience — Gate 3). If Gate 2 fails, stop and fix grooming before investing in scale
work — a resilient path that a hardware IRD rejects is not a product.

## Experiments

Each experiment is its own file, structured as Objective / Environment / Procedure / Results /
Observations / Conclusion / References. The pyramid tier and acceptance gate are from
[evidence](../docs/evidence.md) §1.2.

**The per-experiment file is authoritative for that experiment's measurements, scope and
qualifications.** The *Current finding* column below is an index entry, not a summary of the
evidence: one line, no qualifications, and no number that is not stated with its conditions in the
file it points at.

| # | Experiment | Pyramid rung | Gate | State | Current finding | File |
|---|---|---|---|---|---|---|
| T1 | Baseline TS characterisation (P0 reference) | reference for 1, 3 | precondition for Gate 1 | complete | The four-clip source set is clean and representative, so downstream deltas are honest | [test-1-baseline-ts.md](test-1-baseline-ts.md) |
| T2 | Transport transparency — media-aware lane (local) | 1, 2, 3 | Gate 1 (reference lane) | complete | Every elementary stream and the DVB service layer round-trip; the lane's own PCR cadence does not | [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md) |
| T3 | Transport transparency — opaque `m2ts` lane (local) | 1, 2, 3 | **Gate 1 (product lane)** | complete | Byte-transparent at P1 on one run, and the reference the other lanes are read against | [test-3-opaque-transparency.md](test-3-opaque-transparency.md) |
| T4 | Remote relay end-to-end + SRT contribution (public internet) | 2 (E2E over real path) | supports Gate 1 & 3 | complete (media-aware) | Three data planes graded over one internet path by one instrument; the service layer survives it | [test-4-remote-e2e-srt.md](test-4-remote-e2e-srt.md) |
| T5 | Network impairment (both lanes) | 2 (E2E under loss/jitter) | supports Gate 1 & 3 | complete | Loss behaviour is the congestion controller's, not the lane's; its reordering cell is superseded by T20 | [test-5-network-impairment.md](test-5-network-impairment.md) |
| T6 | Relay resilience & active/active source failover | 6 (redundancy drill) | Gate 3 — resilience | partial | Relay failover is bounded by the QUIC idle timeout and is not hitless; a graceful source exit is not failed over at all | [test-6-relay-resilience.md](test-6-relay-resilience.md) |
| T7 | Timing integrity (TR 101 290) | 3 (file), 4 (**hardware**) | **Gate 2 — make-or-break** | P1 complete; P2 open | The re-stamp arithmetic is right on file, which is necessary and not sufficient | [test-7-timing-integrity.md](test-7-timing-integrity.md) |
| T8 | SRT vs MoQ comparative benchmark | 7 (comparative lab) | feeds [economics](../docs/economics.md) §4, §9 | partial | At a matched congestion controller MoQ and SRT are on par through 10 % loss | [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) |
| T8b | Congestion control for a permanent fixed-rate trunk | 7 (comparative lab) | extends T8 | complete — C1–C6, 68 cells and a 14.006 h soak | **No controller recommendation is supportable**: three conditions rank them three ways. What governs the feed is the provisioning margin, the bottleneck queue discipline and the receiver's latency budget. MoQ thins where SRT damages | [test-8b-congestion-control.md](test-8b-congestion-control.md) |
| T9 | System performance & resource utilisation | 5 (scale/soak) | feeds [architecture](../docs/architecture.md) §9, [economics](../docs/economics.md) §3.1, §4, §9 | partial | Publisher and subscriber pass; relay growth is root-caused to `quinn-proto` and convergent, at about twice the slot arithmetic. Its N = 55 knee was the test box (T26) | [test-9-performance.md](test-9-performance.md) |
| T11 | Cross-implementation interop | 7 (comparative lab) | transport neutrality | T11a partial; T11b open | Media flows within one implementation and through none of eight others, with at least four distinct causes | [test-11-interop.md](test-11-interop.md) |
| T12 | End-to-end 1+1 dual-path delivery and hand-off | 6 (redundancy drill) | Gate 3 — resilience; de-risks Gate 2 | complete for a co-started pair, arms A–D; independent restart blocked upstream | Two stream-clocked groomers are byte-identical and hitless with no shared component at all — **on single-track content**. A multi-track mux over independent chains does not merge at the byte | [test-12-dual-path-handoff.md](test-12-dual-path-handoff.md) |
| T13 | Off-the-shelf CBR/PCR grooming of an MPEG-TS egress | 4 (file), plus wire cadence | supports Gate 2; decides how the grooming requirement can be documented | complete for TSDuck, FFmpeg, GStreamer and `rawsendmpeg2ts` on both data planes | **The answer depends on the lane**: off-the-shelf `tsp -P pcradjust -P regulate` grooms a segmented egress to all four criteria with the mux intact; behind a MoQ egress nothing off the shelf passes, and the missing half is carriage | [test-13-downstream-grooming.md](test-13-downstream-grooming.md) |
| T14 | MoQ against segmented HTTP on one route | 7 (comparative lab) | Gate 1 + Gate 2, both data planes; feeds [comparison](../docs/comparison.md) | partial — burst granularity, carriage fidelity and wire cost measured | Segmented HTTP is verbatim in payload for a single programme and ~240× coarser at the hand-off. Hardware P1/P2 and MPTS-through-CDN are blocked on kit this lab does not have | [test-14-data-plane-comparison.md](test-14-data-plane-comparison.md) |
| T15 | RIST and SRT on T14's cadence instrument, and what each transport does to the clock | 7 (comparative lab) | extends T14; grades [comparison](../docs/comparison.md) §10.1 | complete on a healthy path | RIST and SRT are *transparent* — identical to a no-transport control — so their egress is their source's, where MoQ sets its own granularity. The media-aware lane delivers TDT ~14 s late on the exporter's own grid | [test-15-point-to-point-cadence.md](test-15-point-to-point-cadence.md) |
| T16 | Grooming a segmented-HTTP egress | 4 (file), plus wire cadence | supports Gate 2 on the alternative data plane | complete on a healthy path | The same groomer, no flag changed, takes a segmented egress to the MoQ lane's conformance with nothing dropped. The operative variable is cushion depth, not the stall timeout | [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md) |
| T17 | Standalone SI on snapshot tracks: EIT carriage and its join cost | 2/3 (carriage fidelity) | closes the EIT residual in [evidence](../docs/evidence.md) §3.1 | complete, and the design it graded is merged | Neither plane loses an EPG — the media-aware one by reconstructing the table, the segmented one by never parsing it. Carriage is bitrate-neutral and the join costs 1 ms | [test-17-si-snapshot-tracks.md](test-17-si-snapshot-tracks.md) |
| T18 | Delivery latency at equal conformance, on four data planes | 1 (latency) + supports Gate 2 | closes the campaign's last unmeasured axis | complete on loopback and over the public internet | **It refuted the premise it was designed to test**: latency and PCR conformance are independent on the media-aware lane. MoQ crosses the internet in 109 ms against SRT's 1,618 ms and segmented HTTP's 4,067 ms — at cushions that are *not* P1-conformant on any lane | [test-18-delivery-latency.md](test-18-delivery-latency.md) |
| T19 | The PCR grid, and reconstructing a CBR wire from a media-aware source | supports Gate 2 (conformance) | grades the three upstream PCR fixes and the downstream reconstruction they left to be done | complete; criteria 1–3 met, criterion 4 not | **The lane passes on the wire** — 0 of 20,193 PCR intervals above 40 ms over 300 s, 0 continuity errors, exact CBR — after three upstream PCR fixes, none of them sufficient, and three defects in our own groomer. **It fails its own pre-registered latency criterion**: the conformant configuration runs at 2,447 ms median delivery latency. The cost is a buffer sized by the peak coded frame, not by the bitrate | [test-19-pcr-grid-verification.md](test-19-pcr-grid-verification.md) |
| T20 | The segmented lane over HTTP/3, and what that does to the reordering result | Gate 1 (data plane), substrate-matching | closes P0-2 | complete | **A correction**: T5's reordering separation was a packet-size artefact, and on a shared substrate the lanes overlap. The substrate change is a trade — it costs the segmented lane reordering and wins it loss and outage recovery. Its H3 receiver re-muxes, so continuity and PCR there grade the receiver | [test-20-segmented-http3.md](test-20-segmented-http3.md) |
| T21 | The permanence soak of the complete media-aware lane, groomer included | Gate 2 (conformance) over time | the first long run to put the groomer inside the measurement | complete — 24.01 h, and the verdict splits | **The media plane passes without qualification**: 632,199,204 packets, 0 continuity errors, 0 intervals above 40 ms, 0 underruns, exact CBR, and the 33-bit rollover crossed in flight for nothing. **The resource criterion fails in one role** — `moq import ts` grows linearly at +2.83 MB/h with no drawdown. Permanence is blocked by one upstream component, not by the architecture | [test-21-permanence-soak.md](test-21-permanence-soak.md) |
| T22 | Silent media-plane failure: the feed stops, the transport does not | R8 (observability) | closes P0-4 for the MoQ lane | complete, six arms including a control | **The transport never detects a stalled source** — 120 s frozen, not one log line anywhere. The media plane detects it in about one cushion. Its own recommendation of PCR progression as the detector is superseded by T24 | [test-22-silent-media-plane-failure.md](test-22-silent-media-plane-failure.md) |
| T23 | Which PCR timeline events the lane survives, by class | Gate 2 (conformance) across the events a permanent feed cannot avoid | grades the discontinuity as a controlled variable | complete, and re-graded against both fixes it prompted | The **33-bit rollover is carried correctly end to end and always was**. Since [#3375](https://github.com/moq-dev/moq/pull/3375), which these measurements prompted, every *placed* class sits at the control's content gap; since [#3529](https://github.com/moq-dev/moq/pull/3529) the forward arm is flagged too, and the starvation this file had booked against our groomer proves to have been the exporter's. Before the fixes a rewind cost its own duration in programme with the wire showing nothing — the durable finding | [test-23-pcr-discontinuity-classes.md](test-23-pcr-discontinuity-classes.md) |
| T24 | A partial media-plane stall: half the programme stops and every check stays green | R8 (observability) | closes the partial-stall half of F3; **corrects T22's primary recommendation** | complete, four arms including a control | **The lane contains the failure** — with the video dead for a minute every other stream ran uninterrupted, which retires the objection that one dead track blocks the rest. **But a partial stall is invisible to the whole of TR 101 290 P1**, and the two detectors that do fire are blind to a small stream. Only per-PID access-unit liveness caught every arm | [test-24-partial-media-plane-stall.md](test-24-partial-media-plane-stall.md) |
| T25 | Isolation under abuse: can one receiver degrade the others? | R2/R7 — the multi-tenancy exposure [comparison](../docs/comparison.md) §2 asserts and had never tested | tests a claim the paper was making unsupported | complete, five arms plus a control | **The media plane is isolated**; what abuse costs is the relay's memory, and four further arms attribute it to **abandoned-session retention** — not the group cache, not concurrency. It scales with the idle timeout, which is both mechanism and mitigation, so this is an operational property with a knob rather than a defect | [test-25-isolation-under-abuse.md](test-25-isolation-under-abuse.md) |
| T26 | Cross-host fan-out: the scaling model, and whose limit the knee is | R2 — fan-out at near-zero marginal cost | retires the caveat on every fan-out figure in the paper: all of them had the subscribers co-resident with the relay | complete, three arms | **The relay's marginal cost is small, constant and linear, and relay CPU binds first — at the point the model predicts**, confirmed by pinning the relay to one core. Saturation *collapses* rather than degrades, so a relay needs headroom and admission control. Two AZs in one region, so this bounds relay capacity and says nothing about internet-scale fan-out | [test-26-cross-host-fanout.md](test-26-cross-host-fanout.md) |
| T27 | The per-PID liveness detector: built, made to work in a real lane, and what it found | R8 (observability) — turns T24's recommendation into a running detector | proves the *only sufficient* detector survives the distribution path | complete, seven arms plus fault injection against the detector itself | The detector measures the same suppression **live at a cross-host groomed output** as T24 measured offline, so the fine structure it needs survives a relay, the exporter's PCR regeneration and a CBR groomer. It catches the audio case, which has no other wire-observable signature. **Its first live run found a real fault**, bisected to the #3375 merge — the rewind fix this campaign's own T23 prompted | [test-27-liveness-detector.md](test-27-liveness-detector.md) |

### Pass criteria (agreed in advance)

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Criterion met if the source set is clean
  (0 CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1. Full broadcast transparency (incl. the service layer) is proven on the opaque lane (T3); on this
  lane the service layer is now carried in full, EIT and the wall clock included. What remains is
  *when* the clock is emitted rather than whether
  ([T15](test-15-point-to-point-cadence.md) measurement 4).
- **T3 — Opaque transparency (Gate 1).** Bit-transparency at P1 — TSID/ONID, service name/type, all
  PSI/SI (PAT/PMT/SDT/NIT/TDT/CAT), PMT PID, PCR PID, every elementary stream and every SCTE-35 PID
  preserved verbatim; 0 CC/transport errors; CBR and PCR conformance (0 % > 40 ms) preserved when fed
  the raw source.
- **T4 — Remote E2E + SRT.** Relay reachable over the internet; live SRT contribution chain completes
  end-to-end with 0 CC.
- **T5 — Network impairment.** Loss behaviour is *graceful and bounded* (proportionate throughput
  reduction, recovery observed), not catastrophic; where loss exceeds recovery capacity within the
  buffer, the redundancy path (T6 / ST 2022-7) is the mitigation, not the transport alone.
- **T6 — Serving-node resilience (Gate 3).** ST 2022-7 dual-path drill is **hitless** at the IRD under
  single-path loss (the two egress legs byte-identical and sequence-aligned); relay-failover recovery
  is bounded and documented, re-establishing without operator intervention; subscriber-reconnect join
  latency is bounded with defined catch-up behaviour. T6 met the second and third of those and
  characterised the determinism *precondition* for the first offline; **[T12](test-12-dual-path-handoff.md)
  then met the first at a receiver** — 0 lost packets under blackout, 1 %/3 % loss and up to 200 ms
  differential delay — for a pair the receiver can merge, which now includes two independently
  groomed chains provided each groomer is stream-clocked, and with it protection of the publisher,
  relay and exporter rather than the last hop alone. The segmented arm answers the same three
  questions oppositely: a pair sharing one feed and one naming scheme is hitless with **no**
  receiver-side merge, and a dead origin costs no content — but a misconfigured pair is accepted
  silently and delivers time-travel that passes every continuity check.
- **T7 — Timing integrity (Gate 2, make-or-break).** A clean **TR 101 290 P1/P2 pass on a real
  hardware IRD, on the live wire (P2), sustained** (≥ 72 h, set by the PCR base's 26.51 h wrap period
  rather than chosen), including ST 2022-7 behaviour
  under loss, with the T-STD buffer model confirmed valid under drift/discontinuity. Until this
  exists, the grooming design is "structurally sound and software-validated," not "proven
  broadcast-acceptable."
- **T8 — SRT vs MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer delivery latency
  is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery and
  delivered-rate curves are within a stated margin and the failure mode is no worse; egress quality at
  least matches (P1); overhead/CPU recorded as economic inputs. Feeds [economics](../docs/economics.md) §4 and §9.
  **The latency criterion is met at a matched buffer** — [T18](test-18-delivery-latency.md) measures
  MoQ at 109 ms against SRT's 1,618 ms over the same internet path — but at cushions where neither
  arm is P1-conformant, and the configuration that makes the MoQ lane conformant runs at 2,447 ms
  ([T19](test-19-pcr-grid-verification.md)). The P1 criterion is met in software and not on hardware.

T8b, T9, T11, T13, T16 and T18 were specified after this list was fixed; their pass criteria are stated
the same way, in advance, at the top of their own files.

### Desk analyses

Work that produces numbers without touching the rig. Kept separate from the experiment table
because there is nothing to reproduce on a host and no acceptance gate to map onto — but it is
still working, with inputs, arithmetic and limitations recorded the same way.

| Analysis | Purpose | State | File |
|---|---|---|---|
| Always-on cost model (v1) | Price the T9/T8 capacity constants at public list rates: MoQ vs SRT vs MediaConnect vs Cloudflare vs DIY, 1 channel and a transponder's worth, 1+1 | complete, list prices only | [cost-model.md](cost-model.md), rerun with `python3 lab/cost-model.py` |

Unlike the rig work, this one is reproducible by anyone with Python: every rate is a constant at the
top of the script, so re-pricing against a different tariff or a negotiated rate is a one-line edit.

## Roadmap — specified but not yet run

**Every specified experiment has its own per-test file, whether or not it has run.** An unrun file
carries the objective, environment, procedure, metrics and pass criteria fixed in advance, and says
so in a `State:` line at its head. [planned-experiments.md](planned-experiments.md) is the register
of what is outstanding — a line per item, ranked P0/P1/P2 by what a result could change, pointing
here for the protocol. It holds no protocols and no findings of its own.

**The programme has two strands.** The original asks which of two data planes can be run
permanently, at scale, by an operations team, for years. The second scores against
[control-plane.md](../docs/control-plane.md), which has no evidence behind it at all.

Runnable now — no hardware, no live source, no third party:

| # | Test | Purpose |
|---|---|---|
| [T36](test-36-entitlement-enforcement.md) | Entitlement enforcement | What the relay refuses, and whether anything is delivered before it refuses |
| [T37](test-37-entitlement-revocation.md) | Provisioning and de-provisioning | What actually stops a feed, the bound on how fast, and what that bound costs |
| [T38](test-38-entitlement-estate.md) | The affiliate estate | Many channels, many affiliates, a licensing matrix with holes, and what entitlement costs the scaling model |
| [T33](test-33-gate2-preparation.md) | Gate 2 preparation | Boundary fixtures and the acceptance harness, dry-run before the hardware arrives |
| [T28](test-28-failure-injection-matrix.md) | Failure injection and recovery | The matrix, both planes, scored in media lost rather than in recovery time |
| [T29](test-29-moq-distributed-resilience.md) | MoQ distributed resilience | Multi-relay, multi-publisher and receiver-side selection, above the egress 1+1 pair |
| [T30](test-30-segmented-distributed-resilience.md) | Segmented distributed resilience | Two-host segment store, edge and origin failure, and the silent-misconfiguration class |
| [T31](test-31-congestion-capacity-ladders.md) | Congestion and capacity | The step ladders on both planes, extending T8b |
| [T32](test-32-observability-survey.md) | Observability | Whether commercial monitoring would have caught the silent failures T22, T24 and T27 found |

Blocked, and on what:

| # | Test | Purpose | Blocked on |
|---|---|---|---|
| [T7](test-7-timing-integrity.md)/P2 | Hardware TR 101 290 P1/P2 soak | The make-or-break gate on a real IRD, on the live wire, sustained (≥ 72 h — the PCR base wraps at 26.51 h) incl. ST 2022-7 under loss | IRD + analyser loan — **Gate 2** |
| [T34](test-34-real-encoder-severity.md) | A real encoder against the continuous-source fence | Whether a never-repeating source triggers the per-track backwards-step fence in practice, and how severely | a live TS source |
| [T10](test-10-mpts-multiservice.md) | MPTS / multiple concurrent services | Per-service PSI/SI, PCR and continuity at egress, and relay fan-out under N services | partly a media-aware packaging edge |
| [T14](test-14-data-plane-comparison.md) (remainder) | The blocked comparison cells | A commercial ABR-to-TS gateway on P1/P2, which also gates the segmented plane's low-latency arm; and MPTS through a real CDN | hardware; a CDN account |
| [T12](test-12-dual-path-handoff.md)/E | Restart one leg of a live pair | Byte-identity on independent restart, and a grader that can score a pair that is not byte-identical | [#2779](https://github.com/moq-dev/moq/issues/2779) |
| [T35](test-35-leo-handover-impairment.md) | LEO / Starlink handover | Periodic handover gaps; continuity and redundancy behaviour. A candidate, not yet committed | — |
| T3/T4+ | Opaque lane over the wire | Deploy the opaque publisher on EC2 to run opaque transparency over a real path (T3/T4 are currently localhost/file-fed on the opaque lane) | supports Gate 1 & 3 |

## Cross-cutting limitations (stated up front)

- **No hardware IRD pass yet.** Gate 2 (T7/P2) is the load-bearing open test. Everything above it is
  necessary but not sufficient, and nothing in this campaign has ever been fed to a hardware decoder
  or graded by a hardware analyser.
- **Latency is measured, but it is *delivery* latency and both paths were healthy.**
  [T18](test-18-delivery-latency.md) grades every plane's source-to-groomed-egress latency against the
  conformance of the same bytes, on loopback and from EC2 over the public internet. It does not include
  encoder or decoder delay, so there is still no camera-to-display figure — and neither path was impaired
  or long, so nothing exercised the recovery the point-to-point tunnels exist for, which is the case that
  should favour them.
- **On the media-aware lane, conformance and latency are independent axes but not free of each
  other.** The lane's P1 repetition failure was not bought out of latency
  ([T18](test-18-delivery-latency.md): the figure does not move across an eightfold cushion ladder,
  nor when groomer starvation is removed) — but the configuration that finally clears the gate does
  carry a cost, and it is a buffer sized by the peak coded frame rather than by the bitrate.
  [T19](test-19-pcr-grid-verification.md) measurement 11 reaches 0 of 20,193 intervals above 40 ms
  over 300 s at **2,447 ms** of median delivery latency, against the 109 ms the lane delivers at a
  cushion that is not conformant. **Any latency figure for this lane must be quoted with the
  conformance of the same bytes.** What was *not* the cause, contrary to three readings of it in
  sequence, was buffer depth, groomer starvation, or the exporter's PCR cadence: all three exporter
  PCR domains are fixed upstream and the wire still failed. What cleared it was the groomer reserving
  the output slot for the PCR instead of taking only slots the content scheduler declined.
- **Conformance is established over a day, and only for the media plane.**
  [T21](test-21-permanence-soak.md)'s 24.01 h soak extends T19's 300 s result with 0 continuity errors
  and 0 intervals above 40 ms throughout, but its resource criterion fails in one role, and it ran on a
  synthetic continuous source because this lab has no live feed.
- **The alternative data plane is only partly measured.** [comparison](../docs/comparison.md)
  grades MoQ against segmented HTTP carrying MPEG-TS. [T14](test-14-data-plane-comparison.md) has
  measured three of its rows — burst granularity, carriage fidelity and wire cost — and moved all three;
  [T16](test-16-grooming-segmented-http.md) added the grooming row and [T20](test-20-segmented-http3.md)
  the substrate-matched impairment cells. The rest are still specification text or vendor datasheets, and
  the vendor claims in particular should be read as such: no ABR-to-TS product has been graded on the
  Gate 2 rig. The comparison is also single-route, single-clip, and its per-packet framing is derived
  rather than measured. Its low-latency arm has run and split: publishing MPEG-TS partial segments is
  free and works, while no free client fetches them, so that arm's *receive* half is untested for want
  of any implementation. Everything outside T20's impairment cells is still HTTP/1.1 over TCP, and
  T20's own H3 receiver re-muxes, so continuity and PCR on that arm grade the receiver rather than the
  wire.
- **No live contribution source in the *opaque* transparency run yet.** T2/T3 are localhost,
  file-fed; T4 has run a live SRT contribution source end-to-end on the media-aware lane, but the
  opaque lane over the wire awaits deploying the opaque publisher on EC2.
- **No production relay cluster.** T6 is a two-relay lab, not a federated mesh
  ([architecture](../docs/architecture.md) §8.3).
- **The 1+1 measurement is a software receiver.** [T12](test-12-dual-path-handoff.md) runs two
  concurrently live legs into a receiver that selects between them, which is the form a head-end
  expects at a hand-off — but the receiver is a reference implementation of the selection rules rather
  than a hardware IRD's merge engine. The merge matrix has both legs on one host, so its skew is
  injected rather than natural. Path diversity above the egress is no longer untested: with a
  publisher, relay, exporter and groomer per host across two availability zones, sharing nothing but
  the source file, single-track content stays byte-identical with zero residue. **A seven-stream mux
  over the same topology reaches 75.56 %**, the residue being the same packets in a different order
  rather than damage, for a reason located upstream.
- **`netem` is an emulator.** T5/T8 complement but do not replace the real public-internet EC2 path.
- **Draft-14 pin.** The opaque lane and T3 are against a pinned, now-behind draft (`moq-transport`
  0.14.2); migration to later drafts is a tracked dependency and its own re-test
  ([architecture](../docs/architecture.md) §10).
- **Reproducibility.** The opaque publisher/subscriber/groomer are private
  ([comparison](../docs/comparison.md) §11); the T2 media-aware lane is fully reproducible today
  with public `moq-dev` binaries + TSDuck, and its downstream CBR/PCR groom with the public
  [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) crate. Reproducing the opaque,
  IRD-grade egress independently still requires the opaque grooming logic or an equivalent.
- **Large artefacts are not committed.** Captures, pcaps and analyser exports are the evidence of
  record but are kept out of this repository; the notebook records their identity and method, not the
  binaries ([Contributing](../CONTRIBUTING.md)).

## Shared test environment and conventions

### Reference topology

```
Source TS (file or live SRT/RTP)
   → Publisher (media-aware `moq import ts`  OR  opaque `moq_publisher`)
   → [impairment node: tc/netem]
   → MoQ relay (localhost or AWS EC2)
   → Subscriber + groomer (`moq export ts` + `mpegts-pacer`  OR  opaque `moq_subscriber`)
   → RTP/UDP (multicast, ST 2022-7) → hardware IRD + TR 101 290 analyser
   → (egress + source captured to TSDuck)
```

### Measurement points

- **P0 — Source.** Input TS before the publisher; establishes the reference (T1).
- **P1 — Egress (file).** Subscriber's groomed output captured to file, analysed with TSDuck.
  Cheap; catches gross faults; **not** sufficient for hardware acceptance (file PCR accuracy is
  arithmetic, not wire timing).
- **P2 — Egress (live wire).** Physical output as seen by a hardware IRD / TR 101 290 analyser.
  The only point that decides PCR_accuracy (±500 ns) and TR 101 290 P1/P2 (T7).

### Tooling

| Purpose | Tool |
|---|---|
| TS structural / conformance analysis | **TSDuck** 3.44-4676 (`tsp`, `pcrverify`, `pcrextract`, `analyze`, `continuity`, `pat`/`pmt`/`sdt`) |
| Real-time source pacing | TSDuck `regulate` (PCR-based; `--pcr-synchronous` for looped files) |
| Media-aware lane | `moq-dev` `moq` (import/export) + `moq-relay` (public reference impl; moq-lite / moq-transport) |
| Opaque `m2ts` lane | private `moq_publisher` / `moq_relay` / `moq_subscriber` (draft-14 / MSFTS `m2ts`) |
| CBR/PCR grooming | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0 (`cargo install --git`; the `cbr_file` example for the file arms). The live egress adapter was the `moq_egress` example, renamed `ts_egress` at [T16](test-16-grooming-segmented-http.md) and now the crate's `mpegts-pacer` binary; records name whichever they were run against, and the rigs accept all three. |
| Network impairment | Linux `tc` / `netem` (optionally `tbf`/`htb` for rate); shaped-bottleneck rigs (`t8b-netns.sh`, `t8b-shaper.sh`, `t8b-rtt-probe.sh`) are kept local — see `INSTRUCTIONS.local.md` |
| Hardware conformance | Hardware IRD + TR 101 290 analyser (P2; access-dependent) |

### Recurring reproduction commands (P1 analysis)

```bash
# structure / services / PIDs / bitrate
tsp -I file <clip> -P analyze -O drop
# continuity-counter integrity (no output = 0 errors)
tsp -I file <clip> -P continuity -O drop
# PCR accuracy vs estimated CBR (µs, then absolute PCR units: 27 units = 1 µs, 13 ≈ 481 ns)
tsp -I file <clip> -P pcrverify --jitter-max 500 -O drop
tsp -I file <clip> -P pcrverify --absolute --jitter-max 13 -O drop
# PCR interval min/mean/max + % > 40 ms (TR 101 290 P1), from the CSV's 27 MHz offset column
tsp -I file <clip> -P pcrextract --pcr --csv -o <clip>_pcr.csv -O drop
awk -F, 'NR>1{cur=$7; if(prev!=""){d=(cur-prev)/27000; n++; sum+=d;
  if(d>max)max=d; if(min==""||d<min)min=d; if(d>40)over++} prev=cur}
  END{printf "intervals=%d min=%.2f mean=%.2f max=%.2f ms  >40ms=%d (%.4f%%)\n",
  n, min, sum/n, max, over, (over/n)*100}' <clip>_pcr.csv
```

### Conventions

- Every result records **units**, the **measurement point** (P0/P1/P2), the **tool + version**,
  the **source clip**, and the **build under test**.
- Unmeasured quantities are `TBM` (to be measured) — never blank, never guessed.
- Raw captures and analyser exports are the evidence of record; they are large binaries and are not
  committed. The commands above regenerate them from the source clips.
- Where an experiment produces a result table too large to read inline, the full table is committed as
  CSV in [`results/`](results/) and the per-test file summarises it. The runnable rigs are committed in
  [`scripts/`](scripts/) and are named per test; only machine-specific values (addresses, absolute
  paths, credentials, TLS fingerprints) are held out, in the git-ignored `INSTRUCTIONS.local.md`.

### macOS loopback gotchas (local runs)

- Disable UDP GSO: `--server-quic-gso=false` (relay) and `--client-quic-gso=false` (clients), or
  QUIC handshakes then times out on loopback. Note that this understates relay CPU by ~29 %
  ([T26](test-26-cross-host-fanout.md)), so no capacity figure should be quoted from a GSO-disabled run.
- The `http://` fingerprint bootstrap is broken in recent `moq-dev` builds — connect over `https://`
  and pin the fingerprint explicitly (`--client-tls-fingerprint`). See `INSTRUCTIONS.local.md`.
- Pace the input (`tsp … -P regulate`); an unpaced `import` hits stdin EOF and tears the session
  down before the subscriber pulls.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
