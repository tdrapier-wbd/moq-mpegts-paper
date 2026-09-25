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

## The shape of what is left

Two facts organise almost everything below, and both are worth reading before the tables.

**The segmented lane was the single largest gap; the instrument is built and the gap has largely
closed.** Until [T42](test-42-h3-receiver-fidelity.md) nothing in the lab received an HTTP/3 HLS
stream byte-faithfully, so the segmented plane could not be graded on carriage fidelity at all. That
was **P0-e**, and it is closed — [`hls-verbatim-recv.py`](scripts/hls-verbatim-recv.py) reproduces
the origin's bytes exactly over both substrates. **P0-f and P2-b have since been run and closed on
the segmented lane**, and P2-a's segmented half proves never to have been apparatus-blocked at all:
it is vendor outreach, and the entry that listed it against P0-e was wrong.

The instrument also forced re-measurement, and every cell it has reached has moved in the segmented
lane's favour. T20's clean-baseline PCR figures for the HLS arms were the old receiver's, and the
wire is **conformant** where the receiver reported 95 % of intervals out of gate; **T20's impairment
cells have since been re-run through it** and two of them were receiver artefacts as well. **Any
segmented carriage figure taken before T42 needs re-measuring, not re-qualifying.**

What remains on this lane has narrowed. **P1-d's segmented ladders are run** in both rigs: the T28
impairment shapes and the T31 capacity rungs in T20's loopback/`netem` rig, and the capacity rungs and
a 5 s outage in the `netns`/`cake` rig the MoQ and SRT arms used, with its own HTTP/3 origin inside the
publisher namespace ([`t31-seg-netns.sh`](scripts/t31-seg-netns.sh)). The capacity ranking is drawable
there and holds, though not at equal latency. The segmented lane's 30 s outage and loss cells in that
rig were void under the receiver's default truncation policy and are queued with truncation recorded
as a hole. P1-a's and P1-c's segmented halves have not been run.

**Most of the rest waits on apparatus that is arriving.** A live feed, a professional DVB analyser and
a bank of IRDs are expected together; between them they discharge P0-j, P0-k, P0-d, P1-i, P2-d and
possibly B-3. See *Two of these blocks are being lifted* below for what each becomes.

---

## P0 — could change a viability conclusion

The **MoQ** and **Segmented** columns say what each lane still needs; `—` means the lane is not in
scope for that entry.

| # | What is outstanding | MoQ | Segmented | Protocol | Blocked on |
|---|---|---|---|---|---|
| P0-e | A byte-faithful HTTP/3 HLS receiver — **the instrument three other entries waited on** | — | **built and validated** | [T42](test-42-h3-receiver-fidelity.md) | **closed** |
| P0-f | Silent media-plane failure | run | **run** | [T22](test-22-silent-media-plane-failure.md), [T24](test-24-partial-media-plane-stall.md) | **closed.** Both lanes are silent; the segmented lane's playlist is the one application-layer signal that moves |
| P0-g | Permanence: the seven-day arm, and the segmented soak | 24 h run; 7 d owed | not run | [T21](test-21-permanence-soak.md) | P0-h for the MoQ arm |
| P0-h | Re-soak the importer after the memory fix lands | owed | — | [T21](test-21-permanence-soak.md) | [#3493](https://github.com/moq-dev/moq/issues/3493) closed in `5d0991b9`, but both 2 h checks are invalidated by [#3798](https://github.com/moq-dev/moq/issues/3798); blocked until the import re-anchor lands. **#3798 was closed as completed on 2026-09-23 by a planning PR that changed no code, and re-measured live on `ffa5b81b`** — the closure is not an unblock ([T41](test-41-import-reanchor-coverage.md)) |
| P0-j | A real never-repeating encoder against the continuous-source fence | SRT+recording arm run | — | [T34](test-34-real-encoder-severity.md) | the live feed; export comparison also blocked on the import re-anchor |
| P0-k | Hardware TR 101 290 P1/P2 soak, ≥ 72 h — **the make-or-break gate** | ready | ready | [T7](test-7-timing-integrity.md) | **being lifted** — analyser and IRD bank expected |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Parts A–C run | Parts A–C run | [T33](test-33-gate2-preparation.md) | same hardware as P0-k |

---

## P1 — establishes where one architecture is superior

| # | What is outstanding | MoQ | Segmented | Protocol | Blocked on |
|---|---|---|---|---|---|
| P1-a | Failure-injection and recovery, graded in the media domain | **run** across three impairment shapes (outage, sustained loss, reorder), MoQ and SRT matched on measured latency | **not run — no ranking without it** | [T28](test-28-failure-injection-matrix.md) | nothing — it can be run now. Also outstanding on the MoQ side: the infrastructure axis, and replicates of the latency-budget cells |
| P1-d | Congestion and capacity: the step ladders | **run** in `netns`/`cake`, rungs re-based on multiples of stream rate | **run** in T20's loopback/`netem` rig | [T31](test-31-congestion-capacity-ladders.md) | nothing. Both ladders are content-graded; the MoQ lane sheds at every sustained shortfall. The like-for-like — the segmented ladder inside the namespace, with its own origin there — is run (`t31-seg-netns.sh`): the ranking holds and the segmented lane sheds at chronic 0.8× there too; its 30 s outage and loss cells are run with truncation recorded as a hole. The boundary rungs are run: the MoQ lane is clean at 1.1× and sheds at 1.0× and below, and the segmented lane sheds from 0.8× down in that rig. Still outstanding: the latency-max × contention matrix; buffer instrumentation |
| P1-b | Distributed resilience above the egress 1+1 pair | not run | — | [T29](test-29-moq-distributed-resilience.md) | — |
| P1-c | Distributed resilience: two-host segment store, edge and origin failure | — | not run | [T30](test-30-segmented-distributed-resilience.md) | — |
| P1-f | The scaling model | **re-run on the current build** ([T43](test-43-fanout-current-build.md)): slope, channel count and a two-tier cluster run; T26's model describes a deleted quinn build. Outstanding: the GSO-off control, the ceiling past N = 100, the origin on its own host, and the hour at N = 100 | not run | [T26](test-26-cross-host-fanout.md), [T43](test-43-fanout-current-build.md) | the hour needs a subscriber host that holds 100 exporters, and a source with no lap while [#3798](https://github.com/moq-dev/moq/issues/3798) is unfixed (`ts-testsrc-live.sh`); the ceiling needs a second subscriber host |
| P1-i | The three remaining data-plane comparison cells | run | not run | [T14](test-14-data-plane-comparison.md) | B-4, B-5, hardware |
| P1-o | **Does a corrected byte schedule make the groomer's deterministic mode work?** The one experiment that would let the pacer be retired for 1+1 | blocked | — | [T13](test-13-downstream-grooming.md) § *The head-to-head*, property 3 | **upstream, and measured rather than assumed**: `Clocking::Stream` needs the source's PCR byte positions to track its values, and against the exporter the divergence is 5,762 packets (871 ms), identical across two cells, with a 1,500 ms cushion still leaving 93 % stuffing. Re-run when [#3925](https://github.com/moq-dev/moq/issues/3925) lands; the rig and both graders exist. **#3925 was closed as completed on 2026-09-23 by a planning PR and the schedule is unchanged on `ffa5b81b`** — median PCR byte gap 1,316 B against a 31,124 B nominal, 3.8 % of intervals within 1 %, so this stays blocked |
| P1-e | MPTS / multiple concurrent services | not run | not run | [T10](test-10-mpts-multiservice.md) | partly B-5 |
| P1-g | Capped-stream relay memory under pressure | not run | — | [T9](test-9-performance.md) | — |
| P1-h | Cross-implementation interop, the remaining legs | partial | — | [T11](test-11-interop.md) | B-2 for T11c |
| P1-k | The `--auth-api` half of the entitlement estate: a real endpoint serving a licensing matrix, rather than the stub that drove every run from T36 to T38 | not run | — | [T38](test-38-entitlement-estate.md) § Open | — a component to write, not a rig to book. The key-per-entitlement half is done and negative: the estate scales |
| P1-l | The telemetry return path end to end: a `moq-net` client publishing an opaque or JSON track, closing T39 Part B | not run | — | [T39](test-39-cross-boundary-observability.md) § Open | — **runnable now**, but needs a small client written against the library, since the CLI has no non-media path. See the note below |

**On P1-l's shape.** [#3608](https://github.com/moq-dev/moq/issues/3608) was accepted and became a
four-part questline (`quest/m2/qos/stats/`) which supersedes the schema T39 proposed: a `.stats`
broadcast suffix on the existing `moq-stats` layout, bidirectional, with an encoder-feedback loop,
landing on `dev` with nothing implemented. **A prototype built now should follow that shape and
should not wait for it**, and it must **not** be built into `mpegts-pacer`, which is the fast route
and is rejected — the groomer stays minimal and non-proprietary. The same client is wanted for a
second reason: no shipped CLI can dump a parsed catalog, so no catalog field can be read directly.

---

## P2 — completeness

| # | What is outstanding | MoQ | Segmented | Protocol | Blocked on |
|---|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught | not run | fault mapping run; survey not | [T32](test-32-observability-survey.md) | **never apparatus-blocked** — the segmented half is vendor outreach, and listing it against P0-e was a register error. Its fault-to-telemetry mapping is now measured |
| P2-b | Isolation under abuse | run | **run** | [T25](test-25-isolation-under-abuse.md) | **closed.** Victims byte-identical across all four arms; origin RSS stays within 0.6 MB of baseline — an upper bound, inside that baseline's own drift — against the relay's 22x |
| P2-c | A standby packager joining an already-running feed | — | not run | [T30](test-30-segmented-distributed-resilience.md) | sits behind P1-c |
| P2-d | Differential delay on a real pair rather than modelled with `netem` | not run | — | [T12](test-12-dual-path-handoff.md) | the live feed gives the pair; see below |
| P2-e | Replicates for the congestion cells, to put an error bar on the quoted aggregate | owed | **owed** | [T31](test-31-congestion-capacity-ladders.md) | **nothing — P1-d is run and this no longer sits behind it.** The segmented ladder is one sample per cell throughout, so it needs replicates on the same footing as the MoQ half |
| P2-f | LEO / Starlink handover impairment — a candidate, not yet committed | not run | — | [T35](test-35-leo-handover-impairment.md) | — |
| P2-g | Reproduce the transparency and three-lane arms from an office network, for its UDP/QUIC posture | not run | not run | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) | — |
| P2-h | The opaque lane over a real path — T3/T4 are localhost and file-fed on that lane | not run | — | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) | deploying the opaque publisher on EC2 |
| P2-i | [T12](test-12-dual-path-handoff.md)'s churn arms — the recovered-leg and late-join cells, and a grader the merge oracle is not yet | not run | — | [T12](test-12-dual-path-handoff.md) | **no longer blocked and no longer upstream's**: [#2779](https://github.com/moq-dev/moq/issues/2779) was closed won't-fix, so per-process continuity counters are permanent and the cells now grade our own keyframe-restart padding filter |

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
| B-2 | The full interop suite against a `moq2ts` subscriber (T11c) | they publish one. Worth planning the matrix now so the run is ready when it lands |
| B-3 | [T15](test-15-point-to-point-cadence.md)'s residual | a true CBR hardware source; nothing in the lab produces one |
| B-4 | The segmented plane's low-latency arm at equal conformance | a commercial ABR-to-TS gateway — the same apparatus block as P0-k in a different guise |
| B-5 | Multi-programme carriage through a *media-aware* edge | the commercial packaging edge itself. A byte cache serves an unusual TS payload exactly as nginx does, so asking it of a plain cache re-measures nginx |

### Two of these blocks are being lifted, and the register should be read with that in mind

A live contribution feed of a real service at ~10 Mb/s is being provisioned over SRT to both EC2
hosts, and the same engineer is expected to supply a professional DVB analyser and a bank of IRDs.
Between them they discharge the two apparatus dependencies that gate the most entries:

| Entry | Was waiting on | Effect |
|---|---|---|
| **P0-j** | a live TS source | **The live feed is that source.** A real encoder's hard cut on a continuous transport timeline is the exact trigger for [#3533](https://github.com/moq-dev/moq/issues/3533). That stall is fixed from `5d0991b9`, but on the same stimulus the importer exits instead, still on `ffa5b81b` ([T40](test-40-continuous-join-through-srt.md)), so this arm should be expected to *reproduce* a failure at the cut rather than clear it |
| **P0-k** | IRD + analyser loan | The hardware TR 101 290 P1/P2 soak becomes bookable; it is the only route to a `hardware:` domain figure |
| **P0-d** | analyser-specific pass-table rows | The rows [T33](test-33-gate2-preparation.md) dry-ran against the model can be taken against the instrument |
| **P1-i** | hardware | Two of the three remaining comparison cells are analyser-scored |
| **P2-d** | a real differential-delay pair | The two hosts will carry **the same service over different contribution paths**, which is that pair — unaligned by construction rather than by `netem` |
| **B-3** | a true CBR hardware source | Possibly discharged, depending on what the contribution encoder emits; check the mux rate's stability before assuming it |

### The window before the feed arrives, and what it is for

The feed, the analyser and the IRD bank arrive together and leave together. They are the scarcest
resource the campaign has had, and the failure mode is not running out of things to measure — it is
spending the window debugging a harness. **The window before them is rehearsal, not new enquiry.**

**The standing ingest chain is repaired and verified, and only the feed is now missing.** A subscriber
recovers media through the whole chain from a clip pushed into the multicast group, which is the
standing rehearsal recipe until the feed arrives (`INSTRUCTIONS.local.md`). Method rule in
[method-notes](method-notes.md) § *One measured defect is not a diagnosis of a different symptom*.

**Two rehearsals the window was reserved for are already done, and should not be re-proposed.** The
#3533 trigger was synthesised with `tsp -I file A.ts B.ts -O srt --caller` — one unbroken SRT
session, one continuous transport timeline, a hard content join at the junction — and
[T40](test-40-continuous-join-through-srt.md) is run and conclusive: the two-stage SRT ingest does
**not** absorb the trigger, and on the current build a new failure takes its place (*frame timestamp
is below the live edge*). The Gate 2 acceptance harness has likewise been rehearsed end to end
against the software reference, with its pass table fixed in a file before the first subject ran
([T33](test-33-gate2-preparation.md)); what remains of T33 is the analyser-specific rows, which are
P0-d and need the hardware. **The live arm of T34 is therefore confirmation on a real encoder rather
than first contact with the defect**, which is what the rehearsal was for.

The multicast group also gives a better `OLD`/`NEW` pair than the two hosts do, because two
publishers on different builds reading one group are fed byte-identical input
([T4](test-4-remote-e2e-srt.md)), which removes the host as a variable.

**Does a noq-only build survive the outage ladder?** [#3811](https://github.com/moq-dev/moq/pull/3811)
deleted the quinn backend, so every future build is noq — and
[T8](test-8-srt-vs-moq.md) records noq's BBRv3 *aborting the process* under high loss, which is
precisely what an outage ladder creates. The cheapest useful form is the T8b congestion rig on both
binaries at one impairment point.

**The capacity half of this is answered: noq survives it, and the backend is not a ladder variable.**
The re-based [T31](test-31-congestion-capacity-ladders.md) ran six cells on `84b34f54` with 0
continuity errors and no aborts, and its chronic rung was then replicated three ways — quinn and noq
built from the *same* commit `5d0991b9`, plus `84b34f54` — which separates backend from build. All
nine replicates fall in 0.000–0.850 s and the three arms overlap completely, so **neither the
backend nor the build shifts the lane's capacity behaviour**, and ladder figures no longer need to
be held separately per backend. What remains is the *loss* half: T8's BBRv3 abort was seen under
high loss, which a capacity ladder does not create, so the abort is still unreproduced on the
current build and wants the T8b rig at one high-loss point on both binaries.

**The ordering constraint is that #3533 sits in front of the analyser work.** Its signature — PSI,
AC-3 and teletext continuing while video and primary audio stop — presents on an IRD as a service that
locks and shows nothing, which is indistinguishable at the panel from a dozen other faults. Grade the
feed through `moq export ts` with TSDuck *before* anyone reads an analyser front panel.

**What not to do with the window.** No new speculative cells the feed would invalidate.

---

## What to bundle, because prompt count is the scarce resource

Grouped so nothing in a group contaminates anything else in it. Each group is one run.

- **The segmented group, part run.** P0-e's receiver is the instrument and it now exists
  ([T42](test-42-h3-receiver-fidelity.md)). **P1-d's segmented ladders are done**; P1-a's
  infrastructure axis, P1-c's two-host segment store and P1-f's fan-out half remain, all runnable
  against T20's existing HTTP/3 and HLS apparatus on the same host. Run the fan-out **last**,
  because it deliberately saturates a box, and keep a segmented origin off any box carrying a MoQ
  relay. Two constraints the first pass produced: the receiver is validated for byte fidelity and
  **not** for timing, so any latency arm needs its per-cycle `curl` overhead characterised first;
  and its per-fetch timeout must be swept rather than defaulted on any impaired cell
  ([method-notes](method-notes.md) § *A receiver's per-fetch timeout is a measurement parameter*).
- **The entitlement follow-up.** All of the family has run except **P1-k**: a real `--auth-api`
  endpoint serving a licensing matrix, rather than the stub that drove every run from
  [T36](test-36-entitlement-enforcement.md) to [T38](test-38-entitlement-estate.md). A component to
  write rather than a rig to book, and the scripts in [`scripts/`](scripts/) are the harness it drops
  into.
- **The cheap ladder cells** *(EC2 secondary; see P1-a and P1-d)*. The MoQ ladders run in network
  namespaces against a stopped loop publisher and grade on a per-cell aggregate, so the remaining
  cells — P1-d's 0.9×–0.8× rungs, P2-e's error bars, P1-a's infrastructure axis — are the right
  filler for a window whose main item is posting, reviewing or building. The one cell that is
  **not** cheap is putting the segmented ladder inside the namespace, which needs an origin
  reachable from it and is a rig change.
- **The long runs.** P0-g's soak and P1-g's memory arm want days rather than minutes, and a soak
  measures the machine it runs on, so neither shares a window.
- **The injection matrix.** P1-a and P0-f share a harness: both interrupt a component and grade the
  media that came out. Build the grader once.

**Do not bundle** anything from the blocked list, whose windows are set by apparatus rather than by
us.

---

## The UDP sink: deferred, with the reason it will return

[#3923](https://github.com/moq-dev/moq/issues/3923) asked for `moq export ts --udp <addr:port>`. The
maintainer pushed back softly, suggesting an external tool, and **the campaign agrees and is
deferring it — with no reply posted**. Three reasons, in order of weight, none of which is "it does
not matter":

1. **It is already served, and measured to be.** The deployed contribution chain is two stages joined
   by a loopback multicast group, with `tsp` doing the socket work on both sides
   ([T4](test-4-remote-e2e-srt.md) § *The standing live ingest*), and
   [T40](test-40-continuous-join-through-srt.md) drives media through that exact shape. A pipe into
   `tsp -O ip` is not a workaround here; it is the thing the lab has been running all along.
2. **The sink is not the bottleneck — the byte schedule is.** #3923's own filing subordinated itself
   to [#3925](https://github.com/moq-dev/moq/issues/3925) and that judgement has strengthened: on
   `ffa5b81b` the exporter's median PCR byte gap is 1,316 B against a 31,124 B nominal
   ([T13](test-13-downstream-grooming.md) § *The residual measured*). An in-process socket emitting
   that stream to multicast would be **worse than the pipe**, because an external stage can at least
   re-clock it and a built-in one that does not would look like a supported hand-off while carrying a
   grid no IRD can lock to.
3. **It belongs to the edge gateway, not to the reference CLI.**
   [`docs/architecture.md`](../docs/architecture.md) §4 already places *egress formatting — RTP/UDP
   or raw UDP, unicast or multicast, with optional SMPTE 2022-1 FEC and ST 2022-7* inside the
   gateway's ordered responsibilities, and §3.1 places multicast **ingest** in the pluggable ingest
   layer. So the maintainer's scope judgement and this campaign's architecture agree, and deferring
   costs the design nothing.

**Why it will come back, and on which side.** Where a distributor moves all feeds internally over a
managed multicast network, the pressure falls on **ingest** rather than egress — a globally
multicast contribution network wants `moq import ts` to read a group directly, and the extra `tsp`
stage becomes a per-service process multiplied by the channel count. That is an operational cost
question (process count, CPU, failure domains at hundreds of services), not a capability gap, and it
is the form in which the ask should return if it returns. Egress-side, the last hop into a facility's
IRDs is a *local* conversion at the edge, which is where the gateway already sits.

**One thing the campaign does not know, and should not assume.** Whether receive-side head-ends,
affiliates and licensees actually require a UDP or multicast hand-off into their IRDs, or whether a
unicast hand-off suffices, is **unestablished here**. Multicast does not traverse the public
internet, so external hand-off is unicast in practice (SRT, Zixi, RIST) while internal facility
distribution is multicast — but which side of that line a given licensee sits on is a deployment fact
this lab has never measured and cannot infer. It is recorded as an open question in
[`docs/problem.md`](../docs/problem.md) R3's terms rather than answered, and the arriving IRD bank is
the first opportunity to ask it of real equipment.

## Deliberately not doing

Recorded so they are not proposed again. Each was considered and dropped; where a result exists, it
is in the file named.

- **The arrival oracle on a bigger host** — run, and the caveat it existed to retire is retired
  ([T19](test-19-pcr-grid-verification.md)).
- **The clean two-host 1+1 arm, and the full two-publisher two-relay topology** — both run. Remaining
  multi-track identity is an upstream fix, not another cell here: the interleave half was fixed by
  [#4001](https://github.com/moq-dev/moq/pull/4001) and verified, and per-leg packet placement is
  what remains ([T12](test-12-dual-path-handoff.md) § *After the media-time interleave*).
- **The congestion cells under an AQM** — run, and it falsified the prediction it was meant to test
  rather than leaving it open. Do not re-run it as a rescue ([T8b](test-8b-congestion-control.md)).
- **Hunting a lower-layer mechanism for the shed** — the sweep discriminated; there is nothing left
  for a shared-lane mechanism to explain ([T8b](test-8b-congestion-control.md)).
- **More transparency clips through lanes already characterised** across a 2.75× bitrate spread.
- **The wire-cost leg on the EC2 path**, whose HTTP-layer term is path-independent and whose framing
  multiplier is measured elsewhere; and per-track wire-byte attribution.
- **The segmented HTTP/3 arm** — run, and both the original motivation and its successor are
  answered ([T20](test-20-segmented-http3.md)). What survived it was P0-e, an instrument gap rather
  than an open question, and that gap is now closed ([T42](test-42-h3-receiver-fidelity.md)). What
  the instrument reopens is narrow and specific: T20's continuity and PCR figures on the H3 and H1
  arms were the receiver's, so they are owed a re-measurement.
- **Conditional-access carriage through the opaque lane, and the apparatus for it.** It would need a
  BISS-CA scrambler and an entitled receiver alongside the loaned analyser. The complexity is real,
  the requirement is unestablished, and [`docs/control-plane.md`](../docs/control-plane.md) §9
  already records the commercial half as the half that decides it. msfts#27 stands on specification
  reading, which is what it claims to be. Dropped now rather than discovered as a dependency on the
  day the hardware arrives.
