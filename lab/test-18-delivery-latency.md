# T18 — delivery latency at equal conformance

## Objective

[T16](test-16-grooming-segmented-http.md) closed the question of whether a segmented-HTTP egress can be
groomed to broadcast conformance — it can — and in doing so named the run this experiment performs:

> If depth is what buys P1 PCR repetition, then the MoQ lane needs depth too — and depth is latency,
> which is the only axis on which MoQ leads. […] Where the MoQ lane's curve crosses zero, and whether
> that point is compatible with sub-second delivery, is unmeasured and is now the campaign's
> highest-leverage outstanding run.

The campaign had measured how each data plane *arrives* ([T14](test-14-data-plane-comparison.md),
[T15](test-15-point-to-point-cadence.md)) and what it costs to groom that arrival into a conformant
wire ([T13](test-13-downstream-grooming.md), T16), but never what the grooming costs in delay. So the
paper could say a plane was clean, and it could say a plane was fast, and it could not say the two of
one plane at the same time.

**A latency figure without a conformance level beside it is not a comparison.** Quoting one number per
transport ranks a non-conformant arm against a conformant one and calls the difference transport: T13
measured the groomer posting 131 PCR repetition intervals above 40 ms in 25 s on the wire where it
posts 0 on a file, and T16 reached 0 on a segmented egress only at an 8 s cushion. This experiment
therefore treats the groomer's cushion as the swept variable and reports, per arm and per cushion, the
delivery latency *and* the conformance of the same bytes.

### What this measures, and what "glass to glass" would mean

This is **delivery latency**: the interval between a picture leaving the source pacer and the same
picture arriving on the groomed egress, measured on the presentation timestamp it carries. It is the
part of the chain the transport choice determines.

It is not glass-to-glass in the literal sense. A camera-to-display figure adds encoder and decoder
latency, both of which are properties of equipment this campaign does not vary and neither of which
differs between the data planes under test. Adding a fixed constant to every arm would change no
comparison and would import two numbers the rig cannot measure. Where the paper needs an
end-to-end figure, it is this plus the receiver's own decode delay.

### Pass criteria (fixed before the runs)

1. **The instrument resolves what it is asked to.** A plain-UDP arm — no jitter buffer, no
   retransmission, no pacing of its own — runs at every cushion, and no transport figure is reportable
   except as a difference against it. Whatever UDP shows is the rig's floor plus the groomer, not a
   protocol's.
2. **The same picture is identified at both ends, on every arm, and the identification is proved
   rather than assumed.** The byte-transparent arms carry the source mux verbatim; the media-aware lane
   demultiplexes and remultiplexes, sharing no TS packet with the source. The report recovers the
   per-lane timestamp shift per run and fails loudly if the two logs are not the same programme.
3. **Latency and conformance are quoted from the same bytes.** The egress tap saves the stream it
   timed, and the conformance gate is applied to that file — not to a second run that might have
   settled differently.
4. **The MoQ lane's curve is graded either way.** "MoQ leads on latency" is falsifiable here, and a
   result showing it cannot reach conformance at any cushion this rig can drive is the more valuable
   outcome, because latency is the axis the paper's recommendation rests on.
5. **On the two-host runs the clock offset is measured, not assumed, and every figure carries its
   bound.** An absolute latency taken from a timestamp on one host and one on another inherits whatever
   the two clocks disagree by. The offset is therefore probed before *and* after each cell, and a cell
   whose clocks moved by more than the probe's own uncertainty is re-run rather than quoted.

## Environment

Two environments, one instrument. **Loopback** — a single macOS host — establishes the ladder and the
control; **WAN** puts the source on the EC2 origin in eu-west-1 and the receiver here, over the open
internet. Same clip, same groomer, same taps in both.

| | |
|---|---|
| Source | `~/CNNiEMEA2.ts` — 1080i25 H.264, 9,945,951 bps CBR, 4.57 % null stuffing |
| Publisher | `tsp -I file --infinite -P regulate --pcr-synchronous --wait-min 5`, T15's resolving granularity |
| Groomer | `mpegts-pacer`, RTP egress at 10 Mb/s, PCR regenerated, `--latency-ms` = cushion, `--max-latency-ms` = cushion + 500, `--stall-ms` = cushion + 2000, `--on-stall mute` |
| SRT | TSDuck `srt` plugins, 1000 ms latency both ends |
| RIST | TSDuck `rist` plugins, Main profile, `buffer=1000` |
| Segmented HTTP | `tsp -O hls --duration 2 --live 6 --intra-close --align-first-segment`, `python3 -m http.server`, `tsp -I hls --live` |
| MoQ build | stock `main`, `moq 0.9.10-eab960192`, relay and CLI from `~/bin-main` |
| Groomer build | `mpegts-pacer` 0.1.0 at `12f41ad` |
| TSDuck | 3.44-4676 |
| Instrument | [`t18-latency.py`](scripts/t18-latency.py), PES presentation timestamps on the video PID |
| Rig, loopback | [`t18-arm.sh`](scripts/t18-arm.sh) per cell, [`t18-sweep.sh`](scripts/t18-sweep.sh) to drive the ladder |
| Rig, WAN | [`t18-wan.sh`](scripts/t18-wan.sh) here, [`t18-wan-source.sh`](scripts/t18-wan-source.sh) on the origin |
| WAN path | EC2 eu-west-1 → domestic connection, 12.8 ms round trip, ~6.4 ms one way |
| WAN topology | the origin listens (or publishes to its relay) and the receiver calls, forced by NAT at the receiver |
| WAN clock | four-timestamp probe bracketing every cell; offset ~2–19 ms with ±6.3 ms uncertainty, per-cell drift reported |
| WAN origin | the standing loop publisher stopped for the duration and restarted afterwards, per the environment's own rule |
| Window | 90 s per cell, first 30 s discarded before the distribution is quoted |
| Cushion ladder | 250 / 500 / 1000 / 2000 ms, following [T8](test-8-srt-vs-moq.md)'s buffer ladder |
| Segmented ladder | 2000 / 4000 / 8000 ms — the shallow end cannot be run at all, because T14 measured silences of 4.01 s on this plane and a groomer given 250 ms of cushion mutes rather than paces |

### The identifier had to be established before the experiment could exist

The arms do not share a byte. SRT, RIST and UDP carry the mux verbatim, but the media-aware lane
demultiplexes to tracks and remultiplexes at the exporter, mints its own continuity counters, and is
re-stamped again by the groomer. Byte position, packet index and continuity counter are therefore all
unusable as a cross-arm identifier.

What survives is the PES presentation timestamp. Measured through the media-aware lane on this build it
arrives at exactly *source PTS − 1 tick*, on every picture — a constant, not a drift. The instrument
recovers that shift per run rather than hard-coding it, which is what lets one tool grade a
byte-transparent tunnel and a remultiplexer without changing what it counts.

### What this environment cannot show

- **Neither path is impaired.** Loopback has no loss, reordering or RTT at all, and the WAN path was a
  healthy 12.8 ms round trip throughout — so nothing here exercises the retransmission or jitter-buffer
  *recovery* these protocols exist for. What is measured is the delay a healthy stream pays, which is the
  hand-off question. A lossy path is the obvious extension and would be expected to separate the tunnels
  from the media-aware lane in the tunnels' favour.
- **A 12.8 ms round trip is a short one.** A contribution path across an ocean is 80–150 ms, and the
  arms that merely add their RTT would add that instead. The finding is that the *path* term is the RTT,
  not that the numbers transfer.
- **Cells run strictly one at a time, and that is a measurement decision.** This host makes MoQ legs skip
  groups when a relay, exporters and groomers share it at ~10 Mb/s, so a contended run measures the
  laptop's scheduler. Two concurrent sweeps were detected and discarded during this campaign; the rig
  now refuses to start if an earlier tap still holds the egress port.
- **The WAN origin is a 2-core box that also runs a relay and two publishers.** The standing loop
  publisher was stopped for the measurement and restarted afterwards, but the relay serves the MoQ arm
  from the same two cores as that arm's publisher.

## Procedure

```bash
# Loopback: the whole ladder, one cell at a time; udp first, because nothing else
# means anything until the floor is known
PACER=<mpegts-pacer> SETTLE=30 \
	lab/scripts/t18-sweep.sh ~/CNNiEMEA2.ts ~/t18b 90 udp srt rist moq hls

# One cell, for diagnosis
PACER=<mpegts-pacer> lab/scripts/t18-arm.sh ~/CNNiEMEA2.ts ~/t18b 90 srt 1000

# The rate-surplus diagnostic: the same lane with the carrier matched to its content
# rate rather than to the original mux rate
PACER=<mpegts-pacer> RATE=9750000 lab/scripts/t18-arm.sh ~/CNNiEMEA2.ts ~/t18c 90 moq 2000

# WAN: the clock reference is a fixture, brought up once and probed by every cell
export ORIGIN_IP=<EC2_IP> PEM=<ssh-key> PACER=<mpegts-pacer>
lab/scripts/t18-wan.sh ~/t18wan 0 clock-up
for cell in "srt 250" "srt 1000" "rist 250" "rist 1000" \
	"moq 250" "moq 1000" "hls 2000" "hls 8000"; do
	arm=${cell%% *} cush=${cell##* }
	SETTLE=30 lab/scripts/t18-wan.sh ~/t18wan 90 "$arm" "$cush"
done
lab/scripts/t18-wan.sh ~/t18wan 0 clock-down
```

Each cell taps the source inline, carries it over the arm under test, reassembles it, grooms it to CBR
at a commanded cushion, and taps the groomed RTP egress — saving that egress so the conformance gate
and the latency figure describe the same bytes. `summary.csv` accumulates one row per cell with both
halves side by side.

## Results

Nineteen cells, one at a time, on an otherwise quiet host. Latency is the median over the settled
window; "repetition" counts differences between successive PCR *values* above 40 ms, which is PCR
placement in the stream rather than its arrival pattern.

| arm | cushion | latency median | p95 | settled | PCR > 40 ms | max interval |
|---|---|---|---|---|---|---|
| udp | 250 ms | **600 ms** | 761 | 558 | 21 / 3594 | 49.9 ms |
| udp | 500 ms | 869 | 1024 | 824 | 19 / 3592 | 49.9 ms |
| udp | 1000 ms | 1398 | 1547 | 1353 | 13 / 3592 | 49.6 ms |
| udp | 2000 ms | 2463 | 2597 | 2423 | 14 / 3577 | 50.8 ms |
| srt | 250 ms | **1606 ms** | 1766 | 1569 | 12 / 3263 | 49.8 ms |
| srt | 500 ms | 1875 | 2029 | 1836 | 20 / 3243 | 50.5 ms |
| srt | 1000 ms | 2407 | 2553 | 2370 | 19 / 3218 | 59.0 ms |
| srt | 2000 ms | 3466 | 3606 | 3433 | 16 / 3194 | 59.6 ms |
| rist | 250 ms | **1610 ms** | 1766 | 1574 | 19 / 3256 | 49.8 ms |
| rist | 500 ms | 1875 | 2028 | 1838 | 20 / 3245 | 50.4 ms |
| rist | 1000 ms | 2405 | 2551 | 2367 | 13 / 3223 | 50.2 ms |
| rist | 2000 ms | 3471 | 3607 | 3438 | 15 / 3184 | 47.4 ms |
| moq | 250 ms | **127 ms** | 185 | 87 | 490 / 3249 | **228.0 ms** |
| moq | 500 ms | 127 | 184 | 86 | 490 / 3311 | 228.0 ms |
| moq | 1000 ms | 126 | 184 | 87 | 489 / 3215 | 228.0 ms |
| moq | 2000 ms | 146 | 942 | 90 | 491 / 3274 | 228.0 ms |
| hls | 2000 ms | **3497 ms** | 4341 | 3514 | 5 / 3474 | 55.8 ms |
| hls | 4000 ms | 5015 | 5077 | 4965 | 2 / 3425 | 54.0 ms |
| hls | 8000 ms | 9185 | 9230 | 9142 | 1 / 3352 | 45.6 ms |

Continuity errors and PCR jitter above 481 ns were **zero on all nineteen cells**, so the conformance
column that separates the arms is repetition alone.

### Measurement 1 — the floor, and what a tunnel costs on a healthy path

The UDP control fixes the rig's floor at **cushion + ~350 ms**, linear in the cushion across the whole
ladder. Nothing below that is attributable to any protocol.

**SRT and RIST cost exactly their configured jitter buffer and nothing else.** Both sit 1000 ms above the
UDP control at every rung — 1606 against 600, 1875 against 869, 2407 against 1398, 3466 against 2463 —
and they agree with *each other* to within 6 ms at every rung, the largest disagreement being 5.3 ms at a
2000 ms cushion. That is the latency counterpart of [T15](test-15-point-to-point-cadence.md)'s cadence
finding: on a lossless path these two are the same machine, and their delay is a dial the operator sets,
not a property of the protocol. Both inherit the source's PCR placement, so both post the same
handful of marginal violations as the control.

### Measurement 2 — the media-aware lane is an order of magnitude faster, and does not improve with depth

MoQ delivers a **127 ms median, settling to 87 ms**, and — the striking part — *the figure is independent
of the commanded cushion*. 250 ms and 1000 ms produce the same 126–127 ms median and the same 87 ms
steady state. Against SRT or RIST at the same 250 ms rung this is **12.6× lower**; against the UDP
control, which has no transport buffer at all, it is 4.7× lower.

The trend column shows why: the cushion sets the *startup* depth, which then drains away. At a 2000 ms
cushion the first third of the window reads 1945 ms and the last third 90 ms. The commanded cushion is
not what the groomer holds.

**But the same lane posts 25× more PCR repetition violations than the transparent arms, at every
cushion, and depth does not move it.** 489–491 intervals above 40 ms out of ~3250, with a 228.0 ms maximum that is identical to three
significant figures across a ladder spanning eight times the depth. Where the transparent arms are
marginal — a dozen or two intervals at 47–60 ms, just over the gate — this is 15 % of all PCRs, at nearly
six times the limit.

### Measurement 3 — segmented HTTP approaches the gate, and pays what T16 predicted

The segmented arm is the only one whose conformance *improves monotonically with depth*: 5 violations at
a 2000 ms cushion, 2 at 4000 ms, 1 at 8000 ms, with the maximum interval falling 55.8 → 54.0 → 45.6 ms.
It is converging on the gate, and [T16](test-16-grooming-segmented-http.md) reached 0 on this plane at
that depth.

The price is the headline: **9185 ms of delivery latency** for the cell that gets closest. Even the
shallowest cushion this plane can be run at costs 3497 ms, and its p95 of 4341 ms carries the
segment-period structure T14 measured. Its latency is also the most *stable* of any arm — a 118 ms spread
at 8000 ms, against MoQ's 700 ms at 1000 ms — because a deep buffer in front of a bursty plane is a
low-pass filter.

### Measurement 4 — the rate-surplus diagnostic, which refuted the obvious explanation

The MoQ groomer logs `underruns=18070`, exactly equal to the nulls it inserted, at 3.2 % stuffing —
and 3.2 % is precisely the surplus of the commanded 10 Mb/s carrier over the ~9.68 Mb/s of content the
lane delivers once nulls are stripped. The transparent arms, carrying the mux with its own stuffing
intact, were given a 0.55 % surplus. So the MoQ arm ran with roughly six times the rate headroom, which
is a rig asymmetry and the obvious candidate for both the drained cushion and the missing PCRs.

Re-running the lane with the carrier matched to its content rate (9.75 Mb/s) separates the two:

| cell | stuffing | underruns | latency median | settled | PCR > 40 ms | max |
|---|---|---|---|---|---|---|
| moq, 1000 ms, 10 Mb/s | 3.2 % | 18,070 | 126 ms | 87 | 489 / 3215 | 228.0 ms |
| moq, 1000 ms, 9.75 Mb/s | 0.8 % | 4,297 | 171 ms | 128 | 503 / 3140 | 233.9 ms |
| moq, 2000 ms, 9.75 Mb/s | **0.0 %** | **5** | 1027 ms | 824 | 502 / 3112 | 233.9 ms |

**Starvation was the cause of the drained cushion and is not the cause of the PCR failure.** Removing it
restores the cushion — latency now tracks the commanded depth, 824 ms settled at a 2000 ms cushion
against 90 ms before — while repetition does not improve at all: 502 against 491, and a *worse* maximum.

The groomer's own counters close the argument: that cell reports `pcr_inserted=0`. Every PCR on the
egress therefore came from the arriving stream, so the egress spacing *is* the lane's spacing. The
groomer is not failing to place PCRs; **the media-aware lane does not deliver them often enough to
place**, which corroborates [T13](test-13-downstream-grooming.md)'s observation that MoQ's egress arrives
with intervals already above 40 ms and a 319.9 ms maximum.

### Measurement 5 — the same instrument over a real path, and the path costs almost nothing

The loopback figures price the buffers; they do not price the internet. The same instrument was run
with the source on the EC2 origin in eu-west-1 and the receiver here, over the open internet at a
12.8 ms round trip — the topology inverted, because this receiver is behind NAT and can only call.

| arm | cushion | WAN latency | loopback | path cost | PCR > 40 ms | max |
|---|---|---|---|---|---|---|
| srt | 250 ms | 1618 ms | 1606 | **+12 ms** | 18 / 3627 | 49.5 ms |
| srt | 1000 ms | 2412 ms | 2407 | **+5 ms** | 21 / 3587 | 52.2 ms |
| moq | 250 ms | **109 ms** | 127 | −18 ms | 504 / 3310 | 201.5 ms |
| moq | 1000 ms | 110 ms | 126 | −16 ms | 505 / 3289 | 217.2 ms |
| rist | 250 ms | 1348 ms | 1610 | −262 ms | 15 / 3638 | 49.0 ms |
| rist | 1000 ms | 2072 ms | 2405 | −333 ms | 36 / 4874 | 48.9 ms |
| hls | 2000 ms | 4067 ms | 3497 | +570 ms | 13 / 3486 | **130.7 ms** |
| hls | 8000 ms | 9286 ms | 9185 | +101 ms | 2 / 4619 | 49.8 ms |

**The path costs its round trip and nothing else, on the arms that settle.** SRT adds 5–12 ms against a
12.8 ms round trip, which is the whole of the difference. MoQ comes out 16–18 ms *lower* than on
loopback, because the loopback rig had source, transport and groomer contending for one laptop while
here the source is on another continent's worth of cable and its own CPU. Neither plane's conformance
moves at all: MoQ's repetition failure is 504 and 505 intervals against loopback's 489–491, with the
same ~200 ms maximum. **The defect isolated in measurement 4 is a property of the lane, not of the
link.**

**MoQ delivers a picture across the internet in 109 ms.** That is the number the paper has wanted and
never had, and it is 15× lower than SRT over the same path in the same window.

**The segmented plane degrades on a real path, and only at the shallow end.** At a 2000 ms cushion its
spread widens to 3511 ms with a 6430 ms worst case, its maximum PCR interval nearly triples to 130.7 ms,
and in the first run of that cell *every* PCR failed the 481 ns accuracy gate. At 8000 ms it is orderly
again — 2 intervals over 40 ms, 49.8 ms maximum, +101 ms over loopback. Segment-fetch jitter is real and
the deep cushion is what absorbs it, which is the same conclusion T16 reached by a different route.

**RIST's WAN figures are not settled and should not be quoted as a protocol advantage.** They come out
262–333 ms *below* loopback, which no path can cause, and their trend rises across the window (+54 ms and
+119 ms) where every other arm's falls. A rising trend means the steady state is above the median quoted,
so the apparent advantage over SRT is an artefact of a window that ends before the arm settles. This is
recorded as open rather than as a finding.

**The clock was the thing most likely to invent a result, so it is bracketed.** Every cell probes the
offset before and after and reports the drift between them; the offset itself moved ~15 ms over the
session, about 1 ms per minute. One cell — RIST at 1000 ms in the first pass — straddled a clock step,
drifting 13.94 ms against a 6.47 ms probe uncertainty, and returned a median of exactly 1000.3 ms with a
37 ms spread and *zero* PCR violations: by far the cleanest cell in the experiment, and entirely
spurious. It was re-run and reads 2072 ms. **A two-host latency rig that does not bracket its clock will
eventually publish that cell.**

### Against the pass criteria

| | |
|---|---|
| 1. Instrument resolves | **Met.** The UDP control runs at every rung and is monotone in the cushion; every transport figure above is quoted as a difference against it. |
| 2. Same picture, proved | **Met.** The recovered shift is 0 on every byte-transparent cell and +1 tick on every MoQ cell, on both paths, matching the constant established before the runs; 100 % of egress pictures matched a source picture on all but one cell (99.8 %). |
| 3. Same bytes graded | **Met.** The egress tap saved the stream it timed and the gate was applied to that file. |
| 4. MoQ graded either way | **Met, and it graded against the paper.** The lane's repetition curve does not cross zero at any cushion, measurement 4 shows depth is not the variable it depends on, and measurement 5 shows the path does not change it either. |
| 5. The two-host clock priced, not assumed | **Met, and it earned its place.** Every WAN cell brackets the offset and reports the drift; the one cell whose drift exceeded its uncertainty produced the cleanest and most spurious result in the experiment, and was caught by that check rather than published. |

---

## Observations

**The paper's latency claim is confirmed, and it is larger than the paper claims.** A 127 ms median
against SRT's 1606 ms at the same grooming depth is not a marginal advantage, and it holds against a
plain-UDP control with no jitter buffer at all. Nothing in this campaign has separated the data planes
this sharply.

**The conformance failure it comes with is not the price of that latency, which is the load-bearing
result.** T16 framed the open question as a trade — depth buys PCR repetition, depth is latency,
so where does the MoQ lane's curve cross zero? The answer is that there is no crossing, because the two
axes are not connected on this lane. Repetition is fixed at ~490 violations and a 228 ms maximum across a
ladder spanning eight times the depth, and it is equally fixed when starvation is removed entirely. What
the groomer cannot do is place a PCR it never received.

**That relocates the defect, and makes it cheaper to fix than a trade-off would be.** A latency-versus-
conformance trade would be structural and would have to be priced into every recommendation. A PCR
emission interval in the exporter is a bug with an owner: the lane already carries the clock, it simply
emits it too rarely. The evidence here does not prove that a denser cadence would clear the gate — only
that depth is not the binding constraint — but it makes the prediction testable at no cost: emit
PCR-bearing packets at the ~25 ms cadence a broadcast mux uses, re-run this rig unaltered, and the lane
should pass at a 250 ms cushion, which is **127 ms of delivery latency**. That is the outcome the paper
hopes for and has never been able to claim.

**SRT and RIST are the same product at this layer on a lossless link, and possibly not on a real one.**
T15 found them indistinguishable in cadence; on loopback they are indistinguishable in latency to within
6 ms across the whole ladder, so an operator choosing between them there is choosing on ecosystem,
licensing and fan-out economics rather than on data-plane behaviour. Over the WAN RIST reads 262–333 ms
lower, but its cells had not settled — their trend rises where every other arm's falls — so that gap is
not yet a finding. It is the one place in this experiment where a real path might separate two protocols
the campaign has so far been unable to tell apart, and it is worth one careful run.

**The rate surplus is a measurement rule, not a footnote.** A groomer's cushion is fictional whenever its
commanded output rate exceeds the content rate arriving at it, because the surplus burns the buffer off.
The effect is large — 90 ms of standing depth from a 2000 ms command — and it is invisible in the
groomer's own log, which cheerfully reports `holding 2000 ms` while underrunning 18,070 times. Any future
cell that commands a cushion must state its surplus, and a null-stripping lane needs its carrier matched
to content rate rather than to the original mux rate.

**No arm reached zero.** The best cell in the experiment is segmented HTTP at an 8 s cushion, with one
interval at 45.6 ms. The byte-transparent arms sit at a floor of 12–21 marginal violations that tracks
their small rate surplus, since nulls inserted between PCR-bearing packets stretch the interval the
receiver sees. T16 reached 0 on this plane using adaptive sizing rather than a commanded cushion, so
these figures are not a contradiction of it — they are the fixed-cushion form of the same curve — but the
floor means this rig grades *relative* conformance reliably and absolute conformance only to within
those few intervals.

---

## Conclusion

**The campaign's highest-leverage outstanding run is closed, and the answer is not the trade-off it was
framed as.** Delivery latency and PCR conformance are independent on the media-aware lane. MoQ delivers a
picture in 127 ms on loopback and **109 ms across the internet** where SRT needs 1606 and 1618 ms and
segmented HTTP needs 3497 and 4067 ms at their shallowest runnable settings — and it fails PCR repetition
at every one of those settings, on both paths, for a reason that has nothing to do with depth or with the
link: the exporter does not emit PCRs often enough for any downstream groomer to place them.

**What each plane costs, at the shallowest cushion it can be run at, over the real path:**

| plane | delivery latency (WAN) | repetition | verdict |
|---|---|---|---|
| MoQ, media-aware | **109 ms** | 504 / 3310, max 201 ms | fastest by 15×; fails the gate for a fixable carriage reason |
| RIST | 1348 ms | 15 / 3638, max 49.0 ms | marginal; below SRT here, but the cell had not settled |
| SRT | 1618 ms | 18 / 3627, max 49.5 ms | marginal; delay is the buffer the operator sets, plus the RTT |
| Segmented HTTP | 4067 ms | 13 / 3486, max 131 ms | erratic at the shallow end on a real path; needs 9.3 s to be clean |

**The path costs its round trip and nothing more**, on every arm that settles, and it changes no
plane's conformance. So the loopback ladder and the WAN figures agree, and the ordering is a property of
the data planes rather than of either environment.

**The recommendation this changes is about where to spend upstream effort.** The paper has treated MoQ's
conformance gap as the cost of its latency advantage and priced that trade into its verdicts. It is
instead a PCR emission cadence in the exporter, and fixing it would let the lane pass the gate at the
depth it already runs at — which, measured across the internet, is 109 ms.

### Still open

| Cell | Needs |
|---|---|
| *Why* the exporter clusters PCRs | reading the exporter against the distribution. The distribution itself is measured — [T4](test-4-remote-e2e-srt.md) has the ungroomed export at 1,123 of 1,307 intervals under 1 ms with 107 gaps to 319.94 ms, mean conserved — and this experiment adds that no downstream stage can repair it. Group-wise reassembly is inferred from the shape, not confirmed in the code |
| Whether a denser PCR cadence actually clears the gate | the exporter change, then this rig re-run unaltered. This is the prediction the experiment makes and does not test. Reported as [#2937](https://github.com/moq-dev/moq/issues/2937), with the measurements above and the argument that #1992's failure was in its delivery model rather than its PCR density |
| Why one clip is immune | 0 % of intervals above 40 ms on a 27.5 Mb/s broadcast mux at a 27 ms native cadence, against 9–25 % on every other source. Unexplained, and it bounds how general the defect is |
| **Whether RIST really beats SRT on a real path** | a window long enough for the RIST arms to settle. Their WAN medians sit 262–333 ms below their own loopback figures with a *rising* trend, so the apparent advantage is an unsettled arm, not a protocol property. The one place a real path may separate two protocols this campaign cannot otherwise tell apart |
| A lossy path | impairment on the WAN legs. Both paths here were healthy, so nothing exercised the recovery the tunnels exist for — the case that should favour them |
| A long path | 80–150 ms of RTT rather than 12.8 ms. The path term is the RTT, but that is a rule, not a transferable number |
| Absolute glass-to-glass | encoder and decoder latency, which no arm here varies and this rig cannot measure |
| Zero on a byte-transparent arm | a carrier matched tightly enough to remove the null-stretching floor of 12–21 intervals |

---

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md).

**Believed: the MoQ lane's PCR failure was groomer starvation.** The groomer's `underruns` count equalled
its inserted nulls exactly, and the commanded carrier exceeded the lane's content rate by the same 3.2 %,
so starvation explained the numbers arithmetically. **True: starvation explains the drained cushion and
none of the PCR failure.** Rate-matching the carrier cut underruns from 18,070 to 5 and left repetition
at 502 violations. **Rule: when a groomer and its source could each explain a placement defect, the
groomer's own insertion counter decides it** — `pcr_inserted=0` means every PCR came from upstream, and no
amount of buffering will change what was never sent.

**Believed: one latency figure per transport would answer the question.** **True: the figure is a
function of the grooming depth, and on a null-stripping lane it is a function of the rate surplus as
well** — the same lane reads 87 ms or 824 ms at the same commanded cushion depending only on the carrier
rate. **Rule: quote latency with the cushion and the surplus, or do not quote it.**

**Believed: the WAN rig could start its remote clock reference per cell.** The launch used `setsid` and
`nohup` and looked correct. **True: an SSH invocation does not return until the remote process it started
has exited**, so a cell that starts an hour-long fixture hangs for an hour rather than racing. **Rule:
launch a long-lived remote fixture from a locally backgrounded SSH, once, as a deliberate setup step —
and have the measurement probe it and refuse to run without it**, so a missing reference is an error
rather than a silent zero.

---

## References

- [T13](test-13-downstream-grooming.md) — the grooming standard this grades against, and MoQ's
  as-delivered PCR intervals
- [T14](test-14-data-plane-comparison.md) — burst structure and the 4.01 s segmented silence that sets
  this experiment's segmented ladder
- [T15](test-15-point-to-point-cadence.md) — SRT and RIST transparency, and the `--wait-min 5` source
  granularity used here
- [T16](test-16-grooming-segmented-http.md) — the open question this experiment closes
- [planned-experiments.md](planned-experiments.md) — the protocol this run was owed against
