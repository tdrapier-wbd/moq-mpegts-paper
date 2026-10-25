# T56 — Media-aware failover: what a decoder sees, and how small it can be made

**State: run on `main` at `66af72315` and graded ([`t56-failover.sh`](scripts/t56-failover.sh),
[`t56-grade.py`](scripts/t56-grade.py)).** C4 passes; C0, C2, C3, C5 and one-source C6 fail. On the
demultiplexed lane every leg event is a switch, including a standby's start, and every switch costs
at least the export's delay, so no idle timeout brings a hard kill under a second. Selection at the
receiver, between exports each on its own leg, avoided every switch in the relay.

## Objective

On the media-aware lane, 1+1 is a switch: the demultiplexing export follows a second importer as a
marked programme switch ([Architecture](../docs/architecture.md) §5). The two legs are not started
together: either restarts after a failure or for maintenance while the other serves, so every cell
starts them apart, and a leg's arrival is an event graded like a failure. [T6](test-6-relay-resilience.md)
measured the source time each switch loses, on one build at one idle timeout: a hard kill costs
5.4–9.0 s and a clean exit under 2 s, and a relay lost under one importer skips 7 s unflagged. What a
downstream decoder shows is a different quantity, and the lane's acceptability turns on it: the
operational threshold this test grades against is that a failover under a second is tolerable and
one of several seconds is not ([Evidence](../docs/evidence.md) §5 row 8). The test absorbs T6's
relay-loss cell on the current build (P1-ab).

**Questions.**

1. What does each failover class cost: the output's stall, the programme lost, and the time a
   decoder shows no new picture?
2. How does a hard kill's cost fall with the QUIC idle timeout, and at what timeout is it under a
   second?
3. At that timeout, what uplink outage of the serving importer causes a switch, and what does it
   cost?
4. With the two importers on separately encoded sources, which is what protects the input, what does
   a switch cost beyond the one-source case?
5. Is a relay lost under one importer seamless on the current build?
6. Does a standby leg's start, or its restart after a failure, cost the serving output anything?
7. A receiver that selects between two exports, each on its own leg, needs no switch in the relay:
   what does its input select cost a decoder, on one source and on two?

**Hypotheses.**

- **H1.** A failover costs detection, then re-subscription, then the wait for the standby's next
  group. A clean exit has no detection term and costs under a second in every measure.
- **H2.** A hard kill's cost tracks the idle timeout, so it is under a second only at a timeout under
  a second.
- **H3.** An uplink outage longer than the idle timeout costs two switches: away, and back when the
  importer reconnects under a new instance.
- **H4.** Separate sources add their offset, lost or repeated, to a switch, which is marked as for
  one source.
- **H5.** A relay lost under one importer now resumes at the first frame the subscription lacked.
- **H6.** Each importer is its own publisher instance and the relay serves the newest, so a standby's
  start is a switch onto it, costing what a clean exit's switch costs.
- **H7.** An input select between two exports of one source costs at most a GOP of decoder hole and
  no programme; between separate encodes, their offset as well.

## Environment

| Component | Build |
|---|---|
| `moq`, `moq-relay` | `main` at `66af72315` (moq 0.14.2, moq-relay 0.17.2), recorded with each run |
| Host | the laptop, loopback, for every cell but `outage`, which needs Linux and `iptables` (the secondary, loopback, its standing units untouched); no other timing work on the host |
| One source | the drills' contribution clip (1080i H.264, 9.95 Mb/s CBR) played live to a file that every importer follows from its own start (T6's `FEED=file`) |
| Two sources | the clip, and a separate encode of its first 200 s (720p H.264, 2 s closed GOP, 9 Mb/s CBR, other PIDs, a PTS origin 37 s later), each played live from the same instant, so that pictures align and packets do not |
| Export | `export ts --stitch --follow 10s --delay 2s`, two per run, each under a supervisor that restarts it when it exits; the passthrough lane (`--passthrough` both ends, no `--stitch`) as the control |
| Version | the default (moq-lite 06 is negotiated) |

## Procedure

[`t56-failover.sh`](scripts/t56-failover.sh) starts every leg apart: importer A at 0 s, export 1 at
2 s, export 2 at 7 s, importer B at 8 s. Each export's output is recorded from its pipe with arrival
times ([`t56-stamp.py`](scripts/t56-stamp.py)); event times go to the run's `events.txt`, and the
importer serving at a fault is the one whose log shows more groups served over the 2 s before it.
Three runs per cell, 75 s each, the fault at 30 s and the restart 15 s later, past detection at a
6 s idle timeout.

| Cell | Event | Idle timeout (keep-alive a third of it) |
|---|---|---|
| `kill` | importer B's start; SIGKILL of the serving importer; its restart | 1, 2, 4, 6 s |
| `term` | the same with SIGTERM | 6 s |
| `outage` | the serving importer's uplink dropped for half, once and twice the idle timeout | C2's timeout, or 1 s if none passes |
| `sources` | `kill` and `term` with importer B on the separate encode | 6 s and C2's timeout |
| `select` | none: one importer, or with `SRC2` one per source on a broadcast each; the grader splices export 1 into export 2 and back every 8 s, at packet boundaries by arrival | 6 s |
| `relay` | T6's arm 3 ([`t6-relay-kill.sh`](scripts/t6-relay-kill.sh) `MODE=diamond`): one importer through two middle relays, the serving middle relay SIGKILLed, graded by [`t6-switch-grade.py`](scripts/t6-switch-grade.py) | 6 s; `--delay` 2 s and 10 s |
| `passthrough` | `kill` and `term` on the passthrough lane | 6 s and C2's timeout |

**Measures per event** ([`t56-grade.py`](scripts/t56-grade.py)). Each capture is decoded by FFmpeg
following PMT changes, and afresh wherever the PAT moves the programme to another PMT PID, which a
receiver re-acquires and FFmpeg does not follow; each picture is matched to its frame in the clip's reference decode (16×9
grey thumbnails) and placed at its last packet's arrival. A picture is *good* when its 64×36
thumbnail is within three times the local median distance of that frame, so a concealed or corrupt
picture is not. The *stall* is the longest gap between video packet arrivals; the *decoder hole*
the longest gap between good pictures starting from half a second before the event (up to half a
second before the next, for select cuts), beside the same before the event; the *programme lost*
(positive) or *repeated* (negative) the step in source frame less output picture across the event;
the *latency step* the change in arrival less source time. Audio's longest gap is reported beside
them. Each switch is *marked* if it carries a new PMT version and a discontinuity indicator on every
PID, and each export restart is counted.

## Pass criteria, fixed before running

1. **Void** unless the source file shows no continuity error, every event time is in `events.txt`,
   and every export's capture covers its run to within 3 s of its end.
2. **C0, a leg's arrival is free:** a standby importer's start, and the failed importer's restart,
   cost the serving export no switch, or one with a decoder hole under 1 s and no programme lost, in
   all three runs. This is the requirement that legs need not start together.
3. **C1, the costs**, measured, no pass mark: per cell and event, the median and worst of three runs
   of the stall, the programme lost and the decoder hole, whether every switch is marked, and the
   export restarts.
4. **C2, sub-second:** a hard kill passes at an idle timeout if its decoder hole and its programme
   lost are under 1 s in all three runs. The result is the largest timeout tested that passes, or
   that none does.
5. **C3, the timeout's price:** at C2's timeout, an outage shorter than it causes no switch in any
   run; a longer one is graded as C1.
6. **C4, separate sources:** every switch is marked and every export survives, and each decoder hole
   is within one GOP of the same event's on one source.
7. **C5, a relay loss is seamless** (P1-ab): at both delays, no programme lost, no repeated
   timestamp, no flag and no continuity error.
8. **C6, input select:** at every splice of every `select` run, a decoder hole under 1 s and no
   programme lost or repeated beyond one frame on one source; on two, the same hole, with the
   programme step reported.

## Limits, fixed in advance

- FFmpeg is the decoder, not an IRD; the hardware window (B-6) can repeat `kill` and `sources` at
  C2's timeout against a bank of IRDs.
- Loopback: detection here is the idle timeout alone. On a real path, an idle timeout under a second
  meets loss and jitter that loopback does not have, which C3 prices only in part.
- The select cell's splice is a model of a receiver's input select, at packet boundaries on the
  exports' recorded arrivals; a real IRD or switch may resynchronise differently.
- The laptop's timings carry its scheduler; the secondary repeats the cells whose results turn on
  less than half a second.

## Results

Every run passed the void checks. Three runs per cell, two exports each: each range is over the six
exports, in seconds. *Bad* counts the pictures after the event that fail the match. Only `outage`
ran on the secondary: no other verdict turned on less than half a second of timing. The one that
came closest, one-source C6, is made of corrupt pictures, not of the clock.

**One source, demultiplexed lane, `--delay 2s`.**

| Cell (idle timeout) | Event | Stall | Decoder hole | Programme lost | Bad |
|---|---|---|---|---|---|
| `kill` (6 s) | B's start, onto it | 2.09–2.10 | 3.28–3.29 | 2.48 | 17–18 |
| | SIGKILL of B, serving | 8.17–9.34 | 8.39–9.51 | 8.28–9.32 | 0–2 |
| | B's restart | 1.67–1.69 | 2.25–2.48 | 2.40 | 0–1 |
| `term` (6 s) | SIGTERM of B | 1.33–1.54 | 1.59–2.47 | 1.44–2.52 | 0–21 |
| `kill` (4 s) | SIGKILL | 5.72–6.24 | 5.90–6.41 | 5.76 | 1 |
| `kill` (2 s) | SIGKILL | 3.31–3.32 | 3.50–3.52 | 3.32 | 0 |
| `kill` (1 s) | SIGKILL | 1.57–1.65 | 2.94–3.02 | 2.48 | 6–9 |
| `kill` (6 s), `--delay 10s` | B's start | 9.78–9.79 | 10.00–10.02 | 10.12 | 0 |
| | SIGKILL | 19.26–19.34 | 19.86–19.94 | 19.24–19.36 | 14 |

A start or restart cost the same at every idle timeout and in `term` (hole 1.75–3.30 s, programme
2.32–2.52 s). The 10 s delay's runs were 85 s long, with B's start at 20 s and the kill at 40 s, so
that each event follows a full buffer. There the restart came inside the kill's stall and had no
switch of its own. The programme lost at a switch is the delay plus 0.1–0.5 s. At the 2 s delay a
hard kill's is the larger of that and 1.24 × the idle timeout + 0.84 s; at 10 s it was 19.3 s, near
the two added (10.1 + 8.3).

Every switch was marked except where an export had ended. **An export ended at a hard kill** in 3 of
13 runs (idle timeout 4 s: 1 of 3; 6 s: 2 of 4, the smoke run included). Each logged *MPEG-TS output
missed a decode deadline on PID 111 … raise the multiplex rate* as the relay evicted the serving
group, then exited. Its supervisor's restart began again at PMT version 0 with no flag, a further
1.0 s lost. That did not happen at 1 or 2 s, on SIGTERM, on two sources or at an outage.

**Two sources (`sources`, 6 s).** Every switch moved the PMT to the other source's PID, with the
PAT's and PMT's versions bumped and every PID flagged. No export ended. B's start and restart are
switches onto the separate encode, and SIGKILL and SIGTERM are switches back.

| Event | Stall | Decoder hole | Programme lost | Latency step | Bad |
|---|---|---|---|---|---|
| B's start | 1.24–1.26 | 1.47–1.49 | 0.48 | +0.57 | 0 |
| SIGKILL of B | 7.97–8.06 | 8.10–8.18 | 8.68–8.76 | −0.56 to −0.60 | 3 |
| SIGTERM of B | 1.33–1.46 | 1.41–1.54 | 2.08–2.16 | −0.67 to −0.71 | 20–21 |
| B's restart | 1.63–1.87 | 1.90–2.07 | 1.00–1.28 | +0.59 to +0.67 | 0–1 |

**Outage (secondary, one source, 1 s idle timeout).** At 0.5 s: no switch in any run (hole 0.17 s,
nothing lost). At 1 s: one switch away (hole 3.47–3.83 s, 2.48 s lost, 19 bad). At 2 s: one switch
away (3.31–3.43 s, 3.00 s lost). The reconnected importer kept its instance, so the output stayed on
the standby, with no second switch.

**Relay loss (`relay`).** Every export survived, with no continuity error and no repeated
timestamp. At the 2 s delay the serving relay's loss was a marked switch losing 7.8 s, with a 5–6 s
stall. The relay's restart caused a second marked switch, losing 0.58–1.58 s. At the 10 s delay it
was one marked switch losing 13.6–18.2 s.

**Passthrough lane.** The export stays on the importer it started on, so B's start and A's restart
cost nothing (hole 0.21–0.47 s, nothing lost, no switch). When the serving importer A goes, every
export exits *unroutable*, and its supervisor's restart lands on B unmarked, with 11–12 continuity
errors:

| Event (idle timeout) | Stall | Decoder hole | Programme lost |
|---|---|---|---|
| SIGKILL of A (6 s) | 8.67–8.90 | 8.88–9.12 | 8.64–8.88 |
| SIGTERM of A (6 s) | 2.70–2.98 | 2.87–3.12 | 2.72–2.96 |
| SIGKILL of A (1 s) | 2.42–2.44 | 2.57–2.59 | 2.40–2.48 |

**Select (`select`, 6 s; 18 cuts per cell).** Each export's own start cost 0.20–0.28 s of hole.

| Sources | Decoder hole | Programme | Latency step | Bad |
|---|---|---|---|---|
| One | 0.13–0.51 at 15 cuts; 1.25, 1.35, 1.57 at three | 0 (≤ 0.08) | ±0.08 | 0 at 15 cuts; 28–36 at the three |
| Two | 0.42–0.88 | 1.12–1.40 lost onto the clip, 0–0.12 repeated onto the encode | ±0.64–0.71 | 0–1 |

The three long holes were all cuts onto export 2, with no gap in packets (stall 0.05 s): consistent
with a cut inside a picture, concealed until the next random-access point, though this was not
checked cut by cut. Nothing marks a cut, so each run carries about 61 continuity errors at its cuts.

## Grading

- **C0 fails on the demultiplexed lane**: a leg's start or restart is a switch costing 1.75–3.30 s of
  hole and 2.3–2.5 s of programme on one source (1.47–2.07 s and 0.48–1.28 s on two). It **holds on
  the passthrough lane**.
- **C2 fails at every timeout**, on both lanes: at 1 s a hard kill still costs 2.94–3.02 s of hole
  (passthrough 2.57–2.59 s).
- **C3**, run at 1 s since no timeout passed C2: a 0.5 s outage caused no switch in any run; the
  longer ones are graded above.
- **C4 passes**: every switch was marked, every export survived, and no hole exceeded the same
  event's on one source.
- **C5 fails**: 7.8 s of programme lost at the 2 s delay and 13.6–18.2 s at 10 s, marked, with no
  continuity error.
- **C6 fails on one source** (three of 18 cuts over 1 s) and **passes on two** (every hole under
  0.9 s, with a programme step of up to 1.4 s).
- **H1** in part: a clean exit has no detection term, yet costs 1.4–2.5 s, the switch itself. **H2**
  holds above the floor that the delay sets. **H3** fails: one switch, never back. **H4** holds, with
  a ±0.6 s offset. **H5** fails. **H6** holds on the demultiplexed lane and not on passthrough.
  **H7** fails on one source at cuts inside a picture, and holds on two.

## Conclusions

- **Legs started apart cost a switch at every arrival on the demultiplexed lane.** The relay serves
  the newest instance, so a standby's start or a failed leg's restart pre-empts a healthy serving
  leg: up to 3.3 s of decoder hole and 2.5 s of programme, with 11–25 corrupt pictures at a start on
  this open-GOP clip. The lane, as built, fails the requirement that its legs need not start
  together.
- **A switch discards the export's delay buffer.** That puts the floor of every switch at the delay
  plus up to half a second, and a hard kill adds detection beyond it. No idle timeout brings a failover
  under a second at a delay that still absorbs the source's jitter.
- **A hard kill can end a following export** (3 of 13 hard kills, all at idle timeouts of 4 s and
  more), turning a marked switch into an unmarked restart.
- **An outage shorter than the idle timeout is absorbed**; a longer one leaves the output on the
  standby.
- **The passthrough lane is the opposite trade**: arrivals are free, but losing the serving importer
  ends the export, and its restart lands on the standby unmarked, at about the demultiplexed lane's
  cost.
- **Selection at the receiver avoided every switch in the relay.** Two exports, one per leg and
  started apart, cost nothing at either start. A cut between them cost under 0.9 s on two encodes,
  plus their offset, and up to 1.6 s on one source where it split a picture. This model has no
  detection; a real input switch adds its receive timeout.
