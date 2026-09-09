# Candidate Data Planes Compared

Status: working draft.
Layer: **the data-plane choice** — this document *is* the layer where the candidates differ.
Scope: the head-to-head this repository owes its own thesis. [Problem](problem.md) §5 states the
requirement set; this document evaluates the candidates against R1, R2, R4 and R5, and against the point-to-point
incumbents, on the axes an operator actually decides on. The layer above the transport — where
nearly all the measured work sits, and which is common to both candidates — is
[Architecture](architecture.md).

**The conclusion, first.** For most primary-distribution routes there are *two* viable Internet-native
data planes. They differ most on latency, and the margin depends on the conformance the comparison is
held at: **held at the only configuration each has been measured TR 101 290 P1-conformant in, MoQ
delivers a picture over one internet path in 2,447 ms and segmented HTTP in 9,286 ms**
([Evidence](evidence.md) §3.11, §3.2). That settles which plane a route in the two-to-nine-second band
should use, and nothing else. **Neither plane is an unconditional choice.** Segmented HTTP leads on
most of the remaining axes — maturity, delivery economics and the delivery path's interoperability —
but those advantages are upstream of the receiver, and this evaluation did not establish a receiver
path from segmented HTTP back to an IRD-ready transport stream (§4.6, §6.1). Everything that makes
either plane *broadcast-grade* sits above the transport and is common to both
([Problem](problem.md) §1). **Below about two seconds no plane here is demonstrated conformant**, so
MoQ's sub-second case is architecturally credible and not yet evidenced (§5.1).

The demanding comparison is **segmented HTTP carrying MPEG-TS**: specified, interoperable along the
whole delivery path, commodity-delivered today, with an off-the-shelf path back to a transport stream
at classic segment durations — nothing free receives the low-latency variant, and no off-the-shelf
client survives an origin restart (§3.2, §11) — where MoQ has one implementation. Point-to-point
incumbents set a low bar on fan-out (§10). Measured on the axes below, segmented HTTP is ahead of MoQ
on most of them, and the axes it is ahead on stop at the receiver (§6.1).

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

**TS-over-HTTP/1.1** — a continuous TS in a chunked HTTP response — is excluded because there is no
agreed specification; several vendors implement it incompatibly, so choosing it buys a vendor rather
than a protocol. It cannot serve as the *specified* baseline this comparison needs (§13).

**WebRTC/SFU** is excluded because its media model does not carry an MPEG-TS at all, so the hand-off
problem it creates is a different one.

Segmented HTTP is assessed against [HTTP Live Streaming 2nd
Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
(`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS), and quoted
from it rather than from convention, because practitioner convention diverges from the normative text
in both directions — see §13.

---

## 2. Scaling the distribution (R2)

**Fan-out separates both Internet-native candidates from the point-to-point incumbents; between the two
of them it is barely an axis.** Tunnel architectures run out near 50 destinations ([Problem](problem.md)
§2.3); the requirement is hundreds to low thousands. **Both candidates put a cache in the path and clear
R2; what remains is who operates the replication point** (§10). An HTTP edge cache and a MoQ relay share
the same topology — fetch once, serve N unicast connections — and neither breaks last-mile linearity
([Economics](economics.md) §4.4).

| | Segmented HTTP | MoQ | SRT / Zixi / RIST |
|---|---|---|---|
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, from a dozen suppliers, today | one CDN today, at five to ten times commodity delivery; otherwise you | you, or a managed media service |
| Adding a destination | a cache fill nobody provisions | a subscription and its relay state | a gateway output slot, and sometimes an instance |
| Known hard ceilings | none at this scale | **relay CPU, at 124–139 subscribers per core** (~1.2–1.34 Gb/s of egress) measured cross-host, linear up to it and a hard collapse past it rather than a graceful thinning ([Evidence](evidence.md) §3.6) — still our own rig, and two availability zones in one region at 0.72 ms RTT. Relay memory grows per ingested group and plateaus softly, at a ceiling whose scaling term is open by a factor of two. Separately, **subscription churn costs the relay ~1.8 GB in 60 s** at 40 crashing receivers — retained sessions, not cache, and tunable through the idle timeout (§3.14) | AWS MediaConnect: 50 outputs per flow |
| Marginal cost of a destination | a cache fill: shared upstream, one egress copy | **0.806 % of a relay core, 1.39 MB of relay memory and one full stream copy** — linear, with no superlinear term and no per-subscriber cache duplication (§3.6) | a session's worth of gateway CPU and one egress copy |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network | none | none |

Only statelessness is a differentiator between the two Internet-native candidates.

**Statelessness is segmented HTTP's scaling advantage and a reliability advantage in disguise** (§3):
a segment is a named resource, so destinations can move between edges or suppliers mid-stream without
re-establishing a session. MoQ and SRT fan-out is stateful — losing a relay loses a session.

Per-subscription state costs the relay memory under churn — forty crashing receivers every five seconds
take it from 87 MB to 1.9 GB in 60 s ([Evidence](evidence.md) §3.14) — but buys no access to anyone
else's stream; well-behaved subscribers stayed within 8 KB of a control across 198 MB at zero
continuity errors. The idle timeout prices the exposure. The segmented lane's half is unrun.

**Nobody here does point-to-multipoint at the last mile.** DVB-MABR is specified and deployed, but
inside an access network the operator controls — consumer distribution, not affiliate distribution
(§10).


---

## 3. Reliability (R5)

Two questions: *behaviour under impairment* (§3.1) and *recovery when something fails* (§3.2–§3.3). The
second favours segmented HTTP and matters more for a trunk.

### 3.1 Under impairment: loss separates the controllers, and once the lanes are substrate-matched nothing cleanly separates the lanes

Low-Latency HLS **requires** HTTP/2 or HTTP/3, so on HTTP/3 both lanes share QUIC, per-stream loss
isolation and RFC 9218 priorities — QUIC is necessary for both and distinguishes neither; MoQ differs
in the object and subscription model above it (§13). Both lanes were measured head-to-head under one
shaper across lane × controller; the delivered-rate matrix is in [Evidence](evidence.md) §3.3.

**Loss is a controller result, not a lane result.** Down a column the lanes match — at 10 % loss both
hold full rate on BBR (1.04 segmented, 0.96 media-aware) and both collapse on CUBIC (0.17 and 0.13).
The claim that segment fetching degrades under loss where MoQ does not is TCP's default controller
against QUIC's tuned one.

**Reordering was the one axis that separated the lanes; on a shared substrate it does not.** The
0.98-against-0.19 cell gave the segmented lane 65536-byte loopback packets while the media-aware lane
had GSO disabled: **1,209 packets averaging 34,380 bytes against 29,062 averaging 931 bytes.**
`netem` reorders per packet, so the winner met ~24× fewer events. Equalised across all three arms
([Evidence](evidence.md) §3.3, [T20](../lab/test-20-segmented-http3.md)):

| 25 % reordering, 3 replicates | Segmented / TCP | Segmented / **HTTP/3** | Media-aware / QUIC |
|---|---|---|---|
| Equal packet sizes | 0.44 | **0.18** | **0.13** |
| As originally measured | 0.995 | 0.995 | 0.125 |

Original conditions reproduce exactly — sound measurement, wrong reading. **On HTTP/3 the lanes
overlap**; on TCP the segmented lane keeps a smaller advantage. HTTP/3 costs reordering and wins loss
(0.10 on TCP against **0.70** on HTTP/3 at ~20 % applied loss) and the 30 s outage (0.51 against
**0.76**); unimpaired, byte-identical output ([T20](../lab/test-20-segmented-http3.md)).

**Trunking several feeds down one congested path is a third result — a latency decision, not a lane
defect.** Two or three media-aware feeds at a 2 s subscriber budget deliver less in total than one
(9.44 Mb/s against 5.39 and 4.48) while SRT rises to 12.65 Mb/s; widening `--latency-max` from 500 ms
to 30 s takes the two-flow aggregate under `cake` from 4.29 to 10.35 Mb/s at **0 continuity errors**,
where SRT under the same queue discipline converts the shortfall into ~26,000 continuity errors. A
trunk must be provisioned in latency as well as rate ([Evidence](evidence.md) §3.3).

**Segmented HTTP did not corrupt what it delivered at any loss level:** 0 continuity errors and 0 PCR
intervals above 40 ms in every *loss* cell, including where it delivered a sixth of the stream. Inside
the availability window it sheds *time*, not *bytes*; past 7.7–12.2 % applied loss the client re-anchors
and leaves holes of 7.2 s, 24 s and 82 s — silently past ~20 % loss when the origin returns only 200s
([T5](../lab/test-5-network-impairment.md)). The ladder arm was a single origin over HTTP/1.1; on
HTTP/3 the same lane holds 0.70 at ~20 % applied loss where TCP holds 0.10.

**Under sustained capacity shortfall the lanes fail differently.** At 8 Mb/s against a 9.95 Mb/s
stream, segmented arms deliver 0.79–0.81 (lateness); the media-aware lane delivers 0.46 (discarded
programme). Transient degradations are absorbed by all three ([Evidence](evidence.md) §3.3). The
media-aware lane's PCR non-conformance sat unchanged at 7.9–9.2 % in every cell — a groomer defect since
fixed, and independent of the impairment either way (§5.1).

### 3.2 On recovery: segmented HTTP has the more robust model

Segmented HTTP gives each segment a **defined availability window** (HLS §4.4.3): a failed fetch can
be retried idempotently from another edge or Pathway for a specified period without the sender's
involvement. MoQ's reliability is scoped to a live subscription; recovery depends on a deliberately
shallow relay cache ([Evidence](evidence.md) §3.4). **For a trunk this favours segmented HTTP in the
protocol:** byte-completeness at the hand-off becomes cache retry rather than live session management
— and the tooling does not yet deliver it, which is the qualification below.

Retry under loss splits: no resilience of *rate* (controller sets that — §3.1), but resilience of
*content* inside the availability window — byte-verbatim and P1-clean throughout the ladder to 10 %
loss. An origin killed for ten seconds costs **no content** on the segmented lane (refetch from store);
the media-aware exporter skips to the live edge and loses the outage. **No off-the-shelf TS client in
the rig survives an origin restart** — TSDuck and FFmpeg abandon at the first failed playlist reload —
so a purpose-written client was needed ([T6](../lab/test-6-relay-resilience.md)). Edge and Pathway
selection under Content Steering remains specification-only.

### 3.3 Where broadcast actually gets its reliability, and why it is common to both

Broadcast reliability comes from **1+1 with selection at the receiver** — transport-independent
([Architecture](architecture.md) §5, [Evidence](evidence.md) §3.4). Head-to-head, the lanes diverge
sharply:

- **Serving-node failover:** media-aware relay reselect takes 30–33 s by default (~10 s tuned); hitless
  by relay reselect is unreachable. A segmented active/active pair sharing one feed and segment names
  fails over **with no measurable interruption**, 3/3 runs under hard kill ([T6](../lab/test-6-relay-resilience.md)).
- **Misconfiguration:** a segmented pair with mismatched sources delivers ±20 s time-travel that passes
  continuity and PCR checks; the media-aware relay refuses and tears down.

On the media-aware lane a hitless pair must be built at the receiver; on the segmented lane it falls
out of a shared source and a naming convention.

---

## 4. The hand-off (R3)

### 4.1 What the obligation actually is

**The deliverable is a clean, paced MPEG-TS at the hand-off — the distributor's obligation on either
data plane** ([Problem](problem.md) §1.5). Neither HLS nor MoQ specifies PCR, CBR, stuffing or null
packets; both deliver in bursts that fail TR 101 290 without grooming ([Evidence](evidence.md) §3.2),
which is the conformance the installed base enforces ([Problem](problem.md) §1.2) — accepted broadcast
practice rather than something this campaign observed, since no hardware has been fed by this chain.
The comparison is between distributor-side toolchains, not client estates.

### 4.2 Reassembly: off the shelf for segmented HTTP, single-implementation for MoQ

**Segmented HTTP has an off-the-shelf reassembly stage:** TSDuck `tsp -I hls` / `tsp -O hls`, FFmpeg.
**MoQ has one implementation:** `moq export ts`, continuity counters rendered from process state
([Evidence](evidence.md) §3.4). MoQ reassembly is simpler to write (subscription plus object
reassembly); segmented HTTP carries a manifest state machine — for an operator, already written usually
wins.

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

Silences arrive at segment duration; MoQ delivers in every second, segmented HTTP alternates nothing
and 20–30 Mb/s.

**One groomer covers both** when it sizes its buffer from what arrives — the same binary, no flags
changed, takes segmented-HTTP egress to TR 101 290 conformance **on the wire** (0 intervals above 40 ms,
0 PCR violations at 481 ns; [Evidence](evidence.md) §3.2, [T16](../lab/test-16-grooming-segmented-http.md)).
Cost: 7.5 s before the first byte, 13.1 MB buffer, ~9 s to detect a dead origin (§5.1).

RIST/SRT in the third column are **transparent** — 30.6 kB is the publisher's, not the protocol's.
**MoQ hands the smallest bursts; the tunnels the shortest silences** — buffer depth vs start gate.
Burst size is segment size, coupled to latency; partial segments publish free but **no free client
fetches them** ([Evidence](evidence.md) §3.9).

**On this lane, off-the-shelf tools do the whole job — and that is a difference between the two data
planes rather than a fact about MPEG-TS.** Every candidate an engineer would reach for was graded
against four criteria fixed in advance — mux preserved, PCR inside 481 ns, no interval above 40 ms,
honest duration on a rate-controlled wire — against both egresses. Behind MoQ each fails a different
one. Behind a segmented egress, `tsp -P pcradjust -P regulate -O ip` passes all four with the mux
carried byte-for-byte.

The packager slices the TS it was given — stuffing, mux rate and PCR spacing intact (0 intervals above
40 ms vs 163 on MoQ egress) — so `tsp -P pcradjust -P regulate` need only own a clock
([T13](../lab/test-13-downstream-grooming.md)). Below the segment period the failure is not graceful: 1 s
cushion → 1.85 s silences and 311 continuity errors vs clean at 8 s. A mux-preserving groomer is
required on both paths.

### 4.4 What the IRD vendors' HLS inputs are, and are not

Professional IRD and edge-gateway platforms list HLS/DASH inputs with ABR-to-TS conversion (Ateme
TITAN Edge, Synamedia MEG — **vendor datasheet claims, unmeasured**). That is a supply-chain option on
the distributor's own side, not a reason to assume the hand-off problem is solved at the client's
demarcation. Whether such a stage passes TR 101 290 on hardware is open
([planned-experiments](../lab/planned-experiments.md)).

### 4.5 Where the demarcation puts the gateway

Gateway *placement* moves fan-out arithmetic: at each client's demarcation the transport serves every
client; in regional PoPs it serves every PoP ([Economics](economics.md) §4.5,
[Architecture](architecture.md) §4.4). Open architectural decision; neither data plane is favoured.

### 4.6 The honest verdict on this axis

**Three claims were run together under "hand-off":**

- **Receiving** favours segmented HTTP **at classic segment durations** — off the shelf against
  MoQ's single implementation, and ABR-to-TS boxes are purchasable where no MoQ equivalent exists
  (conformance unmeasured — §4.4). **At low latency it reverses:** nothing free receives TS-in-HLS,
  so the free receiver exists on the MoQ lane and the segmented one requires a purchase (§6.1).
- **Grooming burden** favours MoQ (~240× coarser bursts, 24 multi-second silences — §4.3). **Which
  stage can carry the burden favours segmented HTTP:** off-the-shelf TSDuck passes all four grooming
  criteria with mux intact; MoQ has no off-the-shelf mux-preserving option and needs a purpose-built
  stage ([T13](../lab/test-13-downstream-grooming.md)).
- **Groomed wire** (what an IRD grades) is a tie on conformance and not on its cost: both reach 0 PCR
  intervals above 40 ms in software — segmented at the 8 s cushion its segment duration already imposes,
  MoQ at a buffer sized by the source's peak coded frame. MoQ reaches it at 2,447 ms of delivery latency
  against segmented HTTP's 9,286 ms, and holds it over 24.01 h where the segmented lane has never been
  soaked (§5.1). The two lanes' figures are not equally tight: MoQ's conformance and its latency come
  from the same configuration, whereas the segmented lane's zero-violation result is a local groomer run
  and its 9,286 ms internet cell at that depth posts 2 marginal intervals — within the resolution that
  rig grades absolute conformance to ([Evidence](evidence.md) §3.11).

**"Easier to receive", "easier to groom" and "conformant once groomed" are three different claims.**
The broadcast-grade layer is required on both planes; the same groomer binary sits behind either, at
depth set by segment duration vs the source's **peak coded frame** (§5.1).

---

## 5. Latency (R4)

**This is the axis on which the two data planes differ most, and the size of the difference depends
entirely on which conformance level the comparison is held at.** At the shallowest cushion each plane
will run at — where no plane is P1-conformant — MoQ delivers a picture over one internet path in
**109 ms** against segmented HTTP's **4,067 ms**. At the only configuration each has been *measured
conformant* in, MoQ delivers in **2,447 ms** and segmented HTTP in **9,286 ms**
([Evidence](evidence.md) §3.11, §3.2). The gap between the two Internet-native planes survives the
conformance requirement at roughly 3.8×; MoQ's 37× headline does not. **Every latency figure on the
media-aware lane must be quoted with the conformance of the same bytes**, and §5.1 is why.

The arithmetic below explains why segmented HTTP's floor is structural; the measurements follow it.

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

**MoQ's floor is measured twice, and the two figures belong to different builds.** The 109 ms above was
the same clip tapped leaving an EC2 origin and again on the groomed egress here, and on loopback it came
in 4.7× lower than a plain-UDP control carrying no transport buffer at all ([Evidence](evidence.md)
§3.11). **That figure was measured on a build whose wire cannot be made P1-conformant**, and the fixes
that made the lane conformant did not preserve it (§5.1). Both are *delivery* latency — source to
groomed egress — and exclude encoder and decoder delay, which no plane here varies.

**The edge stage's contribution is measured on both planes, and the asymmetry is real but smaller than
it looks.** The groomer that satisfies R3 held **7.5 s of programme before emitting a byte** on the
segmented plane ([Evidence](evidence.md) §3.2), and over the internet that plane runs from 4,067 ms at
its shallowest runnable cushion to 9,286 ms at the depth that makes it P1-conformant. On the MoQ lane
the *commanded* cushion is not the depth in force — standing depth drains to ~90 ms whatever it is told,
because the carrier outruns the null-stripped content arriving at it — so on that build the stage added
tens of milliseconds. On the conformant build it does not: the buffer bound the gate requires is set by
the source's peak coded frame, and the lane delivers at 2,447 ms.

### 5.1 Latency and PCR conformance are independent axes, and the lane still pays for conformance in latency

Grooming appeared to buy PCR-repetition conformance with buffer depth, and buffer depth is latency —
which would have made conformance something MoQ pays for out of the only axis on which it leads.
**That particular trade does not exist.** Sweeping the groomer's cushion across a ladder spanning eight
times the depth moves the lane's repetition figure not at all, and it does not move when groomer
starvation is removed altogether; over the internet it read 504 and 505 intervals above 40 ms at the
two rungs run there. The variable is not depth ([Evidence](evidence.md) §3.2, [T18](../lab/test-18-delivery-latency.md)).

**What clears the gate is in the edge stage, and it is independent of depth, exporter cadence and
content.** PCR re-insertion was *opportunistic* — it could only occupy an output slot the content
scheduler had declined, and a media-aware source delivers a coded frame as one burst, so the output had
ample stuffing overall and none inside a burst. Every one of the 71 over-40 ms intervals in a graded
20 s output contained **zero** null slots. **Reserving** the slot costs 0.34 % of the carrier and closes
the gate at every cushion on every source tested. With two further groomer fixes — estimating the media
rate as a ratio of sums rather than a mean of per-interval ratios, and closing the release loop on
buffer occupancy rather than running open-loop on the estimate — the lane's wire returns **0 of 20,193
intervals above 40 ms over 300 s, 0 continuity errors, 0 groomer drops, 0 underruns and exact CBR**
([T19](../lab/test-19-pcr-grid-verification.md) measurement 11), sustained over **24.01 h** across
632,199,204 packets with the 33-bit PCR rollover crossed in flight
([T21](../lab/test-21-permanence-soak.md)).

**But the conformant configuration is an order of magnitude slower than the 109 ms figure, and that is
the finding this section turns on.** It delivers at a **2,447 ms** median. The gap has two identified
components and neither is the groomer's cushion:

- **~650 ms is a named upstream regression.** The exporter PCR fix that made an even grid possible also
  moved delivery latency from **120.0 ms to 771.6 ms** against the same control on the same rig, and
  reproduced at 118 → 769 ms on a second platform against a build with no output pacing in it at all —
  so it is the positional clustering meeting a groomer, not a pacing change
  ([T19](../lab/test-19-pcr-grid-verification.md) measurement 6). This component is a defect with an
  owner and could be recovered.
- **The remainder is structural to the media-aware lane.** The buffer the gate requires is sized by the
  **peak coded frame**, not by the bitrate: three sources at 9.5–9.9 Mb/s of programme, with peak frames
  of 256, 1,826 and 4,562 transport packets, need bounds differing by more than 3×, and 3.6× the peak
  frame's carriage duration sufficed where 2.5× did not. That quantity is the contribution encoder's VBV
  occupancy, which the source's byte spacing used to carry and which a demuxed lane cannot recover from
  decode timestamps — **so the media-aware lane moves the encoder's VBV budget downstream into the edge
  gateway's buffer.** It is content-dependent, sizeable per feed from a published encoder parameter, and
  not removable by tuning.

**At equal conformance the ordering changes, and it does not favour MoQ against the incumbents.**
Against the other Internet-native plane MoQ keeps a decisive margin — 2,447 ms against segmented HTTP's
9,286 ms. Against the point-to-point tunnels it does not: SRT and RIST are *transparent*, so their
egress carries the source's own PCR grid and needs no grooming stage at all — byte-faithful SRT
reproduces the source mux rate, PSI cadence and PCR grid over the public internet with **0 P2 violations
at the 481 ns gate, ungroomed** ([Evidence](evidence.md) §3.1) — and their delivery latency is the
jitter buffer the operator sets plus the round trip, which read **1,618 ms at a 1 s buffer** and is
reducible by setting the buffer shallower. **So the sub-second band, which is the one hard technical
discriminator MoQ has over the incumbents (§5.2, [Economics](economics.md) §7.4), is not demonstrated at
conformance anywhere in this repository.** Two qualifications bound that statement in MoQ's favour: no
clean sub-second SRT cell was measured on this rig either, so the tunnels' conformant floor is inferred
from their transparency rather than measured at depth; and the ~650 ms upstream component above is a
defect rather than a property.

Two further caveats apply to every figure here. Both paths measured were healthy, so nothing exercised
the retransmission and jitter-buffer recovery the tunnels exist for — the case that should favour them
([Evidence](evidence.md) §4). And **neither lane has been graded on a hardware IRD**, which remains the
measurement that would most change this comparison and is blocked on apparatus rather than on either
project.

One deployment constraint is separate from latency and belongs with any conformance claim: since
[#3375](https://github.com/moq-dev/moq/pull/3375) every *placed* PCR-timeline class is carried at the
control's content gap, but that fix regressed the complement — on a continuous timeline whose content
restarts it stalls video and primary audio permanently, bisected to its own merge commit
([T27](../lab/test-27-liveness-detector.md)). No build currently carries both cases, so a deployment on
current `main` must pin or patch the client. The **forward** jump's missing flag, the one residue those
six arms left, has since been fixed upstream and verified by re-running the arm
([T23](../lab/test-23-pcr-discontinuity-classes.md)).

### 5.2 The decision rule, restated

**Two conditions have to hold together before segmented HTTP is the better engineering choice, and
one of them is not a latency question.** The route's destinations must absorb seconds — in practice
nearer six unless a commercial ABR-to-TS receiver is bought — **and** the receive path to an
IRD-ready transport stream must be supplied separately, either bought as an ABR-to-TS stage or
already present in the destination estate, or else fall outside what the route is being asked to
cover. Where both hold, segmented HTTP wins on the balance of the remaining axes: maturity, delivery
economics and delivery-path interoperability, narrowly on the hand-off, against narrower MoQ
advantages on receiver-side reception, entitlement and multi-programme carriage. **Where the receive
path is the thing being evaluated, this axis does not decide it** — nothing free receives low-latency
TS-in-HLS, and the commercial stage that does is unmeasured here (§4.4, §6.1).

**Between roughly 2.5 and 9 seconds, MoQ is the better choice on this axis and the margin is measured
at conformance:** 2,447 ms against 9,286 ms, with the broadcast-grade edge stage inside both figures.
That is a narrower and more defensible claim than the 37× headline, and it is the one the current record
supports.

**Below about two seconds, no plane in this repository is demonstrated conformant.** MoQ is the only
Internet-native candidate whose *architecture* reaches that band, and it is the only one with commodity
delivery in prospect, but the campaign has not produced a conformant sub-second configuration on any
lane. A route with a sub-second budget is therefore choosing on a projection — that the ~650 ms upstream
regression is recovered and that the VBV-derived buffer bound is smaller for its own content — rather
than on a result. **The honest position is that MoQ's distinguishing claim is architecturally credible
and not yet evidenced.**

Note what the rule does *not* decide: the grooming and egress layer is built either way (§4).

And note the question behind the rule, which is a condition of MoQ's case specifically rather than of
Internet-native distribution generally: **does the sub-second requirement exist on identifiable routes,
or is it a preference?** Most other axes here favour segmented HTTP wherever its receive path is
separately provided, so if no real route needs sub-second delivery then MoQ addresses a preference
rather than a requirement, whatever its measured margin. The
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

**Segmented HTTP wins the delivery path decisively, and "interoperable" has to say which layer it
means: the answer differs at every one of the five in §6.1, and on a low-latency receive path it
reverses.**

**On the delivery path segmented HTTP has no transport to interoperate** — HTTP bytes pass through
every CDN and cache. MoQ's relay is a protocol implementation; measured against all eight other
registered public relays a MoQ feed carries no media at all, with at least four distinct causes
([Evidence](evidence.md) §3.7, [T11](../lab/test-11-interop.md)). HLS is not an Internet standard and
is consumed by every general-purpose client; MoQ is standards-track and carries media within one
implementation.

**Delivery-path interop and multi-programme carriage are mutually exclusive on segmented HTTP:**
"Transport Stream Segments MUST contain a single MPEG-2 Program." Delivery-path interop survives MPTS
in segments; conformant clients and packagers do not.

Service-layer SI is a smaller residual: HLS defines initialisation as PAT+PMT only; extra PIDs ride
along but nothing requires SDT/NIT/EIT/TDT/TOT. MoQ now threads the service layer through its catalog
([Evidence](evidence.md) §3.1). SCTE-35 has a specified out-of-band `EXT-X-DATERANGE` mapping;
monitoring (CMCD/CMSD, segment probes) exists where MoQ observability is thin.

### 6.1 Five layers, and they do not resolve the same way

Nothing in this repository grades them together, and treating them as one claim is how a delivery-path
result comes to stand for a receiver one.

| Layer | Segmented HTTP | MoQ |
|---|---|---|
| **Cache and CDN carriage** | clears — a named object over HTTP, through a dozen suppliers (§2) | one CDN operates a relay; no feed traversed anyone else's ([Evidence](evidence.md) §3.7) |
| **General-purpose client reception** | clears, and is why the format is ubiquitous | within one implementation |
| **Low-latency TS-in-HLS reception** | **no free implementation exists** — both free TS-capable clients fetched zero parts and fell back to whole segments ([Evidence](evidence.md) §3.9) | not applicable; the lane has no segment period to receive |
| **A receive stage yielding a transport stream the groomer can take** | classic HLS: off the shelf (§4.2). Low-latency: commercial ABR-to-TS only, **conformance unmeasured** (§4.4) | `moq export ts`, free and single-implementation | 
| **Hardware-verified conformance of that hand-off** | **not run on either plane** (§4.6, [Evidence](evidence.md) §4) | **not run** |

**The first two layers are segmented HTTP's, decisively. The third and fourth are the unresolved
condition on this plane**, and the fifth is unresolved on both. The distributor-owned groomer sits
behind layer 4 on either plane and is not what separates them (§4.1). So segmented HTTP's
interoperability advantage is real, large and located upstream of the receiver — and a route cannot
bank it as a receiver path unless that path is supplied separately, by purchase or by an estate that
already has one.

---

## 7. Entitlement and access control (R7)

**MoQ's advantage is real but narrow — not revocation latency.** Low-latency segmented HTTP re-fetches
the playlist every part-target duration; worst-case revocation is about one request interval — not
materially worse than dropping a subscription ([Control](control-plane.md) §4).

What differs: **where enforcement lives and whether the session is observable.** Segmented HTTP
enforces at the CDN (per-supplier token machinery); MoQ at the relay (portable if you operate it). A
subscription is a live, queryable fact; segmented delivery is inferred from logs. Cache invalidation vs
no cached entitlement. **Architectural reading, not a measurement** — the authorization hook is verified
at subscription ([Evidence](evidence.md) §3.10).

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

**Domains differ:** internet-measured for segmented HTTP, media-aware MoQ and SRT ([T4](../lab/test-4-remote-e2e-srt.md));
three-clip breadth loopback ([T3](../lab/test-3-opaque-transparency.md)); EIT on synthetic fixture
([T17](../lab/test-17-si-snapshot-tracks.md)). SRT is the byte-faithful reference.

**Single-programme mux content is as verbatim as the opaque MoQ lane** — prepending PAT/PMT inserts two
packets and renumbers two continuity counters; in a 1,200-packet window the only difference is byte 3 on
one PAT and one PMT ([Evidence](evidence.md) §3.1). **The clock is not verbatim:** one PAT/PMT pair per
segment displaces PCR by 109–302 µs (predicted and measured); grooming closes P2 violations at the
demarcation (§4.1). P2 presupposes a mux rate — uninformative on the media-aware lane until groomed.

**EPG:** both deliver 69 sections byte-identically; MoQ via reconstruction (must detect completeness),
segmented via copy. MoQ hands joining receivers the whole EPG in ~1 ms; segmented clients wait the
carousel ([T17](../lab/test-17-si-snapshot-tracks.md)).

**MoQ's remaining mux-content advantage is multi-programme carriage alone** (normative HLS exclusion,
open measurement). Against the media-aware lane, segmented HTTP keeps stuffing, CAT, continuity counters
and wall clock. **Fidelity costs ~7 % wire volume** (§9) — the same fidelity-vs-bandwidth trade on both
planes.

---

## 9. Economics

Fully modelled in [Economics](economics.md).

**Wire volume favours MoQ by ~7 %** — §8's fidelity trade: **0.982×** media-aware vs **1.056×**
segmented HTTP/3 (derived) vs **1.037×** SRT ([Evidence](evidence.md) §3.5). Only declining verbatim
carriage sits below 1.0×; the off-the-shelf packager retains stuffing. HTTP overhead is 0.06 %;
HTTP/3 costs ~2.6 points more than HTTP/2 on TCP.

**Destination count decides the bill, not the transport** ([Economics](economics.md) §4.4). **Delivery
market decides the level:** commodity CDN $0.005–0.010/GB vs one MoQ supplier at $0.050/GB
([Economics](economics.md) §4.6).

---

## 10. SRT and RIST: scaling is possible, and that is not the differentiator

**SRT can be scaled** via a gateway tier — N point-to-point sessions from a replication point
([Economics](economics.md) §4.3). **No commodity market sells SRT to the destination** — only ingest
at the CDN door; fan-out is segmented HTTP. The SRT-vs-MoQ difference is who operates the replication
point and which market prices it (§2). **MoQ's advantage over SRT is segmented HTTP's advantage:**
cache-shaped delivery commoditised for a decade; the narrow claim is the sub-second band. Zixi adds a
per-GB licence.

### 10.1 RIST, which deserves better than being listed alongside SRT

RIST (VSF TR-06) is the **strongest point-to-point transport** here — openly specified and
multi-vendor (§6), RTP-native, native dual-path protection. On hand-off it ties SRT on worst-case
silence (**~35 ms** vs MoQ's 149 ms and segmented HTTP's 4.01 s) and passes through 30.6 kB bursts
where MoQ re-paces to 12.2 kB (§4.3). **It fails the same way as SRT:** fan-out is N sessions the
operator runs; multicast is for managed networks, not the public internet. For tens of destinations
over owned transit RIST may beat both candidates here; the Internet-native case is about **reach and
cost at scale**.

---

## 11. The toolchain: what is free, and the one stage that is not

Stage by stage: most stages are common; where the two differ, **they are incomplete in opposite places.**

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

The bottom four rows are the broadcast-grade layer common to both ([Architecture](architecture.md)).

**Every stage has a free implementation except receiving low-latency HLS back into a transport
stream** (§5, [Evidence](evidence.md) §3.9):

| Want | Free option | Commercial option |
|---|---|---|
| Classic HLS → TS, ~6 s latency | `tsp -I hls`, FFmpeg | any professional IRD with an HLS input |
| **Low-latency HLS → TS, ~2 s** | **none** | Synamedia MEG (ABR2TS), Ateme TITAN Edge |
| MoQ → TS | `moq export ts` | **none** |
| TS → CBR, PCR re-stamped, **mux preserved** | `mpegts-pacer` | Synamedia, Ateme, Harmonic gateways |
| CBR TS → paced wire | [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts), `mpegts-pacer` | the same gateways |

**Pacing onto a socket is solved off the shelf** ([Evidence](evidence.md) §3.2). **Rewriting a mux to
CBR without re-multiplexing depends on the lane:** segmented egress — TSDuck `pcradjust` + `regulate`;
MoQ egress — purpose-built stage ([T13](../lab/test-13-downstream-grooming.md)). The middle two rows are
the receive layer §6.1 leaves open, and they point opposite ways: the free receiver is MoQ's, the
commercial one segmented HTTP's. Extending TSDuck's `hls` input for partial segments is tracked in
[planned-experiments](../lab/planned-experiments.md).

---

## 12. The MoQ implementation landscape

*Assessed from repositories and public documentation; measured cross-implementation result in
[Evidence](evidence.md) §3.7.*

| | `moq-dev` | `moq2ts` / `moqxr` | Cloudflare `moq-rs` | This work |
|---|---|---|---|---|
| Lane | media-aware (+ opaque prototype) | **transparent TS** | none — transport only | **transparent TS** + grooming |
| Scope | publisher, relay, subscriber | **publisher only** | protocol library, **relay**, sample clients | publisher + egress + pacer |
| Media format | `hang` catalog/container | MSF + MSFTS (`packaging: "m2ts"`) | **deliberately none** | verbatim TS |
| Format standing | no IETF draft | **adopted WG format** + individual draft | N/A | internal |
| Wire versions | moq-lite 03–06, **MOQT 14–19** | MOQT 16, 18 | MOQT 14, 16 and 18 | inherits `moq-dev` |
| Source failover | route reselection via `--origin` | N/A (publisher) | **none — publisher loss is terminal** | relies on `moq-dev` |
| Deployment | self-hosted | self-hosted | **managed, provisioned by API** | self-hosted |

**No one else does the broadcast-specific layer** — PCR egress, CBR grooming, TR 101 290 conformance.
Transparent carriage is no longer single-vendor (MSF adopted) but **transparent ≠ verbatim**
(`moq2ts` strips nulls). Cloudflare's format-blind relay cannot corrupt opaque TS but thins less
intelligently under pressure. **Publisher disconnect is terminal on Cloudflare's relay** — no source
takeover; route reselection is `moq-dev`-specific ([Architecture](architecture.md) §5).

---

## 13. Seven corrections the comparison forced

Measurement rules and incidents are in [`lab/method-notes.md`](../lab/method-notes.md). Current
positions:

- **TS-in-HLS is not new** — MPEG-TS was HLS's original container; Low-Latency mode added partial
  segments.
- **QUIC is not decisive** — Low-Latency HLS requires HTTP/2 or HTTP/3; MoQ differs in the object model
  above QUIC (§3.1).
- **Client-side HLS inputs do not discharge the distributor's grooming obligation** (§4.1).
- **TS segments are verbatim in payload, not as a mux** — one inserted PAT/PMT pair costs file-domain
  PCR accuracy (§8).
- **Stuffing retention is not optional on segmented HTTP** — the off-the-shelf packager keeps it; stripping
  would forfeit the §8 advantage (§9).
- **Transparent tunnels pass source cadence; MoQ re-paces** — RIST/SRT hand 30.6 kB bursts; MoQ 12.2 kB
  (§4.3).
- **Sub-second MoQ delivery is measured, and not at conformance** — 109 ms across the internet on a build
  whose wire cannot be made P1-conformant; the conformant configuration reads 2,447 ms
  ([T18](../lab/test-18-delivery-latency.md), [T19](../lab/test-19-pcr-grid-verification.md), §5.1). A
  latency figure and a conformance figure must come from the same bytes.

---

## 14. Verdict, axis by axis

Read the "favours" column as *today*, on the evidence in this repository and the current
specifications. The **Basis** column states what kind of evidence the row rests on: **M** measured
here, **S** specification, **V** vendor datasheet, **R** reasoning, **—** none.

| Axis | Favours | Basis | Margin |
|---|---|---|---|
| Scaling the distribution (R2) | segmented HTTP | R+S | narrow *between these two* — both put a cache in the path and so both clear the requirement the tunnel incumbents fail; statelessness and supplier count are the only difference left (§2) |
| Reliability under impairment (R5) | **neither, once substrate-matched — they trade cells** | **M** | **measured head-to-head, then re-measured on a shared substrate.** Loss does not separate the lanes given the same controller (1.04 and 0.96 on BBR to 10 %; 0.17 and 0.13 on CUBIC), so "segment fetching degrades under loss" is a controller comparison. **Reordering, the one axis that did separate them, no longer does** — equalised for packet size it reads 0.44 on TCP, **0.18 on HTTP/3 and 0.13 media-aware, overlapping**. On the shared substrate the segmented lane instead wins loss (0.70 against 0.10 on TCP at ~20 % applied) and the 30 s outage (0.76 against 0.51), and under *sustained* under-capacity delivers 0.79 against 0.46, taking lateness where the other discards programme (§3.1) |
| Reliability of recovery (R5) | segmented HTTP, in the protocol | M+S | **retry splits: no resilience of *rate*, and resilience of *content* only inside the origin's availability window** — 0 continuity errors and 0 PCR intervals above 40 ms throughout a ladder to 10 % loss, so within the window the lane sheds time rather than data. The window is crossed between 7.7 % and 12.2 % applied loss, after which the client re-anchors and leaves 7–82 s holes, past ~20 % loss without the origin returning a single error. Edge and Pathway selection remains specification-only (§3.2) |
| Redundancy — serving node (R5) | **segmented HTTP** | **M** | **decisive on the protocol, blocked on the tooling.** Both lanes resume within a few seconds of the node returning, but the media-aware exporter skips to the live edge and loses the media produced during the outage where the segmented client refetches it losslessly. Neither TSDuck's HLS input nor FFmpeg's demuxer survives an origin restart at all, so it took a purpose-written client to show (§3.2) |
| Redundancy — 1+1 source failover (R5) | **segmented HTTP, conditionally** | **M** | **the sharpest divergence measured.** A pair sharing one feed and one naming scheme fails over with no measurable interruption, 3/3 runs identical, needing no receiver-side merge; the media-aware floor is one detection interval (30–33 s default, ~10 s tuned) and hitless is unreachable by relay reselect. **Conditional** because a *misconfigured* segmented pair is accepted silently and delivers ±20 s time-travel that passes every continuity and PCR-interval check, where the relay refuses the same mistake outright (§3.3) |
| Reassembly to a transport stream | **segmented HTTP at classic segment durations; MoQ at low latency** | M | off the shelf in TSDuck and ffmpeg against MoQ's single `moq export ts` (§4.2) — but only for whole segments. Below the segment period the free tooling on this plane does not exist, so the free receiver is the MoQ one and the segmented path requires an ABR-to-TS purchase (§6.1) |
| Grooming *burden* (R3) | **MoQ** | **M** | **the same groomer absorbs ~240× coarser bursts and 24 multi-second silences on segmented HTTP; against RIST and SRT the two split, MoQ on burst size and the tunnels on worst-case silence** (§4.3, §10.1) |
| Grooming *outcome* — a P1-conformant wire (R3) | **neither — both reach it, at different costs** | **M** | **the MoQ lane's long-standing failure here is closed**, and not by the diagnosis the campaign expected: it posted 489–504 intervals above 40 ms at *every* cushion, and what cleared it was the groomer reserving a PCR slot rather than taking only slots the content scheduler declined. The lane returns **0 of 20,193 intervals above 40 ms over 300 s and holds it over 24.01 h** with 0 continuity errors and exact CBR. Segmented HTTP reaches the same standard at the 8 s cushion its segment duration already imposes, on a local groomer run rather than the internet cell that gives its latency (§4.6); MoQ at a buffer set by the peak coded frame (~3.6× its carriage duration, content-dependent) and 2,447 ms of latency against the segmented lane's 9,286 ms. Only MoQ has been soaked, and **neither is verified on hardware** (§5.1) |
| Latency (R4) | **MoQ over segmented HTTP, decisively; MoQ over the tunnels, not at conformance** | **M** | **the margin depends on the conformance it is held at, and the headline does not survive it.** Where none is P1-conformant, MoQ reads 109 ms against SRT's 1,618 ms and segmented HTTP's 4,067 ms — 15× and 37×. **At conformance MoQ reads 2,447 ms against segmented HTTP's 9,286 ms** (3.8×, still decisive between the Internet-native planes), while the transparent tunnels carry their source's conformant grid ungroomed at a latency the operator sets — 1,618 ms at a 1 s jitter buffer, reducible. Of MoQ's gap, ~650 ms is a named upstream regression and the rest a buffer bound set by the source's peak coded frame. **No plane here is demonstrated conformant below ~2 s.** Caveats: delivery latency rather than camera-to-display; both paths healthy; no clean sub-second tunnel cell either (§5, §5.1) |
| Interoperability (R1) | **segmented HTTP on the delivery path; not established on the receive path** | M+S | **decisive on the delivery path, and it stops at the receiver.** Cache, CDN and general-purpose client reception all clear, against MoQ carrying no media through any of eight other relays — conditional on the single-programme envelope. But the two layers that make it a *broadcast* receive path do not clear: no free implementation receives low-latency TS-in-HLS, the commercial ABR-to-TS stage that would is unmeasured, and hardware conformance of the hand-off is unrun on both planes (§6.1) |
| Entitlement and control (R7) | MoQ | R | narrow — enforcement point and session observability, not revocation speed (§7) |
| Carriage fidelity, one programme (R1) | neither, on mux content; **SRT on the clock, and it is the only one measured over a real path** | M | **a wash on content across three clips** — service identity, PMT/PCR PID, CAT, TDT/TOT, splice PIDs and stuffing all survive, so MoQ's content advantage narrows to the untested multi-programme case. Segmented HTTP alone is *additive*: one PAT/PMT pair per segment, costing 109–302 µs of file-domain PCR accuracy that grooming then closes. **On the clock the incumbent wins outright:** byte-faithful SRT reproduces the source mux rate, PSI cadence and PCR grid over the public internet with 0 P2 violations, where the media-aware lane preserves the mux as bytes and destroys it as a timed object (§8) |
| Wire volume | **MoQ** | M+derived | ~7.0 %, MTU-invariant — 0.982× against 1.056× over HTTP/3; §8's fidelity trade priced (§9) |
| Delivery economics | segmented HTTP | S(published rates) | decisive, and it swamps the row above — commodity delivery at $0.005–0.010/GB against one MoQ supplier at $0.050 (§9) |
| Operational maturity | segmented HTTP | R+M | decisive — mature multi-vendor tooling and existing staff skills against a pre-1.0 ecosystem |

**What that adds up to, and neither column adds up to a winner.** For routes that can absorb five
seconds or more, carry a single programme, **and have a receive path to an IRD-ready transport stream
from somewhere other than this evaluation** — a purchased ABR-to-TS stage, an estate that already
receives HLS, or a scope that stops short of the receiver — segmented HTTP is the better engineering
choice, on delivery-path interoperability, maturity, delivery economics and recovery in the protocol.
Mux-content fidelity is not on that list: the two planes are a wash on it, and the plane that
reproduces the source's *clock* is neither of them (§8). The receive-path condition is not a formality
either: it is the layer this evaluation did not close (§6.1).
On HTTP/3 the impairment trade favours segmented HTTP on loss, outage recovery and sustained
under-capacity, not reordering ([T20](../lab/test-20-segmented-http3.md)). **MoQ's case is
route-specific and narrower than the headline latency figure suggests:** smaller bursts for the groomer,
multi-programme carriage, portable enforcement, ~7 % less wire volume, and — at equal conformance —
2,447 ms against 9,286 ms, which is decisive for a route in the two-to-nine-second band and is not a
sub-second result (§5.1).

MoQ's ~7 % wire saving is a rounding error against five-to-ten× delivery cost. Cushion depth is not what
buys PCR conformance on the media-aware lane, but conformance is not free of latency either: the
configuration that clears the gate costs an order of magnitude against the lane's fastest measured
figure (§5.1).

**Broadcast-grade work is common to both** — grooming, 1+1, ST 2022-7, entitlement, observability —
and sits above neither specification ([Evidence](evidence.md)).

### 14.1 The framework the final conclusion has to satisfy

**Viability is a gate, not a score** — whether each plane can serve permanent primary distribution, and
under what conditions each is preferable.

| Gate | Cleared when | MoQ today | Segmented HTTP today |
|---|---|---|---|
| **Conformant egress** | Groomed output passes TR 101 290 P1/P2 on hardware, sustained | **Cleared in software and sustained for a day; not verified on hardware; and not on one build.** Over 300 s and again over **24.01 h / 632 M packets**: 0 intervals > 40 ms, 0 continuity errors, 0 groomer drops, 0 underruns, exact CBR, 0 PCRs outside ±500 ns, 33-bit rollover crossed in flight ([T19](../lab/test-19-pcr-grid-verification.md), [T21](../lab/test-21-permanence-soak.md)). Needed all three upstream PCR fixes *and* the three groomer fixes in §5.1, and costs a buffer sized by the peak coded frame (~3.6× its carriage duration), content-dependent, plus 2,447 ms of delivery latency. **The build question is the live risk:** since [#3375](https://github.com/moq-dev/moq/pull/3375), which these measurements prompted, all six *placed* timeline classes are carried at the control's content gap ([Evidence](evidence.md) §3.13) — but that same fix stalls video and primary audio permanently on a *continuous* timeline whose content restarts ([T27](../lab/test-27-liveness-detector.md)), and the 24 h soak ran on the pre-#3375 build. **No build carries both cases**, so a deployment must pin or patch. Residue: a **forward** jump reaches the wire with no `discontinuity_indicator` | **Cleared in software** at an 8 s cushion (0 intervals > 40 ms on a local groomer run; the internet cell at that depth posts 2 marginal intervals), at 9,286 ms; never soaked; hardware unverified |
| **Permanent operation** | Stable operating state over ≥ 7 days, every resource series flat or converged | **Partial, and the media plane is no longer the blocker.** 24.01 h clean on delivery and conformance; relay memory converges softly at a ceiling whose scaling term is open by a factor of two; **`moq import ts` grows linearly at +2.83 MB/h with no drawdown**, which is what fails the resource criterion, in that one role ([T21](../lab/test-21-permanence-soak.md)) | **Unknown.** Never soaked |
| **Deterministic recovery** | A bounded, known quantity of programme lost per failure class, no manual intervention | **Partial.** Recovery is fast but lossy — the exporter resumes at the live edge and discards the outage | **Partial.** Refetches losslessly inside the availability window, silently holed past it |
| **Redundancy to R6** | Receiver-side selection yielding no visible failure during contracted content | **Cleared for single-track**, byte-identical across independent hosts; not for a multi-programme mux | **Cleared conditionally** — hitless when configured correctly, silent time-travel when not |
| **Fan-out to R2** | Marginal cost per destination approaching zero, with a known scaling model | **Indicated.** Audience is not a memory term; the measured knee is the host's, not the relay's | **Indicated.** Cache offload measured at one node, not at a CDN |
| **Operable at fleet scale** | A fault in one of hundreds of feeds is localisable from telemetry | **Unassessed** | **Unassessed** |
| **A receive stage at the route's latency budget** | A stage exists that turns the delivered feed back into a transport stream the groomer can take, at the latency the route allows | **Cleared, single-implementation.** `moq export ts` is free and the only one; the groomer behind it is the distributor's on either plane (§11) | **Cleared at classic segment durations, open below them.** Off the shelf for whole segments; nothing free receives low-latency TS-in-HLS, and the commercial ABR-to-TS stage is a datasheet claim this campaign did not measure (§4.4, §6.1) |

**Preference is conditional on the route:**

- **Latency budget** — between ~2.5 s and ~9 s MoQ leads at conformance (2,447 ms vs 9,286 ms; §5.1);
  above that the axis stops discriminating; below ~2 s neither plane is demonstrated conformant.
- **Programmes per feed** — MPTS favours MoQ; normatively excluded on HLS (§8).
- **Destination estate** — open on the delivery path (segmented HTTP) against single-implementation
  carriage (MoQ); reversed on a low-latency receive path, where only MoQ's is free (§6.1).
- **Delivery price** — commodity CDN vs MoQ supplier (§9).
- **Impairment profile** — substrate-matched trade: loss/outage favour segmented HTTP on HTTP/3;
  reordering no longer separates the lanes (§3.1, [T20](../lab/test-20-segmented-http3.md)).
- **Redundancy topology** — receiver-side 1+1 (MoQ) vs shared object store (segmented HTTP) (§3.3).
- **Operational estate** — HTTP maturity vs pre-1.0 MoQ ecosystem.

Both may be viable; neither without a distributor-owned edge stage, and neither as an unconditional
choice. Conformance on hardware remains the deciding gate for both
([T21](../lab/test-21-permanence-soak.md)); the receive path is the condition that decides segmented
HTTP specifically, and it is the one a route has to satisfy from outside this evaluation (§6.1).

---

## 15. Open questions

Ranked by leverage:

1. **Hardware TR 101 290 on groomed egresses, sustained?** §5.1 — both conformant in software, MoQ over
   24 h; neither near an IRD. The measurement that would most change this comparison.
2. **Can a conformant sub-second configuration be produced on any lane?** §5.1 — decides whether MoQ has
   a technical discriminator over the incumbents at all, and turns on recovering the ~650 ms upstream
   regression and on how large the peak-coded-frame buffer bound is for real contribution content.
3. **Commercial ABR-to-TS gateway on hardware?** §4.4, §6.1 — the only path to low-latency TS-in-HLS
   at scale, and therefore the condition on which segmented HTTP's route-level case rests.
4. **Sub-second requirement: routes or preference?** §5.2 — decides MoQ's addressable share, and is now
   a commercial question rather than a technical one.
5. **MPTS in TS segments in practice?** §8 — MoQ's remaining mux-content advantage.
6. **Edge gateway at demarcation vs regional PoP?** §4.5 — sets delivery bill ([Economics](economics.md)).
7. **Genuine segment loss vs lateness?** §3.2 — edge/Pathway selection under Content Steering remains
   specification-only.
8. **Relay portability vs commoditised delivery economics?** ([Evidence](evidence.md) §3.7).

---

## 16. References

The implementations and specifications this comparison assesses. Where a row is graded rather than
described, the grading is in [Evidence](evidence.md) §3.7 (interop) and §3.1 (carriage).

**Implementations**

- `moq-dev` — media-aware lane; publisher, relay, subscriber: https://github.com/moq-dev/moq
- Cloudflare `moq-rs` — IETF-aligned transport library and production relay, media-agnostic: https://github.com/cloudflare/moq-rs
- Cloudflare MoQ relay service and provisioning API: https://developers.cloudflare.com/moq/
- `moq2ts` — transparent MPEG-TS publisher: https://github.com/mondain/moq2ts
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

**Background**

- MPEG-TS over MOQ: https://edis.mx/insights/mpeg-ts-over-moq.html
- MPEG-TS over MOQ — PCR: https://edis.mx/insights/mpeg-ts-over-moq-pcr.html
- MPEG-TS over MOQ — pacing: https://edis.mx/insights/mpeg-ts-over-moq-pacing.html
- MOQ Interop Runner: https://github.com/englishm/moq-interop-runner
