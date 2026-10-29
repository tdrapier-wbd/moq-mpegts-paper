# Test 67 — The import's own restart at an unflagged encoder switch

**State: run, three times per stimulus and a control; every criterion holds.** At an unflagged
encoder switch, back or forward, the import republishes itself and neither export ends; a switch
costs 1,360 ms of programme on T64's stimulus and 1,600 ms on T34's capture, against 2,400–2,800 ms
behind a supervisor. Rig: [T41](test-41-import-reanchor-coverage.md)'s
[`t41-rewind-supervisor.sh`](scripts/t41-rewind-supervisor.sh), graded by
[`t41-rewind-grade.py`](scripts/t41-rewind-grade.py); stimuli from
[T34](test-34-real-encoder-severity.md) and [T64](test-64-synthetic-encoder-switch.md).

## Objective

Upstream's `main` now republishes a TS import itself when its clock steps onto another timeline:
the PCR and every stream stepping back, flagged or not, or more than 10 s forward unflagged. The
broadcast ends there and the rest of the input publishes under a new epoch, which
`export ts --stitch --follow` carries on into. Measure what that costs a subscriber at the switch
T34 caught on the live feed, and at T64's synthetic switch in both directions, against what a
supervisor restarting the import cost on the build before it.

**Falsifies:** [evidence](evidence.md) §3.13's account of the current build, that a backward step
ends the import and a supervisor's republish costs 2.8–3.8 s per step; and T34's forward step ending
every export.

## Environment

The laptop, loopback: one relay, one import, two exports in one invocation, `moq-lite-07-wip`.
`main` `548a41ec3` (thin LTO, functional), which carries the restart; control `main` `66af72315`,
T34's and T64's build, on which the step back ends the import and the forward step ends the exports.

## Procedure

`t41-rewind-supervisor.sh <bin> <out> <stimulus> pipe <secs>` with `EXPORT_ARGS=--stitch`: the
source played in real time through `tsp -P regulate` into the import, two exports at
`--delay 1s --follow 30s --stitch`. The supervisor stays as an instrument: on `main` it should
record one start and one exit, after the source has ended.

| Stimulus | Built by | Switch | `VPID` | Played |
|---|---|---|---|---|
| T34's capture | the ring's five files, lifted 30,000 s (`p0j-lift.py`) | back 16,844.35–16,844.65 s, 71.2 s in | 111 | 95 s |
| T64 back | `t64-switch.py <out> back` | back 16,844.70–16,845.00 s, 30 s in | 257 | 55 s |
| T64 forward | `t64-switch.py <out> forward` | forward 16,844.00–16,844.30 s, 30 s in | 257 | 55 s |

Before the runs, `p0j-splice.py` on each stimulus: the real switch at packet 1,182,916 with T34's
steps, and each synthetic one T64's class. Three runs per stimulus on `main`, and one run of T64 back
on `66af72315`. Each run graded with `t41-rewind-grade.py --pts`, and again on decode times, which
T34's table uses.

## Pass criteria, fixed before running

0. **Control.** On `66af72315` the T64 back run reproduces T64: the import exits once at the
   switch with the live error, and the programme lost on presentation times is within 200 ms of
   T64's 2,400–2,480 ms. Otherwise `main` is compared with today's control, not with T64's table.
1. **Validity.** A run counts if the source plays in real time across the switch (no gap over
   0.5 s in its tap within 5 s of it) and both exports exit 0 after the source has ended; otherwise
   it is reported, not graded.
2. **H1, the restart engages.** On `main` no import exits at a switch, in either direction: the
   supervisor records one start, and its one exit follows the source's end. Fails if any does.
3. **H2, back, it costs no more than a supervisor's restart.** Per export, the programme lost on
   presentation times is at most 200 ms above the supervisor's on `66af72315`: T64's 2,400–2,480 ms
   on the synthetic switch, and T34's 2,800 ms (decode times) on the real one, compared on decode
   times. Lower is reported with its parts (the old encode's held tail, the new encode's head).
4. **H3, forward, the exports carry on.** Neither export ends at the forward step, and the
   programme lost is reported as found. Fails if either ends there.
5. **Reported, not graded:** the longest arrival gap, the first post-switch picture's delay beyond
   the steady latency, and whether the two exports are byte-identical.

## Results

**Every run counts.** The source's longest pause within 5 s of the switch was 85–148 ms, and every
export exited 0 after the source ended. The stimuli classified as T34 and T64 recorded them: the
capture's splice at packet 1,182,916 with T34's steps, and the synthetic switch stepping
16,844.70–16,845.00 s back or 16,844.00–16,844.30 s forward, unflagged.

**The control reproduces T64 (criterion 0).** On `66af72315` the import exited once at the switch,
*frame timestamp … is below the previous group's start*, and its successor started 32 ms later. The
two exports lost 2,480 and 2,400 ms on presentation times, inside T64's range.

**The restart engages, both ways (H1 holds).** On `main` every import logged *the source's clock
stepped; republishing*, with the step, *went back* or *jumped forward*, and *without a
discontinuity_indicator*, and published a new epoch 0.3–1.5 ms later. The supervisor recorded one start
in each of the nine runs, so no import exited.

**It costs about half what a supervisor's restart did (H2 and H3 hold).** Each figure holds on both
exports of every run. The real switch is on decode times, as T34's table is:

| Switch | Build | Runs | Programme lost (ms) | Old encode's tail (ms) | New encode's head (ms) | Longest arrival gap (ms) | First post-switch picture beyond the latency (ms) | Latency before the switch (ms) |
|---|---|---:|---|---|---|---|---|---|
| T64 back, presentation times | `66af72315` (control) | 1 | 2,400–2,480 | 1,120–1,200 | 1,280 | 2,373–2,395 | 1,304–1,305 | 1,136–1,137 |
| T64 back, presentation times | `548a41ec3` | 3 | 1,360 | 80 | 1,280 | 1,397–1,404 | 1,308–1,312 | 1,133–1,135 |
| T64 forward, presentation times | `548a41ec3` | 3 | 1,360 | 80 | 1,280 | 1,400–1,408 | — | 1,145–1,149 |
| T34 back, decode times | `66af72315` (T34) | 3 | 2,800 | 1,240 | 1,560 | 2,778–2,785 | 1,564–1,572 | 1,203–1,212 |
| T34 back, decode times | `548a41ec3` | 3 | 1,600 | 40 | 1,560 | 1,516–1,541 | 1,474–1,503 | 1,215–1,228 |

The whole saving is the old encode's tail. Behind a supervisor the old broadcast ended with about
the export's latency of it held and unreleased; now the export plays it to the switch. What remains
of the tail is the picture the switch cut mid-PES, the source's own loss. The new encode's head is
unchanged to the millisecond, so it is the restarted import's catalog hold, as T34 found. On
presentation times the capture costs 1,960 ms, 320 + 1,640: its truncated last picture is presented
400 ms after its decode time, so it counts in that clock's tail.

**The exports stayed byte-identical across T64's switch in all six runs**, back and forward, where
the control's parted at the stitched break, its flag 80 packets apart on the two legs. On the
capture they were 96.5–98.8 % identical, parting on the video, the MP2 and the teletext, from the
run's first seconds in two runs and after the switch in the third.

**The grader's presentation-time mode mis-split the capture**, taking a 280 ms reordering step four
pictures in for the switch. [`t41-rewind-grade.py`](scripts/t41-rewind-grade.py) `--pts` now finds
the cut and each break in decode order and measures on presentation times; it reproduces every
synthetic figure and gives the capture's 1,960 ms.

## Conclusions

1. **Upstream's import now carries an unflagged encoder switch in both directions**, as a marked
   programme switch that `export ts --stitch --follow` follows. Neither the backward step that ended
   T34's imports nor the forward one that ended its exports ends anything on `main`.
2. **A switch costs 1.4–1.6 s of programme**: the catalog hold of the restarted import, which the
   `restart-catalog` quest would remove. Nothing of the old encode is lost but the picture the switch
   itself truncated.
3. **Not covered:** a 1+1 ingest pair, whose two importers each mint an epoch at the switch
   ([T41](test-41-import-reanchor-coverage.md) § *A 1+1 ingest pair whose importers each mint an
   epoch*); the SRT gateway path; and the release builds, which predate the restart.
