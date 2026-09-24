# Test 28 — Failure-injection and recovery matrix

**State: run in part. The MoQ and SRT lanes are measured across three impairment shapes — discrete
outage, sustained partial loss and reorder — matched on measured latency in the `netns`/`cake` rig;
the segmented lane is measured on the same three shapes in T20's loopback rig, which is not the same
rig and whose figures are not interchangeable with them; the infrastructure axis is not run.**
Infrastructure and transport failures have been probed one at a
time in [T5](test-5-network-impairment.md) and [T6](test-6-relay-resilience.md), usually reported as
recovery *time*; what a distributor buys is programme continuity, and the two are not the same number.
This experiment applies one media-domain grader across a full matrix on both lanes.

**Headline: an outage shorter than the subscriber's latency budget costs nothing, and the programme
cost of a longer one scales with the budget rather than with the outage.** That is the opposite of the
intuition the register was built on, and it is the result an operator sizes against. Every cell
returned **0 continuity errors**: when this lane loses programme it loses whole groups cleanly, and a
receiver sees absence rather than corruption.

**Second headline: the segmented lane's resilience is bounded by the origin's retention and by
almost nothing else.** Sustained loss at 5 % and at 10 % returns bytes **identical to the
unimpaired control**, and a 5 s total outage does too; a 30 s outage costs 17.134 s because it
outlasts the segment store. Three impairment shapes and one boundary — how long the origin keeps a
segment — where the MoQ lane has a different boundary for each shape.

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
of one PCR cadence, well inside the 100 ms margin. Everything below is graded `wire`.

## Measured — the transport axis, MoQ lane

**Environment.** EC2 secondary, 8 vCPU / 15 GB, Ubuntu 26.04. Two network namespaces joined by veth
(`t8b-netns.sh`), `cake` at the bottleneck provisioned at 20 Mb/s, 100 ms base RTT (50 ms each way),
source a 120 s ~9.95 Mb/s CBR slice of `CNNiEMEA2.ts` paced with `tsp regulate --pcr-synchronous`.
Build `moq` 0.11.0-`fd4f5d82e`. `moq import ts` → relay → `moq export ts`, **no groomer in the
path**, captured at the subscriber. Rig: [`t28-t31-moq-ladder.sh`](scripts/t28-t31-moq-ladder.sh).
Outage = 100 % loss applied at the bottleneck for a fixed duration, 20 s after delivery settles.
Domain **wire**, measurement point **P1**, one sample per cell.

| Outage | `--latency-max` | Media lost | Holes | Largest hole | Continuity errors |
|---|---|---|---|---|---|
| none (control) | 3 s | **0.000 s** | 0 | — | 0 |
| 0.5 s | 3 s | **0.000 s** | 0 | — | 0 |
| 5 s | 3 s | **2.075 s** | 2 | 1.200 s | 0 |
| 30 s | 3 s | **30.125 s** | 2 | 29.625 s | 0 |
| 5 s | 1 s | **1.250 s** | 2 | 0.725 s | 0 |
| 5 s | 6 s | **0.000 s** | 0 | — | 0 |

**A 0.5 s outage is free**, and a 5 s outage costs no *media* at all provided the latency budget
exceeds it — the relay's cache replays what the subscriber waited for. This is the operationally
useful half: the budget buys outage immunity up to its own length. **It is not free in delivery
latency, though, and this table does not show that half.** §*The matched ladder* measures the price:
the recovered content arrives late, the lane steps to a higher delivery latency, and it does not step
back. Read this table as "what reaches the receiver", not as "what it costs".

**Beyond the budget, loss falls as the budget rises — the opposite of what the two cells above
suggested, and the replication is what settles it.** Those two cells (1 s losing 1.250 s, 3 s losing
2.075 s) were read as the *larger* budget losing *more* programme, and a sizing rule was drawn from
them: that an intermediate budget is the worst choice. **Three replicates across six budgets do not
support it** — see *The budget ladder replicated* below. The direction reverses, and the reason the
original reading was available at all is that the scatter at budgets shorter than the outage is a
factor of seven, so any two single samples can be ordered either way.

**The 30 s cell is a different failure and should not be read as the ladder's top rung.** It lost
30.125 s — *more* than the outage — where the budget model predicts 27 s. 30 s is also the default
`--quic-idle-timeout`, so this cell straddles the point where the QUIC session dies rather than
starving, and what it measures is teardown rather than a gap. **This is now attributed rather than
suspected**: the bracketing cells are in §*The 30 s cell was the QUIC idle timeout*, and they confirm
it — at the default the session ends and does not return, and with the timeout raised the same
outage becomes ordinary starvation.

**0 continuity errors in every cell, including the 30 s one**, is a broadcast-domain result in its own
right and it is not what an impaired TS path normally does. Loss on this lane presents as missing
media with the continuity counters intact, not as corrupt packets, so a downstream analyser will flag
absence rather than errors. Pass criterion 4's 0-continuity-error requirement is met on every cell
run.

### The budget ladder replicated, and the nominal budget is not a latency setting

Run as the MoQ half of [P1-m](planned-experiments.md), whose purpose is a matched-buffer comparison
against SRT. This pass ran the MoQ half only, on a rig with two defects since found and fixed, so
**nothing in this section ranks the two architectures**; the ranking is in §*The matched ladder*,
which supersedes these figures. What this pass delivers is the replication T28 owed, and the measured
result that changed how the comparison had to be set up.

**Environment.** As above, but build `moq` 0.11.2-`5d0991b9`, rig
[`t28-t31-srt-ladder.sh`](scripts/t28-t31-srt-ladder.sh), and an inline PES-timestamp tap
(`t18-latency.py`) on both sides of the lane so delivery latency is measured rather than assumed.
Both namespaces are on one host, so the two taps share a clock and the offset is 0. 5 s total outage,
three replicates per budget, `cake` at 20 Mb/s, 100 ms base RTT. Domain **wire**, point **P1**.

Media lost against the same 5 s outage, in seconds:

| `--max-age` | rep 1 | rep 2 | rep 3 | median | control (unimpaired) |
|---|---:|---:|---:|---:|---:|
| 0.5 s | 2.925 | 2.475 | 0.875 | 2.475 | **1.050 — not clean** |
| 1 s | 2.675 | 4.300 | 0.600 | 2.675 | 0.000 |
| 2 s | 1.025 | 1.375 | 2.025 | 1.375 | 0.000 |
| 3 s | 0.200 | 0.300 | 0.200 | **0.200** | 0.000 |
| 4 s | 0.625 | 0.450 | 0.900 | 0.625 | 0.000 |
| 6 s | 0.200 | 0.200 | 1.275 | **0.200** | 0.000 |

`cc = 0` in all 18 impaired cells and all 6 controls.

**The controls license the grading for budgets ≥ 1 s and disqualify the 0.5 s row.** Five of six
unimpaired cells grade at exactly 0.000 s lost, which is what makes the wire domain usable here. The
0.5 s cell loses 1.050 s *with no impairment at all*, so a 500 ms release deadline is below what this
path costs (100 ms base RTT, 20 Mb/s `cake`) and its impaired cells cannot separate the outage from
the budget. Recorded, not used.

**Loss falls with the budget, and the previously reported non-monotonicity does not replicate.** From
1 s upward the medians are 2.675, 1.375, 0.200, 0.625, 0.200 — a fall of better than an order of
magnitude between 1 s and 3 s. **The sizing rule stated earlier in this file is therefore withdrawn:**
an intermediate budget is not the worst choice, and the ordinary reading is the right one — a budget
at or beyond the expected outage buys near-immunity, and below it the cost rises as the budget
shrinks.

**What survives of the non-monotonicity is much smaller and reproducible: the 4 s cell is
consistently worse than the 3 s cell** (0.450–0.900 against 0.200–0.300, in all three replicates).
That is a real bump, not scatter, and it is unexplained. It is also not the effect originally
claimed.

**The scatter below the outage length is the methodological finding.** At a 1 s budget the three
replicates span 0.600 to 4.300 s — a factor of seven — while at 3 s and 6 s they span 0.200 to 0.300.
So the lane's behaviour is tightly determined once the budget covers the outage and close to
arbitrary when it does not. **This is why the original two-point reading was available**: any two
single samples drawn from the short-budget distribution can be ordered either way, and the pair that
was drawn happened to order against the trend. Quoting a single sample from a budget shorter than the
impairment is not a measurement of that budget.

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

### The matched ladder: the two lanes make opposite trades, and MoQ's recovery allowance is paid in latency that does not come back

With the rig sound on both sides, the ladder ran matched: the MoQ lane first, its **measured**
unimpaired median delivery latency at each budget written to `MATCH_FILE`, then the SRT lane with
`--latency` set to that figure rather than to the nominal budget. Two replicates per outage cell, one
unimpaired control per budget, 60 s cells, 5 s total outage applied mid-window by `set_loss 100`.
Build `53f8aa99d`, netns at 20 Mb/s and 100 ms RTT, source tap mirrored, egress tap inline.

**The match holds.** Both lanes grade **0.000 s lost and 0 continuity errors** on every unimpaired
cell, and SRT delivers the latency it is commanded to within about a millisecond — 2,028.1 ms against
a commanded 2,029 ms on the control cell. The MoQ lane's own unimpaired latency is **1,845–2,125 ms
across a twelve-fold sweep of `--max-age`**, which restates in the matched rig what §*`--max-age`
does not set delivery latency* found: the commanded budget is not the standing latency.

Under the outage the lanes diverge completely. Both replicates are shown:

| `--max-age` / matched `--latency` | MoQ media lost | MoQ late-window latency | SRT media lost | SRT late-window latency |
|---|---:|---:|---:|---:|
| 0.5 s | 5.53 / 6.20 s | 4,535 / 4,494 ms | 3.52 / 3.57 s | 2,298 / 2,300 ms |
| 1 s | 3.98 / 3.85 s | 6,444 / 6,628 ms | 3.74 / 3.61 s | 2,028 / 2,028 ms |
| 2 s | 2.23 / 0.95 s | 6,635 / 9,593 ms | 3.52 / 3.62 s | 2,172 / 2,189 ms |
| 3 s | 0.38 / 0.35 s | 8,057 / 9,721 ms | 3.49 / 3.74 s | 2,240 / 2,238 ms |
| 4 s | 0.90 / 0.20 s | 8,121 / 8,379 ms | 3.46 s | 2,021 ms |
| 6 s | 0.45 / 0.20 s | 12,268 / 10,707 ms | 3.76 / 3.57 s | 2,205 / 2,213 ms |

**`--max-age` works: it buys back content.** MoQ's media lost falls monotonically with the allowance,
from 5.53–6.20 s at a 0.5 s budget — about the length of the outage itself, so a shallow allowance
recovers essentially none of it — to 0.20–0.45 s at 6 s. By a 3 s allowance the lane is already
recovering the large majority of a 5 s outage.

**It is not free, and what it costs is delivery latency that does not come back inside the window.**
Late-window latency rises with the allowance, from ~4.5 s at the 0.5 s budget to 10.7–12.3 s at 6 s,
against a ~2 s unimpaired baseline on the same cells. **The induced latency is not bounded by
the allowance that induced it**: at a 6 s `--max-age` the lane runs roughly twice that far behind. The
plausible mechanism is contention — backfill and live share one shaped 20 Mb/s egress, so a deeper
allowance means more backfill, which means falling further behind — but this rig does not separate
that from the subscriber's own scheduling, and the attribution is **unproven**.

**SRT makes the opposite trade, and makes it cleanly.** Its loss is pinned at **3.46–3.76 s** — the
outage plus a little — at *every* budget, because the allowance is not an allowance: it is a fixed
delay. Its latency is pinned at the commanded value across the outage, moving **+0.5 to +19.8 ms**
first third to last third. It never falls behind, and it never catches up, because it never tries.

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

*Domain: file, on the subscriber's capture — delivery latency to a file sink, not to a decoder with a
bounded buffer, which would have to drop or drift instead of lagging. Single host, one netns path at
20 Mb/s and 100 ms RTT; not cross-host. One impairment shape — a single 5 s total outage — so this
says nothing about partial loss, and the loss ladder elsewhere in this file is the place for that.*

#### The 30 s cell was the QUIC idle timeout, and bracketing it separates a starved session from a dead one

The outage table above flagged its 30 s cell as unattributable: it lost 30.125 s where the budget
model predicts 27 s, and 30 s is also the default `--quic-idle-timeout` on **both** the relay and the
client, so the cell straddles the point where the session dies rather than starves. Running the same
three outages either side of that boundary settles it. Six cells, one replicate each, build
`53f8aa99d`, `--latency-max 3s`, the namespace rig at 20 Mb/s and 100 ms RTT; the only variable is
`MOQ_QUIC_IDLE_TIMEOUT`, which both binaries honour.

| outage | idle timeout **30 s** (default) | idle timeout **120 s** |
|---|---|---|
| 20 s | 6.000 s lost, 66.2 MB captured | 1.975 s lost, 69.2 MB captured |
| 30 s | **"0.000 s lost", 23.5 MB — session dead** | 21.850 s lost, 70.0 MB captured |
| 40 s | **"0.000 s lost", 23.6 MB — session dead** | 40.725 s lost, 66.1 MB captured |

**At the default, an outage that reaches the idle timeout ends the session and it does not come
back.** Both the 30 s and the 40 s cells terminate with `Caused by: dropped` in the subscriber log,
capture about a third of the bytes the surviving cells do, and never resume inside the window.
**Move the timeout out of the way and all three become ordinary starvation**: the session survives,
the loss scales with the outage — 1.975 s, 21.850 s, 40.725 s — and the 40 s cell logs
`current group evicted; skipping to next buffered group … Hang(Moq(Old))`, which is
[#3515](https://github.com/moq-dev/moq/pull/3515)'s skip working as intended rather than an exit.

**So the 30 s cell was never a media result.** It measures teardown, and the budget model was right
to disagree with it. The deployment rule is the durable part: **`--quic-idle-timeout` must exceed the
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
playout and ad insertion. On this evidence recovery is available on the MoQ lane, but only by
re-timing the service, and nothing observed here re-times it back.

*Both cells ran one replicate. The window was limited to 117.8 s by the source clip rather than by
the commanded `RECOVER=280`, so "does it recover after several minutes" remains formally open — but
a lane flat to ±0.24 s over 75 s is not converging on any timescale that matters to the question.
Same domain and topology caveats as the matched ladder above.*

### Sustained partial loss reverses the outage result: SRT loses nothing, MoQ loses programme at the same delivered latency

The outage ladder above answers one failure mode — a discrete 5 s break — and the promoted evidence
recorded the obvious question it leaves: whether the same ordering holds under *continuous* impairment.
It does not. The two lanes swap places.

Same rig, same clip, same `cake` 20 Mb/s / 100 ms RTT netns, two replicates. The impairment is
sustained rather than a burst: after the 20 s settle, netem loss is applied for the remaining 40 s of
the 60 s window. Budgets 0.5 / 2 / 6 s, and the SRT arm is matched on the MoQ lane's *measured*
latency at each budget via `MATCH_FILE`, as the outage ladder was.

| impairment | budget | MoQ lost (s) | MoQ late-window latency (ms) | SRT lost (s) | SRT latency (ms) |
|---|---:|---:|---:|---:|---:|
| none | 0.5 / 2 / 6 | 0 / 0 / 0 | 2,165 / 2,016 / 2,012 | 0 / 0 / 0 | 2,164 / 2,014 / 2,011 |
| 5 % | 0.5 | 1.65, 1.55 | 2,604, 1,734 | **0, 0** | 2,164, 2,164 |
| 5 % | 2 | 0.35, 3.75 | 1,824, 1,985 | **0, 0** | 1,998, 2,016 |
| 5 % | 6 | 0.33, 3.88 | 1,831, 2,027 | **0, 0** | 2,012, 2,012 |
| 10 % | 0.5 | 21.18, 18.53 | 2,617, 2,667 | **0, 0** | 2,164, 2,164 |
| 10 % | 2 | 17.40, 6.15 | 1,988, 1,983 | **0, 0** | 2,014, 2,014 |
| 10 % | 6 | 18.93, 5.38 | 1,987, 1,993 | **0, 0** | 2,011, 2,011 |

**SRT lost no programme in any of the twelve impaired cells**, at 5 % or 10 %, with zero continuity
errors and a full picture sample (2,019–2,026 matched pictures against 2,026 unimpaired). MoQ lost
programme in every one. This is the reverse of the outage finding, where a 6 s allowance took MoQ's
loss below SRT's floor.

**The mechanism is the one the outage ladder identified, read the other way.** SRT spends a fixed
delay on every packet and retransmits inside it; at ~2 s of buffer over a 100 ms RTT there is room
for many attempts, and independent random loss at these rates is recovered with margin. That is
squarely what SRT is built for. MoQ's allowance is a release deadline, so a group that is not
complete in time is discarded whole — and, decisively, **MoQ did not spend its allowance**: measured
latency stayed at 1.73–2.67 s whether the budget was 0.5 s or 6 s. The 12× budget sweep bought
nothing, because under scattered loss there is no bounded backlog for the allowance to wait through,
which is exactly what it was able to wait through after a discrete outage.

**Two qualifications, and the second limits what the sweep can claim.**

First, **the 10 % MoQ cells are reported but not ranked.** Their capture spans range from 33.2 s to
52.4 s across cells that all ran the same 60 s window, so each covers a different amount of
programme, and the method rule from the outage ladder applies — a figure computed over an unequal
window is not comparable with one computed over a full one. The 5 % cells hold a tighter 48.8–54.6 s
and are ranked. The direction of the result does not depend on the 10 % row: SRT is at zero and MoQ
is not, at both rates.

Second, **the SRT arm is not a budget sweep**, and matching on measured latency is why. MoQ's
measured latency is ~2 s at every nominal budget, so the three matched SRT settings are 2,165 / 2,016
/ 2,012 ms — one buffer, run three times. The row therefore establishes SRT's behaviour at ≈2 s and
says nothing about SRT at a shallower one. A genuine SRT budget sweep under sustained loss is a
separate cell and is not run here.

**Duplication is large on the MoQ lane and is not yet attributed.** The grader reports 5.95–41.6 s of
programme delivered more than once, rising with loss rate, against 0–1.45 s on the unimpaired cells
and 1.45–5.15 s across the whole outage ladder. Against that, its matched-picture count roughly halves
under loss (1,996 unimpaired against 888–1,172), so some of the signal may be the grader losing its
footing rather than the lane repeating content. **Unresolved, and nothing above rests on it.**

*Both lanes graded `--domain wire`; both control cells graded 0.000 s lost, which is what licenses the
domain. Two replicates per cell. Co-resident netns, so the figures are not a cross-host deployment
claim. Continuity errors are not comparable between the lanes — `export ts` re-synthesises SI, so MoQ
reads 0 by construction — and are not netted into loss anywhere above.*

### Reorder is a third pattern and neither lane wins it: SRT delivers everything and damages it, MoQ keeps it clean and loses the picture match

Two impairment shapes had already ranked the lanes in opposite directions, which is a reason to run
the third rather than infer it. Reorder does not resolve into a ranking at all.

Same rig and the same matched budgets. `netem ... reorder P% 50%` against the existing 50 ms delay,
so the reordered packets are the ones sent early and the arm costs no extra latency — ordering is
isolated from the loss and latency axes rather than confounded with them. Held for the last 40 s of
the window, as the loss arm is. Two replicates.

**At 5 % reorder neither lane moves.** Both grade 0.000 s lost at every budget, SRT takes no
continuity errors, and MoQ's picture match and span are indistinguishable from unimpaired. The cell
is reported because a null result on the axis that used to separate these lanes is worth recording.

**At 20 % reorder the two lanes fail in their characteristic directions, and neither is preferable
on the evidence here:**

| | SRT | MoQ |
|---|---|---|
| media lost | **0.000 s in all six cells** | 0.000 s in four; 1.825 s and 5.075 s in two |
| continuity errors | **430–692 in four of six cells** | 0 everywhere, by construction |
| capture span | full, 57.6–57.8 s | 49.6–56.4 s |
| matched pictures | full, 2,019–2,026 | **767–821, against 1,996 unimpaired** |
| duplication | 0 | 3.53–11.28 s |

**SRT is byte-transparent, so reordering arrives as damage rather than absence** — the programme is
all there and several hundred continuity errors are in it. **MoQ re-synthesises, so its output stays
syntactically clean and the cost surfaces somewhere else.** Where, exactly, is not settled by this
run: the latency instrument's matched-picture count falls to about 40 % of the unimpaired sample,
which is a much larger drop than the loss arm produced.

**That collapse is a caveat on the latency column before it is a finding about the media.** With
only ~770 of ~2,000 pictures matched, the latency medians for those cells rest on 40 % of the
sample, and one of them (1,326.8 ms at a 2 s budget) sits *below* the unimpaired figure, which is
not a credible delivery latency and is better read as the instrument struggling to pair pictures
across a reordered stream. **No latency conclusion is drawn from the 20 % reorder cells.** Whether
the matched-picture collapse also indicates a real presentation-order defect at the egress is the
open question this arm leaves, and it needs an instrument that grades output order directly rather
than one that infers it from pairing.

**What the arm does establish is the negative.** Three impairment shapes on one rig at one matched
latency now rank these two lanes three different ways — MoQ ahead under a discrete outage, SRT ahead
under sustained loss, and neither ahead under reorder. A resilience claim about either lane that
does not name its impairment shape is not supported by anything here.

*Measurement point P1, domain wire on both lanes; both unimpaired controls grade 0.000 s lost. Two
replicates per cell, one control per budget, single host and namespace path at 20 Mb/s and 100 ms
RTT, so not cross-host. Continuity errors are not comparable between the lanes — `export ts`
re-synthesises SI and reads 0 by construction — and are not netted into loss. The matched SRT arm is
again one buffer (≈2 s) run three times rather than a sweep, for the reason in
§*Sustained partial loss*.*

## Measured — the transport axis, segmented lane

The third lane runs the same three impairment shapes over segmented HTTP/3, so that a resilience
statement about this architecture rests on a measurement rather than on the absence of one.

**Environment.** EC2 secondary. `tsp -O hls` to nginx, pulled over HTTP/3 by
[`hls-verbatim-recv.py`](scripts/hls-verbatim-recv.py); the FFmpeg receiver re-muxes and would grade
itself ([T42](test-42-h3-receiver-fidelity.md)). Loopback with `netem`, 20 Mb/s provisioned, no added
RTT — **not** the `netns`/`cake`/100 ms rig the MoQ and SRT arms above used, for the reason in
[T31](test-31-congestion-capacity-ladders.md) § *The segmented ladder is in a different rig*. One
sample per cell, **wire** domain, at **P1**, receiver per-fetch timeout 15 s unless stated.

| Shape | Delivered bytes | Of control | Media lost | Continuity errors | PCR max | Carriage |
|---|---|---|---|---|---|---|
| none (control) | 82,851,600 | — | **0.000 s** | 0 | 24.95 ms | yes |
| sustained loss 5 % | 82,851,600 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| sustained loss 10 % | 82,851,600 | **100.0 %** | **0.000 s** | 0 | 24.95 ms | yes |
| outage 5 s | 100,837,560 (75 s window) | — | **0.000 s** | 0 | 24.95 ms | yes |
| outage 30 s | 79,533,400 (75 s window) | 78.9 % of the 5 s cell | 17.134 s | 10 | 17,139 ms | no: receiver exited 1 |

**Sustained loss is not merely survived, it is invisible.** At 5 % and at 10 % the receiver returns
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

| Receiver per-fetch budget | Delivered | Of control | Media captured | Holes | Continuity errors |
|---|---|---|---|---|---|
| 15 s (default) | 3,002,360 | 4.0 % | 2.4 s | — (refused) | 0 |
| 60 s | 18,967,320 | **25.4 %** | 57.0 s | 11 | 40 |

**Neither figure is a stable lane constant, and the spread between them is the finding.** A
six-fold move from a receiver setting means this cell measures the instrument as much as the lane,
and the method rule is in [method-notes](method-notes.md) § *A receiver's per-fetch timeout is a
measurement parameter*. What both readings agree on is the direction: **the segmented lane is badly
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
| 5 s | 0.227 delivered, 15.8 s of media, session cancelled at the outage | **0.961 delivered, 70.0 s of media, 0 continuity errors, carriage valid** |
| 30 s | 0.220 delivered, 16.5 s of media | 0.270 delivered, 15.4 s of media |

Under the shipped default the relay logs `subscribe canceled (idle)` at the moment the lane drops
and the session never recovers; the arm reads 0.220–0.227 whether the outage is 5 s or 30 s, because
what it is measuring is the time before the outage, not the outage. Pinned to CUBIC the same 5 s
outage costs 3.9 % of delivery. **A four-fold difference in the headline, from a flag that was not
set.**

**The 30 s cell is fatal under both controllers**, with the idle timeout already raised to 120 s so
that the teardown characterised in §*The 30 s cell was the QUIC idle timeout* is not the cause. Both
arms stop at the outage and neither resumes. In the `netns`/`cake` rig the same outage at a 120 s
timeout became ordinary starvation, so this is a rig difference and not a correction to that
section; what it shows is that on this path the segmented lane's 0.853 and the MoQ lane's 0.22–0.27
are not two readings of one phenomenon.

This is the third impairment shape on which the MoQ arm's result turned out to be the controller's:
[T20](test-20-segmented-http3.md) found it under reorder, where BBRv3 delivers zero bytes in 60 s
and CUBIC delivers 55.2 s of span, and [T31](test-31-congestion-capacity-ladders.md) finds it on the
capacity rungs. **No MoQ impairment cell in this campaign should be read without the controller
named beside it**, and cells measured before the controller was pinned cannot be assumed to have
used the one their file implies.

*Domain wire, measurement point P1, one sample per cell, single host over loopback with `netem` and
no added RTT. Delivery is quoted against the ladder's own control because the receiver joins on the
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
| 1 | Grader validity: a control reports 0 s lost and 0 continuity errors **on both lanes**; a synthetic hole reproduces the injected duration ± 100 ms | **Now passes on both lanes.** Every unimpaired control on the matched ladder grades 0.000 s lost and 0 continuity errors on MoQ *and* SRT. The earlier SRT failure (controls at 4.196–5.391 s lost) was real and the criterion is what caught it; its cause was the split publisher a source-side tap forces, not the tap, and a single-`tsp` publisher clears it |
| 2 | Matrix completeness | **Partial.** MoQ and SRT are run on three transport axes, all matched on measured latency and all two replicates deep: the outage axis (six budgets, plus four outage durations on MoQ and a re-convergence pass), sustained partial loss at 5 % and 10 %, and reorder at 5 % and 20 %. The segmented lane is run on the same three shapes but in a different rig and at one sample per cell, and its reorder cell is void on the receiver's fetch timeout. The bandwidth step and the infrastructure axis are not run |
| 3 | Ranking published | **Met for MoQ against SRT on all three axes run, and they rank three different ways.** By criterion 5's rule — lower median media lost wins — MoQ is superior under a discrete outage at every budget from 2 s up (0.20–2.23 s against SRT's 3.46–3.76 s); SRT is superior under sustained partial loss at every budget and both rates (0.000 s against 0.33–3.88 s at 5 %); and **reorder does not resolve into a ranking at all**, with SRT delivering the whole programme carrying 430–692 continuity errors and MoQ delivering it clean but losing 60 % of its picture match. All three are published, with the reason the first is incomplete: the lanes do not pay in the same currency, and a rule that scores only media lost cannot see that MoQ buys its content with delivery latency it never gives back. **A single-axis ranking of these two lanes is therefore not supportable, and no impairment shape stands for the others — that is now measured on three shapes rather than argued.** **The three-way ranking is still not published**, and now for a different reason: the segmented lane is measured on all three shapes, but in the loopback rig rather than the `netns`/`cake` one, so its column cannot be set against the other two rung for rung. What the segmented column does establish on its own controls is that loss at 5 % and 10 % is byte-identical to unimpaired, a 5 s outage likewise, a 30 s outage costs 17.134 s, and reorder is the shape that hurts it |
| 4 | Comparability | **Pass on the cells run.** One host, one rig, one build, one clip, one grader and one domain across every cell, with an unimpaired control through the same path. On the matched ladder the SRT arm's `--latency` is additionally set from the MoQ lane's measured median rather than its nominal budget |
| 5 | Segmented receiver axis | **Not run.** The apparatus is on the same host (T20's HTTP/3 and HLS lane), so this is now a session's work rather than a blocker |

## What remains

Nothing here is blocked on a third party, a loan or an account. The apparatus, the clips, the binaries
and the grader are all on the EC2 secondary, which has 29 GB free — the disk objection this file used
to record was against a stale figure.

- ~~**Replicate the latency-budget non-monotonicity.**~~ **Done — it did not replicate**, and the
  sizing rule drawn from it is withdrawn; see *The budget ladder replicated*. What remains of it is a
  small reproducible bump at 4 s, unexplained.
- ~~**Make the SRT arm comparable**: a mirroring latency tap, and SRT matched on measured rather than
  nominal buffer.~~ **Done** — see *The matched ladder*. Both rig defects are fixed and both lanes
  grade clean unimpaired.
- **Add the latency axis to the pre-registered scoring rule.** Criterion 5 ranks on media lost alone,
  which scores MoQ superior at every budget from 2 s up while missing that it pays in permanent
  delivery latency. Any future lane comparison here needs a two-axis verdict; that revision is not
  yet written.
- **Extend the re-convergence pass beyond 117.8 s.** The source clip, not the commanded window, ended
  it. A lane flat to ±0.24 s over 75 s is not converging, but "never" is not yet measured.
- ~~**Bracket the idle timeout.** 20 s and 40 s outages with the idle timeout set explicitly, to
  separate a starved session from a dead one.~~ **Done** — the flag is `--quic-idle-timeout`, not
  `--server-quic-idle-timeout`, and the result is in §*The 30 s cell was the QUIC idle timeout*. One
  replicate per cell; worth replicating before any figure from it is quoted outside this file.
- ~~**The loss step.**~~ **Done, and it reverses the outage ordering** — see §*Sustained partial
  loss*. What it leaves open is narrower: the 10 % MoQ cells are unranked on unequal spans and want
  a re-run, the duplication signal is unattributed, and a genuine SRT budget sweep under loss was
  not run because matching on measured latency collapsed the three budgets onto one setting. **The
  segmented arm's answer is that loss at 5 % and 10 % is byte-identical to its control**, so this
  axis now separates all three lanes.
- ~~**The reorder step.**~~ **Done, and it ranks the lanes a third way** — see §*Reorder is a third
  pattern*. It leaves one question sharper than it found it: MoQ's matched-picture count falls to
  ~40 % at 20 % reorder, which is currently a caveat on the latency column and may be a real
  presentation-order defect. Separating those needs an instrument that grades output order directly
  rather than inferring it from picture pairing.
- **The bandwidth step**, the last of the transport axes, on the rig as it stands.
- **The infrastructure axis**: kill and restart a publisher, a relay and an exporter. This needs no
  emulator and could equally run on the macOS workstation.
- ~~**The segmented lane**, using T20's HTTP/3 and HLS apparatus already built on the same host.~~
  **Run on all three shapes** — see §*Measured — the transport axis, segmented lane*. Three things
  it leaves: the reorder cell is void on the receiver's 15 s per-fetch timeout and needs re-running
  with the budget raised; every cell is one sample where the other lanes are two; and it is in the
  loopback rig rather than the `netns`/`cake` one, so criterion 3's three-way ranking still cannot
  be drawn from it.
- **The segmented lane inside the `netns` rig**, which is what a rung-for-rung three-way ranking
  needs and is a rig change rather than a re-run: the origin has to be reachable from inside the
  namespace.

Quoting [T6](test-6-relay-resilience.md) recovery times as programme-loss figures remains
methodologically out of bounds, but the MoQ lane now has real programme-loss figures of its own for
the outage row.

