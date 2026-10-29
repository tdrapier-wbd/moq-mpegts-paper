# Test 60 — Aligned leg start: two segmented legs that join apart, in phase

**State: run (46 trials). H1 holds on one pathway and fails across two, by one trial of ten. The
follow-up's H5 and H6 fail: an uncached playlist narrows the residual but does not bound it,
which leaves a common time reference at the origin ([T63](test-63-pdt-anchored-release.md)).**

## Objective

[T59](test-59-segmented-1plus1-cloudfront.md) found the one gap between its segmented pair and a
standard ST 2022-7 receiver: each stream-clocked leg's phase is fixed when it starts, by the age of
the newest content it holds at that moment, so two legs that join a 24/7 feed apart sit anywhere
within about ±1.5 s of each other, and a Class C receiver's 450 ms covered two starts of seven.
P1-ai asks for legs whose start fixes their skew. This test grades the groomer's opt-in alignment
(`mpegts-pacer --align-ms`): a leg watches its input for a window before starting and ties its
clock to the content that arrived soonest after its stream position, plus the release latency.
That is a property of the path's fastest delivery, which every receiver of the stream sees, rather
than of the moment the leg joined.

The single-CDN design the author has chosen (two receivers of one distribution, merged by 2022-7)
needs it, and so does T59's two-pathway design; both are graded.

## Hypotheses, fixed before running

- **H1.** Aligned legs started apart are within 450 ms of each other in every trial, on one pathway
  and across two.
- **H2.** The skew is constant within a trial and does not depend on when either leg joined.
- **H3.** Alignment leaves identity untouched: aligned legs match on every datagram both carry.
- **H4 (the control).** Unaligned legs on the same rig, in the same session, spread past 450 ms,
  as T59's did.

## Environment

T59's rig, rebuilt: the live feed, a packager and nginx origin per pathway on the primary (A) and
the secondary (B), one CloudFront distribution with an origin per pathway, both receivers on the
tertiary in their own network namespaces (`b8-hls-recv.py`, 250 ms playlist poll; CloudFront holds
the playlist 1 s). Groomer `mpegts-pacer` `2eea651` at 26 Mb/s, latency 8 s, cap 14 s, stall 1 s
then mute, `--align-ms 30000` for aligned trials. Both legs recorded from their sockets into one
pcap on one clock.

## Procedure

Each trial: the recorder starts; leg A's receiver starts; leg B's starts a random 3–25 s later; once
both legs have emitted for at least 15 s, the legs are killed and the recorder stopped. The skew is
the median, over datagrams both legs carry under the same RTP sequence and timestamp, of B's arrival
minus A's ([`t60-skew.py`](scripts/t60-skew.py)); identity is whether those datagrams' payloads are
equal. Three arms, interleaved:

| Arm | Legs | Trials |
|---|---|---|
| `same` | both on pathway A (one distribution path, as the single-CDN design) | 10 |
| `cross` | A on pathway A, B on pathway B (T59's design) | 10 |
| `control` | `cross` without `--align-ms` | 6 |

## Pass criteria, fixed before running

1. **Void** unless, in each trial, both legs emit for at least 15 s together and CloudFront answers
   both receivers. A void trial is re-run, not graded.
2. **H1:** |skew| < 450 ms in every `same` and `cross` trial. Reported beside it: the distribution
   per arm, and how many fall within 50 ms (a Class B receiver's window).
3. **H2:** the skew's spread within a trial (5th to 95th percentile) under 50 ms; and no correlation
   between skew and the join offset worth stating (reported as the rank correlation).
4. **H3:** 0 mismatched payloads at equal numbers in every aligned trial.
5. **H4:** at least one `control` trial with |skew| ≥ 450 ms; otherwise the control did not
   discriminate on this run, which is reported, and H1 stands on T59's control alone.

Reported, not graded: each leg's `align_gain_us` (how much faster a later delivery was than the one
it started on).

## Limits

- Both receivers on one host and one clock: the phase is a property of each leg's path, not of a
  host clock, so two hosts should behave the same, but that is reasoned, not measured.
- Both receivers reach CloudFront through the same edge, so `same` shares the edge's playlist cache;
  receivers at different edges see independent caches.
- Short trials: the skew's stability over hours is the soak's question (P1-aj).

## Results

All 26 trials valid: both legs emitted together for 25–33 s in each, every receiver answered.
Skew is B's arrival less A's at equal RTP numbers, in milliseconds.

| Arm | Trials | Skew, sorted | Within 50 ms | ≥ 450 ms | Largest spread (p05–p95) | Mismatched | ρ(skew, join offset) |
|---|---|---|---|---|---|---|---|
| `same` | 10 | −9.9, 1.0, 5.1, 5.5, 11.0, 18.3, 28.2, 33.6, 36.2, 37.3 | 10 | 0 | 2.2 | 0 | 0.32 |
| `cross` | 10 | −202.0, −104.6, 33.3, 35.2, 52.9, 59.6, 62.2, 125.5, 142.8, 471.9 | 2 | 1 | 2.2 | 0 | 0.56 |
| `control` | 6 | 46.8, 49.3, 183.9, 219.5, 1,083.6, 1,201.2 | 2 | 2 | 2.2 | 0 | −0.26 |

- **H1 holds on one pathway and fails across two.** Every `same` trial fell within a Class B
  receiver's 50 ms, joins 3–24 s apart; one `cross` trial of ten fell outside 450 ms (471.9 ms), so
  the criterion as fixed fails there. The 50 ms is this rig's, not a bound: on one path of T61's
  rig, two cells of six reached 228 and 232 ms.
- **H2 holds.** Within a trial the skew is constant to 2.2 ms in every arm. Neither arm's skew
  tracks the join offset to a degree ten trials can separate from none (ρ 0.32 and 0.56).
- **H3 holds:** 0 mismatched payloads in 2.0 million datagrams compared, all arms.
- **H4 holds:** unaligned, two trials of six exceeded 450 ms (1.08 and 1.20 s), on this rig and
  session.

**What sets the residual is how each leg's window samples its path's delivery.** A leg ties its
clock to the soonest delivery in its 30 s window. A delivery is the playlist's visibility (up to
the cache's second plus the 250 ms poll) plus the segment's fetch and its hand-off to the groomer,
and all of them vary per request.
The hosts' packagers published within 3 ms of each other on every segment the epoch-locked
segmenter cut ([T61](test-61-origin-group-failover.md) § *Before the cells*), so the paths'
delivery separates the legs, not their content. In `same` both legs read one cached playlist and
one edge's cached segments; in `cross` each reads its own. Within these short trials neither leg
saw a delivery much faster than its window's (`align_gain_us` 0 in all but six aligned trials, at
most 34 ms there); over T61's 300 s cells later deliveries beat the window's by up to 293 ms, so a
window does not find its path's floor. The follow-up separates the cache's part.

## Follow-up: the edge cache, fixed before running

Two arms of ten on T61's rig: both legs read one origin group's epoch-locked segments (identical
on both origins), under two paths CloudFront caches apart. `g-h`: the playlist cached 1 s, as in
the arms above. `y-z`: `Cache-Control: max-age=0`, so the edge revalidates every playlist request
at the origin. Same procedure and grader.

1. **H5:** if the residual is the cache's phase, `g-h` spreads as `cross` did (one trial or more
   past 100 ms), and `y-z` holds within 100 ms in every trial.
2. **H6, the design's bound:** `y-z` within 50 ms in at least eight of ten trials. If it holds, an
   uncached playlist is the setting that lets receivers at different edges merge at Class B; if
   not, the bound needs a common time reference at the origin.

### Follow-up results

All 20 trials valid: both legs emitted together for 31.6–33.5 s in each. The legs reached the same
edge location, each path a miss there.

| Arm | Trials | Skew, sorted | Within 50 ms | Past 100 ms | ≥ 450 ms | Largest spread | Mismatched | ρ |
|---|---|---|---|---|---|---|---|---|
| `g-h` | 10 | −132.7, −87.6, −59.6, −47.3, −28.8, 33.2, 37.5, 145.5, 148.1, 512.8 | 4 | 4 | 1 | 2.2 | 0 | 0.59 |
| `y-z` | 10 | −96.6, 7.8, 14.5, 21.9, 33.2, 59.5, 86.0, 87.3, 105.3, 168.2 | 4 | 2 | 0 | 2.3 | 0 | 0.56 |

- **H5 fails.** `g-h` spread as predicted (four trials past 100 ms, one past a Class C receiver's
  450 ms on one edge), but `y-z` did not hold within 100 ms (105.3 and 168.2 ms). The cache's phase
  is one term: without it the largest skew fell from 513 to 168 ms.
- **H6 fails:** four `y-z` trials of ten within 50 ms. By the rule fixed beforehand, the bound needs
  a common time reference at the origin, which [T63](test-63-pdt-anchored-release.md) grades.
- Identity held: 0 mismatched payloads in 1.6 million datagrams compared.

**The other term is the segment's hand-off to the groomer.** On the uncached path every playlist
read reached the origin, and each new segment was visible to a leg 10–260 ms after it was
published. Fetching it, a miss each time, took 15–53 ms; the groomer then took it in at about
12 MB/s, a further 0.25–0.75 s in proportion to its size ([T63](test-63-pdt-anchored-release.md)).
A leg's window holds about 14 deliveries, and two windows' soonest differ by that variation, at
one edge or several.

## Corrections

**The segment's "transfer" was the groomer's ingest.** This file first read the 0.3–0.7 s between
a segment's appearance in the playlist and its logged delivery as CloudFront's transfer. The
receiver logs a segment after writing it to the groomer, and the groomer took input a packet per
read at about 12 MB/s; CloudFront's own fetch (the log's `ms`) took 15–53 ms. Both arms' residuals
include that ingest, so H5 and H6 were graded on a slower groomer than the one now under test.
Rule: a time read from a receiver's log brackets every step between the two log points, including
the consumer it writes to; take the fetch from the fetch's own timer, and time the hand-off
separately.
