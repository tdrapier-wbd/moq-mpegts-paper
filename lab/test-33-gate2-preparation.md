# Test 33 — Gate 2 preparation: boundary fixtures and the acceptance harness

**State: run, 2026-09-11. Parts A, B and C complete except one arm; nine of ten pass criteria met, one
partially.** The lane carried every boundary condition that could be built — a placed 33-bit PCR wrap,
a signalled discontinuity, a PMT version increment and source-clock offsets to 20,000 ppm — with **zero
continuity errors on every capture of every arm**, and the acceptance harness has been rehearsed
end to end against the software reference with its pass table fixed in a file before the first subject
ran.

**The preparation found its first untested precondition immediately, which is what it was for.** The
boundary fixtures could not reach the pipeline at all: they carry no PAT or PMT, so `moq import ts`
resolves no tracks and publishes nothing, and even once PSI is added `moq export ts` refuses a stream
of verbatim tracks outright — *"TS export requires a video or audio track for the PCR"*. The conditions
had to be re-expressed against real coded video before any of Part A could run. Had that been
discovered during the hardware window it would have cost the window.

Gate 2 itself ([T7](test-7-timing-integrity.md) P2) still waits on the IRD and analyser loan. Nothing
below needed them.

Source: [P0-d](planned-experiments.md#p0--could-change-a-viability-conclusion) (parts A–C).

## Objective

Convert Gate 2 boundary questions from **hardware-day unknowns** into **software-day confirmations**, so
when the analyser and IRD arrive the window is spent on receiver behaviour rather than discovering an
untested precondition in the pipeline ([T19](test-19-pcr-grid-verification.md) found the groomer assumed
PCR value and byte position advance together — nothing exposed it until upstream changed).

Three deliverables:

- **Part A** — synthesised PCR/PSI boundary stimuli through MoQ + groomer, graded at P1.
- **Part B** — scripted acceptance harness dry-run against the software reference receiver.
- **Part C** — real-source capture rig and honest substitution map for what still needs a live encoder.

## What is already known, and precisely what it leaves open

**Steady-state conformance is measured at length on file.** [T19](test-19-pcr-grid-verification.md) and
[T21](test-21-permanence-soak.md) established P1 wire behaviour over 300 s and 24 h on a continuous
timeline; Gate 2's value is in **boundaries** the steady state does not exercise.

**Fixture generation and analyser self-test are built.** [`ts-pcr-fixtures.py`](scripts/ts-pcr-fixtures.py)
generates every Part A condition; [`ts-pcr-selftest.py`](scripts/ts-pcr-selftest.py) asserts the verdict
each must produce on the analyser-side instrument, turning accept/reject behaviour into a tested
quantity — which already found two analyser defects on conforming input. The wrap in item 1 is **placed
400 ms into a fixture** rather than waited for ([method-notes](method-notes.md) §3: 72 h soak arithmetic
versus placed wrap).

**Those fixtures grade an analyser and cannot be carried by a pipeline**, which is the first thing this
experiment established and is described under *Part A* below. The conditions now exist in two forms:
the original synthetic stimuli for the analyser, and
[`t33-inject-condition.py`](scripts/t33-inject-condition.py), which applies the same conditions to real
coded video so the lane will accept them.

**PMT version increment is now built**, as a condition of the injector rather than of the synthetic
generator.

## Environment

| | |
|---|---|
| Fixtures | [`ts-pcr-fixtures.py`](scripts/ts-pcr-fixtures.py): `wrap`, `discontinuity`, `pid-change`; PMT version increment TBM. |
| Self-test | [`ts-pcr-selftest.py`](scripts/ts-pcr-selftest.py) on analyser-side captures before pipeline runs. |
| MoQ lane | Media-aware path: `moq import ts` → relay → `moq export ts` → [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer); loopback or `<EC2_IP>` per arm. |
| Grading | TSDuck P1: `continuity`, `pcrverify`, `pcrextract`, `analyze`, PAT/PMT plugins; `compliance.py` from the upstream `test/ts` tree where used for T7 file arms. |
| Reference receiver | Software reference from [T12](test-12-dual-path-handoff.md) / campaign harness — stand-in for IRD until hardware. |
| Real-source rig (Part C) | Capture at source ingress; same TSDuck instruments; grade source **before** it becomes an input. |
| Hardware | **Not required** for Parts A and B. Part C benefits from a live encoder but lists substitutable stimuli. |

## Part A — Boundary-condition fixtures, and the groomer dry-run against them

### Procedure

Run each fixture **through MoQ round trip + groomer** and grade at P1. Precede each with
`ts-pcr-selftest.py` on the raw fixture file. In leverage order:

1. **PCR 33-bit wrap, placed.** Base clock wraps every **26.51 h** ([method-notes](method-notes.md) §3);
   `ts-pcr-fixtures.py wrap` starts 20 slots below the boundary and crosses 400 ms in. `mpegts-pacer`
   unit-tests modular arithmetic (`Slot::slots_per_wrap`, `forward_delta_handles_wrap`); **what is proven
   is arithmetic, not the pipeline** through scheduler run-closing, discontinuity threshold, and the
   importer's timeline. Feeding the fixture to the groomer after MoQ is the outstanding step.

2. **Source-clock drift via mis-rated replay.** The pacer locks output rate and cushion once from a
   two-PCR warmup ([`pacer.rs`](https://github.com/tdrapier-wbd/mpegts-pacer)); every long run paced
   on the same host never met a source whose clock differed from the sink's. ISO 13818-1 permits **±30
   ppm** on 27 MHz (2.6 s offset per day). Substitute: replay at nominal × (1 ± 30 ppm) with
   `tsp -P regulate`; sample **buffer occupancy and derived latency**, not throughput alone. Margin
   should hold arithmetically; registering the prediction before the run is the point.

3. **Signalled discontinuity.** Campaign carried only the loop wrap's *unsignalled* splice
   ([T23](test-23-pcr-discontinuity-classes.md)). `ts-pcr-fixtures.py discontinuity` supplies a flagged
   splice; the fixture already caught analyser false rejects on legal signalled splices.

4. **Mid-stream PID change, PCR-PID change, PMT version increment.** `ts-pcr-fixtures.py pid-change`
   moves PCR to a second PID; PMT version increment still to be added to the generator. Exercises
   importer track model and groomer; exporter has logged "TS track layout changed after PAT/PMT was
   emitted" mid-run in prior work.

A failure in any arm is **our defect** if it fails before MoQ; if it fails only after MoQ, classify
upstream versus groomer before the hardware window ([upstream-contributions.md](upstream-contributions.md)
for filing latency).

### Metrics (Part A)

Per fixture: continuity errors; PCR interval stats; `pcrverify` violations; discontinuity indicator
honoured; PID/PMT consistency; groomer buffer occupancy and underrun count through the event; MoQ
session survival.

### The fixtures cannot reach the pipeline, and finding out cost one probe

The synthetic fixtures are one PID of filler payload with **no PAT and no PMT**. `moq import ts` builds
its catalog from PSI, so given a fixture it resolves no tracks, drops the catalog producer and **exits
zero having published nothing** — a silent no-op, not an error.

Adding PSI is not enough. [`t33-service-fixture.py`](scripts/t33-service-fixture.py) wraps a fixture in
a PAT and PMT declaring its elementary stream as private PES, which gets a track published; the
exporter then refuses the round trip outright:

```
Error: TS export requires a video or audio track for the PCR
```

A stream of verbatim tracks carries no media timeline for the exporter to anchor PCR to, so no amount
of PSI makes a filler fixture round-trip. **The conditions have to be applied to a stream carrying real
coded video**, which is what [`t33-inject-condition.py`](scripts/t33-inject-condition.py) does.

That change is not a workaround, and it moves what the arm measures. The media-aware lane **regenerates**
PCR from the media timeline rather than passing source PCR through, so the question a boundary arm can
answer is not whether a PCR value survives — it does not, by design — but whether the *timeline
arithmetic* survives the boundary. The injector therefore rebases PCR together with PTS and DTS, so the
whole timeline crosses the 33-bit boundary as a real source's does after 26.51 h of uptime.

### Part A results

Source: the first 26,596 packets of `~/t12_vidonly.ts` — 20 s of 2.000 Mbps CBR, AVC on PID 0x0100,
PMT 0x1000, graded clean before use. Lane: `moq import ts` → relay → `moq export ts` → `mpegts-pacer`,
all on loopback, `moq` 0.11.0-`fd4f5d82e` and groomer `5ab84cd`. **Domain: file. Measurement point: P1.**
Three captures per arm, so a failure can be attributed rather than argued about: the source, the
exporter's own output with no groomer in the path, and the groomed egress.

The continuity counter is matched on the plugin's *data* (`missing N packets`), and
[`t33-grade.py --selftest`](scripts/t33-grade.py) was shown reading both ways — 0 events on a clean
capture, 3 events and 8 packets on one with 40 packets excised — before any zero below was recorded.

| Arm | Condition | Continuity, all three captures | PCR intervals at groomed egress | Verdict |
|---|---|---|---|---|
| A0 | control, clean, nominal rate | 0 events | min 0.75 / mean 21.41 / max 30.08 ms, 0 over 40 ms | pass |
| A1 | 33-bit PCR wrap, placed 5 s in | 0 events | min 0.75 / mean 21.52 / max 30.08 ms, 0 over 40 ms | pass |
| A2a | source clock +30 ppm | 0 events | min 0.75 / mean 22.06 / max 30.08 ms, 0 over 40 ms | pass |
| A2b | source clock −30 ppm | 0 events | min 1.50 / mean 22.04 / max 30.08 ms, 0 over 40 ms | pass |
| A3 | signalled discontinuity, +500 ms | 0 events | min 1.50 / mean 21.75 / max 30.08 ms, 0 over 40 ms | pass |
| A4 | PMT version increment | 0 events | min 1.50 / mean 22.00 / max 30.08 ms, 0 over 40 ms | pass |

**The wrap crosses the whole lane.** The boundary is present exactly once in the source, once in the
exporter's output and once at groomed egress, with no continuity error, no interval past the repetition
limit and no backwards step anywhere. The importer's timeline arithmetic, the exporter's PCR
regeneration and the groomer's slot arithmetic all carry it.

**A signalled discontinuity survives as signalling and not as a clock jump.** Exactly one packet carries
`discontinuity_indicator` at the source, at the exporter and at groomed egress — and none does in the
control, so the check discriminates. The 500 ms jump itself behaves differently at each stage: 519.55 ms
at the source, **amplified to 1500.00 ms at the exporter**, and absorbed entirely by the groomer, whose
worst interval is 30.08 ms. A groomer regenerating PCR against output byte position necessarily emits
its own continuous clock; what matters operationally is that it does so **without discarding the flag**,
so a downstream decoder is still told a splice happened.

**An exporter figure is not a lane figure, and the gap is three orders of magnitude.** The exporter's
PCR sits on an exact 25.00 ms grid — min, mean and max all 25.00 — and **every one of its samples fails
the 481 ns TR 101 290 accuracy gate** (790 of 790 on the control arm; 753 of 790 fail even the 1000×
looser 500 µs pre-check). The groomer's output passes both on every arm (0 of 927). This restates
[T13](test-13-downstream-grooming.md) and [T19](test-19-pcr-grid-verification.md) rather than adding to
them, and it is repeated here because a Gate 2 rig that captures at the wrong point would report the
lane as grossly non-conformant.

**`pid-change` did not run**, and is the one arm outstanding. The synthetic version cannot reach the
pipeline for the reason above, and moving the PCR to a second PID inside real coded video means
synthesising a second elementary stream rather than editing an existing one. It is the only Part A
condition that needs apparatus that does not exist.

### Part A item 2: the drift criterion could not be graded as written, and was replaced

**At ±30 ppm the criterion cannot reach its own failure mode.** A 30 ppm offset moves a buffer by 30 µs
per second, so against the 1000 ms cushion the rail is 1000/30×10⁻⁶ ≈ **9.3 hours** away, and the
30-minute run the criterion asks for sees 54 ms of movement — indistinguishable from the burstiness the
arrival process already has. A run that cannot reach the condition it is testing returns a null whatever
the mechanism does.

So the mechanism was measured instead, across a ladder wide enough for a slope to resolve
([`t33-drift-ladder.sh`](scripts/t33-drift-ladder.sh)): 115 s per arm on the full 120 s clip, the
groomer emitting at the nominal rate with `--stats-interval-ms 1000`, the publisher mis-rated.

| Imposed offset | Cushion high-water | Stuffing | Underruns | Fitted occupancy slope | r² |
|---|---|---|---|---|---|
| 0 ppm | 1808 packets | 5.4 % | 5 | 2.09 pkt/s | 0.36 |
| +1,000 ppm | 1812 | 5.4 % | 4 | 2.14 | 0.36 |
| +5,000 ppm | 1813 | 5.4 % | 0 | 2.22 | 0.37 |
| +20,000 ppm | 1816 | 5.4 % | 6 | 2.02 | 0.31 |

**No drift signal, over a 667× range of imposed offset.** High-water spans 0.4 % across the ladder,
stuffing is identical, underruns show no trend, and the fitted slope is the same ~2.1 packets/s at every
arm **including 0 ppm** — so that slope is the priming-to-steady-state ramp and cannot be drift. For
reference the offsets the ladder predicts are 0, 1.26, 6.28 and 25.10 packets/s against a measured media
rate of 1255.2 packets/s; none of them appears.

**The mis-rating did take effect**, which a separate control establishes rather than assumes: replaying
30,000 packets at `--bitrate 2000000` and `--bitrate 2040000` measured 1,990,685 b/s and 2,032,398 b/s,
a ratio of 1.0210 against an imposed 1.02. So the null is a property of the lane, not of the stimulus.

**What this does and does not establish.** It establishes that the groomer's cushion stays bounded and
does not walk to its rail, at offsets three orders of magnitude beyond the ISO 13818-1 ±30 ppm limit —
which is what criterion 3 asks. It does **not** establish where the surplus goes. The groomer reads its
input on demand, so a fast source's excess can accumulate upstream of it — in the pipe, the exporter or
the relay — where this instrument cannot see it. **Buffer occupancy at the groomer is therefore not a
drift detector**, which matters for §9's monitoring design as much as for this arm, and attributing the
surplus needs the upstream buffers instrumented. That is recorded under *Open*.

## Part B — The acceptance harness, dry-run against the software reference receiver

### Procedure

Fix measurement set, run order, and capture format **before** the analyser ships. Rehearse against the
software reference receiver; the rehearsal validates the **rig**, not Gate 2 pass/fail.

- **Control before every subject, pre-scripted.** Feed the source clip straight from disk through
  `rawsendmpeg2ts` before any MoQ lane touches it. Clip is measured conformant; if the reference flags
  it, the rig is wrong and nothing downstream is interpretable — must be scripted, not improvised on
  the day.
- **Machine-readable capture, decided in advance.** Whatever the analyser offers — CSV, syslog, SNMP —
  one path logged to file. A 72 h soak read from a GUI is not a measurement ([method-notes](method-notes.md)).
  Confirm export path on the specific model **before it ships**; this detail cannot be worked around on
  site.
- **Time budget, soak first.** Soak is the long pole (≥ 72 h — PCR base wraps at 26.51 h); boundary
  drills from Part A are short and attended. If the analyser has two inputs, interleave; if one input,
  drills follow soak — decide order before the window opens.
- **Named pass definition.** P1 and P2 sub-error by sub-error, plus PLL lock state and buffer-model
  verdict (analyser-specific, not TR 101 290 proper). A gate fixed after seeing output is not a gate.

Dry-run: execute the script against the software reference with a **short** soak (e.g. 2 h) to verify
capture plumbing, control ordering, and pass/fail automation — not to claim hardware acceptance.

### Metrics (Part B)

Harness checklist completion; control pass before each subject; capture file non-empty and parseable;
clock sync between capture and TS egress timestamps; script runtime without manual intervention.

### Part B results

The harness is [`t33-acceptance.sh`](scripts/t33-acceptance.sh), and the pass definition it enforces is
[`t33-pass-table.json`](scripts/t33-pass-table.json) — **6 TR 101 290 P1 sub-errors, 8 P2, and 4
analyser-specific fields**, the last kept in their own block so that a PLL lock state or a T-STD buffer
verdict is never quoted as conformance. Each entry carries a `measurable_in_software` flag, so the list
of things that will happen for the first time on hardware day is explicit in advance rather than
discovered on it. The harness reads the table from the file; it does not assemble one from what a run
produced.

The rehearsal ran 13 graded arms unattended in 4m26s: a control, then `wrap`, `discontinuity` and
`pmt-version` as subjects with a control re-check after each, then a soak, each subject graded at both
the exporter and the groomed egress, all of it into one `results.csv`.

**Both halves of the control gate were exercised, not just the passing half.** Run normally the control
passes and the subjects proceed. Run with a deliberately damaged clip as the control, the harness
aborts before any subject starts — one row in `results.csv`, the failed control, and a non-zero exit.
A gate that has only ever returned "clean" has not been shown to work
([method-notes](method-notes.md) §1).

**The rehearsal found a defect in the harness, which is what a rehearsal is for.** The first pass
scored the `discontinuity` subject FAIL at the exporter on a PCR interval past the 40 ms repetition
limit. That interval is the injected splice, and ISO 13818-1 2.4.3.4 permits the clock to jump in a
packet carrying `discontinuity_indicator` — so the gate was failing a conforming stream, exactly the
class of defect the analyser self-test was built to catch on the other instrument. The gate now
discounts intervals against the count of signalled packets, and the arm passes while an *unsignalled*
gap of the same size still fails. Its limitation is stated where it sits: it discounts by count rather
than pairing each interval to its own flag, which is sound while a capture carries few signalled
events and would not be on a splice-heavy feed.

With that corrected, **13 of 13 arms pass**.

The rehearsal is a rig validation and the harness says so in its own output: the receiver is software,
so no PLL lock state and no buffer-model verdict exists; every figure is P1 on a file; and the soak ran
240 s against the 72 h the hardware protocol requires, so the 26.51 h PCR base wrap was not crossed by
waiting — Part A crosses it by placement instead.

## Part C — The real-source rig, and what can honestly be substituted

### Procedure

Every campaign figure today comes from a looped file. Separate what a real encoder changes from what
merely looks different:

| Need | Substitutable now (Part A) | Substitutable other | Not substitutable |
|---|---|---|---|
| Free-running clock drift | Mis-rated replay ±30 ppm | — | — |
| Signalled discontinuity | `ts-pcr-fixtures.py discontinuity` | — | — |
| 33-bit wrap | Placed wrap fixture | — | — |
| Loop wrap splice artefact | Long single-pass replay of long clip | Removes rig artefact | — |
| Encoder PCR floor | — | — | Particular encoder's PCR conformance |
| Scene-driven CBR variation | — | — | Genuine rate variation within CBR |
| Event-driven SI | — | — | SI changing because something happened |

Stand up: capture point at source ingress, same instruments pointed at it, **source conformance graded
before use as input** — so the first real-feed result is not a lane verdict on an ungraded source.

### Metrics (Part C)

Source-side P1 grade before MoQ ingress; delta versus looped-file baseline on PCR interval distribution
and SI change rate when live feed becomes available.

### Part C results

The gate is [`t33-source-gate.sh`](scripts/t33-source-gate.sh), and it **exits non-zero** rather than
reporting: a source that fails it cannot be published by a script that checks the status. It grades
sync, `transport_error_indicator`, continuity, service presence, PCR presence, PCR PID count and the
repetition limit — the last discounting signalled discontinuities, so a legal splice in a live feed
does not reject the feed.

Validated in both directions before use: the campaign clip passes on all seven checks (157,847 packets,
2,000,000 b/s, 1 service, 5,990 PCR on one PID, intervals 0.75 / 19.82 / 21.81 ms), and the deliberately
damaged capture fails on two of them — continuity, and one unsignalled interval of 140 ms — with exit
status 1.

**Service presence is in the gate because of what Part A found.** A source with no PMT is not merely
unconformant, it is un-importable in a way that produces no error at all: the importer resolves no
tracks and exits zero. Catching that at the source is cheaper than debugging a silent no-op publish.

The capture chain is documented in the script's own header with `<SOURCE_INGEST>` as the only
machine-specific element. The substitution table above is committed. What remains unsubstitutable is
unchanged: a particular encoder's PCR conformance, genuine scene-driven rate variation within CBR, and
SI that changes because something happened.

## Pass criteria, fixed before running

**Part A — pipeline dry-run**

1. Each of wrap, ±30 ppm drift, signalled discontinuity, and pid-change: **0 continuity errors** at
   groomed P1 egress after MoQ round trip, unless the fixture is designed to expect a flagged
   discontinuity — then the flag and PCR behaviour match ISO 13818-1 intent.
2. Wrap: no backwards PCR step at egress; pacer slot index monotonic across boundary (grade with
   `pcrextract` + interval script from [lab README](README.md)).
3. Drift: buffer occupancy remains bounded over ≥ 30 min at ±30 ppm without underrun storm; no
   monotonic walk to rail ([T21](test-21-permanence-soak.md) method lesson on transient versus trend).
4. Any failure **only on MoQ path** is bisected (file → groomer-only → full lane) before hardware week.

**Part B — harness rehearsal**

1. Control-before-subject runs unattended and aborts the session if control fails.
2. Capture export produces a machine-readable file for every scripted subject arm in the dry-run.
3. Pass/fail script agrees with manual TSDuck grade on a 2 h rehearsal soak.
4. Written pass table covers every P1/P2 sub-error the hardware protocol will use, plus PLL and
   buffer-model fields, **fixed before first hardware run**.

**Part C — real-source rig**

1. Capture chain documented with placeholders only (`<SOURCE_INGEST>`).
2. Source conformance checklist runs automatically on any new capture before MoQ publish.
3. Substitution table (above) committed so hardware week does not conflate loop artefacts with encoder
   behaviour.

## Limits, stated in advance

- **Software reference ≠ hardware IRD.** Part B proves the harness; PLL and buffer-model verdicts on
  hardware may differ — that is what Gate 2 measures.
- **Part A is P1.** File PCR accuracy is arithmetic, not wire timing ([lab README](README.md) measurement
  points); hardware confirms P2 only after loan.
- **PMT version fixture missing** until generator extended; pid-change alone does not close PSI mid-stream
  edits.
- **Part C live encoder** improves fidelity but is not required to complete Parts A and B — the point of
  this file is that **A and B are not blocked on the loan**.

## Verdict against the pass criteria

| # | Criterion | Verdict |
|---|---|---|
| A1 | 0 continuity errors at groomed P1 egress after MoQ round trip, per condition | **met** on five of six conditions; `pid-change` not run |
| A2 | Wrap: no backwards PCR step at egress, slot index monotonic across the boundary | **met** — the boundary appears once in each of the three captures, with no continuity error and no interval past the limit |
| A3 | Drift: occupancy bounded over ≥ 30 min at ±30 ppm without an underrun storm | **met, by a substituted method.** The criterion as written cannot reach its failure mode in 30 min; a ladder to 20,000 ppm found no occupancy signal at all |
| A4 | Any MoQ-path-only failure bisected before hardware week | **not triggered** — no arm failed at any capture point |
| B1 | Control before subject runs unattended and aborts the session on control failure | **met**, and exercised in both directions |
| B2 | Machine-readable capture for every scripted subject arm | **met** — one `results.csv`, 13 rows, no arm without one |
| B3 | Pass/fail script agrees with a manual TSDuck grade on a 2 h rehearsal soak | **partially met.** Agreement confirmed arm by arm against a manual grade; the soak ran 240 s, not 2 h |
| B4 | Written pass table covering every P1/P2 sub-error plus PLL and buffer-model fields, fixed before the first hardware run | **met** — 6 P1, 8 P2, 4 analyser-specific, in a file the harness reads |
| C1 | Capture chain documented with placeholders only | **met** |
| C2 | Source conformance runs automatically on any new capture before MoQ publish | **met** — and it exits non-zero, so a caller that checks the status cannot proceed past a bad source |
| C3 | Substitution table committed | **met** |

**What the hardware window still has to do**, unchanged by any of this: every P2 figure, the PLL lock
state, the T-STD buffer-model verdict, and a ≥ 72 h soak that crosses a real 26.51 h wrap rather than a
placed one. The value of the preparation is that those are now the *only* things left to discover on
the day.

## Corrections

**Believed: the boundary fixtures were ready to feed through the lane.** They are not, and nothing in
the file domain could have revealed it — they grade perfectly on the analyser. `moq import ts` needs
PAT/PMT to publish anything, and `moq export ts` needs a video or audio track to anchor PCR to, so a
synthetic fixture of filler payload cannot round-trip however well-formed its PSI is. **Method rule: a
stimulus built for an analyser is not thereby an input for a pipeline, and which one it is has to be
established by feeding it to the pipeline, not by grading it.**

**Believed: a drift soak would grade the drift criterion.** It cannot. At ±30 ppm against a 1 s cushion
the rail is 9.3 hours away, so any run short of that returns a null regardless of the mechanism.
**Method rule: before running a soak, divide the cushion by the imposed rate of change; if the quotient
is longer than the run, the run cannot fail and is not a test.**

**Believed: a PCR interval past the repetition limit is an error.** Only an unsignalled one is. The
first pass of the acceptance harness failed a conforming signalled splice — the same defect class the
analyser self-test exists to prevent, reintroduced in a second instrument written later.

## Open

- **`pid-change` has not run**, and needs a second elementary stream synthesised inside real coded
  video. It is the only Part A condition still outstanding.
- **Where a fast source's surplus accumulates is unattributed.** The groomer reads on demand, so its
  cushion is blind to source-clock drift; the excess is somewhere upstream — pipe, exporter or relay —
  and nothing here instruments those. This bears on [T21](test-21-permanence-soak.md)'s memory question
  and on the monitoring design, not only on this arm.
- **The harness soak is 240 s against a 2 h criterion and a 72 h hardware protocol.** The rig is
  validated; the duration is not.
- **The corrected discontinuity gate discounts by count rather than pairing each interval to its own
  flag.** Sound while signalled events are rare, unsound on a splice-heavy feed.
- **The analyser's machine-readable export path is still unconfirmed** for a specific model, and that
  is the one Part B item that cannot be worked around on site.
