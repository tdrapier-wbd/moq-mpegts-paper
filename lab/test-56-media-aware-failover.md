# T56 — Media-aware failover: what a decoder sees, and how small it can be made

**State: specified; the rig and grader are not yet written.**

## Objective

On the media-aware lane, 1+1 is a switch: the demultiplexing export follows a second importer as a
marked programme switch ([Architecture](../docs/architecture.md) §5). [T6](test-6-relay-resilience.md)
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

## Environment

| Component | Build |
|---|---|
| `moq`, `moq-relay` | `main`, the hash recorded with each run |
| Host | Linux, loopback, no other timing work on the host; `iptables` for the outage cell |
| One source | the drills' contribution clip looped live, every importer reading one file (T6's `FEED=file`) |
| Two sources | two encodes of the clip's reference decode, differing in GOP phase and PTS origin, started together, so that pictures align and packets do not |
| Export | `export ts --stitch --linger 10s --delay 2s`, two per relay; the passthrough lane under the rig's supervisor as the control |
| Version | the default, and moq-lite 07 where its epoch behaviour differs (T6) |

## Procedure

Each export's output goes through `tsp` to a UDP socket on loopback, recorded with arrival times.
Event times come from the processes' logs. Three runs per cell, each graded beyond one idle timeout
after its last event.

| Cell | Event | Idle timeout (keep-alive a third of it) |
|---|---|---|
| `kill` | SIGKILL of the serving importer; its restart 10 s later | 1, 2, 4, 6 s |
| `term` | its SIGTERM; its restart | 6 s |
| `outage` | the serving importer's uplink dropped for half, once and twice the idle timeout | C2's timeout, or 1 s if none passes |
| `sources` | `kill` and `term` with the two importers on separate encodes | 6 s and C2's timeout |
| `relay` | T6's arm 3: one importer through two middle relays, the serving middle relay SIGKILLed | 6 s; `--delay` 2 s and 10 s |
| `passthrough` | `kill` and `term` on the passthrough lane | 6 s and C2's timeout |

**Measures per event.** The *stall* is the longest gap in the export's output arrivals. The
*programme lost* is the source time absent across the event, from the video decode timestamps as in
[`t6-switch-grade.py`](scripts/t6-switch-grade.py); for separate sources, from each decoded picture
matched to the reference decode. The *decoder hole* is the longest interval, across the event,
between pictures FFmpeg decodes without error, each placed at its last packet's arrival. Audio's
longest gap is reported beside it. Each switch is graded *marked* if it carries a new PMT version and
a discontinuity indicator on every PID.

## Pass criteria, fixed before running

1. **Void** unless the source tap shows no loss, every event time is in a log, and every export's
   capture covers its run.
2. **C1, the costs**, measured, no pass mark: per cell and event, the median and worst of three runs
   of the stall, the programme lost and the decoder hole, and whether every switch is marked and
   survived.
3. **C2, sub-second:** a hard kill passes at an idle timeout if its decoder hole and its programme
   lost are under 1 s in all three runs. The result is the largest timeout tested that passes, or
   that none does.
4. **C3, the timeout's price:** at C2's timeout, an outage shorter than it causes no switch in any
   run; a longer one is graded as C1.
5. **C4, separate sources:** every switch is marked and every export survives, and each decoder hole
   is within one GOP of the same event's on one source.
6. **C5, a relay loss is seamless** (P1-ab): at both delays, no programme lost, no repeated
   timestamp, no flag and no continuity error.

## Limits, fixed in advance

- FFmpeg is the decoder, not an IRD; the hardware window (B-6) can repeat `kill` and `sources` at
  C2's timeout against a bank of IRDs.
- Loopback: detection here is the idle timeout alone. On a real path, an idle timeout under a second
  meets loss and jitter that loopback does not have, which C3 prices only in part.
