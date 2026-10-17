# What remains to be done

The campaign's forward roadmap: what is outstanding, why it matters, what gates it, and when it is
done. Protocols, pass criteria and results live in the `test-*.md` file each entry names; nothing here
records what has already been learned. **When nothing of an entry is outstanding, delete it.** An
entry earns its place only if it could change a named claim in `docs/`.

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
| P0-j | A subscriber's export across a real encoder's backward step | Whether the real feed steps back at all is open (every exit captured was a mis-stamped SCTE-35 cue); a step's cost and class are measured on synthetic steps only ([Evidence](../docs/evidence.md) §3.13) | — (running in P0-g's seven-day arm, on standing units past #3997, where an import exit is a candidate step) | One step: a standing export analysed live with TSDuck across it, the programme lost measured, and the step's class read from the hand-off around it | [T34](test-34-real-encoder-severity.md) |
| P0-g | Permanence: the seven-day MoQ soak on the live feed, which never wraps, and a segmented soak behind an nginx origin | Whether either lane runs unattended for a week, and what the segmented lane costs to run (§5 rows 14, 15) | nginx for the segmented arm | 7 d with the wire grader and per-PID resource sampling on; the segmented arm's per-role CPU and memory measured on nginx | [T21](test-21-permanence-soak.md) |
## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-p | 1+1 source failover with a shared publisher epoch on aligned importers, on one relay and in the mesh | Before [#5517](https://github.com/moq-dev/moq/pull/5517) nothing failed over in the mesh, because a standby refused before its PMT was never asked again; #5517 (merged) announces an import only once it knows its tracks, unmeasured in the mesh; the R6 source-failover row ([Comparison](../docs/comparison.md) §13) rests on one relay | Upstream: `hop-aligned-import` ([below](#upstream-quests-worth-building)) | The single-relay matrix and the mesh drill re-run on `moq-lite-07` on such a build | [T6](test-6-relay-resilience.md) § *Single-relay standby*, § *Mesh source failover* |
| P1-o | A late-joining multi-track 1+1 leg merging at the byte | [Architecture](../docs/architecture.md) §5.1's scope: legs must be co-started (§5 row 8) | The live-feed cell once a host besides the primary is fed; upstream TDT placement and `ts-hitless --sync` for the demultiplexed export | On the opaque lane, the live-feed cell hitless; on the demultiplexed export, the merged build's residue attributed and TDT revisions placed by media time | [T12](test-12-dual-path-handoff.md) § *Arm D on the opaque lane*, [T13](test-13-downstream-grooming.md) § *On #4645's PCR grid* |
| P1-a | Failure injection, the remaining cells | The recovery rows of the comparison | — | The segmented shapes completed inside the `netns` rig | [T28](test-28-failure-injection-matrix.md) |
| P1-f | The scaling model's remaining points, and the segmented fan-out | The scaling model is measured to N = 100, with the origin co-resident | a subscriber host that holds 100 exporters; a second subscriber host | The ceiling with GSO on past N = 100; the origin on its own host; an hour at N = 100; the segmented fan-out measured | [T26](test-26-cross-host-fanout.md), [T43](test-43-fanout-current-build.md) |
| P1-g | Capped-stream relay memory under pressure | Whether the relay's memory plateaus under pressure (§5 row 14), which no soak exercises | — | T9's capped-stream arm run | [T9](test-9-performance.md) |
| P1-b | Distributed resilience above the egress 1+1 pair | Fabric-level failure for the media-aware lane | — | T29 run against its criteria | [T29](test-29-moq-distributed-resilience.md) |
| P1-c | Distributed resilience on the segmented lane: a two-host segment store, edge and origin failure, then a standby packager joining a running feed | The segmented lane's equivalent of P1-b | — | T30 run against its criteria, the standby arm last | [T30](test-30-segmented-distributed-resilience.md) |
| P1-e | MPTS: per-programme SI on the T10 rig, and the opaque-lane arm | Whether a selected programme is carried with its own SI | — for SI; an opaque-lane build for the second arm | Per-programme SI verified on T10's fixtures; the opaque arm run | [T10](test-10-mpts-multiservice.md) |
| P1-i | The three remaining data-plane comparison cells | Three empty cells in the comparison's head-to-head | B-4, B-5, B-6 | Each cell scored | [T14](test-14-data-plane-comparison.md) |
| P1-l | The telemetry return path end to end | Closes T39 Part B; the same client gives the only way to dump a parsed catalog | — (a small `moq-net` client outside `mpegts-pacer`, on the live feed) | A CMCD Event Timeline track and the TS health counters read back over the same relay; T32's faults graded against each | [T39](test-39-cross-boundary-observability.md) § *Open* |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-d | Differential delay on a real pair rather than `netem` | a second contribution path; the secondary's feed will share the primary's | T12's merge graded on the real pair | [T12](test-12-dual-path-handoff.md) |
| P2-e | Replicates for the segmented congestion rungs | — | Every segmented rung at three replicates (the MoQ rungs and the delay matrix are) | [T31](test-31-congestion-capacity-ladders.md) |
| P2-f | LEO handover impairment (a candidate, not committed) | — | Committed or deleted | [T35](test-35-leo-handover-impairment.md) |
| P2-g | The transparency and three-lane arms from an office network | — | The arms reproduced, with the network's UDP/QUIC posture recorded | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |
| P2-k | Whether receive sites need a UDP or multicast hand-off into their IRDs | B-6, and the contribution engineer | The answer recorded for each receiver type asked; it decides whether multicast egress is in the edge gateway's scope ([Architecture](../docs/architecture.md) §4) | — (a deployment question) |

**Open in the paper, with no experiment scheduled.** [Evidence](../docs/evidence.md) §5 rows 4 (the
latency ordering on a lossy or long path), 6 (a CDN carrying a multi-programme TS segment), 10 (a
third source profile), 12 (a tuned CDN edge, or an origin on BBR, under loss at
100 ms RTT) and 13 (RIST against SRT on a real path) have no entry yet, and neither have the control
strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions).

**Remainders inside completed experiments** are kept in their own files' open-items sections (T3, T4,
T9, T11, T12, T13, T15, T16, T17, T18, T20) and are not restated here. **Completed entries leave
this file and their IDs are not reused**; a citation of a retired ID resolves to the experiment that
discharged it: P0-e → [T42](test-42-h3-receiver-fidelity.md), P0-f → [T22](test-22-silent-media-plane-failure.md)
and [T24](test-24-partial-media-plane-stall.md), P0-i → [T8b](test-8b-congestion-control.md),
P0-m → [T47](test-47-fixed-delay-export.md), P1-m and P1-q → [T28](test-28-failure-injection-matrix.md),
P1-h → [T11](test-11-interop.md), P1-k → [T38](test-38-entitlement-estate.md), P1-n → [T13](test-13-downstream-grooming.md), P1-v → [T14](test-14-data-plane-comparison.md), P2-h and P1-t → [T48](test-48-passthrough-export.md), P1-r, P1-s, P1-w and P1-x → [T41](test-41-import-reanchor-coverage.md), P0-l and P1-u → [T45](test-45-live-tstd-remux.md),
P2-b → [T25](test-25-isolation-under-abuse.md), P1-d → [T31](test-31-congestion-capacity-ladders.md).

## Upstream quests worth building

Untaken quests on upstream `main` whose result would move an entry above, ranked by weight for primary
distribution. A row leaves when a pull request takes it; ours are in the
[upstream ledger](upstream-contributions.md). Every row is upstream's m2 (after its next release), so
review waits on that release; m1 keeps the T-STD epic.

| Quest | What it does | Gate | Weight |
|---|---|---|---|
| `epoch-anchor` [M] | Its clock and era are our [#5625](https://github.com/moq-dev/moq/pull/5625), open; left: a co-start across two relays, other importers' history-derived catalog fields, the successor epoch | #5625 merged | **High**, R6: its timeline gates the next two |
| `ts-passthrough-epoch-cuts` [S] | Opaque-lane importers sharing an epoch cut identical groups and catalogs: fallback cuts on the epoch's grid, the M2ts section from windows on it. **Ours, built, unposted** | #5625 | **High**, R6 on the opaque lane |
| `hop-aligned-import` [M] | Same-epoch importers number groups on the epoch timeline, so a relay fails over between them ([#4354](https://github.com/moq-dev/moq/issues/4354)) | the two above | **High**, R6: P1-p's other half |
| `ts-hitless` [L] | Two `--sync` export legs of one broadcast emit identical TS for every slot both release | none: the T-STD epic it required is finished | **High**, R6: P1-o's demultiplexed route; gates the next |
| `ts-rtp-egress` [M] | RTP legs an ST 2022-7 receiver can merge | `ts-hitless` | **High**, R6 at the IRD |
Set aside: `ts-live-clock` (the maintainer's own investigation), `ts-reliability`'s `fidelity` plan
and its children `pes-import` and `section-placement`
(verbatim private data, which no entry above waits on), its `recovery` quest (upstream CI for the content loss T28 measures),
and the QoS line's lag
histogram (behind `stats-prefix-tracks`, R8 only).

## Blocked on apparatus

| Gate | State | Unblocks |
|---|---|---|
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d, P1-i, P2-k |
| **B-7** A live contribution feed of a real service over SRT to both EC2 hosts | **on the primary** (graded in [T33](test-33-gate2-preparation.md) Part C); the secondary's pending | now: P0-j, P0-g's live arm; with the secondary's: P1-o's two-ingest arm |
| **B-4** A commercial ABR-to-TS gateway | none | the segmented lane's low-latency arm at equal conformance (§5 row 5); P1-i |
| **B-5** The commercial packaging edge itself | none (a plain byte cache only re-measures nginx) | multi-programme carriage through a media-aware edge; P1-i |

**Inside the hardware window**, which the analyser and IRDs share, measure against the live feed; debug
no harness and run no cell that needs no hardware. [T33](test-33-gate2-preparation.md) orders the work.

## Scheduling constraints

- Run the segmented fan-out last in any session, because it deliberately saturates a box, and keep a
  segmented origin off any box carrying a MoQ relay.
- Soaks and memory arms measure the machine they run on, so neither shares a window.
- The cheap namespace ladder cells (P1-a, P2-e) are the right filler for a window whose main
  item is posting, reviewing or building.

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **The lab re-multiplexer's 550–600 ms floor**: the merged export superseded it as the live stage,
  and the export's own floor is [T47](test-47-fixed-delay-export.md)'s.
- **Re-runs of answered arms**: the arrival oracle on a bigger host ([T19](test-19-pcr-grid-verification.md));
  another clean two-host 1+1 arm or two-relay topology (what remains is P1-o); the congestion cells
  under an AQM, or a lower-layer mechanism for the shed ([T8b](test-8b-congestion-control.md)); another
  segmented HTTP/3 arm ([T20](test-20-segmented-http3.md)); more transparency clips across lanes
  already characterised.
- **The wire-cost leg on the EC2 path** (its HTTP-layer term is path-independent), and per-track
  wire-byte attribution.
- **An in-process UDP sink for `export ts`**: upstream declined it, and `tsp` does the socket work
  ([upstream contributions](upstream-contributions.md) § *A UDP sink for `export ts`*).
- **Conditional-access carriage through the opaque lane, and its apparatus**: it needs a BISS-CA
  scrambler and an entitled receiver, the requirement is unestablished, and
  [Control](../docs/control-plane.md) §9 records the commercial half as deciding.
