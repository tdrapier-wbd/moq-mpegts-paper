# Test 10 — MPTS / multiple concurrent services

**State: specified, not run.** Primary distribution is frequently multi-programme; every carriage,
transparency, fan-out and SI measurement in this campaign to date is single-programme. This experiment
would settle whether Gate 1 fidelity and relay scaling survive at multi-service scale, and it has not
run because the lab lacks an MPTS fixture, a CDN account for the segmented edge case, and the
apparatus to grade fan-out under N concurrent services rather than N subscribers to one broadcast.

## Objective

Carry a multi-programme transport stream — or several single-programme broadcasts running
concurrently — through both data planes and verify that each service's PSI/SI, PCR cadence and
continuity counters survive at egress. On the MoQ lane, add relay fan-out under N services (distinct
broadcasts or distinct tracks within one MPTS) so the scaling question is channel count as well as
audience count.

Gate 1 (carriage fidelity) at multi-service scale is the acceptance gate. The campaign's residual
carriage advantage on mux content — now carried entirely by this cell rather than by
single-programme results — is the comparative stake; see [T14](test-14-data-plane-comparison.md)
measurement 3 and [B-5](planned-experiments.md#blocked-on-apparatus) in the planning record.

## What is already known, and precisely what it leaves open

**Single-programme carriage is established on both lanes.** [T3](test-3-opaque-transparency.md)
confirmed bit-transparency and full service-layer carriage on the opaque lane across three clips.
[T14](test-14-data-plane-comparison.md) showed single-programme carriage in TS segments is verbatim
on the segmented lane. Neither result generalises to a multiplex without measurement.

**Multi-service SI cost is extrapolated, not measured.** [T17](test-17-si-snapshot-tracks.md) priced
snapshot-track carriage at ~29,912 B and four tracks per service, and scaled that to 40 services
(~1.1 MiB across 160 tracks) by multiplication from one service — not by running an MPTS. Whether an
exporter resolves 160 tracks from a real multiplex, whether join blocking scales linearly, and whether
sparse EIT reconstruction holds per service are all open.

**Dual-path byte identity fails on multi-track content for a located upstream reason.**
[T12](test-12-dual-path-handoff.md) reached 75.56 % agreement on a seven-stream mux over independent
chains — the residue being the same packets in a different order, not damage — while single-track
content was byte-identical with zero residue. Multi-service at the egress merge is therefore genuinely
unmeasured even where single-service 1+1 is strong.

**Fan-out scaling is measured for one broadcast, not for N services.** [T26](test-26-cross-host-fanout.md)
established a linear relay cost curve for one publisher and one broadcast; [T9](test-9-performance.md)
read channel count as a separate axis from audience but did not grade multi-broadcast fan-out.
Whether cost grows with channels rather than subscribers remains the open half of the scaling model.

**MPTS through a real CDN is blocked on apparatus.** HLS normatively requires single-programme TS
segments; publishing MPTS segments through a commercial CDN and grading what arrives is specified under
[T14](test-14-data-plane-comparison.md) measurement 3 and [B-5](planned-experiments.md#blocked-on-apparatus).
A byte cache does not parse the payload, so that cell is only interesting where the edge is
media-aware — asking it of a plain cache re-measures nginx.

## Environment

| | |
|---|---|
| Fixture | A representative MPTS capture (or N concurrent SPTS sources muxed at ingest) with at least two programmes, distinct TSIDs, full PAT/PMT/SDT per service, at least one PCR per programme, and SI representative of primary distribution (NIT, EIT where present). Placeholder path `<MPTS_FIXTURE>`; not yet in the lab inventory. |
| MoQ lane | `moq import ts` / `moq-relay` / `moq export ts` on the opaque lane for Gate 1 breadth; media-aware lane with snapshot SI ([T17](test-17-si-snapshot-tracks.md) design) for the carriage-cost and join-cost axes. Relay on `<EC2_IP>` or loopback per arm; GSO flags and TLS fingerprinting per [method-notes](method-notes.md) and `INSTRUCTIONS.local.md`. |
| Segmented lane | `tsp -O hls` packager → HTTP origin → `tsp -I hls --live` receiver, unchanged from [T3](test-3-opaque-transparency.md) / [T14](test-14-data-plane-comparison.md). CDN arm: commercial distribution with `<CDN_DISTRIBUTION>` when an account exists. |
| Grading | TSDuck at P1 (`analyze`, `continuity`, `pat`, `pmt`, `sdt`, `pcrverify`, `pcrextract`); per-service tables, not mux-wide aggregates only. For MoQ multi-broadcast fan-out, cross-host topology from [T26](test-26-cross-host-fanout.md) with N distinct broadcast names. |
| Measurement points | P1 (file egress) for all arms; P2 (hardware IRD) only where the fixture also feeds the Gate 2 rig — out of scope for the initial MPTS characterisation unless paired with [T7](test-7-timing-integrity.md)/P2 scheduling. |

## Procedure

**Arm A — MPTS through the opaque MoQ lane (local).** Pace `<MPTS_FIXTURE>` into `moq import ts`,
subscribe once, capture groomed egress to file. Grade every programme independently: PAT/PMT
consistency, SDT service entries, elementary-stream PIDs, continuity, PCR intervals per PCR PID.

**Arm B — MPTS through the media-aware MoQ lane (local).** Same fixture with snapshot SI enabled.
Grade the same per-service structural criteria plus EIT section sets per service using
[`eit-section-diff.py`](scripts/eit-section-diff.py) where EIT is present. Record join time for a cold
exporter against the single-service baseline from [T17](test-17-si-snapshot-tracks.md).

**Arm C — Several concurrent SPTS broadcasts (MoQ).** Run K independent `moq import ts` publishers
(K ≥ 4) announcing distinct broadcasts through one relay; K subscribers (or one subscriber per
broadcast). Verify no cross-talk (wrong PAT on wrong egress) and grade fan-out resource cost against
the one-broadcast slope from [T26](test-26-cross-host-fanout.md).

**Arm D — MPTS through the segmented lane (local).** Package the MPTS into TS segments with the
existing HLS rig. Grade whether the packager splits, rejects, or carries the multiplex verbatim; per
programme at egress if the chain delivers anything at all.

**Arm E — MPTS through a real CDN (blocked).** Publish TS segments containing the MPTS to
`<CDN_DISTRIBUTION>`. Record whether the CDN delivers them, whether a conformant analyser accepts the
fetched payload, and whether an ABR-to-TS gateway (when available) preserves per-service structure.
This arm implements [T14](test-14-data-plane-comparison.md) measurement 3 and is not runnable without
a CDN account.

Run cheap arms first (A, D local), then B and C, then E when apparatus exists.

## Metrics

Per programme (or per concurrent broadcast), at P1 unless noted:

- **Structural fidelity** — PAT/PMT/SDT/NIT/TDT presence and byte identity against source; TSID/ONID
  and service name/type preserved; every elementary stream accounted for.
- **Continuity** — TSDuck continuity count; 0 is the broadcast-domain pass/fail ([method-notes](method-notes.md)
  on grep-based counting).
- **PCR conformance** — interval min/mean/max, fraction of intervals > 40 ms, `pcrverify` at 500 µs /
  13 absolute units, per PCR PID.
- **Carriage cost (media-aware lane)** — SI snapshot bytes and track count per service; cold-join
  time-to-first-byte with and without full EPG, attributed to bytes or round-trips.
- **Fan-out (Arm C)** — per-role CPU, RSS and delivered rate versus K, compared to the one-broadcast
  slopes from [T26](test-26-cross-host-fanout.md); binding resource named if a knee appears.
- **CDN arm (Arm E)** — deliver/not-deliver; analyser pass/fail per programme; gateway behaviour if
  tested.

Recovery time and session events are recorded for diagnosis but are not headline metrics.

## Pass criteria, fixed before running

1. **Per-programme Gate 1 on MoQ opaque (Arm A).** For every programme in the fixture: PSI/SI
   bit-identical to source at P1, 0 continuity errors, PCR intervals with 0 % > 40 ms on each PCR PID,
   and every elementary stream present with correct `stream_type` and descriptors.
2. **Per-programme Gate 1 on segmented local (Arm D).** If the packager emits a multiplex, the same
   criteria as (1) per programme at the HLS receiver egress. If the packager refuses or splits the
   MPTS, that outcome is reported as a lane limitation — not a failure of the rig — provided the
   behaviour is documented with the exact tool flags used.
3. **No cross-talk (Arm C).** Each of the K concurrent broadcasts delivers only its own programme's
   PAT/PMT set; any PAT referencing another broadcast's TSID is a fail.
4. **Fan-out linearity (Arm C).** Relay CPU and RSS versus K remain linear within the confidence of
   the fit (r² ≥ 0.95 on ≥ 5 points) until a stated stopping condition from [T26](test-26-cross-host-fanout.md)
   (per-subscriber delivery < 95 % of K = 1, or relay CPU saturation). Superlinear growth in relay
   cost with channel count is a finding.
5. **Media-aware SI (Arm B).** EIT section sets equal source for every service that carries EIT;
   carriage rate within ±10 % of source per EIT PID ([T17](test-17-si-snapshot-tracks.md) criterion 3);
   join cost recorded and compared to the single-service baseline — not pass/fail unless join blocking
   exceeds 1 s per additional 10 services (a falsifiable upper bound chosen before the run).
6. **CDN arm (Arm E), when runnable.** Delivered object must contain the MPTS payload unchanged at
   byte level, or the cell records the edge's rejection/splitting behaviour. Silent delivery of a
   truncated or single-programme extract without error is a fail.

## Limits, stated in advance

- **No hardware IRD pass in the initial scope.** P2 remains [T7](test-7-timing-integrity.md)/P2; any
  MPTS hardware soak is a separate scheduling decision.
- **Fixture representativeness.** One MPTS clip and K concurrent SPTS sources bracket behaviour; they
  do not prove every commercial mux shape (scrambled/CAS, datagram services, regional SI variants).
- **CDN and commercial gateway arms need accounts and hardware** the lab does not currently hold
  ([B-5](planned-experiments.md#blocked-on-apparatus), [T14](test-14-data-plane-comparison.md)
  measurement 1).
- **Dual-path merge is out of scope here.** Multi-track 1+1 residue belongs to [T12](test-12-dual-path-handoff.md)
  and upstream [#2829](https://github.com/moq-dev/moq/issues/2829); this test grades single-path egress
  per service, not receiver-side merge.
- **Wide-area and impaired paths are not in v1.** Loopback and cross-host fan-out only; loss and
  outage behaviour stay in [T28](test-28-failure-injection-matrix.md).

## Why this has not run

Three blockers, in order: no committed MPTS fixture in the lab inventory; no CDN account for Arm E
and the whole of MoQ's mux-content carriage advantage resting on that cell; and no fan-out rig that
ramps *broadcast count* rather than subscriber count on a cross-host topology. The planning record
prioritises cheaper Gate 1 work on single-programme paths first; multi-service scale was deferred
knowing [T17](test-17-si-snapshot-tracks.md)'s 40-service figures were scaled from one service and
[T12](test-12-dual-path-handoff.md)'s multi-track residue showed that merge at scale is unmeasured.
