# Test 33 — Gate 2 preparation: boundary fixtures and the acceptance harness

**State: specified, not run.** Gate 2 ([T7](test-7-timing-integrity.md) P2) waits on a hardware IRD and
TR 101 290 analyser on loan, but **most of this preparation work runs now** on software instruments the
lab already has. Boundary fixtures and self-tests exist in [`lab/scripts/`](scripts/); what remains is
feeding them through a MoQ round trip and the groomer, rehearsing the acceptance harness against the
software reference receiver, and standing up the real-source capture rig. It has not run because the
campaign prioritised measured lanes over dry-runs; nothing here is blocked on the hardware loan.

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

**What has never run is the pipeline half.** A fixture passing the analyser says nothing about MoQ
import/export and `mpegts-pacer`; items 1–4 below rest on **MoQ round trip + groomer dry-run**, which
is the outstanding work and is **runnable today**.

**PMT version increment remains unbuilt** in the fixture generator (PSI condition, not PCR-only).

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

## Why this has not run

No apparatus blocker: fixtures, self-tests, MoQ binaries, and groomer exist. The campaign paid a small
version of the cost [T19](test-19-pcr-grid-verification.md) describes — an untested precondition surfacing
on the hardware window — and specified this work to avoid repeating it at Gate 2 scale. Scheduling
 favoured measured experiments over dry-runs; an afternoon per Part A condition and one scripted day for
Part B is the estimated cost stated in the planning record.
