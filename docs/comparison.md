# Candidate Data Planes Compared

Status: working draft.
Layer: **the data-plane choice** — this document *is* the layer where the candidates differ.
Scope: the head-to-head this repository owes its own thesis. [Problem](problem.md) §5 states the
requirement set; this document evaluates the candidates against R1, R2, R4 and R5, and against the point-to-point
incumbents, on the axes an operator actually decides on. The layer above the transport — where
nearly all the measured work sits, and which is common to both candidates — is
[Architecture](architecture.md).

**The conclusion, first.** For the majority of primary-distribution routes there are *two* viable
Internet-native data planes rather than one. They differ decisively on the one axis that can decide the
choice, and it is now measured: **over one internet path in one window, MoQ delivers a picture in 109 ms
and segmented HTTP in 4,067 ms** ([Evidence](evidence.md) §3.11). That settles which plane a route with a
tight budget must use, and settles nothing else —
segmented HTTP is ahead on most other axes, and everything that makes either of them *broadcast-grade*
sits above the transport and is common to both. That is not a retreat from the thesis but a demonstration
of it — [Problem](problem.md) §1 holds that the transport is the least interesting part of the transition.

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

## 2. Scaling the distribution (R2)

**Fan-out is the axis that separates both Internet-native candidates from the point-to-point
incumbents, and it is barely an axis between the two of them.** Both halves of that matter. R2 exists
because the adopted tunnel architectures run out in the region of 50 destinations — a documented,
non-increasable ceiling on the leading managed service ([Problem](problem.md) §2.3) — while the
requirement is hundreds to low thousands. Against that, **both candidates here put a cache in the path
and clear the requirement; so what remains to compare is not whether they scale but who operates the
replication point.**

Neither breaks the linearity of last-mile delivery, and neither claims to: an HTTP edge cache fetches an
object once and serves N receivers over N unicast connections, a MoQ relay receives an object once and
serves N subscribers over N unicast connections, and an SRT gateway holds N sessions. The first two are
the same topology under different names, and the difference from the third is that nobody has to
originate the N ([Economics](economics.md) §4.4).

What differs is the *shape* of the replication point and who runs it.

| | Segmented HTTP | MoQ | SRT / Zixi / RIST |
|---|---|---|---|
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, from a dozen suppliers, today | one CDN today, at five to ten times commodity delivery; otherwise you | you, or a managed media service |
| Adding a destination | a cache fill nobody provisions | a subscription and its relay state | a gateway output slot, and sometimes an instance |
| Known hard ceilings | none at this scale | untested beyond our own rig; relay memory grows per ingested group and plateaus softly, at a ceiling whose scaling term is open by a factor of two ([Evidence](evidence.md) §3.6) | AWS MediaConnect: 50 outputs per flow |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network | none | none |

Three conclusions follow, and only the first is a differentiator.

**Statelessness is segmented HTTP's real scaling advantage, and it is a reliability advantage in
disguise.** Because a segment is a named resource rather than a position in a session, a destination
can move between edges, regions or suppliers mid-stream with nothing to re-establish, and the origin
never learns that it happened. MoQ and SRT fan-out is stateful, so the replication point is also a
failure domain: losing a relay loses a session, and recovery is a resubscribe. Developed in §3.

**The economic case is partly about origin offload.** Rather than egressing every copy of a feed directly from the origin, the stream can be replicated through regional or edge infrastructure, with delivery to consumers occurring closer to the edge. This allows commodity CDN infrastructure to absorb the distribution fan-out while reducing the amount of traffic that must be egressed from the origin.

**Nobody here does point-to-multipoint at the last mile**, which makes the phrase misleading in all
three columns. Segmented HTTP is the only candidate with a specified multicast profile — DVB-MABR,
deployed commercially by tier-one operators — but it replicates inside an access network the operator
controls, terminating at a gateway in the home or the network edge. That is consumer distribution,
not affiliate distribution. So "MoQ is point-to-multipoint and SRT is point-to-point" is true only in
the sense developed in §10: it describes **where the replication point sits and who owns it**, not IP
multicast.


---

## 3. Reliability (R5)

Two questions hide inside this axis and they have different answers: *how does the transport behave
under impairment*, and *how does the system recover when something fails*. On the first, one
impairment separates the two data planes and the other separates congestion controllers rather than
lanes. The second favours segmented HTTP, and it is the more important of the two for a trunk.

### 3.1 Under impairment: loss separates the controllers, and once the lanes are substrate-matched nothing cleanly separates the lanes

**The argument that a shared substrate makes the two indistinguishable was right, and it did not need
a shared substrate to be shown.** Low-Latency HLS **requires** HTTP/2 or HTTP/3, so over HTTP/3 it
rides the same QUIC substrate with the same per-stream loss isolation and the mandatory RFC 9218
priority scheme, and there is no per-packet loss-resilience argument that distinguishes the two. QUIC
is a necessary substrate for both and distinguishes neither; what distinguishes MoQ is the object and
subscription model above it. Measurement bears this out even on the substrates actually deployed:
matching the congestion controller is enough to make the loss axis indistinguishable, with TCP on one
side and QUIC on the other.

Both lanes were measured head-to-head on one host under one shaper, across the full matrix of lane
against congestion controller; the delivered-rate matrix is in
[Evidence](evidence.md) §3.3, and this is what it means for the choice between the two.

**Loss is a controller result, not a lane result.** Read that matrix down a column and the two data
planes are indistinguishable — at 10 % loss both hold full rate on BBR (1.04 segmented, 0.96
media-aware) and both collapse on CUBIC (0.17 and 0.13). Read across a row and the controller decides
the outcome on either of them. A loss-based controller treats a dropped packet as a congestion signal
and backs off whether the bytes are a QUIC stream or an HTTP response; a delay-based one does not,
equally on both. The widely-repeated
claim that segment fetching degrades under loss where MoQ does not is an artefact of comparing TCP's
default controller against QUIC's tuned one.

**Reordering was the one axis that separated the lanes. It has now been measured on a shared
substrate, and it does not.** The earlier cell read 0.98 for segmented HTTP against 0.19 for the
media-aware lane, and the explanation offered for it — that each segment is a bounded, independent
object, completed and buffered ahead of the play point — was reasonable and is not what produced the
number. That cell gave the segmented lane loopback's default 65536-byte packets while the media-aware
lane, correctly but on one arm only, had segmentation offload disabled: **1,209 packets averaging
34,380 bytes against 29,062 averaging 931 bytes, for the same media.** `netem` reorders a *fraction of
packets*, so the lane that won met roughly 24× fewer reordering events. Re-run with packet sizes
equalised across all three arms ([Evidence](evidence.md) §3.3,
[T20](../lab/test-20-segmented-http3.md)):

| 25 % reordering, 3 replicates | Segmented / TCP | Segmented / **HTTP/3** | Media-aware / QUIC |
|---|---|---|---|
| Equal packet sizes | 0.44 | **0.18** | **0.13** |
| As originally measured | 0.995 | 0.995 | 0.125 |

The original conditions reproduce exactly, so the measurement was sound and the reading of it was
wrong. **On HTTP/3 the two lanes overlap** and reordering no longer distinguishes them; on TCP the
segmented lane keeps a real but much smaller advantage than the one previously claimed.

**The substrate change is a trade, and it runs the segmented lane's way on the other two axes.**
Moving it to HTTP/3 costs it reordering and wins it loss — 0.10 on TCP against **0.70** on HTTP/3 at
~20 % applied loss — and the 30 s outage, 0.51 against **0.76**. Unimpaired, the two substrates
produce byte-identical output. So HTTP/3 is not a downgrade for segmented HTTP; it moves where the
lane is strong, and the verdict can no longer rest on a single impairment axis.

**Trunking several feeds down one congested path is a third result, and it is a latency decision rather
than either.** Two or three media-aware feeds sharing a 15 Mb/s bottleneck at a 2 s subscriber budget
deliver *less in total* than one feed delivered unopposed — 9.44 Mb/s at one flow against 5.39 and 4.48
at two and three — while SRT rises to 12.65 and holds at 84 % of the cap. That looks like a lane defect
and is not: it is neither the controller (loss-based CUBIC collapses inside delay-sensing BBRv1's
spread) nor bufferbloat (it survives `cake`, which cut RTT from ~550 ms to 100 ms). It is the
subscriber's release deadline — widening `--latency-max` from 500 ms to 30 s at two flows takes the
aggregate from 4.29 to 10.35 Mb/s, past the single-flow rate, at **0 continuity errors throughout**. So
each receiver is independently discarding groups that missed its own budget, and N receivers doing that
sum to less than one. SRT makes the same trade in the opposite direction and converts the identical
shortfall into ~26,000 continuity errors, so its larger total is not more programme. **The consequence
for a trunk is that it must be provisioned in latency as well as in rate**, and that the media-aware
lane's advantage in §5 — reaching completeness on a much smaller buffer — is the same knob seen from
the other side: spend less buffer and you shed more under contention ([Evidence](evidence.md) §3.3).

**What segmented HTTP did not do at any loss level in this ladder is corrupt what it delivered:** 0
continuity discontinuities and 0 PCR intervals above 40 ms in every loss cell, including the one where
it delivered a sixth of the stream. Inside the origin's availability window it sheds *time*, not *bytes*, which is the
failure a downstream buffer can absorb. That window is a real edge rather than a formality: a deeper
ladder crosses it between 7.7 % and 12.2 % applied loss, and past it the client re-anchors to the live
edge and leaves holes of 7.2 s, 24 s and 82 s as the loss deepens. The mitigation is a buffer only while
the shortfall is short enough that the client stays in the window. **Past that edge the lane also stops
reporting**: a 404 only occurs if the client asks for a segment that has just been deleted, and beyond
about 20 % loss it does not get the chance — it reloads the playlist, finds the segment gone from the
list and skips. The cell that lost 82 s of programme received nothing but 200s, so an origin's error
rate does not detect this and only a continuity or PCR check downstream will.
The media-aware lane's own PCR non-conformance sat unchanged at 7.9–9.2 % in every cell including the
unimpaired baseline, because it is the exporter defect of §5.1 rather than anything impairment did.

One thing bounds this. The segmented arm in that ladder was served by a single unoptimised origin over
HTTP/1.1 rather than a tuned CDN edge, which is the configuration its commercial case assumes, so a CDN
could move the loss curve further. The substrate half of that question is now settled and moves it a
long way on its own: on HTTP/3 the same lane holds 0.70 at ~20 % applied loss where TCP holds 0.10.

**Under sustained capacity shortfall the two lanes fail differently, and that is now measured rather
than argued.** Holding a 20 Mb/s lane at 8 Mb/s against a 9.95 Mb/s stream, both segmented arms deliver
0.79–0.81 — essentially everything the reduced pipe can carry, taking the shortfall as growing lateness
— while the media-aware lane delivers 0.46, discarding groups that miss the subscriber's release
deadline. Transient degradations (5 s below rate, or 60 s at 12 Mb/s, which is still above the stream
rate) are absorbed by all three. **The choice under a lasting shortfall is therefore between lateness
with recoverable objects and bounded latency with discarded programme**, and it is a policy decision
rather than a quality ranking.

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
argument. And **the retry model has now been exercised under loss, with a split verdict**: it does not
deliver resilience *of rate* by itself, because rate under loss is set by the congestion controller
underneath — the same lane reads 0.17 at 10 % loss on CUBIC and 1.04 on BBR (§3.1) — but it does
deliver resilience *of content* while the client stays inside the origin's availability window,
arriving byte-verbatim and P1-clean at every level of the impairment ladder including the cells where
a sixth of the stream got through. Retry buys completeness inside that window, not throughput, and
nothing at all outside it.
The *failover* half has since been exercised too, and the serving-node case is the cleanest result
either lane produced: an origin killed for ten seconds costs **no content at all**, because HTTP holds
no session state, the next successful request is the recovery, and the store still holds what was
missed. The difference from the media-aware lane is not the speed of resumption — both resume within
a few seconds of the node returning — but that the media-aware exporter skips to the live edge and
loses the media produced during the outage, where the segmented client refetches it. The severe qualification is that this is a protocol property no
off-the-shelf TS client in the rig could use — both TSDuck's HLS input and FFmpeg's HLS demuxer
abandon the stream at the first failed playlist reload, the latter with every retry option it
offers already set — so it took a purpose-written client to show it (§3.3, [Evidence](evidence.md)
§3.4). What remains specification-only is edge and Pathway selection under Content Steering. The
boundary where completeness breaks is no longer unmeasured: a ladder to 40 % loss over 120 s windows
pushes the client out of the availability window between 7.7 % and 12.2 % applied loss, and past it
the lane delivers holes rather than lateness — 7.2 s, 24 s and 82 s as the loss deepens, and past about
20 % loss with the origin returning nothing but 200s
([T5](../lab/test-5-network-impairment.md), [T6](../lab/test-6-relay-resilience.md)).

### 3.3 Where broadcast actually gets its reliability, and why it is common to both

Neither transport's own recovery is what a broadcaster relies on. Reliability comes from **1+1 with
selection at the receiver**, and that is transport-independent. It was measured on MoQ: two
independently groomed legs come out byte-identical for single-track content and the pair rides out
the death of a publisher, a relay or an exporter ([Evidence](evidence.md) §3.4).

The two lanes have now been drilled head to head on that question, and they diverge more sharply
here than anywhere else in this comparison — in opposite directions, and for a structural reason.
The media-aware relay owns source selection, so it must *detect* a dead source before it can
reselect: failover is 30–33 s by default, reducible to about ten seconds and fragile below that, and
hitless is not reachable by relay reselect at all. The segmented origin owns nothing, so there is
nothing to fail over. An active/active pair fed from one source and writing one set of segment names
fails over **with no measurable interruption** — no detection delay, no gap, the largest stall equal
to the baseline's and not even falling at the kill instant, reproduced identically across three runs
under a hard kill and holding under a graceful one. No receiver-side machinery is required for it,
and the determinism that makes it safe comes free: two packagers of one feed emit byte-identical
segments, because the cut point is the next intra-coded picture rather than an emit instant.

The same statelessness produces the worse floor. A *misconfigured* pair — two sources that do not
share a feed, or that do not agree on segment names — is accepted without complaint, and delivers
either twenty-second time-travel or every second of media twice. Both pass a continuity-counter
check and a PCR-interval check untouched, because those gates ask whether the clock moved and not
which way. The media-aware relay refuses the same misconfiguration outright and tears the stream
down. Given a choice between a loud outage and silent corruption a broadcaster wants the outage, so
the segmented lane's advantage here is real but conditional on getting the pair right, which is a
weaker guarantee than being unable to get it wrong ([T6](../lab/test-6-relay-resilience.md)).

So the redundancy layer is common in *design* and its shape transfers to either data plane
([Architecture](architecture.md) §5) — but its cost does not. On the media-aware lane a hitless pair
has to be built at the receiver; on the segmented lane it falls out of a shared source and a naming
convention.

---

## 4. The hand-off (R3)

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

### 4.3 Grooming: a heavier burden on segmented HTTP, the better measured result there, and the only lane an off-the-shelf stage can groom

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
into the identical chain, the same binary with no flag changed takes the segmented-HTTP egress to
TR 101 290 conformance **on the wire** — 0 intervals above 40 ms, 0 PCR violations at 481 ns
([Evidence](evidence.md) §3.2). What it costs is 7.5 s of programme held before the first byte, a
13.1 MB buffer and ~9 s to notice a dead origin. Note which way round this comes out: on the
segmented plane the groomer clears a bar the MoQ lane does not currently clear, and it clears it with
the buffer depth segment duration had already imposed. That is the coupling §5.1 is about.

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

**On this lane, off-the-shelf tools do the whole job — and that is a difference between the two data
planes rather than a fact about MPEG-TS.** Every candidate an engineer would reach for was graded
against four criteria fixed in advance — mux preserved, PCR inside 481 ns, no interval above 40 ms,
honest duration on a rate-controlled wire — against both egresses. Behind MoQ each fails a different
one. Behind a segmented egress, `tsp -P pcradjust -P regulate -O ip` passes all four with the mux
carried byte-for-byte.

The reason is what the packager hands downstream. It slices the transport stream it was given, so the
stream still carries the source's null stuffing (4.57 % against the source's 4.59 %), still declares
the source's mux rate, and still has the source's PCR spacing (0 intervals above 40 ms, where a MoQ
egress arrives with 163). Two of the three jobs a groomer exists to do are therefore already done, and
the one that remains — owning a clock — is the one TSDuck does well. The failures the tools show on
the MoQ lane are unchanged and simply do not arise here: `tsp` still cannot inflate a stream, but on
this lane it is not asked to ([Evidence](evidence.md) §3.2).

What this lane does demand instead is buffer depth. A grooming stage fed 2 s segments must hold a
cushion at least as deep as the segment period, and below it the failure is not graceful: at a 1 s
cushion the same stage went silent for 1.85 s at a time and posted 311 continuity errors, against a
clean record at 8 s.

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

**It splits three ways, and the third way is the one that decides whether a hardware IRD locks.**
Three separate claims were being run together under "hand-off":

- **Receiving** — turning the delivery back into a transport stream — favours segmented HTTP. Off the
  shelf on one side, single-implementation on the other, and an ABR-to-TS box is purchasable as the
  distributor's own edge stage where no MoQ equivalent exists at any price. Whether that box
  discharges the obligation to broadcast conformance is unmeasured (§4.4).
- **The burden on the groomer** favours MoQ, measurably: the same stage has ~240× coarser bursts and
  24 multi-second silences to absorb on the segmented-HTTP side (§4.3). **Which stage can carry that
  burden favours segmented HTTP**, and by more than the burden costs: off-the-shelf TSDuck grooms the
  segmented egress to all four criteria with the mux intact, where the MoQ lane has no off-the-shelf
  option that preserves a broadcast mux and needs a purpose-built stage (§4.3).
- **The stream that actually leaves the groomer** — which is what an IRD grades — no longer separates
  them, though it did for four experiments. Both lanes now deliver 0 PCR intervals above 40 ms on the
  wire: the segmented arm at the 8 s cushion its segment duration already imposes, the MoQ lane at a
  buffer sized by its peak coded frame ([Evidence](evidence.md) §3.2). **The lighter burden and the
  worse outcome turned out not to be the same fact**, which is what the measurement changed — and the
  worse outcome then turned out not to be the exporter's either.

**"Easier to receive", "easier to groom" and "conformant once groomed" are three different claims,
and running them together is what let this axis read as a MoQ win.** They still resolve differently —
MoQ leads on burden and needs a purpose-built stage where TSDuck suffices — but the delivered result is
now a tie, and the reason the MoQ side failed for so long was in that purpose-built stage rather than in
the plane (§5.1).

**Three upstream fixes were each necessary and none was sufficient.** The exporter's PCR values became
an exact 25 ms grid, then its writes were paced so the cadence reaches a real-time consumer, then the
export was sliced on the grid so each PCR packet sits beside the bytes it labels. Adjacency 87.2 % → 0 %,
p95 release error 1.70 ms — and the wire still carried 12.2 % of intervals above 40 ms, because none of
them could give the groomer back a mux schedule that was never in the decode timestamps
([Evidence](evidence.md) §3.2). **What finally cleared it was one line of scheduling policy in the
groomer**: reserve the output slot for the PCR on its deadline instead of taking only slots the content
scheduler declined, because a burst declines none.

This supports the repository's central position rather than undermining it. Because the obligation to
hand off a clean paced TS does not transfer to the client on either data plane, that layer is
required and owned on both — and it is now demonstrably *one* layer rather than two, since the same
binary sits behind either plane. What differs is the depth it has to run at and what sets that depth:
seconds on the segmented plane, fixed by segment duration, against a bound on MoQ set by the source's
**peak coded frame** — which is a per-feed engineering input rather than a constant (§5.1).

---

## 5. Latency (R4)

**This is the axis on which the two data planes differ most, and the difference is measured rather than
reasoned: 109 ms against 4,067 ms over one internet path in one window** ([Evidence](evidence.md)
§3.11). The arithmetic below explains *why* the gap is structural; the measurements follow it.

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

**MoQ's floor is now measured, and it is 109 ms across the internet.** The same clip, tapped leaving an
EC2 origin and again on the groomed egress here, crosses the public internet in a **109 ms median** — 15×
lower than SRT and 37× lower than segmented HTTP over that path in the same window. On loopback it is
127 ms, and there it also came in 4.7× lower than a plain-UDP control carrying no transport buffer at all
([Evidence](evidence.md) §3.11). This replaces the structural
argument that stood here: the sub-second claim is a result, and it may be cited as one, with the
qualification that it is *delivery* latency — source to groomed egress — and does not include encoder or
decoder delay, which no plane here varies.

**The edge stage's contribution is measured on both planes, and the asymmetry is stark.** The groomer that
satisfies R3 held **7.5 s of programme before emitting a byte** on the segmented plane
([Evidence](evidence.md) §3.2), and over the internet that plane's total runs from 4,067 ms at its
shallowest runnable cushion to 9,286 ms at the depth that makes it P1-conformant. On MoQ the commanded
cushion turns out not to be the depth in force at all — the lane's standing depth drains to ~90 ms whatever
it is told, because the carrier outruns the null-stripped content arriving at it — so the edge stage adds
tens of milliseconds, not seconds. **That is the finding that decides this section:** the stage every
requirement in R3 needs does not cost the MoQ lane its advantage.

### 5.1 Latency and PCR conformance are not coupled, and the gate is met downstream

Grooming appeared to buy PCR-repetition conformance with buffer depth, and buffer depth is latency —
which would have made P1 conformance on the wire something MoQ pays for out of the only axis on which
it leads. **Measured, the two axes are independent** ([Evidence](evidence.md) §3.2,
[T18](../lab/test-18-delivery-latency.md)). Sweeping the groomer's cushion across a ladder spanning
eight times the depth moves the lane's repetition figure not at all, and it does not move either when
groomer starvation is removed altogether; over the internet it reads 504 intervals above 40 ms. The
groomer *was* placing PCRs of its own throughout, at four different rates, and none of it mattered.

**The defect is therefore upstream of the edge stage, and it is narrower than a rate.** The exporter
emits **31–36 PCRs a second against the source's 41**, and against the ~25/s a 40 ms ceiling
arithmetically needs — so it does not send too few. It places 85 % of them within 11 µs of each other
and leaves the residue in gaps of 100 ms to 1.84 s, where the source ran an even grid with *zero*
intervals above 40 ms. So this is not a structural cost to be priced into a recommendation, and it is
not a cadence to be raised. T18 predicts — and does not test — that emitting on an even ~25 ms grid,
against elapsed clock rather than against PES-unit boundaries, would clear the gate at the depth the
lane already runs, which is **109 ms of delivery latency across the internet**.

**That change has since been made upstream — three times — and the prediction is wrong.** The exporter
now emits an exact 25 ms grid, paces its writes so the cadence reaches a real-time consumer, and slices
on the grid so the PCR *packets* sit beside the bytes they label. Adjacency is 0 % and p95 release error
1.70 ms. The wire still carried 12.2 % of intervals above 40 ms, because a coded frame's bytes belong to
*its own* 40 ms however large the frame is, and the CBR mux schedule that used to spread a big picture
across many frame periods is not recoverable from decode timestamps. **The exporter cadence was never
what the gate turned on.**

**What the gate turned on was in the groomer, and it is fixed** ([T19](../lab/test-19-pcr-grid-verification.md)
measurement 11). PCR re-insertion was *opportunistic*: it could only occupy an output slot the content
scheduler had declined. A media-aware source delivers a coded frame as one burst, so its groomed output
has ample stuffing overall and none at all inside a burst — every one of the 71 over-40 ms intervals in
a graded 20 s output contained **zero** null slots, and the worst ran the length of the frame. Reserving
the slot instead of waiting for a spare one costs 0.34 % of the carrier and closes the gate at every
cushion, on every source tested. With two further groomer fixes — estimating the media rate as a ratio
of sums rather than a mean of per-interval ratios, and closing the release loop on buffer occupancy
rather than running open-loop on the estimate — the lane's wire returns **0 of 20,193 intervals above
40 ms over 300 s, 0 continuity errors, 0 groomer drops, 0 underruns and exact CBR**.

So the defensible statement is:

> MoQ delivers a picture across the public internet in 109 ms, 15× lower than SRT over the same path.
> Its groomed wire **is** TR 101 290 P1-conformant on PCR repetition in software over runs of minutes,
> but only with all
> three upstream PCR fixes *and* a groomer that reserves the PCR slot, estimates the media rate
> correctly and closes its release loop on occupancy — and that groomer is not yet shown to hold its
> operating state for hours, since its rate estimate diverges at about nine minutes with the wire
> giving no sign of it. The buffer that costs is set by the **peak coded
> frame**, not by the bitrate, so it is content-dependent and has to be sized per feed. Neither lane has
> been graded on a hardware IRD, which is now the measurement that would most change this comparison,
> and it is blocked on apparatus rather than on either project.

What remains genuinely open about the latency figures themselves: both paths measured were healthy, so
nothing exercised the retransmission and jitter-buffer recovery the point-to-point tunnels exist for —
the case that should favour them ([Evidence](evidence.md) §4).

### 5.2 The decision rule, restated

**If the route's destinations can absorb seconds — in practice nearer six unless a commercial
ABR-to-TS receiver is bought — segmented HTTP is the better engineering choice today** on the balance
of the remaining axes: decisively so on interop, maturity and delivery economics, narrowly on the
hand-off, against narrower MoQ advantages on entitlement and multi-programme carriage.

**If they cannot, MoQ is the only Internet-native candidate with commodity delivery in prospect** — and
its advantage now survives its own edge stage as a measurement rather than as a hope: 109 ms across the
internet against segmented HTTP's 4,067 ms over the same path. §5.1's conformance risk is discharged in
software — the lane's groomed wire is P1-conformant on PCR repetition — at the price of an edge buffer
sized by the peak coded frame, which is a per-feed engineering input rather than a latency risk. The
discharge is scoped to runs of minutes; whether the edge stage sustains it is [T21](../lab/test-21-permanence-soak.md)'s
question and currently its answer is no.

Note what the rule does *not* decide: the grooming and egress layer is built either way (§4).

And note the question behind the rule, which is a condition of MoQ's case specifically rather than of
Internet-native distribution generally: **does the sub-second requirement exist on identifiable routes,
or is it a preference?** Every other axis here favours segmented HTTP, so if no real route needs
sub-second delivery then MoQ addresses a preference rather than a requirement, whatever its measured
margin. The
usual answer — "sub-second desirable, a few seconds tolerable" — is true of the *feed's own
integrity* and understates the transition. Replacing a geostationary path with a 2–5 s one consumes
most of a downstream budget that was previously free, at every destination, and the consequences are
operational rather than technical: regional splice and blackout timing, relative alignment between
affiliates served by different paths during a mixed-estate migration, live handback, and any
destination that re-distributes and adds its own budget. None of that is a transport defect. It is a
reason "seconds are tolerable" has to be answered per route by the destination, not asserted once in
a requirements list.

---

## 6. Interoperability (R1)

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

## 8. Carriage fidelity (R1)

| | Segmented HTTP | MoQ media-aware lane | MoQ opaque lane | SRT — the incumbent |
|---|---|---|---|---|
| Multi-programme mux | **normatively excluded** (§6) | one programme, reconstructed | **verbatim MPTS** | verbatim by construction; measured on one programme |
| PIDs, PES, `stream_type`, PAT/PMT | preserved | preserved | preserved | **preserved** — measured over the wire |
| PMT PID, PCR PID | **preserved, incl. non-default** — measured on three clips | preserved, since the service-layer carriage fix | preserved | **preserved** — measured |
| TSID / ONID / service name, provider, type | **preserved** — measured | preserved, since the same fix | preserved | **preserved** — measured |
| SDT / NIT | **preserved** — measured | preserved ([Evidence](evidence.md) §3.1) | preserved | **preserved** — measured |
| EIT | **preserved, schedule included** — all 69 sections of an 8-day EPG byte-identical, sparse sub-tables and declared extents intact, at 1.003× the source PID rate | preserved, schedule included | preserved | not exercised (the clip carries no EIT) |
| TDT / TOT | **preserved** — measured | carried, TOT descriptors intact, but **delivered ~14 s late** on the exporter's own emission grid | preserved | **preserved** — measured |
| CAT | **preserved** — measured | not carried | preserved | not exercised (the clip carries no CAT) |
| Continuity counters | **preserved except a forced re-stamp on PAT/PMT** | regenerated by the exporter | preserved | **preserved, 0 CC errors** — measured |
| Null stuffing | **carried** — measured | not carried | carried if verbatim | **carried** — measured |
| Mux rate | preserved | **none** — the egress has no byte clock | preserved if verbatim | **the source value exactly** — measured |
| PSI cadence | source cadence, plus the injected pairs | **regenerated thinner** — 8.04 → 2.51 PAT/s, mean gap 124 → 399 ms against P1's 500 ms | unchanged from source | **identical to source** — measured |
| Packets added to the mux | **one PAT/PMT pair per segment** — measured, and nothing else; **1.00 per segment head over the internet too** | rebuilt, not comparable | **none** | **none** — measured |
| PCR repetition (P1), file domain | **unchanged from source** — measured | **not inherited from the source but produced by the lane** — clustered 86 % of intervals under 1 ms with gaps to 320 ms, from a source with none above 40 ms in 600 s; restored by the pacer. **On the merged exporter the values are an exact 25 ms grid and the packets sit beside the bytes they label; the delivered figure clears once the groomer reserves the PCR slot rather than waiting for a spare one — 0 of 20,193 intervals above 40 ms over 300 s** (§5.1) | unchanged from source | **unchanged from source** — measured over the wire |
| PCR accuracy (P2), file domain | **37–74 ns → 109–302 µs**, the injected pair priced; **302.1 µs against 302.4 predicted over the internet**, and **0 violations at 500 µs** bounding it; **0 violations once groomed** | **gate undefined** — a rate-less egress has no byte clock to grade against | unmeasured; byte-preserving by construction | **0 violations at 481 ns** — measured over the wire |
| Byte-identical to source | **in payload, yes; as a mux, no** | no | yes | verbatim by construction; every field, count and cadence measured identical, not diffed byte-for-byte |

**Domains differ across these columns and the difference matters.** Segmented HTTP, the media-aware lane
and SRT were all measured over the public internet on the current build, in one rig with matched windows
and one instrument ([T4](../lab/test-4-remote-e2e-srt.md)); the segmented column's three-clip breadth
(CAT, non-default PMT PIDs) is loopback ([T3](../lab/test-3-opaque-transparency.md)), and the real
path reproduced its single-clip figures to 0.1 %, so the loopback breadth can be read as generalising.
The EIT row is loopback on a synthetic fixture on both MoQ and segmented columns, because no clip held
here carries an EPG ([T17](../lab/test-17-si-snapshot-tracks.md)).
The opaque column is loopback and partly derived, because that lane's egress delivers nothing outside its
original checkout. SRT is included as the *reference* rather than as a fourth candidate: it is the
byte-faithful case the other three are read against.

**For a single programme, segmented HTTP carrying MPEG-TS is as verbatim as the opaque MoQ lane on
mux *content*, which is the opposite of what the specification's wording suggests.** The reasoning
that a segment "must begin with PAT then PMT" and is therefore a re-mux does not hold: prepending a
PAT/PMT pair does not rebuild the multiplex, it inserts two packets and renumbers the continuity
counters of those two PIDs. Measured against the source packet by packet, the only difference in a
1,200-packet window is byte 3 — the continuity counter — on one PAT and one PMT
([Evidence](evidence.md) §3.1).

**Where it stops being verbatim is the clock, and the price is arithmetic.** Scored against the
opaque lane's own transparency inventory on three clips, the lane adds exactly one PAT/PMT pair per
segment and no PID the source lacked — and 376 bytes inserted at a segment head displaces every later
PCR in that segment relative to a constant-rate byte clock by the time those bytes take to transmit.
Predicted at 300.8 / 109.4 / 302.4 µs across a 2.75× bitrate spread, measured at 297.7 / 109.4 /
301.9. So file-domain PCR accuracy falls from tens of nanoseconds to hundreds of microseconds while
PCR *repetition* is untouched ([Evidence](evidence.md) §3.1). A 1 s / 2 s / 6 s duration sweep then
confirms the cost is per-segment rather than cumulative — 5.7× the injections moves the maximum error
by 1 % — so **segment duration trades violation frequency against nothing else**, and the error an IRD
would see is fixed by the clip's bitrate. **This is a demarcation finding, not a fidelity one**: the
groomer the distributor owns on both planes closes it to zero violations at the P2 limit
(§4.1, [Evidence](evidence.md) §3.2). What it forecloses is handing a segmented-HTTP egress to a
receiver *ungroomed* on the strength of its being verbatim.

**The P2 gate cannot be used to rank the three lanes, which is why the row above reads as it does.**
It grades PCR values against the byte positions they arrive at, so it presupposes a mux rate; the
media-aware lane's ungroomed egress has none, and graded anyway returns exactly the maximum PCR
interval rather than an error ([Evidence](evidence.md) §3.1). The axis is therefore informative about
segmented HTTP, silent about the media-aware lane until a groomer restores a clock, and unmeasured on
the opaque lane.

**The EPG is where the two lanes pass for opposite reasons, and the asymmetry is worth naming because
it recurs.** An EIT schedule sub-table is *sparse* — it declares a `last_section_number` covering a
multi-day range and transmits only the sections that hold events — so a lane that reconstructs the
table has to decide when it is complete, and cannot distinguish a section the source skipped from one
it lost. The media-aware lane takes that on and gets it right, committing a generation when the
transmission cycle wraps. The segmented lane never parses PID 0x0012: it copies the packets, so the
problem does not arise. Both deliver all 69 sections of an 8-day EPG byte-identically
([T17](../lab/test-17-si-snapshot-tracks.md)), and **understanding the media is what creates the
obligation to understand it correctly**. The cost lands on the other side of the trade: MoQ hands a
joining receiver the whole EPG as snapshots in about a millisecond, where a segmented client must wait
out the carousel — tens of seconds at the ETSI cadence, with no HLS mechanism to shorten it.

**What survives of MoQ's advantage on mux content is the multi-programme case alone**, where HLS's
"Transport Stream Segments MUST contain a single MPEG-2 Program" bites. That is normative rather than
demonstrated, it is an open measurement, and it now carries the whole row. Against the *media-aware*
lane, segmented HTTP is straightforwardly better: it keeps stuffing, the CAT, continuity counters and
the wall clock that the exporter does not.

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
| **Groom → CBR, PCR re-stamped** | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) — **conformant on the wire**, once it reserves the PCR slot instead of waiting for a spare one and closes its release loop on buffer occupancy (§5.1) | **the same binary, no flags changed** — it sizes its buffer to seconds rather than milliseconds from the arrival it observes, and reaches conformance on the wire ([Evidence](evidence.md) §3.2) | **distributor, on both** |
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
re-placing PCR *without* renumbering PIDs or retyping SCTE-35 — is the half that decides whether a
broadcast mux survives, and whether it needs a bespoke tool depends on the lane.** Behind a segmented
egress it does not: the packager already delivered the stuffing and the PCR spacing, so TSDuck's
`pcradjust` plus `regulate` is the whole answer. Behind MoQ it does, because that egress carries
neither and nothing off the shelf can add them without re-multiplexing.

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

## 13. Seven corrections the comparison forced

Each was a plausible claim, each was load-bearing here, and each turned out to be false. They are
recorded together because the *way* each failed generalises to other transport comparisons. Of the
first six, two fail in the direction that flatters MoQ, two in the direction that flatters the
alternative, the fifth in both directions at once, and the sixth in favour of a transport that is in
neither camp. The seventh is this repository's own. What each yielded as a *measurement* rule, with
the incident that produced it, is held once in
[`lab/method-notes.md`](../lab/method-notes.md); what is recorded here is the correction and what it
changes for the comparison.

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
  counted the client's equipment as if it discharged the distributor's obligation. It does not. An
  advantage that lives in a third party's capex is optionality, not architecture, and the demarcation
  has to be drawn before the comparison rather than after it.
- **"A sequence of TS segments is a re-muxed stream, so byte-verbatim carriage is structurally
  unavailable."** Reasoned from the requirement that a segment begin with a PAT and PMT, and wrong
  about what it claimed: measured against the source, a segment differs in byte 3 on one PAT and one
  PMT, and in nothing else. It was, however, pointing at something real that the refutation then
  overshot — the pair is *inserted*, so the mux is verbatim in payload and not as a mux, and the two
  packets cost file-domain PCR accuracy (§8).
- **"Not carrying stuffing is not unique to MoQ, since a TS packager has no reason to retain it — so
  the wire rows would converge if measured."** They do not converge: the off-the-shelf packager keeps
  the stuffing and segmented HTTP lands 7.0 % above the media-aware lane. What the reasoning missed
  is that the two properties are one: a packager that stripped stuffing to reach parity would forfeit
  its §8 advantage. The saving was a trade seen from one side.
- **"RIST reproduces the source's own cadence, so it hands a groomer the cleanest egress."** The
  premise is exactly right and the conclusion does not follow. Measured, RIST and SRT are
  *transparent* while MoQ *re-paces*, emitting 12.2–12.4 kB regardless of what it is fed. So
  "reproduces the source" is a weaker property than "sets its own granularity", and a transport that
  merely passes its input through had been credited with its source's virtues.

**"MoQ's sub-second capability is measured."** For several revisions it was not. It was a structural
property of the protocol and a reasonable inference from measured delivery granularity, written as a
result in two documents — and it was the claim on which this comparison's latency axis turned. It has
since been measured properly — 109 ms across the public internet, 15× lower than SRT over the same path
([T18](../lab/test-18-delivery-latency.md), §5) — so the claim is now true, which is exactly why it is
kept here. A claim being correct is not a substitute for its having been checked, and the interval
during which this one was right-but-unevidenced is the part worth remembering.

---

## 14. Verdict, axis by axis

Read the "favours" column as *today*, on the evidence in this repository and the current
specifications. The **Basis** column states what kind of evidence the row rests on: **M** measured
here, **S** specification, **V** vendor datasheet, **R** reasoning, **—** none.

| Axis | Favours | Basis | Margin |
|---|---|---|---|
| Scaling the distribution (R2) | segmented HTTP | R+S | narrow *between these two* — both put a cache in the path and so both clear the requirement the tunnel incumbents fail; statelessness and supplier count are the only difference left (§2) |
| Reliability under impairment (R5) | **neither, once substrate-matched — they trade cells** | **M** | **measured head-to-head across the lane × controller matrix and then re-measured on a shared substrate. Loss does not separate the lanes given the same controller (1.04 and 0.96 on BBR to 10 %; 0.17 and 0.13 on CUBIC), so the familiar "segment fetching degrades under loss" result is a controller comparison. **Reordering, the one axis that did separate them, no longer does**: the 0.98-against-0.19 cell gave the segmented lane 34 kB packets against the media-aware lane's 931 B ones and `netem` reorders per packet, so equalised it reads 0.44 on TCP, **0.18 on HTTP/3 and 0.13 media-aware — overlapping**. On the shared substrate the segmented lane instead wins loss (0.70 against 0.10 on TCP at ~20 % applied) and the 30 s outage (0.76 against 0.51), and under *sustained* under-capacity it delivers 0.79 against the media-aware lane's 0.46 by taking lateness where the other discards programme** (§3.1) |
| Reliability of recovery (R5) | segmented HTTP | M+S | **retry now exercised under loss, and it splits: no resilience of *rate*, and resilience of *content* only while the client stays inside the origin's availability window** — 0 continuity errors and 0 PCR intervals above 40 ms throughout a ladder to 10 % loss, so within the window the lane sheds time rather than data. A deeper ladder crosses the window between 7.7 % and 12.2 % applied loss, after which the client re-anchors and leaves 7–82 s holes — and past ~20 % loss it does so without the origin returning a single error, so the failure is silent at the serving node. Edge and Pathway selection remains specification-only (§3.2) |
| Redundancy — serving node (R5) | **segmented HTTP** | **M** | **decisive on the protocol, blocked on the tooling.** Both lanes resume within a few seconds of the node returning; the difference is that the media-aware exporter skips to the live edge and loses the media produced during the outage, where the segmented client refetches it from the store and loses nothing. But neither TSDuck's HLS input nor FFmpeg's demuxer survives an origin restart at all — both abandon at the first failed playlist reload — so it took a purpose-written client to show (§3.2) |
| Redundancy — 1+1 source failover (R5) | **segmented HTTP, conditionally** | **M** | **the sharpest divergence measured. A pair sharing one feed and one naming scheme fails over with no measurable interruption, 3/3 runs identical, needing no receiver-side merge; the media-aware floor is one detection interval (30–33 s default, ~10 s tuned) and hitless is unreachable by relay reselect. Conditional because a *misconfigured* segmented pair is accepted silently and delivers ±20 s time-travel that passes every continuity and PCR-interval check, where the relay refuses the same mistake outright** (§3.3) |
| Reassembly to a transport stream | segmented HTTP | M | clear — off the shelf in TSDuck and ffmpeg against MoQ's single `moq export ts` (§4.2) |
| Grooming *burden* (R3) | **MoQ** | **M** | **the same groomer absorbs ~240× coarser bursts and 24 multi-second silences on segmented HTTP; against RIST and SRT the two split, MoQ on burst size and the tunnels on worst-case silence** (§4.3, §10.1) |
| Grooming *outcome* — a P1-conformant wire (R3) | **neither — both reach it, at different costs** | **M** | **the MoQ lane's long-standing failure here is closed. It posted 489–504 intervals above 40 ms at *every* cushion, unchanged by depth or by the path, and the diagnosis that this was a carriage defect the lane must pay for was wrong twice over: the exporter's three PCR fixes did not clear it either, and what did was the groomer reserving a slot for the PCR instead of taking only slots the content scheduler declined — a burst declines none, so all 71 over-40 ms intervals in a graded output contained zero null slots. The lane now returns **0 of 20,193 intervals above 40 ms over 300 s, 0 continuity errors and exact CBR**. Segmented HTTP reaches the same standard at the 8 s cushion its segment duration already imposes; MoQ at a buffer set by the peak coded frame (~3.6× its carriage duration, content-dependent). Neither is verified on hardware, and the MoQ result is scoped to **minutes**: its edge stage's release loop departs at about nine minutes and collapses its own cushion, invisibly to the wire ([T21](../lab/test-21-permanence-soak.md))** (§5.1) |
| Latency (R4) | **MoQ, decisively** | **M** | **decisive and now measured: 109 ms across the public internet, against SRT's 1,618 ms and segmented HTTP's 4,067 ms over the same path in the same window — 15× and 37×. Segmented HTTP needs 9,286 ms to reach the depth that makes it conformant. The path term is the round trip and nothing more. Caveats: delivery latency rather than camera-to-display, and both paths measured were healthy** (§5, §5.1, [Evidence](evidence.md) §3.11) |
| Interoperability (R1) | segmented HTTP | M+S | decisive, conditional on the single-programme envelope (§6) |
| Entitlement and control (R7) | MoQ | R | narrow — enforcement point and session observability, not revocation speed (§7) |
| Carriage fidelity, one programme (R1) | neither, on mux content; **SRT on the clock, and it is the only one measured over a real path** | M | **a wash on content across three clips — service identity, PMT/PCR PID, CAT, TDT/TOT, all splice PIDs and stuffing all survive — so MoQ's content advantage narrows to the untested multi-programme case. Segmented HTTP alone is *additive*: one PAT/PMT pair per segment, costing 109–302 µs of file-domain PCR accuracy that grooming then closes. On the clock the incumbent wins outright: byte-faithful SRT reproduces the source mux rate, PSI cadence and PCR grid over the public internet with 0 P2 violations, where the media-aware lane preserves the mux as bytes and destroys it as a timed object** (§8) |
| Wire volume | **MoQ** | M+derived | ~7.0 %, MTU-invariant — 0.982× against 1.056× over HTTP/3; §8's fidelity trade priced (§9) |
| Delivery economics | segmented HTTP | S(published rates) | decisive, and it swamps the row above — commodity delivery at $0.005–0.010/GB against one MoQ supplier at $0.050 (§9) |
| Operational maturity | segmented HTTP | R+M | decisive — mature multi-vendor tooling and existing staff skills against a pre-1.0 ecosystem |

**What that adds up to.** For a route whose destinations can absorb two to five seconds and which
carries a single programme, segmented HTTP carrying MPEG-TS is the better engineering choice today —
on interop, maturity, delivery economics and recovery, none of which is close; on carriage fidelity,
where its mux content turns out to be verbatim; and on the conformance of the groomed stream itself.

**One qualification belonged on that sentence and has now been discharged.** The segmented lane's
intended production form is HTTP/3, and the impairment cells have since been re-run on it, against an
origin with no TCP listener at all. The outcome does not change the recommendation but does change its
grounds: segmented HTTP no longer wins the impairment row on reordering — equalised, that axis does not
separate the lanes — and instead wins loss, outage recovery and behaviour under sustained
under-capacity, while losing nothing unimpaired, where the two substrates are byte-identical. **The
recommendation now rests on interop, maturity, delivery economics and recovery**, which is a broader
and more durable base than the single impairment cell it used to rest on. What is still measured only
over HTTP/1.1 is everything outside those impairment cells; wire cost remains derived for H3 and stated
as derived, and interop, economics, maturity and carriage fidelity do not turn on the substrate. **MoQ's case is not general and should not be stated as though it were.** Measurement
narrowed it and sharpened it at the same time. What is left is: an egress that hands a groomer less to
absorb, verbatim *multi-programme* carriage, a portable enforcement point with an observable session, push
rather than manifest polling, ~7 % less wire volume — and a **measured 109 ms** across the public
internet, which is a 15× margin on the axis that decides the comparison for routes that cannot absorb
seconds.

**Two warnings about reading any single row.** MoQ moves ~7 % fewer bytes and today those bytes cost
five to ten times as much, so the axis it wins there is worth a rounding error against the axis it loses.
And the two rows that decide the comparison now point in opposite directions for the same lane: MoQ wins
latency decisively and loses the conformance of the groomed wire decisively, and those two facts are
independent of each other (§5.1). A reader who treats either as the price of the other will reach the
wrong conclusion, which is the mistake this document made until the latency work was done.

**And the part that matters more than the verdict.** Every item that makes either data plane
*broadcast-grade* is common to both: PCR and CBR grooming to TR 101 290, 1+1 with byte-identical legs
and receiver-side selection, ST 2022-7 pairing, entitlement and multi-tenant control, observability
in broadcast terms, and interop with the MPEG-TS installed base. Neither specification addresses any
of it. That is why this is framed as an evaluation of Internet-native primary distribution on two
candidate data planes rather than as a case for one protocol, and why the measured work in
[Evidence](evidence.md) transfers between them.

### 14.1 The framework the final conclusion has to satisfy

The verdict above is a scorecard of what has been measured. The conclusion this study is working
toward is a different object: **not which data plane is better, but whether each is viable for
permanent primary distribution, and under what conditions each is preferable.** Those are separable
answers — both may be viable, and the interesting output is then the boundary between them rather than
a winner.

Setting the framework down before the remaining evidence arrives is deliberate. It fixes what would
count as an answer while the answer is still unknown, which is the only time that decision can be made
honestly.

**Viability is a gate, not a score.** A data plane is viable for primary distribution if it clears
every one of these; failing one is disqualifying regardless of how it reads elsewhere.

| Gate | Cleared when | MoQ today | Segmented HTTP today |
|---|---|---|---|
| **Conformant egress** | Groomed output passes TR 101 290 P1/P2 on hardware, sustained | **Cleared in software over minutes, not sustained.** Over 300 s: 0 of 20,193 intervals > 40 ms, 0 continuity errors, 0 groomer drops, exact CBR, 0 PCRs outside ±500 ns. Needed all three upstream PCR fixes *and* a groomer that reserves the PCR slot, estimates the media rate as a ratio of sums and closes its release loop on buffer occupancy. Costs a buffer sized by the peak coded frame (~3.6× its carriage duration), content-dependent. **At ~9 min that release loop departs and the cushion collapses to zero while the wire stays conformant** ([T21](../lab/test-21-permanence-soak.md)) — a `mpegts-pacer` defect, not an upstream or architectural one, but the *sustained* half of this criterion is now failed rather than untested. Hardware unverified | **Cleared in software** at an 8 s cushion (0 intervals > 40 ms); never soaked; hardware unverified |
| **Permanent operation** | Stable operating state over ≥ 7 days, every resource series flat or converged | **Partial.** 14 h clean on delivery; relay memory converging but not flat, publisher threads still growing | **Unknown.** Never soaked |
| **Deterministic recovery** | A bounded, known quantity of programme lost per failure class, no manual intervention | **Partial.** Recovery is fast but lossy — the exporter resumes at the live edge and discards the outage | **Partial.** Refetches losslessly inside the availability window, silently holed past it |
| **Redundancy to R6** | Receiver-side selection yielding no visible failure during contracted content | **Cleared for single-track**, byte-identical across independent hosts; not for a multi-programme mux | **Cleared conditionally** — hitless when configured correctly, silent time-travel when not |
| **Fan-out to R2** | Marginal cost per destination approaching zero, with a known scaling model | **Indicated.** Audience is not a memory term; the measured knee is the host's, not the relay's | **Indicated.** Cache offload measured at one node, not at a CDN |
| **Operable at fleet scale** | A fault in one of hundreds of feeds is localisable from telemetry | **Unassessed** | **Unassessed** |

**Preference is a comparison, and it is conditional on the route.** Where both gates clear, these are
the dimensions on which one should be chosen over the other, each stated as the question that decides
it rather than as a claim:

- **Latency budget of the route.** Below ~2 s, only MoQ is in contention on the numbers measured
  (109 ms against 4,067 ms, and 9,286 ms at the depth that makes the segmented lane conformant). Above
  ~5 s the axis stops discriminating. The band between is where a low-latency segmented configuration
  would compete, and no free receiver realises it.
- **Number of programmes per feed.** Multi-programme carriage is MoQ's remaining fidelity advantage
  and it is normatively excluded on HLS. If the route carries an MPTS the question may not be open.
- **Whether the destination estate is fixed or open.** Segmented HTTP interoperates with everything;
  MoQ interoperates within one implementation. This is the widest measured margin in the study and it
  is the one least likely to be closed by an experiment here.
- **Delivery volume and its price.** Commodity delivery at $0.005–0.010/GB against one MoQ supplier at
  $0.050/GB swamps MoQ's ~7 % wire-volume advantage by an order of magnitude. At what volume the
  supplier market changes is a commercial question, not a measurement.
- **The impairment profile of the path.** The one axis on which the lanes genuinely separate, and the
  one whose measurement is not substrate-matched — see §3.1. Until the HTTP/3 arm runs, this dimension
  cannot be used to choose.
- **Redundancy topology available.** Whether the operator can run independent chains end to end
  (favours MoQ's byte-identical 1+1) or would rather rely on multiple delivery paths to one object
  store (favours segmented HTTP, if F7 demonstrates it).
- **Operational estate.** Existing HTTP tooling, staff skills and vendor support against a pre-1.0
  ecosystem with no operational precedent.

**Three conclusions this framework is designed to permit, and which must not be foreclosed.** That
both are viable and the choice is a route-by-route engineering decision. That neither is viable
without an edge stage the distributor owns, which is already the strongest measured finding and is
common to both. And that one is viable and the other is not — which, on today's evidence, would be
decided by the conformance gate rather than by any comparative row, and is the reason the merged-build
PCR verification outranks every comparison in the programme.

---

## 15. Open questions

Ranked by how much each would move the comparison.

1. **Do the groomed egresses pass TR 101 290 P1/P2 on real hardware, sustained?** §5.1. This replaces
   the exporter-cadence question, which is answered twice over. An evenly spaced exporter cadence does
   *not* clear the P1 repetition gate — every PCR domain is now fixed upstream and the wire still carried
   12.2 % of intervals above 40 ms — but the gate is cleared by the groomer reserving the slot rather
   than waiting for a spare one, and the MoQ lane now returns **0 of 20,193 intervals above 40 ms over
   300 s with 0 continuity errors and exact CBR**. Both lanes are therefore conformant in software over
   the windows measured and neither has been near an IRD, which makes hardware the highest-leverage
   item outright. It is blocked on apparatus rather than on either project. On the MoQ lane a second
   item is now ahead of it in time order though not in leverage: the groomer holds that wire while its
   own release loop comes apart at about nine minutes ([T21](../lab/test-21-permanence-soak.md)), so
   the software result is established over minutes and not over hours.
2. **Does a commercial ABR-to-TS gateway, operated as the distributor's own edge stage, produce
   TR 101 290 P1/P2-conformant output on real hardware?** §4.4. If yes, part of the broadcast-grade
   layer is purchasable on one data plane and not the other; if no, the reassembly advantage in §4.2
   is all that is left of the hand-off axis. It is also the only candidate receiver that could
   realise a low-latency TS-in-HLS route at all.
3. **Does the sub-second requirement exist on identifiable routes, or is it a preference?** §5.2.
   This decides how much of primary distribution MoQ addresses at all.
4. **Can a CDN carry a multi-programme TS segment in practice, and does anything downstream of the
   cache object to it?** §8. This now carries the whole of MoQ's carriage-fidelity advantage on mux
   *content*, since single-programme carriage measured as a wash. What it does not carry is the clock
   half of §8, which is settled and small: the segment-head PAT/PMT injection costs file-domain PCR
   accuracy on segmented HTTP and grooming closes it.
5. **Should the edge gateway sit at each client's demarcation or in the distributor's regional
   PoPs?** §4.5. The choice sets how many destinations the transport actually serves, and therefore
   most of the delivery bill, on both data planes.
6. **How does a segmented-HTTP leg behave when segments are genuinely lost rather than late?** §3.2.
   The retry model itself has been exercised: a ladder to 40 % loss crosses the availability window
   between 7.7 % and 12.2 % applied loss, after which the client re-anchors and leaves 7.2 s, 24 s and
   82 s holes, silently past ~20 %. What remains specification-only is *edge and Pathway selection* —
   whether a second edge, a redundant origin or a Content Steering pathway can serve what the first
   could not. Its *carriage* over a real path has been measured, and reproduced loopback to 0.1 % (§8).
7. **Why does the media-aware lane cluster PCRs?** §8. The distribution — 86 % of intervals under 1 ms,
   monotonic, mean conserved, gaps to 320 ms — points at group-wise reassembly, but the mechanism is
   inferred from the output rather than confirmed in the exporter. It matters because if PSI density and
   PCR spacing are both group-derived, one parameter moves both, and the groomer depth question in
   §5.1 is really a question about group size.
8. **Would relay portability, if achieved, change the economics enough to matter against a delivery
   market that is already commoditised?** MoQ's strongest economic argument is contingent on an
   interoperability fix ([Evidence](evidence.md) §3.7), and its prize is a market position segmented
   HTTP already occupies everywhere except the sub-second band.
