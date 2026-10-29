# T57 — Source-to-egress media timing across hosts, on one clock (P1-aa)

**State: complete ([`p1aa-timing.sh`](scripts/p1aa-timing.sh), [`p1aa-tap.py`](scripts/p1aa-tap.py),
[`p1aa-grade.py`](scripts/p1aa-grade.py)). Over 72 h the export holds its delay on the two PCR clocks
and runs at its source's rate (C2 passes); C1, timed on arrivals, fails on the two multiplexers'
scheduling; the hand-offs' offset is below what the clocks can bound.**

## Objective

End-to-end timing through MoQ is measured on loopback, or for 2 h across hosts on PCR arrivals, and
an export's regenerated PCR grades the export, not the path ([Evidence](../docs/evidence.md) §3.11,
§3.16; §5 row 3). The live feed is handed off twice from one contribution path, once to each host.
Tapping the secondary's own hand-off against its export of the primary's import puts both ends of
the path, from the primary's ingest through its relay to the secondary's export, on one clock.

**Questions.**

1. What is the matched-PTS latency from the hand-off to the export, and does it hold over 72 h:
   its drift, and any step?
2. Does the export's output run at the hand-off's rate, as a fixed-delay export locked to its
   source should?
3. How far apart are the two hand-offs, and how well do the two hosts' clocks bound that offset?

## Environment

| Component | Build or setting |
|---|---|
| Hand-off | each host's standing ingest: SRT listener (2 s receive latency) to a loopback multicast group |
| Import | the primary's standing live publisher, demultiplexing, into its standing relay (standing build, untouched) |
| Export | on the secondary: the standing build, the hash recorded with the run; `export ts --delay 2s` from the primary's relay over the public addresses, under a supervisor that restarts it when it exits. `main` was planned, but cannot read the standing publisher's catalog (*unknown variant `pes`, expected `section`*), so an upgraded subscriber needs an upgraded publisher |
| Taps | [`p1aa-tap.py`](scripts/p1aa-tap.py): each picture's PTS and every 25th PCR with its arrival, no media. The hand-off is stamped by the kernel on receive (`SO_TIMESTAMPNS`); the export's pipe by the application |
| Clocks | chrony on Amazon Time Sync on both hosts, `chronyc tracking` logged every minute |

## Procedure

```bash
# on the secondary
ROLE=egress BIN=<moq dir> URL=https://<primary-ip>:443/anon BCAST=<feed-a broadcast> \
  setsid nohup bash p1aa-timing.sh <label> 72 &
# on the primary
ROLE=handoff setsid nohup bash p1aa-timing.sh <label> 72 &
# afterwards, on the secondary, with the primary's run copied beside it
python3 p1aa-grade.py ~/p1aa/<label> --primary ~/p1aa/<label>-primary --json grade.json
```

The grader joins pictures on PTS within two ticks and reports per minute the pictures matched and
missing and the latency's median, 1st and 99th percentiles; over the run, the median, the drift
(least-squares slope of the per-minute medians), each step over 5 ms, the restarts, and each
stream's PCR rate against its own arrivals, fitted within each continuous stretch of its PCR and
pooled: a splice or a restarted export's fresh clock otherwise bends a whole-run fit by tens of
percent.

## Pass criteria, fixed before running

1. **Void** unless both hosts' taps cover 72 h, the hand-off's packet count grows throughout at
   the feed's rate (a gap of over a minute is reported and its minutes excluded), and every export
   restart is in `events.txt`.
2. **C1, the delay holds:** outside the minute of each restart and the one after it, no per-minute
   median steps by more than 5 ms, and the drift is under 0.36 ms/h (0.1 ppm). Measured beside it:
   the median latency and its per-minute range.
3. **C2, the rate is the source's:** the export's PCR rate against its arrivals is within 0.1 ppm of
   the hand-off's.
4. **C3, the hand-offs' offset**, measured, no pass mark: per minute, beside the two clocks' summed
   error bound. It is relied on as the primary-to-secondary path only where the bound is under a
   tenth of it.
5. **Beside C1, ungraded, added after a look at the first 22 h:** the delay on the two PCR clocks,
   each picture's latency less its lead over the hand-off's PCR at its arrival plus its lead over
   the export's, summarised as C1 is. C1's measure times arrivals, so it carries how each
   multiplexer schedules pictures against its own PCR; this one takes that out. C1 stays the grade.

## Limits, fixed in advance

- One feed, one path between two zones of one region, and the demultiplexed lane only.
- The export's stamp is the application's read of a pipe, not the kernel's; scheduling delay on an
  otherwise lightly loaded host adds to it.
- The latency includes the export's 2 s delay by design; C1 and C2 grade its constancy, not its size.

## Results (72 h, the standing build, moq 0.14.2)

**Valid.** Both taps cover the 72 h, 4,321 minutes each with matched pictures: 8,053,472 matched
and 64 missing, all in the first minute while the join filled. The export restarted 13 times, each
in `events.txt`: on the contribution's forward encoder switch at hour 23.6, where it ended on its
clock check, and on the backward switch at hour 58.4, where the republished import's tracks were not
found (both as [T34](test-34-real-encoder-severity.md) records them); then eleven times in the last
38 s, into the pipe the stopped tap had closed.

| Criterion | Measured | Verdict |
|---|---|---|
| C1, on arrival times | median 3,685.8 ms, per-minute 3,466–3,789 ms; 3,793 of 4,320 minute-to-minute changes over 5 ms; drift −0.375 ms/h (−0.104 ppm) | fails |
| Beside C1, on the PCR clocks | median 4,031.8 ms, per-minute 4,020–4,063 ms; two steps over 5 ms (+7.0 and +5.8 ms), each in the minute of a restart; drift −0.013 ms/h (−0.004 ppm) | would pass |
| C2, the rate | hand-off −1.357 ppm and export −1.343 ppm against the secondary's arrivals: the export +0.014 ppm off the hand-off | passes |
| C3, the hand-offs' offset | median −0.138 ms, per-minute −0.313 to −0.029 ms, against a summed clock bound of 2.064 ms | not resolved |

**C1 fails on the multiplexers' scheduling, not the path.** In both streams each picture's lead
over its own PCR at arrival moves from minute to minute: the hand-off's, set by the contribution
encoder's multiplexer, has a per-minute median of 826.7 ms (1st–99th percentile 786–934 ms) and
moves a median 16.7 ms a minute; the export's is 1,182 ms (1,096–1,328 ms) and moves 27.0 ms. The
arrival latency is the PCR-clock delay plus the first lead less the second (4,031.8 + 826.7 − 1,182
≈ 3,677 ms, against 3,685.8 ms measured), so its movement is theirs.

**What it settles.** Across two hosts on one clock, an export of the primary's import holds its
delay from the secondary's own hand-off for 72 h on the media clocks, at 4,031.8 ms including its
2 s delay, with no drift a 0.1 ppm budget would see, and each restart re-anchors it by 6–7 ms. Its
output runs at its source's rate to 0.014 ppm, and so 1.36 ppm slow against the host's
disciplined clock: it follows the contribution's clock, not UTC. On arrivals, the two multiplexers'
scheduling moves the same latency by tens of milliseconds a minute. The two hand-offs sit 0.14 ms
apart, a fifteenth of what the two clocks can bound, so this rig cannot separate the
primary-to-secondary leg from the hand-offs' offset.
