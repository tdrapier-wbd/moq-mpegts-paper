# Laboratory notebook — MoQ ⇄ MPEG-TS validation campaign

This directory is the **engineering laboratory notebook** for the MoQ MPEG-TS primary-distribution
evaluation. It is both the campaign **plan** (the objective, the gate mapping, and the pass criteria
agreed *before* the numbers were known) and the campaign **record** (what was actually done and
measured — objectives, environments, exact procedures, results, observations and conclusions) so that
an external engineer can follow the experiments and reproduce them. It is the executable companion to
[implementation](../docs/implementation.md) §6–§7 (the validation pyramid and acceptance gates).

It is deliberately distinct from the rest of the repository:

- **`lab/` (here) — "this is what happened," plus the plan behind it.** The chronological engineering
  record: experiments, commands, measured numbers, and the corrections made along the way (preserved,
  not rewritten), together with the pass criteria fixed in advance.
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
exercise ([economics](../docs/economics.md)).

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
| T8 | SRT vs MoQ comparative benchmark | 7 (comparative lab) | feeds [economics](../docs/economics.md) §8 | partial | [test-8-srt-vs-moq.md](test-8-srt-vs-moq.md) |

### Pass criteria (agreed in advance)

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Criterion met if the source set is clean
  (0 CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1. Full broadcast transparency (incl. the service layer) is proven on the opaque lane (T3); on this
  lane it is bounded by the dynamic TDT/TOT/EIT tables.
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
  latency is bounded with defined catch-up behaviour.
- **T7 — Timing integrity (Gate 2, make-or-break).** A clean **TR 101 290 P1/P2 pass on a real
  hardware IRD, on the live wire (P2), sustained** (target ≥ 24 h), including ST 2022-7 behaviour
  under loss, with the T-STD buffer model confirmed valid under drift/discontinuity. Until this
  exists, the grooming design is "structurally sound and file-validated," not "proven
  broadcast-acceptable."
- **T8 — SRT vs MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer glass-to-glass
  is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery and
  delivered-rate curves are within a stated margin and the failure mode is no worse; egress quality at
  least matches (P1); overhead/CPU recorded as economic inputs. Feeds [economics](../docs/economics.md) §8.

## Roadmap — specified but not yet run

Protocols are drafted in [planned-experiments.md](planned-experiments.md); each becomes its own
per-test file when executed, or earlier where a runnable rig already exists. In priority order:

| # | Test | Purpose | Gate |
|---|---|---|---|
| T7/P2 | Hardware TR 101 290 P1/P2 soak | The make-or-break gate on a real IRD, on the live wire, sustained (≥ 24 h) incl. ST 2022-7 under loss | **Gate 2** |
| T8b | [Bufferbloat under a shaped bottleneck](test-8b-bufferbloat-cc.md) | The one meaningful congestion-control test (10 Mb/s source, rate-limited to 5 Mb/s, 100 ms RTT, 500 ms queue), all controllers, goodput **and** standing RTT together — gates any default-controller recommendation. **Condition 6a run (first pass):** CUBIC reliably bloats; BBRv2 reliably ~½ its RTT; BBRv1 bimodal; BBRv3 broken (#768). 6b/6c/6d pending | extends T8 |
| T9 | System performance & resource utilisation | Per-role CPU/RSS/fd/thread envelope, fan-out scaling, protocol overhead, and a hours→days soak. Pass: **no leak** (RSS slope ≈ 0 over ≥ 24 h per role; fd/socket/thread counts stable), bounded CPU with a documented fan-out knee, overhead within budget | feeds [operations](../docs/operations.md) & [economics](../docs/economics.md) §8 |
| T10 | MPTS / multiple concurrent services | Carry a multi-program TS (or several concurrent SPTS broadcasts) through the opaque lane; verify per-service PSI/SI, PCR and CC at egress, plus relay fan-out under N services | Gate 1 at multi-service scale |
| T5+ | LEO / Starlink satellite-handover profile | Impairment profile with periodic handover gaps; characterise CC and redundancy behaviour | extends T5/T8 |
| T3/T4+ | Opaque lane over the wire | Deploy the opaque publisher on EC2 to run opaque transparency over a real path (T3/T4 are currently localhost/file-fed on the opaque lane) | supports Gate 1 & 3 |

## Rough chronology

Dates are as recorded at the time; builds under test are pinned per experiment (see also the
provenance table in `notebook.local.md`).

- **2026-07-16** — T2 first media-aware run (`moq-token-cli` build, moq-lite-04): elementary
  streams survive, DVB service layer dropped, PMT renumbered.
- **2026-07-17** — T5 opaque-lane impairment, built and run on EC2 loopback.
- **2026-07-18** — `mpegts-pacer` P1 grooming three-clip run.
- **2026-07-20** — ST 2022-7 output-determinism study (T6 precondition).
- **2026-07-21** — T2 `dev` re-run @ `e3576465` confirming the #1979 fix (#2072 + #2066).
- **2026-07-22** — T1 P0 baseline (4 clips); T4 remote SRT chain; T7 P1 four-clip run; T8
  clean-path + start of the impairment matrix.
- **2026-07-23** — T8 four-way CC comparison; third-party BBR relay dual long-haul.
- **2026-07-24** — T6 #2473 first review; #2468 CC-default flip noted.
- **2026-07-27** — T6 #2473 re-review (`cc11cbaf`), live two-relay drill passes.
- **2026-07-28** — #2473 merged (`b624c7c0`).
- **2026-07-30** — T6 re-verify on the `moq-net 0.2.5` / `moq-cli 0.9.5` release.

## Cross-cutting limitations (stated up front)

- **No hardware IRD pass yet.** Gate 2 (T7/P2) is the load-bearing open test. Everything above it is
  necessary but not sufficient.
- **No live contribution source in the *opaque* transparency run yet.** T2/T3 are localhost,
  file-fed; T4 has run a live SRT contribution source end-to-end on the media-aware lane, but the
  opaque lane over the wire awaits deploying the opaque publisher on EC2.
- **No production relay cluster.** T6 is a two-relay lab, not a federated mesh
  ([relay](../docs/relay.md) §6).
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
| CBR/PCR grooming | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0 (`cbr_file` / `moq_egress` examples) |
| Network impairment | Linux `tc` / `netem` (optionally `tbf`/`htb` for rate); shaped-bottleneck rigs in [`scripts/`](scripts/) |
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

### macOS loopback gotchas (local runs)

- Disable UDP GSO: `--server-quic-gso=false` (relay) and `--client-quic-gso=false` (clients), or
  QUIC handshakes then times out on loopback.
- The `http://` fingerprint bootstrap is broken in recent `moq-dev` builds — connect over `https://`
  and pin the fingerprint explicitly (`--client-tls-fingerprint`). See `INSTRUCTIONS.local.md`.
- Pace the input (`tsp … -P regulate`); an unpaced `import` hits stdin EOF and tears the session
  down before the subscriber pulls.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
