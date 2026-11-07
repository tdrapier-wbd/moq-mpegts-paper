# What remains to be done

The campaign's forward roadmap: what is outstanding, why it matters, what gates it, and when it is done. Protocols, pass criteria and results live in the `test-*.md` file each entry names; nothing here records what has already been learned. **When nothing of an entry is outstanding, delete it.** An entry earns its place only if it could change a named claim in `docs/`.

**Priority** is by what a result could change. **P0** could change a viability conclusion, and nothing else competes for a run window while a P0 is runnable. **P1** sharpens or reverses a verdict row. **P2** is completeness; a P2 that starts to look like it could change a conclusion has been mis-tiered. The **Gate** column names what must happen first (`—` means runnable now); gates are defined [below](#blocked-on-apparatus).

## P0 — could change a viability conclusion

| # | What remains | Why it matters | Gate | Done when | Protocol |
| --- | --- | --- | --- | --- | --- |
| P0-k | Hardware TR 101 290 P1/P2 soak of groomed output, ≥ 72 h, including ST 2022-7 under loss, with the source-clock-drift and mid-stream PID-change fixtures | The top open question ([Evidence](evidence.md) §5, rows 1 and 6): the grooming design is software-validated, not broadcast-acceptable | B-6 | A `hardware:` domain P1/P2 result on both lanes over the full window, accuracy from the bytes and overall jitter and delay factor on arrival at the RTP input; 2022-7 graded under loss on two passthrough legs' RTP, each from a stream-clocked groomer, at the receiver's class; both fixtures graded; the site network's UDP and QUIC posture recorded | [T7](test-7-timing-integrity.md) |
| P0-d | The analyser-specific rows of the Gate 2 acceptance harness | Completes the acceptance test the harness was built for | B-6 | Every analyser row of T33's fixed pass table taken | [T33](test-33-gate2-preparation.md) |

## P1 — establishes where one architecture is superior

| # | What remains | Why it matters | Gate | Done when | Protocol |
| --- | --- | --- | --- | --- | --- |
| P1-b | 1+1 across two distribution chains: two passthrough legs of one broadcast, each through a stream-clocked groomer into RTP, one through our relay and one through P1-j's, merged by a 2022-7 receiver while one chain fails | [Architecture](../docs/architecture.md) §5's active/active from the importer on is measured on one host or two over our own relays, under `netem` | P1-j's relay | Hitless through each failure class on one chain (relay restart, path outage, export killed), the pair's real differential delay against a named receiver class, both legs' RTP identical | [T29](test-29-moq-distributed-resilience.md), [T12](test-12-dual-path-handoff.md) |
| P1-j | Permanence through a CDN-hosted relay: the passthrough lane's ramp and soak, and the demultiplexed soak again on v0.3.7, which carries #874's memory fix; later, more than one hop | Every MoQ fan-out figure is one relay in one region ([Evidence](evidence.md) §4), so its R2 cell reads _indicated_ ([Comparison](../docs/comparison.md) §11.1) | T76's end, whose hosts publish and receive, and the operator's dates; both test nodes run v0.3.7 and serve the joins ([T52](test-52-cdn-relay-fanout.md)) | 72 h with the wire grader on, reconnects counted with gap and cause, the path's loss and RTT recorded; both ramps read against the node's own stats | [T52](test-52-cdn-relay-fanout.md) |
| P1-ac | Revocation at scale on a second implementation: a subset of a fan-out's subscribers withdrawn on P1-j's relay | Every revocation result is `moq-relay` on loopback ([Evidence](evidence.md) §3.10); on moqx v0.3.6 and v0.3.7 a live session outlives its token and a key is withdrawn only by a restart ([T53](test-53-token-interop.md)) | P1-j's relay taking our tokens, and a moqx release that reloads its keys | Time to effect and collateral on the kept subscribers, against T37's | [T53](test-53-token-interop.md) |
| P1-l | The telemetry return path at scale, run inside P1-j's window, with a fault made between relay and subscriber | Delivered-media health at a subscriber is satisfied by no candidate ([Comparison](../docs/comparison.md) gates); loopback names partial faults only (T39 Part B) | P1-j's relay | Each subscriber's feedback read back over the same relay, from every subscriber of a P1-j step, and a fault only the report can reveal named from it | [T39](test-39-cross-boundary-observability.md) § _Part B_ |
| P1-ao | T72's MoQ arm: both MoQ lanes through P1-j's relay under T28's last-mile shapes at T72's columns, the relay's loss counters beside, a qlog of one focused cell | Through a CloudFront edge the segmented lane's loss is the edge's TCP's ([Evidence](evidence.md) §3.3); whether a CDN relay's QUIC, which the operator neither sets nor sees, decides the MoQ lanes' likewise | P1-j's window; the synthetic fixture only | Each shape's loss at both columns against T28's MoQ row and T72's edge row | [T72](test-72-segmented-cdn-edge-impairment.md) |
| P1-aq | Stock receivers behind the origin group: T61's six cells with `tsp -I hls` as both legs' fetchers, each under a supervisor, and one cell dropping every packet on one leg's path for 30 s | [Comparison](../docs/comparison.md) §6.2 reads "no off-the-shelf TS client survives an origin restart" from T6, where clients faced the origin; behind T61's group they saw no failed fetch, so what reaches a receiver is an edge or path failure, which the merge covers | T61's rig (`t59-cell.sh`, the guard, the group); after P1-aj's soak, which holds it. The fetchers run under [`p1aq-stock-recv.py`](scripts/p1aq-stock-recv.py); GStreamer is left out, as its HLS elements send the viewer key on the first playlist request only | Per cell T61's criteria 2–4 on each leg and the merge; the cut leg's rejoin graded against the merge | [T61](test-61-origin-group-failover.md) |
| P1-aj | Permanence to the gate's 7 days: [T62](test-62-origin-group-soak.md)'s design on the fixed groomer, PTS graded against PCR on the merged wire, with a withdrawal rule that withdraws only on damage one pathway alone carries | _Permanent operation_ reads _not cleared_ for the lane ([Comparison](../docs/comparison.md) §11.1); in T62's 72 h the withdrawal cost 54 s and the groomer's clock was wrong for 43 h | running | 7 days holding T76's criteria: T62's C1 and C3–C6, PTS within 2 s of PCR throughout, programme lost only where the contribution lost it | [T76](test-76-seven-day-soak.md) |
| P1-ae | Encrypted carriage through a third-party relay, both lanes | [Control](../docs/control-plane.md) §7.3 offers upstream's object-level encryption as a contract option, by design and unmeasured: relays and caches hold only ciphertext | Upstream E2EE through `moq-mux` (quests `net-wrap/mux`, `e2ee/rust-publish`) | Each lane's export identical to an unencrypted control through P1-j's relay, the relay holding only ciphertext, the per-frame overhead measured, and a re-key drill timed | — (specified when the gate clears) |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
| --- | --- | --- | --- | --- |
| P2-a | What commercial monitoring would have caught: T32's five outreach questions, best as fixture trials | vendor contacts (the author) | Each question answered or marked unanswered, and the gap list published against T32's fault table | [T32](test-32-observability-survey.md) |
| P2-o | Mid-stream PID and PCR-PID change through the media-aware lane, the one boundary of [Architecture](../docs/architecture.md) §4.3 that has met no stage, on real coded video: the clip's video PID remapped from a point onward with its PMT version raised, the fixture T33 could not build and P0-k needs | — | Import, export and groomer each graded at the change against an unchanged control: continuity, content gap, PMT and PCR PID followed, PTS against PCR | [T33](test-33-gate2-preparation.md) Part A item 4 |
| P2-p | The groomer's buffer bound on a real encode: T19's ladder on the live feed's 300 s capture (hardware encoder, 25 Mb/s) through the media-aware lane | — | Content conserved and PCR repetition graded at 2.5× and 3.6× the capture's peak-frame carriage and between, so the coefficient of [Architecture](../docs/architecture.md) §12 question 2, set on three synthetic 9.4 Mb/s sources, holds or moves | [T19](test-19-pcr-grid-verification.md) measurement 11 |

**Open in the paper, with no experiment scheduled:** the [Evidence](evidence.md) §5 rows no entry above names, and the control strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions). Of the deployment milestones ([lab README](README.md)), operations has P1-l and P2-a but nothing for NOC tooling or an SLA.

## Upstream quests worth building

Untaken quests on upstream `main` whose result would move an entry above, ranked by weight for primary distribution. A row leaves when a pull request takes it; ours are in the [upstream ledger](upstream-contributions.md).

| Quest | Size | Would move | Why it ranks here | Gate |
| --- | --- | --- | --- | --- |
| `route-health/recovery` | L | P1-b; [Architecture](../docs/architecture.md) §5 | Relays would switch from a route lagging a same-epoch standby by more than the reader's delay, before the idle timeout, without a 2022-7 receiver | Deferred upstream (m5), behind clustering, federation and P2P; its metadata-subscription and route-selection quests; epochs on every hop, which moq-transport no longer carries (#7239), so never P1-j's moqx hop |
| `qos-publisher-timeliness` | M | P1-l | A health verdict per publisher from the relay alone; the per-subscriber verdict is on `main` | The lag histogram whose type it reuses, which waits on moq-net's QUIC acknowledgments |

Set aside: the QoS line's lag histogram (R8 only), the E2EE line beyond P1-ae's gate (a contract option, not a requirement: [Control](../docs/control-plane.md) §7.3), `broadcast-fairness` (tenants sharing a cluster link; one operator's channels until P1-j's second hop), `perf/shard-default` (our relay's knee, which P1-j's supersedes), `auth-token-fetch` (a gate for P1-ac's moqx arm only if moqx asks a token of FETCH).

## Blocked on apparatus

| Gate | State | Unblocks |
| --- | --- | --- |
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | promised alongside the live feed; not arrived | P0-k, P0-d |
| **Inside the hardware window**, which the analyser and IRDs share, measure against the live feed; debug no harness and run no cell that needs no hardware. [T33](test-33-gate2-preparation.md) orders the work. |

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **Closed or commercial components** (an ABR-to-TS gateway, a commercial packaging edge): the evaluation covers open, interoperable components only. [T14](test-14-data-plane-comparison.md)'s cells that needed them stay empty. This does not close the segmented lane to commercial receivers: a receive profile the distributor publishes, with an open reference receiver, is one Ateme's, Sencore's or any vendor's HLS input may implement ([Economics](../docs/economics.md) §8.5).
- **Low-Latency HLS** (parts): the segmented lane is qualified on whole segments, down to [T70](test-70-segmented-latency-budget.md)'s one second.
- **MPTS carriage**: deliveries are single-programme; [T10](test-10-mpts-multiservice.md) and [T77](test-77-mpts-through-cloudfront.md) stand.
- **LEO links for primary distribution.**
- **The lab re-multiplexer's 550–600 ms floor**: the merged export superseded it as the live stage, and the export's own floor is [T47](test-47-fixed-delay-export.md)'s.
- **Re-runs of answered arms**: the arrival oracle on a bigger host ([T19](test-19-pcr-grid-verification.md)); another clean two-host 1+1 arm or two-relay topology (what remains is P1-b); the congestion cells under an AQM, or a lower-layer mechanism for the shed ([T8b](test-8b-congestion-control.md)); another segmented HTTP/3 arm ([T20](test-20-segmented-http3.md)); more transparency clips across lanes already characterised; the self-hosted relay's fan-out past N = 100 ([T26](test-26-cross-host-fanout.md)), which P1-j's CDN relay supersedes as the deployment's.
- **The wire-cost leg on the EC2 path** (its HTTP-layer term is path-independent), and per-track wire-byte attribution.
- **An in-process UDP sink for `export ts`**: upstream declined it, and `tsp` does the socket work ([upstream contributions](upstream-contributions.md) § _A UDP sink for `export ts`_).
- **FEC on the MoQ lane**: SRT's lead in [T28](test-28-failure-injection-matrix.md)'s matched ladder is retransmission alone (no packet filter ran), QUIC already retransmits, and FEC pays only on a budget of a few round trips. The gap is in QUIC's controller, outage recovery, reorder thresholds and liveness, which T28 measures.
- **BISS-CA's key ladder** (ECMs and EMMs an IRD would accept): T66 carried the scrambling without it; the ladder needs a BISS-CA head-end and an entitled receiver, the requirement is unestablished, and [Control](../docs/control-plane.md) §10 records the commercial half as deciding.
