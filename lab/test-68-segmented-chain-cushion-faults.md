# Test 68 — The segmented chain's cushion, catch-up and path faults

**State: parts B and C run, every criterion holds; part A not yet run.** Two independent chains of
the current segmented design are byte-identical from a 3 s cushion with the receiver's hold and the
groomer's alignment, and from 1.5 s with neither, against the 8 s the lane has used; the floor is
set by how the epoch cuts the clip. A 10 s frozen playlist costs a leg what its cushion fails to
cover, 2.44 s at 8 s and nothing at 10.5 s, and the groomer's cap never binds. Rig:
[`t68-seg-pair.sh`](scripts/t68-seg-pair.sh), driven by [`t68-drive.py`](scripts/t68-drive.py).

## Objective

P1-ag. The segmented lane's fault figures ([T28](test-28-failure-injection-matrix.md)'s segmented
rows, [T31](test-31-congestion-capacity-ladders.md)'s ladder) and its 8 s cushion
([T12](test-12-dual-path-handoff.md)) were measured on the first chain: `tsp -O hls`, TSDuck's or a
verbatim HLS input, and a groomer fed as segments arrived. The chain
[T59](test-59-segmented-1plus1-cloudfront.md)–[T63](test-63-pdt-anchored-release.md) measured
replaced every stage but the origin: a packager that cuts and names by content time
([`t61-epochseg.py`](scripts/t61-epochseg.py)), a receiver that retries and can hold each segment
until its last PCR's program date-time plus a fixed hold ([`b8-hls-recv.py`](scripts/b8-hls-recv.py)),
and a stream-clocked groomer. Three questions on that chain:

- **B. The cushion.** The smallest groomer cushion at which two independent chains emit
  byte-identical RTP, to 0.5 s. T12 found 1 s failing and 8 s holding on the first chain, and 8 s
  was never a minimum. It sets P1-ah's configurations.
- **C. A catch-up.** What a 10 s frozen playlist costs one leg, and whether the groomer's cap or its
  cushion decides it. [T30](test-30-segmented-distributed-resilience.md)'s frozen playlist lost
  0.40–0.48 s, dropped by an adaptive groomer's 8 s cap from the catch-up burst.
- **A. Path faults.** T28's shapes at its durations in its `netns`/`cake` rig, beside its MoQ and
  SRT rows at matched latency.

## Environment

| | |
|---|---|
| Host | the EC2 tertiary (8 vCPU, Ubuntu 26.04), no other rig running |
| Source | `contrib-10m.ts` (9.95 Mb/s on its PCR), `tsp -P regulate` to UDP multicast on loopback, from the clip's start each run |
| Packager | `t61-epochseg.py --duration 2 --window 6 --extra 3 --pdt`, one per chain. On this clip its random-access points fall every 1.2 s, so it cuts mostly 2.4 s and 1.2 s segments (48 and 28 of the first 89), the rest 1.6–2.84 s |
| Origin | nginx 1.28, one per chain; playlist `max-age=1`, segments `max-age=60` |
| Receiver | `b8-hls-recv.py`, 250 ms poll, joining one segment back from the live edge |
| Groomer | `mpegts-pacer` `97f3a38`, `--stream-clock` at 11.438 Mb/s, `--stall-ms 1000 --on-stall mute`, cap 14 s unless stated |
| Graders | [`t12-rtpcmp.py`](scripts/t12-rtpcmp.py) at equal RTP timestamps (B); [`t68-rtp2ts.py`](scripts/t68-rtp2ts.py), then [`t28-content-lost.py`](scripts/t28-content-lost.py) `--from-s 8` (C) |

## Procedure

**Parts B and C.** `t68-seg-pair.sh <out>` starts the source, two packagers and two origins, waits
until both serve a playlist, then starts both legs together and records their RTP from the sockets.
Environment: `LAT_MS` (the cushion), `HOLD_MS` (the receiver's hold), `ALIGN_MS` (the groomer's
alignment watch), `CAP_MS`, `WINDOW`. Part C adds `FREEZE_AT=70 FREEZE_S=10` (70 s, past the
design's 30 s alignment watch and first output): chain A's origin
serves a copy of the playlist in place of the live one for 10 s while segments keep landing, and
chain B is the control. `FREEZE_PHASE` delays the freeze until that many seconds after chain A's
next listing. Each groomer's closing counters (cap drops, late drops, withheld, cut runs, stalls,
muted) and its highest buffer level are on the run's `RESULT` line. A short ungraded run checks the
rig first.

Two variants, because the deployed receivers and the measured design differ:

- **Design:** hold 1.5 s and alignment 30 s, as T62 and T63 ran it; 150 s of legs.
- **Default:** no hold and no alignment, as the standing receiver units start; 120 s of legs.

**Part A.** [`t68-netns-cell.sh`](scripts/t68-netns-cell.sh) runs one chain in T28's rig
(`t8b-netns.sh`, 20 Mb/s `cake`, 100 ms RTT): source and packager on the host, nginx in the
publisher namespace, receiver and groomer in the subscriber namespace, each shape on the media
direction as T28 applied it. Video PTS is tapped at the source (mirrored) and at the groomer's output
(inline) by `t18-latency.py`, T28's matching instrument. Design variant only, with the receiver's
defaults (3 s socket timeout, a failing segment given up after 4 s). A cell's clock starts at the
groomer's first output, after its alignment watch: 20 s clean, then the shape, and the receiver and
groomer stop together at 60 s (outage) or 95 s (loss, reorder).
[`t68-netns-drive.py`](scripts/t68-netns-drive.py) runs an arm (placement, controller, cushion): its
control, three replicates of each shape replicate-major, then each cell conserved against the
control at the groomer's output and at the receiver's.

The hold is 2.5 s in both columns, set by the link rather than taken from the loopback design: at
20 Mb/s a 2.84 s segment takes 1.4 s to cross, so 1.5 s cannot hold, and 2.5 s leaves the 5.91 s
column its 3 s floor. The cushion then moves until criterion 9 holds. The rig check, an ungraded
control at T28's placement on CUBIC, showed what the hold cannot cure. The receiver fetches one
segment at a time: after a held segment it waits a poll and re-reads the playlist before the next
fetch. So each 1.2 s segment, about 0.9 s to fetch, arrived 60–450 ms past its release whatever the
hold, 21 of 47 segments in all. The cushion absorbed every one, and the control conserved to 0.0 s.
Criterion 7's second half therefore fails at T28's placement, and its bias arm runs beside the
T28-placement arms, not in their place: CUBIC with the whole RTT on the acknowledgement path, as
T28's topology check ran it, at 5.91 s. It runs the outage and loss shapes only, because reorder
needs a delay in front of the shaper. If a shape loses programme where the receiver gave a segment
up or timed out, that shape is re-run at `--timeout 10 --give-up-ms 15000` (method notes § *A
receiver's per-fetch timeout*).

## Pass criteria, fixed before running

**B, the cushion.**

1. **Control.** In the design variant at an 8 s cushion, the two chains are 100.0000 % identical
   with no residue over the slots both carry, and neither groomer counts a late drop, withheld
   packet, cut run, stall or muted packet from its first output to the legs' stop
   ([`t68-grade.py`](scripts/t68-grade.py), from its 1 s samples). The rig check showed each leg
   paying the same start-up cost before its first output (2,772 late drops at 8 s) and cutting its
   last run when the receiver stops; those are reported, not graded. Otherwise the rig is faulty
   and part B stops.
2. **Bisection, per variant.** The smallest cushion, in 0.5 s steps, at which three runs of three
   meet criterion 1. The search starts at T12's failing 1 s. If 1 s meets it, the search steps down
   to 0.5 s and reports ≤ 0.5 s if that meets it too. If 1 s fails, it bisects 1–8 s one run per
   step, then runs three at the minimum found and one 0.5 s below it. Identity reached while
   both groomers drop the same late packets is not a pass: the counters are part of the criterion.
3. **Scope.** The loopback minimum is the chain's own floor. Fetch time over a real path adds to it,
   which P1-ah measures.

*Predicted:* the floor is set by how unevenly the epoch cuts this clip, not by the poll or a
loopback fetch. A groomer anchored on a 1.2 s segment has 1.2 s less slack on every 2.4 s one, so
the floor should lie between about 1.2 and 3 s in both variants.

**C, a catch-up.** In the design variant at the standing 14 s cap.

4. **Control.** Chain B loses no video and its groomer counts nothing, as in criterion 1.
5. **The cushion that keeps the freeze lossless.** Three runs at the standing 8 s cushion with the
   freeze at 1.9 s after a listing (meant as the worst phase on 2 s epochs; on this clip's cuts it
   was not, see *Results*), then at 0.5 s steps upward until
   three runs of three lose no video on chain A. Each run reports chain A's video lost, its groomer's
   cap drops and late drops, and its receiver's lateness for each segment after the thaw.
6. **The cap.** No run drops at the cap, and every groomer's highest buffer level stays below it,
   counted from its first output to the legs' stop as in criterion 1. The window was stated after
   part C's first run, which showed what part B's runs had too: the design's 30 s alignment watch
   fills the buffer to the cap and drops at it before the first output, on both legs, freeze or not.

*Predicted:* a segment held to its last PCR's time plus the hold cannot reach the groomer early, so
its depth peaks near the cushion plus a segment, and the cap never binds. What decides the freeze is
the cushion: chain A loses roughly the freeze plus the poll, less the hold, the cushion and the
freeze's phase (about 0.5 s at 8 s), and nothing once the hold plus the cushion exceeds the freeze
plus the poll (about 9 s).

**A, path faults.** In its own pass.

7. **Rig control.** Before any impaired cell, an unimpaired control in the rig conserves to 0.0 s of
   video, and its receiver's fetches finish inside the hold at the 99th percentile. Otherwise the
   rig's bias against TCP ([method notes](method-notes.md) § *Delay in front of the shaper*) is named
   and run as its own arm, not tuned away.
8. **Shapes**, at T28's durations and delay placement: a 5 s outage in a 60 s cell; 5 % and 10 %
   loss, and 5 % and 20 % reorder (`netem delay 50ms reorder P% 50%`), each impaired from 21 s to
   61 s of a 95 s cell; three replicates. Video lost is conserved against the window (method notes
   § *A hole count*), at the groomer's output with the receiver's beside it.
9. **Matched.** The cushion is set so that the unimpaired control's latency is within 100 ms of
   T28's 5.91 s and 11.87 s columns, measured as T28 measured its lanes. A column out of reach is
   reported as such, not approximated.
10. **Controller.** The loss and reorder shapes run with the origin's TCP on CUBIC (the kernel's
    default) and on BBR, set in the publisher namespace.

*Verdict:* per shape and column, the segmented lane's median video lost beside T28's MoQ and SRT
medians.

## Results

Groomer `97f3a38`, loopback, both chains started together from the clip's start. Late drops are
converted at the clip's 9.95 Mb/s. Below the floor, a leg starves at every long segment: it stalls,
mutes and late-drops.

**Part B.** Two independent chains, 120 s of legs (150 s in the design variant). Each run's identity
is 100.0000 % with no residue over the 63,268–133,750 slots both legs carry, at every cushion:

| Variant | Cushion | Runs | Each leg, first output to stop | Verdict |
|---|---|---|---|---|
| Design: hold 1.5 s, alignment 30 s | 8 s | 1 | clean | pass (criterion 1) |
| | 4.5 s | 1 | clean | pass |
| | **3 s** | 4 | clean | **pass, the floor** |
| | 2.5 s | 2 | 3 stalls, 1,708–1,731 late drops (0.26 s) | fail |
| | 2 s | 1 | 36 stalls, 89,021–89,153 late drops (13.5 s) | fail |
| | 1 s | 1 | 58 stalls, 360,437 late drops (54.5 s) | fail |
| Default: no hold, no alignment | 8, 4.5, 3, 2 s | 1 each | clean | pass |
| | **1.5 s** | 4 | clean | **pass, the floor** |
| | 1 s | 1 | 37 stalls, 100,091–100,104 late drops (15.1 s) | fail |

Below the floor the two legs drop nearly the same packets (their late-drop counts within 1.4 % of
each other), so where both carry a slot they agree. Identity alone would have passed every failing
run, and only the counters failed them. Each design leg's 30 s alignment watch fills its buffer to the cap and drops at it before its
first output. The four default runs at 1.5 s are identical to the packet (129,798 shared slots
each): every run starts from the clip's start, so each leg anchors on the same segment.

**Part C.** Design variant, cap 14 s (106,470 packets, 16.1 s of this clip). Chain A's playlist
was frozen 10 s, and its next listing came 0.51–0.52 s after the freeze in every run. The clip
cuts mostly 2.4 s and 1.2 s segments, so a freeze 1.9 s after the listing that opens a 2.4 s
segment falls 0.5 s before the next one, not at the worst phase. The first segment after the thaw
reached the groomer 8.11 s late in every run.

| Cushion | Runs | Chain A video lost | Chain A's groomer, first output to stop | Chain B |
|---|---|---|---|---|
| 8 s | 3 | 2.44 s each | 1 stall, 16,001–16,024 late drops | 0 lost, clean |
| 8.5 s | 1 | 2.04 s | 1 stall, 12,845 late drops | 0, clean |
| 9 s | 1 | 1.52 s | 1 stall, 9,661 late drops | 0, clean |
| 9.5 s | 1 | 1.00 s | 1 stall, 6,495 late drops | 0, clean |
| 10 s | 1 | 0.52 s | 1 stall, 3,320 late drops | 0, clean |
| **10.5 s** | 3 | **0 at the grader's 100 ms tolerance** | 1 stall, 155 late drops (23 ms) each | 0, clean |

No run dropped at the cap from first output to stop. The highest steady level was 10.0 s of content
at a 10.5 s cushion. The frozen leg's peak after its catch-up equalled the control leg's, because a
segment released at its program date-time cannot arrive early.

**Grading.** Criterion 1 holds. Criterion 2: the floor is **3 s** with the hold and alignment and
**1.5 s** with neither; each was reached by bisection, held in four runs of four, and failed 0.5 s
below. Part B's prediction holds: both floors lie in 1.2–3 s. Criterion 4 holds in every part C
run. Criterion 5: **10.5 s**, three runs of three, at this phase. Criterion 6 holds. Part C's
prediction fails (it predicted about 0.5 s lost at 8 s and nothing from about 9 s). It took the
clock from a segment's first packet, but the design's alignment ties the clock to the content
that arrived soonest after its stream position. Under the release that is a segment's last
packet, so a segment's first packet has the cushion less its span. The frozen leg then loses
about freeze + poll − phase + span − hold − cushion, which is 2.4–2.6 s at 8 s (the poll's part
is 0–0.25 s) against the measured 2.44 s. It falls one second per second of cushion, as measured.

## Conclusions

1. **On the current chain, two independent segmented chains are byte-identical at a 3 s cushion,
   not 8 s.** That holds with the receiver's 1.5 s hold and the groomer's alignment, as T62 and T63
   ran them. With neither, the floor is 1.5 s. Both figures are for this clip; over a 12 ms internet
   path both hold ([T70](test-70-segmented-latency-budget.md)).
2. **The floor is the clip's cuts, not the receiver or the path.** Aligned, the cushion must cover
   the longest segment's span, 2.84 s here. Unaligned, it must cover the longest span less the
   anchor segment's. The epoch cuts this clip's 1.2 s GOP into 2.4 s and 1.2 s segments, so a source
   whose random-access points fall on the epoch would need less.
3. **Below the floor, identity is not the test.** Both legs lose the same programme and still agree
   wherever both carry, so a 1+1 grade reads the groomers' counters.
4. **A catch-up is the cushion's, not the cap's.** Under the stream clock and the release, no
   catch-up deepened the buffer and the cap never bound. A 10 s frozen playlist costs one leg
   freeze + poll − phase + span − hold − cushion: 2.44 s at the standing 8 s, and nothing at 10.5 s
   at this phase; at no phase and the 2.84 s segment the formula gives about 11.6 s, unmeasured. In
   a 1+1 pair the other leg covers it: chain B lost nothing.
5. **For P1-ah:** the design's floor at 2 s epochs is 3 s of cushion behind a 1.5 s hold. A single
   leg that must also ride a 10 s frozen playlist needs 10.5 s at the measured phase, and by the
   formula up to about 11.6 s. The standing 8 s sits between.

## Limits

One host, loopback, one clip; legs started together from the clip's start, so each variant
anchored on one segment, and the default variant's floor could need up to the longest span less
the shortest (1.64 s here, plus the poll) on another anchor. One freeze phase, and one freeze
length. Part A has not run.
