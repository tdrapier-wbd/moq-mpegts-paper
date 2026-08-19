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
| CBR and PCR cadence | restored downstream by `mpegts-pacer` | preserved end to end by the prototype's own pacer |
| Public-internet operation | yes | **no** |
| Congestion controller | BBR (explicit) | quinn default (CUBIC) |

### 1.1 Instruments, and what each cannot show

| Instrument | Used for | What it cannot show |
|---|---|---|
| TSDuck `analyze`, `continuity`, `pcrextract`, `pcrverify` | Structure, PID census, continuity, PCR interval and accuracy | Wire timing. `pcrverify` on a file checks PCR against byte position, i.e. the arithmetic of the re-stamp |
| `t13-cadence.py` (64 kB pipe reads, or per-datagram capture) | Burst size, gap distribution, coefficient of variation | Absolute rate on loopback — loopback inflates burst *rate*; burst *size* and inter-burst silence are structural |
| `t12-merge-oracle.py` + `t12-maskcmp.py` + `t12-seqskew.py` | ST 2022-7 merge behaviour, byte identity, skew | A hardware IRD's merge engine. It is a reference implementation of the selection rules. The oracle also degrades to noise on a pair that is not byte-identical, which is why the mask and skew tools exist |
| `compliance.py` / `t13-grade.py` | Structural and shape checks, packet conservation | Decoder acceptance |
| Interop client (`interop/`) | Media-level carriage through a third-party relay | Anything about pacing or conformance — deliberately out of scope for a relay test |
| `tc`/`netem` | Loss, delay, reordering, shaped bottleneck | Real congestion. `netem` loss is Bernoulli where real loss is bursty and RTT-coupled, and `netem` "jitter" reorders |
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
| **Carriage** | Media-aware and opaque lanes carry a full broadcast mux with 0 continuity errors; segmented HTTP is byte-verbatim for one programme | Multi-programme carriage through a real CDN; the opaque lane anywhere but loopback |
| **Timing** | Grooming restores exact CBR and P2-limit PCR accuracy **on file**; a segmented-HTTP egress reaches the same standard on the **wire** with an 8 s cushion | **P1 PCR repetition on the wire on the MoQ lane at its current depth (measured failing)**; anything at all on hardware |
| **Loss** | CUBIC collapses, BBR restores parity with SRT; reordering is the residual | Congestion control on a provisioned path; a controller recommendation for a permanent trunk |
| **Redundancy** | Two stream-clocked groomers are byte-identical and hitless through every upstream failure, single-track, one host | Two hosts, two clocks; multi-track identity; a hardware merge |
| **Cost** | Wire multipliers on a real path; relay CPU and memory envelope | The opaque lane's wire cost; a second source profile |
| **Interop** | Media flows within one implementation and through none of eight others | Why three of the eight fail |
| **Latency** | — | **Nothing. No glass-to-glass measurement exists on either data plane** |

---

## 3. Results by question

### 3.1 Does the transport carry a broadcast mux intact? — Yes, on both lanes, with one named residual

**End to end over the public internet.** Live MPEG-TS traverses the whole chain — SRT contribution
into an AWS EC2 host, import → relay → a local export — with **0 continuity errors**
([T4](../lab/test-4-remote-e2e-srt.md)), and the full ~9.93 Mbps contribution mux comes home over
QUIC at **9.48 Mbps sustained for four minutes, 0 CC** ([T8](../lab/test-8-srt-vs-moq.md)). A
third-party relay in Mexico, reached from an EC2 publisher in Ireland by a subscriber in London,
carried 300 s at 9.47 Mbps with 0 CC, 0 reconnects and all 8 elementary streams reconstituted.

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

**Segmented HTTP is byte-verbatim for a single programme**, which is the opposite of what the
specification's wording suggests. A published segment aligned against the source and compared packet
by packet differs, in a 1,200-packet window, in **two packets, both PSI, each in byte 3 alone** — the
continuity counter on the PAT and PMT the segmenter injects at each segment head, whose renumbering
is forced. Every media, audio, teletext, splice and stuffing packet is byte-identical, and continuity
is error-free across segment boundaries ([T14](../lab/test-14-data-plane-comparison.md)). The DVB
service layer travels too — not because the specification provides for it, which it does not, but
because nothing in the path parses the payload.

### 3.2 What does delivery do to the clock, and can it be repaired? — Partly, and the wire is not the file

**This is the load-bearing result in the repository and the one most often quoted without its
domain.**

**The problem.** Bursty delivery leaves a reconstructed transport stream with PCR *intervals* that no
longer track a constant mux rate: the bytes, PCR values included, are intact; the delivery *cadence*
is not. Soft players tolerate this; hardware IRDs lock a PLL to PCR and raise TR 101 290 P1/P2 alarms
in response. *(The IRD reaction is accepted broadcast practice, not something this campaign observed
— no hardware has been fed by this chain.)*

**Ungroomed, at P1** ([T2](../lab/test-2-media-aware-transparency.md),
[T7](../lab/test-7-timing-integrity.md)): **0–26 % of PCR intervals exceed the 40 ms limit, depending
on the source.** Per clip: 25.2 % on a synthetic 10 Mbps CBR reference, 13.9 % and 9.1 % on two real
CNN contribution captures, and **0 % on a 27.5 Mbps broadcast mux whose native 27 ms PCR cadence is
already inside the limit**. The opaque prototype fed the raw stream holds 0 % on every clip
([T3](../lab/test-3-opaque-transparency.md)), which isolates cadence loss to the re-mux rather than
to QUIC.

**Groomed, at P1 (file), MoQ lane** ([T7](../lab/test-7-timing-integrity.md), four clips): **0 % of
intervals above 40 ms**, exact CBR (bitrate = pcrbitrate = userbitrate), **0 `pcrverify` violations
at ±500 ns**, 0 continuity errors, 0 content packets dropped. Tightening to absolute PCR units on a
different rig gives **0 of 2,598 PCRs outside ±500 ns on a groomed output, against 1,523 of 1,524 for
the same feed delivered ungroomed** ([T12](../lab/test-12-dual-path-handoff.md)).

**Groomed, on the wire, MoQ lane** ([T13](../lab/test-13-downstream-grooming.md)): **131 PCR
intervals above 40 ms in 25 s on one host and 159 on another, with a 227.4 ms maximum.** T13's own
scoring records this as *"pass on file (0); **fail live**"* and instructs that criterion 3 be read on
the live column when the question is what an IRD receives.

**Groomed, on the wire, segmented-HTTP lane, 8 s derived cushion**
([T16](../lab/test-16-grooming-segmented-http.md)): **0** intervals above 40 ms, **0** PCR violations
at 481 ns over 2,496 PCRs (and 0 at 18 µs, a gate tighter than any other quoted in this campaign),
**0** continuity errors, `pcrbitrate` exactly the commanded rate, 10 ms coefficient of variation
0.068 against the ungroomed egress's 12.381, largest silence 17.2 ms against 4,011.9 ms — with
**nothing dropped and nothing muted**, and no flag set beyond the output rate.

**So the mechanism is buffer depth, not live operation.** T13 read its 131 live intervals as a
property of re-timing a stream as it arrives, against 0 when reading a file. The segmented arm posts
0 *on the wire* while holding 8 s of cushion, so what constrains PCR placement is **whether the stage
always has a packet ready at the deadline**, which is what depth buys. A stage that mints its own PCR
schedule places PCRs freely and posts none in either domain; a pass-through stage inherits the
exporter's spacing, and the MoQ egress arrives with 55 intervals already above 40 ms and a 319.9 ms
maximum.

> **The open question this creates is the most consequential in the repository.** Grooming buys PCR
> repetition with latency. The two measured points are on different data planes — shallow cushion on
> MoQ giving 131–159, 8 s cushion on segmented HTTP giving 0 — and **the curve between them has never
> been measured on the MoQ lane**. If MoQ needs seconds of cushion to reach P1 on the wire, the
> grooming stage spends the only advantage MoQ has ([Comparison](comparison.md) §5.1). The protocol
> for closing it is in [planned-experiments](../lab/planned-experiments.md); it uses the existing rig,
> instrument and grading script, and it is the cheapest high-leverage measurement outstanding.

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

**Nothing off the shelf does the whole job, and the missing half is carriage.** Every candidate an
engineer would reach for, graded against four criteria fixed in advance
([T13](../lab/test-13-downstream-grooming.md)):

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

**The two halves of grooming therefore separate cleanly, and only one is unsolved off the shelf:**
tools that regenerate a mux can time it perfectly and cannot carry it, and tools that carry it cannot
inflate it. The requirement is documentable with standard tools wherever signalling is not
contractual; a mux carrying full signalling to a hardware receiver still needs a purpose-built stage.

**What has not been exercised at all**: source-clock drift, PCR discontinuity and the 33-bit wrap,
mid-stream PID or PCR-PID change, and T-STD occupancy through the media-aware exporter's clustered
per-PID delivery — the last observed only as a compliance-tool shape warning and never root-caused
([Architecture](architecture.md) §4.3).

### 3.3 How does the transport behave under loss? — Parity with SRT, once the controller is chosen

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

### 3.4 Can redundancy be made hitless? — Yes at a reference receiver, within a stated scope

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

**So the load-bearing redundancy belongs at the receiver, and it is hitless — measured end to end**
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

---

## 4. The limits of the evidence

Stated in one place, because the individual caveats above understate their sum.

**No hardware.** Nothing in this repository has been fed to a hardware IRD or graded by a hardware
TR 101 290 analyser. Every conformance figure is P1 (file) or against a reference software receiver.
The make-or-break gate is not merely open — it has never been attempted.

**No latency measurement.** There is no glass-to-glass latency figure for either data plane, at any
conformance level, anywhere in this campaign. The sub-second capability attributed to MoQ is a
structural property of the protocol plus an inference from measured delivery granularity.

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

| # | Question | Blocked on | What it moves |
|---|---|---|---|
| 1 | **Does groomed output pass TR 101 290 P1/P2 on real hardware IRDs, sustained, including ST 2022-7 under loss?** | A hardware IRD and analyser | Everything. Until it passes, the grooming design is structurally sound and file-validated, not broadcast-acceptable |
| 2 | **Does a MoQ chain stay sub-second while reaching P1 PCR repetition on the wire?** (§3.2) | Nothing — the rig, instrument and grading script exist | The only axis on which MoQ leads. Cheapest high-leverage measurement outstanding |
| 3 | **What is glass-to-glass latency, at equal conformance, on either plane?** | Partly the hardware in row 1, for the segmented arm | The decision rule in [Comparison](comparison.md) §5.2 rests on a structural argument, not a measurement |
| 4 | **Does a commercial ABR-to-TS gateway produce P1/P2-conformant output as the distributor's own edge stage?** | MEG- or TITAN-class hardware | Whether part of the broadcast-grade layer is purchasable on one data plane and not the other; also the only route to a low-latency TS-in-HLS receiver |
| 5 | **Can a CDN carry a multi-programme TS segment in practice?** | A CDN account and the MPTS fixture | The whole of MoQ's remaining carriage-fidelity advantage |
| 6 | **Do the groomer's correctness boundaries hold** — source-clock drift, PCR discontinuity and wrap, mid-stream PID change, T-STD occupancy? | The hardware rig in row 1 | Whether steady-state conformance generalises |
| 7 | **Does the 1+1 result survive two hosts, two clocks and multi-track content?** | A second instance in another availability zone | [Architecture](architecture.md) §5.1's recommendation is currently scoped to one host and single-track content |
| 8 | **Which congestion controller suits a permanent fixed-rate trunk?** | Running T8b's C2–C6 | An operational recommendation that currently cannot be made |
| 9 | **What does the opaque lane cost on the wire, and does it survive a real path?** | Building the private lane in the measurement environment | Whether byte-verbatim carriage is a wash or a real cost against SRT |
| 10 | **How much of MoQ's carriage advantage survives a different source?** | Two more source profiles | The largest caveat on the deciding line of the cost model |
| 11 | **Does fixing the announce convention clear the pairings it blocks, and what are the three undiagnosed failures?** (§3.7) | Upstream adoption, and diagnosis | Relay portability, which underwrites the economic argument |
| 12 | **How does a segmented-HTTP leg behave when segments are genuinely lost rather than late?** | A lossy path in the rig | Its recovery-model advantage is specification-based and unexercised |
| 13 | **Does the relay's memory plateau hold over weeks rather than hours?** (§3.6) | A longer soak | A sizing line rather than a restart cycle |
| 14 | **Should a recovered audio gap be signalled downstream, and should the continuity guard be the only check?** (§3.1) | Upstream design | Whether the ingest edge's absorption is observable |

Protocols for the runnable ones are in [planned-experiments](../lab/planned-experiments.md).
