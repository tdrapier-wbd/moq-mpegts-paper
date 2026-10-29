# Test 62 — Permanence of the single-CDN design: 72 h through one origin group (P1-aj)

**State: running, to 10-29 (72 h).**

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
