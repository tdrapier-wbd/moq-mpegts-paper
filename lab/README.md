# Laboratory notebook — MoQ ⇄ MPEG-TS validation campaign

This directory is the engineering notebook for the MoQ MPEG-TS primary-distribution evaluation. It
holds the campaign **plan** — the objective, the gate mapping and the pass criteria fixed before the
numbers were known — and the campaign **record**: for each experiment, the objective, environment,
exact procedure, measured results and conclusion, written so that an external engineer can reproduce
it. It is the executable companion to [evidence](../docs/evidence.md) §1.2, which defines the
validation pyramid and the acceptance gates.

Three other files here are not experiments. [`method-notes.md`](method-notes.md) holds every
measurement rule the campaign learned by getting something wrong, by theme rather than by experiment.
[`upstream-contributions.md`](upstream-contributions.md) records what was found, reported and verified
in other people's projects, including the review of the MSFTS carriage specification.
[`planned-experiments.md`](planned-experiments.md) is the register of outstanding work. The paper in
[`docs/`](../docs/) states what has been learned; where an observation here has become a permanent
finding, this notebook points to [`docs/evidence.md`](../docs/evidence.md) rather than restating it.

> **On honesty.** The plan is written to be disproven. Results that reached the wrong conclusion and
> were later corrected are recorded in the per-test files, which state the current finding and, where
> the correction carries a lesson, why the earlier reading was wrong.

> Machine-specific detail — addresses, the EC2 host IP, absolute paths, TLS fingerprints, build
> locations, credentials — is not in this public notebook. It lives in the git-ignored
> `INSTRUCTIONS.local.md`, and public commands use placeholders such as `<EC2_IP>` and
> `<subscriber-home-ip>`. Every rig script is committed.

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

The campaign does not attempt to prove economic superiority, which is a separate, route-specific
exercise ([economics](../docs/economics.md)); its desk working is kept here as an analysis
([cost-model.md](cost-model.md)).

**Ordering.** Run cheap-and-decisive first: T1 (reference) → T2 (media-aware fidelity) → T3 (opaque
fidelity, Gate 1) → T7 file-based, then T7 hardware (Gate 2, make-or-break) → T4/T5/T6 (real path,
impairment, resilience — Gate 3). If Gate 2 fails, stop and fix grooming before investing in scale
work: a resilient path that a hardware IRD rejects is not a product.

## Experiments

Every experiment the campaign has specified, run or not, has its own file, structured as Objective /
Environment / Procedure / Results / Observations / Conclusion / References. **The file is
authoritative** for its measurements, scope and qualifications, and its `State:` line for how far it
has got. The *Current finding* column is an index entry, not a summary of the evidence: one line, and
no number without the conditions its file states. The rung and gate are from
[evidence](../docs/evidence.md) §1.2.

| # | Experiment | Rung · gate | State | Current finding | File |
|---|---|---|---|---|---|
| T1 | Baseline TS characterisation (P0 reference) | reference · precondition for Gate 1 | complete | The four-clip source set is clean and representative, so downstream deltas are honest | [test-1](test-1-baseline-ts.md) |
| T2 | Transport transparency — media-aware lane | 1–3 · Gate 1 (reference lane) | complete | Every elementary stream and the DVB service layer round-trip; the lane's own PCR cadence does not | [test-2](test-2-media-aware-transparency.md) |
| T3 | Transport transparency — opaque `m2ts` lane | 1–3 · **Gate 1 (product lane)** | complete | Byte-transparent at P1 on one run, and the reference the other lanes are read against | [test-3](test-3-opaque-transparency.md) |
| T4 | Remote relay end-to-end + SRT contribution | 2 · Gates 1 and 3 | complete, all three lanes | Three data planes graded over one internet path by one instrument; the service layer survives it | [test-4](test-4-remote-e2e-srt.md) |
| T5 | Network impairment | 2 · Gates 1 and 3 | complete | Loss behaviour is the congestion controller's, not the lane's; its reordering cell is superseded by T20 | [test-5](test-5-network-impairment.md) |
| T6 | Relay resilience and active/active source failover | 6 · Gate 3 | partial | Relay failover is bounded by the QUIC idle timeout and is not hitless; a graceful source exit is not failed over | [test-6](test-6-relay-resilience.md) |
| T7 | Timing integrity (TR 101 290) | 3 (file), 4 (**hardware**) · **Gate 2** | P1 complete; P2 open | The re-stamp arithmetic is right on file, which is necessary and not sufficient | [test-7](test-7-timing-integrity.md) |
| T8 | SRT against MoQ | 7 · feeds economics §4, §9 | partial | Graded on throughput and continuity at a matched controller, MoQ and SRT are on par through 10 % loss; graded on content, T28 finds SRT loses less | [test-8](test-8-srt-vs-moq.md) |
| T8b | Congestion control for a permanent fixed-rate trunk | 7 · extends T8 | complete, C1–C7 | **No controller recommendation is supportable**; provisioning margin, queue discipline and the receiver's budget govern the feed | [test-8b](test-8b-congestion-control.md) |
| T9 | System performance and resource utilisation | 5 · feeds architecture §9, economics §3 | partial | Publisher and subscriber pass; relay growth is root-caused to `quinn-proto` stream recycling; its N = 55 knee was the test box (T26) | [test-9](test-9-performance.md) |
| T10 | MPTS / multiple concurrent services | 3 + 5 · Gate 1 | arms A, B, D run on two builds; C, E not run | The segmented lane carries a three-programme multiplex; the MoQ lane's handling varies by build, and on `main` a programme must be selected | [test-10](test-10-mpts-multiservice.md) |
| T11 | Cross-implementation interop | 7 · transport neutrality | T11a partial; T11b open | Media flows within one implementation and through none of eight others, for at least four distinct causes | [test-11](test-11-interop.md) |
| T12 | End-to-end 1+1 dual-path delivery and hand-off | 6 · Gate 3 | complete for a co-started pair, arms A–D | Two stream-clocked groomers are byte-identical and hitless **on single-track content**; a multi-track mux over independent chains does not merge at the byte | [test-12](test-12-dual-path-handoff.md) |
| T13 | Off-the-shelf CBR/PCR grooming of an MPEG-TS egress | 4 · Gate 2 | complete for four tools on both data planes | **It depends on the lane**: `tsp` grooms a segmented egress to all four criteria; behind a MoQ egress nothing off the shelf passes | [test-13](test-13-downstream-grooming.md) |
| T14 | MoQ against segmented HTTP on one route | 7 · Gates 1 and 2 | partial | Segmented HTTP is verbatim in payload for one programme and much coarser at the hand-off; hardware and MPTS-through-CDN need kit this lab lacks | [test-14](test-14-data-plane-comparison.md) |
| T15 | RIST and SRT on T14's cadence instrument | 7 · extends T14 | complete on a healthy path | RIST and SRT are transparent to their source's cadence, where MoQ sets its own granularity | [test-15](test-15-point-to-point-cadence.md) |
| T16 | Grooming a segmented-HTTP egress | 4 · Gate 2, alternative plane | complete on a healthy path | The same groomer, unchanged, takes a segmented egress to the MoQ lane's conformance; cushion depth is the operative variable | [test-16](test-16-grooming-segmented-http.md) |
| T17 | Standalone SI on snapshot tracks | 2–3 · closes the EIT residual | complete; design merged | Neither plane loses an EPG; carriage is bitrate-neutral and the join costs 1 ms | [test-17](test-17-si-snapshot-tracks.md) |
| T18 | Delivery latency at equal conformance, four data planes | 1 · supports Gate 2 | complete, loopback and internet | **It refuted its premise**: on the media-aware lane latency and PCR conformance are independent, and the fastest cushions are not P1-conformant on any lane | [test-18](test-18-delivery-latency.md) |
| T19 | The PCR grid, and a CBR wire from a media-aware source | supports Gate 2 | complete; criteria 1–3 met, 4 not | **The lane passes P1 on the wire** after three upstream fixes and three groomer fixes, and **fails its own latency criterion** at that configuration | [test-19](test-19-pcr-grid-verification.md) |
| T20 | The segmented lane over HTTP/3 | Gate 1 · substrate matching | complete | T5's reordering separation was a packet-size artefact; through a byte-faithful receiver the HLS wire is PCR-conformant and the impairment cells are re-measured | [test-20](test-20-segmented-http3.md) |
| T21 | Permanence soak of the complete media-aware lane | Gate 2 over time | complete | **The media plane passes 24 h** on `d518b61b`; resources fail in the importer there and pass in every role on `main` at `9d2a4f6e` | [test-21](test-21-permanence-soak.md) |
| T22 | Silent media-plane failure | R8 | complete, both lanes | **Neither lane's transport detects a stalled source**; only the segmented lane's playlist moves | [test-22](test-22-silent-media-plane-failure.md) |
| T23 | Which PCR timeline events the lane survives | Gate 2 | complete, re-graded against both fixes | The 33-bit rollover always carried; since #3375 and #3529 every placed class sits at the control's content gap | [test-23](test-23-pcr-discontinuity-classes.md) |
| T24 | A partial media-plane stall | R8 · corrects T22 | complete | The lane contains the failure, but **TR 101 290 P1 cannot see it**; only per-PID access-unit liveness caught every arm | [test-24](test-24-partial-media-plane-stall.md) |
| T25 | Isolation under abuse | R2/R7 | complete, both lanes | **Both planes isolate the victims' media**; abuse costs the MoQ relay memory through abandoned-session retention, which the idle timeout sets | [test-25](test-25-isolation-under-abuse.md) |
| T26 | Cross-host fan-out and the knee | R2 | complete | The relay's marginal cost is small, constant and linear and relay CPU binds first, on 0.14.15 (quinn); the current build does not reproduce the slope (T43) | [test-26](test-26-cross-host-fanout.md) |
| T27 | The per-PID liveness detector | R8 | complete | The detector survives the distribution path and catches the audio case; its first live run found a real fault | [test-27](test-27-liveness-detector.md) |
| T28 | Failure injection, scored in media lost | 6 · Gate 3 | partial; infrastructure axis not run | **Graded on content, SRT loses less programme than MoQ under all three shapes**, by a margin build and QUIC backend set | [test-28](test-28-failure-injection-matrix.md) |
| T29 | MoQ distributed resilience above the 1+1 pair | 6 · Gate 3 | specified, not run | — | [test-29](test-29-moq-distributed-resilience.md) |
| T30 | Segmented distributed resilience | 6 · Gate 3 | specified, not run | — | [test-30](test-30-segmented-distributed-resilience.md) |
| T31 | Congestion and capacity step ladders | 7 · R4/R5 | partial; latency × contention matrix not run | **MoQ loses picture at every sustained shortfall, including 0.9×**; the segmented lane loses less by falling behind rather than discarding | [test-31](test-31-congestion-capacity-ladders.md) |
| T32 | Would commercial monitoring have caught T22, T24, T27? | R8 | fault-to-telemetry mapping measured; vendor survey not started | The mapping is measured on both lanes; what remains is vendor outreach | [test-32](test-32-observability-survey.md) |
| T33 | Gate 2 preparation: boundary fixtures and harness | 3–4 · **de-risks Gate 2** | run; nine of ten criteria met | Every buildable boundary condition carried with zero continuity errors; the harness is rehearsed with its pass table fixed | [test-33](test-33-gate2-preparation.md) |
| T34 | A real encoder against the continuous-source fence | 2 · Gate 3 | partial; needs the live feed | Grades whether a real encoder triggers the join failure in practice | [test-34](test-34-real-encoder-severity.md) |
| T35 | LEO / Starlink handover impairment | 2 · candidate | specified, not run | — | [test-35](test-35-leo-handover-impairment.md) |
| T36 | Entitlement enforcement | control plane | complete; six of six criteria | The relay admits exactly what a credential names, **before any media is delivered** | [test-36](test-36-entitlement-enforcement.md) |
| T37 | Provisioning and de-provisioning | control plane | complete; criterion 2 failed | **The binding finding is correctness**: three `Cache-Control` forms disable re-checking silently, so a withdrawn grant never takes effect | [test-37](test-37-entitlement-revocation.md) |
| T38 | The affiliate estate | control plane | complete; six of seven criteria | **The key-per-entitlement estate scales**, because the relay reads a key on demand and caches nothing | [test-38](test-38-entitlement-estate.md) |
| T39 | Observability across the administrative boundary | R8 · control plane | Part A passed; Part B blocked on a CLI gap | A client-edge process catches a partial fault no relay-side telemetry can express; nothing shipped can carry it back | [test-39](test-39-cross-boundary-observability.md) |
| T40 | The content-join stall through the SRT chain | 2 · Gate 3 | complete, conclusive | The SRT ingest carries #3533's trigger; on `main` at `9d2a4f6e` the chain is healthy through every join | [test-40](test-40-continuous-join-through-srt.md) |
| T41 | Which TS stream kinds re-anchor below the live edge | 3 · Gate 3 | complete, conclusive | **#3798 has two parts** (no re-anchor; one re-anchor only), so the fix had to be cumulative; fixed on `main` at `9d2a4f6e` | [test-41](test-41-import-reanchor-coverage.md) |
| T42 | A byte-faithful HTTP/3 HLS receiver | 3 · closes P0-e | built and validated | The old receiver reported clean carriage unconditionally; the new one matches `tsp -I hls` hash for hash | [test-42](test-42-h3-receiver-fidelity.md) |
| T43 | Fan-out on the current build | R2 | S1–S3 run; the hour deferred | **T26's model does not transfer to the current build**, and each carried channel is a cost of its own | [test-43](test-43-fanout-current-build.md) |
| T44 | The transmux lane against a calibrated T-STD model | 3 · R3 | complete, conclusive | **The lane's P1/P2-conformant wire is not a conformant transport stream**; a T-STD re-multiplexer repairs it offline | [test-44](test-44-tstd-grading.md) |
| T45 | A live T-STD re-multiplexer behind the lane | 3 · R3, P0-l | questions 1–3 answered; clock recovery and 1+1 not attempted | **A live re-multiplexer makes the wire T-STD-conformant**, at 2.20 s presentation latency on `ffa5b81b` (loopback, one clip, one run) | [test-45](test-45-live-tstd-remux.md) |
| T46 | Two T-STD checks cross-validated | instrument validation · R3 | complete, offline | The two agree on all 35 files on upstream `main`'s merged check; every earlier disagreement traced to upstream's check, since fixed, and `ts-tstd.py`'s own defects are fixed with no verdict moved | [test-46](test-46-tstd-check-cross-validation.md) |
| T47 | The upstream fixed-delay TS export (#4645 `[unmerged]`) | 3 · R3, P0-m | current head graded; scratch fix tested | The head holds the clock but drops audio on most joins; a scratch fix keeps every track, without a latency advantage over the re-multiplexer | [test-47](test-47-fixed-delay-export.md) |

### Pass criteria (agreed in advance)

These are the criteria fixed for T1–T8 before they ran. Later experiments state theirs the same way,
at the top of their own files.

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Met if the source set is clean (0
  CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1. The service layer is now carried in full on this lane, EIT and the wall clock included; what
  remains is *when* the clock is emitted ([T15](test-15-point-to-point-cadence.md) measurement 4).
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
  latency is bounded with defined catch-up behaviour. T6 met the second and third; the first was met
  at a receiver by [T12](test-12-dual-path-handoff.md), for a pair the receiver can merge.
- **T7 — Timing integrity (Gate 2, make-or-break).** A clean **TR 101 290 P1/P2 pass on a real
  hardware IRD, on the live wire (P2), sustained** (≥ 72 h, set by the PCR base's 26.51 h wrap period
  rather than chosen), including ST 2022-7 behaviour under loss, with the T-STD buffer model confirmed
  valid under drift/discontinuity. Until this exists, the grooming design is "structurally sound and
  software-validated," not "proven broadcast-acceptable."
- **T8 — SRT against MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer delivery
  latency is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery
  and delivered-rate curves are within a stated margin and the failure mode is no worse; egress
  quality at least matches (P1); overhead/CPU recorded as economic inputs. **The latency criterion is
  met at a matched buffer only at cushions where neither arm is P1-conformant**
  ([T18](test-18-delivery-latency.md)); the configuration that makes the MoQ lane conformant costs
  far more ([T19](test-19-pcr-grid-verification.md)). The P1 criterion is met in software, not on
  hardware.

### Desk analyses

| Analysis | Purpose | State | File |
|---|---|---|---|
| Always-on cost model (v1) | Price the T9/T8 capacity constants at public list rates: MoQ vs SRT vs MediaConnect vs Cloudflare vs DIY, 1 channel and a transponder's worth, 1+1 | complete, list prices only | [cost-model.md](cost-model.md), rerun with `python3 lab/cost-model.py` |

Every rate is a constant at the top of the script, so re-pricing against a different tariff is a
one-line edit.

## Where the campaign stands, and what is left

What is and is not established is stated once, in [evidence](../docs/evidence.md) §2, and the limits
of the evidence in §4. What is outstanding, what blocks it and in what order to run it is stated
once, in [planned-experiments.md](planned-experiments.md), ranked P0/P1/P2 by what a result could
change. Neither is restated here. The limits that bear on every row of the table above:

- **No hardware.** Gate 2 has never been attempted: nothing in this campaign has been fed to a
  hardware IRD or graded by a hardware analyser.
- **Latency is delivery latency on healthy paths**, not glass to glass, and on the media-aware lane a
  latency figure means nothing without the conformance of the same bytes.
- **The opaque lane has one loopback measurement** on a pinned, now-obsolete draft, against a
  private implementation.
- **The 1+1 result is a software receiver**, and the impairment matrices are mostly one run per
  condition on an emulator.

The programme has two strands: the original asks which of two data planes can be run permanently, at
scale, by an operations team; the second scores against [control-plane.md](../docs/control-plane.md).

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
| Media-aware lane | `moq-dev` `moq` (import/export) + `moq-relay` (public reference implementation) |
| Opaque `m2ts` lane | private `moq_publisher` / `moq_relay` / `moq_subscriber` (draft-14 / MSFTS `m2ts`) |
| CBR/PCR grooming | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0 (`cargo install --git`; the `cbr_file` example for file arms). The live egress adapter was the `moq_egress` example, renamed `ts_egress` at [T16](test-16-grooming-segmented-http.md) and now the crate's `mpegts-pacer` binary; records name whichever they ran against |
| Network impairment | Linux `tc` / `netem` (optionally `tbf`/`htb` for rate); the shaped-bottleneck rigs are described in `INSTRUCTIONS.local.md` |
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
- A result table too large to read inline is committed as CSV in [`results/`](results/) and
  summarised in its per-test file. The rigs are in [`scripts/`](scripts/), named per test; only
  machine-specific values are held out, in `INSTRUCTIONS.local.md`.

### macOS loopback gotchas (local runs)

- **Take CLI flags from [`scripts/moq-cli-flags.sh`](scripts/moq-cli-flags.sh)**, not from memory:
  `moq-dev`'s CLI was migrated, and the GSO, idle-timeout and TLS-fingerprint flags have different
  names either side of it. `scripts/check-rigs.sh` fails the tree on a hard-coded renamed flag.
- Disable UDP GSO on relay and clients, or QUIC handshakes time out on loopback. This understates
  relay CPU by ~29 % ([T26](test-26-cross-host-fanout.md)), so no capacity figure should be quoted
  from a GSO-disabled run.
- Connect over `https://` and pin the relay's certificate fingerprint explicitly; the `http://`
  fingerprint bootstrap is broken in recent builds.
- Pace the input (`tsp … -P regulate`); an unpaced `import` hits stdin EOF and tears the session
  down before the subscriber pulls.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
