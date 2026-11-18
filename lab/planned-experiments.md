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
| P1-b | 1+1 across two distribution chains: two passthrough legs of one broadcast, each through a stream-clocked groomer into RTP, one through our relay and one through P1-j's, merged by a 2022-7 receiver while one chain fails | [Architecture](../docs/architecture.md) §5's active/active from the importer on is measured on one host or two over our own relays, under `netem` | A window on P1-j's relay the operator has not been asked for: his agreed schedule ends with P1-j's soaks | Hitless through each failure class on one chain (relay restart, path outage, export killed), the pair's real differential delay against a named receiver class, both legs' RTP identical | [T29](test-29-moq-distributed-resilience.md), [T12](test-12-dual-path-handoff.md) |
| P1-j | Permanence through a CDN-hosted relay: the passthrough lane's soak, and the demultiplexed soak again on v0.3.7, which carries #874's memory fix; later, more than one hop | Every MoQ fan-out figure is one relay in one region ([Evidence](evidence.md) §4), so its R2 cell reads _indicated_ ([Comparison](../docs/comparison.md) §11.1) | Both soaks running ([T52](test-52-cdn-relay-fanout.md)) on `d66c892833`, the client until upstream's `main` delivers the catalog to a late joiner through a draft-18 relay | 72 h with the wire grader on, reconnects counted with gap and cause, the path's loss and RTT recorded; the v0.3.7 ramps read against the node's own stats | [T52](test-52-cdn-relay-fanout.md) |
| P1-ac | Revocation at scale on a second implementation: a subset of a fan-out's subscribers withdrawn on P1-j's relay | Every revocation result is `moq-relay` on loopback ([Evidence](evidence.md) §3.10); on moqx v0.3.6 and v0.3.7 a live session outlives its token and a key is withdrawn only by a restart ([T53](test-53-token-interop.md)) | Two things not yet asked or released: the operator's node verifying our tokens, and a moqx release that reloads its keys without a restart ([moqx#786](https://github.com/openmoq/moqx/issues/786)) | Time to effect and collateral on the kept subscribers, against T37's | [T53](test-53-token-interop.md) |
| P1-ax | T37's arms on current `main`, whose relay leases each grant, renews it in band and re-checks its sessions when told to | [Control](../docs/control-plane.md) §4.1 and §8's two binding criteria rest on a September 2026 relay: three `Cache-Control` settings disabled revocation, no re-check could be pushed, an outage was honoured an hour | — | Each of T37's arms graded again, and a commanded re-check's time to effect against the polled bound | [T37](test-37-entitlement-revocation.md) |
| P1-l | The telemetry return path at scale, run inside P1-j's window, with a fault made between relay and subscriber | Delivered-media health at a subscriber is satisfied by no candidate ([Comparison](../docs/comparison.md) gates); loopback names partial faults only (T39 Part B) | P1-j's window; the fault is made on our side, so nothing more is asked of the operator | Each subscriber's feedback read back over the same relay, from every subscriber of a P1-j step, and a fault only the report can reveal named from it | [T39](test-39-cross-boundary-observability.md) § _Part B_ |
| P1-aw | An IRD's input switch between SRT and a new-plane send; a hardware 2022-7 merge of T83 Part A's pairs | Only hardware shows whether an IRD rides a cut whose tables change | B-6 | Criterion 12 reported | T83 Part E |
| P1-ae | Encrypted carriage through a third-party relay, both lanes | [Control](../docs/control-plane.md) §7.3 offers upstream's object-level encryption as a contract option, by design and unmeasured: relays and caches hold only ciphertext | Upstream E2EE through `moq-mux`: quests `net-wrap/mux` (L) and `e2ee/rust-publish` (M), both in upstream's deferred milestone (m5), behind the net-wrap traits line; not soon | Each lane's export identical to an unencrypted control through P1-j's relay, the relay holding only ciphertext, the per-frame overhead measured, and a re-key drill timed | — (specified when the gate clears) |

## P2 — completeness

| # | What remains | Gate | Done when | Protocol |
| --- | --- | --- | --- | --- |
| P2-a | What commercial monitoring would have caught: T32's five outreach questions, best as fixture trials | vendor contacts (the author) | Each question answered or marked unanswered, and the gap list published against T32's fault table | [T32](test-32-observability-survey.md) |
| P2-o | Mid-stream PID and PCR-PID change through the media-aware lane, the one boundary of [Architecture](../docs/architecture.md) §4.3 that has met no stage, on real coded video: the clip's video PID remapped from a point onward with its PMT version raised, the fixture T33 could not build and P0-k needs | — | Import, export and groomer each graded at the change against an unchanged control: continuity, content gap, PMT and PCR PID followed, PTS against PCR | [T33](test-33-gate2-preparation.md) Part A item 4 |
| P2-p | The groomer's buffer bound on a real encode: T19's ladder on the live feed's 300 s capture (hardware encoder, 25 Mb/s) through the media-aware lane | — | Content conserved and PCR repetition graded at 2.5× and 3.6× the capture's peak-frame carriage and between, so the coefficient of [Architecture](../docs/architecture.md) §12 question 2, set on three synthetic 9.4 Mb/s sources, holds or moves | [T19](test-19-pcr-grid-verification.md) measurement 11 |
| P2-q | T82 Part D's storm with its abusers on a second host, two storms per cell: are the victims' group skips the relay's, and is main's memory after a storm a high-water mark ([Evidence](evidence.md) §3.14)? It scopes [Architecture](../docs/architecture.md) §8.4 | An EC2 host | T82's criterion 1 with no abuser on the relay's host; the memory after a second storm against the first | [T82](test-82-slow-unresponsive-subscribers.md) Part D |
| P2-r | `moq2ts`'s output conformance: T7's TR 101 290 and T19's PCR grid on its receiver's output, its publisher to its receiver through a relay, on the reference clips | `moq2ts` built headless on the laptop | P1/P2 errors and PCR intervals per clip, beside `moq-dev`'s | [T7](test-7-timing-integrity.md), [T19](test-19-pcr-grid-verification.md) |
| P2-s | `moq2ts` at PCR discontinuities: T23's placed classes and T64's unflagged step back and forward, which cost `moq-dev`'s MoQ legs 6–12 s on the live feed where SRT lost nothing ([T83](test-83-mixed-plane-pair.md) Part C) | as P2-r | Programme lost per event, beside `moq-dev`'s | [T23](test-23-pcr-discontinuity-classes.md), [T64](test-64-synthetic-encoder-switch.md) |
| P2-t | `moq2ts` across restarts and a late join: T28's publisher and receiver restarts, T41's re-anchor | as P2-r | Gap and re-anchor per cell, beside `moq-dev`'s | [T28](test-28-failure-injection-matrix.md), [T41](test-41-import-reanchor-coverage.md) |
| P2-u | `moq2ts` under loss on the path: T5's netem ladder | as P2-r | Content lost and continuity errors at the output per rung | [T5](test-5-network-impairment.md) |
| P2-v | `moq2ts` on a multi-programme stream: T10's cells | as P2-r | Each programme's survival, and its PAT and PMT, per cell | [T10](test-10-mpts-multiservice.md) |
| P2-w | `moq2ts` on the live feed: T34's captured step and the 300 s capture through the pair | as P2-r | Units conserved against the capture on T83 Part C's grader; the step's cost | [T34](test-34-real-encoder-severity.md) |
| P2-x | Cross-vendor TS ingest and egress in the interop runner: one implementation's TS publisher (`moq import ts`, `moq2ts`) through each relay to another's TS subscriber (`moq export ts`), graded by the runner's `check-ts.py` | The runner's TS cells in its nightly (the client image built); a packaging both vendors read (`moq-dev` reads no MSFTS, [moq#3731](https://github.com/moq-dev/moq/issues/3731)); the media area's maintainers agreeing to publisher × checker pairing | Each pairing graded in the nightly, or its lack of a common packaging stated against [Comparison](../docs/comparison.md) §9.3's format row | [T11](test-11-interop.md) |

**P2-r to P2-w** put the campaign's tests to OpenMOQ's `moq2ts`: they grade [Comparison](../docs/comparison.md) §9.3's untested receiver and show whether a defect found here is MoQ's or one implementation's; a gap becomes a [cross-check](cross-check.md) row and a draft for OpenMOQ. Once they have run, their fixtures and graders are to be packaged and offered to OpenMOQ (the author's go-ahead), so its builds can run them.

**Open in the paper, with no experiment scheduled:** the [Evidence](evidence.md) §5 rows no entry above names, and the control strand's clustering and rights windows ([Control](../docs/control-plane.md), open questions). Of the deployment milestones ([lab README](README.md)), operations has P1-l and P2-a but nothing for NOC tooling or an SLA.

## Upstream quests worth building

Untaken quests on upstream `main` whose result would move an entry above, ranked by weight for primary distribution. A row leaves when a pull request takes it; ours are in the [upstream ledger](upstream-contributions.md).

| Quest | Size | Would move | Why it ranks here | Gate |
| --- | --- | --- | --- | --- |
| `qos-publisher-timeliness` | M | P1-l | A health verdict per publisher from the relay alone; the per-subscriber verdict is on `main` | None: it now defines the histogram type the lag histogram reuses; not taken |

Set aside: the QoS line's lag histogram (R8 only), the E2EE line beyond P1-ae's gate (a contract option, not a requirement: [Control](../docs/control-plane.md) §7.3), `broadcast-fairness` (tenants sharing a cluster link; one operator's channels until P1-j's second hop) `perf/shard-default` (our relay's knee, which P1-j's supersedes) and `ts-step-damage` (one stream's step; every step met so far moved the whole multiplex).

## Blocked on apparatus

| Gate | State | Unblocks |
| --- | --- | --- |
| **B-6** A professional DVB analyser and a bank of IRDs, on loan | no analyser or IRD bank on loan; a broadcast engineer has been asked (ticket open) to take four SRT sends into his IRDs and analyser, his listeners and window awaited | P0-k, P0-d, P1-aw |
| **Inside the hardware window**, which the analyser and IRDs share, measure against the live feed; debug no harness and run no cell that needs no hardware. [T33](test-33-gate2-preparation.md) orders the work. |

## Deliberately not doing

Recorded so they are not proposed again; where a result exists, it is in the file named.

- **Closed or commercial components** (an ABR-to-TS gateway, a commercial packaging edge): the evaluation covers open, interoperable components only. [T14](test-14-data-plane-comparison.md)'s cells that needed them stay empty. This does not close the segmented lane to commercial receivers: a receive profile the distributor publishes, with an open reference receiver, is one Ateme's, Sencore's or any vendor's HLS input may implement ([Economics](../docs/economics.md) §8.5).
- **Low-Latency HLS** (parts): the segmented lane is qualified on whole segments, down to [T70](test-70-segmented-latency-budget.md)'s one second.
- **MPTS carriage**: deliveries are single-programme; [T10](test-10-mpts-multiservice.md) and [T77](test-77-mpts-through-cloudfront.md) stand.
- **LEO links for primary distribution.**
- **Re-runs of answered arms**: the arrival oracle on a bigger host ([T19](test-19-pcr-grid-verification.md)); another clean two-host 1+1 arm or two-relay topology (what remains is P1-b); the congestion cells under an AQM, or a lower-layer mechanism for the shed ([T8b](test-8b-congestion-control.md)); another segmented HTTP/3 arm ([T20](test-20-segmented-http3.md)); more transparency clips across lanes already characterised; the self-hosted relay's fan-out past N = 100 ([T26](test-26-cross-host-fanout.md)), which P1-j's CDN relay supersedes as the deployment's.
- **The wire-cost leg on the EC2 path** (its HTTP-layer term is path-independent), and per-track wire-byte attribution.
- **An in-process UDP sink for `export ts`**: upstream declined it, and `tsp` does the socket work ([upstream contributions](upstream-contributions.md) § _A UDP sink for `export ts`_).
- **FEC on the MoQ lane**: SRT's lead in [T28](test-28-failure-injection-matrix.md)'s matched ladder is retransmission alone (no packet filter ran), QUIC already retransmits, and FEC pays only on a budget of a few round trips. The gap is in QUIC's controller, outage recovery, reorder thresholds and liveness, which T28 measures.
- **BISS-CA's key ladder** (ECMs and EMMs an IRD would accept): T66 carried the scrambling without it; the ladder needs a BISS-CA head-end and an entitled receiver, the requirement is unestablished, and [Control](../docs/control-plane.md) §10 records the commercial half as deciding.
