# Test 62 — Permanence of the single-CDN design: 72 h through one origin group (P1-aj)

**State: run, 72 h. C1 and C3–C6 hold; C2 fails on six losses common to both pathways, each
from damage in the contribution. For the last 43 h the wire's PTS sat 4.7 h from its PCR, which no
criterion graded.**

## Objective

*Permanent operation* reads *unknown* for the segmented lane ([Comparison](../docs/comparison.md)
§13.1): every figure it has rests on runs of minutes. P1-aj asks for 72 h of the chain through
CloudFront, across a PTS wrap. Its subject is the design the author has chosen and
[T61](test-61-origin-group-failover.md) grades by failure class: two interchangeable origins in one
origin group, two aligned receivers of the one distribution, merged by ST 2022-7. Nothing is
injected; what a healthy chain does over three days, unattended, is the question.

## Environment

T61's rig, with the receivers T63's follow-up graded: both pathways (epoch-locked segmenter with
T61's reset fix, dating each segment by `--pdt`; staleness guard; nginx) on the primary (A, the
group's primary) and the secondary (B); one distribution, `/g/*` and `/h/*` on the group. Both
receivers on the tertiary, groomer `0c7a5ba`, `--align-ms 30000`, each releasing on the date with
a 1.5 s hold, leg B joining 20 s after leg A. Leg A reads `/g/` at the edge its resolver gives (a
Dublin PoP); leg B reads `/h/`, pinned to a Düsseldorf PoP by its namespace's `hosts` file, so the
two legs share neither an edge nor a cache key. On the tertiary,
[`p1aj-soak.sh`](scripts/p1aj-soak.sh) merges the two legs live
([`p1aj-merge.py`](scripts/p1aj-merge.py), 450 ms) and grades the merged wire in flight with
[`t21-pcr-monitor.py`](scripts/t21-pcr-monitor.py) and `tsp -P continuity`; nothing is stored but
logs and counters. [`p1aj-sample.sh`](scripts/p1aj-sample.sh) records every role's memory and CPU
each minute, on all three hosts. The pathways' processes are niced and share the hosts with T57's
taps; their start and stop are logged so that T57 can attribute a step to them.

## Pass criteria, fixed before running

1. **Void** if the run ends before 72 h for a cause outside the chain (a host stopped, the rig
   broken); a cause inside it is a result.
2. **C1, the merged wire:** in every minute, 0 PCR intervals over 40 ms and 0 continuity errors,
   except minutes attributed to damage in the contribution that both pathways' segmenters saw (a
   reset on both at the same content). Each exception is listed with its attribution.
3. **C2, the merge:** 0 datagrams lost and 0 mismatched over the run; each leg's own losses
   reported with their causes.
4. **C3, the skew:** within 450 ms throughout; its hourly median and drift reported.
5. **C4, resources:** every role's memory grows slower than F2's exhaustion rate, T21's bar
   (1.60 MB/h on these 15–16 GB hosts), by a least-squares slope over the run.
6. **C5, events traced:** every segmenter reset, guard withdrawal, origin failover, receiver retry,
   loss or playlist failure, and groomer stall, mute or late drop has a cause in the logs.
7. **C6, the wrap:** across each PTS wrap the segment numbering stays consecutive (no reset, no
   gap) on both pathways, and C1 holds in the minutes around it.

## Limits

- One feed, one distribution, both receivers on one host, at two edges. Leg B is pinned to one
  edge address, which CloudFront may withdraw during the run; leg B's losses would then have that
  cause, and the merge is graded through them.
- The legs never restart, so the release sets their phase once; how its hold tracks the feed's
  clock against the host's over 72 h is read from the receivers' held and late times, not graded.
- No failure is injected: T61 covers the failure classes, briefly; this covers duration.
- A failover the run happens to contain is graded under C2 and C5, but its occurrence is not
  controlled.
- No criterion grades PTS against PCR; the capture that did is 8 s of each leg, once.
- Unattended upgrades replaced nginx on both origins during the run. The pathways' nginx, started
  by hand, ran the old binary throughout, so an origin restarted by its package manager is untested.
  On the secondary the sampler's pattern also matched the host's own nginx, which the upgrade
  restarted; the pathway's three processes ran unchanged.

## Results

*Graded by [`t62-grade.py`](scripts/t62-grade.py) from the three hosts' logs; hours from the soak's
start.*

| Criterion | Result | |
|---|---|---|
| Void | 72.0 h, every process up throughout | not void |
| C1, the merged wire | 7 of 4,321 minutes with a PCR interval over 40 ms or a continuity error, and `tsp`'s 67 reports in 6 bursts, all in the six windows of a reset both segmenters made | holds |
| C2, the merge | 134,047 datagrams lost (54 s of programme), all in those six windows; 0 mismatched, 0 late | **fails** |
| C3, the skew | −1.1 to +0.6 ms; hourly medians −0.1 to 0.0 ms; no drift | holds |
| C4, resources | steepest +0.34 MB/h (a receiver, 50.0 to 67.6 MB); every other role ≤ +0.02 MB/h | holds |
| C5, events | every event traced (below) | holds |
| C6, the wrap | four PTS wraps (0.8, 27.3, 32.0 and 58.5 h; the splice moved the third), numbering consecutive on both pathways, no reset and no C1 minute within 5 min | holds |

**Six resets, common to both pathways.** At 29.34 h the contribution splice graded in
[T34](test-34-real-encoder-severity.md) (PCR and every PTS back 16,844.6 s, unflagged) reached both
segmenters as a continuity break on the video PID in the same second. Five more breaks did the
same, at 41.23, 41.46, 47.80 and 52.18 h on the video PID and at 52.22 h on two others. The
contribution's SRT link lost nothing in those minutes, though each five-minute count holding a
break was 96–1,139 packets short of an unbroken one's 712,386: the damage was a gap in what reached
the link. Each time both segmenters withdrew their playlists until a window of intact segments was
cut again, as designed ([T61](test-61-origin-group-failover.md)). The receivers met 404 for
12.9–16.0 s, the origin group failed over to the secondary on the primary's 404 and met 404 there
too, each groomer stalled and muted, and the merge lost 5.9–11.5 s of programme each time. Neither
leg could cover the other. C2 has no exception for common damage, where C1 does, so it fails as
written. Each leg's own losses, which the merge covered from the other, were leg B's 20 s later
join and 1,105–1,857 datagrams in each window (6,007 of leg A's in one).

**The origins stayed interchangeable.** Both cut the same 129,640 segments, each identical in size
and SHA-1, and neither cut one the other did not. On these breaks the withdrawal therefore protected
no difference between the pathways and cost 6–12 s each. Whether a damaged segment would have been
identical on both is not measured, since neither published one.

**The groomer's clock after the splice.** Each leg re-based once, at the splice, on `0c7a5ba`,
whose re-base leaves the emitted PCR on the old time base ([T65](test-65-ird-hls-profile.md)). A
passive capture of each leg's RTP for 8 s at 68 h found every elementary stream's PTS
16,841.2–16,842.5 s behind the emitted PCR, alike on both legs. C1 grades PCR intervals and
continuity, not PTS against PCR, so it holds on a wire whose frames, for its last 43 h, were 4.7 h
late on the clock a decoder recovers from it. What an IRD does with that is not tested. `97f3a38`
fixes the re-base (T65) and has not been soaked.

**Unforced failovers.** Of 517,464 fetches, seven waited about 1 s longer than their edge's usual
7–70 ms for a first byte, the length of one TCP retransmission timeout. In five the edge's 1 s
origin timeout fired and the secondary served the request, which the primary never logged (four at
leg B's edge, one at leg A's); in two the primary served it a second late. None cost the merged wire
a datagram. No guard withdrew a pathway and no origin was acted on. Every request without the origin
header, 92 at each origin, was refused.

**The release held its phase.** Each leg kept one edge throughout, leg B its pinned one. Each leg's
hourly median hold stayed within 845–957 ms (A) and 634–694 ms (B), its first and last hours
within 20 ms of each other. Outside the reset windows, 104 of leg A's segments and 436 of leg B's
arrived after their release time, by up to 2.3 s, mostly at the same moments on both legs; no
groomer counter moved for them.

**Running cost**, mean over the run, one 26 Mb/s feed:

| Host | Role | Memory | CPU, % of a core |
|---|---|---|---|
| each origin | segmenter | 30 to 31 MB | 2.8–3.0 |
| | nginx; guard | 5 MB; 14 MB | ≤ 0.1; 0.0 |
| receiver host | receiver, per leg | up to 50 to 68 MB | 0.9 |
| | groomer, per leg | 40 MB | 5.7 |
| | merge; the two monitors | 25 to 30 MB; 15 and 50 MB | 3.8; 1.1 |

## Conclusions

1. **Over 72 h the single-CDN design added no failure of its own.** Every loss, stall and failover
   traces to the contribution or to one TCP retransmission at an edge; memory is flat, the skew
   within ±1.1 ms, four PTS wraps crossed cleanly, and the origins stayed byte-identical.
2. **Its availability is set by the segmenter's withdrawal rule, not by its redundancy.** Six
   continuity breaks in the contribution cost 54 s of programme (99.98 % of the run delivered), on
   both pathways at once, so 1+1 covered none of it. The rule is this rig's, not segmented HTTP's;
   one that withdraws only a pathway whose segments differ from its peer's is untested.
3. **The groomer soaked carried a wrong clock for its last 43 h**, which no criterion graded. A soak
   of `97f3a38` grading PTS against PCR on the merged wire would discharge it.
4. 72 h is short of the 7 days *Permanent operation* asks ([Comparison](../docs/comparison.md)
   §13.1).
