# Test 11 — Cross-implementation interop

**Pyramid rung 7** (comparative lab). **Feeds:** [comparison](../docs/comparison.md) §12 and the "a MoQ relay is a neutral transport fabric" assumption in [architecture](../docs/architecture.md). **State:** T11a run at `main` (P1-h) against every relay in the interop runner's registry, `moq-dev` publishing and subscribing over raw QUIC. **Of nine third-party relay implementations reached, seven carry the TS intact from the subscriber's join, and two lost packets after it** in each of two runs, imquic at group ends and red5 within the group being written when a subscription joins. Three replicates on later `main` mapped them: at the same ten of nineteen boundaries imquic's relay sends a group's final object on a second stream of its subgroup, which `moq-dev`'s subscriber drops (a parser defect that imquic's fix removes), and red5 lost nothing after a join at the next group. The join itself splits them. libquicr and moqx start a subscriber at the current group and pass both of the runner proposal's cases. moxygen and Cloudflare start at the next group and still serve a late subscriber. aiomoqt, moqtail and Nokia (draft 22) also start at the next group, and never deliver the catalog to a late subscriber, so `moq export ts` joining mid-stream receives nothing; on draft 18 moqtail hands it the broadcast's first group before the live one. Nokia's draft-18 endpoint refuses the TLS handshake at ALPN, and quiche-moq's host does not answer. The first sweep, with `moq` 0.9.8, carried nothing through any of eight relays; its main cause, a publisher that announced only when asked, is fixed upstream.

**T11b run: an outside opaque-TS publisher through a `moq-dev` relay.** OpenMOQ's MSFTS example publisher, as released, delivers at most one object on each of the three combinations tried. With a one-line publisher fix it crosses the relay **byte-exact on every elementary-stream PID**, but only on draft 18 over raw QUIC to an IETF subscriber, and only for about 27 s at 10 Mb/s before the relay aborts its single unbounded group. Every other combination fails on a publisher-side defect, bar WebTransport, which fails on a relay transport parameter `moq-dev` already plans to add. No relay defect was found in the passing arm. **T11c on OpenMOQ's moq5 (P1-h), on drafts 16, 18 and 22:** moq5's TS crosses a `moq-dev` relay byte-exact on every PID, and `moq-dev`'s TS crosses `moq5-relay` in both modes: demultiplexed with no content lost, and passthrough byte-exact on every PID on moq5 `main`, which fixed the draft-22 join we reported. Neither side's TS track is visible to the other's catalog parser.

**The same fixture and oracle put through segmented HTTP pass against every third party tried** — FFmpeg, VLC, a bare `curl` loop, an off-the-shelf nginx cache, and Apple's `mediastreamvalidator` with 0 errors and 0 warnings. Two clients through the cache cost the origin nine segment fetches rather than eighteen, which is the CDN scaling argument measured rather than asserted. **Six third parties, six passes; on MoQ, two of nine third-party relays pass both cases.** One correction falls out of it: the HLS packager is _not_ byte-transparent — it re-muxes, and it silently truncated 5.0 % of a finite input.

## Objective

"A MoQ relay is a neutral transport fabric" is load-bearing for this project, and every other test in this campaign exercises it only against `moq-dev` peers. T11 tests it against everyone else's.

The claim is comparative, so the measurement has to be. Segmented HTTP's whole case rests on an interoperability assertion of the same shape — that any HTTP client reads it and any HTTP cache forwards it — and that assertion is repeated far more often than it is tested. **The segmented arm therefore asks the identical question with the identical fixture and oracle**, so the two tables can be read against each other rather than merely placed side by side.

The secondary objective is a contribution: the work is shaped as a test client for [`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) rather than a private rig, in support of [#32](https://github.com/englishm/moq-interop-runner/issues/32). Building it for the harness and running it for ourselves is the same work.

## Method

Client, fixture and oracle live in [`interop/`](interop/README.md) — see that README for the interface contract, usage and the sensitivity results.

- **Fixture:** synthetic, generated at build time. 20 s, 2 Mbps CBR, H.264 640×360 + AAC, 1 s closed GOP, one service, video PID 256, audio PID 257. 26,612 packets, continuity clean at birth.
- **Oracle:** continuity counters plus PSI/SI, via TSDuck. No decoder, no player, no frame capture. Verified sensitive to packet loss, duplication and reordering before being trusted (see README).
- **Tests:** `ts-carriage-integrity` (subscriber present throughout) and `ts-late-subscriber` (joins 8 s in). Publisher paced with `tsp regulate --pcr-synchronous`, so the relay sees a live arrival pattern rather than a file burst.

**Byte identity is graded on the opaque lane only.** The sweep at `main` runs `import ts --passthrough` into `export ts --passthrough`, whose egress is the fixture's own bytes, and the proposal's `check-ts.py` grades it so. The first sweep, on `moq` 0.9.8, could run only the media-aware lane, which demultiplexes to `hang` tracks and remultiplexes at egress (5,003,056 → 4,366,112 bytes, essentially the CBR null stuffing it does not carry), so it was graded on the oracle alone.

## Results at `main`: the registry's relays (P1-h)

**What was run.** `moq-dev` at `3c0daa21` at both ends, from an EC2 host over the public internet; fixture against received file (P1); one run per relay. [`t11-relay-sweep.sh`](scripts/t11-relay-sweep.sh) takes each raw-QUIC endpoint in the runner's registry at its highest registered draft, and runs the runner proposal's two cases with the synthetic fixture: a carriage subscriber up 2 s before the publisher, and a late subscriber joining 8.5 s in, both `export ts --passthrough`, against publishers running `import ts --passthrough` paced by `tsp regulate`. The proposal's `check-ts.py` grades carriage as the whole fixture and as a tail, and the late capture as a tail. First, [`p1h-relay-probe.sh`](scripts/p1h-relay-probe.sh) dialled the relays the first sweep never reached, on both transports, with each session logged to its first request.

| Relay | Draft | Carriage (subscriber first) | Late subscriber |
| --- | --- | --- | --- |
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

_Whole_: every check passes against the whole fixture. _Intact from group N_, and _pass_ for a late subscriber: every check passes on the capture as a tail starting at a group's first packet, nothing lost after it.

**Three behaviours, none of them `moq-dev`'s.** The controls are the relays that pass, with the same client, fixture and grading.

- **Where a new subscription starts.** The importer writes its catalog only once the first group holds objects, so even the carriage subscriber reaches the TS track after group 0 has begun. moqx, at object 30 of group 0 when its SUBSCRIBE_OK went out, delivered that group from its first object; moxygen at object 24, moqtail at object 50 of group 1 and aiomoqt at object 11 of group 2 each started at the next group, and delivered a clean tail from there. Both are legitimate joins. The proposal's carriage case orders the subscription before the first object, which a test client built on the `moq` CLI cannot do until the importer writes its catalog earlier.
- **A late subscriber and a catalog written once.** `moq-dev`'s subscriber asks for the current group (draft 22's location filter in FILL_PARAMETERS). aiomoqt, moqtail and Nokia answer the catalog's SUBSCRIBE with SUBSCRIBE_OK and send nothing, because the catalog's only group predates the subscription; moxygen and red5 deliver it on the same draft. The FILL_PARAMETERS framing split (§ T11d) would produce exactly this in a relay that reads the filter as absent; their side was not observed. On draft 18, moqtail answers the same request with the broadcast's first group.
- **Losses after the join.** Every packet imquic lost is the PCR-only packet (adaptation field only, PID 256) that ends a group, its final object. red5, joining the subscriber at object 36 of group 0, delivered the start of that group and dropped the rest. A second run of both, same build and rig, reproduced loss with a different pattern: imquic lost 4 video packets and the PAT and PMT after them once, about 18.7 s in, and never announced the late broadcast to the late subscriber, whose namespace subscription it acknowledged 8 s after accepting the publisher's; red5 lost 13 video packets, the PAT and PMT and one SDT packet within the first 1.2 s, and passed the late case. The replicates below map each loss to its group and object.

The sessions themselves now set up everywhere but Nokia's draft-18 endpoint and quiche-moq: moqtail and libquicr, which the first sweep could not reach, accept PUBLISH_NAMESPACE and the empty-prefix SUBSCRIBE_NAMESPACE on both transports. Cloudflare's draft-18 relay takes an anonymous publish.

**What this establishes.** Relay portability holds for carriage after the join on eight of nine third-party relays, and for both of the proposal's cases on libquicr and moqx; moxygen and Cloudflare join if a start at the next group is accepted. It is not yet the neutral fabric the architecture assumes: two relays lost media, imquic still splits a group's stream where `moq-dev`'s subscriber loses its end, and on three a subscriber joining mid-stream never starts.

### imquic and red5 replicated, losses mapped (criteria fixed before the first run)

The export drops an object that arrives later than its `--delay` (1 s by default) and logs it, so a packet missing from the capture may be one the relay delivered late rather than lost. Three replicates of the sweep on early November 2026 `main`, `moq-dev`'s own relay first in each as the control, each adding a carriage subscriber at a 10 s delay (`SLOW_DELAY=10s`). [`t11-loss-map.py`](scripts/t11-loss-map.py) recomputes the importer's groups and objects from the fixture and names the group and object of every packet a capture lacks between its join and end; on a synthetic capture with four known packets removed it named those four.

1. **Valid run:** the control passes carriage whole and the late case.
2. **Late or lost:** a packet missing at the 1 s delay and present at 10 s was delivered late; missing at both, it was not delivered within 10 s.
3. **Reportable:** a loss at the same place in the group structure (for example a group's last object) in at least two of three replicates, in the same class.

**Results** (`moq-dev` at `204c97f4f` at both ends, from the EC2 host):

| Relay | Carriage, 1 s delay | Carriage, 10 s delay | Late subscriber |
| --- | --- | --- | --- |
| `moq-dev` (control) | whole, 3 of 3 | whole, 3 of 3 | pass, 3 of 3 |
| imquic | the last object of groups 2, 3, 5, 8, 9, 11, 12, 15, 17 and 18 missing, 3 of 3; in one, also seven objects of group 14 | the same ten, 3 of 3 | the same ten from its join, 3 of 3 |
| red5 | intact from group 1, 3 of 3 | intact from group 1, 3 of 3 | pass, 3 of 3 |

- **Criterion 1 holds** in every replicate.
- **Through imquic, `moq-dev`'s subscriber lacks a group's final object at the same ten boundaries of nineteen**, in every replicate and at either delay, the count the first sweep showed. Each is one PCR-only packet, some with a null packet behind it; neither shape, size nor the group's object count (51 in all nineteen) separates the ten from the nine delivered. Reportable by criterion 3; the relay sends them on a split stream that subscriber drops (below). Group 14's objects, in one replicate, were late: the 1 s export dropped them (its seven deadline drops) and the 10 s one has them.
- **red5 lost nothing in any replicate**: it starts a subscription at the next group, as moxygen and Cloudflare do. The earlier runs' losses within the first group did not recur on this build.

### imquic's final objects: which client loses them (criteria fixed before the first run)

imquic's maintainer asked whether the objects come back on FETCH; a probe from the laptop with imquic's own subscriber (`imquic-moq-sub`, imquic `7b19884` on picoquic `629e4b64`) received every final object of the groups `moq-dev` lacked. [`t11-imquic-fetch.sh`](scripts/t11-imquic-fetch.sh) runs three clients on one publish, three replicates, from the laptop: **M**, `moq export ts --passthrough` up before the publisher, mapped by `t11-loss-map.py`; **I**, imquic's SUBSCRIBE from 2 s in, each object logged with its group, ID, size and whether its stream ended with it; **F**, imquic's FETCH of groups 0–19, ascending, from 26 s in, the publisher still connected.

1. **Valid:** M lacks the final object at five or more of the nineteen boundaries.
2. **Per group M lacks:** whether I received the final object, and whether F did.
3. **Reading, 3 of 3:** I and F both hold every final object M lacks: the relay stores and forwards them, and the loss is `moq-dev`'s subscriber's. F holds them and I lacks them: the relay's forwarding. F lacks them: the relay never stored them.
4. **Diagnostic, not graded:** whether M's lost groups are those whose final object reached I with its stream's end, as the probe suggested.

**Results** (`moq-dev` at `204c97f4f`, imquic `7b19884`; three replicates, and a fourth with `moq-dev`'s network layer at debug level; graded by [`t11-imquic-grade.py`](scripts/t11-imquic-grade.py)):

| Replicate | M lacks the final object of groups | I holds them | F holds them | Groups I received on two streams |
| --- | --- | --- | --- | --- |
| 1 | 0, 2, 3, 5, 8, 9, 11, 12, 15, 17, 18 | the ten from its join | all eleven | those ten |
| 2 | 2, 3, 5, 8, 9, 11, 12, 15, 17, 18 | all ten | all ten | nine: all but 5 |
| 3 | 2, 3, 5, 8, 11, 12, 15, 17, 18 | all nine | all nine | those nine |
| 4 (debug) | 2, 3, 5, 8, 9, 11, 12, 15, 17, 18 | all ten | all ten | those ten |

- **Criterion 1 holds** in every replicate, and **criterion 3 reads `moq-dev`'s subscriber, 3 of 3**: imquic's relay stores every final object and forwards it to both subscribers. Replicate 2's group 5 is a different loss: M lacks it from object 6 on, which the export dropped late at its release deadline (its seven deadline drops).
- **The trigger is imquic's, and it is a stream split.** In every group M lost from I's join on, the relay ended the subgroup's stream after object 49 and sent object 50 on a second stream of the same subgroup whose header sets FIRST_OBJECT; M logged each such stream as `no fill to stitch a mid-group stream onto` and dropped it. The publisher served each of the twenty groups once, on one stream (fourth replicate, `serving group`), so the relay made the split. imquic's source shows why: its subgroup parser marks every object parsed from the chunk that carries the stream's FIN as the stream's end, so when objects 49 and 50 arrive in one chunk the relay closes its stream on 49 and opens a new one for 50, copying the upstream header's FIRST_OBJECT. No group whose final object is large (1,696 or 1,884 bytes) or whose FIN came on its own was split, and whether a small final is split varies from run to run (groups 5 and 9).
- **Before and after a one-line patch (criteria fixed before the first run).** The patch marks an object as the stream's end only if it also empties the chunk carrying the FIN. The same rig, three replicates each, against imquic's relay at `7b19884` run on the laptop on loopback (`IP=127.0.0.1`, its certificate issued by a local CA), unpatched and then patched; in each arm the relay and `imquic-moq-sub` load the same library. **Valid:** unpatched, M lacks at least one final object with a stitch warning in two of three replicates; otherwise loopback does not reproduce the split and the comparison is void. **Pass:** patched, no replicate has a stitch warning or a group I received on two streams, and every final object M lacks is a logged deadline drop. **Valid, and passed.** Unpatched, every replicate splits groups 2, 3, 5, 8, 9, 11, 12, 15, 17 and 18: M lacks each one's final object with a stitch warning, and I receives each on two streams. Patched, no replicate splits a group or logs a stitch warning, and M lacks no final object. Neither arm logged a deadline drop. The parser makes the split, and the one line removes it.
- **The maintainer's fix (criteria fixed before the first run).** It sets a stream's end only on the object that empties the chunk carrying the FIN, in the subgroup and the FETCH parsers both. The same loopback rig, three replicates per arm, unpatched (`7b19884`) and then at the fix (`55fec0e`, whose one later commit touches only the interop demo), relay and `imquic-moq-sub` each loading their own arm's library. **Valid** as for the patch. **Pass:** the patched arm's criterion, and the fix's complement: every group I receives from its join to group 18 ends its stream, and F holds the final object of each of groups 0–18. Three replicates against imquic's public relay are informative only, since which build it runs is not known. **Valid, and passed but for one exception the control shares.** Unpatched, every replicate split groups 2, 3, 5, 8, 9, 11, 12, 15, 17 and 18, each with a stitch warning at M. At the fix, no replicate split a group or logged a stitch warning, M lacked no final object, none was dropped at a deadline, and F held every final object. Every group after I's join ended its stream (17 stream ends a replicate, against the unpatched relay's 27, the ten more being the splits). The group I joined mid-way, at object 44 or 47 (twice unpatched, once at the fix), never ended its stream in either build; a join at a group's first object did. That exception predates the fix. The public relay, with the fixed subscriber, still split 10–11 groups in 3 of 3, so it does not yet run the fix.
- **Not settled here:** whether `moq-dev` should accept the second stream. Its first stream had already ended the group, and the second claims the subgroup's first object at ID 50, so it holds no consistent place to put it; a parked tail also waits on the subscription's unrelated join fill until the session ends, which its code says should cost only the group the fill heads.

### A CDN-hosted moqx deployment, both lanes

A private moqx endpoint run by a CDN, offered for draft 16 and 18 over WebTransport or raw QUIC. `moq-dev` at `3abf0161`, and again at `f13283b30`, at both ends from a home line, the synthetic fixture paced by `tsp regulate`, one subscriber up before the publisher; raw QUIC on draft 18 and WebTransport on draft 16, each with the passthrough lane (`import`/`export ts --passthrough`) and the demultiplexed one (`export ts --delay 1s`). Anonymous publish is accepted under one prefix.

- **Passthrough: intact from the first random access point after the join.** From fixture packet 2,395 to the end the capture is the fixture's bytes (`check-ts.py --suffix`); continuity 0, PCR intervals at most 21.06 ms, 2 Mb/s, no T-STD overflow. Group 0 never arrives (below).
- **Demultiplexed: media intact, the SDT lost.** 450 of the fixture's 500 video frames, the first at its third group; every non-key frame byte-identical, and every audio frame from fixture frame 95 on; PCR intervals at most 25.57 ms, continuity 0, no T-STD overflow or video underflow. Each keyframe differs from its source in one start code (the IDR slice's, four bytes for three) and, at `3abf0161`, in NAL order (the AUD after the SPS and PPS, fixed by #6001), as it does through a local `moq-relay`, so that is the export's. **The output carries no SDT** (below). Through the local `moq-relay`, which delivers the current group whole, the SDT arrives and video starts a group earlier.

Both transports and both drafts give the same results, on both builds; at `f13283b30` the demultiplexed video started one group later still (425 frames), unattributed. **Why, from trace-level reruns on draft 18:** `moq-net` subscribes from the next object and, since each SUBSCRIBE_OK reports a largest object, sends a relative joining FETCH (offset 0) for the current group on every track. None reaches the publisher, which logs every SUBSCRIBE and no FETCH, and no object comes back, though the relay holds the group: it has already opened the group's stream on the subscription. So a group in progress loses its head: `moq-net` drops the tail it does receive, and the SI track's one object, which is that head, never arrives. Two intermittent failures deliver nothing, each the relay's answer to a legitimate request:

- _Code 0xFFFFFFFF_ (one of the two first raw-QUIC runs, two of three trace reruns on `3abf0161`; none of six later trace reruns on it, nor seven runs at `f13283b30`). When the catalog request races its subscription, `moq-net` learns the track by TRACK_STATUS; the relay refuses it with 0xFFFFFFFF, a code no draft defines, and `moq-net`, which then fell back to SUBSCRIBE only on NOT_SUPPORTED, gives the catalog up. At `f13283b30` a subscription no longer sends TRACK_STATUS (#5991).
- _Code 0_ (one passthrough rerun). Joined at object 1 of group 0, `moq-net` resets the headless tail's stream; the relay then ends the subscription with PUBLISH_DONE, status 0, "Write after stream complete or reset": openmoq/moqx#817's removal on a peer's STOP_SENDING, which its open fix (openmoq/moxygen#533) covers.

### The first sweep, with `moq` 0.9.8

The client's first sweep carried media through `moq-dev`'s relays alone and through none of eight others. The main cause was the publisher's: it withheld `PUBLISH_NAMESPACE` until a peer sent it a `SUBSCRIBE_NAMESPACE`, which only `moq-dev`'s relay does. Proactive announcement is a MAY in the drafts, so it was reported as an interop hazard rather than a bug, and it is fixed upstream. Behind it, moxygen then rejected the subscriber's empty-prefix `SUBSCRIBE_NAMESPACE` (error 16, confirmed by a same-relay version A/B), a draft inconsistency the working group resolved in favour of the empty tuple. moqtail refused SETUP, and quiche-moq and libquicr never established a session; at `main` those three resolve as above.

### A 200 ms QUIC/WebSocket race

The client still starts a WebSocket attempt 200 ms after dialling QUIC (`QUIC not yet connected, attempting WebSocket fallback delay_ms=200`, in the probe's logs at `main` too). Wherever QUIC answered on the probe's paths it won, but a fixed 200 ms timer will tend to choose WebSocket for any relay more than about 100 ms away: a confound for interop measurement, since the transport under test is not the one named, and a concern for broadcast carriage, since WebSocket means TCP and head-of-line blocking.

## The same question, asked of segmented HTTP — every third party carries it

The MoQ table above is the interesting half of a comparison only if the other half is measured, and the fair way to measure it is with the same fixture, the same oracle and third-party software at each of the three places the MoQ arm hit a wall: the intermediary that has to forward the media, the client that has to read it, and the judge that decides whether it conformed. [`t11-segmented.sh`](scripts/t11-segmented.sh) does that. The fixture is packaged to a complete playlist so every client has the whole 20 s available and the comparison against source is exact.

| Third party | Role | Result |
| --- | --- | --- |
| TSDuck `tsp -I hls` | control — the toolkit that wrote the segments | **pass**, 4,750,948 B |
| **FFmpeg** | independent HLS implementation | **pass**, remuxed to 4,123,592 B |
| **VLC** | a third independent implementation | **pass**, remuxed to 4,143,144 B |
| **`curl` in a `while` loop** | no HLS implementation at all | **pass**, byte-identical to the served segments |
| **nginx `proxy_cache`** | an intermediary we did not write | **pass** — and see below |
| **Apple `mediastreamvalidator`** | the reference conformance judge | **pass** — 9/9 segments, **0 errors, 0 warnings**, 0 parse errors, 0 load failures |

**Six third parties, six passes; two of nine third-party MoQ relays pass both cases.** Every capture cleared the same twelve hard checks the MoQ arm clears — continuity, sync, TEI, PAT, PMT, service count and stream inventory all matching the source.

Three of those rows carry more weight than the raw count.

**The cache row is the one that matters architecturally**, because it is the segmented lane's answer to the relays that lose or never start our media. An off-the-shelf nginx in front of the origin, configured with nothing but `proxy_cache`, forwarded the stream intact — and **two client passes cost the origin nine segment fetches, not eighteen**: nine misses and nine hits, the second client served entirely from cache. That is the CDN scaling argument reduced to a measurement rather than an assertion, and it took one `proxy_cache` directive against a MoQ fan-out story that requires a relay implementing the protocol.

**The `curl` row is the floor of the interoperability claim.** A shell loop that reads the playlist, fetches each URL in order and concatenates the bodies recovers the media exactly — it is byte-identical to what the origin served. There is no HLS implementation in that arm at all. The client requirement for this lane really is "an HTTP client", which is the thing the lane is always claimed to have and this is what claiming it costs.

**And the judge is not ours.** `validate-ts.sh` grading our own output is worth something, but Apple's `mediastreamvalidator` is the reference implementation of the specification with no stake in the result, and it reported zero errors and zero warnings while processing 100 % of the segments and correctly identifying `avc1` and `aac`. The MoQ arm has no counterpart to this, because MoQ has no reference conformance tool — which is itself a difference in the maturity of the two ecosystems rather than of the two protocols.

### But the packager is not transparent, and that was assumed rather than checked

The one thing this arm does **not** establish is byte-transparency, and looking for it turned up a defect. Concatenating the served segments and comparing against the fixture:

|  | Source fixture | Served segments |
| --- | --: | --: |
| Packets | 26,612 | 25,271 |
| Video PID 256 / audio 257 / nulls 8191 | 21,236 / 1,878 / 3,039 | 20,143 / 1,798 / 2,880 |
| Playlist duration | 20.0 s | 19.004 s |

**`tsp -O hls` dropped the last 1,340 packets — 5.0 % of the fixture, the final second of media — and declared the playlist complete with `#EXT-X-ENDLIST` while doing so.** The loss is at the tail, where the input ended between intra frames, so it is a finite-input behaviour and a live feed has no tail to lose; every other segmented arm in this campaign is unaffected. It is still a silent, unreported truncation of content the packager was given, and any use of this toolchain for file-based packaging would inherit it.

The bytes also differ from the third packet onward, because the packager aligns the first segment to an intra frame and re-emits PSI rather than copying the input. **Every PID's count is scaled by the same ~0.948, so nothing is being selectively stripped** — the content is all there, in proportion, which is why the oracle passes — but the segmented lane as packaged by TSDuck is a _media-aware_ lane, not an opaque one. That correction matters beyond this file: the intuition that segment fetching is byte-verbatim carriage is wrong at the packager, even though it is right on the wire, where every byte the packager emits is delivered unaltered (the `curl` and `tsp` arms agree to the byte).

### Why this matters beyond our own question

The runner's interop matrix is control-plane only. Against imquic, red5, aiomoqt, moqtail and Nokia, every control-plane cell this sweep exercised succeeds while media is lost or a late subscriber never starts. **That gap is invisible in the current matrix**, and it is the strongest argument for the media-level profile proposed in #32.

## T11b — OpenMOQ's MSFTS publisher through a `moq-dev` relay

The question is whether an outside implementation's opaque TS crosses a `moq-dev` relay intact. `moqxr` has no subscriber, so a `moq-dev` broadcast into an OpenMOQ receiver is T11c's, on moq5.

**What was run.**

- **Publisher:** the headless `examples/msfts-publisher` in [`moqxr`](https://github.com/openmoq/moqxr) 0.4.4. The plan named `moq2ts`, which then had no headless mode (T11d runs the one it has since gained); the example is the same project's headless MSFTS publisher, on the MSFTS -01 catalog field names. It keeps the selected programme's PIDs and the nulls and drops NIT, SDT and TDT. It rewrites the PAT and the PAT/PMT continuity counters and inserts PAT and PMT copies periodically. It puts every object in group 0, one every 10 ms, and publishes only while subscribed.
- **Relay:** `moq-relay` from `moq-dev` main at `00e24446f`, local, GSO off, anonymous grant ([`t11b-relay.toml`](scripts/t11b-relay.toml)).
- **Subscriber:** [`t11b-rawsub.rs`](scripts/t11b-rawsub.rs), a `moq-net` client that holds one SUBSCRIBE and writes each object's payload in arrival order. `moq fetch` cannot stand in for it, because the relay forwards the FETCH to this publisher, which answers _unsupported_.
- **Clip:** the first 15 s (99,000 packets) of the news channel's capture. It is a single programme at 9.93 Mb/s: PMT 100, PCR and video on 111, six other elementary streams and 4,525 nulls.
- **Oracle:** [`t11b-grade.py`](scripts/t11b-grade.py) per PID, plus TSDuck continuity.
- **Measurement:** P1, co-resident on loopback, source file against received file. Rigs: [`t11b-arm.sh`](scripts/t11b-arm.sh) and [`t11b-rejoin.sh`](scripts/t11b-rejoin.sh).

"Patched" below means one line added to the example (defect A). Rows marked _as released_ ran without it.

| Arm | Draft and transport | Subscriber | Result |
| --- | --- | --- | --- |
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

**A. Every object claims to close its subgroup.** The publisher library's object type defaults `final_in_subgroup` to true, and the example sets group 0 on every object without overriding it. The session therefore FINs subgroup 0 after object 0 and silently skips every later object in the same group, because its subgroup is closed. The publisher reports _"Published 1 objects"_ and exits 0. The relay and subscriber both behave correctly: one stream arrives, carries one object and ends. Setting `final_in_subgroup = false` on the media objects is the fix used in every patched arm. This is a defect in the example, not the library.

**B. The draft-18 publisher never releases a cancelled subscription.** The set of established subscriptions it checks before admitting a SUBSCRIBE is inserted into and never erased, in all three of its publish paths. Draft 18 allows a publisher at most one subscription per track and DUPLICATE_SUBSCRIPTION only against an existing one. It also lets the publisher destroy subscription state as soon as it receives STOP_SENDING (§5.1.1). Draft 18 has no UNSUBSCRIBE: a subscriber cancels by terminating the request stream. `moq-relay` triggers the defect on every moq-lite subscriber. It answers the subscriber's track-info probe by subscribing upstream, cancelling as soon as SUBSCRIBE_OK arrives, and then subscribing again for the real request about 0.5 ms later.

At 0.5 ms the refusal could be a cross-stream race, since QUIC orders nothing across streams. The rejoin arm rules that out. The relay cancelled its upstream subscription when the first subscriber's session timed out, the second subscriber arrived 5.07 s later, and the publisher refused the relay's new SUBSCRIBE twice with the same error.

**C. One group for the life of the stream.** `moq-net` caps a group at 8,192 frames and at 32 MiB (`MAX_GROUP_FRAMES`, `MAX_CACHE_BYTES`), and aborts it as too large past either.

- At 66 packets per object and 9.93 Mb/s, the byte cap binds first. It cut the stream at 27.0 s, with 33,571,912 bytes published against a cap of 33,554,432.
- At the example's default of 7 packets per object, the frame cap binds first. A subscriber received exactly 8,192 objects and then lost the track.

MSFTS -02 says _"A Group SHOULD NOT last longer than 2 seconds"_, and the example predates -02. A bounded group is `moq-dev`'s model rather than a defect, so this is a publisher-side incompatibility. It also sets the join behaviour. A subscriber attaching 7 s into the stream received the group's whole cached history, 832 objects in its first second, before reaching the live edge.

**D. Drafts 14 to 17 fail on the relay's SUBSCRIBE_NAMESPACE.** `moq-relay` sends SUBSCRIBE_NAMESPACE on the empty prefix to every session, publishers included (see _Root cause_ above). Only on draft 18, where the message became 0x50, does the publisher handle it.

- **Draft 17:** the publisher's request-stream dispatcher treats 0x11 as unknown while request streams are in use. It answers _"unsupported request stream"_ and closes the session as a protocol violation. Draft 17 defines 0x11 as SUBSCRIBE_NAMESPACE on a request stream, and `moq-net` encodes it as such.
- **Draft 16:** the trace fits a publisher that does not count the relay's request 1 (the SUBSCRIBE_NAMESPACE) in its request-ID sequence, so the SUBSCRIBE that follows as request 3 is out of sequence. This rests on the message trace, not on a reading of the publisher's code.
- **Draft 14:** the failure follows the same two requests but has not been isolated.

**E. WebTransport.** WebTransport over HTTP/3 (`draft-ietf-webtrans-http3-16` §3.1) requires a server to send an empty `reset_stream_at` transport parameter. `moq-relay` does not, and the publisher enforces the requirement. This is a `moq-dev` gap, and `moq-dev` already plans the fix in its own reliable-reset quest. Browsers connect to `moq-relay` today, so the gap shows only against a client that enforces the parameter.

**What this establishes.** When the publisher behaves, an outside implementation's opaque TS crosses a `moq-dev` relay unaltered on every elementary-stream PID. That is measured on one combination only: draft 18, raw QUIC, an IETF subscriber, a one-line publisher fix and a stream under 27 s at this bitrate. As released, the publisher delivered at most one object on the three combinations tried: draft 18 to an IETF and to a moq-lite subscriber, and draft 14. All of A to D are on the publisher side, and the relay contributed no defect to the passing arm. The result is one relay against one outside publisher, co-resident and from file. It is evidence for the neutral-fabric assumption at the byte level, not for interoperability as deployed. T11d ran the MSFTS -02 publisher in `moq2ts` against the same relay on draft 22, where it does not get as far as the data path.

## T11c — moq5 against `moq-dev`, both ways (criteria fixed before the first run)

OpenMOQ's [moq5](https://github.com/openmoq/moq5) has a sender, a receiver and a relay, so it closes what `moqxr` left open, and claims no cross-implementation result of its own. Four directions, each on every draft both builds speak (16, 18, 22; raw QUIC):

| # | Publisher | Relay | Subscriber | Tests |
| --- | --- | --- | --- | --- |
| 1 | `moq import ts`, `--passthrough` and demultiplexed | `moq5-relay` | `moq export ts` | relay portability, theirs |
| 2 | moq5 sender (MSFTS) | `moq-relay` | moq5 receiver | relay portability, ours |
| 3 | `moq import ts`, both modes | `moq-relay` | moq5 receiver | catalog, ours to theirs |
| 4 | moq5 sender | `moq-relay` | `moq export ts` | catalog, theirs to ours |

**An arm passes** when, held for at least 120 s at the clip's rate (four times T11b's 27 s ceiling) with no session or group abort:

1. the subscriber finds the TS track through the publisher's own catalog, with no track name or packaging given out of band (a failure records the field it lacked);
2. a passthrough arm delivers the source's packet sequence on every elementary-stream PID (`t11b-grade.py`, PSI continuity masked), and a demultiplexed arm passes the campaign's content grader per PID;
3. TSDuck reports zero continuity errors;
4. the negotiated draft and ALPN, and both builds' commits, are recorded.

Measurement P1: co-resident on loopback, from file, paced by PCR. **Predicted:** directions 1 and 2 pass on bytes; 3 and 4 fail at discovery (MSF `mpeg2ts` packaging against the hang catalog's `m2ts` section).

**Results: directions 1 and 2 pass, passthrough 1 on draft 22 only from moq5 `main`; 3 and 4 fail at discovery, as predicted.** `moq-dev` `3c0daa21b` against moq5 `0729c49` (`moq5-relay` on MsQuic), raw QUIC, where the ALPN (`moqt-16`, `moqt-18`, `moqt-22`) is the negotiated draft and both sides logged the one offered. moq5's side is the harness [`t11c-moq5-ts.c`](scripts/t11c-moq5-ts.c) on its service tier; rigs [`t11c-d1.sh`](scripts/t11c-d1.sh) and [`t11c-arm.sh`](scripts/t11c-arm.sh); a 120 s clip at 9.9 Mb/s. The harness's own loop through `moq5-relay` delivers every PID byte-exact.

| # | 16 | 18 | 22 | Where it stops |
| --- | --- | --- | --- | --- |
| 1, passthrough | pass | pass | pass from moq5 `main` | on `0729c49`, draft 22's catalog join, in `moq5-relay` |
| 1, demultiplexed | pass | pass | pass | — |
| 2 | pass | pass | pass | — |
| 3 | fail | fail | fail | discovery: no track moq5 can deliver |
| 4 | fail | fail | fail | discovery: `moq-dev` reads no `mpeg2ts` packaging |

- **Direction 1, passthrough, passes with the passthrough lane's own subscriber** (see Corrections). With `export ts --passthrough`, the arm is the source's packets on every PID with no continuity error on drafts 16, 18 and 22 against moq5 `main` (`56dd342`), and on draft 16 against `0729c49`. On draft 22 `0729c49` delivered nothing: the export joins at the current group, a Next Object filter with a fill from StartGroup 1 (§3.5), and `moq5-relay` served fills only from what it had retained, which never held the catalog's one group; draft 22's relay "retrieves any missing objects upstream". That half of [openmoq/moq5#51](https://github.com/openmoq/moq5/issues/51) was the relay's, and `main` fixes it.
- **Direction 1, demultiplexed, passes on all three drafts:** the export has the catalog within 4 ms of subscribing and subscribes to every track, with no continuity error and, on the content grader ([`t28-content-lost.py`](scripts/t28-content-lost.py)), no video or audio lost or repeated. On each draft the requests are the passthrough arm's, and `moq-dev` serves group 2 on the relay's subscription the same way in both modes. What in the two catalogs decides whether `moq5-relay` delivers one is not located.
- **Direction 2 passes on all three drafts:** 144,753,420 bytes, every elementary-stream PID a contiguous byte-exact suffix of the source from the join at group 2, no continuity error, and no gap in the receiver's own loss report across 100 groups. That holds with the sender dropping media written before any subscriber, as a live source does. Under moq5's default, which queues that media until demand appears, the receiver got group 0 only to object 36 and then group 1 with the rest of group 0 reported lost: seven continuity errors on draft 18. Which side drops the tail is not established.
- **Directions 3 and 4: each side's TS track is invisible to the other's catalog parser.** `moq-dev`'s MSF catalog lists only video, audio and text renditions, so for a passthrough import it is empty, the track named only in the hang catalog's `m2ts` member, and moq5 enumerates no track. That is upstream's TS draft as written: its frames carry timestamps, so an MSFTS subscriber needs a converter that republishes them. Demultiplexed, it lists `0.avc3` and `6.mp2` as `legacy` packaging, which moq5 does not parse, so moq5 subscribes to neither. The other way, `moq export ts` reads moq5's catalog only under a `.msf` broadcast name (otherwise `catalog.json` is refused _not found_), then skips the track with a warning: its MSF parser has no `mpeg2ts` packaging. The export then waits on the catalog until the broadcast ends, about 2 minutes later, and exits 1 on the relay's PUBLISH_DONE, with no error naming the missing track.

## T11d — `moq2ts` headless, publisher and receiver (criteria fixed before the first run)

`moq2ts` now ships a headless MSFTS -02 publisher (`moq2ts-cli`, on `moqxr`) and a console receiver (`moq2ts-receiver`, on moq5's service tier, draft 22 only), so T11b's arm can run against the project's own publisher, and a second MSFTS subscriber joins T11c's. Raw QUIC, draft 22, loopback, the same 120 s clip at 9.9 Mb/s, the publisher in `--unmodified --paced` mode (every source packet forwarded unchanged, paced at media rate):

| # | Publisher | Relay | Subscriber | Tests |
| --- | --- | --- | --- | --- |
| A | `moq2ts-cli` | `moq-relay` | `moq2ts-receiver` | our relay carries their TS, both ends theirs |
| B | `moq2ts-cli` | `moq5-relay` | `moq2ts-receiver` | the same on their relay (control) |
| C | `moq import ts`, both modes | `moq-relay` | `moq2ts-receiver` | catalog, ours to theirs |
| D | `moq2ts-cli` | `moq-relay` | `moq export ts` | catalog, theirs to ours |

**An arm passes** when, over the whole clip with no session or group abort: (1) the subscriber finds the TS track through the publisher's catalog, with nothing given out of band; (2) the capture is the source's own bytes from the join, every PID ([`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py): nothing foreign, no gap); (3) TSDuck reports zero continuity errors; (4) the PCR value checks ([`ts-pcr-timing.py`](scripts/ts-pcr-timing.py)) give the source's verdict. The receiver writes objects as they arrive, so its release timing is reported, not graded: a receiver that does not pace needs a pacer before an IRD. **Predicted:** A and B pass; C and D fail at discovery, as T11c's directions 3 and 4 did, since neither side's catalog parser reads the other's TS track.

**What was run.** `moq-dev` at `3c0daa21` (relay and CLI), `moq2ts` 1.0.4 on `moqxr` 0.4.4, and the msquic build of `moq5-relay`; the 120 s clip (793,000 packets, 9.95 Mb/s); loopback on one host, source file against received file (P1). Rig: [`t11d-arm.sh`](scripts/t11d-arm.sh).

| Arm | Result |
| --- | --- |
| A | **Fails at the first SUBSCRIBE.** The relay subscribes upstream for the receiver's catalog; `moqxr` answers REQUEST_ERROR code 1, "invalid SUBSCRIBE", and closes the session. Nothing is delivered |
| B | **The source byte for byte, then its last group again.** All 793,000 packets arrive in order from packet 0, nulls included, followed by the final group's 6,172 packets (0.93 s) a second time. On the first 793,000 packets every check gives the source's verdict; the repeat accounts for all six continuity errors and the one non-positive PCR interval, so criteria 2 to 4 fail as written |
| C, both modes | **Fails at discovery**, as predicted: "catalog has 0 matching TS tracks". Naming the track (`--track 0.m2ts`) does not get round it, because the receiver chooses only among catalog tracks with MSF `mpeg2ts` packaging |
| D | **Fails at the first SUBSCRIBE**, as A does. `moq export ts` prints "unauthorized", which is how `moq-net` names REQUEST_ERROR code 1 |

**Why A and D fail: one draft-22 ambiguity, not a carriage defect.** The relay's upstream SUBSCRIBE carries FILL_PARAMETERS (0x23) holding a Location Filter: draft 22's current-group join. Draft 22 length-prefixes the value and calls it "a sequence of Parameters … encoded as if they were Parameters for a separate message". `moq-net` writes a parameter count first, as a message does. `moqxr`'s decoder reads parameters straight away, takes the count as parameter type 0x01 and rejects the message. [moq-wg/moq-transport#1991](https://github.com/moq-wg/moq-transport/issues/1991) records the same split (moq-net and Meta send the count, moqtail does not), and the merged [#2015](https://github.com/moq-wg/moq-transport/pull/2015) settles it as a count with no length prefix, which both sides would have to adopt. The locus rests on the relay's trace of the SUBSCRIBE's fields and on the decoder's code; the bytes were not captured.

**Two publisher behaviours the arms had to work around.** `--paced` releases one object per `--fragment-ms` whatever it holds, so at the default 64 KiB every 250 ms it sends 2.09 Mb/s whatever the source rate. The arms set `--segment-bytes 310764`, 250 ms of this clip. A first arm B without it had to be stopped, and the publisher then aborted in shutdown ("double free or corruption") after a 10 s close-drain timeout. The receiver writes each 250 ms object as it lands: 91.5 % of PCRs are released more than 10 ms early (p95 216 ms), reported and not graded.

**What this establishes.** `moq2ts`'s publisher and receiver carry a transport stream byte-exact over OpenMOQ's relay, apart from a repeated final group, which is the receiver's: on `a734a91` with moqxr v0.4.8 the publisher sends each object once, and the final group repeats at both object sizes with the receiver built on moq5 `main` and at neither with openmoq/moq5#54. There 10 of 10 interrupts without a subscriber exit cleanly, which on `4717ce3` aborted. Against `moq-dev` they interoperate in neither direction on draft 22. The FILL_PARAMETERS split closes the data path before any TS object reaches `moq-relay`, and the two TS descriptions (MSF `mpeg2ts` and `moq-dev`'s `m2ts`) close discovery. So T11d says nothing yet about `moq-relay` carrying their TS; arm A reruns once either side adopts #2015's framing.

## Corrections

> **T11c's passthrough arm ran the wrong subscriber.** Believed: `moq5-relay` never delivered a passthrough import's catalog on drafts 16, 18 and 22, reported as openmoq/moq5#51. True: the subscriber was the demultiplexing `export ts`, which delivers nothing for a passthrough import through `moq-dev`'s own relay either (draft 16, 0 bytes); with `export ts --passthrough` drafts 16 and 18 pass, and only draft 22's failure was the relay's, fixed on moq5 `main` (§ T11c). Rule: [method-notes](method-notes.md) §1, run the control before believing a striking result.

## Next steps

- Report the packager's silent 5 % tail truncation on a finite input to TSDuck. It needs a minimal reproducer first — the input ending between intra frames is the suspected trigger, and that should be confirmed against a clip whose final GOP is complete before anything is filed.
- Raise the 200 ms QUIC→WebSocket fallback timer separately.
- The late subscriber aiomoqt, moqtail and Nokia never start waits on their adopting moq-transport#2015's framing.
- The two TS cases, fixture and checker are proposed to the runner as [englishm/moq-interop-runner#159](https://github.com/englishm/moq-interop-runner/pull/159); once it merges, [`interop/`](interop/README.md) retires and this file's method cites the runner.
- Rerun T11d arm A once `moqxr` or `moq-net` adopts moq-transport#2015's FILL_PARAMETERS framing.

What this experiment reported upstream, and each report's state, is in the [upstream ledger](upstream-contributions.md).
