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

PCR jitter above 481 ns was zero on all nineteen cells. **Continuity was not**, and the column that
originally reported it as zero everywhere was an instrument defect rather than a measurement — the
matcher searched the plugin's output for the word "discontinuity", which it never prints (see the
Corrections). Re-graded from the same captured bytes:

| arm | 250 / 2000 ms | 500 / 4000 ms | 1000 / 8000 ms | 2000 ms |
|---|---|---|---|---|
| udp | 98 (442 pkts) | 91 (362) | 89 (380) | 92 (357) |
| srt | 102 (479) | 92 (375) | 90 (388) | 99 (419) |
| rist | 132 (672) | 83 (404) | 90 (386) | 100 (474) |
| **moq** | **0** | **0** | **0** | **0** |
| **hls** | **583 (3,962)** | **78 (555)** | **64 (443)** | — |

Two of these are attributable and two are not, and the difference matters more than the numbers.

**MoQ is the only arm that delivers the stream intact, and that is a real result** — QUIC is reliable
end to end, so nothing is lost between publisher and groomer. It also disposes of the obvious worry
about the tap: the capture socket is common to every arm, so an arm reading zero through it proves the
instrument is not the source of the others' losses.

**The segmented arm's continuity scales with cushion, and that is the starvation mechanism
[T13](test-13-downstream-grooming.md) isolated.** TCP delivers every byte, so the losses cannot be in
the lane; they are the groomer running dry between segment arrivals. 583 events at a 2000 ms cushion
against 2000 ms segments, falling to 64 by 8000 ms, is the same curve T13 measured directly (311
continuity errors at a 1 s cushion, 0 at 8 s). It is one more reading of the rule that a segmented
lane's cushion must exceed its segment period.

**The ~90-event floor on udp, srt and rist is not yet attributed, and the arms disagree with their own
premise.** Plain UDP losing ~380 packets in 90 s on loopback is unremarkable. SRT and RIST landing on
the *same* figure is not: both run a 1000 ms ARQ buffer whose purpose is to remove exactly this, and
[T15](test-15-point-to-point-cadence.md) and measurement 1 both treat them as lossless on a healthy
path. Only RIST explains itself — its receive log carries repeated `Rist data out fifo queue
overflow`, so that arm's loss is a receiver FIFO overrunning rather than the tunnel failing. SRT logs
nothing. Until a source-side capture is graded beside the egress on the same cell, these three figures
bound a rig artefact and a transport result together and should not be quoted as either.

None of this moves measurement 1–4's latency findings, which are timing rather than carriage, and none
of it moves the repetition column.

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
cushion, and depth does not move it.** 489–491 intervals above 40 ms out of ~3,250 PCRs in the 90 s
cell, with a 228.0 ms maximum that is identical to three
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

| cell | stuffing | underruns | `pcr_inserted` | latency median | settled | PCR > 40 ms | max |
|---|---|---|---|---|---|---|---|
| moq, 250 ms, 10 Mb/s | 4.1 % | 23,151 | **137** | 90 ms | 87 | 491 / 3215 | 228.0 ms |
| moq, 1000 ms, 10 Mb/s | 3.2 % | 18,070 | **103** | 126 ms | 87 | 489 / 3215 | 228.0 ms |
| moq, 1000 ms, 9.75 Mb/s | 0.8 % | 4,297 | **28** | 171 ms | 128 | 503 / 3140 | 233.9 ms |
| moq, 2000 ms, 9.75 Mb/s | **0.0 %** | **5** | **0** | 1027 ms | 824 | 502 / 3112 | 233.9 ms |

**Starvation was the cause of the drained cushion and is not the cause of the PCR failure.** Removing it
restores the cushion — latency now tracks the commanded depth, 824 ms settled at a 2000 ms cushion
against 90 ms before — while repetition does not improve at all: 502 against 491, and a *worse* maximum.

The `pcr_inserted` column is what closes the argument, and it closes it by *varying* rather than by
reading zero. This groomer places a PCR of its own only into a slot it was going to stuff anyway — a
deliberate design property, so that grooming never displaces content — so its insertion budget *is* the
rate surplus. Across the ladder that surplus falls from 4.1 % to 0.0 % and the insertions fall with it,
137 → 103 → 28 → 0, exactly as the mechanism predicts. **The violation count does not move: 491, 489,
503, 502.** The groomer was placing PCRs, at four different rates, and it made no difference to
conformance at any of them.

That is a stronger result than a groomer which placed none, and it says something the zero could not.
137 insertions cannot cover ~490 gaps, and they were never going to: a stuffing slot falls wherever the
carrier happens to run ahead of the content, which is uncorrelated with where the exporter left a gap.
Closing ~490 gaps from downstream needs enough surplus that spare slots land inside all of them — and
scaling from the measured 4.1 % → 137 puts that at a carrier running many times further above content
rate, which is [#1992](https://github.com/moq-dev/moq/pull/1992)'s abandoned first horn (~20 % empty
PCR-only windows) arrived at from the other direction. **So the division of labour is measured, not
argued: PCR placement is the exporter's, because buying it downstream costs the carrier efficiency the
downstream stage exists to provide.** This corroborates
[T13](test-13-downstream-grooming.md)'s observation that MoQ's egress arrives with intervals already
above 40 ms and a 319.9 ms maximum.

### Measurement 6 — the defect is the *spacing*, not the density, and three transparent lanes prove it

Everything above measures the exporter through a groomer, which is the deployable configuration but the
wrong instrument for asking what the exporter itself emits. [T8b](test-8b-congestion-control.md)'s
provisioned-path rig happens to supply the missing control: its MoQ arm writes `moq export ts` straight
to a file with **no pacer in the path**, and its SRT and segmented arms carry the *same clip* on the
*same PID* over transports already shown to be byte-transparent. So the source's own PCR train and the
exporter's can be read off the same source in the same session.

| lane | PCRs/s | median interval | < 1 ms | > 40 ms | > 100 ms | max |
|---|---:|---:|---:|---:|---:|---:|
| source via SRT | 40.9 | **24.648 ms** | 0.1 % | 4 | 0 | 74.1 ms |
| source via segmented (`tsp`) | 41.0 | **24.648 ms** | 0.0 % | **0** | 0 | **25.0 ms** |
| source via segmented (re-anchoring) | 41.0 | **24.648 ms** | 0.0 % | **0** | 0 | **25.0 ms** |
| MoQ export, CUBIC | 35.6 | **0.011 ms** | 85.2 % | 412 | 397 | 1200.0 ms |
| MoQ export, BBRv1 | 36.0 | **0.011 ms** | 85.3 % | 414 | 399 | 539.9 ms |
| MoQ export, BBRv2 | 31.3 | **0.011 ms** | 84.9 % | 375 | 361 | 1840.0 ms |

**The clip is conformant, comfortably, and the number of PCRs survives the round trip — only their
positions do not.** The source carries an evenly spaced PCR every 24.65 ms, and two independent
segmented readings confirm it end to end with a 25.0 ms maximum and *not one* interval above 40 ms. The
exporter emits 31–36 PCRs a second against the source's 41 — the same order, and well above the ~25/s
that a 40 ms ceiling arithmetically requires — but it places 85 % of them **within 11 µs of the one
before**, and then leaves gaps of 100 ms to 1.84 s. An even train goes in; the same quantity of PCRs
comes out in bursts.

**That vindicates how [#2937](https://github.com/moq-dev/moq/issues/2937) was filed and condemns how this
repository has been summarising it.** The issue itself says "it is not sparsity", reports the mean
conserved to 0.7 ms, and asks for PCR-bearing packets "at a bounded interval" — all correct. But the
shorthand that spread through `docs/` and the other lab files was "the exporter emits PCRs too rarely"
and "a denser cadence would clear the gate", and that is false: adding PCRs to a stream whose median
inter-PCR gap is already 11 µs puts them inside the existing clusters, where they are redundant, and does
nothing to the 100 ms–1.8 s holes that are the actual violations. **The correct phrasing throughout is
placement, never rate.** The exporter attaches its PCR to the
adaptation field of the *first TS packet of each PES unit* and to no other packet
(`rs/moq-mux/src/container/ts/export.rs`, the `first && (unit.is_pcr || unit.keyframe)` guard), so PCR
cadence is a side-effect of unit boundaries and unit ordering, and there is no interval-based insertion
path in the exporter at all. A stage that emits a PCR-bearing packet whenever the clock has advanced
past a threshold — the thing `mpegts-pacer` does downstream and can only do inside stuffing slots —
would remove the defect at source.

**Loss and clustering are distinguishable in this distribution, which is what makes it a usable
diagnostic.** T8b's `codel` cells put SRT through 22,365 continuity errors, and its PCR train degrades
to 538 intervals over 40 ms with a 296 ms maximum — but its *median* stays at 24.8 ms and its sub-1 ms
fraction stays at 0.0 %. Loss punches holes in an even train; the exporter re-bunches it. A single
"intervals over 40 ms" count cannot tell those apart, and this campaign has quoted that count for both.

The mechanism behind the sub-millisecond clusters is still not established. One PCR per PES unit on a
25 fps clip predicts a 40 ms cadence, not 36/s at 11 µs spacing, so unit ordering or the
`dts.unwrap_or(pts)` choice of clock is doing something the guard alone does not explain. That is the
next thing to read, and it needs the per-unit DTS sequence logged against packet position rather than
another distribution.

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
moves at all: MoQ's repetition failure is 504 and 505 intervals out of ~3,310 PCRs against loopback's
489–491 out of ~3,250, both in a 90 s cell, with the same ~200 ms maximum. **The defect isolated in measurement 4 is a property of the lane, not of the
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
conformance trade would be structural and would have to be priced into every recommendation. PCR
placement in the exporter is a bug with an owner: the lane already carries the clock, and measurement 6
shows it carries very nearly the right *number* of clock samples — 31–36 a second against the source's
41 — while putting 85 % of them within 11 µs of each other and leaving 100 ms–1.8 s holes between the
bursts. **The lane is not emitting the clock too rarely; it is emitting it all at once.** So the fix is
a placement rule rather than a rate: emit a PCR-bearing packet whenever the clock has advanced past a
threshold, independent of PES-unit boundaries, which is the ~25 ms even cadence the same clip already
shows on all three transparent lanes. Re-run this rig unaltered afterwards and the lane should pass at a
250 ms cushion, which is **127 ms of delivery latency**. That is the outcome the paper hopes for and has
never been able to claim, and it is still a prediction this experiment makes rather than tests.

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
link: the exporter emits very nearly the right number of PCRs and places them wrong, clustering 85 % of
them within 11 µs of each other and leaving the residue in 100 ms–1.8 s holes no downstream groomer can
fill (measurement 6).

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
instead where the exporter places PCR, and fixing that would let the lane pass the gate at the depth it
already runs at — which, measured across the internet, is 109 ms.

### Still open

| Cell | Needs |
|---|---|
| *Why* the exporter clusters PCRs | the per-unit DTS sequence logged against packet position. Measurement 6 locates *where* PCR is emitted (one adaptation field per PES unit, no interval path) and establishes that the source train is even and the density is preserved, so the cluster comes from unit ordering or from the `dts.unwrap_or(pts)` clock choice — but one PCR per unit on a 25 fps clip does not by itself predict 36/s at 11 µs spacing, so the mechanism is located, not explained |
| Whether an **evenly spaced** PCR cadence clears the gate | the exporter change, then this rig re-run unaltered. This is the prediction the experiment makes and does not test. [#2937](https://github.com/moq-dev/moq/issues/2937) asks for the right thing — a bounded *interval* — and measurement 6 adds the control that rules out the density reading of it, since 31–36 PCRs/s already exceeds the ~25/s the gate requires |
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

- **The continuity column read zero on all nineteen cells because its matcher could not match.** It
  counted lines of `tsp -P continuity` output containing the word "discontinuity". The plugin prints
  `* continuity: packet index: …, PID: …, missing 14 packets`, and emits that word only in its
  `--help`, so the count was structurally zero for every input including badly broken ones. Nothing
  in the output looked wrong: a conformance column of zeros on a healthy rig is exactly what one
  expects to see, which is why it survived a whole sweep. Re-graded from the same saved captures with
  a corrected matcher, five of the nineteen cells are still zero and fourteen are not, with the
  segmented arm posting 583 events at its shallowest cushion. **Method rule:** an instrument that
  reports the value you expect is not thereby working — before publishing a column of zeros or
  passes, feed it an input known to be bad and check that it says so. This defect was shared by six
  rigs across the campaign and is recorded in full in the [T5 Corrections](test-5-network-impairment.md).

**Believed: the MoQ lane's PCR failure was groomer starvation.** The groomer's `underruns` count equalled
its inserted nulls exactly, and the commanded carrier exceeded the lane's content rate by the same 3.2 %,
so starvation explained the numbers arithmetically. **True: starvation explains the drained cushion and
none of the PCR failure.** Rate-matching the carrier cut underruns from 18,070 to 5 and left repetition
at 502 violations. **Rule: when a groomer and its source could each explain a placement defect, the
groomer's own insertion counter decides it.**

**Believed: `pcr_inserted=0` was that counter's verdict.** It was read from the rate-matched cell — the
one cell in the ladder at **0.0 % stuffing**. This groomer inserts PCR only into slots it was already
going to stuff, so at 0.0 % stuffing it has no slots and the counter cannot read anything but zero. The
figure was quoted as proof the groomer could not help, when it was a measurement of the groomer having no
opportunity to try. **True: read across the ladder, the counter varies with the surplus — 137, 103, 28, 0
at 4.1 %, 3.2 %, 0.8 %, 0.0 % stuffing — while the violation count holds flat at 491, 489, 503, 502.**
The conclusion is unchanged and the evidence for it is now the opposite shape: the groomer *did* place
PCRs, at four different rates, and conformance did not move. **Rule: a counter reading zero in the one
configuration where the thing it counts is impossible is evidence about that configuration and about
nothing else. Before quoting a zero, vary the condition that makes the mechanism possible and check the
counter moves.**

**Believed: the exporter emits PCR too rarely, and the fix upstream is a denser cadence.** That was the
inference from a count of intervals above 40 ms, and it spread as shorthand through `docs/evidence.md`,
`docs/comparison.md`, `docs/architecture.md`, the top-level `README.md`, T13 and T16 — though *not* into
[#2937](https://github.com/moq-dev/moq/issues/2937) itself, which was filed correctly as a clustering
defect asking for a bounded interval. **True: the density is very nearly right and the spacing is
wrong.** Measured against the same clip carried transparently by three other lanes, the
exporter emits 31–36 PCRs a second where the source emits 41 and conformance needs ~25 — but with a
median interval of 11 µs, 85 % of intervals below 1 ms, and the violations concentrated in 100 ms–1.8 s
holes between bursts. A denser cadence would add PCRs inside the clusters and leave every violation in
place. **Rule: a threshold-crossing count summarises a distribution and can point at the opposite of its
cause. Before asking anyone to change a rate, plot the distribution of the intervals and check the mean
is actually deficient.** The only reason this surfaced is that an unrelated rig (T8b) happened to capture
the exporter with no groomer downstream and the same source on transparent lanes beside it — **so keep a
transparent-lane control in any rig that measures a conversion.** The narrower lesson is about
summarising: the upstream report was precise and the in-house paraphrase of it was not, which is the
direction of drift worth watching, because the paraphrase is what the rest of the repository then cites.

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
