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

| # | Experiment | Pyramid rung | Gate | State | File |
|---|---|---|---|---|---|
| T1 | Baseline TS characterisation (P0 reference) | reference for 1, 3 | precondition for Gate 1 | complete | [test-1-baseline-ts.md](test-1-baseline-ts.md) |
| T2 | Transport transparency — media-aware lane (local) | 1, 2, 3 | Gate 1 (reference lane) | complete | [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md) |
| T3 | Transport transparency — opaque `m2ts` lane (local) | 1, 2, 3 | **Gate 1 (product lane)** | complete | [test-3-opaque-transparency.md](test-3-opaque-transparency.md) |
| T4 | Remote relay end-to-end + SRT contribution (public internet) | 2 (E2E over real path) | supports Gate 1 & 3 | complete (media-aware) | [test-4-remote-e2e-srt.md](test-4-remote-e2e-srt.md) |
| T5 | Network impairment (both lanes) | 2 (E2E under loss/jitter) | supports Gate 1 & 3 | complete | [test-5-network-impairment.md](test-5-network-impairment.md) |
| T6 | Relay resilience & active/active source failover | 6 (redundancy drill) | Gate 3 — resilience | partial | [test-6-relay-resilience.md](test-6-relay-resilience.md) |
| T7 | Timing integrity (TR 101 290) | 3 (file), 4 (**hardware**) | **Gate 2 — make-or-break** | P1 complete; P2 open | [test-7-timing-integrity.md](test-7-timing-integrity.md) |
| T8 | SRT vs MoQ comparative benchmark | 7 (comparative lab) | feeds [economics](../docs/economics.md) §4, §9 | partial | [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) |
| T8b | Congestion control for a permanent fixed-rate trunk | 7 (comparative lab) | extends T8 | C1–C6 run — 68 cells plus a **14.006 h soak**. **Names no controller — three conditions rank them three ways** — and replaces that question with a provisioning rule: ≥ 1.2× content rate for MoQ, ≥ 1.5× for segmented. An AQM removes bufferbloat outright for every controller at once (554–584 → 101–119 ms). MoQ takes **0 continuity errors in every cell of every condition** while SRT worsens the better-behaved the network is, to 17,652–22,365 under an AQM. C6 settles permanence in BBRv1's favour (0 continuity errors, 0 respawns, no stall) and refutes its own pre-registered memory prediction, converging on **2.03×** the ceiling T9 predicted. **C3 is the lane's one bad result, and it is the receiver's latency budget rather than the network.** At a 2 s budget the aggregate *falls* as feeds are added — 9.44 → 4.89 → 4.02 Mb/s at one, two and three flows under BBRv1, below what one feed carried alone — against SRT's 9.63 → 12.65 rising and holding at 84 %. Two causes eliminated by measurement: not the controller (loss-based CUBIC collapses to 5.39 and 4.48, inside BBRv1's spread) and not bufferbloat (it survives `cake`, which cut RTT ~550 → 100 ms). Widening `--latency-max` 500 ms → 30 s at `n=2` moves the aggregate **4.29 → 10.35 Mb/s**, past the single-flow rate, at 0 continuity errors throughout — so N subscribers independently shed groups that missed their own deadline, and a trunk must be provisioned in latency as well as rate | [test-8b-congestion-control.md](test-8b-congestion-control.md) |
| T9 | System performance & resource utilisation | 5 (scale/soak) | feeds [architecture](../docs/architecture.md) §9), [economics](../docs/economics.md) §3.1, §4, §9 | partial — publisher and subscriber pass; relay growth root-caused upstream to quinn-proto, and its predicted plateau confirmed on this rig (soft ceiling; sub-proportional mitigation). **The ceiling is about twice the slot arithmetic**: T8b's C6 soak converged asymptotically on 2.03× it, still creeping at 14 h, so the "soft" component is real rather than allocator drift. Audience is not a term — growth is flat across 0–4 subscribers here and five connections land in the same range as two — so what remains open is only whether that second term converges and what it tracks | [test-9-performance.md](test-9-performance.md) |
| T11 | Cross-implementation interop | 7 (comparative lab) | transport neutrality | T11a partial; T11b open | [test-11-interop.md](test-11-interop.md) |
| T12 | End-to-end 1+1 dual-path delivery and hand-off | 6 (redundancy drill) | Gate 3 — resilience; de-risks Gate 2 | complete for a co-started pair, arms A–D, incl. leg failure and recovery; independent restart of one leg blocked upstream. **Byte-identity now confirmed across two hosts in two AZs on independent oscillators** — 46,759 datagrams, zero residue — so co-resident agreement is no longer standing in for clock independence. The service layer, clock included, is byte-identical across the pair even with one leg running behind — the exporter renders SI from media position, not arrival | [test-12-dual-path-handoff.md](test-12-dual-path-handoff.md) |
| T13 | Off-the-shelf CBR/PCR grooming of an MPEG-TS egress | 4 (file), plus wire cadence | supports Gate 2; decides how the grooming requirement can be documented | complete for TSDuck, FFmpeg and GStreamer on both data planes, and for `rawsendmpeg2ts` as a datagram sender after them; **the answer depends on the lane** — behind a MoQ egress no off-the-shelf stage satisfies all four criteria and the closest fails carriage alone, but behind a segmented egress `tsp -P pcradjust -P regulate` passes all four with the mux intact, because that lane delivers the stuffing and PCR spacing MoQ drops | [test-13-downstream-grooming.md](test-13-downstream-grooming.md) |
| T14 | MoQ against segmented HTTP on one route | 7 (comparative lab) | Gate 1 + Gate 2, both data planes; feeds [comparison](../docs/comparison.md) | partial — burst granularity (both arms), carriage fidelity and wire cost measured; the low-latency arm split, publishing TS parts free but finding no free client that fetches them; hardware P1/P2 (which now gates latency too) and MPTS-through-CDN blocked on kit this lab does not have | [test-14-data-plane-comparison.md](test-14-data-plane-comparison.md) |
| T15 | RIST and SRT on T14's cadence instrument, and what each transport does to the clock | 7 (comparative lab) | extends T14; grades [comparison](../docs/comparison.md) §10.1; settles the clock design on [#2914](https://github.com/moq-dev/moq/issues/2914) | complete on a healthy path — RIST (Main and Simple) and SRT measured transparent, identical to a no-transport control, so their egress is their source's; MoQ's granularity is source-independent; on the clock, the pipes add nothing while the media-aware lane delivers a TDT ~14 s late and repeats one it has already sent when the source ticks slower than its 30 s timer; loss/RTT and a true CBR hardware source left open | [test-15-point-to-point-cadence.md](test-15-point-to-point-cadence.md) |
| T16 | Grooming a segmented-HTTP egress | 4 (file), plus wire cadence | supports Gate 2 on the alternative data plane; closes [architecture](../docs/architecture.md) §4.5 and the unmeasured cell in [evidence](../docs/evidence.md) §3.2 | complete on a healthy path — the same groomer, sizing itself from arrival, takes T14 arm B1's egress to T13's MoQ-lane conformance with nothing dropped; the three flag-pinned control arms show why it needed deriving rather than documenting; 6 s segments and a lossy path left open | [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md) |
| T17 | Standalone SI on snapshot tracks: EIT carriage and its join cost | 2/3 (carriage fidelity) | closes the EIT residual in [evidence](../docs/evidence.md) §3.1; prices the join question [#2882](https://github.com/moq-dev/moq/issues/2882) asked | complete, and the design it graded is merged — EIT round-trips section-for-section including the sparse schedule, carriage is bitrate-neutral (0.985×) and the export gate cost 1 ms, which is what retired the gate upstream rather than tuning it; the clock has since been added too, leaving its emission timing rather than its carriage as the open item ([T15](test-15-point-to-point-cadence.md) measurement 4). The same fixture through the segmented lane also arrives with all 69 sections byte-identical, so neither plane now loses an EPG — the media-aware one by reconstructing the table, the segmented one by never parsing it | [test-17-si-snapshot-tracks.md](test-17-si-snapshot-tracks.md) |
| T18 | Delivery latency at equal conformance, on four data planes | 1 (latency) + supports Gate 2 | closes the campaign's last unmeasured axis and the open coupling in [comparison](../docs/comparison.md) §5.1 | complete on loopback and over the public internet, and it **refuted the premise it was designed to test** — latency and PCR conformance are independent on the media-aware lane. MoQ crosses the internet in **109 ms** against SRT's 1,618 ms and segmented HTTP's 4,067 ms, and fails P1 repetition at every buffer depth for a reason upstream of the groomer — which placed 137, 103, 28 and 0 PCRs of its own across the stuffing ladder for violation counts of 491, 489, 503, 502. Measurement 6 then shows the defect is **spacing, not density** — 31–36 PCRs/s against the source's 41, but 85 % of intervals under 1 ms — which overturns the premise of our own upstream issue. A lossy path and a long path are left open; whether an evenly spaced cadence clears the gate is now [T19](test-19-pcr-grid-verification.md)'s | [test-18-delivery-latency.md](test-18-delivery-latency.md) |
| T19 | The PCR grid, and reconstructing a CBR wire from a media-aware source | supports Gate 2 (conformance) | grades the three upstream PCR fixes and then the downstream reconstruction they left to be done | complete, and **the lane passes on the wire**: over 300 s live, 10,838/10,838 pictures matched, **0** continuity errors, **0/20,193** PCR intervals above 40 ms at a worst of 30.1 ms, 0 PCRs outside ±500 ns, 10,999,999 b/s against a nominal 11,000,000, 0 drops and 0 underruns. Getting there took four stages. **Values:** [#2967](https://github.com/moq-dev/moq/pull/2967) fixed them exactly — every one of 2,472 intervals at **25.000 ms**, above 40 ms 210 → **0**, sub-millisecond clustering 85.40 % → **0.00 %** — plus a conformance defect we never found (reserved PCR bits `0x00` → `0x3F`) and the 11 µs mechanism explained from the code. **Arrival time:** [#3006](https://github.com/moq-dev/moq/pull/3006) paced the stdout writer — on-grid share 27.4 → **56.9 %**, gate failures 18.26 → **7.45 %** — but bimodally, and a groomer reads bytes rather than arrival times, so end to end it changed nothing. **Byte positions:** filed as [#3334](https://github.com/moq-dev/moq/issues/3334) with the instrument offered as [#3335](https://github.com/moq-dev/moq/pull/3335), granted and merged as [#3351](https://github.com/moq-dev/moq/pull/3351) — adjacency **87.2 % → 0.0 %**, releases outside ±10 ms **2/4,779** at a p95 of **1.70 ms**, upstream's own gate green. It won the lane its first movement on content (36 % fewer groomer drops, stuffing halved) and **still left 12.2 % of intervals above 40 ms**. **The reconstruction:** the residue was never upstream's — a coded frame's bytes belong to its own 40 ms, so a 417 kB I-frame is 357 ms of carrier, and the CBR mux schedule that used to smooth that is not in the decode timestamps. It was three defects in **our** groomer, none visible on a source arriving at its own mux rate: PCR re-insertion took only slots the content scheduler declined and a burst declines none (all 71 over-40 ms intervals held **zero** nulls); the media-rate estimator averaged per-interval ratios across intervals carrying 1–4,631 packets and read 23 % low; and release was open-loop on that estimate, ramping latency **+1,793 ms in 90 s**. Fixed, the lane passes at every cushion. **The cost is buffer, and it tracks the peak coded frame rather than the bitrate** — three sources at 9.5–9.9 Mb/s with peak frames of 256 / 1,826 / 4,562 packets need bounds differing by more than 3×; **3.6× the peak frame's carriage duration sufficed and 2.5× did not**; cap governs loss and cushion governs underrun. The **~480 ms standing lag is neither B-frame reorder depth nor the latency budget**: `bframes=0` still carries 428.6 ms of it, and moving `--latency-max` across 500 ms / 1 s / 2 s moves it by under 40 ms. **The instrument has a test of its own**, which it did not when any of this was measured: ten boundary fixtures and 38 assertions (`ts-pcr-fixtures.py`, `ts-pcr-selftest.py`), the 33-bit wrap **placed 400 ms in** rather than soaked 26.51 h for, and two further analyser defects found in the building of it | [test-19-pcr-grid-verification.md](test-19-pcr-grid-verification.md) |

| T20 | The segmented lane over HTTP/3, and what that does to the reordering result | Gate 1 (data plane), substrate-matching | closes P0-2 and answers open question 18 | complete. **An HTTP/3 HLS client now exists here**: FFmpeg master `--enable-libcurl` against a libcurl carrying ngtcp2 1.16 / nghttp3 1.12 / OpenSSL 3.5.5 native QUIC, fetching from an nginx vhost with **no TCP listener**, proven by 54/54 origin log lines reading `alpn=h3` and a capture holding **109,657 UDP / 0 TCP**. Building it exposed an FFmpeg defect worth more than the arm: `http_version` is not on the whitelist propagated to a demuxer's child connections, so `-http_version 3only` fetches the *playlist* over H3 and **every media segment over HTTP/1.1**, silently. **The headline is a correction**: T5's 0.98-against-0.19 reordering separation was a **packet-size artefact** — 1,209 packets averaging 34,380 B on the segmented lane against 29,062 averaging 931 B on the media-aware one, with `netem` reordering per packet, so the winner met ~24× fewer events. Reproduce those conditions and the old numbers return exactly (0.995 / 0.125); equalise MTU and offloads and it reads **0.44 TCP, 0.18 HTTP/3, 0.13 media-aware**, the last two overlapping. **The substrate change is a trade, not a loss**: it costs reordering and wins loss (0.10 → 0.70 at ~20 % applied) and the 30 s outage (0.51 → 0.76), while unimpaired the two substrates are byte-identical. Under *sustained* under-capacity the segmented arms take lateness (0.79–0.81, near the pipe's 0.85 ceiling) where the media-aware lane discards programme (0.46). **Limit:** the H3 receiver re-muxes, so continuity and PCR on the HLS arms grade the receiver, not the wire | [test-20-segmented-http3.md](test-20-segmented-http3.md) |
| T21 | The permanence soak of the complete media-aware lane, groomer included | Gate 2 (conformance) over time, and the permanence question the use case rests on | the first long run to put the groomer inside the measurement; supersedes the assumption that T19's 300 s result extends | **Mechanism found; two faults in series, one upstream and one ours.** The wire is clean and stays clean throughout — **0** continuity errors, **0** PCR intervals above 40 ms (worst 30.08 ms), exact 11,000,000 b/s, 0 drops, 0 respawns, programme conserved. Behind it the groomer's recovered media rate leaves the truth at about **nine minutes** and ramps **linearly without bound** to 6.98 Gb/s, while the de-jitter buffer collapses from **10,587 packets (~1.4 s) to 0** with underruns at **~970/s**, and **nothing downstream can see any of it**. The **trigger is upstream**: the source loops the clip at 600 s and signals one clean PCR discontinuity, and the exporter never passes it on — it latches the last pre-wrap value and emits PCR advancing **one 90 kHz tick per packet** thereafter, so 100,000 packets of programme carry **6.9 ms** of PCR instead of 15,880 ms. The **amplifier was ours**: the estimator divided real packets by a media time that had stopped advancing. Diagnosed by reporting the two accumulators separately (denominator flat at 2.15 s, numerator ramping at exactly the arrival rate) and attributed by capturing both sides of the round trip in one run. Groomer half **fixed and regression-tested** (`mpegts-pacer` `5ab84cd`); exporter half reported upstream. *The earlier reading — wholly ours, loop wrap eliminated — was wrong on both counts: the control that eliminated the wrap had removed the exporter from the path.* T19's conformance result still stands for its 300 s window; the re-soak that would extend it has not been run | [test-21-permanence-soak.md](test-21-permanence-soak.md) |
| T22 | Silent media-plane failure: the feed stops, the transport does not | R8 (observability), the failure primary distribution is least protected against | closes P0-4 for the MoQ lane and validates [Architecture](../docs/architecture.md) §9.1's monitoring design | complete, six arms including a control. **The transport never detects a stalled source**: with the source frozen for **120 s** and every session established, publisher, relay and exporter logged **nothing** — no error, no timeout, no reconnect. Not a threshold artefact, since the 30 s and 120 s arms agree. **The media plane detects it in about one cushion**: the groomer's content alarm at **1.69–1.88 s** and PCR progression within the 100 ms observation tick, from two independent mechanisms, with **no false positive on the control**. A frozen **relay** is the one case the transport catches — QUIC's idle timeout at **34.3 s**, 18× slower, taking the egress chain with it. **`--on-stall continue` makes the failure undetectable downstream**: byte-perfect CBR, valid PCR, no programme, indefinitely. **Recovery is clean and scored on media**: back within **0.02–1.02 s** of resume, stable within 0.92 s, and the programme clock skips **exactly** the wall-clock outage (119,365 ms over 119.3 s) — the lane resumes at the live edge, so it neither replays nor runs late, and the programme lost is gone. The buffer buys **1.8–1.9 s** and no more. **PCR progression is the detector to build on**: it needs nothing from MoQ, nothing from the groomer and no cooperation from the sender. **Left open:** `SIGSTOP` freezes a process cleanly, so a *partial* stall — some tracks advancing, or timestamps repeating while bytes flow — is untested, and a PCR that keeps advancing over a frozen picture defeats the primary detector | [test-22-silent-media-plane-failure.md](test-22-silent-media-plane-failure.md) |

### Pass criteria (agreed in advance)

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Criterion met if the source set is clean
  (0 CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1. Full broadcast transparency (incl. the service layer) is proven on the opaque lane (T3); on this
  lane the service layer is now carried in full: EIT, schedule included, round-trips on
  [#2909](https://github.com/moq-dev/moq/pull/2909), and TDT/TOT is proxied from the source on
  [#2929](https://github.com/moq-dev/moq/pull/2929), closing
  [#2914](https://github.com/moq-dev/moq/issues/2914). What remains is *when* the clock is emitted
  rather than whether: the exporter re-emits a stored section on its own 30 s timer, so the TDT a
  receiver reads is ~14 s later than the one the source sent
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
  exists, the grooming design is "structurally sound and file-validated," not "proven
  broadcast-acceptable."
- **T8 — SRT vs MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer delivery latency
  is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery and
  delivered-rate curves are within a stated margin and the failure mode is no worse; egress quality at
  least matches (P1); overhead/CPU recorded as economic inputs. Feeds [economics](../docs/economics.md) §4 and §9.
  **The latency criterion is met and then some** — [T18](test-18-delivery-latency.md) measures MoQ at
  109 ms against SRT's 1,618 ms over the same internet path — but the P1 criterion is not.

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

Protocols are drafted in [planned-experiments.md](planned-experiments.md), prioritised there as P0/P1/P2
by what a result could change; each becomes its own per-test file when executed. **The programme has
been reorganised around permanent operation rather than around whether MoQ works**, so alongside the
per-experiment remainders below it now carries eleven reliability families (F1–F11): substrate-matched
impairment, 24 h and 7 day soaks on both lanes, silent media-plane failure, a failure-injection matrix
scored in media lost rather than in recovery time, the scaling model, each lane's distributed
redundancy, capacity degradation, interoperability, observability and isolation under abuse.

The per-experiment remainders, in priority order:

| # | Test | Purpose | Gate |
|---|---|---|---|
| T7/P2 | Hardware TR 101 290 P1/P2 soak | The make-or-break gate on a real IRD, on the live wire, sustained (≥ 72 h — the PCR base wraps at 26.51 h) incl. ST 2022-7 under loss | **Gate 2** |
| T14 (remainder) | MoQ against segmented HTTP — the two blocked cells | Burst granularity (both arms), carriage fidelity and wire cost are measured in [test-14](test-14-data-plane-comparison.md), and delivery latency in [test-18](test-18-delivery-latency.md). What remains: a commercial ABR-to-TS gateway on P1/P2, which also gates the segmented plane's *low-latency* arm since B2 showed no *free* client fetches partial segments (needs hardware, and is the cell that moves the paper most); and MPTS through a real CDN (needs a CDN account — and now carries the whole of MoQ's carriage-fidelity advantage) | Gate 1 and Gate 2, on both data planes |
| T12/E | Restart one leg of a live pair | Stream clocking (T12 arm D) made two independently groomed chains byte-identical, and got a recovered or late-joining leg back onto its partner's numbering, slots and phase. The two-host variant is **run**, and the legs stay byte-identical without a shared clock. What remains is byte-identity on independent restart, blocked by `moq export ts` numbering continuity counters per process — which also needs a grader that can score a pair that is not byte-identical | Gate 3 — completes the 1+1 story |
| T10 | MPTS / multiple concurrent services | Carry a multi-program TS (or several concurrent SPTS broadcasts) through the opaque lane; verify per-service PSI/SI, PCR and CC at egress, plus relay fan-out under N services | Gate 1 at multi-service scale |
| T5+ | LEO / Starlink satellite-handover profile | Impairment profile with periodic handover gaps; characterise CC and redundancy behaviour | extends T5/T8 |
| T3/T4+ | Opaque lane over the wire | Deploy the opaque publisher on EC2 to run opaque transparency over a real path (T3/T4 are currently localhost/file-fed on the opaque lane) | supports Gate 1 & 3 |

## Cross-cutting limitations (stated up front)

- **No hardware IRD pass yet.** Gate 2 (T7/P2) is the load-bearing open test. Everything above it is
  necessary but not sufficient, and nothing in this campaign has ever been fed to a hardware decoder
  or graded by a hardware analyser.
- **Latency is measured, but it is *delivery* latency and both paths were healthy.**
  [T18](test-18-delivery-latency.md) grades every plane's source-to-groomed-egress latency against the
  conformance of the same bytes, on loopback and from EC2 over the public internet: MoQ 109 ms, SRT
  1,618 ms, segmented HTTP 4,067 ms, all in the same window. It does not include encoder or decoder delay, so there is still no
  camera-to-display figure — and neither path was impaired or long, so nothing exercised the recovery the
  point-to-point tunnels exist for, which is the case that should favour them.
- **The groomed MoQ egress is P1-conformant on PCR repetition on the wire, and the long-standing
  failure was the groomer's.** It now returns 0 of 20,193 intervals above 40 ms over 300 s, 0 continuity
  errors and exact CBR ([T19](test-19-pcr-grid-verification.md) measurement 11); it used to return
  131–159 in 25 s against 0 % on file ([T13](test-13-downstream-grooming.md)), and
  [T16](test-16-grooming-segmented-http.md) reaches 0 on the *other* data plane at an 8 s cushion. The
  obvious reading — that MoQ needed comparable depth, spending its latency advantage — was **wrong**, and
  so was the reading that replaced it. [T18](test-18-delivery-latency.md) swept the cushion across eight
  times the depth, removed groomer starvation entirely, and moved the figure not at all; that was taken
  as proof of an exporter defect, but no cushion shortens a coded frame, and the groomer could only place
  a PCR in a slot the content scheduler declined. Reserving the slot instead clears it. What *was*
  genuine in the exporter reading is fixed upstream in `#3351`: measured against the same clip on three
  transparent lanes, the old exporter conserved the PCR *count* —
  31–36 a second against the source's 41, where ~25 would satisfy the gate — and destroyed the *spacing*,
  putting 85 % of intervals under 1 ms and collecting the residue into gaps of 100 ms to 1.8 s. Whether an
  **evenly spaced** exporter cadence clears the gate is answered, in three parts:
  [#2967](https://github.com/moq-dev/moq/pull/2967) made the exporter's PCR *values* an exact 25 ms grid,
  [#3351](https://github.com/moq-dev/moq/pull/3351) put each PCR packet beside the media bytes it labels,
  and **neither cleared the wire gate — the third part was ours**. The cost that remains is a buffer, and
  it is sized by the peak coded frame rather than the bitrate ([T19](test-19-pcr-grid-verification.md)).
- **The alternative data plane is only partly measured.** [comparison](../docs/comparison.md)
  grades MoQ against segmented HTTP carrying MPEG-TS. [T14](test-14-data-plane-comparison.md) has
  measured three of its rows — burst granularity, carriage fidelity and wire cost — and moved all three.
  The rest are still specification text or vendor datasheets, and the vendor claims in particular should
  be read as such: no ABR-to-TS product has been graded on the Gate 2 rig. The comparison is also
  single-route, single-clip, loopback, and its per-packet framing is derived rather than measured. Its
  low-latency arm has now run, and split: publishing MPEG-TS partial segments is free and works, while
  no free client fetches them, so that arm's *receive* half is untested for want of any implementation.
  [T16](test-16-grooming-segmented-http.md) has since added the grooming row, on the same route and
  therefore with the same limits: the alternative's egress reaches the MoQ lane's conformance from one
  groomer, at one segment duration, on a path where nothing was ever lost — only late.
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
  the source file, single-track content stays byte-identical over 46,778 of 46,778 shared datagrams
  with zero residue. **A seven-stream mux over the same topology reaches 75.56 %**, the residue being
  the same packets in a different order rather than damage, for a reason located upstream.
- **`netem` is an emulator.** T5/T8 complement but do not replace the real public-internet EC2 path.
- **Draft-14 pin.** The opaque lane and T3 are against a pinned, now-behind draft (`moq-transport`
  0.14.2); migration to later drafts is a tracked dependency and its own re-test
  ([architecture](../docs/architecture.md) §10, [architecture](../docs/architecture.md) §10).
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
  QUIC handshakes then times out on loopback.
- The `http://` fingerprint bootstrap is broken in recent `moq-dev` builds — connect over `https://`
  and pin the fingerprint explicitly (`--client-tls-fingerprint`). See `INSTRUCTIONS.local.md`.
- Pace the input (`tsp … -P regulate`); an unpaced `import` hits stdin EOF and tears the session
  down before the subscriber pulls.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
