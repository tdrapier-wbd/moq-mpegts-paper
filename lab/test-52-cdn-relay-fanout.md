# Test 52 — Fan-out and permanence through a CDN-hosted relay

**State: ramps on moqx v0.3.6 and v0.3.7, the agreed slot and the demultiplexed soak done; the opener's refused join reproduced on loopback, fixed in v0.3.7, and gone from both nodes on it.** On v0.3.6 the demultiplexed lane's knee is the relay's event loop, on the one thread the operator gives it: 32 subscribers of the 25 Mb/s feed at full rate, about 0.82 Gb/s, degraded at 40, where the loop is 99 % busy, with groups skipped in common from 24. There the passthrough lane had none, single sessions falling silent until QUIC's idle timeout at 2, 4 and 24 subscribers and joins failing in clusters. On v0.3.7 no join fails on either node. The passthrough lane degrades on the one-thread node at 24, by groups arriving late. On a second node, on three threads, the passthrough lane delivers 80 in full (2.16 Gb/s) and degrades at 96, its loops 84 % busy, and the demultiplexed lane 64 (1.68 Gb/s), where the subscriber host's CPU ends the ramp. At 16 subscribers the demultiplexed lane held for 72 h by its criteria, its one break the source's, while each subscriber lost video about twice an hour, which the criteria cannot see, and the node's memory grew without bound.

## Objective

Every fan-out figure in the paper is one `moq-relay` in one region ([T26](test-26-cross-host-fanout.md), [T43](test-43-fanout-current-build.md)). This test puts the live feed through a relay another implementation and another operator run, across the internet:

1. **The knee.** On each lane, how many subscribers does the relay carry before delivery degrades, and is the limit the relay's?
2. **Permanence.** Does delivery hold for 72 hours at about half the lower knee, and what does each reconnect cost?

## Environment

- **Relay:** the CDN-hosted moqx deployment of [T11](test-11-interop.md) § _A CDN-hosted moqx deployment_, `<CDN_RELAY_URL>`, draft 18 over raw QUIC, moqx v0.3.6. A VM behind a 4 Gb/s traffic policer, as its operator configured it (described as single-core; its metrics count two CPUs), with logging at INFO for the whole run.
- **Publishers:** on the primary, one per lane, each a separate consumer of the live ingest's loopback multicast group, `moq import ts` and `moq import ts --passthrough`. The standing units are not touched.
- **Subscribers:** on the tertiary (8 vCPU), `moq export ts --delay 1s` and `moq export ts --passthrough`.
- **Source:** the live feed, 25 Mb/s CBR, one service. Nothing is stored: every check runs in flight.
- **Build:** `moq-dev` `main` at both ends, the hash recorded with the results.

## Procedure

**Ramp, per lane.** Subscribers added at 1, 2, 4, 8, 16, 24, 32, 40, 48 and 64, each step settled for 60 s and measured for 120 s, ending at the first degraded step or at the operator's ceiling. Four subscribers per lane are graded continuously by [`t21-pcr-monitor.py`](scripts/t21-pcr-monitor.py) (continuity, PCR); every subscriber's delivered bytes are the bytes its host received on its QUIC socket, an `nftables` counter on its port. On the passthrough lane an uncounted subscriber opens the relay's subscription 5 s before the first: the one that opens it never receives the catalog (_Results_). Groups the exports log as skipped are counted per step, common (at least half the subscribers, one media time) or single, and reported beside the verdict, ungraded. At each step a fresh subscriber measures join time, from start to the first output byte (passthrough) or the first video keyframe (demultiplexed). The subscriber host's CPU and network and the publishers' sent bytes are sampled each second.

**Soak.** The demultiplexed lane, 16 subscribers (half its knee), for 72 h; the passthrough lane, which has no knee through this node (_Results_), waits for the node's fixes. A supervisor restarts any subscriber or publisher that exits and logs the exit, its reason and the gap. A probe beside the subscribers records the path's loss and RTT each second, at the last hop that answers ICMP: the node answers neither ICMP nor TCP.

Rig: [`t52-cdn-fanout.sh`](scripts/t52-cdn-fanout.sh), [`f5-sub-side.sh`](scripts/f5-sub-side.sh) adapted to a remote relay: `pub` on the primary, `ramp` and `soak` on the tertiary. Graders: [`t52-grade.py`](scripts/t52-grade.py) (ramps), [`t52-soak-grade.py`](scripts/t52-soak-grade.py) (soak).

## Pass criteria, fixed before running

- **A step degrades** if, over its measure window, any subscriber delivers less than 98 % of its publisher's bytes, a graded subscriber records a continuity error or a PCR interval over 40 ms, any session ends, or the step's join time exceeds twice step 1's.
- **A failed join is not a degraded step** (added before the graded passthrough runs, after the node's join defect ended the first runs, _Results_): a subscriber that ends within 10 s of starting is restarted, five tries at most, and counted; five failures end the ramp as a join failure. A session that ends after delivering still degrades the step.
- **The knee is the relay's** only if, through the degraded step, the subscriber host stayed below 70 % CPU and below half its network rate, and each publisher kept pace with the source. Otherwise the step is void and the ramp is reported as ending at the harness's limit.
- **The soak holds** if, outside logged events, the graded subscribers record no continuity error and no PCR interval over 40 ms, and every subscriber's delivered bytes stay at or above 99.9 % of its publisher's. Every reconnect is counted with its gap and cause; none is excused.
- The operator's relay-side CPU, egress and errors over the run are reported beside the results, not graded.

## Limits, stated in advance

- One relay, one region, one internet path from each host: neither a multi-hop tree nor a CDN's edge fleet.
- The demultiplexed lane through this relay loses the SI track's object and the head of each track's group in progress at a join (T11). The ramp grades media delivery, not that loss.
- The subscribers are `moq export ts` without a pacer, so delivery and continuity are graded, not the CBR wire.

## Results

_Measured, `main` `f2fca6fd2` at both ends, draft 18 over raw QUIC, the live feed; one run on the demultiplexed lane, three on the passthrough lane._

**Demultiplexed lane: the knee is the relay's, at 32 subscribers by the criteria and 16 by content.**

| N | Received per subscriber, of step 1's | Host CPU | Join (s) | Skipped groups in the measure window, common / single | Step |
| --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % (25.77 Mb/s) | 0.9 % | 1.83 | 0 / 0 | pass |
| 2, 4, 8, 16 | 99.9–100.0 % | 1.8–13.5 % | 0.95–2.04 | 0 / 0 | pass |
| 24 | 100.0 % | 21.1 % | 1.90 | 1 (320 ms of video at 14 subscribers) / 6 | pass |
| 32 | 99.9 % | 28.1 % | 1.97 | 0 / 23 | pass |
| 40 | **83.4 %** | 29.4 % | 2.23 | 17 / 348 | **degraded** |
| 48 | 66.2 %; 24 exports exited | 26.3 % | 1.99 | 12 / 168 | degraded |

The rate per subscriber here is the host's received rate over the step divided by N; at 40 its mean of 83.4 % puts at least one subscriber under 98 %. The graded subscribers recorded no continuity error and no PCR interval over 40 ms through 40, since the export fills a missing group with stuffing. At 48 the exports exited on "output missed a decode deadline", video or MP2, starved past their buffer. What the subscribers received levelled at 0.82–0.86 Gb/s from 32 to 48 subscribers, under a quarter of the node's policer. Through the degraded step the subscriber host stayed under 30 % CPU and 1 Gb/s, and the publisher read 25.00 Mb/s in every minute without an exit. No join exceeded twice step 1's. **The node's own metrics put the knee in its event loop** (the operator's Prometheus, mean over each measure window):

| N | Event loop busy | Busiest CPU | Node's `eth0` sent (Gb/s) | Pacer timer lagged (/s) | Sends blocked by cwnd (/s) |
| --- | --- | --- | --- | --- | --- |
| 8 | 26.8 % | 16.6 % | 0.21 | 0.1 | 7.7 |
| 16 | 48.9 % | 29.5 % | 0.42 | 445 | 41 |
| 32 | 82.8 % | 47.2 % | 0.83 | 1,495 | 377 |
| 40 | **99.4 %** | 55.4 % | 0.87 | 4,082 | 4,892 |
| 48 | 88.6 % | 47.7 % | 0.85 | 1,811 | 1,789 |

The relay's one event loop saturates at 40 subscribers while neither of the VM's two CPUs does, and its output stops growing; neither NIC dropped a packet. The operator runs moqx on one thread, unpinned, so the scheduler spreads it over both CPUs, and keeps the rest of the VM for monitoring: the knee is one thread's.

**On the passthrough lane the node fails joins two ways.** Traced at debug on both:

- **The subscriber that opens the node's subscription never receives the catalog**, nine openers of nine across four publisher sessions. The node answers its SUBSCRIBE with the largest location and refuses the joining FETCH, and a catalog published once has no next group; a second subscriber behind it receives the catalog.
- **A subscriber that joins mid-group loses its session at the media track.** The joining FETCH is refused, the node opens the group's stream at its next object, the export declines a stream it has no head for, and the node ends the subscription (PUBLISH_DONE, status 0). This comes in clusters: every join failed for ten minutes against one publisher, and none for the first minutes after it restarted.

The demultiplexed catalog is revised during SI acquisition, so that lane's opener received a later revision 0.76 s on, and its ramp saw no failed join through 40 subscribers.

**Passthrough lane: no reproducible knee, because single sessions stall at any count.** Three runs under the amended rules, each after a fresh publisher, no join failing five times:

| Run | Steps passed | Degraded at | What ended it |
| --- | --- | --- | --- |
| 1 | 1 | 2 | One subscriber: nothing for 4.4 s, a group evicted, three continuity errors |
| 2 | 1, 2 | 4 | One subscriber: nothing for 11.8 s, then QUIC's idle timeout |
| 3 | 1–16 | 24 | Two subscribers: three groups evicted in 4 s, then the idle timeout; the other 22 in full |

In the passed steps every subscriber received 99.98–100.04 % of step 1's 26.33 Mb/s at its socket, with no skipped group, continuity error or PCR interval over 40 ms, and joins took 0.39–1.18 s. In each failure the host stayed under 12 % CPU and 0.6 Gb/s, and the publisher read 25.00 Mb/s with its session undisturbed, so the silence was the node's or its path's. **The node's metrics place each stall on the path between the two NICs**, neither of which dropped a packet (the node's interface counters, and the subscriber host's UDP buffer errors and EC2 allowance counters, all zero):

- Run 1, at step 2's joins: the node declared about 3,200 packets lost and one persistent congestion in 30 s, its event loop 11–16 % busy.
- Run 2: probe timeouts with no loss declared and the event loop 14–17 % busy, so nothing acknowledged that connection for about 12 s; then one connection closed.
- Run 3: the event loop 73–78 % busy and its pacer timer lagging about 600 times a second, with loss in bursts; two connections closed at the timeouts.

The node logs none of it at INFO. The counters are the node's totals, attributed to a subscriber by time. The lane has one media track, so a stalled track is a silent connection; on the demultiplexed lane the other tracks would keep the connection alive and the stall would show as a skipped group, which fits its single skips from 24 subscribers but is not shown. The demultiplexed ramp recorded no session end through 40.

### The demultiplexed soak

_Measured, `f2fca6fd2` at both ends, 16 subscribers, 72.0 h._

**The soak holds by its criteria; its one break was the source's.**

| Criterion | Measured |
| --- | --- |
| No continuity error or PCR interval over 40 ms outside logged events | none in 4,321 one-minute windows on each graded subscriber |
| Delivered bytes at least 99.9 % of the publisher's | 101.34–101.37 % over the run; 100.63 % in the lowest subscriber-hour (one subscriber's first, as it joined), at least 101.24 % in every other |
| Every reconnect counted, with its gap and cause | one break, all 16 sessions at once: output again in 5.3–5.6 s; the source's (below) |

At 18.8 h the soak's publisher exited on the backward step that ended both standing imports in the same second (16,841 s below the previous group, [T34](test-34-real-encoder-severity.md)), and every session ended with it. The publisher was back in 1.2 s; each subscriber resubscribed after 3.0–3.3 s and reported output by 5.3–5.6 s.

**Ungraded: each subscriber lost video that never reached it in time.** After each start's first 15 s, a subscriber logged 116–169 video skips, 30.6–44.0 s of video in all (about two an hour, most of 320 ms), and 18–34 groups evicted as too old; no export missed a decode deadline. Of the distinct skips, 11 reached at least half the subscribers (ten of video, one of 96 ms on the MP2 track at all 16) and 1,653 fewer, 1,333 of those one subscriber alone. In 141 minutes some subscriber dropped late frames; in five of them at least half did. The monitors saw none of it: the export fills a skipped span with stuffing and keeps its PCR. The skips are neither the host's (CPU mean 15 %, peak 30 %) nor loss on the path to the last hop that answers ICMP (1 probe lost of 258,973; RTT median 10.7 ms, 99.9th percentile 12.5 ms), and QUIC repairs loss rather than skipping it, so each reads as a group that reached its subscriber too late. The subscribers ask for newest-first group order, the client's default, under which a relay may send a group ahead of the tail of the one before; the publisher ranks video below its audio, verbatim and catalog tracks.

**The node's counters do not place them** (its Prometheus per minute over the run, reported beside the result as the criteria set). It held 17 connections throughout, its event loop 58 % busy on average (75 % in the busiest minute), its CPUs 32 % (47 %), sending 0.42 Gb/s. Its subscriber-side subgroup and stream resets stayed at zero; its publisher-side subgroup resets moved only at the soak's start and at the break. Its QUIC declared 0.034 % of 10.8 billion packets lost, in 3,818 of 4,321 minutes and steadily from hour to hour, with 15 persistent-congestion events in 11 minutes, the pacer timer lagging about 685 times a second and about 39 sends a second blocked by the congestion window; no interface, UDP-buffer or softnet drop. None of it stands out at the 11 shared skips (loss 0–2,395 in their minutes, against a median minute's 544; no persistent congestion) or the five late minutes, and the hour with the most skips had among the least loss. At the node's rate the probe would have lost about 90, so the declared loss lies between the node and that hop, falls only on the node's own bursts, or is declared rather than real. The operator counts 5,010 drops at the node's qdisc, not resolved in time: if all fell in the soak, about one in 700 of the declared loss.

**The node's memory grew without bound**, by the operator's reading: about 57 MiB an hour, to 3.06 GiB of its 4 GB by the end, falling back when the sessions ended. He traced part of it to cache metadata moqx v0.3.6 keeps for each evicted group, so it grows with the group rate, about 74 a second here ([moqx#874](https://github.com/openmoq/moqx/issues/874), since fixed). At that rate the node had less than a day left, so 72 h is close to the longest this load can run on that release; a release with the fix is the one to re-soak (P1-j).

**What the criteria could not see.** The byte criterion reads socket bytes, which carry about 1.3 % of QUIC and IP overhead over the publisher's input, so a loss under about 1.2 % would pass it; the subscribers' spread about their median, −0.022 % to +0.014 %, is the finer reading. The monitors cannot see a hole the export has filled. A soak of this lane needs the export's skip count graded.

### The opener's join on a local moqx (criteria fixed before the first run)

moqx v0.3.7 carries [#899](https://github.com/openmoq/moqx/pull/899): with `use_local_forwarders`, a subscriber on the publisher's I/O thread no longer has its joining FETCH refused ([#883](https://github.com/openmoq/moqx/issues/883)). If that is the node's failure, the release fixes it before the node upgrades. Laptop loopback, raw QUIC draft 18, moqx v0.3.6 against v0.3.7 (the macOS arm64 release binaries), in three configurations: **N**, the node's single thread with `use_local_forwarders: true`; **Q**, #883's `threads: 4` with `use_relay_thread` and `use_local_forwarders`; and **D**, the default (no local forwarders), on v0.3.6 only, as the attribution control. A trial is a fresh broadcast: `moq import ts --passthrough` of the synthetic fixture, its catalog published once; 4 s later the opener, `moq export ts --passthrough` for 8 s; 2.5 s after it, a joiner for 6 s. Ten trials per release and configuration, twenty in a configuration where v0.3.6 refuses fewer than half. An opener is refused if it exports no payload in its 8 s and its log shows the joining FETCH refused.

**Void** unless v0.3.6 refuses at least one opener in N or Q: then the node's failure has not been reproduced here, and the release is untested against it. **Pass** if v0.3.7 refuses no opener, in every configuration where v0.3.6 refused one. **Reported:** the joiners on both releases, and D.

**Results: pass.** Rig [`t52-local-join.sh`](scripts/t52-local-join.sh), the client at `204c97f4f`, ten trials each; D ran on both releases.

| Configuration | v0.3.6 openers refused | v0.3.6 joiners refused | v0.3.7 openers refused | v0.3.7 joiners refused |
| --- | --- | --- | --- | --- |
| N | 10 of 10 | 10 of 10 | 0 of 10 | 0 of 10 |
| Q | 10 of 10 | 10 of 10 | 0 of 10 | 0 of 10 |
| D | 0 of 10 | 0 of 10 | 0 of 10 | 0 of 10 |

Each v0.3.6 refusal is the client's "joining FETCH failed … not found" beside moqx's "Session not found". With local forwarders off, v0.3.6 refused nothing, so the refusal is #883's path. Every v0.3.7 opener exported 1.75–2.00 MB in its 8 s, and every joiner 1.37–1.38 MB in its 6 s. Two results differ from the node's: here the joiner is refused too, where the node's received the catalog; and Q refused every subscriber, where #883 refused one in five on Linux. Neither difference is explained. **v0.3.7 fixes the opener's refusal wherever v0.3.6 reproduced it; the node's own case closes when it upgrades.**

### The node's joins on v0.3.7 (criteria fixed before the first run)

Both nodes now run v0.3.7: the one measured above, on one thread, and a second in the same region on three. The trials above, unchanged, against each node across the internet from the laptop: raw QUIC draft 18, the client at `419b799c7`, the synthetic fixture under the operator's test prefix, ten trials per node. In the same session, as the grader's controls, v0.3.6 and v0.3.7 on loopback in configuration N, three trials each.

**Void** unless v0.3.6 refuses all three openers on loopback and v0.3.7 none. **Pass** if neither node refuses an opener or a joiner in its ten trials: each exports payload in its window and logs no refused joining FETCH. **Reported:** each role's payload beside loopback's. Ten fresh broadcasts cannot show the mid-group failure, which came in clusters against one long-lived publisher; the ramp tests that.

**Results: pass on both nodes, and the ramps below saw no mid-group failure.** Controls valid: v0.3.6 refused 3 openers of 3, v0.3.7 none.

| Relay | Openers refused | Joiners refused | Opener payload | Joiner payload |
| --- | --- | --- | --- | --- |
| Loopback, v0.3.7, N | 0 of 3 | 0 of 3 | 1.75–2.00 MB | 1.37–1.39 MB |
| One-thread node | 0 of 10 | 0 of 10 | 0.97–1.75 MB | 1.12–1.37 MB |
| Three-thread node | 0 of 10 | 0 of 10 | 0.52–1.75 MB | 0.62–1.37 MB |

Every subscriber received the catalog and media. Payloads run below loopback's because each window starts a round trip later across the internet; the two lowest, an opener and a joiner, are one broadcast's, so their common cause sits at the publisher's side of the node.

### Ramps on v0.3.7 (criteria fixed before the first run)

Both nodes run moqx v0.3.7, which fixes the refused joining FETCH: the one-thread node measured above, and the three-thread node. Its operator has lifted the DDoS rule that acted above 1.5 Gb/s on the three-thread node, whose ceiling is now its 5 Gb/s policer, but not on the one-thread node. The client is `f2fca6fd2`, as above, so the node is what changed. Joins get five tries and the passthrough lane is anchored, as above.

- **Three-thread node, both lanes:** subscribers at 1, 2, 4, 8, 16, 24, 32, 40, 48 and 56 (56 carry about 1.4 Gb/s of media), each step settled 60 s and measured 120 s, ending at the first degraded step.
- **One-thread node, passthrough lane, for an hour:** the same schedule to 48, then 52, each step settled 120 s and measured 240 s. Its rule allows no more: 56 subscribers would reach about 1.51 Gb/s at the interface. If its own step 1 projects 52 past 1.45 Gb/s at this host's interface, the ramp ends at 48. Either end is reported as the operator's ceiling, not a knee.

**Changed before the first step:** the three-thread node ends every session of `f2fca6fd2` and of `3c0daa21b` as it opens. Each client rejects a SETUP parameter value the node sends, which the one-thread node does not send, and retries; `cd560bde5e` connects. The three-thread node's ramps run `cd560bde5e`, so the threads comparison changes the client as well as the node; the one-thread node's runs `f2fca6fd2` as planned. **Changed again, before the three-thread node's graded ramps:** with `cd560bde5e` at both ends, a subscriber that joins more than about a minute after the first receives no catalog, on either node, so that client cannot ramp (_Results_). Those ramps run `d66c892833`, the commit before that change, once it has connected to the three-thread node and passed a join three minutes after the first subscriber.

The criteria above apply unchanged. **H-threads:** on three threads, the demultiplexed lane passes the one-thread node's 32. **H-join:** on v0.3.7 no passthrough subscriber fails its join, and none ends at a mid-group join, on either node. **Reported:** the passthrough lane's single-session stalls, by subscriber and time; each step's common and single skips; the node's own metrics only as its operator provides them, since this run reads none.

**Results, one-thread node: the passthrough lane degrades at 24, as on v0.3.6, but by late groups rather than silent sessions.** One publisher for 58 min, reading 25.000 Mb/s in every minute without an exit.

| N | Received per subscriber, of step 1's (lowest) | Host CPU | Join (s) | Skips in the measure window, common / single | Graded subscribers: continuity errors / PCR intervals over 40 ms (longest) | Step |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % (25.89 Mb/s) | 1.1 % | 0.72 | 0 / 0 | 0 / 0 | pass |
| 2, 4, 8, 16 | 99.9 % | 1.6–9.2 % | 0.43–0.86 | 0 / 0 | 0 / 0 | pass |
| 24 | 100.0 % | 14.7 % | 0.61 | 0 / 7 | 42 / 7 (350 ms), three of four | **degraded** |
| 32 | 100.0 % | 20.0 % | 1.11 | 0 / 14 | 10 / 0 (35 ms), one | degraded |
| 40 | 100.2 % | 27.8 % | 0.56 | 0 / 163 | 115 / 16 (300 ms), four | degraded |
| 48 | 100.1 %; 10 sessions ended | 27.1 % | 1.05 | 0 / 140 | 156 / 23 (372 ms), three | degraded |

From step 24's settle, subscribers logged the group they were reading evicted before they had read it, a later group having arrived first, and the export resumed at the next: 5,443 skips over the run, a median of 109 ms each and at most 864 ms, all single but five, which fell in step 48's settle. No join failed, so **H-join holds on this node**, and no session ended through 40, where on v0.3.6 single sessions fell silent at 2, 4 and 24. At 48 ten subscribers that had joined at earlier steps ended 31–75 s after the step's joins, each after a run of evicted groups, when the node reset its media track (code 5); the ramp stopped there. The byte criterion cannot see this: the socket's median rate rose from 25.87 Mb/s at 2 subscribers to 26.17 at 48, at most 27.11, which fits retransmission, the repaired group arriving after its successor. The subscriber host stayed under 28 % CPU and 1.09 Gb/s, so by the criteria the knee is the relay's; the node's own counters, below, place it in the node rather than its path.

**Three-thread node, first on `cd560bde5e`: the ramp stopped at its second subscriber, on the client's defect.** Joining three minutes after the first, it received nothing for 190 s, nor did the step's five join probes. That client's publisher gives its catalog a cache duration of zero (`MAX_CACHE_DURATION` 0), which draft 18 applies to the newest object too, and its subscriber fetches no catalog: joiners a minute or more after the first received none on either node, while the October client on either side joined, and on loopback moqx v0.3.7 failed every joiner that `moq-relay` served ([moq#8465](https://github.com/moq-dev/moq/issues/8465)). The ramps below run `d66c892833`.

**Demultiplexed lane: 40 subscribers in full, so H-threads holds; at 48 the subscriber host ran out of memory.** One publisher for 33 min, 25.00 Mb/s in every minute without an exit; no join failed.

| N | Received per subscriber, of step 1's (lowest) | Host CPU | Join (s) | Skips in the measure window, common / single | Step |
| --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % (25.31 Mb/s) | 1.0 % | 2.16 | 0 / 0 | pass |
| 2, 4, 8, 16, 24 | 100.0–100.2 % | 1.9–24.3 % | 1.25–2.37 | 0 / 0 | pass |
| 32 | 99.95 % | 34.1 % | 1.66 | 0 / 1 | pass |
| 40 | 99.9 % | 42.9 % | 2.38 | 0 / 0 | pass |
| 48 | 99.98 % of those alive; 3 exports ended | 50.4 %, 14 MB of memory free | 0.63 | 3 / 9 | **void** |

The graded subscribers recorded no continuity error and no PCR interval over 40 ms at any step, the export filling skipped spans with stuffing. At 48 the three common skips fell within one second, at 24–35 subscribers each (96 ms of MP2, 320 ms of video, 200 ms of a verbatim PID), and in that second two exports ended on a missed MP2 decode deadline; the kernel killed a third for memory. The subscribers received 1.03 Gb/s at 40 and 1.18 Gb/s at 48, the host under 51 % CPU, but its free memory had fallen to 14 MB three seconds before the skips, so the step is the harness's limit, not the relay's knee (_Corrections_). Three threads carry 40 where one carried 32, though the release (v0.3.7) and the client changed with the threads.

**Passthrough lane: degraded at 4 on join time alone; on delivery, 48 subscribers in full, and at 56 the subscriber host ran out of memory.** One publisher for 33 min, 25.00 Mb/s in every minute without an exit; no join failed and no session ended through 48, so **H-join holds on both nodes**.

| N | Received per subscriber, of step 1's (lowest) | Host CPU | Join (s) | Skips in the measure window, common / single | Graded subscribers | Step |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % (25.87 Mb/s) | 1.0 % | 0.41 | 0 / 0 | clean | pass |
| 2 | 100.0 % | 1.6 % | 0.42 | 0 / 0 | clean | pass |
| 4 | 100.0 % | 2.8 % | **1.08** | 0 / 0 | clean | **degraded** (join) |
| 8, 16, 24 | 99.95–100.0 % | 4.9–13.2 % | 0.33–0.78 | 0 / 0 | clean | pass |
| 32, 40 | 99.95–100.0 % | 18.5–22.7 % | 1.03, 0.93 | 0 / 0 | clean | degraded (join) |
| 48 | 100.0 % | 27.5 % | 0.62 | 0 / 0 | clean | pass |
| 56 | 100.0 % of those alive; 3 sessions ended | 35.9 %, 4 MB of memory free | 0.66 | 0 / 59 | continuity errors at two, PCR interval up to 1.37 s | **void** |

The join rule fails at 4 because step 1's join, 0.41 s, sets the bound at 0.83 s, and one probe a step ranged 0.33–1.08 s with no trend in N; on the one-thread node the same lane's ranged 0.43–1.11 s against a bound of 1.45 s. On delivery the lane held through 48, 1.29 Gb/s received with no skip, continuity error or PCR interval over 40 ms. At 56, 1.45 Gb/s, within a second of the measure window's start 49 subscribers lost the same group to eviction, ten seconds after the host's free memory had fallen to 20 MB, and by the window's close the kernel had killed three sessions for memory; the host stayed under 36 % CPU, so the step is the harness's limit (_Corrections_). Where the one-thread node delivered late groups from 24 subscribers, this node delivered none through 48.

**The node's side, read afterwards from its operator's dashboard:** moqx's counters and its host's over each measure window, per second since the one-thread node's windows are 240 s and the other's 120 s. A counter is read as its change between the last scrapes (15 s apart) at or before the window's edges, since `increase()` over the window starts at the first scrape inside it and would drop a burst at its start. Busy is the mean over the node's event loops.

| Node, lane | N | Sent (Gb/s, `eth0`) | Event loops busy | Busiest CPU | Losses a second, real / spurious | Pacer timer lagged (/s) | Step |
| --- | --- | --- | --- | --- | --- | --- | --- |
| One thread, passthrough | 16 | 0.45 | 34.8 % | 24.5 % | 3 / 15 | 0.05 | pass |
|  | 24 | 0.67 | 47.6 % | 32.1 % | 51 / 58 | 11 | degraded |
|  | 40 | 1.10 | 84.0 % | 48.1 % | 72 / 521 | 1,999 | degraded |
|  | 48 | 1.05 | 91.7 % | 49.2 % | 48 / 348 | 3,726 | degraded |
| Three threads, demultiplexed | 1 | 0.03 | 2.3 % | 4.0 % | 0 / 0 | 162 | pass |
|  | 40 | 1.04 | 33.1 % | 30.9 % | 50 / 101 | 3,176 | pass |
|  | 48 | 1.19 | 36.0 % | 34.4 % | 177 / 233 | 3,695 | void |
| Three threads, passthrough | 24 | 0.67 | 22.5 % | 22.9 % | 0 / 0.4 | 0 | pass |
|  | 48 | 1.30 | 40.6 % | 40.6 % | 9 / 8 | 0.03 | pass |
|  | 56 | 1.49 | 48.0 % | 45.7 % | 722 / 41 | 241 | void |

Neither node's host dropped a packet in any window: UDP buffer and input errors, `eth0` drops and softnet drops read zero, so every loss counted arose beyond the node's host or was spurious (declared lost, then acknowledged). **The one-thread node's knee is its own.** Its lane degraded at 24 with the loop under half busy, but there its pacer timer first ran late and its real losses rose from 3 to 51 a second, where the three-thread node carried the same rate to the same host with neither. Its ten sessions ended in the minute its loop was 99.5 % busy, its RTT up to 64 ms, its memory in use 266 MB above the step before and its real losses 575 a second; it reset 10 subgroups and 42 streams and closed 10 connections in that minute. **On three threads the demultiplexed lane's pacer timer ran late from the first subscriber**, the loops 2 % busy, and the passthrough lane's not through 48: the lag follows the lane, not the load. **The passthrough lane's burst at 56 was the subscriber host's.** Between the scrapes either side of the measure window's start the node counted 72,667 losses, 414 of them spurious, against under 50 a second before, and its RTT over that half-minute rose from 13 to 27 ms; smaller bursts followed for a minute, the loops at 48 %. The eviction that 49 subscribers logged falls in that burst, ten seconds after the subscriber host's free memory reached 20 MB.

### The agreed slot: past 1.5 Gb/s, both ends' drops counted (criteria fixed before the first run)

The ramps agreed for 11 November ran a day early, above; the slot's two answer what they left open, on the three-thread node, with `d66c892833` at both ends, joins given five tries and the passthrough lane anchored. The subscriber host now logs each second its UDP receive-buffer and input errors, its softnet drops and its NIC's allowance counters (bandwidth in, packets per second, connection tracking); the node's counters are read for each measure window as above.

- **Passthrough lane, past 1.5 Gb/s:** subscribers at 1, 24, 48, 56, 64, 72, 80 and 96 (96 carry about 2.5 Gb/s), each settled 60 s and measured 120 s. The ramp carries on through degraded steps (`CONTINUE=1`), ending at 96, once more than a quarter of its subscribers have ended, or at the subscriber host's limits.
- **Demultiplexed lane, its knee again:** the schedule to 56, then 64, 72 and 80, ending at the first degraded step, as above.

The criteria above apply, except the join rule, whose baseline was one probe ([method notes](method-notes.md)): a join degrades its step only past twice the longest either node gave the lane on 10 November, 2.2 s passthrough and 4.8 s demultiplexed. **H-path:** the loss at 56 is the network's, at a limit near 1.5 Gb/s: every passthrough step from 56 degrades, the node's real losses rising with its sent rate while its loops stay under 75 % busy, and neither host counts a drop. **H-host:** the subscriber host's counters rise with the losses, so the limit is the receiver and the step is the harness's. **H-event:** a step past 56 passes, so the burst at 56 was an event, not a limit. **H-knee:** the demultiplexed lane degrades again at 48, give or take a step, with neither host dropping. **Reported:** per step, the node's counters as in the table above, the subscriber host's drops, and the onset of any loss burst at 15 s.

### The slot: on three threads the passthrough lane carries 80 subscribers, 2.16 Gb/s, and degrades at 96 with its loops 84 % busy

On the subscriber host with 64 GB. A first run on the 15 GB host passed the same steps through 64 and was void at 72, the kernel killing five subscribers for memory. The node's columns are per second over the window.

| N | Received per subscriber, of step 1's (lowest) | Host CPU | Join (s) | Skips, common / single | Sent (Gb/s) | Loops busy | Busiest CPU | Losses, real / spurious | Pacer lagged | Step |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % | 1.1 % | 0.16 | 0 / 0 | 0.05 | 3 % | 5 % | 0 / 0 | 0 | pass |
| 24 | 99.9 % | 11.1 % | 0.76 | 0 / 0 | 0.67 | 24 % | 23 % | 0.2 / 2.1 | 0 | pass |
| 48 | 99.96 % | 23.0 % | 0.67 | 0 / 0 | 1.31 | 43 % | 41 % | 12 / 15 | 0.1 | pass |
| 56 | 99.98 % | 27.9 % | 0.82 | 0 / 0 | 1.52 | 49 % | 47 % | 22 / 19 | 0.5 | pass |
| 64 | 99.97 % | 32.6 % | 0.90 | 0 / 4 | 1.73 | 57 % | 52 % | 31 / 15 | 11 | pass |
| 72 | 99.98 % | 37.1 % | 0.64 | 0 / 7 | 1.94 | 64 % | 58 % | 45 / 44 | 96 | pass |
| 80 | 99.96 % | 41.6 % | 0.59 | 0 / 14 | 2.16 | 70 % | 63 % | 59 / 56 | 231 | pass |
| 96 | 99.79 % | 49.5 % | 0.87 | 0 / 250 | 2.59 | 84 % | 77 % | 129 / 14 | 1,406 | **degraded** |

At 96 a graded subscriber recorded continuity errors and PCR intervals up to 360 ms; no session ended and no join failed. The subscriber host stayed under 50 % CPU and at 2.6 of its 12.5 Gb/s with no drop counted, and the publisher held 25.00 Mb/s in every minute, so the knee is the relay's by the criteria. There the node's pacer timer lagged six times as often as at 80, and its RTT rose from 14 to 30 ms.

- **H-path fails.** Every step from 56 to 80 passes, the node sending up to 2.16 Gb/s with real losses under 60 a second and neither host dropping.
- **H-event holds, and the event was ours.** The burst at 56 on 10 November was the subscriber host's memory (_Corrections_), not the node's or the path's; H-host holds for it by memory rather than by the drop counters, which on 64 GB stayed at zero throughout.

### The slot: on three threads the demultiplexed lane carries 64 subscribers, 1.68 Gb/s, and the subscriber host's CPU ends the ramp at 72

On the same host. A first run ended at 2 subscribers on the source: the feed's timestamps stepped back 16,845 s unflagged ([Evidence](evidence.md) §3.13), the publisher republished, and the exports, run without `--stitch`, ended. The rerun's schedule went on past 56 to 80, fixed before it ran.

| N | Received per subscriber, of step 1's (lowest) | Host CPU | Join (s) | Skips, common / single | Sent (Gb/s) | Loops busy | Busiest CPU | Losses, real / spurious | Pacer lagged | Step |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 100.0 % (25.34 Mb/s) | 0.9 % | 2.07 | 0 / 0 | 0.03 | 2 % | 4 % | 0 / 0 | 120 | pass |
| 2, 4, 8 | 99.93–100.06 % | 1.7–6.5 % | 1.17–2.27 | 0 / 0 | 0.05–0.21 | 3–8 % | 4–9 % | 0 / 0–2 | 157–693 | pass |
| 16 | 99.84 % | 13.8 % | 1.35 | 0 / 0 | 0.42 | 14 % | 16 % | 2.6 / 9.9 | 1,439 | pass |
| 24 | 99.91 % | 21.3 % | 2.33 | 0 / 0 | 0.63 | 19 % | 19 % | 16 / 216 | 1,896 | pass |
| 32 | 100.2 % | 29.6 % | 2.10 | 0 / 0 | 0.84 | 24 % | 24 % | 99 / 521 | 2,738 | pass |
| 40 | 100.0 % | 40.3 % | 1.41 | 0 / 3 | 1.05 | 31 % | 29 % | 136 / 380 | 4,511 | pass |
| 48 | 99.76 % | 51.0 % | 2.10 | 0 / 6 | 1.25 | 38 % | 34 % | 95 / 245 | 6,521 | pass |
| 56 | 99.86 % | 60.0 % | 1.82 | 0 / 14 | 1.46 | 41 % | 39 % | 126 / 464 | 7,152 | pass |
| 64 | 99.83 % | 69.1 % | 1.53 | 0 / 28 | 1.68 | 47 % | 44 % | 422 / 715 | 8,982 | pass |
| 72 | 99.86 % | **76.9 %** | 1.35 | 2 / 84 | 1.88 | 52 % | 43 % | 688 / 634 | 10,821 | **void** |

The graded subscribers recorded no continuity error and no PCR interval over 40 ms at any step; no session ended, no join failed, the subscriber host dropped nothing and the publisher held 25.00–25.05 Mb/s in every minute. At 72 two video groups were skipped in common, at 65 and 38 subscribers, with the host 76.9 % busy, past the 70 % its knee rule allows, so the ramp ended at the harness's limit and the lane's knee on three threads lies beyond 64. On the way the node's real losses rose from about 100 a second through 56 to 422 at 64, its RTT from 11 to 18 ms and the single skips from 3 to 28, its loops under half busy; at 48 the passthrough lane cost it 12 real losses and 0.1 pacer lags a second, this lane 95 and 6,521.

- **H-knee fails.** The lane passes 48 and 56, where it was to degrade again: its degradation at 48 in the pre-test was the subscriber host's memory (_Corrections_).

## Corrections

- **The ramp's in-flight delivery rule read output bytes.** We counted each subscriber's `wchar`, as F5 did. On the demultiplexed lane the export writes its constant rate in stuffing whatever arrives, so output held 100 % at 40 subscribers while the host received 83 % per subscriber; the demultiplexed ramp is graded from the host's received rate. `rchar`, tried next, reads zero, since a QUIC subscriber receives by `recvmsg`; the rig now counts each subscriber's socket in the firewall. Rule: a receiver that restores a constant rate cannot report delivery by what it writes ([method notes](method-notes.md) §2).
- **Two of the three-thread node's knees were the subscriber host's memory.** We read the demultiplexed lane's degradation at 48 as the relay's and the passthrough lane's at 56 as beyond the node's host, the subscriber host under 51 % CPU and half its network rate. Each subscriber held about 250 MB of the host's 15 GB, and in those steps its free memory fell to 14 MB and 4 MB, the kernel killing four sessions; the harness's memory stop, checked between steps, never fired. Both steps are void. The slot's ramps ran on a host of the same CPU with 64 GB. Rule: every resource of a load generator bounds the step it carries ([method notes](method-notes.md) §5).
- **The node's sent rate summed its interfaces.** The ramp's table first read every interface but loopback. moqx runs in a container on this node, so its bridge and veth carry copies of the traffic, 0.06–0.07 Gb/s above what the node sent. The column now reads `eth0`; the 48-subscriber row, whose window the counters cannot place, is its reading less 0.07. Rule: on a containerised host, read the physical interface.
