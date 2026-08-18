# Laboratory notebook — MoQ ⇄ MPEG-TS validation campaign

This directory is the **engineering laboratory notebook** for the MoQ MPEG-TS primary-distribution
evaluation. It is both the campaign **plan** (the objective, the gate mapping, and the pass criteria
agreed *before* the numbers were known) and the campaign **record** (what was actually done and
measured — objectives, environments, exact procedures, results, observations and conclusions) so that
an external engineer can follow the experiments and reproduce them. It is the executable companion to
[implementation](../docs/implementation.md) §6–§7 (the validation pyramid and acceptance gates).

It is deliberately distinct from the rest of the repository:

- **`lab/` (here) — "this is what we measured," plus the plan behind it.** The engineering record:
  objectives, environments, exact procedures, measured numbers and conclusions, together with the
  pass criteria fixed in advance. Where a result was later corrected, the per-test file states the
  current finding and records that the earlier reading was wrong and why — the correction is kept,
  the blow-by-blow is not.
- **`docs/` — "this is what we've learned."** The paper: [`docs/evidence.md`](../docs/evidence.md) is
  the validated-findings summary; the topic docs (`architecture.md`, `transport.md`, `relay.md`, …)
  are the design and architecture conclusions. Where an observation here has become a permanent
  finding, this notebook cross-references `docs/evidence.md` rather than restating it.

> **On honesty.** The plan below is written to be *disproven*. Its value is the method and the pass
> criteria, fixed before the numbers are known; the numbers themselves — including results that
> reached the wrong conclusion at the time and were later corrected — are recorded in the per-test
> files, not pre-filled into the plan.

> Machine-specific reproduction detail (relay addresses, the EC2 host IP, absolute paths, TLS
> fingerprints, build locations, credentials) is **not** in this public notebook — it lives in the
> git-ignored `INSTRUCTIONS.local.md`. Public commands below use placeholders such as `<EC2_IP>`
> and `<subscriber-home-ip>`.

## Objective

Validate whether MPEG-TS transported via MoQ can meet professional broadcast distribution
requirements — specifically, whether a groomed MoQ egress is **bit-transparent** to the transport
stream, **timing-conformant** to TR 101 290 P1/P2 on real hardware, and **resilient** under realistic
network impairment and infrastructure failure.

The thesis fails if any of the following holds and cannot be remedied:

- MoQ carriage is *not* bit-transparent (continuity errors, dropped signalling, or structural
  corruption survive a lossless path).
- Groomed egress cannot pass **TR 101 290 P1/P2 on a hardware IRD** (the make-or-break gate —
  [implementation](../docs/implementation.md) §7, Gate 2).
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
[implementation](../docs/implementation.md) §6–§7.

| # | Experiment | Pyramid (§6) | Gate (§7) | State | File |
|---|---|---|---|---|---|
| T1 | Baseline TS characterisation (P0 reference) | reference for 1, 3 | precondition for Gate 1 | complete | [test-1-baseline-ts.md](test-1-baseline-ts.md) |
| T2 | Transport transparency — media-aware lane (local) | 1, 2, 3 | Gate 1 (reference lane) | complete | [test-2-media-aware-transparency.md](test-2-media-aware-transparency.md) |
| T3 | Transport transparency — opaque `m2ts` lane (local) | 1, 2, 3 | **Gate 1 (product lane)** | complete | [test-3-opaque-transparency.md](test-3-opaque-transparency.md) |
| T4 | Remote relay end-to-end + SRT contribution (public internet) | 2 (E2E over real path) | supports Gate 1 & 3 | complete (media-aware) | [test-4-remote-e2e-srt.md](test-4-remote-e2e-srt.md) |
| T5 | Network impairment (both lanes) | 2 (E2E under loss/jitter) | supports Gate 1 & 3 | complete | [test-5-network-impairment.md](test-5-network-impairment.md) |
| T6 | Relay resilience & active/active source failover | 6 (redundancy drill) | Gate 3 — resilience | partial | [test-6-relay-resilience.md](test-6-relay-resilience.md) |
| T7 | Timing integrity (TR 101 290) | 3 (file), 4 (**hardware**) | **Gate 2 — make-or-break** | P1 complete; P2 open | [test-7-timing-integrity.md](test-7-timing-integrity.md) |
| T8 | SRT vs MoQ comparative benchmark | 7 (comparative lab) | feeds [economics](../docs/economics.md) §4, §9 | partial | [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) |
| T8b | Congestion control for a permanent fixed-rate trunk | 7 (comparative lab) | extends T8 | C1 run; C2–C6 open | [test-8b-congestion-control.md](test-8b-congestion-control.md) |
| T9 | System performance & resource utilisation | 5 (scale/soak) | feeds [operations](../docs/operations.md), [economics](../docs/economics.md) §3.1, §4, §9 | partial — publisher and subscriber pass; relay growth root-caused upstream to quinn-proto and its predicted plateau confirmed on this rig (soft ceiling; sub-proportional mitigation) | [test-9-performance.md](test-9-performance.md) |
| T11 | Cross-implementation interop | 7 (comparative lab) | transport neutrality | T11a partial; T11b open | [test-11-interop.md](test-11-interop.md) |
| T12 | End-to-end 1+1 dual-path delivery and hand-off | 6 (redundancy drill) | Gate 3 — resilience; de-risks Gate 2 | complete for a co-started pair, arms A–D, incl. leg failure and recovery; independent restart of one leg blocked upstream | [test-12-dual-path-handoff.md](test-12-dual-path-handoff.md) |
| T13 | Off-the-shelf CBR/PCR grooming of a MoQ egress | 4 (file), plus wire cadence | supports Gate 2; decides how the grooming requirement can be documented | complete for TSDuck, FFmpeg and GStreamer on a broadcast mux and a single-programme feed; no off-the-shelf stage satisfies all four criteria | [test-13-downstream-grooming.md](test-13-downstream-grooming.md) |
| T14 | MoQ against segmented HTTP on one route | 7 (comparative lab) | Gate 1 + Gate 2, both data planes; feeds [alternatives](../docs/alternatives.md) | partial — burst granularity (both arms), carriage fidelity and wire cost measured; the low-latency arm split, publishing TS parts free but finding no free client that fetches them; hardware P1/P2 (which now gates latency too) and MPTS-through-CDN blocked on kit this lab does not have | [test-14-data-plane-comparison.md](test-14-data-plane-comparison.md) |
| T15 | RIST and SRT on T14's cadence instrument | 7 (comparative lab) | extends T14; grades [alternatives](../docs/alternatives.md) §10.1 | complete on a healthy path — RIST (Main and Simple) and SRT measured transparent, identical to a no-transport control, so their egress is their source's; MoQ's granularity is source-independent; loss/RTT and a true CBR hardware source left open | [test-15-point-to-point-cadence.md](test-15-point-to-point-cadence.md) |
| T16 | Grooming a segmented-HTTP egress | 4 (file), plus wire cadence | supports Gate 2 on the alternative data plane; closes [implementation](../docs/implementation.md) §9.1 and the unmeasured cell in [interoperability](../docs/interoperability.md) §6 | complete on a healthy path — the same groomer, sizing itself from arrival, takes T14 arm B1's egress to T13's MoQ-lane conformance with nothing dropped; the three flag-pinned control arms show why it needed deriving rather than documenting; 6 s segments and a lossy path left open | [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md) |

### Pass criteria (agreed in advance)

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Criterion met if the source set is clean
  (0 CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1. Full broadcast transparency (incl. the service layer) is proven on the opaque lane (T3); on this
  lane it is bounded by the time-varying tables — TDT/TOT deliberately (the exporter mints the clock),
  and EIT until [#2824](https://github.com/moq-dev/moq/pull/2824) merges.
- **T3 — Opaque transparency (Gate 1).** Bit-transparency at P1 — TSID/ONID, service name/type, all
  PSI/SI (PAT/PMT/SDT/NIT/TDT/CAT), PMT PID, PCR PID, every elementary stream and every SCTE-35 PID
  preserved verbatim; 0 CC/transport errors; CBR and PCR conformance (0 % > 40 ms) preserved when fed
  the raw source.
- **T4 — Remote E2E + SRT.** Relay reachable over the internet; live SRT contribution chain completes
  end-to-end with 0 CC.
- **T5 — Network impairment.** Loss behaviour is *graceful and bounded* (proportionate throughput
  reduction, recovery observed), not catastrophic; where loss exceeds recovery capacity within the
  buffer, the redundancy path (T6 / ST 2022-7) is the mitigation, not the transport alone.
- **T6 — Relay resilience (Gate 3).** ST 2022-7 dual-path drill is **hitless** at the IRD under
  single-path loss (the two egress legs byte-identical and sequence-aligned); relay-failover recovery
  is bounded and documented, re-establishing without operator intervention; subscriber-reconnect join
  latency is bounded with defined catch-up behaviour. T6 met the second and third of those and
  characterised the determinism *precondition* for the first offline; **[T12](test-12-dual-path-handoff.md)
  then met the first at a receiver** — 0 lost packets under blackout, 1 %/3 % loss and up to 200 ms
  differential delay — for a pair the receiver can merge, which now includes two independently
  groomed chains provided each groomer is stream-clocked, and with it protection of the publisher,
  relay and exporter rather than the last hop alone.
- **T7 — Timing integrity (Gate 2, make-or-break).** A clean **TR 101 290 P1/P2 pass on a real
  hardware IRD, on the live wire (P2), sustained** (target ≥ 24 h), including ST 2022-7 behaviour
  under loss, with the T-STD buffer model confirmed valid under drift/discontinuity. Until this
  exists, the grooming design is "structurally sound and file-validated," not "proven
  broadcast-acceptable."
- **T8 — SRT vs MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer glass-to-glass
  is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery and
  delivered-rate curves are within a stated margin and the failure mode is no worse; egress quality at
  least matches (P1); overhead/CPU recorded as economic inputs. Feeds [economics](../docs/economics.md) §4 and §9.

T8b, T9, T11, T13 and T16 were specified after this list was fixed; their pass criteria are stated the
same way, in advance, at the top of their own files.

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

Protocols are drafted in [planned-experiments.md](planned-experiments.md); each becomes its own
per-test file when executed. In priority order:

| # | Test | Purpose | Gate |
|---|---|---|---|
| T7/P2 | Hardware TR 101 290 P1/P2 soak | The make-or-break gate on a real IRD, on the live wire, sustained (≥ 24 h) incl. ST 2022-7 under loss | **Gate 2** |
| T14 (remainder) | MoQ against segmented HTTP — the two blocked cells | Burst granularity (both arms), carriage fidelity and wire cost are measured in [test-14](test-14-data-plane-comparison.md). What remains: a commercial ABR-to-TS gateway on P1/P2, which now also gates glass-to-glass latency since arm B2 showed no *free* client fetches partial segments (needs hardware, and is the cell that moves the paper most); and MPTS through a real CDN (needs a CDN account — and now carries the whole of MoQ's carriage-fidelity advantage) | Gate 1 and Gate 2, on both data planes |
| T12/E | Restart one leg of a live pair | Stream clocking (T12 arm D) made two independently groomed chains byte-identical, and got a recovered or late-joining leg back onto its partner's numbering, slots and phase. What remains is byte-identity on independent restart, blocked by `moq export ts` numbering continuity counters per process — which also needs a grader that can score a pair that is not byte-identical. Plus a two-host variant, where the legs no longer share a clock | Gate 3 — completes the 1+1 story |
| T10 | MPTS / multiple concurrent services | Carry a multi-program TS (or several concurrent SPTS broadcasts) through the opaque lane; verify per-service PSI/SI, PCR and CC at egress, plus relay fan-out under N services | Gate 1 at multi-service scale |
| T5+ | LEO / Starlink satellite-handover profile | Impairment profile with periodic handover gaps; characterise CC and redundancy behaviour | extends T5/T8 |
| T3/T4+ | Opaque lane over the wire | Deploy the opaque publisher on EC2 to run opaque transparency over a real path (T3/T4 are currently localhost/file-fed on the opaque lane) | supports Gate 1 & 3 |

## Cross-cutting limitations (stated up front)

- **No hardware IRD pass yet.** Gate 2 (T7/P2) is the load-bearing open test. Everything above it is
  necessary but not sufficient.
- **The alternative data plane is only partly measured.** [alternatives](../docs/alternatives.md)
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
  ([relay](../docs/relay.md) §6).
- **The 1+1 measurement is a software receiver on one host.** [T12](test-12-dual-path-handoff.md)
  runs two concurrently live legs into a receiver that selects between them, which is the form a
  head-end expects at a hand-off — but the receiver is a reference implementation of the selection
  rules rather than a hardware IRD's merge engine, and both legs share a host and a clock, so skew is
  injected rather than natural and path diversity is untested.
- **`netem` is an emulator.** T5/T8 complement but do not replace the real public-internet EC2 path.
- **Draft-14 pin.** The opaque lane and T3 are against a pinned, now-behind draft (`moq-transport`
  0.14.2); migration to later drafts is a tracked dependency and its own re-test
  ([transport](../docs/transport.md) §5, [implementation](../docs/implementation.md) §8).
- **Reproducibility.** The opaque publisher/subscriber/groomer are private
  ([implementation](../docs/implementation.md) §2); the T2 media-aware lane is fully reproducible today
  with public `moq-dev` binaries + TSDuck, and its downstream CBR/PCR groom with the public
  [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) crate. Reproducing the opaque,
  IRD-grade egress independently still requires the opaque grooming logic or an equivalent.
- **Large artefacts are not committed.** Captures, pcaps and analyser exports are the evidence of
  record but are kept out of this repository; the notebook records their identity and method, not the
  binaries ([CONTRIBUTING](../CONTRIBUTING.md)).

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
| CBR/PCR grooming | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0 (`cbr_file` / `ts_egress` examples — `ts_egress` was `moq_egress` before [T16](test-16-grooming-segmented-http.md), and records written earlier name it that way) |
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
  CSV in [`results/`](results/) and the per-test file summarises it. The runnable rigs themselves are
  kept local (`lab/scripts/`, git-ignored) and are described in the per-test files.

### macOS loopback gotchas (local runs)

- Disable UDP GSO: `--server-quic-gso=false` (relay) and `--client-quic-gso=false` (clients), or
  QUIC handshakes then times out on loopback.
- The `http://` fingerprint bootstrap is broken in recent `moq-dev` builds — connect over `https://`
  and pin the fingerprint explicitly (`--client-tls-fingerprint`). See `INSTRUCTIONS.local.md`.
- Pace the input (`tsp … -P regulate`); an unpaced `import` hits stdin EOF and tears the session
  down before the subscriber pulls.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
