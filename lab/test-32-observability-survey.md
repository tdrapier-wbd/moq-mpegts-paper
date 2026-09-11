# Test 32 — Observability: what commercial monitoring would have caught

**State: specified, not run.** The MoQ lane's silent failure classes are measured and a per-PID
liveness detector is built ([T22](test-22-silent-media-plane-failure.md),
[T24](test-24-partial-media-plane-stall.md), [T27](test-27-liveness-detector.md)). What remains is a
**structured procurement survey**: whether commercial TR 101 290 monitoring and ABR/OTT monitoring
products expose the detectors those experiments proved necessary, and by what mechanism. This is
desk research plus fault-to-telemetry mapping, not a rig run; it has not started because engineering
work on the detector took precedence over vendor outreach.

Specified as the procurement half of [P2-a](planned-experiments.md#p2--completeness) and
[P2-a](planned-experiments.md#p2--completeness). The measured MoQ arms are **not** repeated here.

## Objective

Determine whether an operations team running hundreds of permanent feeds could **localise** the silent
media-plane failure classes this campaign found, using **commercial monitoring** they can buy rather
than custom tooling this lab built.

The reportable output is the list of induced faults for which **no** commercial telemetry on a lane
distinguishes the failing component — extended from the MoQ-specific list T22/T24/T27 established to
cover TR 101 290 analysers, IRD alarms, and ABR/OTT observability suites on the segmented lane.

## What is already known, and precisely what it leaves open

**T22 — total source stall.** A frozen publisher is **invisible to the transport indefinitely** (120 s
frozen, zero non-benign log lines across publisher, relay and exporter). The media plane detects total
stall in about one cushion; QUIC catches a frozen relay at ~34 s
([T22](test-22-silent-media-plane-failure.md)).

**T24 — partial media-plane stall.** With video dead for 60 s, every other stream ran uninterrupted,
but **the whole of TR 101 290 P1 stayed green**, transport logs matched a healthy run, and the stuffing
ratio that catches dead video missed dead audio entirely. **Only per-PID access-unit liveness** caught
every arm at true length with no false positive on the control
([T24](test-24-partial-media-plane-stall.md)).

**T27 — detector in the live path.** The same suppression T24 measured offline reads **57.212 s** live
at a cross-host groomed output versus **57.22 s** offline; audio alarms in **0.7–1.4 s**; nothing fires
on controls. The requirement is **liveness per stream**, not bitrate per stream — dead-PID bitrate goes
to zero without moving service bitrate ([T27](test-27-liveness-detector.md)).

**What those three leave open is procurement, not engineering.** Whether any commercial product exposes
per-PID access-unit liveness, or only per-PID bitrate (which inherits T24's proportional-sensitivity
failure), is unanswered. Whether TR 101 290 P1/P2 analysers catch partial stalls, and whether ABR/OTT
suites localise origin versus edge versus client failures for the segmented lane, is likewise
unanswered. [Architecture](../docs/architecture.md) §9 has the design-level two-domain correlation
problem; `--stats-enabled` is off by default on the relay; the segmented lane's surface is HTTP logs and
manifest probes — mature but indirect ([P2-a](planned-experiments.md#p2--completeness)).

**The segmented lane's observability arms are out of scope here.** Byte-faithful H3 receiver work and
induced faults on that lane belong to separate planning items; this survey **maps commercial tooling**
against the fault catalogue T22/T24/T27 defined on MoQ, then asks the parallel question for segmented
HTTP where vendor documentation allows.

## Environment

| | |
|---|---|
| Fault catalogue | The six T22 arms (total stall, frozen relay, `--on-stall continue`, etc.), four T24 partial-stall arms, and T27's cross-host validation cases — **described by fault class**, not re-induced. |
| MoQ reference path | Documented topology from [T22](test-22-silent-media-plane-failure.md)/[T24](test-24-partial-media-plane-stall.md)/[T27](test-27-liveness-detector.md): publisher → relay → exporter → groomer → monitor point. |
| Segmented reference path | Origin → CDN/edge → client → TS egress, per [Architecture](../docs/architecture.md) §9 and [T14](test-14-data-plane-comparison.md). |
| Commercial products | TR 101 290 hardware analysers and IRD alarm interfaces; broadcast monitoring suites (Elecard, Tektronix, R&S, Ateme-class where public documentation exists); ABR/OTT observability (CDN logs, player/beacon analytics, synthetic manifest/segment probes). No vendor accounts required for the documentary pass; hands-on trials optional where access exists. |
| Ground truth | For each fault class: which component failed, which streams were affected, true outage duration from T22/T24/T27 tables — **cited from those files**, not re-measured. |

## Procedure

**Label the method.** This is a **structured comparison**, not a measurement campaign. Every conclusion
that rests on vendor claims is labelled *specification* or *datasheet*; only faults actually induced in
T22/T24/T27 are labelled *measured*.

**Per lane, build a matrix:**

1. **Native telemetry** — what the lane emits without custom tooling (relay stats broadcast, exporter
   logs, HLS access logs, CDN metrics).
2. **Commercial monitoring fit** — which off-the-shelf products ingest that telemetry or probe the wire;
   deployment and upgrade surface.
3. **Per induced fault class** — walk the catalogue: which signals move, estimated time-to-alarm from
   product documentation, whether the alarm **localises** to publisher / relay / exporter / groomer /
   origin / edge / client.
4. **Gap list** — faults for which *no* product in the survey exposes a distinguishing signal; note
   whether per-PID liveness, per-PID bitrate, PCR progression, or transport liveness is the closest
   offered mechanism and why it fails the T24 counterexample.

**Procurement questions to record explicitly:**

- Do any TR 101 290 analysers alarm on **per-PID access-unit spacing** or only transport-level P1 checks?
- Do ABR/OTT suites detect **partial segment availability** (playlist live, one rendition stalled) versus
  total origin failure?
- Where products offer "bitrate per PID," document the **minimum detectable outage** as a fraction of
  mux bitrate — T24's audio case is the falsification test.

**Segmented lane:** repeat steps 1–4 from public vendor docs; hands-on confirmation only where the lab
already has access — do not conflate documentation review with graded interop.

## Metrics

Per fault class × product (or product class):

- **Telemetry that moved** — yes/no; which metric (named).
- **Time to first alarm** — from documentation or measured trial; state domain.
- **Localisation** — component identified correctly, partially, or not at all.
- **False-positive risk** — would a healthy feed alarm on the thresholds the product documents?

The headline metric is **count of fault classes with no distinguishing commercial telemetry**, split by
lane and by whether the closest offered detector is liveness, bitrate, or transport-level.

## Pass criteria, fixed before running

Judgement criteria, stated as judgement ([P2-a](planned-experiments.md#p2--completeness)):

1. **Completeness.** Every T22/T24/T27 fault class appears in the matrix with at least one commercial
   product class evaluated, or is explicitly marked *no product surveyed* with reason.
2. **Honest labelling.** Measured faults cite [T22](test-22-silent-media-plane-failure.md),
   [T24](test-24-partial-media-plane-stall.md), or [T27](test-27-liveness-detector.md); vendor
   capabilities cite public documentation only unless a hands-on trial is recorded separately.
3. **The gap list is the deliverable.** The survey **passes** if the list of faults with no commercial
   localisation is published with mechanism-level explanation (e.g. "P1 green because partial PID
   loss is below threshold X").
4. **Liveness versus bitrate.** Any product claiming stream health via bitrate alone is scored against
   T24's audio arm: if documentation implies detection of a dead stream whose share is below stated
   mux variance, record *would not have caught T24 audio* unless the product documents AU-level or
   equivalent framing-level liveness.
5. **Actionable procurement guidance.** For each gap, state whether the campaign's custom detector
   ([`ts-liveness.py`](scripts/ts-liveness.py)), upstream importer changes ([T27](test-27-liveness-detector.md)
   recommendation), or no software substitute exists on that lane.

## Limits, stated in advance

- **Not a product benchmark.** No scoring of vendors against each other; the question is coverage of
  *failure classes*, not UI quality or price.
- **Documentation may lag firmware.** Hands-on trials are opportunistic; datasheet conclusions carry
  *specification* qualification.
- **Does not re-run T22/T24/T27.** All fault timings and detection latencies come from those files;
  contradictions would trigger a new rig experiment, not an update to this survey alone.
- **Segmented HTTP/3 byte-faithful path excluded** until the receiver instrument exists ([P0-2](planned-experiments.md)
  status in planning record); survey covers classic HLS/CDN observability only.
- **Security and pen-test scope excluded.** Deliberately matches [T25](test-25-isolation-under-abuse.md):
  operational failure modes, not adversarial worst case.

## Why this has not run

Engineering closed the MoQ detection gap first — T27 built and validated the only sufficient detector
before asking whether anyone sells one. Vendor outreach and datasheet archaeology were deprioritised as
[P2-a](planned-experiments.md#p2--completeness) completeness work with no apparatus blocker: it can run in parallel
with any rig session. The segmented half waits on the same scheduling attention, not on new hardware.
