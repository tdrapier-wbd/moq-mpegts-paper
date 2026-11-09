# Candidate Data Planes Compared

Status: working draft. Layer: **the data-plane choice.** Scope: the candidates evaluated against R1–R7 of [Problem](problem.md) §5, and against the point-to-point incumbents, on the axes an operator decides on; R6 and R7 only as far as the _data plane_ decides them. Reads with: [Architecture](architecture.md) and [Control plane](control-plane.md), for the engineering above the transport, common to both candidates, and [Evidence](../lab/evidence.md), for every measurement cited here with its measurement point, domain and build.

**Contents**

- [In brief](#in-brief)
- [1. Candidates](#1-candidates)
  - [1.1 RIST](#11-rist)
  - [1.2 Satellite hybrid](#12-satellite-hybrid)
- [2. Carriage (R1)](#2-carriage-r1)
- [3. Fan-out (R2)](#3-fan-out-r2)
- [4. Hand-off (R3)](#4-hand-off-r3)
  - [4.1 Obligation](#41-obligation)
  - [4.2 Reassembly](#42-reassembly)
  - [4.3 Grooming](#43-grooming)
  - [4.4 HLS inputs on IRDs](#44-hls-inputs-on-irds)
  - [4.5 Demarcation](#45-demarcation)
- [5. Latency (R4)](#5-latency-r4)
  - [5.1 Conformance cost](#51-conformance-cost)
  - [5.2 Sub-second need](#52-sub-second-need)
- [6. Reliability (R5)](#6-reliability-r5)
  - [6.1 Impairment](#61-impairment)
  - [6.2 Recovery](#62-recovery)
- [7. Redundancy (R6)](#7-redundancy-r6)
- [8. Entitlement (R7)](#8-entitlement-r7)
- [9. Interoperability and implementations](#9-interoperability-and-implementations)
  - [9.1 Layers](#91-layers)
  - [9.2 Toolchain](#92-toolchain)
  - [9.3 MoQ implementations](#93-moq-implementations)
- [10. Economics](#10-economics)
- [11. Verdict](#11-verdict)
  - [11.1 Viability gates](#111-viability-gates)
  - [11.2 Preference by route](#112-preference-by-route)
- [12. Limits](#12-limits)
- [13. Open questions](#13-open-questions)
- [14. References](#14-references)

## In brief

**For most primary-distribution routes there are _two_ viable Internet-native data planes.** They differ on latency only where nothing is conformant: **held TR 101 290 P1/P2-conformant, MoQ delivers a picture over one internet path in 2,447 ms and segmented HTTP in 2,604 ms**, its wire passing the 13818-1 buffer model too ([Evidence](../lab/evidence.md) §3.11). On a route of seconds, latency does not choose between them. **Neither plane is an unconditional choice.** Segmented HTTP leads on most of the remaining axes — maturity, delivery economics and the delivery path's interoperability. Its path back to an IRD-ready transport stream is off the shelf at classic segment durations and groomed to P1/P2 in software, but no free receiver survives an origin failure, and no receiver on either plane has met hardware (§6.2, §9.1, §11). Everything that makes either plane _broadcast-grade_ sits above the transport and is common to both ([Problem](problem.md) §1). **Below about one second no plane here is demonstrated conformant over a whole capture**, so MoQ's sub-second case is architecturally credible and not yet evidenced (§5.1).

The rows are the requirements of [Problem](problem.md) §5 that a data plane decides (R8 is not one), a week's operation, and the three stages a deployment has to source. ✓ met, within the note's condition; ◐ met in part; ✗ not met; — not measured. Every mark rests on software receivers and one clip or feed per cell (§12), and **no lane has met a hardware IRD**.

| Requirement | MoQ, media-aware lane | MoQ, opaque lane | Segmented HTTP | SRT / RIST (incumbent) |
| --- | --- | --- | --- | --- |
| **Faithful carriage (R1)** | ◐ identity, SI and SCTE-35 survive; stuffing, PSI cadence and the packet schedule are rebuilt, and a scrambled feed is refused (§2) | ✓ the source's bytes, a scrambled feed included (§2) | ✓ verbatim in payload, one PAT/PMT pair added per segment; one programme per feed by specification (§2, §9) | ✓ transparent on every criterion measured (§2) |
| **Fan-out (R2)** | ✓ linear to the relay's CPU, and carried through a CDN-hosted relay (§3) | ◐ through the CDN-hosted relay measured, single sessions stalled at 2 to 24 subscribers (§3) | ✓ one origin fetch per segment per CDN edge (§3) | ✗ a session per destination, scaled only by a gateway tier someone runs (§3) |
| **Conformant egress (R3)**, in software | ◐ P1/P2 and the buffer model through upstream's export for a CBR source; through a pacing groomer the P1/P2 wire fails the buffer model (§2, §9.2) | ✓ the source's PCRs and packet schedule, so the source's own verdict (§2) | ✓ P1/P2 and the buffer model, groomed at a 1–3 s cushion (§2, §4) | ✓ the source's PCR grid, 0 P2 violations ungroomed (§2) |
| **Latency at P1/P2 (R4)**, one internet path | ✓ 2,447 ms (§5) | ✓ about 2 s at a 2 s budget over a 116 ms path (§5.1) | ✓ 2,604 ms on one-second segments (§5) | ✓ 1,623 ms at a 1 s jitter buffer, and reducible (§5.1) |
| **Recovery from a failure (R5)** | ◐ fast but lossy: it resumes at the live edge, and loses more programme than SRT across a transport outage (§6.2) | ◐ the same live-edge model; a lost importer ends every export ([Architecture](architecture.md) §5.4) | ◐ lossless inside the availability window, silently holed past it; no free receiver survives an origin restart (§6.2) | ◐ retransmits inside its latency buffer; loses less programme than the media-aware lane across a transport outage (§6.2) |
| **Hitless 1+1 (R6)** | ✗ only legs started together merge; switched at the receiver behind a 2 s hold, a leg's fault costs no hole beyond the stream's own ([Architecture](architecture.md) §5.2) | ✓ legs started apart merge through a late join, loss and a killed export, one clip on one host; the importer is a single point (§11.1) | ✓ packagers started apart, interchangeable in one CDN origin group, merged by receivers released in phase; a misconfigured pair passes silently (§7) | — not measured; RIST specifies dual-path protection (§1.1) |
| **Revocable entitlement (R7)** | ✓ enforced at the relay; revocation's worst case about 1.7 s at its tightest (§8) | ✓ the same relay (§8) | ◐ enforced at the CDN; revocation a median 24–28 s, 86 s at worst, on the one CDN measured (§8) | — not assessed |
| **A week's operation** | ✓ 169 h on the live feed, every resource converged; one run (§11.1) | — not run | ◐ 72 h through one CDN, memory flat; the contribution's breaks withdrew both pathways for 54 s in all (§11.1) | — not run |
| **Open publisher** | ◐ `moq import ts`, one implementation (§9.2) | ✓ `moq-dev`'s whole-multiplex import, and `moq2ts` under MSFTS (§9.3) | ✓ TSDuck at classic durations; at low latency only Apple's segmenter (§9.2) | ✓ open-source SRT; RIST openly specified and multi-vendor (§1.1) |
| **Fan-out fabric as a service** | ◐ Cloudflare, Akamai and moq.pro operate MoQ relays, priced where published at four to ten times commodity; otherwise self-run (§3) | ◐ the same relays; the one CDN-hosted relay measured stalled single sessions (§3) | ✓ any HTTP CDN, a dozen suppliers (§3) | ✗ no commodity market sells it to the destination (§3) |
| **Open subscriber** (receive to TS) | ◐ `moq export ts`, one implementation (§9.2) | ◐ `moq export ts`; `moq2ts`'s console receiver, untested here (§9.3) | ◐ `tsp -I hls` and FFmpeg at classic durations, neither surviving an origin restart; nothing free at low latency (§9.2) | ✓ open-source SRT and RIST receivers (§1.1) |

**Latency marks every lane met because R4 asks for a bounded few seconds**; the sub-second band is a projection on all of them (§5.1).

---

## 1. Candidates

**The candidates are grouped by scaling shape, not by quality.**

| Candidate | What it is here | Class |
| --- | --- | --- |
| **MoQ** | `moq import ts` → relay fabric → `moq export ts`, on QUIC/WebTransport | live publish/subscribe with native relay |
| **Segmented HTTP** | HLS carrying MPEG-TS segments, its original container (DVB-DASH profiles ISOBMFF only), at classic segment durations over HTTP/1.1 | cacheable-object pull over commodity delivery |
| **SRT / Zixi / RIST** | a reliable UDP tunnel per destination, optionally through a gateway tier | point-to-point session transport |

**Segmented HTTP is scoped to a 5–10 s delivery budget and single-programme feeds**; its low-latency and multi-programme variants are described for completeness. **All three rows assume the IP path carries the whole feed**; the satellite-hybrid architectures of VSF TR-06-4 Parts 7 and 8, where RIST carries only the bytes a site lost, answer a different question and are treated in §1.2.

Two exclusions. **TS-over-HTTP/1.1**, a continuous TS in a chunked response, has no agreed specification and several incompatible implementations, so choosing it buys a vendor rather than a protocol. **WebRTC/SFU** does not carry an MPEG-TS at all. Segmented HTTP is assessed against [HTTP Live Streaming 2nd Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/) (`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS), quoted from the normative text because practitioner convention diverges from it in both directions.

### 1.1 RIST

**RIST (VSF TR-06) is the strongest point-to-point transport here**: openly specified and multi-vendor, RTP-native, with native dual-path protection. On the hand-off it ties SRT on worst-case silence and passes the source's bursts through (§4.3). **It fails the same way as SRT**: fan-out is N sessions the operator runs, and multicast is for managed networks. For tens of destinations over owned transit RIST may beat both candidates; the Internet-native case is about **reach and cost at scale**.

### 1.2 Satellite hybrid

**The satellite-hybrid specifications ask RIST to carry only what the satellite lost.** VSF TR-06-4 Part 7 (in-band) and Part 8 (out-of-band) keep satellite as the primary one-to-many path; the receiver detects loss in the satellite transport stream, requests the affected range from a buffered _recovery server_ over RIST, and splices it in, with a full-stream IP fallback for a complete fade. Part 7 marks blocks on an unreferenced private PID, so detection is specified but repair is per block and the uplink needs an inserter; Part 8 leaves the stream unmodified and requests by PCR and duration, but leaves detection to the implementer, so two conformant receivers may disagree about what was lost.

| Model | What the IP path carries | Marginal cost of destination N |
| --- | --- | --- |
| C-band satellite primary | nothing | ~0 inside the footprint |
| **Ku-band satellite + RIST repair** | only the blocks a site lost, while it is losing them | ~0 inside the footprint, plus that site's repair traffic |
| Internet-native (MoQ, segmented HTTP) | the whole feed, to every destination, always | one unicast copy (§3) |
| Point-to-point tunnels | the whole feed, to every destination, always | one session and one copy |

The hybrid keeps satellite's near-zero marginal cost and spends fade margin to do so: rain attenuation rises with frequency (ITU-R P.838, P.618), so Ku fades more than C band (_specified_), and repair buys the margin back selectively. The pressure to leave C band is a US regulatory driver (FCC 20-22).

**Its defence is that full-IP capacity scales as sites × rate × always and repair as faded sites × rate × fade duration**, which holds in the average and fails on four conditions, the decision boundary. **Sizing follows the correlated peak**: one weather system fades many sites at once, and a duty cycle reduces bytes, not committed capacity ([Economics](economics.md) §6.1). **Availability is a joint probability, unevidenced here**: severe weather stresses local access and power where it fades a downlink. **The receiver is the gate**: legacy IRDs keep decoding the satellite stream unrepaired until the client installs hybrid receivers ([Problem](problem.md) §1.5). **It resolves nothing the footprint already limited**: per-destination feeds, reach, event topologies and entitlement. It is strictly worse on R4 than plain satellite: by Part 7's informative sizing its receiver buffers the satellite latency plus a repair margin. And it relocates the conformance problem into the receiver's splice ([Architecture](architecture.md) §2.1).

**MoQ has no equivalent mechanism and is not asked the same question**: neither the IETF MoQ charter nor `draft-ietf-moq-transport-19` addresses loss in a parallel unidirectional path (_specified_, by absence), and named objects are a substrate for range repair only in _reasoning_. Both parts date from 2025–2026, with implementation evidence limited to vendor announcement and single-vendor demonstration.

---

## 2. Carriage (R1)

**On one programme the byte-faithful lanes tie on mux content and the media-aware lane, a transmux, trails them; on the clock SRT leads, the only lane measured carrying the source's own over a real path.**

|  | Segmented HTTP | MoQ media-aware lane | MoQ opaque lane | SRT — the incumbent |
| --- | --- | --- | --- | --- |
| Multi-programme mux | **normatively excluded** (§9) | **flattened** by builds up to moq 0.12.8; **split** into one intact broadcast per programme on upstream `main` from late September 2026, each SDT still listing every service | **verbatim by construction**; measured on one programme | verbatim by construction; measured on one programme |
| PIDs, PSI, service identity, SDT/NIT, EIT schedule | **preserved**, non-default PIDs included; the 8-day EPG byte-identical | preserved; a joining receiver has the whole EPG in ~1 ms | preserved | **preserved** — measured over the wire; EIT not exercised |
| TDT/TOT, CAT | **preserved** | TDT/TOT **~14 s late** on moq 0.9.11, a merged fix unmeasured; CAT not carried | preserved | **preserved**; CAT not exercised |
| Continuity counters, stuffing, mux rate | preserved, except a forced re-stamp on the injected PAT/PMT | counters regenerated; stuffing not the source's, padded to the declared source rate (+0.36 %, file domain) | **preserved** — the source's bytes, released on its PCR | **preserved; the source mux rate exactly** |
| PSI cadence, packets added | source cadence plus **one PAT/PMT pair per segment** | **regenerated thinner** — 8.04 → 2.51 PAT/s against P1's 500 ms gap | unchanged; nothing added | **identical; nothing added** |
| PCR repetition and accuracy (TR 101 290 P2) | repetition unchanged; accuracy **37–74 ns → 109–302 µs** from the injected pair, **0 violations once groomed** | repetition produced by the lane and conformant only behind a groomer that reserves the slot (§5.1); accuracy **fails on every PCR** ungroomed | the source's PCRs, values and positions intact; each released within 2 ms of schedule, arrival jitter not graded | **0 violations at 481 ns**, ungroomed — the source's own, read from a capture over the internet |
| Packet schedule (T-STD), wire | source order carried; **passes** groomed, at four configurations over one internet path ([Evidence](../lab/evidence.md) §3.11) | **discarded**: the P1/P2-conformant groomed wire fails the transport and audio decoder buffers on every build graded, moq 0.10.0 to 0.13.0; rebuilt by a re-multiplexer, and by upstream's fixed-delay export as merged in October 2026 ([Evidence](../lab/evidence.md) §3.16) | **preserved**: the T-STD verdict is the source's, file domain, on two clips and one live feed | **preserved** through the same groomer in every 2 s window, and over a whole capture through its stream-clocked mode |
| TS-level scrambling | **carried byte for byte**, its CA PIDs with it, by a packager not cutting on pictures; `--intra-close` publishes nothing | **cannot be carried** — the importer refuses every scrambled unit and announces no broadcast | **carried byte for byte**, its CA PIDs with it, and through the groomer | carried by construction |
| Byte-identical to source | **in payload, yes; as a mux, no** | no | **yes**, from the first released group | every field, count and cadence measured identical, not diffed byte-for-byte |

Internet-measured for segmented HTTP, media-aware MoQ and SRT ([T4](../lab/test-4-remote-e2e-srt.md)); the opaque lane on loopback, five clips on `moq-dev` ([T48](../lab/test-48-passthrough-export.md), [T3](../lab/test-3-opaque-transparency.md)); scrambling once, on loopback ([T66](../lab/test-66-scrambled-carriage.md), [T69](../lab/test-69-segmented-access-and-scrambling.md)); EIT on a synthetic fixture ([T17](../lab/test-17-si-snapshot-tracks.md)); figures and qualifications in [Evidence](../lab/evidence.md) §3.1. **Single-programme mux content on segmented HTTP is as verbatim as the opaque MoQ lane** — the only difference in a 1,200-packet window is byte 3 on one PAT and one PMT — and **its clock is not**, which grooming closes at the demarcation (§4.1). The segmented column is TSDuck's packager and HLS input: a packager that injects nothing adds no pair, and an input that remuxes keeps none of the SI (§4.4).

**The media-aware lane is a transmux lane, and for TS-out it has three structural limits.** It loses the packet layout, which is why the encoder's VBV budget moves into the groomer's buffer (§5.1). Its subscriber becomes the multiplexer, re-solving the T-STD schedule the source had already solved, which a pacing groomer cannot do — **not insurmountable**, since a laboratory re-multiplexer does it live, and upstream's fixed-delay export does it in the subscriber, keeping every track and buffer on every join tried (§5.1). And it **cannot carry a scrambled stream**. Byte-faithful carriage has none of the three by construction; on MoQ that is the opaque lane (§9.3).

**Scrambling is a narrow gate.** Primary distribution is protected by the transport and the operator ([Control plane](control-plane.md) §7.3), and consumer conditional access is applied downstream of the IRD, so the gate binds only a route that must hand a feed to the IRD **still scrambled** — a BISS-class scheme held end to end, or a third-party feed the distributor may not descramble — and there it is binary.

**MoQ's remaining mux-content advantage is multi-programme carriage alone, and only on the opaque lane**, unmeasured on one.

---

## 3. Fan-out (R2)

**Fan-out separates both Internet-native candidates from the point-to-point incumbents; between the two of them it is barely an axis, favouring segmented HTTP narrowly on statelessness and supplier count**, by reasoning and specification. Tunnel architectures run out near 50 destinations ([Problem](problem.md) §2.3) against a requirement of hundreds to low thousands. An HTTP edge cache and a MoQ relay share one topology — fetch once, serve N unicast connections — so both clear R2, neither breaks last-mile linearity ([Economics](economics.md) §4.4), and what remains is who operates the replication point.

|  | Segmented HTTP | MoQ | SRT / Zixi / RIST |
| --- | --- | --- | --- |
| Unit of fan-out | a cacheable object, fetched by idempotent GET | a subscription the relay holds state for | a session per destination |
| Replication state | none — any edge can serve any object | per-subscriber, per-track, live | per-destination, live |
| Who operates it | the commodity delivery market, a dozen suppliers, today | three CDNs today (Cloudflare, Akamai, moq.pro), the two that publish a rate at four to ten times commodity delivery; otherwise you | you, or a managed media service |
| Known hard ceiling | none at this scale | **relay CPU**, linear up to it and a collapse past it: about 100 subscribers on a 2-vCPU `moq-relay` 0.15.1 (noq) with GSO off; cross-host, in one region. Through a CDN-hosted relay of another implementation, about 0.82 Gb/s on the one thread its operator configures: 32 subscribers of a 25 Mb/s feed on the media-aware lane; on the opaque lane no reproducible knee, single sessions stalling at 2 to 24 ([Evidence](../lab/evidence.md) §3.6) | AWS MediaConnect: 50 outputs per flow |
| Marginal cost of a destination | a cache fill: shared upstream, one egress copy | **1.258 % of a relay core, 2.62 MB and one full stream copy** on `moq-relay` 0.15.1 with GSO on, linear | a session's worth of gateway CPU and one egress copy |
| Specified point-to-multipoint | DVB-MABR (ETSI TS 103 769), inside a managed access network — consumer, not affiliate, distribution | none | none |

**Statelessness is the only differentiator between the two, and a reliability advantage in disguise** (§6): a destination can move between edges or suppliers of one namespace mid-stream, where losing a MoQ or SRT relay loses a session. Per-subscription state also prices churn in relay memory, which a static segmented origin does not pay ([Evidence](../lab/evidence.md) §3.14). On the quinn- and noq-based relays measured, an abandoned session is served at the media rate until the idle timeout closes it. On November 2026 `main`, built on `moq-quic`, a frozen one holds about 0.5 MB until then. It is a structural advantage, bought with the latency of §5, that an origin terminating sessions or personalising responses would give up.

**SRT can be scaled** through a gateway tier ([Economics](economics.md) §4.3), but **no commodity market sells SRT to the destination** — only ingest at the CDN door, with fan-out from there over segmented HTTP. The SRT-against-MoQ difference is who operates the replication point and which market prices it, so **MoQ's advantage over SRT is segmented HTTP's advantage**, plus the narrow sub-second claim. Zixi adds a per-GB licence.

---

## 4. Hand-off (R3)

**Both planes reach a P1/P2-conformant wire in software, neither yet on hardware, at different costs: MoQ at a peak-coded-frame buffer, segmented HTTP at a 1–3 s cushion; segmented HTTP's groomed wire passes the T-STD too, and MoQ's only through upstream's export for a CBR source** (§5.1, §2). Segmented HTTP reassembles off the shelf, and MoQ hands the groomer bursts two orders of magnitude smaller.

### 4.1 Obligation

**The deliverable is a clean, paced MPEG-TS at the hand-off — the distributor's obligation on either data plane** ([Problem](problem.md) §1.5). Neither HLS nor MoQ specifies PCR, CBR, stuffing or null packets, and both deliver in bursts that fail TR 101 290 without grooming ([Evidence](../lab/evidence.md) §3.2) — the conformance the installed base enforces, as accepted practice rather than anything observed here. TR 101 290 does not grade the 13818-1 buffer model, which a conformant stream must also satisfy, and grooming re-times packets without reordering them, so it cannot supply that model where the delivered packet order breaks it (§2).

### 4.2 Reassembly

**Reassembly favours segmented HTTP at classic segment durations and MoQ at low latency, where the free receiver is MoQ's** (§9.1). Segmented HTTP has an off-the-shelf reassembly stage: TSDuck `tsp -I hls` / `tsp -O hls`, FFmpeg. MoQ has one implementation: `moq export ts`, continuity counters rendered from process state ([Evidence](../lab/evidence.md) §3.4). MoQ reassembly is simpler to write than a manifest state machine, but for an operator already written usually wins.

### 4.3 Grooming

**The grooming burden favours MoQ: segmented HTTP inherits the problem in full, its egress ~240× coarser, yet has the better measured outcome and is the only lane an off-the-shelf stage can groom** ([Evidence](../lab/evidence.md) §3.8):

| Ungroomed egress | MoQ | Segmented HTTP (2 s segments) | RIST / SRT |
| --- | --- | --- | --- |
| Median burst | 12.4 kB | **2.95 MB** | 30.6 kB — the source's, not the protocol's |
| Gaps above 1 s in 60 s | **none** | **24** | **none** |
| Largest gap | 149 ms | **4.01 s** | **~35 ms** |
| 10 ms peak/mean | 24× | **231×** | 3.4× |

**MoQ hands the smallest bursts and the tunnels the shortest silences**; a groomer's buffer is sized by the first and its start gate by the second. **One groomer covers both lanes**: the same binary, no flags changed, takes segmented egress to TR 101 290 conformance on the wire, at the cost of 7.5 s before the first byte and ~9 s to detect a dead origin, and fails below the cushion its segments' spans set (311 continuity errors at 1 s behind 2 s segments; [T16](../lab/test-16-grooming-segmented-http.md), [T70](../lab/test-70-segmented-latency-budget.md)). **Off the shelf, only the segmented lane can be groomed**: against four criteria fixed in advance, every candidate behind MoQ fails a different one, while behind a segmented egress `tsp -P pcradjust -P regulate -O ip` passes all four with the mux carried byte-for-byte, because the packager slices the TS it was given with its stuffing, mux rate and PCR spacing intact ([T13](../lab/test-13-downstream-grooming.md)). A mux-preserving groomer is required on both paths.

### 4.4 HLS inputs on IRDs

**Four products list HLS input with transport-stream output, as vendor datasheet claims, unmeasured**: Ateme TITAN Edge, Sencore MRD 8000, Spica HLS2SRT and Synamedia MEG (its ABR2TS function). They align on nothing beyond HLS: no specification says how a receiver rebuilds an IRD-ready stream or reports what it lost.

**What decides whether such an input can serve an IRD is whether it hands on the segments' packets**, measured on the software stacks a product may be built on (loopback, one broadcast clip, one run; [Evidence](../lab/evidence.md) §3.1). TSDuck's, GStreamer's and this campaign's HLS inputs deliver every DVB table and SCTE-35 section verbatim. FFmpeg's remuxes: its own PAT, PMT and SDT, no NIT, EIT or TDT, every PID renumbered, and SCTE-35 carried as PES a splicer does not read. A datasheet's "HLS in, TS out" does not say which a product is. **Apple's validator is the wrong judge**: a contribution feed (interlaced, open GOP) fails its device rules whatever the packager. The receive profile these results imply is drafted in [T65](../lab/test-65-ird-hls-profile.md): SI and SCTE-35 unchanged from packager to IRD, segments that open on a random access point within their target duration, and a receiver that survives an origin's failure and paces to the PCR. Whether any product meets it, or passes TR 101 290 on hardware, is open ([Evidence](../lab/evidence.md) §5).

### 4.5 Demarcation

**Gateway placement moves fan-out arithmetic**: at each client's demarcation the transport serves every client; in regional PoPs it serves every PoP ([Economics](economics.md) §4.5, [Architecture](architecture.md) §4.4). Open architectural decision; neither data plane is favoured.

---

## 5. Latency (R4)

**This axis separates the two data planes only where nothing is conformant.** There MoQ delivers a picture over one internet path in **141 ms**, inside a single segment's span; held at P1/P2 conformance, MoQ delivers in **2,447 ms** and segmented HTTP, on one-second segments, in **2,604 ms**, on one clip and a clean path ([Evidence](../lab/evidence.md) §3.11). All are _delivery_ latency, source to groomed egress, excluding the encoder and decoder delay that no plane here varies.

**Segmented HTTP's floor is arithmetic, not implementation quality.** `PART-HOLD-BACK` MUST be at least twice, and SHOULD be at least three times, the part target, and production part targets sit around 200–330 ms, so the hold-back alone is roughly 0.6–1 s before encode, packaging, delivery and the gateway's de-jitter buffer. The specification warns that a shorter target trades buffer for a greater "likelihood of playback stall." Two to five seconds is the realistic envelope, and **through the free clients that turn HLS back into a transport stream it is nearer six**, because none fetches parts ([Evidence](../lab/evidence.md) §3.9); the 2,604 ms above takes no parts, only one-second segments.

### 5.1 Conformance cost

**Latency and PCR conformance are independent axes: cushion depth does not buy conformance, the edge stage does, and the lane still pays for it in latency.** An eightfold cushion ladder leaves the lane's PCR repetition unchanged, while a groomer that reserves the PCR slot rather than waiting for a spare one returns, on the wire, 0 of 20,193 intervals above 40 ms over 300 s, and 0 over 24.01 h ([Evidence](../lab/evidence.md) §3.2).

**The conformant configuration delivers at 2,447 ms, an order of magnitude above the 141 ms, and neither part of the gap is cushion depth.** About **650 ms is a named upstream regression**, the exporter PCR change that made an even grid possible ([Evidence](../lab/evidence.md) §3.11): a defect with an owner, and recoverable. **The rest is structural**: a demultiplexed lane cannot recover the VBV occupancy the source's byte spacing carried, so **the media-aware lane moves the encoder's VBV budget into the edge gateway's buffer**, sized by the peak coded frame rather than the bitrate — content-dependent, sizeable from a published encoder parameter, and not removable by tuning.

**Both the conformance and the 2,447 ms are P1/P2's**; the same wire fails the 13818-1 buffer model (§2). The stages that repair it present at **2,196.7 ms** (a laboratory re-multiplexer, moq 0.12.1) and **1,137 ms** at a 1 s delay (upstream's export, which sends ahead within the delay), both on loopback and both presentation latency, which does not subtract from delivery latency ([Evidence](../lab/evidence.md) §3.11, §3.16).

**At equal P1/P2 conformance MoQ keeps 6 % over segmented HTTP and nothing over the tunnels.** Byte-faithful SRT carries the source's own PCR grid over the public internet with 0 P2 violations at 481 ns, ungroomed, at a latency the operator sets — **1,623 ms at a 1 s jitter buffer**, and reducible ([Evidence](../lab/evidence.md) §3.1). **So the sub-second band, the one hard technical discriminator MoQ has over the incumbents ([Economics](economics.md) §7.4), is not demonstrated at conformance on MoQ, and no configuration below one second has passed a whole capture on any lane.** Byte-faithful carriage comes closest, at 114–234 ms on loopback with a damaged stretch in each run, which weighs against MoQ, and the ~650 ms defect bounds that in MoQ's favour. **On a 116 ms path at an equal 1 s budget, only SRT stays whole at 1 % loss**, each MoQ lane losing under a second in one run of three and the media-aware lane trailing both by about 0.25 s; at 2 s every lane is, the MoQ lanes at 2.02–2.30 s and segmented HTTP at 3.22 s, which alone fails under burst loss (§6.1). On CUBIC neither MoQ lane carries 0.1 % ([Evidence](../lab/evidence.md) §3.11). **Neither lane has been graded on a hardware IRD** ([Evidence](../lab/evidence.md) §4).

### 5.2 Sub-second need

**Whether MoQ's sub-second claim matters is a condition of its case specifically: does the sub-second requirement exist on identifiable routes, or is it a preference?** "A few seconds tolerable" is true of the feed's own integrity and understates the transition: replacing a geostationary path with a 2–5 s one consumes a downstream budget that was previously free, at every destination — splice and blackout timing, alignment between affiliates on different paths during a migration, live handback, and re-distribution — so it has to be answered per route by the destination.

---

## 6. Reliability (R5)

**Under impairment nothing cleanly separates the lanes once they are substrate-matched; on recovery, 1+1 included (§7), segmented HTTP has the more robust model, and recovery matters more for a trunk.**

### 6.1 Impairment

**Loss separates the congestion controllers, not the lanes.** Low-Latency HLS **requires** HTTP/2 or HTTP/3, so on HTTP/3 both lanes share QUIC, its per-stream loss isolation and RFC 9218 priorities; MoQ differs in the object and subscription model above it. Measured head-to-head under one shaper ([Evidence](../lab/evidence.md) §3.3):

- **At 10 % loss both lanes hold full rate on BBR and both collapse on CUBIC**, so "segment fetching degrades under loss" compares TCP's default controller with QUIC's tuned one. On HTTP/3, through a byte-faithful receiver, the segmented lane loses nothing up to ~20 % applied loss.
- **Reordering ranks controllers, not lanes**: equalised for packet size, the segmented lane on HTTP/3 keeps a quarter of the stream whatever the controller, and the media-aware figure moves across the whole range on one controller flag ([T20](../lab/test-20-segmented-http3.md)).
- **Outage recovery is the origin's retention**, not the transport: under a 30 s outage the two substrates are byte-identical.
- **Trunking contended feeds is a latency decision**: media-aware feeds at a 2 s budget deliver less in total than one, because each subscriber discards groups past its own deadline, and SRT converts the same shortfall into continuity errors. The media-aware lane's shortfall shows only as absent content, since its exporter writes its own counters.
- **Under sustained under-capacity the segmented lane takes lateness** at 0 continuity errors, invisible to an integrity monitor, until the origin evicts the segment it asks for — a cliff where the media-aware lane has a slope.
- **Burst loss on a long path stalls the segmented lane over TCP** (HTTP/3 untested): on a 116 ms path, a burst that takes most of a fetch is resent only after a retransmission timeout, then one round trip at a time. It fails under bursts counted in packets, and in two replicates of three under 20 ms bursts covering 1 % of time. Re-requesting after 1 s on a fresh connection does not bound the stall (5.0–5.8 s lost where it fired); after 500 ms on a second, open one it does, whole in three of three for 2–9 % more bytes, on one path ([Evidence](../lab/evidence.md) §3.11).

**Against SRT, matched on measured latency and graded on content, the media-aware lane loses more programme in every random-loss and reorder stress cell but 5 % reorder**, by a margin its build and QUIC stack set. **Matched the same way at 100 ms RTT, the segmented lane loses nothing to 5–20 % reorder, and to 5–10 % loss nothing on BBR, one replicate aside, as SRT, and nothing through a CloudFront edge, whose TCP behaves as BBR (one PoP), but more than the media-aware lane on CUBIC**; a 5 s outage costs it more than either where its cushion is short ([Evidence](../lab/evidence.md) §3.3).

### 6.2 Recovery

**Segmented HTTP has the more robust recovery model in the protocol, and the tooling does not deliver it.** Each segment has a **defined availability window** (HLS §4.4.3), so a failed fetch can be retried idempotently from another edge or Pathway without the sender, where MoQ's reliability is scoped to a live subscription and a deliberately shallow relay cache ([Evidence](../lab/evidence.md) §3.4). What survives is content inside the window, not rate, and past it the stream is silently holed. No off-the-shelf TS client survives an origin restart ([T6](../lab/test-6-relay-resilience.md)), retry cannot recover a fetch that succeeds stale (a playlist an edge holds past the window, replicas that disagree), and Content Steering is specification-only. An origin killed for ten seconds costs the segmented lane no content, where the media-aware exporter skips to the live edge. Against SRT, graded on content, the media-aware lane loses more programme to every failure but a relay that keeps its key or a killed exporter; across a _transport_ outage, behind the fixed-delay export, the margin is QUIC's probe-timeout backoff, which a conformant default cannot cap ([Evidence](../lab/evidence.md) §3.3).

**Neither lane's transport reports a stalled source, and only the segmented one offers a substitute**: its playlist media sequence stops advancing, which a poller can alarm on without parsing media ([Evidence](../lab/evidence.md) §3.12).

---

## 7. Redundancy (R6)

**Broadcast reliability comes from 1+1 with selection at the receiver, which is transport-independent; head-to-head, source failover is the sharpest divergence measured, and it favours segmented HTTP conditionally** ([Architecture](architecture.md) §5, [Evidence](../lab/evidence.md) §3.4). **Serving-node failover** favours segmented HTTP decisively in the protocol, unmet by off-the-shelf tooling (§6.2); on MoQ it is never hitless, since relay reselection takes at least one idle timeout.

**Source failover is hitless on segmented HTTP** for a co-started pair sharing a feed and segment names, with no measurable interruption on one host (3/3 runs), and for interchangeable origins in one CDN origin group, merged downstream by receivers released in phase. Origins become interchangeable when packagers name segments by content time, which a stock packager started later does not; over CloudFront the group covered every single-pathway failure tested. Released on the origin's program date-time, receivers at two edges start within 1.1 ms for a 2022-7 merge, against about ±1.5 s at random unreleased ([Evidence](../lab/evidence.md) §3.4). On the media-aware lane it costs a detection interval or more in the relay; at the receiver behind a 2 s hold it cost a software decoder nothing beyond the stream's own hole, on one clip ([Architecture](architecture.md) §5.2). **The verdict is conditional because a misconfigured segmented pair is accepted silently**: a pair with mismatched sources delivers ±20 s of time-travel that passes continuity and PCR checks and fails no request, where the media-aware relay refuses.

---

## 8. Entitlement (R7)

**MoQ's advantage is real, and on revocation latency MoQ is the faster of the two measured.** MoQ's revocation is a poll whose tightest worst case is **about 1.7 s measured and 2.11 s as documented** ([Evidence](../lab/evidence.md) §3.10). Low-latency segmented HTTP re-fetches its playlist every 0.28–0.30 s part ([T14](../lab/test-14-data-plane-comparison.md)), but a CDN that checks every request refuses a revoked token only once its edges hold the revocation: through CloudFront's own key-value store, **a median 24–28 s and 86 s at worst** at two edge locations ([T69](../lab/test-69-segmented-access-and-scrambling.md)), some fifty times MoQ's worst case. Expiry is exact on both, so a faster segmented bound needs short-lived tokens, which is design; the figure is one CDN's mechanism. Three plausible MoQ configurations disable revocation altogether, and an authorization outage is tolerated for an hour by default ([Control](control-plane.md) §4.1). What differs otherwise is **where enforcement lives and whether the session is observable** — at the relay, portable and queryable, or at the CDN through per-supplier machinery inferred from logs. Enforcement is exact on both.

---

## 9. Interoperability and implementations

**Segmented HTTP wins the delivery path decisively and, for a single programme, the receive path at classic durations; "interoperable" has to say which layer it means.** HTTP bytes pass through every CDN and cache, where MoQ's relay is a protocol implementation and a MoQ feed crosses nine of nine other implementations' public relays intact after the join, but only five for a subscriber joining mid-stream ([Evidence](../lab/evidence.md) §3.7). **Segmented HTTP excludes multi-programme carriage by specification, not delivery path**: "Transport Stream Segments MUST contain a single MPEG-2 Program," yet a CDN carries one intact ([Evidence](../lab/evidence.md) §3.1). HLS requires only PAT and PMT, where MoQ threads SDT, NIT, EIT and TDT/TOT through its catalog. SCTE-35 has a specified `EXT-X-DATERANGE` mapping, and CMCD/CMSD give client reporting MoQ has only in drafts, but **neither plane defines how an origin establishes that what a subscriber received was intact** ([Architecture](architecture.md) §9.4).

### 9.1 Layers

**Segmented HTTP's interoperability advantage is real and large: decisive on the first two of five layers, and at classic durations it reaches the receiver.**

| Layer | Segmented HTTP | MoQ |
| --- | --- | --- |
| **Cache and CDN carriage** | clears, through a dozen suppliers (§3) | three CDNs operate relays (§3); other implementations' relays carry it in part (§9) |
| **General-purpose client reception** | clears, and is why the format is ubiquitous | within one implementation |
| **Low-latency TS-in-HLS reception** | **no free implementation** — both free TS-capable clients fetched zero parts ([Evidence](../lab/evidence.md) §3.9); not asked of the lane (§1) | not applicable; no segment period |
| **A receive stage yielding a transport stream the groomer can take** | classic HLS: off the shelf (§4.2), not surviving an origin failure (§6.2); low latency: commercial ABR-to-TS only, **conformance unmeasured** (§4.4) | `moq export ts`, free and single-implementation |
| **Hardware-verified conformance of that hand-off** | **not run** | **not run** |

### 9.2 Toolchain

**Every stage has a free implementation except receiving low-latency HLS back into a transport stream, and where the two planes differ they are incomplete in opposite places** ([Evidence](../lab/evidence.md) §3.9). Ingest (TSDuck `tsp`), egress FEC and ST 2022-7, analysis and the control plane are identical on both planes and the distributor's ([Architecture](architecture.md)); the stages that differ:

| Stage | MoQ | Segmented HTTP | Commercial option |
| --- | --- | --- | --- |
| **Publish / package** | `moq import ts` (media-aware), or an opaque lane under MSFTS | classic `tsp -O hls`; low-latency TS through Apple `mediastreamsegmenter` | — |
| **Fan-out** | `moq-relay`, self-run or hosted by moq.pro; Cloudflare's implementation | any HTTP origin and cache, or a commodity CDN | — |
| **Receive → TS** | `moq export ts` | classic: `tsp -I hls`, FFmpeg, neither surviving an origin restart; low latency: **nothing free** | HLS: the receivers of §4.4; MoQ: **none** |
| **Groom → CBR, PCR re-stamped, mux preserved** | for a CBR source, `moq export ts --delay` itself: it lays the mux back at the rate the importer recorded, conformant to P1/P2 and the buffer model across hosts ([Evidence](../lab/evidence.md) §3.16); for a VBR source, `[mpegts-pacer](https://github.com/tdrapier-wbd/mpegts-pacer)`, conformant on the wire (§5.1) | the same binary, no flags changed; or TSDuck `pcradjust` + `regulate` | Synamedia, Ateme, Harmonic gateways |
| **CBR TS → paced wire** | `[rawsendmpeg2ts](https://github.com/EDIS-mx/rawsendmpeg2ts)`, `mpegts-pacer` | identical | the same gateways |

### 9.3 MoQ implementations

**Only** `moq-dev` **does any of the broadcast-specific layer**: its export grooms a CBR source to a conformant wire (§9.2), and its importer counts TR 101 290 errors. The table is assessed from repositories and public documentation; the measured cross-implementation result is in [Evidence](../lab/evidence.md) §3.7.

|  | `moq-dev` | `moq2ts` / `moqxr` | Cloudflare `moq-rs` |
| --- | --- | --- | --- |
| Lane | media-aware, and whole-multiplex passthrough | **transparent TS** | none — transport only |
| Scope | publisher, relay, subscriber | **publisher**, console receiver | protocol library, **relay**, sample clients |
| Media format | `hang` catalog/container | MSF + MSFTS (`packaging: "m2ts"`) | **deliberately none** |
| Format standing | individual draft for its `mpegts` catalog section (demultiplexed carriage only) | **adopted WG format** + individual draft | N/A |
| Wire versions | moq-lite 01–06, 07 opt-in and in progress; **MOQT 18 and 22** on upstream `main` from late October 2026, 14–22 before | MOQT 14, 16–18, 21, 22 | MOQT 14, 16 and 18 |
| Source failover | route reselection; between importers, a marked switch to the newest (`export ts --stitch`) | N/A (publisher) | **none — publisher loss is terminal** |
| Deployment | self-hosted, or hosted by moq.pro | self-hosted | **managed, provisioned by API** |

Transparent carriage is no longer single-vendor, but **transparent is not always verbatim** (`moq2ts`'s per-program mode drops nulls). Cloudflare's format-blind relay cannot corrupt opaque TS, but thins less intelligently under pressure ([Architecture](architecture.md) §5).

**Two open implementations subscribe to whole-TS carriage**: `moq-dev`'s whole-multiplex import and the export writing its bytes back out ([Evidence](../lab/evidence.md) §3.1), and `moq2ts`'s console receiver, on OpenMOQ's stack and not covered here. `moq-dev`'s "verbatim" tracks carry undecoded PIDs one per track inside the media-aware lane. Byte-faithful carriage over MoQ is measured on one implementation, one run per arm, which is why §2's structural limits do not yet move the preference to the opaque lane. Relay-level interop with `moqxr` holds only narrowly; with OpenMOQ's moq5 it holds at the byte both ways, though neither stack's catalog finds the other's TS track ([Evidence](../lab/evidence.md) §3.7).

**Operational maturity favours segmented HTTP decisively**, by reasoning and measurement: mature multi-vendor tooling and staff skills against a pre-1.0 ecosystem, whose cost is in following upstream. A breaking change reached a rig about weekly, two of nine silently, so each upgrade needs a rig audit ([T54](../lab/test-54-dependency-risk.md)).

---

## 10. Economics

**Wire volume favours MoQ by the source's stuffing** — §2's fidelity trade: on a clip 4.57 % nulls, **0.982×** media-aware against **1.056×** segmented HTTP/3 (derived), ~7.0 % less, and **1.037×** SRT; on a stuffing-free feed 1.033× against SRT's 1.035×, level ([Evidence](../lab/evidence.md) §3.5). Verbatim carriage costs 1.03–1.06×; the off-the-shelf packager retains stuffing.

**Destination count decides the bill, not the transport** ([Economics](economics.md) §4.4, which models the bill in full). **The delivery market decides the level, and it favours segmented HTTP decisively, swamping the wire volume:** at published rates, commodity CDN at $0.005–0.010/GB against two MoQ suppliers at $0.040–0.050/GB ([Economics](economics.md) §4.6).

---

## 11. Verdict

**Neither plane's advantages add up to a winner.** For routes whose destinations absorb a few seconds, that carry a single programme, **and whose receive stage survives an origin failure**, which no free TS client does (§6.2), segmented HTTP is the better engineering choice. **MoQ's case is route-specific and narrower than its headline latency**: smaller bursts for the groomer, multi-programme carriage, portable enforcement, and up to ~7 % less wire volume, a rounding error against five-to-ten× delivery cost; at equal P1/P2 conformance it adds no latency margin. Nor is it a sub-second result: a sub-second route chooses MoQ on a projection, that the ~650 ms regression is recovered, that the VBV-derived bound is smaller for its own content, and that the export, presenting about 140 ms past a 1 s delay, holds a shorter delay over a whole capture. **Broadcast-grade work is common to both** and sits above neither specification. Every verdict here is today's, on the evidence in this repository and the current specifications.

### 11.1 Viability gates

**Viability is a gate, not a score** — whether each plane can serve permanent primary distribution, and under what conditions each is preferable.

| Gate | Cleared when | MoQ today | Segmented HTTP today |
| --- | --- | --- | --- |
| **Conformant egress** | Groomed output is a conformant transport stream on hardware, sustained — TR 101 290 P1/P2 and the 13818-1 buffer model | **Not cleared on the media-aware lane.** P1/P2 holds in software, its continuity and PCR repetition for a day, and the same wire fails the T-STD, which only a re-multiplexing stage repairs (§5.1, §2); no build is measured to carry every timeline case. Not on hardware | **P1/P2 and the buffer model cleared in software** over one internet path, and continuity and PCR repetition for 72 h on the live feed but at the feed's six breaks; PTS once hours from PCR (below); not on hardware ([Evidence](../lab/evidence.md) §3.4, §3.11) |
| **Scrambled feed to the IRD** | Where a route requires it, a feed under TS-level conditional access reaches the IRD still scrambled | **Carried on the opaque lane and through the groomer** (once, loopback, no key ladder); excluded on the media-aware lane; a narrow gate (§2) | **Carried** by a packager not cutting on pictures (once, loopback, no key ladder; §2) |
| **Permanent operation** | Stable operating state over ≥ 7 days, every resource series flat or converged | **Cleared for continuity and resources over a week**: 169 h on the live feed, every role converged, no unit restarted, every media-plane event traced to the contribution, one export end included; one run, one subscriber; one 72 h export, every PCR within ±481 ns ([Evidence](../lab/evidence.md) §3.6, §3.16) | **Not cleared**: 72 h on the live feed through one CDN, memory flat; six breaks in the contribution each withdrew both pathways, 54 s in all, and the groomer left PTS hours from PCR after a splice, its fix not soaked; one run ([Evidence](../lab/evidence.md) §3.4, §5) |
| **Deterministic recovery** | A bounded, known quantity of programme lost per failure class, no manual intervention | **Partial.** Fast but lossy — the exporter resumes at the live edge | **Partial.** Lossless inside the availability window, silently holed past it |
| **Redundancy to R6** | Receiver-side selection yielding no visible failure during contracted content | **Cleared for single-track**; for a multi-track mux on the opaque lane through a late join, each leg's loss and a killed export (one clip, one host), and on the media-aware lane for a co-started pair only, on one host or two ([Evidence](../lab/evidence.md) §3.4) | **Cleared conditionally** — hitless for a co-started pair configured alike, and for two origins in one CDN origin group behind receivers released in phase; silent time-travel when misconfigured (§7) |
| **Fan-out to R2** | Marginal cost per destination approaching zero, with a known scaling model | **Indicated.** Linear to the relay's CPU; through a CDN-hosted relay, on the media-aware lane only (§3) | **Indicated.** One origin fetch per segment per CDN edge, at two edges; no origin knee to 128 edges ([Evidence](../lab/evidence.md) §3.4, §3.6) |
| **Operable at fleet scale** | A fault in one of hundreds of feeds is localisable from telemetry | **Unassessed** | **Unassessed** |
| **Delivered-media health at a subscriber** | An origin can tell that what a subscriber _received_ was intact | **Partial**, on upstream `main`: a subscriber's own report names a dead audio or video stream, on loopback and for an hour live; a total stall reads as silence ([Architecture](architecture.md) §9.4) | **Partial**: CMCD custom keys carrying the receiver's TR 101 290 counters name dead audio, not dead video, on loopback; CloudFront's logs keep them raw ([Architecture](architecture.md) §9.4) |
| **A receive stage at the route's latency budget** | A stage turns the delivered feed back into a transport stream at the latency the route allows | **Cleared, single-implementation** (§9.2) | **Cleared at classic segment durations, open below them** (§9.1) |

### 11.2 Preference by route

**Preference is conditional on the route** — its latency budget, whether it must deliver a feed still scrambled, its programmes per feed, its destination estate, the delivery price, its impairment profile, its redundancy topology and its operational estate, each argued above. Both planes may be viable; neither without a distributor-owned edge stage. Conformance on hardware remains the deciding gate for both, and a resilient, observable receive stage decides segmented HTTP specifically.

**These two are not the only choice on the table.** The satellite-hybrid model of §1.2 is not scored because nothing about it is measured here, but it is strongest exactly where both planes are weakest — a large estate inside one footprint on a common always-on feed — and a route that reads "incumbent" on destination count in [Economics](economics.md) §6 is one where it is the live alternative.

---

## 12. Limits

**Four limits qualify every verdict here**, each with its conditions in [Evidence](../lab/evidence.md) §4 and, where one exists, the §5 row there that would discharge it.

- **No lane has been graded on a hardware IRD, and every 1+1 result comes from a software receiver** against a self-tested ST 2022-7 oracle (§7); row 1 would discharge both.
- **The data-plane comparison is one clip over two routes, and each impairment cell one run**; no attempt yet, but for row 8's third source, which tests carriage cost alone.
- **Fan-out is one relay in one region or two CDN edges**; no attempt yet past one hop.
- **Most media-aware results are on September 2026 builds** and hold on current upstream only where stated; no attempt yet at a full re-run.

---

## 13. Open questions

**Nine questions would change a verdict here, ranked by leverage**, each with the Evidence §5 row or experiment that answers it:

1. **Hardware TR 101 290 on groomed egresses, sustained?** (Row 1.) Both are P1/P2-conformant in software and neither has been near an IRD; on the media-aware lane it would also show how far receivers tolerate a wire that fails the buffer model (§5.1, §2).
2. **Can a transmux subscriber keep a T-STD-conformant wire live across hosts and for 1+1?** (Row 2.) The merged export does across hosts, within the drift limits [Evidence](../lab/evidence.md) §3.16 states; open are a laboratory stage following a remote clock, and 1+1 beyond a co-started pair ([Evidence](../lab/evidence.md) §3.4). It decides whether the lane serves TS-out to an IRD in a deployment.
3. **A P1/P2-conformant sub-second configuration on any lane?** (No experiment scheduled.) It decides whether MoQ has any technical discriminator over the incumbents, and turns on the three conditions §11 names.
4. **A receive stage that survives delivery-path failures and reports them, and HLS-input receivers on hardware, multi-programme segments included?** ([T61](../lab/test-61-origin-group-failover.md)'s stock-receiver cells for the first, row 5 for the second.) The condition segmented HTTP's route-level case rests on (§6.2, §4.4).
5. **Sub-second requirement: routes or preference?** It decides MoQ's addressable share, and is a commercial question (§5.2).
6. **Edge gateway at the demarcation or at a regional PoP?** It sets the delivery bill (§4.5). No attempt yet.
7. **Genuine segment loss against lateness?** A redundant origin covers it inside one CDN (§7); a second edge or a Content Steering pathway, specification-only, has no attempt yet (§6.2).
8. **Relay portability against commoditised delivery economics?** ([Evidence](../lab/evidence.md) §3.7; row 9.)
9. **A real estate's fade and connectivity profile?** The satellite-hybrid case turns on correlated fades and on whether IP availability is independent of fade at each site (§1.2). Only an estate's own records answer it.

---

## 14. References

The implementations and specifications this comparison assesses. Where a row is graded rather than described, the grading is in [Evidence](../lab/evidence.md) §3.7 (interop) and §6.1 (carriage).

**Implementations**

- `moq-dev` — media-aware lane; publisher, relay, subscriber: [https://github.com/moq-dev/moq](https://github.com/moq-dev/moq)
- Cloudflare `moq-rs` — IETF-aligned transport library and production relay, media-agnostic: [https://github.com/cloudflare/moq-rs](https://github.com/cloudflare/moq-rs)
- Cloudflare MoQ relay service and provisioning API: [https://developers.cloudflare.com/moq/](https://developers.cloudflare.com/moq/)
- `moq2ts` — transparent MPEG-TS publisher and receiver: [https://github.com/openmoq/moq2ts](https://github.com/openmoq/moq2ts)
- `moqxr` / OpenMOQ Publisher: [https://github.com/mondain/moqxr](https://github.com/mondain/moqxr)
- `[mpegts-pacer](https://github.com/tdrapier-wbd/mpegts-pacer)` — MPEG-TS VBR-to-CBR grooming stage (§9.2)
- `rawsendmpeg2ts` — datagram sender: [https://github.com/EDIS-mx/rawsendmpeg2ts](https://github.com/EDIS-mx/rawsendmpeg2ts)

**Standards and formats**

- IETF MOQ working group: [https://datatracker.ietf.org/group/moq/about/](https://datatracker.ietf.org/group/moq/about/)
- MOQT Streaming Format (MSF), adopted WG draft: [https://datatracker.ietf.org/doc/draft-ietf-moq-msf/](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/)
- CMSF (CMAF profile of MSF): [https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/](https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/)
- MSFTS (MPEG-TS profile): [https://github.com/mondain/msfts](https://github.com/mondain/msfts)
- HTTP Live Streaming 2nd Edition — obsoletes RFC 8216, includes Low-Latency HLS and MPEG-TS segment carriage: [https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
- DVB-MABR, adaptive media streaming over IP multicast (ETSI TS 103 769): [https://dvb.org/?standard=adaptive-media-streaming-over-ip-multicast](https://dvb.org/?standard=adaptive-media-streaming-over-ip-multicast)

**Satellite-hybrid (§1.2)**

- VSF TR-06-4 Part 7, RIST Satellite-Hybrid: In-Band Method — approved July 2025, revised December 2025: [https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-7_2025-12-10.pdf](https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-7_2025-12-10.pdf)
- VSF TR-06-4 Part 8, RIST Satellite-Hybrid: Out-of-Band Method — approved June 2026: [https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-8_2026-06-04.pdf](https://static.vsf.tv/download/technical_recommendations/VSF_TR-06-4-Part-8_2026-06-04.pdf)
- VSF Technical Recommendations index, for the TR-06 family and current revisions: [https://vsf.tv/technical-recommendations/](https://vsf.tv/technical-recommendations/)
- RIST Forum, the activity group's own material: [https://www.rist.tv/](https://www.rist.tv/)
- ITU-R P.838, specific attenuation model for rain — the frequency dependence behind the C-to-Ku fade argument: [https://www.itu.int/rec/R-REC-P.838/](https://www.itu.int/rec/R-REC-P.838/)
- ITU-R P.618, propagation data and prediction methods for Earth–space telecommunication systems: [https://www.itu.int/rec/R-REC-P.618/](https://www.itu.int/rec/R-REC-P.618/)
- ITU-R P.837, characteristics of precipitation for propagation modelling — the rainfall statistics a per-site fade estimate needs ([Economics](economics.md) §6.1): [https://www.itu.int/rec/R-REC-P.837/](https://www.itu.int/rec/R-REC-P.837/)
- FCC 20-22, _Expanding Flexible Use of the 3.7 to 4.2 GHz Band_, GN Docket 18-122 — the C-band clearing and fixed-satellite repack: [https://docs.fcc.gov/public/attachments/FCC-20-22A1.pdf](https://docs.fcc.gov/public/attachments/FCC-20-22A1.pdf)

**Background**

- MPEG-TS over MOQ: [https://edis.mx/insights/mpeg-ts-over-moq.html](https://edis.mx/insights/mpeg-ts-over-moq.html)
- MPEG-TS over MOQ — PCR: [https://edis.mx/insights/mpeg-ts-over-moq-pcr.html](https://edis.mx/insights/mpeg-ts-over-moq-pcr.html)
- MPEG-TS over MOQ — pacing: [https://edis.mx/insights/mpeg-ts-over-moq-pacing.html](https://edis.mx/insights/mpeg-ts-over-moq-pacing.html)
- MOQ Interop Runner: [https://github.com/englishm/moq-interop-runner](https://github.com/englishm/moq-interop-runner)
