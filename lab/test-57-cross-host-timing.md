# T57 — Source-to-egress media timing across hosts, on one clock (P1-aa)

**State: rig and grader written ([`p1aa-timing.sh`](scripts/p1aa-timing.sh),
[`p1aa-tap.py`](scripts/p1aa-tap.py), [`p1aa-grade.py`](scripts/p1aa-grade.py)); the 72 h run in progress.**

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
stream's PCR rate against its own arrivals.

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
