# Test 50 — Deterministic TS legs (`moq export ts --sync`)

**State: run; fails. Identity holds under join skew (arm A) and the grader fails when it should
(arm C), but complementary loss on broadcast content diverges for 22 s (arm B): the decode clock
the DTS comes from depends on the leg's history.**

## Objective

ST 2022-7 merges two legs packet by packet, so it needs two exporters of one broadcast to write the
same packets, continuity counters included. Today they do not: the export's slots follow media time,
but where a packet lands inside a slot depends on what the leg released before it, its counters
number what the process sent, and its tables and audio PES boundaries follow the leg's own history.
[T12](test-12-dual-path-handoff.md) found byte identity only on single-track content.

This grades our implementation of upstream's `quest/m2/ts-hitless.md`: under `--sync`, legs that
joined at different times, behind different delivery skews and losing different content emit
identical packets for every slot both release, from their first common slot; a slot whose content
one leg lacks keeps its position there as stuffing.

## Design under test

- **Every PID owns a fixed lane** of positions on the multiplex rate's packet grid, a function of
  the slot alone and of what every leg shares: the rate, and the catalog's codecs. Audio lanes carry
  one maximum-size frame of the codec per frame period; teletext a nine-packet PES per frame,
  other private PES two packets per slot, sections one; video takes the remainder, at most its Rx. A rate too low for that is refused.
- **Each MoQ group re-anchors** at its lane's first position from the instant its first unit may
  go out (its decode time less its drain and the send-ahead), and its units follow one another in
  its lane, none before its own release. Nothing outside the group moves a packet, so a leg that
  lacks a group, or joined after it, lays the next one where every other leg does.
- **Continuity counters restart at each group**, with the discontinuity indicator on the group's
  first packet. The PCR rides a PID of its own at each slot's first position. PAT and PMT have
  positions reserved in every slot and go out on the absolute 500 ms grid and in a leg's first
  slot, which is laid one slot before its first packet so the tables lead it; SI repeats on its
  own absolute grid in the positions no lane owns, revisions anchored to their snapshot's timestamp.
- **A unit is planned when it is read**, so a frame dropped late still advances its group; an open
  GOP's leading pictures, which a joiner cannot decode, are planned and decode-clocked like any
  other, then dropped.
- **Two counters mark where legs can differ:** `overruns` (a group that starts behind the one
  before it on a lane too narrow to absorb it) and `late` (packets placed after their slot went
  out), in the export's stats and its release log line.

## Environment

- **Build:** branch `quest/m2/ts-hitless` (commit recorded in the results), release.
- **Host:** the EC2 tertiary, everything on loopback: one relay, one publisher (`import ts`) reading
  the CNN clip paced on its PCR, two or three `export ts` subscribers.
- **Source:** the CNN clip (9.95 Mb/s; H.264, MP2, AC-3, teletext, three SCTE-35 PIDs, DVB SI).
- **Rig and grader:** [`t50-sync-legs.sh`](scripts/t50-sync-legs.sh) runs the arms;
  [`ts-sync-identity.py`](scripts/ts-sync-identity.py) aligns the legs on their PCR slots and compares
  them packet by packet, continuity counters included, and writes the position-wise merge.

## Arms

- **A, join skew.** Leg B joins 20 s after leg A (mid-GOP); 60 s of common capture.
- **B, complementary loss.** Three legs start together; leg A's process is stopped for 3 s at +20 s
  and leg B's for 3 s at +35 s, so each misses content the other has; leg R is never stopped.
- **C, known-bad control.** Arm A without `--sync`, and arm A's leg B with one byte flipped.

All arms: `--mux-rate 12000000 --delay 1s`.

## Pass criteria (fixed before the first run)

1. **Identity.** In arms A and B, for every pair of legs, from their first common slot to the end of
   the shorter capture, no position carries different non-null packets in the two. Positions where exactly one leg
   carries a null are content it lacks; in arm A they occur only before the joiner's first group on
   each PID has started (at most one GOP plus the delay after its first slot).
2. **The grader can fail.** In arm C, the legs without `--sync` report differing packets, and the
   one-byte corruption is reported as exactly one differing packet.
3. **Continuity.** TSDuck `continuity` reports no error on either leg of arms A and B, nor on arm
   B's merge.
4. **PCR.** On each leg, every PCR interval is at most 40 ms and `pcrverify --absolute
   --jitter-max 13` at the multiplex rate reports no PCR out of tolerance.
5. **Constant rate.** Each leg carries exactly the multiplex rate's packets per slot.
6. **Merge.** In arm B, the position-wise merge of legs A and B is byte-identical to leg R over
   their common span: neither leg's loss survives the merge.
7. **Upstream's own tests.** The quest's mocked-time tests pass, and the previously ignored
   `two_legs_render_a_skip_the_same_way` fails on `main` and passes on the branch.

## Results

Build: `quest/m2/ts-hitless` at 7e7ef8eb4, release; the rig grades `pcrverify` with `--bitrate` at
the multiplex rate. A first arm A ran on 9651fa412, before the open-GOP fix below.

| Criterion | A, join skew | B, complementary loss | C, control | Verdict |
|---|---|---|---|---|
| 1 Identity | 470,752 positions equal, 0 conflicts, 0 alone over 59.1 s | A vs R 0 conflicts; B vs R and A vs B 103,158 conflicts, all video, 33.6–55.4 s | — | **fail** (B) |
| 2 Grader fails | — | — | no `--sync`: 373,098 conflicts; flipped byte: exactly 1 | pass |
| 3 Continuity | 0, 0 | A 0, R 0; B 1 (14 packets missing at its own stall); merge 83 | — | **fail** (B) |
| 4 PCR | max interval 25.07 ms; every PCR within 13 ticks | same, all three legs | — | pass |
| 5 Constant rate | every slot at the rate | every slot at the rate | — | pass |
| 6 Merge | — | 436,090 equal, 6,330 differ, 0 lost in both | — | **fail** |
| 7 Upstream tests | 515 TS unit tests pass (2 ignored); the five identity tests fail with `--sync` off | | | partial |

**Arm A before the open-GOP fix** had 5,282 conflicts, all video and all in the joiner's first
0.95 s. A joiner dropped its first open GOP's leading pictures before the decode clock, so that
group's DTS and positions differed from the other leg's. Under `--sync` they are now planned and
decode-clocked, then dropped (Design). The mocked-time tests could not see this: their source has
closed, unreordered GOPs.

**Arm B's divergence is the decode clock.** For the same PTS, leg B's DTS is one field (1,800
ticks) earlier than R's on 517 pictures, from 25,661.16 s to 25,683.08 s of media time. Leg A, whose
stall fell at 20 s, matches R on every picture. The clock's reorder delay is a running maximum that
never shrinks, above a floor taken from the SPS. That floor is `max_num_reorder_frames` (3) times the
frame period (40 ms). Leg B's stall cut a group, losing one or two fields, and the 15 field pictures
still inside the clock's lookahead were given slots from a set missing them. That raised B's delay by
a field. R's delay rose by the same field at 25,683 s on its own content, which is when the legs
reconverge. So this field-coded source reorders past the floor, and above it a leg's DTS depends on
what it has seen: a skip that truncates the lookahead, or a join after the deepest reorder so far.
A shifted DTS moves the release instant, so every later group lands elsewhere. The mocked-time source
never reorders, so no unit test reaches this.

Two counts that did not cause the failure:
- **Overruns.** Every leg logged 10 to 16 a minute. The video lane is 9.9 Mb/s against 9.0 Mb/s of
  video, and about three slots in four are full. Arm A held identity through them, and arm B's A
  and R legs did too.
- **Leg B's continuity gap.** Its single error falls at its stall. TSDuck accepts every group's
  flagged restart (legs A and R report none), so this one is inside a group. The quest keeps a loss
  inside a group detectable, so criterion 3 as written cannot hold on a leg that loses mid-group.

**Criterion 7's premise does not hold.** On `main`, the ignored `two_legs_render_a_skip_the_same_way`
passes with `--ignored` at both lags: the PES header byte difference the quest describes no longer
reproduces. The evidence that the new tests fail without the fix is the run with `--sync` off.

## Conclusions

- Under `--sync`, two legs of a real broadcast mux (H.264, MP2, AC-3, teletext, SCTE-35, SI) that
  joined 20 s apart write the same packets, continuity counters included, from their first common
  slot, at a constant rate and with a conformant PCR.
- Complementary loss is not yet safe. The fix needs two things. Frames still unsettled in the decode
  clock when a skip cuts their group must be discarded, not decode-clocked from an incomplete set.
  And the reorder delay must be one every leg derives from the catalog and SPS alone, which
  `max_num_reorder_frames` times the frame period is not on field-coded content. Its test needs a
  mocked-time source that reorders, with a field-coded stretch deeper than its declared depth.
- The quest's mocked-time tests pass and fail without the fix, but they cannot stand in for this
  test. Their source neither reorders nor opens a GOP, and each defect this test found needs one
  of the two.
