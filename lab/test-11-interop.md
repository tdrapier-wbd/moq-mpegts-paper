# Test 11 — Cross-implementation interop

**Pyramid rung 7** (comparative lab). **Feeds:**
[comparison](../docs/comparison.md) §12 and the "a MoQ relay is a neutral transport fabric"
assumption in [architecture](../docs/architecture.md). **State:** T11a partly run. A
media-level test client exists and passes against `moq-dev` locally and over the public internet;
**eight other registered public relays return no data**. Root cause isolated for the five that
establish a session: **`moq-dev`'s IETF publisher withholds `PUBLISH_NAMESPACE` until the peer sends it
a `SUBSCRIBE_NAMESPACE`**. Its own relay does that; no third-party MOQT relay does, because in MOQT a
publisher announces proactively. So `moq import ts` connects and then never sends a single control
message. The IETF path itself carries media cleanly (MOQT-14 passes on a local relay), so this is a
client-side convention, not a relay defect. Three relays fail earlier, at the connection or SETUP
layer, and are not yet diagnosed. T11b and T11c not started.

**The same fixture and oracle put through segmented HTTP pass against every third party tried** —
FFmpeg, VLC, a bare `curl` loop, an off-the-shelf nginx cache, and Apple's `mediastreamvalidator` with
0 errors and 0 warnings. Two clients through the cache cost the origin nine segment fetches rather
than eighteen, which is the CDN scaling argument measured rather than asserted. **Six third parties,
six passes, against nine relays and eight failures.** One correction falls out of it: the HLS packager
is *not* byte-transparent — it re-muxes, and it silently truncated 5.0 % of a finite input.

## Objective

"A MoQ relay is a neutral transport fabric" is load-bearing for this project, and every other test in
this campaign exercises it only against `moq-dev` peers. T11 tests it against everyone else's.

The claim is comparative, so the measurement has to be. Segmented HTTP's whole case rests on an
interoperability assertion of the same shape — that any HTTP client reads it and any HTTP cache
forwards it — and that assertion is repeated far more often than it is tested. **The segmented arm
therefore asks the identical question with the identical fixture and oracle**, so the two tables can
be read against each other rather than merely placed side by side.

The secondary objective is a contribution: the work is shaped as a test client for
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) rather than a private rig, in
support of [#32](https://github.com/englishm/moq-interop-runner/issues/32). Building it for the harness
and running it for ourselves is the same work.

## Method

Client, fixture and oracle live in [`interop/`](../interop/README.md) — see that README for the
interface contract, usage and the sensitivity results.

- **Fixture:** synthetic, generated at build time. 20 s, 2 Mbps CBR, H.264 640×360 + AAC, 1 s closed
  GOP, one service, video PID 256, audio PID 257. 26,612 packets, continuity clean at birth.
- **Oracle:** continuity counters plus PSI/SI, via TSDuck. No decoder, no player, no frame capture.
  Verified sensitive to packet loss, duplication and reordering before being trusted (see README).
- **Tests:** `ts-carriage-integrity` (subscriber present throughout) and `ts-late-subscriber`
  (joins 8 s in). Publisher paced with `tsp regulate --pcr-synchronous`, so the relay sees a live
  arrival pattern rather than a file burst.

**Byte-identity is not a pass criterion here.** `moq import ts` / `export ts` is the media-aware lane:
it demuxes to `hang` tracks and remuxes at egress, so the egress legitimately differs from the source.
Measured difference is 5,003,056 → 4,366,112 bytes, essentially the CBR null-packet stuffing (PID 8191)
that is not carried. Byte-identity is the *transparent* lane's property and needs a purpose-built
client, because **the `moq` CLI has no opaque byte-carriage mode** — every `ImportSource` and
`ExportSink` is media-aware. That is a finding in itself and is the main gap between this proof of
concept and a transparent-carriage test.

## Results — `moq` 0.9.8

| Relay | Endpoint | Result |
|---|---|---|
| `moq-dev` (local) | `localhost:4443`, moq-lite-05 | **pass** — 13/13 checks |
| `moq-dev` (public) | `cdn.moq.dev/anon` | **pass** — 13/13, egress byte-identical to the local run |
| moxygen (Meta) | `fb.mvfst.net:9448` | no data — but **SETUP succeeds, `moq-transport-14`** |
| quiche-moq (Google) | `quichemoq.dev:443` | no data |
| moqtail (OzU) | `relay.moqtail.dev` | no data — `Setup failed` reported |
| imquic (Meetecho) | `lminiero.it:9000` | no data |
| moqx (openmoq) | `moqx-main.ci.openmoq.org:4433` | no data |
| Nokia Research | `moqt.nokiaresearch.com:4443` | no data — `closed` |
| Cloudflare draft-18 | `draft-18-interop.cloudflare...` | no data (anonymous publish; expected to need a provisioned scope) |
| libquicr (Cisco) | `us-west-2.relay.quicr.org:33437` | no data |

`ts-late-subscriber` also passes locally: a subscriber joining 8 s into the 20 s fixture receives
2.59 MB, continuity clean from the join, PSI present without waiting for a new session.

### Failure signatures: at least four distinct causes

Per-relay signatures from the sweep, which show the eight failures are **not** a single cause:

| Relay | Negotiated | Signature |
|---|---|---|
| moxygen | `moq-transport-14` | `subscribe_namespace error error_code=16` — **isolated, see below** |
| imquic | `moq-transport-19` | connects cleanly, no error, no data |
| moqx | `moq-transport-16` | connects cleanly, no error, no data |
| Cloudflare draft-18 | `moq-transport-18` | connects cleanly, no error, no data (anonymous publish; scope expected) |
| Nokia Research | `moq-transport-19` | connects, then `error: closed` |
| moqtail | — | `closed by peer: Setup`, then timeout — SETUP rejected |
| quiche-moq | — | no version negotiated; connection never established |
| libquicr | — | no version negotiated; connection never established |

Only moxygen's signature is self-explaining at this point in the sweep; the group below it —
**imquic, moqx and Cloudflare all negotiate a modern draft (16/18/19) with no error at any layer and
still deliver no media** — is the interesting one, and the next section identifies the cause it shares
with moxygen. The bottom three, which never establish a session or have SETUP refused, remain
undiagnosed.

**The arithmetic behind "at least four distinct causes"**, since it is quoted downstream:
(1) the demand-driven announce convention, covering the five relays that establish a session;
(2) the empty-prefix namespace subscription sitting behind it, which is what moxygen rejects
outright; (3) one SETUP refusal (moqtail); and (4) two connections that never establish
(quiche-moq, libquicr). Causes 3 and 4 are undiagnosed, so the count is a floor rather than a
finding.

Version negotiation is clearly working broadly — `moq-transport-19` was negotiated twice, above the
`moq-transport-17` ceiling the CLI's own help text advertises.

### Root cause: the publisher only announces when asked, and no third-party relay asks

Instrumenting the control messages on both ends, against a relay that works and the ones that do not,
gives one cause covering **every** "connects but no data" case.

On a local `moq-dev` relay forced to `moq-transport-14`, where media does flow, the publisher's
sequence is:

```
received subscribe_namespace          <- the relay asks the publisher what it has
encoding self=SubscribeNamespaceOk
encoding self=PublishNamespace        <- only THEN does the publisher announce
received subscribe
encoding self=SubscribeOk
```

**`moq-dev`'s IETF publisher is demand-driven: it withholds `PUBLISH_NAMESPACE` until the peer sends
it a `SUBSCRIBE_NAMESPACE`.** Its own relay does exactly that, so the chain completes. No third-party
MOQT relay does — in MOQT a publisher is expected to announce proactively on connect, and a relay has
no reason to interrogate a session that has claimed nothing. So `moq import ts` connects, negotiates,
and then **encodes not one control message for the rest of its life**, which is precisely what the logs
show against imquic, moqx and Cloudflare.

Two checks rule out the obvious alternative explanations:

- **Is it downstream demand propagating?** No. With **no subscriber connected at all**, `moq-relay`
  still sends `SUBSCRIBE_NAMESPACE` and the publisher still announces (3 protocol lines, same order).
  The relay interrogates every publisher session unconditionally, so the announce is gated purely on
  being asked.
- **Is the silence a logging artefact?** No. With `RUST_LOG=moq_net=trace` the publisher log against
  imquic contains exactly one `moq_net::client` line, while the *subscriber* in the same run logs
  `moq_net::ietf::message` and `moq_net::ietf::subscriber` normally. Same environment, same process
  tree — the publisher genuinely emits nothing.

| Relay | Publisher control messages sent | Subscriber |
|---|---|---|
| local `moq-dev`, MOQT-14 | `SubscribeNamespaceOk`, `PublishNamespace`, 3× `SubscribeOk` | `SubscribeNamespaceLegacy`, 3× `Subscribe` — **3.49 MB flows** |
| imquic (draft-19) | **none** | `SubscribeNamespace` sent, never answered |
| moqx (draft-16) | **none** | `SubscribeNamespaceLegacy` sent, never answered |
| Cloudflare (draft-18) | **none** | `SubscribeNamespace` sent, never answered |
| moxygen (draft-14) | **none** | `SubscribeNamespaceLegacy` sent, **rejected with error 16** |

This is the preannounce/demand-driven split flagged for T11b from `moqxr` PR #21, observed directly:
`moq-dev` is firmly in the demand-driven camp, and that is incompatible with relays expecting a
proactive announce.

#### The secondary symptom: discovery on an empty prefix

**`moq export ts` opens discovery by sending `SUBSCRIBE_NAMESPACE` on the empty prefix**:

```
TRACE moq_net::ietf::message: encoding self=SubscribeNamespaceLegacy {
        request_id: RequestId(0), namespace: Path(""), subscribe_options: 1 }
DEBUG moq_net::ietf::subscriber: subscribe_namespace sent prefix=
 WARN moq_net::ietf::subscriber: subscribe_namespace error error_code=16 reason=empty
 WARN moq_net::ietf::session: subscribe_namespace failed, continuing without err=cancelled
```

`moq-dev`'s own relay accepts a subscription to `Path("")` and answers it with the full announce feed.
moxygen rejects it — error code 16 is `UnexpectedMessage` in `moq-net`'s own mapping. `moq-dev` then
logs *"continuing without"* and proceeds with **no announce feed at all**, so it never learns the
broadcast exists, never subscribes to it, and the demand-driven publisher is never asked to produce
anything. Hence a publisher that connects, negotiates cleanly, and then sits silent.

Two controls isolate this from the transport:

| Control | Result |
|---|---|
| Local `moq-dev` relay, **forced `--client-version moq-transport-14`** | **passes** — announce propagates, 3.49 MB received, continuity clean, PSI intact |
| moxygen over raw QUIC (`moqt://`) instead of WebTransport | identical failure, so the transport is not the variable |

So the IETF path itself is sound: **the media-level test passes over `moq-transport-14` as well as
`moq-lite-05`**. But the empty prefix is the *lesser* of the two problems — even if moxygen accepted
it, the publisher would still be sitting waiting to be asked. **The demand-driven announce is the
blocking defect; the empty-prefix rejection is a second one behind it.**

Separate from both, and still unexplained: quiche-moq and libquicr never establish a session at all,
and moqtail's SETUP is refused. Those are connection-level failures, not announce-level, and need
their own diagnosis.

### Is any of this a spec violation? Mostly no — and that matters

Checked against draft-17 and draft-19, because "interop hazard" and "protocol violation" warrant very
different reports.

**The demand-driven publisher is legal.** draft-17 §6.2: *"A publisher **MAY** send PUBLISH_NAMESPACE
messages to any subscriber… If a publisher is authoritative for a given namespace… it **MUST** send a
PUBLISH_NAMESPACE to any subscriber that has subscribed via SUBSCRIBE_NAMESPACE for that namespace."*
Announcing proactively is permitted, not required; the obligation only bites once someone has
subscribed. So `moq-dev` withholding the announce is **spec-conformant and still unable to interoperate
with any relay that does not interrogate publishers** — which is the normal case, since
PUBLISH_NAMESPACE is the message that flows *from* client publishers *towards* relays and carries the
authorisation. This is an interop-hazard report, not a bug report.

**The empty prefix is a known spec inconsistency, not a `moq-dev` error.** The draft says a namespace
of zero fields is a `PROTOCOL_VIOLATION`, while the working group has stated it intends to allow an
empty tuple for exactly this "give me everything" discovery case —
[moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457): *"I think we also
allow SUBSCRIBE_NAMESPACE with an empty tuple… the draft is inconsistent and we intended to allow empty
everywhere."* moxygen rejecting it is defensible under the letter; `moq-dev` sending it is defensible
under the intent. **Neither implementation is wrong** — the specification is, and it is already
tracked. Our contribution here is a concrete interop data point for that issue.

No existing `moq-dev` issue covers the announce behaviour. The nearest are
[#2708](https://github.com/moq-dev/moq/issues/2708) (open announce interest lazily, on first consumer)
and [#2695](https://github.com/moq-dev/moq/issues/2695) (linger keeps broadcasts announced), both
adjacent but neither this.

### Incidental finding: a 200 ms QUIC/WebSocket race

On the transatlantic path to moxygen the client silently abandoned QUIC and fell back to WebSocket:

```
DEBUG moq_native::websocket: QUIC not yet connected, attempting WebSocket fallback delay_ms=200
```

Not causal here — raw QUIC behaves identically — but a fixed 200 ms timer will systematically choose
WebSocket for any relay more than ~100 ms away. That is a confound for interop measurement (the
transport under test is not the one you think) and a concern for broadcast carriage, since WebSocket
means TCP and head-of-line blocking. Worth raising separately.

## The same question, asked of segmented HTTP — every third party carries it

The MoQ table above is the interesting half of a comparison only if the other half is measured, and
the fair way to measure it is with the same fixture, the same oracle and third-party software at each
of the three places the MoQ arm hit a wall: the intermediary that has to forward the media, the client
that has to read it, and the judge that decides whether it conformed.
[`t11-segmented.sh`](scripts/t11-segmented.sh) does that. The fixture is packaged to a complete
playlist so every client has the whole 20 s available and the comparison against source is exact.

| Third party | Role | Result |
|---|---|---|
| TSDuck `tsp -I hls` | control — the toolkit that wrote the segments | **pass**, 4,750,948 B |
| **FFmpeg** | independent HLS implementation | **pass**, remuxed to 4,123,592 B |
| **VLC** | a third independent implementation | **pass**, remuxed to 4,143,144 B |
| **`curl` in a `while` loop** | no HLS implementation at all | **pass**, byte-identical to the served segments |
| **nginx `proxy_cache`** | an intermediary we did not write | **pass** — and see below |
| **Apple `mediastreamvalidator`** | the reference conformance judge | **pass** — 9/9 segments, **0 errors, 0 warnings**, 0 parse errors, 0 load failures |

**Six third parties, six passes, against nine MoQ relays and eight failures.** Every capture cleared
the same twelve hard checks the MoQ arm clears — continuity, sync, TEI, PAT, PMT, service count and
stream inventory all matching the source.

Three of those rows carry more weight than the raw count.

**The cache row is the one that matters architecturally**, because it is the segmented lane's answer
to the eight relays that would not forward our media. An off-the-shelf nginx in front of the origin,
configured with nothing but `proxy_cache`, forwarded the stream intact — and **two client passes cost
the origin nine segment fetches, not eighteen**: nine misses and nine hits, the second client served
entirely from cache. That is the CDN scaling argument reduced to a measurement rather than an
assertion, and it took one `proxy_cache` directive against a MoQ fan-out story that requires a relay
implementing the protocol.

**The `curl` row is the floor of the interoperability claim.** A shell loop that reads the playlist,
fetches each URL in order and concatenates the bodies recovers the media exactly — it is byte-identical
to what the origin served. There is no HLS implementation in that arm at all. The client requirement
for this lane really is "an HTTP client", which is the thing the lane is always claimed to have and
this is what claiming it costs.

**And the judge is not ours.** `validate-ts.sh` grading our own output is worth something, but Apple's
`mediastreamvalidator` is the reference implementation of the specification with no stake in the
result, and it reported zero errors and zero warnings while processing 100 % of the segments and
correctly identifying `avc1` and `aac`. The MoQ arm has no counterpart to this, because MoQ has no
reference conformance tool — which is itself a difference in the maturity of the two ecosystems rather
than of the two protocols.

### But the packager is not transparent, and that was assumed rather than checked

The one thing this arm does **not** establish is byte-transparency, and looking for it turned up a
defect. Concatenating the served segments and comparing against the fixture:

| | Source fixture | Served segments |
|---|---:|---:|
| Packets | 26,612 | 25,271 |
| Video PID 256 / audio 257 / nulls 8191 | 21,236 / 1,878 / 3,039 | 20,143 / 1,798 / 2,880 |
| Playlist duration | 20.0 s | 19.004 s |

**`tsp -O hls` dropped the last 1,340 packets — 5.0 % of the fixture, the final second of media — and
declared the playlist complete with `#EXT-X-ENDLIST` while doing so.** The loss is at the tail, where
the input ended between intra frames, so it is a finite-input behaviour and a live feed has no tail to
lose; every other segmented arm in this campaign is unaffected. It is still a silent, unreported
truncation of content the packager was given, and any use of this toolchain for file-based packaging
would inherit it.

The bytes also differ from the third packet onward, because the packager aligns the first segment to
an intra frame and re-emits PSI rather than copying the input. **Every PID's count is scaled by the
same ~0.948, so nothing is being selectively stripped** — the content is all there, in proportion,
which is why the oracle passes — but the segmented lane as packaged by TSDuck is a *media-aware* lane,
not an opaque one. That correction matters beyond this file: the intuition that segment fetching is
byte-verbatim carriage is wrong at the packager, even though it is right on the wire, where every byte
the packager emits is delivered unaltered (the `curl` and `tsp` arms agree to the byte).

### Why this matters beyond our own question

The interop matrix today is control-plane only. Against moxygen, `setup-only` would report green
while no media flows at all. **That gap is invisible in the current matrix**, and it is the strongest
argument for the media-level profile proposed in #32.

## Status and next steps

- [x] Fixture generator, oracle, and oracle sensitivity tests
- [x] Test client conforming to the runner's interface (TAP v14, exit 0/1/127)
- [x] Local and public `moq-dev` validation
- [x] Sweep across all registered public relays
- [x] Proposal posted to [#32](https://github.com/englishm/moq-interop-runner/issues/32#issuecomment-5239364972)
- [x] Root cause reported upstream as [moq-dev/moq#2730](https://github.com/moq-dev/moq/issues/2730),
      framed as an interop hazard rather than a bug since the behaviour is conformant
- [x] Findings posted back to [#32](https://github.com/englishm/moq-interop-runner/issues/32#issuecomment-5240521275),
      including two harness-level suggestions: a control-plane test for zero-field
      `SUBSCRIBE_NAMESPACE` handling (data for moq-wg#1457), and recording the transport actually used
      alongside the negotiated draft
- [x] Isolate the cross-implementation failure — empty-prefix `SUBSCRIBE_NAMESPACE`, confirmed by a
      same-relay version A/B
- [x] Segmented-HTTP arm: the same fixture and oracle through FFmpeg, VLC, `curl`, an nginx cache and
      Apple's `mediastreamvalidator`
- [ ] Report the packager's silent 5 % tail truncation on a finite input to TSDuck. It needs a minimal
      reproducer first — the input ending between intra frames is the suspected trigger, and that
      should be confirmed against a clip whose final GOP is complete before anything is filed.
- [ ] Put the segmented arm through a real CDN rather than a local nginx. The cache result is the
      architecturally load-bearing one and a single-node `proxy_cache` is the weakest possible form of
      it: it shows the objects are cacheable, not that a distribution network will behave.
- [ ] Contribute the empty-prefix data point to [moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457),
      which is where it belongs: the draft is internally inconsistent, so neither `moq-dev` (sending)
      nor moxygen (rejecting) is the party to report against
- [ ] Raise the 200 ms QUIC→WebSocket fallback timer separately
- [ ] Cloudflare leg properly: provision a scope, obtain publish/subscribe tokens, rerun
- [ ] Dockerfile and `implementations.json` wiring, once #32 settles the format-axis question
- [ ] Transparent-carriage variant (`--require-identical`), which needs a purpose-built client since
      the `moq` CLI has no opaque mode
- [ ] T11b (`moq2ts` broadcast through a `moq-dev` relay) and T11c (full suite against a `moq2ts`
      subscriber, blocked on their subscriber landing)
