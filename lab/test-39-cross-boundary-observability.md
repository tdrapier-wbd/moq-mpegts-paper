# Test 39 — Observability across an administrative boundary

**State: Parts A and C run and passed; Part B, the return path, is measured on loopback on late October 2026 `main` (in no release): it carries the client edge's report on one scoped credential and names a dead audio or video stream, and it reads a total stall as silence and ends with its exporter. The run at scale is [P1-l](planned-experiments.md#p1--establishes-where-one-architecture-is-superior).** Tier placement and the reasoning for it are in _Tiering_ below, including the one place this stretches a tier.

**Headline.** A standalone process at the client edge, on its own subscription, **catches a T24-class partial-media fault that no relay-side telemetry can express** — _measured_: the suppressed audio PID alarmed on its own at media t=25.025 s with every other elementary stream still delivering, while the groomer ran alongside it unmodified and the relay's counters carried no per-PID field in which the fault could appear. That settles the tier split the design rests on: **tier 2 can prove bytes flowed and can never prove the media was healthy**, so the only place the delivered signal can be assessed is hardware the broadcaster does not own.

**The return path is authorizable, protocol-legal and, on `main`, tooled — and it names partial faults, not total ones.** One token can carry a `--subscribe` prefix for media and an unrelated `--publish` prefix for telemetry, and a segment-aware relay routes both correctly (_measured_, six cells, Part C). An opaque telemetry payload on its own track is legal on both wires this relay speaks (_specified_, see _Open_). Upstream's solicited viewer feedback carries the subscriber's per-PID report back over the same relay on that one token, and the publisher side names a dead audio or video stream from it **4.1–6.1 s after onset, 1.4–2.6 s after a detector at the client edge itself** (_measured_, loopback, Part B). **It cannot name two faults:** a total stall changes nothing in the report and an unchanged report is not re-sent, so the publisher side hears the same silence as a lost return path; and a relay frozen past the QUIC idle timeout ends the subscriber's exporter, and its report with it.

## Objective

Establish what is observable about delivered media across the boundary between the broadcaster's infrastructure and the client's, and whether the entitlement credential the client already holds can carry a telemetry return path without new infrastructure.

The deployed topology is asymmetric in ownership:

```mermaid
flowchart LR
  P[Publisher<br/>ours] --> R[Relay / fabric<br/>ours or a vendor's]
  R -.->|administrative boundary| S[Subscriber<br/>client hardware]
  S --> G[Groomer<br/>client hardware]
  G --> D[Client's downstream]
```

[T32](test-32-observability-survey.md) asks whether commercial products expose a needed detector _within_ one administrative domain. This asks a different question: which side of the boundary each kind of evidence is available on, and what that costs.

## Tiering, and where this stretches one

The campaign's observability evidence divides by which side of the boundary can see it. The tiers are about _visibility_, not importance:

| Tier | Vantage | Owner | What it can establish |
| --- | --- | --- | --- |
| 1 | Publisher / ingest | Ours | Source conformance and liveness before anything is transported — `ts-pcr-timing.py`, `ts-liveness.py` at ingest |
| 2 | Relay / fabric | Ours **or a vendor's** | Session, byte, subscription and revocation state. Content-blind by construction |
| 3 | Client edge | **Theirs** | Per-PID liveness and PCR conformance on the signal actually delivered |

**Part A is tier 3 in isolation** and is placed there without qualification: a standalone process at the client-edge position, on its own subscription, with no groomer involvement. It needs no apparatus that does not already exist and no cooperation from the other tiers.

**Part B — the telemetry return path — is a tier-3 measurement whose _results_ have to reach tier 1, and that crossing is the thing being tested.** It is listed here rather than as its own experiment because the detector is Part A's and only the carriage differs.

**Part C is tier 2, and calling it that is a stretch worth flagging.** It measures what the relay will authorize and route, which is squarely tier 2, but it is here because it is a precondition for Part B rather than because anything in it is about observability. If it were graded as an entitlement result it would belong in [T38](test-38-entitlement-estate.md); it is kept here so that Part B's blocker is not mistaken for an authorization failure, which is precisely the confusion the starting hypothesis invited.

## What is already known, and precisely what it leaves open

| # | Established | Where | What it leaves open |
| --- | --- | --- | --- |
| 1 | A healthy transport does not imply a live programme | [T22](test-22-silent-media-plane-failure.md) | Nothing about who can see the difference |
| 2 | A partial stall passes the whole of TR 101 290 P1; an audio-only stall has no wire-observable signature | [T24](test-24-partial-media-plane-stall.md) | Whether the only detector that works can run where the boundary puts it |
| 3 | Per-PID access-unit counting catches every arm, and works at a cross-host groomed output | [T27](test-27-liveness-detector.md) | It was run on infrastructure we own end to end |
| 4 | The relay is QUIC-payload-blind by construction | [T36](test-36-entitlement-enforcement.md) | Whether its _published_ telemetry adds anything the log does not |
| 5 | `moq token sign` takes repeatable `--publish` and `--subscribe` | T37 environment notes | Whether both survive on one token, and whether the relay routes them independently |

**The starting hypothesis, which this experiment was told to verify rather than assume**, is that a token can carry a `--subscribe` prefix for media and an unrelated `--publish` prefix for `<affiliate>.telemetry`, routed correctly by a segment-aware relay, so a client edge can report back over the same relay under the same T36–T38 apparatus instead of a separate telemetry pipe. Part C tests exactly that and it holds. It is not sufficient, for reasons Part B gives.

## Environment

Parts A and C: build `moq` 0.11.0-`fd4f5d82e` / `moq-relay` 0.14.16-`fd4f5d82e` from `~/bin-3529/` (Part B's is in its procedure); groomer `mpegts-pacer` `5ab84cd`, **unmodified**. Loopback, macOS, `--server-quic-gso=false`. Source `contrib-5m.ts`: AVC video on PID 111 (also PCR), MPEG-1 audio on 121, AC-3 on 123, teletext on 131, three SCTE-35 PIDs. Detector `lab/scripts/ts-liveness.py`.

**The hard constraint on this experiment is that `mpegts-pacer` gets no changes.** Any client-edge capture is a standalone process on a duplicate subscription, never a groomer patch. Part A is constructed to demonstrate that the constraint is satisfiable concurrently rather than merely asserted: the groomer runs in the same lane, at the same time, with the flags it already takes.

## Procedure

### Part A — tier 3 in isolation

`lab/scripts/t39-clientedge-monitor.sh`. One publisher into one relay; three consumers at the client-edge position:

1. the groomer subscription, `moq export ts | mpegts-pacer - auto`, unmodified;
2. the monitor subscription, an independent `moq export ts` into `ts-liveness.py`;
3. the relay's own view, with `--stats-enabled --stats-interval 1 --stats-node edge1`.

The fault is T24-class and is built offline so its instant is known: twenty seconds of the clip followed by twenty seconds with the MPEG-1 audio PID removed, video and PCR untouched across the join and the PMT still declaring the audio. The harness verifies the fault is present in the source before publishing it, and aborts if it is not.

Detector thresholds are given explicitly (`--gap 111:1000,121:1500,123:1500`) rather than learned. Learning over this lane set every PID to 8,400 ms because the learning window contains the join transient; detection latency is [T27](test-27-liveness-detector.md)'s measurement, not this one's, and an 8.4 s threshold would have made the tier comparison meaningless.

### Part B — the telemetry return path

Publish the client edge's health report back over the same relay on the same credential, and read it at the publisher side. [`t39b-echo-return.sh`](scripts/t39b-echo-return.sh), graded by [`t39b-grade.py`](scripts/t39b-grade.py); loopback, build `419b799c7`, behind `moq auth serve`. The importer solicits feedback (`import --report --echo-path telemetry`); the subscriber, `export --echo affa ts --delay 2s`, publishes `telemetry/affa.echo` with one token that subscribes to `ch1/**` and publishes only `telemetry/affa.echo/**`. At the publisher side a reader holding only `telemetry/**` runs `export echo`, and a second runs `export report` on the importer's own report (tier 1). Part A's detector reads the subscriber's output as the client-edge comparator. Every line is stamped with wall time on arrival.

Arms, two trials each, on the first 75 s of `contrib-10m.ts`: **control**; **audio dead** and **video dead, PCR kept** (`ts-partial-stall.py`, at 20 s for 30 s, onset timed by the byte where the stimulus first differs from the control as it passes into the importer); **source stalled** (the regulator `SIGSTOP`ped 30 s); **relay frozen** (`SIGSTOP` 20 s, past this build's 10 s QUIC idle timeout). The report carries per-PID `units` and `quiet` and the release clock; the exporter runs no TR 101 290 checks, so none are expected.

Grading rules: an audio or video row, as the report classes it, is **stopped** at the first snapshot whose `units` equal a snapshot's at least 2.0 s earlier; the feedback is **absent** 3.0 s after the last snapshot. An arm's classification is its first alarm after onset: audio rows stopped with video advancing; the video row stopped with audio advancing; every row stopped with the feedback still arriving; or absent.

Pass criteria, fixed before the first run:

1. **The return path carries it.** In every arm, feedback reaches the reader at one snapshot per 1.5 s or better outside the fault, with a row for PIDs 111, 121 and 123; in the control, no alarm between 10 s after the first snapshot and the source's end (the negative control).
2. **The publisher side tells the faults apart**, in both trials: each fault arm is classified as its own fault, and the client-edge comparator alarms on the same PIDs (the positive control; a fault absent from the source aborts the arm).
3. **Soon enough to act on.** The first correct alarm at the reader within 6.0 s of the source's onset (the 2 s export delay, the 2 s rule, the 1 s cadence, and a margin), reported beside the comparator.
4. **It recovers.** The stopped rows advance again, or the feedback resumes, within 10 s of the fault's end.

Tier 1's report is recorded beside each arm and not graded.

### Part C — dual-scope credentials

`lab/scripts/t39-token-dualscope.sh`. Six cells over one token carrying both a `--subscribe` prefix for media and a `--publish` prefix for a telemetry path, checking that each is honoured for its own prefix and refused for the other's, and that a neighbouring tenant's telemetry path is refused.

**The oracle is the point.** A publish cell is scored by whether an independent, fully privileged subscriber can read back what was published — bytes at a subscriber, never a log line. The first version read each cell's verdict by grepping the publishing client's own log for an authorization error and reported that the relay admits publishes it should refuse; that was wrong, because the publishing client is told nothing either way. The run ends with an oracle control.

## Results

### Part A — the client edge sees what the relay cannot

_(file domain, P1 detector, loopback, single relay, build `fd4f5d82e`, groomer `5ab84cd` unmodified.)_

Source verified before publishing: part 1 132,427 packets carrying 2,689 audio packets on PID 121; part 2 129,805 packets carrying none.

| Vantage | What it reported |
| --- | --- |
| **Tier 3 — standalone monitor** | `alarm pid=121` at media t=**25.025 s**, the instant the detector armed (warm-up plus learning, 25 s; the fault began at 20 s), **localised**: every other elementary stream still delivering. The next alarm is 14.30 s later and is all remaining PIDs at once, i.e. the source ending |
| **Tier 2 — relay** | No per-PID field exists in which the fault could appear. Bytes, frames and groups continued |
| **Groomer** | 333,144 packets out, `buffer_high_water=10746`, `media_rate=9538593 b/s`. No flags added, no patch |

**The monitor localised the fault to one elementary stream while the service around it was healthy**, which is the distinction [T24](test-24-partial-media-plane-stall.md) established as the operationally important one — an alarm that fires when everything stops is the cheap clock-progression layer, and it is not sufficient. The harness classifies an alarm as localised only if other PIDs are still delivering behind it, so the end-of-stream alarm is not counted as a detection.

**What tier 2 published, in full.** The relay's stats are not a metrics endpoint. `/metrics` serves only `moq_relay_accept_failures_total{listener,class}` and `moq_relay_accept_stalled_seconds{listener}`; everything else is published as MoQ broadcasts of JSON tracks under `--stats-prefix` (default `.stats`), with `--stats-depth 1` giving a per-first-segment broadcast so a consumer can announce-scope to one tenant. The counters are, per broadcast path and split publisher/subscriber: `announced`, `announced_closed`, `announced_bytes`, `broadcasts`, `broadcasts_closed`, `subscriptions`, `subscriptions_closed`, `fetches`, `bytes`, `frames`, `groups`, `datagrams`; plus per auth root, `sessions` and `sessions_closed`.

**Audited against [Architecture](../docs/architecture.md) §9, tier 2 supplies about half of the systems-domain half and none of the broadcast-domain half:**

| §9 requirement | In the relay's published stats? |
| --- | --- |
| Session counts and health | **Yes** — `sessions`, `sessions_closed` per auth root |
| Per-track subscription counts | **Yes** — `subscriptions`, `broadcasts` per broadcast path |
| Cache hit/miss | **No** |
| Delivery latency and jitter | **No** — byte and frame counts only, no timing |
| Congestion and loss indicators | **No** |
| Control-plane operation latency | **No** |
| TR 101 290 P1/P2 status, PCR statistics, continuity integrity, service presence | **No, and not possible** — the payload is opaque |

The last row is the load-bearing one and it is not a gap to be filled: it is what [T36](test-36-entitlement-enforcement.md) established by construction. **No amount of relay telemetry reaches a T24-class fault**, so the broadcast-domain half of §9 is only ever satisfiable at tier 1 or tier 3, and across this boundary that means tier 3.

### Part C — one credential carries both directions

_Measured_, six cells, all passing, with an oracle control. A single token bearing `--subscribe` for the media prefix and `--publish` for the telemetry prefix is honoured for each on its own prefix and refused for the other's, and a neighbouring tenant's telemetry prefix is refused. Matching is segment-aware, so `ch1.telemetry` and `ch1` are distinct prefixes rather than one being a prefix of the other by string comparison.

**The starting hypothesis is confirmed at the authorization and routing layer.** The relay will let a client edge publish telemetry back over the same credential and the same relay, scoped so that it can reach nothing else.

**A side finding, and the subject of a drafted upstream report: a publishing client is never told its announce was refused.** The client connects, announces, is refused, and its log ends at "connected". Nothing distinguishes a working publish from a silently discarded one at the publisher. This is what made the first oracle wrong, and it is a worse problem for an unattended client-edge telemetry reporter than it was for a test harness — such a reporter would publish into a void indefinitely with no local indication.

### Part B — the report crosses back, and names partial faults only

_(loopback, MoQ lane, build `419b799c7` behind `moq auth serve`, export `--delay 2s`; faults at the source, read at the publisher side; two trials an arm, and two more each of audio and video with the comparator armed before onset.)_ Released tooling still cannot do this: every released `moq` source and sink is a media container, and the exporter refuses a telemetry-only transport stream for want of a track to carry PCR ([T33](test-33-gate2-preparation.md)).

| Arm | What the publisher side reads in the report | First alarm after onset | Client-edge detector | Importer's report (tier 1) | Back after the fault |
| --- | --- | --- | --- | --- | --- |
| control | one snapshot a second, every row; no alarm | — | — | — | — |
| audio dead | the MP2 row (121) stopped, video advancing | 5.14–6.13 s | 3.50–3.52 s | 2.94–3.92 s | 3.0–4.0 s |
| video dead, PCR kept | the video row (111) stopped, audio advancing | 4.13–5.13 s | 2.70–2.71 s | 2.96–3.96 s | 3.2–4.2 s |
| source stalled 30 s | **nothing**: the report stops arriving | 6.0 s, as absent | 5.9–6.0 s | audio and video rows at 1.8 s or 13.9 s, then silent | 0.25–0.96 s |
| relay frozen 20 s | **nothing**, and it never returns | 2.0 s, as absent | 5.9–6.0 s | none: its reader ended | never |

The client-edge detector column is from the armed trials; the stall and relay arms' are its clock-stopped alarm.

- **The report crosses on one scoped credential.** The subscriber's token subscribed to `ch1/**` and could publish only `telemetry/affa.echo/**`; the reader held only `telemetry/**`. Fourteen of fourteen trials delivered a snapshot every 1.0 s with every row, and neither control raised an alarm.
- **A dead audio or video stream is named at the publisher side**, the same PIDs the client-edge detector named in every trial. The AC-3 stream (123), carried verbatim, is reported as `data`: its `units` stop with the MP2's, but no rule on the report's classes grades it, and neither does upstream's stopped-stream log, so a dead AC-3 alone would go unnamed.
- **A total stall reads as silence.** With no frames arriving the exporter writes no program clock, so every count stops and `quiet`, measured on that clock, freezes (725–825 ms) instead of growing. The snapshot stops changing, and the snapshot encoder writes nothing for an unchanged value: no report reached the publisher side for 22–28 s of the 30. A lost return path looks the same. The importer's own report went silent the same way (29 s, and 13 s then 17 s); here the publisher's importer knew the source had stopped, but across a boundary, with the fault downstream, silence cannot say which.
- **A relay frozen past the idle timeout ends the report.** At this build's 10 s QUIC idle timeout every session dropped. The publisher and the feedback reader reconnected after the thaw; the subscriber's exporter, under its default `--follow 0s`, exited when its broadcast went away, and the report with it. The report lasts as long as the exporter process.
- **The report costs 1.4–2.6 s over the client-edge detector** on the same thresholds: one second of cadence, and a 2 s rule that over 1 s snapshots needs two or three of them. No relay-hop cost is visible on loopback. Tier 1 names a source fault first because it does not wait for the export delay; what the report adds is that the client edge received the same, and, not constructed here, faults that arise between the two.
- **Not alarm inputs on a fresh subscriber:** over the first 75 s of a healthy run the release clock's drift estimate ranged −123 to +352 ppm and its out-of-tolerance count reached 24–33. The exporter runs no TR 101 290 checks; the importer counted 42 `PTS_error` in each partial arm, one per 700 ms of the stopped stream.

**Against Part B's criteria:** 1, pass (14 of 14); 2, fail on the stall arm (6 of 8, then 4 of 4); 3, fail: video 4 of 4 and the relay arm 2 of 2, audio 1 of 4 (5.14 s; three at 6.13 s, because the criterion's bound counted the cadence once), the stall arm none; 4, fail on the relay arm.

## Metrics

- Whether the tier-3 detector alarms on the suppressed PID **with other PIDs still delivering** — a boolean, and the only one that distinguishes localisation from stream-end.
- Media time of each alarm, and the interval to the next, so an end-of-stream alarm is separable.
- The groomer's packet count and pacer summary, to show the monitor was additive.
- The relay's published counter set, enumerated from source and audited against §9 line by line.
- Part C: per cell, whether an independent privileged subscriber could read back what was published.
- Part B: per arm, what the publisher side reads in the report and when, beside the client-edge detector, the importer's own report, and recovery.

## Verdict against the pass criteria, fixed before running

| # | Criterion | Verdict |
| --- | --- | --- |
| 1 | A standalone client-edge process detects a T24-class fault on its own subscription | **Pass.** PID 121 alarmed at media t=25.025 s, localised |
| 2 | It does so with **zero** changes to `mpegts-pacer`, running concurrently | **Pass.** The groomer ran in the same lane with the flags it already takes and produced 333,144 packets |
| 3 | The relay's published telemetry is enumerated and audited against §9 rather than characterised | **Pass.** Twelve traffic counters and two presence counters, audited line by line |
| 4 | The dual-scope token hypothesis is **verified, not assumed**, either way | **Pass.** Six cells with a readback oracle and a control; it holds |
| 5 | The return path is either demonstrated end to end or its blocker identified and evidenced | **Pass, on loopback and on `main`.** Demonstrated (Part B): a dead audio or video stream is named at the publisher side; a total stall and a relay freeze are not, for the reasons given there. Released tooling still has no path |
| 6 | A correlation convention is found in upstream or its absence established, before any is invented | **Pass.** Found; see below. Nothing was invented |

### The correlation convention already exists and was not invented

[Architecture](../docs/architecture.md) §9 requires "a common correlation identifier [that] flows from publisher through fabric to gateway". Before designing one, the `moq-hang` draft, the catalog and `@moq/json` were checked. The shipped catalog already carries it: `rs/hang/src/catalog/timeline.rs` declares `pub wall: Option<u64>`, milliseconds since a MoQ epoch of 2020-01-01, and documents that a consumer "derives the wall-clock time of any group as `wall + pts`".

That is enough to attribute a client-edge observation to a publisher-side group without any new field: both ends name the same group by the same arithmetic. What it does **not** provide is clock synchrony between the two ends, and upstream is explicit that it will not — decision #2278 records that the library offers no clock-sync mechanism and that synchronisation is a declared deployment property. Across an administrative boundary that matters: the correlation is exact in _media_ time and only as good as the two sites' clock discipline in _wall_ time.

**Design consequence.** A cross-boundary telemetry summary should be keyed by group sequence and `wall + pts`, and should carry the reporting site's own clock offset as an explicit field rather than assuming it is zero. No new identifier is needed.

## Limits, stated in advance

- **Loopback, and a simulated boundary.** There is no administrative boundary in this run — both "sides" are one machine. What is demonstrated is that the _vantage_ works where the boundary puts it, not that it works across a real one with a real network and a real customer's change control.
- **The groomer's presence shows concurrency, not non-interference at scale.** One extra subscription on a loopback relay is not evidence about what N monitoring subscriptions cost a client's box.
- **Part A measures no detection latency**, and its figures must not be read as latencies. Thresholds were set explicitly to make the tier comparison legible; [T27](test-27-liveness-detector.md) is the authority, and it measured 1.0–3.1 s at a groomed monitoring point.
- **Part A: one fault class.** An audio-PID suppression; Part B runs the others.
- **Part B makes every fault at the source**, where the publisher's own importer sees it too. A fault arising between relay and subscriber, which only the report could reveal, is not constructed on loopback. Its latencies are quantised by the 1 s report cadence, from two to four trials an arm, on one build.
- **Part C's oracle proves readback, not refusal semantics.** A cell that reads back nothing is scored as refused; it does not distinguish a refusal from a publish that failed for another reason. The oracle control bounds this but does not eliminate it.
- **Nothing here measures a vendor-operated relay.** Tier 2 is "ours or a vendor's" in the design and entirely ours in the measurement, and a vendor's relay may publish more, less, or nothing.

## Corrections

**A slicing failure and a null detection look identical, and one of them was mine.** Part A's first two runs reported that the monitor did not catch the fault. It had not: `tsp -P until --seconds` does not exist, and `--milli-seconds` is wall-clock by default, so reading a file at disk speed it expires only after twenty seconds of _reading_ — by which point the whole 372 MB clip has passed. The "20-second" part 1 was the entire clip and part 2 was empty, so the published stream had its audio throughout and the detector was correctly silent about a fault that was never built. The first attempt also sent the slicing errors to `/dev/null`. Two rules: **time-slicing a transport stream needs `--pcr-based`, because wall-clock and media time differ by the ratio of disk speed to bitrate**; and **a harness must assert that the fault is present in its own source before asking anything downstream about it** — this one now counts the PID in each part and aborts if the suppression did not take.

**A detector that learns its thresholds from a window containing the join transient is not armed.** Learning over this lane set every PID to 8,400 ms, because the threshold is a multiple of the worst spacing observed and the worst spacing was the start-up gap. It would not have been wrong, exactly — it would have alarmed eventually — but an 8.4 s threshold on a 1.5 s question measures the learning window rather than the lane. Where a test is about something other than detection latency, set the thresholds explicitly and say so. Explicit thresholds still arm only after `--warmup` plus `--learn` (25 s of media): Part B's comparator alarmed at arming, 8.4 s after a fault at 20 s, until `--warmup 2 --learn 0` armed it before the fault.

**"Permission" and "carriage" are different blockers and the hypothesis only named one.** The starting hypothesis asked whether the credential could carry both scopes. It can, and that did not make the return path available: on Part C's build no tool could carry a report. A verified hypothesis is not a working mechanism.

## Open

**An opaque telemetry track is legal at the wire-protocol level, so the return path is not a side-channel.** Checked directly rather than assumed:

- `draft-lcurley-moq-lite` states it three times: _"the transport is payload agnostic and can be proxied by relays/CDNs without knowledge of codecs, containers, or encryption keys"_; of a frame, _"The contents are opaque to the moq-lite layer"_; and FRAME's payload field is _"An application-specific payload."_
- `rs/moq-net`'s model agrees. `Frame` is a timestamp plus `payload: Bytes`. `track::Info` carries `timescale`, `latency_max`, `priority` and `ordered` — **no codec, MIME type or media typing of any kind.**
- The same holds on the moq-transport drafts (14–19) this relay also implements, so the answer does not depend on which of the two wires a peer speaks.

**A reporter is therefore an ordinary MoQ client using the standard wire protocol**, interoperable with any conformant implementation, and not an extension. That is the answer to the interoperability requirement.

**Proposed upstream as [#3608](https://github.com/moq-dev/moq/issues/3608), and adopted as solicited viewer feedback** (a catalog `echo` section, one `.echo` broadcast per viewer, the TS rows under `mpegts`; the [ledger](upstream-contributions.md) holds the history). It is not a wire-protocol change and no client is required to implement it. Part B measures it.

**No incumbent offers this, and the framing matters.** No open control plane and no transport protocol in current use gives an origin this visibility into a subscriber's delivered-media health — not WebRTC, SRT or RTMP, not HLS/CMAF/DASH. CMCD/CMSD is the nearest thing and is a different measurement: request and buffer state reported to a CDN, silent on whether the arriving media was intact. So there is no existing convention to copy or interoperate with, which is freedom and risk in the same place, and it is a reason to think carefully about the schema rather than a reason not to propose it. Two consequences for how this experiment's results may be used: **nothing here is a deficiency of MoQ against an incumbent**, because no incumbent offers it either; and **no adoption decision turns on it**, so it must not appear in a verdict table as a point for or against a data plane. It is recorded as a real operational gap a distributor meets at fleet scale, whose mechanism happens to be unusually close to hand on this plane.

**The route deliberately not taken: the groomer.** `mpegts-pacer` already decodes the stream and already counts per-PID access units for [T27](test-27-liveness-detector.md)'s detector, so emitting this telemetry from there is a small amount of code and by far the fastest path to the measurement. It is rejected on purpose. The groomer is kept minimal and non-proprietary, and a health-reporting channel inside one distributor's grooming binary is a capability only that distributor's receivers can offer — which forfeits exactly the interoperability that makes the observation worth having, and converts an open convention into a private extension. The value of the capability is that _any_ conformant subscriber could report using a credential the operator already issues. Building it into the groomer would produce the data and destroy the reason for it. This is consistent with the standing constraint that the client-edge monitor is a standalone process on a second subscription and never a groomer patch — the monitor in Part A was built that way for the same reason.

**The announce-refusal finding reaches both wires, and it is not a dropped error.** Payload agnosticism holds on both wires, and so does the silence. Measured with [`t39-ietf-refusal.sh`](scripts/t39-ietf-refusal.sh) — one relay, one token scoped to publish `affa.telemetry`, one clip, the wire pinned per cell with `--client-version`, each version carrying an in-scope control as well as the out-of-scope subject:

| Wire | In-scope control | Out-of-scope subject | What the publishing client was told |
| --- | --- | --- | --- |
| `moq-lite-05` | admitted, 2,171,588 B read back | refused, 0 B | nothing; ran to timeout |
| `moq-transport-14` | admitted, 2,171,588 B read back | refused, 0 B | nothing; ran to timeout |
| `moq-transport-19` | admitted, 2,171,588 B read back | refused, 0 B | nothing; ran to timeout |

Enforcement is correct on all three; no out-of-scope publish was admitted anywhere. The in-scope control is what makes the subject readable: without it, an error on a given wire could equally mean that the wire cannot publish at all.

**The mechanism is scoped interest, not refusal.** The relay, acting as subscriber toward the publishing client, opens announce-interest narrowed to the token's publish scope — visible in its own log as `subscribe_namespace sent prefix=affa.telemetry` — and a conforming publisher announces only what matches. A client holding `ch2/<leaf>` therefore emits no `PUBLISH_NAMESPACE` at all, and the relay's log contains none for that path. **Nothing refuses the announcement because the announcement is never made.** moq-lite does the same via the prefix on its `AnnounceRequest`.

This explains why neither error path in the code is reached, and it retires the earlier reading of them. `moq-transport` does define a refusal — `PUBLISH_NAMESPACE_ERROR` (0x08) on draft-14, generic `REQUEST_ERROR` (0x05) with `error_code` and `reason_phrase` on 15+ — and `ietf/subscriber.rs` can encode it; but that call site serves an announcement that arrived _inside_ the interest prefix and then failed, which is not the path a mis-scoped publisher takes. The moq-lite counterpart, `announced.declined(path)` in `lite/subscriber.rs`, writes `None` into a local map with no `tracing::` call at any level — also not the reason a mis-scoped publisher sees silence. It remains true, and is still structurally interesting, that **moq-lite has no per-announcement refusal message**: its Announce Stream is opened by the _subscriber_ (stream type `0x1`, creator _Subscriber_), so a publisher answers an `ANNOUNCE_REQUEST` rather than requesting permission, and a prompt stream reset — moq-lite's general rejection mechanism — is the wrong instrument because one Announce Stream carries many announcements.

So the finding does not split by wire after all. **The fix that would help an operator is client-side and needs no protocol change on either wire:** the publishing client knows both the broadcast paths it holds and every interest prefix it has received, so it can warn when a broadcast matches none of them. A report was drafted and not filed, with the protocol half held for a separate conversation.

**One provenance point, because it bounds how far "any conformant implementation" reaches.** moq-lite is itself an Internet-Draft (`draft-lcurley-moq-lite`) but an **individual submission, not a MoQ working-group document**; `moq-transport` is the working-group protocol. This relay implements both and negotiates moq-lite by default. The payload-agnosticism answer holds on either, which is why it is the safe one to build on; the refusal answer has to name its wire.

**What the IETF measurement does not cover.** It shows that the configuration an operator meets — a token whose publish scope excludes the path — produces silence on both wires, and why. It does not show that _no_ configuration reaches `write_error`; an announcement arriving inside the interest prefix and then failing may well do so, and that case was not constructed. Each cell is a single sample, which is adequate for a categorical told/not-told outcome and would not be for a figure.

**Whether a client would accept running it is not a technical question.** The whole design puts the only useful detector on hardware the broadcaster does not own, under someone else's change control. Part A shows it is additive and needs no groomer changes, which is the strongest technical answer available, and it does not answer the commercial one.

**Clock offset across the boundary is unmeasured.** The correlation convention is exact in media time and depends on deployment clock discipline in wall time. What that discipline actually is between a broadcaster's site and a client's is a question for a real deployment, and the design's instruction to carry the offset explicitly is _reasoned_, not measured. Upstream's report stamps each rendition's newest arrival with the subscriber's wall clock and carries no offset; on loopback the offset is zero.
