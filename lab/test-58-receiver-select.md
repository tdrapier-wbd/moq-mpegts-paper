# Test 58: 1+1 on the media-aware lane, selected at the receiver

**State: run and graded.** C0 and C3 hold; C2 and C4 fail. No leg's start, restart or return cost
the output anything; every fault but an uplink outage under the receive timeout cost it 0.6–3.6 s of
decoder hole, and no cell stayed under a second in all three runs.

## Objective

[T56](test-56-media-aware-failover.md) found that two legs of one broadcast cannot be started
apart on the demultiplexed lane: the relay serves the newest instance, so every leg's arrival is a
switch, and a switch empties the export's delay. Its `select` cell modelled the alternative, each
leg its own broadcast and export with the receiver choosing between them, and found that it cost
nothing at either leg's start, but it modelled the choice with no detection.

This test puts a real input switch in that place: TSDuck's `tsswitch`, reading both exports, cutting
to the other on a receive timeout. It asks whether that arrangement meets the requirement that
redundant legs start and restart at their own times
([Architecture](../docs/architecture.md) §5), and what each failure class costs the switched output.

## Environment

| Component | Build |
|---|---|
| `moq`, `moq-relay` | `main` at `66af72315` (moq 0.14.2, moq-relay 0.17.2), recorded with each run |
| Switch | TSDuck `tsswitch` 3.45, `--fast-switch` (both inputs read throughout), recorded with each run |
| Host | the laptop, loopback; no other timing work and no build on the host during a run. `outage`: an 8-core Linux host with no other work, loopback, `tsswitch` 3.44, importers retrying without limit (`RETRY=0s`), the clip's first 120 s byte for byte as the source |
| One source | T56's: the drills' contribution clip (1080i H.264, 9.95 Mb/s CBR) played live to a file that each importer follows from its own start |
| Two sources | T56's separate encode (720p H.264, 2 s closed GOP, 9 Mb/s CBR, other PIDs), played from the same instant |
| Legs | leg A and leg B, each an importer, its own relay and its own broadcast, and an `export ts --stitch --follow 10s --delay 2s` under a supervisor that restarts it when it exits |
| QUIC idle timeout | 6 s on every client and relay, keep-alive a third of it |

## Procedure

[`t58-receiver-select.sh`](scripts/t58-receiver-select.sh) starts every leg apart: importer A at
0 s, export A at 2 s, export B at 7 s, importer B at 8 s. `tsswitch` reads both exports' pipes from
2 s and writes the switched output. The switched output and each leg's export are recorded with
arrival times ([`t56-stamp.py`](scripts/t56-stamp.py)); every event, and each `tsswitch` switch
(`--event-command`), goes to the run's `events.txt`.

At 30 s the rig fails one component of the leg `tsswitch` is serving, and restarts it 15 s later
(an export restarts at once under its supervisor). Three runs per cell, 75 s each.

| Cell | Fault on the serving leg |
|---|---|
| `kill` | SIGKILL its importer |
| `term` | SIGTERM its importer |
| `relay` | SIGKILL its relay |
| `egress` | SIGKILL its export |
| `outage` | drop its importer's QUIC flow both ways, and any socket the importer opens meanwhile, for 0.3, 3, 6 and 12 s: under the receive timeout, between it and the idle timeout, at it and past it; nothing is restarted |

| Mode | `tsswitch` | Receive timeouts | Cells |
|---|---|---|---|
| non-revertive | `--receive-timeout` alone | 500 ms, 2,000 ms | all four; `outage` at 500 ms |
| revertive | `--primary-input 0` (leg A) | 500 ms | `kill`, `relay` |
| two sources | non-revertive, leg B on the separate encode | 500 ms | `kill`, `term` |

**Diagnostic, not graded:** the 3 s outage, three times on `bdc47852a`, which carries
[#6873](https://github.com/moq-dev/moq/pull/6873)'s fix for an export that ends on a missed decode
deadline after a silence; reported as whether leg A's export ends, and the cell's costs.

**Measures per event**, from [`t56-grade.py`](scripts/t56-grade.py) on each recording, as T56
defines them: the stall, the decoder hole beside the same before the event, the programme lost or
repeated, the latency step, and whether each cut is marked. Beside them, from `events.txt`: the
*detection*, from the fault to the switch that leaves its leg, and every switch a leg's start or
restart causes. The graded events are the fault, the standby's first start (importer and export)
and each restart.

## Pass criteria, fixed before running

1. **Void** unless every event time is in `events.txt`, every recording covers its run to within
   3 s of its end, and the source file shows no continuity error.
2. **C0, a leg's arrival is free:** in the non-revertive mode, the standby's start and each
   restart cause no switch, and no decoder hole on the switched output beyond its hole before the
   event plus 0.1 s, in all three runs of every cell. This is the requirement that legs need not
   start together.
3. **C1, the costs,** measured, no pass mark: per mode, timeout and cell, the median and worst of
   three runs of the detection, the stall, the decoder hole and the programme lost.
4. **C2, sub-second failover:** at the 500 ms timeout, in the non-revertive mode, every cell's
   fault costs the switched output a decoder hole and a programme lost under 1 s, in all three runs.
5. **C3, the revertive return:** the primary's restart costs one cut, with a decoder hole and a
   programme lost under 1 s, in all three runs. Graded against C0 rather than in place of it.
6. **C4, two sources:** every cut decodes on, with a decoder hole under 1 s, and the programme step
   reported, in all three runs of both cells.
7. **The outage** is graded on C0 to C2 at each duration: the uplink's return is an arrival (C0);
   the outage itself is a fault (C1, C2). An outage that causes no switch is reported as such, with
   the hole and programme lost it cost the output.

## Limits, fixed in advance

- `tsswitch` models a receiver's input select. It cuts at TS packet boundaries as packets arrive,
  detects only the absence of packets, and repairs no continuity counter or table; an IRD or an
  input switch may detect on content (TR 101 290 priority 1) and cut at a random access point.
- An export that kept sending packets after its media stopped would hold `tsswitch` on a dead leg.
  The detection measure shows this, and the result reports it rather than voiding the cell.
- FFmpeg is the decoder, not an IRD. Loopback has no loss or jitter, and the laptop's scheduler is
  in every timing.
- Both legs read one file on one host, so the source is common to them, which no 1+1 covers. The
  outage is a clean blackout of one flow on loopback, not a path that degrades.

## Results

**As run.** 36 runs on the laptop and 15 outage runs on the Linux host (12 on `66af72315`, three on
`bdc47852a`) graded; every one passed the void checks. Three departures from the procedure:

- **The relay cell ran twice.** In its first nine runs each importer gave up after the CLI's default
  reconnect budget (10 s) while its relay was down for 15 s, so leg A never returned and its
  recording did not cover the run (void). They were re-run with the importers retrying without limit
  (`RETRY=0s`, recorded in each run's `build.txt`). No other cell takes an importer's relay away.
- **Cuts come from the switch's own log.** `tsswitch` changes no table, so the grader marks none of
  its cuts and counts their continuity errors as outside any switch: 7–18 per run on the switched
  output, at most one per PID at each cut. Detection and every cut are taken from `events.txt`.
- **Two events were graded on their own cut.** The revertive return cuts 4.0–4.3 s after the
  importer's restart (6 s after the relay's), and at 2,000 ms the egress cell's restart comes
  0.9–1.1 s before its own fault's cut. Each run was re-graded with that cut inserted as an event,
  so that one window holds it alone.

Before leg A's export first sent (about 4 s), `tsswitch` cut between its two empty inputs at every
receive timeout; that precedes every graded event and the output's first picture.

**Faults.** Median, with the worst of three in brackets, in seconds. *Detection* runs from the fault
to the cut that leaves its leg; *bad* is the range of corrupt pictures after it.

| Mode, timeout | Cell | Detection | Stall | Decoder hole | Programme lost | Bad |
|---|---|---|---|---|---|---|
| non-revertive, 500 ms | `kill` | 3.34 (3.50) | 1.49 (1.49) | 2.24 (2.85) | 1.80 (2.12) | 0–33 |
| | `term` | 1.52 (1.54) | 0.52 (0.52) | 1.67 (1.69) | 0.44 (0.44) | 16–36 |
| | `relay` | 3.19 (3.21) | 1.49 (1.50) | 2.54 (2.55) | 2.40 (2.40) | 0 |
| | `egress` | 0.52 (0.53) | 0.51 (0.52) | 1.51 (1.54) | 0.40 (0.40) | 12–35 |
| | `outage`, 0.3 s | no cut | 0.03 (0.03) | 0.13 (0.13) | 0 (0) | 0 |
| | `outage`, 3 s | 3.41 (3.41) | 1.49 (1.49) | 2.87 (2.87) | 1.08 (1.08) | 33 |
| | `outage`, 6 s | 3.41 (3.42) | 1.49 (1.49) | 2.87 (2.87) | 1.08 (1.08) | 33 |
| | `outage`, 12 s | 3.42 (3.42) | 1.49 (1.49) | 2.87 (2.87) | 1.08 (1.08) | 33 |
| non-revertive, 2,000 ms | `kill` | 4.87 (4.91) | 2.99 (3.00) | 3.30 (3.56) | 3.16 (3.16) | 4–12 |
| | `term` | 3.02 (3.04) | 2.02 (2.03) | 3.15 (3.29) | 2.48 (2.52) | 13–16 |
| | `relay` | 4.82 (4.88) | 3.00 (3.00) | 3.29 (3.59) | 3.16 (3.16) | 4–12 |
| | `egress` | 2.03 (2.18) | 2.02 (2.02) | 2.05 (2.79) | 2.52 (2.52) | 7–12 |
| revertive, 500 ms | `kill` | 3.31 (3.39) | 1.49 (1.50) | 2.50 (2.54) | 2.40 (2.40) | 0 |
| | `relay` | 3.40 (3.45) | 1.50 (1.50) | 2.25 (2.54) | 2.12 (2.40) | 0 |
| two sources, 500 ms | `kill` | 3.37 (3.60) | 1.71 (1.71) | 3.64 (3.64) | 2.68 (2.68) | 0 |
| | `term` | 1.54 (1.56) | 0.56 (0.59) | 2.48 (2.49) | 1.52 (1.56); one run 0.28 repeated | 0–1 |

The best single runs: `term` at 500 ms 0.92 s of hole and 0.20 s lost; `egress` 0.79 s and 0.08 s.

**What detection waited for.** Leg A's own recording shows it. After a SIGKILL of its importer, or of
its relay, the export sent media for 1.61–1.95 s (what its 2 s delay held), then 0.97–0.98 s of
packets with no media (PCR and null), then nothing; the cut followed at the receive timeout. After a
SIGTERM, media and packets stopped together, 0.95–0.98 s after the signal. When the export itself
was killed, detection was the receive timeout (0.51–0.53 s and 1.98–2.18 s). No detection waited on
the QUIC idle timeout.

**Uplink outage.** At 0.3 s the importer kept its session and the output lost nothing. From 3 s the
cut came 3.41–3.42 s after the outage began, whatever its length, about when a hard kill's does, at
the same cost in all nine runs. The importer kept its session through 3 s. At 6 and 12 s the session
closed at the idle timeout (6.02 s, 0.02 s before the 6 s outage ended), and the importer reconnected
on its own: 0.5–1.0 s after the close, or 1.5–1.9 s after a 12 s outage ended. Leg A's export then
followed the new instance, marking the switch, and did not exit. After each 3 s outage it exited
instead, on *missed a decode deadline on PID 111*, 0.3–0.7 s after the uplink returned, and its
supervisor restarted it a second later: [#6802](https://github.com/moq-dev/moq/issues/6802)'s
failure, which `66af72315` predates. The cut came at the same instant whether or not the exit preceded
it. A smoke run at 3 s before these did not cut: its export ran on, and the output took holes of 1.58
and 1.30 s, 1.48 s of programme lost and 27 corrupt pictures.

**On `bdc47852a`** (the diagnostic) the export dropped the late frames and ran on in all three runs,
and the uplink's return raced the cut. Two runs did not cut: the output stayed on leg A with a 2.55 s
hole, 2.40 s of programme lost and no corrupt picture. One cut at 3.41 s, at `66af72315`'s cost.

**Arrivals.** 117 arrivals (each run's standby start, importer and export, and every restart but the
revertive mode's, which C3 grades) caused no cut. Each one's decoder hole was 0.15–0.30 s, within its hole before the event plus 0.1 s, except
the 2,000 ms egress restarts': 0.33, 0.48 and 0.63 s against 0.23 s. Re-graded on its own window, each
of those gaps begins at the fault's cut onto leg B, 0.9–1.1 s after the restart, and the restarted
leg was never selected. In the 12 outage runs on `66af72315`, 36 more (the standby's starts, the
uplink's returns and the 3 s cell's export restarts) caused no cut, each with a hole of 0.15–0.23 s, within the bar.

**Revertive return.** One cut back to leg A in every run: after the importer's restart, a decoder
hole of 0.20–0.21 s, 0.20 s of programme lost and one bad picture; after the relay's, 0.26–0.29 s,
0.24 s and one.

**Two sources.** Every cut moved the output onto the other encode's PIDs and decoded on.

## Grading

- **C0 holds.** No arrival cut the output, the uplink's returns included, and every arrival's hole is
  within the bar except two restarts whose window holds the fault's own cut, which a restarted leg
  that is never selected cannot cause.
- **C1** is the table above.
- **C2 fails** in every cell but the 0.3 s outage: at 500 ms each other cell's hole exceeded 1 s in
  at least two runs of three, and the programme lost exceeded 1 s in every `kill`, `relay` and
  3–12 s outage run.
- **7, the outage:** under the receive timeout it caused no switch and cost nothing; from 3 s,
  through and past the idle timeout, one cut costing 2.87 s of hole and 1.08 s of programme, and a
  return that cost nothing. On `bdc47852a` a 3 s outage cost over a second whether it cut or not.
- **C3 holds**: one cut, at most 0.29 s of hole and 0.24 s of programme, in all six runs.
- **C4 fails**: every cut decoded on, but the hole was 1.89–3.64 s at SIGKILL and 0.60–2.49 s at
  SIGTERM, with a programme step of 0.96–2.68 s lost at SIGKILL and from 0.28 s repeated to 1.56 s
  lost at SIGTERM.

## Conclusions

- **Selected at the receiver, legs start and restart at their own times.** Two broadcasts and an
  input switch meet the requirement that redundant legs need not start together: no start or
  restart cut the output or cost it more than its background hole, where in the relay each was a
  switch costing up to 3.3 s of hole ([T56](test-56-media-aware-failover.md)).
- **A fault costs what the failed leg sends after it, plus the cut.** A switch that detects on
  silence waits for the export to stop: at once when the export dies, about a second after a clean
  importer exit, and after a hard importer kill or relay loss for the media the delay held plus about
  a second of PCR and null packets. That hard kill cost 1.9–2.9 s of hole at a 500 ms timeout, against
  8.4–9.5 s for the relay's switch at the same 6 s idle timeout in T56, because no detection here
  waits on the transport.
- **An uplink outage costs nothing under the receive timeout, and from 3 s is detected as a hard
  kill is.** Once the export's delay runs dry the leg falls silent as a killed importer's does, so
  the cut comes at 3.4 s however long the outage. Past the idle timeout the importer reconnects on its
  own and its export follows, so the leg is ready again with nothing restarted. Outages between 0.3
  and 3 s were not run; at 3 s, with the export's exit fixed, the uplink's return races the cut.
- **A cut across missing programme corrupts until the next random-access point.** With detection at
  the timeout (a killed export) the hole was still 0.8–1.5 s, with 12–35 corrupt pictures, while the
  return between two live legs cost 0.2–0.3 s and one. An input switch that detects on the video
  PID rather than on packets would not wait out the padding, and one that cuts at a random-access
  point would not corrupt; `tsswitch` does neither, and neither has been measured.
- **Two sources add their offset**: up to 2.7 s of programme at a hard kill.
