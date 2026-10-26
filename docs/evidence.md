# Evidence: Method, Results and Limits

Status: working draft.
Layer: **cross-cutting** — the empirical basis for every claim in [Comparison](comparison.md),
[Architecture](architecture.md) and [Economics](economics.md).

This document is organised by **question**. Each subsection of §3 states the answer an operator would
act on, the finding with the conditions under which it holds, and the experiment behind it. The
experimental record — procedures, exact commands, full result tables, pass criteria fixed in advance,
and the corrections each experiment forced — is the laboratory notebook in [`lab/`](../lab/README.md).

**Conventions.** Every figure names its measurement point — *P0* source, *P1* captured file, *P2*
live wire — which are not the TR 101 290 priority sets of the same names
([Glossary](glossary.md#broadcast-terms-used-without-definition)). **Nothing here is a hardware
result**; where file and wire differ, the domain is stated. A P2 PCR figure is read from a software
capture's bytes: it grades a real-time stage's multiplex, not when its packets left the host, which
only a result marked *on arrivals* grades. **`[unmerged]`** marks evidence against
upstream code that had not merged when it was measured. Single-run matrices establish mechanism and
ordering, not distributions. **Upstream builds are named by the version they report and when they
were built**: *moq 0.12.1* is a `main` build at or just after that release, and *upstream `main`,
October 2026* a build newer than the latest release. The commit behind each result is in its
experiment file.

**Vocabulary.** The *media-aware lane* is upstream `moq-dev`'s MPEG-TS path: the *importer*
(`moq import ts`) demultiplexes the transport stream into MoQ tracks, a *relay* forwards them, and the
*exporter* (`moq export ts`) re-multiplexes them at the subscriber. The *groomer* rebuilds CBR and PCR
cadence in front of the receiver. The *segmented lane* is HLS carrying MPEG-TS. MoQ and QUIC terms are
defined in broadcast terms in the [Glossary](glossary.md#moq).

---

## 1. What was measured, and on what

| Code base | Role here | Reach |
|---|---|---|
| **Upstream `moq-dev`, media-aware lane** | The preferred path, and the lane almost every result was measured on | The public internet, through an AWS EC2 [relay](glossary.md#transport-and-deployment-terms) |
| **[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)** (public, ours) | The CBR/PCR [groomer](glossary.md#broadcast-terms-used-without-definition) for a VBR source, deliberately outside the transport; for a CBR source on the media-aware lane, the merged export is its own (§3.16) | Every lane |
| **Upstream `moq-dev`, whole-multiplex passthrough** (its export ours) | The opaque lane | **Loopback on one host; one live feed across hosts** |
| **TSDuck plugins** — `hls`, `srt`, `rist` | The alternative data planes, built from the tool used as the oracle throughout | Loopback and the public internet, from the same EC2 origin |

FFmpeg, GStreamer and [`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) are graded as
grooming and sending *stages*, not transports ([T13](../lab/test-13-downstream-grooming.md),
[T16](../lab/test-16-grooming-segmented-http.md)). The media-aware lane runs the moq-lite version
its build negotiates by default, 04 to 06 across the builds measured, with BBR set explicitly unless
an experiment says otherwise; the passthrough runs on the same builds and protocol.

### 1.1 Instruments, and what each cannot show

| Instrument | Used for | What it cannot show |
|---|---|---|
| TSDuck `analyze`, `continuity`, `pcrextract`, `pcrverify` | Structure, continuity, PCR interval and accuracy | Arrival: accuracy is the PCR against its byte position, the same on a file or a capture; on a byte-locked re-stamp that is its arithmetic, and off a constant rate it is undefined |
| `t13-cadence.py` | Burst size and gaps | Absolute rate on loopback; burst size and silence are structural |
| `t12-merge-oracle.py` and companions | ST 2022-7 merge, byte identity, skew | A hardware IRD's merge engine; the oracle is a self-tested reference implementation of the selection rules (§4) |
| `ts-tstd.py` | The 13818-1 T-STD per PID, calibrated per stream type and to the video's HRD, validated on a source that passes at exactly +0 ms. It agrees with upstream's independently written check on all 35 files of a cross-validation set ([T46](../lab/test-46-tstd-check-cross-validation.md), file domain) | A real decoder's tolerance: it grades the minimum buffers the standard guarantees. SCTE-35 and SI have no normative T-STD |
| `t18-latency.py` | Delivery latency on the PES PTS, source to groomed egress | Encoder and decoder delay, so not camera-to-display |
| `t6-hls-pull.py` | Segmented-lane failover from a client that retries | A player. It bounds what the protocol permits, because TSDuck and FFmpeg both abandon the stream at a failed playlist reload |
| `tc`/`netem` | Loss, delay, reordering, shaped bottlenecks | Real congestion: its loss is Bernoulli, its jitter reorders, and it does not deliver the commanded loss unless [segmentation offload](glossary.md#transport-and-deployment-terms) is off. Impairment figures carry the counted fraction, or are stated as commanded where §3.3 shows the counters cannot be trusted |
| Interop client ([`interop/`](../interop/README.md)), `compliance.py`, `cost-model.py` | Media-level relay carriage; structural checks; the economic model | Pacing; decoder acceptance; negotiated rates |

**Two rig properties recur**: a ratio computed across two captures is invalid unless both cover the
same media, and a control with the mechanism removed is worth more than a second run of the same arm.
These and the campaign's other measurement rules are in [`lab/method-notes.md`](../lab/method-notes.md).

### 1.2 The validation pyramid and the acceptance gates

Seven rungs, cheapest and most decisive first: media round-trip fidelity; integration through a cloud
relay; file-based conformance, which **does not prove hardware acceptance**; **hardware TR 101 290
conformance, the decisive rung**; non-ideal-source robustness, which surfaced every media-aware import
defect since fixed upstream; a redundancy drill; and the comparative lab against the alternative data
plane and SRT. **Gate 1, media fidelity, is met at P1** (§3.1). **Gate 2, hardware conformance, is
make-or-break and has not been attempted.** **Gate 3, resilience, is met in software against a
reference receiver** (§3.4).

---

## 2. Summary of what is and is not established

A signpost, not a substitute: every entry carries its qualifications in the section named, and every
"not established" entry recurs in §4 or §5.

| | Established | Not established | Where |
|---|---|---|---|
| **Carriage** | All three lanes carry a single-programme broadcast mux at 0 continuity errors, departing from verbatim differently: SRT on no criterion, segmented HTTP by one PAT/PMT pair per segment, the media-aware lane by PSI density and PCR spacing; the opaque lane, on `moq-dev`, is the source's bytes. A multi-programme mux is flattened up to moq 0.12.8 and split on later `main` into one broadcast per programme whose SI still describes the whole mux | Multi-programme carriage through a CDN; the opaque lane beyond one run per arm | §3.1 |
| **Timing** | Grooming restores PCR repetition **on the wire** on both lanes; on the media-aware lane 0 of 20,193 intervals above 40 ms over 300 s, and 0 over 24.01 h crossing the 33-bit rollover. Buffer depth was never the variable | Hardware; arrival at an IRD-facing output; beyond a day; a real encoder's timeline | §3.2 |
| **Buffer model** | **The media-aware lane's P1/P2-conformant wire fails the 13818-1 T-STD** on its packet order, on every build graded up to moq 0.13.0; the groomer cannot repair it, and a re-multiplexer does, live at 2,196.7 ms (moq 0.12.1, loopback). Upstream's fixed-delay export, merged on October 2026 `main`, keeps every track and buffer at 500 ms–1 s across hosts and at up to 2 % loss, its clock following a drifting source, but not over a whole capture at 500 ms; on arrivals its drift rate exceeds 0.075 Hz/s | Hardware; the re-multiplexer across hosts and for 1+1; another source profile | §3.16 |
| **Loss** | The congestion controller decides the result on both Internet-native lanes, and reordering does not separate them once substrate-matched. No controller recommendation is supportable. **Matched on measured latency and graded on content, SRT loses less programme than the media-aware lane across an outage, a killed publisher and a relay restarted without its reset key**, by a margin the build and QUIC's recovery and idle timeout set, and in every random-loss and deep-reorder stress cell but 5 % reorder, which costs neither. A relay keeping its reset key costs it less, at unmatched latency | The trunking knee; a real CDN edge or captured path; burst loss; SRT below ≈2 s under loss; segmented HTTP under loss off loopback | §3.3 |
| **Redundancy** | Stream-clocked groomers are byte-identical and hitless on **single-track** content with no shared component. On merged builds multi-track legs of one broadcast merge on the media-aware lane only co-started, behind the fixed-delay export merged on October 2026 `main`, on one host or two; its opt-in `--sync` mode merged a late leg only where the source carries an H.264 HRD. On the opaque lane a leg joining 8 s late merges. Relay source failover is not hitless on any build measured; on current `main` it is a marked programme switch, about one detection interval at a hard kill, and a relay lost under one importer skips 7 s unflagged. The segmented lane is hitless with no merge, given one feed and one naming scheme | A hardware merge; a late leg on a source without an HRD; a cross-host pair beyond 120 s; a distributed segment store | §3.4 |
| **Cost** | Wire on a 4.57 %-stuffed clip: MoQ 0.982×, SRT 1.037×, segmented HTTP 1.056× (derived); on a stuffing-free feed MoQ 1.033×, SRT 1.035×, opaque lane 1.054×. Fan-out is linear to a CPU collapse: 1.258 % of a core and 2.62 MB per subscriber on moq-relay 0.15.1 with GSO on; through a CDN-hosted relay, 32 subscribers of a 25 Mb/s feed on the media-aware lane, and 16 for 72 h at about two skips an hour each | A third source; fan-out beyond one relay; the opaque lane through that relay | §3.5, §3.6 |
| **Isolation** | An abusive receiver cannot reach another's media; the cost is relay memory, 87 MB → 1.9 GB in 60 s, set by abandoned-session retention. A static segmented origin has no such term | Adversarial abuse | §3.14 |
| **Availability** | With both upstream fixes 0 of 10 subscribers exited on an evicted group, against 4 of 15 without; consistent with the fix but not established by the count | What sets the rate | §3.15 |
| **Observability** | **The transport never detects a media-plane failure.** Per-PID access-unit liveness detects every case measured, live: 57.212 s against an offline 57.22 s; dead audio in 0.7–1.4 s | A frozen picture in valid access units | §3.12 |
| **Timeline events** | All five placed PCR events cross with no programme hole on the September 2026 builds measured. From moq 0.14.0 a backward step ends the import by design, and a supervisor's republish under a new epoch costs 3–4 s of programme per step and is not hitless for a 1+1 pair | Why the other five diverge; whether a real feed steps back, what a step costs a subscriber, and whether it is flagged | §3.13 |
| **Interop** | The opaque lane crosses seven of nine other relays intact after the join, and five for a late subscriber; an outside publisher's opaque TS crosses `moq-dev`'s relay only after a one-line fix | Why three relays never start a late subscriber | §3.7 |
| **Cadence, LL-HLS, entitlement** | Three structurally different hand-off classes; LL-HLS with TS parts publishes free and nothing free receives it; enforcement is exact and revocation a poll whose best worst case is about 1.7 s | A commercial ABR-to-TS receiver; entitlement across a mesh | §3.8–§3.10 |
| **Latency** | Where nothing is conformant MoQ crosses the internet in 109 ms against SRT's 1,618 and segmented HTTP's 4,067. **At P1/P2 conformance MoQ reads 2,447 ms and segmented HTTP 9,286 ms**; the tunnels carry their source's grid at a buffer the operator sets. At the buffer model MoQ presents at 2,196.7 ms through the re-multiplexer and 1,137 ms at a 1 s delay through the export, which sends ahead within the delay | Camera-to-display; lossy or long paths; **a sub-second configuration conformant over a whole capture, on any lane** | §3.11 |

---

## 3. Results by question

### 3.1 Does the transport carry a broadcast mux intact? — Yes on all three lanes, each departing from verbatim in a different direction; the opaque lane does not depart

**For an operator:** no lane is ruled out on content. SRT changes nothing; segmented HTTP adds a
PAT/PMT pair per segment; the media-aware lane loses the mux's timing, so it depends on the groomer of
§3.2.

**Over the public internet, by one instrument on one window** ([T4](../lab/test-4-remote-e2e-srt.md),
ungroomed): **byte-faithful SRT is transparent on every criterion** — 13 of 13 PIDs at their source
numbers, SDT, NIT, TDT/TOT, splice PIDs, stuffing, the source mux rate exactly (9,945,951 b/s), the
source PSI cadence and PCR grid, and every PCR within 481 ns of its byte position, the source's own
accuracy delivered intact. **The media-aware
lane is faithful to the mux as bytes and not as a timed object**: identity, PIDs, SI and splice
signalling survive; stuffing, PSI density (8.04 → 2.51 PAT/s, mean gap 124 → 399 ms against P1's
500 ms) and PCR spacing do not. Every elementary stream keeps its PID, `stream_type` and descriptors,
SCTE-35 included ([T2](../lab/test-2-media-aware-transparency.md), P1). The importer records the source
mux rate and the exporter pads to it, +0.36 % of the source (file domain, moq 0.11.2,
[T13](../lab/test-13-downstream-grooming.md)), which makes the P2 gate answerable on the ungroomed
egress: it fails, with 0 of 1,807 PCRs inside it.

**SI.** On per-table snapshot tracks the EIT's distinct sections equal the source's exactly across an
8-day EPG, sparse sub-tables included, bitrate-neutral, with a ~1 ms join
([T17](../lab/test-17-si-snapshot-tracks.md)). TDT/TOT is proxied byte-identically, but on the
deployed build it was re-emitted on the exporter's own 30 s grid and arrived **~14 s late**
([T15](../lab/test-15-point-to-point-cadence.md)); upstream has merged a fix this campaign has not
re-measured. **Non-ideal sources** cross — open-GOP video, one-byte audio damage at a cost of one 24 ms
frame, splices left as gaps — with three residuals: ~1/16 splices invisible to the continuity counter,
256 ms of good AC-3 lost per splice, and recovered gaps signalled nowhere (§5).

**A multi-programme mux** ([T10](../lab/test-10-mpts-multiservice.md); P1, file domain, one host) is
flattened by builds up to moq 0.12.8 into one PAT entry and one PMT, while SDT and EIT still list every
service. Upstream `main` from the end of September 2026 splits it instead, publishing each programme as
its own intact broadcast (four of four runs), with each SDT still listing every service. A multiplex
travels as N single-programme feeds, and reassembly is the receiver's job.

**Segmented HTTP is transparent to what a mux contains and not to when it was sent**
([T14](../lab/test-14-data-plane-comparison.md), [T3](../lab/test-3-opaque-transparency.md)). A
segment differs from the source in two packets, each in byte 3 alone — the continuity counters of the
PAT and PMT the segmenter injects — and across three clips it matches the opaque lane on content, CAT
and TDT/TOT included. The packager re-multiplexes and cuts by picture type
([T11](../lab/test-11-interop.md)), so the claim is **verbatim in payload, not as a mux**. The injected
pair costs predictable PCR accuracy: registered in advance and measured over a ~125 ms internet path,
exactly 1.00 pair per segment head and 302.148 µs against 302.4 µs predicted, with 0 violations at
500 µs. Groomed, it passes at 481 ns (§3.2).

**The opaque lane is byte-transparent on `moq-dev`** ([T48](../lab/test-48-passthrough-export.md);
P1 and P2, upstream `main`, October 2026; loopback on one dedicated host, two clips, 120 s at a 1 s
delay, one run each on two builds). Upstream's import publishes the whole multiplex as one track and
our export writes it back out: from the first released group each leg is the source's packets in
order, a leg joining 8 s late matches the first over their overlap, the strict T-STD verdict is the
source's (a pass on one clip, a fail on the other), and every PCR goes out within 2 ms of its
schedule. On a live 25 Mb/s contribution feed it holds across hosts (P1, one 150 s run per build at
a 2 s delay): a leg in another availability zone, one joining 8 s late and one over the internet are
each the hand-off capture's packets in order and identical to each other, every PCR within 2 ms.
Upstream's relay test holds the import byte-identical through a flagged 20 s forward jump but for
the break marker's sequence (P0, software, `moq-lite` 06 and `moq-transport` 14).

### 3.2 What does delivery do to the clock, and can it be repaired? — Yes, on both lanes and on the wire in software; the wire is not the file, and on the media-aware lane the repair costs latency

**For an operator:** put the groomer in front of every receiver fed by the media-aware lane. With it,
both lanes pass TR 101 290 PCR repetition in software at the socket, for a day on a synthetic source.
Size its buffer from the source's peak coded frame, not its bitrate; conformance costs this lane
latency (§3.11).

Bursty delivery changes when PCRs arrive; a byte-faithful lane keeps their values and positions, and
the media-aware lane's re-mux writes its own. Hardware IRDs lock a PLL to PCR and alarm when either
goes wrong — accepted practice, not observed here. **Ungroomed**, the re-mux's PCR values leave 0–26 %
of intervals above 40 ms depending on the source (P1, file;
[T2](../lab/test-2-media-aware-transparency.md), [T7](../lab/test-7-timing-integrity.md)), while the
opaque lane keeps the source's intervals on all five clips graded
([T3](../lab/test-3-opaque-transparency.md), §3.1), which puts the loss
in the re-mux and not in QUIC. The exporter now writes an exact 25 ms PCR grid with each PCR beside
the bytes it labels ([T13](../lab/test-13-downstream-grooming.md)); what the groomer rebuilds is the
clustering between slots and accuracy against a constant-rate model.

**Groomed, on the wire — the figure to quote** ([T19](../lab/test-19-pcr-grid-verification.md)
measurement 11): **0 of 20,193 PCR intervals above 40 ms over 300 s, worst 30.1 ms**, 0 continuity
errors, 0 drops, 0 underruns and exact 11 Mb/s CBR. It takes three groomer properties: the PCR slot is
reserved on its deadline rather than waited for (inside a burst no spare slot comes), the media rate is
a ratio of sums over 2 s, and release is closed on occupancy. **Cushion depth is not the variable**: an
eightfold ladder moved repetition not at all. T19's fourth criterion, no latency regression, is **not**
met: the passing arm delivers at 2,447 ms (§3.11). **Any "0 %" must name its domain** — a file grades
the stage run offline, and the same stage once passed on file and failed live; neither grades arrival.

**Over a day** ([T21](../lab/test-21-permanence-soak.md), moq 0.11.2 before its development line
merged): 24.01 h on a continuous timeline, 632,199,204 packets, 0 continuity errors, 0 intervals
above 40 ms (worst 30.08 ms), 0 underruns, 0 respawns, and the 33-bit rollover crossed in flight. The source replays a clip with clocks
advanced across joins, so the claim is a synthetic clock over repeating programme; resource behaviour
across builds is §3.6, and on an October 2026 build this source cannot run at all (§3.13).

**The buffer bound is the peak coded frame, not bitrate**: three sources at 9.5–9.9 Mb/s have peak
frames of 256, 1,826 and 4,562 packets, and 3.6× the peak frame's carriage duration sufficed on all
three where 2.5× did not. That is the encoder's VBV occupancy, moved downstream. **Off the shelf, behind
a MoQ egress nothing passes all four grooming criteria**; behind segmented HTTP,
`tsp -P pcradjust -P regulate -O ip` does ([T13](../lab/test-13-downstream-grooming.md)). **The segmented
lane reaches the same wire standard** — 0 intervals above 40 ms and 0 PCR violations at 481 ns over
2,496 PCRs ([T16](../lab/test-16-grooming-segmented-http.md)) — but there depth binds: at 1 s against
2 s segments it posts 311 continuity errors, and at 8 s none.

### 3.3 How does the transport behave under loss? — The controller decides it on every lane; once the lanes are substrate-matched, reordering does not separate them either; and matched with SRT on measured latency, the media-aware lane loses more across an outage, a killed publisher and a relay restarted without its reset key, by a margin the build and QUIC's recovery set, as in every stress cell but 5 % reorder

**For an operator:** on a lossy route the congestion controller and the QUIC stack decide what the
media-aware lane delivers. Pin the controller, because the default is backend-specific, and choose it
against the route's own conditions ([Architecture](architecture.md) §8.5); provisioning margin, queue
discipline and the receiver's latency budget then govern the feed.

**The controller, not the protocol** ([T8](../lab/test-8-srt-vs-moq.md); one run per condition on an
over-provisioned EC2-to-home path, so non-congestive impairment; the ordering is the result). Under
loss-based CUBIC the MoQ lane collapses at ≥ 2 % uniform loss (13 % delivered at 10 %), at 25 %
reordering and on a WAN profile, while SRT holds full rate; under BBRv1 on quinn it is byte-complete
through all three, on par with SRT. The noq stack's BBRv3 treats loss as congestion and collapses as
CUBIC does. The controller is sender-local, so it can be set on the lossy hop alone. **Against segmented
HTTP, loss does not separate the lanes** (one host, one shaper, controllers read back from the sockets):

| Commanded impairment | Segmented, **CUBIC** | Segmented, **BBR** | Media-aware, **CUBIC** | Media-aware, **BBR** |
|---|---|---|---|---|
| 1 % loss | 1.00 | **0.97** | 0.76 | **0.96** |
| 5 % loss | 0.59 | **0.97** | 0.17 | **0.96** |
| 10 % loss | 0.17 | **1.04** | 0.13 | **0.96** |

Across a row the controller decides; down a column the lanes match. **Reordering ranks controllers,
not lanes** ([T20](../lab/test-20-segmented-http3.md); P1, wire, loopback): with packet sizes equalised
and byte-faithful receivers, the segmented lane on HTTP/3 delivers 0.259–0.263 of control at 25 %
reordering (11 holes a cell, so void for carriage) whatever the controller, and the media-aware lane
0.000 on BBRv3 and 0.039 on CUBIC. On HTTP/3 the segmented lane loses nothing at ~20 % applied loss,
against 0.13 on TCP.

**Segmented HTTP fails late, then loses at the window edge** ([T5](../lab/test-5-network-impairment.md);
P1, loopback, one replicate, one HTTP/1.1 origin, loss as commanded). Inside the origin's availability
window it never corrupted what it delivered; past it the client re-anchors and leaves holes of 7.2 s,
24 s and 82 s — beyond about 20 % loss without a single error from the origin, and sized only by the
PCR interval, not the continuity counter. **The media-aware lane fails the other way**: it sheds whole
groups into a syntactically clean TS, so continuity count does not reveal its loss and delivered
bitrate does. Under over-subscription it delivers 45–81 % at 0 continuity errors where SRT keeps 90 % of
the bytes with 4,279 continuity errors ([T8b](../lab/test-8b-congestion-control.md)).

**No controller recommendation is supportable** ([T8b](../lab/test-8b-congestion-control.md); P1, one
replicate a cell, reproducing to ±15 %). Of six conditions, three rank the controllers in three orders:
a controller that yields to a full queue is right when the link is too small, wrong when a neighbour is
briefly busy, and irrelevant under an AQM. BBRv1 is the campaign's operational choice on the strength of
one condition and a 14 h soak at 0 continuity errors and 0 respawns, not of a ranking. What moves the
outcome further is an AQM (standing delay
554–584 ms → 100–119 ms for everything), the provisioning margin — **≥ 1.2× content rate for the
media-aware lane and ≥ 1.5× for a segmented one**, whose fetches are line-rate bursts — and the
receiver's budget. Two or three contended MoQ feeds at a 2 s budget deliver less in total than one
(9.44 Mb/s against 5.39 and 4.48 under CUBIC), not because of the controller or bufferbloat but because
each subscriber discards groups past its own deadline: widening `--latency-max` from 500 ms to 30 s
takes two flows from 4.29 to 10.35 Mb/s. **A trunk must be provisioned in latency as well as rate.**
A release delay does not substitute for the rate margin: with two or three feeds sharing a class at
0.8× their combined rate for 80 s, no `--delay` from 1 to 6 s brings any subscriber within 1 s of its
control at RTTs of 20 to 200 ms; each loses 14.0–21.9 s of video, and each second of delay buys back
about 0.6 s of picture for about 2 s of latency. Against a 5 s dip to 0.8×, a 6 s delay absorbs the
video at 200 ms RTT and none up to 6 s does at 20 ms; the bottleneck drops nothing, and on one build
of two audio is lost too. At 20 ms the relay abandons groups that outrun the subscription's delay
budget, all of the loss at 6 s and 71–84 % at 2 s; at 200 ms its queue rises to 0.40–0.96 s and
drains with at most 0.05 s abandoned
([T31](../lab/test-31-congestion-capacity-ladders.md); P1, `netns`/`cake`, three replicates, two
October 2026 builds, the relay's queue read from qlog at n = 2).

**Matched against SRT, graded on content** ([T28](../lab/test-28-failure-injection-matrix.md); P1, one
namespace path at 20 Mb/s and 100 ms RTT, so not cross-host; two to five replicates a cell; latency to
a file sink). **`--max-age` is a recovery allowance, not a latency setting**: a twelve-fold change
leaves delivered latency between 1.845 and 2.125 s with no trend, where SRT delivers its commanded
`--latency` to about a millisecond, so SRT was set to the MoQ lane's measured median. Under a 5 s
outage on moq 0.11.2 (noq), the MoQ lane loses 15.1–20.2 s of video across budgets of 0.5–6 s against
SRT's 5.0–5.4 s, and its delivery latency steps up with the allowance, beyond it, and does not come
back (±0.24 s over the following ~75 s) — a bounded-latency concern for [R4](problem.md) as much as
R5. The cost is the build's: the oldest build measured, moq 0.11.0, loses 4.8–8.5 s where every later
`--max-age` build, on either stack, loses 17–23 s at the same budget, and the step is not attributed.
**Behind the fixed-delay export merged on October 2026 `main`, matched at 2.2–11.9 s across delays of
1–6 s, SRT keeps its lead on every shape but 5 % reorder, and the MoQ lane's latency is back within
100 ms after every outage**. SRT loses 0–3.74 s of the outage, less as its latency rises, against
6.1–7.6 s; at 2 s, 70–80 % of the excess falls
between the link's return and the first delivered datagram, 2.4–2.5 s later, so SRT's lead there is
**QUIC's probe-timeout backoff**, not the lane (noq). Capped at one doubling (a lab switch), the lane
loses 4.9–6.1 s of a 5 s outage, but RFC 9002 requires the doubling, so a cap belongs only in a
provisioned-path profile. The default adopted instead, an early probe once the peer is heard again,
leaves 7.7–8.5 s (a later October 2026 `main`, three replicates): the rig drops only the relay's
direction, so that probe is spent inside the outage. Dropping both directions costs 6.1–12.6 s: the
first acknowledgement after it carries an RTT sample spanning the outage.
Under 5–10 %
random loss and 20 % reorder, stress cells rather than any route's model, SRT loses nothing against
30–40 s of 40. At 11.9 s SRT needs both ends' buffers
sized to its latency times the link rate, without which it fails even unimpaired; that column ran on
a second host of the same type. **A killed component costs each lane its liveness timer** (October
2026 `main`, matched at 3.8 s, 20 ms RTT, three replicates): a killed relay or publisher costs the
MoQ lane 12.0–14.2 s of video against SRT's 5.4–6.3 s, because each waits out QUIC's 10 s idle
timeout: a relay restarted with a new key cannot reset its predecessor's connections, and the
relay holds a dead publisher's session as long; a killed exporter costs it 3.9 s against SRT's 8.8 s.
**A relay keeping its reset key across the restart costs 4.2 s, less than SRT's 6.3 s**, since its
stateless resets end both clients' sessions within 3 s (the same build, at 2.3 s against SRT's 3.8 s,
so unmatched); the exporter still exits once. **On the `--max-age` builds, under sustained
5–10 % loss the stack decides**: SRT lost nothing
in twelve cells, the noq builds 23.4–33.6 s of 40, and the quinn builds 0.00–0.64 s at 5 %, because
BBRv1 does not treat loss as congestion (*reasoned*). **Under 20 % reorder every one, on both stacks,
loses 30.8–38.3 s of 60**, while SRT delivers every picture with 430–692 continuity errors in four of
six cells. On noq that is the stack's loss detection — every packet it declared lost was acknowledged
later, and relaxing both QUIC loss thresholds cuts the loss to 2.12–3.0 s. On quinn the default
thresholds' cost is the same detection, since no queue on the path drops a packet, and relaxing them
lets the window overrun the bottleneck, which then drops a third to two-fifths of what the relay
declares lost; the programme is not saved.
**An impairment figure on this lane must name its shape, build and
QUIC stack.**

**The segmented lane on the same shapes** ([T28](../lab/test-28-failure-injection-matrix.md),
[T31](../lab/test-31-congestion-capacity-ladders.md); P1, content-graded, one host). At loopback RTT it
returns bytes identical to control under 5–10 % loss and a 5 s outage, and is bounded by the origin's
retention: a 30 s outage costs 17.134 s. In the `netns`/`cake` rig at 100 ms RTT it loses less than the
MoQ lane on every capacity rung (2.4 s against 13–18 s at 0.9× for 60 s) — **but not at equal latency**,
running 21–22 s behind the live edge against MoQ's 2 s budget — and **under random loss it collapses**,
completing no fetch after two segments at 5 %, because nginx's QUIC sender is loss-based (*reasoned*).
"Loss is invisible" on this lane is a loopback result; the arm that would show it riding loss runs the
origin with BBR.

### 3.4 Can redundancy be made hitless? — Yes; on the media-aware lane it takes a reference receiver, on the segmented lane it does not

**For an operator:** on the media-aware lane, build hitless redundancy at the receiver — two legs into
an ST 2022-7 merge, each behind a stream-clocked groomer. Relay reselection is bounded by the idle
timeout and does not cover a clean exit. On the segmented lane a pair sharing one feed and one naming
scheme is hitless with no merge.

**At the transport.** Two subscribers of one broadcast produce byte-identical captures, the
publisher redials and re-announces, and two relays cluster. On builds from moq 0.12.1 the exporter
exits when its broadcast's last session drops, by upstream design, so a standing egress needs a
supervisor; with one, a 30 s outage costs 34.72 s of programme (P1, noq, one host;
[T6](../lab/test-6-relay-resilience.md), [T28](../lab/test-28-failure-injection-matrix.md)). On moq
0.14.0, **`--linger` lets it wait instead**: it resumed in-process, continuity-clean, across a relay
restart (a 12.13 s gap for a 3 s outage) and across 24 resumes over a publisher's clean end or
crash, each resume flagging the PCR discontinuity one to four times at the default `--max-age 500ms`
(P1, file domain, loopback, one relay, one run
per arm; [T13](../lab/test-13-downstream-grooming.md) § *Liveness*). **On later October 2026 `main`
the linger covers one publisher instance, and following any other is an explicit programme switch**
(`--stitch`: a new PMT, the break flagged on every PID). Without it a replacement ends the export at
once (7 of 7 runs, either protocol). With it the export resumed at every replacement in 6 of 7,
continuity-clean with one flag each and no late unit, in 3–6 s (10–13 s where it waited out a dead
moq-lite 06 session); in the seventh it exited on an `internal error` from a just-killed
replacement, taken for a refusal (P1, file domain, loopback, one relay,
one to four runs per arm; [T47](../lab/test-47-fixed-delay-export.md) § *Re-requests on `main`*). So
a standing egress keeps its supervisor as a backstop.

**Source failover across a relay mesh worked for a hard kill on the builds before the epoch, bounded by
detection and by the standby's lag** ([T6](../lab/test-6-relay-resilience.md); P1, two relays on one
host). A shared publisher identity declared two feeds interchangeable — `--hop` on those builds, a
shared `--epoch` on early October 2026 `main`, with which nothing failed over in the mesh: the
standby's relay asked it for its tracks once, before its PMT, and never again, so every subscriber on
both relays was silent from the failover on, without an error (10 of 10 runs, `moq-lite-07` on every
process).
Nothing downstream learns of a hard failure before the QUIC idle timeout, so the resume is at least
one timeout late: ~30 s at the builds' 30 s default, ~11 s at moq 0.14.0's 10 s. **The precondition is a common source**, and on moq 0.12.1 a standby that joined
mid-stream adds its group-numbering lag to the outage. On the `--hop` builds the standby relay's own
subscribers are lost at its arrival or at the failover, so on no build measured is mesh failover
reliable for every subscriber. **Continuity-clean is not hitless**: the outage is a
PCR/PTS discontinuity across a content hole. **A graceful exit is never reliably failed over** — the
relay propagates completion, or hands the exporter a standby behind its live edge, and the subscriber
ends either way — so failover covers host loss and not the commoner SIGTERM or rolling restart.

**On one relay a shared importer epoch removed the standby's arrival teardown but not the outage,
and upstream has since removed it** ([T6](../lab/test-6-relay-resilience.md) § *Single-relay
standby*, [T47](../lab/test-47-fixed-delay-export.md) § *Re-requests on `main`*; P1, loopback, one
host, two publishers of one forked feed, a 6 s idle timeout, one to three runs per arm). On
moq-lite 07 a hard kill moved a subscription to the standby with no error, but each importer numbered
its groups from its own start, so the continuation landed on different media: the export survived
where the standby had started later (3 of 3, and all 8 exports on later `main`), after a 3–6 s stall,
and aborted on a timestamp rewind in two of three where it had started earlier, and in one of two
with byte-identical inputs. A clean exit, switched 8–13 ms after the signal, ended an export in all 8
counted runs, 7 on the rewind; importers numbering every group by the shared catalog clock's second
kept both exporters in all 7 counted runs and 0 foreign packets in 12 passthrough captures, where
the stack without it repeated media in all 8, in a build upstream declined ([T51](../lab/test-51-same-epoch-groups.md); 3–4 counted runs per lane and build).
On the default 06 every failover is the exporter re-requesting; with `--stitch --linger` all four
exports took over the kill of the instance they followed after a 4–6 s stall, one flag each.
**On upstream's current model every importer takeover is a marked programme switch that the
demultiplexed export survives, and a relay lost under one importer is not seamless**
([T6](../lab/test-6-relay-resilience.md) § *Distinct epochs*; P1, file domain, loopback, October
2026 `main` with distinct epochs, a 6 s idle timeout, three runs per cell). Independent importers each mint their own
epoch, the relay serves the newest, and `export ts --stitch` marks a replacement with a new PMT
version and a flag on every PID; a shared epoch is kept for replicas of one publisher's bytes. With
two importers on one relay or across a two-relay mesh, every exporter survived every event in 24
runs: a hard kill of the serving importer cost 5.4–9.0 s, about one detection interval, and a clean
exit under 2 s; on moq-lite 07 a standby's start and each restart are switches of their own. With
`--passthrough`, which refuses `--stitch`, the serving importer's loss ends the exporter. One
importer reaching the exporters through two relays, on moq-lite 07, survived the serving relay's
loss with no error or flag, but skipped 7.02 s of programme in every run, at the default delay and at
10 s alike. Upstream traced two defects behind it, a cancelled group read as a cut and a resumed copy
discarding cached groups within its maximum age, and fixed both on later `main`; not re-measured.

**The segmented lane answers the other way, because its serving node holds no state**
([T6](../lab/test-6-relay-resilience.md); P0/P1, same clip and host):

| Question | Media-aware lane | Segmented lane |
|---|---|---|
| Serving node dies and returns | resumes across a **content hole** | **loses no content** — backlog refetched from the store |
| 1+1 source failover, hard kill | one idle timeout or more; hitless unreachable by reselection | **no measurable interruption**, 3/3 runs |
| Source exits gracefully | **not reliably failed over** | hitless; `EXT-X-ENDLIST` visible for 1.10 s |
| A misconfigured pair | refused, both torn down | **accepted silently** — ±20 s of repeated and skipped time, at 0 continuity errors |

The hitless result needs one source **and** one set of segment names, and its standby was always
co-started onto one filesystem. It is a protocol result: **neither TSDuck's HLS input nor FFmpeg's
demuxer survives an origin restart**; a purpose-written client showed it.

**On the media-aware lane the redundancy belongs at the receiver, and it is hitless**
([T12](../lab/test-12-dual-path-handoff.md), 42 cells, one run each). Two live legs into a reference
ST 2022-7 receiver lose **zero** packets across a total blackout of one leg, 1 % and 3 % loss, and
200 ms of differential delay, past a Class B receiver's 50 ms; a SIGTERM to one publisher is invisible
at the merge; skew tracks injected delay within 60 µs. What decides mergeability is how the egress is
produced: arrival-clocked
groomers never merge (30–53 %), one groomer duplicated to both paths merges but protects only the last
hop, and **stream-clocked groomers — placing each packet from the source PCR grid — are byte-identical
on every datagram, continuity counters included (46,778 of 46,778), on single-track content with
publisher, relay, exporter and host all independent across two availability zones.** A multi-track mux
over independent chains does not merge on the merged builds graded: each leg's exporter places a few
packets of its own, which shifts every later slot. What T12 establishes is PCR accuracy, from the
bytes, and mergeability, not PCR repetition: 1.4–1.6 % of intervals exceed 40 ms in every cell,
control included.

**Behind the fixed-delay export merged on October 2026 `main`, a co-started multi-track pair merges
at the byte** (P1, file domain, one host, one clip, one 146.9 s run;
[T13](../lab/test-13-downstream-grooming.md), [T47](../lab/test-47-fixed-delay-export.md)). That
export hands the groomer advancing PCR values and positions, so groomers behind two co-started
exporters emit the same seven-track bytes. The two exports are byte-identical before any groomer as
well, and so are two on two hosts in one region, through all 782,483 packets
of a 120 s run ([T45](../lab/test-45-live-tstd-remux.md); P1, wire, moq 0.14.2). That run ends
before either export's clock steers, so whether two hosts' steering keeps their PCR values equal
over hours is not measured. A pair 8 s apart does not merge without the `--sync` mode below.

**The export's opt-in `--sync` mode merged legs that joined apart or lost complementary content
only where the source carries an H.264 HRD** ([T50](../lab/test-50-deterministic-ts-legs.md); P1,
file domain, one clip, October 2026 `main`). Each group opened where the encoder's buffering period
says the one before has arrived, on a fixed per-PID packet grid: two legs joined 20 s apart agreed
on all 474,909 common positions, and two legs each stopped for 3 s merged to equal a third past its first second. On the
live feed, which declares no HRD, a leg joining 20 s late differed in video for 100.2 s at 30 Mb/s
and 13.6 s at 40 Mb/s (two hosts in one region, two runs). The design does not rely on the mode
([Architecture](architecture.md) §5).

**On the opaque lane a pair with one leg 8 s late merges hitlessly**, through the
join, 5 s blackouts of each leg in turn and one leg's export killed, once each leg's stream-clocked
groomer stays silent rather than send a datagram it cannot fill exactly; with the earlier groomer
every impaired cell lost packets ([T12](../lab/test-12-dual-path-handoff.md); P1, wire, one clip,
one host, one run per cell, October 2026 `main`). The export's media-time interleave falls back to arrival order under sustained
loss, which keeps its output at the mux rate at 10 % loss, though graded on content that output
carries 3–8 % of the video, and limits determinism to a clean path (moq 0.14.0,
[T8b](../lab/test-8b-congestion-control.md) § *C7*). **A groomer must also stop when its content
stops**: one that keeps emitting valid CBR with no programme defeats every receiver-side switch.

### 3.5 What does carriage cost on the wire? — Verbatim lanes 3–6 % over the source; the media-aware lane saves about the source's stuffing

**For an operator:** the media-aware lane undercuts a byte pipe by the null stuffing it declines to
carry, which the groomer regenerates, and by little more; quote the source's stuffing ratio with any
cost figure.

IP bytes per datagram on the sender's interface, two sources, each lane in one window (P1, wire, one
run per cell): the reference clip EC2 to home at ~25 ms RTT ([T9](../lab/test-9-performance.md)),
and the live feed across two EC2 zones ([T14](../lab/test-14-data-plane-comparison.md) § *On the live
feed's profile*):

| Data plane | Clip, 4.57 % nulls | Live feed, no nulls | Basis |
|---|---:|---:|---|
| **MoQ, media-aware, 1200 B** | **0.982×** | **1.033×** | measured |
| MoQ, media-aware, 1452 B (MTU discovery on) | 0.973× | — | measured |
| SRT, byte-verbatim | 1.037× | 1.035× | measured |
| MoQ, opaque lane | — | 1.054× | measured, per leg |
| **Segmented HTTP over HTTP/3, 1200 B** | **1.056×** | — | HTTP layer measured at 1.0006×; framing **derived** |
| Segmented HTTP over HTTP/2 on TCP+TLS, 1500 B | 1.029× | — | derived |

On the clip MoQ carries the service in **5.3 % less than SRT** (6.2 % with MTU discovery on, off by
default), 4.3 % counting the return path, and **~7.0 % less than segmented HTTP**, MTU-invariant. On
the feed it is level with SRT forward and dearer counting acknowledgements (1.0 % of the source rate
against 0.2 %). QUIC's framing at its default 1200 B datagram costs ~2 points more than SRT's,
mostly its mandatory 16-byte authentication tag (1.9 measured on the opaque lane); the media-aware
lane wins them back by not carrying TS packet headers, which the export regenerates. **Every
verbatim plane sits between 1.03× and 1.06× whatever its framing, and only declining stuffing gets
below that** — §3.1's fidelity result and this cost are one finding.

### 3.6 What does a relay cost to run? — Cheap and predictable, with one bounded memory cost

**For an operator:** size a relay on sessions and memory, not gigabits. CPU per subscriber is linear up
to a hard collapse, each carried channel holds its retention window in memory, and churn is priced by
the idle timeout (§3.14). Any capacity figure is a figure about a configuration.

**Fan-out is linear in subscribers up to the relay's CPU** — cross-host, the relay alone on one
instance, in one region at 0.72 ms RTT. On moq-relay 0.14.15 on quinn each subscriber costs **0.806 % of
a core, 1.39 MB and one full stream copy** (r² ≥ 0.998), giving **124–139 subscribers per core**, and
pinning the relay to one core moved its collapse to exactly the predicted point
([T26](../lab/test-26-cross-host-fanout.md), P0/P1). **On moq-relay 0.15.1 (noq) the slope is 1.258 %
of a core and 2.62 MB with GSO on**, 1.686 % with it off; with GSO off a 2-vCPU relay knees at about 100
subscribers (*measured*), and with it on at 127–159 (*extrapolated*)
([T43](../lab/test-43-fanout-current-build.md), P1). **Saturation is a collapse**: past the cliff
aggregate throughput falls (1,184 → 528 Mb/s) with nobody thinned in favour of another, so a relay
needs headroom and admission control. GSO alone cuts per-subscriber CPU by 25–29 %.

**Through a CDN-hosted relay of another implementation, across the internet, the media-aware lane
carried 32 subscribers of a 25 Mb/s live feed in full and degraded at 40**, what they received
levelling at 0.82–0.86 Gb/s under a quarter of the relay's policer while the subscriber host stayed under
30 % CPU and the publisher kept pace: the limit is the relay's or its egress path's. In its
three-minute steps no group was skipped through 16 subscribers and from 24 some were, which the
export fills with stuffing. **Held for 72 h at 16 subscribers, the lane passed its criteria, but each
subscriber skipped video about twice an hour** (116–169 skips, most of 320 ms; 11 reached at least
half the subscribers at once), unseen by the monitors because the export fills the span. Neither the
subscriber host, the probed path nor the relay's own counters account for them, so their cause is
not established ([T52](../lab/test-52-cdn-relay-fanout.md); P1, socket counters, moqx on draft 18,
one run each). The
opaque lane has no reproducible knee there: in three runs one or two sessions fell silent until
QUIC's idle timeout, at 2, 4 and 24 subscribers, with host and publisher undisturbed, and the
relay's refusal of the joining fetch costs the subscriber that opens a subscription its catalog.

**Memory.** Each carried 10 Mb/s channel adds about 2 % of a core and 60–69 MB, the relay's 30 s
default retention (T43); `--cache-duration 5s` cut twelve channels from 766.1 MB to 195.8 MB, so a
channel costs roughly 1.5 × bitrate × window (*derived*, one build). A subscriber process fills to
**~120 MB** on a logarithm and stays there ([T27](../lab/test-27-liveness-detector.md),
[T21](../lab/test-21-permanence-soak.md)), so a host aggregating many sessions is sized by memory before
CPU. **On quinn the relay also retains ~9 KiB per group ingested**, a QUIC library's per-stream slot
rather than anything in MoQ: flat in subscriber count, proportional to group rate, unbound by any cache
setting, and **plateauing softly at ~100 MB above baseline per publisher** after ~10,000 groups. Budget
~2–2.5× that ceiling per publisher: a 14 h soak converged on +200.5 MB and a 24 h one reached +242.6 MB
([T8b](../lab/test-8b-congestion-control.md), T21). A day-long noq relay reads flat.

**Over a day**, the importer on moq 0.11.2 grew linearly at +2.83 MB/h, failing T21's resource
criterion in that role; on moq 0.12.8 a 24.0 h re-soak passes every role, the importer at +0.23 MB/h
(P1, one host, one run each). **Over a week, on the live feed**, the standing chain on moq 0.14.2 (an
October 2026 `main`) ran 169 h unattended to an export on a second host across the public path, and
every role converged: the noq relay held 355–369 MB for the last 150 h, the importer 375–379 MB, and
each export took one ~42 MB heap step in its first day and then held, the fastest series +0.135 MB/h,
under the host's exhaustion rate of 1.60 MB/h. So the exporter's step is one per export, not one a day.
No unit restarted. One export ended at 99 h on a source-clock jump and was restarted within 1 s; the
exports' output had 0 continuity errors in 10.11 G packets, and every media-plane event, that end
included, traced to damage in the contribution upstream of SRT
([T21](../lab/test-21-permanence-soak.md#the-seven-day-live-arm-result), P1, one run). Its PCR
accuracy was graded at ±18.5 µs, not ±500 ns. *Except T26 and T43, these rigs are loopback with co-resident clients, pricing neither the NIC nor
congestion control; per-bitrate CPU figures from them are not for sizing.*

### 3.7 Does it interoperate? — Through seven of nine other relays after the join, and for a late subscriber through five

**For an operator:** another vendor's MoQ relay can carry this feed, but test its join first; relay
capacity is not yet a substitutable commodity.

The test is media-level — a 20 s transport stream whose own continuity counters and PSI/SI are the
oracle ([T11](../lab/test-11-interop.md); client public in [`interop/`](../interop/README.md)) — run
as the interop runner's two cases, a subscriber present from the start and one joining 8.5 s in, on
the opaque lane (P1, over the internet, one run per relay and two for imquic and red5, `moq-dev` from
October 2026 `main` at both ends). **Both cases pass through `moq-dev`'s relay, libquicr and moqx;
moxygen and Cloudflare start a subscriber at the next group, not the current one, and serve the late
one.** imquic and red5 lose packets after the join in both runs, imquic in a different pattern each
time. aiomoqt, moqtail and Nokia carry the stream from the next group but never deliver the catalog
to a late subscriber; a draft-22 framing ambiguity in the start filter would explain it,
though their side was not observed. Two further endpoints were unreachable. An older release carried
nothing through any relay but `moq-dev`'s, mainly because its publisher announced only when asked.

**The other direction**
([T11b](../lab/test-11-interop.md#t11b--openmoqs-msfts-publisher-through-a-moq-dev-relay); P1,
co-resident, file against file): OpenMOQ's MSFTS publisher (`moqxr` 0.4.4) through `moq-relay`
(upstream `main`, October 2026) delivers at most one object as released. **With a one-line publisher
fix, a 15 s broadcast clip crosses byte-exact on every elementary-stream PID**, but only on draft 18
over raw QUIC to an IETF subscriber; every other combination fails on the publisher side,
WebTransport fails on a parameter the relay omits, and the publisher's single unbounded group meets
the relay's per-group cap after about 27 s at 10 Mb/s. One relay is neutral at the byte toward one
outside publisher; the two do not interoperate as released.

### 3.8 How do the data planes compare on delivery cadence? — Three structurally different classes

**For an operator:** MoQ hands a groomer small bursts with short silences, SRT and RIST pass the source's
pacing through unchanged, and segmented HTTP delivers megabyte bursts separated by seconds of silence.

| Class | Granularity set by | Median burst | Largest gap | 10 ms peak/mean |
|---|---|---|---|---|
| **MoQ** | the object model — *re-paces* | 12.2–12.4 kB, whatever the source | 149 ms | 24× |
| **RIST / SRT** | the source — *transparent* | 30.6 kB, tracking the publisher | ~35 ms | 3.4× |
| **Segmented HTTP** | segment duration — *aggregates* | 2.95 MB at 2 s segments | 4.01 s | 231× |

Same clip and instrument, 1 ms burst threshold ([T14](../lab/test-14-data-plane-comparison.md),
[T15](../lab/test-15-point-to-point-cadence.md)). Segmented HTTP is **~240× coarser** and silent for
exactly a segment period. RIST and SRT match a plain-UDP control to three significant figures, so a
tunnel's 30.6 kB is this campaign's software pacer, and a tunnel cannot improve a bursty publisher. MoQ's
egress did not move when fed a source four times finer — which falsified the prediction that grooming
burden would rank inversely to scalability. The rankings disagree: MoQ has the smallest bursts and the
tunnels the shortest silences, and a groomer's buffer is sized by the first while its start gate is sized
by the second. *Loopback inflates burst rate; MoQ's median is threshold-sensitive, and the ordering holds
below a 2 ms threshold.*

### 3.9 Can low-latency HLS carry MPEG-TS in practice? — It can be published free, and nothing free receives it

**For an operator:** TS-in-HLS runs at classic HLS latency unless a commercial ABR-to-TS receiver is
bought.

Apple's `mediastreamsegmenter` emits conformant low-latency playlists of MPEG-TS parts of 0.28–0.30 s,
free and first time ([T14](../lab/test-14-data-plane-comparison.md)). **Both freely available clients
that turn HLS back into a transport stream fetched zero parts and made zero blocking reloads**, against a
static origin and Apple's own low-latency origin, while Apple's validator fetched 17–21 parts over the
same origins, so the gap is in the clients. TSDuck cannot see parts at all, and FFmpeg's demuxer exposes
no option for them. With parts, the median burst falls only from 2.95 MB to ~2.3 MB. **The practical
envelope for TS-in-HLS remains nearer 6 s than the 2–5 s the hold-back arithmetic implies, and the
reason is a market**: the missing stage is the receive stage commercial ABR-to-TS products sell. HLS's
ubiquity is therefore a delivery-path property, not a low-latency TS receive path
([Comparison](comparison.md) §6.1).

### 3.10 Is there a credible entitlement substrate? — Enforcement is measured and exact; revocation is a poll with a floor above the proposed target

**For an operator:** the relay enforces a licensing matrix exactly, but withdrawing a grant takes one to
two re-check cadences and never less than about a second, three plausible cache settings silently
disable it, and the revocable unit is the signing key, so provision one key per channel.

**Enforcement is exact** ([T36](../lab/test-36-entitlement-enforcement.md),
[T38](../lab/test-38-entitlement-estate.md), P2): eight refusing arms each delivered zero payload bytes
at the receiving endpoint, path matching is segment-aware, each affiliate is announced only what it
licenses, and seven credentials against four channels gave twenty-eight correct cells. One refusal path
leaves no relay log line, so a log-based audit would read nothing. **Revocation is a poll**
([T37](../lab/test-37-entitlement-revocation.md), P2): `max-age=0` — what an operator writes meaning "ask
every time" — a sub-second `max-age`, and an omitted `Cache-Control` each disable revalidation without
warning, leaving token expiry (honoured within 0.110 s) as the only bound; an authorization outage is
tolerated for an hour by default. With several sessions live, re-checks are served from a shared cache
and the *measured* worst case is **1.54 cadences**, against two *specified*; with a one-second cadence
floor, **the best achievable worst case is about 1.7 s measured and 2.11 s as documented**, so
[Control](control-plane.md) §8's sub-second target cannot be met. **The revocable unit is the key**:
withdrawing one of two channels sharing a key took the kept channel down for 2.78 s, and under a key per
channel it was untouched. Authorization adds nothing to the per-subscriber CPU slope at a ten-second
cadence and 27 % at one second. **A warning**: on the build measured, with client-certificate authentication
configured, a valid certificate and no token was served every channel, another broadcaster's included
(upstream's redesign since: [Control](control-plane.md) §3). **Across two implementations enforcement
transfers and the token does not** ([T53](../lab/test-53-token-interop.md), P2, loopback, one release
of each relay, drafts 16 and 18): `moq-relay` and moqx both refused everything outside a grant before
any payload byte and matched on path segments, but neither client carried the other relay's token
end to end. moqx's keys verify grants on any namespace of their service, its announcements follow a
separate discovery grant, and on v0.3.6 a live session outlives its token's expiry and a key is
withdrawn only by a restart that ends every session. **Unmeasured**: a mesh, a real rights system in place of the stub, and
rights windows.

### 3.11 How long does a picture take to cross each data plane? — MoQ by 15× where nothing is conformant, and by 3.8× over the other Internet-native plane where both are

**For an operator:** at the only configurations measured conformant, SRT and RIST deliver fastest,
because their latency is a jitter-buffer dial on the source's own grid; the media-aware lane beats
segmented HTTP but not the tunnels, and its far lower non-conformant figure is not a deployment latency.

Measured source to groomed egress on each picture's PTS, **every figure paired with the conformance of
the same bytes** ([T18](../lab/test-18-delivery-latency.md), P2; 90 s cells, an EC2 origin over a 12.8 ms
round trip). At each plane's shallowest runnable cushion **MoQ delivers in 109 ms, against SRT's
1,618 ms, RIST's 1,348 ms (unsettled) and segmented HTTP's 4,067 ms** — and no cell is P1/P2-conformant,
MoQ's posting 504 of 3,310 intervals above 40 ms. At the only configurations measured conformant:

| Plane | Conformant configuration | Delivery latency | Conformance measured |
|---|---|---|---|
| **MoQ, media-aware** | groomer reserves the PCR slot; buffer 3.6× the peak coded frame | **2,447 ms** | 0 / 20,193 intervals > 40 ms over 300 s; 0 over 24.01 h (§3.2) |
| **Segmented HTTP** | 8 s cushion, set by segment duration | **9,286 ms** | 2 intervals > 40 ms, 49.8 ms maximum |
| **SRT / RIST** | none needed — the egress carries the source's grid | **1,618 ms** at a 1 s jitter buffer, a dial | 0 P2 violations at 481 ns ungroomed (§3.1) |

**Conformance costs the media-aware lane an order of magnitude, in two parts, neither of them cushion
depth.** About **650 ms is a named upstream regression** — the exporter PCR change that made an even grid
possible moved latency from 120.0 to 771.6 ms against the same control
([T19](../lab/test-19-pcr-grid-verification.md) measurement 6) — and the rest is the peak-coded-frame
buffer bound, which is structural. **Against segmented HTTP the advantage survives at 3.8×**, decisive
for a route in the two-to-nine-second band; **against the tunnels it does not**, since their conformance
is their source's and their latency the operator's choice, the two agreeing within 6 ms.

**At the buffer model**, the 2,447 ms is a P1/P2 figure on a wire that fails 13818-1 (§3.16). The
lane's live configurations that pass it present **2,196.7 ms** behind the source through the
laboratory re-multiplexer (moq 0.12.1, loopback, two clips of one service), about 1.6 s of that the
lane's own transit and ordering, and **1,137 ms at a 1 s delay** and 2,176 ms at 2 s through
`main`'s export, which sends ahead within the delay, on a live 25 Mb/s feed (wire, loopback, one
280 s run each; its limits are §3.16's). Builds and metrics differ, so these do not rank against each other, and segmented HTTP's wire is
ungraded. **No configuration below one second has passed a whole capture on any lane**: the source's
own bytes over UDP through the stream-clocked groomer pass at 113.7 ms only after a damaged first 5
s, and over SRT at 234.0 ms one burst in 288 s went unrecovered
([T45](../lab/test-45-live-tstd-remux.md); loopback, one run each).

*Carried from source:* a commanded cushion is not the depth in force when the carrier outruns the
content; RIST's WAN cells had not settled; and no arm reached zero intervals above 40 ms on the WAN,
so this rig grades relative conformance reliably and absolute conformance only to within 12–21
marginal intervals.

### 3.12 Can an operations system tell that the feed has stopped while the transport is healthy? — Yes if it has stopped completely, and only from per-stream instrumentation if it has stopped partly

**For an operator:** session state, process liveness and the TR 101 290 P1 set do not catch a stalled
programme, and P1 misses a partial stall entirely. Specify per-PID access-unit liveness at the groomed
output, and do not leave the groomer to carry on at CBR when the programme stops.

**The transport never detects a stalled source**
([T22](../lab/test-22-silent-media-plane-failure.md), P2): with the source frozen for 120 s,
publisher, relay and exporter logged nothing, because an idle stream is not an error. The groomer's
content-liveness alarm fired at 1.69–1.88 s. **The segmented lane's transport is equally silent** —
200 to every request, bytes identical to control — but its playlist media sequence froze for 31.5 s
against a ≤ 3.1 s steady state, an alarm the media-aware lane has no counterpart for. **A partial
stall defeats P1** ([T24](../lab/test-24-partial-media-plane-stall.md)): dead video behind a live
mux passes the entire P1 set with a worst interval identical to control, and dead audio moves no
counter at all. **Per-PID access-unit liveness detects every case, and it runs live**
([T27](../lab/test-27-liveness-detector.md), P1): at the groomed output of a cross-host lane it
measured a 60 s video suppression at **57.212 s** against an offline 57.22 s, caught dead audio
within **0.7–1.4 s**, localised each to the PID, and fired nothing on healthy material. Its
thresholds are learned per stream and are wider at the groomed point than in a file; SCTE-35 and
subtitles have no cadence and are reported as unmonitorable. Per-PID *bitrate* is not a substitute.

**Out of reach of all of it**: an encoder emitting valid access units of a frozen picture, equally
undetectable over SDI and untested here. **The groomer's stall policy decides whether the failure is
silent downstream**: under `continue` it emits valid CBR with no programme indefinitely; under `mute` the
carrier stops 0.1 s after the programme. Recovery resumes at the live edge, the programme clock skipping
exactly the outage, so what was lost is gone and only redundancy mitigates it.

### 3.13 Which PCR timeline events does the lane survive? — All five placed classes on the September 2026 builds measured; from moq 0.14.0 a backward step ends the import by design

**For an operator:** on the builds measured in September 2026, a PCR base rollover, a forward jump,
a rewind and an encoder restart each cross the lane with no programme hole and no deep buffer.
**From moq 0.14.0 a backward timestamp step ends the import instead, flagged or not, on every stream
kind measured**, while a flagged forward jump still publishes; upstream has declined an in-process
restart, even for the flagged case. A source whose timeline steps back must then be republished at
each step, by a supervisor under a new epoch, or the build pinned. Each republish costs 3–4 s of
programme, and a 1+1 pair is not hitless across it, nor meant to be on this export. On a real feed
the standing import ended three times in about 19 h over a clean hand-off, two exits 3 min apart,
but none of the exits since captured with their source was a step: each was the import mis-stamping
a SCTE-35 cue, which current builds do not. **Whether a real feed steps back is not yet measured**
([T34](../lab/test-34-real-encoder-severity.md); P1, the import's log and the hand-off ring, one
feed, an October 2026 build).

[T23](../lab/test-23-pcr-discontinuity-classes.md) (P0/P2, software; one run per arm per build)
places one event at 45 s of a 105 s run, shifting PTS and DTS with PCR, and grades source, round
trip and groomed egress. On moq 0.10.0 the 33-bit rollover, a 30 s forward jump, 1 s and 600 s
rewinds and an encoder restart (a 44.7 s rewind with a counter reset) each leave a 26–37 ms
programme gap against the control's 27 ms, at 0 continuity errors and 0 drops, with the
discontinuity flag on every signalled event (the forward jump from moq 0.11.0) and none on the
rollover. A scheduler monotonic in media time would instead pay each rewind's duration as a hole,
and the buffer it needed falls from 8,000 ms to 200–348 ms. **STRONGLY SUPPORTED** at this rig's
scale. **The rollover, the one event a permanent feed cannot avoid, is discharged**: it crosses as a
30.080 ms step, the stream's own worst normal interval, with 6,259 PCRs inside ±500 ns.

**A continuous source is the other half** ([T40](../lab/test-40-continuous-join-through-srt.md),
[T41](../lab/test-41-import-reanchor-coverage.md); P1, wire, one host, one run per arm). A looping source
whose AC-3 and teletext timestamps step back at each content join stops the importer at the first join on
moq 0.11.2 and 0.12.1, is published through five joins on 0.12.8, and ends at the first unflagged wrap
from 0.14.0, by design. **No build measured carries both
a continuous restarting source and the current design**, so §3.2's day is not reproducible on an October
2026 build.

**Republishing at each backward step costs 3–4 s of programme, set by the export and the restarted importer's catalog, not the step**
([T41](../lab/test-41-import-reanchor-coverage.md) § *A flagged rewind carried as a new broadcast*;
P1, wire; moq 0.14.2, `moq-lite-07`, one host, one clip, a flagged 1 s or 600 s step, thirteen
runs). A supervisor restarted the import at the step under a fresh epoch; two co-started exports at
a 1 s delay followed with no unit missing either side of the break.
Pipe-fed, 2.9–3.0 s of programme was lost, for either step size; the export carried
the first post-step picture about 0.6 s beyond its steady latency. Later October 2026 builds hold a
restarted importer's catalog for its first mux-rate window and lose 3.8 s, 1.2 s of it to that hold
([T41](../lab/test-41-import-reanchor-coverage.md) § *Where the step's cost grew*; P1, wire, one
host, seven runs). Through an SRT gateway the first build lost
3.2–7.7 s, mostly latency the gateway path had built up before the step and the restart discarded.
**The two exports stayed byte-identical across the break in 8 of 13 runs.** The other five part
after it, by packetisation or one picture, breaking the packet identity an ST 2022-7 merge needs. The cause is not located; upstream holds the outcome by design, each export starting a fresh stream
after a replacement, with byte identity promised within one epoch only and identity across a
republish left to the whole-multiplex export, merged (§3.1) but not measured across one.

**A 1+1 ingest pair republished this way keeps both legs, but each export follows whichever leg
announced last** ([T41](../lab/test-41-import-reanchor-coverage.md) § *A 1+1 ingest pair whose
importers each mint an epoch*; P1, wire, later October 2026 `main` with `--stitch`, `moq-lite-07`, one
host, a flagged 1 s step, five runs and a single-importer control). Fed from one source, the legs
restart together and the step costs what the single importer's does, with one flagged break; with one leg
2 s behind, the export ends on the lagging leg and the step costs up to the skew more. Losing the leg
followed is a further switch, with about 1.1 s missing. Such a pair is two supervised feeds under one
name, not a hitless pair.

### 3.14 Can one receiver degrade the others? — Not their media; the relay pays in memory, and the price is set by a knob

**For an operator:** a misbehaving receiver cannot damage another subscriber's programme, but receivers
that crash or churn can drive relay memory into gigabytes. Size that exposure through the QUIC idle
timeout; a static segmented origin shows no such term.

[T25](../lab/test-25-isolation-under-abuse.md) (P1; accidental abuse through the shipped CLI, **not
a security assessment**). **The media plane is isolated in every arm**: well-behaved subscribers
deliver within **8 KB of control across 198 MB** at 0 continuity errors, and the relay never refuses
or delays a connection. **The cost lands on relay memory**: forty subscribers killed and relaunched
every 5 s take it from **87 MB to 1.9 GB in 60 s**. Capping the group cache leaves it there (1,930
MB), holding the same audience instead of churning it costs 144 MB, and cutting the idle timeout
from 30 s to 10 s cuts it to 489 MB — so **it is abandoned-session retention**: a peer killed
without closing is served, unflow- controlled, until the idle timeout. The first storm sets the
high-water mark. Provision `abandoned-session rate × idle timeout × media rate`, with
`--server-quic-idle-timeout` as the control, traded against the failover detection the same timeout
provides (§3.4); its default is 10 s from moq 0.14.0. **A static segmented origin has no such
term**: twelve abusers moved its working set by at most 0.6 MB, inside its own baseline drift, with
victim captures byte-identical (wire, P2) — a structural result scoped to a *static* origin.

### 3.15 Does the subscriber survive the loss it is designed to absorb? — With both upstream fixes none exited, consistent with the fix but not established by the count

**For an operator:** a subscriber that exits on a group it was designed to discard leaves a clean
capture and no programme; only process supervision detects it.

Through a congested bottleneck, 0 of 10 subscribers exited with both upstream fixes, against 4 of 15
on a build without them ([T8b](../lab/test-8b-congestion-control.md); P1, three flows, five
replicates). **The count is
consistent with the fix without establishing it**, since 0 of 10 is also what an unchanged build
produces most of the time; the conclusion rests on the closed code path, upstream's regression tests,
and a control that still provokes the failure
([upstream contributions](../lab/upstream-contributions.md)).

### 3.16 Is the media-aware lane's TS-out a conformant transport stream? — Not through a pacing groomer: its P1/P2-conformant wire fails the buffer model on the lane's packet order, which only a re-multiplexing stage repairs

**For an operator:** a P1/P2 pass on the media-aware lane does not make its output a conformant
transport stream, and the pacing groomer cannot close the remainder. For TS-out to an IRD the lane needs
a stage that re-multiplexes against the decoder model. A laboratory re-multiplexer does this live at
2.2 s of presentation latency, most of it set by the lane; upstream's fixed-delay export, merged in
October 2026, builds it into the subscriber and keeps every track and buffer on every join tried;
sending ahead within the delay, it presents about 1.1 s behind at a 1 s delay. Byte-faithful carriage keeps the model behind an edge stage that places
each packet on the source's PCR.

**The problem.** ISO/IEC 13818-1 defines conformance through the T-STD: every PID's bytes must fit a
512-byte transport buffer draining at a fixed rate, and then a decoder buffer that neither overflows nor
underflows. TR 101 290 P1/P2 does not grade it. The source multiplexer solved that schedule in its byte
positions; a lane that demultiplexes keeps the timestamps and discards the positions, so its subscriber
has to solve the schedule again.

**Measured** ([T44](../lab/test-44-tstd-grading.md); P1, wire, loopback, one clip, 300 s arms): four
media-aware configurations from moq 0.10.0 to 0.13.0, each reproducing its P1/P2 pass, against
byte-faithful SRT and UDP through the same groomer.

| | Source | MoQ, all four arms | SRT, arrival-clocked groomer | SRT or UDP, stream-clocked groomer |
|---|---|---|---|---|
| Video / MPEG-1 L2 / AC-3 transport buffer, packets overflowing | 0 / 0 / 0 | **4.2–4.6 % / 86 % / 92 %** | 0 / 0 / 0 | 0 / 0 / 0 |
| 2 s windows with a legal PCR offset for all buffers | all | **none** | all | all |
| Whole capture, all buffers at once | legal from +0 to +100 ms | **no legal offset** | **no legal offset** | **legal from +0 to +100 ms** |

**The failure is the lane's packet order, beyond any groomer that only paces and re-stamps.** The
four builds agree within 0.5 points on every transport buffer, no PCR offset touches a transport
buffer, and the audio decoder buffers are legal at no offset in any window. Byte-faithful input
through the same groomer passes every buffer in every 2 s window, and over a whole capture through
its stream-clocked mode, whose PCR does not drift against the PTS. Neither clock mode repairs the
lane, and nor does padding to the mux rate. The cause, read from the exporter's code: it writes one
whole frame at a time, so an audio peak is about 36 packets back to back into a buffer draining at 2
Mb/s.

**A re-multiplexer repairs it**, scheduling each slot of a constant-rate output to the earliest decode
deadline its buffers admit. Offline (file domain), from the lane's groomed egress on three builds, it
passes every buffer at 0.9–1.4 s of decoder delay, and from frame-granular source timing at 25 ms.
**Live** ([T45](../lab/test-45-live-tstd-remux.md); P1, wire, loopback, moq 0.12.1, two clips of one
service, one run each), on only what a subscriber has and with buffer parameters calibrated in advance,
it passes every buffer and P1/P2 over the whole capture, needing no source PCR. **It presents 2,196.7 ms
behind the source**: about 1.2 s is the lane's transit, about 0.4 s the exporter's ordering — each video
frame arrives at its own decode time with none of the source's pre-load (read from the code; 420 ms
measured) — and 0.6 s the re-multiplexer's lead. **600 ms is the lowest lead measured to pass**; 550, 500
and 400 ms fail the buffer model while still passing P1/P2, and a deployable lead must also cover the
lane's worst excursion. The second clip passes at 600 ms with more margin, though both are one encoder,
profile and rate.

**Upstream's fixed-delay export, merged on October 2026 `main`, carries every track conformantly on
every join tried, at 500 ms to 1 s** ([T47](../lab/test-47-fixed-delay-export.md); no parameter set
by hand; P1 and P2, wire; one clip; units counted per PID; on moq 0.14.2, eight joins spread across
a GOP, seven loss cells and two cross-host runs, and seven runs as merged). It anchors and steers
its release clock on the track sent latest. Every buffer passes in every window, `compliance.py`
passes, and every PCR is within ±500 ns — at 500 ms, 750 ms and 1 s on loopback, over 540 s at 1 s
with the output clock following the source to about 1.2 ppm, across hosts at 500 ms and 1 s, at
every join phase tried, and at 2 % loss at 1 s and 1 % at 500 ms. **Over 35 min at 1 s it stays
conformant on loopback and across hosts** (moq 0.14.2), through three joins of a source looped so
that each join passes the T-STD, with every unit of every track carried inside the run. Across
hosts, with the source paced 25 ppm fast, its clock follows the source at about its 0.075 Hz/s slew
limit, from 0 to +4.6 ppm over the run and inside 13818-1's 30 ppm, and presentation latency rises
31.8 ms as the gap closes; following 25 ppm fully would take about 2.5 h (derived). **Behind a
source 4 ppm fast it settles on the source's rate after about 100 min** (P1, wire; across hosts, 1
s, moq 0.14.2 with its steering logged, PCR arrivals tapped on both hosts; one 2 h run): its
estimate follows the source, and it first spends, at the slew limit and up to 5.3 ppm past the
source, the 10–12 ms of delay the lane gives back in the 20 s after the export anchors. Its clock
changes rate at the limit, but on arrivals the drift rate reaches 0.088 Hz/s between 600 s windows,
over 13818-1's 0.075 Hz/s: the export writes on a 1 ms timer, so the wire's phase moves in 1 ms
steps. **Its limits**: over 540 s at 500 ms it stops about 157 s in on the video's schedule, so 500
ms is not a working delay over a whole capture; **on a 25 ms path it stops between 2 % and 3 % loss
at 1 s, and between 1 % and 2 % at 500 ms**, skipping evicted groups and then exiting loud on a
missed deadline (at 500 ms and 2 % it runs the capture conformant but with units missing); on later
October 2026 `main` it follows another publisher instance only as a flagged programme switch (§3.4);
and where the multiplex runs faster than the video's Rx, it overruns the video's transport buffer on
88 of 943,296 video packets of a 25 Mb/s broadcast recording (peak 646 B against 512 B; P1, wire,
loopback, one 110 s cut, later October 2026 `main`), all in slots where the video is at its admission cap and four program-table packets lead it, which the interleave does not
spread ([T45](../lab/test-45-live-tstd-remux.md)). **Sending ahead within the delay, it presents
about 140–180 ms past it** at 1 s and 2 s (§3.11). At 500 ms **which track anchors its clock sets the figure**: on this
source AC-3 reads about 250 ms further behind its decode time than MP2, the next track, so a join
that hears it within the 1 s acquisition window presents about 250 ms later, though joins that
anchored elsewhere delivered every AC-3 unit at the same margins. Why AC-3 can go unheard for that
window is not located.

**The graders cannot see a missing track**, nor a system clock far off the source: both T-STD checks
and `pcrverify` passed outputs with either, and only counting each PID's units and fitting the output
clock catches them ([T47](../lab/test-47-fixed-delay-export.md)).

**Not established**: how a hardware IRD responds (**hardware: not run**); the re-multiplexer's clock
recovery across hosts, and the stream-only schedule 1+1 needs (§3.4); another source profile; the
decoded-picture buffer, which the grader does not model; and segmented HTTP's wire, *reasoned* to
behave as SRT's. The arms that settle it are a hardware IRD fed this wire and its rebuild, and the
re-multiplexer across hosts.

---

## 4. The limits of the evidence

Stated in one place, because the individual caveats understate their sum.

**No hardware.** Nothing has been fed to a hardware IRD or graded by a hardware TR 101 290 analyser.
Every conformance figure is graded from bytes, a file's or a socket capture's on a general-purpose OS,
or by a reference software receiver; where file and socket disagree (§3.2) the socket is closer to an
IRD and still is not one, and no figure grades arrival at an IRD's input. The make-or-break gate has
never been attempted.

**Delivery latency, not glass to glass, on healthy paths.** Encoder and decoder delay are unmeasured and
do not differ between planes, so the comparison holds while the total does not. Loopback has no RTT and
the WAN leg was 12.8 ms, so nothing exercised the recovery the tunnels exist for; a long (80–150 ms) or
lossy path could change the ordering.

**The opaque lane is one run per arm and build** — on `moq-dev`, five clips on loopback and one live
feed across hosts (§3.1).

**The data-plane comparison is single-route, single-clip and single-host.** The segmented arm of the
carriage, cadence and latency comparisons is one route, one clip and one run per leg on loopback, with
per-packet framing derived. Its impairment cells were re-measured on HTTP/3 through a byte-faithful
receiver, because the first HTTP/3 receiver re-multiplexed and graded itself — reporting 0 continuity
errors where ten packets had been excised ([T42](../lab/test-42-h3-receiver-fidelity.md)); everything
else on that lane is HTTP/1.1 over TCP. A per-packet impairment is not a per-byte one: at matched MTU
the QUIC arm sends ~1.5× the packets of the TCP arm.

**Impairment matrices are one run per condition** on `netem` models whose loss is Bernoulli and whose
jitter reorders, and the congestion aggregate reproduces only to about ±15 %.

**The 1+1 result is a software receiver**, with skew injected on one host; the determinism precondition
holds across two availability zones on single-track content only (§3.4). Only T12 merged RTP legs,
packetised by TSDuck or our groomer; the deterministic exports are transport-stream identity, which ST 2022-7
needs and does not test. The ST 2022-7 oracle is
self-tested against 14 adversarial conditions and 53 assertions — eight match the standard's
requirements, one is unspecified, three are not modelled, one is a blind spot — and is not offered as
reference-compliant.

**Fan-out is one relay in one region**: cross-host at 0.72 ms RTT, and through one CDN-hosted relay
across the internet; no multi-hop tree or edge fleet, so it bounds relay capacity and says nothing
about internet-scale fan-out (§3.6).

**The builds move faster than the evidence.** Most media-aware results were measured on September 2026
builds, moq 0.10.0 to 0.13.0. Upstream `main` changed materially in October 2026 — a fixed-delay export
that schedules the wire, an epoch-based publisher identity, a backward timestamp ending the import — and
results are on it only where stated. The permanence evidence is a week on moq 0.14.2 with the live feed,
for continuity and resources, and a day on moq 0.11.2 with a synthetic source, for PCR intervals; PCR
accuracy over days is ungraded (§5 row 14).

**No production relay cluster or federated mesh**: the resilience work is a two-relay lab.
**Reproducibility is partial**: the media-aware lane reproduces from public binaries, TSDuck and the
public groomer, the opaque lane from upstream `main`, while the IRD-facing egress
beyond grooming is private. **Large
artefacts are not committed**; the notebook records their identity and how to regenerate them.

---

## 5. Open questions, ranked

Ranked by how much a result would change the conclusions. **The hardware verdict is the top open question
outright**, since both lanes pass P1/P2 in software. On the media-aware lane, whose wire fails the T-STD
(§3.16), hardware would test how far receivers tolerate a known non-conformance, unless it is fed a
rebuild.

| # | Question | Blocked on | What it moves |
|---|---|---|---|
| 1 | **Does groomed output pass TR 101 290 P1/P2 on hardware IRDs, sustained, on its bytes and on its arrival over RTP, including ST 2022-7 under loss?** | A hardware IRD, an ST 2022-7 receiver and an analyser | Everything. Until it passes, the grooming design is software-validated, not broadcast-acceptable |
| 2 | **Can a live re-multiplexer keep the lane's wire T-STD-conformant across hosts, and for 1+1?** On one host it can; the merged export does across hosts and as a co-started pair (§3.4, §3.16) | A schedule computed from the stream alone; a source of another profile that passes the T-STD | Whether the lane serves TS-out to an IRD at conformance in a deployment |
| 3 | **Is upstream's merged fixed-delay export itself an acceptable conformant stage?** It carries every track conformantly for 35 min across hosts and settles on a drifting remote source, but its wire's drift rate exceeds 0.075 Hz/s, and 500 ms does not last a whole capture (§3.16) | A hardware IRD and analyser, for whether those steps matter | Whether the subscriber is itself the conformant stage, and at what latency |
| 4 | **Does the latency ordering survive a lossy or long path?** | Impairment on the WAN legs; 80–150 ms of RTT | The case that should favour the tunnels |
| 5 | **Does a commercial ABR-to-TS gateway produce P1/P2-conformant output as the distributor's edge stage?** | MEG- or TITAN-class hardware | The only route to a low-latency TS-in-HLS receiver ([Comparison](comparison.md) §6.1) |
| 6 | **Can a CDN carry a multi-programme TS segment in practice?** | A CDN account and the MPTS fixture | MoQ's remaining carriage-fidelity advantage |
| 7 | **Do the groomer's boundaries hold on hardware** — source-clock drift, mid-stream PID change? | The rig in row 1 | Whether software-validated conformance generalises; drift and PID change have fixtures only |
| 8 | **How large is a media-aware failover as a decoder sees it, and can it be brought under a second?** A hard-killed importer costs about one detection interval, a marked switch, and detection is bounded by the QUIC idle timeout; the decoder's freeze is not measured, nor the relay-loss case on the build that fixed it (§3.4) | A decoder-graded failover run across idle timeouts | Whether the media-aware lane's switched 1+1 is acceptable where a merge is not ([Architecture](architecture.md) §5) |
| 9 | **Where does a contended feed lose what a release delay does not cover under a sustained shortfall?** Not at the bottleneck, and not as a function of RTT; on a 5 s dip at 20 ms RTT, in the relay's abandonment of groups past the delay budget (§3.3) | The relay's queue read on the sustained rungs | Whether a delay, or only a rate margin, can protect N contended feeds |
| 10 | **How much of MoQ's carriage advantage survives a third source?** It is the source's stuffing on two (§3.5) | A third source profile | The largest caveat on the cost model's deciding line |
| 11 | **Why do three relays never start a late subscriber, and two lose media after the join?** (§3.7) | Those relays' own logs; the draft settling how the start filter is carried | Relay portability, which underwrites the economic argument |
| 12 | **What does a CDN edge, or an origin whose sender ignores random loss, deliver under loss at 100 ms RTT?** (§3.3) | A tuned edge, or the origin on BBR | The segmented lane's loss curve off loopback |
| 13 | **Does RIST beat SRT on a real path?** | One long WAN run | The one place a real path may separate two protocols this campaign cannot otherwise tell apart |
| 14 | **Is the export's PCR accurate to ±500 ns over days?** A week on the live feed passes continuity, attribution and resources in every role, but graded PCR at ±18.5 µs (§3.6) | A ≥ 72 h export graded at ±500 ns, best on hardware (row 1) | Whether the P2 accuracy that captures of minutes pass holds for a permanent feed (§3.16) |
| 15 | **What does the segmented lane cost to run?** (§3.6) | An nginx origin and a soak | Its per-role CPU, memory and fan-out knee; the origin measured is `python3 -m http.server` |
| 16 | **Should a recovered audio gap be signalled downstream?** (§3.1) | Upstream design | Upstream `main` now counts TR 101 290 errors at `moq import ts`, equal per PID to TSDuck's on a 72 s excerpt at P0 and P1, but signals nothing downstream and does not grade PCR accuracy ([upstream contributions](../lab/upstream-contributions.md)) |
Protocols for the runnable ones are in [planned-experiments](../lab/planned-experiments.md).
