# Test 63 — Receivers at different edges, in phase: release on the origin's program date-time

**State: run, 20 trials and a follow-up of 20. In the first run H1 and H2 fail, H3 and H4 hold;
in the follow-up H5–H8 hold.** First run, release narrowed the skew between receivers at two edges
from a 639 ms range to 136 ms, but two trials of ten sat 86–87 ms apart: the groomer's own ingest,
slow and in proportion to segment size, set each leg's floor. With that ingest fast and the release
aimed at the last PCR, every released trial of ten sat within 1.1 ms, while the same edges
unreleased still spread to 379 ms.

## Objective

The single-CDN design merges two receivers of one distribution by ST 2022-7, and the author's
model puts them on different CDN edges so that an edge's failure is the last mile's, not the
service's. A 2022-7 merge needs the two legs within its window. [T60](test-60-aligned-leg-start.md)
and [T61](test-61-origin-group-failover.md) found that a leg aligned on its path's fastest delivery
does not get there: each leg ties its clock to the soonest segment in its own 30 s window, and a
segment's delivery (the playlist's visibility plus the segment's hand-off to the groomer) varies
per request and per edge, so two legs sat up to 472 ms apart across paths and up to 232 ms apart
on one.

The design under test removes delivery from the phase. Each origin's segmenter dates every segment
with `EXT-X-PROGRAM-DATE-TIME`, the wall-clock time of its first PCR
([`t61-epochseg.py --pdt`](scripts/t61-epochseg.py)): the PCR plus an offset each origin fixes from
its feed's soonest arrival, so the dates follow the content exactly and the two origins' differ by
their feed paths alone (T61 measured their writes within 3 ms). Each receiver
([`b8-hls-recv.py --release-ms`](scripts/b8-hls-recv.py)) holds every dated segment until its last
packet's multiplex time plus a fixed hold, computed from the segment's own PCRs, and only then hands
it to the groomer. Every on-time segment then reaches every groomer at the same instant, so the
groomer's existing alignment finds the same floor on every leg.

## Hypotheses, fixed before running

- **H1 (the design's bound).** Released legs at different edges are within a Class B receiver's
  50 ms of each other in every trial.
- **H2 (what is left).** Within 10 ms in at least eight trials of ten: the residual is the hosts'
  clocks, the origins' offsets and the pipe, not the path.
- **H3.** Release leaves identity untouched: 0 mismatched payloads at equal numbers.
- **H4 (the control).** Aligned legs at the same two edges without the release spread past 50 ms
  in at least one trial of ten.

## Environment

T61's rig: both origins in one origin group, each segmenter now with `--pdt` (offset settled over
2 s), the staleness guard, nginx. Both receivers on the tertiary, groomer `2eea651`, 26 Mb/s,
latency 8 s, cap 14 s, `--align-ms 30000`. Leg A reads `/g/` at the edge its resolver gives (a
Dublin PoP); leg B reads `/h/`, a path CloudFront caches apart, pinned to a Düsseldorf PoP by its
namespace's `hosts` file (connection 20 ms against Dublin's 1 ms). Every request's PoP is logged.

## Procedure

[T60](test-60-aligned-leg-start.md)'s trial and grader ([`t60-trials.sh`](scripts/t60-trials.sh),
[`t60-skew.py`](scripts/t60-skew.py)): leg A starts, leg B a random 3–25 s later, both emit together
for at least 20 s, skew is the median of B's arrival less A's at equal RTP numbers. Two arms of ten,
interleaved:

| Arm | Legs | Release |
|---|---|---|
| `x` | A on `/g/` at Dublin, B on `/h/` at Düsseldorf, aligned | none |
| `pdt-x` | the same | `--release-ms 1500` on both |

## Pass criteria, fixed before running

1. **Void** unless both legs emit together for at least 15 s and every request of leg B's was
   answered at Düsseldorf and every one of leg A's elsewhere. A void trial is re-run.
2. **H1:** |skew| < 50 ms in every `pdt-x` trial.
3. **H2:** |skew| < 10 ms in at least eight `pdt-x` trials.
4. **H3:** 0 mismatched payloads in every trial.
5. **H4:** at least one `x` trial with |skew| ≥ 50 ms; otherwise the control did not discriminate
   on this run, which is reported.

Reported, not graded: per arm, each leg's `align_gain_us`; under release, how many segments each
leg held and for how long, and how many arrived after their release time.

## Results

All 20 trials valid: both legs emitted together for 30.9–33.3 s in each, every request of leg A's
was answered at Dublin and every one of leg B's at Düsseldorf.

| Arm | Trials | Skew, ms, sorted | Within 50 ms | Within 10 ms | Largest spread (p05–p95), ms | Mismatched |
|---|---|---|---|---|---|---|
| `x` | 10 | −114.8, 30.1, 150.5, 170.5, 203.5, 227.3, 228.2, 334.4, 386.3, 523.9 | 1 | 0 | 2.2 | 0 |
| `pdt-x` | 10 | −48.6, −8.0, 5.6, 11.2, 13.3, 17.6, 20.9, 28.9, 86.2, 87.0 | 8 | 2 | 2.3 | 0 |

- **H1 fails:** two `pdt-x` trials of ten at 86.2 and 87.0 ms.
- **H2 fails:** two trials of ten within 10 ms.
- **H3 holds:** 0 mismatched payloads in 1.6 million datagrams compared.
- **H4 holds:** nine `x` trials of ten at 50 ms or more, the largest 523.9 ms.
- Under release, leg A held 33–42 segments a trial and had at most one arrive late (by up to
  138 ms); leg B, at the slower edge, held 27–32 and had one to five late (once by 1.0 s).
  `align_gain_us` was 0 on both legs in four `pdt-x` trials and at most 60 ms in the rest, against
  up to 408 ms under `x`.

**What was left is the groomer's ingest.** The groomer read its input a packet at a time, each
read a trip through its runtime's blocking pool, and took a segment in at 12.2–12.4 MB/s on the
receiver host, measured offline: 0.24 s for a 3 MB segment, 0.72 s for an 8.8 MB one. A released
segment's last packet therefore reached the groomer that long after the release, and each leg's
window settled on its smallest on-time segment rather than on the release. Leg B's small segments
were the ones late (30 of 91 under 4.5 MB, against 2 of 231 larger): a short segment's release
follows the previous one's soonest, and the receiver fetches it only after handing the previous
one on, from the farther edge. In the two trials past 50 ms, leg A's window held an on-time segment 0.73 and 0.91 MB smaller
than any leg B's did, 60–75 ms at that rate; at −48.6 ms the difference ran the other way
(1.32 MB). A second, smaller term: the release aimed a segment's last packet at the hold, but a
stream-clocked groomer places packets only up to the newest PCR it has seen, so the stretch after
a segment's last PCR (up to one PCR interval, 25 ms on this feed) did not count.

The same ingest stood in [T60](test-60-aligned-leg-start.md)'s "transfer" term: CloudFront's
fetches there took 15–53 ms, and the rest of what T60 attributed to transfer was the hand-off
(T60 § *Corrections*).

## Follow-up: a fast ingest and the last PCR, fixed before running

Two changes. The groomer reads its input 64 KiB at a time (`0c7a5ba`), which took the same
segments in at 400–495 MB/s offline on the receiver host (7 ms for 3 MB, 21 ms for 8.8 MB). The
receiver holds each segment until its last PCR's time plus the hold, not its last packet's, and
logs how long the groomer took to accept it (`write_ms`). Otherwise as above: the same edges, the
same 1.5 s hold, `x` and `pdt-x` interleaved, ten trials each, the same void rule.

1. **H5:** |skew| < 50 ms in every `pdt-x` trial.
2. **H6:** |skew| < 10 ms in at least eight `pdt-x` trials of ten.
3. **H7:** 0 mismatched payloads in every trial.
4. **H8 (the control):** at least one `x` trial with |skew| ≥ 50 ms; otherwise the control did
   not discriminate on this run, which is reported.

Reported, not graded: `write_ms` per leg; held and late segments; `align_gain_us`.

### Follow-up results

All 20 trials valid: both legs emitted together for 30.7–33.2 s in each, every request of leg A's
was answered at Dublin and every one of leg B's at Düsseldorf.

| Arm | Trials | Skew, ms, sorted | Within 50 ms | Within 10 ms | Largest spread (p05–p95), ms | Mismatched |
|---|---|---|---|---|---|---|
| `x` | 10 | −22.2, 14.4, 58.7, 130.8, 171.2, 192.9, 194.0, 205.9, 340.1, 378.9 | 2 | 0 | 2.3 | 0 |
| `pdt-x` | 10 | 0.0 (five trials), 0.1, 0.4, 0.7, 0.9, 1.1 | 10 | 10 | 2.2 | 0 |

- **H5 holds:** every `pdt-x` trial within 1.1 ms.
- **H6 holds:** ten trials of ten within 10 ms.
- **H7 holds:** 0 mismatched payloads in 1.58 million datagrams compared.
- **H8 holds:** eight `x` trials of ten at 50 ms or more, the largest 378.9 ms.
- The groomer accepted a segment in 14 ms at the median and 27 ms at most, on both legs and in
  both arms. Under release, leg A held 389 segments of 394 and leg B 322 of 324; the seven late
  ones (by up to 584 ms) set no floor, and `align_gain_us` was 0 on every released leg.

**With the hand-off fast, release puts receivers at different edges in phase to within the
recorder's resolution.** The unreleased arm still spread to 379 ms with the same fast groomer, so
the release, not the ingest, is what bounds the skew; the ingest only had to stop adding a
term of its own. The limits below stand: one host and one clock, a hold of 1.5 s added to the
delay, and a late segment's inability to set the floor.

## Limits

- Both receivers on one host, so one clock. Receivers on two hosts add their clocks' offset:
  chrony on Amazon Time Sync bounded two hosts' summed error at 2.1 ms in
  [T57](test-57-cross-host-timing.md); a plant without a disciplined clock gets no such bound.
- The hold adds to the end-to-end delay unless the groomer's latency is cut by as much; that
  trade is P1-ah's.
- A segment that arrives after its release time is handed on late and cannot set the floor; a hold
  shorter than the path's worst delivery during the alignment window weakens the bound.
- The date is multiplex time, not presentation time, so a player reading it as presentation time
  is off by the encoder's PTS lead.
