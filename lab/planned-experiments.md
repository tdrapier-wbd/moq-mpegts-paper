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
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](../docs/evidence.md) §5, rows 1 and 7): the grooming design is software-validated, not broadcast-acceptable | B-6 | A `hardware:` domain P1/P2 result on both lanes over the full window, accuracy from the bytes and overall jitter and delay factor on arrival at the RTP input; 2022-7 graded under loss on two passthrough legs' RTP, each from a stream-clocked groomer, at the receiver's class; both fixtures graded; the site network's UDP and QUIC posture recorded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |

## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-b | 1+1 across two distribution chains: two passthrough legs of one broadcast, each through a stream-clocked groomer into RTP, one through our relay and one through P1-j's, merged by a 2022-7 receiver while one chain fails | [Architecture](../docs/architecture.md) §5's active/active from the importer on is measured on one host or two over our own relays, under `netem` | P1-j's relay | Hitless through each failure class on one chain (relay restart, path outage, export killed), the pair's real differential delay against a named receiver class, both legs' RTP identical | [T29](test-29-moq-distributed-resilience.md), [T12](test-12-dual-path-handoff.md) |
| P1-j | Permanence through a CDN-hosted relay: 72 h of the demultiplexed lane at half its knee (running); the passthrough lane's ramp and soak once the node serves its joins; later, more than one hop | Every fan-out figure is one relay in one region ([Evidence](../docs/evidence.md) §6), so the R2 row reads *indicated* ([Comparison](../docs/comparison.md) §13) | Passthrough: the node's fixes (moqx#795, #817) | 72 h with the wire grader on, reconnects counted with gap and cause, the path's loss and RTT recorded; both ramps read against the node's own stats | [T52](test-52-cdn-relay-fanout.md) |
| P1-ad | The latency ordering on a long, lossy path: SRT and both MoQ lanes from the primary to a host in a distant region (80–150 ms RTT), clean and at two loss rates | Every ordering is loopback or one 12.8 ms path ([Evidence](../docs/evidence.md) §3.11; §5 row 4), and a long, lossy path is the case that should favour the tunnels | A host in a distant region (the author's go-ahead) | Each lane's matched-PTS latency at equal conformance, and its delivered programme, per condition, three replicates | [T18](test-18-delivery-latency.md) |
| P1-aa | Source-to-egress media timing across hosts on one clock: the secondary's own hand-off of the feed tapped against its export of the primary's import, PTS-matched | End-to-end timing through MoQ is loopback, or 2 h across hosts on PCR arrivals; the export's regenerated PCR grades the export, not the path ([Evidence](../docs/evidence.md) §3.11, §3.16; §5 row 3) | — | Matched-PTS latency, its drift and any steps over ≥ 72 h, with the export's rate against the hand-off's on arrivals; arrivals stamped by the kernel or NIC and the two hosts' clock error calibrated, or the uncertainty bounded and stated, before the hand-off's offset from the primary's is relied on | [T57](test-57-cross-host-timing.md) (running) |
| P1-af | 1+1 on the media-aware lane selected at the receiver: each leg its own broadcast and export, a TS input switch (TSDuck `tsswitch`: a primary input and a receive timeout) choosing between them; every failure class, and each leg's start and restart | In the relay every leg event is a switch, the newest leg wins, and each switch costs the export's delay, so legs that restart independently fail there; a receiver's select avoided every relay switch in a model without detection ([T56](test-56-media-aware-failover.md); [Architecture](../docs/architecture.md) §5) | — | Per event, the switch output's decoder hole and programme lost, on one source and on two encodes, at two receive timeouts, every leg started apart; whether any leg event costs the serving output a second | — (specified before its first run) |
| P1-ac | Revocation at scale on a second implementation: a subset of a fan-out's subscribers withdrawn on P1-j's relay | Every revocation result is `moq-relay` on loopback ([Evidence](../docs/evidence.md) §3.10); on moqx v0.3.6 a live session outlives its token and a key is withdrawn only by a restart ([T53](test-53-token-interop.md)) | P1-j's relay taking our tokens, and a moqx release that reloads its keys | Time to effect and collateral on the kept subscribers, against T37's | [T53](test-53-token-interop.md) |
| P1-l | The telemetry return path end to end, run inside P1-j's window | Delivered-media health at a subscriber is satisfied by no candidate ([Comparison](../docs/comparison.md) gates); closes T39 Part B | — (`import --echo-path`, `import --report` and `export echo` are on `main`) | Each subscriber's feedback (or a CMCD Event Timeline track) and the TS health counters read back over the same relay, from every subscriber of a P1-j step; T32's faults graded against each | [T39](test-39-cross-boundary-observability.md) § *Open* |
| P1-ae | Encrypted carriage through a third-party relay, both lanes | [Control](../docs/control-plane.md) §7.3 offers upstream's object-level encryption as a contract option, by design and unmeasured: relays and caches hold only ciphertext | Upstream E2EE through `moq-mux` (quests `net-wrap/mux`, `e2ee/rust-publish`) | Each lane's export identical to an unencrypted control through P1-j's relay, the relay holding only ciphertext, the per-frame overhead measured, and a re-key drill timed | — (specified when the gate clears) |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-e | Replicates for the segmented congestion rungs | — | Every segmented rung at three replicates (the MoQ rungs and the delay matrix are) | [T31](test-31-congestion-capacity-ladders.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |
| P2-l | The segmented lane's remainders: T28's segmented shapes, T30's distributed resilience, and a soak behind an nginx origin | — | The segmented shapes completed inside the `netns` rig; T30 run against its criteria, the standby arm last; the soak's per-role CPU and memory measured on nginx (§5 row 15) | [T28](test-28-failure-injection-matrix.md), [T30](test-30-segmented-distributed-resilience.md), [T21](test-21-permanence-soak.md) |
| P2-m | MPTS: per-programme SI on the T10 rig, and the opaque-lane arm | — (upstream's shared parser is on `main`) | Per-programme SI verified on T10's fixtures; the opaque arm run | [T10](test-10-mpts-multiservice.md) |

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
| `qos-publisher-timeliness` | M | P1-l | A health verdict per publisher from the relay alone; the per-subscriber verdict is on `main` | — |
| `interop-coverage/late-join` | M | T52's join limit | The CDN node refuses the joining FETCH a local moqx serves ([T52](test-52-cdn-relay-fanout.md)); coverage would catch either side regressing | — |
| `ts-reliability/pat-lifecycle`, the export half | M | P2-m; P0-k's PID-change fixture | A PAT change on a live source is followed, published or retired, never ignored; our #6689 takes the import half | — |

Set aside: the QoS line's lag histogram (R8 only), the E2EE line beyond P1-ae's gate (a contract option, not a requirement:
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
  another clean two-host 1+1 arm or two-relay topology (what remains is P1-b); the congestion
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
