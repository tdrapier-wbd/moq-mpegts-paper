# Test 52 — Fan-out and permanence through a CDN-hosted relay

**State: ramps done; the demultiplexed soak running.** The demultiplexed lane's knee is the relay's
event loop: 32 subscribers of the 25 Mb/s feed at full rate, about 0.82 Gb/s, degraded at 40, where
the loop is 99 % busy, with groups skipped in common from 24. The passthrough lane has none: through
this node single sessions fall silent until QUIC's idle timeout at 2, 4 and 24 subscribers, on loss
or a silent path between the node and the subscriber host, and joins fail in clusters (the node refuses the joining
FETCH).

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
  deployment*, `<CDN_RELAY_URL>`, draft 18 over raw QUIC, moqx v0.3.6. A VM behind a 4 Gb/s traffic
  policer, as its operator configured it (described as single-core; its metrics count two CPUs),
  with logging at INFO for the whole run.
- **Publishers:** on the primary, one per lane, each a separate consumer of the live ingest's loopback
  multicast group, `moq import ts` and `moq import ts --passthrough`. The standing units are
  not touched.
- **Subscribers:** on the tertiary (8 vCPU), `moq export ts --delay 1s` and `moq export ts
  --passthrough`.
- **Source:** the live feed, 25 Mb/s CBR, one service. Nothing is stored: every check runs in
  flight.
- **Build:** `moq-dev` `main` at both ends, the hash recorded with the results.

## Procedure

**Ramp, per lane.** Subscribers added at 1, 2, 4, 8, 16, 24, 32, 40, 48 and 64, each step settled
for 60 s and measured for 120 s, ending at the first degraded step or at the operator's ceiling.
Four subscribers per lane are graded continuously by
[`t21-pcr-monitor.py`](scripts/t21-pcr-monitor.py) (continuity, PCR); every subscriber's delivered
bytes are the bytes its host received on its QUIC socket, an `nftables` counter on its port. On the
passthrough lane an uncounted subscriber opens the relay's subscription 5 s before the first: the
one that opens it never receives the catalog (*Results*). Groups the exports log as
skipped are counted per step, common (at least half the subscribers, one media time) or single, and
reported beside the verdict, ungraded. At each step a fresh subscriber measures join time,
from start to the first output byte (passthrough) or the first video keyframe (demultiplexed). The
subscriber host's CPU and network and the publishers' sent bytes are sampled each second.

**Soak.** The demultiplexed lane, 16 subscribers (half its knee), for 72 h; the passthrough lane,
which has no knee through this node (*Results*), waits for the node's fixes. A
supervisor restarts any subscriber or publisher that exits and logs the exit, its reason and the
gap. A probe beside the subscribers records the path's loss and RTT each second, at the last hop
that answers ICMP: the node answers neither ICMP nor TCP.

Rig: [`t52-cdn-fanout.sh`](scripts/t52-cdn-fanout.sh), [`f5-sub-side.sh`](scripts/f5-sub-side.sh)
adapted to a remote relay: `pub` on the primary, `ramp` and `soak` on the tertiary. Grader:
[`t52-grade.py`](scripts/t52-grade.py).

## Pass criteria, fixed before running

- **A step degrades** if, over its measure window, any subscriber delivers less than 98 % of its
  publisher's bytes, a graded subscriber records a continuity error or a PCR interval over 40 ms, any
  session ends, or the step's join time exceeds twice step 1's.
- **A failed join is not a degraded step** (added before the graded passthrough runs, after the
  node's join defect ended the first runs, *Results*): a subscriber that ends within 10 s of
  starting is restarted, five tries at most, and counted; five failures end the ramp as a join
  failure. A session that ends after delivering still degrades the step.
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

## Results

*Measured, `main` `f2fca6fd2` at both ends, draft 18 over raw QUIC, the live feed; one run on the
demultiplexed lane, three on the passthrough lane.*

**Demultiplexed lane: the knee is the relay's, at 32 subscribers by the criteria and 16 by content.**

| N | Received per subscriber, of step 1's | Host CPU | Join (s) | Skipped groups in the measure window, common / single | Step |
|---|---|---|---|---|---|
| 1 | 100.0 % (25.77 Mb/s) | 0.9 % | 1.83 | 0 / 0 | pass |
| 2, 4, 8, 16 | 99.9–100.0 % | 1.8–13.5 % | 0.95–2.04 | 0 / 0 | pass |
| 24 | 100.0 % | 21.1 % | 1.90 | 1 (320 ms of video at 14 subscribers) / 6 | pass |
| 32 | 99.9 % | 28.1 % | 1.97 | 0 / 23 | pass |
| 40 | **83.4 %** | 29.4 % | 2.23 | 17 / 348 | **degraded** |
| 48 | 66.2 %; 24 exports exited | 26.3 % | 1.99 | 12 / 168 | degraded |

The rate per subscriber here is the host's received rate over the step divided by N; at 40 its mean
of 83.4 % puts at least one subscriber under 98 %. The graded subscribers recorded no continuity
error and no PCR interval over 40 ms through 40, since the export fills a missing group with
stuffing. At 48 the exports exited on "output missed a decode deadline", video or MP2, starved
past their buffer. What the subscribers received levelled at 0.82–0.86 Gb/s from 32 to 48
subscribers, under a quarter of the node's policer. Through the degraded step the subscriber host stayed under 30 % CPU and
1 Gb/s, and the publisher read 25.00 Mb/s in every minute without an exit. No join exceeded twice
step 1's. **The node's own metrics put the knee in its event loop** (the operator's Prometheus,
mean over each measure window):

| N | Event loop busy | Busiest CPU | Node's interface sent (Gb/s) | Pacer timer lagged (/s) | Sends blocked by cwnd (/s) |
|---|---|---|---|---|---|
| 8 | 26.8 % | 16.6 % | 0.26 | 0.1 | 7.7 |
| 16 | 48.9 % | 29.5 % | 0.48 | 445 | 41 |
| 32 | 82.8 % | 47.2 % | 0.90 | 1,495 | 377 |
| 40 | **99.4 %** | 55.4 % | 0.94 | 4,082 | 4,892 |
| 48 | 88.6 % | 47.7 % | 0.92 | 1,811 | 1,789 |

The relay's one event loop saturates at 40 subscribers while neither of the VM's two CPUs does, and
its output stops growing; neither NIC dropped a packet.

**On the passthrough lane the node fails joins two ways.** Traced at debug on both:

- **The subscriber that opens the node's subscription never receives the catalog**, nine openers of
  nine across four publisher sessions. The node answers its SUBSCRIBE with the largest location and
  refuses the joining FETCH, and a catalog published once has no next group; a second subscriber
  behind it receives the catalog.
- **A subscriber that joins mid-group loses its session at the media track.** The joining FETCH is
  refused, the node opens the group's stream at its next object, the export declines a stream it
  has no head for, and the node ends the subscription (PUBLISH_DONE, status 0). This comes in
  clusters: every join failed for ten minutes against one publisher, and none for the first
  minutes after it restarted.

The demultiplexed catalog is revised during SI acquisition, so that lane's opener received a later
revision 0.76 s on, and its ramp saw no failed join through 40 subscribers.

**Passthrough lane: no reproducible knee, because single sessions stall at any count.** Three runs
under the amended rules, each after a fresh publisher, no join failing five times:

| Run | Steps passed | Degraded at | What ended it |
|---|---|---|---|
| 1 | 1 | 2 | One subscriber: nothing for 4.4 s, a group evicted, three continuity errors |
| 2 | 1, 2 | 4 | One subscriber: nothing for 11.8 s, then QUIC's idle timeout |
| 3 | 1–16 | 24 | Two subscribers: three groups evicted in 4 s, then the idle timeout; the other 22 in full |

In the passed steps every subscriber received 99.98–100.04 % of step 1's 26.33 Mb/s at its socket,
with no skipped group, continuity error or PCR interval over 40 ms, and joins took 0.39–1.18 s. In
each failure the host stayed under 12 % CPU and 0.6 Gb/s, and the publisher read 25.00 Mb/s with its
session undisturbed, so the silence was the node's or its path's. **The node's metrics place each
stall on the path between the two NICs**, neither of which dropped a packet (the node's interface
counters, and the subscriber host's UDP buffer errors and EC2 allowance counters, all zero):

- Run 1, at step 2's joins: the node declared about 3,200 packets lost and one persistent
  congestion in 30 s, its event loop 11–16 % busy.
- Run 2: probe timeouts with no loss declared and the event loop 14–17 % busy, so nothing
  acknowledged that connection for about 12 s; then one connection closed.
- Run 3: the event loop 73–78 % busy and its pacer timer lagging about 600 times a second, with
  loss in bursts; two connections closed at the timeouts.

The node logs none of it at INFO. The counters are the node's totals, attributed to a subscriber by
time. The lane has one media track, so
a stalled track is a silent connection; on the demultiplexed lane the other tracks would keep the
connection alive and the stall would show as a skipped group, which fits its single skips from 24
subscribers but is not shown. The demultiplexed ramp recorded no session end through 40.

## Corrections

- **The ramp's in-flight delivery rule read output bytes.** We counted each subscriber's `wchar`,
  as F5 did. On the demultiplexed lane the export writes its constant rate in stuffing whatever arrives, so
  output held 100 % at 40 subscribers while the host received 83 % per subscriber; the demultiplexed
  ramp is graded from the host's received rate. `rchar`, tried next, reads zero, since a QUIC
  subscriber receives by `recvmsg`; the rig now counts each subscriber's socket in the firewall.
  Rule: a receiver that restores a constant rate cannot report delivery by what it writes
  ([method notes](method-notes.md) §2).
