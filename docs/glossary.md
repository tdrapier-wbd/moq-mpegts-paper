# Glossary: the two data planes in broadcast terms

The documents in this repository use two vocabularies, and both rest on a handful of internet-transport
terms that a broadcast engineer need not have met. This is the whole of each, in the nearest broadcast
equivalent. The two are worth reading side by side, because several rows are the same idea
under different names — a **group** and a **segment** are both "the point a receiver can join at",
and a **catalog** and a **Media Initialization Section** are both "what PAT/PMT tells you".

---

## MoQ

Terms are from the IETF Media over QUIC working group's drafts and from `moq-dev`'s implementation,
which is what the prototype runs on.

| MoQ term | What it means here |
|---|---|
| **Broadcast** | One named feed, roughly a service or channel. Note it does not mean "broadcast" in the RF sense. |
| **Track** | One elementary stream inside that feed: video, an audio pair, or data such as SCTE-35. |
| **Group** | A self-contained run of a track that starts at a keyframe, and the point a new subscriber can join at. The closest analogue is a GOP. |
| **Object** | The individual unit of delivery within a group, roughly a frame's worth of bytes. Loss stalls one object rather than the whole multiplex. |
| **Catalog** | The manifest saying which tracks exist and how they are coded. The closest analogue is PAT/PMT. |
| **Announce** | How a publisher advertises that a feed exists, so relays learn where to route it from. |
| **Namespace** | The name prefix under which a publisher's feeds are announced and under which subscribers discover them, much as a service is found by its identifiers rather than by its PIDs. Not to be confused with the Linux *network namespace* that names one of the test rigs ([Evidence](evidence.md) §3.3). |
| **SETUP** | The first control exchange of a MoQ session, in which the two ends agree the protocol version before anything else is sent. A relay that refuses it never carries media ([Evidence](evidence.md) §3.7). |
| **Hop** (`--hop <id>`, formerly `--origin`) | An identifier a publisher stamps as the first hop of its route, by which two publishers declare they carry interchangeable content, i.e. a 1+1 pair. Current builds refuse `--origin`; unset, each publisher mints its own. |
| **Route reselect** | A relay switching from a failed publisher to a standby carrying the same feed. |
| **Publisher / subscriber** (importer / exporter) | The sending and receiving endpoints. In this work they are `moq import ts` and `moq export ts`, which convert between MPEG-TS and MoQ tracks, and the documents call them the *importer* and *exporter* when that conversion is the point. |
| **Media-aware lane** | Carriage that demultiplexes the transport stream into MoQ tracks and re-muxes at the subscriber — for a TS hand-off, a **transmux**, with the structural limits in [Comparison](comparison.md) §8. The preferred path, and the one almost every measurement here was taken on. |
| **moq-lite** | `moq-dev`'s own wire protocol, distinct from the IETF `moq-transport` drafts. The media-aware lane runs on it; which protocol each lane exercised is stated in [Evidence](evidence.md) §1. |
| **Opaque lane** | Carriage that treats the transport stream as an opaque byte stream and segments it into objects, preserving it verbatim. Measured here only as a private loopback prototype, used as the reference for byte-for-byte transparency rather than as a deployable path ([Evidence](evidence.md) §1). The MPEG-TS-over-MoQ community calls the same property *transparent passthrough*; the two terms are interchangeable. |

## Segmented HTTP (HLS carrying MPEG-TS)

Terms are from [HTTP Live Streaming 2nd Edition](https://datatracker.ietf.org/doc/draft-pantos-hls-rfc8216bis/)
(`draft-pantos-hls-rfc8216bis-22`, which obsoletes RFC 8216 and folds in Low-Latency HLS). The
comparison that uses them is [Comparison](comparison.md).

| HLS term | What it means here |
|---|---|
| **Media Segment** | A few seconds of one programme as a standalone file. Here it is an MPEG-TS file, and it **must carry exactly one MPEG-2 programme** — the constraint that rules out a contribution mux ([Comparison](comparison.md) §6). The nearest MoQ analogue is a group. |
| **Partial Segment** (`EXT-X-PART`) | A fraction of a segment, typically 200–330 ms, published before the segment completes. This is what makes Low-Latency mode low-latency, and it may also be MPEG-TS. The nearest MoQ analogue is an object. |
| **Media Initialization Section** | What a receiver needs before it can decode a segment. For MPEG-TS it is defined as a PAT followed by a PMT, and every segment must carry both. Note what is *not* in it: SDT, NIT, EIT, TDT and TOT appear nowhere in the specification. |
| **Media Playlist** | The list of segments currently available for one rendition, re-fetched continuously. It is the closest thing to a subscription: there is no session, only a receiver repeatedly asking what exists now. |
| **Multivariant Playlist** | The top-level list of renditions and their properties. Loosely a catalog. |
| **Blocking Playlist Reload** | The server holds a playlist request open until the part the receiver asked for exists, instead of answering "nothing new yet". It is how a pull protocol approximates push, and it is why the delivery path must not time out held requests. |
| **`PART-HOLD-BACK`** | How far back from the live edge a receiver must start. At least twice, and preferably three times, the part duration — the structural floor under Low-Latency HLS's latency ([Comparison](comparison.md) §5). |
| **Availability Duration** | How long a segment stays fetchable after it leaves the playlist. This is the retry window, and it is what makes recovery a cache problem rather than a session problem ([Comparison](comparison.md) §3.2). |
| **`EXT-X-DATERANGE`** | Where SCTE-35 goes: the specification defines an explicit mapping of `splice_info_section()` into a playlist tag, so splice signalling travels out of band rather than depending on an in-band PID surviving transit. |
| **Redundant Variant Stream / Content Steering** | Two disjoint delivery paths for the same feed, and the mechanism by which a receiver moves between them. The specified equivalent of a 1+1 pair with receiver-side selection. |
| **ABR2TS** *(vendor term, not in the specification)* | The stage that turns segments back into a continuous transport stream for the installed base. Professional IRDs and edge gateways list it as an input mode; a distributor may buy such a box as its *own* edge stage, but cannot assume a client's receiver has one, so this does not remove the hand-off obligation ([Comparison](comparison.md) §4). |

## Transport and deployment terms

These carry the reliability, scaling and cost arguments, so they appear in every document.

| Term | What it means here |
|---|---|
| **QUIC** | The internet transport MoQ runs on (RFC 9000), carried in UDP. It encrypts the session, retransmits lost packets and controls its own sending rate, and it lets many independent streams share one connection so that a loss on one does not hold up the others. |
| **QUIC stack** (quinn, noq) | The software library that implements QUIC inside the relay and its clients. `moq-dev` ran on quinn and now runs on noq, a fork of it. Results here name the stack because the same MoQ code behaves differently on the two under loss and reordering ([Evidence](evidence.md) §3.3). |
| **Relay** | A server that takes in a feed once and forwards it to every subscriber that asks for it, keeping recent groups so that a late joiner can start at a group boundary. The MoQ counterpart of a CDN edge. It does not inspect or alter the media. |
| **Fan-out** | Serving one feed to many destinations. On the internet the last hop to each destination is always its own copy; what a relay tree saves is the copies upstream of that, not the last-mile ones ([Economics](economics.md) §4.5). |
| **Egress** | Traffic leaving a cloud provider or network towards the internet, usually billed per gigabyte. It is the line that dominates the cost model ([Economics](economics.md) §1). |
| **Congestion controller** (BBR, CUBIC) | The sender's rule for how fast to send, given the loss and delay it observes. CUBIC backs off on packet loss; BBR estimates the path's bandwidth and round-trip time, and its versions differ in how much loss moves it. SRT in live mode has none: it sends at the source rate and retransmits within a fixed delay. |
| **Loss, reordering, outage** | The three impairment shapes measured: packets that never arrive, packets that arrive out of order, and a path that carries nothing for a while. QUIC declares a packet lost once enough later packets have arrived, so heavy reordering can read to the sender as heavy loss. |
| **Idle timeout** | How long a QUIC endpoint waits without hearing from its peer before it treats the session as dead — 30 s by default on the builds most results here were measured on, and 10 s on upstream `main` from [#4606](https://github.com/moq-dev/moq/pull/4606). It bounds how quickly a hard failure is detected, and an outage longer than it ends the session ([Evidence](evidence.md) §3.4). |
| **GSO** (generic segmentation offload) | A Linux host setting that lets a sender hand the kernel many packets in one call. It changes relay CPU cost materially, so every capacity figure names it ([Evidence](evidence.md) §3.6). |
| **Supervisor** | A process manager, such as systemd, that restarts a program when it exits. On the current build the subscriber needs one to survive a lost session ([Evidence](evidence.md) §3.4). |

## Broadcast terms used without definition

Assumed familiar, and listed only to fix the sense in which this repository uses them.

| Term | Sense used here |
|---|---|
| **Primary distribution** | The trunk layer: a small number of high-value feeds from playout to known, contracted professional endpoints. Distinguished from *contribution* (toward origination) and *distribution* (to the consumer) in [Problem](problem.md) §1. |
| **IRD** | Integrated Receiver Decoder — the professional receiving equipment at the far end of a primary-distribution route. Capital equipment on a five-to-fifteen-year replacement cycle. |
| **TR 101 290 P1 / P2** | ETSI's measurement guidelines for DVB transport streams. P1 is the first priority set (including PCR repetition ≤ 40 ms); P2 the second (including PCR accuracy ±500 ns). Used throughout as the acceptance criterion an IRD applies. **Do not read these as the measurement points P0/P1/P2**, which say where a figure was taken rather than which conformance set it was graded against; [Evidence](evidence.md) defines those and labels every result with one. The collision is unfortunate and both vocabularies are load-bearing, so each use here is qualified by *conformant* or by *measurement point*. |
| **T-STD** | The transport-stream system target decoder of ISO/IEC 13818-1: per-PID transport and decoder buffers, of fixed size and drain rate, that a conformant stream must never overflow or underflow on its own PCR clock. TR 101 290 P1/P2 does not grade it, so a stream can pass P1/P2 and not be conformant ([Evidence](evidence.md) §3.16). |
| **Transmux** | Carriage that takes a transport stream apart into its elementary streams and has the receiving end build a new one. The source's packet layout is not carried, so the receiving end has to act as a multiplexer. Distinguished from byte-faithful carriage, which delivers the source's own packets in their order. |
| **PCR** | Programme Clock Reference. The 27 MHz timestamp an IRD locks a phase-locked loop to. Its *values* survive any transport that carries the bytes; its *inter-packet cadence* does not. |
| **Grooming** | Used in this repository for the edge stage that reconstructs a constant mux rate from bursty arrival: re-inserting null stuffing, pacing the output as byte-locked CBR, and re-stamping PCR against the reconstructed clock. Not re-multiplexing — PIDs, PES and signalling are untouched. The *groomer* is the process that does it (here `mpegts-pacer`), and its *cushion* is the depth of media it holds before emitting, which trades delivery latency against starvation ([Evidence](evidence.md) §3.2). |
| **CBR / stuffing / nulls** | A constant-bit-rate multiplex is padded to a fixed rate with null packets on PID `0x1FFF`. That constant cadence is what an IRD's clock recovery locks to, and it is what every Internet-native transport destroys and an edge stage must rebuild. |
| **ST 2022-7** | SMPTE's seamless protection switching: two packet-identical streams with aligned RTP sequence numbers, merged at the receiver. The last-hop redundancy mechanism this architecture depends on ([Architecture](architecture.md) §5). |
