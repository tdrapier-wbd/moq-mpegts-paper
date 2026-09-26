# Test 28 — Failure-injection and recovery matrix

**State: run in part. The MoQ and SRT lanes are measured across three impairment shapes — discrete
outage, sustained partial loss and reorder — matched on measured latency in the `netns`/`cake` rig,
and the MoQ lane is re-measured on five builds and both QUIC backends with the controller pinned and
graded on content; the segmented lane is measured on the same three shapes in T20's loopback rig and
in part in the `netns` rig; the infrastructure axis is not run.**
Infrastructure and transport failures have been probed one at a
time in [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md), usually reported as
recovery *time*; what a distributor buys is programme continuity, and the two are not the same number.
This experiment applies one media-domain grader across a full matrix on both lanes.

**Headline: graded on the content it delivers, the media-aware lane loses more programme than SRT
under every impairment shape run at matched latency, and how much more depends on the build and on
the QUIC stack.** At a 2 s budget a 5 s total outage costs SRT 3.9–5.3 s of video; it costs the MoQ
lane 7.5 s on the oldest build and 16.3–28.4 s on every later one, where one commit loses the same on
both stacks and under either controller. Under 5 % random loss SRT
loses nothing, and the MoQ lane loses 0–0.6 s on quinn, whose `delay` controller is BBRv1, with a
bandwidth model that ignores loss, but 26.6–37.5 s of a 60 s window on noq, under BBRv3 and CUBIC alike. Under 20 % reorder SRT
loses no pictures and carries several hundred continuity errors; the MoQ lane loses 30.8–38.3 s on
every build, both stacks included. On noq nearly all of that is the stack's loss detection: a relay
patched to relax its thresholds, which no flag exposes, loses 2–3 s. On quinn the same patch does not
save the programme. **This reverses what the file published before** — that an outage shorter
than the budget was free and that the MoQ lane was ahead under a discrete outage — and the reason
is the grader: § *Corrections*. Every MoQ cell still returns 0 continuity errors, which on this lane
is a property of the exporter and measures nothing.

**Second headline: at loopback RTT the segmented lane's resilience is bounded by the origin's
retention and by almost nothing else.** Sustained loss at 5 % and at 10 % returns bytes **identical
to the unimpaired control**, and a 5 s total outage does too; a 30 s outage costs 17.134 s because it
outlasts the segment store. At 100 ms RTT in the `netns` rig the 5 s outage is still free, and the
loss cells are not: § *Measured — the transport axis, segmented lane*.

**What changed.** The reason this test had never run was that its shared grader did not exist, so no
cell could be scored in the media domain. **That grader now exists and has been validated against
known answers** — `lab/scripts/t28-media-lost.py`, with `lab/scripts/t28-grader-selftest.sh` as its
oracle. That discharges pass criterion 1 and removes the blocker the file previously named.

**The substrate was never missing.** The matrix needs `netem`/`tc` and Linux network namespaces,
which the campaign's macOS workstation does not have — but both EC2 Linux hosts do, and both had
already used them for [T5](test-5-network-impairment.md),
[T8b](test-8b-congestion-control.md) and [T20](test-20-segmented-http3.md). The transport axis now
runs on the **EC2 secondary** (8 vCPU / 15 GB, `eu-west-1b`), chosen over the primary because a
2 vCPU host cannot carry a relay, a publisher and a subscriber without the knee being the host's.
Substituting macOS dummynet would still be wrong, for the comparability reason, and was not done.
The method rule this cost is in [method-notes](method-notes.md) § Rig hygiene.

**Grader validation, measured.** Five cells, one command, `CNNiEMEA.ts` as the source:

| Cell | Injected | Measured lost | Measured duplicated | Continuity errors |
|---|---|---|---|---|
| control (unimpaired 80,000-packet slice) | — | **0.000 s** | 0.000 s | 0 |
| hole, 2,000 packets excised | 0.302435 s | **0.302435 s** | 0.000 s | 37 |
| hole, 10,000 packets excised | 1.512173 s | **1.512173 s** | 0.000 s | 62 |
| hole, 50,000 packets excised | 7.560866 s | **7.560866 s** | 0.000 s | 84 |
| repeat, 20,000 packets duplicated | 3.024345 s | 0.000 s | **3.024346 s** | 98 |

The control is clean and every injection is recovered inside the 100 ms margin criterion 1 fixes. The
duplication cell is there because duplication is a separate code path and a separate column: a stream
that loses five seconds and repeats five seconds has not broken even, and the grader is required not to
net them off. It does not.

**How much this validates, stated precisely.** The agreement is exact rather than merely within
tolerance because the oracle derives the injected duration from the clip's PCR timeline using the same
median-rate arithmetic the grader uses. That is a strong check on the *implementation* — it would have
caught a wrong CSV column, a PCR wrap bug, a sign error, or a rate reference moved by the holes being
measured, which are the failures this campaign has actually hit — but it is **not** an independent
check on the *method*. The independent corroboration is the continuity-error column, which comes from
a different tool and rises from 0 to 37–98 exactly where an excision or repeat was made, confirming
each capture was damaged as intended.

**The grader needed a second reference before it could score a live capture, and finding that out is
part of this result.** The validated arithmetic above compares elapsed PCR time against the bytes
between two PCR samples, which assumes a constant byte rate. That holds for a clip or a groomed
egress — the file domain, which is what the self-test exercises — and fails on a raw
`moq export ts` capture, because the exporter emits PCR-bearing packets in clusters
([T19](test-19-pcr-grid-verification.md)'s positional finding): the median packet gap between adjacent PCR
samples measured **6 packets** rather than the ~150 a CBR stream gives, so the rate estimate
collapsed to **0.361 Mb/s against a true 8.595 Mb/s** and the grader reported **1,254 s of
duplication in a 55 s capture**. The hole figure survived that corruption, because a hole is
dominated by its time term, but a grader that is right in one column and silently wrong in another is
not usable. `t28-media-lost.py` now takes `--domain {file,wire}`; `wire` references the stream's own
PCR cadence and ignores byte positions. **Both domains are validated against the same five known
answers** (`DOMAIN=wire bash t28-grader-selftest.sh`), the wire domain carrying a systematic offset
of one PCR cadence, well inside the 100 ms margin.

**That grader is sound for a lane that passes the stream through — SRT and segmented HTTP — and is
not sound for the MoQ lane.** `moq export ts` keeps writing PCR across pictures it never received, so
a hole in the programme is not a hole in the clock, and the grader scores a lane that has stopped
delivering picture as nearly clean ([method-notes](method-notes.md) § *The exporter manufactures
bytes and clock*). MoQ cells are graded on the content's own timeline by
[`t28-content-lost.py`](scripts/t28-content-lost.py) from 8 s in (the join is not the impairment),
validated against known answers by `t28-content-selftest.sh` within 0–40 ms, and **conserved** against
a clean cell of the same invocation by [`t2831-conservation.py`](scripts/t2831-conservation.py),
because a picture that stops before the window closes leaves no hole to count
([method-notes](method-notes.md) § *A hole count sees only gaps between what arrived*). The figure
quoted is **video missing at close**: in holes, plus what had not arrived when the window ended —
lost, or late by up to the budget.

Where a capture was deleted, the matched ladder's latency taps survive it: they log one row per
picture at the source and at the egress, and
[`t2831-tap-conservation.py`](scripts/t2831-tap-conservation.py) conserves on those. On the cells that
have both, the tap figure agrees with the capture's within 0.85 s on outage cells and reads
2.5–4.2 s lower on cells whose picture stops, so it is the conservative of the two.

## Measured — the transport axis, MoQ lane

**Environment.** EC2 secondary, 8 vCPU / 15 GB, Ubuntu 26.04. Two network namespaces joined by veth
(`t8b-netns.sh`), `cake` at the bottleneck provisioned at 20 Mb/s, 100 ms base RTT (50 ms each way),
source a 120 s ~9.95 Mb/s CBR slice of `CNNiEMEA2.ts` paced with `tsp regulate --pcr-synchronous`.
`moq import ts` → relay → `moq export ts`, **no groomer in the path**, captured at the subscriber.
Outage = 100 % loss applied at the bottleneck for a fixed duration, 20 s after delivery settles.
Measurement point **P1**, graded on content and conserved, as above. The build and QUIC backend are
named on every table, because the lane's figures differ between builds by more than between budgets.

### The build bisection: the lane lost ground between builds, and the backend decides the loss shape

Every build a published MoQ figure in this file or [T31](test-31-congestion-capacity-ladders.md)
came from, in commit order, on one rig ([`t2831-build-bisect.sh`](scripts/t2831-build-bisect.sh)):
the relay's controller pinned to `delay`, which is what each resolves an unset flag to — BBRv1 on
quinn, BBRv3 on noq — and padding off where the build pads. `5d0991b9` is run on both backends,
which isolates the stack from the code. The ladder
([`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh)) runs at a 3 s budget with 35 s of recovery
after each impairment, three replicates; the matched cells run at a 2 s budget through
[`t28-t31-srt-ladder.sh`](scripts/t28-t31-srt-ladder.sh), two replicates. Video missing at close,
seconds, replicates in order:

| Build | Backend | 5 s outage, 3 s budget | 30 s outage | 0.9× stream rate for 60 s |
|---|---|---|---|---|
| `fd4f5d82e` | quinn | 8.52, 8.52, 4.84 | 33.32, 33.64, 33.60 — session survives | 5.16, 7.84, 6.04 |
| `5d0991b9` | quinn | 20.56, 16.96, 18.80 ¹ | 63.24, 63.52, 63.52 — session ends | 54.48, 9.86, 13.90 ² |
| `5d0991b9` | noq | 18.80, 18.56, 17.28 ¹ | 63.52, 62.92, 63.52 — session ends | 20.34, 21.62, 17.76 ¹ |
| `53f8aa99d` | noq | 18.80, 18.24, 17.92 | 63.52, 63.52, 62.92 — session ends | 24.04, 18.74, 18.32 |
| `84b34f54` | noq | 18.20, 18.20, 16.98 | 62.92, 62.92, 62.92 — session ends | 21.74, 23.18, 34.62 |
| `ffa5b81b` | noq | 21.12, 23.22, 19.72 | 63.52, 63.52, 63.52 — session ends | 28.44, 33.20, 18.02 |

| Build | Backend | 2 s budget: 5 s outage | 5 % loss | 20 % reorder |
|---|---|---|---|---|
| `fd4f5d82e` | quinn | 7.52, 7.52 | 0.64, 0.00 | 34.62, 37.10 |
| `5d0991b9` | quinn | 13.84, 8.10 | −0.32, 0.00 | 37.30, 36.50 |
| `5d0991b9` | noq | 17.68, 17.56 | 33.58, 32.78 | 37.50, 37.50 |
| `53f8aa99d` | noq | 17.54, 17.68 | 31.96, 32.46 | 37.50, 38.06 |
| `84b34f54` | noq | 16.28, 16.60 | 32.08, 33.34 | 37.78, 37.60 |
| `ffa5b81b` | noq | 17.56, 26.60 | 33.06, 32.04 | 38.10, 37.96 |

Every unimpaired cell conserves to 0.0 s. A negative figure is inside the method's resolution of
about ±1 s.

**Sustained loss is decided by the stack.** One commit, two backends: 0.00 and −0.32 s on quinn,
32.78–33.58 s on noq. `fd4f5d82e` on quinn agrees with the first, and every noq build with the
second. § *Sustained partial loss* gives the mechanism and the CUBIC arm that excludes BBRv3 alone.

**The outage cost rose with the builds, and the stack and the controller add nothing to it.** At 3 s
`fd4f5d82e` loses 4.8–8.5 s and every later build 17.0–23.2 s — **including `5d0991b9` on quinn**,
which loses 17.0–20.6 s against 17.3–18.8 s on noq from the same commit. At 2 s the bisection's pass
left the quinn and noq builds apart (7.5–13.8 s against 16.3–28.4 s), on two quinn cells of one
commit. Six more replicates of that commit on each stack, with both stacks pinned to CUBIC, which
both implement, and to their own `delay`, close the gap ([`t2831-attrib.sh`](scripts/t2831-attrib.sh)
phase `cubic`; same rig and cells):

| `5d0991b9`, 5 s outage, video missing (s) | quinn | noq |
|---|---|---|
| 2 s budget, `delay` (BBRv1 on quinn, BBRv3 on noq) | 17.08, 18.76, 17.68 | 21.84, 17.68, 16.58 |
| 2 s budget, CUBIC | 16.26, 21.52, 18.44 | 20.20, 17.56, 21.96 |
| 2 s budget, `delay`, the bisection's pass | 13.84, 8.10 | 17.68, 17.56 |
| 3 s budget, CUBIC | 18.84, 8.56, 18.52 | 18.24, 17.56, 18.52 |

Every unimpaired cell conserves to 0.0 s. With the 3 s `delay` cells of the bisection table above,
this commit has fourteen 5 s outage cells on each stack. Eleven of the quinn cells fall at
16.3–21.5 s, where all fourteen noq cells fall at 16.6–22.0 s; the other three are the bisection's
pair and one CUBIC replicate at 3 s (8.56 s). So the step is between `fd4f5d82e` and the builds after
it, not between the stacks, and it does not depend on the controller. It is not attributed: unlike sustained loss, a clean break gives a
loss-responsive controller nothing to respond to until the path returns, which is consistent with a
change in the lane's code rather than in its transport.

**The cost came in with upstream's `dev` branch, in at least two steps.** `5d0991b9` merges `dev`
into `main`, and its two parents were probed on the same 5 s outage cell at the 3 s budget, three
replicates each, graded by the programme missing ([`t2831-idle-bisect.sh`](scripts/t2831-idle-bisect.sh)
`JUDGE=missing --step`):

| Build | Where | 5 s outage, video missing (s) |
|---|---|---|
| `fd4f5d82e` | `main`, 2026-09-08 | 8.2, 8.2, 8.2 |
| `1cb2a7360` | `main` at the merge (first parent) | 4.92, 6.4, 7.0 |
| `c74e99d9` | `dev`, 2026-09-02 | 3.92, 4.8, 9.08 |
| `e5a8fb51` | `dev`, 2026-09-13 | 12.76, 11.24, 11.56 |
| `46dc064a` | `dev` at the merge (second parent) | 17.28, 8.82, 17.56 |

`main` never regressed, so the cost is `dev`'s. It rises once between the two `dev` probes and again
after the second, and the tip is bimodal (8.82 s against 17.3–17.6 s), so a median judge misreads it
and each half is bisected on the worst replicate against its own threshold.

**Neither step is attributed to a commit.** Bisected at three replicates a step, both halves end on
a merge of `main` into `dev` — `b22ddbf59` against 10 s and `07f313286` against 14 s — and in each case
both parents pass. The verdicts sit inside the replicate scatter: passing commits in the first half
reach 9.72 s, and `07f313286` fails on one replicate of 38.22 s beside 7.52 s and 7.36 s. A step this
small against the cell's scatter cannot be located by a three-replicate judge, and a merge whose
parents both pass may be an interaction or noise.

**Under a 0.9× capacity step the stack does separate, and the controller does not change that.** The
same `cubic` pass ran the 3 s ladder's 0.9× rung for 60 s: quinn lost 15.90, 20.88 and 19.18 s and noq
22.78, 38.46 and 25.74 s, where under `delay` the same commit lost 9.86 and 13.90 s on quinn (the first
replicate, 54.48 s, lost the programme) against 17.76–21.62 s on noq. The noq side loses more on both
controllers. What in the stack does it is not measured; [T31](test-31-congestion-capacity-ladders.md)
owns the capacity ladder.

**Reorder at 20 % defeats every build and both stacks**, at 34.6–38.1 s, **and neither buffering nor
headroom moves it.** One factor per arm on `ffa5b81b`, relay `delay`, the 2 s matched cell, two
replicates each ([`t2831-attrib.sh`](scripts/t2831-attrib.sh) phase `reorder`):

| Arm | Changed | Video missing (s) |
|---|---|---|
| base | — | 37.38, 37.64 |
| relay send window | 256 KiB | 37.98, 38.32 |
| relay send window | 64 MiB | 37.38, 36.88 |
| subscriber stream receive window | 64 KiB | 37.28, 37.14 |
| subscriber receive windows | 64 MiB connection, 16 MiB per stream | 37.78, 37.52 |
| exporter release budget | 8 s | 37.2, 37.54 |
| bottleneck | 100 Mb/s for 20 | 36.68, 36.54 |
| bottleneck, `5d0991b9` on quinn | 100 Mb/s for 20 | 35.84, 35.46 |

Every unimpaired cell conserves to 0.0 s. How the loss divides between holes and a stream that ends
short varies from replicate to replicate (1.3–30.7 s in holes), so only the total is compared. Five
times the capacity rescues neither stack, so the lane is not starving the link with retransmissions
of packets it wrongly declared lost. Windows anywhere from 64 KiB to 64 MiB and a release budget four
times longer change nothing, so no buffer runs dry. What is left is the sender's rate itself.

**On noq the relay declares reordered packets lost, and its controller cuts its rate by an order of
magnitude.** The same cell, one replicate, with the relay built with the `qlog` feature and writing a
trace per connection (phase `qlog`; it lost 38.1 s, as the base arm did). On the relay's connection to
the subscriber, from the qlog:

| | Unimpaired | 20 % reorder |
|---|---|---|
| Packets declared lost | 0 | 1,619 |
| Of those, acknowledged afterwards | — | **1,619** — every one spurious |
| Packets sent per 10 s, after the impairment starts | 10,245–10,706 | 1,533–3,674 |
| Congestion window, median (p10–p90) | 426,721 B (120,872–538,942) | 30,110 B (19,308–370,226) |
| Pacing rate, median, in the trace's own units | 2,393,316 | 227,795 |
| Smoothed RTT, median | 108.9 ms | 105.8 ms |

The first loss is declared 2 s after the impairment begins and the send rate falls with it. The
smoothed RTT does not move, so this is not queueing: `netem` delivers every packet, the relay declares
reordered packets lost that the subscriber then acknowledges, and BBRv3 takes the loss as congestion
and holds its window at about a fourteenth of the unimpaired one. This is measured on `ffa5b81b`, noq,
BBRv3, and it explains why capacity, windows and budget are irrelevant here.

The trace does not say which of noq's two loss rules fired. A packet is declared lost once three later
packets are acknowledged (the packet threshold) or once it is 9/8 of an RTT old with a later one
acknowledged (the time threshold). The trace labels all 1,619 `reordering_threshold`, but its qlog
code computes the send time minus the present, which saturates to zero, so it can label no loss by
time (§ *Corrections*).

**On noq, relaxing both loss rules removes almost the whole reorder cost; relaxing either alone
removes none of it.** The same cell on `ffa5b81b`'s relay patched to take noq's two thresholds from
the environment (`t2831-loss-thresholds-noq.patch`; phases `pthresh` and `thresh`), two replicates
per arm under a qlog. A packet threshold of 1000 cannot fire. A time threshold of 2 RTT clears the
cell's reordering, which overtakes a packet by at most the 50 ms one-way delay:

| noq relay | Programme missing | Declared lost | Of those, acknowledged afterwards | Window median after |
|---|---|---|---|---|
| Default (3 packets, 9/8 RTT) | 37.38–38.1 s | 1,619 | all | 26,958 B |
| Packet threshold 1000 only | 34.90–36.22 s | 12,749–17,856 | 80–90 % | 88,824–95,585 B |
| Time threshold 2 RTT only | 36.72–36.92 s | 1,347–5,131 | 43–100 % | 24,480–34,347 B |
| **Both** | **2.12–3.0 s** | 2,779–3,308 | 25–42 % | 196,676–211,200 B |

*Measured, P1, on `ffa5b81b`, noq, BBRv3, the 2 s matched cell. The default row's programme range
spans the unpatched base arm (two replicates) and the `qlog` arm (one); its loss and window figures
are the `qlog` arm's. Window medians are the summariser's (`t2831-qlog-summary.py`), which samples the
metric differently from the first table: on the default-threshold trace it reads 486,626 B before the
impairment and 26,958 B after.*

Either rule alone declares enough reordered packets lost to hold the window down. With the packet
rule out of play the time rule declares about ten times as many losses, most of them spurious. With
the time rule relaxed alone, the packet rule declares them as before. So both have to be relaxed.
With both relaxed the relay still declares a few thousand packets lost, most of them never
acknowledged, and the lane delivers all but 2–3 s. So on noq the reorder cost is the stack's loss
detection, not the lane or its buffering. The fix is a configuration the relay does not expose. RFC
9002 permits a sender to raise its thresholds when it sees spurious loss, and neither stack does.

**quinn declares two-thirds of its packets lost, and its window collapses too.** The same cell on
`5d0991b9`'s relay on quinn (BBRv1), built with qlog (phase `qlog-quinn`, one replicate), lost 37.78 s,
all of it as a stream short at close. On the relay's connection to the subscriber it declared 55,546
of the 84,005 packets it sent lost, from 22.0 s, the moment the impairment starts, and its window
median fell from 12,128,845 B before to 183,580 B after; the smoothed RTT stayed at about 100 ms.
quinn's trace carries no frames, so whether those packets were acknowledged later is not recorded,
and its loss labels have the same defect as noq's. BBRv1's bandwidth model ignores loss, but quinn's
BBRv1 also bounds its window by packet conservation while in recovery (`quinn-proto` 0.11.17,
`congestion/bbr`), which a continuous stream of declared losses would hold it in.

**On quinn the same relaxation keeps the window and does not save the programme.** Two replicates on
the patched `5d0991b9` relay, both thresholds relaxed. The programme missing is 27.42 s and 32.36 s.
The window median after the impairment starts is 407,757–441,497 B, against 183,580 B with the
default thresholds. The first loss moves from 22.0 s to 24.5–25.7 s. Yet the relay still declares
86,272 of its 126,940 packets lost and 83,694 of 117,810, 68–71 %. Under a 2 RTT time threshold, a
packet overtaken by 50 ms is not declared lost. So these packets were plausibly dropped, or delayed
by more than two round trips, and quinn's reorder cost would then lie outside loss detection. That
reading is not established: quinn's trace carries no frames and does not record its thresholds, and
the rig does not sample the bottleneck's drop counter. The arm that settles it is the same cell with
`tc -s qdisc` sampled at the shaper.

**At an outage equal to the idle timeout, only builds from before upstream's `dev` merge survive,
because one commit on that branch closes a broadcast with its session.** 30 s is the default idle
timeout on both ends of every build here, so the cell sits on the boundary, and on every build the
session times out inside it: each subscriber logs `session closed, reconnecting`, drops every track
and schedules a reconnect. On the older builds the client keeps the broadcasts that session fed
alive for the reconnect loop's give-up budget plus one second — 11 s by default — so the exporter
survives if the reconnect resubscribes inside that window. On `fd4f5d82e` the container consumer
takes the dropped tracks as an evicted group (`Hang(Moq(Dropped))`), and in all three 30 s cells the
client reconnected and resubscribed to the catalog and every track about 1.4 s later, so the cell
costs the outage and little more. **At 40 s, where the reconnect waits about 10 s for the path — the
edge of that window — `fd4f5d82e` loses in one replicate of two**: one replicate resubscribed
(43.0 s missing), and the other logged the same eviction and then exited `json: dropped` (72.92 s
missing, all of it short at close) ([`t2831-attrib.sh`](scripts/t2831-attrib.sh) phase `idle`). On
every later build `moq export ts` exits `json: dropped` at the session drop, before any reconnect —
the exit [#3926](https://github.com/moq-dev/moq/issues/3926) asks about, reached through a transport
outage alone.

**The change is `e2c603c5`, "remove linger; a broadcast closes with its last source"
([#2704](https://github.com/moq-dev/moq/pull/2704)), made on `dev` and reaching `main` with that
branch's merge, `5d0991b9` ([#3793](https://github.com/moq-dev/moq/pull/3793)).** Bisected on the
30 s cell, two replicates a step ([`t2831-idle-bisect.sh`](scripts/t2831-idle-bisect.sh)), every
`main` commit up to the merge survives in both, and the first that does not is the merge. Inside
`dev`, judged on the exit itself, `e2c603c5` exits `json: dropped` in both replicates and the three
commits tested below it, its parent among them, survive in both. The commit's removed documentation
states the mechanism: broadcasts fed by a reconnecting session "linger across a session drop for as
long as the reconnect loop keeps retrying", so that "consumers ride out a relay restart instead of
tearing down". The same change ends T6's relay-restart drill on the build under test
([T6](test-6-relay-resilience.md) § *Transport-resilience drills*).

**A supervisor restores the older build's figure.** With the ladder restarting the exporter whenever
it exits (`SUPERVISE=1`, [`t2831-attrib.sh`](scripts/t2831-attrib.sh) phase `supervise`), `ffa5b81b`
loses 34.72 s in both replicates of the 30 s cell, against 63.52 s unsupervised and 33.32–33.64 s on
`fd4f5d82e`; each replicate restarted its exporter once, after `json: dropped`. The capture after the
restart is a second process's stream appended to the first, graded on content like any other.

The branch failed the same cell in two other ways on the way there, which a bisection judged on
survival alone could not separate from this one, and neither is seen on any later build. A reconnect
stall — output ends at the teardown, the client schedules its reconnect and never dials, and nothing
errors — entered `dev` from `main` at its 29 July merge: that merge's `main` parent `27df65e3` stalls
in 4 of 4, its `dev` parent `fc6efefa` survives 4 of 4, and `main` had fixed it by 29 August, when
`d59008da` survives 2 of 2. Between 31 July and 5 August the exporter also exited
`hang: moq error: old`. The deployment rule in § *The 30 s cell was the QUIC idle timeout* is
unaffected: raising the timeout keeps the session up on every build.

¹ **Re-run separately.** In the bisection's own pass the `5d0991b9` 5 s outage and 0.9× cells were
void on both backends: that build's relay drains its sessions on SIGTERM for longer than the ladder's
one-second teardown allowed, so each of those cells found the port still held
([method-notes](method-notes.md) § *A replicate loop inside one script invocation re-uses the fixed
port*). The ladder now waits for the relay to exit, and these cells come from
[`t2831-bisect-redo.sh`](scripts/t2831-bisect-redo.sh), same rig and settings, every relay confirmed
started. ² The first replicate lost its sound as well (62.38 s): the session did not carry the
programme past the rung, which the other two did.

**One earlier capture confirms the oldest build's lower figure.** The single retained capture of the
original `fd4f5d82e` pass — a 5 s outage at 3 s — holds 0.20 s in holes and is an estimated
2.8–3.4 s short at close, within that budget; the other cells of that pass were not kept and are
withdrawn with their PCR grades (§ *Corrections*).

**Continuity errors are 0 in every MoQ cell**, and on this lane that is the exporter writing its own
counters over whatever it re-muxes: it measures nothing
([method-notes](method-notes.md) § *A continuity count detects loss and cannot measure it*).

### The budget ladder, and the nominal budget is not a latency setting

Run as the MoQ half of [P1-m](planned-experiments.md), whose purpose is a matched-buffer comparison
against SRT. This pass ran the MoQ half only, on a rig with two defects since found and fixed, so
**nothing in this section ranks the two architectures**; the ranking is in §*The matched ladder*.
What this pass delivers is the measured result that changed how the comparison had to be set up.

**Environment.** As above, but build `moq` 0.11.2-`5d0991b9` on quinn (BBRv1 under the unset
controller), rig [`t28-t31-srt-ladder.sh`](scripts/t28-t31-srt-ladder.sh), and an inline
PES-timestamp tap (`t18-latency.py`) on both sides of the lane so delivery latency is measured
rather than assumed. Both namespaces are on one host, so the two taps share a clock and the offset is
0. 5 s total outage, three replicates per budget, `cake` at 20 Mb/s, 100 ms base RTT. Point **P1**.
The captures were not kept; the figures are the taps' picture count, conserved against each budget's
clean cell.

Video missing at close against the same 5 s outage, in seconds:

| `--max-age` | rep 1 | rep 2 | rep 3 |
|---|---:|---:|---:|
| 0.5 s | 23.34 | 20.24 | 9.74 |
| 1 s | 13.22 | 15.10 | 17.15 |
| 2 s | 21.26 | 21.04 | 15.10 |
| 3 s | 18.97 | 15.16 | 16.89 |
| 4 s | 20.42 | 14.95 | 18.37 |
| 6 s | 13.88 | 12.77 | 8.73 |

**A 5 s outage cost 8.7–23.3 s of picture at every budget, and the budget sets no trend in it.** The
lowest cell is at 6 s and the next lowest at 0.5 s; every budget's replicates overlap every other's.
The pass also carried two inline tap stages that the rig corrections below removed, so these cells
are superseded for the lane result by § *The build bisection*; what it still carries is the latency
result that follows.

#### `--max-age` does not set delivery latency on a healthy path, which invalidates the obvious way to match buffers

This is the result P1-m was built to establish before comparing anything, and it is negative.

| `--max-age` (nominal) | measured median latency, unimpaired | measured median latency, post-outage (3 reps) |
|---|---:|---|
| 0.5 s | 1943 ms | 2550 / 3180 / 5838 ms |
| 1 s | 1654 ms | 5521 / 6433 / 6444 ms |
| 2 s | 1985 ms | 1581 / 1803 / 7407 ms |
| 3 s | 1899 ms | 9069 / 7781 / 8995 ms |
| 4 s | 1418 ms | 9399 / 8975 / 9758 ms |
| 6 s | 1661 ms | 10823 / 10857 / 10723 ms |

**Unimpaired, a twelve-fold change in the nominal budget produces no trend in delivered latency** —
every cell lands between 1.42 s and 1.98 s, and 4 s is the *fastest* of the six. **After the outage,
latency scales with the budget**, from ~2.5–5.8 s at 0.5 s to a very tight ~10.7–10.9 s at 6 s.

*These cells predate the rig corrections below and carry two inline tap stages, so the absolute
figures are rig-inclusive; the sound-rig replication is in §*The matched ladder*, which reproduces
both effects — no unimpaired trend, and post-outage latency scaling with the budget — and adds the
SRT comparator this pass lacked. Quote that section's figures, not these.*

So `--max-age` is not an end-to-end delay budget in the sense SRT's `--latency` is. It is the amount
of *recovery* delay the subscriber will accept before it gives up on a group, and on a healthy path it
is not spent at all: the lane delivers at its own floor whatever the number says. SRT's `--latency`,
by contrast, is a fixed delay inside which retransmission may complete, and it is spent continuously.

**Consequently, setting `--max-age 2s` against `--latency 2000` is not a matched comparison, and an
SRT arm built that way would produce a ranking that looks like a result and is not one.** The correct
design — and what the SRT arm must use — is to set SRT's `--latency` to the MoQ lane's *measured*
unimpaired delivery latency, then compare programme loss against the same outage. That is a change to
the experiment, and it is the main thing this run bought.

Two qualifications on the absolute figures. They are **rig-inclusive**: the ~1.4–2.0 s floor contains
`tsp regulate --pcr-synchronous`, two inline tap stages and their pipes, so it is not a figure for the
lane alone and must not be quoted as one. What is robust to a constant offset is the **invariance
across budgets** and the **post-outage scaling**, and those are the findings.

#### The SRT lane's budget *is* its delivered latency, and on this pass the arm was not yet comparable

The SRT lane now produces cells, at budgets {1, 2, 3} s. Its latency behaviour is the exact complement
of the MoQ lane's:

| SRT `--latency` | measured median delivery latency | spread across the window |
|---|---:|---:|
| 1 s | **1050.2 ms** | 74 ms |
| 2 s | **2050.3 ms** | 74 ms |
| 3 s | **3050.2 ms** | 74 ms |

Nominal plus one-way path delay, to a tenth of a millisecond, every time. **So the two lanes'
"latency" parameters are different quantities**: SRT's is a fixed end-to-end delay that is always
spent, MoQ's is a recovery allowance that is spent only on failure. Equating the two numbers — the
obvious way to build this comparison, and the way it was originally specified — compares a lane
running at 2.05 s against a lane running at 1.9 s *and* holding 2 s of recovery headroom. That is not
one buffer measured twice. *`MATCH_FILE` is the fix, and §*The matched ladder* is the comparison this
paragraph was blocking.*

**The loss figures from this arm are nevertheless void, and the reason is the instrument.** The SRT
controls do not grade clean: unimpaired cells lost 4.196–5.391 s with 5,704–8,930 continuity errors.
Re-run through the identical netns path **with the inline tap removed**, the same lane graded
**0.000 s lost, 0 holes, 0 continuity errors** over a 27.7 s span. A pass-through tap was corrupting
the transport stream — or rather, as the next section establishes, the **split publisher** that a
source-side tap forces; the egress tap is harmless — and **the MoQ lane never showed it** because `moq export ts` re-synthesises the stream at
egress and regenerates the continuity counters, laundering any upstream damage. Had the SRT
controls been omitted, this rig would have reported SRT as catastrophically worse than MoQ on entirely
fabricated evidence. Method rule in [method-notes](method-notes.md) § *An inline instrument damaged
one lane and was invisible on the other*.

**What the SRT arm needs before it can rank anything**: a latency tap that mirrors rather than passes
through, and then SRT's `--latency` set to the MoQ lane's *measured* unimpaired delivery latency
rather than to its nominal budget. Both are changes to the rig, not to the question. **The first is
now built and validated** — see below; the second is outstanding.

#### The artefact attributed: it is the source-side *process split*, and the Python tap only forced one

The paragraph above named "the pass-through tap" without saying *which* of the two the rig ran. There
were two — one between `regulate` and the SRT sender, one on the egress — and they do not behave
alike. Five arms on one clean SRT lane, differing only in how the stream is observed
([`t18-tap-perturbation.sh`](scripts/t18-tap-perturbation.sh), `53f8aa99d` host, netns at 20 Mb/s and
100 ms RTT, `--latency 2000`, 60 s per arm):

| arm | what observes the stream | media lost | continuity errors | pictures seen |
|---|---|---:|---:|---:|
| `none` | nothing — the reference | **0.000 s** | **0** | — |
| `inline` | egress tap, in the path | **0.000 s** | **0** | 2,099 |
| `mirror` | egress tap, off a `tsp -P fork` copy | **0.000 s** | **0** | 2,099 |
| `src-inline` | **source** tap, in the path | **4.693 / 4.563 s** | **6,001 / 6,493** | 2,206 |
| `src-mirror` | **source** tap, off a `tsp -P fork` copy | **0.000 / 0.000 s** | **0 / 0** | 2,154 |

*Two cells are quoted twice because the source arms were replicated; the two runs agree on the
picture counts exactly and on the loss to within 0.13 s.*

**The egress tap is innocent and the damage is entirely on the source side.** `src-inline` lands
inside the originally observed 4.196–5.391 s and 5,704–8,930 continuity errors, so the defect is
reproduced rather than merely hypothesised; `inline` sits at zero on the same rig in the same session.

**But "the source tap" is not the cause — the process split it requires is.** These five arms cannot
separate the two, because the only way to put a Python reader in the source path is to break the
publisher into `tsp … -O file - | python3 … | tsp -I file - -O srt`, which also takes
`regulate --pcr-synchronous` out of the process that owns the SRT sender. The arm that separates them
came later, from the P1-m ladder itself: its SRT publisher kept the two-`tsp` split for unrelated
reasons while running `SRC_TAP=mirror`, so **no Python sat in the path at all** — and it graded
**4.601 / 4.602 s lost with 6,104 / 6,133 continuity errors**, reproducing `src-inline` to within
0.1 s and 400 errors. It also delivered **65.0 s of programme in a 60 s run** against the MoQ lane's
57.1 s on the same rig, which is the tell: the transmitter had lost its pacing and was running ~8 %
fast. Collapsing the publisher back to a single `tsp` holding both `regulate` and `-O srt`, with the
tap still mirrored, returned **0.000 s lost, 0 continuity errors and a 57.6 s span**, and a median
delivery latency of 2,028.1 ms against a commanded 2,029 ms.

**So the rule is about process boundaries, not instrumentation.** `regulate --pcr-synchronous` paces
a stream against its own PCRs; a pipe to a second `tsp` puts an unpaced buffer between that clock and
the transmitter, and a live SRT sender drops rather than waits. `tsp -P fork --nowait --ignore-abort`
is the right way to observe the source not because it avoids Python but because it keeps the whole
chain in one process: it hands the tap a *copy* while the main chain continues to its output.
`src-mirror` grades identically to the untouched reference while still seeing 2,154 pictures against
`src-inline`'s 2,206 — the instrument survives the change, which is the half that makes it a fix
rather than a removal.

*One run per arm for the egress three; the two source arms replicated; the separating evidence from
the P1-m SRT ladder, two cells plus a single-cell control. Domain: file, on the subscriber's capture.
This validates fidelity only.*

#### …but mirroring the *egress* tap breaks the other half of what it measures

The obvious conclusion from the table above is "mirror both taps", and it is wrong. A tap does two
jobs — preserve the stream and timestamp its arrival — and `tsp -P fork` fixes the first by breaking
the second: the tap now reads its copy from the far side of `tsp`'s internal buffer, so it records
when `tsp` got round to forwarding a packet rather than when the packet arrived. One MoQ cell at
`--max-age 2s`, unimpaired, three rigs differing only in where each tap sits:

| source tap | egress tap | media lost | continuity | delivery latency, median | spread |
|---|---|---:|---:|---:|---:|
| mirror | **inline** | 0.000 s | 0 | **2,047.1 ms** | 618.6 ms |
| mirror | **mirror** | 0.000 s | 0 | **5,278.9 ms** | 6,987.1 ms |
| inline | **inline** | 0.000 s | 0 | **2,056.6 ms** | 590.2 ms |

**Mirroring the egress tap adds 3.2 s to the measured latency and multiplies its spread elevenfold**,
against a figure the other two rigs agree on to 9.5 ms. Nothing about the *stream* differs — all three
grade 0.000 s lost and 0 continuity errors — so a rig validated on fidelity alone would have passed
this and then reported MoQ as three times slower than it is.

**So the defensible rig is asymmetric, and each side is chosen on a measurement rather than a
principle:** mirrored at the source, where inline destroys the stream and where MoQ's re-multiplexing
means the tap position does not move the timing figure anyway (2,047.1 against 2,056.6 ms); inline at
the egress, where a pass-through tap is harmless and is the only position that sees true arrival.
`SRC_TAP` and `EG_TAP` in
[`t28-t31-srt-ladder.sh`](scripts/t28-t31-srt-ladder.sh) keep both claims falsifiable.

*The second rig change the arm needs — matching SRT's `--latency` to the MoQ lane's measured delivery
latency rather than its nominal budget — is implemented as `MATCH_FILE` and is exercised below.*

One incidental rig defect worth keeping, because it cost a whole pass: TSDuck's `tsp` does not start
its output plugin until the `regulate` input stage has filled, which takes **~8 s** with this source,
and TSDuck's SRT caller does not retry. A 3 s sleep between starting the listener and starting the
caller voided every SRT cell in the first pass, with nothing in the publisher's log to say why. The
rig now polls for the bound port and marks a cell `nobind` if it never appears.

### The matched ladder: MoQ loses more of a 5 s outage than SRT at every budget, and pays in latency as well

With the rig sound on both sides, the ladder ran matched: the MoQ lane first, its **measured**
unimpaired median delivery latency at each budget written to `MATCH_FILE`, then the SRT lane with
`--latency` set to that figure rather than to the nominal budget. Two replicates per outage cell, one
unimpaired control per budget, 60 s cells, 5 s total outage applied mid-window by `set_loss 100`.
Build `53f8aa99d` (noq, BBRv3 under the unset controller, padded by default — padding is applied at
the subscriber, after the link, and does not move these cells:
[T31](test-31-congestion-capacity-ladders.md)), netns at 20 Mb/s and 100 ms RTT, source tap mirrored,
egress tap inline. The captures were not kept, so both lanes are graded here on the taps' picture
count, conserved against each budget's clean cell.

**The match holds.** Both lanes grade 0 pictures missing and 0 continuity errors on every unimpaired
cell, and SRT delivers the latency it is commanded to within about a millisecond — 2,028.1 ms against
a commanded 2,029 ms on the control cell. The MoQ lane's own unimpaired latency is **1,845–2,125 ms
across a twelve-fold sweep of `--max-age`**, which restates in the matched rig what §*`--max-age`
does not set delivery latency* found: the commanded budget is not the standing latency.

Under the outage, both replicates:

| `--max-age` / matched `--latency` | MoQ video missing | MoQ late-window latency | SRT video missing | SRT late-window latency |
|---|---:|---:|---:|---:|
| 0.5 s | 15.30 / 15.96 s | 4,535 / 4,494 ms | 5.01 / 5.04 s | 2,298 / 2,300 ms |
| 1 s | 19.99 / 19.99 s | 6,444 / 6,628 ms | 5.37 / 5.34 s | 2,028 / 2,028 ms |
| 2 s | 16.81 / 20.21 s | 6,635 / 9,593 ms | 5.22 / 5.25 s | 2,172 / 2,189 ms |
| 3 s | 17.86 / 20.50 s | 8,057 / 9,721 ms | 5.42 / 5.10 s | 2,240 / 2,238 ms |
| 4 s | 16.86 / 15.58 s | 8,121 / 8,379 ms | 5.23 s | 2,021 ms |
| 6 s | 15.08 / 15.27 s | 12,268 / 10,707 ms | 5.36 / 5.16 s | 2,205 / 2,213 ms |

**The MoQ lane lost 15.1–20.5 s of picture to a 5 s outage, three to four times SRT's 5.0–5.4 s, and
`--max-age` did not buy any of it back.** There is no trend with the allowance: the 0.5 s and 6 s rows
are the two lowest. SRT's figure here is higher than the 3.46–3.76 s its PCR grading gives, because a
picture damaged by the outage's edge is not counted as delivered by the tap; the PCR figure is valid
for SRT's verbatim stream, and the ranking is the same on either.

**The allowance is spent in delivery latency all the same, and that latency does not come back
inside the window.** Late-window latency rises with the allowance, from ~4.5 s at the 0.5 s budget
to 10.7–12.3 s at 6 s, against a ~2 s unimpaired baseline on the same cells. **The induced latency is
not bounded by the allowance that induced it**: at a 6 s `--max-age` the lane runs roughly twice that
far behind. The plausible mechanism is contention — backfill and live share one shaped 20 Mb/s egress,
so a deeper allowance means more backfill, which means falling further behind — but this rig does not
separate that from the subscriber's own scheduling, and the attribution is **unproven**. So on this
build the lane pays for an outage in both currencies at once: more programme lost than SRT, and a
latency step SRT does not take.

**SRT's trade is the clean one.** Its loss is pinned near the outage length at *every* budget,
because its allowance is a fixed delay rather than an allowance. Its latency is pinned at the
commanded value across the outage, moving **+0.5 to +19.8 ms** first third to last third. It never
falls behind, and it never catches up, because it never tries.

**Continuity errors are not comparable across these lanes and should not be read as a quality
ranking.** MoQ returns **0** in every cell and SRT **927–2,451**, but that is a property of the
egress: `moq export ts` re-synthesises the stream and regenerates continuity counters, so damage
upstream of it is laundered, while SRT passes the transport through verbatim. The same effect hid the
rig defect described above.

*Two anomalies, both explained and neither a lane result.* One SRT cell (4 s, replicate 2) graded a
**19.8 s** span against ~57.6 s elsewhere and is excluded as a short capture; it is the reason that
row carries one replicate. And the *median* latency disagreed between MoQ replicates at the 3 s budget
(7,936 against 2,184 ms) purely because a median over a window containing a step depends on where in
the window the step fell — that cell's p95 was 9,868 ms and its trend 1,896 → 9,721 ms, in line with
its sibling. **The late-window figure is the statistic reported above for exactly this reason.**

*Point P1; picture counts and delivery latency from the taps at the subscriber's egress — latency to
a file sink, not to a decoder with a bounded buffer, which would have to drop or drift instead of
lagging. Single host, one netns path at 20 Mb/s and 100 ms RTT; not cross-host. One build: the
[build bisection](#the-build-bisection-the-lane-lost-ground-between-builds-and-the-backend-decides-the-loss-shape)
repeats the 2 s row on four others.*

#### The 30 s cell was the QUIC idle timeout, and bracketing it separates a starved session from a dead one

30 s is the default `--quic-idle-timeout` on **both** the relay and the client, so a 30 s outage
straddles the point where the session dies rather than starves. Running three outages either side
of that boundary separates the two. Six cells, one replicate each, build
`53f8aa99d`, `--latency-max 3s`, the namespace rig at 20 Mb/s and 100 ms RTT; the only variable is
`MOQ_QUIC_IDLE_TIMEOUT`, which both binaries honour.

Graded on content from 8 s in; video present against the ~64, ~74 and ~84 s the 75, 85 and 95 s
windows should hold (estimated from the bisection's clean cells on the same ladder, since this
run's own controls were not kept):

| outage | idle timeout **30 s** (default) | idle timeout **120 s** |
|---|---|---|
| 20 s | 16.74 s present, 22.92 s in holes | 22.44 s present, 28.32 s in holes |
| 30 s | **session dead**: 23.5 MB, capture not kept | 15.70 s present, 46.72 s in holes |
| 40 s | **session dead**: 23.6 MB, capture not kept | 15.64 s present, 41.72 s in holes |

**At the default, an outage that reaches the idle timeout ends the session and it does not come
back.** Both the 30 s and the 40 s cells terminate with `Caused by: dropped` in the subscriber log,
capture about a third of the bytes the surviving cells do, and never resume inside the window.
**Move the timeout out of the way and the session survives, but the picture does not come back
with it.** About 12 s of each window precedes the outage, so the 15.6–22.4 s present at 120 s is
that plus 3.6–10.4 s of picture over the 34–54 s after the outage ends. The 40 s cell logs
`current group evicted; skipping to next buffered group … Hang(Moq(Old))`, which is
[#3515](https://github.com/moq-dev/moq/pull/3515)'s skip working as intended rather than an exit;
what it skips to arrives sparsely. The PCR grader had read these cells as 1.975, 21.850 and
40.725 s lost — ordinary starvation scaling with the outage — and on content they are not.

**So the 30 s cell measures teardown, not a gap.** The deployment rule is the durable part: **`--quic-idle-timeout` must exceed the
longest transport outage the route is expected to ride through**, on both ends, and its 30 s default
is below the outage lengths a satellite or terrestrial contribution path can present.

**The failure mode is the one [#3926](https://github.com/moq-dev/moq/issues/3926) asks about, reached
by a route that issue did not describe.** That question was filed about the publisher going away;
here the publisher never left — a transport outage alone produced the same `dropped` exit. An
exporter that exits rather than waiting is off air permanently where a reconnecting one would have
been degraded for 40 s.

> **And the grader says the dead cells are perfect.** Both report **0.000 s media lost, 0 holes and 0
> continuity errors**, because a capture that simply stops has nothing after the hole to compare
> against. Only the byte count and the span reveal it. This is the second time in this experiment
> that a truncated capture has scored as a flawless cell — see the excluded SRT cell in §*The matched
> ladder* — and it is now a standing check rather than an observation.

#### The lane does not re-converge: it steps once and holds the new latency

The 60 s cells above could not distinguish a lane still falling behind from one that had settled at a
worse operating point, because each window ended while the figure was still moving. A longer pass
settles it. Two cells at the 2 s and 6 s budgets, same rig and same 5 s outage, run out to **117.8 s
of wall clock — about 93 s after the outage, against roughly 35 s in the short cells.** Plotting
delivery latency *added since the first sample* against wall clock:

| budget | latency added by t≈45 s | over the remaining ~74 s | drift across that span |
|---|---:|---:|---:|
| 2 s | 7.33 s | 7.26 – 7.66 s | **+0.24 s** |
| 6 s | 11.85 s | 11.81 – 12.23 s | **+0.19 s** |

**The step is a step, not a ramp.** Latency climbs once while the backfill is delivered, reaches its
new level within about 20 s of the outage ending, and then holds flat to within a quarter of a second
for the next seventy-odd seconds. It neither continues to degrade nor recovers: over ~75 s of healthy
path after a 5 s outage, **the lane gives back none of the delay it took on**. Absolute late-window
latency on these two cells is **8,036 ms** and **12,538 ms**, consistent with the short cells.

This corrects a reading the short cells invited. The large "trend" figures there — up to +10.5 s
first-third to last-third — were the *transition* being captured mid-step, not evidence of unbounded
growth, so the 60 s numbers are settled values rather than the lower bounds they first appeared to
be.

**The operational consequence is the one R4 names.** A lane that permanently absorbs an outage into
its delivery latency has a buffer that is neither bounded nor stable across a fault, and
[`problem.md`](../docs/problem.md) §5 treats a drifting buffer as itself a fault for downstream
playout and ad insertion. On this evidence the MoQ lane re-times the service after an outage as well
as losing more of it than SRT does, and nothing observed here re-times it back.

*Both cells ran one replicate. The window was limited to 117.8 s by the source clip rather than by
the commanded `RECOVER=280`, so "does it recover after several minutes" remains formally open — but
a lane flat to ±0.24 s over 75 s is not converging on any timescale that matters to the question.
Same domain and topology caveats as the matched ladder above.*

### Sustained partial loss: SRT loses nothing, and the MoQ lane's picture stops unless its controller ignores loss

Same rig, same clip, same `cake` 20 Mb/s / 100 ms RTT netns, two replicates. The impairment is
sustained rather than a burst: after the 20 s settle, netem loss is applied for the remaining 40 s of
the 60 s window. Budgets 0.5 / 2 / 6 s, and the SRT arm is matched on the MoQ lane's *measured*
latency at each budget via `MATCH_FILE`, as the outage ladder was. Build `53f8aa99d` (noq, BBRv3);
video missing at close from the taps, as above.

| impairment | budget | MoQ video missing (s) | MoQ late-window latency (ms) | SRT video missing (s) | SRT latency (ms) |
|---|---:|---:|---:|---:|---:|
| none | 0.5 / 2 / 6 | 0 / 0 / 0 | 2,165 / 2,016 / 2,012 | 0 / 0 / 0 | 2,164 / 2,014 / 2,011 |
| 5 % | 0.5 | 25.75, 28.28 | 2,604, 1,734 | **0, 0** | 2,164, 2,164 |
| 5 % | 2 | 26.60, 28.02 | 1,824, 1,985 | **0, 0** | 1,998, 2,016 |
| 5 % | 6 | 23.39, 26.57 | 1,831, 2,027 | **0, 0** | 2,012, 2,012 |
| 10 % | 0.5 | 31.43, 29.41 | 2,617, 2,667 | **0, 0** | 2,164, 2,164 |
| 10 % | 2 | 30.83, 31.46 | 1,988, 1,983 | **0, 0** | 2,014, 2,014 |
| 10 % | 6 | 28.99, 29.90 | 1,987, 1,993 | **0, 0** | 2,011, 2,011 |

**SRT lost no programme in any of the twelve impaired cells**, at 5 % or 10 %, with zero continuity
errors and a full picture sample. **The MoQ lane lost 23.4–31.5 s of a 60 s window in every one**,
most of the 40 s the loss was applied for. The latency column is taken from the pictures that did
arrive, and they arrived on time: the lane did not fall behind, it stopped delivering picture.

**The QUIC stack decides this cell, through what its controller does with random loss.** The
[build bisection](#the-build-bisection-the-lane-lost-ground-between-builds-and-the-backend-decides-the-loss-shape)
runs the 2 s / 5 % cell on both backends of one commit: on quinn it loses **0.00 and −0.32 s**, on
noq **32.78–33.58 s**; `fd4f5d82e` on quinn loses 0.00–0.64 s. And on `ffa5b81b` pinning the relay to
CUBIC instead of BBRv3 does not rescue it (36.86–37.50 s against 30.34–33.88 s at 5 %, across the
three budgets). What the two quinn
builds share, and none of the others has, is **BBRv1, which does not treat loss as a congestion
signal**; BBRv3 and CUBIC both do. The reasoned mechanism is the one that bounds any loss-responsive
sender: at 5 % random loss and 100 ms RTT such a sender is held far below a 10 Mb/s stream (the
Mathis bound gives about 0.5 Mb/s for a Reno-like one), so the backlog grows until the subscriber's
deadline discards it. SRT's live mode has no congestion controller at all: it retransmits inside a
fixed delay at whatever rate the loss demands, and at ~2 s of buffer over a 100 ms RTT there is room
for many attempts. **So this cell measures whether the lane's sender yields to random loss**, and
the lane rides it only with a controller that does not — a property that also lets a sender take
more than its share from competing traffic on a genuinely congested path, which is reasoned here and
consistent with BBRv1 barely registering a competing flow in [T8b](test-8b-congestion-control.md).

**The SRT arm is not a budget sweep**, and matching on measured latency is why. MoQ's measured
latency is ~2 s at every nominal budget, so the three matched SRT settings are 2,165 / 2,016 /
2,012 ms — one buffer, run three times. The row therefore establishes SRT's behaviour at ≈2 s and
says nothing about SRT at a shallower one. A genuine SRT budget sweep under sustained loss is a
separate cell and is not run here.

*Point P1; SRT and MoQ both graded on the taps' picture count against each budget's clean cell, which
grade 0 missing. Two replicates per cell. Co-resident netns, so the figures are not a cross-host
deployment claim. The content grader finds **no repeated pictures** in any of the 66 outage, loss and
reorder captures of the bisection and the `ffa5b81b` re-run, so the 5.95–41.6 s of "duplication" the PCR grader reported on these
cells was its own: the exporter's PCR does not track what was delivered. Continuity errors are not
comparable between the lanes — `export ts` re-synthesises SI, so MoQ reads 0 by construction — and
are not netted into loss anywhere above.*

### Reorder: SRT delivers every picture and damages the stream, MoQ keeps the stream clean and loses most of the picture

Same rig and the same matched budgets, build `53f8aa99d`. `netem ... reorder P% 50%` against the existing 50 ms delay,
so the reordered packets are the ones sent early and the arm costs no extra latency — ordering is
isolated from the loss and latency axes rather than confounded with them. Held for the last 40 s of
the window, as the loss arm is. Two replicates.

**At 5 % reorder neither lane moves.** SRT misses no pictures and takes no continuity errors; MoQ
misses 0–0.63 s, inside the clean cells' resolution.

**At 20 % reorder the lanes fail in opposite directions, and the MoQ failure is the larger:**

| | SRT | MoQ |
|---|---|---|
| video missing at close | **0.00–0.17 s in all six cells** | **33.36–35.09 s in all six** |
| continuity errors | 430–692 in four of six cells | 0 everywhere, by construction |
| pictures delivered | 2,019–2,026 of 2,026 | 767–821, against 1,996 unimpaired |

**SRT is byte-transparent, so reordering arrives as damage rather than absence** — every picture is
there, and several hundred continuity errors are in the stream carrying them; what a decoder makes of
those is not measured here. **The MoQ lane's output stays syntactically clean and loses more than half
the window's picture.** The matched-picture collapse that this file previously held as a caveat on
the latency column is the loss itself: the taps pair fewer pictures because fewer arrive. **No latency
figure is drawn from these cells**, because the ~40 % of pictures that did arrive are not a sample of
the ones that did not.

The bisection runs the 2 s / 20 % cell on every build and both stacks, and **every one loses
30.8–38.3 s** — `fd4f5d82e` on quinn included — so unlike sustained loss this shape is not the
backend's, and with CUBIC pinned on `ffa5b81b` it is not the controller's either (34.66–37.7 s). On
noq it is the stack's loss detection: the relay declares reordered packets lost, and relaxing both
loss thresholds brings the cell to 2.12–3.0 s (§ *The build bisection*). On quinn the same relaxation
keeps the window and not the programme, so quinn's cost is not attributed.

*Point P1, both lanes graded on the taps' picture count against each budget's clean cell. Two
replicates per cell, one control per budget, single host and namespace path at 20 Mb/s and 100 ms
RTT, so not cross-host. Continuity errors are not comparable between the lanes — `export ts`
re-synthesises SI and reads 0 by construction — and are not netted into loss. The matched SRT arm is
again one buffer (≈2 s) run three times rather than a sweep, for the reason in
§*Sustained partial loss*.*

### The rig's delay placement moves neither lane

The rig puts half its RTT in front of the shaper. A calibration with no media in the path showed that
this costs an ack-clocked sender its slow start: bulk TCP ran at 5.92 Mb/s through 20 Mb/s, and at
15.3 Mb/s with the whole RTT on the acknowledgement path, while paced UDP passed the rate in both
([method notes](method-notes.md) § *Delay in front of the shaper*). The MoQ lane's sender is
ack-clocked and SRT's is paced, so every ranking in this file could have carried the rig.
[`t2831-topology.sh`](scripts/t2831-topology.sh) re-ran both lanes with the whole 100 ms RTT on the
acknowledgement path — `cake` under a 0 ms data-path `netem`, which the impairments need — on
`ffa5b81b` (noq, relay `delay`, unpadded), two replicates, graded on content and conserved. Video
missing at close, seconds:

| Cell | Delay in front of the shaper | Delay on the acknowledgement path |
|---|---|---|
| MoQ, 3 s budget, 5 s outage | 21.12, 23.22, 19.72 (bisection) | 20.84, 18.80 |
| MoQ, 3 s budget, 1.0× for 60 s | 12.62, 12.16, 10.30 ([T31](test-31-congestion-capacity-ladders.md)) | 9.96, 12.02 |
| MoQ, 3 s budget, 0.9× for 60 s | 19.78, 18.82, 21.10 (T31) | 18.38, 17.22 |
| MoQ, 2 s budget, 5 s outage | 17.56, 26.60 (bisection) | 24.52, 27.84 |
| MoQ, 2 s budget, 5 % loss | 33.06, 32.04 (bisection) | 32.40, 33.50 |
| SRT, 2 s, 5 s outage | 3.9–5.3 (matched ladders) | 3.24, 3.24 |
| SRT, 2 s, 5 % loss | 0 in every cell | 0.00, 0.00 |

Every unimpaired cell conserves to 0.0 s on both lanes. **No MoQ cell moves outside its scatter, and
SRT stays at or below the outage length and at zero under loss**, so the rankings in this file are
not the rig's. Why is reasoned rather than measured: the placement slows a sender's climb to the
bottleneck's rate, which a 3 MB transfer must make from slow start and a live stream at the source's
rate mostly need not. One qualification:
this arm set SRT's `--latency` to the nominal 2 s (1.93–1.96 s measured) rather than to the MoQ
lane's measured median (1.30–1.90 s in these cells), so its SRT column is not latency-matched. SRT's
outage figure has stayed pinned near the outage length at every budget from 0.5 s to 6 s, and its
loss figure at zero in every cell, so the extra half-second is not what the SRT column shows.

## Measured — the transport axis, segmented lane

The third lane runs the same three impairment shapes over segmented HTTP/3, so that a resilience
statement about this architecture rests on a measurement rather than on the absence of one.

**Environment.** EC2 secondary. `tsp -O hls` to nginx, pulled over HTTP/3 by
[`hls-verbatim-recv.py`](scripts/hls-verbatim-recv.py); the FFmpeg receiver re-muxes and would grade
itself ([T42](test-42-h3-receiver-fidelity.md)). Loopback with `netem`, 20 Mb/s provisioned, no added
RTT — **not** the `netns`/`cake`/100 ms rig the MoQ and SRT arms above used
([T31](test-31-congestion-capacity-ladders.md) § *The loopback segmented ladder is in a different
rig*). One sample per cell, **wire** domain, at **P1**, receiver per-fetch timeout 15 s unless
stated. The same shapes inside the `netns` rig follow the table.

| Shape | Delivered bytes | Of control | Media lost | Continuity errors | PCR max | Carriage |
|---|---|---|---|---|---|---|
| none (control) | 82,851,600 | — | **0.000 s** | 0 | 24.95 ms | yes |
| sustained loss 5 % | 82,851,600 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| sustained loss 10 % | 82,851,600 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| outage 5 s | 100,837,560 (75 s window) | — | **0.000 s** | 0 | 24.95 ms | yes |
| outage 30 s | 79,533,400 (75 s window) | 78.9 % of the 5 s cell | 17.134 s | 10 | 17,139 ms | no: receiver exited 1 |

**Inside the `netns`/`cake` rig at 100 ms RTT**, with an origin in the publisher namespace and the
receiver on one connection ([T31](test-31-congestion-capacity-ladders.md) § *In the `netns`/`cake`
rig*): the 5 s outage again costs nothing (0.00 s lost, 0 holes). The receiver's default policy
voids the other three cells, because it refuses a truncated segment, so they were run with
truncation recorded as a hole and a 60 s per-fetch timeout, two replicates each:

| Shape | Video lost in holes | Missing at close | What the receiver saw |
|---|---|---|---|
| outage 30 s | **23.08, 23.08 s** | 21.48 s | nine segments rolled out of the window during the outage |
| sustained loss 5 % | 0.00 s | **61.10, 60.92 s** | two segments, then no fetch completed |
| sustained loss 10 % | — | — | one segment or none; the first fetch truncated |

**At 100 ms RTT the lane collapses under random loss.** The origin's QUIC sender is loss-based, and
random loss at a real RTT bounds a loss-based flow far below the stream's rate (*reasoned*; the
mechanism is in [T31](test-31-congestion-capacity-ladders.md) § *In the `netns`/`cake` rig*). The
30 s outage costs 23.08 s against 17.134 s on loopback, the difference being the lag the receiver
already carried at the rig's RTT. So the invisibility below is a **loopback result**, not a property
the lane keeps at 100 ms.

**At loopback RTT, sustained loss is not merely survived, it is invisible.** At 5 % and at 10 % the receiver returns
**82,851,600 bytes — the same number, to the byte, as the unimpaired control** — with zero
continuity errors and a 24.95 ms worst-case PCR interval. [T20](test-20-segmented-http3.md) measures
the same thing at 20 %. Three loss rates spanning a factor of four produce one answer, because
QUIC's loss recovery sits underneath the media and the media never learns a packet was lost. The
cost is paid in time, and at these rates the segment budget absorbs it without the receiver falling
behind at all.

**A 5 s total outage also costs nothing.** 100,837,560 bytes over a 75 s window, 0 continuity
errors, PCR max 24.95 ms, no holes, carriage valid. The receiver's fetches fail while the lane is
down, it retries, and when the lane returns the segments it missed are still in the origin's
playlist. **The outage is shorter than the retention, so the lane behaves as though it never
happened.**

**A 30 s outage exhausts the retention and costs 17.134 s of programme.** One hole, 10 continuity
errors, and a 17,139 ms worst-case PCR interval that *is* the hole. The loss is not 30 s because the
origin's window still held part of the gap; it is 30 s minus whatever retention covered. **This lane
converts an outage into lost programme only once the outage outlasts the segment store**, which is
the same boundary [T31](test-31-congestion-capacity-ladders.md) finds from the capacity side.
[T20](test-20-segmented-http3.md) reaches it from a third: at 30 s its HTTP/1.1 and HTTP/3 arms
deliver **byte-identical** output, so the substrate makes no difference to a recovery the origin's
retention is setting. Retention, not transport, is the design parameter.

**Reorder is the shape that hurts this lane, and the first reading of it was six times too harsh.**
At the receiver's default 15 s per-fetch budget, `delay 30ms reorder 25% 50%` returned 3,002,360
bytes — 4 % of control — and exited with `segment seg-000001.ts is not a valid transport stream
(3002302 bytes is not a multiple of 188)`. The timeout had cut a transfer in half and the receiver
refused the fragment, which is correct behaviour rather than a defect: concatenating a truncated
segment produces a corrupt stream that grades as a wire fault. Raising the budget to 60 s changes
the answer:

| Origin `http3_stream_buffer_size` | Receiver per-fetch budget | Delivered | Of control | Media captured | Holes | Continuity errors |
|---|---|---|---|---|---|---|
| 64k (nginx default) | 15 s (default) | 3,002,360 | 4.0 % | 2.4 s | — (refused) | 0 |
| 64k (nginx default) | 60 s | 18,967,320 | **25.4 %** | 57.0 s | 11 | 40 |
| 16m, three replicates | 15 s (default) | 19,343,884–19,602,572 | **25.9–26.3 %** | 54.6–59.4 s | 11 each | 31–41 |

**The 60 s reading is the lane's; the 15 s one was the instrument and the origin together.** With the
origin's per-stream buffer at nginx's 64k default, each segment took long enough under reordering
that the first one crossed the 15 s timeout and was truncated. With the buffer at 16m no segment
does (10.0–13.5 s each), and three replicates at the default timeout land on the 60 s reading. The
six-fold move from a receiver setting is why the method rule in [method-notes](method-notes.md)
§ *A receiver's per-fetch timeout is a measurement parameter* exists; the buffer is why this cell
crossed it, and § *An origin or a receiver can be the bottleneck at the rig's RTT* is the check.
What every reading agrees on is the direction: **the segmented lane is badly
hurt by reordering where it is untouched by loss.** At 60 s it spans the window but delivers a
quarter of the bytes in 11 holes with 40 continuity errors — the worst carriage anywhere in the
segmented columns of T28 and T31 — against 100.0 % and zero holes at 10 % loss. QUIC's loss
detector reads reordering as loss, and the retransmissions it triggers compete with the fetch they
are meant to rescue.

**The 0.5× rung is not the same kind of cell, and the same test says so.** Re-run at the 60 s budget
it returns 96,203,924 bytes — **byte-identical to the 15 s run** — so its 404 and its 17.979 s of
lost programme are the lane falling off the availability window, not the instrument giving up. The
timeout test distinguishes the two cases rather than excusing both.

### The MoQ arm in this rig measures its congestion controller, not its lane

The segmented rig carries a MoQ arm so the rig difference can be sized, and on the outage shape that
arm produced the sharpest instance yet of a pattern this campaign now has three of.

| Outage | MoQ, BBRv3 (`delay`, shipped default) | MoQ, CUBIC (`loss`), idle timeout 120 s |
|---|---|---|
| 5 s | 16.46 s of video in a 75 s window; session cancelled at the outage | **56.46 s present over a 70.1 s timeline, 13.64 s in holes** |
| 30 s | 16.44 s of video; session ends at the outage | 16.46 s of video; session ends at the outage |

Build `ffa5b81b`, which pads by default, so the byte ratios this arm first reported (0.227 and 0.961
on the 5 s cell) are not delivery figures — 24 % of the CUBIC cell's bytes are padding — and the
cells are graded here on content. Under the shipped default the relay logs `subscribe canceled
(idle)` at the moment the lane drops and the session never recovers, so the arm delivers the same
~16.5 s of picture whether the outage is 5 s or 30 s: what it measures is the time before the outage.
Pinned to CUBIC the session survives the 5 s outage and loses 13.64 s of picture to it. **The
controller decides whether the session lives, from a flag that was not set.**

**The 30 s cell is fatal under both controllers**, with the idle timeout already raised to 120 s so
that the teardown characterised in §*The 30 s cell was the QUIC idle timeout* is not the cause. Both
arms stop at the outage and neither resumes. In the `netns`/`cake` rig the session survived the same
outage at a 120 s timeout, though its picture largely did not return, so this is a rig difference
and not a correction to that section; what it shows is that on this path the segmented lane's 0.853
and the MoQ lane's ~16.5 s are not two readings of one phenomenon.

[T20](test-20-segmented-http3.md) found the same under reorder in this rig, where BBRv3 delivers
zero bytes in 60 s and CUBIC delivers 55.2 s of span. In the `netns`/`cake` rig the controller does
not decide the capacity rungs ([T31](test-31-congestion-capacity-ladders.md)) or the 20 % reorder
cell, and the backend decides sustained loss (§ *Sustained partial loss*). **No MoQ impairment cell
in this campaign should be read without the controller and the backend named beside it**, and cells
measured before the controller was pinned cannot be assumed to have used the one their file implies.

*MoQ arm graded on content, segmented arm on the wire; measurement point P1, one sample per cell,
single host over loopback with `netem` and no added RTT. Delivery is quoted against the ladder's own control because the receiver joins on the
playlist backlog and reads above unity when healthy ([T31](test-31-congestion-capacity-ladders.md)).
Continuity errors are not comparable across the lanes — `moq export ts` re-synthesises SI and reads
0 by construction — and are not netted into loss. Not cross-host, and not the `netns`/`cake` rig the
MoQ and SRT arms above ran in, so the segmented column is sound against its own controls and is not
a rung-for-rung ranking against them.*

## Objective

For each defined failure on each lane, measure how much *programme* is lost or corrupted before
continuous delivery is restored — not how quickly a session reconnects. Rank outcomes by media lost,
because a 30 s outage that costs 30 s of programme is a worse result than a 60 s outage that costs
none, and the ladder exists to find where each lane crosses from the second behaviour to the first.

This closes the single largest comparative gap called out as [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior):
the campaign has substantial partial evidence ([T5](test-5-network-impairment.md),
[T6](test-6-relay-resilience.md)) but no unified matrix scored in the broadcast domain.

## What is already known, and precisely what it leaves open

**Loss and reordering ladders exist on both lanes.** [T5](test-5-network-impairment.md) graded loss,
reordering and jitter with `netem`/`tc` at P1; its reordering separation was later corrected by
[T20](test-20-segmented-http3.md) on a substrate-matched arm. What is missing is the *outage* ladder
(500 ms, 5 s, 30 s, 5 min blackouts) and simultaneous injections.

**Infrastructure failures were probed individually, reported as times.** [T6](test-6-relay-resilience.md)
characterised origin restart, relay return, dual-source failover and the segmented lane's shared-store
behaviour — including the structural asymmetry that MoQ reselects while segmented HTTP needs no merge.
Those drills establish starting points (for example, that MoQ exporter resume skips to the live edge
while a retrying segmented client may refetch) but they do not apply one grader or one ranking metric
across all cells. Recovery-time figures from T6 must not be quoted as programme-loss figures without
this matrix.

**Availability windows are measured for segmented HTTP under loss.** [T5](test-5-network-impairment.md)
established the edge of the window at roughly 7.7–12.2 % applied loss; behaviour past that boundary
is lane-specific and was not scored as seconds of media lost in a comparative table.

**Dual failures and combined transport-plus-infrastructure cells are untested.** Killing two
components at once — publisher and path, relay and packager — is specified here and has no designed
record.

## Environment

| | |
|---|---|
| Lanes | Media-aware MoQ (`moq import ts` → relay → `moq export ts` → groomed egress) and segmented HTTP (`tsp -O hls` → origin → receiver → groomed egress), topologies aligned with [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md) so existing drills are reused, not re-run for their own sake. |
| Impairment point | `netem`/`tc` at the same logical hop on both lanes — the path between source node and serving node — per [method-notes](method-notes.md) on matching substrate and controller variables. |
| Source | Looped `<CLIP>` at known CBR, paced with `tsp -P regulate --pcr-synchronous`; segmented packager flags unchanged from [T6](test-6-relay-resilience.md) segmented arm. |
| Hosts | Loopback for v1 matrix; cross-host variant optional once the grader is stable. Placeholder `<EC2_IP>` when remote. |
| Grader | One script pair: inject failure → capture egress → emit **seconds of media lost**, continuity-error count, PCR discontinuity count, PTS regressions, wall-clock time to first byte after fault, time to *stable* operation (defined below), and whether operator intervention was required. Built once for [P1-a](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) and shared with silent-failure arms ([P0-f](planned-experiments.md#p0--could-change-a-viability-conclusion)). |
| Receivers (segmented) | At minimum `t6-hls-pull.py` as the protocol-capable control; `tsp -I hls` and FFmpeg as shelf behaviour columns, because [T6](test-6-relay-resilience.md) showed receiver choice changes failover outcome without changing lane specification. |

**Role equivalences to declare in the report**, not to paper over:

| Concept | MoQ lane | Segmented lane |
|---|---|---|
| Source node | publisher (`moq import ts`) | packager (`tsp -O hls`) |
| Mid-path node | relay | origin / cache |
| Session state | subscription on relay | none on origin |
| Asymmetry | reselect after detection interval | shared namespace, no merge |

## Procedure

Two axes, applied identically where the lane has an equivalent role.

**Transport axis** — at the shared impairment point, in separate runs:

- Random loss steps (reuse [T5](test-5-network-impairment.md) ladder where still current; extend only
  where gaps remain).
- Reordering and jitter (reuse T5 cells; do not duplicate substrate-matched work already in
  [T20](test-20-segmented-http3.md) unless the grader adds the media-lost column).
- Bandwidth reduction (step down from provisioned rate).
- **Outage ladder** — 100 % loss for **500 ms, 5 s, 30 s and 5 min**, then restore; grade the whole
  window including recovery tail.

**Infrastructure axis** — kill and restart, one component per run unless noted:

- Source node (MoQ publisher; segmented packager).
- Mid-path node (MoQ relay; segmented origin — cache/edge where applicable).
- Receiver-side process without killing the transport (exporter stall, groomer stall).
- Network path reset (flush `netem`, restart interface — simulates route change).
- **Dual failures** — two components, e.g. publisher + path, relay + packager, chosen from pairs that
  production 1+1 is meant to survive.

Each cell: baseline capture → inject at known wall time → capture through stable recovery → grade.
MoQ idle-timeout and reselect tuning (`--server-quic-idle-timeout`, `--client-quic-idle-timeout`)
are explicit parameters recorded per cell because [T6](test-6-relay-resilience.md) showed they move
detection interval without moving media-skip behaviour.

**Stable operation** is defined before the run: delivered byte rate within 95 % of pre-fault rate for
30 consecutive seconds *and* 0 new continuity errors in that window. First byte after fault may arrive
earlier; stable operation is the criterion for "recovered".

## Metrics

Per injection, per lane, at groomed P1 egress (file):

- **Media lost (headline)** — seconds of programme time missing or duplicated, computed from PCR/PTS
  timeline holes and regressions, not from session logs.
- **Continuity errors** — TSDuck count during fault and recovery windows ([method-notes](method-notes.md)).
- **PCR discontinuities** — count and maximum jump.
- **PTS regressions** — count.
- **Wall-clock recovery** — time to first post-fault byte; time to stable operation (secondary).
- **Operator intervention** — boolean; automatic recovery only passes without it.
- **Transport narrative** — what the session/API reported throughout (HTTP 200s with frozen media,
  QUIC reconnect, etc.); recorded to show disconnect from media-domain outcome, not scored as pass/fail.

Rank cells **by media lost ascending**; recovery time breaks ties only for equal media lost.

## Pass criteria, fixed before running

These are criteria on the *experiment's deliverable*, not on the lanes — neither lane is assumed to
pass every cell.

1. **Grader validity.** A control run with no injection reports 0 s media lost and 0 continuity errors
   on both lanes; a synthetic hole injected in post produces the injected duration ± 100 ms.
2. **Matrix completeness.** Every transport outage duration {500 ms, 5 s, 30 s, 5 min} × both lanes;
   every infrastructure single-failure row × both lanes; ≥ 4 dual-failure pairs × both lanes. A cell
   skipped for missing apparatus is listed as blocked, not omitted silently.
3. **Ranking published.** Final table sorted by media lost; no cell reported only as recovery time.
4. **Comparability.** Same source clip, same provisioned rate, same groomer configuration within a
   lane across all cells unless the cell explicitly tests configuration (then labelled).
5. **Segmented receiver axis.** Where [T6](test-6-relay-resilience.md) showed receiver-dependent
   outcomes, at least two receivers are graded for origin-restart and outage-5 s cells; divergence is
   a finding, not a rig error.

**Lane-level interpretation (fixed before running):** a lane is *superior on resilience* for a given
failure class if its median media lost across three repeats is lower than the other lane's at matched
ingress rate and matched conformance of pre-fault bytes. A tie within ± 0.5 s programme time is
reported as tied.

## Limits, stated in advance

- **P1 file egress only in v1.** Wire timing (P2) and hardware IRD merge are out of scope; outage
  behaviour on a hardware IRD may differ from file PCR arithmetic.
- **`netem` is an emulator.** Results complement, not replace, the public-internet path from
  [T4](test-4-remote-e2e-srt.md).
- **Reuse, don't repeat.** Cells that duplicate [T5](test-5-network-impairment.md) or
  [T6](test-6-relay-resilience.md) verbatim add only the media-lost column; their session-level
  narratives are cross-referenced, not re-measured for a second publication.
- **1+1 merge is out of scope.** Hitless dual-path behaviour belongs to [T12](test-12-dual-path-handoff.md);
  this matrix grades single-path recovery unless extended later.
- **Silent misconfiguration** (time-travel that passes continuity checks) is graded under
  [T30](test-30-segmented-distributed-resilience.md) for segmented pairs; only noted here if a
  transport outage exposes the same class.

## Verdict against the pass criteria

| # | Criterion | Verdict |
|---|---|---|
| 1 | Grader validity: a control reports 0 s lost and 0 continuity errors **on both lanes**; a synthetic hole reproduces the injected duration ± 100 ms | **Passes on both lanes, with a different grader on each.** SRT and segmented cells are graded on the PCR timeline, whose self-test passes and whose controls grade 0.000 s lost; MoQ cells on the content timeline (`t28-content-selftest.sh` within 0–40 ms), conserved against the window, with every clean cell at 0.0–0.9 s. The PCR grader also passed the MoQ controls and was blind on that lane's impaired cells, so a clean control is necessary and was not sufficient (§ *Corrections*). The earlier SRT failure (controls at 4.196–5.391 s lost) was real and the criterion is what caught it; its cause was the split publisher a source-side tap forces, and a single-`tsp` publisher clears it |
| 2 | Matrix completeness | **Partial.** MoQ and SRT are run on three transport axes, matched on measured latency and two replicates deep: the outage axis (six budgets, plus four outage durations on MoQ and a re-convergence pass), sustained partial loss at 5 % and 10 %, and reorder at 5 % and 20 %; the MoQ lane is repeated on five builds and both backends at three replicates. The segmented lane is run on the same three shapes in the loopback rig at one sample per cell, and in the `netns` rig on both outages and both loss rates, one or two samples per cell, not on reorder. The bandwidth step is in T31; the infrastructure axis is not run |
| 3 | Ranking published | **Met for MoQ against SRT on all three axes run, and graded on content SRT is ahead on every one.** By criterion 5's rule — lower median media lost wins — SRT is superior under a discrete outage at every budget (5.0–5.4 s against the MoQ lane's 15.1–20.5 s on `53f8aa99d`; at a 2 s budget on every build, the MoQ lane loses 7.2–28.4 s); under sustained loss on the noq builds at every budget and both rates (0 against 23.4–31.5 s), **tied** with the quinn builds at 5 % (0 against 0.00–0.64 s, inside criterion 5's ± 0.5 s at the median); and under 20 % reorder on every build (0.00–0.17 s against 33.4–35.1 s), where SRT's stream carries 430–692 continuity errors whose effect on a decoder is not measured. Criterion 5 still scores media lost alone and so cannot see that the MoQ lane also re-times the service after an outage. **The three-way ranking is not published**: in the `netns` rig the segmented column has no reorder cell, and its outage cells are read at 18–22 s of lag the other lanes do not carry, which a media-lost rule cannot weigh. In that rig it loses nothing to a 5 s outage, 23.08 s to a 30 s one, and collapses under 5 % loss. What it establishes on its own controls at loopback RTT is that loss at 5 % and 10 % is byte-identical to unimpaired, a 5 s outage likewise, a 30 s outage costs 17.134 s, and reorder is the shape that hurts it |
| 4 | Comparability | **Pass within each table.** One host, one rig, one clip, one grader and one domain per table, with an unimpaired control through the same path; the build and backend are named on each, because the MoQ figures differ between builds by more than between budgets. On the matched ladder the SRT arm's `--latency` is set from the MoQ lane's measured median rather than its nominal budget |
| 5 | Segmented receiver axis | **Not run.** The apparatus is on the same host (T20's HTTP/3 and HLS lane), so this is now a session's work rather than a blocker |

## What remains

Nothing here is blocked on a third party, a loan or an account. The apparatus, the clips, the binaries
and the grader are all on the EC2 secondary.

- **Which `dev` changes raised the outage cost.** The stack and the controller are excluded, and the
  probes place the cost on `dev` in at least two steps, but three-replicate bisections of each step
  end on merges whose parents both pass (§ *The build bisection*). The arm that settles it runs each
  merge and both its parents at ten replicates and compares distributions rather than worst cases,
  about six hours of the secondary. What upstream could act on without it is the cell and the range.
- **Why the 0.9× capacity step costs noq more on either controller** — a stack property the
  controller arm does not reach. The arm that would name it is a relay qlog of the step on both
  stacks, reading the rate each sustains against the 0.9× ceiling.
- **Where quinn's reorder cost lies.** On noq it is the loss detection: relaxing both thresholds
  takes the cell from 37.38–38.1 s to 2.12–3.0 s (§ *The build bisection*). On quinn the same
  relaxation keeps the window and still loses 27.42–32.36 s, with two-thirds of its packets declared
  lost even under the 2 RTT time threshold. The arm that settles it samples the shaper's drop counter
  (`tc -s qdisc`) through the quinn reorder cell. If the shaper drops them, quinn's cost is real
  loss from its own sending, not detection.
- **Add the latency axis to the pre-registered scoring rule.** Criterion 5 ranks on media lost alone.
  On content the MoQ lane now loses on that axis as well, so the omission no longer flatters it, but
  it still cannot see that the lane also re-times the service after an outage; any future lane
  comparison here needs a two-axis verdict, and that revision is not yet written.
- **Extend the re-convergence pass beyond 117.8 s.** The source clip, not the commanded window, ended
  it. A lane flat to ±0.24 s over 75 s is not converging, but "never" is not yet measured.
- **Replicate the idle-timeout bracketing, graded on content with its controls kept.** One replicate
  per cell, and the missing-at-close figures in § *The 30 s cell* are estimated from another run's
  join offsets.
- **A genuine SRT budget sweep under sustained loss.** Matching on measured latency collapsed the
  three budgets onto one ≈2 s setting.
- **The bandwidth step** is in [T31](test-31-congestion-capacity-ladders.md); **the infrastructure
  axis** — kill and restart a publisher, a relay and an exporter — is not run in this rig and graded
  on content. [T6](test-6-relay-resilience.md) drills the relay and publisher restarts on loopback,
  counting bytes rather than pictures.
- **The segmented lane in the `netns` rig**: reorder is not run there, the 5 s outage is one sample,
  and the loss collapse is attributed to the origin's loss-based sender by reasoning; the arm that
  would test it runs the origin with BBR. Criterion 3's three-way ranking needs the reorder cell and
  the latency axis above, since this lane is never at the other two lanes' latency.

Quoting [T6](test-6-relay-resilience.md) recovery times as programme-loss figures remains
methodologically out of bounds; the MoQ lane now has programme-loss figures of its own, graded on
content, for all three transport shapes.


## Corrections

**Believed:** graded on the PCR timeline, the MoQ lane lost little of a 5 s outage once the budget
covered it — 0.20–2.23 s from a 2 s budget up, below SRT's 3.46–3.76 s — and nothing at all at a 6 s
budget; it lost 0.33–3.88 s under 5 % loss, and nothing in four of six 20 % reorder cells. So an
outage shorter than the budget was free, `--max-age` bought back content, and three impairment
shapes ranked MoQ and SRT three different ways. **True:** `moq export ts` writes PCR across pictures
it never received, so the PCR timeline has no hole where the picture has one, and a picture that
stops before the window closes leaves no hole at all. Graded on content and conserved against the
window, the lane loses 15.1–20.5 s of that outage on the same build with no trend in the budget,
23.4–31.5 s under 5–10 % loss, and 33.4–35.1 s under 20 % reorder, and SRT is ahead on all three
shapes. The latency results, the idle-timeout rule and the dead-session finding survive; the 0
continuity errors survive and measure nothing. **Rule:** a grader validated on the file domain is not
validated on a lane whose egress synthesises the clock; grade such a lane on the content's own
timeline, conserve against the window, and treat a clean control as necessary rather than sufficient
([method-notes](method-notes.md) § *The exporter manufactures bytes and clock*, § *A hole count sees
only gaps between what arrived*).

**Believed:** noq's relay declared every reordered packet lost by the packet-reordering threshold and
none by the time threshold, because its qlog labels all 1,619 losses `reordering_threshold`.
**True:** the label cannot say otherwise. The qlog code in noq, and in the quinn it forks, computes
the packet's send time minus the present, which saturates to zero and never reaches the loss delay,
so every loss is labelled by reordering whichever rule fired. Raising the packet threshold to 1000
left thousands of losses in place, and so the time threshold was firing too. The spurious-loss
finding stands, because it rests on the acknowledgement frames, not on the label. **Rule:** a field
that attributes a cause is code like any other; read the code that emits it before quoting it, and
prefer the evidence that does not depend on it ([method-notes](method-notes.md) § *A trace's labels
are code*).
