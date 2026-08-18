# Glossary: the two data planes in broadcast terms

The documents in this repository use two vocabularies. This is the whole of each, in the nearest
broadcast equivalent. The two are worth reading side by side, because several rows are the same idea
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
| **Origin** (`--origin <id>`) | An identifier by which two publishers declare they carry interchangeable content, i.e. a 1+1 pair. |
| **Route reselect** | A relay switching from a failed publisher to a standby carrying the same feed. |
| **Publisher / subscriber** | The sending and receiving endpoints. In this work they are `moq import ts` and `moq export ts`, which convert between MPEG-TS and MoQ tracks. |
| **Media-aware lane** | Carriage that demultiplexes the transport stream into MoQ tracks and re-muxes at the subscriber. The preferred path, and the one almost every measurement here was taken on. |
| **Opaque lane** | Carriage that treats the transport stream as an opaque byte stream and segments it into objects, preserving it verbatim. The fallback. The MPEG-TS-over-MoQ community calls the same property *transparent passthrough*; the two terms are interchangeable. |

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

## Broadcast terms used without definition

Assumed familiar, and listed only to fix the sense in which this repository uses them.

| Term | Sense used here |
|---|---|
| **Primary distribution** | The trunk layer: a small number of high-value feeds from playout to known, contracted professional endpoints. Distinguished from *contribution* (toward origination) and *distribution* (to the consumer) in [Problem](problem.md) §1. |
| **IRD** | Integrated Receiver Decoder — the professional receiving equipment at the far end of a primary-distribution route. Capital equipment on a five-to-fifteen-year replacement cycle. |
| **TR 101 290 P1 / P2** | ETSI's measurement guidelines for DVB transport streams. P1 is the first priority set (including PCR repetition ≤ 40 ms); P2 the second (including PCR accuracy ±500 ns). Used throughout as the acceptance criterion an IRD applies. |
| **PCR** | Programme Clock Reference. The 27 MHz timestamp an IRD locks a phase-locked loop to. Its *values* survive any transport that carries the bytes; its *inter-packet cadence* does not. |
| **Grooming** | Used in this repository for the edge stage that reconstructs a constant mux rate from bursty arrival: re-inserting null stuffing, pacing the output as byte-locked CBR, and re-stamping PCR against the reconstructed clock. Not re-multiplexing — PIDs, PES and signalling are untouched. |
| **CBR / stuffing / nulls** | A constant-bit-rate multiplex is padded to a fixed rate with null packets on PID `0x1FFF`. That constant cadence is what an IRD's clock recovery locks to, and it is what every Internet-native transport destroys and an edge stage must rebuild. |
| **ST 2022-7** | SMPTE's seamless protection switching: two packet-identical streams with aligned RTP sequence numbers, merged at the receiver. The last-hop redundancy mechanism this architecture depends on ([Architecture](architecture.md) §5). |
