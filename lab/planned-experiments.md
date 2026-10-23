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
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](../docs/evidence.md) §5, rows 1 and 7): the grooming design is software-validated, not broadcast-acceptable | B-6; the 2022-7 arm also #6304, and its PID-change fixture #6542 (both the maintainer's) | A `hardware:` domain P1/P2 result on both lanes over the full window, accuracy from the bytes and overall jitter and delay factor on arrival at the RTP input; 2022-7 graded under loss on the RTP datagrams, at the receiver's class; both fixtures graded; the site network's UDP and QUIC posture recorded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |

## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-o | A late leg merging at the byte from its join on a source without an H.264 HRD: on the live feed its video differs for up to 100 s after the join (T50 arm L) | [Architecture](../docs/architecture.md) §5.1's scope and [Evidence](../docs/evidence.md) §5 row 8: on the merged export a late leg merges on the clip, which carries an HRD | Upstream's placement for groups without a buffering period ([#6546](https://github.com/moq-dev/moq/issues/6546)) | Arm L passes criterion 1 within one GOP plus the delay of the join | [T50](test-50-deterministic-ts-legs.md) |
| P1-b | 1+1 across two distribution chains: two `--sync` RTP legs of one broadcast, one through our relay and one through P1-j's, merged by a 2022-7 receiver while one chain fails | [Architecture](../docs/architecture.md) §5's active/active from the importer on is measured on one host or two over our own relays, under `netem` (§5 row 8) | #6304 (the maintainer's); P1-o, since a restored chain is a late leg; P1-j's relay | Hitless through each failure class on one chain (relay restart, path outage, export killed), the pair's real differential delay against a named receiver class, both legs' RTP identical | [T29](test-29-moq-distributed-resilience.md), [T12](test-12-dual-path-handoff.md) |
| P1-j | Permanence through a CDN-hosted relay: 72 h of the demultiplexed lane at half its knee (running); the passthrough lane's ramp and soak once the node serves its joins; later, more than one hop | Every fan-out figure is one relay in one region ([Evidence](../docs/evidence.md) §6), so the R2 row reads *indicated* ([Comparison](../docs/comparison.md) §13) | Passthrough: the node's fixes (moqx#795, #817) | 72 h with the wire grader on, reconnects counted with gap and cause, the path's loss and RTT recorded; both ramps read against the node's own stats | [T52](test-52-cdn-relay-fanout.md) |
| P1-ad | The latency ordering on a long, lossy path: SRT and both MoQ lanes from the primary to a host in a distant region (80–150 ms RTT), clean and at two loss rates | Every ordering is loopback or one 12.8 ms path ([Evidence](../docs/evidence.md) §3.11; §5 row 4), and a long, lossy path is the case that should favour the tunnels | A host in a distant region (the author's go-ahead) | Each lane's matched-PTS latency at equal conformance, and its delivered programme, per condition, three replicates | [T18](test-18-delivery-latency.md) |
| P1-aa | Source-to-egress media timing across hosts on one clock: the secondary's own hand-off of the feed tapped against its export of the primary's import, PTS-matched | End-to-end timing through MoQ is loopback, or 2 h across hosts on PCR arrivals; the export's regenerated PCR grades the export, not the path ([Evidence](../docs/evidence.md) §3.11, §3.16; §5 row 3) | — | Matched-PTS latency, its drift and any steps over ≥ 72 h, with the export's rate against the hand-off's on arrivals; arrivals stamped by the kernel or NIC and the two hosts' clock error calibrated, or the uncertainty bounded and stated, before the hand-off's offset from the primary's is relied on | [T47](test-47-fixed-delay-export.md) |
| P1-ab | T6's relay-loss cell (C3) on a build carrying upstream's resume fix | A relay lost under one importer skips 7 s unflagged ([Evidence](../docs/evidence.md) §2, §3.4); upstream has fixed the resume | — | C3 at the default and a 10 s delay, against the same control | [T6](test-6-relay-resilience.md) |
| P1-ac | One entitlement estate on `moq-relay` and moqx, with token carriage, format and grant semantics tested apart; then revocation at scale | Every enforcement result is one implementation on loopback; [Control](../docs/control-plane.md) §3 puts the portability in the enforcement point, not the token format, and [Evidence](../docs/evidence.md) §3.10 lists a second implementation as unmeasured | — (loopback; the SETUP arms on #6177, open, or its branch); the scale arm P1-j's relay, if it takes our tokens | T53's criteria graded on drafts 16 and 18; on P1-j's relay, a subset of the subscribers revoked, time to effect and collateral measured | [T53](test-53-token-interop.md) |
| P1-l | The telemetry return path end to end, run inside P1-j's window | Delivered-media health at a subscriber is satisfied by no candidate ([Comparison](../docs/comparison.md) gates); closes T39 Part B | A publisher soliciting feedback: `import --echo-path` (quest `m2/stats/rust`); `import --stats` and `export --echo` are on `main` | Each subscriber's feedback (or a CMCD Event Timeline track) and the TS health counters read back over the same relay, from every subscriber of a P1-j step; T32's faults graded against each | [T39](test-39-cross-boundary-observability.md) § *Open* |
| P1-ae | Encrypted carriage through a third-party relay, both lanes | [Control](../docs/control-plane.md) §7.3 offers upstream's object-level encryption as a contract option, by design and unmeasured: relays and caches hold only ciphertext | Upstream E2EE through `moq-mux` (quests `net-wrap/mux`, `e2ee/rust-publish`) | Each lane's export identical to an unencrypted control through P1-j's relay, the relay holding only ciphertext, the per-frame overhead measured, and a re-key drill timed | — (specified when the gate clears) |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-e | Replicates for the segmented congestion rungs | — | Every segmented rung at three replicates (the MoQ rungs and the delay matrix are) | [T31](test-31-congestion-capacity-ladders.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |
| P2-l | The segmented lane's remainders: T28's segmented shapes, T30's distributed resilience, and a soak behind an nginx origin | — | The segmented shapes completed inside the `netns` rig; T30 run against its criteria, the standby arm last; the soak's per-role CPU and memory measured on nginx (§5 row 15) | [T28](test-28-failure-injection-matrix.md), [T30](test-30-segmented-distributed-resilience.md), [T21](test-21-permanence-soak.md) |
| P2-m | MPTS: per-programme SI on the T10 rig, and the opaque-lane arm | Upstream's shared parser (#6371) | Per-programme SI verified on T10's fixtures; the opaque arm run | [T10](test-10-mpts-multiservice.md) |
| P2-n | Dependency risk, from the campaign's own builds: what following upstream cost per release, against [Comparison](../docs/comparison.md)'s operational-maturity row | — (desk) | Each breaking change that reached the rigs, the standing units or the wire since moq 0.11, with its cost to adopt and the draft each release spoke; a pinning policy (release, draft, how long held) and the last upgrade's cost under it | — (a test file when started) |

**Open in the paper, with no experiment scheduled.** [Evidence](../docs/evidence.md) §5 rows 6 (a
CDN carrying a multi-programme TS segment) and 12 (a tuned CDN edge, or an origin on BBR, under loss
at 100 ms RTT) bear on the segmented lane only, which is not pursued; rows 10 (a third source
profile) and 13 (RIST against SRT on a real path) have no entry, and neither have the control
strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions). Of the
deployment milestones ([lab README](README.md)), operations has P1-l and P2-a but nothing for NOC
tooling or an SLA.

## Upstream quests worth building

Untaken quests on upstream `main` whose result would move an entry above, ranked by weight for primary
distribution. A row leaves when a pull request takes it; ours are in the
[upstream ledger](upstream-contributions.md).

| Quest | Size | Would move | Why it ranks here | Gate |
|---|---|---|---|---|
| `route-health/design`, then `recovery` | M, then L | P1-b; [Architecture](../docs/architecture.md) §5 | Relays would leave a stalled route for a same-epoch standby without a 2022-7 receiver; the maintainer ranks it after clustering and federation | Epochs on every hop (lite-07 or draft 17) |
| `stats/rust` (its `import --echo-path`), `stats/health`, `qos-publisher-timeliness` | M, M, M | P1-l | A CLI publisher soliciting each subscriber's feedback; a health verdict per subscriber, and per publisher from the relay alone: the gate no candidate satisfies | — |
| `interop-coverage/late-join` | M | T52's join limit | The CDN node refuses the joining FETCH a local moqx serves ([T52](test-52-cdn-relay-fanout.md)); coverage would catch either side regressing | — |
| `ts-reliability/pat-lifecycle` | M | P2-m; P0-k's PID-change fixture | A PAT change on a live source is followed, published or retired, never ignored | — |

Set aside: `ts-hitless-h265` (our sources are H.264), the QoS line's lag histogram (R8 only),
`ts-sync-restart-tail` (a source restart reaches both legs alike; it shortens a hole no 2022-7 pair
can fill), the E2EE line beyond P1-ae's gate (a contract option, not a requirement:
[Control](../docs/control-plane.md) §7.3), `broadcast-fairness` (tenants sharing a cluster link; one
operator's channels until P1-j's second hop), `perf/shard-default` (our relay's knee, which P1-j's
supersedes) and `auth-token-fetch` (a gate for P1-ac's moqx arm only if moqx asks a token of FETCH).

## Blocked on apparatus

| Gate | State | Unblocks |
|---|---|---|
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d |

**Inside the hardware window**, which the analyser and IRDs share, measure against the live feed; debug
no harness and run no cell that needs no hardware. [T33](test-33-gate2-preparation.md) orders the work.

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **Closed or commercial components** (an ABR-to-TS gateway, a commercial packaging edge): the
  evaluation covers open, interoperable components only. [T14](test-14-data-plane-comparison.md)'s
  cells that needed them stay empty.
- **LEO links for primary distribution.**
- **The lab re-multiplexer's 550–600 ms floor**: the merged export superseded it as the live stage,
  and the export's own floor is [T47](test-47-fixed-delay-export.md)'s.
- **Re-runs of answered arms**: the arrival oracle on a bigger host ([T19](test-19-pcr-grid-verification.md));
  another clean two-host 1+1 arm or two-relay topology (what remains is P1-o and P1-b); the congestion
  cells under an AQM, or a lower-layer mechanism for the shed ([T8b](test-8b-congestion-control.md));
  another segmented HTTP/3 arm ([T20](test-20-segmented-http3.md)); more transparency clips across lanes
  already characterised; the self-hosted relay's fan-out past N = 100
  ([T26](test-26-cross-host-fanout.md)), which P1-j's CDN relay supersedes as the deployment's.
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
