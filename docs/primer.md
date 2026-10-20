# A Primer: MPEG-TS, SRT, Segmented HTTP and MoQ

Status: working draft.
Layer: background. How the stream format and the three transports work, for a reader who knows some of
them and not others; no verdicts and no measurements.
Scope: terms defined in the [Glossary](glossary.md) are linked rather than defined again. Which
transport suits primary distribution, and why, is [Comparison](comparison.md); every measurement is in
[Evidence](evidence.md).

---

## 1. MPEG-TS in a page

An MPEG transport stream (ISO/IEC 13818-1) is a continuous sequence of 188-byte packets. Each begins
with the sync byte `0x47` and a four-byte header. Its 13-bit **packet identifier (PID)** says which
stream the packet belongs to, and its four-bit **continuity counter** counts packets per PID, so a
receiver can tell that a packet went missing, though not how many once sixteen or more have gone. An
optional adaptation field carries the clock and padding.

The payloads are of two kinds. *Elementary streams* (a video, each audio language, subtitles, teletext,
SCTE-35 cue messages) are cut into PES packets, each stamped on a 90 kHz clock with when to present it
(PTS) and often when to decode it (DTS). *Tables* describe the multiplex. The PAT, on PID 0, lists the
programmes and where each one's PMT is. The PMT lists a programme's elementary streams by PID and type,
and names the PID that carries its clock. The CAT, on PID 1, points at conditional-access data. DVB adds
service information that receivers and programme guides use: the SDT for service names, the NIT for the
network, the EIT for the schedule, and the TDT and TOT for time. A distribution feed is usually a
**multiplex** of several programmes (an MPTS); a single-programme stream is an SPTS.

**The clock.** The encoder runs a 27 MHz system clock and writes samples of it into the stream as the
[PCR](glossary.md), on one PID per programme: at least every 100 ms by the standard, and every 40 ms in
the older DVB recommendation this paper grades against. A receiver recovers the encoder's clock by
comparing the PCR values with when they arrive, through a phase-locked loop; PTS and DTS, on the same
clock, then say when each picture and audio frame is due. So a transport stream carries its timing
twice: in the *values* it asserts, and in *when its packets arrive*. Any transport preserves the first
by carrying the bytes. The second survives only if the transport reproduces the sender's packet timing,
or if something at the far end rebuilds it. The PCR's 33-bit base wraps about every 26.5 hours, which
receivers handle and test rigs therefore have to exercise.

**Constant bit rate.** A broadcast multiplex runs at a fixed rate, padded with null packets where the
content does not fill it ([CBR, stuffing and nulls](glossary.md)). The fixed rate comes from the channel,
since a transponder or an ASI link carries one rate, and IRD clock recovery is designed around that
steady arrival. A statistical multiplexer shares the fixed total between programmes, so each
programme's own rate varies while the multiplex's does not.

**The buffer model.** The standard defines conformance by a model receiver, the [T-STD](glossary.md).
Each PID's packets enter a small transport buffer and drain at a fixed rate into the stream's decoder
buffer, which each access unit leaves whole at its decoding time. A conformant stream never overflows or
underflows any of these buffers, measured on its own PCR clock. That makes the *order and spacing* of
packets part of conformance, not only their content. A multiplexer schedules packets to keep every
buffer legal, and anything that reorders or re-spaces them inherits that obligation.

**Monitoring it.** ETSI TR 101 290 ([Glossary](glossary.md)) is the industry's monitoring checklist,
grouped in three priorities. It checks whether the stream can be decoded at all (sync, PAT and PMT
present and repeated, continuity, referenced PIDs present); whether its clock is carried properly (PCR
repetition, and PCR accuracy within ±500 ns); and whether its service information is present. It does
not grade the T-STD, so a stream can pass TR 101 290 and still not be conformant.

**What the receiver does.** An IRD locks to the sync byte and reads the PAT and PMT. It selects the
service, recovers the clock, and descrambles if the service is scrambled (BISS, or a conditional-access
system carried through the CAT and its own streams). Then it decodes, or passes the multiplex on.
Whatever carries the feed must hand that receiver a stream it accepts. A transport that changes the
bytes, their order or their timing has to put them back, and that stage, the edge gateway, is where
this paper spends most of its effort ([Architecture](architecture.md) §4).

---

## 2. SRT: a reliable tunnel with a fixed delay

SRT (Secure Reliable Transport) is an open protocol with an open-source library, `libsrt`, built to move
a live stream between two points over the public internet. It runs over UDP, and each SRT session joins
**exactly two endpoints**.

**Connecting.** One end is the *listener*, waiting on a port; the other is the *caller*, which dials it.
In *rendezvous* mode both dial each other at once, which helps through firewalls. Which end calls is
independent of which way the media flows, so a receiver behind NAT can call out to a sender that
listens. A listener can take many callers on one port, told apart by a stream ID that the caller sends,
and that ID is also where access is usually decided.

**Sending.** In live mode the sender carries the transport stream unchanged, usually seven TS packets
(1,316 bytes) to a datagram, at the rate it arrives. There is no congestion control in the TCP sense,
only an optional cap on how much bandwidth retransmissions may add. Each datagram carries a sequence
number and a timestamp of when the sender took it in.

**Recovering.** The receiver acknowledges what arrives and sends a negative acknowledgement for every
gap, and the sender keeps recent packets and retransmits them on request. This is ARQ, repair by asking
again, and each attempt costs a round trip.

**Timing.** The receiver holds every packet until its sender timestamp plus a fixed **latency** has
passed, then releases it (timestamp-based packet delivery). Its output therefore reproduces the sender's
packet spacing, delayed by the latency, with the network's jitter absorbed. That is why an SRT receiver
can hand an IRD a CBR multiplex with its original cadence. A packet that has still not arrived by its
release time, however many retransmissions were tried, is dropped. The latency setting is therefore
both the delay and the repair budget. A common rule of thumb sets it to three or four times the
round-trip time, more on lossy paths; `libsrt`'s default is 120 ms.

**Securing.** Payloads can be encrypted with AES at 128, 192 or 256 bits, using keys derived from a
pre-shared passphrase and exchanged in the handshake.

**Scaling.** Every receiver needs its own session, and every session its own copy of the stream from
whatever holds the other end. Serving N destinations takes N sessions from the source, or a tier of
gateways that each take one session in and send several out, a tier the operator builds, runs and pays
for ([Problem](problem.md) §2.3). RIST and Zixi have the same shape; RIST is the openly specified,
multi-vendor member of the family ([Comparison](comparison.md) §10).

SRT neither reads nor changes the transport stream. It delivers the source's bytes, in the source's
order, at the source's timing, late by the latency.

---

## 3. Segmented HTTP: files a cache can serve

Segmented HTTP turns a live stream into a series of files and lets ordinary web infrastructure deliver
them. This paper assesses HLS, whose original container is MPEG-TS. DASH works the same way with a
different manifest ([Comparison](comparison.md) §1).

**Packaging.** A packager cuts the live stream into [media segments](glossary.md) a few seconds long, at
points a decoder can start from, so that each is a standalone file. It writes them to an origin web
server and maintains a **media playlist** listing the most recent. Older segments drop off the list but
stay fetchable for an availability window. A multivariant playlist lists alternative renditions.

**Receiving.** There is no session, and nothing is pushed. The receiver fetches the playlist, then each
new segment by its URL, and re-fetches the playlist to learn what has appeared since. Each fetch is an
ordinary HTTP request, over TCP (HTTP/1.1 or HTTP/2) or over QUIC (HTTP/3).

**Scaling.** A segment is an immutable object with a name, so any HTTP cache can serve it. A CDN edge
fetches it from the origin once and serves every receiver behind it. Fan-out is the delivery network's
job, bought as a commodity, and the origin sees one request per edge rather than one per receiver
([Comparison](comparison.md) §2).

**Recovering.** Loss inside a fetch is repaired by the transport's own retransmission. A fetch that
fails can be retried, from the same edge or another, for as long as the segment remains in its
availability window. Redundant variant streams and content steering give a receiver a second path. So
recovery is a property of the cache, not of a session ([Comparison](comparison.md) §3.2).

**Latency.** A receiver cannot fetch a segment until it is complete, and it starts a few segments back
from the live edge so that it does not stall, so latency is a multiple of the segment duration.
Low-Latency HLS cuts that multiple three ways. It publishes [partial segments](glossary.md) of a few
hundred milliseconds before the whole segment is complete. It lets the receiver hold a playlist request
open until the next part exists. And it sets the starting distance from the edge with
[`PART-HOLD-BACK`](glossary.md), whose floor is the structural limit on its latency
([Comparison](comparison.md) §5).

**What it does to a transport stream.** Each TS segment must carry exactly one programme, with its PAT
and PMT. A multi-programme multiplex therefore has to be split into one rendition per programme, and the
specification is silent on the DVB service information the multiplex carried. Segments also arrive in
bursts, a fetch at a time, so the source's packet timing is gone. A receiver that must feed an IRD has
to reassemble the segments into a continuous stream and rebuild its constant-rate cadence and clock: the
[ABR2TS](glossary.md) stage, then [grooming](glossary.md) ([Comparison](comparison.md) §4).

**Securing.** Delivery is over HTTPS. Segments can also be encrypted, with keys the playlist points to,
and access is usually enforced at the CDN with signed or tokenised URLs.

---

## 4. MoQ: subscriptions carried through relays

Media over QUIC is a publish/subscribe transport for live media. The IETF's MOQ working group is
standardising it as MOQT, and it is implemented by, among others, the open-source `moq-dev` project,
whose simpler wire protocol, [moq-lite](glossary.md), is the one measured here. It runs on
[QUIC](glossary.md), directly or inside WebTransport, so every hop is encrypted with TLS 1.3 and has its
own congestion controller.

**The model.** A publisher announces a **broadcast** under a name, and a broadcast holds **tracks**: one
per elementary stream, or one for a whole multiplex. A track is a sequence of **groups**, each beginning
at a point a decoder can start from, and a group is a sequence of **objects**, roughly a frame each. A
**catalog** track says what the other tracks are. (Each term is defined in the [Glossary](glossary.md)'s
MoQ table.) Subscribers subscribe to tracks by name; nothing is fetched by URL, and nothing is polled.

**Delivery.** Objects are pushed to subscribers as they are produced. Groups travel on separate QUIC
streams, so a lost packet delays only its own group, where on a single TCP connection it would hold up
everything behind it. QUIC retransmits lost packets within a stream, and the sender's congestion
controller sets how fast it sends.

**Latency over completeness.** When the path cannot keep up, the sender does not build a growing
backlog. It favours the newest group and abandons older ones that have fallen too far behind, so the
subscriber skips forward to a fresh starting point instead of drifting further from live. Where an SRT
receiver would drop late packets and a segmented-HTTP receiver would stall, a MoQ subscriber sees whole
groups missing. How far behind a subscriber may fall before content is dropped is a setting, and it is
MoQ's counterpart to SRT's latency.

**Relays.** A [relay](glossary.md) takes each track in once and forwards it to every subscriber that
asks, keeping recent groups so that a late joiner can start at once from the latest group boundary.
Relays learn where feeds are from announcements, and they can be chained into a tree, so the source
sends one copy whatever the audience. They do not inspect or alter the media. Unlike an HTTP cache, they
hold a live session with every subscriber ([Architecture](architecture.md) §8).

**Redundancy.** Each publisher announces under its own [epoch](glossary.md), and a relay serves the
newest; when it fails, an older one still announcing takes over as a restart, which a subscriber sees
as a programme switch. Legs of one publisher's broadcast carried over two paths are what a receiver
can merge. What that buys, and what it does not, is in [Architecture](architecture.md) §5.

**Carrying a transport stream.** There are two ways, which this paper calls lanes
([Architecture](architecture.md) §6). The [media-aware lane](glossary.md) demultiplexes the TS at the
publisher into one track per elementary stream, with groups at keyframes, and the subscriber builds a new
transport stream from the tracks. It is a [transmux](glossary.md): the source's packet layout, its PCR
cadence and anything not mapped onto a track are regenerated or lost. The [opaque lane](glossary.md)
cuts the multiplex's own bytes into objects on one track and delivers them verbatim, so the source's
signalling and programme structure arrive intact by construction. On either lane the receiver gets
bursts of objects rather than the source's packet timing. The IRD hand-off therefore needs the same
edge stage as segmented HTTP: a groomer that rebuilds the constant-rate cadence and clock, and on the
media-aware lane a multiplexer as well ([Architecture](architecture.md) §4).

---

## 5. Side by side

| | SRT | Segmented HTTP | MoQ |
|---|---|---|---|
| **Shape** | one session per receiver | stateless requests for named files | subscriptions to named tracks, each a live session |
| **Who moves the media** | the sender pushes | the receiver pulls, polling a playlist | the publisher pushes, through relays |
| **Unit of delivery** | a datagram of seven TS packets | a segment, or a partial segment | an object within a group |
| **Fan-out** | more sessions, or a gateway tier the operator runs | HTTP caches, bought from a CDN | a relay fabric |
| **Loss repaired by** | retransmission on request, inside the latency | the transport's retransmission, then a re-fetch inside the availability window | QUIC retransmission; whole old groups dropped when the subscriber falls behind |
| **Latency set by** | the latency setting | segment or part duration, and the hold-back | how far behind the subscriber may fall, and the path |
| **What arrives** | the source's bytes at the source's timing, delayed | the source's bytes, one programme per segment, in bursts | media-aware: tracks to re-multiplex; opaque: the source's bytes, in bursts |
| **Before an IRD** | an SRT input or gateway; the timing is reproduced | reassembly and grooming | grooming, plus a multiplexer on the media-aware lane |
| **Encryption** | AES from a pre-shared passphrase | HTTPS, with optional segment encryption | TLS 1.3 on every hop |

Which of these differences decide primary distribution, and by how much, is the subject of
[Comparison](comparison.md), whose verdicts are in §13; the requirement set they are scored against is
[Problem](problem.md) §5.
