# Candidate Data Planes Compared

Status: working draft
Layer: **the data-plane choice** — this document *is* the layer where the two candidates differ.
Scope: the head-to-head this paper owes its own thesis. [Transport](transport.md) states the
requirements primary distribution imposes and evaluates MoQ against them; this document
evaluates the **alternatives** against the same requirements, on the axes an operator actually
decides on — scaling the distribution, reliability, hand-off complexity, interoperability,
latency, entitlement, carriage fidelity, economics and operational maturity.

**The conclusion, first.** For the majority of primary-distribution routes there are *two* viable
Internet-native data planes rather than one; they differ on a single axis that decides the choice
(latency); and everything that makes either of them *broadcast-grade* sits above the transport and
is common to both. That is not a retreat from the paper's thesis but a demonstration of it —
[vision](vision.md) §1 holds that the transport is the least interesting part of the transition.

The comparison that matters is not against the point-to-point incumbents. SRT, Zixi and RIST are
the obvious yardstick and the wrong one to lead with, because a transport that cannot fan out at
all sets a low bar (§10). The demanding alternative is **segmented HTTP carrying MPEG-TS**: it is
specified, universally interoperable, sells over commodity delivery today, and has an off-the-shelf
path back to a transport stream where MoQ has one implementation. Measured on the axes below it is
ahead of MoQ on most of them — though not on the one that costs the most to build, since the
obligation to hand a client a clean paced TS falls on the distributor either way (§4).

---

## 1. The three candidates, and what class each belongs to

| Candidate | What it is here | Class |
|---|---|---|
| **MoQ** | `moq import ts` → relay fabric → `moq export ts`, on QUIC/WebTransport | live publish/subscribe with native relay |
| **Segmented HTTP** | HLS carrying MPEG-TS segments (and DVB-DASH), over HTTP/2 or HTTP/3 | cacheable-object pull over commodity delivery |
| **SRT / Zixi / RIST** | a reliable UDP tunnel per destination, optionally through a gateway tier | point-to-point session transport |

They are grouped by *scaling shape*, not by quality, and the grouping flatters two of them: RIST is
openly specified and multi-vendor where the others are not, and is treated on its own in §10.1.

Two exclusions, so the field is honest. **TS-over-HTTP/1.1** — a continuous transport stream in
a chunked HTTP response — is assessed in [transport](transport.md) §3.3 and is excluded as a
neutral baseline because there is no agreed specification for it: choosing it buys a vendor
rather than a protocol. **WebRTC/SFU** is excluded because its media model does not carry an
MPEG-TS at all, so the hand-off problem it creates is a different one.

Segmented HTTP is assessed against [HTTP Live Streaming 2nd
Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
(`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS), and
quoted from it rather than from convention, because practitioner convention diverges from the
normative text in both directions — see §11.

---

## 2. Scaling the distribution

**At primary-distribution scale, scaling is not the discriminator. Who operates the replication
point is.** The topology is one-to-many but not internet-scale: tens to low hundreds of
endpoints ([vision](vision.md) §2). All three candidates handle that without strain, and none
of them breaks the linearity of last-mile delivery — an HTTP edge cache fetches an object once
and serves N receivers over N unicast connections, a MoQ relay receives an object once and
serves N subscribers over N unicast connections, and an SRT gateway holds N sessions. These are
the same topology under different names ([economics](economics.md) §4.7).

What differs is the *shape* of the replication point and who runs it.

| | Segmented HTTP | MoQ | SRT / Zixi / RIST |
|---|---|---|---|
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, from a dozen suppliers, today | one CDN today, at five to ten times commodity delivery; otherwise you | you, or a managed media service |
| Adding a destination | a cache fill nobody provisions | a subscription and its relay state | a gateway output slot, and sometimes an instance |
| Known hard ceilings | none at this scale | untested beyond our own rig; relay memory grows per ingested group and plateaus softly ([evidence](evidence.md) §8) | AWS MediaConnect: **50 outputs per transport-stream flow, not increasable**; 2 sources per flow |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network | none | none |

Three conclusions follow, and only the first is a differentiator.

**Statelessness is segmented HTTP's real scaling advantage, and it is a reliability advantage
in disguise.** Because a segment is a named resource rather than a position in a session, a
destination can move between edges, regions or suppliers mid-stream with nothing to
re-establish, and the origin never learns that it happened. MoQ and SRT fan-out is stateful, so
the replication point is also a failure domain: losing a relay loses a session, and recovery is
a resubscribe. This is developed in §3.

**Nobody here does point-to-multipoint at the last mile, which makes the phrase misleading in
all three columns.** Segmented HTTP is the only candidate with a specified multicast profile —
DVB-MABR, deployed commercially by tier-one operators — but it replicates inside an access
network the operator controls, terminating at a gateway in the home or the network edge. That is
consumer distribution, not affiliate distribution, and it does not apply to a few hundred
professional endpoints spread across the public internet. So "MoQ is point-to-multipoint and SRT
is point-to-point" is true only in the sense developed in §10: it describes **where the
replication point sits and who owns it**, not IP multicast.

**Fan-out economises backhaul, not delivery, for every candidate equally.** A regional
replication point collapses N copies of upstream carriage into one, which is worth real money on
a backhauled multiplex and nothing at all on the last mile ([economics](economics.md) §4.8).
This is the advantage most often cited first for MoQ, and it is not an advantage over segmented
HTTP, because a cache does exactly the same thing.

---

## 3. Reliability

Two questions hide inside this axis and they have different answers: *how does the transport
behave under loss*, and *how does the system recover when something fails*. The first is a wash.
The second favours segmented HTTP, and it is the more important of the two for a trunk.

### 3.1 Under loss: a wash, once the controller is chosen

MoQ collapses under uniform loss with QUIC's default CUBIC controller and restores full-rate,
byte-complete delivery on par with SRT once the sender is switched to BBR — parity, not
superiority, and a controller choice rather than a protocol property ([evidence](evidence.md)
§6). Low-Latency HLS **requires** HTTP/2 or HTTP/3, so over HTTP/3 it rides the same QUIC
substrate with the same per-stream loss isolation, and the RFC 9218 priority scheme is mandatory
there. There is no per-packet loss-resilience argument that distinguishes the two.

### 3.2 On recovery: segmented HTTP has the more robust model

The specification gives a segment a **defined availability window**: its Availability Duration
is the segment's own duration plus the duration of the longest playlist containing it, a live
playlist may not fall below three times the target duration, and a partial segment must remain
downloadable for at least three target durations after it leaves the playlist. So a failed fetch
can be retried — from the same edge, a different edge, a different Pathway under Content
Steering, or a redundant variant stream — for a specified period, using idempotent requests,
without the sender's involvement and without a session to re-establish. Completeness is bounded
by a published window rather than by a buffer somebody sized.

MoQ's reliability is scoped to a live subscription. Within it, QUIC delivers each object
completely or errors the stream. Outside it, recovery depends on a relay cache that is
deliberately shallow — "a recovery buffer, not a time-shift buffer" ([relay](relay.md) §3.2) —
because for live linear distribution falling far behind is itself a fault. Failure *detection*
is bounded by the QUIC idle timeout rather than being hitless, and a source that exits cleanly
is not failed over at all ([evidence](evidence.md) §7).

**For a trunk, this is the wrong way round for MoQ.** Primary distribution's acceptance test is
byte-completeness at the hand-off with a few seconds of latitude, and segmented HTTP converts
that into cache retry — the most heavily exercised reliability mechanism on the internet — while
MoQ converts it into live session management, which is operationally heavier for a trunk route and
the part of the stack where current implementations are roughest ([evidence](evidence.md) §7). The
countervailing MoQ property is that it reaches the same completeness
with a much smaller buffer, which is the latency argument in §5 and not a reliability argument.

### 3.3 Where broadcast actually gets its reliability, and why it is common to both

Neither transport's own recovery is what a broadcaster relies on. Reliability comes from **1+1
with selection at the receiver**, and that is transport-independent. It was measured on
MoQ: two independently groomed legs come out byte-identical and the pair rides out the death of a
publisher, a relay or an exporter, with a residual on restarting one leg of a live pair that is
an upstream fix rather than an architectural limit ([evidence](evidence.md) §7). Segmented HTTP
gets the equivalent from the specification — redundant variant streams, and Content Steering with
Pathway Cloning for client-driven failover between disjoint delivery paths — and gets it
*specified*, which MoQ's `--origin` reselect is not.

So the redundancy layer is common and its design transfers to either data plane unchanged. That is
the first of several places where the effort sits above the transport.

---

## 4. Complexity on the hand-off side

### 4.1 What the obligation actually is

**The deliverable is a clean, paced MPEG-TS at the hand-off, and it is the distributor's
obligation on either data plane.** This has to be stated before the comparison, because getting it
wrong inverts the answer.

A distributor no longer supplies its clients' receiving equipment. The era of shipping a
PowerVu or an XOS receiver to every affiliate is over: the receive estate is the client's capex and
the client's choice, on a five-to-fifteen-year replacement cycle nobody upstream controls. What
survives from that era is the *contract* — a conformant transport stream, correctly paced, over
ASI or IP, at an agreed demarcation point, which the client then feeds into whatever it has chosen
to run. **So the working assumption is that many receivers want nothing but a clean TS**, and any
argument that leans on the client owning a modern software-defined receiver is an argument about
someone else's estate.

The consequence is that **the grooming stage sits on the distributor's side of the demarcation on
both data planes, and its absence from either specification is the distributor's problem either
way.** The HLS document contains **zero occurrences of PCR, constant bit rate, stuffing or null
packet**; MoQ has no notion of them either. Both deliver in bursts, and a stream reconstructed from
bursts has timing hardware IRDs reject on TR 101 290 — measured on MoQ at
[evidence](evidence.md) §3 and, more severely, on segmented HTTP at [evidence](evidence.md) §10. Either
way an edge stage must reassemble a continuous transport stream, pad it to a nominal constant rate,
re-stamp PCR inside the P2 accuracy limit and at intervals under 40 ms, re-insert null stuffing,
and present RTP / ST 2022-7 and ASI / SDI / ST 2110 ([architecture](architecture.md) §7.2).

The comparison is therefore between the two *distributor-side* toolchains, not between what a
client happens to own.

### 4.2 Reassembly: off the shelf for segmented HTTP, single-implementation for MoQ

This is the asymmetry that survives, and it is narrower than a product comparison suggests.

**Segmented HTTP has an off-the-shelf reassembly stage in the toolchain broadcast engineers
already run.** TSDuck's `tsp -I hls` pulls a playlist and emits the transport stream; its
`tsp -O hls` does the reverse, writing TS segments with a PAT and PMT at the start of each — the
specification's Media Initialization Section requirement, implemented natively — and a sliding live
window with a retention margin. FFmpeg reads a playlist too, with the fidelity costs
[T13](../lab/test-13-downstream-grooming.md) measured. So the "turn this back into a TS" half is a
solved, multi-implementation problem.

**For MoQ it is one implementation.** `moq export ts` is the only stage that converts MoQ tracks
back to MPEG-TS, its continuity counters are rendered from process state rather than carried
([evidence](evidence.md) §7), and there is no second implementation to fall back to.

**Against that, MoQ's reassembly is much simpler to write.** It is a subscription plus object
reassembly. A segmented-HTTP gateway carries a manifest state machine — blocking playlist reload,
media-sequence tracking, partial segments and preload hints, rendition reports, discontinuity
handling, availability windows and a retry policy — and must hold at least `PART-HOLD-BACK` of
buffer, which the specification requires to be at least twice and recommends at least three times
the part target duration. Simpler to write and already written are both real advantages; for an
operator, already written usually wins.

### 4.3 Grooming: unsolved off the shelf for both, and measurably harder for segmented HTTP

**Segmented HTTP inherits the grooming problem in full, and it is worse rather than equal — measured,
at two orders of magnitude.** Each transport's ungroomed egress was captured at the same point with the
same instrument, the two candidate data planes in [T14](../lab/test-14-data-plane-comparison.md) and
the point-to-point tunnels in [T15](../lab/test-15-point-to-point-cadence.md):

| | MoQ | Segmented HTTP (2 s segments) | RIST / SRT *(see below)* |
|---|---|---|---|
| Median burst | 12.4 kB | **2.95 MB** | 30.6 kB — the source's, not the protocol's |
| Bursts in 60 s | 3,078 | 28 | 2,400–2,650 |
| Gaps above 1 s | **none** | **24** | **none** |
| Largest gap | 149 ms | **4.01 s** | **~35 ms** |
| 10 ms peak/mean | 24× | **231×** | 3.4× |

The mechanism is unambiguous: silences arrive at exactly the segment duration, with occasional stalls
of two segment periods, because the client fetches a completed segment at line rate and then waits for
the next one to exist. MoQ delivers something in every second of the window; segmented HTTP alternates
between nothing and 20–30 Mb/s. A groomer for it needs seconds of buffer where a MoQ groomer needs
milliseconds — and [T16](../lab/test-16-grooming-segmented-http.md) has since shown that one groomer
covers both, provided it sizes that buffer from what it observes arriving rather than from a configured
depth: same binary, no flag changed, and an egress indistinguishable from the groomed MoQ lane's.

The third column is [T15](../lab/test-15-point-to-point-cadence.md), and it is a different kind of
entry, in two ways worth stating before it is read across. RIST and SRT are **transparent** — measured
identical to a plain-UDP control — so the 30.6 kB is what this campaign's software publisher produced
and not a property of either protocol; a smoother source would come through smoother. And it is taken
at a *finer* publisher setting than the first two columns, because at the setting T14 used the source's
own bursts were coarser than anything the tunnels could add and the control could not be separated
from the transport. That does not make the columns incomparable: MoQ was re-run at both settings and
does not move (12.2 kB against 12.4 kB, peak/mean 23.93 against 23.95), and segmented HTTP's burst is
segment-sized regardless. Only the third column depends on the source, which is the finding.

The two rankings that result disagree, and a hand-off claim has to say which one it means: **MoQ hands
over the smallest bursts, the tunnels the shortest silences.** Buffer depth follows the former; a
groomer's start gate and underrun threshold follow the latter.

**The consequence is a single knob; it is the same knob as latency; and it is measurably stuck.** Burst
size is segment size, so reducing the grooming burden means reducing segment size, which is identical to
the action that reduces latency, and it terminates in partial segments. That escape route has now been
tested and is closed: partial segments carrying MPEG-TS **can** be published, free, with Apple's tools —
but **no freely available client fetches them**, so the egress a groomer actually sees is the classic
one. Measured, the median burst falls only from 2.95 MB to 2.27 MB, and that reduction is explained by
segment duration rather than by parts; against MoQ the gap closes from ~240× to ~185×
([T14](../lab/test-14-data-plane-comparison.md) measurement 2b). So an operator gets both problems
together and cannot pay down either without buying receive-side hardware (§4.4).

What is not in doubt is that off-the-shelf tools do not do it. T13 graded every candidate an
engineer would reach for against four criteria fixed in advance — mux preserved, PCR inside 481 ns,
no interval above 40 ms, honest duration on a rate-controlled wire. TSDuck cannot restore stuffing
at all, because `tsp` can overwrite existing null packets but cannot inflate a stream. FFmpeg's
`-muxrate` produces the best PCR arithmetic measured and an unusable wire, retypes all three
SCTE-35 PIDs and relabels AC-3. GStreamer's `mpegtsmux` loses every PSI table beyond PAT and PMT,
the PMT's own PID, the teletext descriptor and two of three splice PIDs. **None of those failures
is about MoQ** — they are properties of the tools, so they apply identically to a stream reassembled
from HLS segments. The purpose-built groomer is required on both paths.

### 4.4 What the IRD vendors' HLS inputs are, and are not

Professional edge-gateway and IRD platforms do list HLS, DASH and TS-over-HTTP inputs with
ABR-to-TS conversion alongside RF, ASI, SRT, RIST and Zixi — Ateme's TITAN Edge lists an HLS and a
DASH receiver among its inputs, Synamedia's Media Edge Gateway lists "TS over HTTP, HLS, and DASH
with ABR2TS conversion" for affiliate and MVPD hand-off, both with ST 2022-7 failover and
SDI / ST 2110 out. That is worth knowing, and it is worth being precise about what it buys.

- **It is not a reason to assume the problem is solved**, because it is the client's box. Across a
  real estate the assumption fails at most sites, and where it holds it is the client's decision to
  reverse.
- **It is a supply-chain option on the distributor's own side.** The same class of product can be
  bought and operated as the distributor's *own* edge gateway, in a regional PoP or as owned kit at
  the demarcation. That is a genuine advantage over MoQ, where the equivalent does not exist at any
  price — but it is an advantage in procuring the egress stage, not in offloading it.
- **It is unmeasured.** Whether such a stage's output passes TR 101 290 P1/P2 on a real analyser is
  exactly the question this paper holds open for its own groomer, and it should be assumed of
  nobody's product until measured. These are **datasheet claims** wherever they appear here, and
  the test is the first open cell in [lab](../lab/planned-experiments.md).
- **Where it does hold, it is optionality rather than architecture.** A client running a
  software-defined receiver can take segmented HTTP directly and the distributor's edge stage is
  skipped at that site. Nothing equivalent is available for MoQ. Worth having; not something a design
  can rest on.

### 4.5 Where the demarcation puts the gateway, which changes more than it looks

Because the gateway is the distributor's, its *placement* is a decision rather than a given, and it
moves the fan-out arithmetic. Place it at each client's demarcation and the Internet-native transport
runs to as many destinations as there are clients. Place it in regional PoPs and the transport runs to
as many destinations as there are PoPs, with the client-facing hop becoming a short TS-over-IP
delivery on local transit — which is the configuration that most reduces the delivery bill, for the
same reason a relay economises backhaul rather than delivery ([economics](economics.md) §4.8).
[Architecture](architecture.md) §7.3 currently prefers placement at the hand-off location; that
preference is about timing determinism and hitless pairing, and its cost side has not been modelled
against the PoP alternative. Neither data plane is favoured by the choice, which is why it is noted
here and pursued in the economics rather than in this comparison.

### 4.6 So the honest verdict on this axis

**It splits, and on the half that decides whether a hardware IRD locks, MoQ wins.** Two separate
claims were being run together under "hand-off":

- **Receiving** — turning the delivery back into a transport stream — favours segmented HTTP.
  Off the shelf on one side, single-implementation on the other, and an ABR-to-TS box is purchasable as
  the distributor's own edge stage where no MoQ equivalent exists at any price.
- **Handing off cleanly** — presenting a paced, conformant stream at the demarcation — favours MoQ,
  measurably: the same groomer has ~240× coarser bursts and 24 multi-second silences to absorb on the
  segmented-HTTP side (§4.3). Off-the-shelf tools do it on neither.

Since it is the second that the installed base actually requires, the axis no longer favours segmented
HTTP overall. **"Easier to receive" and "easier to hand off cleanly" are different claims, and it is
easy to run them together.**

**This restores the paper's central claim rather than undermining it.** The claim is that the
durable engineering value sits in the broadcast-grade layer above the transport
([vision](vision.md) §7, item 6). Because the obligation to hand off a clean paced TS does not
transfer to the client on either data plane, that layer is required and owned on both — so it is
defensible against the alternative, not merely against MoQ's immaturity. It is also now demonstrably
*one* layer rather than two: the same groomer, sizing itself from arrival, has been measured to the same
conformance behind either plane ([T16](../lab/test-16-grooming-segmented-http.md)). The caveat that
remains is narrower once reassembly and grooming are separated: a *product* exists that can be bought to
fill part of that layer on the segmented-HTTP side, and whether it fills it to broadcast conformance is
unmeasured.

---

## 5. Latency

**This is the one axis where MoQ is structurally ahead, and because everything else favours
segmented HTTP it is the axis that decides the choice.**

Low-Latency HLS is bounded by construction, not by implementation quality. `PART-HOLD-BACK`
MUST be at least twice, and SHOULD be at least three times, the part target duration, and part
targets in production sit around 200–330 ms — so the hold-back alone is roughly 0.6–1 s before
encode, packaging, delivery and the gateway's own de-jitter buffer are counted. The specification
is explicit that the trade is not free: a shorter target duration "reduces latency but also
reduces available buffer, handicaps adaption and increases delivery overhead, increasing the
likelihood of playback stall." Two to five seconds end to end is the realistic envelope, and
pushing below two seconds makes the chain fragile in a specific way — an encoder hiccup longer
than the part target breaks the blocking playlist reload, which degrades silently into polling.

MoQ carries the same feed sub-second, measured, on the media-aware lane. Both then pay whatever
the groomer's buffer costs, which is common.

**The question is therefore whether seconds are tolerable, and the usual answer is too generous.**
"Sub-second desirable, a few seconds tolerable" ([transport](transport.md) §2) is true of the
*feed's own integrity* and understates the transition. A
geostationary satellite path delivers a fraction of a second; replacing it with a 2–5 s path
consumes most of a downstream budget that was previously free, at every destination, and the
consequences are operational rather than technical: regional splice and blackout timing,
relative alignment between affiliates served by different paths during a mixed-estate migration,
live handback, and any destination that re-distributes and adds its own budget. None of that is
a transport defect. It is a reason "seconds are tolerable" has to be answered per route by the
destination, not asserted once in a requirements list.

Stated as a decision rule: **if the route's destinations can absorb 2–5 s — in practice nearer 6 s
unless a commercial ABR-to-TS receiver is bought, since no free client fetches partial segments
(§4.3) — segmented HTTP is the better engineering choice today on the balance of the remaining axes — decisively so on interop,
maturity and delivery economics, narrowly on the hand-off, against narrower MoQ advantages on
entitlement and multi-programme carriage. If they cannot, segmented HTTP is not a candidate at all
and MoQ is the only Internet-native option with commodity delivery in prospect.** That is a narrow
case, and it is a real one. Note what the rule does *not* decide: the grooming and egress layer is
built either way (§4).

---

## 6. Interoperability

Segmented HTTP wins this decisively, and the reason is worth stating precisely, because the
summary version of it flatters both sides.

**On the delivery path, segmented HTTP has no interop problem because it has no transport to
interoperate.** It is HTTP; every CDN, proxy and cache moves the bytes without parsing them.
MoQ's delivery path is a relay, which is a protocol implementation, and measured against all
eight other registered public relays a MoQ feed carries no media at all — with at least four
distinct causes, so no single fix restores portability ([evidence](evidence.md) §9). On the
acceptance criterion this paper set for itself — does a stream published into somebody else's
infrastructure arrive intact — segmented HTTP passes today and MoQ does not. The standards status
is inverted relative to the outcome: HLS states plainly that it "is not an Internet standard" and
interoperates everywhere, MoQ is genuinely standards-track and interoperates within one
implementation. **Standards-track status is a prediction about interop; this is the evidence that
the prediction and the property are different things.**

**But segmented HTTP's interop and its ability to carry a contribution mux are mutually
exclusive, and that has not been said anywhere.** The specification is normative: "Transport
Stream Segments MUST contain a single MPEG-2 Program; playback of Multi-Program Transport Streams
is not defined." A CDN does not parse the payload, so an MPTS placed in TS segments *will* be
delivered — but no conformant client, packager or analyser is required to handle it, and the
moment you rely on that you are running a private profile over public infrastructure, which is
the same lock-in position as TS-over-HTTP/1.1 ([transport](transport.md) §3.3) reached by a more
respectable route. So the honest form of the interop advantage is: **segmented HTTP interoperates
universally as long as you stay inside the single-programme envelope, and the moment you leave it
you keep the delivery-path interop and lose all the rest.**

The service layer is a second, smaller residual on the same side. A TS segment's initialisation
state is defined as a PAT followed by a PMT, and each segment must carry both; SDT, NIT, EIT, TDT
and TOT appear nowhere in the specification. Nothing forbids extra PIDs riding along and nothing
requires or preserves them — so "TS in HLS guarantees the DVB components" is true of PIDs, PES,
`stream_type` and PAT/PMT and untrue of the service layer. That is the same residual the
media-aware MoQ lane has, reached by a different route, except that the MoQ lane has a catalog
through which the service layer could in principle be threaded and a segment has nothing.

Two ecosystem asymmetries complete the picture and both favour segmented HTTP. Ad signalling has
a specified out-of-band representation — the mapping of SCTE-35 `splice_info_section()` into
`EXT-X-DATERANGE` — so it does not depend on an in-band PID surviving transit, which is exactly
what [T13](../lab/test-13-downstream-grooming.md) found the off-the-shelf MoQ grooming candidates
damaging. And monitoring exists: manifest
and segment probes, CMCD/CMSD, and the analyser estate, against MoQ's thin observability
([operations](operations.md) §3).

---

## 7. Entitlement and access control

**MoQ's advantage here is real but narrow, and it is not about revocation latency.**

The intuitive case is that MoQ carries authorization at the point of subscription and can refuse
or drop it there, while segmented HTTP's entitlement is an external bolt-on with revocation
bounded by token lifetime. The second half does not survive contact with how Low-Latency HLS
actually behaves. [Architecture](architecture.md) §11.2 revokes by two paths — a
fast path that drops the subscription, and a backstop of short token lifetimes that revokes by
declining to refresh. **Segmented HTTP has the backstop natively and lacks only the fast path**,
and its backstop is tight rather than loose: every request is authorized at the edge by signed
URL, signed cookie or a CDN token scheme, and a low-latency client re-fetches the playlist roughly
every part target duration. The worst-case revocation bound is therefore about one request
interval — sub-second to a couple of seconds — which is not materially worse than dropping a
subscription, and much tighter than the loose token lifetimes the bolt-on framing implies.

What genuinely differs is **where enforcement lives and whether the session is observable**.

- With segmented HTTP the enforcement point is the CDN, so the entitlement model is whatever that
  supplier's token machinery supports, configured per supplier, and it is not your code. With
  multiple suppliers it is configured more than once, differently.
- With MoQ the relay is the enforcement point, so if you operate the relay the policy is yours
  and portable across it. If you do not operate it, this advantage transfers to whoever does.
- A subscription is a **live, queryable fact**: which endpoint is receiving what, right now, is
  a state the relay holds. With segmented HTTP it is inferred from delivery logs. For per-tenant
  accounting, for "is this affiliate actually receiving" and for the control-plane model in
  [architecture](architecture.md) §11 this is the substantive difference.
- Revoking access to content already in an edge cache is a cache-invalidation problem in one
  model and a non-problem in the other.

So the defensible claim is that MoQ gives entitlement a native, portable place to live and makes
the session observable — not that it revokes faster.

---

## 8. Carriage fidelity

Measured for a single programme in [T14](../lab/test-14-data-plane-comparison.md); the MoQ columns
are from [T1](../lab/test-1-baseline-ts.md)/[T2](../lab/test-2-media-aware-transparency.md).

| | Segmented HTTP | MoQ media-aware lane | MoQ opaque lane |
|---|---|---|---|
| Multi-programme mux | **normatively excluded** (see §6) | one programme, reconstructed | **verbatim MPTS** |
| PIDs, PES, `stream_type`, PAT/PMT | preserved | preserved | preserved |
| SDT / NIT / TDT / TOT | **preserved** — measured | residual, partly closed upstream ([evidence](evidence.md) §1) | preserved |
| Continuity counters | **preserved except a forced re-stamp on PAT/PMT** | regenerated by the exporter | preserved |
| Null stuffing | **carried** — measured | not carried | carried if verbatim |
| Byte-identical to source | **yes, except byte 3 of PAT/PMT** | no | yes |

**For a single programme, segmented HTTP carrying MPEG-TS is as verbatim as the opaque MoQ lane,
which is the opposite of what the specification's wording suggests.** The reasoning that a segment
"must begin with PAT then PMT" and is therefore a re-mux does not hold: prepending a PAT/PMT pair does not rebuild the
multiplex, it inserts two packets and renumbers the continuity counters of those two PIDs. Measured
against the source packet by packet, the only difference in a 1,200-packet window is byte 3 — the
continuity counter — on one PAT and one PMT. Media, audio, teletext, all three splice PIDs and the null
stuffing are byte-identical, and continuity is error-free across segment boundaries. The DVB service
layer travels too, not because the specification provides for it (it does not mention SDT, NIT, TDT or
TOT) but because nothing in the path parses the payload.

**What survives of MoQ's advantage on this axis is the multi-programme case alone**, where HLS's
"Transport Stream Segments MUST contain a single MPEG-2 Program" bites (§6). That is normative rather
than demonstrated, it is measurement 4 in [lab](../lab/planned-experiments.md), and it now carries the
whole row. Against the *media-aware* lane, segmented HTTP is straightforwardly better: it keeps
stuffing and continuity counters that the exporter regenerates.

**Fidelity is not free, and §9 prices it at ~7 % of the wire.** The bottom two rows of that table
are the reason: carrying the stuffing and every TS packet header is what makes segmented HTTP verbatim
*and* what makes it 1.056× the source TS rate against the media-aware lane's 0.982×. The same is true of
the opaque lane, whose cost is still unmeasured but derives to near SRT's 1.037× if it is truly verbatim
— so on this axis the choice is not between data planes but between fidelity and bandwidth, and it is
the same choice on both. It is also the lane on which MoQ's graceful-degradation advantage is weakest
([economics](economics.md) §9, [transport](transport.md) §4.1).

---

## 9. Economics

Fully modelled in [economics](economics.md); the comparison reduces to three facts.

**The wire favours MoQ by ~7 %, and that is the fidelity trade of §8 priced rather than a separate
axis.** MoQ's media-aware lane measures **0.982×** the source TS rate and SRT **1.037×** on a real path;
segmented HTTP over HTTP/3 comes to **1.056×**, its HTTP layer measured at 1.0006× and per-packet framing
taken from the same real-path measurement, so that figure is derived rather than measured end to end
([T14](../lab/test-14-data-plane-comparison.md)):

- **Only declining to be verbatim gets a data plane below 1.0×.** Every verbatim candidate sits at
  1.03–1.06× whatever its framing; MoQ's lane is cheaper because it carries neither this clip's
  4.57 % null stuffing nor the 4-byte header on each surviving TS packet. So §8's fidelity wash and
  this 7 % are the same fact: segmented HTTP's strongest card and its bandwidth penalty have one cause.
- **The obvious rejoinder — that a TS packager has no reason to retain stuffing either, so the
  saving is not MoQ's — fails twice over**: the off-the-shelf packager does retain it, and one that
  stripped it would stop producing byte-verbatim segments and forfeit the §8 advantage.
- **HTTP costs nothing to speak of.** Response headers and playlist re-fetching total 0.06 % of
  payload at 2.4 s segments, and the request bytes back another 0.01 %, so the penalty is what HLS
  carries, not that it is HTTP. **HTTP/3 is the more expensive substrate by ~2.6 points** than
  HTTP/2 on TCP, since QUIC's minimum 1200 B datagram charges 5.5 % framing against 2.7 %.

The margin still travels with the source's stuffing ratio — an unstuffed mux narrows it to ~2.5
points — and single-digit percentages remain the wrong basis for choosing a transport in either
direction ([economics](economics.md) §4.8).

**Destination count decides the bill, not the transport.** Unicast cost is linear in destinations
for every candidate here, and the choice among transports moves the model by single digits while
destination count moves it by three orders of magnitude ([economics](economics.md) §4.7).

**The market the delivery is bought in decides the level, and this is where segmented HTTP is
ahead by an order of magnitude today.** Commodity CDN delivery lists at $0.005–0.010/GB against
roughly $0.09/GB of metered cloud egress; the one CDN that sells MoQ relay prices it at $0.050/GB.
So segmented HTTP is the only candidate whose delivery can be bought in the commoditised market
right now, which is the position [economics](economics.md) §4.9 argues MoQ *could* reach.

---

## 10. SRT and RIST: scaling is possible, and that is not the differentiator

A vendor's challenge, and it is correct: **SRT can be scaled.** The mechanism is a
re-origination or gateway tier — each hop remains a point-to-point session, and fan-out comes
from running N sessions out of a replication point. Replicating a relay architecture with SRT as
a DIY platform is entirely feasible, and for an operator with the network to put it on it can be
the cheapest option per byte on the whole ladder ([economics](economics.md) §4.4).

**What is unavailable is a commodity market for it, and the shape of that absence is specific.**
CDNs do support SRT — at the *door*. SRT is the standard contribution ingest into a CDN's
packaging tier, after which fan-out to the audience happens as segmented HTTP. No CDN sells SRT
*to the destination*. So an SRT trunk to N professional endpoints resolves to one of three cost
bases, and the choice among them is the actual engineering decision:

1. **Your own transit and points of presence.** The cheapest per byte, and the reason a DIY relay
   platform is a serious answer rather than a workaround. Bounded by reach: serving several
   hundred sites from owned infrastructure means PoPs near all of them, and the build-up prices
   one ([economics](economics.md) §4.7).
2. **A gateway fleet in a hyperscaler.** Operationally the easiest and structurally the most
   expensive, because every copy leaves through metered egress at roughly an order of magnitude
   above commodity delivery — and that spread is the entire always-on trunk case
   ([economics](economics.md) §4.2).
3. **A managed media service** — MediaConnect, Zixi, Haivision, LTN. Premium per-flow pricing on
   top of hyperscaler-class egress, and with structural quotas rather than elastic ones: a
   MediaConnect transport-stream flow allows **50 outputs, not increasable**, and 2 sources, so
   past 50 destinations the topology becomes chained flows each paying egress again.

**So the SRT-versus-MoQ difference is not that SRT cannot fan out. It is who operates the
replication point and which market prices it.** SRT has no object model and no native relay
primitive, so its replication point is a stateful media gateway per stream per destination — a
media-server business rather than a delivery business, which is why the commodity delivery market
has nothing to sell there and why the burden stays with the operator.

That argument is sound, and it has a consequence that is easy to miss: **the advantage MoQ
claims over SRT is exactly the advantage segmented HTTP already has.** Being shaped like
something a delivery market can sell is not a MoQ property; it is a property of anything
cache-shaped, and segmented HTTP has been cache-shaped and commoditised for well over a decade. So the
market-structure argument in [economics](economics.md) §4.9 narrows to a precise claim: *the
sub-second band has no commodity supplier, and MoQ is the only candidate whose architecture could
give it one.* It is not a general claim that MoQ is the cheapest way to move a broadcast feed
over the internet, and where seconds are tolerable it does not apply at all.

Zixi sits in the same class as SRT for this purpose, and additionally carries a per-GB licence on
top of every rate, so a proprietary protocol commoditises only as far as its licensor permits.

### 10.1 RIST, which deserves better than being listed alongside SRT

Grouping RIST with SRT and Zixi, as §10 has just done, undersells it. On the axes this
comparison actually cares about it is the **strongest of the point-to-point transports**, and on one
axis it is plausibly stronger than either candidate data plane. It fails the primary-distribution
test for one reason only, and it is a reason about markets rather than engineering.

Comparisons below are against the **four transports this paper weighs individually**: MoQ,
segmented HTTP, SRT — taken as representative of the proprietary point-to-point tunnels, Zixi
included — and RIST.

**Where RIST is genuinely ahead.**

- **It is an open specification with real multi-vendor implementation** — VSF TR-06 (Simple, Main
  and Advanced profiles), developed in the Video Services Forum and exercised at interop
  plugfests. Set against §6: HLS interoperates universally but is an Apple-authored informational
  document with a closed authoritative implementation; MoQ is standards-track but carries media
  within a single implementation. **RIST is the only one of the four that is both openly specified
  and demonstrably multi-vendor.** For a broadcaster procuring against a 5–10 year horizon that is
  not a small thing, and it is the axis on which MoQ is weakest ([evidence](evidence.md) §9).
- **It is RTP-native**, so it lands on infrastructure the installed base already speaks, and Simple
  Profile is compatible with SMPTE 2022-1 FEC. Main Profile adds DTLS or PSK encryption,
  tunnelling, multiplexing and in-band control — a coherent answer to several things this paper
  has to build above the transport.
- **Its hand-off leads the four on worst-case silence — tied with SRT — and is mid-table on burst
  size.**
  RIST is a packet-level tunnel with a jitter buffer and hybrid ARQ/FEC, so it reconstructs the
  *original* packet cadence, delayed, rather than reassembling a stream from objects or segments.
  Measured, that is exactly what it does: RIST's egress is identical to a no-transport control on
  burst size, at two different source granularities, and so is SRT's
  ([evidence](evidence.md) §11). The consequence is not the one the mechanism suggests. A
  transparent transport hands on whatever it was given, whereas MoQ *re-paces* — its 12.2–12.4 kB
  bursts are a property of the object model and do not move when the source is made four times
  finer. So from the same publisher RIST hands a groomer 30.6 kB where MoQ hands it 12.2 kB. Where
  RIST leads is the longest silence, which is what actually sizes a groomer's start gate and
  underrun threshold: **~35 ms against MoQ's 149 ms and segmented HTTP's 4.01 s.** Two caveats in
  RIST's favour: transparency means a true CBR hardware source would come through smoother than this
  campaign's software publisher, and libRIST's opt-in `cbr-output` paces the receiver's own egress
  down to 1.3 kB, the finest measured anywhere here.
- **Dual-path seamless protection is native**, rather than the 1+1 construction §4 has to assemble.

**Where it fails, and it is the same failure as SRT.** Fan-out is N sessions from a replication
point the operator runs. RIST's efficient multi-destination story is **multicast**, and it is a good
one — but multicast is a property of a managed network, and the public internet is not one. So over
the internet RIST degenerates to the three cost bases above, with no CDN selling RIST to the
destination and no commodity market to price it. **The scaling limit is not a deficiency in RIST;
it is that RIST was designed for a different network than the one primary distribution now has to
cross.**

**The honest summary is uncomfortable for the thesis and worth stating plainly.** For a distributor
serving *tens* of destinations over owned transit or a managed network — which is a great deal of
real primary distribution — RIST is likely the best-engineered choice available today, and better
than either candidate here on openness, worst-case delivery silence and installed-base fit. What it cannot
do is follow commodity delivery pricing to hundreds of destinations over the public internet. The
case for an Internet-native data plane is therefore a case about **reach and cost at scale**, not
about RIST being deficient — and any argument that reaches for RIST's technical shortcomings is
reaching for the wrong thing.

---

## 11. Six corrections the comparison forced

Each of the six below is a plausible claim, each was load-bearing in this comparison, and each
turned out to be false. They are recorded together because the *way* each failed generalises to
other transport comparisons. Two fail in the direction that flatters MoQ, two in the direction that
flatters the alternative — one by argument, one by measurement — the fifth in both directions
at once, and the sixth in favour of a transport that is in neither camp.

- **"HLS carrying TS is a new capability."** It is the opposite: MPEG-TS was HLS's original
  container and, until fragmented MP4 arrived a decade ago, its only one. Nor is HLS a
  carry-anything envelope — the specification admits a closed list of five formats (MPEG-2 TS,
  fragmented MP4, packed audio, WebVTT, IMSC) and states that transport of other media file
  formats is not defined. What is genuinely newer is Low-Latency mode, in which partial segments
  may also be MPEG-TS. TS-in-HLS has therefore been available throughout, and its absence from
  most MoQ comparisons is a habit rather than a technical fact.
- **"MoQ rides QUIC, and that is the decisive property."** Low-Latency HLS *requires* HTTP/2 or
  HTTP/3, with RFC 9218 priorities mandatory on HTTP/3, so over HTTP/3 it rides the same QUIC
  substrate with the same per-stream loss isolation. QUIC is a necessary substrate for both and
  distinguishes neither; what distinguishes MoQ is the object and subscription model above it.
- **"Segmented HTTP's receive-side hand-off already ships, so that layer is solved for it."** This
  counted the client's equipment as if it discharged the distributor's obligation. It does not: a
  distributor no longer supplies its clients' receivers, so the deliverable is a clean paced TS at a
  demarcation on the distributor's side, and the grooming stage is therefore owned on both data
  planes. The method rule: **when comparing two designs, draw the demarcation before comparing, and
  count only work that falls on the same side of it.** An advantage that lives in a third party's
  capex is optionality, not architecture.
- **"A sequence of TS segments is a re-muxed stream, so byte-verbatim carriage is structurally
  unavailable."** Reasoned from the requirement that a segment begin with a PAT and PMT, and wrong:
  measured against the source, a segment differs in byte 3 — the continuity counter — on one PAT and
  one PMT, and in nothing else (§8, [T14](../lab/test-14-data-plane-comparison.md)). Inserting two
  packets is not re-muxing. The method rule: **a "structurally impossible" claim derived from a
  specification is a hypothesis about an implementation, and costs one afternoon to test.** A claim
  like this is easy to state once in a table cell and once in prose without either prompting the test.
- **"Not carrying stuffing is not unique to MoQ, since a TS packager has no reason to retain it — so
  the wire rows would converge if measured."** They do not converge: measured, the off-the-shelf
  packager keeps the stuffing and segmented HTTP lands 7.0 % above the media-aware lane (§9). The
  reasoning fails in the direction that flatters the alternative, while the estimate attached to it
  (~1.05×, [economics](economics.md) §4.7) proves right at 1.056× for a different reason than the one given.
  What the reasoning missed is that the two properties are one: a packager that stripped stuffing to
  reach parity would stop producing byte-verbatim segments and forfeit its §8 advantage. The method
  rule: **when an argument says two measurements should converge, check whether the mechanism it
  proposes would cost something elsewhere in the same comparison.** A saving reasoned about in
  isolation is usually a trade seen from one side.
- **"RIST reproduces the source's own cadence, so it hands a groomer the cleanest egress."** The
  premise is exactly right and the conclusion does not follow. Measured, RIST and SRT are
  *transparent* — indistinguishable from a no-transport control on burst size — while MoQ *re-paces*,
  emitting 12.2–12.4 kB regardless of what it is fed (§10.1, [evidence](evidence.md) §11). So
  "reproduces the source" is a weaker property than "sets its own granularity", and from the same
  publisher RIST hands over 30.6 kB where MoQ hands over 12.2 kB. The method rule: **when a
  comparison ranks transports by a property of their output, measure the input as well** — otherwise
  a transport that merely passes its input through is credited with its source's virtues, and a
  claim about an encoder is filed as a claim about a protocol.

---

## 12. Where the comparison stands, and the test that would settle it

**Verdict, axis by axis.** Read the "favours" column as *today*, on the evidence in this
repository and the current specifications.

| Axis | Favours | Margin |
|---|---|---|
| Scaling the distribution | segmented HTTP | narrow — both scale at this size; statelessness and supplier count are the difference (§2) |
| Reliability under loss | neither | none — shared QUIC substrate; MoQ measured at parity with SRT (§3.1) |
| Reliability of recovery | segmented HTTP | clear — specified availability window, idempotent retry, client-driven failover (§3.2) |
| Reassembly to a transport stream | segmented HTTP | clear — off the shelf in TSDuck and ffmpeg against MoQ's single `moq export ts` (§4.2) |
| Grooming to a clean hand-off | **MoQ** | **measured — the same groomer absorbs ~240× coarser bursts and 24 multi-second silences on segmented HTTP; against RIST and SRT the two candidates split, MoQ on burst size and the tunnels on worst-case silence** (§4.3, §10.1) |
| Latency | **MoQ** | **decisive — sub-second against a 2–5 s floor that free software cannot reach with MPEG-TS at all: parts publish free, no free client fetches them, so ~6 s without buying a receiver** (§5) |
| Interoperability | segmented HTTP | decisive, conditional on the single-programme envelope (§6) |
| Entitlement and control | MoQ | narrow — enforcement point and session observability, not revocation speed (§7) |
| Carriage fidelity | neither, for one programme | **measured a wash — segmented HTTP is byte-verbatim but for the PAT/PMT continuity counter, so MoQ's advantage narrows to the multi-programme case alone** (§8) |
| Wire volume | **MoQ** | **~7.0 %, MTU-invariant — 0.982× the source TS rate against 1.056× over HTTP/3; the §8 fidelity trade priced. HTTP layer measured, framing derived from a real-path measurement** (§9) |
| Delivery economics | segmented HTTP | decisive, and it swamps the row above — commodity delivery at $0.005–0.010/GB against one MoQ supplier at $0.050 (§9) |
| Operational maturity | segmented HTTP | decisive — mature multi-vendor tooling and existing staff skills against a pre-1.0 ecosystem |

**What that adds up to.** For a route whose destinations can absorb two to five seconds and which
carries a single programme, segmented HTTP carrying MPEG-TS over HTTP/3 is still the better engineering
choice today — on interop, maturity, delivery economics and recovery, none of which is close, and now
on carriage fidelity too, where it turns out to be byte-verbatim. MoQ's case is not general and should
not be stated as though it were. Measurement narrowed it and sharpened it at the same time: it is
sub-second capability, verbatim *multi-programme* carriage, a portable enforcement point with an
observable session, push rather than manifest polling, an egress a groomer can actually pace, and
~7 % less wire volume.

**The last two rows of that table are a warning about reading any single row.** MoQ moves ~7 % fewer
bytes and today those bytes cost five to ten times as much, so the axis it wins is worth a rounding
error against the axis it loses. Every margin in the table has to be weighed in the units the decision
is actually made in.

**What separates them is not the part that costs the most to build; it is how much that part has to
absorb.** Because the deliverable is a clean paced TS at a demarcation the distributor owns, the
grooming and egress layer is required, owned and unsolved off the shelf on both sides (§4). Choosing
segmented HTTP shortens the transport project, does not shorten the broadcast-grade one, and makes the
groomer's job substantially harder: ~240× coarser bursts and silences measured in seconds rather than
milliseconds (§4.3).

**And the part that matters more than the verdict.** Every item on the list of things that make
either data plane *broadcast-grade* is common to both: PCR and CBR grooming to TR 101 290, 1+1
with byte-identical legs and receiver-side selection, ST 2022-7 pairing, entitlement and
multi-tenant control, observability in broadcast terms, and interop with the MPEG-TS installed
base. Neither specification addresses any of it. That is why this paper is framed as an
evaluation of Internet-native primary distribution on two candidate data planes rather than as a
case for one protocol, and why the measured work in [lab](../lab/README.md) — nearly all of which
sits above the transport — transfers between them.

**Four rows of that table rest on measurement rather than argument.**
[T14](../lab/test-14-data-plane-comparison.md) runs both data planes from the same source through the
same instrument on one route, and settles these:

- **Burst granularity**, which moved the hand-off axis: ~240× coarser bursts and 24 multi-second
  silences against none (§4.3).
- **Carriage fidelity for one programme**, which moved the row to a wash: byte-verbatim except the
  PAT/PMT continuity counter (§8).
- **Wire cost**, which lands where the estimate said but for a different reason: 1.0006× source TS
  bytes at the HTTP layer, so 1.056× on the wire over HTTP/3 against MoQ's 0.982×.
  [economics](economics.md) §4.7 estimated ~1.05× on the premise that the packager strips stuffing;
  the number holds and the premise does not. HTTP's own overhead is 0.06 % of payload, and HTTP/3
  costs ~2.6 points more than HTTP/2 on TCP.
- **The low-latency arm**, which divides cleanly into publish and receive: partial segments carrying
  MPEG-TS can be published free of charge and correctly, and **no freely available client will fetch
  them**, so the burst gap barely moves (~240× → ~185×) and the latency floor does not move at all.

What remains, blocked on ABR-to-TS hardware or a CDN account, is in
[lab/planned-experiments.md](../lab/planned-experiments.md). The most consequential is still whether a
commercial ABR-to-TS gateway passes P1/P2 as the distributor's own edge stage, since every vendor claim
in §4.4 is a datasheet claim. The low-latency measurement makes that question sharper still, since such
a box is the *only* candidate receiver for a low-latency TS-in-HLS route.

**The toolchain gap is real but it is not evenly spread, and where it sits is the whole point.** The
specification permits TS partial segments and the low-latency ecosystem standardised on CMAF/fMP4
regardless — TSDuck implements no `EXT-X-PART` and cannot even parse a parts-only playlist, FFmpeg's
demuxer exposes no way to fetch parts, Shaka's low-latency path is CMAF and discards the TS carriage.
Apple's macOS-only tools fill the **publish** stage completely and for free. Nothing fills the
**receive** stage, which is the distributor's own side of the demarcation (§4.1) and precisely what
Synamedia's MEG and Ateme's TITAN Edge are sold to do. So the practical envelope for TS-in-HLS on free
software is nearer 6 s than the 2–5 s §5 states; the latency axis widens rather than narrows; and the
grooming burden and the latency floor still cannot be paid down separately, because both are segment
size and the parts that would shrink both are unreachable.

---

## 13. Open questions

- Does a commercial ABR-to-TS gateway, operated as the distributor's own edge stage, produce
  TR 101 290 P1/P2-conformant output on real hardware? If yes, part of the broadcast-grade layer is
  purchasable on one data plane and not the other; if no, the reassembly advantage in §4.2 is all that
  is left of the hand-off axis.
- **Would a receiver that actually fetches partial segments close the grooming gap?** How much of
  the burden is inherent to the segment model and how much is merely classic segment sizes cannot be
  settled on free software: parts publish correctly and no free client fetches them, so the gap
  closes only from ~240× to ~185× and that residue is segment duration, not parts (§4.3). What
  remains open is whether a commercial
  ABR-to-TS gateway, which is the only thing that *does* fetch parts, brings the burden down to
  something a millisecond-scale groomer could absorb. That collapses into the first question above:
  the same box decides both.
- Should the edge gateway sit at each client's demarcation or in the distributor's regional PoPs?
  The choice sets how many destinations the Internet-native transport actually serves, and therefore
  most of the delivery bill, on both data planes (§4.5).
- Can a CDN carry a multi-programme TS segment in practice, and does anything downstream of the
  cache object to it? This now decides the whole of MoQ's carriage-fidelity advantage rather than part
  of it, since single-programme carriage measured as a wash (§8).
- Does the sub-second requirement exist on identifiable routes, or is it a preference? §5 makes
  this the deciding axis, so the answer determines how much of primary distribution MoQ addresses
  at all.
- Would relay portability, if achieved, change the economics enough to matter against a delivery
  market that is already commoditised? MoQ's strongest economic argument is contingent on an
  interoperability fix ([evidence](evidence.md) §9), and its prize is a market position segmented
  HTTP already occupies everywhere except the sub-second band.
