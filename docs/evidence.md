# Evidence: Method, Results and Limits

Status: working draft.
Layer: **cross-cutting** — this is the empirical basis for every claim in
[Comparison](comparison.md), [Architecture](architecture.md) and [Economics](economics.md).

This document is organised by **question**, not by experiment. The per-experiment record — objective,
environment, exact commands, full result tables, pass criteria fixed in advance, and the corrections
each experiment forced — is the laboratory notebook in [`lab/`](../lab/README.md), and each result
below cites the experiment that produced it.

Three conventions apply throughout and are not decorative.

**Every conformance figure names its measurement point.** *P0* is the source before the transport,
*P1* is a captured file analysed offline, and *P2* is the live wire as a hardware analyser or IRD
would see it. **Nothing in this repository is a P2 result.** File analysis confirms the arithmetic of
a re-stamp; it cannot see a software pacer's scheduling jitter at the physical output. Where a
figure is *file* and the corresponding *wire* figure differs, both are given.

**Evidence measured against unmerged upstream code is marked `[unmerged]`.** It is the measurement of
a proposed fix, not of shipped behaviour, and one such fix in this campaign merged in a materially
different form after review — changing its own result. Do not plan against these. `[dev]` marks the
weaker case: merged, but onto a development branch that has not converged with the release line, so the
behaviour is settled while the version carrying it is not.

**Single-run results are marked as such.** Several matrices below are one run per cell. They
establish mechanism and ordering; they do not establish distributions.

---

## 1. What was measured, and on what

Results come from four code bases and it matters which produced which.

| Code base | Role here | Reach |
|---|---|---|
| **Upstream `moq-dev`, media-aware lane** (`moq import ts` → `moq-relay` → `moq export ts`) | The **preferred path** and the lane almost every result was measured on | Deployed over the public internet via an AWS EC2 relay |
| **[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)** (public, ours) | The CBR/PCR groomer, deliberately outside the transport | Exercised on both data planes |
| **Private opaque `m2ts` prototype** (draft-14, MSFTS `m2ts` packaging) | **Reference and benchmark** — it shows what byte-for-byte transparency looks like, so the media-aware lane's residual gaps are measured rather than asserted | **Loopback only. One run. Never deployed** |
| **TSDuck `hls` output and input plugins** | The *alternative data plane*, published and reassembled with the same tool used as the oracle throughout, so its results are directly comparable | Loopback |

| Property | Media-aware lane + `mpegts-pacer` | Opaque prototype (reference) |
|---|---|---|
| Wire version exercised | moq-lite-04/05 | `moq-transport` draft-14 |
| Elementary streams, original PIDs, SCTE-35 | preserved | preserved verbatim |
| Service layer (SDT/NIT, PMT PID, TSID/ONID) | preserved | preserved verbatim |
| EIT | round-trips section-for-section | preserved verbatim |
| TDT/TOT | carried, but **re-emitted on the exporter's own 30 s grid, so the clock arrives ~14 s late** | preserved verbatim |
| CBR and PCR cadence | restored downstream by `mpegts-pacer` — **on file; not on the wire at *any* depth, because the exporter emits PCRs too rarely to place, §3.2** | preserved end to end by the prototype's own pacer |
| Public-internet operation | yes | **no** |
| Congestion controller | BBR (explicit) | quinn default (CUBIC) |

### 1.1 Instruments, and what each cannot show

| Instrument | Used for | What it cannot show |
|---|---|---|
| TSDuck `analyze`, `continuity`, `pcrextract`, `pcrverify` | Structure, PID census, continuity, PCR interval and accuracy | Wire timing. `pcrverify` on a file checks PCR against byte position, i.e. the arithmetic of the re-stamp |
| `t13-cadence.py` (64 kB pipe reads, or per-datagram capture) | Burst size, gap distribution, coefficient of variation | Absolute rate on loopback — loopback inflates burst *rate*; burst *size* and inter-burst silence are structural |
| `t12-merge-oracle.py` + `t12-maskcmp.py` + `t12-seqskew.py` | ST 2022-7 merge behaviour, byte identity, skew | A hardware IRD's merge engine. It is a reference implementation of the selection rules. The oracle also degrades to noise on a pair that is not byte-identical, which is why the mask and skew tools exist |
| `compliance.py` / `t13-grade.py` | Structural and shape checks, packet conservation | Decoder acceptance |
| `t18-latency.py` | Delivery latency on the PES presentation timestamp, tapped at source and at groomed egress, plus a four-timestamp clock probe for the two-host case | Encoder and decoder delay, so it is not camera-to-display. The PTS is the one identifier that survives a media-aware remux *and* every byte-transparent arm, which is what makes one instrument grade all four planes |
| Interop client (`interop/`) | Media-level carriage through a third-party relay | Anything about pacing or conformance — deliberately out of scope for a relay test |
| `t6-hls-pull.py` | Serving-node and source-failover behaviour on the segmented lane, from a client that retries instead of exiting | Not a player: no ABR, no master playlist, no LL-HLS, and it ignores `EXT-X-ENDLIST`. It bounds what the protocol permits, which is the only way to separate that from what TSDuck and FFmpeg happen to implement — both abandon the stream on a failed playlist reload |
| `tc`/`netem` | Loss, delay, reordering, shaped bottleneck | Real congestion. `netem` loss is Bernoulli where real loss is bursty and RTT-coupled, and `netem` "jitter" reorders. It also does not deliver the loss it is commanded unless segmentation offload is disabled at both the kernel and the application — and the error differs per transport, so it distorts *comparisons*, which is why every impairment figure here is labelled with the fraction the shaper counted |
| Published price lists + `cost-model.py` | The economic model | Negotiated rates, which are not publishable |

**Two rig properties recur and both were found the hard way.** A capture window and a payload window
are not the same interval, so any ratio computed across two captures is invalid unless both cover the
same media — an error that appeared three times in this campaign, in three different rigs. And a
control with the mechanism removed is worth more than a second run of the same arm: a plain-UDP
control is what revealed that a "clean" RIST result was the publisher's own release granularity.
These and the rest are collected in [`lab/method-notes.md`](../lab/method-notes.md).

### 1.2 The validation pyramid and the acceptance gates

The campaign is ordered cheapest-and-most-decisive first, and every experiment maps onto one rung and
one gate. This is the ordering the laboratory notebook uses.

| Rung | What it establishes | Cost |
|---|---|---|
| 1 | **Media-layer round-trip fidelity** under complete, lossless carriage — every elementary stream, PID, `stream_type`, PMT descriptor, SCTE-35 PID and DVB service identity intact | cheap |
| 2 | **End-to-end integration over a real network**, through a cloud relay, under real loss and jitter | cheap |
| 3 | **File-based conformance** — PCR interval and accuracy, structural integrity. Catches gross problems and **does not prove hardware acceptance** | cheap |
| 4 | **Hardware TR 101 290 conformance** — a clean P1/P2 pass on a real IRD and analyser, on the live wire, sustained | **the decisive one** |
| 5 | **Non-ideal-source robustness** — open-GOP with recovery-point SEI, damaged and spliced audio, discontinuities, mid-stream PID changes | cheap, and it has done real work: it surfaced both media-aware import defects that closed upstream |
| 6 | **Redundancy drill** — induced path failure, hitless selection at the receiver | moderate |
| 7 | **Comparative lab** — head-to-head against the alternative data plane and against SRT under matched conditions | moderate |

Three acceptance gates sit on those rungs.

- **Gate 1 — media fidelity.** Rungs 1 and 5 pass. Cheap, do first. **Met** on both lanes at P1
  (§3.1).
- **Gate 2 — hardware conformance.** A TR 101 290 P1/P2 pass on real IRDs (rung 4).
  **Make-or-break; not attempted.** If this fails, fix grooming before anything else.
- **Gate 3 — resilience.** The hitless redundancy drill passes (rung 6). **Met in software against a
  reference receiver**; the on-hardware merge is part of Gate 2.

Two properties of this ordering are worth stating because they were decided in advance rather than
after the fact. **Rung 3 is necessary and not sufficient**, and the gap between rungs 3 and 4 turned
out to be measurable rather than theoretical (§3.2). And **rung 7 belongs before a data-plane
commitment rather than after one**: the comparative lab settled which data plane is harder to groom,
and settled it against the intuitive answer.


---

## 2. Summary of what is and is not established

| | Established | Not established |
|---|---|---|
| **Carriage** | Media-aware and opaque lanes carry a full broadcast mux with 0 continuity errors; segmented HTTP preserves mux *content* on three clips — service identity, PMT PID, CAT, TDT/TOT, all splice PIDs — and adds one PAT/PMT pair per segment, costing file-domain PCR accuracy; a 1/2/6 s duration sweep confirms that cost is per-segment, not cumulative. Over the public internet, all three lanes graded together: **byte-faithful SRT is transparent on every criterion including the 481 ns P2 gate**; **segmented HTTP reproduces its loopback result to 0.1 % — 302.148 µs against 302.4 µs predicted, exactly 1.00 injected pair per segment head — so the injection is a property of the segmenter and not of the path**; the media-aware lane preserves the mux as bytes and not as a timed object (stuffing, mux rate, PSI density, PCR spacing) | Multi-programme carriage through a real CDN; the opaque lane anywhere but loopback, and its PCR arithmetic at any gate. *The P2 gate cannot rank all three — it is undefined on a rate-less media-aware egress, though it is a real measurement on both byte-faithful lanes* |
| **Timing** | Grooming restores exact CBR and P2-limit PCR accuracy **on file**; a segmented-HTTP egress reaches the same standard on the **wire** with an 8 s cushion. On the MoQ lane, P1 PCR repetition on the wire **fails at every buffer depth and is not a depth problem**: the exporter emits PCRs too rarely for a groomer to place them (P1, `pcr_inserted=0`) | Anything at all on hardware; whether a denser exporter PCR cadence clears the gate |
| **Loss** | CUBIC collapses, BBR restores parity with SRT — and the same is true of segmented HTTP, so **loss does not separate the two data planes**: at a matched controller both hold full rate to 10 % (1.04 and 0.96 on BBR) and both collapse under CUBIC (0.17 and 0.13). **Reordering does separate them**, 0.98 against 0.19 on either controller, because QUIC's in-order delivery blocks. Segmented HTTP does not corrupt what it delivers *while it stays inside the origin's availability window*; a deeper ladder pushes it out between 7.7 % and 12.2 % applied loss, after which it re-anchors and leaves 7–82 s content holes, past ~20 % loss without the origin returning any error at all | Congestion control on a provisioned path; a controller recommendation for a permanent trunk; the same ladder against a real CDN edge rather than one plain origin |
| **Redundancy** | Two stream-clocked groomers are byte-identical and hitless through every upstream failure, single-track, one host. On the segmented lane a pair sharing one feed and one naming scheme is hitless with no receiver-side merge at all, and two packagers of one feed are byte-identical by default | Two hosts, two clocks; multi-track identity; a hardware merge. On the segmented lane: a distributed segment store, and a standby joining mid-stream |
| **Cost** | Wire multipliers on a real path; relay CPU and memory envelope | The opaque lane's wire cost; a second source profile |
| **Interop** | Media flows within one implementation and through none of eight others | Why three of the eight fail |
| **Latency** | Delivery latency measured on all four planes, on loopback and over the public internet, each graded against the conformance of the same bytes. **MoQ crosses the internet in 109 ms** against SRT's 1618 ms and segmented HTTP's 4067 ms; the path term is the round trip and nothing more (P2) | Encoder and decoder latency, so no camera-to-display total; a lossy or long path; whether RIST really beats SRT on a real path (its cells had not settled) |

---

## 3. Results by question

### 3.1 Does the transport carry a broadcast mux intact? — Yes on all three lanes, each departing from verbatim in a different direction

**End to end over the public internet.** Live MPEG-TS traverses the whole chain — SRT contribution
into an AWS EC2 host, import → relay → a local export — with **0 continuity errors**
([T4](../lab/test-4-remote-e2e-srt.md)), and the full ~9.93 Mbps contribution mux comes home over
QUIC at **9.48 Mbps sustained for four minutes, 0 CC** ([T8](../lab/test-8-srt-vs-moq.md)). A
third-party relay in Mexico, reached from an EC2 publisher in Ireland by a subscriber in London,
carried 300 s at 9.47 Mbps with 0 CC, 0 reconnects and all 8 elementary streams reconstituted.

**The service layer survives that path too, not only localhost.** Re-measured on the deployed build
(`0.9.11-eab96019`), a subscriber in London pulling the EC2 relay receives TSID, ONID, service name,
provider and type, SDT, NIT, the **source** PMT and PCR PIDs, AC-3 with its typing, teletext and all
three SCTE-35 PIDs, with 0 continuity errors — where the same leg, before the service-layer carriage fix
this campaign asked for, delivered two renumbered streams and no service layer at all. **TDT/TOT is the sole exception** and has a merged
upstream fix the deployed build predates. So the carriage result below is a real-path result, not a
loopback one ([T4](../lab/test-4-remote-e2e-srt.md)).

**Three data planes have now been graded against each other over that path by one instrument, and they
fail different halves of the question** ([T4](../lab/test-4-remote-e2e-srt.md), three-lane arm: same
clip, same origin, same 198,389-packet window, ungroomed measurement point, `t3-transparency.py` on all
three). **Byte-faithful SRT is transparent on every criterion** — 13 PIDs of 13 at their source numbers,
SDT, NIT, TDT/TOT, three splice PIDs, stuffing preserved, the source mux rate exactly (9,945,951 b/s),
an identical PSI cadence and PCR grid, 0 continuity errors, and **0 PCR-accuracy violations at the
481 ns P2 gate**. **The media-aware lane is faithful to the mux as a set of bytes and unfaithful to it as
a timed object:** identity, PIDs, SI and splice signalling all survive, while stuffing, the mux rate, PSI
density (8.04 → **2.51 PAT/s**, mean gap 124 → **399 ms** against P1's 500 ms limit) and PCR spacing do
not. The same capture's 0 continuity errors rule out the path as the cause.

**Segmented HTTP's loopback carriage result generalises to a real path, tested as a prediction rather
than confirmed after the fact.** Registered in advance from the loopback arm and then measured: content
intact (13 of 13 PIDs, TDT/TOT, stuffing, 0 CC, the source PCR grid at 0 % above 40 ms), criterion 6
failed by **+13 PAT and +13 PMT over equal media — exactly 1.00 pair per segment head** — at a cost of
**302.148 µs** of PCR accuracy against **302.4 µs** predicted from 376 bytes at the source rate, plus
0.043 % of added rate. **Per-segment TCP fetches across a ~125 ms path change none of the injection
accounting**, which is not something that could be assumed of a lane whose delivery model is a sequence
of separate HTTP requests. These two lanes also make the P2 gate usable over the wire for the first time
— both retain a mux rate for it to grade against, and they bracket the range: SRT at the instrument's
floor (1 tick, 37 ns), segmented HTTP at a fully explained displacement, with **0 violations at 500 µs**
bounding that displacement rather than merely counting it.

**Component fidelity on the media-aware lane** ([T2](../lab/test-2-media-aware-transparency.md), P1):
every elementary stream, at its **original PID**, with `stream_type` and PMT descriptors intact —
AVC video, MPEG-1 audio, AC-3 with correct DVB signalling, teletext with its descriptor, and **all
three SCTE-35 splice PIDs** with program-level CUEI registration. 0 continuity errors, 0 transport
errors. The DVB service layer — SDT service name, provider and type, NIT, PMT PID, TSID, ONID — is
threaded through the catalog and preserved.

**EIT round-trips, including the hard case** `[dev]` ([T17](../lab/test-17-si-snapshot-tracks.md)).
Measured against the upstream change carrying SI on per-table snapshot tracks, since merged, across four
sub-tables of an 8-day EPG, the set of distinct sections on the egress equals the source's exactly —
none missing, none added, sizes and `last_section_number` preserved — against **zero EIT packets on
the same fixture from the merge base**.

That result matters because the interesting sub-table cannot be validated by counting sections. An
EIT schedule sub-table is **sparse**: it declares a `last_section_number` spanning its whole
four-day range and transmits only the segment-boundary sections holding events — measured here as 32
sections against a declared 248 — so an importer cannot decide it is complete and must commit on
observing the transmission cycle wrap instead. **The corollary is a limit on the guarantee: in a
sparse table a lost section and a deliberately skipped section number are indistinguishable**, so a
section lost before the cycle wraps yields a snapshot quietly missing a segment. Nothing in the
algorithm can do better; that is what sparseness costs.

Two costs that theory predicted are not material. Carriage is **bitrate-neutral** — the EIT PID runs
at 28,445 bps on the egress against 28,870 bps at source (0.985×) — even though export re-emits at
the ETSI TS 101 211 maximum interval rather than the source's observed cadence. And the join costs
**1 ms**: a median 15 ms time-to-first-byte across six SI tracks against 14 ms across two, because
the subscriptions are issued together, making the cost a bandwidth term rather than a round-trip per
track. An 8-day EPG is 29,912 B across four snapshot tracks per service, so a 40-service multiplex
puts ~1.1 MiB across 160 tracks in front of the first TS packet: bounded, and bounded by the EPG's
size.

**That design carried a liveness risk, and measuring the join is what removed it.** As proposed, export
opened its output only once every SI entry either held a snapshot or had reached a terminal state, so an
entry that neither succeeded nor failed emitted **no TS at all, media included**. Because the join
measurement showed the subscriptions resolving inside the first poll, the gate was deleted rather than
given a timeout: nothing in SI is something a stream cannot begin without, since PAT and PMT are built
locally and a receiver acquires the service layer mid-stream by design.

**The clock is carried, and the residual is now its timing rather than its absence.** TDT/TOT is proxied
from the source, and TOT's `local_time_offset` descriptors — DST transition dates and per-country
offsets, which are operator policy rather than time — arrive byte-identical. That settles a design
question the alternative could not have: a clock synthesised at the edge would misplace every EIT event
by the offset between the two time bases, because EIT event times are absolute UTC and only the source's
own clock stays coherent with the schedule it accompanies.

What proxying does not fix is *when* the clock is emitted, and the two classes of stage differ sharply
here. The incumbent tunnels forward each tick: RIST and SRT deliver TDT with inter-section gaps matching
a no-transport control to two decimal places, because a constant-delay pipe is late by its path and by
nothing else. A stage that rebuilds the multiplex stores a section and re-emits it on its own grid, so
it is late by however long it held one — measured at **~14 s against a source true to 0.5 s** — and when
the source ticks slower than that grid it re-sends a time it has already asserted, stepping a trusting
receiver's clock *backwards* ([T15](../lab/test-15-point-to-point-cadence.md) measurement 4). The fix is
narrow and upstream: treat the interval as a floor on repetition and emit when the value changes.

**Real feeds broke naive import, and the gaps closed upstream.** Three defects, each measured before
and after the fix:

- **Open-GOP encodes** signalling recovery-point SEI rather than IDR (roughly one IDR every 15 s)
  produced no video rendition, because keyframe detection keyed only on the IDR NAL type. Open-GOP is
  common on contribution feeds, not a niche quirk. Fixed, and verified here rather than taken on
  trust.
- **Audio frame-sync loss was fatal to the whole publisher.** A single damaged byte in an MP2, AC-3
  or E-AC-3 frame header terminated the publisher and took every other track with it — video,
  teletext, all three SCTE-35 PIDs — while the video path resynchronised through identical
  corruption. That is the wrong way round for a contribution feed. Fixed within two days, and
  verified against both builds with three copies of a real capture differing by **exactly one byte**:
  the same damage that killed the previous release now costs **exactly one 24 ms audio frame**, with
  every other track intact and nothing spurious emitted.
- **A splice is not a bit error, and closing the first left the second open.** Where the damage is a
  corrupt byte the parser rejects the frame. Where it is a *splice* — a feed restarting, a looping
  file wrapping mid-frame — the header is intact and only the bytes after it are foreign, so the
  frame is published: not a frame lost but a frame **substituted**. That is harder to detect, because
  a substituted frame of the right length in the right place leaves the timeline intact. The
  mechanism that catches it was already in the stream and already implemented next door — the
  transport continuity counter, which the same demuxer checked for private sections but not for
  elementary streams — and upstream adopted exactly that.

**Two residuals survive that last fix, both measured.** The guard trusts one signal, so where a wrap
happens to leave the counter *contiguous* — about one cut point in sixteen — the splice is invisible
again. A codec CRC would close it, and AC-3's rejects every mixed frame measured, but it cannot be
the general answer because MP2 carries no CRC at all in this feed. And the fix has a cost that falls
unevenly: the truncated PES is meant to be flushed so the whole frames it already carried still
publish, which MP2 gets and AC-3 does not — about **256 ms of good audio lost per splice on AC-3**,
where MP2 loses nothing.

**One further residual is a gap rather than a fault, and it is architecturally significant.** A
recovered stream is **signalled nowhere** — no continuity error, no discontinuity indicator, no log
line, no counter. The audio timeline simply steps over the hole. A feed quietly losing frames is
indistinguishable from a healthy one. For an architecture that treats the ingest edge as the place
where a contribution feed's defects are absorbed, **the absorbing needs to be observable**.

**The opaque lane is byte-transparent, on one run.** TSID, ONID, service name and type, all PSI/SI
including TDT/TOT and CAT, PMT PID, PCR PID, every elementary stream and every SCTE-35 PID preserved
verbatim; 0 CC and transport errors; CBR and PCR conformance preserved when fed raw
([T3](../lab/test-3-opaque-transparency.md)). **Read that with §4's scope limit attached**: it is
loopback, file-fed, on a pinned obsolete draft, against a private implementation, and it has never
been repeated.

**Segmented HTTP is byte-verbatim in its payload for a single programme**, which is the opposite of
what the specification's wording suggests. A published segment aligned against the source and compared
packet by packet differs, in a 1,200-packet window, in **two packets, both PSI, each in byte 3
alone** — the continuity counter on the PAT and PMT the segmenter injects at each segment head, whose
renumbering is forced. Every media, audio, teletext, splice and stuffing packet is byte-identical, and
continuity is error-free across segment boundaries ([T14](../lab/test-14-data-plane-comparison.md)).
The DVB service layer travels too — not because the specification provides for it, which it does not,
but because nothing in the path parses the payload.

**The packager itself is media-aware, and the distinction matters for what may be claimed.** `tsp -O hls`
is not a byte splitter: it re-multiplexes, regenerates PSI and chooses segment boundaries by picture
type, and on a *finite* input it truncates roughly the last 5 % rather than flushing it
([T11](../lab/test-11-interop.md)). What the packet-by-packet comparison above establishes is that
those mechanisms happen to be payload-preserving on a live feed, not that nothing parses the stream.
So the accurate form of the claim is the one §8 of [comparison](comparison.md) uses — **verbatim in
payload, not as a mux** — and "nothing in the path parses the payload" is true of the *cache and the
network*, which is where the scaling argument needs it, and not of the packager.

**Scored against the opaque lane's own inventory, segmented HTTP is transparent to what a mux
contains and not to when it was sent** ([T3](../lab/test-3-opaque-transparency.md), three clips,
P1/file domain). On content it matches the opaque lane and beats the media-aware one: TSID, ONID,
service name, provider and type, PMT PID (0x1000, 0x0020 and 0x0064 all held rather than renumbered),
PCR PID, every elementary stream at its original PID including visual-impaired commentary audio,
every SCTE-35 PID, null stuffing, **CAT and TDT/TOT**, no table re-versioned, 0 continuity errors, 0
transport errors, and 0 PCR repetition intervals above 40 ms.

**The EPG survives it too, and the two planes pass that test for opposite reasons.** None of the three
clips carries EIT, so it is measured on a synthetic 8-day fixture through the same chain: all **69
distinct sections arrive byte-identical**, sparse schedule sub-tables included, each still declaring
the `last_section_number` it left with, at 1.003× the source's PID rate
([T17](../lab/test-17-si-snapshot-tracks.md) §5). The media-aware lane passes the same test at 0.985×.
The asymmetry is in how. An EIT schedule sub-table is *sparse* — it declares an extent covering days
and transmits only the sections holding events — so a lane that reconstructs the table must decide when
it is complete and cannot distinguish a section the source skipped from one it lost; the media-aware
lane takes that on and gets it right by committing on transmission-cycle wrap. The segmented lane never
parses PID 0x0012, so the problem does not arise. **Understanding the media is what creates the
obligation to understand it correctly**, and this is the cleanest instance of it in the campaign. The
cost lands on the other side: MoQ hands a joining receiver the whole EPG as snapshots in about a
millisecond, where a segmented client waits out the carousel — tens of seconds at the ETSI cadence,
with no HLS mechanism to shorten it.

What it adds is **exactly one PAT/PMT pair per segment and nothing else** — no PID at egress that the
source lacked — and that addition has a price the survival census cannot see. Two packets is 376
bytes, so inserting them at a segment head displaces every later PCR in that segment relative to a
constant-rate byte clock by the time 376 bytes take to transmit: predicted at 300.8, 109.4 and
302.4 µs on three clips spanning 2.75× in bitrate, measured at **297.7, 109.4 and 301.9 µs**.
File-domain PCR accuracy therefore falls from 37–74 ns to hundreds of microseconds, taking 2,453 of
~2,457 PCRs past the 481 ns P2 gate on the broadcast clip against the source's zero,
while every clip still passes the campaign's looser 500 µs pre-check.

**A segment-duration sweep confirms the mechanism on the parameter it predicts is irrelevant.** Holding
the clip and the window fixed and moving segment duration 1 s → 2 s → 6 s changes the injection count
5.7× (51, 26, 9 pairs) and the **maximum error by 1 %** (299.6, 301.9, 302.4 µs), which is what a
per-segment displacement does and an accumulating error does not. The *count* of violations, by
contrast, collapses 2,456 → 2,453 → **8**, tracking how far the injections shift the capture's mean
rate (+0.156 %, +0.042 %, +0.011 %) rather than the number of events. So P2 exposure at this point is
partly a segment-duration choice, the max is the result and the count is an indication.

Three things follow. **The deviation is bounded and already discharged** — the groomed version of
this same chain measures 0 violations at 481 ns (§3.2, [T16](../lab/test-16-grooming-segmented-http.md))
— so this is a demarcation result, not a fidelity one: a segmented-HTTP egress cannot be handed to an
IRD ungroomed on the strength of being verbatim. **The same injection buys P1 table margin**, because
an extra PAT can only shorten a repetition interval: on the clip with the least headroom the PAT mean
falls 475 → 402 ms against a 500 ms limit, with the maximum unmoved, and across the sweep the margin
falls monotonically as segments lengthen (113 → 118 → 122 ms against 125 ms). And **the two gates that
both get called "PCR conformance" disagree here by four orders of magnitude**, because inserting packets
changes no PCR value and every PCR's byte position — which is why every figure in this repository
carries the gate it was measured against.

**The P2 PCR-accuracy gate does not rank the three lanes, because it is undefined on one of them.**
It compares PCR values against the byte positions they arrive at, so it presupposes a mux rate. The
media-aware lane's ungroomed egress carries no stuffing and has none — `analyze` puts its rate at
22–32 **Gb/s** on 10–27 Mb/s content — and graded anyway the gate returns **exactly the maximum PCR
interval** (159.995 against 160.000 ms; 39.9886 against 39.9889 ms; 319.931 against 319.933 ms, on a
`moq 0.9.10-eab960192` capture). So the gate is informative where a mux rate survives — the source
clips, and segmented HTTP, which is why the injection was visible there at all — and is a category
error where one does not. Stated the other way, this is the same conclusion T13 and T16 reach from the
grooming side: on the media-aware lane the groomer is what *creates* the quantity the gate names. The
opaque lane is unmeasured at this gate, and being byte-preserving by construction its PCR arithmetic is
reasoned rather than measured ([T3](../lab/test-3-opaque-transparency.md)).

### 3.2 What does delivery do to the clock, and can it be repaired? — Partly, and the wire is not the file

**This is the load-bearing result in the repository and the one most often quoted without its
domain.**

**The problem.** Bursty delivery leaves a reconstructed transport stream with PCR *intervals* that no
longer track a constant mux rate: the bytes, PCR values included, are intact; the delivery *cadence*
is not. Soft players tolerate this; hardware IRDs lock a PLL to PCR and raise TR 101 290 P1/P2 alarms
in response. *(The IRD reaction is accepted broadcast practice, not something this campaign observed
— no hardware has been fed by this chain.)*

**Ungroomed, at P1 (file)** ([T2](../lab/test-2-media-aware-transparency.md),
[T7](../lab/test-7-timing-integrity.md)): **0–26 % of PCR intervals exceed the 40 ms limit, depending
on the source.** Per clip: 25.2 % on a synthetic 10 Mbps CBR reference, 13.9 % and 9.1 % on two real
CNN contribution captures, and **0 % on a 27.5 Mbps broadcast mux whose native 27 ms PCR cadence is
already inside the limit**. The opaque prototype fed the raw stream holds 0 % on every clip
([T3](../lab/test-3-opaque-transparency.md)), which isolates cadence loss to the re-mux rather than
to QUIC.

**The ungroomed egress does not inherit its interval distribution from the encoder — it manufactures
one, and the mean hides it** ([T4](../lab/test-4-remote-e2e-srt.md), over the public internet, current
build). On a source profiled across every span of its 600 s at a flat ~24.4 ms grid with a **24.95 ms
maximum and not one interval above 40 ms**, the egress conserves the mean interval to within 0.7 ms
(23.81 against 24.47 ms) and stays monotonic, while **1,123 of its 1,307 intervals fall under 1 ms** and
the residual time collects into 107 gaps of up to **319.94 ms**. PCR values are timestamps, so this is
independent of the stripped stuffing: the lane emits PCR-bearing packets in near-simultaneous clusters.
The proportion above 40 ms still varies by clip for reasons not established, so "depending on the
source" above describes the *size* of the effect and not its origin. This also corrects a claim
previously made in [T4](../lab/test-4-remote-e2e-srt.md), that the lane transports the cadence the
encoder produced — it does not, and
[T2](../lab/test-2-media-aware-transparency.md) had already recorded these figures as impairments
introduced by the lane. **The consequence for the groomer is a change of role, not of requirement: it
reconstructs a timeline the lane discarded rather than tidying an awkward encoder.**

**Groomed, as delivered — the figure to quote** ([T13](../lab/test-13-downstream-grooming.md)).
Measured on the socket at the ~1 s cushion the MoQ lane runs, the groomer delivers **131 PCR
intervals above 40 ms in 25 s on the laptop rig and 159 on the EC2 rig, with a 227.4 ms maximum.**
T13's own scoring records this as *"pass on file (0); **fail live**"* and instructs that criterion 3
be read on the live column when the question is what an IRD receives. **The MoQ lane at its current
depth is not P1-conformant on PCR repetition as delivered**, and any figure of "0 %" that does not
name the file domain is wrong. The mechanism is not a defect in the stage: a pass-through groomer
inherits the exporter's PCR spacing, and the MoQ egress arrives with 55 intervals already above 40 ms
and a 319.9 ms maximum, where a stage that mints its own PCR schedule places PCRs freely and posts
none in either domain.

**Groomed, on file — necessary, and demonstrably not sufficient**
([T7](../lab/test-7-timing-integrity.md), four clips). What file analysis establishes is that the
re-stamp *arithmetic* is right: **0 % of intervals above 40 ms**, exact CBR (bitrate = pcrbitrate =
userbitrate), **0 `pcrverify` violations at ±500 ns**, 0 continuity errors, 0 content packets
dropped. Tightening to absolute PCR units on a different rig gives **0 of 2,598 PCRs outside ±500 ns
on a groomed output, against 1,523 of 1,524 for the same feed delivered ungroomed**
([T12](../lab/test-12-dual-path-handoff.md)). That the stage computes the right stream is a
precondition for it emitting one on time, and nothing more — and neither of the two measurements
that ask the second question returns zero.

**Between the two: a live chain, analysed on file** ([T8](../lab/test-8-srt-vs-moq.md), EC2 → home
over the public internet, 30 s window, *one run, indicative*). Grooming a genuinely live arrival
rather than a capture takes the egress from **10.78 % of intervals above 40 ms, 1,200 ms maximum**,
to **0.06 % — 8 gaps, 139 ms maximum**, with 0 `pcrverify` violations at ±500 ns and exact CBR. Not
comparable cell-for-cell with T13 (different host, build, path and pacer mode) but pointing the same
way: an order of magnitude fewer events than T13's socket measurement, and still not zero. The
residue is therefore in the stage's real-time behaviour, not in T13's instrument.

**Groomed, on the wire, segmented-HTTP lane, 8 s derived cushion**
([T16](../lab/test-16-grooming-segmented-http.md)): **0** intervals above 40 ms, **0** PCR violations
at 481 ns over 2,496 PCRs (and 0 at 18 µs, a gate tighter than any other quoted in this campaign),
**0** continuity errors, `pcrbitrate` exactly the commanded rate, 10 ms coefficient of variation
0.068 against the ungroomed egress's 12.381, largest silence 17.2 ms against 4,011.9 ms — with
**nothing dropped and nothing muted**, and no flag set beyond the output rate.

**That result holds across clips, and it is bounded by bitrate rather than by content**
([T7](../lab/test-7-timing-integrity.md)). Repeating it on the four reference clips — a synthetic
exact-CBR stream, two real contribution captures and a 27.5 Mbps 4:2:2 broadcast mux — the three at
~10 Mbps deliver **0 intervals above 40 ms, 0 `pcrverify` violations at ±500 ns, 0 continuity errors,
and declared rate agreeing with PCR-implied rate to within a few parts per million**. The 27.5 Mbps clip does not, and the cause is the test
host rather than the lane: fed the same clip at the same output rate straight from a local file, with
no packager, origin or HTTP client anywhere in the chain, the groomer posts *more* violations than it
does through the segmented lane. So the segmented lane's conformance is established to ~11.5 Mbps and
**untested above it**, pending a host that can pace 30 Mbps without underrunning. Note also that the
*ungroomed* segmented egress already carries 0 intervals above 40 ms on every clip, because a segment
carries the source's own PCR grid in its payload: unlike the media-aware lane, this one gives the
groomer no PCR damage to repair, and what grooming buys there is cadence and CBR.

**On the segmented plane the constraint is buffer depth, not live operation.** T13 first read its 131
live intervals as a property of re-timing a stream as it arrives, against 0 when reading a file. The
segmented arm falsifies that reading by posting 0 *on the wire* while holding 8 s of cushion: what
constrains PCR placement *there* is whether the stage always has a packet ready at the deadline, which
is what depth buys.

**On the MoQ lane it is neither, and that has now been measured**
([T18](../lab/test-18-delivery-latency.md)). Sweeping the groomer's cushion across a ladder spanning
eight times the depth moves the lane's repetition figure **not at all** — 489–491 intervals above 40 ms
with a 228 ms maximum at every rung — and it stays at 502 when groomer starvation is removed altogether by
matching the carrier rate to the arriving content rate (`underruns` 18,070 → 5, stuffing 0.0 %). The
groomer's own counter settles the attribution: **`pcr_inserted=0`**, so every PCR on the egress came from
the lane. **The exporter does not emit PCR-bearing packets often enough for any downstream groomer to
place them**, which is the exact sense in which T13's word "inherits" was load-bearing.

> **This closes what was the most consequential open question in the repository, and the premise was
> wrong.** Grooming was thought to buy PCR repetition with latency, so the question was where the MoQ
> lane's curve crosses zero and whether that point is compatible with sub-second delivery. There is no
> crossing and no trade: on this lane the two axes are independent. A structural cost that would have had
> to be priced into every recommendation is instead **an upstream defect with an owner** — a PCR emission
> interval in the exporter. T18 predicts, and does not test, that emitting at a broadcast mux's ~25 ms
> cadence would clear the gate at the depth the lane already runs, which is 109 ms of delivery latency
> across the internet (§3.11). That prediction is now the cheapest high-leverage measurement outstanding,
> and it is blocked only on upstream, where the defect has been reported with the measurements behind it
> ([upstream contributions](../lab/upstream-contributions.md) §1).

**One groomer serves both data planes, and that part is demonstrated rather than argued.** The same
binary, no flag changed, inserted into the identical publisher-origin-receiver chain the ungroomed
segmented-HTTP figures came from, reaches the standard above. It measures how far ahead of real time
its input runs and derives the cushion, the buffer cap, the start condition and the stall timeout
from that one observation. On a MoQ egress the same derivation is a no-op, because the lead never
approaches its floor.

**Two costs of absorption are structural and survive grooming.** The segmented arm held **7.5 s of
programme before emitting a byte** and ran a **13.1 MB buffer**, and its derived stall timeout is
**~9 s against the MoQ lane's ~1 s** — on a segment-fetching leg a dead origin and a slow publish
cannot be told apart faster than a segment period. Segment duration still sets a latency floor; what
grooming removes is that floor being visible to the receiver as a cadence fault.

**A perfect wire is not evidence of a good groomer.** A configuration reachable by flag — raising
only the stall timeout, which is what an earlier reading of this problem proposed — posts the *best*
PCR record of any arm (0 violations at 481 ns over 2,723 PCRs, 7.9 µs max jitter) and a flat cadence,
over a stream carrying **231 continuity errors including on two of three SCTE-35 PIDs**. Every
measure of *when* bytes leave was satisfied; the failure is visible only in measures of *which* bytes
left. Any grading of a pacing stage needs a packet-conservation column beside the timing ones.

**Whether anything off the shelf does the whole job depends on the data plane.** Every candidate an
engineer would reach for was graded against four criteria fixed in advance, against both egresses
([T13](../lab/test-13-downstream-grooming.md)). **Behind a MoQ egress nothing passes, and the missing
half is carriage.** Behind a segmented egress, `tsp -P pcradjust -P regulate -O ip` passes all four
with the mux carried byte-for-byte, because the packager already delivered the stuffing (4.57 %
against the source's 4.59 %), the declared mux rate, and a PCR spacing with **0** intervals above
40 ms where a MoQ egress arrives with 163. The MoQ-lane table:

| Chain | Mux preserved | PCR ≤ 481 ns | No interval > 40 ms | Honest time, paced wire |
|---|---|---|---|---|
| TSDuck `regulate` alone | pass | **fail** (1,527) | **fail** (163) | pass |
| TSDuck `pcradjust` @ content rate + `regulate` | pass | pass | **fail** (299 file, 136 live) | pass |
| TSDuck `mux` nulls + `pcradjust` @ nominal | pass | pass | **fail** (284) | **fail** — duration 0.956; claims a rate it does not carry |
| FFmpeg `-muxrate`, PIDs pinned, own socket | **fail** — SCTE-35 retyped, AC-3 relabelled, SDT injected | pass | pass | **fail** — 8.11–46.34 Mb/s |
| FFmpeg `-muxrate`, PIDs pinned, **+ `rawsendmpeg2ts`** | **fail** — same carriage losses, plus NIT dropped | pass | pass (0 live, 20.4 ms max) | pass — 11.000 Mb/s, CoV 0.048, worst silence 3.5 ms |
| GStreamer `mpegtsmux`, PIDs pinned, SCTE-35 forwarded | **fail** — PSI beyond PAT/PMT, the PMT's own PID, teletext descriptor, 2 of 3 splice PIDs | pass | pass | partial — silences to 284 ms |
| `mpegts-pacer` *(control)* | pass | pass | pass on file; **fail live** (131/159) | pass |

**TSDuck cannot restore stuffing by construction** — `tsp` can overwrite existing null packets but
cannot inflate a stream, which its own plugin documentation states three ways over. A MoQ egress has
no nulls to replace.

**The wire half of grooming does have an off-the-shelf answer, and it isolates what is actually
missing.** A dedicated datagram sender after the muxer — 366 lines of C11 pacing 1316-byte datagrams
against absolute deadlines — leaves the stream untouched and changes only when packets leave. Holding
the muxer fixed and swapping only the egress takes the same FFmpeg output from a 6.55 coefficient of
variation, a 171× 10 ms peak-to-mean and a 265.8 ms silence to **0.048, 1.15× and 3.5 ms**, and
delivers the declared 11.000 Mb/s rather than the 12.721 Mb/s its own socket puts out while dumping a
join backlog. Replaying a CBR file the same sender is **byte-identical to it across 165,326
packets**. So a fully off-the-shelf chain now passes three of four criteria and **fails only
carriage**: PIDs can be pinned back, SCTE-35 stream types cannot, AC-3 is relabelled and the NIT is
dropped.

**The two halves of grooming therefore separate cleanly, and on the MoQ lane only one is unsolved off
the shelf:** tools that regenerate a mux can time it perfectly and cannot carry it, and tools that
carry it cannot inflate it. The requirement is documentable with standard tools wherever signalling is
not contractual; a mux carrying full signalling to a hardware receiver still needs a purpose-built
stage *on that lane*.

**Stated that precisely, the gap is conditional, and the segmented lane is the case where the
condition does not hold.** What defeats the off-the-shelf tools is not MPEG-TS grooming but two
properties of `moq export ts`: it drops stuffing, so a groomer must inflate a stream, and it emits
PCRs too rarely, so a stage that carries them rather than minting its own inherits non-conformant
spacing. A segmented egress has neither property, and the same tools pass. The honest general
statement is therefore about the exporter rather than the tooling: *an egress that drops stuffing and
thins PCR needs a grooming stage no off-the-shelf tool can supply without damaging the mux; an egress
that preserves both needs only a paced sender, and TSDuck is one.*

**On the segmented lane the binding constraint is buffer depth instead, and it is a hard edge rather
than a tuning choice.** A grooming stage fed 2 s segments must hold a cushion at least as deep as the
segment period. At 8 s, both the TSDuck chain and the pacer deliver 0 PCR intervals above 40 ms, 0
continuity errors and a rate flat to ±1 % per second. At 1 s the pacer starves twice in 25 s, going
silent for **1.85 s** at a time — the same figure in three independent instruments — for **311
continuity errors** and 14 % of the delivered rate. There is no partial-credit region between them.

**Buffer depth does not buy PCR repetition on either lane, which removes a feared trade.** Depth is
latency, and latency is MoQ's only advantage, so an earlier reading that credited T16's clean PCR
record to its deep cushion implied that conformance had to be bought with MoQ's lead. It does not:
[T18](../lab/test-18-delivery-latency.md) swept the MoQ cushion across eight times the depth with no
movement at all, and the segmented TSDuck chain posts 0 while holding almost no buffer. What decides
PCR repetition is the spacing the egress delivers. Depth only prevents a stage from *adding* faults by
running dry.

**What has not been exercised at all**: source-clock drift, PCR discontinuity and the 33-bit wrap,
mid-stream PID or PCR-PID change, and T-STD occupancy through the media-aware exporter's clustered
per-PID delivery — the last observed only as a compliance-tool shape warning and never root-caused
([Architecture](architecture.md) §4.3).

### 3.3 How does the transport behave under loss? — The controller decides it, on every lane; only reordering separates the data planes

**Loss resilience is set by the QUIC congestion controller, not by the protocol.** Under the default
loss-based CUBIC, a head-to-head against SRT over a real EC2→home path collapses under uniform loss
≥ 2 % (53 % delivered at 2 %, 31 % at 5 %, 13 % at 10 %), 25 % reordering (20 %) and a combined WAN
profile (14 %), while SRT holds full rate throughout: loss-based CC misreads random loss as
congestion. Switching to **BBR** removes the collapse entirely — full-rate and byte-complete through
10 % loss, 25 % reordering and the WAN profile, **on par with SRT**
([T8](../lab/test-8-srt-vs-moq.md)).

*This matrix is **one run per condition** on an over-provisioned path (~292 Mbps raw TCP against a
~10 Mbps stream). It measures resilience to non-congestive impairment, not congestion control: a
"100 %" cell means the source fitted in spare capacity. Treat the ordering as the result and the
constants as indicative.*

The change is **sender-local and per-connection**: not on the wire, not negotiated, interop
preserved, and because the fabric is hop-by-hop QUIC it can be enabled on just the lossy
relay→subscriber hop.

**The residual weakness is reordering, not delay variation.** In-order jitter delivers **97 %** at
60 ± 30 ms, while non-ordered jitter of the same magnitude collapses under every controller — 2 %
under CUBIC, 7–13 % under quinn-BBRv1, unstable under BBRv3. That is QUIC in-order-stream
head-of-line blocking, a loss-detection item rather than a CC or protocol flaw. Terrestrial paths
reorder far less than the emulator's model, so unbounded reordering is mainly a LEO or
mobile-handover concern.

**Against segmented HTTP, loss does not separate the two lanes and reordering does.** Measured
head-to-head on one host under one shaper — same clip, same window, both lanes run at both
controllers, each cell confirming its controller by reading it back off the sockets carrying the run
([T8](../lab/test-8-srt-vs-moq.md); the reordering row from
[T5](../lab/test-5-network-impairment.md)):

| Commanded impairment | Segmented, **CUBIC** | Segmented, **BBR** | Media-aware, **CUBIC** | Media-aware, **BBR** |
|---|---|---|---|---|
| 1 % loss | 1.00 | **0.97** | 0.76 | **0.96** |
| 3 % loss | 0.90 | **0.97** | 0.34 | **0.96** |
| 5 % loss | 0.59 | **0.97** | 0.17 | **0.96** |
| 10 % loss | 0.17 | **1.04** | 0.13 | **0.96** |
| 25 % reordering | **0.98** | — | 0.19 | 0.19 |

**Read down a column and the data planes are indistinguishable; read across a row and the controller
decides the result.** A loss-based controller reads a dropped packet as congestion and backs off
whether the bytes are a QUIC stream or an HTTP response, and a delay-based one does not, equally on
both. So the familiar claim that segment fetching degrades under loss where MoQ does not is a
comparison of TCP's default controller against QUIC's tuned one; correcting it removes the loss axis
as a discriminator between the two architectures entirely.

**What survives as a lane property is reordering**, because QUIC's in-order stream delivery converts
it into head-of-line blocking that no controller removes — the media-aware lane reads 0.19 under both
— while segment fetching cannot suffer it, each segment being an independent object with TCP
reassembling beneath it.

**Segmented HTTP did not corrupt what it delivered at any loss level in this ladder, and the ladder has
a boundary** — 0 continuity discontinuities and 0 PCR intervals above 40 ms in every loss cell of the
matrix including the ones delivering a sixth of the stream, **so inside the origin's availability
window its failure mode is lateness rather than damage**, which is the one a bounded downstream buffer
can absorb.
Both halves of that sentence are load-bearing. Pushed past the window — a deeper ladder, to 40 % loss
over 120 s windows rather than 10 % over 40 s — the client falls far enough behind that segments are
deleted before it asks for them and it re-anchors to the live edge, skipping 3, 10 and 34 segments as
the loss deepens. The holes are 7.2 s, 24 s and 82 s of programme, and the measured PCR gaps at those
cells are 7.24 s, 24.57 s and 83.38 s, so the arithmetic closes on the segments that expired. Lateness
converts to loss at the window edge, and where that edge sits is a function of the shortfall and how
long it lasts, not of the loss rate alone — the impairment matrix's own rate-capped cell crosses the
same boundary with no loss applied, at 0.077 of source rate, and posts continuity errors and a 12 s PCR
gap for the same reason.

**Two properties of that failure matter more than the boundary itself.** It is *silent at the serving
node* past about 20 % loss: an HTTP 404 requires the client to ask for a segment that has just been
deleted, and beyond that point it instead reloads the playlist, finds the segment already gone from the
list and skips — the cell that lost 82 s of programme received nothing but 200s. And the continuity
counter *detects but cannot size* it: each re-anchor breaks continuity on every PID carrying it, giving
6–11 events for one splice, and the packet totals beside them understate the hole by three orders of
magnitude because a four-bit counter wraps. Only the PCR interval measures the damage. The media-aware
lane's own PCR intervals above 40 ms are present in the unimpaired baseline too and do not move with
impairment; that is the exporter defect of §3.2, not an impairment effect.

*Measurement point P1, on the ungroomed egress. Loopback with a 15 ms one-way base delay, one clip,
one 40 s window, one replicate per cell. Stated at commanded loss rather than counted: the shaper's
counters disagree with the sockets' own retransmission accounting on the segmented arm (1.2 % counted
against 7.8 % of bytes retransmitted at a commanded 10 %), so they are used here as evidence the
filter matched the flow and not as an applied-loss measurement — a `netem` instance cannot apply a
different policy to two flows given one command. The segmented arm was served by a **single
unoptimised HTTP/1.1 origin, not a CDN edge**, which is the configuration its commercial case assumes.
Treat the ordering and the shape as the finding and the constants as indicative.*

**Two failure modes are opposite, and for reconstruction the MoQ one is better.** Under loss the
media-aware lane sheds *whole groups* and emits a syntactically clean TS — so **continuity-error
count does not reveal loss on this lane**, and the true health metric is delivered bitrate against
source bitrate ([T5](../lab/test-5-network-impairment.md)). SRT's degradation shows as dropped
packets in a damaged stream. Under sustained over-subscription this becomes stark: MoQ delivers
45–81 % with **0 continuity errors** — thinned but reconstructable — where SRT keeps 90 % of the bytes
and delivers **4,279 continuity errors**, an unreconstructable stream
([T8b](../lab/test-8b-congestion-control.md)).

**No controller recommendation for a permanent fixed-rate trunk is supportable from what has been
run.** One under-provisioned condition has been executed, at 2–3 replicates, with delivered fraction
swinging ~20 points: BBRv2 on quiche held ~half CUBIC's queuing delay and full delivery on every
replicate, while quinn-BBRv1 showed a full queue-bloat excursion on one replicate of three, and
BBRv3 both bloated and collapsed to ~12 % on a known library defect. **That is enough to say the
controller ranking under a shaped bottleneck is not the ranking under non-congestive loss, and not
enough to disqualify a controller.** The provisioned-path conditions that would settle it are unrun,
and the experiment says so itself. The operational consequence is the one in
[Architecture](architecture.md) §8.5: pin the controller explicitly, because the resolved default is
backend-specific, and choose it against the route's own conditions rather than against either of
these matrices.

### 3.4 Can redundancy be made hitless? — Yes; on the media-aware lane it takes a reference receiver, on the segmented lane it does not

**Transport-level resilience is essentially free.** Two independent subscribers produce
byte-identical continuous captures of one broadcast, so fan-out to N subscribers → N groomers → N
IRDs needs no extra machinery. The publisher redials its relay with jittered backoff and re-announces
on every session; two-relay clustering carries the feed; and the exporter survives a relay kill and
restart, skipping the evicted group and resuming byte-identical output automatically — a clean
object-boundary gap ([T6](../lab/test-6-relay-resilience.md)).

**Source failover across a relay mesh works, and is bounded by detection rather than recovery.** A
relay advertises, per peer, the best route whose hop chain *excludes* the requester, and a shared
origin identifier lets two publishers declare their feeds interchangeable — explicitly, because the
relay is content-agnostic and will not infer it. The two-relay drill passes end to end, the standby
being advertised the instant its publisher joins. But nothing downstream learns of a hard failure
until the QUIC **idle timeout** expires, so the subscriber resumes one idle timeout later (~30 s at
the default, ~11 s with it set to 10 s). **The precondition is a common source, not byte-identical
segmentation**: a standby that joins mid-stream with offset group numbering still fails over cleanly,
because the subscriber skips to the standby's live edge. What a shared source rules out is a
divergent track layout or codec across the pair.

**Continuity-clean is not hitless, and a graceful exit is not failed over at all.** The resumed
capture carries 0 continuity errors, because the subscriber's output mux never resets; the outage
appears instead as a PCR/PTS discontinuity — break-before-make across a content hole. And when the
active publisher shuts down *cleanly* rather than dying, the relay propagates completion instead of
reselecting and the subscriber terminates. This reads as intended semantics rather than a defect, but
the consequence for broadcast is awkward: failover covers the *harder* failure mode (host loss) and
not the easier, far more common one — a SIGTERM to an encoder, a container rescheduled, a rolling
restart.

**The segmented lane answers the same three questions in the opposite direction, because its serving
node holds no state** ([T6](../lab/test-6-relay-resilience.md), same clip and host, measurement point
P0/P1). There is nothing to re-establish after a serving-node failure and nothing to reselect after a
source failure, and both consequences are measured.

| Question | Media-aware lane | Segmented lane |
|---|---|---|
| Serving node dies and returns | resumes ~4 s after the relay returns, but the outage is a **content hole** — the exporter skips to the live edge | resumes on the first successful poll and **loses no content** — 10.0 s outage, 1.012 of source rate over the window, backlog refetched from the store |
| 1+1 source failover, hard kill | 30–33 s default, ~10 s tuned; hitless unreachable by relay reselect | **no measurable interruption**, 3/3 runs identical, largest stall equal to baseline and not at the kill instant |
| Source exits gracefully | **not failed over** — subscriber terminates | hitless, but `EXT-X-ENDLIST` is visible for **1.10 s** before the survivor rewrites the playlist |
| A misconfigured pair | refused outright (`unroutable`), both torn down | **accepted silently**: ±20 s of repeated and skipped time, or every second delivered twice |
| Two live packagers/groomers of one feed | byte-identical only once keyed to stream position (T12) | **17/17 segments byte-identical**, by default |

Three things in that table carry more weight than the headline. First, the hitless result is
conditional on the pair sharing one source *and* one set of segment filenames: identical content
under different names leaves a URI-keyed client fetching both copies, at 1.389 of source rate. That
is the same conclusion MoQ's specification reaches about object dedup — matching bytes are not
enough, identifiers must match too — arrived at from the other end. Second, **every corrupt cell
reported zero continuity errors**, because a continuity counter and a PCR-interval test both ask only
whether the clock advanced, not which way; the rate ratio and an explicit PCR-rewind count are what
expose it. Third, the segmented lane's determinism is free rather than engineered: `--intra-close`
puts the segment boundary at the next intra-coded picture, so the cut is chosen by content and not by
the packager's emit clock — precisely the property a live pacer had to be redesigned to acquire.

**The serving-node result carries a qualification severe enough to state alongside it.** Neither
TSDuck's HLS input nor FFmpeg's HLS demuxer survives an origin restart at all: both abandon the
stream at the first failed playlist reload, FFmpeg with `-reconnect`, `-seg_max_retry`, `-max_reload`
and `-m3u8_hold_counters` all set. Demonstrating the protocol's behaviour required a purpose-written
retrying client. So this lane's best redundancy property is real in the protocol and absent from the
off-the-shelf TS tooling — a packaging problem rather than a transport one, but a real one.

**Two limits bound the segmented result.** Both packagers wrote to one filesystem, which stands in
for a shared or replicated segment store; the measurement is of the client-visible property *given* a
consistent store, and says nothing about the cost of making one consistent across hosts. And the
standby was always co-started, so a mid-stream joiner — the production shape — is untested. Content-chosen
boundaries predict its segments would align, but that is a prediction.

**On the media-aware lane the load-bearing redundancy therefore belongs at the receiver, and it is
hitless — measured end to end**
([T12](../lab/test-12-dual-path-handoff.md), 42 cells, one run per cell). Two concurrently live
delivery legs carrying one programme, terminated by a reference ST 2022-7 receiver, lose **zero** TS
packets across a total blackout of one leg, 1 % and 3 % path loss, and differential delay to 200 ms.
The graceful-exit gap disappears entirely: a `SIGTERM` to publisher A, which terminates a single-leg
subscriber outright, is invisible at a merged output. Measured skew tracks injected delay to within
60 µs, so the merge buffer a pair demands is simply its path delta.

**How the egress is produced decides whether the pair merges, and only one topology gives both
identity and whole-chain protection.**

| Egress topology | Mergeable? | Protects |
|---|---|---|
| Ungroomed, RTP framing pinned on both legs | **yes** — 100 % alignment in 12/12 cells; but 1,523 of 1,524 PCRs outside ±500 ns, so not a transport an IRD will lock to | the whole chain |
| One *arrival-clocked* groomer per leg | **no** — 30–53 % alignment, never merges | nothing mergeable; input-select still works |
| One groomer, datagrams duplicated to both paths | **yes** — 100 %, hitless under every path injection | **the last hop only** |
| One *stream-clocked* groomer per leg | **yes** — byte-identical on every datagram, single-track, co-started | **the whole chain**, including publisher, relay and exporter death |

**The middle row fails structurally, not through re-stamped PCR** — and that mattered, because the
standing hypothesis was that two groomers would agree on content and differ only in PCR bytes a
receiver could ignore. Of 400 sampled conflicting datagrams, **none** differs only in the PCR field;
39.5 % disagree on PID order and 28.2 % carry a different number of null packets. Each groomer strips
the arriving nulls and chooses its own content/stuffing interleave against its own emit clock, so the
two produce **different transports** rather than the same transport differently stamped. No receiver
can patch that.

**The last row is the fix.** Placing every packet on the absolute output slot its source PCR implies
at the locked mux rate — and deriving the emitted PCR, RTP sequence number and RTP timestamp from
that slot — makes what a leg sends a function of the stream rather than of when its process started.

> **A caveat on P1 that this rig cannot resolve.** On the rig that produced these cells, **1.4–1.6 %
> of PCR intervals exceed 40 ms in every cell including the clean control**. The experiment attributes
> this provisionally to running a 4 Mb/s carrier for a 1.9 Mb/s feed and explicitly declines to make
> any absolute PCR-interval claim from it. **What these runs establish is P2 accuracy and
> mergeability, not P1 repetition.** A matched-rate re-run would settle it.

**The service layer, clock included, is already deterministic across the pair.** Now that the exporter
carries the DVB tables and proxies TDT/TOT, a 1+1 pair has to agree about a table whose bytes advance
while the stream runs — and it does: on the 11-PID DVB feed every PSI/SI PID carries an identical packet
count on both legs, no SI PID appears in the residue, and both legs emit the same advancing sequence of
clock values. That holds with one leg running 866 ms behind its partner, and it holds when the clock is
driven at its one-second resolution limit, where a table selected by arrival rather than by media
position would differ on roughly seven emissions in ten. So the exporter's remaining per-process values
are the media-side ones below, and the clock is not among them.

**A groomer must stop when its content stops, and only the groomer can.** Asked only to hold a rate,
a groomer holds it against a dead source: when a groomed leg's publisher is killed the leg keeps
emitting a byte-perfect CBR carrier — full rate, valid TS, PCRs present and accurate — containing
**no programme packets at all**. Every failure signal a 1+1 receiver keys on is then absent: an
input-select policy performs **zero** switches at every threshold from 50 to 500 ms, and a sequence
merge prefers the dead leg over its live partner. The information the receiver needs was destroyed
upstream of it. With silence detection and mute in place, publisher `SIGKILL`, publisher `SIGTERM`,
relay kill and egress kill each stop the leg with its content and produce exactly **one** switch at
every threshold, costing 1–3 continuity errors.

**Failure detection cannot be faster than a leg's own burstiness.** An ungroomed leg has
inter-datagram gaps to 242 ms, so a 50 ms threshold produces 413–446 spurious switches, while a
groomed leg's gaps stay at 3.8–4.3 ms clean and 8.3–8.4 ms under 3 % loss, making 50 ms safe. The
groomer is therefore what makes prompt failover detection possible, quite apart from its TR 101 290
role.

**A leg can rejoin in phase but not byte-identically, and what is missing comes from the exporter.**
A leg returning from a 15 s blackout resumes with a numbering deficit of **zero**, and a leg brought
up 20 s late sends each shared sequence number a median of 10 ms from its partner. What a pair does
not reach is byte-identity, and the residual divergence is three values the exporter renders from
**process state** rather than from the broadcast:

- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %.
- **SI emission cadence**, anchored to process start, landed tables on slots where the partner
  carried video. A fix has merged and takes a single-track pair to **100 %**.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the
  earliest frame, so legs whose bytes arrive at different moments order the same media differently.
  Ordinary multi-track content therefore stops at **94–96 %** even when co-started.

The counter is no longer a question of feasibility, only of adoption and cost. Restarting each PID's
counter at the video keyframe boundary and padding every span to a multiple of 16 packets takes the
same pair from 0.4 % to **99.9 %** identical on single-track content and from 24.6 % to **93.6 %** on
multi-track, with both legs continuity-clean. The cost is small in aggregate and regressive in
detail: 1.5–1.7 % of packets, but **10–18 kb/s per PID almost regardless of what that PID carries**,
because a PID emitting one or two packets per group is nearly always 14 or 15 short of a multiple of
16.

### 3.5 What does carriage cost on the wire? — MoQ 0.982×, SRT 1.037×, segmented HTTP 1.056×

Measured on a real WAN path (EC2 → home, ~25 ms RTT) with both protocols carrying the same clip over
the same path in the same window ([T9](../lab/test-9-performance.md)):

| Data plane | Wire vs source TS | Basis |
|---|---:|---|
| **MoQ, media-aware, 1200 B** | **0.982×** | measured, real path |
| MoQ, media-aware, 1452 B (MTU discovery on) | 0.973× | measured, real path |
| SRT, byte-verbatim | 1.037× | measured, same path |
| **Segmented HTTP over HTTP/3, 1200 B** | **1.056×** | HTTP layer measured at 1.0006×; per-packet framing **derived** from the row above |
| Segmented HTTP over HTTP/3, 1452 B | 1.046× | derived |
| Segmented HTTP over HTTP/2 on TCP+TLS, 1500 B | 1.029× | derived |
| MoQ, opaque lane | **unmeasured** | derivation puts verbatim near SRT and null-stripped near the media-aware lane |

**MoQ carries the service in 5.3 % less bandwidth than SRT** — 6.2 % with path MTU discovery on, a
one-flag change that is off by default — **and ~7.0 % less than segmented HTTP, MTU-invariant**,
because both ride QUIC and pay identical framing.

**MoQ wins because it declines to carry null stuffing, and that outweighs everything QUIC charges.**
The reference clip is 4.57 % nulls. SRT, a byte pipe, cannot refuse them; the media-aware lane strips
them on import and the downstream groomer regenerates them from stream position, which the
architecture does anyway for TR 101 290 reasons. Against the *delivered* payload MoQ's overhead is
+2.79 %, decomposing exactly into 2.54 points of IP and UDP headers and 0.25 for every QUIC, moq-lite
and container header combined. Priced from the protocol, **the irreducible QUIC-versus-SRT penalty is
~1.2 points, almost all of it the 16-byte authentication tag QUIC mandates and SRT does not** — which
null stripping repays several times over.

**Read the table down rather than across and the pattern is not MoQ-against-HTTP.** Every verbatim
data plane sits between 1.03× and 1.06× whatever its framing, and **the only thing that gets below
1.0× is declining to be verbatim**. SRT is a cheaper verbatim carriage than segmented HTTP over
HTTP/3; the two differ only in framing. So §3.1's fidelity result and this 7 % are one finding read
twice.

**The debits, so the advantage is not overstated.** MoQ's return path is eight times SRT's (1.16 % of
the forward rate against 0.13 %), which does not reverse the result: counting both directions MoQ is
4.3 % cheaper. Datagrams are full — 88.4 % exactly 1200 B — so the short-datagram tail from opening a
stream per audio access unit costs under a fifth of a point. Under 1 % forward loss both protocols
rose by about the loss rate and the ranking held; above 1 % the sender-side cost is inferred from
shaper counters rather than captured.

**The advantage *is* the source's stuffing ratio.** A tightly packed carrier converges the two
towards the 1.2-point floor; a loosely filled one widens it sharply — 1.9 Mbps of content in a 4 Mbps
carrier would cost SRT 4.13 Mbps of IP against roughly half that on the media-aware lane (derived).
**Any cost model quoting these figures must quote the stuffing level with them.**

Two components of the segmented-HTTP figure resisted estimation and had to be measured. **HTTP's own
overhead is negligible**: response headers and playlist re-fetching total 0.06 % of payload at 2.4 s
segments and 0.09 % at 1.26 s, with request bytes back a further 0.01 %, all scaling as 1/segment
duration. Extrapolated to 200–330 ms parts that is ~0.4–0.6 %, so **the chattiness of low-latency HLS
is not a bandwidth argument against it**. And **HTTP/3 is the more expensive substrate by ~2.6
points**, since QUIC's minimum 1200 B datagram charges 5.5 % framing against a 1500 B TCP path's
2.7 %.

### 3.6 What does a relay cost to run? — Cheap and predictable, with one bounded memory cost

Measured on Linux with the current release, MPEG-TS at 2–27 Mbps
([T9](../lab/test-9-performance.md)).

**Relay cost tracks session count, not bitrate.** A subscriber session costs ~0.34 % / 0.87 % / 1.18 %
of a core at 2 / 10 / 27 Mbps, so nearly fourteen times the bitrate costs about three and a half
times the CPU. Cost per Mbps therefore *falls* as bitrate rises, and one core carries roughly a
gigabit — about 110–120 sessions at 10 Mbps. Count sessions rather than gigabits, and note that
contribution-grade high-bitrate feeds are the *cheapest per Mbps* to relay.

**The fan-out limit measured was the host, not the relay.** Per-subscriber egress held between 9.49
and 9.65 Mbps to **N = 55 and 527 Mbps aggregate**, then collapsed at N = 70. CPU attribution shows
why: co-located subscriber processes cost ~2.4× the relay's own CPU, so the 2-vCPU box hit 94 % of
both cores at N = 55. The relay was using under half of one core to deliver 527 Mbps. **N = 55 is the
usable envelope this rig measured; the higher fan-out points measure the box.**

**Host configuration outweighs anything else measured** — the same relay version cost ~6× more CPU
per Mbps on macOS loopback with UDP GSO disabled than on Linux with it enabled.

**Publisher and subscriber roles are stable over a day and a half.** Across two 26.5-hour soaks both
held memory flat (+0.03 and +0.15 MB/hour, against run-to-run noise several times larger), with
descriptors unchanged and no restarts.

**The relay retains memory in proportion to content carried, and the cause is a QUIC library rather
than MoQ.** `quinn-proto` keeps a slot per stream a peer may open and recycles a freed stream's
reassembly buffer rather than releasing it; MoQ opens a stream per group, so **every group the relay
ingests permanently converts one empty slot into an occupied one — about 9 KiB**. Three measured
properties follow from that and from nothing about MoQ:

- **Flat in subscriber count** (28.7, 27.9, 28.0, 28.1 MB/hour from one to eight subscribers) — only
  streams the *peer* opens take slots, so fan-out is free and it is hours of programming carried, not
  audience, that drives the cost.
- **Proportional to group rate**, confirmed by prediction: doubling the group rate at identical
  bitrate doubled it to within 0.3 %. A deployment tuned for low latency reaches the ceiling sooner
  rather than settling higher.
- **No cache setting binds it.** Capping the group cache at 32 MiB left the relay running to more
  than twice that cap above baseline at an unchanged slope, and an age ceiling did the same, because
  the memory is not the relay's to evict.

**It plateaus, and the ceiling is the number to budget.** Growth stops once every slot is occupied,
which at 10,000 streams per connection is **~100 MB above baseline per publisher connection**,
reached after ~10,000 groups — around three hours at the rate tested. **Any run shorter than that
reads as unbounded growth**, which is why an hourly slope extrapolated to a daily figure overstates
the cost; an earlier reading of this file made exactly that error. A dedicated run confirmed the knee
within 11 % of the predicted ceiling and bracketed the per-slot cost at 9.1–10.5 KiB against the
9.9 KiB derived upstream by instrumenting the library.

So a relay is **sizeable rather than fragile**: budget the ceiling per publisher connection and treat
scheduled restarts as prudence rather than necessity. Two operational qualifications: the plateau is
**soft**, still creeping at ~8 MB/hour past the knee, so alarm thresholds belong above the ceiling
rather than at it; and the one lever that works is **sub-proportional** — cutting slots by 9.8×
reduced retained memory by only 3.3×, because 20–30 MB of the ceiling is slot-independent. A separate
and far more severe defect is genuinely gone: an older release grew ~21 MB/hour *with no subscribers
at all* to an out-of-memory kill after six days, and no current build reproduces that.

*Two caveats apply throughout: these are loopback rigs with subscribers co-resident with the relay,
so they price neither the NIC nor congestion control doing real work; and `moq import` costs about
three times more CPU on a trickle-fed live source than on a file-paced one, which is the normal live
contribution topology. Treat the shapes as the result and the constants as indicative.*

### 3.7 Does it interoperate? — Within one implementation, and through none of eight others

Every other result in this repository was measured against `moq-dev` peers. That makes "a relay is a
neutral transport fabric" — load-bearing in [Architecture](architecture.md) and the basis for
treating relay capacity as a substitutable commodity in [Economics](economics.md) — an assumption
normally granted without test.

Testing it needs a media-level check rather than a handshake, so the fixture is a 20-second transport
stream and the oracle is its own continuity counters and PSI/SI: **a TS validates itself, with no
decoder, player or frame capture** ([T11](../lab/test-11-interop.md); the client is public in
[`interop/`](../interop/README.md), and its sensitivity to loss, duplication and reordering is
demonstrated before it is trusted).

**The lane passes against `moq-dev`'s relay locally and over the public internet, with byte-identical
egress in both cases, and returns no media whatsoever through all eight other registered public
relays** — Meta, Google, Cisco, Nokia, Meetecho, Cloudflare, OzU and openmoq.

**Draft-version incompatibility, the expected culprit, is not the cause.** Negotiation succeeds
widely, reaching `moq-transport-19` against two relays — above the ceiling the client's own help text
advertises. The blocking cause is a convention above the version: **`moq-dev`'s publisher withholds
its namespace announcement until a peer explicitly asks for it, and only `moq-dev`'s own relay asks.**
Every other relay expects a publisher to announce on connect, so the publisher negotiates, reports no
error, and then sends no control message at all. Two controls rule out the alternatives: with no
subscriber connected, `moq-dev`'s relay still asks and its publisher still announces, so it is not
downstream demand propagating; and instrumenting both ends confirms the silence is real rather than a
logging artefact.

**Both behaviours are permitted by the draft** — announcing unprompted is a MAY — so this is
underspecification surfacing as an interop hazard rather than a defect in anyone's code, and it is
reported upstream on that basis. Forcing the same media test over an IETF draft against a local relay
passes cleanly, which confirms the transport itself carries broadcast MPEG-TS correctly.

**The eight failures resolve into at least four distinct causes**, so fixing the announce convention
alone would not clear them: five relays establish a session and are blocked by the announce
convention; a second hazard of the same kind sits behind it, since the subscriber opens discovery on
an *empty* namespace prefix which one relay rejects outright and about which the draft is internally
inconsistent; one relay refuses SETUP; and two never establish a connection at all. **The last three
are undiagnosed.**

**For the thesis this cuts two ways.** Nothing here indicts the architecture — the substrate works,
and the blocking behaviour is a client-side default that is straightforward to change. But
**multi-vendor relay portability is currently absent in practice**, and that property is what makes
an Internet-native trunk route substitutable between providers, which is what the economic argument
assumes. Until a broadcast feed demonstrably traverses a relay someone else operates, relay
neutrality is an aspiration of the protocol rather than a property of the ecosystem.

**A secondary result matters for how such claims get tested at all.** The community interop matrix is
control-plane only, so a `setup-only` check reports success against relays through which not one
media byte flows — **an entire class of failure is invisible to the test the ecosystem reads**. That
is the argument for a media-level interop profile, which this project has contributed rather than
merely proposed. One incidental finding from the same runs is a confound worth naming: the client
abandons QUIC for a WebSocket fallback on a fixed 200 ms timer, so any relay much further away than
that is silently carried over TCP, head-of-line blocking included.

### 3.8 How do the data planes compare on delivery cadence? — Three structurally different classes

All figures from the same clip through the same instrument, at a 1 ms burst-grouping threshold
([T14](../lab/test-14-data-plane-comparison.md), [T15](../lab/test-15-point-to-point-cadence.md)).

| Class | Egress granularity is set by | Median burst | Largest gap | 10 ms peak/mean |
|---|---|---|---|---|
| **MoQ** | the object model — *re-paces*, finer than its input | 12.2–12.4 kB, whatever the source | 149 ms | 24× |
| **RIST / SRT** | the source — *transparent* | 30.6 kB here, tracking the publisher exactly | ~35 ms | 3.4× |
| **Segmented HTTP** | segment duration — *aggregates* | 2.95 MB at 2 s segments | 4.01 s | 231× |
| libRIST with opt-in `cbr-output` | the receiver's own pacing | 1.3 kB | ~35 ms | 3.28× |

**Segmented HTTP's egress is ~240× coarser by median burst and stops entirely for seconds where MoQ
never stops for more than 149 ms.** The mechanism is unambiguous: silences arrive at exactly the
segment duration, with occasional stalls of two segment periods, because the client fetches a
completed segment at line rate and then waits for the next to exist. MoQ delivers something in every
second of the window; segmented HTTP alternates between nothing and 20–30 Mb/s.

**RIST and SRT are indistinguishable from no transport at all.** Against a plain-UDP control through
the same chain, median and p95 burst match to three significant figures, for RIST Main, RIST Simple
and SRT, at two different source granularities. They neither coarsen their input nor refine it —
though they do smooth *within* the burst, halving the 10 ms peak-to-mean against the raw control,
because a jitter buffer drains a group over a longer sub-interval than the kernel does.

**MoQ, by contrast, sets its own granularity.** Fed a source four times finer, its egress does not
move: 12.2 kB median against 12.4 kB, and a 149 ms worst case either way. That is the structural
difference, and it falsified the prediction that grooming burden would rank inversely to scalability
— the most scalable candidate is also the finest-grained, and the incumbent tunnels sit in the
middle.

**The two hand-off rankings disagree, and which one matters depends on the groomer.** MoQ delivers
the smallest bursts; RIST and SRT the shortest silences, by a factor of four. A groomer's buffer is
sized by burst, but its start gate and underrun threshold are sized by the longest silence, so a
claim that one transport "hands over more cleanly" has to say which it means.

**Transparency moves the question to the source.** Because a tunnel's egress is its ingress, the
30.6 kB above is a fact about this campaign's software pacer, not about RIST — a true CBR hardware
feed would come through smoother. It also means a tunnel cannot improve a bursty publisher.

*Two measurement caveats. Loopback inflates burst rate, so peak-rate figures are an upper bound;
burst size and inter-burst silence are structural. And MoQ's median is threshold-sensitive where the
tunnels' is not — swept from 0.2 ms to 5 ms it runs 7.1–25.8 kB while every point-to-point leg stays
at 30.6 kB — so the single 12.4 kB figure is a 1 ms-threshold figure. The ordering is unaffected
below a 2 ms threshold.*

### 3.9 Can low-latency HLS carry MPEG-TS in practice? — It can be published free, and nothing free receives it

The HLS specification permits partial segments in MPEG-TS, and the low-latency ecosystem standardised
on CMAF/fMP4 regardless. Measured rather than read off documentation, the gap sits **entirely on one
side of the pipeline** ([T14](../lab/test-14-data-plane-comparison.md)).

**Publishing works, free, first time.** Apple's `mediastreamsegmenter --format=transport
--part-target-duration-ms=300` emits a conformant playlist with `EXT-X-PART` entries pointing at
MPEG-TS parts of 0.28–0.30 s and 240–430 kB, `INDEPENDENT=YES` where a part carries an IDR, and a
preload hint for the part still being written. The tools are closed-source and macOS-only, but they
are free and it took one command.

**Nothing free receives it.** Both freely available clients that can turn HLS back into a transport
stream fetched **zero** parts from an origin advertising them, and fell back to whole segments.
Repeated against two origins — a static one, and Apple's own low-latency origin example advertising
`CAN-BLOCK-RELOAD=YES` and `PART-HOLD-BACK=0.900` and validating with zero MUST-fix issues — with the
same outcome, and **zero blocking playlist reloads** from either client, so neither even attempted
the low-latency handshake.

**The control that makes this a statement about clients rather than about the rig** is Apple's own
`mediastreamvalidator`, which over the same origins fetched 21 parts against 5 segments, and 17
against 7 using 12 blocking reloads. The parts are real, conformant and actively advertised. TSDuck's
limitation is proven outright: pointed at a live edge where the playlist legitimately holds only
parts, it exits with `empty HLS media playlist` — it cannot see parts at all. FFmpeg's HLS demuxer
exposes no partial-segment options.

**So low-latency HLS with MPEG-TS does not reduce the grooming burden in practice**: the median burst
falls only from 2.95 MB to ~2.3 MB, and that ~20 % is explained by segment duration rather than by
parts. Against MoQ the gap closes from ~240× to ~185×, which is noise on a two-order-of-magnitude
difference.

**The practical envelope for TS-in-HLS therefore remains nearer 6 s than the 2–5 s the hold-back
arithmetic implies — and the reason is a market rather than an immaturity.** The missing stage is the
receive stage, which is exactly what the commercial ABR-to-TS products sell. An operator unwilling to
buy a receiver gets classic HLS whatever the publisher emits.

This is worth holding beside §3.7. **HLS has no normative reference implementation at all** — it is
an Apple-authored informational document — and its authoritative implementation is closed-source,
yet it interoperates everywhere. MoQ is standards-track with open implementations and no
cross-implementation media interop. **Open source and interoperability are not the same axis, and
here they point in opposite directions.**

### 3.10 Is there a credible entitlement substrate? — Architecturally yes; nothing beyond that is built

MoQ's authorization hook at subscription time, with its relay and caching semantics, is a credible
*substrate* for dynamic, revocable, multi-tenant entitlement. **This is an architectural reading of
the protocol rather than a measurement**, and it carries two boundaries: the credential profile
enforced there — path-scoped JWTs, mTLS peer identity, expiry — is a deployment choice, not a wire
primitive the protocol guarantees across implementations; and the multi-region cluster mesh is
distributed-systems work the platform must build.

**Nothing in [Control](control-plane.md) beyond the existence of the hook has been built or
measured.** That document says so at its head, and it is the largest untested assumption in the
thesis.

### 3.11 How long does a picture take to cross each data plane? — MoQ by 15×, and its conformance gap is not the price

Measured source-to-groomed-egress on the presentation timestamp each picture carries, so one instrument
grades a byte-transparent tunnel and a remultiplexer alike; **every figure is paired with the conformance
of the same bytes**, because a latency quoted without a conformance level ranks a non-conformant arm
against a conformant one and calls the difference transport
([T18](../lab/test-18-delivery-latency.md), P2).

At each plane's shallowest runnable groomer cushion, on loopback and then from an EC2 origin over the
public internet at a 12.8 ms round trip:

| Plane | Cushion | Loopback | WAN | PCR intervals > 40 ms (WAN) | Max interval |
|---|---|---|---|---|---|
| **MoQ, media-aware** | 250 ms | **127 ms** | **109 ms** | 504 / 3,310 | 201 ms |
| RIST | 250 ms | 1,610 ms | 1,348 ms *(unsettled)* | 15 / 3,638 | 49.0 ms |
| SRT | 250 ms | 1,606 ms | 1,618 ms | 18 / 3,627 | 49.5 ms |
| Segmented HTTP | 2 s | 3,497 ms | 4,067 ms | 13 / 3,486 | 131 ms |

PCR jitter above 481 ns was zero on all nineteen loopback cells. **Continuity was not, and the column
that originally said so was an instrument defect** — the matcher searched for a word the TSDuck
continuity plugin never prints, so it returned zero on every input the campaign ever gave it. Re-graded
from the same captured bytes: the MoQ arms are genuinely 0 at every cushion, and the **segmented arm
posts 583 continuity events at a 2,000 ms cushion, 78 at 4,000 ms and 64 at 8,000 ms** — the groomer
starving between segment arrivals, the same mechanism measured directly at 311 events on a 1 s cushion
against 2 s segments. The UDP, SRT and RIST arms sit at a common ~90-event floor that is not yet
attributed: RIST logs a receiver FIFO overflow that accounts for its own, SRT does not, and until a
source-side capture is graded beside the egress those three figures bound a rig artefact together with
a transport result and should not be read as either. The defect and its scope are recorded in
[T18](../lab/test-18-delivery-latency.md) and [T5](../lab/test-5-network-impairment.md).

**MoQ delivers a picture across the internet in 109 ms**, 15× lower than SRT and 37× lower than segmented
HTTP over the same path in the same window. On loopback, where the ladder also carried a plain-UDP control
with no transport buffer at all, MoQ came in **4.7× lower than that control** — a media-aware lane beat
raw datagrams, because what the control still pays and MoQ does not is groomer depth. This is the first
latency measurement in the campaign, and it is the figure the paper's structural argument previously stood
in for.

**Latency and PCR conformance are independent on the media-aware lane** — the result in §3.2. MoQ's
repetition failure is identical at every cushion, identical when starvation is removed, and identical over
the WAN (504 against loopback's 489). It is a carriage defect upstream of the groomer, not the price of
the lane's speed.

**On a healthy path a point-to-point tunnel costs exactly its configured jitter buffer.** SRT and RIST
both sit 1,000 ms above the UDP control at every rung of the loopback ladder and agree with *each other*
to within 6 ms — the latency form of §3.8's transparency finding. Their delay is a dial the operator sets,
not a property of the protocol.

**The path term is the round trip and nothing more.** SRT adds 5–12 ms over a 12.8 ms RTT; MoQ comes out
16–18 ms *lower* than loopback, because the loopback rig had source, transport and groomer contending for
one host. No plane's conformance moved. The loopback ladder and the WAN figures therefore agree, and the
ordering is a property of the data planes rather than of either environment.

**Segmented HTTP degrades on a real path, but only at the shallow end.** At a 2 s cushion its worst case
reaches 6,430 ms, its maximum PCR interval nearly triples to 131 ms, and in the first run of that cell
*every* PCR failed the 481 ns accuracy gate. At 8 s it is orderly again — 2 intervals above 40 ms, a
49.8 ms maximum — at 9,286 ms of latency. Segment-fetch jitter over a real path is what the deep cushion
absorbs, which is the conclusion §3.2 reached by a different route.

*Three caveats carried from source. A commanded cushion is **not** the depth in force whenever the carrier
rate exceeds the arriving content rate: the MoQ lane reads 87 ms or 824 ms at the same commanded 1,000 ms
depending only on carrier rate, so the cushions in the table are what was asked for and the latencies are
what was delivered. RIST's WAN cells had a **rising** trend where every other arm's falls, so their
apparent 262–333 ms advantage over SRT is an unsettled window rather than a finding. And no arm reached
zero intervals above 40 ms on the WAN: the byte-transparent arms sit at a floor of 12–21 marginal
violations (45–60 ms) tracking their small rate surplus, so this rig grades relative conformance reliably
and absolute conformance only to within those few intervals.*

---

## 4. The limits of the evidence

Stated in one place, because the individual caveats above understate their sum.

**No hardware.** Nothing in this repository has been fed to a hardware IRD or graded by a hardware
TR 101 290 analyser. Every conformance figure is either file arithmetic, a socket capture on a
general-purpose OS, or a reference software receiver — and where the file and the socket disagree, as
they do on P1 PCR repetition (§3.2), the socket is the closer of the two to what an IRD sees and
still is not it. The make-or-break gate is not merely open — it has never been attempted.

**Delivery latency, not glass to glass.** The latency figures are source-to-groomed-egress, measured on
the presentation timestamp each picture carries. A camera-to-display total adds encoder and decoder
latency; neither is measured here and neither differs between the data planes, so the comparison holds
while the absolute total does not. Both paths tested were also *healthy* — loopback has no RTT at all and
the WAN leg was a 12.8 ms round trip — so nothing exercised the retransmission and jitter-buffer recovery
the point-to-point tunnels exist for, which is the case that should favour them. A long path (80–150 ms)
or a lossy one could change the ordering rather than confirm it.

**The opaque lane has one measurement.** Loopback, file-fed, one run, on a pinned obsolete draft,
against a private implementation. It has never been deployed over a real path, never measured for
wire cost, never measured for cadence, and never re-run against a current build. It is a demonstrated
principle rather than a validated component.

**Single-route, single-clip, single-host, wherever the data plane comparison is concerned.** The
segmented-HTTP arm is one route, one clip, one run per leg, loopback, **no packet loss** — nothing
was ever missing, only late — burst granularity and fidelity at one segment duration, wire cost at
three, and its per-packet framing derived rather than measured.

**The 1+1 result is a software receiver on one host.** Two concurrently live legs into a reference
implementation of the ST 2022-7 selection rules, not a hardware IRD's merge engine. Both legs share a
host and therefore a clock, so skew is injected rather than natural and path diversity is untested.
Byte-identity is measured on a **single-track** source; multi-track content holds at 94–96 %. One run
per cell.

**Impairment matrices are one run per condition**, on an over-provisioned path, with `netem` models
that approximate loss as Bernoulli where real loss is bursty and RTT-coupled, and whose "jitter"
reorders. The congestion-control experiment proper has one of six conditions run.

**Resource figures are loopback rigs** with subscribers co-resident with the relay, on a 2-vCPU
instance, so they price neither the NIC nor congestion control doing real work.

**Some results rest on upstream code that is not on the release line.** Two of the three
exporter-determinism fixes are still unmerged; the SI carriage results — EIT, and the clock — are merged
onto a development branch that has not converged with `main`, so the behaviour is settled while the
version carrying it is not. One fix in this campaign merged in a materially different form after review
and changed its own result, which is the argument for labelling both cases rather than neither.

**No production relay cluster, and no federated mesh.** The resilience work is a two-relay lab.

**Reproducibility is partial.** The media-aware lane is fully reproducible today with public binaries
plus TSDuck, and its downstream groom with the public `mpegts-pacer` crate. The opaque
publisher/subscriber and the IRD-facing egress beyond grooming are private, so reproducing an
IRD-grade opaque egress independently requires equivalent code.

**Large artefacts are not committed.** Captures, pcaps and analyser exports are the evidence of
record but are kept out of the repository; the notebook records their identity and the method that
regenerates them.

---

## 5. Open questions, ranked

Ranked by how much a result would change the conclusions this repository draws.

**The first two are ordered by sequence rather than by leverage, and the order is deliberate.** The
hardware verdict is worth more, but taking the media-aware lane to an IRD *today* would test a stream
already measured to fail P1 PCR repetition on the wire at every cushion — the result is known and the
kit would be spent confirming it. The exporter fix is the precondition, not the lesser question.

| # | Question | Blocked on | What it moves |
|---|---|---|---|
| 1 | **Would a denser exporter PCR cadence clear the P1 repetition gate on the MoQ lane?** (§3.2) | An upstream change to the exporter's PCR emission interval, now reported ([upstream contributions](../lab/upstream-contributions.md) §1); the rig then re-runs unaltered | The lane's last conformance failure, and the precondition for row 2 being worth running on the media-aware lane at all. [T18](../lab/test-18-delivery-latency.md) established the failure is *not* a latency trade-off — the groomer places no PCRs of its own and the lane sends too few — so this is the cheapest remaining path to a plane that is both conformant and sub-second. **Cheapest high-leverage measurement outstanding once upstream moves** |
| 2 | **Does groomed output pass TR 101 290 P1/P2 on real hardware IRDs, sustained, including ST 2022-7 under loss?** | A hardware IRD and analyser | Everything. Until it passes, the grooming design is structurally sound and file-validated, not broadcast-acceptable. Note that the segmented lane is ready for this test now and the media-aware lane is not, so the two arms need not wait on each other |
| 3 | **Does the latency ordering survive a lossy or long path?** | Impairment on the WAN legs, and a path with 80–150 ms of RTT | Both paths measured were healthy, so nothing exercised the recovery the point-to-point tunnels exist for — the case that should favour them. This is the arm that could change the ordering rather than confirm it |
| 4 | **Does a commercial ABR-to-TS gateway produce P1/P2-conformant output as the distributor's own edge stage?** | MEG- or TITAN-class hardware | Whether part of the broadcast-grade layer is purchasable on one data plane and not the other; also the only route to a low-latency TS-in-HLS receiver |
| 5 | **Can a CDN carry a multi-programme TS segment in practice?** | A CDN account and the MPTS fixture | The whole of MoQ's remaining carriage-fidelity advantage |
| 6 | **Do the groomer's correctness boundaries hold** — source-clock drift, PCR discontinuity and wrap, mid-stream PID change, T-STD occupancy? | The hardware rig in row 2 | Whether steady-state conformance generalises |
| 7 | **Does the 1+1 result survive two hosts, two clocks and multi-track content?** | A second instance in another availability zone | [Architecture](architecture.md) §5.1's recommendation is currently scoped to one host and single-track content |
| 8 | **Which congestion controller suits a permanent fixed-rate trunk?** | Running T8b's C2–C6 | An operational recommendation that currently cannot be made |
| 9 | **What does the opaque lane cost on the wire, and does it survive a real path?** | Building the private lane in the measurement environment | Whether byte-verbatim carriage is a wash or a real cost against SRT |
| 10 | **How much of MoQ's carriage advantage survives a different source?** | Two more source profiles | The largest caveat on the deciding line of the cost model |
| 11 | **Does fixing the announce convention clear the pairings it blocks, and what are the three undiagnosed failures?** (§3.7) | Upstream adoption, and diagnosis | Relay portability, which underwrites the economic argument |
| 12 | **Does a real CDN edge change the segmented lane's loss curve?** (§3.3) | A tuned edge instead of one plain HTTP/1.1 origin | The completeness half is now answered: retry preserves *content* while the client stays inside the availability window, and not past it. A ladder to 40 % loss over 120 s windows crosses that edge between 7.7 % and 12.2 % applied loss, after which the client re-anchors and leaves 7–82 s content holes — and past ~20 % loss the origin logs no error while it happens. Rate was never preserved (0.17 of source at 8 % loss). What remains is the origin: the one measured is the weakest form of the deployed one, and a CDN could plausibly move the loss curve — it cannot move the reordering result, which is TCP's |
| 12a | **Why does the media-aware lane cluster PCRs sub-millisecond?** (§3.2) | Reading the exporter against the measured distribution | If PSI density and PCR spacing are both group-derived, one parameter moves both, and row 2's cadence change is a group-size change. T18 raised this row's value: PCR *emission* is now the lane's one remaining conformance defect, so how the exporter decides to emit is the question |
| 12b | **Does RIST actually beat SRT on a real path?** | One long WAN run | On loopback the two are indistinguishable within 6 ms; over the WAN RIST reads 262–333 ms lower but its cells had a rising trend and had not settled, so the gap is not yet a finding. The one place a real path may separate two protocols this campaign cannot otherwise tell apart |
| 13 | **Does the relay's memory plateau hold over weeks rather than hours?** (§3.6) | A longer soak | A sizing line rather than a restart cycle |
| 13a | **What does the segmented lane cost to run?** (§3.6) | An nginx origin rather than a single-threaded reference server, and a soak | The cost comparison is currently one lane characterised for resources and one characterised only for bytes. Segmented carriage overhead is measured (1.036× source TS); its per-role CPU and memory, its fan-out knee and its stability over days are not. The origin is the role the whole commercial argument for this lane rests on, and the one measured is `python3 -m http.server` |
| 14 | **Should a recovered audio gap be signalled downstream, and should the continuity guard be the only check?** (§3.1) | Upstream design | Whether the ingest edge's absorption is observable |

Protocols for the runnable ones are in [planned-experiments](../lab/planned-experiments.md).
