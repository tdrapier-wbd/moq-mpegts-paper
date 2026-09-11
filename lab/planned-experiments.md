# What remains to be done

**This file is a register of outstanding work, and nothing else.** Every protocol lives in the
`test-*.md` file that owns it, whether or not that experiment has run; every measurement lives there
too. An entry here is a line naming what is outstanding and where its protocol is written down. When
nothing of an entry is outstanding, the entry is deleted — a to-do list that accumulates its own
history stops being readable as a to-do list.

So this file carries no results, no corrections and no reasoning. Those are in `test-*.md` and
[method-notes.md](method-notes.md).

Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
`INSTRUCTIONS.local.md`.

---

## How this is ranked

**By what a result could change, not by how interesting it is.**

- **P0 — could change a viability conclusion.** If the result comes out one way, a `docs/` conclusion
  changes side or a lane stops being recommendable. Nothing else competes for a run window while a
  P0 is runnable.
- **P1 — establishes where one architecture is superior.** Sharpens or reverses a verdict *row*;
  does not decide viability.
- **P2 — completeness.** Worth having, unlikely to change a conclusion. A P2 that starts looking like
  it could change one has been mis-tiered; move it.

Two standing rules keep this from becoming a wishlist. **An experiment earns a place only if a named
document says something it could falsify**, and that claim is named in its own `test-*.md` file. And
**an entry is deleted once nothing of it is outstanding.**

**The programme has two strands.** The original one asks which of two data planes can be run
permanently, at scale, by an operations team, for years. The second scores against
[Control](../docs/control-plane.md). Its first three entries have now run
([T36](test-36-entitlement-enforcement.md), [T37](test-37-entitlement-revocation.md),
[T38](test-38-entitlement-estate.md)) and between them corrected two of that document's claims, so the
strand is no longer wholly unevidenced — but it remains the thinner half, and what is left of it is
the part that matters commercially: clustering, the integration surface, and rights windows. Tiering
across the two strands is a judgement rather than a derivation.

---

## P0 — could change a viability conclusion

| # | What is outstanding | Protocol | Blocked on |
|---|---|---|---|
| P0-d | Gate 2 preparation: boundary fixtures and the acceptance harness, dry-run before the hardware arrives | [T33](test-33-gate2-preparation.md) | **largely discharged** — Parts A, B and C run; the analyser-specific pass-table rows still need hardware |
| P0-e | A byte-faithful HTTP/3 HLS receiver | *instrument, not an experiment* | us — see below |
| P0-f | Silent media-plane failure, segmented half | [T22](test-22-silent-media-plane-failure.md), [T24](test-24-partial-media-plane-stall.md) | P0-e |
| P0-g | Permanence: the seven-day arm, and the segmented soak | [T21](test-21-permanence-soak.md) | P0-h for the MoQ arm |
| P0-h | Re-soak the importer after the memory fix lands | [T21](test-21-permanence-soak.md) | upstream [#3493](https://github.com/moq-dev/moq/issues/3493) |
| P0-i | `moq export ts` exiting under two-feed contention — instrument the read path and attribute it | [T8b](test-8b-congestion-control.md) | — |
| P0-j | A real never-repeating encoder against the continuous-source fence | [T34](test-34-real-encoder-severity.md) | a live TS source |
| P0-k | Hardware TR 101 290 P1/P2 soak, ≥ 72 h | [T7](test-7-timing-integrity.md) | IRD + analyser loan |
| P0-l | A client certificate is a cross-tenant master key, and the authorization endpoint is not told which certificate was presented | [T38](test-38-entitlement-estate.md) § Open | **discharged** — measured, and reported upstream as [#3603](https://github.com/moq-dev/moq/issues/3603) |

**P0-e is a build task, not an experiment, and it gates three entries.** Nothing in the lab receives
an HTTP/3 HLS stream byte-faithfully; the current receiver re-muxes. Until one exists, the segmented
plane cannot be graded on carriage fidelity and the segmented halves of P0-f, P2-b and
[T32](test-32-observability-survey.md) cannot run.

---

## P1 — establishes where one architecture is superior

| # | What is outstanding | Protocol | Blocked on |
|---|---|---|---|
| P1-a | Failure-injection and recovery, both planes, graded in the media domain | [T28](test-28-failure-injection-matrix.md) | **grader built and validated** (pass criterion 1 discharged); matrix blocked on a **Linux host** for `netem`/`tc`. The infrastructure-axis rows need no emulator and are the cheapest available next step |
| P1-b | MoQ distributed resilience above the egress 1+1 pair | [T29](test-29-moq-distributed-resilience.md) | — |
| P1-c | Segmented-HTTP distributed resilience | [T30](test-30-segmented-distributed-resilience.md) | — |
| P1-d | Congestion and capacity: the step ladders, both planes | [T31](test-31-congestion-capacity-ladders.md) | blocked on a **Linux host**: the rig is two network namespaces joined by a veth. Not re-basable on macOS dummynet without losing comparability with [T8b](test-8b-congestion-control.md) |
| P1-e | MPTS / multiple concurrent services | [T10](test-10-mpts-multiservice.md) | partly B-5 |
| P1-f | The scaling model, segmented half | [T26](test-26-cross-host-fanout.md) | — |
| P1-g | Capped-stream relay memory under pressure | [T9](test-9-performance.md) | — |
| P1-h | Cross-implementation interop, the remaining legs | [T11](test-11-interop.md) | B-2 for T11c |
| P1-i | The three remaining data-plane comparison cells | [T14](test-14-data-plane-comparison.md) | B-4, B-5, hardware |
| P1-j | Three `Cache-Control` configurations under which an entitlement cannot be withdrawn at all | [T37](test-37-entitlement-revocation.md) § Open | **discharged, and it is the binding revocation finding** — a correctness hazard, not a latency one. Filed upstream as [#3605](https://github.com/moq-dev/moq/issues/3605) together with the undocumented 2× revocation window. A third finding measured alongside them — the one-hour default staleness window — is held unfiled by the operator |
| P1-k | Whether a key-per-entitlement estate scales: keys sized by the licensing matrix, not the affiliate count | [T38](test-38-entitlement-estate.md) § Open | — **runnable now**, not started; the T36–T38 rig is the apparatus |
| P1-l | The telemetry return path end to end: a `moq-net` client publishing an opaque or JSON track, closing T39 Part B | [T39](test-39-cross-boundary-observability.md) § Open | — **runnable now**; needs a small client written against the library, since the CLI has no non-media path |

---

## P2 — completeness

| # | What is outstanding | Protocol | Blocked on |
|---|---|---|---|
| P2-a | What commercial monitoring would have caught | [T32](test-32-observability-survey.md) | — |
| P2-b | Isolation under abuse, segmented half | [T25](test-25-isolation-under-abuse.md) | P0-e |
| P2-c | A standby packager joining an already-running feed | [T30](test-30-segmented-distributed-resilience.md) | sits behind P1-c |
| P2-d | Differential delay on a real pair, modelled with `netem` on the cross-AZ path | [T12](test-12-dual-path-handoff.md) | — |
| P2-e | Replicates for the congestion cells, to put an error bar on the quoted aggregate | [T31](test-31-congestion-capacity-ladders.md) | deprioritised behind P1-d |
| P2-f | LEO / Starlink handover impairment — a candidate, not yet committed | [T35](test-35-leo-handover-impairment.md) | — |
| P2-g | Reproduce the transparency and three-lane arms from an office network, for its UDP/QUIC posture | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) | — |

**Remainders inside completed experiments** are recorded in their own files and are not restated
here: [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md),
[T9](test-9-performance.md), [T11](test-11-interop.md), [T12](test-12-dual-path-handoff.md),
[T13](test-13-downstream-grooming.md), [T15](test-15-point-to-point-cadence.md),
[T16](test-16-grooming-segmented-http.md), [T17](test-17-si-snapshot-tracks.md),
[T18](test-18-delivery-latency.md) and [T20](test-20-segmented-http3.md) each carry an open-items
section.

---

## Blocked on apparatus

| # | What it blocks | Waiting on |
|---|---|---|
| B-1 | [T12](test-12-dual-path-handoff.md)'s churn arms — the recovered-leg and late-join cells, and a grader the merge oracle is not yet | upstream [#2779](https://github.com/moq-dev/moq/issues/2779); commenting is the only thing that moves it |
| B-2 | The full interop suite against a `moq2ts` subscriber (T11c) | they publish one. Worth planning the matrix now so the run is ready when it lands |
| B-3 | [T15](test-15-point-to-point-cadence.md)'s residual | a true CBR hardware source; nothing in the lab produces one |
| B-4 | The segmented plane's low-latency arm at equal conformance | a commercial ABR-to-TS gateway — the same apparatus block as P0-k in a different guise |
| B-5 | Multi-programme carriage through a *media-aware* edge | the commercial packaging edge itself. A byte cache serves an unusual TS payload exactly as nginx does, so asking it of a plain cache re-measures nginx |

---

## What to bundle, because prompt count is the scarce resource

Grouped so nothing in a group contaminates anything else in it. Each group is one run.

- **The entitlement follow-ups.** P0-l and P1-j are discharged; **P1-k** still reuses the rig and stub
  authorization endpoint built for [T36](test-36-entitlement-enforcement.md) to
  [T38](test-38-entitlement-estate.md), whose scripts are in [`scripts/`](scripts/). It needs no
  hardware, no live source and no third party, which is what recommends it while the
  apparatus-blocked entries wait.
- **The two-host group.** P1-f's fan-out and P1-c's two-host segment store. Both need both boxes and
  neither can share a host with a timing measurement. Run the fan-out **last**, because it
  deliberately saturates a box.
- **The cheap ladder** *(needs a Linux host — see P1-d)*. P1-d's MoQ half runs in network namespaces against a stopped loop publisher
  and grades on a per-cell aggregate, so it is the right filler for a window whose main item is
  posting, reviewing or building.
- **The long runs.** P0-g's soak and P1-g's memory arm want days rather than minutes, and a soak
  measures the machine it runs on — so neither shares a window, and a segmented origin and a MoQ
  relay must not share a box.
- **The injection matrix.** P1-a and P0-f share a harness: both interrupt a component and grade the
  media that came out. Build the grader once.

**Do not bundle** anything from the blocked list, whose windows are set by apparatus rather than by
us.

---

## Deliberately not doing

Recorded so they are not proposed again. Each was considered and dropped; where a result exists, it
is in the file named.

- **The arrival oracle on a bigger host** — run, and the caveat it existed to retire is retired
  ([T19](test-19-pcr-grid-verification.md)).
- **The clean two-host 1+1 arm, and the full two-publisher two-relay topology** — both run. Remaining
  multi-track identity is an upstream fix, not another cell here
  ([T12](test-12-dual-path-handoff.md), [#2829](https://github.com/moq-dev/moq/issues/2829)).
- **The congestion cells under an AQM** — run, and it falsified the prediction it was meant to test
  rather than leaving it open. Do not re-run it as a rescue ([T8b](test-8b-congestion-control.md)).
- **Hunting a lower-layer mechanism for the shed** — the sweep discriminated; there is nothing left
  for a shared-lane mechanism to explain ([T8b](test-8b-congestion-control.md)).
- **More transparency clips through lanes already characterised** across a 2.75× bitrate spread.
- **The wire-cost leg on the EC2 path**, whose HTTP-layer term is path-independent and whose framing
  multiplier is measured elsewhere; and per-track wire-byte attribution.
- **The segmented HTTP/3 arm** — run, and both the original motivation and its successor are
  answered ([T20](test-20-segmented-http3.md)). What survives is P0-e, an instrument gap rather than
  an open question.
