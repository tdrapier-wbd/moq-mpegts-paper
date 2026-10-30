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
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](evidence.md) §5, rows 1 and 7): the grooming design is software-validated, not broadcast-acceptable | B-6 | A `hardware:` domain P1/P2 result on both lanes over the full window, accuracy from the bytes and overall jitter and delay factor on arrival at the RTP input; 2022-7 graded under loss on two passthrough legs' RTP, each from a stream-clocked groomer, at the receiver's class; both fixtures graded; the site network's UDP and QUIC posture recorded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |

## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
|---|---|---|---|---|---|
| P1-b | 1+1 across two distribution chains: two passthrough legs of one broadcast, each through a stream-clocked groomer into RTP, one through our relay and one through P1-j's, merged by a 2022-7 receiver while one chain fails | [Architecture](../docs/architecture.md) §5's active/active from the importer on is measured on one host or two over our own relays, under `netem` | P1-j's relay | Hitless through each failure class on one chain (relay restart, path outage, export killed), the pair's real differential delay against a named receiver class, both legs' RTP identical | [T29](test-29-moq-distributed-resilience.md), [T12](test-12-dual-path-handoff.md) |
| P1-j | Permanence through a CDN-hosted relay: the passthrough lane's ramp and soak once the node serves its joins, and the demultiplexed soak again on a release whose memory is flat; later, more than one hop | Every fan-out figure is one relay in one region ([Evidence](evidence.md) §6), so the R2 row reads *indicated* ([Comparison](../docs/comparison.md) §13) | Passthrough: the node's fixes (moqx#795, #817); the re-soak: moqx#874's fix on the test nodes | 72 h with the wire grader on, reconnects counted with gap and cause, the path's loss and RTT recorded; both ramps read against the node's own stats | [T52](test-52-cdn-relay-fanout.md) |
| P1-ad | The latency ordering on a long, lossy path: SRT and both MoQ lanes from the primary to a host in a distant region (80–150 ms RTT), clean and at two loss rates | Every ordering is loopback or one 12.8 ms path ([Evidence](evidence.md) §3.11; §5 row 4), and a long, lossy path is the case that should favour the tunnels | A host in a distant region (the author's go-ahead) | Each lane's matched-PTS latency at equal conformance, and its delivered programme, per condition, three replicates | [T18](test-18-delivery-latency.md) |
| P1-af | [T58](test-58-receiver-select.md)'s uplink outage: the serving leg's importer cut off from its relay for less and more than the receive timeout and the QUIC idle timeout | The one failure class T58 has not run, and the one whose leg can come back on its own session | a Linux host (`iptables`), with no other timing work on it | The outage rows of T58's table, graded against its C0–C2 | — (T58's rig has no outage cell yet) |
| P1-ac | Revocation at scale on a second implementation: a subset of a fan-out's subscribers withdrawn on P1-j's relay | Every revocation result is `moq-relay` on loopback ([Evidence](evidence.md) §3.10); on moqx v0.3.6 a live session outlives its token and a key is withdrawn only by a restart ([T53](test-53-token-interop.md)) | P1-j's relay taking our tokens, and a moqx release that reloads its keys | Time to effect and collateral on the kept subscribers, against T37's | [T53](test-53-token-interop.md) |
| P1-l | The telemetry return path end to end, run inside P1-j's window | Delivered-media health at a subscriber is satisfied by no candidate ([Comparison](../docs/comparison.md) gates); closes T39 Part B | — (`import --echo-path`, `import --report` and `export echo` are on `main`) | Each subscriber's feedback (or a CMCD Event Timeline track) and the TS health counters read back over the same relay, from every subscriber of a P1-j step; T32's faults graded against each | [T39](test-39-cross-boundary-observability.md) § *Open* |
| P1-ag | Path faults on the current segmented chain: T28's shapes at its durations in its `netns`/`cake` rig, beside its MoQ and SRT rows at matched latency, the origin's TCP on CUBIC and on BBR (T68 part A; the cushion and the catch-up have run) | The lane's fault figures are the first chain's, on loopback, and its loss collapse at 100 ms RTT is attributed to the origin's controller by reasoning | — | T68 criteria 7–10: media lost per shape, three replicates, at T28's 5.91 s and 11.87 s columns | [T68](test-68-segmented-chain-cushion-faults.md) |
| P1-am | T30's remainder: Cell 2, two packager hosts over one NFS store (each killed, the store partitioned) | Criterion 2, the only distributed one, is unrun | three hosts (the tertiary as store) | T30's criterion 2 | [T30](test-30-segmented-distributed-resilience.md) |
| P1-ah | Latency against the 5–10 s budget: 1 s and 2 s segments at their minimum cushions (on loopback at 2 s, 3 s with hold and alignment and 1.5 s with neither: T68), graded on P1/P2 and the 13818-1 buffer model, over the internet path | The segmented wire is ungraded at the buffer model ([Comparison](../docs/comparison.md) §8, §13.1) and its 9,286 ms is one configuration | — | Matched-PTS latency with the P1/P2 and T-STD verdicts of the same bytes, per configuration | [T16](test-16-grooming-segmented-http.md), [T44](test-44-tstd-grading.md) |
| P1-aj | Permanence to the gate's 7 days: [T62](test-62-origin-group-soak.md)'s design on the fixed groomer, PTS graded against PCR on the merged wire, with a withdrawal rule that does not take both pathways down on damage they share | *Permanent operation* reads *unknown* for the lane ([Comparison](../docs/comparison.md) §13.1); in T62's 72 h the withdrawal cost 54 s and the groomer's clock was wrong for 43 h | — | 7 days holding T62's C1 and C3–C6, PTS within 2 s of PCR throughout, programme lost only where the contribution lost it | [T62](test-62-origin-group-soak.md) |
| P1-ak | Observability: B-8's HLS telemetry beside TSDuck's TR 101 290 counters (`influx`), on T22, T24 and T32's faults; CMCD v2 from B-8 into CloudFront's logs and an event-mode collector | R8 on this lane, and whether CMCD v2 is enough for a NOC | B-8; B-7 for the logs | Each fault's detection time and signal per source; which CMCD v2 keys reach the logs; what CMCD cannot express | [T32](test-32-observability-survey.md) |
| P1-al | Access and scrambling on the segmented lane: CAT (CTA-5007-B) on CloudFront with AES-128 segment keys, against what BISS-CA gives the route; and a scrambled source through `tsp -O hls`, descrambled after the receiver. The MoQ lanes ran ([T66](test-66-scrambled-carriage.md)) | R7 on this lane is derived ([Comparison](../docs/comparison.md) §7); neither `--intra-close` nor our segmenter, which names segments from PES timestamps, can cut a scrambled source | B-7 for CAT | Revocation timed at the edge; the BISS-CA properties kept and lost; the descrambled feed identical to the clear source | — (specified when run) |
| P1-ae | Encrypted carriage through a third-party relay, both lanes | [Control](../docs/control-plane.md) §7.3 offers upstream's object-level encryption as a contract option, by design and unmeasured: relays and caches hold only ciphertext | Upstream E2EE through `moq-mux` (quests `net-wrap/mux`, `e2ee/rust-publish`) | Each lane's export identical to an unencrypted control through P1-j's relay, the relay holding only ciphertext, the per-frame overhead measured, and a re-key drill timed | — (specified when the gate clears) |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
|---|---|---|---|---|
| P2-a | What commercial monitoring would have caught: the vendor survey | — (outreach, not apparatus) | Survey answers mapped against the measured fault-to-telemetry table | [T32](test-32-observability-survey.md) |
| P2-e | Replicates for the segmented congestion rungs | — | Every segmented rung at three replicates (the MoQ rungs and the delay matrix are) | [T31](test-31-congestion-capacity-ladders.md) |
| P2-i | T12's churn arms: the recovered-leg and late-join cells, with a grader | — (upstream's planned per-group counters would be a second subject) | Both cells graded against our keyframe-restart padding filter | [T12](test-12-dual-path-handoff.md) |

**Open in the paper, with no experiment scheduled.** [Evidence](evidence.md) §5 row 12 (a
CDN edge under loss at 100 ms RTT) falls inside P1-ag's path shapes; rows 10 (a third source
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
| `route-health/recovery` | L | P1-b; [Architecture](../docs/architecture.md) §5 | Relays would leave a stalled route for a same-epoch standby, before the idle timeout, without a 2022-7 receiver | Its design, which the maintainer has claimed (#7096); epochs on every hop, which only moq-lite 07 will carry (`ietf-epoch-cut`, taken by #7239), so not P1-j's moqx hop |
| `qos-publisher-timeliness` | M | P1-l | A health verdict per publisher from the relay alone; the per-subscriber verdict is on `main` | The lag histogram whose type it reuses, which waits on moq-net's QUIC acknowledgments |

Set aside: the QoS line's lag histogram (R8 only), the E2EE line beyond P1-ae's gate (a contract option, not a requirement:
[Control](../docs/control-plane.md) §7.3), `broadcast-fairness` (tenants sharing a cluster link; one
operator's channels until P1-j's second hop), `perf/shard-default` (our relay's knee, which P1-j's
supersedes), `auth-token-fetch` (a gate for P1-ac's moqx arm only if moqx asks a token of FETCH).

## Blocked on apparatus

| Gate | State | Unblocks |
|---|---|---|
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d |
| **B-7** CloudFront for the campaign's AWS user: distributions, functions, key-value stores, real-time logs | granted for distributions, functions, key-value stores and real-time log configs; Kinesis, S3 and listing cache policies denied, so real-time logs need Kinesis granted | P1-aj, P1-ak's logs, P1-al's CAT |
| **B-8** An HLS receive front end feeding `tsp` or the groomer on stdin: retry, JSON telemetry, CMCD v2 keys | first increment built (`b8-hls-recv.py`: retry, telemetry, media-sequence regression and skips, release on the program date-time, a playlist's discontinuity signalled in the stream), with units for both ends ([`seg-units.sh`](scripts/seg-units.sh)); CMCD and CAT to build ([T30](test-30-segmented-distributed-resilience.md) § *Tooling*). Pathway fallback is not needed: the origin group fails over inside the CDN ([T61](test-61-origin-group-failover.md)) | P1-ak, P1-al |

**Inside the hardware window**, which the analyser and IRDs share, measure against the live feed; debug
no harness and run no cell that needs no hardware. [T33](test-33-gate2-preparation.md) orders the work.

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **Closed or commercial components** (an ABR-to-TS gateway, a commercial packaging edge): the
  evaluation covers open, interoperable components only. [T14](test-14-data-plane-comparison.md)'s
  cells that needed them stay empty. This does not close the segmented lane to commercial receivers:
  a receive profile the distributor publishes, with an open reference receiver, is one Ateme's,
  Sencore's or any vendor's HLS input may implement ([Economics](../docs/economics.md) §8.5).
- **Low-Latency HLS**: 5–10 s qualifies the segmented lane.
- **MPTS carriage**: deliveries are single-programme; [T10](test-10-mpts-multiservice.md) stands.
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
- **BISS-CA's key ladder** (ECMs and EMMs an IRD would accept): T66 carried the scrambling without
  it; the ladder needs a BISS-CA head-end and an entitled receiver, the requirement is unestablished,
  and [Control](../docs/control-plane.md) §9 records the commercial half as deciding.
