# Test 39 — Observability across an administrative boundary

**State: partially run, 2026-09-11. Part A run and passed; Part B blocked on an upstream gap, with
the blocker identified and evidenced rather than assumed.** Tier placement and the reasoning for it
are in *Tiering* below, including the one place this stretches a tier.

**Headline.** A standalone process at the client edge, on its own subscription, **catches a
T24-class partial-media fault that no relay-side telemetry can express** — *measured*: the suppressed
audio PID alarmed on its own at media t=25.025 s with every other elementary stream still delivering,
while the groomer ran alongside it unmodified and the relay's counters carried no per-PID field in
which the fault could appear. That settles the tier split the design rests on: **tier 2 can prove
bytes flowed and can never prove the media was healthy**, so the only place the delivered signal can
be assessed is hardware the broadcaster does not own.

**The return path is authorizable today, protocol-legal today, and untooled today — three separate
things that must not be collapsed.** One token can carry a `--subscribe` prefix for media and an
unrelated `--publish` prefix for `<affiliate>.telemetry`, and a segment-aware relay routes both
correctly (*measured*, six cells, Part C). An opaque telemetry payload on its own track is **legal at
the wire-protocol level on both wires this relay speaks** — *specified*, and confirmed against
`rs/moq-net`'s types — so such a client is an ordinary MoQ client rather than a side-channel. What is
missing is only tooling: the `moq` CLI has no non-media publish or consume path, and the obvious
workaround of wrapping telemetry in a transport stream is blocked by the exporter's requirement for a
video or audio track to carry PCR ([T33](test-33-gate2-preparation.md)). **The blocker is a CLI gap,
not a permission gap and not a protocol gap** — see *Open* for the evidence on each.

## Objective

Establish what is observable about delivered media across the boundary between the broadcaster's
infrastructure and the client's, and whether the entitlement credential the client already holds can
carry a telemetry return path without new infrastructure.

The deployed topology is asymmetric in ownership:

```mermaid
flowchart LR
  P[Publisher<br/>ours] --> R[Relay / fabric<br/>ours or a vendor's]
  R -.->|administrative boundary| S[Subscriber<br/>client hardware]
  S --> G[Groomer<br/>client hardware]
  G --> D[Client's downstream]
```

[T32](test-32-observability-survey.md) asks whether commercial products expose a needed detector
*within* one administrative domain. This asks a different question: which side of the boundary each
kind of evidence is available on, and what that costs.

## Tiering, and where this stretches one

The campaign's observability evidence divides by which side of the boundary can see it. The tiers are
about *visibility*, not importance:

| Tier | Vantage | Owner | What it can establish |
|---|---|---|---|
| 1 | Publisher / ingest | Ours | Source conformance and liveness before anything is transported — `ts-pcr-timing.py`, `ts-liveness.py` at ingest |
| 2 | Relay / fabric | Ours **or a vendor's** | Session, byte, subscription and revocation state. Content-blind by construction |
| 3 | Client edge | **Theirs** | Per-PID liveness and PCR conformance on the signal actually delivered |

**Part A is tier 3 in isolation** and is placed there without qualification: a standalone process at
the client-edge position, on its own subscription, with no groomer involvement. It needs no apparatus
that does not already exist and no cooperation from the other tiers.

**Part B — the telemetry return path — is a tier-3 measurement whose *results* have to reach tier 1,
and that crossing is the thing being tested.** It is listed here rather than as its own experiment
because the detector is Part A's and only the carriage differs.

**Part C is tier 2, and calling it that is a stretch worth flagging.** It measures what the relay will
authorize and route, which is squarely tier 2, but it is here because it is a precondition for Part B
rather than because anything in it is about observability. If it were graded as an entitlement result
it would belong in [T38](test-38-entitlement-estate.md); it is kept here so that Part B's blocker is
not mistaken for an authorization failure, which is precisely the confusion the starting hypothesis
invited.

## What is already known, and precisely what it leaves open

| # | Established | Where | What it leaves open |
|---|---|---|---|
| 1 | A healthy transport does not imply a live programme | [T22](test-22-silent-media-plane-failure.md) | Nothing about who can see the difference |
| 2 | A partial stall passes the whole of TR 101 290 P1; an audio-only stall has no wire-observable signature | [T24](test-24-partial-media-plane-stall.md) | Whether the only detector that works can run where the boundary puts it |
| 3 | Per-PID access-unit counting catches every arm, and works at a cross-host groomed output | [T27](test-27-liveness-detector.md) | It was run on infrastructure we own end to end |
| 4 | The relay is QUIC-payload-blind by construction | [T36](test-36-entitlement-enforcement.md) | Whether its *published* telemetry adds anything the log does not |
| 5 | `moq token sign` takes repeatable `--publish` and `--subscribe` | T37 environment notes | Whether both survive on one token, and whether the relay routes them independently |

**The starting hypothesis, which this experiment was told to verify rather than assume**, is that a
token can carry a `--subscribe` prefix for media and an unrelated `--publish` prefix for
`<affiliate>.telemetry`, routed correctly by a segment-aware relay, so a client edge can report back
over the same relay under the same T36–T38 apparatus instead of a separate telemetry pipe. Part C
tests exactly that and it holds. It is not sufficient, for reasons Part B gives.

## Environment

Build under test `moq` 0.11.0-`fd4f5d82e` / `moq-relay` 0.14.16-`fd4f5d82e` from `~/bin-3529/`;
groomer `mpegts-pacer` `5ab84cd`, **unmodified**. Loopback, macOS, `--server-quic-gso=false`.
Source `CNNiEMEA.ts`: AVC video on PID 111 (also PCR), MPEG-1 audio on 121, AC-3 on 123, teletext on
131, three SCTE-35 PIDs. Detector `lab/scripts/ts-liveness.py`.

**The hard constraint on this experiment is that `mpegts-pacer` gets no changes.** Any client-edge
capture is a standalone process on a duplicate subscription, never a groomer patch. Part A is
constructed to demonstrate that the constraint is satisfiable concurrently rather than merely
asserted: the groomer runs in the same lane, at the same time, with the flags it already takes.

## Procedure

### Part A — tier 3 in isolation

`lab/scripts/t39-clientedge-monitor.sh`. One publisher into one relay; three consumers at the
client-edge position:

1. the groomer subscription, `moq export ts | mpegts-pacer - auto`, unmodified;
2. the monitor subscription, an independent `moq export ts` into `ts-liveness.py`;
3. the relay's own view, with `--stats-enabled --stats-interval 1 --stats-node edge1`.

The fault is T24-class and is built offline so its instant is known: twenty seconds of the clip
followed by twenty seconds with the MPEG-1 audio PID removed, video and PCR untouched across the join
and the PMT still declaring the audio. The harness verifies the fault is present in the source before
publishing it, and aborts if it is not.

Detector thresholds are given explicitly (`--gap 111:1000,121:1500,123:1500`) rather than learned.
Learning over this lane set every PID to 8,400 ms because the learning window contains the join
transient; detection latency is [T27](test-27-liveness-detector.md)'s measurement, not this one's, and
an 8.4 s threshold would have made the tier comparison meaningless.

### Part B — the telemetry return path

Publish the monitor's summary back to `<affiliate>.telemetry` over the same relay on the same
credential, and read it at the publisher side, attributing it by the existing correlation convention.

### Part C — dual-scope credentials

`lab/scripts/t39-token-dualscope.sh`. Six cells over one token carrying both a `--subscribe` prefix
for media and a `--publish` prefix for a telemetry path, checking that each is honoured for its own
prefix and refused for the other's, and that a neighbouring tenant's telemetry path is refused.

**The oracle is the point.** A publish cell is scored by whether an independent, fully privileged
subscriber can read back what was published — bytes at a subscriber, never a log line. The first
version read each cell's verdict by grepping the publishing client's own log for an authorization
error and reported that the relay admits publishes it should refuse; that was wrong, because the
publishing client is told nothing either way. The run ends with an oracle control.

## Results

### Part A — the client edge sees what the relay cannot

*(file domain, P1 detector, loopback, single relay, build `fd4f5d82e`, groomer `5ab84cd` unmodified.)*

Source verified before publishing: part 1 132,427 packets carrying 2,689 audio packets on PID 121;
part 2 129,805 packets carrying none.

| Vantage | What it reported |
|---|---|
| **Tier 3 — standalone monitor** | `alarm pid=121` at media t=**25.025 s**, **localised**: every other elementary stream still delivering. The next alarm is 14.30 s later and is all remaining PIDs at once, i.e. the source ending |
| **Tier 2 — relay** | No per-PID field exists in which the fault could appear. Bytes, frames and groups continued |
| **Groomer** | 333,144 packets out, `buffer_high_water=10746`, `media_rate=9538593 b/s`. No flags added, no patch |

**The monitor localised the fault to one elementary stream while the service around it was healthy**,
which is the distinction [T24](test-24-partial-media-plane-stall.md) established as the operationally
important one — an alarm that fires when everything stops is the cheap clock-progression layer, and
it is not sufficient. The harness classifies an alarm as localised only if other PIDs are still
delivering behind it, so the end-of-stream alarm is not counted as a detection.

**What tier 2 published, in full.** The relay's stats are not a metrics endpoint. `/metrics` serves
only `moq_relay_accept_failures_total{listener,class}` and `moq_relay_accept_stalled_seconds{listener}`;
everything else is published as MoQ broadcasts of JSON tracks under `--stats-prefix` (default
`.stats`), with `--stats-depth 1` giving a per-first-segment broadcast so a consumer can announce-scope
to one tenant. The counters are, per broadcast path and split publisher/subscriber: `announced`,
`announced_closed`, `announced_bytes`, `broadcasts`, `broadcasts_closed`, `subscriptions`,
`subscriptions_closed`, `fetches`, `bytes`, `frames`, `groups`, `datagrams`; plus per auth root,
`sessions` and `sessions_closed`.

**Audited against [Architecture](../docs/architecture.md) §9, tier 2 supplies about half of the
systems-domain half and none of the broadcast-domain half:**

| §9 requirement | In the relay's published stats? |
|---|---|
| Session counts and health | **Yes** — `sessions`, `sessions_closed` per auth root |
| Per-track subscription counts | **Yes** — `subscriptions`, `broadcasts` per broadcast path |
| Cache hit/miss | **No** |
| Delivery latency and jitter | **No** — byte and frame counts only, no timing |
| Congestion and loss indicators | **No** |
| Control-plane operation latency | **No** |
| TR 101 290 P1/P2 status, PCR statistics, continuity integrity, service presence | **No, and not possible** — the payload is opaque |

The last row is the load-bearing one and it is not a gap to be filled: it is what
[T36](test-36-entitlement-enforcement.md) established by construction. **No amount of relay telemetry
reaches a T24-class fault**, so the broadcast-domain half of §9 is only ever satisfiable at tier 1 or
tier 3, and across this boundary that means tier 3.

### Part C — one credential carries both directions

*Measured*, six cells, all passing, with an oracle control. A single token bearing `--subscribe` for
the media prefix and `--publish` for the telemetry prefix is honoured for each on its own prefix and
refused for the other's, and a neighbouring tenant's telemetry prefix is refused. Matching is
segment-aware, so `cnn.telemetry` and `cnn` are distinct prefixes rather than one being a prefix of
the other by string comparison.

**The starting hypothesis is confirmed at the authorization and routing layer.** The relay will let a
client edge publish telemetry back over the same credential and the same relay, scoped so that it can
reach nothing else.

**A side finding, and the subject of a drafted upstream report: a publishing client is never told its
announce was refused.** The client connects, announces, is refused, and its log ends at "connected".
Nothing distinguishes a working publish from a silently discarded one at the publisher. This is what
made the first oracle wrong, and it is a worse problem for an unattended client-edge telemetry
reporter than it was for a test harness — such a reporter would publish into a void indefinitely with
no local indication.

### Part B — blocked on tooling, not on permission and not on the protocol

**There is no way to put telemetry in the return path with shipped tooling.** Every `moq import`
source and every `moq export` sink is a media container (`ts`, `fmp4`, `avc3`, `flv`, `mkv`, `h264`,
`h265`, `hls`, `rtmp`, `srt`, `rtc`). There is no JSON or opaque-data path in either direction, which
also means the relay's own stats broadcasts cannot be read with the CLI that publishes them.

The obvious workaround is to wrap the summary in a transport stream, and the apparatus for it already
exists — `lab/scripts/t33-service-fixture.py` builds a conforming PAT/PMT around a private PES. It
does not work, for a reason [T33](test-33-gate2-preparation.md) already established: `moq export ts`
refuses a broadcast with no video or audio track, because it has nothing to derive PCR from. A
telemetry-only transport stream can be imported and cannot be read back.

**That exhausts the CLI and nothing else.** An opaque payload on its own track is explicitly legal in
both wire protocols and carries no media typing in `rs/moq-net`'s model, so a client written against
the library is standard usage rather than a workaround — the evidence is set out under *Open*. The
return path therefore needs a small `moq-net` client, or the equivalent CLI subcommand upstream; it
does not need a protocol change, and it does not need telemetry disguised as a decorative audio
track. **The starting hypothesis was about permission, was verified, and is not the obstacle.**

## Metrics

- Whether the tier-3 detector alarms on the suppressed PID **with other PIDs still delivering** — a
  boolean, and the only one that distinguishes localisation from stream-end.
- Media time of each alarm, and the interval to the next, so an end-of-stream alarm is separable.
- The groomer's packet count and pacer summary, to show the monitor was additive.
- The relay's published counter set, enumerated from source and audited against §9 line by line.
- Part C: per cell, whether an independent privileged subscriber could read back what was published.

## Verdict against the pass criteria, fixed before running

| # | Criterion | Verdict |
|---|---|---|
| 1 | A standalone client-edge process detects a T24-class fault on its own subscription | **Pass.** PID 121 alarmed at media t=25.025 s, localised |
| 2 | It does so with **zero** changes to `mpegts-pacer`, running concurrently | **Pass.** The groomer ran in the same lane with the flags it already takes and produced 333,144 packets |
| 3 | The relay's published telemetry is enumerated and audited against §9 rather than characterised | **Pass.** Twelve traffic counters and two presence counters, audited line by line |
| 4 | The dual-scope token hypothesis is **verified, not assumed**, either way | **Pass.** Six cells with a readback oracle and a control; it holds |
| 5 | The return path is either demonstrated end to end or its blocker identified and evidenced | **Partial.** Not demonstrated. The blocker is identified and evidenced from the CLI's own surface, from T33, and from both wire protocols: it is a **tooling** gap. Authorization works (Part C) and an opaque data track is protocol-legal, so neither is the obstacle |
| 6 | A correlation convention is found in upstream or its absence established, before any is invented | **Pass.** Found; see below. Nothing was invented |

### The correlation convention already exists and was not invented

[Architecture](../docs/architecture.md) §9 requires "a common correlation identifier [that] flows from
publisher through fabric to gateway". Before designing one, the `moq-hang` draft, the catalog and
`@moq/json` were checked. The shipped catalog already carries it: `rs/hang/src/catalog/timeline.rs`
declares `pub wall: Option<u64>`, milliseconds since a MoQ epoch of 2020-01-01, and documents that a
consumer "derives the wall-clock time of any group as `wall + pts`".

That is enough to attribute a client-edge observation to a publisher-side group without any new field:
both ends name the same group by the same arithmetic. What it does **not** provide is clock synchrony
between the two ends, and upstream is explicit that it will not — decision #2278 records that the
library offers no clock-sync mechanism and that synchronisation is a declared deployment property.
Across an administrative boundary that matters: the correlation is exact in *media* time and only as
good as the two sites' clock discipline in *wall* time.

**Design consequence.** A cross-boundary telemetry summary should be keyed by group sequence and
`wall + pts`, and should carry the reporting site's own clock offset as an explicit field rather than
assuming it is zero. No new identifier is needed.

## Limits, stated in advance

- **Loopback, and a simulated boundary.** There is no administrative boundary in this run — both
  "sides" are one machine. What is demonstrated is that the *vantage* works where the boundary puts
  it, not that it works across a real one with a real network and a real customer's change control.
- **The groomer's presence shows concurrency, not non-interference at scale.** One extra subscription
  on a loopback relay is not evidence about what N monitoring subscriptions cost a client's box.
- **Detection latency is not measured here** and the figures in this file must not be read as
  latencies. Thresholds were set explicitly to make the tier comparison legible;
  [T27](test-27-liveness-detector.md) is the authority, and it measured 1.0–3.1 s at a groomed
  monitoring point.
- **One fault class.** An audio-PID suppression. T24's other arms are not re-run here.
- **Part C's oracle proves readback, not refusal semantics.** A cell that reads back nothing is scored
  as refused; it does not distinguish a refusal from a publish that failed for another reason. The
  oracle control bounds this but does not eliminate it.
- **Nothing here measures a vendor-operated relay.** Tier 2 is "ours or a vendor's" in the design and
  entirely ours in the measurement, and a vendor's relay may publish more, less, or nothing.

## Corrections

**A slicing failure and a null detection look identical, and one of them was mine.** Part A's first
two runs reported that the monitor did not catch the fault. It had not: `tsp -P until --seconds` does
not exist, and `--milli-seconds` is wall-clock by default, so reading a file at disk speed it expires
only after twenty seconds of *reading* — by which point the whole 372 MB clip has passed. The
"20-second" part 1 was the entire clip and part 2 was empty, so the published stream had its audio
throughout and the detector was correctly silent about a fault that was never built. The first attempt
also sent the slicing errors to `/dev/null`. Two rules: **time-slicing a transport stream needs
`--pcr-based`, because wall-clock and media time differ by the ratio of disk speed to bitrate**; and
**a harness must assert that the fault is present in its own source before asking anything downstream
about it** — this one now counts the PID in each part and aborts if the suppression did not take.

**A detector that learns its thresholds from a window containing the join transient is not armed.**
Learning over this lane set every PID to 8,400 ms, because the threshold is a multiple of the worst
spacing observed and the worst spacing was the start-up gap. It would not have been wrong, exactly —
it would have alarmed eventually — but an 8.4 s threshold on a 1.5 s question measures the learning
window rather than the lane. Where a test is about something other than detection latency, set the
thresholds explicitly and say so.

**"Permission" and "carriage" are different blockers and the hypothesis only named one.** The starting
hypothesis asked whether the credential could carry both scopes. It can. Having verified that, the
first instinct was to record the return path as available; it is not, and the reason has nothing to do
with tokens. A verified hypothesis is not a working mechanism, and the gap between them is where this
experiment's actual finding is.

## Open

**An opaque telemetry track is legal at the wire-protocol level. The CLI's lack of a `json` sink is a
tooling gap, not a protocol gap, and not a proprietary design.** This distinction was left unstated in
the first version of this file, which recorded only that the CLI could not carry telemetry — leaving
open whether the return path would have to be a side-channel. It would not. Checked directly rather
than assumed:

- `draft-lcurley-moq-lite` states it three times: *"the transport is payload agnostic and can be
  proxied by relays/CDNs without knowledge of codecs, containers, or encryption keys"*; of a frame,
  *"The contents are opaque to the moq-lite layer"*; and FRAME's payload field is *"An
  application-specific payload."*
- `rs/moq-net`'s model agrees. `Frame` is a timestamp plus `payload: Bytes`. `track::Info` carries
  `timescale`, `latency_max`, `priority` and `ordered` — **no codec, MIME type or media typing of any
  kind.**
- The same holds on the moq-transport drafts (14–19) this relay also implements, so the answer does
  not depend on which of the two wires a peer speaks.

**A client written against `moq-net` to carry a telemetry track is therefore an ordinary MoQ client
using the standard wire protocol**, interoperable with any conformant implementation, and not an
extension or a side-channel. That is the answer to the interoperability requirement, and it makes
Part B's blocker purely one of tooling: `moq import json` / `moq export json` (or an opaque `--track`
passthrough) would close it, as would a small local client. Registered as P1-l; not written this
session.

**Where the announce-refusal finding reaches is narrower, and the difference matters.** Payload
agnosticism holds on both wires; the refusal signal does not. `moq-transport` defines it —
`PUBLISH_NAMESPACE_ERROR` (0x08) on draft-14, generic `REQUEST_ERROR` (0x05) with `error_code` and
`reason_phrase` on 15+ — and `rs/moq-net/src/ietf/subscriber.rs` **sends** it, from the same
`Error::Unauthorized` that `rs/moq-net/src/lite/subscriber.rs` silently discards:

```rust
// An error means the path is outside our scope, so don't serve it.
let Ok(source) = self.origin.create_broadcast(&path, route) else {
    announced.declined(path);
    return Ok(false);
};
```

`declined()` writes `None` into a local map; there is no `tracing::` call on that path at any level, so
the relay does not record the decision even for its own operator. **moq-lite has no per-announcement
refusal message at all**, and for a structural reason rather than an oversight: its Announce Stream is
opened by the *subscriber* (stream type `0x1`, creator *Subscriber*), so a publisher never requests
permission to announce — it answers an `ANNOUNCE_REQUEST` — and moq-lite's general rejection
mechanism, a prompt stream reset, is wrong here because one Announce Stream carries many
announcements.

So the finding splits: **making the refusal visible to the relay operator is a one-line logging fix
needing no protocol change; making it visible to the moq-lite publisher would need a new
per-announcement status and is a protocol proposal.** Both are written up at
[`docs/upstream/publish-refusal-not-signalled.local.md`](../docs/upstream/publish-refusal-not-signalled.local.md),
staged and unfiled, with the protocol half explicitly held for a separate conversation. **T39's own
measurements are all on `moq-lite-05`**, which is what the shipped CLI negotiates, so the silence we
observed is the moq-lite path's behaviour and not the relay's behaviour in general.

**One provenance point, because it bounds how far "any conformant implementation" reaches.** moq-lite
is itself an Internet-Draft (`draft-lcurley-moq-lite`) but an **individual submission, not a MoQ
working-group document**; `moq-transport` is the working-group protocol. This relay implements both
and negotiates moq-lite by default. The payload-agnosticism answer holds on either, which is why it is
the safe one to build on; the refusal answer has to name its wire.

**The IETF path's refusal signal has not been exercised here.** It is read from `ietf/subscriber.rs`
and the draft message definitions, not observed on a wire. Running a publisher against this relay over
`moq-transport` to watch a `REQUEST_ERROR` arrive is cheap and should happen before the upstream draft
is filed.

**Whether a client would accept running it is not a technical question.** The whole design puts the
only useful detector on hardware the broadcaster does not own, under someone else's change control.
Part A shows it is additive and needs no groomer changes, which is the strongest technical answer
available, and it does not answer the commercial one.

**The silent announce refusal deserves the upstream report it has been drafted into**, at
[`docs/upstream/publish-refusal-not-signalled.local.md`](../docs/upstream/publish-refusal-not-signalled.local.md).
An unattended telemetry reporter that is silently refused is indistinguishable, at the reporter, from
one that is working.

**Clock offset across the boundary is unmeasured.** The correlation convention is exact in media time
and depends on deployment clock discipline in wall time. What that discipline actually is between a
broadcaster's site and a client's is a question for a real deployment, and the design's instruction to
carry the offset explicitly is *reasoned*, not measured.
