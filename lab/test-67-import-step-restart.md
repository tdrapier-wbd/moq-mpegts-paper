# Test 67 — The import's own restart at an unflagged encoder switch

**State: run, three times per stimulus and a control, on two builds.** At an unflagged encoder switch, back or forward, the import republishes itself and neither export ends. Past the catalog fix a switch costs 160 ms of programme on T64's stimulus, the truncated picture and the wait for a random-access one; on T34's capture it still costs 1,600 ms, because the import announces the new instance 1.2 s late, its catalog waiting on every track, and the stitched export starts at its second group (traced). Behind a supervisor it cost 2,400–2,800 ms. The passthrough lane, which ended at a step back, carries both directions with every byte on #9069's branch (loopback). On `main`, which has merged it, its 72 h shadow on the live feed met three of the encoder's own switches, one back and two forward, and carried each with no stall, no loss and nothing ended; the relay and the export outgrew the memory criterion, at no switch. Rig: [T41](test-41-import-reanchor-coverage.md)'s [`t41-rewind-supervisor.sh`](scripts/t41-rewind-supervisor.sh), graded by [`t41-rewind-grade.py`](scripts/t41-rewind-grade.py); stimuli from [T34](test-34-real-encoder-severity.md) and [T64](test-64-synthetic-encoder-switch.md).

## Objective

Upstream's `main` now republishes a TS import itself when its clock steps onto another timeline: the PCR and every stream stepping back, flagged or not, or more than 10 s forward unflagged. The broadcast ends there and the rest of the input publishes under a new epoch, which `export ts --stitch --follow` carries on into. Measure what that costs a subscriber at the switch T34 caught on the live feed, and at T64's synthetic switch in both directions, against what a supervisor restarting the import cost on the build before it.

**Falsifies:** [evidence](evidence.md) §3.13's account of the current build, that a backward step ends the import and a supervisor's republish costs 2.8–3.8 s per step; and T34's forward step ending every export.

## Environment

The laptop, loopback: one relay, one import, two exports in one invocation, `moq-lite-07-wip`. `main` `548a41ec3` (thin LTO, functional), which carries the restart; control `main` `66af72315`, T34's and T64's build, on which the step back ends the import and the forward step ends the exports.

## Procedure

`t41-rewind-supervisor.sh <bin> <out> <stimulus> pipe <secs>` with `EXPORT_ARGS=--stitch`: the source played in real time through `tsp -P regulate` into the import, two exports at `--delay 1s --follow 30s --stitch`. The supervisor stays as an instrument: on `main` it should record one start and one exit, after the source has ended.

| Stimulus | Built by | Switch | `VPID` | Played |
| --- | --- | --- | --- | --- |
| T34's capture | the ring's five files, lifted 30,000 s (`p0j-lift.py`) | back 16,844.35–16,844.65 s, 71.2 s in | 111 | 95 s |
| T64 back | `t64-switch.py <out> back` | back 16,844.70–16,845.00 s, 30 s in | 257 | 55 s |
| T64 forward | `t64-switch.py <out> forward` | forward 16,844.00–16,844.30 s, 30 s in | 257 | 55 s |

Before the runs, `p0j-splice.py` on each stimulus: the real switch at packet 1,182,916 with T34's steps, and each synthetic one T64's class. Three runs per stimulus on `main`, and one run of T64 back on `66af72315`. Each run graded with `t41-rewind-grade.py --pts`, and again on decode times, which T34's table uses.

## Pass criteria, fixed before running

0. **Control.** On `66af72315` the T64 back run reproduces T64: the import exits once at the switch with the live error, and the programme lost on presentation times is within 200 ms of T64's 2,400–2,480 ms. Otherwise `main` is compared with today's control, not with T64's table.
1. **Validity.** A run counts if the source plays in real time across the switch (no gap over 0.5 s in its tap within 5 s of it) and both exports exit 0 after the source has ended; otherwise it is reported, not graded.
2. **H1, the restart engages.** On `main` no import exits at a switch, in either direction: the supervisor records one start, and its one exit follows the source's end. Fails if any does.
3. **H2, back, it costs no more than a supervisor's restart.** Per export, the programme lost on presentation times is at most 200 ms above the supervisor's on `66af72315`: T64's 2,400–2,480 ms on the synthetic switch, and T34's 2,800 ms (decode times) on the real one, compared on decode times. Lower is reported with its parts (the old encode's held tail, the new encode's head).
4. **H3, forward, the exports carry on.** Neither export ends at the forward step, and the programme lost is reported as found. Fails if either ends there.
5. **Reported, not graded:** the longest arrival gap, the first post-switch picture's delay beyond the steady latency, and whether the two exports are byte-identical.

## Results

**Every run counts.** The source's longest pause within 5 s of the switch was 85–148 ms, and every export exited 0 after the source ended. The stimuli classified as T34 and T64 recorded them: the capture's splice at packet 1,182,916 with T34's steps, and the synthetic switch stepping 16,844.70–16,845.00 s back or 16,844.00–16,844.30 s forward, unflagged.

**The control reproduces T64 (criterion 0).** On `66af72315` the import exited once at the switch, _frame timestamp … is below the previous group's start_, and its successor started 32 ms later. The two exports lost 2,480 and 2,400 ms on presentation times, inside T64's range.

**The restart engages, both ways (H1 holds).** On `main` every import logged _the source's clock stepped; republishing_, with the step, _went back_ or _jumped forward_, and _without a discontinuity_indicator_, and published a new epoch 0.3–1.5 ms later. The supervisor recorded one start in each of the nine runs, so no import exited.

**It costs about half what a supervisor's restart did (H2 and H3 hold).** Each figure holds on both exports of every run. The real switch is on decode times, as T34's table is:

| Switch | Build | Runs | Programme lost (ms) | Old encode's tail (ms) | New encode's head (ms) | Longest arrival gap (ms) | First post-switch picture beyond the latency (ms) | Latency before the switch (ms) |
| --- | --- | --: | --- | --- | --- | --- | --- | --- |
| T64 back, presentation times | `66af72315` (control) | 1 | 2,400–2,480 | 1,120–1,200 | 1,280 | 2,373–2,395 | 1,304–1,305 | 1,136–1,137 |
| T64 back, presentation times | `548a41ec3` | 3 | 1,360 | 80 | 1,280 | 1,397–1,404 | 1,308–1,312 | 1,133–1,135 |
| T64 forward, presentation times | `548a41ec3` | 3 | 1,360 | 80 | 1,280 | 1,400–1,408 | — | 1,145–1,149 |
| T34 back, decode times | `66af72315` (T34) | 3 | 2,800 | 1,240 | 1,560 | 2,778–2,785 | 1,564–1,572 | 1,203–1,212 |
| T34 back, decode times | `548a41ec3` | 3 | 1,600 | 40 | 1,560 | 1,516–1,541 | 1,474–1,503 | 1,215–1,228 |

The whole saving is the old encode's tail. Behind a supervisor the old broadcast ended with about the export's latency of it held and unreleased; now the export plays it to the switch. What remains of the tail is the picture the switch cut mid-PES, the source's own loss. The new encode's head is unchanged to the millisecond: on T64's switch the restarted import's catalog hold, which #7293 removes; on the capture not (§ _On `main` past the catalog fix_). On presentation times the capture costs 1,960 ms, 320 + 1,640: its truncated last picture is presented 400 ms after its decode time, so it counts in that clock's tail.

**The exports stayed byte-identical across T64's switch in all six runs**, back and forward, where the control's parted at the stitched break, its flag 80 packets apart on the two legs. On the capture they were 96.5–98.8 % identical, parting on the video, the MP2 and the teletext, from the run's first seconds in two runs and after the switch in the third.

**The grader's presentation-time mode mis-split the capture**, taking a 280 ms reordering step four pictures in for the switch. [`t41-rewind-grade.py`](scripts/t41-rewind-grade.py) `--pts` now finds the cut and each break in decode order and measures on presentation times; it reproduces every synthetic figure and gives the capture's 1,960 ms.

## On `main` past the catalog fix

`main` `204c97f4f` (thin LTO) carries `restart-catalog` (#7293): a restarted import publishes its catalog at once. The same rig, three runs per stimulus. T34's capture is regenerated byte-identical (sha256 `4f7aa6b2…`); T64's encodes are not deterministic, so the synthetic stimuli are new files of the same class (`p0j-splice.py`: back 16,844.7–16,845.0 s, forward 16,844.0–16,844.3 s, unflagged).

_Criteria, fixed before running:_

- **R0, control.** `548a41ec3` on the new synthetic back stimulus loses 1,360 ms ± 200 ms on presentation times; otherwise the synthetic rows are compared with this control, not T67's table.
- **R1.** Criteria 1 and 2 above, unchanged: valid runs, and no import exits at a switch.
- **R2, the head.** The new encode's head falls by at least 200 ms below 1,280 ms (synthetic) and 1,560 ms (the capture, decode times) on every run; otherwise the fix does not change what a subscriber loses here.

_Predicted:_ the head falls to the wait for the new encode's first random-access picture plus the export's re-anchor, under 700 ms.

**Results.** Every run counts but the third forward one, whose exports both ended on a broken pipe at teardown, 15 s after the source; a fourth replaced it. Each valid run recorded one import start and no exit, and the source's longest gap was 0.21 s.

| Switch | Build | Runs | Programme lost (ms) | Old encode's tail (ms) | New encode's head (ms) | Longest arrival gap (ms) |
| --- | --- | --: | --- | --- | --- | --- |
| T64 back, presentation times | `548a41ec3` (control) | 1 | 1,360 | 80 | 1,280 | 1,400 |
| T64 back, presentation times | `204c97f4f` | 3 | 160 | 80 | 80 | 155–162 |
| T64 forward, presentation times | `204c97f4f` | 3 | 160 | 80 | 80 | 200 |
| T34 back, decode times | `204c97f4f` | 3 | 1,600 | 40 | 1,560 | 1,361–1,394 |

On decode times T64's switch costs 200 ms (40 + 160) both ways. **R0** passes, to the millisecond. **R1** passes. **R2 passes on T64's switch and fails on T34's capture**, whose head is unchanged.

**The capture's head is not the hold #7293 removes.** The export's first picture after the switch is the source's second random-access picture, 1,680 ms of presentation time past the cut (its decode time is the export's own); the new encode's first, 80 ms in, never reached it. The export's requests for that group were refused as `old` 1.2 s after the republish: that is when the stitched export turns to the new instance (traced below), and it starts at its newest group. On this capture video leads its decode time by 0.76 s and the GOP is 1.2 s, so the second group has begun by then; on T64's 2 s GOP the first is still the newest. The exports stayed byte-identical across T64's switch in all six valid runs, and were 98.7–99.8 % identical on the capture, parting on the video and PID 131.

## The capture's head, traced

One run of the capture on `204c97f4f`, the same rig, with every process at `RUST_LOG=info,moq_mux::container::ts::handoff=debug,moq_mux::container::ts::follower=debug,moq_mux::follow=debug`: the export's own record of each phase of a turn to a new instance (`left`, `follow`, `prepared`, `adopt`, `keyframe`), against the import's republish and its refused fetches.

_Criteria, fixed before running:_

- **TR0, validity.** Criterion 1 holds and both exports lose 1,600 ms ± 200 ms on decode times; otherwise the trace changed the run and nothing is read from it.
- **TR1, the reading holds** if on each export the old program's `left` precedes the new instance's `follow`, that `follow` comes at least 0.8 s after the republish, and the refused fetches follow it.
- **TR2, the reading fails** if `follow` comes within 0.3 s of the republish: the export turned at once, and the phases after it locate the loss instead.
- **TR3, where a late turn is spent**, fixed after the first traced run and before the second, which adds `moq_net::lite::subscriber=debug` (each session's receipt of an announcement or takeover): in the import if the relay receives the new instance 0.8 s or more after the republish; in the relay if it receives it within 0.3 s and the export 0.8 s or more later; in the export if both receive it within 0.3 s and its `follow` comes 0.8 s or more after.

**Results.** Both runs count (TR0): the source's longest gap within 5 s of the switch was 147–148 ms, both exports exited 0 after the source, and each lost 1,600 ms (40 + 1,560), as untraced. Times are from the import's republish; the two exports agree within 2 ms:

| Event | Run 1 (ms) | Run 2 (ms) |
| --- | --: | --: |
| The relay receives the old instance's withdrawal | — | +1.2 |
| The relay receives the new instance's announcement | — | +1,197 |
| The export receives it, logs _broadcast replaced_ and `follow` | +1,199 | +1,197 |
| The relay refuses the export's fetches as `old` | +1,207 | +1,202 |
| The new instance's first keyframe reaches the export (`prepared`) | +1,215 | +1,210 |
| `adopt`: the new program goes out | +2,346 | +2,347 |

**TR1 fails on its first clause and TR2 fails; TR3 places the delay in the import.** No `left` is logged: the export never ends the old program before turning, and turns within 2 ms of the announcement. The relay receives the old instance's withdrawal at once and the new instance's announcement 1.2 s later. At this build the import holds a new broadcast's announcement until its catalog's first snapshot goes out, which waits until every track the import created has published its configuration. On the capture every elementary stream's first unit starts within 0.76 s of the cut (SCTE-35 PID 0x8D last); which track's configuration resolves at 1.2 s is not traced.

## The passthrough lane: a splice in place of the end

`import ts --passthrough` ended at every step back ([#8911](https://github.com/moq-dev/moq/issues/8911)), and `export ts --passthrough` cannot follow a republish. [#9069](https://github.com/moq-dev/moq/pull/9069) (open, head `db0b251d4`) splices a step back, flagged or not, and an unflagged step forward of more than 10 s behind a break marker, the bytes passing unchanged. Its parent `f1eecd3a7` is the control; both thin LTO, on the laptop's loopback, `moq-lite-07-wip`. The supervisor runs as above with `IMPORT_ARGS=--passthrough FOLLOW=0` (a passthrough export refuses `--follow`): two exports `--delay 1s --passthrough` from the start, and a third (`LATE`) joining 9 s after the switch, on the table's three stimuli. One run per stimulus on the parent, three on the head. [`t67p-bytes.py`](scripts/t67p-bytes.py) grades each export's bytes against the stimulus; `t41-rewind-grade.py` the arrivals.

_Criteria, fixed before running:_

- **PS0, control.** On the parent the import exits at the switch in the capture's and T64's back runs, as #8911 reports; the forward run is reported. Otherwise the head is compared with what the parent did.
- **PS1, validity.** Criterion 1's condition on the source; on the head, every export exits 0 after the source has ended.
- **PS2, the import carries on.** On the head the supervisor records one start in every run, and its one exit follows the source's end.
- **PS3, the bytes pass.** Each export's output is the stimulus's own bytes from its first packet to its last: no packet missing or altered, at the switch or elsewhere.
- **PS4, no stall.** No export's longest picture arrival gap within 10 s of the switch exceeds 0.5 s.
- **PS5, a late join.** The late export's first picture arrives within 3 s of its start.
- **Reported:** where each export starts and ends in the stimulus, what the logs say at the switch, and each export's longest gap.

_Results: every criterion holds._

| Build, stimulus | Import at the switch | Exports a and b | Late export | Longest gap near the switch |
| --- | --- | --- | --- | --- |
| Parent, T64 back | exits: `PCR on PID 257 went back … without a discontinuity_indicator` | exit 1, ending at the switch (stimulus packet 113,223) | reads the supervisor's restarted import | — |
| Parent, capture | exits, the same message on PID 111 | exit 1, ending at packet 1,166,546 | as above | — |
| Parent, T64 forward | carries on | each loses 197 packets at the switch, 80 ms of the old encode's tail | — | — |
| Head, T64 back and forward (×3 each) | carries on; one start, no exit | exit 0; the stimulus's own bytes, packets 4 to 219,811 (forward 219,801), no break | the stimulus's own bytes from its join, first picture 0.36–1.03 s after its start | 65–87 ms |
| Head, capture (×3) | as above | exit 0; packets 1,578 to 1,579,881, no break | as above | 197–199 ms |

On the head no log line marks the splice, the programme lost nothing, and the two exports are byte-identical. `t41-rewind-grade.py` counts seven continuity holes after the capture's switch; byte identity puts them in the stimulus. The import outlived the source on both builds, the rig holding its pipe open.

_The shadow, criteria fixed before running._ The branch then runs against the live feed for 72 h on the primary, to meet the encoder's own switches ([`t67p-shadow.sh`](scripts/t67p-shadow.sh)): its own loopback relay, a passthrough import of the feed's multicast group and an export `--delay 1s --passthrough`, each supervised; [`t67p-tap.py`](scripts/t67p-tap.py) counts packets, continuity errors and PCR steps every 10 s before the import and after the export.

- **SH1, validity.** The input records at least one PCR step of more than 1 s; otherwise the run is inconclusive and extended.
- **SH2, nothing ends.** The import's and the export's supervisors each record one start and no exit before the rig stops.
- **SH3, nothing stalls or drops at a step.** Within 30 s of each step the output's longest read gap is at most 0.5 s and it gains no continuity error the input lacks; the difference between the input's and the output's cumulative packet counts moves across the step (60 s before to 60 s after) by no more than its range over the hour before.
- **SH4, no growth.** Each process's resident memory at the end is within 1.5× its value after the first hour.
- **Reported:** each step's direction and size, and the log lines around it.

_The shadow's first 72 h, on the branch before its final fix: inconclusive._

- **SH1 fails:** the input recorded no PCR step in 72.0 h and 4.31 G packets, so the run is extended, on `main` past the merge, under the same criteria.
- **SH2 holds:** each supervisor recorded one start and no exit.
- **SH3 has no step to grade.** Without one, the output's longest read gap was 239 ms (the input's 233 ms), its six continuity errors were the input's six, and the difference between the two cumulative packet counts held at 54,600 ± 270, the export's 3.3 s behind the import.
- **SH4 fails on the relay**, which grew 1.92× from the first hour to the end (251 to 481 MB); the import grew 1.44× (225 to 325 MB) and the export 1.19× (262 to 311 MB). The relay's growth slows, 112, 75 and 43 MB in successive days, but has not levelled off at 72 h, unlike the per-group retention measured on quinn ([Evidence](evidence.md) §3.6). The branch changed only the import and the export; the extension measures the relay on `main` again.

_The shadow extended on `main` (`9df4313a`), 72 h: SH1–SH3 hold at three switches; SH4 fails on the relay and the export._

- **SH1 holds:** both taps recorded three PCR steps, the encoder's own switches: forward 16,845 s on the second day, back 16,845 s and forward again 3.2 h apart on the fourth. Each reached the output 0.7–1.0 s after the input.
- **SH2 holds:** each supervisor recorded one start and no exit.
- **SH3 holds at each step.** Within 30 s of it the output's longest read gap was 231, 234 and 50 ms (the input's 492, 492 and 35); its continuity errors were the input's (15, 17 and 13); and the difference between the cumulative counts moved by −132, +360 and +48 packets across it, inside its range over the hour before (362, 444 and 368), at about 59,200, the export's 3.6 s behind the import. Over the run both taps counted 4.31 G packets and 81 continuity errors. The output's one read gap over 0.5 s, 552 ms, came in its first 20 s. The import logged nothing between start and stop; the export logged only its release clock at each step, one to eleven lines with nothing dropped, trimmed or missing.
- **SH4 fails on the relay and the export:** from the first hour to the end the relay grew 1.73× (257 to 444 MB), the export 1.55× (259 to 402 MB) and the import 1.33× (209 to 277 MB). No step moved any of them by more than 8 MB over the 20 min around it; the relay grew 67, 37 and 83 MB in successive days, as on the branch, without levelling off.

_The growth profiled, criteria fixed before running._ For 24 h on the same commit, two shadows join the group side by side ([`t67p-heap.sh`](scripts/t67p-heap.sh)): arm G on the default build, the allocator the growth was seen on, and arm J on a build with upstream's `jemalloc` feature, sampling one allocation per 64 KiB from startup (upstream's benchmark setting, without its cumulative counters) and dumping a heap profile every hour.

- **HP1, validity.** Arm G's relay grows by at least 15 % from the first hour to the end (the two 72 h runs grew 26 % and 45 % in their first day); otherwise the comparison is inconclusive.
- **HP2, the allocator.** If arm J's relay grows by less than half of arm G's growth over the same hours, the default allocator accounts for most of it.
- **HP3, attribution.** If arm J's sampled live heap grows by at least 70 % of its relay's resident growth, the growth is held allocations, and the stacks that grew most between the first and last profiles are reported; otherwise it is the allocator's own overhead. The same for the export.
- **HP4, the profile costs no media.** Each arm's taps count the same packets in and out (SH3's difference holding within twice arm G's range), so a profiled process that falls behind voids its arm.

## Conclusions

1. **Upstream's import now carries an unflagged encoder switch in both directions**, as a marked programme switch that `export ts --stitch --follow` follows. Neither the backward step that ended T34's imports nor the forward one that ended its exports ends anything on `main`.
2. **Past the catalog fix a switch costs what the encode's structure sets**: nothing of the old encode but the picture the switch truncated, and of the new one the wait until the export's first group. On T64's stimulus that is 160 ms. On T34's capture it is 1,600 ms, a GOP more than the first random-access picture, because the import announces the new instance only once its catalog's first snapshot goes out, 1.2 s after the republish; the export turns at once, is refused the first group as older than its max age, and starts at the newest.
3. **On #9069's branch the passthrough lane carries both switches with every byte.** The import splices in place of ending, and each export, a late one included, delivers the stimulus's bytes unchanged; on the parent the step back ends both. The live feed's own switches agree: on `main` the shadow carried three, one back and two forward, without a stall or a lost packet.
4. **Not covered:** a 1+1 ingest pair, whose two importers each mint an epoch at the switch ([T41](test-41-import-reanchor-coverage.md) § _A 1+1 ingest pair whose importers each mint an epoch_); the SRT gateway path; and the release builds, which predate the restart.

## Corrections

- **The capture's head was not the hold #7293 removes.** _Believed:_ the 1,560 ms head on T34's capture was the restarted import's catalog hold, because it was unchanged to the millisecond across a build that changed the tail. _True:_ the build that removes the hold leaves it unchanged; it is the stitched export starting at the new instance's second group, announced 1.2 s late because its catalog's first snapshot waits on every track (traced). _Rule:_ a cost unchanged across a build is attributed to nothing that build changed; it is attributed only by a build that removes the mechanism.
