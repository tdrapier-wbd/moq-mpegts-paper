# Candidate Data Planes Compared

Status: working draft.
Layer: **the data-plane choice** — this document *is* the layer where the candidates differ.
Scope: the head-to-head this repository owes its own thesis. [Problem](problem.md) §5 states the
requirement set; this document evaluates the candidates against R1–R4 and against the point-to-point
incumbents, on the axes an operator actually decides on. The layer above the transport — where
nearly all the measured work sits, and which is common to both candidates — is
[Architecture](architecture.md).

**The conclusion, first.** For the majority of primary-distribution routes there are *two* viable
Internet-native data planes rather than one. They differ structurally on one axis that could decide
the choice (latency), and **that axis is the one this campaign has not measured end to end on either
plane**. Everything that makes either of them *broadcast-grade* sits above the transport and is
common to both. That is not a retreat from the thesis but a demonstration of it —
[Problem](problem.md) §1 holds that the transport is the least interesting part of the transition.

The comparison that matters is not against the point-to-point incumbents. SRT, Zixi and RIST are the
obvious yardstick and the wrong one to lead with, because a transport that cannot fan out at all sets
a low bar (§10). The demanding alternative is **segmented HTTP carrying MPEG-TS**: it is specified,
universally interoperable, sells over commodity delivery today, and has an off-the-shelf path back to
a transport stream where MoQ has one implementation. Measured on the axes below it is ahead of MoQ on
most of them.

---

## 1. The candidates

| Candidate | What it is here | Class |
|---|---|---|
| **MoQ** | `moq import ts` → relay fabric → `moq export ts`, on QUIC/WebTransport | live publish/subscribe with native relay |
| **Segmented HTTP** | HLS carrying MPEG-TS segments (and DVB-DASH), over HTTP/2 or HTTP/3 | cacheable-object pull over commodity delivery |
| **SRT / Zixi / RIST** | a reliable UDP tunnel per destination, optionally through a gateway tier | point-to-point session transport |

They are grouped by *scaling shape*, not by quality, and the grouping flatters two of them: RIST is
openly specified and multi-vendor where the others are not, and is treated on its own in §10.1.

Two exclusions, so the field is honest.

**TS-over-HTTP/1.1** — a continuous transport stream in a chunked HTTP response — is excluded as a
neutral baseline because there is no agreed specification for it. It is an arrangement of standard
parts implemented incompatibly by several vendors, so choosing it buys a vendor rather than a
protocol, which is a lock-in risk of the same kind as a proprietary receive estate. It has real
strengths — native TS carriage by construction, mature HTTP/TCP infrastructure, proven CDN fan-out —
and where HTTP infrastructure is already in place and latency budgets are relaxed it can be a sound,
low-risk choice. What it cannot be is a *specified* baseline, which is what this comparison needs.

**WebRTC/SFU** is excluded because its media model does not carry an MPEG-TS at all, so the hand-off
problem it creates is a different one.

Segmented HTTP is assessed against [HTTP Live Streaming 2nd
Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
(`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS), and quoted
from it rather than from convention, because practitioner convention diverges from the normative text
in both directions — see §13.

---

## 2. Scaling the distribution (R4)

**At primary-distribution scale, scaling is not the discriminator. Who operates the replication point
is.** The topology is one-to-many but not internet-scale: tens to low hundreds of endpoints
([Problem](problem.md) §1.4). All three candidates handle that without strain, and none of them
breaks the linearity of last-mile delivery — an HTTP edge cache fetches an object once and serves N
receivers over N unicast connections, a MoQ relay receives an object once and serves N subscribers
over N unicast connections, and an SRT gateway holds N sessions. These are the same topology under
different names ([Economics](economics.md) §4.4).

What differs is the *shape* of the replication point and who runs it.

| | Segmented HTTP | MoQ | SRT / Zixi / RIST |
|---|---|---|---|
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, from a dozen suppliers, today | one CDN today, at five to ten times commodity delivery; otherwise you | you, or a managed media service |
| Adding a destination | a cache fill nobody provisions | a subscription and its relay state | a gateway output slot, and sometimes an instance |
| Known hard ceilings | none at this scale | untested beyond our own rig; relay memory grows per ingested group and plateaus softly ([Evidence](evidence.md) §3.6) | AWS MediaConnect: **50 outputs per transport-stream flow, not increasable**; 2 sources per flow |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network | none | none |

Three conclusions follow, and only the first is a differentiator.

**Statelessness is segmented HTTP's real scaling advantage, and it is a reliability advantage in
disguise.** Because a segment is a named resource rather than a position in a session, a destination
can move between edges, regions or suppliers mid-stream with nothing to re-establish, and the origin
never learns that it happened. MoQ and SRT fan-out is stateful, so the replication point is also a
failure domain: losing a relay loses a session, and recovery is a resubscribe. Developed in §3.

**Nobody here does point-to-multipoint at the last mile**, which makes the phrase misleading in all
three columns. Segmented HTTP is the only candidate with a specified multicast profile — DVB-MABR,
deployed commercially by tier-one operators — but it replicates inside an access network the operator
controls, terminating at a gateway in the home or the network edge. That is consumer distribution,
not affiliate distribution. So "MoQ is point-to-multipoint and SRT is point-to-point" is true only in
the sense developed in §10: it describes **where the replication point sits and who owns it**, not IP
multicast.

**Fan-out economises backhaul, not delivery, for every candidate equally.** A regional replication
point collapses N copies of upstream carriage into one, which is worth real money on a backhauled
multiplex and nothing at all on the last mile ([Economics](economics.md) §4.5). This is the advantage
most often cited first for MoQ, and it is not an advantage over segmented HTTP, because a cache does
exactly the same thing.

---

## 3. Reliability (R2)

Two questions hide inside this axis and they have different answers: *how does the transport behave
under loss*, and *how does the system recover when something fails*. The first is a wash. The second
favours segmented HTTP, and it is the more important of the two for a trunk.

### 3.1 Under loss: a wash, once the controller is chosen

MoQ collapses under uniform loss with QUIC's default CUBIC controller and restores full-rate,
byte-complete delivery on par with SRT once the sender is switched to BBR — parity, not superiority,
and a controller choice rather than a protocol property ([Evidence](evidence.md) §3.3).

Low-Latency HLS **requires** HTTP/2 or HTTP/3, so over HTTP/3 it rides the same QUIC substrate with
the same per-stream loss isolation, and the RFC 9218 priority scheme is mandatory there. **There is
no per-packet loss-resilience argument that distinguishes the two.** QUIC is a necessary substrate
for both and distinguishes neither; what distinguishes MoQ is the object and subscription model above
it.

### 3.2 On recovery: segmented HTTP has the more robust model

The specification gives a segment a **defined availability window**: its Availability Duration is the
segment's own duration plus the duration of the longest playlist containing it, a live playlist may
not fall below three times the target duration, and a partial segment must remain downloadable for at
least three target durations after it leaves the playlist. So a failed fetch can be retried — from
the same edge, a different edge, a different Pathway under Content Steering, or a redundant variant
stream — for a specified period, using idempotent requests, without the sender's involvement and
without a session to re-establish.

MoQ's reliability is scoped to a live subscription. Within it, QUIC delivers each object completely
or errors the stream. Outside it, recovery depends on a relay cache that is deliberately shallow —
a recovery buffer, not a time-shift buffer, because for live linear distribution falling far behind is
itself a fault. Failure *detection* is bounded by the QUIC idle timeout rather than being hitless, and
a source that exits cleanly is not failed over at all ([Evidence](evidence.md) §3.4).

**For a trunk, this is the wrong way round for MoQ.** Primary distribution's acceptance test is
byte-completeness at the hand-off with a few seconds of latitude, and segmented HTTP converts that
into cache retry — the most heavily exercised reliability mechanism on the internet — while MoQ
converts it into live session management, which is operationally heavier and the part of the stack
where current implementations are roughest.

Two qualifications keep this honest. The countervailing MoQ property is that it reaches the same
completeness with a much smaller buffer, which is the latency argument in §5 and not a reliability
argument. And **segmented HTTP's recovery model is specification-based here, not measured**: the
grooming run in [Evidence](evidence.md) §3.2 was on a path where nothing was ever missing, only late,
so nothing in this campaign has exercised a segmented-HTTP leg's retry behaviour under real loss.

### 3.3 Where broadcast actually gets its reliability, and why it is common to both

Neither transport's own recovery is what a broadcaster relies on. Reliability comes from **1+1 with
selection at the receiver**, and that is transport-independent. It was measured on MoQ: two
independently groomed legs come out byte-identical for single-track content and the pair rides out
the death of a publisher, a relay or an exporter ([Evidence](evidence.md) §3.4). Segmented HTTP gets
the equivalent from the specification — redundant variant streams, and Content Steering with Pathway
Cloning — and gets it *specified*, which MoQ's `--origin` reselect is not.

So the redundancy layer is common and its design transfers to either data plane unchanged
([Architecture](architecture.md) §5). That is the first of several places where the effort sits above
the transport.

---

## 4. The hand-off (R5)

### 4.1 What the obligation actually is

**The deliverable is a clean, paced MPEG-TS at the hand-off, and it is the distributor's obligation
on either data plane.** This has to be stated before the comparison, because getting it wrong inverts
the answer.

A distributor no longer supplies its clients' receiving equipment ([Problem](problem.md) §1.5). What
survives is the *contract*: a conformant transport stream, correctly paced, at an agreed demarcation,
which the client feeds into whatever it has chosen to run. **So the working assumption is that many
receivers want nothing but a clean TS**, and any argument that leans on the client owning a modern
software-defined receiver is an argument about someone else's estate.

The consequence is that **the grooming stage sits on the distributor's side of the demarcation on
both data planes, and its absence from either specification is the distributor's problem either
way.** The HLS document contains zero occurrences of PCR, constant bit rate, stuffing or null packet;
MoQ has no notion of them either. Both deliver in bursts, and a stream reconstructed from bursts has
timing hardware IRDs reject on TR 101 290 ([Evidence](evidence.md) §3.2).

The comparison is therefore between the two *distributor-side* toolchains, not between what a client
happens to own.

### 4.2 Reassembly: off the shelf for segmented HTTP, single-implementation for MoQ

This is the asymmetry that survives, and it is narrower than a product comparison suggests.

**Segmented HTTP has an off-the-shelf reassembly stage in the toolchain broadcast engineers already
run.** TSDuck's `tsp -I hls` pulls a playlist and emits the transport stream; its `tsp -O hls` does
the reverse, writing TS segments with a PAT and PMT at the start of each. FFmpeg reads a playlist
too. So the "turn this back into a TS" half is a solved, multi-implementation problem.

**For MoQ it is one implementation.** `moq export ts` is the only stage that converts MoQ tracks back
to MPEG-TS, its continuity counters are rendered from process state rather than carried
([Evidence](evidence.md) §3.4), and there is no second implementation to fall back to.

**Against that, MoQ's reassembly is much simpler to write.** It is a subscription plus object
reassembly. A segmented-HTTP gateway carries a manifest state machine — blocking playlist reload,
media-sequence tracking, partial segments and preload hints, rendition reports, discontinuity
handling, availability windows and a retry policy — and must hold at least `PART-HOLD-BACK` of
buffer. Simpler to write and already written are both real advantages; for an operator, already
written usually wins.

### 4.3 Grooming: unsolved off the shelf for both, and measurably harder for segmented HTTP

**Segmented HTTP inherits the grooming problem in full, and it is worse rather than equal — measured,
at two orders of magnitude.** Each transport's ungroomed egress was captured at the same point with
the same instrument ([Evidence](evidence.md) §3.8, §3.9):

| | MoQ | Segmented HTTP (2 s segments) | RIST / SRT *(see below)* |
|---|---|---|---|
| Median burst | 12.4 kB | **2.95 MB** | 30.6 kB — the source's, not the protocol's |
| Bursts in 60 s | 3,078 | 28 | 2,400–2,650 |
| Gaps above 1 s | **none** | **24** | **none** |
| Largest gap | 149 ms | **4.01 s** | **~35 ms** |
| 10 ms peak/mean | 24× | **231×** | 3.4× |

The mechanism is unambiguous: silences arrive at exactly the segment duration, because the client
fetches a completed segment at line rate and then waits for the next to exist. MoQ delivers something
in every second of the window; segmented HTTP alternates between nothing and 20–30 Mb/s.

**One groomer covers both, provided it sizes its buffer from what it observes arriving.** Inserted
into the identical chain, the same binary with no flag changed takes the segmented-HTTP egress to the
same conformance the MoQ lane was graded to ([Evidence](evidence.md) §3.2). What it costs is
7.5 s of programme held before the first byte, a 13.1 MB buffer and ~9 s to notice a dead origin.

The third column is the point-to-point class, and it is a different kind of entry in two ways. RIST
and SRT are **transparent** — measured identical to a plain-UDP control — so the 30.6 kB is what this
campaign's software publisher produced and not a property of either protocol. And it is taken at a
*finer* publisher setting than the first two columns; MoQ was re-run at both settings and does not
move (12.2 kB against 12.4 kB), and segmented HTTP's burst is segment-sized regardless, so only the
third column depends on the source. That is the finding.

**The two rankings disagree, and a hand-off claim has to say which one it means: MoQ hands over the
smallest bursts, the tunnels the shortest silences.** Buffer depth follows the former; a groomer's
start gate and underrun threshold follow the latter.

**The consequence is a single knob; it is the same knob as latency; and it is measurably stuck.**
Burst size is segment size, so reducing the grooming burden means reducing segment size, which is
identical to the action that reduces latency, and it terminates in partial segments. That escape
route has been tested and is closed: partial segments carrying MPEG-TS **can** be published, free,
with Apple's tools — and **no freely available client fetches them**, so the egress a groomer
actually sees is the classic one. Measured, the median burst falls only from 2.95 MB to 2.27 MB, and
that reduction is explained by segment duration rather than by parts ([Evidence](evidence.md) §3.9).

**What is not in doubt is that off-the-shelf tools do not do all of it.** Every candidate an engineer
would reach for was graded against four criteria fixed in advance — mux preserved, PCR inside 481 ns,
no interval above 40 ms, honest duration on a rate-controlled wire — and each fails a different one.
TSDuck cannot restore stuffing at all, because `tsp` can overwrite existing null packets but cannot
inflate a stream. FFmpeg's `-muxrate` produces the best PCR arithmetic measured and, on its own
socket, an unusable wire; it retypes all three SCTE-35 PIDs and relabels AC-3. GStreamer's
`mpegtsmux` loses every PSI table beyond PAT and PMT, the PMT's own PID, the teletext descriptor and
two of three splice PIDs ([Evidence](evidence.md) §3.2).

**None of those failures is about MoQ** — they are properties of the tools, so they apply identically
to a stream reassembled from HLS segments. A groomer that preserves a broadcast mux is required on
both paths.

### 4.4 What the IRD vendors' HLS inputs are, and are not

Professional edge-gateway and IRD platforms do list HLS, DASH and TS-over-HTTP inputs with ABR-to-TS
conversion alongside RF, ASI, SRT, RIST and Zixi — Ateme's TITAN Edge lists an HLS and a DASH
receiver among its inputs, Synamedia's Media Edge Gateway lists "TS over HTTP, HLS, and DASH with
ABR2TS conversion" for affiliate and MVPD hand-off, both with ST 2022-7 failover and SDI / ST 2110
out. **Every claim in this subsection is a vendor datasheet claim. Nothing here has been measured.**

- **It is not a reason to assume the problem is solved**, because it is the client's box. Across a
  real estate the assumption fails at most sites, and where it holds it is the client's decision to
  reverse.
- **It is a supply-chain option on the distributor's own side.** The same class of product can be
  bought and operated as the distributor's *own* edge gateway. That is a genuine advantage over MoQ,
  where the equivalent does not exist at any price — but it is an advantage in *procuring* the egress
  stage, not in offloading it.
- **It is unmeasured.** Whether such a stage's output passes TR 101 290 P1/P2 on a real analyser is
  exactly the question this repository holds open for its own groomer, and it should be assumed of
  nobody's product until measured. This is the first open cell in
  [planned-experiments](../lab/planned-experiments.md).

### 4.5 Where the demarcation puts the gateway

Because the gateway is the distributor's, its *placement* is a decision rather than a given, and it
moves the fan-out arithmetic. Place it at each client's demarcation and the Internet-native transport
runs to as many destinations as there are clients. Place it in regional PoPs and it runs to as many
destinations as there are PoPs, with the client-facing hop becoming a short TS-over-IP delivery on
local transit — which is the configuration that most reduces the delivery bill, for the same reason a
relay economises backhaul rather than delivery ([Economics](economics.md) §4.5).

[Architecture](architecture.md) §4.4 prefers placement at the hand-off location on timing-determinism
grounds and records that its cost side has not been modelled against the PoP alternative. **That is
an open architectural decision, not a settled one**, and neither data plane is favoured by it.

### 4.6 The honest verdict on this axis

**It splits, and on the half that decides whether a hardware IRD locks, MoQ wins.** Two separate
claims were being run together under "hand-off":

- **Receiving** — turning the delivery back into a transport stream — favours segmented HTTP. Off the
  shelf on one side, single-implementation on the other, and an ABR-to-TS box is purchasable as the
  distributor's own edge stage where no MoQ equivalent exists at any price. Whether that box
  discharges the obligation to broadcast conformance is unmeasured (§4.4).
- **Handing off cleanly** — presenting a paced, conformant stream at the demarcation — favours MoQ,
  measurably: the same groomer has ~240× coarser bursts and 24 multi-second silences to absorb on the
  segmented-HTTP side (§4.3). Off-the-shelf tools do it on neither.

Since it is the second that the installed base actually requires, the axis no longer favours
segmented HTTP overall. **"Easier to receive" and "easier to hand off cleanly" are different claims,
and it is easy to run them together.**

This supports the repository's central position rather than undermining it. Because the obligation to
hand off a clean paced TS does not transfer to the client on either data plane, that layer is
required and owned on both — and it is now demonstrably *one* layer rather than two, since the same
groomer reaches the same conformance behind either plane.

---

## 5. Latency (R1)

**This is the axis on which the two data planes differ most in structure, and it is the axis on which
neither has been measured end to end.** Both halves of that sentence are load-bearing, and the second
is stated first because earlier versions of this comparison reported the first as though it were the
second.

**Segmented HTTP's floor is arithmetic, not implementation quality.** `PART-HOLD-BACK` MUST be at
least twice, and SHOULD be at least three times, the part target duration, and part targets in
production sit around 200–330 ms — so the hold-back alone is roughly 0.6–1 s before encode,
packaging, delivery and the gateway's own de-jitter buffer are counted. The specification is explicit
that the trade is not free: a shorter target duration "reduces latency but also reduces available
buffer, handicaps adaption and increases delivery overhead, increasing the likelihood of playback
stall." Two to five seconds end to end is the realistic envelope, and pushing below two seconds makes
the chain fragile in a specific way — an encoder hiccup longer than the part target breaks the
blocking playlist reload, which degrades silently into polling.

**With MPEG-TS the free-tooling floor is measured, and it is nearer six seconds.** Partial segments
carrying MPEG-TS publish correctly and free of charge with Apple's macOS-only tools, and neither
freely available client that can turn HLS back into a transport stream fetches them — measured
against a fully conformant origin, zero parts and zero blocking reloads from both, while Apple's own
validator fetched 17–21 parts over the same origins ([Evidence](evidence.md) §3.9). An operator
unwilling to buy an ABR-to-TS receiver gets classic HLS whatever the publisher emits.

**MoQ's floor is structural; its delivery cadence is measured; its end-to-end latency is not.** The
transport delivers objects with a median burst of 12.4 kB and a worst-case inter-burst gap of 149 ms,
and neither figure moves when the source is made four times finer ([Evidence](evidence.md) §3.8).
That is consistent with a sub-second transport and is not a measurement of one. **No glass-to-glass
latency figure exists for either data plane anywhere in this campaign**: it is recorded as owed in
[T8](../lab/test-8-srt-vs-moq.md) and as unmeasured in
[T14](../lab/test-14-data-plane-comparison.md), and [Evidence](evidence.md) has no latency result.
So MoQ's sub-second capability is a property of the protocol's construction and of its measured
delivery granularity — not a result, and it should not be cited as one.

**And the edge stage's contribution is unmeasured on MoQ and large on segmented HTTP.** The groomer
that satisfies R5 held **7.5 s of programme before emitting a byte** on the segmented plane
([Evidence](evidence.md) §3.2). On MoQ the equivalent depth has never been established, for the
reason in §5.1.

### 5.1 The open coupling between latency and PCR conformance

This is the most consequential unresolved question in the repository, and it was not visible until
the grooming work on both planes could be read together.

**Grooming buys PCR-repetition conformance with buffer depth, and buffer depth is latency.** Two
points are measured and they are on different data planes:

| Groomer cushion | Data plane | PCR intervals > 40 ms, on the wire |
|---|---|---|
| Shallow (the depths the MoQ lane runs) | MoQ | **131** in 25 s on one host, **159** on another, 227 ms maximum |
| 8 s (derived from arrival) | Segmented HTTP | **0** |

The campaign's own explanation is general, not specific to one plane: *"what constrains PCR placement
is not live operation but whether the stage always has a packet ready at the deadline — which is what
buffer depth buys"* ([T16](../lab/test-16-grooming-segmented-http.md)). If that holds on MoQ, then
delivering TR 101 290 P1-conformant PCR repetition **on the wire** costs seconds of buffer on both
planes. On segmented HTTP that cost is already sunk in the segment duration. On MoQ it would be spent
out of the only axis on which MoQ leads.

**The curve between those two points has not been measured on the MoQ lane.** Until it is, the
defensible statement is:

> MoQ's transport is structurally capable of sub-second delivery and its measured delivery
> granularity is consistent with that. Whether a MoQ chain can be simultaneously sub-second
> end-to-end **and** TR 101 290 P1-conformant on the wire is **unmeasured and open**, and it is the
> single measurement that would most change this comparison.

The protocol for closing it is in [planned-experiments](../lab/planned-experiments.md) — a cushion
sweep on the existing rig, using the existing instrument and grading script. It is the cheapest
outstanding measurement in the campaign and the one with the highest leverage.

### 5.2 The decision rule, restated

**If the route's destinations can absorb seconds — in practice nearer six unless a commercial
ABR-to-TS receiver is bought — segmented HTTP is the better engineering choice today** on the balance
of the remaining axes: decisively so on interop, maturity and delivery economics, narrowly on the
hand-off, against narrower MoQ advantages on entitlement and multi-programme carriage.

**If they cannot, MoQ is the only Internet-native candidate with commodity delivery in prospect** —
subject to §5.1, which is the open question of whether MoQ's structural advantage survives its own
edge stage.

Note what the rule does *not* decide: the grooming and egress layer is built either way (§4).

And note the question behind the rule, which [Problem](problem.md) §6 lists as a condition of the
thesis: **does the sub-second requirement exist on identifiable routes, or is it a preference?** The
usual answer — "sub-second desirable, a few seconds tolerable" — is true of the *feed's own
integrity* and understates the transition. Replacing a geostationary path with a 2–5 s one consumes
most of a downstream budget that was previously free, at every destination, and the consequences are
operational rather than technical: regional splice and blackout timing, relative alignment between
affiliates served by different paths during a mixed-estate migration, live handback, and any
destination that re-distributes and adds its own budget. None of that is a transport defect. It is a
reason "seconds are tolerable" has to be answered per route by the destination, not asserted once in
a requirements list.

---

## 6. Interoperability (R3)

Segmented HTTP wins this decisively, and the reason is worth stating precisely, because the summary
version flatters both sides.

**On the delivery path, segmented HTTP has no interop problem because it has no transport to
interoperate.** It is HTTP; every CDN, proxy and cache moves the bytes without parsing them. MoQ's
delivery path is a relay, which is a protocol implementation, and measured against all eight other
registered public relays a MoQ feed carries no media at all ([Evidence](evidence.md) §3.7). On the
acceptance criterion this repository set for itself — does a stream published into somebody else's
infrastructure arrive intact — segmented HTTP passes today and MoQ does not.

The standards status is inverted relative to the outcome: HLS states plainly that it "is not an
Internet standard" and interoperates everywhere; MoQ is genuinely standards-track and interoperates
within one implementation. **Standards-track status is a prediction about interop; this is the
evidence that the prediction and the property are different things.**

**But segmented HTTP's interop and its ability to carry a contribution mux are mutually exclusive.**
The specification is normative: "Transport Stream Segments MUST contain a single MPEG-2 Program;
playback of Multi-Program Transport Streams is not defined." A CDN does not parse the payload, so an
MPTS placed in TS segments *will* be delivered — but no conformant client, packager or analyser is
required to handle it, and the moment you rely on that you are running a private profile over public
infrastructure. So the honest form of the interop advantage is: **segmented HTTP interoperates
universally as long as you stay inside the single-programme envelope, and the moment you leave it you
keep the delivery-path interop and lose all the rest.**

The service layer is a second, smaller residual on the same side. A TS segment's initialisation state
is defined as a PAT followed by a PMT; SDT, NIT, EIT, TDT and TOT appear nowhere in the
specification. Nothing forbids extra PIDs riding along and nothing requires or preserves them — so
"TS in HLS guarantees the DVB components" is true of PIDs, PES, `stream_type` and PAT/PMT and untrue
of the service layer. That is the same residual the media-aware MoQ lane has, reached by a different
route, except that the MoQ lane has a catalog through which the service layer *can* be threaded — and
now is ([Evidence](evidence.md) §3.1) — where a segment has nothing.

Two ecosystem asymmetries complete the picture and both favour segmented HTTP. Ad signalling has a
specified out-of-band representation — the mapping of SCTE-35 `splice_info_section()` into
`EXT-X-DATERANGE` — so it does not depend on an in-band PID surviving transit, which is exactly what
the off-the-shelf grooming candidates were measured damaging. And monitoring exists: manifest and
segment probes, CMCD/CMSD, and the analyser estate, against MoQ's thin observability.

---

## 7. Entitlement and access control (R7)

**MoQ's advantage here is real but narrow, and it is not about revocation latency.**

The intuitive case is that MoQ carries authorization at the point of subscription and can refuse or
drop it there, while segmented HTTP's entitlement is an external bolt-on with revocation bounded by
token lifetime. The second half does not survive contact with how Low-Latency HLS actually behaves.
The platform design revokes by two paths — a fast path that drops the subscription, and a backstop of
short token lifetimes that revokes by declining to refresh ([Control](control-plane.md) §4).
**Segmented HTTP has the backstop natively and lacks only the fast path**, and its backstop is tight
rather than loose: every request is authorized at the edge by signed URL, signed cookie or a CDN
token scheme, and a low-latency client re-fetches the playlist roughly every part target duration.
The worst-case revocation bound is therefore about one request interval — sub-second to a couple of
seconds — which is not materially worse than dropping a subscription.

What genuinely differs is **where enforcement lives and whether the session is observable**.

- With segmented HTTP the enforcement point is the CDN, so the entitlement model is whatever that
  supplier's token machinery supports, configured per supplier, and it is not your code. With
  multiple suppliers it is configured more than once, differently.
- With MoQ the relay is the enforcement point, so if you operate the relay the policy is yours and
  portable across it. If you do not operate it, this advantage transfers to whoever does.
- A subscription is a **live, queryable fact**: which endpoint is receiving what, right now, is a
  state the relay holds. With segmented HTTP it is inferred from delivery logs. For per-tenant
  accounting and for "is this affiliate actually receiving", this is the substantive difference.
- Revoking access to content already in an edge cache is a cache-invalidation problem in one model
  and a non-problem in the other.

So the defensible claim is that MoQ gives entitlement a native, portable place to live and makes the
session observable — not that it revokes faster. **This is an architectural reading of the protocol,
not a measurement**; what has been verified is that the authorization hook exists and is enforced at
subscription ([Evidence](evidence.md) §3.10).

---

## 8. Carriage fidelity (R3)

| | Segmented HTTP | MoQ media-aware lane | MoQ opaque lane |
|---|---|---|---|
| Multi-programme mux | **normatively excluded** (§6) | one programme, reconstructed | **verbatim MPTS** |
| PIDs, PES, `stream_type`, PAT/PMT | preserved | preserved | preserved |
| SDT / NIT | **preserved** — measured | preserved ([Evidence](evidence.md) §3.1) | preserved |
| EIT | **preserved** — measured | preserved on an open upstream PR, schedule included | preserved |
| TDT / TOT | **preserved** — measured | **not carried, by design; nothing regenerates it** | preserved |
| Continuity counters | **preserved except a forced re-stamp on PAT/PMT** | regenerated by the exporter | preserved |
| Null stuffing | **carried** — measured | not carried | carried if verbatim |
| Byte-identical to source | **yes, except byte 3 of PAT/PMT** | no | yes |

**For a single programme, segmented HTTP carrying MPEG-TS is as verbatim as the opaque MoQ lane,
which is the opposite of what the specification's wording suggests.** The reasoning that a segment
"must begin with PAT then PMT" and is therefore a re-mux does not hold: prepending a PAT/PMT pair does
not rebuild the multiplex, it inserts two packets and renumbers the continuity counters of those two
PIDs. Measured against the source packet by packet, the only difference in a 1,200-packet window is
byte 3 — the continuity counter — on one PAT and one PMT ([Evidence](evidence.md) §3.8).

**What survives of MoQ's advantage on this axis is the multi-programme case alone**, where HLS's
"Transport Stream Segments MUST contain a single MPEG-2 Program" bites. That is normative rather than
demonstrated, it is an open measurement, and it now carries the whole row. Against the *media-aware*
lane, segmented HTTP is straightforwardly better: it keeps stuffing, continuity counters and the wall
clock that the exporter does not.

**Fidelity is not free, and §9 prices it at ~7 % of the wire.** Carrying the stuffing and every TS
packet header is what makes segmented HTTP verbatim *and* what makes it 1.056× the source TS rate
against the media-aware lane's 0.982×. The same is true of the opaque lane, whose cost is still
unmeasured but derives to near SRT's 1.037× if it is truly verbatim — so on this axis the choice is
not between data planes but **between fidelity and bandwidth, and it is the same choice on both.**

---

## 9. Economics

Fully modelled in [Economics](economics.md); the comparison reduces to three facts.

**The wire favours MoQ by ~7 %, and that is §8's fidelity trade priced rather than a separate axis.**
MoQ's media-aware lane measures **0.982×** the source TS rate and SRT **1.037×** on a real path;
segmented HTTP over HTTP/3 comes to **1.056×**, its HTTP layer measured at 1.0006× and per-packet
framing taken from the same real-path measurement, so that figure is derived rather than measured end
to end ([Evidence](evidence.md) §3.5).

- **Only declining to be verbatim gets a data plane below 1.0×.** Every verbatim candidate sits at
  1.03–1.06× whatever its framing; MoQ's lane is cheaper because it carries neither this clip's
  4.57 % null stuffing nor the 4-byte header on each surviving TS packet. So §8's fidelity wash and
  this 7 % are the same fact.
- **The obvious rejoinder — that a TS packager has no reason to retain stuffing either — fails twice
  over**: the off-the-shelf packager does retain it, and one that stripped it would stop producing
  byte-verbatim segments and forfeit the §8 advantage.
- **HTTP costs nothing to speak of.** Response headers and playlist re-fetching total 0.06 % of
  payload at 2.4 s segments. **HTTP/3 is the more expensive substrate by ~2.6 points** than HTTP/2 on
  TCP, since QUIC's minimum 1200 B datagram charges 5.5 % framing against 2.7 %.

The margin travels with the source's stuffing ratio — an unstuffed mux narrows it to ~2.5 points —
and single-digit percentages remain the wrong basis for choosing a transport in either direction.

**Destination count decides the bill, not the transport.** Unicast cost is linear in destinations for
every candidate here, and the choice among transports moves the model by single digits while
destination count moves it by three orders of magnitude ([Economics](economics.md) §4.4).

**The market the delivery is bought in decides the level, and this is where segmented HTTP is ahead
by an order of magnitude today.** Commodity CDN delivery lists at $0.005–0.010/GB against roughly
$0.09/GB of metered cloud egress; the one CDN that sells MoQ relay prices it at $0.050/GB. So
segmented HTTP is the only candidate whose delivery can be bought in the commoditised market right
now, which is the position [Economics](economics.md) §4.6 argues MoQ *could* reach.

---

## 10. SRT and RIST: scaling is possible, and that is not the differentiator

A vendor's challenge, and it is correct: **SRT can be scaled.** The mechanism is a re-origination or
gateway tier — each hop remains a point-to-point session, and fan-out comes from running N sessions
out of a replication point. Replicating a relay architecture with SRT as a DIY platform is entirely
feasible, and for an operator with the network to put it on it can be the cheapest option per byte on
the whole ladder ([Economics](economics.md) §4.3).

**What is unavailable is a commodity market for it, and the shape of that absence is specific.** CDNs
do support SRT — at the *door*. SRT is the standard contribution ingest into a CDN's packaging tier,
after which fan-out to the audience happens as segmented HTTP. No CDN sells SRT *to the destination*.
So an SRT trunk to N professional endpoints resolves to one of three cost bases, and choosing among
them is the actual engineering decision: own transit and PoPs (cheapest per byte, bounded by reach);
a gateway fleet in a hyperscaler (easiest, structurally most expensive); or a managed media service
with premium per-flow pricing and structural quotas ([Economics](economics.md) §4.6).

**So the SRT-versus-MoQ difference is not that SRT cannot fan out. It is who operates the replication
point and which market prices it.** SRT has no object model and no native relay primitive, so its
replication point is a stateful media gateway per stream per destination — a media-server business
rather than a delivery business, which is why the commodity delivery market has nothing to sell there.

That argument has a consequence that is easy to miss: **the advantage MoQ claims over SRT is exactly
the advantage segmented HTTP already has.** Being shaped like something a delivery market can sell is
not a MoQ property; it is a property of anything cache-shaped, and segmented HTTP has been
cache-shaped and commoditised for over a decade. So the market-structure argument narrows to a
precise claim: *the sub-second band has no commodity supplier, and MoQ is the only candidate whose
architecture could give it one.*

Zixi sits in the same class as SRT for this purpose, and additionally carries a per-GB licence on top
of every rate, so a proprietary protocol commoditises only as far as its licensor permits.

### 10.1 RIST, which deserves better than being listed alongside SRT

Grouping RIST with SRT and Zixi undersells it. On the axes this comparison cares about it is the
**strongest of the point-to-point transports**, and on one axis it is plausibly stronger than either
candidate data plane. It fails the primary-distribution test for one reason only, and it is a reason
about markets rather than engineering.

**Where RIST is genuinely ahead.**

- **It is an open specification with real multi-vendor implementation** — VSF TR-06 (Simple, Main and
  Advanced profiles), developed in the Video Services Forum and exercised at interop plugfests. Set
  against §6: HLS interoperates universally but is an Apple-authored informational document with a
  closed authoritative implementation; MoQ is standards-track but carries media within a single
  implementation. **RIST is the only one of the four that is both openly specified and demonstrably
  multi-vendor.** For a broadcaster procuring against a 5–10 year horizon that is not a small thing,
  and it is the axis on which MoQ is weakest.
- **It is RTP-native**, so it lands on infrastructure the installed base already speaks, and Simple
  Profile is compatible with SMPTE 2022-1 FEC. Main Profile adds DTLS or PSK encryption, tunnelling,
  multiplexing and in-band control.
- **Its hand-off leads the four on worst-case silence — tied with SRT — and is mid-table on burst
  size.** RIST is a packet-level tunnel with a jitter buffer and hybrid ARQ/FEC, so it reconstructs
  the *original* packet cadence, delayed. Measured, that is exactly what it does — identical to a
  no-transport control on burst size, at two source granularities, and so is SRT. The consequence is
  not the one the mechanism suggests: a transparent transport hands on whatever it was given, whereas
  MoQ *re-paces*, so from the same publisher RIST hands a groomer 30.6 kB where MoQ hands it 12.2 kB.
  Where RIST leads is the longest silence, which is what sizes a groomer's start gate and underrun
  threshold: **~35 ms against MoQ's 149 ms and segmented HTTP's 4.01 s.** Two caveats in RIST's
  favour: transparency means a true CBR hardware source would come through smoother than this
  campaign's software publisher, and libRIST's opt-in `cbr-output` paces the receiver's own egress
  down to a 1.3 kB median — the finest measured anywhere here, though it is not grooming: no PCR
  re-stamp, no padding to a nominal rate, no accuracy guarantee.
- **Dual-path seamless protection is native**, rather than the 1+1 construction §4 has to assemble.

**Where it fails, and it is the same failure as SRT.** Fan-out is N sessions from a replication point
the operator runs. RIST's efficient multi-destination story is **multicast**, and it is a good one —
but multicast is a property of a managed network, and the public internet is not one. **The scaling
limit is not a deficiency in RIST; it is that RIST was designed for a different network than the one
primary distribution now has to cross.**

**The honest summary is uncomfortable for the thesis.** For a distributor serving *tens* of
destinations over owned transit or a managed network — which is a great deal of real primary
distribution — RIST is likely the best-engineered choice available today, and better than either
candidate here on openness, worst-case delivery silence and installed-base fit. What it cannot do is
follow commodity delivery pricing to hundreds of destinations over the public internet. The case for
an Internet-native data plane is therefore a case about **reach and cost at scale**, not about RIST
being deficient.

---

## 11. The toolchain: what is free, and the one stage that is not

Both data planes decompose the same way, so the useful view is stage by stage. Two things fall out:
most stages are common, and where the two differ, **they are incomplete in opposite places.**

| Stage | MoQ | Segmented HTTP | Owned by |
|---|---|---|---|
| **Ingest** | SRT / RTP / file — TSDuck `tsp` | identical | distributor |
| **Publish / package** | `moq import ts` (media-aware) or the opaque `m2ts` lane under MSFTS | *classic:* `tsp -O hls`<br>*low-latency TS:* Apple `mediastreamsegmenter --format=transport` | distributor |
| **Fan-out** | `moq-relay`; Cloudflare's implementation | any HTTP origin + cache, or a commodity CDN | distributor or CDN |
| **Receive → TS** | `moq export ts` | *classic:* `tsp -I hls`, FFmpeg<br>*low-latency:* **nothing free exists** | recipient or distributor |
| **Groom → conformant CBR** | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) | **the same binary, no flags changed** — it sizes its buffer to seconds rather than milliseconds from the arrival it observes ([Evidence](evidence.md) §3.2) | **distributor, on both** |
| **Egress FEC / ST 2022-7 / start gate** | private | private; identical requirement | **distributor, on both** |
| **Analysis / conformance** | TSDuck, hardware TR 101 290 analyser | identical | distributor |
| **Control plane** | provisioning, entitlement, observability | identical model, different projection target (§7) | distributor |

The bottom four rows are the same on both, which is this repository's thesis expressed as a bill of
materials: **the parts an operator has to build or buy do not change with the transport, and the
parts that change with the transport are the ones already written.**

**Every stage has a free implementation except one: receiving low-latency HLS back into a transport
stream.** Publishing it is free and works first time; receiving it has no free implementation at all
(§5, [Evidence](evidence.md) §3.9). So the free toolchain is **asymmetric**, and the missing half is
precisely what the commercial products sell:

| Want | Free option | Commercial option |
|---|---|---|
| Classic HLS → TS, ~6 s latency | `tsp -I hls`, FFmpeg | any professional IRD with an HLS input |
| **Low-latency HLS → TS, ~2 s** | **none** | Synamedia MEG (ABR2TS), Ateme TITAN Edge |
| MoQ → TS | `moq export ts` | **none** |
| TS → CBR, PCR re-stamped, **mux preserved** | `mpegts-pacer` | Synamedia, Ateme, Harmonic gateways |
| CBR TS → paced wire | [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts), `mpegts-pacer` | the same gateways |

The last two rows are worth separating, because they are usually sold together and are not the same
problem. **Pacing a constant-rate stream onto a socket is small, self-contained and solved off the
shelf**: 366 lines of C11 that rewrite nothing produce a tighter wire than anything else graded
([Evidence](evidence.md) §3.2). **Rewriting a mux to be constant-rate — adding stuffing and
re-placing PCR *without* renumbering PIDs or retyping SCTE-35 — is the half that remains a single
free implementation**, and it is the half that decides whether a broadcast mux survives.

**So the two data planes are incomplete in mirror-image ways.** Segmented HTTP has mature commercial
receivers and no free low-latency one; MoQ has a free receiver and no commercial one, and carries
media in only a single implementation. Neither offers a complete free path to a low-latency,
IRD-conformant hand-off today.

**The narrowness of the gap is what makes it worth pinning.** A free low-latency HLS receiver needs
`EXT-X-PART` parsing and blocking playlist reload in front of a TS demuxer that already exists — a
few hundred lines, not a new stack — and everything downstream of it is already public. Extending
TSDuck's `hls` input plugin is the strongest route: it already fetches playlists, already emits TS
into a `tsp` chain, and already has everything except partial-segment support. That work is tracked
in [planned-experiments](../lab/planned-experiments.md).

---

## 12. The MoQ implementation landscape

"MPEG-TS over MoQ" is no longer a single-implementation question: there is a dedicated
MPEG-TS-over-MoQ effort with an adopted working-group format, a second independent publisher, and a
production relay from a major CDN. *This section is assessed from repositories, drafts and public
documentation. The measured cross-implementation result is in [Evidence](evidence.md) §3.7.*

| | `moq-dev` | `moq2ts` / `moqxr` | Cloudflare `moq-rs` | This work |
|---|---|---|---|---|
| Lane | media-aware (+ opaque prototype) | **transparent TS** | none — transport only | **transparent TS** + grooming |
| Scope | publisher, relay, subscriber | **publisher only** | protocol library, **relay**, sample clients | publisher + egress + pacer |
| Media format | `hang` catalog/container | MSF + MSFTS (`packaging: "m2ts"`) | **deliberately none** | verbatim TS |
| Format standing | no IETF draft | **adopted WG format** + individual draft | N/A | internal |
| Wire versions | moq-lite 03–06, **MOQT 14–19** | MOQT 16, 18 | MOQT 14, 16 and 18 | inherits `moq-dev` |
| Source failover | route reselection via `--origin` | N/A (publisher) | **none — publisher loss is terminal** | relies on `moq-dev` |
| Deployment | self-hosted | self-hosted | **managed, provisioned by API** | self-hosted |

Four structural facts matter more than any individual feature.

**No one else does the broadcast-specific layer.** `moq2ts` is publisher-only; Cloudflare is
transport-and-relay only. Neither carries PCR-accurate egress, CBR grooming, TR 101 290 conformance
or IRD-facing output. The layer this repository argues is the hard part remains unclaimed, which is
evidence for the thesis rather than against it.

**Transparent carriage is no longer a single-vendor idea.** With an adopted working-group format
(MSF) and more than one implementer, the profile question moves from "will anyone else do this?" to
"will it be adopted widely enough?".

**Transparent does not automatically mean verbatim.** `moq2ts` strips nulls just as the media-aware
lane does, so it also needs downstream re-pacing to restore CBR and cannot be assumed to hold a
conformant bitrate on its own. Being SPTS-out-of-MPTS, it does not answer the multi-programme
question either. Where it is ahead is **standards posture**, and its `.timeline` side track mapping
media time to wall clock is a cleaner answer to timing correlation than anything in this
architecture.

**A format-blind transport is the right split for primary distribution, and the cost is real.**
Cloudflare's `moq-transport` is deliberately media-agnostic: it carries namespaces, tracks, groups
and objects with no catalog opinion. That lets any streaming format ride it, lets the transport
standardise on its own timeline, and keeps relays simple — a relay that cannot misinterpret the
payload cannot corrupt it, which is exactly what a transparent TS lane wants. The counter-argument is
equally real: a relay that understands the media can prioritise tracks and drop non-keyframe groups
first under pressure, so a format-blind relay thins less intelligently. For contribution-grade
carriage the trade is the right way round — broadcast semantics cannot be expressed in a generic
catalog anyway — and the cost is that relay-side graceful degradation is forgone.

One further detail matters for redundancy design: Cloudflare's relay documents that **if the
publisher disconnects, subscribers receive an error and do not recover, even if a new publisher
reuses the path**. There is no source takeover. The route reselection tested here is a `moq-dev`
capability, not a property of MoQ relays generally, so **any 1+1 design that assumes relay-side
source failover is implementation-locked** — which strengthens the case for receiver-side
dual-subscribe as the primary redundancy mechanism ([Architecture](architecture.md) §5).

---

## 13. Six corrections the comparison forced

Each of the six below is a plausible claim, each was load-bearing here, and each turned out to be
false. They are recorded together because the *way* each failed generalises to other transport
comparisons. Two fail in the direction that flatters MoQ, two in the direction that flatters the
alternative, the fifth in both directions at once, and the sixth in favour of a transport that is in
neither camp.

- **"HLS carrying TS is a new capability."** It is the opposite: MPEG-TS was HLS's original container
  and, until fragmented MP4 arrived a decade ago, its only one. Nor is HLS a carry-anything envelope
  — the specification admits a closed list of five formats and states that transport of other media
  file formats is not defined. What is genuinely newer is Low-Latency mode, in which partial segments
  may also be MPEG-TS. TS-in-HLS has been available throughout, and its absence from most MoQ
  comparisons is a habit rather than a technical fact.
- **"MoQ rides QUIC, and that is the decisive property."** Low-Latency HLS *requires* HTTP/2 or
  HTTP/3, so over HTTP/3 it rides the same substrate with the same per-stream loss isolation. QUIC is
  a necessary substrate for both and distinguishes neither; what distinguishes MoQ is the object and
  subscription model above it.
- **"Segmented HTTP's receive-side hand-off already ships, so that layer is solved for it."** This
  counted the client's equipment as if it discharged the distributor's obligation. It does not. **The
  method rule: when comparing two designs, draw the demarcation before comparing, and count only work
  that falls on the same side of it.** An advantage that lives in a third party's capex is
  optionality, not architecture.
- **"A sequence of TS segments is a re-muxed stream, so byte-verbatim carriage is structurally
  unavailable."** Reasoned from the requirement that a segment begin with a PAT and PMT, and wrong:
  measured against the source, a segment differs in byte 3 on one PAT and one PMT, and in nothing
  else. **The method rule: a "structurally impossible" claim derived from a specification is a
  hypothesis about an implementation, and costs one afternoon to test.**
- **"Not carrying stuffing is not unique to MoQ, since a TS packager has no reason to retain it — so
  the wire rows would converge if measured."** They do not converge: the off-the-shelf packager keeps
  the stuffing and segmented HTTP lands 7.0 % above the media-aware lane. What the reasoning missed
  is that the two properties are one: a packager that stripped stuffing to reach parity would forfeit
  its §8 advantage. **The method rule: when an argument says two measurements should converge, check
  whether the mechanism it proposes would cost something elsewhere in the same comparison.**
- **"RIST reproduces the source's own cadence, so it hands a groomer the cleanest egress."** The
  premise is exactly right and the conclusion does not follow. Measured, RIST and SRT are
  *transparent* while MoQ *re-paces*, emitting 12.2–12.4 kB regardless of what it is fed. So
  "reproduces the source" is a weaker property than "sets its own granularity". **The method rule:
  when a comparison ranks transports by a property of their output, measure the input as well** —
  otherwise a transport that merely passes its input through is credited with its source's virtues.

A seventh belongs with them, and it is this repository's own: **"MoQ's sub-second capability is
measured."** It was not. It is a structural property of the protocol and a reasonable inference from
measured delivery granularity, and it was written as a result in two documents for several revisions.
**The method rule: a claim that decides a comparison should carry a citation to the measurement that
established it, and the absence of one is a finding about the comparison rather than a gap in its
prose.**

---

## 14. Verdict, axis by axis

Read the "favours" column as *today*, on the evidence in this repository and the current
specifications. The **Basis** column states what kind of evidence the row rests on: **M** measured
here, **S** specification, **V** vendor datasheet, **R** reasoning, **—** none.

| Axis | Favours | Basis | Margin |
|---|---|---|---|
| Scaling the distribution (R4) | segmented HTTP | R+S | narrow — both scale at this size; statelessness and supplier count are the difference (§2) |
| Reliability under loss (R2) | neither | M+S | none — shared QUIC substrate; MoQ measured at parity with SRT (§3.1) |
| Reliability of recovery (R2) | segmented HTTP | S | clear on the specification — availability window, idempotent retry, client-driven failover. **Not exercised under loss in this campaign** (§3.2) |
| Reassembly to a transport stream | segmented HTTP | M | clear — off the shelf in TSDuck and ffmpeg against MoQ's single `moq export ts` (§4.2) |
| Grooming to a clean hand-off (R5) | **MoQ** | **M** | **the same groomer absorbs ~240× coarser bursts and 24 multi-second silences on segmented HTTP; against RIST and SRT the two split, MoQ on burst size and the tunnels on worst-case silence** (§4.3, §10.1) |
| Latency (R1) | **MoQ, structurally** | **S + —** | **unresolved. Segmented HTTP's 2–5 s floor is arithmetic and its ~6 s free-tooling floor is measured; MoQ's sub-second capability is structural and its glass-to-glass latency is unmeasured on both planes, as is whether it survives the groomer depth R5 needs** (§5, §5.1) |
| Interoperability (R3) | segmented HTTP | M+S | decisive, conditional on the single-programme envelope (§6) |
| Entitlement and control (R7) | MoQ | R | narrow — enforcement point and session observability, not revocation speed (§7) |
| Carriage fidelity, one programme (R3) | neither | M | **measured a wash — segmented HTTP is byte-verbatim but for the PAT/PMT continuity counter, so MoQ's advantage narrows to the multi-programme case alone, which is untested** (§8) |
| Wire volume | **MoQ** | M+derived | ~7.0 %, MTU-invariant — 0.982× against 1.056× over HTTP/3; §8's fidelity trade priced (§9) |
| Delivery economics | segmented HTTP | S(published rates) | decisive, and it swamps the row above — commodity delivery at $0.005–0.010/GB against one MoQ supplier at $0.050 (§9) |
| Operational maturity | segmented HTTP | R+M | decisive — mature multi-vendor tooling and existing staff skills against a pre-1.0 ecosystem |

**What that adds up to.** For a route whose destinations can absorb two to five seconds and which
carries a single programme, segmented HTTP carrying MPEG-TS over HTTP/3 is the better engineering
choice today — on interop, maturity, delivery economics and recovery, none of which is close, and on
carriage fidelity, where it turns out to be byte-verbatim. **MoQ's case is not general and should not
be stated as though it were.** Measurement narrowed it and sharpened it at the same time. What is
left is: an egress a groomer can actually pace, verbatim *multi-programme* carriage, a portable
enforcement point with an observable session, push rather than manifest polling, ~7 % less wire
volume — and a structural sub-second capability whose survival through the edge stage is the open
question of §5.1.

**Two warnings about reading any single row.** MoQ moves ~7 % fewer bytes and today those bytes cost
five to ten times as much, so the axis it wins is worth a rounding error against the axis it loses.
And the latency row — the one that decides the comparison — is the only row in the table with no
measurement behind it.

**And the part that matters more than the verdict.** Every item that makes either data plane
*broadcast-grade* is common to both: PCR and CBR grooming to TR 101 290, 1+1 with byte-identical legs
and receiver-side selection, ST 2022-7 pairing, entitlement and multi-tenant control, observability
in broadcast terms, and interop with the MPEG-TS installed base. Neither specification addresses any
of it. That is why this is framed as an evaluation of Internet-native primary distribution on two
candidate data planes rather than as a case for one protocol, and why the measured work in
[Evidence](evidence.md) transfers between them.

---

## 15. Open questions

Ranked by how much each would move the comparison.

1. **Does a MoQ chain stay sub-second while reaching TR 101 290 P1 PCR repetition on the wire?**
   §5.1. The cheapest outstanding measurement in the campaign and the one with the highest leverage,
   because a negative answer removes the only axis on which MoQ leads.
2. **Does a commercial ABR-to-TS gateway, operated as the distributor's own edge stage, produce
   TR 101 290 P1/P2-conformant output on real hardware?** §4.4. If yes, part of the broadcast-grade
   layer is purchasable on one data plane and not the other; if no, the reassembly advantage in §4.2
   is all that is left of the hand-off axis. It is also the only candidate receiver that could
   realise a low-latency TS-in-HLS route at all.
3. **Does the sub-second requirement exist on identifiable routes, or is it a preference?** §5.2.
   This decides how much of primary distribution MoQ addresses at all.
4. **Can a CDN carry a multi-programme TS segment in practice, and does anything downstream of the
   cache object to it?** §8. This now carries the whole of MoQ's carriage-fidelity advantage, since
   single-programme carriage measured as a wash.
5. **Should the edge gateway sit at each client's demarcation or in the distributor's regional
   PoPs?** §4.5. The choice sets how many destinations the transport actually serves, and therefore
   most of the delivery bill, on both data planes.
6. **How does a segmented-HTTP leg behave when segments are genuinely lost rather than late?** §3.2.
   Its recovery advantage is specification-based and has not been exercised.
7. **Would relay portability, if achieved, change the economics enough to matter against a delivery
   market that is already commoditised?** MoQ's strongest economic argument is contingent on an
   interoperability fix ([Evidence](evidence.md) §3.7), and its prize is a market position segmented
   HTTP already occupies everywhere except the sub-second band.
