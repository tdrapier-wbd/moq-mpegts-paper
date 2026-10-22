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
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](../docs/evidence.md) §5, rows 1 and 7): the grooming design is software-validated, not broadcast-acceptable | B-6; the 2022-7 arm also #6304 | A `hardware:` domain P1/P2 result on both lanes over the full window, accuracy from the bytes and overall jitter and delay factor on arrival at the RTP input; 2022-7 graded under loss on the RTP datagrams, at the receiver's class; both fixtures graded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |
| P0-j | A subscriber's export across a real encoder's backward step | Whether the real feed steps back at all is open (every exit captured was a mis-stamped SCTE-35 cue); a step's cost and class are measured on synthetic steps only ([Evidence](../docs/evidence.md) §3.13) | — (running in P0-g's seven-day arm, on standing units past #3997, where an import exit is a candidate step) | One step: a standing export analysed live with TSDuck across it, the programme lost measured, and the step's class read from the hand-off around it | [T34](test-34-real-encoder-severity.md) |
| P0-g | Permanence: the seven-day MoQ soak on the live feed, which never wraps, and a segmented soak behind an nginx origin | Whether either lane runs unattended for a week, and what the segmented lane costs to run (§5 rows 14, 15) | nginx for the segmented arm | 7 d with the wire grader and per-PID resource sampling on; the segmented arm's per-role CPU and memory measured on nginx | [T21](test-21-permanence-soak.md) |
## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-o | Legs of one broadcast merging at the byte on a merged `--sync` export, a late-joining leg included, on the live feed across two hosts | [Architecture](../docs/architecture.md) §5.1's scope: a multi-track pair merges co-started on merged builds, a late leg only on an `[unmerged]` one (§5 row 8) | P0-g's end (`--sync` merged as our [#5949](https://github.com/moq-dev/moq/pull/5949)) | T50's arms on the merged build, and a late leg on the live feed graded against its partner | [T50](test-50-deterministic-ts-legs.md) |
| P1-j | Fan-out and permanence through a CDN-hosted relay: a subscriber ramp to the knee on the live feed, then 72 h at about half of it; later, more than one hop | Every fan-out figure is one relay in one region ([Evidence](../docs/evidence.md) §6), so the R2 row reads *indicated* ([Comparison](../docs/comparison.md) §13) | The operator's window and logging level; P0-g's end | Each step's delivered rate, continuity, PCR and join time to the first degradation; 72 h with the wire grader on, reconnects counted, the path's loss and RTT recorded | [T52](test-52-cdn-relay-fanout.md) |
| P1-a | Failure injection, the remaining cells | The recovery rows of the comparison | — | The segmented shapes completed inside the `netns` rig | [T28](test-28-failure-injection-matrix.md) |
| P1-f | The scaling model's remaining points, and the segmented fan-out | The scaling model is measured to N = 100, with the origin co-resident | a subscriber host that holds 100 exporters; a second subscriber host | The ceiling with GSO on past N = 100; the origin on its own host; an hour at N = 100; the segmented fan-out measured | [T26](test-26-cross-host-fanout.md), [T43](test-43-fanout-current-build.md) |
| P1-g | Capped-stream relay memory under pressure | Whether the relay's memory plateaus under pressure (§5 row 14), which no soak exercises | — | T9's capped-stream arm run | [T9](test-9-performance.md) |
| P1-b | Distributed resilience above the egress 1+1 pair | Fabric-level failure for the media-aware lane | — | T29 run against its criteria | [T29](test-29-moq-distributed-resilience.md) |
| P1-c | Distributed resilience on the segmented lane: a two-host segment store, edge and origin failure, then a standby packager joining a running feed | The segmented lane's equivalent of P1-b | — | T30 run against its criteria, the standby arm last | [T30](test-30-segmented-distributed-resilience.md) |
| P1-e | MPTS: per-programme SI on the T10 rig, and the opaque-lane arm | Whether a selected programme is carried with its own SI | — (`import ts --passthrough` is the opaque lane) | Per-programme SI verified on T10's fixtures; the opaque arm run | [T10](test-10-mpts-multiservice.md) |
| P1-i | The three remaining data-plane comparison cells | Three empty cells in the comparison's head-to-head | B-4, B-5, B-6 | Each cell scored | [T14](test-14-data-plane-comparison.md) |
| P1-aa | Source-to-egress media timing across hosts on one clock: the secondary's own hand-off of the feed (B-7) tapped against its export of the primary's import, PTS-matched | End-to-end timing through MoQ is loopback, or 2 h across hosts on PCR arrivals; the export's regenerated PCR grades the export, not the path ([Evidence](../docs/evidence.md) §3.11, §3.16; §5 row 3) | P0-g's end | Matched-PTS latency, its drift and any steps over ≥ 72 h, with the export's rate against the hand-off's on arrivals; arrivals stamped by the kernel or NIC and the two hosts' clock error calibrated, or the uncertainty bounded and stated, before the hand-off's offset from the primary's is relied on | [T47](test-47-fixed-delay-export.md) |
| P1-ab | T6's relay-loss cell (C3) on a build carrying upstream's resume fix | A relay lost under one importer skips 7 s unflagged ([Evidence](../docs/evidence.md) §2, §3.4); upstream has fixed the resume | — | C3 at the default and a 10 s delay, against the same control | [T6](test-6-relay-resilience.md) |
| P1-ac | One entitlement estate on `moq-relay` and moqx, with token carriage, format and grant semantics tested apart | Every enforcement result is one implementation; [Control](../docs/control-plane.md) §3 puts the portability in the enforcement point, not the token format, and [Evidence](../docs/evidence.md) §3.10 lists a second implementation as unmeasured | — (loopback; the SETUP arms on #6177, open, or its branch) | T53's criteria graded on drafts 16 and 18 | [T53](test-53-token-interop.md) |
| P1-l | The telemetry return path end to end | Closes T39 Part B; the same client gives the only way to dump a parsed catalog | — (a small `moq-net` client outside `mpegts-pacer`, on the live feed) | A CMCD Event Timeline track and the TS health counters read back over the same relay; T32's faults graded against each | [T39](test-39-cross-boundary-observability.md) § *Open* |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-d | Differential delay on a real pair rather than `netem`: two `--sync` legs of one broadcast over two distribution paths, our relay and P1-j's | The RTP legs (our [#6304](https://github.com/moq-dev/moq/pull/6304), in review); P1-j | T12's merge graded on the real pair's RTP, its skew against a named receiver class | [T12](test-12-dual-path-handoff.md) |
| P2-e | Replicates for the segmented congestion rungs | — | Every segmented rung at three replicates (the MoQ rungs and the delay matrix are) | [T31](test-31-congestion-capacity-ladders.md) |
| P2-f | LEO handover impairment (a candidate, not committed) | — | Committed or deleted | [T35](test-35-leo-handover-impairment.md) |
| P2-g | The transparency and three-lane arms from an office network | — | The arms reproduced, with the network's UDP/QUIC posture recorded | [T3](test-3-opaque-transparency.md), [T4](test-4-remote-e2e-srt.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |
| P2-k | Whether receive sites need a UDP or multicast hand-off into their IRDs | B-6, and the contribution engineer | The answer recorded for each receiver type asked; it decides whether multicast egress is in the edge gateway's scope ([Architecture](../docs/architecture.md) §4) | — (a deployment question) |

**Open in the paper, with no experiment scheduled.** [Evidence](../docs/evidence.md) §5 rows 4 (the
latency ordering on a lossy or long path), 6 (a CDN carrying a multi-programme TS segment), 10 (a
third source profile), 12 (a tuned CDN edge, or an origin on BBR, under loss at
100 ms RTT) and 13 (RIST against SRT on a real path) have no entry yet, and neither have the control
strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions). Of the
deployment milestones ([lab README](README.md)), operations has P1-l and P2-a but nothing for NOC
tooling or an SLA, and dependency risk has nothing: what following a draft-version upstream costs
per release, and a pinning policy that bounds it.

**Remainders inside completed experiments** are kept in their own files' open-items sections (T3, T4,
T9, T11, T12, T13, T15, T16, T17, T18, T20) and are not restated here. **Completed entries leave
this file and their IDs are not reused**; a citation of a retired ID resolves to the experiment that
discharged it: P0-e → [T42](test-42-h3-receiver-fidelity.md), P0-f → [T22](test-22-silent-media-plane-failure.md)
and [T24](test-24-partial-media-plane-stall.md), P0-i → [T8b](test-8b-congestion-control.md),
P0-m → [T47](test-47-fixed-delay-export.md), P1-m, P1-q, P1-y and P1-z → [T28](test-28-failure-injection-matrix.md),
P1-h → [T11](test-11-interop.md), P1-p → [T6](test-6-relay-resilience.md), P1-k → [T38](test-38-entitlement-estate.md), P1-n → [T13](test-13-downstream-grooming.md), P1-v → [T14](test-14-data-plane-comparison.md), P2-h and P1-t → [T48](test-48-passthrough-export.md), P1-r, P1-s, P1-w and P1-x → [T41](test-41-import-reanchor-coverage.md), P0-l and P1-u → [T45](test-45-live-tstd-remux.md),
P2-b → [T25](test-25-isolation-under-abuse.md), P1-d → [T31](test-31-congestion-capacity-ladders.md).

## Upstream quests worth building

Untaken quests on upstream `main` whose result would move an entry above, ranked by weight for primary
distribution. A row leaves when a pull request takes it; ours are in the
[upstream ledger](upstream-contributions.md). **None at the last audit.**

Set aside: `ts-hitless-h265` (our sources are H.264), the QoS line's lag histogram (R8 only),
`decode-order` (a gate for P1-o only if its late leg fails on DTS) and `state-bound` (P0-g's
grading shows whether our feed needs it).

## Blocked on apparatus

| Gate | State | Unblocks |
|---|---|---|
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d, P1-i, P2-k |
| **B-7** A live contribution feed of a real service over SRT | **on both hosts**, one multiplex sent twice over one contribution path (graded in [T33](test-33-gate2-preparation.md) Part C) | P0-j, P0-g's live arm, P1-j, P1-o's live leg, P1-aa |
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
- **FEC on the MoQ lane**: SRT's lead in [T28](test-28-failure-injection-matrix.md)'s matched ladder
  is retransmission alone (no packet filter ran), QUIC already retransmits, and FEC pays only on a
  budget of a few round trips. The gap is in QUIC's controller, outage recovery, reorder thresholds
  and liveness, which T28 measures.
- **Conditional-access carriage through the opaque lane, and its apparatus**: it needs a BISS-CA
  scrambler and an entitled receiver, the requirement is unestablished, and
  [Control](../docs/control-plane.md) §9 records the commercial half as deciding.
