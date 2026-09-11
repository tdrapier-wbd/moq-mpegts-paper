# Evidence: Method, Results and Limits

Status: working draft.
Layer: **cross-cutting** — this is the empirical basis for every claim in
[Comparison](comparison.md), [Architecture](architecture.md) and [Economics](economics.md).

This document is organised by **question**, not by experiment. The per-experiment record — objective,
environment, exact commands, full result tables, pass criteria fixed in advance, and the corrections
each experiment forced — is the laboratory notebook in [`lab/`](../lab/README.md), and each result
below cites the experiment that produced it.

Three conventions apply throughout. **Every figure names its measurement point** (*P0*
source, *P1* captured file, *P2* live wire). **Nothing here is a hardware P2 result**; where file and
wire differ, both are given. **`[unmerged]`** marks evidence against proposed upstream code; **`[dev]`**
marks merged behaviour not yet on the release line. **Single-run matrices** establish mechanism and
ordering, not distributions.

---

## 1. What was measured, and on what

Four code bases carry the media on the paths under test, and it matters which produced which.

| Code base | Role here | Reach |
|---|---|---|
| **Upstream `moq-dev`, media-aware lane** (`moq import ts` → `moq-relay` → `moq export ts`) | The **preferred path** and the lane almost every result was measured on | Deployed over the public internet via an AWS EC2 relay |
| **[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)** (public, ours) | The CBR/PCR groomer, deliberately outside the transport | Exercised on the media-aware, segmented and point-to-point arms alike |
| **Private opaque `m2ts` prototype** (draft-14, MSFTS `m2ts` packaging) | **Reference and benchmark** — it shows what byte-for-byte transparency looks like, so the media-aware lane's residual gaps are measured rather than asserted | **Loopback only. One run. Never deployed** |
| **TSDuck plugins** — `hls` output and input for the segmented lane, `srt` and `rist` for the byte-transparent point-to-point controls | The *alternative data planes*, published and reassembled with the same tool used as the oracle throughout, so their results are directly comparable | Loopback and, for all three, over the public internet from the same EC2 origin |

Two further classes of code appear but are not data planes. **Candidate grooming and sending stages**
— FFmpeg, GStreamer and [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) — are graded as
*stages* on the paths above rather than as transports ([T13](../lab/test-13-downstream-grooming.md),
[T16](../lab/test-16-grooming-segmented-http.md)). **Purpose-written instruments and clients**, including
the segmented lane's retrying puller, are listed in §1.1 with what each cannot show.

| Property | Media-aware lane + `mpegts-pacer` | Opaque prototype (reference) |
|---|---|---|
| Wire version exercised | moq-lite-04/05 | `moq-transport` draft-14 |
| Elementary streams, original PIDs, SCTE-35 | preserved | preserved verbatim |
| Service layer (SDT/NIT, PMT PID, TSID/ONID) | preserved | preserved verbatim |
| EIT | round-trips section-for-section | preserved verbatim |
| TDT/TOT | carried, but **re-emitted on the exporter's own 30 s grid, so the clock arrives ~14 s late** | preserved verbatim |
| CBR and PCR cadence | restored downstream by `mpegts-pacer` — **on file, and on the wire once the groomer reserves the PCR slot rather than waiting for a spare one; buffer depth was never the variable, §3.2** | preserved end to end by the prototype's own pacer |
| Public-internet operation | yes | **no** |
| Congestion controller | BBR (explicit) | quinn default (CUBIC) |

### 1.1 Instruments, and what each cannot show

| Instrument | Used for | What it cannot show |
|---|---|---|
| TSDuck `analyze`, `continuity`, `pcrextract`, `pcrverify` | Structure, PID census, continuity, PCR interval and accuracy | Wire timing. `pcrverify` on a file checks PCR against byte position, i.e. the arithmetic of the re-stamp |
| `t13-cadence.py` (64 kB pipe reads, or per-datagram capture) | Burst size, gap distribution, coefficient of variation | Absolute rate on loopback — loopback inflates burst *rate*; burst *size* and inter-burst silence are structural |
| `t12-merge-oracle.py` + `t12-maskcmp.py` + `t12-seqskew.py` | ST 2022-7 merge behaviour, byte identity, skew | A hardware IRD's merge engine. It is a reference implementation of the selection rules, tested against fourteen adversarial conditions (`t12-oracle-selftest.py`) which label where it matches the standard, where the standard requires nothing, where the rule does not apply and where it is blind — not a conformance claim. It also degrades to noise on a pair that is not byte-identical, which is why the mask and skew tools exist |
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

- **Gate 1 — media fidelity.** Rungs 1 and 5 pass. Cheap, do first. **Met at P1** (§3.1).
- **Gate 2 — hardware conformance.** A TR 101 290 P1/P2 pass on real IRDs (rung 4).
  **Make-or-break; not attempted.** If this fails, fix grooming before anything else.
- **Gate 3 — resilience.** The hitless redundancy drill passes (rung 6). **Met in software against a
  reference receiver**; the on-hardware merge is part of Gate 2.

**Rung 3 is necessary and not sufficient** — the gap to rung 4 is measurable (§3.2). **Rung 7
belongs before a data-plane commitment**: the comparative lab settled grooming burden against the
intuitive answer.


---

## 2. Summary of what is and is not established

A signpost, not a substitute: every entry is stated with its qualifications in the section named, and
every "not established" entry recurs in §4 or §5.

| | Established | Not established | Where |
|---|---|---|---|
| **Carriage** | All three lanes carry a full broadcast mux with 0 continuity errors, each departing from verbatim in a different direction: SRT on no criterion, segmented HTTP by one injected PAT/PMT pair per segment, the media-aware lane by stuffing, mux rate, PSI density and PCR spacing | Multi-programme carriage through a real CDN; the opaque lane anywhere but loopback, and its PCR arithmetic at any gate | §3.1 |
| **Timing** | Grooming restores exact CBR and P2-limit PCR accuracy **on file**, and both lanes now reach the same standard **on the wire over minutes**: the MoQ lane passes P1 repetition (0 of 20,193 intervals above 40 ms over 300 s) once the groomer reserves a slot for the PCR instead of waiting for a spare one. It was never a buffer-depth problem. **It also holds over a day** — 24.01 h on a continuous timeline, clean on continuity, repetition, underruns and respawns, crossing the 33-bit rollover in flight ([T21](../lab/test-21-permanence-soak.md)) | Anything at all on hardware; anything beyond a day, or on a real encoder's timeline rather than a synthetic clock over a repeating clip | §3.2 |
| **Loss** | The controller decides the result on both data planes, and **once the lanes are substrate-matched no impairment axis cleanly separates them** — the reordering separation that used to do so was a packet-size artefact. Six congestion conditions rank the controllers three ways, so **no controller recommendation is supportable**: what governs the feed is the provisioning margin (≥ 1.2× / ≥ 1.5×), the bottleneck queue discipline and the receiver's latency budget. Trunking N contended media-aware feeds costs aggregate throughput, and the cost is the subscriber's release deadline rather than the controller or bufferbloat | Where the latency knee sits, and whether it tracks RTT, group duration or relay buffering; the same ladder against a real CDN edge | §3.3 |
| **Redundancy** | Two stream-clocked groomers are byte-identical and hitless through every upstream failure, **on single-track content, with no shared component at all** — separate publisher, relay, exporter and host in two availability zones. **A multi-track mux over independent chains reaches only 75.56 %**, the same packets in a different order. On the segmented lane a pair sharing one feed and one naming scheme is hitless with no receiver-side merge at all | A hardware merge; multi-track identity, which now needs the exporter's interleave fixed rather than a measurement. On the segmented lane: a distributed segment store, and a standby joining mid-stream | §3.4 |
| **Cost** | Wire multipliers on a real path; relay CPU and memory envelope. **The fan-out scaling model is now the relay's rather than the test box's**: measured cross-host, each additional subscriber costs 0.806 % of a core, 1.39 MB and one full stream copy, all linear, giving 124–139 subscribers per core, confirmed against a predicted cliff. Saturation collapses rather than degrades | The opaque lane's wire cost; a second source profile; any wide-area path — this is two availability zones in one region at 0.72 ms RTT, so it bounds relay capacity and says nothing about internet-scale fan-out; channel-count scaling; high fan-out held for longer than 45 s | §3.5, §3.6 |
| **Isolation** | An abusive receiver cannot reach another subscriber's media: five arms leave the victims within 8 KB of the control across 198 MB at 0 continuity errors, and the relay never refuses or delays a connection. The cost is the relay's memory — 87 MB → 1.9 GB in 60 s from subscription churn — and it is **abandoned-session retention** rather than cached payload or concurrency, each of which §3.14 rules out with its own control. Tunable: 30 s → 10 s idle timeout takes it to 489 MB | The segmented lane's half of the same experiment, so no comparison; anything adversarial rather than accidental; whether it scales linearly in abuser count | §3.14 |
| **Observability** | **The transport never detects a media-plane failure** — a source frozen for 120 s produced no log line anywhere, and a dead video path behind a live mux passes the *whole* of TR 101 290 P1 with a worst PCR interval identical to the control's. What does detect every case is **per-PID access-unit liveness**, and that is now a running detector rather than a recommendation: live at the groomed output of a cross-host lane it measures a 60 s video suppression as **57.212 s** against an offline grader's 57.22 s, catches a dead *audio* stream — which has no other wire-observable signature at all — in **0.7–1.4 s**, localises it to the PID, and fires nothing on a healthy lane | Whether commercial monitoring exposes per-PID liveness rather than only per-PID bitrate, which inherits the proportional-sensitivity problem; a **frozen picture** in valid advancing access units, which defeats every transport-layer detector here and over SDI equally; detection-to-response, since only signal availability is measured | §3.12 |
| **Interop** | Media flows within one implementation and through none of eight others | Why three of the eight fail | §3.7 |
| **Latency** | Delivery latency on all four planes, loopback and public internet, each graded against the conformance of the same bytes. **Where no plane is conformant, MoQ crosses the internet in 109 ms** against SRT's 1618 ms and segmented HTTP's 4067 ms. **At the configurations measured conformant, MoQ reads 2,447 ms and segmented HTTP 9,286 ms**, while the transparent tunnels carry their source's grid at a buffer the operator sets | Encoder and decoder latency, so no camera-to-display total; a lossy or long path; whether RIST really beats SRT on a real path; **any conformant sub-second configuration, on any lane** | §3.11 |

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

The hard case is a **sparse** schedule sub-table (32 sections against a declared 248): an
importer must commit on transmission-cycle wrap, and a lost section is indistinguishable from one the
source skipped. Carriage is **bitrate-neutral** (0.985×) and join costs **~1 ms** across six SI
tracks. TDT/TOT is proxied byte-identically but re-emitted on the exporter's **~14 s grid** rather
than the source's 0.5 s cadence — late and occasionally backwards-stepping
([T15](../lab/test-15-point-to-point-cadence.md) measurement 4); upstream fix merged, not on the
deployed build.

**Three real-feed import defects closed upstream**, each measured before and after: open-GOP
(recovery-point SEI, not IDR — no video); audio frame-sync loss fatal to the whole publisher (now
**one 24 ms frame** on one-byte damage); splice-as-substitution (continuity counter now checked on
elementary streams). **Residuals**: ~1/16 splices invisible to the counter; **256 ms good AC-3 audio
lost per splice** (MP2 unaffected); recovered gaps **signalled nowhere** (open question §5).

**The opaque lane is byte-transparent, on one run.** TSID, ONID, service name and type, all PSI/SI
including TDT/TOT and CAT, PMT PID, PCR PID, every elementary stream and every SCTE-35 PID preserved
verbatim; 0 CC and transport errors; CBR and PCR conformance preserved when fed raw
([T3](../lab/test-3-opaque-transparency.md)). **Read that with §4's scope limit attached**: it is
loopback, file-fed, on a pinned obsolete draft, against a private implementation, and it has never
been repeated.

**Segmented HTTP is transparent to what a mux contains and not to when it was sent**, which is the
opposite of what the specification's wording suggests. Measured two ways. Packet by packet against the
source, a published segment differs in a 1,200-packet window in **two packets, both PSI, each in byte 3
alone** — the continuity counter on the PAT and PMT the segmenter injects at each segment head, whose
renumbering is forced; every media, audio, teletext, splice and stuffing packet is byte-identical and
continuity is error-free across segment boundaries
([T14](../lab/test-14-data-plane-comparison.md)). Scored against the opaque lane's own inventory on
three clips ([T3](../lab/test-3-opaque-transparency.md), P1/file domain) it matches the opaque lane on
content and beats the media-aware one: TSID, ONID, service name, provider and type, PMT PID (0x1000,
0x0020 and 0x0064 all held rather than renumbered), PCR PID, every elementary stream at its original
PID including visual-impaired commentary audio, every SCTE-35 PID, null stuffing, **CAT and TDT/TOT**,
no table re-versioned, 0 continuity errors, 0 transport errors, and 0 PCR repetition intervals above
40 ms.

**The packager itself is media-aware, and the distinction bounds what may be claimed.** `tsp -O hls`
is not a byte splitter: it re-multiplexes, regenerates PSI and chooses segment boundaries by picture
type, and on a *finite* input it truncates roughly the last 5 % rather than flushing it
([T11](../lab/test-11-interop.md)). What the packet-by-packet comparison establishes is that those
mechanisms happen to be payload-preserving on a live feed, not that nothing parses the stream. So the
accurate form of the claim is **verbatim in payload, not as a mux**, and "nothing in the path parses
the payload" is true of the *cache and the network* — which is where the scaling argument needs it —
and not of the packager.

**The EPG survives both lanes** on a synthetic 8-day fixture (69 sections byte-identical at
1.003× on segmented HTTP, 0.985× on MoQ — [T17](../lab/test-17-si-snapshot-tracks.md) §5). MoQ
delivers snapshots in ~1 ms; a segmented client waits out the carousel.

Segmented HTTP adds **exactly one PAT/PMT pair per segment** — 376 bytes displacing later PCRs by
**~300 µs** predictable from the source rate (measured 297.7–301.9 µs on three clips). That takes
2,453 of ~2,457 PCRs past the 481 ns P2 gate on the broadcast clip while P1 table margin improves;
segment duration changes the violation *count* but not the max error (sweep detail:
[T14](../lab/test-14-data-plane-comparison.md)). Groomed, the chain passes at 481 ns (§3.2). **The P2
accuracy gate is undefined on the media-aware lane's ungroomed egress** — no mux rate to grade against
(22–32 Gb/s on 10–27 Mb/s content); on that lane the groomer *creates* the quantity the gate names.

### 3.2 What does delivery do to the clock, and can it be repaired? — Yes, on both lanes and on the wire in software; the wire is not the file, and on the media-aware lane the repair costs latency
**The problem.** Bursty delivery leaves a reconstructed transport stream with PCR *intervals* that no
longer track a constant mux rate: the bytes, PCR values included, are intact; the delivery *cadence*
is not. Soft players tolerate this; hardware IRDs lock a PLL to PCR and raise TR 101 290 P1/P2 alarms
in response. *(The IRD reaction is accepted broadcast practice, not something this campaign observed
— no hardware has been fed by this chain.)*

**Ungroomed, at P1 (file)** ([T2](../lab/test-2-media-aware-transparency.md),
[T7](../lab/test-7-timing-integrity.md)): **0–26 % of PCR intervals exceed the 40 ms limit, depending
on the source** — 25.2 % on a synthetic 10 Mbps CBR reference, 13.9 % and 9.1 % on two real CNN
contribution captures, and **0 % on a 27.5 Mbps broadcast mux whose native 27 ms PCR cadence is
already inside the limit**. The opaque prototype holds 0 % on every clip
([T3](../lab/test-3-opaque-transparency.md)), isolating cadence loss to the re-mux rather than to QUIC.

**The ungroomed egress manufactures its own interval distribution** ([T4](../lab/test-4-remote-e2e-srt.md),
public internet): on a source at a flat ~24.4 ms grid with **not one interval above 40 ms**, the egress
conserves the mean to within 0.7 ms while **1,123 of 1,307 intervals fall under 1 ms** and the residual
collects into gaps to **319.94 ms**. The groomer's role is therefore reconstructing a timeline the lane
discarded, not tidying an awkward encoder.

**Groomed, on the wire — the figure to quote** ([T13](../lab/test-13-downstream-grooming.md),
[T19](../lab/test-19-pcr-grid-verification.md) measurement 11): measured on the socket over 300 s, the
current groomer delivers **0 of 20,193 PCR intervals above 40 ms, worst 30.1 ms**, with 0 continuity
errors, 0 drops and exact CBR. **Any "0 %" figure must name its domain**: file analysis confirms
re-stamp *arithmetic* ([T7](../lab/test-7-timing-integrity.md): 0 % above 40 ms, 0 `pcrverify`
violations at ±500 ns, exact CBR) but does not prove wire-time placement; T13's original result was
*"pass on file; **fail live**"* until the stage was corrected.

**Groomed, on file over a live chain** ([T8](../lab/test-8-srt-vs-moq.md), one run, indicative):
EC2 → home takes egress from **10.78 % of intervals above 40 ms** to **0.06 %** — still not zero on
the wire, pointing at real-time stage behaviour.

**The segmented-HTTP lane** reaches the same standard on the wire
([T16](../lab/test-16-grooming-segmented-http.md)): **0** intervals above 40 ms, **0** PCR violations
at 481 ns over 2,496 PCRs, with nothing dropped — bounded to ~11.5 Mbps on this test host. Its
ungroomed egress already carries the source PCR grid in segment payloads, so grooming there buys
cadence and CBR rather than PCR repair.

**On the MoQ lane, cushion depth is not the variable.** Sweeping the groomer's cushion across an
eightfold ladder moved repetition **not at all** — ~490 intervals above 40 ms out of ~3,300 at every
rung, 228 ms maximum unchanged — and the groomer's own insertions ran **137 → 0** at four insertion
rates with one violation count ([T18](../lab/test-18-delivery-latency.md),
[T19](../lab/test-19-pcr-grid-verification.md) measurement 11). The misread — that upstream headroom
was the cause — failed because the groomer placed PCR only into slots the content scheduler declined;
inside a burst there are none. **Pre-empting the slot — reserving it on the deadline and deferring the
displaced packet by one — clears the gate at every depth tested**, independent of cushion, exporter
cadence and content.

**What the exporter did wrong is spacing, not rate** (P0/P1 comparison on the same clip: source via SRT
**0 intervals > 40 ms, max 25.0 ms**; MoQ export **85 % sub-millisecond, 375–414 > 40 ms, max to
1.84 s**). An even PCR train went in and the same quantity came out in bursts. Three upstream fixes
landed ([#2967](https://github.com/moq-dev/moq/pull/2967) exact 25 ms values,
[#3006](https://github.com/moq-dev/moq/pull/3006) stdout pacing,
[#3351](https://github.com/moq-dev/moq/pull/3351) byte-adjacent placement), resolving value grid,
release timing and positional clustering respectively — yet the wire gate still failed until **three
groomer defects** were corrected ([T19](../lab/test-19-pcr-grid-verification.md) measurement 11;
chronology and intermediate builds in [T19](../lab/test-19-pcr-grid-verification.md) and
[T18](../lab/test-18-delivery-latency.md)): opportunistic PCR re-insertion (fixed by pre-emption), a
media-rate estimate biased low on uneven intervals (fixed by ratio-of-sums over 2 s), and open-loop
release (fixed by occupancy-closed loop). **The refuted hypotheses matter**: denser upstream cadence
would not help — extra PCRs land inside existing clusters; buffer depth cannot help — no cushion
shortens a coded frame; and file-domain validation was optimistic relative to the wire throughout.

After all three groomer fixes, on the same 90 s live arm: continuity **527 → 0**, intervals above
40 ms **432/3,882 → 0/5,892** (worst **286.2 → 30.1 ms**). Over 300 s: **0 of 20,193 intervals above
40 ms**, exact 11 Mb/s CBR, 0 drops, 0 underruns. T19's three conformance criteria are met; its fourth
— no regression in delivery latency — is **not**, because the arm that passes the other three delivers
at 2,447 ms (§3.11).

**It holds over a day** ([T21](../lab/test-21-permanence-soak.md)): 24.01 h on a continuous timeline —
**632,199,204 packets, 5,947,298 PCRs, 0 continuity errors, 0 intervals above 40 ms (worst 30.08 ms),
0 underruns, 0 respawns**, worst programme gap **27 ms**, **33-bit PCR rollover crossed in flight at
19.4 h** at no cost. The source replays a clip with clocks advanced across joins
(`ts-continuous-source.py`); it bounds the claim to a synthetic clock over repeating programme, not a
real encoder's restarts.

The nine-minute failure of an earlier attempt is a **rewind-recovery result, not permanence** (§3.13):
the groomer's rate estimator ramped when the exporter's PCR degenerated on a looping stimulus — fixed
in `mpegts-pacer` `5ab84cd` and upstream for the exporter half.

**Permanence is blocked by one resource series**: `moq import ts` resident memory grew **+2.83 MB/h**
linearly with no drawdown over 24 h (~24 GB/year), failing [T21](../lab/test-21-permanence-soak.md)'s
resource criterion in that role only; every other role passes (groomer flat, exporter converged, relay
logarithmic — §3.6).

**The buffer bound is set by the peak coded frame, not bitrate.** Three sources at 9.5–9.9 Mb/s
programme have peak coded frames of **256, 1,826 and 4,562 packets**; **3.6× the peak frame's carriage
duration** sufficed on all three where 2.5× did not. The cap governs loss; the cushion does not. A coded
frame's carriage duration at the mux rate is the encoder's VBV occupancy moved downstream.

**Off-the-shelf grooming** ([T13](../lab/test-13-downstream-grooming.md)): behind a MoQ egress
**nothing passes all four criteria** (mux preserved, PCR accuracy, repetition, honest paced wire) —
TSDuck cannot inflate stuffing, FFmpeg/GStreamer damage carriage. A dedicated datagram sender after the
muxer passes wire timing; **carriage remains unsolved off the shelf on the MoQ lane**. On segmented
HTTP, where stuffing and PCR grid survive, `tsp -P pcradjust -P regulate -O ip` passes all four. Full
chain matrix: [T13](../lab/test-13-downstream-grooming.md).

**On the segmented lane, buffer depth is the binding constraint** — at 8 s cushion, 0 intervals above
40 ms; at 1 s against 2 s segments, **311 continuity errors** and 1.85 s silences. Depth prevents a
stage running dry; it does not buy PCR repetition on either lane.

**PCR discontinuity, wrap and drift stimuli** are reproducible as fixtures (`ts-pcr-fixtures.py`;
graded by `ts-pcr-selftest.py`, 38 assertions). Pipeline response to each class: §3.13. Analyser
defects found during fixture build are recorded in [T19](../lab/test-19-pcr-grid-verification.md); no
published conformance figure changed.


### 3.3 How does the transport behave under loss? — The controller decides it, on every lane; and once the lanes are substrate-matched, reordering does not separate them either

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
| 25 % reordering *(superseded — packet-size artefact, see below)* | *0.98* | — | *0.19* | *0.19* |

**Read down a column and the data planes are indistinguishable; read across a row and the controller
decides the result.** A loss-based controller reads a dropped packet as congestion and backs off
whether the bytes are a QUIC stream or an HTTP response, and a delay-based one does not, equally on
both. So the familiar claim that segment fetching degrades under loss where MoQ does not is a
comparison of TCP's default controller against QUIC's tuned one; correcting it removes the loss axis
as a discriminator between the two architectures entirely.

**Reordering was a packet-size artefact, not a lane property** ([T20](../lab/test-20-segmented-http3.md),
P1): unequal MTU gave the segmented lane **24× fewer** reorder events. Equalised, HTTP/3 cells overlap
(segmented 0.18, media-aware 0.13); the original 0.98/0.19 separation was substrate and size, not
architecture.

**The substrate change is a trade rather than a loss.** Moving the segmented lane to HTTP/3 costs it
the reordering cell and wins it two others: at ~20 % *applied* loss it reads **0.10 on TCP against
0.70 on HTTP/3**, and under a 30 s total outage **0.51 against 0.76**. Under no impairment the two
substrates produce byte-identical output, so nothing in carriage fidelity turns on the choice.

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

**No controller recommendation for a permanent fixed-rate trunk is supportable, and that is now a
result rather than a gap.** Six conditions have been run — under-provisioned, provisioned with a
competing flow, coexistence, an AQM counterfactual, a provisioning-margin ladder and a 14 h soak — and
**three of them rank the controllers in three different orders**. Under a permanently too-small cap
behind a tail-drop buffer, BBRv2 on quiche is stable and complete where CUBIC bloats and BBRv1 is
bimodal on one replicate of three. On a provisioned path with a competing flow, BBRv2 sheds 28–35 % of
the feed and takes 11–13 s to recover, CUBIC sheds 6–15 %, and BBRv1 barely registers it. Put an AQM at
the bottleneck and the spread closes to nothing worth quoting. The reason they disagree is consistent:
**a controller that yields to a full queue is right when the queue is full because the link is too
small, wrong when it is full because a neighbour is briefly busy, and irrelevant when the queue is never
allowed to fill.** BBRv3 (noq) is excluded in every condition by a library defect
([T8b](../lab/test-8b-congestion-control.md)).

**What does move the outcome is three things the controller choice is smaller than.** An AQM takes
standing delay from 554–584 ms to 100–119 ms for every controller and transport at once. The
provisioning margin gives the one number an operator can act on — **provision at ≥ 1.2× content rate
for the media-aware lane and ≥ 1.5× for a segmented one**, the segmented figure higher because each
segment fetch is a line-rate burst whose queueing is set by burst shape rather than average headroom
(336 and 337 ms, measured independently in two conditions). And the third is the receiver's own latency
budget, below.

**Trunking several media-aware feeds down one congested path costs aggregate throughput, and the price
is set by the subscriber's latency budget rather than by the network.** At a 2 s budget through a
15 Mb/s bottleneck, MoQ's *total* delivered falls from 9.44 Mb/s at one feed to 5.39 at two and 4.48 at
three under CUBIC (4.89 and 4.02 under BBRv1) — below what a single feed carried unopposed — while SRT
rises to 12.65 and holds at 84 % of the cap. **Neither the controller nor bufferbloat explains it:**
loss-based CUBIC collapses inside BBRv1's spread at every flow count, and the collapse survives `cake`,
which cut RTT from ~550 ms to 100 ms and left the aggregate at 48 % and 40 % of cap. What explains it is
the release deadline — widening `--latency-max` from 500 ms to 30 s at two flows moves the aggregate
**4.29 → 10.35 Mb/s**, past the single-flow rate, at **0 continuity errors throughout**. Each subscriber
is independently discarding groups that missed its own deadline, and N of them doing so sums to less
than one subscriber under no pressure.

That makes it a sizing rule and not a limit of the lane: **a trunk carrying N contended feeds must be
provisioned in latency as well as in rate**, and the two lanes make the same trade in opposite
directions — at a comparable budget SRT converts the identical shortfall into 26,000 continuity errors
rather than into absence. What is not established is where the knee sits, or whether it tracks the RTT,
the group duration or the relay's own buffering.

*Measurement point P1. One replicate per cell; the aggregate reproduces to about ±15 % (7.17 against
5.50 Mb/s for one cell run twice), so no statement above rests on a difference smaller than a third.*

The operational consequence is the one in [Architecture](architecture.md) §8.5: pin the controller
explicitly, because the resolved default is backend-specific, and choose it against the route's own
conditions rather than against any of these matrices.

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
| Ungroomed, RTP framing pinned on both legs | **yes** — 100 % alignment in 12/12 cells; but 1,523 of 1,524 PCRs outside ±500 ns, so a transport that fails the P2 accuracy gate | the whole chain |
| One *arrival-clocked* groomer per leg | **no** — 30–53 % alignment, never merges | nothing mergeable; input-select still works |
| One groomer, datagrams duplicated to both paths | **yes** — 100 %, hitless under every path injection | **the last hop only** |
| One *stream-clocked* groomer per leg | **yes on single-track content** — byte-identical on every datagram, co-started, and with publisher, relay, exporter and host all independent. **No on a multi-track mux** (75.56 %), where the exporter's arrival-ordered interleave differs between chains | **the whole chain**, including publisher, relay and exporter death |

Arrival-clocked groomers fail structurally — they produce different transports, not the same
transport differently stamped (PID-order and null-packet disagreements dominate; none of 400 sampled
conflicts differ only in PCR). **Stream-clocked** groomers — placement from the source PCR grid — are
the fix. Re-tested with legs on separate hosts in two availability zones and again with fully
independent publisher/relay/exporter/host chains: **byte-identical on every shared datagram including
continuity counters**, 46,778 of 46,778 on single-track content, zero residue
([T12](../lab/test-12-dual-path-handoff.md)). **Multi-track mux over independent chains: 75.56 %** —
same packets, different order (`pick_next_track` interleave — [#2829](https://github.com/moq-dev/moq/issues/2829)).
Byte-level mergeability is therefore a property of **single-track content**, not of 1+1 in general.

> **A caveat on P1 that this rig cannot resolve.** On the rig that produced these cells, **1.4–1.6 %
> of PCR intervals exceed 40 ms in every cell including the clean control**. The experiment attributes
> this provisionally to running a 4 Mb/s carrier for a 1.9 Mb/s feed and explicitly declines to make
> any absolute PCR-interval claim from it. **What these runs establish is P2 accuracy and
> mergeability, not P1 repetition.** A matched-rate re-run would settle it.

**A groomer must stop when its content stops** — without silence detection it emits valid CBR
with no programme, defeating every receiver-side switch policy; with mute, each failure mode produces
one switch at thresholds from 50 ms (groomed) to 500 ms. Ungroomed burstiness to 242 ms makes 50 ms
unsafe (413–446 spurious switches). Residual byte-identity gaps come from exporter process state:
continuity counters (masking lifts agreement to ~98 %), SI cadence (fixed upstream for single-track),
and audio/video interleave (94–96 % co-started, 75.56 % on independent chains). Counter restart at
keyframes plus 16-packet padding reaches **99.9 % / 93.6 %** at 1.5–1.7 % overhead.

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

MoQ's return path is eight times SRT's (1.16 % vs 0.13 % of forward); counting both directions
MoQ is still 4.3 % cheaper. **The advantage tracks the source's stuffing ratio** — quote stuffing
with any cost figure. HTTP overhead is negligible (0.06–0.09 %); HTTP/3 costs ~2.6 points more than TCP
for framing.

### 3.6 What does a relay cost to run? — Cheap and predictable, with one bounded memory cost

Measured on Linux with the current release, MPEG-TS at 2–27 Mbps
([T9](../lab/test-9-performance.md)).

**Relay cost tracks session count, not bitrate.** A subscriber session costs ~0.34 % / 0.87 % / 1.18 %
of a core at 2 / 10 / 27 Mbps, so nearly fourteen times the bitrate costs about three and a half
times the CPU. Cost per Mbps therefore *falls* as bitrate rises, and one core carries roughly a
gigabit — about 110–120 sessions at 10 Mbps. Count sessions rather than gigabits, and note that
contribution-grade high-bitrate feeds are the *cheapest per Mbps* to relay.

**The fan-out limit is the relay's CPU, and it arrives where a linear model says it will.** Measured
cross-host, with the relay alone on one instance and the publisher and every subscriber on another
([T26](../lab/test-26-cross-host-fanout.md), P0/P1) — because the earlier N = 55 knee was the *test
box*: co-located subscribers cost ~2.4× the relay's own CPU, so a 2-vCPU host hit 94 % of both cores
while the relay used under half of one. Moved off the box, the same relay class carries **150
subscribers at 1,426 Mb/s aggregate** with per-subscriber delivery flat within 1.5 %, and the cost per
additional subscriber is linear on every axis:

| Per additional subscriber | Cost | Fit |
|---|---|---|
| Relay CPU | **0.806 % of a core** | linear, r² = 0.998 |
| Relay RSS | **1.39 MB** | linear, r² = 0.9997 |
| Relay egress | **9.84 Mb/s — one full copy** | linear, r² = 0.9996 |

That slope gives **124–139 subscribers per core**, or ~1.2–1.34 Gb/s of egress per core at this
bitrate — and it was *tested* rather than extrapolated: pinning the relay to a single core moved the
collapse to exactly the predicted point, at 99.9 % of that core, with its host only 61 % busy. The
attribution is closed from the other side too, since EC2's four interface allowance counters stayed at
**zero** throughout and the subscriber host was at 39–65 % busy at every cliff. **Nothing here is
superlinear**, and neither descriptors nor threads move at all across a 200× fan-out (11 and 3),
because every QUIC connection shares one UDP socket.

**The subscriber's own cost is a cache filling to ~120 MB, not a fixed per-process footprint nor a
leak** ([T27](../lab/test-27-liveness-detector.md), P1). With subscriber count held constant so time
is the only variable, **mean** `moq export ts` RSS rose **49.0 → 119.1 MB over 703 s** (peak single
process **124.4 MB**); a logarithm fits at r² = 0.904 against a line's 0.602, the second half
decelerates to **−0.21 MB/min**, and the largest drawdown from a running peak is **9.4 MB**. The mean
sits in a **106–119 MB** band past 300 s; [T21](../lab/test-21-permanence-soak.md) independently
found the same process at **119–122 MB** from 0.5 h to 4.5 h — the same run T27 cites as **50.2 →
121.9 MB** when read at peak RSS rather than mean. **~120 MB per session is the figure to plan
against**; [T26](../lab/test-26-cross-host-fanout.md)'s 45 s snapshots (~96 MB) captured only the
fill's early axis. A host aggregating many sessions is sized by *memory* well before CPU (~130
sessions exhaust 15.7 GB).

**Saturation is a collapse, not a graceful degradation.** Past the cliff aggregate throughput *falls* —
1,184 → 528 Mb/s, and 964 → 46 Mb/s in a second arm — while relay CPU stays pinned at its limit and
relay RSS jumps 2.5× as queues back up behind it. No subscriber is thinned in favour of another; the
service breaks for everyone together. A relay must therefore be provisioned with headroom and
admission-controlled, and the memory spike means a memory-constrained relay meets the OOM killer at
the same moment rather than merely slowing down.

**Host configuration outweighs anything else measured**, and it is worth more than a caveat: enabling
UDP GSO cut per-subscriber relay CPU by **29 %** (1.135 → 0.806 % of a core) and raised the usable
ceiling by half, on Linux, from one flag. The same relay version had cost ~6× more CPU per Mbps on
macOS loopback with GSO disabled. **Any capacity figure for this lane is a figure about a
configuration.**

**Role memory varies by role and soak length.** [T9](../lab/test-9-performance.md)'s 26.5 h soaks read
flat for import and export (+0.03 and +0.15 MB/h); [T8b](../lab/test-8b-congestion-control.md) C6's
14 h shaped WAN run read importer **+0.14 MB/h** and exporter **+0.06 MB/h** with **0 continuity
errors and 0 respawns**. **[T21](../lab/test-21-permanence-soak.md)'s 24 h permanence soak splits
that picture**: groomer flat (+0.5 MB total), `moq export ts` converged (+118.9 MB total), relay
logarithmic (baseline **+242.6 MB** at 24 h), and **`moq import ts` linear at +2.83 MB/h** with no
drawdown — failing that experiment's resource criterion (§3.2). Per-process confirmation at 6 h:
**+2.91 MB/h** in `moq import ts` alone ([#3493](https://github.com/moq-dev/moq/issues/3493)).

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

So a relay is **sizeable rather than fragile**: budget the ceiling and treat scheduled restarts as
prudence rather than necessity. Two operational qualifications: the plateau is **soft**, still creeping
at ~8 MB/hour past the knee, so alarm thresholds belong above the ceiling rather than at it; and the one
lever that works is **sub-proportional** — cutting slots by 9.8× reduced retained memory by only 3.3×,
because 20–30 MB of the ceiling is slot-independent. A separate and far more severe defect is genuinely
gone: an older release grew ~21 MB/hour *with no subscribers at all* to an out-of-memory kill after six
days, and no current build reproduces that.

**Budget ~2–2.5× the slot ceiling, not the slot arithmetic alone.** C6's 14 h soak converged on
baseline + 200.5 MB (**2.03×** the ~99 MB slot ceiling), slope decaying from +24.60 to +1.82 MB/h
([T8b](../lab/test-8b-congestion-control.md) C6). [T21](../lab/test-21-permanence-soak.md)'s 24 h run
reached baseline **+242.6 MB** with a log fit extrapolating to **~519 MB at a year** — confirming
logarithmic convergence at **~2.5× the slot ceiling** (vs C6's **2.03×** at 14 h). Connection scaling is ruled out: the
pre-knee slope is flat across 0–4 subscribers, and five connections reach the same range as two. **Size
a high-fan-out relay at ~2.5× the slot ceiling per publisher**, not per connection.

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

**Multi-vendor relay portability is absent in practice** — a client-side announce default, fixable,
but the economic substitutability argument is unproven until a feed traverses someone else's relay.
The community interop matrix is control-plane only; this project contributed a media-level profile
([`interop/`](../interop/README.md)). The test client falls back to WebSocket after 200 ms, confounding
distance tests.

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
an Apple-authored informational document — and its authoritative implementation is closed-source, yet
every cache, CDN and general-purpose client carries it. MoQ is standards-track with open
implementations and no cross-implementation media interop. **Open source and interoperability are not
the same axis, and here they point in opposite directions.** But the two results scope each other:
HLS's ubiquity is on the delivery path and among clients that terminate in a player, and this section
is the measurement that it does *not* extend to a low-latency transport-stream receive path
([Comparison](comparison.md) §6.1).

### 3.10 Is there a credible entitlement substrate? — Enforcement is measured and exact; revocation is a poll with a floor above the proposed target

**Enforcement is exact, and it does not leak.** Presented with a credential, the relay admits exactly
the paths that credential names and refuses everything else. Across eight refusing arms — out-of-scope
channel, sibling tenant, expired token, publish-only credential, parent path, three malformed
tokens — **every arm delivered exactly zero payload bytes**, measured at the receiving endpoint rather
than from a relay log. Path matching is segment-aware, so a grant on `cnn` does not reach `cnn-intl`.
And entitlement governs *disclosure* as well as delivery: each affiliate was announced precisely the
channels it licenses and no others ([T36](../lab/test-36-entitlement-enforcement.md), P2; all six pass
criteria met).

Two qualifications travel with that. Refusal arrives by **two different mechanisms** depending on
where the credential fails, and one of them produces no error to the client and **no line in the
relay log at all** — so a log-based enforcement audit would have read nothing on those arms. And the
admitted arms miss the TR 101 290 P2 PCR gate, but the unauthenticated control on the same host
misses it identically, so the miss is the ungroomed MoQ egress rather than a cost of authorization.

**A licensing matrix is enforced combinatorially.** Seven credentials against four channels, all
twenty-eight cells correct, with the channel no affiliate licenses reaching nobody
([T38](../lab/test-38-entitlement-estate.md); six of seven criteria met).

**Revocation, however, is a poll rather than a push, and that sets the bound.** The relay re-asks its
admission question on a timer and acts on the answer; nothing is pushed to it. With one session live,
decision-to-last-byte is `(re-check cadence − phase) + 0.110 s` across five cadences, with the fixed
overhead constant to within two milliseconds. **That single-session figure is the mechanism's floor,
not its bound.** Re-checks are served from the same cached HTTP client as admission, so with several
sessions live a re-check can be answered from an entry another session left up to one cadence ago:
across six subscribers started a second apart, four of six tore down later than one cadence plus
0.110 s and the *measured* worst case was **1.54 cadences**, against a bound the relay's own source
states as two cadences. The smallest cadence the mechanism accepts is one second — the period is
carried as integer `Cache-Control` delta-seconds and is additionally clamped to a one-second floor — so
**the best achievable worst case is about 1.7 s measured, 2.11 s as the implementation documents it,
and [Control](control-plane.md) §8's sub-second target cannot be met at any setting**
([T37](../lab/test-37-entitlement-revocation.md), P2, measured from the affiliate's captured egress;
the 2× figure is *specified* by the implementation, not measured here).

**An authorization-endpoint outage is tolerated for an hour by default, and the cadence does not
change that.** Absent a `stale-if-error` or `stale-while-revalidate` directive the staleness window is
a one-hour constant, independent of `max-age`: *measured*, a session on a one-second cadence kept
delivering uninterrupted for the whole 70 s an outage was observed, while the relay made 202 failed
re-check attempts. Revocation latency and outage tolerance are set by different parameters, and only
the first is adjustable from the cadence an operator tunes.

**Worse, the settings an operator would reach for to go faster disable revocation entirely.**
`max-age=0`, a sub-second `max-age`, and omitting `Cache-Control` each produce no revalidation at all;
in that state a withdrawn grant never takes effect, and one arm kept delivering for the full 50 s it
was observed, having been re-checked once at admission. **Three configurations silently yield an
unrevocable session, and one of them is what "revoke immediately" looks like.** What makes them
survivable is the backstop, which is real: a session ends 0.110 s after its token expires *even with
revalidation switched off*. Token lifetime is therefore the bound that always holds, and re-check
cadence the one that bounds a deliberate revocation.

**De-provisioning granularity is a credential-topology decision, and it is the sharpest practical
result.** The revocable unit is the *key*, not the grant inside the token, so an affiliate whose
channels all authenticate under one key cannot lose one of them without losing all of them.
Withdrawing one channel from a two-channel affiliate under that topology took the channel it *kept*
down for **2.78 s** and required re-provisioning under a fresh credential. Under a key per channel the
kept channel was never touched — 229,743 packets, zero continuity errors, and a delivery trace
indistinguishable from a session with the intervention removed. This is a third term in
[Control](control-plane.md) §4's scope-granularity trade-off that the document does not consider, and
it dominates the other two ([T38](../lab/test-38-entitlement-estate.md)).

**Authorization is close to free per subscriber, until the cadence gets tight.** Against an
unauthenticated relay on the same host, per-subscriber CPU slope was unchanged at 0.0920 % of a core
with authorization and a ten-second cadence; admission is a once-per-session cost that lands in the
intercept (up 0.17–0.23 percentage points). At a one-second cadence the *slope* rises 27 %, because
re-check is per session. So the price of pulling the revocation bound toward its floor is a 27 %
increase in the term that sets the fan-out ceiling. This is a same-host slope comparison over twenty
subscribers, **not** comparable in absolute terms with §3.6's cross-host figures; per-subscriber memory
under authorization was not gradeable in the rig and is not quoted.

**Key handling holds structurally.** Every key the authorization endpoint can serve is a public
verifying key with no private component, and the relay is given no key material at all — its entire
authorization configuration is the endpoint URL. Rotation with overlapping validity interrupted
nothing, and a retired key stopped being honoured 0.122 s after retirement.

**One finding is a warning rather than a result.** With client-certificate authentication configured, a
peer presenting a valid certificate and **no token** was served every channel in the estate, including
the channel nobody licenses and **the other broadcaster's channel**. The authorization endpoint is told
only that *some* certificate was presented, never which one, so certificate-scoped entitlement is not
merely unimplemented but not expressible. This does not contradict [Control](control-plane.md) §3,
which already reserves mTLS for data-plane peers — it shows why that split is load-bearing, and that
configuring both credentials together silently bypasses the token matrix.

**What remains unmeasured is the half that decides the commercial argument.** One implementation, and
the credential profile enforced at the hook is a deployment choice rather than a wire primitive the
protocol guarantees across implementations. **One relay throughout** — entitlement across a mesh, where
the admitting node and the revoking decision are different nodes, is the harder problem and is
untested. **A stub drove every run**; that the mechanism can be driven by a broadcaster's rights and
scheduling systems is untested, and [Control](control-plane.md) §6 argues that integration, not
mechanism, is what decides whether the layer delivers anything. **Rights windows are not modelled** —
every grant here is on or off, so §4's *temporary* grant type is unexercised. The licensing matrix is
irregular by construction but invented, and the scale is a handful of channels rather than an estate.

### 3.11 How long does a picture take to cross each data plane? — MoQ by 15× where nothing is conformant, and by 3.8× over the other Internet-native plane where both are

Measured source-to-groomed-egress on the presentation timestamp each picture carries, so one instrument
grades a byte-transparent tunnel and a remultiplexer alike; **every figure is paired with the conformance
of the same bytes**, because a latency quoted without a conformance level ranks a non-conformant arm
against a conformant one and calls the difference transport
([T18](../lab/test-18-delivery-latency.md), P2).

At each plane's shallowest runnable groomer cushion, on loopback and then from an EC2 origin over the
public internet at a 12.8 ms round trip, over a 90 s cell per lane:

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
raw datagrams, because what the control still pays and MoQ does not is groomer depth.

**Not one cell in that table is P1-conformant, and the ranking changes when conformance is imposed.**
Every arm above ran at the shallowest cushion it would run at; the byte-transparent arms sit at a floor
of 12–21 marginal violations attributed to the rig's rate surplus rather than to the transports, and the
MoQ arm fails outright at 504 of 3,310. **At the only configurations measured conformant:**

| Plane | Conformant configuration | Delivery latency | Conformance measured |
|---|---|---|---|
| **MoQ, media-aware** | groomer reserves the PCR slot; buffer bound 3.6× the source's peak coded frame | **2,447 ms** | 0 / 20,193 intervals > 40 ms over 300 s, and 0 over 24.01 h (§3.2) |
| **Segmented HTTP** | 8 s cushion, set by segment duration | **9,286 ms** | 2 intervals > 40 ms, 49.8 ms maximum |
| **SRT / RIST** | none needed — the egress carries the source's own grid | **1,618 ms** at a 1 s jitter buffer, and the buffer is a dial | 0 P2 violations at 481 ns ungroomed, over the internet (§3.1) |

**So conformance costs the media-aware lane an order of magnitude, and the cost has two identified parts,
neither of which is cushion depth.** About **650 ms is a named upstream regression** — the exporter PCR
fix that made an even grid possible moved delivery latency from 120.0 ms to 771.6 ms against the same
control on the same rig, and reproduced at 118 → 769 ms on a second platform against a build with no
output pacing in it at all, so it is positional clustering meeting a groomer rather than a pacing change
([T19](../lab/test-19-pcr-grid-verification.md) measurement 6). That part is a defect with an owner. The
remainder is the **peak-coded-frame buffer bound** — the contribution encoder's VBV occupancy, which the
source's byte spacing used to carry and which a demuxed lane cannot recover from decode timestamps
(§3.2) — and that part is structural to the lane.

**Two consequences for how these figures may be cited.** Against the other Internet-native plane MoQ's
advantage survives conformance at 3.8×, which is decisive for a route in the two-to-nine-second band.
Against the transparent tunnels it does not survive: their conformance is their source's and their
latency is the operator's dial. **No conformant sub-second configuration was produced on any lane in
this campaign**, so the sub-second band is not evidenced here — noting that no clean sub-second tunnel
cell was measured either, so the tunnels' conformant floor is inferred from their transparency rather
than measured at depth.

**Cushion depth is nevertheless not the variable** — the result in §3.2, and it holds in both directions.
MoQ's repetition failure was identical at every cushion, identical when starvation was removed, and
identical over the WAN (504 of 3,310 PCRs against loopback's 489 of 3,215). It was not a carriage defect
upstream of the groomer either: it was the groomer waiting for a spare slot that a burst never yields.
Reserving the slot clears it without buying depth.

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

### 3.12 Can an operations system tell that the feed has stopped while the transport is healthy? — Yes if it has stopped completely, and only from per-stream instrumentation if it has stopped partly

The failure a primary-distribution operator is least protected against is not a component dying — that
case closes a socket and something notices. It is every component still running, still connected, and
the programme off air. [T22](../lab/test-22-silent-media-plane-failure.md) induces exactly that with
`SIGSTOP`, so the process exists, its sockets stay open and its connection state is untouched, and
times each candidate detector from the **last advancing media** rather than from the injection — the
difference being the 1.8–1.9 s the buffer paid for.

**The transport never detects a stalled source.** With the source frozen for **120 s**, the publisher,
relay and exporter logged nothing at all: no error, no timeout, no reconnect. The 30 s and 120 s arms
agree, so this is not a race with the QUIC idle timeout — an idle stream is not an error, and a
monitoring design that alarms on session state or process liveness misses this failure entirely and
indefinitely.

**The media plane detects it in about one cushion, from two independent signals.** The groomer's
content-liveness alarm fired at **1.69–1.88 s** in every injected arm; PCR progression at the graded
output stopped within the 100 ms observation tick, its true floor being the 40 ms P1 repetition limit it
tests against. The control arm fired nothing.

**PCR progression fails on partial stalls** ([T24](../lab/test-24-partial-media-plane-stall.md)):
dead video behind a live mux passes **the entire TR 101 290 P1 set** — 0 CC, worst interval 30.080 ms,
identical to control. Stuffing ratio and underrun counters fire for video (**13.7 % → 95.2 %**,
406,850 underruns) but not for dead audio alone (27.0 % vs 27.1 % control — below mux variance).

**What detects every case is per-PID access-unit liveness** — counting access units per elementary
stream in media time. It found the video outage at 57.22 s and the AC-3 outage at 60.53 s, and fired
nothing on the control. That is the detector to specify, and the distinction that matters when
procuring monitoring is that per-PID *bitrate* inherits the same proportional-sensitivity problem: a
dead stream's PID bitrate goes to zero, but the service bitrate barely moves.

**That recommendation has since been built and run in the delivery path, and it holds**
([T27](../lab/test-27-liveness-detector.md), P1). T24 measured with an offline grader over a capture
on one host, which left open whether the fine structure a liveness detector needs survives a relay,
the exporter's PCR regeneration and a CBR groomer. It does, and the agreement is close enough to be
the result: the same 60 s video suppression measured **57.212 s** by a live detector at the groomed
output of a cross-host lane, against T24's **57.22 s** offline on loopback — different code,
different topology, three decimal places apart. **The media-aware lane therefore preserves the
evidence that the only sufficient detector depends on**, which it was under no obligation to do.

Operationally: the audio case — the one with no wire-observable signature at all — is caught and
localised to the PID within **0.7–1.4 s**, the video case within **1.24 s**, and 180 s of healthy
cross-host lane plus 300 s of healthy broadcast material produce **zero alarms**. Detection latency
equals the per-stream threshold, which the detector learns from observed cadence and states when it
arms, so it is knowable per stream before a fault occurs. Two qualifications carry: thresholds are
**wider at the groomed monitoring point than in a file** for the small streams — 1.0–3.1 s against
1.0–1.8 s for the same content — so the measurement point must be quoted with any latency figure;
and SCTE-35 and DVB subtitling have no intrinsic cadence and are reported as unmonitorable rather
than watched, which is a property of those streams and not of the lane.

**One failure mode is out of reach of all of it, and is not this architecture's problem.** An encoder
that keeps emitting *valid* access units carrying a frozen or looping picture advances PCR, PTS, DTS and
the continuity counters and holds its bitrate, so it defeats every detector above including per-stream
liveness. It is equally undetectable under opaque carriage or over SDI, because it can only be found by
decoding and comparing pictures. It is untested here and is stated as a limit of transport monitoring
in general.

**A frozen relay is the one case the transport eventually catches, 18× slower** — QUIC's idle timeout at
**34.3 s**, against 1.88 s for the media plane on the same run, and it took the egress chain down with
it.

**The groomer's stall policy decides whether the failure is silent downstream.** Under `mute` the
carrier stops 0.1 s after the programme does. Under `continue` the carrier **never stops**: byte-perfect
CBR, valid PCR, no programme, for as long as the source is gone. That is the default behaviour of any
pacer not told otherwise, and it converts a detectable failure into an undetectable one.

**Recovery is clean and is scored on media.** Media returned **0.02–1.02 s** after resume, stable within
0.92 s, and the programme clock skipped **exactly** the wall-clock outage in every arm (28,458 ms over
28.4 s; 119,365 ms over 119.3 s). The lane resumes at the live edge: it does not replay what it missed
and does not run late afterwards. For primary distribution that is the right behaviour, but it means the
programme lost is gone and the only mitigation is redundancy, not buffering.

With video dead for a minute, **audio, subtitles, SCTE-35 and PSI continued** and the carrier
held exact CBR — the lane degrades to the failed streams only (§3.1's demuxing objection does not
materialise). **`moq import ts` logs audio frame-sync loss but not video silence** — reported upstream.
The recurring asymmetry (also T21, T22): wire conformance and transport health are not sufficient;
per-stream liveness plus groomer counters are.

### 3.13 Which PCR timeline events does the lane survive? — All six placed classes, since #3375; but that fix stalls a *continuous* timeline whose content restarts

[T23](../lab/test-23-pcr-discontinuity-classes.md), P0/P2, software. Six arms, each placing exactly one
deliberate timeline event at 45 s of a 105 s run, graded at the source, after the round trip and after
grooming. The stimuli shift PTS and DTS as well as PCR, because the exporter schedules from media
timestamps; moving PCR alone exercises a path the lane does not use. Measured three times on the same
stimulus files and the same groomer `5ab84cd`, with the MoQ build as the only variable:
`f8236680b` (#3351, not #3375), `d88c2ee99` (contains `0e61e3520`, the #3375 merge) and current `main`
`fd4f5d82e` (contains the #3529 merge `d4b5349`).

| event | gap on `f8236680b` | **gap on `d88c2ee99`** | CC errors | drops | flag emitted | verdict now |
|---|---:|---:|---:|---:|---:|---|
| **33-bit base rollover** | 52 ms | **27 ms** | 0 | 0 | none, correctly | **clean, unchanged** |
| forward 30 s | 238 ms | **27 ms** | 0 | 0 | none on this build; **1 per rendition since #3529** | **clean, and now flagged** |
| backward 1 s | 268 ms | **26 ms** | 0 | 0 | 1 | **clean** |
| backward 600 s | ≥62,760 ms | **27 ms** | 0 | 0 | 1 | **clean** |
| encoder restart (backward 44.7 s + counter reset) | 44,049 ms | **37 ms** | 103 → **0** | 54,168 → **0** | 1 | **clean** |
| control | 26 ms | **27 ms** | 0 | 0 | none, correctly | clean |

**Every class the lane meets is now carried, and this campaign is why.**
[#3375](https://github.com/moq-dev/moq/pull/3375) opened citing these measurements, merged as
`0e61e3520` and closed #2833; re-running the arms unchanged against it puts all six at the control's
figure. The exporter follows the new timebase instead of waiting it out — arm B's export signals
−599.525 s against the source's −599.989 s, rate ratio 1.004 — and flags it on exactly the three
signalled arms while correctly leaving the rollover unflagged. On `d88c2ee99` the forward arm was the
fourth signalled event and the only one not flagged; #3529 closed that, and the rollover is still
correctly unflagged there. **The buffer requirement collapses with
the burst**: adaptive cushion 8,000 ms → 200–348 ms, high water 98,035 → 1,102–1,417 packets, which
discharges the *rewind × bitrate* provisioning rule the pre-fix build implied. **STRONGLY SUPPORTED**
for the six classes at this rig's scale; one run per arm per build.

**The same fix regresses the case none of these arms tests, and that is the more operationally
relevant one.** Every arm above places a *single* event in a *single* pass. Feed the fixed exporter a
source whose timeline is **continuous** and whose *content* restarts — what a real encoder emits —
and video and MPEG-1 audio stop at the first content join and never return, leaving only PSI, AC-3
and teletext at **0.31 Mb/s** against a 9.5 Mb/s source. Bisected over the 53 commits between the
build [T21](../lab/test-21-permanence-soak.md) soaked and the build under test to
**`0e61e35`, the #3375 merge itself**, and confirmed against its parent `025613d` with two replicates
per build sharing one publisher and one relay: parent 9.0–9.8 Mb/s across seven joins, #3375 0.31 Mb/s
from the first. The two builds carry disjoint cases — on a *true* rewind the parent stalls completely
(0.00 Mb/s) while #3375 sustains 8.66 Mb/s; on a continuous timeline the parent is clean and #3375
stalls. A per-PID liveness detector on both outputs at once shows the parent recording **0**
delivered-clock discontinuities where #3375 records **−119.35 s, one pass length**, so the rewind is
generated inside the recovery path rather than delivered to it. **The code path is named**:
`Track::admit` discards frames from any track left in an older generation unless they both change a
discontinuity counter and step backwards on that track's own timeline, and `rewind()` leaves every
track with a timeline behind on a backwards boundary — so one track's backwards step fences the
others permanently. A prediction from that reading was tested: a **video-only** source is clean on
both builds across five joins, because the fence needs a bystander. **The stall is permanent, not
slow recovery**: over 40 minutes and ~80 further joins the fenced subscriber's maximum sample is
exactly 0.31 Mb/s across 235 samples, against 9.52 Mb/s mean for the parent on the same publisher and
relay. P1, client-side, `[unmerged fix
absent — regression present in merged `main`]`. **Not a relay or carriage property**: the relay served
a freshly joining subscriber perfectly (8.9 Mb/s) while 60 incumbents were stuck, at 0.54 of 2 cores.
Ready to report upstream; see [T27](../lab/test-27-liveness-detector.md) and
[upstream contributions](../lab/upstream-contributions.md).

**The mandatory event is discharged.** The 33-bit PCR base wraps every 26.51 h in every conformant
stream, unconditionally, and was the one timeline event a permanent feed cannot avoid. Placed rather
than waited for, it crosses at all three points as a **30.080 ms step in modulo arithmetic** — the same
as the worst normal interval in the same stream — with 6,259 PCRs OK at ±500 ns absolute and zero
continuity errors. Nothing sets `discontinuity_indicator`, correctly. **PROVEN, and the rollover no
longer qualifies the permanence claim.**

On pre-`0e61e3520` builds, rewinds cost their own duration linearly (1 s → 268 ms … 44.7 s →
44,049 ms) via monotonic scheduling — **PROVEN**; #3375 removes the burst. **`discontinuity_indicator`**
now emits on rewind classes ([#2833](https://github.com/moq-dev/moq/issues/2833)), and on the forward
jump too since [#3529](https://github.com/moq-dev/moq/pull/3529), which also reconstructs that jump to
within 11 ms of the source instead of 961 ms short — re-verified by re-running the arm on `fd4f5d82e`
(T23 § against #3529). Pre-fix, wire conformance missed a 62.8 s programme hole
(§3.12 asymmetry). T23 does not reproduce T21's counter degeneration — **UNRESOLVED** whether they
share a root cause.

### 3.14 Can one receiver degrade the others? — Not their media; the relay pays in memory, and the price is set by a knob

[T25](../lab/test-25-isolation-under-abuse.md), P1, software. Five arms and a control against a running
11 Mb/s feed on the 8-vCPU secondary, then four variants of the worst arm to attribute its cost. Every
abuser is something an ordinary client does by accident — a crashing receiver, a retry loop, a reader
whose disk filled — expressed through the shipped CLI. **Not a security assessment**, and none of it
generalises to a determined attacker.

**The media plane is isolated, in every arm.** The two well-behaved subscribers deliver within **8 KB
of the control across 198 MB** — a spread of 0.004 % — at **0 continuity errors** and no hole above
100 ms, including in the arm expected to be worst, a subscriber that stays connected and stops reading.
`accept_failures_total` and `accept_stalled_seconds` are **0 in every phase of every arm**, so the
relay never refused or delayed a connection either. Threads (9) and file descriptors (12–13) are flat
throughout: nothing accumulates handles.

**The cost lands entirely on relay memory, and it is large.** A subscription storm — 40 subscribers to
the feed the victims are already watching, killed and relaunched every 5 s — takes relay RSS from
**87 MB to 1.9 GB in 60 s**. Subscriptions to broadcasts that *do not exist* reach 903 MB, which is the
cheapest version available since it needs no knowledge of what the relay carries.

**Four variants say what that memory is, and the answer changes the conclusion.** Each holds the cell
identical and varies one thing:

| variant | abuse peak | what it eliminates |
|---|---:|---|
| storm, as specified | 1,911 MB | — |
| group cache capped at 256 MiB | **1,930 MB** | **not cached payload** — the relay's only documented memory bound does not cover it |
| same 42 subscribers **held**, not churned | **144 MB** | **not concurrency** — 28× less for the same audience |
| QUIC idle timeout 30 s → 10 s | **489 MB** | **it is retention** — 4.5× less growth for 3× less retention |

A subscriber killed without a `CONNECTION_CLOSE` cannot be distinguished from a silent one, so the
relay serves it until the idle timeout expires. At a 5 s churn period roughly **seven generations
coexist**, each still accruing media it will never deliver — ~44 MB per retained session against the
~37 MB that 30 s at 9.95 Mb/s implies. **A dead peer is not flow-controlled**, which is why one *live*
non-draining reader costs nothing measurable while 42 dead ones cost 1.8 GB.

**It is bounded and it is provisionable.** Four consecutive abuse cycles reach 1,911 → 1,949 → 1,955 →
1,959 MB: the first storm sets the high-water and the rest reuse it, so the exposure scales with peak
retained sessions rather than with how many storms arrive. Provision
`abandoned-session rate × idle timeout × media rate`, and treat `--server-quic-idle-timeout` as the
control — against the failover detection the 30 s default exists to provide
([T6](../lab/test-6-relay-resilience.md)).

**This narrows a claim the paper was making without evidence.** [Comparison](comparison.md) §2 holds
that a relay carrying per-subscription state is structurally more exposed than a cache serving
idempotent GETs. The exposure is real, reachable with the shipped CLI, and **confined to the relay's
own memory** — not to any other subscriber's stream. It also qualifies this campaign's own "relay
memory is not an audience term" ([T9](../lab/test-9-performance.md)): that holds for a *steady*
audience, confirmed here at 1.6 MB per held subscriber, and **the growth term is subscription lifetime
against churn rate**. The segmented lane's half of this is **not measured**, so no comparison is drawn.

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

**The 1+1 result is a software receiver.** Two concurrently live legs into a reference implementation of
the ST 2022-7 selection rules, not a hardware IRD's merge engine. The merge and injection matrix was
measured with both legs on one host, so its skew is injected rather than natural. The determinism
precondition has since been re-measured with no shared component at all — separate publisher, relay,
exporter and host across two availability zones — and holds byte-identically on a **single-track**
source. **On a multi-track mux over independent chains it does not** (75.56 %): the legs carry the same
packets in a different order, which is upstream's interleave rather than the groomer's placement. One
run per cell elsewhere in the matrix.

**The ST 2022-7 oracle is self-tested** (14 adversarial conditions, 53 assertions): eight match the
standard's requirements; one is unspecified; three are not modelled; one is a blind spot (intra-leg
payload change). It is **not offered as reference-compliant** — hardware decides that.

**The impairment cells are now substrate-matched; the rest of the segmented result is still
HTTP/1.1 over TCP.** [T20](../lab/test-20-segmented-http3.md) built an HTTP/3 acquisition path —
FFmpeg with `--enable-libcurl` against a libcurl carrying ngtcp2/nghttp3 and OpenSSL 3.5 native QUIC,
fetching from an nginx vhost with **no TCP listener** — and re-ran reordering, loss, outage and
capacity on it. Everything outside those cells (interop, economics, maturity, availability-window
behaviour, carriage fidelity) is a property of the object model and the specification and was not
re-measured, and the wire-cost figures for H3 and H2 remain labelled *derived* wherever they appear.

**Two limits of the H3 lane itself.** Its receiver is `ffmpeg -c copy -f mpegts`, which re-muxes: it
regenerates continuity counters and re-times PCR, so on the H3 and H1 arms **continuity and PCR grade
the receiver rather than the wire**, and a `cc_errors=0` there is true by construction. The
byte-faithful `tsp -I hls` receiver used for the carriage work cannot negotiate HTTP/3, so this lane
trades carriage fidelity for substrate reach, and a byte-faithful H3 receiver is not yet built. And a
per-packet impairment is still not a per-byte one: at matched MTU the QUIC arm sends ~1.5× the packets
of the TCP arm for the same media, a residual that runs against QUIC and that no setting in the rig
removes — far smaller than the 24× it replaced, but the reordering figures should be read as "same
shaper setting" rather than "same impairment".

**Impairment matrices are one run per condition**, on an over-provisioned path, with `netem` models
that approximate loss as Bernoulli where real loss is bursty and RTT-coupled, and whose "jitter"
reorders. The congestion-control experiment proper has all six conditions run, still at one replicate
per cell, and the aggregate reproduces only to about ±15 % — the same cell run twice returned 7.17 and
5.50 Mb/s — so a single cell is worth roughly one significant figure and no conclusion here rests on a
difference smaller than a third.

**The fan-out scaling model is cross-host, and confined to one region.** The per-subscriber costs and
the 124–139 figure were measured with the relay alone on its own instance and every subscriber on
another, so they price the NIC and congestion control doing real work — but across two availability
zones at a 0.72 ms round trip, which bounds relay capacity and says nothing about internet-scale
fan-out (§3.6). The **per-bitrate** CPU figures are the older co-resident rig and should not be used
for sizing.

**Two upstream defects block deployment on current `main` without pinning or patching.**
[#3375](https://github.com/moq-dev/moq/pull/3375) fixes placed PCR timeline events but **stalls video
and primary audio permanently** on a continuous timeline whose content restarts — bisected to that
merge ([T27](../lab/test-27-liveness-detector.md),
[upstream contributions](../lab/upstream-contributions.md)). Separately, **`moq import ts` grows
linearly at +2.83 MB/h** with no drawdown over 24 h ([T21](../lab/test-21-permanence-soak.md)),
failing permanence on that role alone.

**Some results rest on upstream code not yet uniformly on the release line.** Exporter
PCR fixes ([#2967](https://github.com/moq-dev/moq/pull/2967), [#3006](https://github.com/moq-dev/moq/pull/3006),
[#3351](https://github.com/moq-dev/moq/pull/3351)) are merged; [#3375](https://github.com/moq-dev/moq/pull/3375)
is merged with a regression on continuous content-restart timelines (§3.13). SI carriage — EIT and the
clock — is `[dev]` until the branch converges with `main`.

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

**Row 1 was the precondition for row 2 and it is now discharged.** Both lanes produce a wire that passes
in software, so hardware time would no longer be spent confirming a known failure: **the hardware
verdict is the top open question outright**, and the two arms are equally ready for it (§3.2).

| # | Question | Blocked on | What it moves |
|---|---|---|---|
| 1 | ~~**Would an evenly spaced exporter PCR cadence clear the P1 repetition gate on the MoQ lane?**~~ (§3.2) | **Answered — no, and the gate is now met by another route.** Closed by [T19](../lab/test-19-pcr-grid-verification.md) measurements 10 and 11 | The cadence question is settled negatively: all three exporter domains are fixed upstream ([#2967](https://github.com/moq-dev/moq/pull/2967) values, [#3006](https://github.com/moq-dev/moq/pull/3006) release timing, [#3351](https://github.com/moq-dev/moq/pull/3351) byte position — adjacency 0 %, p95 release error 1.70 ms) and the wire still carried **12.2 % of intervals above 40 ms**, because a coded frame's bytes belong to its own 40 ms and the CBR mux schedule that used to smooth them is not in the decode timestamps. **What clears the gate is downstream and unrelated to cadence** — the three groomer fixes in §3.2, which hold on every source and at every cushion tested |
| 2 | **Does groomed output pass TR 101 290 P1/P2 on real hardware IRDs, sustained, including ST 2022-7 under loss?** | A hardware IRD and analyser | Everything. Until it passes, the grooming design is structurally sound and file-validated, not broadcast-acceptable. **Both lanes are now ready for this test**, the media-aware one since [T19](../lab/test-19-pcr-grid-verification.md) measurement 11 |
| 2a | **Does [#3375](https://github.com/moq-dev/moq/pull/3375) ship without the continuous-timeline content-restart regression?** (§3.13) | Upstream fix or revert; deployment must pin or patch until then | A deployment on current `main` stalls video and primary audio permanently when content restarts on a continuous timeline — the operationally common case [T27](../lab/test-27-liveness-detector.md) bisected over 53 commits |
| 3 | **Does the latency ordering survive a lossy or long path?** | Impairment on the WAN legs, and a path with 80–150 ms of RTT | Both paths measured were healthy, so nothing exercised the recovery the point-to-point tunnels exist for — the case that should favour them. This is the arm that could change the ordering rather than confirm it |
| 4 | **Does a commercial ABR-to-TS gateway produce P1/P2-conformant output as the distributor's own edge stage?** | MEG- or TITAN-class hardware | Whether part of the broadcast-grade layer is purchasable on one data plane and not the other. It is also the only route to a low-latency TS-in-HLS receiver, and therefore the condition the segmented lane's route-level case rests on ([Comparison](comparison.md) §6.1) |
| 5 | **Can a CDN carry a multi-programme TS segment in practice?** | A CDN account and the MPTS fixture | The whole of MoQ's remaining carriage-fidelity advantage |
| 6 | **Do the groomer's correctness boundaries hold on hardware** — source-clock drift, mid-stream PID change, T-STD occupancy? | The hardware rig in row 2 | Whether software-validated steady-state conformance generalises. **Partially answered in software**: placed PCR discontinuity classes and 33-bit wrap pass ([T23](../lab/test-23-pcr-discontinuity-classes.md), [T21](../lab/test-21-permanence-soak.md)); drift and PID-change have fixtures only; T-STD occupancy unrooted |
| 7 | **Can a multi-track 1+1 pair be merged at the byte?** | **Nothing further to measure; the question is now upstream's to answer.** §3.4 settles path diversity above the egress — a single-track pair is byte-identical with fully independent publisher, relay, exporter and host — and locates the multi-track cause: `pick_next_track` orders by which track's frame arrived, not by the media timeline ([#2829](https://github.com/moq-dev/moq/issues/2829)) | [Architecture](architecture.md) §5.1's recommendation is no longer scoped to one host or to a shared upstream. It remains scoped to **single-track content**, and lifting that scope depends on an upstream fix rather than on further measurement here |
| 8 | **Which congestion controller suits a permanent fixed-rate trunk?** | Nothing, on the controller question or on C3. **C3's collapse is attributed in §3.3** — not the controller, not bufferbloat, but the subscriber's own release deadline. What remains is a sizing question: where the knee sits, and whether it tracks RTT, group duration or relay buffering | **Answered, and the answer is that the question was wrong**: three conditions produce three orders, and what governs the feed is the provisioning margin, the bottleneck queue discipline and the receiver's latency budget — each of which moves the outcome further than any controller choice. BBRv1 is the operational pick on the strength of C2 and a 14 h C6 soak (0 continuity errors, 0 respawns) |
| 9 | **What does the opaque lane cost on the wire, and does it survive a real path?** | Building the private lane in the measurement environment | Whether byte-verbatim carriage is a wash or a real cost against SRT |
| 10 | **How much of MoQ's carriage advantage survives a different source?** | Two more source profiles | The largest caveat on the deciding line of the cost model |
| 11 | **Does fixing the announce convention clear the pairings it blocks, and what are the three undiagnosed failures?** (§3.7) | Upstream adoption, and diagnosis | Relay portability, which underwrites the economic argument |
| 12 | **Does a real CDN edge change the segmented lane's loss curve?** (§3.3) | A tuned edge instead of one plain HTTP/1.1 origin | The completeness half is answered in §3.3: retry preserves *content* inside the availability window and not past it, and rate was never preserved (**0.17 of source at 8 % loss**). What remains is the origin: the one measured is the weakest form of the deployed one, and a CDN could plausibly move the loss curve. The substrate half is settled — row 18 — and it moves the curve substantially in the segmented lane's favour |
| 13 | ~~**Why does the media-aware lane cluster PCRs sub-millisecond?**~~ **Answered** (§3.2) | — | On reordered content the authored decode clock is a saw: each B-frame dipping below it was nudged exactly one 90 kHz tick — 11.1 µs — past the previous DTS, which is the measured median. Named in [#2967](https://github.com/moq-dev/moq/pull/2967) from the code rather than the distribution, and the guess in this row was wrong: it was not group-derived and shares no parameter with PSI density |
| 14 | **Does RIST actually beat SRT on a real path?** | One long WAN run | On loopback the two are indistinguishable within 6 ms; over the WAN RIST reads 262–333 ms lower but its cells had a rising trend and had not settled, so the gap is not yet a finding. The one place a real path may separate two protocols this campaign cannot otherwise tell apart |
| 15 | **Does the relay's year-scale extrapolation plateau?** (§3.6) | Longer soak or `/proc/pressure/memory` logged beside RSS | **Partially answered** — §3.6 records the logarithmic convergence [T21](../lab/test-21-permanence-soak.md) measured, and rules connection scaling out. Open: whether the extrapolated asymptote is observed or continues creeping |
| 16 | **What does the segmented lane cost to run?** (§3.6) | An nginx origin rather than a single-threaded reference server, and a soak | The cost comparison is currently one lane characterised for resources and one characterised only for bytes. Segmented carriage overhead is measured (1.036× source TS); its per-role CPU and memory, its fan-out knee and its stability over days are not. The origin is the role the whole commercial argument for this lane rests on, and the one measured is `python3 -m http.server` |
| 17 | **Should a recovered audio gap be signalled downstream, and should the continuity guard be the only check?** (§3.1) | Upstream design | Whether the ingest edge's absorption is observable |
| 17a | **`moq import ts` linear memory growth (+2.83 MB/h) — leak or cache?** (§3.6) | Upstream ([#3493](https://github.com/moq-dev/moq/issues/3493)); longer per-process soak | Permanence blocked on that role; ~7.5 months to exhaust a 15.3 GB host at current slope ([T21](../lab/test-21-permanence-soak.md)) |
| 18 | ~~**Does segmented HTTP keep its reordering advantage over HTTP/3?**~~ **Answered — no, and it never held it for the reason assumed** (§3.3) | — | Answered by [T20](../lab/test-20-segmented-http3.md), and **the advantage proved not to be a substrate effect at all**: re-run with packet sizes equalised it falls to **0.44 even on TCP**, because the original cell gave the segmented lane 34 kB packets against the media-aware lane's 931 B ones and `netem` reorders per packet. §3.3 carries the H3 figures and the loss and outage cells the substrate change wins the segmented lane instead. **The successor question** is not which lane is more robust but which failure mode a primary feed should prefer — lateness with recoverable objects, or bounded latency with discarded programme |

Protocols for the runnable ones are in [planned-experiments](../lab/planned-experiments.md).
