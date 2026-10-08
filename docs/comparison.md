# Candidate Data Planes Compared

Status: working draft.
Layer: **the data-plane choice** — this document *is* the layer where the candidates differ.
Scope: [Problem](problem.md) §5 states the requirement set; this document evaluates the candidates
against R1–R7, and against the point-to-point incumbents, on the axes an operator decides on. R6 and R7
appear only as far as the *data plane* decides them; the broadcast-grade engineering above the
transport, common to both candidates and where nearly all the measured work sits, is
[Architecture](architecture.md) and [Control plane](control-plane.md). R8 is not a data-plane axis.
Every measurement cited here is stated with its measurement point, domain and build in
[Evidence](evidence.md); this document carries the argument.

**The conclusion, first.** For most primary-distribution routes there are *two* viable Internet-native
data planes. They differ most on latency, and the margin depends on the conformance the comparison is
held at: **at the only configuration each has been measured TR 101 290 P1-conformant in, MoQ delivers a
picture over one internet path in 2,447 ms and segmented HTTP in 9,286 ms** ([Evidence](evidence.md)
§3.11). That settles which plane a route in the two-to-nine-second band should use, and nothing else.
**Neither plane is an unconditional choice.** Segmented HTTP leads on most of the remaining axes —
maturity, delivery economics and the delivery path's interoperability — but those advantages are
upstream of the receiver, and this evaluation did not establish a receiver path from segmented HTTP back
to an IRD-ready transport stream (§4.6, §6.1). Everything that makes either plane *broadcast-grade* sits
above the transport and is common to both ([Problem](problem.md) §1). **Below about two seconds no plane
here is demonstrated conformant over a whole capture**, so MoQ's sub-second case is architecturally
credible and not yet evidenced (§5.1).

The demanding comparator is **segmented HTTP carrying MPEG-TS**: specified, interoperable along the
whole delivery path, commodity-delivered today, and with an off-the-shelf path back to a transport
stream at classic segment durations — though nothing free receives the low-latency variant, and no
off-the-shelf client survives an origin restart (§3.2, §11) — where MoQ has one implementation.
Point-to-point incumbents set a low bar on fan-out (§10).

---

## 1. The candidates

| Candidate | What it is here | Class |
|---|---|---|
| **MoQ** | `moq import ts` → relay fabric → `moq export ts`, on QUIC/WebTransport | live publish/subscribe with native relay |
| **Segmented HTTP** | HLS carrying MPEG-TS segments (and DVB-DASH), over HTTP/2 or HTTP/3 | cacheable-object pull over commodity delivery |
| **SRT / Zixi / RIST** | a reliable UDP tunnel per destination, optionally through a gateway tier | point-to-point session transport |

They are grouped by *scaling shape*, not by quality, which flatters two of them: RIST is openly
specified and multi-vendor where the others are not (§10.1). **All three rows assume the IP path carries
the whole feed**; the satellite-hybrid architectures of VSF TR-06-4 Parts 7 and 8, where RIST carries
only the bytes a site lost, answer a different question and are treated in §10.2.

Two exclusions. **TS-over-HTTP/1.1**, a continuous TS in a chunked response, has no agreed specification
and several incompatible implementations, so choosing it buys a vendor rather than a protocol. **WebRTC/SFU**
does not carry an MPEG-TS at all. Segmented HTTP is assessed against [HTTP Live Streaming 2nd
Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
(`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS), quoted from
the normative text because practitioner convention diverges from it in both directions (§13).

---

## 2. Scaling the distribution (R2)

**Fan-out separates both Internet-native candidates from the point-to-point incumbents; between the two
of them it is barely an axis.** Tunnel architectures run out near 50 destinations
([Problem](problem.md) §2.3) against a requirement of hundreds to low thousands. An HTTP edge cache and a
MoQ relay share one topology — fetch once, serve N unicast connections — so both clear R2, neither breaks
last-mile linearity ([Economics](economics.md) §4.4), and what remains is who operates the replication
point (§10).

| | Segmented HTTP | MoQ | SRT / Zixi / RIST |
|---|---|---|---|
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, a dozen suppliers, today | one CDN today, at five to ten times commodity delivery; otherwise you | you, or a managed media service |
| Known hard ceiling | none at this scale | **relay CPU**, linear up to it and a collapse past it: 124–139 subscribers per core on `moq-relay` 0.14.15 (quinn), about 100 on a 2-vCPU `moq-relay` 0.15.1 (noq) with GSO off; cross-host, in one region ([Evidence](evidence.md) §3.6) | AWS MediaConnect: 50 outputs per flow |
| Marginal cost of a destination | a cache fill: shared upstream, one egress copy | **1.258 % of a relay core, 2.62 MB and one full stream copy** on `moq-relay` 0.15.1 with GSO on, linear | a session's worth of gateway CPU and one egress copy |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network — consumer, not affiliate, distribution | none | none |

**Statelessness is the only differentiator between the two, and a reliability advantage in disguise**
(§3): a destination can move between edges or suppliers mid-stream, where losing a MoQ or SRT relay loses
a session. Per-subscription state also prices churn in relay memory, which a static segmented origin
does not pay ([Evidence](evidence.md) §3.14) — a structural advantage, bought with the latency of §5, that
an origin terminating sessions or personalising responses would give up.

---

## 3. Reliability (R5)

Two questions: *behaviour under impairment* (§3.1) and *recovery when something fails* (§3.2–§3.3). The
second favours segmented HTTP and matters more for a trunk.

### 3.1 Under impairment: loss separates the controllers, and once the lanes are substrate-matched nothing cleanly separates the lanes

Low-Latency HLS **requires** HTTP/2 or HTTP/3, so on HTTP/3 both lanes share QUIC, its per-stream loss
isolation and RFC 9218 priorities; MoQ differs in the object and subscription model above it. Measured
head-to-head under one shaper ([Evidence](evidence.md) §3.3):

- **Loss is a controller result, not a lane result.** At 10 % loss both lanes hold full rate on BBR (1.04
  segmented, 0.96 media-aware) and both collapse on CUBIC (0.17 and 0.13), so "segment fetching degrades
  under loss" compares TCP's default controller with QUIC's tuned one. On HTTP/3, through a byte-faithful
  receiver, the segmented lane loses nothing up to ~20 % applied loss.
- **Reordering ranks controllers, not lanes**: equalised for packet size, the segmented lane on HTTP/3
  keeps a quarter of the stream whatever the controller, and the media-aware figure moves across the
  whole range on one controller flag ([T20](../lab/test-20-segmented-http3.md)).
- **Outage recovery is the origin's retention**, not the transport: under a 30 s outage the two substrates
  are byte-identical.
- **Trunking contended feeds is a latency decision**: media-aware feeds at a 2 s budget deliver less in
  total than one, because each subscriber discards groups past its own deadline, and SRT converts the
  same shortfall into continuity errors. The media-aware lane's shortfall shows only as absent content,
  since its exporter writes its own counters.
- **Under sustained under-capacity the segmented lane takes lateness** at 0 continuity errors, invisible
  to an integrity monitor, until the origin evicts the segment it asks for — a cliff where the
  media-aware lane has a slope.

Past 7.7–12.2 % applied loss the segmented lane's HTTP/1.1 client re-anchors and leaves holes of 7.2 s,
24 s and 82 s, silently past ~20 % ([T5](../lab/test-5-network-impairment.md)). **Against SRT, matched on
measured latency and graded on content, the media-aware lane loses more programme under every shape
measured**, by a margin its build and QUIC stack set.

### 3.2 On recovery: segmented HTTP has the more robust model

Segmented HTTP gives each segment a **defined availability window** (HLS §4.4.3), so a failed fetch can be
retried idempotently from another edge or Pathway without the sender. MoQ's reliability is scoped to a
live subscription and a deliberately shallow relay cache ([Evidence](evidence.md) §3.4). **This favours
segmented HTTP in the protocol, and the tooling does not deliver it**: no off-the-shelf TS client survives
an origin restart ([T6](../lab/test-6-relay-resilience.md)), and Content Steering is specification-only.
An origin killed for ten seconds costs the segmented lane no content, where the media-aware exporter
skips to the live edge. Across a *transport* outage the media-aware lane recovers nearly all of the
content from the relay cache, but pays in a latency step that does not reverse, where SRT holds its
latency and discards the content: the two are billed in different currencies ([Evidence](evidence.md)
§3.3).

**Neither lane's transport reports a stalled source, and only the segmented one offers a substitute**: its
playlist media sequence stops advancing, which a poller can alarm on without parsing media
([Evidence](evidence.md) §3.12) — a monitoring hook, not a self-reporting transport.

### 3.3 Where broadcast actually gets its reliability, and why it is common to both

Broadcast reliability comes from **1+1 with selection at the receiver**, which is transport-independent
([Architecture](architecture.md) §5, [Evidence](evidence.md) §3.4). Head-to-head the lanes diverge.
**Serving-node failover**: media-aware relay reselection takes 30–33 s at the idle-timeout default of the
builds measured and ~10 s tuned, 10 s being the default from moq 0.14.0, and is never hitless; a segmented
pair sharing one feed and one set of segment names fails over with no measurable interruption, 3/3 runs.
**Misconfiguration**: a segmented pair with mismatched sources delivers ±20 s of time-travel that passes
continuity and PCR checks, where the media-aware relay refuses. On the media-aware lane a hitless pair is
built at the receiver; on the segmented lane it falls out of a shared source and a naming convention.

---

## 4. The hand-off (R3)

### 4.1 What the obligation actually is

**The deliverable is a clean, paced MPEG-TS at the hand-off — the distributor's obligation on either data
plane** ([Problem](problem.md) §1.5). Neither HLS nor MoQ specifies PCR, CBR, stuffing or null packets,
and both deliver in bursts that fail TR 101 290 without grooming ([Evidence](evidence.md) §3.2) — the
conformance the installed base enforces, as accepted practice rather than anything observed here. TR 101
290 does not grade the 13818-1 buffer model, which a conformant stream must also satisfy, and grooming
re-times packets without reordering them, so it cannot supply that model where the delivered packet order
breaks it (§8).

### 4.2 Reassembly: off the shelf for segmented HTTP, single-implementation for MoQ

**Segmented HTTP has an off-the-shelf reassembly stage:** TSDuck `tsp -I hls` / `tsp -O hls`, FFmpeg.
**MoQ has one implementation:** `moq export ts`, continuity counters rendered from process state
([Evidence](evidence.md) §3.4). MoQ reassembly is simpler to write than a manifest state machine, but for
an operator already written usually wins.

### 4.3 Grooming: a heavier burden on segmented HTTP, the better measured result there, and the only lane an off-the-shelf stage can groom

**Segmented HTTP inherits the grooming problem in full, and worse, by two orders of magnitude**
([Evidence](evidence.md) §3.8):

| Ungroomed egress | MoQ | Segmented HTTP (2 s segments) | RIST / SRT |
|---|---|---|---|
| Median burst | 12.4 kB | **2.95 MB** | 30.6 kB — the source's, not the protocol's |
| Gaps above 1 s in 60 s | **none** | **24** | **none** |
| Largest gap | 149 ms | **4.01 s** | **~35 ms** |
| 10 ms peak/mean | 24× | **231×** | 3.4× |

**MoQ hands the smallest bursts and the tunnels the shortest silences**; a groomer's buffer is sized by
the first and its start gate by the second. **One groomer covers both lanes**: the same binary, no flags
changed, takes segmented egress to TR 101 290 conformance on the wire, at the cost of 7.5 s before the
first byte and ~9 s to detect a dead origin, and fails below the segment period (311 continuity errors at
a 1 s cushion, clean at 8 s; [T16](../lab/test-16-grooming-segmented-http.md)). **Off the shelf, only the
segmented lane can be groomed**: against four criteria fixed in advance, every candidate behind MoQ fails
a different one, while behind a segmented egress `tsp -P pcradjust -P regulate -O ip` passes all four
with the mux carried byte-for-byte, because the packager slices the TS it was given with its stuffing,
mux rate and PCR spacing intact ([T13](../lab/test-13-downstream-grooming.md)). A mux-preserving groomer
is required on both paths.

### 4.4 What the IRD vendors' HLS inputs are, and are not

Professional IRD and edge-gateway platforms list HLS/DASH inputs with ABR-to-TS conversion (Ateme TITAN
Edge, Synamedia MEG — **vendor datasheet claims, unmeasured**). That is a supply-chain option on the
distributor's own side, not a reason to assume the hand-off problem is solved at the client's
demarcation. Whether such a stage passes TR 101 290 on hardware is open
([planned-experiments](../lab/planned-experiments.md)).

### 4.5 Where the demarcation puts the gateway

Gateway *placement* moves fan-out arithmetic: at each client's demarcation the transport serves every
client; in regional PoPs it serves every PoP ([Economics](economics.md) §4.5,
[Architecture](architecture.md) §4.4). Open architectural decision; neither data plane is favoured.

### 4.6 The honest verdict on this axis

Three claims are run together under "hand-off". **Receiving** favours segmented HTTP at classic segment
durations — off the shelf, with ABR-to-TS boxes purchasable (conformance unmeasured, §4.4) — and reverses
at low latency, where nothing free receives TS-in-HLS (§6.1). **Grooming burden** favours MoQ, and
**which stage can carry it** favours segmented HTTP (§4.3). **The groomed wire** is a tie on P1/P2 and not
on its cost: both reach 0 PCR intervals above 40 ms in software, segmented at the 8 s cushion its segments
impose and MoQ at a buffer sized by the source's peak coded frame, MoQ at 2,447 ms against 9,286 ms and
soaked for a day where the segmented lane never has been. The two are not equally tight: MoQ's conformance
and latency come from one configuration, while the segmented zero is a local groomer run and its internet
cell posts 2 marginal intervals ([Evidence](evidence.md) §3.11). **The tie is P1/P2's alone**: at the
buffer model the media-aware wire fails and the segmented one is ungraded (§8).

---

## 5. Latency (R4)

**This is the axis on which the two data planes differ most, and the size of the difference depends on
the conformance it is held at.** Where no plane is P1-conformant, MoQ delivers a picture over one
internet path in **109 ms** against segmented HTTP's **4,067 ms**; at the only configuration each has been
measured conformant in, MoQ delivers in **2,447 ms** and segmented HTTP in **9,286 ms**
([Evidence](evidence.md) §3.11). The gap between the Internet-native planes survives conformance at about
3.8×, and MoQ's 37× headline does not. **Every latency figure on the media-aware lane must be quoted with
the conformance of the same bytes.** All are *delivery* latency, source to groomed egress, excluding the
encoder and decoder delay that no plane here varies.

**Segmented HTTP's floor is arithmetic, not implementation quality.** `PART-HOLD-BACK` MUST be at least
twice, and SHOULD be at least three times, the part target, and production part targets sit around
200–330 ms, so the hold-back alone is roughly 0.6–1 s before encode, packaging, delivery and the
gateway's de-jitter buffer. The specification warns that a shorter target "reduces latency but also
reduces available buffer, handicaps adaption and increases delivery overhead, increasing the likelihood
of playback stall." Two to five seconds is the realistic envelope, and **with MPEG-TS and free tooling it
is nearer six**, because no free client that turns HLS back into a transport stream fetches parts
([Evidence](evidence.md) §3.9).

### 5.1 Latency and PCR conformance are independent axes, and the lane still pays for conformance in latency

**Cushion depth does not buy conformance; the edge stage does.** An eightfold cushion ladder leaves the
lane's PCR repetition unchanged. What clears the gate is a groomer that reserves the PCR slot instead of
waiting for a spare one, which never comes inside a frame-sized burst, plus a media-rate estimate and a
release loop closed on occupancy: the wire then returns 0 of 20,193 intervals above 40 ms over 300 s, and
0 over 24.01 h with the 33-bit rollover crossed ([Evidence](evidence.md) §3.2).

**The conformant configuration delivers at 2,447 ms, an order of magnitude above the 109 ms, and neither
part of the gap is cushion depth.** About **650 ms is a named upstream regression** — the exporter PCR
change that made an even grid possible moved delivery latency from 120.0 to 771.6 ms against the same
control ([T19](../lab/test-19-pcr-grid-verification.md) measurement 6) — a defect with an owner, and
recoverable. **The rest is structural**: the buffer is sized by the source's peak coded frame, not its
bitrate, because a demultiplexed lane cannot recover the encoder's VBV occupancy that the source's byte
spacing carried. **The media-aware lane moves the encoder's VBV budget downstream into the edge gateway's
buffer** — content-dependent, sizeable from a published encoder parameter, and not removable by tuning.

**Both the conformance and the 2,447 ms are P1/P2's**; the same wire fails the 13818-1 buffer model (§8).
The stages that repair it present at **2,196.7 ms** (a laboratory re-multiplexer, moq 0.12.1) and
**2,272.5 ms** over 540 s at a 1 s delay (upstream's fixed-delay export in its last draft before merge
`[unmerged]`, which at 500 ms stops 157 s into a 540 s run), both on loopback and both presentation
latency, which does not subtract from delivery latency ([Evidence](evidence.md) §3.16).

**At equal P1/P2 conformance MoQ keeps a decisive margin over segmented HTTP and none over the tunnels.**
Byte-faithful SRT carries the source's own PCR grid over the public internet with 0 P2 violations at
481 ns, ungroomed, at a latency the operator sets — **1,618 ms at a 1 s jitter buffer**, and reducible
([Evidence](evidence.md) §3.1). **So the sub-second band, the one hard technical discriminator MoQ has
over the incumbents ([Economics](economics.md) §7.4), is not demonstrated at conformance on MoQ, and no
configuration below one second has passed a whole capture on any lane.** Byte-faithful carriage comes
closest — 113.7 ms over UDP after a damaged first 5 s, and 234.0 ms over SRT with one unrecovered burst
in 288 s, on loopback — which weighs against MoQ, and the ~650 ms defect bounds that in MoQ's favour. Both
paths were healthy, so nothing exercised the recovery the tunnels exist for, and **neither lane has been
graded on a hardware IRD** ([Evidence](evidence.md) §4).

**A deployment constraint separate from latency.** On the September 2026 builds measured, every placed
PCR-timeline class crosses the lane at the control's content gap. From moq 0.14.0 a backward timestamp
step ends the import by design, flagged or not, and upstream plans an in-process restart for the flagged
case only. moq 0.12.8 publishes a continuous source whose content restarts but has not had its placed
classes re-measured, so no build is *measured* to carry both cases, and a deployment must pin the build
or republish at each backward step ([Evidence](evidence.md) §3.13).

### 5.2 The decision rule, restated

**Segmented HTTP is the better engineering choice only where two conditions hold together**: the route's
destinations absorb seconds — nearer six unless an ABR-to-TS receiver is bought — **and** the receive
path to an IRD-ready transport stream is supplied separately. Then it wins on maturity, delivery
economics and delivery-path interoperability, and narrowly on the hand-off. **Between roughly 2.5 and
9 seconds MoQ is the better choice**, measured at P1/P2 conformance; at the buffer model the band is not
yet compared, since segmented HTTP's wire is ungraded. **Below about two seconds no plane here is
demonstrated conformant**, and a sub-second route is choosing MoQ on a projection — that the ~650 ms
regression is recovered, that the VBV-derived bound is smaller for its own content, and that the lane
delivers frames ahead of their decode time, where its own transit and ordering take about 1.6 s before
any rebuild. **MoQ's distinguishing claim is architecturally credible and not yet evidenced.**

**Whether that claim matters is a condition of MoQ's case specifically: does the sub-second requirement
exist on identifiable routes, or is it a preference?** "A few seconds tolerable" is true of the feed's
own integrity and understates the transition: replacing a geostationary path with a 2–5 s one consumes a
downstream budget that was previously free, at every destination — splice and blackout timing, alignment
between affiliates on different paths during a migration, live handback, and re-distribution — so it has
to be answered per route by the destination.

---

## 6. Interoperability (R1)

**Segmented HTTP wins the delivery path decisively, and "interoperable" has to say which layer it
means.** HTTP bytes pass through every CDN and cache, where MoQ's relay is a protocol implementation and a
MoQ feed carries no media through any of the eight other registered public relays, for at least four
distinct causes ([Evidence](evidence.md) §3.7). **Delivery-path interop and multi-programme carriage are
mutually exclusive on segmented HTTP**: "Transport Stream Segments MUST contain a single MPEG-2 Program."
HLS requires only PAT and PMT, where MoQ threads SDT, NIT, EIT and TDT/TOT through its catalog. SCTE-35
has a specified `EXT-X-DATERANGE` mapping, and CMCD/CMSD give client reporting MoQ has no equivalent of —
though they carry request and buffer state rather than delivered-media integrity, so **neither plane lets
an origin establish that what a subscriber received was intact** ([Architecture](architecture.md) §9.4).

### 6.1 Five layers, and they do not resolve the same way

| Layer | Segmented HTTP | MoQ |
|---|---|---|
| **Cache and CDN carriage** | clears, through a dozen suppliers (§2) | one CDN operates a relay; no feed traversed anyone else's |
| **General-purpose client reception** | clears, and is why the format is ubiquitous | within one implementation |
| **Low-latency TS-in-HLS reception** | **no free implementation** — both free TS-capable clients fetched zero parts ([Evidence](evidence.md) §3.9) | not applicable; no segment period |
| **A receive stage yielding a transport stream the groomer can take** | classic HLS: off the shelf (§4.2); low latency: commercial ABR-to-TS only, **conformance unmeasured** (§4.4) | `moq export ts`, free and single-implementation |
| **Hardware-verified conformance of that hand-off** | **not run** | **not run** |

**The first two layers are segmented HTTP's, decisively; the third and fourth are the unresolved
condition on that plane, and the fifth is unresolved on both.** Its interoperability advantage is real,
large and located upstream of the receiver, and a route cannot bank it as a receiver path unless that
path is supplied separately.

---

## 7. Entitlement and access control (R7)

**MoQ's advantage is real but narrow, and on revocation latency MoQ loses.** MoQ's revocation is a poll
whose tightest worst case is **about 1.7 s measured and 2.11 s as documented** ([Evidence](evidence.md)
§3.10). Low-latency segmented HTTP re-fetches the playlist every part target, so where the CDN authorizes
each request the bound is **0.28–0.30 s** against the part durations measured here
([T14](../lab/test-14-data-plane-comparison.md)): on worst case **MoQ is roughly six to seven times
worse**; three plausible MoQ configurations disable revocation altogether, and an authorization outage
is tolerated for an hour by default ([Control](control-plane.md) §4.1). It is not a verdict: the
segmented figure is **derived**, not measured against a revocation, and holds only where the CDN checks
**every request** rather than issuing a token with its own lifetime. What differs otherwise is **where enforcement lives and whether the
session is observable** — at the relay, portable and queryable, or at the CDN through per-supplier
machinery inferred from logs. MoQ's enforcement is exact and measured; the segmented half is an
architectural reading.

---

## 8. Carriage fidelity (R1)

| | Segmented HTTP | MoQ media-aware lane | MoQ opaque lane | SRT — the incumbent |
|---|---|---|---|---|
| Multi-programme mux | **normatively excluded** (§6) | **flattened** by builds up to moq 0.12.8; **split** into one intact broadcast per programme on upstream `main` from late September 2026, each SDT still listing every service | **verbatim by construction**; measured on one programme | verbatim by construction; measured on one programme |
| PIDs, PSI, service identity, SDT/NIT, EIT schedule | **preserved**, non-default PIDs included; the 8-day EPG byte-identical | preserved; a joining receiver has the whole EPG in ~1 ms | preserved | **preserved** — measured over the wire; EIT not exercised |
| TDT/TOT, CAT | **preserved** | TDT/TOT **~14 s late** on moq 0.9.11, a merged fix unmeasured; CAT not carried | preserved | **preserved**; CAT not exercised |
| Continuity counters, stuffing, mux rate | preserved, except a forced re-stamp on the injected PAT/PMT | counters regenerated; stuffing not the source's, padded to the declared source rate (+0.36 %, file domain) | carried if verbatim | **preserved; the source mux rate exactly** |
| PSI cadence, packets added | source cadence plus **one PAT/PMT pair per segment** | **regenerated thinner** — 8.04 → 2.51 PAT/s against P1's 500 ms gap | unchanged; nothing added | **identical; nothing added** |
| PCR repetition (P1) and accuracy (P2) | repetition unchanged; accuracy **37–74 ns → 109–302 µs** from the injected pair, **0 violations once groomed** | repetition produced by the lane and conformant only behind a groomer that reserves the slot (§5.1); accuracy **fails on every PCR** ungroomed | unmeasured; byte-preserving by construction | **0 violations at 481 ns**, ungroomed — measured over the wire |
| Packet schedule (T-STD), wire | source order carried; **not graded** | **discarded**: the P1/P2-conformant groomed wire fails the transport and audio decoder buffers on every build graded, moq 0.10.0 to 0.13.0; rebuilt by a re-multiplexer, and by upstream's export in its last draft before merge `[unmerged]`; the export as merged is ungraded ([Evidence](evidence.md) §3.16) | preserved by construction; *reasoned* to survive only behind a stream-clocked egress | **preserved** through the same groomer in every 2 s window, and over a whole capture through its stream-clocked mode |
| TS-level scrambling | carried as bytes; reasoned | **cannot be carried** — the publisher parses PES headers scrambling hides; specified | carried by construction | carried by construction |
| Byte-identical to source | **in payload, yes; as a mux, no** | no | yes | every field, count and cadence measured identical, not diffed byte-for-byte |

Internet-measured for segmented HTTP, media-aware MoQ and SRT ([T4](../lab/test-4-remote-e2e-srt.md));
breadth on three clips on loopback ([T3](../lab/test-3-opaque-transparency.md)); EIT on a synthetic
fixture ([T17](../lab/test-17-si-snapshot-tracks.md)); figures and qualifications in
[Evidence](evidence.md) §3.1. **Single-programme mux content on segmented HTTP is as verbatim as the
opaque MoQ lane** — the only difference in a 1,200-packet window is byte 3 on one PAT and one PMT — and
**its clock is not**, which grooming closes at the demarcation (§4.1).

**The media-aware lane is a transmux lane, and for TS-out it has three structural limits.** It loses the
packet layout, which is why the encoder's VBV budget moves into the groomer's buffer (§5.1). Its
subscriber becomes the multiplexer, re-solving the T-STD schedule the source had already solved, which a
pacing groomer cannot do — **not insurmountable**, since a laboratory re-multiplexer does it live, and
upstream's fixed-delay export, merged in October 2026, does it in the subscriber, its last draft before
merge having kept every track and buffer on every join tried (§5.1). And it **cannot carry a scrambled
stream**. Byte-faithful carriage has none of the three by construction; on MoQ that is the opaque lane,
with one loopback measurement and no open subscriber (§12).

**Scrambling is a narrow gate.** Primary distribution is protected by the transport and the operator
([Control plane](control-plane.md) §7.3), and consumer conditional access is applied downstream of the
IRD, so the gate binds only a route that must hand a feed to the IRD **still scrambled** — a BISS-class
scheme held end to end, or a third-party feed the distributor may not descramble — and there it is
binary.

**MoQ's remaining mux-content advantage is multi-programme carriage alone, and only on the opaque lane**,
unmeasured on one. Against the media-aware lane segmented HTTP keeps stuffing, CAT, continuity counters
and wall clock, and **fidelity costs ~7 % wire volume** on both planes (§9).

---

## 9. Economics

Fully modelled in [Economics](economics.md).

**Wire volume favours MoQ by ~7 %** — §8's fidelity trade: **0.982×** media-aware against **1.056×**
segmented HTTP/3 (derived) and **1.037×** SRT ([Evidence](evidence.md) §3.5). Only declining verbatim
carriage sits below 1.0×; the off-the-shelf packager retains stuffing. HTTP overhead is 0.06 %, and
HTTP/3 costs ~2.6 points more than HTTP/2 on TCP.

**Destination count decides the bill, not the transport** ([Economics](economics.md) §4.4). **The
delivery market decides the level:** commodity CDN at $0.005–0.010/GB against one MoQ supplier at
$0.050/GB ([Economics](economics.md) §4.6).

---

## 10. SRT and RIST: scaling is possible, and that is not the differentiator

**SRT can be scaled** through a gateway tier ([Economics](economics.md) §4.3), but **no commodity market
sells SRT to the destination** — only ingest at the CDN door, with fan-out from there over segmented HTTP.
The SRT-against-MoQ difference is who operates the replication point and which market prices it (§2), so
**MoQ's advantage over SRT is segmented HTTP's advantage**, plus the narrow sub-second claim. Zixi adds a
per-GB licence.

### 10.1 RIST, which deserves better than being listed alongside SRT

RIST (VSF TR-06) is the **strongest point-to-point transport** here: openly specified and multi-vendor,
RTP-native, with native dual-path protection. On the hand-off it ties SRT on worst-case silence (~35 ms
against MoQ's 149 ms and segmented HTTP's 4.01 s) and passes the source's bursts through (§4.3). **It fails
the same way as SRT**: fan-out is N sessions the operator runs, and multicast is for managed networks. For
tens of destinations over owned transit RIST may beat both candidates; the Internet-native case is about
**reach and cost at scale**.

### 10.2 Satellite-hybrid: a resolution that keeps the satellite

**The satellite-hybrid specifications ask RIST to carry only what the satellite lost.** VSF TR-06-4 Part 7
(in-band) and Part 8 (out-of-band) keep satellite as the primary one-to-many path; the receiver detects
loss in the satellite transport stream, requests the affected range from a buffered *recovery server* over
RIST, and splices it in, with a full-stream IP fallback for a complete fade. Part 7 marks blocks on an
unreferenced private PID, so detection is specified but repair is per block and the uplink needs an
inserter; Part 8 leaves the stream unmodified and requests by PCR and duration, but leaves detection to
the implementer, so two conformant receivers may disagree about what was lost.

| Model | What the IP path carries | Marginal cost of destination N |
|---|---|---|
| C-band satellite primary | nothing | ~0 inside the footprint |
| **Ku-band satellite + RIST repair** | only the blocks a site lost, while it is losing them | ~0 inside the footprint, plus that site's repair traffic |
| Internet-native (MoQ, segmented HTTP) | the whole feed, to every destination, always | one unicast copy (§2) |
| Point-to-point tunnels | the whole feed, to every destination, always | one session and one copy |

The hybrid keeps satellite's near-zero marginal cost and spends fade margin to do so: rain attenuation rises
with frequency (ITU-R P.838, P.618), so Ku fades more than C band (*specified*), and repair buys the
margin back selectively. The pressure to leave C band is a US regulatory driver (FCC 20-22).

**Its defence is that full-IP capacity scales as sites × rate × always and repair as faded sites × rate ×
fade duration**, which holds in the average and fails on four conditions, the decision boundary.
**Sizing follows the correlated peak**: one weather system fades many sites at once, and a duty cycle
reduces bytes, not committed capacity ([Economics](economics.md) §6.1). **Availability is a joint
probability, unevidenced here**: severe weather stresses local access and power where it fades a
downlink. **The receiver is the gate**: legacy IRDs keep decoding the satellite stream unrepaired until
the client installs hybrid receivers ([Problem](problem.md) §1.5). **It resolves nothing the footprint
already limited**: per-destination feeds, reach, event topologies and entitlement. It is also strictly
worse on R4 than plain satellite, since Part 7's informative sizing guidance bounds the receiver buffer
below by the satellite latency plus repair margin, and how it compares with §5.1 depends on a buffer the
specifications do not fix and nobody here has measured. And it relocates the conformance problem: Part 8
concedes that splicing recovered data without re-stamping PCRs risks exceeding 13818-1's ±500 ns, a
grooming function at the receiver.

**MoQ has no equivalent mechanism and is not asked the same question**: neither the IETF MoQ charter nor
`draft-ietf-moq-transport-19` addresses loss in a parallel unidirectional path (*specified*, by
absence), and named objects are a substrate for range repair only in *reasoning*. Part 7 was approved in
July 2025 and revised in December 2025, Part 8 in June 2026, with implementation evidence limited to
vendor announcement and single-vendor demonstration. **Nothing in §10.2 is measured here**, which is why
§14.1 frames the model as a competing resolution rather than scoring it.

---

## 11. The toolchain: what is free, and the one stage that is not

Ingest (TSDuck `tsp`), egress FEC and ST 2022-7, analysis and the control plane are identical on both
planes and the distributor's ([Architecture](architecture.md)). **Where the two differ they are
incomplete in opposite places, and every stage has a free implementation except receiving low-latency
HLS back into a transport stream** ([Evidence](evidence.md) §3.9):

| Stage | MoQ | Segmented HTTP | Commercial option |
|---|---|---|---|
| **Publish / package** | `moq import ts` (media-aware), or an opaque lane under MSFTS | classic `tsp -O hls`; low-latency TS through Apple `mediastreamsegmenter` | — |
| **Fan-out** | `moq-relay`; Cloudflare's implementation | any HTTP origin and cache, or a commodity CDN | — |
| **Receive → TS** | `moq export ts` | classic: `tsp -I hls`, FFmpeg; low latency: **nothing free** | low-latency HLS: Synamedia MEG, Ateme TITAN Edge; MoQ: **none** |
| **Groom → CBR, PCR re-stamped, mux preserved** | [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer), conformant on the wire (§5.1) | the same binary, no flags changed; or TSDuck `pcradjust` + `regulate` | Synamedia, Ateme, Harmonic gateways |
| **CBR TS → paced wire** | [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts), `mpegts-pacer` | identical | the same gateways |

The receive row is the layer §6.1 leaves open, and it points both ways: the free low-latency receiver is
MoQ's, the commercial one segmented HTTP's. Extending TSDuck's `hls` input for partial segments is in
[planned-experiments](../lab/planned-experiments.md).

---

## 12. The MoQ implementation landscape

*Assessed from repositories and public documentation; the measured cross-implementation result is in
[Evidence](evidence.md) §3.7.*

| | `moq-dev` | `moq2ts` / `moqxr` | Cloudflare `moq-rs` | This work |
|---|---|---|---|---|
| Lane | media-aware (+ opaque prototype) | **transparent TS** | none — transport only | **transparent TS** + grooming |
| Scope | publisher, relay, subscriber | **publisher only** | protocol library, **relay**, sample clients | publisher + egress + pacer |
| Media format | `hang` catalog/container | MSF + MSFTS (`packaging: "m2ts"`) | **deliberately none** | verbatim TS |
| Format standing | individual draft for its `mpegts` catalog section (demultiplexed carriage only) | **adopted WG format** + individual draft | N/A | internal |
| Wire versions | moq-lite 01–06, 07 opt-in and in progress; **MOQT 14–22** | MOQT 16, 18 | MOQT 14, 16 and 18 | inherits `moq-dev` |
| Source failover | route reselection; a 1+1 pair declared by a shared publisher epoch (`--epoch`), which only the opt-in moq-lite 07 carries on the wire | N/A (publisher) | **none — publisher loss is terminal** | relies on `moq-dev` |
| Deployment | self-hosted | self-hosted | **managed, provisioned by API** | self-hosted |

**No one else does the broadcast-specific layer** — PCR egress, CBR grooming, TR 101 290 conformance.
Transparent carriage is no longer single-vendor, but **transparent is not verbatim** (`moq2ts` strips
nulls). Cloudflare's format-blind relay cannot corrupt opaque TS, but thins less intelligently under
pressure and ends a broadcast with its publisher ([Architecture](architecture.md) §5).

**No open implementation subscribes to whole-TS carriage**, as of October 2026: `moq2ts` and `moqxr`
publish only, `moq-dev`'s "verbatim" tracks carry undecoded PIDs one per track inside the media-aware
lane, and the opaque prototype measured here is private. Byte-faithful carriage over MoQ is therefore not
runnable against an open receiver, which is why §8's structural limits do not by themselves move the
preference to the opaque lane, and relay-level interop with `moqxr` holds only narrowly
([Evidence](evidence.md) §3.7).

---

## 13. Seven readings the comparison corrects

The measurement rules behind them are in [`lab/method-notes.md`](../lab/method-notes.md).

- **TS-in-HLS is not new** — MPEG-TS was HLS's original container; Low-Latency mode added partial
  segments.
- **QUIC is not decisive** — Low-Latency HLS requires HTTP/2 or HTTP/3, and MoQ differs in the object
  model above QUIC (§3.1).
- **Client-side HLS inputs do not discharge the distributor's grooming obligation** (§4.1).
- **TS segments are verbatim in payload, not as a mux** — one inserted PAT/PMT pair costs PCR accuracy
  (§8).
- **Stuffing retention is not optional on segmented HTTP** — stripping it would forfeit the §8 advantage
  (§9).
- **Transparent tunnels pass the source's cadence; MoQ re-paces** — 30.6 kB bursts against 12.2–12.4 kB
  whatever the source (§4.3).
- **Sub-second MoQ delivery is measured, and not at conformance** — 109 ms on a wire that is not
  P1-conformant, against 2,447 ms conformant (§5.1). A latency figure and a conformance figure must come
  from the same bytes.

---

## 14. Verdict, axis by axis

Read "favours" as *today*, on the evidence in this repository and the current specifications. **Basis**:
**M** measured here, **S** specification, **V** vendor datasheet, **R** reasoning, **—** none.

| Axis | Favours | Basis | Margin |
|---|---|---|---|
| Scaling the distribution (R2) | segmented HTTP | R+S | narrow *between these two*; statelessness and supplier count are the difference (§2) |
| Reliability under impairment (R5) | **neither, once substrate-matched** | **M** | a controller result, not a lane result; **against SRT** the media-aware lane loses more programme under every shape measured, by a margin its build and QUIC stack set (§3.1) |
| Reliability of recovery (R5) | segmented HTTP, in the protocol | M+S | resilience of *content* inside the availability window, not of *rate*; past it, silent holes (§3.2) |
| Redundancy — serving node (R6) | **segmented HTTP** | **M** | **decisive in the protocol, unmet by off-the-shelf tooling**, since no off-the-shelf TS client survives an origin restart (§3.2) |
| Redundancy — 1+1 source failover (R6) | **segmented HTTP, conditionally** | **M** | **the sharpest divergence measured**: hitless for a shared-feed segmented pair, one detection interval or more on the media-aware lane, whose `--epoch` pairing is ungraded; conditional because a misconfigured segmented pair is accepted silently (§3.3) |
| Reassembly to a transport stream | **segmented HTTP at classic segment durations; MoQ at low latency** | M | below the segment period the free receiver is MoQ's (§4.2, §6.1) |
| Grooming *burden* (R3) | **MoQ** | **M** | segmented egress is ~240× coarser; against the tunnels, MoQ wins on burst size and they on silence (§4.3) |
| Grooming *outcome* — a P1-conformant wire (R3) | **neither — both reach it, at different costs** | **M** | MoQ for a day at a peak-coded-frame buffer; segmented HTTP at its segment-imposed cushion; neither on hardware, and **P1/P2 alone**: MoQ's wire fails the T-STD and segmented HTTP's is ungraded (§4.6, §8) |
| Latency (R4) | **MoQ over segmented HTTP, decisively; MoQ over the tunnels, not at conformance** | **M** | 109 ms where nothing is conformant; **2,447 against 9,286 ms at P1/P2 conformance**, while the tunnels carry their source's grid at a latency the operator sets; **nothing conformant below ~2 s over a whole capture** (§5.1) |
| Interoperability (R1) | **segmented HTTP on the delivery path; not established on the receive path** | M+S | decisive through caches and general clients, for a single programme; the low-latency receive path is unmet or unmeasured (§6.1) |
| Entitlement and control (R7) | MoQ | R | narrow — enforcement point and session observability, not revocation speed (§7) |
| Carriage fidelity, one programme (R1) | neither on mux content; **SRT on the clock, the only one measured over a real path** | M | a wash on content; the media-aware lane is a transmux whose conformant wire fails the T-STD (M) and which cannot carry a scrambled feed (S) (§8) |
| Wire volume | **MoQ** | M+derived | ~7.0 %, MTU-invariant (§9) |
| Delivery economics | segmented HTTP | S (published rates) | decisive, and it swamps the row above (§9) |
| Operational maturity | segmented HTTP | R+M | decisive — mature multi-vendor tooling and staff skills against a pre-1.0 ecosystem |

**Neither column adds up to a winner.** For routes that can absorb five seconds or more, carry a single
programme, **and have a receive path to an IRD-ready transport stream from somewhere other than this
evaluation**, segmented HTTP is the better engineering choice. **MoQ's case is route-specific and
narrower than its headline latency**: smaller bursts for the groomer, multi-programme carriage, portable
enforcement, ~7 % less wire volume — a rounding error against five-to-ten× delivery cost — and, at equal
P1/P2 conformance, a decisive margin in the two-to-nine-second band that is not a sub-second result.
**Broadcast-grade work is common to both** and sits above neither specification.

### 14.1 The framework the final conclusion has to satisfy

**Viability is a gate, not a score** — whether each plane can serve permanent primary distribution, and
under what conditions each is preferable.

| Gate | Cleared when | MoQ today | Segmented HTTP today |
|---|---|---|---|
| **Conformant egress** | Groomed output is a conformant transport stream on hardware, sustained — TR 101 290 P1/P2 and the 13818-1 buffer model | **Not cleared on the media-aware lane.** P1/P2 holds in software for a day, and the same wire fails the T-STD, which only a re-multiplexing stage repairs (§5.1, §8); no build is measured to carry every timeline case. Not on hardware | **P1/P2 cleared in software** on a local groomer run; buffer model ungraded; never soaked; not on hardware |
| **Scrambled feed to the IRD** | Where a route requires it, a feed under TS-level conditional access reaches the IRD still scrambled | **Excluded on the media-aware lane** (specified); a narrow gate (§8) | By construction as bytes (reasoned); not exercised |
| **Permanent operation** | Stable operating state over ≥ 7 days, every resource series flat or converged | **Partial: a day, on two builds, never a week** — delivery and conformance on moq 0.11.2, resources on moq 0.12.8 ([Evidence](evidence.md) §3.6) | **Unknown.** Never soaked |
| **Deterministic recovery** | A bounded, known quantity of programme lost per failure class, no manual intervention | **Partial.** Fast but lossy — the exporter resumes at the live edge | **Partial.** Lossless inside the availability window, silently holed past it |
| **Redundancy to R6** | Receiver-side selection yielding no visible failure during contracted content | **Cleared for single-track**; for a multi-track mux only for a co-started pair behind the export's last draft `[unmerged]` ([Evidence](evidence.md) §3.4) | **Cleared conditionally** — hitless when configured correctly, silent time-travel when not |
| **Fan-out to R2** | Marginal cost per destination approaching zero, with a known scaling model | **Indicated.** Linear to the relay's CPU, in one region (§2) | **Indicated.** Cache offload at one node, not a CDN |
| **Operable at fleet scale** | A fault in one of hundreds of feeds is localisable from telemetry | **Unassessed** | **Unassessed** |
| **Delivered-media health at a subscriber** | An origin can tell that what a subscriber *received* was intact | **Not satisfied by any candidate** ([Architecture](architecture.md) §9.4) | **Not satisfied** |
| **A receive stage at the route's latency budget** | A stage turns the delivered feed back into a transport stream at the latency the route allows | **Cleared, single-implementation** (§11) | **Cleared at classic segment durations, open below them** (§6.1) |

**Preference is conditional on the route** — its latency budget, whether it must deliver a feed still
scrambled, its programmes per feed, its destination estate, the delivery price, its impairment profile,
its redundancy topology and its operational estate, each argued above. Both planes may be viable;
neither without a distributor-owned edge stage, and neither as an unconditional choice. Conformance on
hardware remains the deciding gate for both, and the receive path decides segmented HTTP specifically.

**These two are not the only choice on the table.** The satellite-hybrid model of §10.2 keeps the
broadcast medium and puts IP behind it only for repair. It is not scored because nothing about it is
measured here, but it is strongest exactly where both planes are weakest — a large estate inside one
footprint on a common always-on feed — and a route that reads "incumbent" on destination count in
[Economics](economics.md) §6 is one where it is the live alternative.

---

## 15. Open questions

Ranked by leverage:

1. **Hardware TR 101 290 on groomed egresses, sustained?** Both are P1/P2-conformant in software and
   neither has been near an IRD; on the media-aware lane it would also show how far receivers tolerate a
   wire that fails the buffer model (§5.1, §8).
2. **Can a transmux subscriber keep a T-STD-conformant wire live across hosts and for 1+1?** Open: the
   merged export graded per track, a laboratory stage following a remote clock, and deterministic
   scheduling for a late-joining leg ([Evidence](evidence.md) §3.4, §3.16). It decides whether the lane
   serves TS-out to an IRD in a deployment; its comparator, segmented HTTP's wire graded against the same
   model, has not been run either.
3. **A P1/P2-conformant sub-second configuration on any lane?** It decides whether MoQ has a technical
   discriminator over the incumbents at all, and on MoQ it turns on the ~650 ms regression, the
   peak-coded-frame bound for real contribution content and frames delivered ahead of decode (§5.1).
4. **A commercial ABR-to-TS gateway on hardware?** The condition segmented HTTP's route-level case rests
   on (§4.4, §6.1).
5. **Sub-second requirement: routes or preference?** It decides MoQ's addressable share, and is a
   commercial question (§5.2).
6. **MPTS in TS segments in practice?** MoQ's remaining mux-content advantage (§8).
7. **Edge gateway at the demarcation or at a regional PoP?** It sets the delivery bill (§4.5).
8. **Genuine segment loss against lateness?** Content Steering is specification-only (§3.2).
9. **Relay portability against commoditised delivery economics?** ([Evidence](evidence.md) §3.7).
10. **A real estate's fade and connectivity profile?** The satellite-hybrid case turns on correlated fades
    and on whether IP availability is independent of fade at each site (§10.2).

---

## 16. References

The implementations and specifications this comparison assesses. Where a row is graded rather than
described, the grading is in [Evidence](evidence.md) §3.7 (interop) and §3.1 (carriage).

**Implementations**

- `moq-dev` — media-aware lane; publisher, relay, subscriber: https://github.com/moq-dev/moq
- Cloudflare `moq-rs` — IETF-aligned transport library and production relay, media-agnostic: https://github.com/cloudflare/moq-rs
- Cloudflare MoQ relay service and provisioning API: https://developers.cloudflare.com/moq/
- `moq2ts` — transparent MPEG-TS publisher: https://github.com/openmoq/moq2ts
- `moqxr` / OpenMOQ Publisher: https://github.com/mondain/moqxr
- [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) — MPEG-TS VBR-to-CBR grooming stage (§11)
- `rawsendmpeg2ts` — datagram sender: https://github.com/EDIS-mx/rawsendmpeg2ts

**Standards and formats**

- IETF MOQ working group: https://datatracker.ietf.org/group/moq/about/
- MOQT Streaming Format (MSF), adopted WG draft: https://datatracker.ietf.org/doc/draft-ietf-moq-msf/
- CMSF (CMAF profile of MSF): https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/
- MSFTS (MPEG-TS profile): https://github.com/mondain/msfts
- HTTP Live Streaming 2nd Edition — obsoletes RFC 8216, includes Low-Latency HLS and MPEG-TS segment carriage: https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/
- DVB-MABR, adaptive media streaming over IP multicast (ETSI TS 103 769): https://dvb.org/?standard=adaptive-media-streaming-over-ip-multicast

**Satellite-hybrid (§10.2)**

- VSF TR-06-4 Part 7, RIST Satellite-Hybrid: In-Band Method — approved July 2025, revised December 2025: https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-7_2025-12-10.pdf
- VSF TR-06-4 Part 8, RIST Satellite-Hybrid: Out-of-Band Method — approved June 2026: https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-8_2026-06-04.pdf
- VSF Technical Recommendations index, for the TR-06 family and current revisions: https://vsf.tv/technical-recommendations/
- RIST Forum, the activity group's own material: https://www.rist.tv/
- ITU-R P.838, specific attenuation model for rain — the frequency dependence behind the C-to-Ku fade argument: https://www.itu.int/rec/R-REC-P.838/
- ITU-R P.618, propagation data and prediction methods for Earth–space telecommunication systems: https://www.itu.int/rec/R-REC-P.618/
- ITU-R P.837, characteristics of precipitation for propagation modelling — the rainfall statistics a per-site fade estimate needs ([Economics](economics.md) §6.1): https://www.itu.int/rec/R-REC-P.837/
- FCC 20-22, *Expanding Flexible Use of the 3.7 to 4.2 GHz Band*, GN Docket 18-122 — the C-band clearing and fixed-satellite repack: https://docs.fcc.gov/public/attachments/FCC-20-22A1.pdf

**Background**

- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html
- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
