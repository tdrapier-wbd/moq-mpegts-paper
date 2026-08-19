# Specified but not yet executed

These protocols were designed as part of the campaign and are recorded here so an external engineer
can execute them reproducibly.

**This file holds only what is outstanding.** Everything measured lives in the per-test file it
belongs to; where an experiment is partly executed, the entry here is reduced to the *remaining*
conditions plus a pointer to the results. An entry is deleted once nothing of it is outstanding — a
to-do list that accumulates its own history stops being readable as a to-do list. Results,
corrections and the reasoning behind them belong in `test-*.md` and
[method-notes.md](method-notes.md).

**Ordered by leverage, not by convenience.** The first two entries would change the paper's
conclusions; the rest refine them.

Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
`INSTRUCTIONS.local.md`.

---

## The cushion sweep: does MoQ stay sub-second while reaching P1 on the wire? (T13/T16 extension)

**The highest-leverage outstanding measurement in the campaign, and the cheapest.** Nothing is
blocked: the rig, the instrument and the grading script all exist and the source is unchanged.

**The question.** Grooming buys TR 101 290 P1 PCR-repetition conformance with buffer depth, and
buffer depth is latency. Two points are measured and they are on different data planes:

| Groomer cushion | Data plane | PCR intervals > 40 ms, on the wire | Source |
|---|---|---|---|
| shallow (the depths the MoQ lane runs) | MoQ | **131** on the laptop rig, **159** on the EC2 box, 227 ms max | [T13](test-13-downstream-grooming.md) |
| 8 s, derived from arrival | segmented HTTP | **0** | [T16](test-16-grooming-segmented-http.md) |

T16's explanation is general rather than plane-specific — *what constrains PCR placement is not live
operation but whether the stage always has a packet ready at the deadline, which is what buffer depth
buys*. If that holds on MoQ, the edge stage that makes MoQ presentable spends the only advantage MoQ
has ([comparison](../docs/comparison.md) §5.1).

**Procedure.** T16's rig with leg A replaced by the MoQ chain — publisher, relay, `moq export ts`,
groomer, `t13-cadence.py capture` — sweeping the cushion and grading each arm with
`t13-grade.py` plus `tsp -P pcrverify`, `-P continuity` and `-P analyze`:

```bash
for CUSHION in 200 400 800 1500 3000 5000 8000; do
	# MoQ leg, groomer cushion pinned; capture on loopback UDP as T13's wire domain
	LAT_MS=$CUSHION lab/scripts/t13-cadence.sh ~/CNNiEMEA2.ts ~/t18/moq-$CUSHION 60
done
python3 lab/scripts/t13-grade.py grade ~/t18/moq-*/egress.ts
```

**Report, per cushion:** PCR intervals above 40 ms and the maximum interval, `pcrverify --absolute
--jitter-max 13`, continuity errors, packets dropped and muted (criterion 4 — a pass reached by
discarding programme is not a pass), 10 ms coefficient of variation, and **the resident buffer and
the programme held before the first byte**, which is the latency the conformance costs.

**Fix the pass criteria before running.** (1) The cushion at which wire-domain intervals above 40 ms
first reaches 0 with nothing dropped and nothing muted. (2) Whether that cushion, plus the exporter's
own `--latency-max`, plus a nominal encode and network budget, leaves the chain under one second. A
negative answer on (2) is the more valuable result, and it should be published as such.

**One thing to pin while there.** T13 describes its cushion as "~1 s" while the flag set
[T16](test-16-grooming-segmented-http.md) reproduces as "the depths T13 ran" is
`--latency-ms 200 --max-latency-ms 2000 --stall-ms 1000`. Record the cushion actually in force per
arm so the two files agree.

---

## Glass-to-glass latency, at equal conformance, on both data planes

**Unmeasured on either plane, and it decides the comparison.** [T8](test-8-srt-vs-moq.md) records it
as owed; [T14](test-14-data-plane-comparison.md) records it as unmeasured. There is no latency figure
anywhere in this campaign, and the paper's decision rule
([comparison](../docs/comparison.md) §5.2) currently rests on a structural argument plus the
measured delivery granularity.

**Method.** One encoder with burnt-in timecode and a local clock reference, tee'd byte-identical into
both data planes, each groomed to the *same* P1/P2 gate before measurement — otherwise the comparison
prices conformance rather than transport. Report the composition, not just the total: encode,
package, deliver, reassemble, groom, egress. A buffer ladder is already defined in T8
(B ∈ {250 ms, 500 ms, 1 s, 2 s}).

**Partly blocked.** The segmented arm cannot reach the low end of its own envelope on free software —
no free client fetches partial segments ([T14](test-14-data-plane-comparison.md) measurement 2b) — so
a like-for-like low-latency comparison needs the same commercial ABR-to-TS hardware as the entry
below. The **MoQ arm is not blocked** and should be run with the cushion sweep above, since the two
share a rig and the sweep produces half the answer.

---

## Hardware TR 101 290 P1/P2 soak (T7, P2 — Gate 2)

The load-bearing open test. Feed the live groomed egress to a hardware IRD + TR 101 290 analyser and
confirm PLL lock and a clean P1/P2 result over a **sustained soak (target ≥ 24 h, ideally 72 h)** —
short runs can pass by luck; only hours→days surface slow clock drift, buffer-model violations, and
rare discontinuity handling. Run jointly with the resource soak below so one long run yields both
verdicts. Exercise the boundaries a groomer must handle beyond steady state:

- source-clock drift; PCR discontinuities / 33-bit wrap; mid-stream PID / PCR-PID change;
- ST 2022-7 determinism under loss (the on-hardware hitless-switch drill), verifying the two egress
  legs stay byte-identical under *divergent* object-loss recovery, not only in the clean case.

Where access exists, corroborate with a second analyser (Elecard / R&S MTS4EA / Tektronix MTS / Ateme
Titan). The precondition — which groomer topologies can produce a byte-identical pair — is already
characterised in [test-6-relay-resilience.md](test-6-relay-resilience.md), and the hand-off it enables
is graded in software in [T12](test-12-dual-path-handoff.md). This drill therefore starts from a
known-good sender pattern, and its open question is narrow: **does a real IRD's merge engine agree with
T12's reference receiver?**

---

## T14 — remaining measurements (Gate 1 + Gate 2, both data planes)

**Partly run.** Burst granularity, carriage fidelity and wire cost are measured and recorded in
[test-14-data-plane-comparison.md](test-14-data-plane-comparison.md), which also holds the rigs, the
environment and what the results do to
[comparison](../docs/comparison.md). Three cells remain, each blocked on something the lab does not
currently have.

1. **Whether a commercial ABR-to-TS gateway, run as the distributor's own edge stage, passes
   TR 101 290 P1/P2 on hardware.** Feed a MEG- or TITAN-Edge-class gateway an HLS-with-TS feed and
   grade its TS output on the Gate 2 rig — PLL lock, P1/P2 clean, PCR accuracy inside 481 ns, no
   interval above 40 ms, duration fidelity 1.000. The question is not whether a client's receiver
   relieves the distributor of the hand-off, since the distributor does not supply that receiver; it
   is whether such a box discharges the distributor's *own* grooming obligation. §4.4 of
   [comparison](../docs/comparison.md) rests on datasheet claims and this converts them into a
   finding either way. **Blocked on:** hardware. *Moves:* whether part of the broadcast-grade edge
   layer is purchasable for segmented HTTP and not for MoQ, or whether the hand-off axis closes
   entirely.
2. **Glass-to-glass latency at equal conformance.** Tune each leg until its groomed egress passes the
   *same* P1/P2 gate, then measure, reporting the composition rather than the total. Report arm B1's
   floor alongside, because B1 is what off-the-shelf tooling gives. **Blocked on:** the same hardware
   as measurement 1, and this is why the two have merged. Arm B2 has now run: partial segments can be
   *published* with MPEG-TS free of charge, and no free client fetches them, so the only receiver that
   could realise the low-latency arm is a commercial ABR-to-TS box. The sub-question this cell used to
   carry — how far 200–330 ms parts close the 240× burst gap — is **answered**: not at all, because
   nothing free gets at the parts. *Moves:* §5's structural floor.
3. **Multi-programme carriage in practice.** HLS normatively excludes it ("Transport Stream Segments
   MUST contain a single MPEG-2 Program"), and a cache does not parse the payload. Publish TS
   segments containing an MPTS through a real CDN and record: does it deliver them, does a conformant
   analyser accept the result, and does an ABR-to-TS gateway. **Blocked on:** a CDN account.
   *Moves:* this now carries the *whole* of MoQ's carriage-fidelity advantage, because test-14 showed
   single-programme carriage in TS segments is verbatim — so it is the one cell where a negative
   result for HLS is the interesting one.

**Deliberately not queued.** Wire cost's per-packet framing is derived from
[T9](test-9-performance.md)'s real-path measurement rather than measured on the segmented-HTTP leg,
because loopback's 16384 B MTU cannot price a packet and the HTTP-layer term that *is* measured is
path-independent. Re-running arm B1 on the EC2 path under
[`t9-overhead-wan.sh`](scripts/t9-overhead-wan.sh)'s accounting would confirm a multiplier, not move a
result, so it ranks below all three cells above.

**What none of this can settle.** One route, one source, one host. Nothing about whether a commodity
MoQ relay market appears, nothing about operating either chain at scale, and — like every Gate 1
result here — nothing about hardware acceptance except in measurement 1.

---

## T15 — RIST and SRT on the cadence instrument — **run**

Results in [test-15-point-to-point-cadence.md](test-15-point-to-point-cadence.md). Neither of the two
outcomes this was specified against is what happened, so the specification is kept here in summary
rather than deleted.

It asked whether RIST's egress is near-source-paced, expecting either that **grooming burden ranks
inversely to scalability** or that the incumbents' hand-off advantage is folklore. The answer is
neither: RIST and SRT are *transparent* — measured identical to a no-transport control on burst size —
so their egress is whatever their publisher produced, while MoQ's is set by its object model and does
not move when the source changes. Grooming burden therefore does **not** rank inversely to
scalability; MoQ hands over the finest bursts (12.2 kB against 30.6 kB from the same source), and the
tunnels lead only on worst-case silence (~35 ms against 149 ms), which is the figure that sizes a
groomer's start gate.

What remains open from this line is in T15's own "still open" table: the tunnels under loss and RTT,
and a true CBR hardware source, which the transparency result makes the interesting variable.

---

## T16 — grooming a segmented-HTTP egress — **run**

Results in [test-16-grooming-segmented-http.md](test-16-grooming-segmented-http.md), rig in
[`scripts/t16-groom-segmented.sh`](scripts/t16-groom-segmented.sh). Specified to close the cell
[evidence](../docs/evidence.md) §3.2 admitted was open — "the equivalent grooming pass on
a segmented-HTTP egress is unmeasured" — by inserting the groomer into T14 arm B1's chain and changing
nothing else, then grading with T13's criteria and gates verbatim.

It also tested T14's disposal of the gap as "a configuration finding, not a defect", by running the
groomer at three points in the parameter space beside the adaptive arm. That is the half of the
specification worth keeping: the adaptive arm passed, and so did an arm with every depth pinned by flag
to what the adaptive arm derived — but T14's proposal taken literally, raising only the stall timeout,
produced a stream with 231 continuity errors behind a flawless PCR record and a perfectly flat wire. **A
cadence instrument and a PCR grader between them cannot detect a groomer that is deleting programme**,
which is a method finding for any future pacing measurement: score packet conservation as its own
column.

What remains open is in T16's own "still open" table. In rough order of value:

- **6 s segments**, which T14 measurement 5 already publishes, against the groomer's 8 s default cushion
  ceiling. This is the one arm expected to fail as shipped, and therefore the one worth running.
- **1 s segments**, where 2.5 × the observed lead lands under that ceiling, so the adaptive factor is
  tested rather than clamped. T16 measured only that 8 s was adequate.
- **A lossy segmented path.** Every T16 arm is loopback, so no segment ever failed to arrive; the run
  measures absorption of a late delivery, not recovery from a missing one.
- **A feed that is not rate-matched, or a join mid-segment,** which is what would distinguish the
  content-based start gate from a plain timer at the same depth. On a rate-matched delivery the two
  coincide, so T16 leaves the gate unfalsified rather than demonstrated.

---

## T17 — standalone SI on snapshot tracks — **run**

Results in [test-17-si-snapshot-tracks.md](test-17-si-snapshot-tracks.md); rigs in
[`scripts/eit-roundtrip.sh`](scripts/eit-roundtrip.sh) and
[`scripts/si-join-cost.sh`](scripts/si-join-cost.sh), fixture generator in
[`scripts/make-eit-epg.py`](scripts/make-eit-epg.py). Specified to settle the one part of upstream's
SI-on-tracks design that code review cannot: an EIT schedule sub-table is sparse, so its completeness
cannot be decided by counting sections, and the importer commits on observing the transmission cycle
wrap instead. Whether that reconstructs the table is empirical.

It does. EIT round-trips section-for-section across four sub-tables of an 8-day EPG against zero on the
merge base, and the two costs theory predicted are immaterial: carriage is bitrate-neutral (0.985×) and
the export gate — which holds all output until every SI entry has a snapshot — costs 1 ms, because the
subscriptions are issued together. The experiment also produced the 8-day price
[#2882](https://github.com/moq-dev/moq/issues/2882) asked for: 29,912 B across four snapshot tracks per
service, so ~1.1 MiB across 160 tracks at 40 services.

The method finding is worth more than either number. The census that opened the run used
`tsp -P tables` without `--all-sections` and read a sparse sub-table's *non-completion* as its
*absence*, producing a confident and wrong conclusion about the existing fixture. **An instrument that
reports completed tables cannot establish the absence of a table designed never to complete.**

What remains open:

- **A lossy path.** In a sparse table a lost section and a skipped section number are
  indistinguishable, so a section lost before the cycle wraps should yield a snapshot quietly missing a
  segment. That is reasoned, not measured; it wants a drop injected on the SI PID. Upstream has since
  fixed a related defect by merging same-version sections rather than replacing them, so this arm is now
  confirmation of a fix rather than the adjudication of an open question.
- **Multi-service.** The 40-service figures are scaled from one service, not measured on an MPTS.
- **The clock's emission timing.** Carriage is settled — TDT/TOT is proxied from the source and TOT's
  descriptors survive byte-for-byte — but the exporter re-emits a stored section on its own 30 s timer,
  so the delivered clock is ~14 s late and repeats a time it has already asserted when the source ticks
  slower than the timer ([T15](test-15-point-to-point-cadence.md) measurement 4). Measured on a clean
  loopback path only; what a lost snapshot group does to it is untested.

---

## T13 extended — an off-the-shelf datagram sender — **run**

Results in [test-13-downstream-grooming.md](test-13-downstream-grooming.md) under "The egress stage on
its own"; rig in [`scripts/t13-rawsend.sh`](scripts/t13-rawsend.sh). T13 concluded that a constant-rate
stream is not a paced wire and that the missing piece is a stage owning a clock.
[`rawsendmpeg2ts`](https://github.com/EDIS-mx/rawsendmpeg2ts) is exactly that stage and nothing else,
so it tests the conclusion directly rather than adding another candidate groomer.

The conclusion holds and the gap it named is now closed. Holding the muxer fixed and swapping only the
egress takes the same FFmpeg output from 10 ms CoV 6.553 and a 265.8 ms silence to 0.048 and 3.5 ms,
at the declared rate rather than 15 % above it. Replaying a CBR file the sender is byte-identical
across 165,326 packets and reaches the instrument's resolution floor. A fully off-the-shelf chain now
passes three of T13's four criteria and fails only carriage, which sharpens what has to be said in
someone else's documentation: not "you need a groomer" but "you need a stage that inflates a mux and
re-places PCR without rewriting it, and nothing off the shelf does that".

Legs ran on the EC2 box because the sender does not build on macOS — `clock_nanosleep` with
`TIMER_ABSTIME` is the pacing mechanism and does not exist there — so every control was re-measured
on that host at a matched rate.

What remains open:

- **Hardware.** This is loopback on a general-purpose kernel, and the tool's own documentation insists
  a switch between sender and IRD invalidates the test. It is a candidate for [T7](test-7-timing-integrity.md)'s Gate 2 rather than a substitute.
- **Behaviour at a join backlog.** The sender has no buffer policy, so a backlog becomes standing
  latency or is discarded upstream by the exporter's `--latency-max`. Neither was measured; a
  deliberately delayed start would show which.
- **A rate that drifts.** The rate is derived once from ~1 s of PCR on a CBR assumption. What happens
  when the groomer in front does not hold it exactly is untested.

---

## Dual-path 1+1: remaining conditions (T12)

All four arms are run; results and limitations are in
[test-12-dual-path-handoff.md](test-12-dual-path-handoff.md), rigs in [`scripts/t12-*`](scripts/).
What those results left open:

**Restart one leg of a live pair — blocked upstream.** A stream-clocked leg that mutes and returns
already rejoins its partner's numbering and phase correctly; the one thing stopping the pair being
byte-identical afterwards is the exporter's continuity counters, filed as
[moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779). Once that lands, re-run the recovered-leg
and late-join cells expecting 100 % agreement.

That re-run also needs a grader the current one is not. `t12-merge-oracle.py` recovers the legs'
sequence offset by voting on payload identity and derives skew from it, so it cannot grade a pair that
differs in any field — it graded the join cell on 15 datagrams out of 23,175 and returned a spurious
offset and a 12 s skew that did not exist. Either give the oracle a masked-compare mode or wait for the
exporter fix; meanwhile use [`t12-seqskew.py`](scripts/t12-seqskew.py), which measures phase without
correlating.

**Two-host and meshed variants.** Both T12 legs ran on one host, sharing a clock, which flatters the
rate coherence [architecture](../docs/architecture.md) §5.1 requires of two gateways on free-running
oscillators; and both traversed the same physical path, so T12 graded the hand-off, not path
diversity. This matters more now than it did: arm D's identity claim rests on two groomers agreeing
about stream position, and on one host they agree about wall time as well. Repeat the arm C and arm D
cells across two hosts, and optionally with relay B dialling relay A as a cluster peer
(`~/t6-redundancy/relayA.toml`/`relayB.toml`), to check that relay reselect neither helps nor
interferes once the receiver is doing the switching.

The second host is a **second EC2 instance in a different AWS availability zone**, which is wanted in
its own right as the secondary relay. Until it exists this is blocked: the local re-run in
[T12](test-12-dual-path-handoff.md#what-the-fixes-are-worth-measured-on-the-pair) shares a host too,
so nothing measured so far separates "the legs agree about stream position" from "the legs share a
clock". Run it once the exporter fixes land, so the two-host result grades path diversity rather than
re-measuring defects already filed.

**Also unaddressed by T12:** SMPTE 2022-1 FEC; a full 10 Mbps mux rather than 2 Mbps on a 2-vCPU box;
a carrier rate matched to the content rate, to resolve whether the 1.4 % PCR-interval floor measured
there is an artefact of 55–60 % stuffing; and any hardware IRD merge, which is Gate 2.

---

## Congestion control for a permanent fixed-rate trunk (extends T8)

Promoted to its own protocol with a runnable rig — see
[test-8b-congestion-control.md](test-8b-congestion-control.md). The under-provisioned
failure-mode run (C1) is done; the provisioned-path conditions (transient congestion, coexistence,
AQM, provisioning margin, soak) are pending. Until those run, the T8 controller ranking is scoped to
non-congestive impairment only.

---

## LEO / Starlink satellite-handover impairment (candidate — extends T5/T8)

The [T5](test-5-network-impairment.md) runs used *steady* impairment. On Starlink (LEO) the perceived
damage is not steady-state loss but the **satellite-to-satellite handover** — a periodic pulse
(~every 15 s) of elevated delay and **bursty** loss lasting ~1 s, against an otherwise near-clean
baseline. Because QUIC treats a loss burst very differently from uniform Bernoulli loss, this is a
plausible cause of the periodic degradation reported by collaborators on satellite-backhauled
contribution.

A collaborator's `netem` sketch (a **candidate**, not yet run or calibrated) models it as a
clean-ish baseline with a periodic 1 s handover pulse. As written it drives an `ifb0` ingress-redirect
qdisc rather than the SSH-safe egress `prio` band, so it needs adapting to the media-only filter
before running on a shared host:

```bash
#!/bin/bash
# S3: "Starlink medium-degraded", ~25% worse than APNIC/MMSys'24 measurements.
BASELINE="delay 50ms 8ms 25% loss 0.3%"
tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
while true; do
    sleep 11
    tc qdisc change dev ifb0 root netem limit 20000 delay 150ms 20ms loss 10%   # handover pulse
    sleep 1
    tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
done
```

If run it belongs alongside the T8 impairment matrix (condition 5, bursty/correlated loss) so both
transports meet the same pulse; the metric to watch is not average throughput but **per-pulse
recovery** (does each 1 s burst cause a bounded, self-clearing dip, or accumulate into
starvation/collapse over successive handovers?). Open items before trusting the numbers: (a) calibrate
period/hold/loss against a real Starlink capture rather than the assumed 15 s / 1 s / 10 %; (b) run it
correlated with the T5 reordering finding (a handover that also reorders is the genuine worst case);
(c) apply via the SSH-safe media-only filter, not a blanket `ifb0` qdisc, on any shared host.

---

## System performance & resource utilisation (T9)

Soaks, the fan-out envelope, the bitrate sweep, protocol overhead, the relay memory characterisation
and the audio-resync work are all executed and written up in
[test-9-performance.md](test-9-performance.md). What is left:

1. **Run a leg long enough to resolve the soft plateau.** The knee reproduced where predicted, but
   growth past it continues at ~+8 MB/h rather than stopping, and four hours cannot distinguish slow
   convergence from a second, shallower leak. A 12-hour leg on the default slot count would settle it.
   Related: the ceiling has a ~20–30 MB slot-independent term whose origin is unattributed — a third
   slot count (say 4,096) would test whether the two-point fit holds as a line.
2. **Re-test the memory behaviour after any upstream fix**, using `gop14` as the sensitive case — at
   6,445 groups/h it shows a regression in half the time. The fix has to come from `quinn-proto` and no
   released version past 0.11.16 changes the recycling behaviour, so this may wait a long time.
3. **What a real decoder does with an unflagged 24 ms audio hole, and with a substituted frame**, if
   [#2798](https://github.com/moq-dev/moq/issues/2798) needs it. A resync is signalled nowhere, but
   "unsignalled" only matters if something downstream would have acted on the signal. The splice case is
   the sharper half: a frame of spliced bytes decodes to *something*, and whether that is an inaudible
   glitch or a full-scale click decides how much the missing signal costs. An AC-3 decoder that honours
   `crc1` should conceal it; an MP2 decoder on this content has no CRC to check.
4. **Two residuals from the splice fix ([#2823](https://github.com/moq-dev/moq/pull/2823), merged and
   verified: the mixed frame is gone from the looped feed).** First, **the counter-contiguous wrap**,
   where the fix is blind and the mixed frame returns — reproduced on `main` with a 130,705-packet cut
   of the broadcast clip, chosen so the audio PID's counter runs straight through the wrap, and worth
   reporting as its own issue once the AC-3 question below is answered, since a CRC or a PES-length
   check would cover it. Second, **why AC-3 loses the 8 whole
   frames inside its truncated PES while MP2 keeps its 7**, when `salvages_partial_pes` is true for both
   and they take the same branch: either the salvage flush is not reaching the parser for AC-3 or the
   parser is discarding a confirmed frame, and ~256 ms of good audio per wrap turns on which. Also worth
   constructing the opposite case — a mux that *does* split audio frames across PES boundaries — to
   exercise the first commit's confirmation path, which no content we have reaches.
5. **The publisher thread count**, which grows and decelerates without settling.
6. **A cross-machine fan-out** to find the relay's own knee, overhead under loss versus SRT, and the
   groomer/pacer envelope.
7. **A full-feed publisher soak — both blockers now cleared, so this is ready to run.** Every long run
   to date used a video-only source, because looping a normal broadcast TS killed the publisher at the
   wrap. The origin host now runs a `main` build carrying the whole audio-resync and continuity series
   (#2751, #2823, #2891), and its standing loop publisher was rebuilt to replay the file's own bytes
   (`tsp -I file --infinite -P regulate --pcr-synchronous`) instead of re-muxing through `ffmpeg -c
   copy`. Verified at the subscriber: all seven elementary streams arrive on the source's own PIDs with
   AC-3 typed AC-3, the teletext descriptor intact and all three SCTE-35 PIDs typed 0x86 — where the
   ffmpeg loop had delivered two tracks on renumbered PIDs. The soak therefore now exercises what it was
   commissioned to exercise, and the publisher's `NRestarts` doubles as a wrap regression test, since
   the byte-faithful wrap is the #2802 splice rather than a remuxer's approximation of it.

**Standing method** (used for the executed conditions, and for the remaining ones). Per role
(publisher, relay, subscriber + groomer/pacer), establish the steady-state resource envelope and its
scaling, and prove stability over long runs. The priority dimension is a **hours→days soak** to detect
memory leaks / unbounded growth — a resource leak is a production blocker, not a characterisation
note. Run on the Linux EC2 host so `pidstat`/`/proc` are available; pin builds and record them.

```bash
# steady-state per role (fixed 10 Mbps CNNiEMEA2 loop), ≥ 300 s after warm-up
pidstat -h -r -u -d -t -p <PID> 1 300 > perf_<role>.log
while :; do printf '%s fds=%s thr=%s\n' "$(date +%s)" \
  "$(ls /proc/<PID>/fd | wc -l)" "$(ls /proc/<PID>/task | wc -l)"; sleep 1; done > fds_<role>.log

# soak (≥ 24 h, ideally 72 h): coarse sampler + RSS-vs-time slope (slope ~0 = no leak)
while :; do printf '%s ' "$(date +%s)"; ps -o rss=,%cpu=,nlwp= -p <PID>; sleep 60; done > soak_<role>.log
awk '{n++;x=$1;y=$2;sx+=x;sy+=y;sxy+=x*y;sxx+=x*x}
  END{b=(n*sxy-sx*sy)/(n*sxx-sx*sx); printf "RSS slope = %.4f MB/hour\n", b*3600/1024}' soak_<role>.log
```

Pass criteria for any role: RSS growth slope statistically ≈ 0 over the soak, or a plateau with a
stated ceiling; fd, socket and thread counts stable and returning to baseline after join/leave and
relay-reconnect churn; bounded CPU with headroom. Pair the soak with the T7 ≥ 24 h PLL-lock soak so one
long run yields both verdicts. Re-running the fan-out sweep across two machines needs
N ∈ {1,5,10,25,50} subscribers on hosts separate from the relay, since a co-resident subscriber costs
more CPU than the relay serving it and the knee then belongs to the box.

**Carriage overhead: the opaque lane and loss above 1 % remain.** The media-aware lane and SRT are
measured on a real path ([T9](test-9-performance.md)). Two rules for whoever runs the rest, on top of
the three enforced by the rigs themselves ([`scripts/README.md`](scripts/README.md)) — the first pass
here produced a wrong number that survived two rounds of hypothesis:

- **State the budget in advance.** QUIC's per-packet cost is ~64 B (IP + UDP + short header + AEAD tag
  + `STREAM` header), so 5.5 % at a 1200 B datagram and 4.5 % at 1500 B, against SRT's 3.3 %. Without
  a prediction, a wrong measurement has nothing to fail against.
- **State the denominator.** Elementary-stream bytes, delivered TS and source TS differ by the stuffing
  and TS-header volumes; only the last is the like-for-like comparison against a byte pipe.

---

## Cross-implementation interop (T11)

Three other MoQ implementations now matter to this project
([comparison](../docs/comparison.md) §12), and "a MoQ relay is a neutral transport fabric"
is a load-bearing assumption that has only ever been tested against `moq-dev` peers.

**T11a — `moq-dev` against third-party relays.** *Partly run;* harness, relay matrix and the isolated
root cause are in [test-11-interop.md](test-11-interop.md), which carries its own list of remaining
legs. The one worth prioritising is **Cloudflare with a provisioned scope**: the anonymous attempt
negotiated draft 18 cleanly and returned no data, which is the expected outcome without publish and
subscribe tokens, so it has not yet tested anything. Done properly it is **the strongest available test
of relay neutrality**, because it uses third-party production infrastructure rather than a lab peer.
Record the negotiated draft, whether the `hang` catalog survives a relay with no catalog concept,
round-trip fidelity against the T1 baseline, and added latency. Their relay treats publisher disconnect
as terminal, so expect no source-failover behaviour — confirming that is itself a result worth
recording against [architecture](../docs/architecture.md) §5.

**T11b — a `moq2ts` broadcast through a `moq-dev` relay.** *Runnable now, weaker result.* `moq2ts` is
publisher-only, so there is no MSFTS subscriber to close the loop; the question is only whether the
relay forwards objects whose catalog it cannot parse. Observe the relay's forwarding and announce
behaviour rather than decoding output. `moq-dev` is demand-driven (T11a), so the open part of the
preannounce split documented in `moqxr` PR #21 is the other direction: run with their default
(preannounce off) and then with it on, to establish whether an early `PUBLISH` poisons namespace
registration.

**T11c — the full suite against a `moq2ts` subscriber.** *Blocked until they publish one.* When it
exists, run T1–T3 transparency, T7 timing integrity and TR 101 290 conformance against their
implementation and contrast with ours. This is the comparison that would actually settle which lane
preserves what — particularly whether their null-stripping and SPTS-from-MPTS behaviour costs
conformance in the same places ours does, and whether the `mediatimeline` side track is a better
answer to wall-clock correlation than downstream PCR regeneration. Plan the matrix now so the run is
ready when the subscriber lands.

**Ecosystem contribution to consider alongside these:** a **broadcast profile** for the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) — TS carriage fidelity, PSI/SI
survival, PCR integrity across a relay. The harness already exists and deliberately stops at the
protocol handshake, so this extends shared infrastructure rather than building a private rig, and
gives the transparent-TS profile a neutral conformance target.

---

## MPTS / multiple concurrent services (T10)

Carry a multi-program TS (or several SPTS broadcasts concurrently) through the opaque lane and verify
per-service PSI/SI, PCR and CC integrity at egress, plus relay fan-out behaviour under N services.
Primary distribution is frequently MPTS; the campaign to date is SPTS-only. Gate 1 (fidelity) at
multi-service scale.

---

## Office-network reproduction of T3/T4

Re-run the opaque lane (T3) and the remote end-to-end SRT chain (T4) from the office network. The
office has ample upload capacity (removing the ~2 Mbps home-uplink ceiling that capped T4's SRT leg)
but may impose UDP/QUIC throttling or DPI a home link does not. This tests two things at once: (a) the
opaque lane and full-rate SRT contribution without the access-link bottleneck, and (b) whether
MoQ/QUIC survives an enterprise network posture that polices or rate-limits UDP — a real deployment
risk. Record connect success, negotiated draft, throughput, and any QUIC fallback/blocking.
