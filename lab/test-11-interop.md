# Test 11 — Cross-implementation interop

**Pyramid rung 7** (comparative lab). **Feeds:**
[comparison](../docs/comparison.md) §12 and the "a MoQ relay is a neutral transport fabric"
assumption in [architecture](../docs/architecture.md). **State:** T11a run at `main` (P1-h)
against every relay in the interop runner's registry, `moq-dev` publishing and subscribing over raw
QUIC. **Of nine third-party relay implementations reached, seven carry the TS intact from the
subscriber's join, and two lose packets after it**: imquic drops a group's final object at about
half the group boundaries, and red5 drops the rest of the group being written when a subscription
joins. The join itself splits them. libquicr and moqx start a subscriber at the current group and
pass both of the runner proposal's cases. moxygen and Cloudflare start at the next group and still
serve a late subscriber. aiomoqt, moqtail and Nokia (draft 22) also start at the next group, and
never deliver the catalog to a late subscriber, so `moq export ts` joining mid-stream receives
nothing; on draft 18 moqtail hands it the broadcast's first group before the live one. Nokia's
draft-18 endpoint refuses the TLS handshake at ALPN, and quiche-moq's host does not answer.
The first sweep, with `moq` 0.9.8, carried nothing through any of eight relays; its main cause, a
publisher that announced only when asked, is fixed upstream.

**T11b run: an outside opaque-TS publisher through a `moq-dev` relay.** OpenMOQ's MSFTS example
publisher, as released, delivers at most one object on each of the three combinations tried. With a
one-line publisher fix it crosses the relay **byte-exact on every elementary-stream PID**, but only on
draft 18 over raw QUIC to an IETF subscriber, and only for about 27 s at 10 Mb/s before the relay
aborts its single unbounded group. Every other combination fails on a publisher-side defect, bar
WebTransport, which fails on a relay transport parameter `moq-dev` already plans to add. No relay
defect was found in the passing arm. **T11c on OpenMOQ's moq5 (P1-h), on drafts 16, 18 and 22:**
moq5's TS crosses a `moq-dev` relay byte-exact on every PID, and `moq-dev`'s demultiplexed TS
crosses `moq5-relay` with no content lost. Its passthrough TS does not, because `moq5-relay` never
delivers that catalog, and neither side's TS track is visible to the other's catalog parser.

**The same fixture and oracle put through segmented HTTP pass against every third party tried** —
FFmpeg, VLC, a bare `curl` loop, an off-the-shelf nginx cache, and Apple's `mediastreamvalidator` with
0 errors and 0 warnings. Two clients through the cache cost the origin nine segment fetches rather
than eighteen, which is the CDN scaling argument measured rather than asserted. **Six third parties,
six passes; on MoQ, two of nine third-party relays pass both cases.** One correction falls out of
it: the HLS packager is *not* byte-transparent — it re-muxes, and it silently truncated 5.0 % of a
finite input.

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

## Results at `main`: the registry's relays (P1-h)

**What was run.** `moq-dev` at `3c0daa21` at both ends, from an EC2 host over the public internet;
fixture against received file (P1); one run per relay. [`t11-relay-sweep.sh`](scripts/t11-relay-sweep.sh)
takes each raw-QUIC endpoint in the runner's registry at its highest registered draft, and runs the
runner proposal's two cases with the synthetic fixture: a carriage subscriber up 2 s before the
publisher, and a late subscriber joining 8.5 s in, both `export ts --passthrough`, against
publishers running `import ts --passthrough` paced by `tsp regulate`. The proposal's `check-ts.py`
grades carriage as the whole fixture and as a tail, and the late capture as a tail. First,
[`p1h-relay-probe.sh`](scripts/p1h-relay-probe.sh) dialled the relays the first sweep never reached,
on both transports, with each session logged to its first request.

| Relay | Draft | Carriage (subscriber first) | Late subscriber |
|---|---|---|---|
| `moq-dev` (`cdn.moq.dev`) | 20 | **whole** | **pass** |
| stitcher-moq (a `moq-relay`) | 22 | **whole** | **pass** |
| libquicr (Cisco) | 18 | **whole** | **pass** |
| moqx (OpenMOQ) | 18 | **whole** | **pass** |
| moxygen (Meta) | 22 | intact from group 1 | **pass** |
| Cloudflare draft-18 | 18 | intact from group 1 | **pass** |
| moqtail (OzU) | 18 | **whole** | the broadcast's first group, then the live one: 3 continuity errors |
| moqtail | 22 | intact from group 2 | nothing: the catalog never arrives |
| aiomoqt | 22 | intact from group 3 | nothing: the catalog never arrives |
| Nokia Research | 22 | intact from group 3 | nothing: the catalog never arrives |
| red5 | 22 | the rest of group 0 lost at the join (284 packets), intact after | **pass** |
| imquic (Meetecho) | 22 | one packet lost at 10 of the 19 group boundaries | the same losses |
| Nokia Research | 18, 19 | TLS handshake refused with alert 120 (no application protocol) at both drafts; its WebTransport CONNECT answers 500 | — |
| quiche-moq (Google) | 18, WebTransport only | the host answers neither UDP nor TCP on 443, from EC2 or a home line | — |

*Whole*: every check passes against the whole fixture. *Intact from group N*, and *pass* for a late
subscriber: every check passes on the capture as a tail starting at a group's first packet, nothing
lost after it.

**Three behaviours, none of them `moq-dev`'s.** The controls are the relays that pass, with the same
client, fixture and grading.

- **Where a new subscription starts.** The importer writes its catalog only once the first group
  holds objects, so even the carriage subscriber reaches the TS track after group 0 has begun.
  moqx, at object 30 of group 0 when its SUBSCRIBE_OK went out, delivered that group from its first
  object; moxygen at object 24, moqtail at object 50 of group 1 and aiomoqt at object 11 of group 2
  each started at the next group, and delivered a clean tail from there. Both are legitimate joins.
  The proposal's carriage case orders the subscription before the first object, which a test
  client built on the `moq` CLI cannot do until the importer writes its catalog earlier.
- **A late subscriber and a catalog written once.** `moq-dev`'s subscriber asks for the current
  group (draft 22's location filter in FILL_PARAMETERS). aiomoqt, moqtail and Nokia answer the
  catalog's SUBSCRIBE with SUBSCRIBE_OK and send nothing, because the catalog's only group predates
  the subscription; moxygen and red5 deliver it on the same draft. The FILL_PARAMETERS framing split
  (§ T11d) would produce exactly this in a relay that reads the filter as absent; their side was not
  observed. On draft 18, moqtail answers the same request with the broadcast's first group.
- **Losses after the join.** Every packet imquic lost is the PCR-only packet (adaptation field only,
  PID 256) that ends a group, its final object. red5, joining the subscriber at object 36 of group 0,
  delivered the start of that group and dropped the rest.

The sessions themselves now set up everywhere but Nokia's draft-18 endpoint and quiche-moq: moqtail
and libquicr, which the first sweep could not reach, accept PUBLISH_NAMESPACE and the empty-prefix
SUBSCRIBE_NAMESPACE on both transports. Cloudflare's draft-18 relay takes an anonymous publish.

**What this establishes.** Relay portability holds for carriage after the join on seven of nine
third-party relays, and for both of the proposal's cases on libquicr and moqx; moxygen and Cloudflare
join if a start at the next group is accepted. It is not yet the neutral fabric the architecture
assumes: two relays lose media, and on three a subscriber joining mid-stream never starts.

### The first sweep, with `moq` 0.9.8

The client's first sweep carried media through `moq-dev`'s relays alone and through none of eight
others. The main cause was the publisher's: it withheld `PUBLISH_NAMESPACE` until a peer sent it a
`SUBSCRIBE_NAMESPACE`, which only `moq-dev`'s relay does. Proactive announcement is a MAY in the
drafts, so it was reported as an interop hazard rather than a bug, and it is fixed upstream. Behind
it, moxygen then rejected the subscriber's empty-prefix `SUBSCRIBE_NAMESPACE` (error 16), a draft
inconsistency the working group resolved in favour of the empty tuple. moqtail refused SETUP, and
quiche-moq and libquicr never established a session; at `main` those three resolve as above.

### A 200 ms QUIC/WebSocket race

The client still starts a WebSocket attempt 200 ms after dialling QUIC (`QUIC not yet connected,
attempting WebSocket fallback delay_ms=200`, in the probe's logs at `main` too). Wherever QUIC
answered on the probe's paths it won, but a fixed 200 ms timer will tend to choose WebSocket for any relay more than about
100 ms away: a confound for interop measurement, since the transport under test is not the one
named, and a concern for broadcast carriage, since WebSocket means TCP and head-of-line blocking.

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

**Six third parties, six passes; two of nine third-party MoQ relays pass both cases.** Every capture cleared
the same twelve hard checks the MoQ arm clears — continuity, sync, TEI, PAT, PMT, service count and
stream inventory all matching the source.

Three of those rows carry more weight than the raw count.

**The cache row is the one that matters architecturally**, because it is the segmented lane's answer
to the relays that lose or never start our media. An off-the-shelf nginx in front of the origin,
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

The interop matrix today is control-plane only. Against imquic, red5, aiomoqt, moqtail and Nokia,
every control-plane cell this sweep exercised succeeds while media is lost or a late subscriber never
starts. **That gap is invisible in the current matrix**, and it is the strongest argument for the
media-level profile proposed in #32.

## T11b — OpenMOQ's MSFTS publisher through a `moq-dev` relay

The question is whether an outside implementation's opaque TS crosses a `moq-dev` relay intact.
`moqxr` has no subscriber, so a `moq-dev` broadcast into an OpenMOQ receiver is T11c's, on moq5.

**What was run.**

- **Publisher:** the headless `examples/msfts-publisher` in [`moqxr`](https://github.com/openmoq/moqxr)
  0.4.4. The plan named `moq2ts`, which then had no headless mode (T11d runs the one it has since
  gained); the example is the same project's headless MSFTS publisher, on the MSFTS -01 catalog
  field names. It keeps the selected
  programme's PIDs and the nulls and drops NIT, SDT and TDT. It rewrites the PAT and the PAT/PMT
  continuity counters and inserts PAT and PMT copies periodically. It puts every object in group 0, one
  every 10 ms, and publishes only while subscribed.
- **Relay:** `moq-relay` from `moq-dev` main at `00e24446f`, local, GSO off, anonymous grant
  ([`t11b-relay.toml`](scripts/t11b-relay.toml)).
- **Subscriber:** [`t11b-rawsub.rs`](scripts/t11b-rawsub.rs), a `moq-net` client that holds one
  SUBSCRIBE and writes each object's payload in arrival order. `moq fetch` cannot stand in for it,
  because the relay forwards the FETCH to this publisher, which answers *unsupported*.
- **Clip:** the first 15 s (99,000 packets) of a CNN International capture. It is a single programme
  at 9.93 Mb/s: PMT 100, PCR and video on 111, six other elementary streams and 4,525 nulls.
- **Oracle:** [`t11b-grade.py`](scripts/t11b-grade.py) per PID, plus TSDuck continuity.
- **Measurement:** P1, co-resident on loopback, source file against received file. Rigs:
  [`t11b-arm.sh`](scripts/t11b-arm.sh) and [`t11b-rejoin.sh`](scripts/t11b-rejoin.sh).

"Patched" below means one line added to the example (defect A). Rows marked *as released* ran
without it.

| Arm | Draft and transport | Subscriber | Result |
|---|---|---|---|
| As released | 18, raw QUIC | IETF-18 | **1 object of 1,500.** Its 68 packets match the source; nothing follows (A) |
| As released | 18, raw QUIC | moq-lite-06 | **0 objects** (B) |
| Patched | 18, raw QUIC | IETF-18 | **Pass.** 1,500 objects in order, 18,619,896 bytes. Every elementary-stream PID identical to the source packet for packet, nulls 4,525 of 4,525, NIT/SDT/TDT absent, zero TSDuck continuity errors |
| Patched, 60 s clip | 18, raw QUIC | IETF-18 | **Relay aborts group 0 as too large** after 2,702 objects, 27.0 s in (C) |
| Patched | 18, raw QUIC | moq-lite-06 | **0 objects.** The publisher refuses the relay's second SUBSCRIBE as a duplicate (B) |
| Patched, rejoin after 15 s | 18, raw QUIC | IETF-18, twice | **Second subscriber refused** the same way, 5.07 s after the relay cancelled the first (B) |
| Patched | 17, raw QUIC | IETF-17 | **Publisher closes the session** on the relay's SUBSCRIBE_NAMESPACE (D) |
| Patched | 16, raw QUIC | IETF-16 | **Publisher fails:** "peer request id is not next in sequence" (D) |
| Patched, and as released | 14, raw QUIC | IETF-14 on both builds, moq-lite-06 patched only | **Publisher times out** "waiting for stream data" about 2 s in (D, not isolated) |
| Patched | 18, WebTransport | IETF-18 | **Publisher will not send CONNECT:** the relay omits `reset_stream_at` (E) |

**A. Every object claims to close its subgroup.** The publisher library's object type defaults
`final_in_subgroup` to true, and the example sets group 0 on every object without overriding it. The
session therefore FINs subgroup 0 after object 0 and silently skips every later object in the same
group, because its subgroup is closed. The publisher reports *"Published 1 objects"* and exits 0. The
relay and subscriber both behave correctly: one stream arrives, carries one object and ends. Setting
`final_in_subgroup = false` on the media objects is the fix used in every patched arm. This is a
defect in the example, not the library.

**B. The draft-18 publisher never releases a cancelled subscription.** The set of established
subscriptions it checks before admitting a SUBSCRIBE is inserted into and never erased, in all three
of its publish paths. Draft 18 allows a publisher at most one subscription per track and
DUPLICATE_SUBSCRIPTION only against an existing one. It also lets the publisher destroy subscription
state as soon as it receives STOP_SENDING (§5.1.1). Draft 18 has no UNSUBSCRIBE: a subscriber cancels
by terminating the request stream. `moq-relay` triggers the defect on every moq-lite subscriber. It
answers the subscriber's track-info probe by subscribing upstream, cancelling as soon as SUBSCRIBE_OK
arrives, and then subscribing again for the real request about 0.5 ms later.

At 0.5 ms the refusal could be a cross-stream race, since QUIC orders nothing across streams. The
rejoin arm rules that out. The relay cancelled its upstream subscription when the first subscriber's
session timed out, the second subscriber arrived 5.07 s later, and the publisher refused the relay's
new SUBSCRIBE twice with the same error.

**C. One group for the life of the stream.** `moq-net` caps a group at 8,192 frames and at 32 MiB
(`MAX_GROUP_FRAMES`, `MAX_CACHE_BYTES`), and aborts it as too large past either.

- At 66 packets per object and 9.93 Mb/s, the byte cap binds first. It cut the stream at 27.0 s, with
  33,571,912 bytes published against a cap of 33,554,432.
- At the example's default of 7 packets per object, the frame cap binds first. A subscriber received
  exactly 8,192 objects and then lost the track.

MSFTS -02 says *"A Group SHOULD NOT last longer than 2 seconds"*, and the example predates -02. A
bounded group is `moq-dev`'s model rather than a defect, so this is a publisher-side incompatibility.
It also sets the join behaviour. A subscriber attaching 7 s into the stream received the group's
whole cached history, 832 objects in its first second, before reaching the live edge.

**D. Drafts 14 to 17 fail on the relay's SUBSCRIBE_NAMESPACE.** `moq-relay` sends SUBSCRIBE_NAMESPACE
on the empty prefix to every session, publishers included (see *Root cause* above). Only on draft 18,
where the message became 0x50, does the publisher handle it.

- **Draft 17:** the publisher's request-stream dispatcher treats 0x11 as unknown while request
  streams are in use. It answers *"unsupported request stream"* and closes the session as a protocol
  violation. Draft 17 defines 0x11 as SUBSCRIBE_NAMESPACE on a request stream, and `moq-net` encodes
  it as such.
- **Draft 16:** the trace fits a publisher that does not count the relay's request 1 (the
  SUBSCRIBE_NAMESPACE) in its request-ID sequence, so the SUBSCRIBE that follows as request 3 is out of
  sequence. This rests on the message trace, not on a reading of the publisher's code.
- **Draft 14:** the failure follows the same two requests but has not been isolated.

**E. WebTransport.** WebTransport over HTTP/3 (`draft-ietf-webtrans-http3-16` §3.1) requires a server
to send an empty `reset_stream_at` transport parameter. `moq-relay` does not, and the publisher
enforces the requirement. This is a `moq-dev` gap, and `moq-dev` already plans the fix in its own
reliable-reset quest. Browsers connect to `moq-relay` today, so the gap shows only against a client
that enforces the parameter.

**What this establishes.** When the publisher behaves, an outside implementation's opaque TS crosses
a `moq-dev` relay unaltered on every elementary-stream PID. That is measured on one combination only:
draft 18, raw QUIC, an IETF subscriber, a one-line publisher fix and a stream under 27 s at this
bitrate. As released, the publisher delivered at most one object on the three combinations tried:
draft 18 to an IETF and to a moq-lite subscriber, and draft 14. All of A to D are on the
publisher side, and the relay contributed no defect to the passing arm. The result is one relay
against one outside publisher, co-resident and from file. It is evidence for the neutral-fabric
assumption at the byte level, not for interoperability as deployed. T11d ran the MSFTS -02 publisher
in `moq2ts` against the same relay on draft 22, where it does not get as far as the data path.

## T11c — moq5 against `moq-dev`, both ways (criteria fixed before the first run)

OpenMOQ's [moq5](https://github.com/openmoq/moq5) has a sender, a receiver and a relay, so it closes
what `moqxr` left open. Four directions, each on every draft both builds speak (16, 18, 22; raw QUIC):

| # | Publisher | Relay | Subscriber | Tests |
|---|---|---|---|---|
| 1 | `moq import ts`, `--passthrough` and demultiplexed | `moq5-relay` | `moq export ts` | relay portability, theirs |
| 2 | moq5 sender (MSFTS) | `moq-relay` | moq5 receiver | relay portability, ours |
| 3 | `moq import ts`, both modes | `moq-relay` | moq5 receiver | catalog, ours to theirs |
| 4 | moq5 sender | `moq-relay` | `moq export ts` | catalog, theirs to ours |

**An arm passes** when, held for at least 120 s at the clip's rate (four times T11b's 27 s ceiling)
with no session or group abort:

1. the subscriber finds the TS track through the publisher's own catalog, with no track name or
   packaging given out of band (a failure records the field it lacked);
2. a passthrough arm delivers the source's packet sequence on every elementary-stream PID
   (`t11b-grade.py`, PSI continuity masked), and a demultiplexed arm passes the campaign's content
   grader per PID;
3. TSDuck reports zero continuity errors;
4. the negotiated draft and ALPN, and both builds' commits, are recorded.

Measurement P1: co-resident on loopback, from file, paced by PCR. **Predicted:** directions 1 and 2
pass on bytes; 3 and 4 fail at discovery (MSF `mpeg2ts` packaging against the hang catalog's `m2ts`
section).

**Results: directions 2 and demultiplexed 1 pass; passthrough 1 fails in `moq5-relay`; 3 and 4 fail
at discovery, as predicted.**
`moq-dev` `3c0daa21b` against moq5 `0729c49` (`moq5-relay` on MsQuic), raw QUIC, where the ALPN
(`moqt-16`, `moqt-18`, `moqt-22`) is the negotiated draft and both sides logged the one offered.
moq5's side is the harness [`t11c-moq5-ts.c`](scripts/t11c-moq5-ts.c) on its service tier; rigs
[`t11c-d1.sh`](scripts/t11c-d1.sh) and [`t11c-arm.sh`](scripts/t11c-arm.sh); a 120 s clip at
9.9 Mb/s. The harness's own loop through `moq5-relay` delivers every PID byte-exact.

| # | 16 | 18 | 22 | Where it stops |
|---|---|---|---|---|
| 1, passthrough | fail | fail | fail | the catalog's join, in `moq5-relay` |
| 1, demultiplexed | pass | pass | pass | — |
| 2 | pass | pass | pass | — |
| 3 | fail | fail | fail | discovery: no track moq5 can deliver |
| 4 | fail | fail | fail | discovery: `moq-dev` reads no `mpeg2ts` packaging |

- **Direction 1, passthrough, never delivers the catalog, so no media follows.** The export
  subscribes to `catalog.json` and gets `SUBSCRIBE_OK` with largest 2/0; the importer published the
  catalog once, in group 2. On drafts 16 and 18 the export joins with a Joining FETCH, which
  `moq5-relay` forwards upstream as a standalone FETCH of group 2; `moq-dev` answers it with
  `FETCH_OK` and the object (its End Location the request's, as draft 16 §9.17 has it), and
  `moq5-relay` never answers downstream. Its design collects the whole upstream response before its
  own `FETCH_OK`, and the stall is inside that. On draft 22 the export joins at the current group, a
  Next Object filter with a fill from StartGroup 1 (§3.5). `moq5-relay` serves fills only from what
  it has retained, its upstream `SUBSCRIBE` asks for no fill, and group 2 was never retained; draft
  22's relay "retrieves any missing objects upstream using a SUBSCRIBE with FILL_PARAMETERS or
  FETCHes". Both are on `moq5-relay`'s side. The first run's draft-18 announce that was acknowledged
  but not kept did not recur.
- **Direction 1, demultiplexed, passes on all three drafts:** the export has the catalog within
  4 ms of subscribing and subscribes to every track, with no continuity error and, on the content
  grader ([`t28-content-lost.py`](scripts/t28-content-lost.py)), no video or audio lost or repeated.
  On each draft the requests are the passthrough arm's, and `moq-dev` serves group 2 on the relay's
  subscription the same way in both modes. What in the two catalogs decides whether `moq5-relay`
  delivers one is not located.
- **Direction 2 passes on all three drafts:** 144,753,420 bytes, every elementary-stream PID a
  contiguous byte-exact suffix of the source from the join at group 2, no continuity error, and no
  gap in the receiver's own loss report across 100 groups. That holds with the sender dropping
  media written before any subscriber, as a live source does. Under moq5's default, which queues
  that media until demand appears, the receiver got group 0 only to object 36 and then group 1 with
  the rest of group 0 reported lost: seven continuity errors on draft 18. Which side drops the tail
  is not established.
- **Directions 3 and 4: each side's TS track is invisible to the other's catalog parser.**
  `moq-dev`'s MSF catalog lists only video, audio and text renditions, so for a passthrough import
  it is empty, the track named only in the hang catalog's `m2ts` member, and moq5 enumerates no
  track. That is upstream's TS draft as written: its frames carry timestamps, so an MSFTS
  subscriber needs a converter that republishes them. Demultiplexed, it lists `0.avc3` and `6.mp2` as `legacy` packaging, which moq5 does not
  parse, so moq5 subscribes to neither. The other
  way, `moq export ts` reads moq5's catalog only under a `.msf` broadcast name (otherwise
  `catalog.json` is refused *not found*), then skips the track with a warning: its MSF parser has
  no `mpeg2ts` packaging. The export then waits on the catalog until the broadcast ends, about
  2 minutes later, and exits 1 on the relay's PUBLISH_DONE, with no error naming the missing track.

## T11d — `moq2ts` headless, publisher and receiver (criteria fixed before the first run)

`moq2ts` now ships a headless MSFTS -02 publisher (`moq2ts-cli`, on `moqxr`) and a console receiver
(`moq2ts-receiver`, on moq5's service tier, draft 22 only), so T11b's arm can run against the
project's own publisher, and a second MSFTS subscriber joins T11c's. Raw QUIC, draft 22, loopback,
the same 120 s clip at 9.9 Mb/s, the publisher in `--unmodified --paced` mode (every source packet
forwarded unchanged, paced at media rate):

| # | Publisher | Relay | Subscriber | Tests |
|---|---|---|---|---|
| A | `moq2ts-cli` | `moq-relay` | `moq2ts-receiver` | our relay carries their TS, both ends theirs |
| B | `moq2ts-cli` | `moq5-relay` | `moq2ts-receiver` | the same on their relay (control) |
| C | `moq import ts`, both modes | `moq-relay` | `moq2ts-receiver` | catalog, ours to theirs |
| D | `moq2ts-cli` | `moq-relay` | `moq export ts` | catalog, theirs to ours |

**An arm passes** when, over the whole clip with no session or group abort: (1) the subscriber finds
the TS track through the publisher's catalog, with nothing given out of band; (2) the capture is the
source's own bytes from the join, every PID ([`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py):
nothing foreign, no gap); (3) TSDuck reports zero continuity errors; (4) the PCR value checks
([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py)) give the source's verdict. The receiver writes
objects as they arrive, so its release timing is reported, not graded: a receiver that does not pace
needs a pacer before an IRD. **Predicted:** A and B pass; C and D fail at discovery, as T11c's
directions 3 and 4 did, since neither side's catalog parser reads the other's TS track.

**What was run.** `moq-dev` at `3c0daa21` (relay and CLI), `moq2ts` 1.0.4 on `moqxr` 0.4.4, and the
msquic build of `moq5-relay`; the 120 s clip (793,000 packets, 9.95 Mb/s); loopback on one host,
source file against received file (P1). Rig: [`t11d-arm.sh`](scripts/t11d-arm.sh).

| Arm | Result |
|---|---|
| A | **Fails at the first SUBSCRIBE.** The relay subscribes upstream for the receiver's catalog; `moqxr` answers REQUEST_ERROR code 1, "invalid SUBSCRIBE", and closes the session. Nothing is delivered |
| B | **The source byte for byte, then its last group again.** All 793,000 packets arrive in order from packet 0, nulls included, followed by the final group's 6,172 packets (0.93 s) a second time. On the first 793,000 packets every check gives the source's verdict; the repeat accounts for all six continuity errors and the one non-positive PCR interval, so criteria 2 to 4 fail as written |
| C, both modes | **Fails at discovery**, as predicted: "catalog has 0 matching TS tracks". Naming the track (`--track 0.m2ts`) does not get round it, because the receiver chooses only among catalog tracks with MSF `mpeg2ts` packaging |
| D | **Fails at the first SUBSCRIBE**, as A does. `moq export ts` prints "unauthorized", which is how `moq-net` names REQUEST_ERROR code 1 |

**Why A and D fail: one draft-22 ambiguity, not a carriage defect.** The relay's upstream SUBSCRIBE
carries FILL_PARAMETERS (0x23) holding a Location Filter: draft 22's current-group join. Draft 22
length-prefixes the value and calls it "a sequence of Parameters … encoded as if they were Parameters
for a separate message". `moq-net` writes a parameter count first, as a message does. `moqxr`'s
decoder reads parameters straight away, takes the count as parameter type 0x01 and rejects the
message. [moq-wg/moq-transport#1991](https://github.com/moq-wg/moq-transport/issues/1991) records the
same split (moq-net and Meta send the count, moqtail does not), and the open
[#2015](https://github.com/moq-wg/moq-transport/pull/2015) settles it as a count with no length
prefix, which both sides would have to adopt. The locus rests on the relay's trace of the SUBSCRIBE's
fields and on the decoder's code; the bytes were not captured.

**Two publisher behaviours the arms had to work around.** `--paced` releases one object per
`--fragment-ms` whatever it holds, so at the default 64 KiB every 250 ms it sends 2.09 Mb/s whatever
the source rate. The arms set `--segment-bytes 310764`, 250 ms of this clip. A first arm B without it
had to be stopped, and the publisher then aborted in shutdown ("double free or corruption") after a
10 s close-drain timeout. The receiver writes each 250 ms object as it lands: 91.5 % of PCRs are
released more than 10 ms early (p95 216 ms), reported and not graded.

**What this establishes.** `moq2ts`'s publisher and receiver carry a transport stream byte-exact over
OpenMOQ's relay, apart from a repeated final group. The run cannot say whether the publisher or the
relay repeats it: the relay counts 481 objects in and out, the receiver 484. Against `moq-dev` they
interoperate in neither direction on draft 22. The FILL_PARAMETERS split closes the data path before
any TS object reaches `moq-relay`, and the two TS descriptions (MSF `mpeg2ts` and `moq-dev`'s `m2ts`)
close discovery. So T11d says nothing yet about `moq-relay` carrying their TS; arm A reruns once either
side adopts #2015's framing.

## Status and next steps

- [x] Fixture generator, oracle, and oracle sensitivity tests
- [x] Test client conforming to the runner's interface (TAP v14, exit 0/1/127)
- [x] Local and public `moq-dev` validation
- [x] Sweep across all registered public relays
- [x] Proposal posted to [#32](https://github.com/englishm/moq-interop-runner/issues/32#issuecomment-5239364972)
- [x] Root cause reported upstream as [moq-dev/moq#2730](https://github.com/moq-dev/moq/issues/2730),
      framed as an interop hazard rather than a bug since the behaviour is conformant; fixed
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
- [ ] Raise the 200 ms QUIC→WebSocket fallback timer separately
- [x] P1-h and the sweep at `main` across the registry's relays (§ Results at `main`)
- [ ] Report imquic's lost final objects, red5's loss at the join, and the late subscriber that
      aiomoqt, moqtail and Nokia never start (not drafted)
- [x] Transparent-carriage variant: the runner proposal's checker grades byte identity, and passes
      `moq-dev`'s `--passthrough` lane through its relay
- [ ] The two TS cases, fixture and checker proposed to the runner as
      [englishm/moq-interop-runner#159](https://github.com/englishm/moq-interop-runner/pull/159); once
      it merges, [`interop/`](../interop/README.md) retires and this file's method cites the runner
- [x] T11b: OpenMOQ's MSFTS example publisher through a `moq-dev` relay, across drafts 14, 16, 17
      and 18, raw QUIC and WebTransport, with IETF and moq-lite subscribers
- [x] T11b's publisher defects A, B and D, and the single-group incompatibility C, reported as
      [openmoq/moqxr#57](https://github.com/openmoq/moqxr/issues/57)
- [x] T11c, the four moq5 directions on drafts 16, 18 and 22 (§ T11c); moq5 claims no
      cross-implementation result of its own
- [x] T11c's passthrough join reported as [openmoq/moq5#51](https://github.com/openmoq/moq5/issues/51);
      its discovery result posted to [moq-dev/moq#3731](https://github.com/moq-dev/moq/issues/3731#issuecomment-6223909800)
- [x] T11d, `moq2ts`'s headless publisher and receiver against `moq-dev` on draft 22
- [ ] Rerun T11d arm A once `moqxr` or `moq-net` adopts moq-transport#2015's FILL_PARAMETERS framing
- [ ] Report T11d's pacing defect and repeated final group to `moq2ts` (drafted, not posted)
