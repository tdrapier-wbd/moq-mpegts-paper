# Test 50 — Deterministic TS legs (`moq export ts --sync`)

**State: run; passes criteria 1, 2, 4 and 5; 6 on the second build, and on its port to current
`main` past the first second; 7 is partial. Legs that joined apart write the same packets (arm A).
Under complementary loss the first build split the legs wherever a group had overrun the video lane
on another leg, at any multiplex rate; the second, which opens each group where the encoder's HRD
says the one before has arrived, gives no conflict and no overrun at 12, 16 and 24 Mb/s, and so does
its port once a restarted grid runs on past a stopped leg's resume. Criterion 3 cannot hold on a leg
that loses mid-group.**

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
- **The second build anchors at the HRD's buffering period.** A release assumes a full CPB. When a
  group's first picture carries an H.264 buffering period SEI, the CPB room it leaves
  (`CpbSize − BitRate × initial_cpb_removal_delay`) delays that picture by its lane time, never
  past the picture's deadline. The HRD received the group before by then (H.264 C.3), so a lane faster
  than BitRate has carried it on any leg that holds it. Other streams keep the first anchor.
- **Continuity counters restart at each group**, with the discontinuity indicator on the group's
  first packet. The PCR rides a PID of its own at each slot's first position. PAT and PMT have
  positions reserved in every slot and go out on the absolute 500 ms grid and in a leg's first
  slot, which is laid one slot before its first packet so the tables lead it; SI repeats on its
  own absolute grid in the positions no lane owns, revisions anchored to their snapshot's timestamp.
- **A unit is planned when it is read**, so a frame dropped late still advances its group; an open
  GOP's leading pictures, which a joiner cannot decode, are planned and decode-clocked like any
  other, then dropped.
- **The decode clock settles by count.** A video track whose SPS declares `max_num_reorder_frames`
  gives a frame its decode slot once more frames are held than can precede one in decode order and
  follow it in output: that depth N, or 2N+1 when the SPS allows field pictures. The DTS is the slot
  less N frame periods, capped at the PTS. A cut drops the frames still held from the cut group.
  Without a declared depth the export warns and keeps the timing rule, whose settling and growing
  delay depend on what the leg read before.
- **On the port, private PES and sections** go out whole, as current `main` carries them: each
  unit its own group, placed at its arrival on the program clock and sent a slot after it. A
  restarted grid runs on from its last slot unless its first packet sits more than a minute either
  side, and what it then holds behind that slot goes out as stuffing.
- **Two counters mark where legs can differ:** `overruns` (a group that starts behind the one
  before it on a lane too narrow to absorb it) and `late` (packets placed after their slot went
  out), in the export's stats and its release log line.

## Environment

- **Build:** branch `quest/m2/ts-hitless` (commits recorded in the results), release.
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
- **B at 16 and 24 Mb/s**, added after arm B's second run failed, to test whether a wider lane
  removes the failure. Arm B's four runs were repeated on the second build, and arm A once and
  arm B six times at 12 Mb/s on its port. The criteria are unchanged.

All arms: `--mux-rate 12000000 --delay 1s` unless stated.

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

First build: `quest/m2/ts-hitless` at e0f4d21c8, pushed as f92d2d5e0 after `just fix` rewrapped
three lines. Second build: e2cfc7e40, the first plus the HRD anchor. On each, arm B ran twice at
12 Mb/s, then once each at 16 and 24 Mb/s; arm A ran on the first build and the port, arm C on
the first only. Third build: the
second ported onto current `main` (59d39cd9c), with the minute's restart window and the late count
below. All release.

| Criterion | A, join skew | B, first build | B, second build | B, port | C, control | Verdict |
|---|---|---|---|---|---|---|
| 1 Identity | 470,752 positions equal, 0 conflicts over 59.1 s; positions only one leg carries fall in the joiner's first 1.3 s and its first slot's tables. Port: 475,105 equal, 0 conflicts over 59.6 s, one-leg positions in the first 1.2 s | A vs R 0 conflicts in every run. B vs R and A vs B: 0 in the first run; 3,821, 2,218 and 2,218 in the others, all video, within 0.6 s of B's resume | 0 conflicts for every pair in every run | 0 for every pair in all six runs | — | **pass** on the second build and the port |
| 2 Grader fails | — | — | — | — | no `--sync`: 373,098 conflicts; flipped byte: exactly 1 | pass |
| 3 Continuity | 0, 0 | R and the merge 0 in every run; A 1 in every run, B 1 in the first, each at its own loss | R and the merge 0 in every run; each stopped leg 1 at its own loss, but A in the second run 0 | R and the merge 0; each stopped leg 0 to 2, at its own loss | — | **fail** as written (B) |
| 4 PCR | max interval 25.07 ms; every PCR within 13 ticks | same, every leg and merge | same | same; no leg's PCR steps back | — | pass |
| 5 Constant rate | every slot at the rate | every slot at the rate | every slot at the rate | every slot at the rate | — | pass |
| 6 Merge | — | equals R in every run (first: 442,420 equal, 0 differ, 0 lost in both) | equals R in every run: 441,223 to 882,048 positions equal, 0 differ, 0 lost in both | equals R in three runs; in three, R lacks 16 to 76 teletext or AC-3 packets of the first 0.85 s that the merge holds; 0 lost in both | — | pass on the second build; on the port, **fail** as written in the first second |
| 7 Upstream tests | 1,483 `moq-mux` library tests pass (2 ignored); the five identity tests fail with `--sync` off; the reordering join and loss tests fail with the timing rule in place of the count, the stop test without the discard | | 1,486 pass; a mocked burst overruns once without the anchor | 1,598 pass; a grid restarted 3 s behind its last slot jumps back with a 2 s window | | partial |

**The decode clock no longer diverges.** In every arm-B run each picture carries the same DTS on
every leg, and A and R, whose losses fell apart, agree in every packet. Both halves of the fix are
needed. A build that counted without dropping the frames held at a cut gave 1,064 (A vs R) and
10,790 (B vs R) conflicts around each leg's stall in one run, and its merge differed from R in 1,856
packets: the frames a cut leaves in the clock took slots from a set missing their group's tail.

**On the first build, what fails is a group that began behind the one before it.** In the three
failing runs every conflict lies in the group leg B resumed into. R and A hold the group before it,
so they found the video lane still busy with it and opened 14 to 19 packets after the anchor. B had
lost that group and opened at the anchor. Each frame's payload and DTS are the same on all legs;
the positions realign at the first frame released after the lane caught up. These are the
`overruns` the export counts and logs: about 12 a minute at 12 Mb/s and 8 at 16 or 24, of some 50
groups, at the same instants on every leg that holds the previous group. A leg that lacks a group
cannot know how far it spilled, so a loss or join whose first group overran elsewhere diverges
there. Arm A and arm B's first run passed because theirs had not. Leg B's stop falls near the same
group in every run, and that group overran in the last three.

**No multiplex rate removes it.** Video takes what the fixed lanes leave, at most its Rx. At 12 Mb/s
that is 9.93 Mb/s, full in 79% of slots. At 16 and 24 Mb/s the lane stops at the stream's Rx,
10.59 Mb/s, against 9.0 Mb/s of video, and both runs gave the same 2,218 conflicts. This clip's
four-frame mini-GOPs peak near 13 Mb/s. On such content the quest's re-anchoring "with headroom"
has no headroom a conformant lane can give.

**Anchoring at the HRD's buffering period removes it.** Every group on this source opens on a
picture with a buffering period SEI (102 of 102 random access points over two minutes; NAL HRD,
CBR, BitRate and CpbSize 8,797,568, a 1.0 s buffer; `initial_cpb_removal_delay` 0.51 to 0.92 s).
The headroom that matters is over BitRate, not over the content's peaks, which the CPB absorbs. On
the second build no leg counted an overrun or a late unit in any of the four runs, against the first
build's 12 overruns a minute: the later anchor cost no deadline. A mocked source whose group ends in
a burst overruns once without the anchor and not with it.

**On current `main` a stopped leg resumes behind its grid.** Its subscription resumes at the group it
was in, as far behind the slots its grid laid during the stop as the stop lasted. A grid that ran on
only within 2 s took that for a new timeline: in three of six runs on the port before the wider
window, leg A's PCR stepped back 2.2 to 2.9 s and it laid those slots again. Within a minute the
grid runs on, and no PCR stepped back in six runs; the content behind it is dropped and counted
`late`, 4,925 packets on leg A or 5,119 on leg B in five of the twelve stops.

**Legs that start together do not hold the same first units.** On current `main` each private PES
is its own group, so a leg that subscribes a few milliseconds later lacks the first teletext or
AC-3 units. In three runs R lacked 16 to 76 packets of the first 0.85 s that leg A or B held, and
the merge differed from R only there. Criterion 6 assumed a reference holding all the legs hold.

**Stopped legs finish behind, more often with the discard.** After its 3 s stop a leg's release
clock may re-anchor, as for a timeline jump: the frames after the skip look more than a delay ahead
of everything queued. On the first build all eight stopped legs finished 0.58 to 1.93 s behind R
and leg A always re-anchored; without the discard one of four did and leg A never re-anchored. The
second build was not measured for it. Grading by PCR slot keeps this out of criteria 1 to 6, but a
receiver merging the legs would have to buffer that skew. The mechanism is not established.

**Continuity on a losing leg.** TSDuck accepts each group's flagged restart, so a loss that ends at a
group boundary leaves no error; each error here is a loss inside a group, which the quest keeps
detectable. Criterion 3 as written cannot hold on a leg that loses mid-group.

**Criterion 7's premise does not hold.** On `main`, the ignored `two_legs_render_a_skip_the_same_way`
passes with `--ignored` at both lags: the PES header byte difference the quest describes no longer
reproduces. The evidence that the identity tests fail without the fix is the run with `--sync` off.
For the decode clock, the mocked source now reorders (a b-pyramid of depth 2) and can evict a
leg's group as the relay does a slow subscriber's: with the timing rule in place of the count, its
join and loss tests fail, and without the discard, so does its test of legs stopped in turn.

## Conclusions

- Under `--sync`, two legs of a real broadcast mux (H.264, MP2, AC-3, teletext, SCTE-35, SI) that
  joined 20 s apart write the same packets, continuity counters included, from their first common
  slot, at a constant rate and with a conformant PCR.
- Settled by count at the depth the SPS declares, a frame's DTS no longer depends on what the leg
  read before it.
- Anchored at each group's first release, legs split after a loss wherever the group before
  overran on another leg, at any rate on this clip. Anchored where the encoder's HRD says that
  group has arrived, legs that lose complementary content write the same packets and their merge
  is a clean leg, at 12, 16 and 24 Mb/s. That needs a NAL HRD and a buffering period SEI on each
  group's first picture, read for H.264 only; other streams keep the first anchor and its
  overruns. Whether it replaces the quest's placement is the maintainer's choice.
- A stopped leg resumes as far behind its grid as it stopped; the grid must run on through that
  restart, or the leg's PCR steps back.
- The mocked-time tests now reorder, and one fills its lane with a burst at a group's end.

## Corrections

- **Arm B's first divergence was blamed on the content.** We believed this field-coded source
  reorders past the depth its SPS declares, so a DTS floor of that depth times the frame period
  could not hold. It holds: settled by count at that floor, every picture gets the encoder's own DTS
  (slot less 10,800 ticks) on every leg. The divergence came from the timing rule, whose settling
  and growing delay depend on what the leg read, and from the frames held at a cut. Rule: check a
  stream's declared parameters against its own timestamps before blaming them.
