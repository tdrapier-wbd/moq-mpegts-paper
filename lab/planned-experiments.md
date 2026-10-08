# What remains to be done

The campaign's forward roadmap: what is outstanding, why it matters, what gates it, and when it is
done. Protocols, pass criteria and results live in the `test-*.md` file each entry names; nothing here
records what has already been learned. **When nothing of an entry is outstanding, delete it.** An
entry earns its place only if it could change a named claim in `docs/`. Placeholders such as
`<EC2_IP>` stand for values in `INSTRUCTIONS.local.md`.

**Priority** is by what a result could change. **P0** could change a viability conclusion, and
nothing else competes for a run window while a P0 is runnable. **P1** sharpens or reverses a verdict
row. **P2** is completeness; a P2 that starts to look like it could change a conclusion has been
mis-tiered. The **Gate** column names what must happen first (`—` means runnable now); gates are
defined [below](#blocked-on-apparatus).

## P0 — could change a viability conclusion

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](../docs/evidence.md) §5, rows 1 and 7): the grooming design is software-validated, not broadcast-acceptable | B-6 | A `hardware:` domain P1/P2 result on both lanes over the full window, 2022-7 graded under loss, both fixtures graded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |
| P0-j | A real never-repeating encoder against the continuous-source fence | The import's survival of a real encoder's hard cuts is shown on synthesised joins only | B-7 | The live feed graded through `moq export ts` with TSDuck over T34's arm | [T34](test-34-real-encoder-severity.md) |
| P0-g | Permanence: the seven-day MoQ soak, and a segmented soak behind an nginx origin | Whether either lane runs unattended for a week, and what the segmented lane costs to run (§5 rows 15, 16) | — (a host for a week; nginx for the segmented arm) | 7 d with the wire grader and per-PID resource sampling on; the segmented arm's per-role CPU and memory measured on nginx | [T21](test-21-permanence-soak.md) |
| P0-l | A live T-STD re-multiplexer across hosts and for 1+1 | Whether the lane serves TS-out to an IRD at conformance in a deployment (§5 row 2) | — | A cross-host rebuild passes the T-STD and P1/P2 over a whole capture with its clock recovered from the lane; two legs scheduled from the stream alone are byte-identical; the 550–600 ms floor bisected on a lane that holds its band; one clip of another profile or rate | [T45](test-45-live-tstd-remux.md) |
| P0-m | Upstream's merged fixed-delay export, beyond the cells already graded | Whether the subscriber is itself the conformant stage, and at what latency (§5 row 3) | — ; the re-request arm waits on the upstream fix | Every PID's units counted at joins spread across a GOP; a run of tens of minutes graded for PCR_FO and PCR_DR; loss between 1 % and 10 %; the join-dependent latency at 500 ms explained; the re-request arms of T6 and T13 re-run once the exporter's re-request exit is fixed upstream | [T47](test-47-fixed-delay-export.md) |

## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-p | 1+1 source failover with a shared publisher epoch, in the two-relay mesh and on aligned importers | The R6 source-failover row ([Comparison](../docs/comparison.md) §14) rests on one relay only | — for the mesh; upstream for aligned group numbering | The mesh drill ported to `--epoch` and graded per arm on `moq-lite-07`; the single-relay matrix re-run on a build whose importers align group numbering | [T6](test-6-relay-resilience.md) § *Single-relay standby* |
| P1-o | A late-joining multi-track 1+1 leg merging at the byte | [Architecture](../docs/architecture.md) §5.1's scope: legs must be co-started (§5 row 8) | upstream, for TDT placement | The merged build's residue attributed; an 8 s-late pair byte-identical after a counter rewrite outside upstream, with TDT revisions placed by media time | [T13](test-13-downstream-grooming.md) § *On #4645's PCR grid* |
| P1-q | Why the media-aware lane loses more programme than SRT, and why the figure moves with the build | Whether SRT's lead belongs to the lane or to one QUIC stack's configuration (§5 row 18) | — | The outage cost bisected across builds; the reorder cell re-run with the shaper's drop counter sampled | [T28](test-28-failure-injection-matrix.md), [T8b](test-8b-congestion-control.md) |
| P1-a | Failure injection, the remaining cells | The recovery rows of the comparison | — | The segmented shapes completed inside the `netns` rig; the infrastructure axis on both lanes; replicates of the MoQ latency-budget cells | [T28](test-28-failure-injection-matrix.md) |
| P1-d | Congestion: the latency-max × contention matrix | Where the trunking knee sits and what it tracks (§5 row 9) | — | The latency-budget ladder at several RTTs; buffer instrumentation on the relay | [T31](test-31-congestion-capacity-ladders.md) |
| P1-f | The scaling model's remaining points, and the segmented fan-out | The scaling model is measured to N = 100, with the origin co-resident | a subscriber host that holds 100 exporters; a second subscriber host | The ceiling with GSO on past N = 100; the origin on its own host; an hour at N = 100; the segmented fan-out measured | [T26](test-26-cross-host-fanout.md), [T43](test-43-fanout-current-build.md) |
| P1-g | Capped-stream relay memory under pressure | The relay's memory under pressure, which no soak exercises | — | T9's capped-stream arm run | [T9](test-9-performance.md) |
| P1-b | Distributed resilience above the egress 1+1 pair | Fabric-level failure for the media-aware lane | — | T29 run against its criteria | [T29](test-29-moq-distributed-resilience.md) |
| P1-c | Distributed resilience on the segmented lane: a two-host segment store, edge and origin failure, then a standby packager joining a running feed (formerly P2-c) | The segmented lane's equivalent of P1-b | — | T30 run against its criteria, the standby arm last | [T30](test-30-segmented-distributed-resilience.md) |
| P1-e | MPTS: per-programme SI on the T10 rig, and the opaque-lane arm | Whether a selected programme is carried with its own SI | — for SI; an opaque-lane build for the second arm | Per-programme SI verified on T10's fixtures; the opaque arm run | [T10](test-10-mpts-multiservice.md) |
| P1-h | Interoperability, the remaining legs | Relay portability, which underwrites the economic argument (§5 row 12) | B-2 for T11c; upstream adoption of the announce convention | The full suite against a `moq2ts` subscriber; the three undiagnosed relay failures diagnosed | [T11](test-11-interop.md) |
| P1-i | The three remaining data-plane comparison cells | Three empty cells in the comparison's head-to-head | B-4, B-5, B-6 | Each cell scored | [T14](test-14-data-plane-comparison.md) |
| P1-k | The `--auth-api` half of the entitlement estate: a real endpoint serving a licensing matrix | Every entitlement run so far used a stub | — (a component to write) | T38's matrix run against the endpoint | [T38](test-38-entitlement-estate.md) § *Open* |
| P1-l | The telemetry return path end to end | Closes T39 Part B; the same client gives the only way to dump a parsed catalog | — (a small client to write against the library; follow upstream's `.stats` broadcast layout, and keep it out of `mpegts-pacer`) | A `moq-net` client publishing a telemetry track that the far end reads | [T39](test-39-cross-boundary-observability.md) § *Open* |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-d | Differential delay on a real pair rather than `netem` | B-7 (two hosts carrying one service over different contribution paths) | T12's merge graded on the real pair | [T12](test-12-dual-path-handoff.md) |
| P2-e | Replicates for the congestion cells, both lanes | — | An error bar on each quoted aggregate | [T31](test-31-congestion-capacity-ladders.md) |
| P2-f | LEO handover impairment (a candidate, not committed) | — | Committed or deleted | [T35](test-35-leo-handover-impairment.md) |
| P2-g | The transparency and three-lane arms from an office network | — | The arms reproduced, with the network's UDP/QUIC posture recorded | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) |
| P2-h | The opaque lane over a real path, and its wire cost (§5 row 10) | the opaque publisher deployed on EC2 | T3/T4's opaque arms over the internet path | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |
| P2-j | A timestamp rewind as a new broadcast, at scale | — ; the in-process republish waits on upstream | The programme lost per rewind measured at scale; re-run when the import can republish in the same connection | [T40](test-40-continuous-join-through-srt.md), [T41](test-41-import-reanchor-coverage.md) |
| P2-k | Whether receive sites need a UDP or multicast hand-off into their IRDs | B-6, and the contribution engineer | The answer recorded for each receiver type asked; it decides whether multicast egress is in the edge gateway's scope ([Architecture](../docs/architecture.md) §4) | — (a deployment question) |

**Open in the paper, with no experiment scheduled.** [Evidence](../docs/evidence.md) §5 rows 4 (the
latency ordering on a lossy or long path), 6 (a CDN carrying a multi-programme TS segment), 11 (two
more source profiles for the cost model), 13 (a tuned CDN edge, or an origin on BBR, under loss at
100 ms RTT) and 14 (RIST against SRT on a real path) have no entry yet, and neither have the control
strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions). Each
needs an entry and a protocol before it can be run; until then the paper carries them as open.

**Remainders inside completed experiments** are kept in their own files' open-items sections (T3, T4,
T9, T11, T12, T13, T15, T16, T17, T18, T20) and are not restated here. **Completed entries leave
this file and their IDs are not reused**; a citation of a retired ID resolves to the experiment that
discharged it: P0-e → [T42](test-42-h3-receiver-fidelity.md), P0-f → [T22](test-22-silent-media-plane-failure.md)
and [T24](test-24-partial-media-plane-stall.md), P0-i → [T8b](test-8b-congestion-control.md),
P1-m → [T28](test-28-failure-injection-matrix.md), P1-n → [T13](test-13-downstream-grooming.md),
P2-b → [T25](test-25-isolation-under-abuse.md).

## Blocked on apparatus

| Gate | State | Unblocks |
|---|---|---|
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d, P1-i, P2-k |
| **B-7** A live contribution feed of a real service (~10 Mb/s over SRT to both EC2 hosts) | not arrived; the standing ingest chain is verified with a clip pushed into its multicast group (`INSTRUCTIONS.local.md`) | P0-j, P2-d; possibly B-3 |
| **B-2** A `moq2ts` subscriber published by its authors | not published | P1-h (T11c) |
| **B-3** A true CBR hardware source | none in the lab; check whether the live feed's encoder is one before assuming it | the residual in [T15](test-15-point-to-point-cadence.md) |
| **B-4** A commercial ABR-to-TS gateway | none | the segmented lane's low-latency arm at equal conformance (§5 row 5); P1-i |
| **B-5** The commercial packaging edge itself | none (a plain byte cache only re-measures nginx) | multi-programme carriage through a media-aware edge; P1-i |

**Inside the hardware window.** The feed, analyser and IRDs are expected to arrive and leave together,
so the window is for measurement, not for debugging a harness or for speculative cells the feed would
invalidate. Grade the feed through `moq export ts` with TSDuck before anyone reads an analyser front
panel: a service whose video and primary audio stop while PSI continues looks, on an IRD, like a dozen
other faults.

## Scheduling constraints

- Run the segmented fan-out last in any session, because it deliberately saturates a box, and keep a
  segmented origin off any box carrying a MoQ relay.
- The byte-faithful HLS receiver is validated for byte fidelity, not timing: characterise its per-cycle
  `curl` overhead before any latency arm, and sweep its per-fetch timeout on impaired cells
  ([method-notes](method-notes.md) § *A receiver's per-fetch timeout is a measurement parameter*).
- Soaks and memory arms run for days and measure the machine they run on, so neither shares a window
  with anything else.
- The cheap namespace ladder cells (P1-a, P1-d, P2-e) are the right filler for a window whose main
  item is posting, reviewing or building.

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **The arrival oracle on a bigger host**: run, and the caveat it existed to retire is retired
  ([T19](test-19-pcr-grid-verification.md)).
- **Another clean two-host 1+1 arm or two-publisher two-relay topology**: both run; what remains of
  multi-track identity is P1-o ([T12](test-12-dual-path-handoff.md)).
- **The congestion cells under an AQM, again**: run, and it falsified the prediction it tested; do not
  re-run it as a rescue ([T8b](test-8b-congestion-control.md)).
- **A lower-layer mechanism for the shed**: the sweep discriminated, and nothing is left for a
  shared-lane mechanism to explain ([T8b](test-8b-congestion-control.md)).
- **More transparency clips through lanes already characterised** across a 2.75× bitrate spread.
- **The wire-cost leg on the EC2 path**, whose HTTP-layer term is path-independent and whose framing
  multiplier is measured elsewhere; and per-track wire-byte attribution.
- **Another segmented HTTP/3 arm**: run, and its questions answered ([T20](test-20-segmented-http3.md),
  [T42](test-42-h3-receiver-fidelity.md)).
- **An in-process UDP sink for `export ts`**: upstream closed it as not planned, and `tsp` already does
  the socket work in the deployed chain; the edge gateway owns egress formatting
  ([upstream contributions](upstream-contributions.md) § *A UDP sink for `export ts`*). If the ask
  returns, it returns as UDP *ingest* at channel scale, an operational-cost question.
- **Conditional-access carriage through the opaque lane, and its apparatus**: it needs a BISS-CA
  scrambler and an entitled receiver, the requirement is unestablished, and
  [Control](../docs/control-plane.md) §9 already records the commercial half as the deciding one.
