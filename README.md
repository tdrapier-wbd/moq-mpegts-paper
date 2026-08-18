# Internet-Native Primary Distribution for Professional Broadcast
MPEG-TS over MoQ and over segmented HTTP, evaluated together

**A technical evaluation of Internet-native primary distribution for professional broadcast, on the two data planes that can carry it: Media over QUIC, and segmented HTTP carrying MPEG-TS.**

Status: working draft. This paper is deliberately critical: the goal is to find the fastest way to *disprove* the thesis, not to sell it. AI assistance was used in drafting.

> **In one line.** Broadcast's trunk layer is being pushed off satellite and managed fibre onto the public internet. This paper asks what an Internet-native replacement has to do, and which data plane can do it: **Media over QUIC (MoQ)**, a live-media transport being standardised in the IETF, or **segmented HTTP carrying MPEG-TS** (HLS with TS segments, over HTTP/3), which is already specified, interoperable and sold over commodity delivery. Most of the answer turns out not to be about the transport at all.

**Why two data planes and not one.** The obvious comparison for a new live transport is against the point-to-point incumbents — SRT, Zixi, RIST — and it is the wrong one to lead with, because it flatters anything that can fan out at all. The demanding comparison is against segmented HTTP carrying MPEG-TS, which is already specified, universally interoperable and sold over commodity delivery, and which on most axes an operator decides on is **ahead of MoQ today** ([Alternatives](docs/alternatives.md)). Hence the shape of this paper: two candidate data planes, one shared broadcast-grade layer above them, and a conclusion about that layer rather than about a protocol.

---

## What this paper is — and is not

**It is:**
- A technical argument that the pressures reshaping broadcast (cloud-native plants, API-driven operations, shrinking linear revenue, global/dynamic rights) are pushing primary distribution toward an Internet-native model.
- A head-to-head evaluation of the two data planes that can serve that model, on scaling, reliability, hand-off complexity, interoperability, latency, entitlement, carriage fidelity, economics and maturity ([Alternatives](docs/alternatives.md)).
- A reference architecture for a broadcast-grade distribution platform — the unglamorous interop, grooming, entitlement, redundancy and observability layers above the transport, nearly all of which is common to both data planes. It is written against MoQ because that is what the prototype runs on, and the parts that are transport-specific are marked as such.
- Explicit about what remains unproven, and about where MoQ's advantage over existing IP transports and over segmented HTTP is narrow.

**It is not:**
- A claim that MoQ beats segmented HTTP. On current evidence it does not, except on latency, on how easily its egress can be groomed into a clean hand-off, and on wire volume by ~7 % ([Alternatives](docs/alternatives.md) §12).
- A claim that MoQ is production-ready today. The wire protocol is pre-standard and unstable (see [Transport](docs/transport.md)).
- A claim that Internet-native distribution is *already* economically superior to a depreciated satellite transponder or an existing IP contract. The always-on case is modelled numerically, and the headline is that **cost is decided by commercial terms rather than by transport engineering**: which market delivery is bought in moves the bill by an order of magnitude, the choice of transport by a few percent ([Economics](docs/economics.md) §4).

  It is modelled on **public list prices** by necessity rather than oversight. Real negotiated rates and depreciated route costs are commercially sensitive and cannot be published, and they sit below list on *both* sides of the comparison. The IP-side figures here are therefore an *upper* bound, and the comparison is stated as a **parity threshold** an operator substitutes its own incumbent cost into privately — a method, not a verdict on anyone's economics ([Contributing](CONTRIBUTING.md)).
- A product pitch or a business plan.

---

## Bottom line up front

**The transport is not the decision.** Both candidate data planes ride QUIC, both need the same grooming layer before a hardware IRD will lock to them, both are unicast at the last mile, and they land within 7 % of the same wire volume. Segmented HTTP is ahead today where it counts commercially — universally interoperable, sells over commodity delivery now, the more robust recovery model, and an off-the-shelf path back to a transport stream where MoQ has one implementation. It is also, measured, byte-verbatim for a single programme — so the fidelity advantage usually assumed for MoQ survives only on a multi-programme mux. What MoQ has is latency, and one asymmetry that is easy to underweight until it is measured: **its egress is two orders of magnitude easier to pace.** At 2 s segments the alternative bursts at ~2.95 MB against MoQ's 12.4 kB and stops for over a second 24 times a minute, where MoQ never stops for more than 149 ms ([Evidence](docs/evidence.md) §10) — and because burst size *is* segment size, that is the same knob as latency, not a separate one. MoQ also moves ~7 % fewer bytes, though those bytes currently cost five to ten times as much to deliver, so that one is a rounding error against the price. So the decision rule is narrow and testable: **if the destinations can absorb seconds — nearer six of them unless a commercial ABR-to-TS receiver is bought, since partial segments publish free but no free client fetches them — segmented HTTP is the better engineering choice today; if they cannot, MoQ is the only Internet-native candidate with commodity delivery in prospect** ([Alternatives](docs/alternatives.md) §12).

**What that leaves is the layer above the transport, and it is the same layer either way** — IRD-accurate egress and PCR grooming, 1+1 with byte-identical legs and receiver-side selection, entitlement and multi-tenant control, observability in broadcast terms, and interop with the installed base. Neither specification addresses any of it. That is where nearly all the measured work here sits, which is why it transfers between the two data planes, and whether that layer can meet broadcast's trust bar on a best-effort substrate is the real question — still open, and **not yet proven**.

**And that layer does not transfer to the client on either data plane.** A distributor no longer supplies its clients' receiving equipment, so the deliverable is a clean, paced transport stream at a demarcation the distributor owns, and the assumption has to be that many receivers want nothing else. Where a client happens to run a modern software-defined receiver that takes segmented HTTP directly, that is useful optionality on the client's side of the line; it is not something a design can rest on, and there is no equivalent for MoQ. Neither specification says a word about PCR, constant bit rate or stuffing, so the grooming stage is required and owned whichever data plane is chosen ([Alternatives](docs/alternatives.md) §4).

MoQ is a credible **transport foundation**. It is open-source, standards-track, and prototypes show it works: the media-aware lane carries a full contribution mux end-to-end over a public-internet cloud relay with 0 continuity errors, a downstream groomer takes the bursty egress to exact CBR (0 % of PCR intervals > 40 ms where the carrier rate is matched to the content, and no PCR outside TR 101 290's ±500 ns accuracy limit on file), and switching the sender off QUIC's default CUBIC to BBR holds full-rate, byte-complete delivery on par with SRT under loss — though which BBR generation suits a permanent fixed-rate trunk is not yet settled ([Evidence](docs/evidence.md) §1, §3 and §6; campaign record in [lab](lab/README.md)). Everything measured there is evidence about the layer above the transport as much as about MoQ, which is the point.

**Operational maturity is a separate risk from the protocol being pre-standard, and it cuts both ways.** Most of what this evaluation found wanting sits in the implementations and tooling being built alongside the standard rather than in MoQ itself: defaults tuned for demos rather than trunk routes, memory held by the QUIC library beneath the relay, thin observability, and interop conventions the drafts leave open to more than one reading. That is the expected shape of implementations maturing *with* a specification rather than after it, and several gaps recorded here have since closed upstream. The counterweight is that a broadcaster procures an implementation, not a specification — so much of what reads as "MoQ does X" is really "this build does X", and an evaluation of a pre-1.0 ecosystem is tracking a moving target ([Evidence](docs/evidence.md) §1, §8 and §9).

---

## Why a new approach at all

Traditional primary distribution — satellite, leased fibre, MPLS — succeeds by *engineering determinism into a dedicated or managed layer and charging for the guarantee*. That model works and its buyers are structurally conservative. But the plant around it has gone software-defined and API-driven, linear revenue is declining (pressuring the fixed cost of dedicated capacity), rights are increasingly global and dynamic, and the QUIC/HTTP-3 substrate needed for an Internet-native alternative now exists as a commodity. The full argument, with the strongest counter-cases, is in [Vision](docs/vision.md).

## Which data plane, and why the question is narrower than it looks

There are three candidates in two classes. SRT, Zixi and RIST already move a linear feed reliably from A to B — RIST notably well, being the only one of these transports that is both openly specified and demonstrably multi-vendor, and, measured, the shortest worst-case delivery silence of any of them, though not the smallest bursts ([Alternatives](docs/alternatives.md) §10.1). What none of them can do is fan out over a market: replication is a point the operator runs, because a CDN will take SRT at its door as contribution ingest and will not carry it to the destination, so an SRT trunk to N endpoints is priced on own transit, hyperscaler egress, or a managed media service with a 50-output quota ([Economics](docs/economics.md) §4.9). Segmented HTTP already delivers over commodity CDN at seconds of latency, with interop and maturity MoQ does not have, and an off-the-shelf path back to a transport stream. Against that field, MoQ's case reduces to four claims: sub-second capability, verbatim multi-programme carriage, a portable enforcement point with an observable session, and push rather than manifest polling ([Alternatives](docs/alternatives.md)). The architecture underneath them is what distinguishes MoQ, not raw performance:

- **Native relay and 1:N amplification** (the advantage usually cited first, and the weakest of them): a single protocol carries a feed from contribution through a relay fabric that fans out point-to-multipoint, with caching, on the QUIC/HTTP-3 substrate CDNs and hyperscalers already run. The economic value of that fan-out is narrower than it sounds — it removes duplicated backhaul and uplink, not last-mile egress, which stays linear in destinations for every transport including this one ([Economics](docs/economics.md) §4.8).
- **A shape a commodity delivery market can sell** — the strongest economic argument here, and a claim about markets rather than a measurement. A MoQ relay *is* a cache, so relaying maps onto machinery CDNs already run at scale; SRT has no object model or native relay, so fanning it out means a stateful media gateway per stream per destination. That is why no CDN sells SRT relay as a commodity product and one already sells MoQ relay, and why MoQ is the first *sub-second* broadcast-grade transport whose price could follow commodity delivery down rather than sitting at hyperscaler rates ([Economics](docs/economics.md) §4.9). The word sub-second is load-bearing: segmented HTTP already has the commodity delivery market, so this argument is about the latency band it cannot reach, not about delivery economics in general.
- **Subscription-oriented delivery with a native authorization point** at subscription (the platform layers path-scoped tokens, mTLS, and expiry on it). The advantage is *not* revocation speed — segmented HTTP authorizes every request and re-fetches a low-latency playlist each part duration, so its worst case is about one request interval. It is that the enforcement point is a relay you can operate, so the policy is yours and portable, and that a subscription is a live, queryable fact rather than something inferred from delivery logs ([Alternatives](docs/alternatives.md) §7).
- **Per-stream delivery** — a lost packet stalls only its own object, not the whole multiplex — with **graceful multi-rendition degradation** (strongest on the default media-aware lane, constrained on the opaque fallback). Loss resilience itself is a controller choice, not a free protocol property: QUIC's default CUBIC *collapses* under loss, while BBR restores full-rate delivery *on par with* SRT — parity, not superiority ([Transport](docs/transport.md) §3.1, [Evidence](docs/evidence.md) §6).

These matter most at fan-out scale and heterogeneity — precisely where primary distribution is *least* heterogeneous, so the fit must be tested, not assumed. Developed in [Vision](docs/vision.md) and [Transport](docs/transport.md).

## Why this might fail

The strongest reasons the thesis fails, each testable rather than rhetorical:

- **MoQ is squeezed from both sides, and the band where it is the right answer may be too narrow to matter (highest thesis risk).** Against SRT, Zixi and RIST the differentiator is *not* the per-route engineering, and the measurements keep narrowing that ground: MoQ's wire saving is ~5 % and travels with the source's stuffing ratio, so a tightly packed carrier converges it to a ~1.2-point floor and byte-verbatim carriage forgoes it entirely ([Evidence](docs/evidence.md) §8); on hand-off the two split rather than separate, MoQ giving smaller bursts and the tunnels shorter silences ([Evidence](docs/evidence.md) §11). What is left is fan-out — replication over a market instead of a point the operator runs — and it is decisive only once a route has enough destinations to price ([Economics](docs/economics.md) §4.9). Below that, RIST is the better-engineered choice today. Above it, the fan-out argument is one segmented HTTP already satisfies, at commodity delivery prices against MoQ's single supplier at five to ten times the rate. So the thesis does not fail on any one axis; it fails if the range of routes that need internet-scale fan-out *and* cannot tolerate seconds of latency turns out to be a thin slice of real primary distribution. **That is the question the paper is ultimately betting on, and it is not yet answered.**
- **A specified, universally interoperable alternative already carries MPEG-TS (the strongest challenge).** HLS has carried MPEG-TS since 2009, and its current edition folds in low-latency mode over HTTP/2 or HTTP/3 — so it rides the same QUIC substrate. It is explicitly *not* an Internet standard, yet it interoperates across essentially every CDN, packager and analyser, while MoQ, which *is* standards-track, currently carries media only within a single implementation. It is ahead today on interop, delivery economics, maturity and recovery model, it is byte-verbatim for a single programme (measured), and its 2–5 s latency sits inside the tolerance this paper states for most routes — though reaching that band *with* MPEG-TS turns out to be blocked in a specific and awkward place: partial segments carrying MPEG-TS can be **published** free of charge with Apple's macOS-only tools, and no freely available client will **fetch** them, so free software lands nearer 6 s whatever the publisher emits, and the only candidate receiver is commercial ABR-to-TS hardware (measured). What it does *not* do is remove the broadcast-grade edge stage: the obligation to hand a client a clean paced TS is the distributor's on either data plane, and the alternative gives that stage measurably more to absorb ([Evidence](docs/evidence.md) §10). *Test (partly run):* four rows of the head-to-head are measured; the cell that would move the paper most — a commercial ABR-to-TS gateway on real hardware — needs kit this lab does not have ([Alternatives](docs/alternatives.md) §12).
- **Hardware IRDs reject groomed output, on either data plane (potential showstopper).** Bursty delivery yields PCR that hardware IRDs flag on TR 101 290 P1/P2 — inherent to Internet-native carriage, not a bug in any one protocol. Grooming addresses it but must be *proven on real hardware*. *Test (not yet run):* a clean P1/P2 pass on real IRDs ([Evidence](docs/evidence.md), [Architecture](docs/architecture.md) §7.2 and §17). The *requirement* is transport-independent, and so is the ownership of it: no Internet-native transport, MoQ or HTTP-based, delivers IRD-conformant timing without an edge grooming stage; the HLS specification mentions PCR, CBR, stuffing and null packets nowhere at all; and since the distributor no longer supplies its clients' receivers, that stage sits on the distributor's side of the demarcation either way. Off-the-shelf tools fully groom neither, and the residue is now narrow and specific: pacing a constant-rate stream onto the wire has a free answer good enough to beat this project's own tool on cadence, while rewriting a mux to be constant-rate *without* renumbering PIDs or retyping SCTE-35 has none ([lab: T13](lab/test-13-downstream-grooming.md)). Measured, the alternative needs *more* grooming, not less, because segment-granular bursts are ~240× coarser than MoQ's frame-granular ones ([Evidence](docs/evidence.md) §10, [Alternatives](docs/alternatives.md) §4). One stage now covers both, which is the layering claim made concrete rather than argued: the same groomer, sizing its buffer from the arrival it observes rather than from a configured depth, takes either egress to the same conformance with no flag changed — at the cost, on the segmented plane, of seconds of start-up latency and ~9 s to notice a dead source ([lab: T16](lab/test-16-grooming-segmented-http.md)).
- **Relay portability never arrives, which removes the strongest economic argument.** The commodity-relay case assumes a feed can be carried over a relay somebody else operates, and treating relay capacity as a substitutable commodity is what [Economics](docs/economics.md) §4.9 rests on. Measured against all eight other registered public relays, no media arrives at all. Version negotiation is *not* the obstacle — the nearest cause is an announce convention the draft permits either way — but the eight failures have at least four distinct causes, so no single fix restores portability ([Evidence](docs/evidence.md) §9). Until it is demonstrated, single-vendor dependence is the realistic position and "commodity relay" is an aspiration.

---

## The two data planes in broadcast terms

The documents below use both vocabularies. This is the whole of each, in the nearest broadcast equivalent. The two are worth reading side by side, because several rows are the same idea under different names — a **group** and a **segment** are both "the point a receiver can join at", and a **catalog** and a **Media Initialization Section** are both "what PAT/PMT tells you".

### MoQ

| MoQ term | What it means here |
|---|---|
| **Broadcast** | One named feed, roughly a service or channel. Note it does not mean "broadcast" in the RF sense. |
| **Track** | One elementary stream inside that feed: video, an audio pair, or data such as SCTE-35. |
| **Group** | A self-contained run of a track that starts at a keyframe, and the point a new subscriber can join at. The closest analogue is a GOP. |
| **Object** | The individual unit of delivery within a group, roughly a frame's worth of bytes. Loss stalls one object rather than the whole multiplex. |
| **Catalog** | The manifest saying which tracks exist and how they are coded. The closest analogue is PAT/PMT. |
| **Announce** | How a publisher advertises that a feed exists, so relays learn where to route it from. |
| **Origin** (`--origin <id>`) | An identifier by which two publishers declare they carry interchangeable content, i.e. a 1+1 pair. |
| **Route reselect** | A relay switching from a failed publisher to a standby carrying the same feed. |
| **Publisher / subscriber** | The sending and receiving endpoints. In this paper they are `moq import ts` and `moq export ts`, which convert between MPEG-TS and MoQ tracks. |

### Segmented HTTP (HLS carrying MPEG-TS)

Terms are from [HTTP Live Streaming 2nd Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/); the comparison that uses them is [Alternatives](docs/alternatives.md).

| HLS term | What it means here |
|---|---|
| **Media Segment** | A few seconds of one programme as a standalone file. Here it is an MPEG-TS file, and it **must carry exactly one MPEG-2 programme** — the constraint that rules out a contribution mux ([Alternatives](docs/alternatives.md) §6). The nearest MoQ analogue is a group. |
| **Partial Segment** (`EXT-X-PART`) | A fraction of a segment, typically 200–330 ms, published before the segment completes. This is what makes Low-Latency mode low-latency, and it may also be MPEG-TS. The nearest MoQ analogue is an object. |
| **Media Initialization Section** | What a receiver needs before it can decode a segment. For MPEG-TS it is defined as a PAT followed by a PMT, and every segment must carry both. Note what is *not* in it: SDT, NIT, EIT, TDT and TOT appear nowhere in the specification. |
| **Media Playlist** | The list of segments currently available for one rendition, re-fetched continuously. It is the closest thing to a subscription: there is no session, only a receiver repeatedly asking what exists now. |
| **Multivariant Playlist** | The top-level list of renditions and their properties. Loosely a catalog. |
| **Blocking Playlist Reload** | The server holds a playlist request open until the part the receiver asked for exists, instead of answering "nothing new yet". It is how a pull protocol approximates push, and it is why the delivery path must not time out held requests. |
| **`PART-HOLD-BACK`** | How far back from the live edge a receiver must start. At least twice, and preferably three times, the part duration — the structural floor under Low-Latency HLS's latency ([Alternatives](docs/alternatives.md) §5). |
| **Availability Duration** | How long a segment stays fetchable after it leaves the playlist. This is the retry window, and it is what makes recovery a cache problem rather than a session problem ([Alternatives](docs/alternatives.md) §3.2). |
| **`EXT-X-DATERANGE`** | Where SCTE-35 goes: the specification defines an explicit mapping of `splice_info_section()` into a playlist tag, so splice signalling travels out of band rather than depending on an in-band PID surviving transit. |
| **Redundant Variant Stream / Content Steering** | Two disjoint delivery paths for the same feed, and the mechanism by which a receiver moves between them. The specified equivalent of a 1+1 pair with receiver-side selection. |
| **ABR2TS** *(vendor term, not in the specification)* | The stage that turns segments back into a continuous transport stream for the installed base. Professional IRDs and edge gateways list it as an input mode; a distributor may buy such a box as its *own* edge stage, but cannot assume a client's receiver has one, so this does not remove the hand-off obligation ([Alternatives](docs/alternatives.md) §4). |

---

## Repository

**The documents are organised in three layers, because that is the paper's argument.** If the
conclusion is that the data plane is the small part of the problem, the structure should show which
part is which. Every document in `docs/` declares its layer in its header:

| Layer | What it covers | Depends on the data plane? |
|---|---|---|
| **The requirement** | What Internet-native primary distribution has to do, before any transport is chosen. | No |
| **The data plane** | Which transport carries the bytes, and the case for each. | It *is* the choice |
| **Above the transport** | Everything that makes the result broadcast-grade: IRD-accurate egress and PCR grooming, 1+1 redundancy, entitlement, control, observability, interop with the installed base. | **No — required and owned identically on both** |

The third row is the paper's substance and the reason the transport choice does not settle much. Read
[Vision](docs/vision.md) for the *why*, [Alternatives](docs/alternatives.md) for *which data plane*,
[Architecture](docs/architecture.md) for *how the layer above it is engineered*, and
[Implementation](docs/implementation.md) for *what you would assemble, on either*.

### The paper (`docs/`) — the design and the validated findings

| Document | Layer | Description |
|----------|-------|-------------|
| [Vision](docs/vision.md) | Requirement | Why broadcast primary distribution is changing — industry problem, opportunity, and critical analysis. |
| [Alternatives](docs/alternatives.md) | **Data plane** | The head-to-head: MoQ against segmented HTTP carrying MPEG-TS, and against SRT/Zixi/RIST, on scaling, reliability, hand-off complexity, interop, latency, entitlement, fidelity, economics and maturity. |
| [Transport](docs/transport.md) | **Data plane (MoQ)** | The transport requirements primary distribution imposes, how MoQ meets them, MPEG-TS/MSFTS carriage, and draft-stability strategy. |
| [Relay](docs/relay.md) | **Data plane (MoQ)** | MoQ relay fabric, routing, fan-out, federation, and resilience. The segmented-HTTP equivalent is a CDN cache, treated in [Alternatives](docs/alternatives.md) §2. |
| [Architecture](docs/architecture.md) | Above the transport | End-to-end reference architecture for a broadcast-grade platform, worked through on the MoQ data plane; the grooming, redundancy, control and observability layers apply unchanged to segmented HTTP. |
| [Implementation](docs/implementation.md) | Above the transport | What you would assemble and how you would test it, on either data plane — including which toolchain stages are free and which must be bought. |
| [Control Plane](docs/control-plane.md) | Above the transport | Provisioning and orchestration. |
| [Entitlement](docs/entitlement.md) | Above the transport | Dynamic, revocable distribution rights. |
| [Security](docs/security.md) | Above the transport | Identity, authentication, and threat model. |
| [Interoperability](docs/interoperability.md) | Above the transport | IRDs, MPEG-TS, RTP, ST 2022-7, SRT, Zixi — on ingest and egress, for both data planes. |
| [Operations](docs/operations.md) | Above the transport | NOC model, SLOs, monitoring, and runbooks. |
| [Economics](docs/economics.md) | Cross-cutting | Cost framework, and a numeric model of the always-on case at published rates — MoQ against SRT, segmented HTTP, managed services, commodity CDN delivery and satellite. |
| [Evidence](docs/evidence.md) | Cross-cutting | What the working prototype proved — the empirical basis for the claims above, on both data planes. |

### The validation campaign (`lab/`) — what was planned and measured

| Document | Description |
|----------|-------------|
| [Laboratory Notebook](lab/README.md) | The validation campaign — both the *plan* (objectives, acceptance-gate mapping, and the pass criteria agreed before the numbers) and the *executed* work: exact procedures, commands, and **measured results** per test (baseline TS characterisation, transport transparency on both lanes, remote end-to-end over the public internet, impairment and congestion-control behaviour, resilience, resource envelope, and cross-implementation interop). Where a result was later corrected, the per-test file states the current finding and records what the earlier reading got wrong. |

### Code (`interop/`) — what this project contributes back

| Component | Description |
|----------|-------------|
| [Media-level interop test client](interop/README.md) | A test client for the community [MOQ Interop Runner](https://github.com/englishm/moq-interop-runner), carrying an MPEG-TS fixture through a relay and validating what comes out — continuity counters make the fixture check itself, so no decoder or frame capture is needed. Offered in support of [runner #32](https://github.com/englishm/moq-interop-runner/issues/32) as an argument that media-level interop can be tested automatically. |

The CBR grooming component is a separate public crate, [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer).

---

## Contributing and feedback

This is a public, living reference whose purpose is to be tested and challenged.
Corrections, counter-evidence, and disagreement are actively wanted — see
[CONTRIBUTING](CONTRIBUTING.md) for how to raise an issue, start a discussion, or
propose a change, and for the editorial and confidentiality conventions.

---

## Open questions

- **Does the sub-second requirement exist on identifiable routes, or is it a preference?** This is now the question that decides how much of primary distribution MoQ addresses at all, because every other axis on which the two data planes differ currently favours segmented HTTP. ([Alternatives](docs/alternatives.md) §5)
- **Does a commercial ABR-to-TS gateway, run as the distributor's own edge stage, produce TR 101 290 P1/P2-conformant output on real hardware?** The IRD vendors' HLS and DASH inputs are datasheet claims, and the equivalent question is open for this project's own groomer. If yes, part of the broadcast-grade edge layer is purchasable on one data plane and not the other; if no, it is a build on both. ([Alternatives](docs/alternatives.md) §12)
- **Should the edge gateway sit at each client's demarcation or in the distributor's own regional PoPs?** The choice sets how many destinations the Internet-native transport actually serves, and therefore most of the delivery bill, identically on both data planes. ([Alternatives](docs/alternatives.md) §4.5)
- **Can a CDN carry a multi-programme TS segment in practice?** HLS normatively excludes it and a cache does not parse the payload, so MoQ's clearest carriage advantage is either real or merely normative, and nothing has established which. ([Alternatives](docs/alternatives.md) §6)
- Does the parity threshold survive substitution of a real operator's own two numbers? This is the decisive commercial question and it is deliberately *not* answered here: the model is built on public list prices and expressed as a threshold precisely so it can be re-run in private against negotiated and depreciated costs that cannot be published. It is a test only the operator can run. ([Economics](docs/economics.md) §4.7)
- Why does published cloud egress sit roughly an order of magnitude above commodity CDN delivery and above the all-in cost of running delivery yourself, and does anything force that gap to close? The always-on trunk case lives entirely inside that spread. ([Economics](docs/economics.md) §4.2)
- Does groomed MoQ output pass TR 101 290 P1/P2 on real hardware IRDs? ([Evidence](docs/evidence.md))
- How much of the IRD-facing egress layer should be public? The groomer's placement is settled — downstream of the transport, as a public crate — but FEC, ST 2022-7 pairing, start gating and egress TR 101 290 monitoring are not, and publishing them trades differentiation for credibility. ([Implementation](docs/implementation.md) §9)
- What does the opaque lane cost on the wire? It is the lane preferred for hardware IRDs and the only one unmeasured on the line that dominates the cost model — derivation puts verbatim carriage near SRT and null-stripped carriage near the media-aware lane, which is the difference between carriage being a wash and being an advantage. ([Economics](docs/economics.md) §9)
- Which congestion controller suits a permanent fixed-rate trunk? The ranking inverts by regime: the generation that best resists non-congestive loss is not the one that behaves best under a shaped bottleneck, and the provisioned-path conditions that would settle it are unrun, so no single recommendation covers both. ([Evidence](docs/evidence.md) §6)
- Does the relay's per-connection memory ceiling really hold over weeks rather than hours? The plateau is confirmed but soft — still creeping ~8 MB/hour past the knee — and the only lever that binds it works sub-proportionally. ([Evidence](docs/evidence.md) §8)
- Can one leg of a live 1+1 pair be restarted on its own? Only for some receivers. A recovering leg regains its numbering, slots and phase, but not byte-identity, because `moq export ts` renders continuity counters from process state — so an **input-select** receiver is protected again immediately while a **sequence-merge** receiver needs the pair restarted together. That is an upstream fix rather than an edge one ([moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779), [Evidence](docs/evidence.md) §7).
- Can a broadcast feed traverse a relay somebody else operates? Measured today it cannot — carriage works within one implementation and fails against all eight other public relays, which makes "commodity relay" an aspiration rather than a property. ([Evidence](docs/evidence.md) §9, [Interoperability](docs/interoperability.md) §9.6)

---

## Author

**Thomas Drapier**  
Senior Director, Service Management & Partner Services  
Broadcast Distribution Engineering

This repository represents research and engineering work on Internet-native
broadcast primary distribution, evaluating Media over QUIC and segmented HTTP as
candidate data planes for it. Parts of the documents were drafted with AI
assistance and then reviewed (see [CONTRIBUTING](CONTRIBUTING.md)).

LinkedIn: https://www.linkedin.com/in/tdrapier/

---

## References

A comparison of the implementations below — what each covers, where they
interoperate, and where they do not — is in
[Interoperability](docs/interoperability.md) §9.

**Implementations**

- MOQ-dev (media-aware lane; publisher, relay, subscriber): https://github.com/moq-dev/moq
- Cloudflare `moq-rs` (IETF-aligned transport library + production relay, media-agnostic): https://github.com/cloudflare/moq-rs
- Cloudflare MoQ relay service and provisioning API: https://developers.cloudflare.com/moq/
- `moq2ts` (transparent MPEG-TS publisher): https://github.com/mondain/moq2ts
- `moqxr` / OpenMOQ Publisher (the transport SDK beneath it): https://github.com/mondain/moqxr
- MPEG-TS VBR to CBR Pacer: https://github.com/tdrapier-wbd/mpegts-pacer

**Standards and formats**

- IETF MOQ working group: https://datatracker.ietf.org/group/moq/about/
- MOQ Transport working area: https://github.com/moq-wg/moq-transport
- MOQT Streaming Format (MSF), adopted WG draft: https://datatracker.ietf.org/doc/draft-ietf-moq-msf/
- CMSF (CMAF profile of MSF): https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/
- MSFTS (MPEG-TS profile): https://github.com/mondain/msfts
- OpenMOQ: https://openmoq.org/
- HTTP Live Streaming 2nd Edition (obsoletes RFC 8216; includes Low-Latency HLS and MPEG-TS segment carriage — the alternative data plane, [Alternatives](docs/alternatives.md)): https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/
- DVB-MABR, adaptive media streaming over IP multicast (ETSI TS 103 769) — the only specified point-to-multipoint profile in the field, and an access-network one: https://dvb.org/?standard=adaptive-media-streaming-over-ip-multicast

**Testing and background**

- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html

---

*This is a living document. Its purpose is to be proven wrong quickly and cheaply.*
