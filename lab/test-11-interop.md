# Test 11 — Cross-implementation interop

**Pyramid (§6):** transport neutrality. **Gate (§7):** feeds
[interoperability](../docs/interoperability.md) §9 and the "a MoQ relay is a neutral transport fabric"
assumption in [architecture](../docs/architecture.md). **State:** T11a partly run (2026-08-10). A
media-level test client exists and passes against `moq-dev` locally and over the public internet;
**eight other registered public relays return no data**. Root cause isolated for the five that
establish a session: **`moq-dev`'s IETF publisher withholds `PUBLISH_NAMESPACE` until the peer sends it
a `SUBSCRIBE_NAMESPACE`**. Its own relay does that; no third-party MOQT relay does, because in MOQT a
publisher announces proactively. So `moq import ts` connects and then never sends a single control
message. The IETF path itself carries media cleanly (MOQT-14 passes on a local relay), so this is a
client-side convention, not a relay defect. Three relays fail earlier, at the connection or SETUP
layer, and are not yet diagnosed. T11b and T11c not started.

## Objective

"A MoQ relay is a neutral transport fabric" is load-bearing for this project, and until now it had only
ever been tested against `moq-dev` peers. T11 tests it against everyone else's.

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

## Results — 2026-08-10, `moq` 0.9.8-9698cd93

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

### Failure signatures: at least four distinct causes, one isolated

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

Only moxygen is explained so far. The most interesting group is the middle one: **imquic, moqx and
Cloudflare all negotiate a modern draft (16/18/19) with no error at any layer, and still deliver no
media.** That is a different failure from moxygen's and has not been diagnosed.

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

Two checks were run before reporting this, because both were assumptions worth breaking:

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

Checked against draft-17 and draft-19 before reporting anything, because "interop hazard" and
"protocol violation" warrant very different reports.

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
- [ ] Establish whether an empty `SUBSCRIBE_NAMESPACE` prefix is legal in draft-14, then report to
      whichever side is wrong (`moq-dev` for sending it, or moxygen for rejecting it)
- [ ] Raise the 200 ms QUIC→WebSocket fallback timer separately
- [ ] Cloudflare leg properly: provision a scope, obtain publish/subscribe tokens, rerun
- [ ] Dockerfile and `implementations.json` wiring, once #32 settles the format-axis question
- [ ] Transparent-carriage variant (`--require-identical`), which needs a purpose-built client since
      the `moq` CLI has no opaque mode
- [ ] T11b (`moq2ts` broadcast through a `moq-dev` relay) and T11c (full suite against a `moq2ts`
      subscriber, blocked on their subscriber landing)
