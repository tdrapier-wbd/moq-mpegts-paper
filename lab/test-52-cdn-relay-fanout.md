# Test 52 — Fan-out and permanence through a CDN-hosted relay

**State: specified, not run.** Waits on the operator's window and logging level, and on P0-g's end.

## Objective

Every fan-out figure in the paper is one `moq-relay` in one region ([T26](test-26-cross-host-fanout.md),
[T43](test-43-fanout-current-build.md)). This test puts the live feed through a relay another
implementation and another operator run, across the internet:

1. **The knee.** On each lane, how many subscribers does the relay carry before delivery degrades,
   and is the limit the relay's?
2. **Permanence.** Does delivery hold for 72 hours at about half the lower knee, and what does each
   reconnect cost?

## Environment

- **Relay:** the CDN-hosted moqx deployment of [T11](test-11-interop.md) § *A CDN-hosted moqx
  deployment*, `<CDN_RELAY_URL>`, draft 18 over raw QUIC. A single-core VM behind a 4 Gb/s traffic
  policer, as its operator configured it, with logging at INFO for the whole run.
- **Publishers:** on the primary, one per lane, each a separate consumer of the live ingest's loopback
  multicast group (B-7), `moq import ts` and `moq import ts --passthrough`. The standing units are
  not touched.
- **Subscribers:** on the tertiary (8 vCPU), `moq export ts --delay 1s` and `moq export ts
  --passthrough`.
- **Source:** the live feed, 25 Mb/s CBR, one service. Nothing is stored: every check runs in
  flight, and only event windows are kept.
- **Build:** `moq-dev` `main` at both ends, the hash recorded with the results.

## Procedure

**Ramp, per lane.** Subscribers added at 1, 2, 4, 8, 16, 24, 32, 40, 48 and 64, each step settled
for 60 s and measured for 120 s, ending at the first degraded step or at the operator's ceiling.
Four subscribers per lane are graded continuously by
[`t21-pcr-monitor.py`](scripts/t21-pcr-monitor.py) (continuity, PCR); every subscriber's delivered
bytes are counted from its `/proc/<pid>/io`. At each step a fresh subscriber measures join time,
from start to the first output byte (passthrough) or the first video keyframe (demultiplexed). The
subscriber host's CPU and network and the publishers' sent bytes are sampled each second.

**Soak.** Both lanes, the subscriber count at half the lower knee, split evenly, for 72 h. A
supervisor restarts any subscriber or publisher that exits and logs the exit, its reason and the
gap. A probe beside the subscribers records the path's loss and RTT each second.

The rig adapts [`f5-sub-side.sh`](scripts/f5-sub-side.sh) to a remote relay; it is written and named
here before the first run.

## Pass criteria, fixed before running

- **A step degrades** if, over its measure window, any subscriber delivers less than 98 % of its
  publisher's bytes, a graded subscriber records a continuity error or a PCR interval over 40 ms, any
  session ends, or the step's join time exceeds twice step 1's.
- **The knee is the relay's** only if, through the degraded step, the subscriber host stayed below
  70 % CPU and below half its network rate, and each publisher kept pace with the source. Otherwise
  the step is void and the ramp is reported as ending at the harness's limit.
- **The soak holds** if, outside logged events, the graded subscribers record no continuity error
  and no PCR interval over 40 ms, and every subscriber's delivered bytes stay at or above 99.9 % of
  its publisher's. Every reconnect is counted with its gap and cause; none is excused.
- The operator's relay-side CPU, egress and errors over the run are reported beside the results,
  not graded.

## Limits, stated in advance

- One relay, one region, one internet path from each host: neither a multi-hop tree nor a CDN's edge
  fleet.
- The demultiplexed lane through this relay loses the SI track's object and the head of each
  track's group in progress at a join (T11). The ramp grades media delivery, not that loss.
- The subscribers are `moq export ts` without a pacer, so delivery and continuity are graded, not
  the CBR wire.
