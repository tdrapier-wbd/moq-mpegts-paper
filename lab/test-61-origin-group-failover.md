# Test 61 — Source protection at the CDN: interchangeable origins in one CloudFront origin group

**State: run (six cells); every criterion holds in every cell. No failure confined to the
primary's pathway left a hole in either receiver or the merge, and none kept a receiver waiting
longer than 5.2 s.**

## Objective

[T59](test-59-segmented-1plus1-cloudfront.md) protected the segmented lane as a broadcaster
would: two pathways end to end, each its own packager, origin and path through the CDN, merged by
ST 2022-7 at the receiver. The design under test here moves the source protection into the CDN,
where CDNs already provide it: two origins in one origin group, which CloudFront fails over per
request on an error status, a refused connection or a timeout. Downstream, two receivers of the one
distribution are still merged by 2022-7 for the last mile, with
[T60](test-60-aligned-leg-start.md)'s alignment.

Per-request failover is only invisible if the two origins are interchangeable: a viewer may take
the playlist from one and the next segment from the other, and an edge caches whichever answered.
T59's packagers were not (each named and numbered its segments from when it started), and T59 found
the other half of the problem: an origin whose packager stopped goes on serving its last playlist
with a 200, which no CDN fails over from. Two pieces are built for this test:

- an epoch-locked segmenter ([`t61-epochseg.py`](scripts/t61-epochseg.py)): each segment starts at
  the first random-access point at or after a multiple of D of content time and is named and
  numbered by that multiple, so packagers that join apart publish the same objects. It publishes
  only while it holds a full window of intact segments, so a pathway that has just joined or lost
  input answers 404 rather than a window its peer does not share;
- a staleness guard ([`t61-guard.py`](scripts/t61-guard.py)), a separate process that withdraws a
  playlist that has stopped advancing, so the origin answers 404 and the group fails over.

## Hypotheses, fixed before running

- **H1 (interchangeable).** Two packagers that join apart cut every segment they share identically:
  name, duration and bytes.
- **H2 (protection).** No failure confined to the primary origin's pathway (its packager dies or
  freezes; its origin refuses, hangs or becomes unreachable) leaves a hole in either receiver's
  output, and nor does the primary's return.
- **H3 (bounded).** The longest a receiver waits for a new segment through any of those failures
  stays inside the groomer's latency.
- **H4 (merge).** The two receivers' legs stay identical and in phase through each failure, and the
  2022-7 merge loses nothing.

## Environment

T60's rig. A pathway is the segmenter (D = 2 s, six segments listed, three more kept, target
duration 4 s), the guard (4 s) and T59's nginx origin, on the primary (pathway A, the group's
primary) and the secondary (B), each reading its host's copy of the live feed. The guard's 4 s
exceeds the longest cut interval the grid allows (D plus the feed's longest random-access spacing,
1.2 s): any less would withdraw both origins' playlists together on a long interval, since both cut
at the same content. CloudFront: one distribution, `/g/*` on the origin group (A, failing over to B
on 404, 500, 502, 503 or 504), one connection attempt, 1 s connection and response timeouts (the
minimums), playlist cached 1 s and segments 60 s. Both receivers on the tertiary, on `/g/`, groomer
`2eea651` at 26 Mb/s, latency 8 s, cap 14 s, `--align-ms 30000`.

## Procedure

One cell per failure, by [`t59-cell.sh`](scripts/t59-cell.sh) with `LEG_PATH=g`: leg A's receiver
at 0 s, leg B's at 20 s, the failure on pathway A at 120 s, restored at 150 s, 300 s per cell,
graded by [`t59-grade.sh`](scripts/t59-grade.sh) (merge at 450 ms; each leg's holes; continuity of
the merged output) and [`t61-report.py`](scripts/t61-report.py) (each receiver's longest wait for a
new segment; which origin served `/g/` when, from both origins' access logs).

| Cell | At 120 s, on A | At 150 s | What CloudFront should see |
|---|---|---|---|
| `clean` | nothing | | |
| `seg-kill` | packager killed | restarted | the guard's 404 |
| `seg-freeze` | packager stopped (SIGSTOP) | resumed | the guard's 404; on resuming, the packager's overflowed input resets it |
| `origin-down` | nginx stopped | started | a refused connection |
| `ngx-hang` | nginx stopped (SIGSTOP), listening | resumed | a response timeout |
| `block` | the origin port drops every packet | reopened | a connection timeout |

Identity across hosts is graded on the two segmenters' logs over the whole session. Each failure is
issued over an SSH connection opened when the cell starts, so it lands within a fraction of a
second of its time.

## Pass criteria, fixed before running

1. **Void** unless both legs emit from 60 s to the tail and the failure landed at 120 ± 2 s.
2. **H1:** every segment both segmenters cut in the session is identical in duration, size and
   hash; 0 mismatched datagrams between legs in every cell.
3. **H2:** in every cell, each leg 0 holes and 0 lost segments, and the merged output 0 lost and 0
   continuity errors to the tail.
4. **H3:** each leg's longest wait between new segments under 8 s (the groomer's latency) in every
   cell; reported beside it, the failover onset (A's last `/g/` answer to B's first) and the
   failback (restoration to A's first `/g/` answer).
5. **H4:** |skew| < 450 ms in every cell, with its 5th–95th percentile spread under 50 ms.
6. **Failback:** A serves `/g/` again within 60 s of its restoration.

## Limits

- One failure at a time, always on the primary. A failure common to both origins (the feed itself)
  is an outage this design does not address, nor is a failure of the CDN: the author's scope is one
  CDN.
- Both receivers on one host, at one edge.
- While the primary is unreachable, every miss pays its timeout before failing over: 1 s here.
- An encoder timestamp discontinuity is not exercised. A backward jump resets both packagers (an
  outage of one window, 12 s); a forward one is a gap in the numbering both share.
- 30 s failures in 300 s cells: duration is the soak's question (P1-aj).

## Results

### Before the cells: identity across hosts

The two segmenters, started 3 s apart and run through every cell, cut 2,632 segments in common:
every one identical in duration, size and hash, written on the two hosts within 3 ms of each other,
each playlist within 4 ms. The segments only one host holds are those the other missed while its
packager was killed, frozen or restarted. Durations ran 0.92–3.04 s.

### The cells

*Groomer `2eea651`, graded from 60 s (leg B's settling) to the tail. Skew is B's arrival less A's
at equal RTP numbers, median and 5th–95th percentile. Failover onset: A's last `/g/` answer to B's
first. Failback: the restoration to A's first `/g/` answer.* Every cell's legs reached the same
CloudFront edge location.

| Cell | Failure at | Failover onset | Failback | Longest wait, A / B | Skew (ms) | Mismatched; holes; merged lost, CC |
|---|---|---|---|---|---|---|
| `clean` | — | — | — | 3.69 / 3.61 s | −47.7 (−48.6 to −46.6) | 0; 0; 0, 0 |
| `seg-kill` | 120.2 s | 4.22 s | 6.27 s | 5.21 / 5.20 s | 228.4 (227.5 to 229.2) | 0; 0; 0, 0 |
| `seg-freeze` | 120.2 s | 3.62 s | 2.78 s | 3.66 / 3.63 s | −14.3 (−15.4 to −13.1) | 0; 0; 0, 0 |
| `origin-down` | 120.7 s | 1.72 s | 0.77 s | 4.42 / 4.41 s | 232.5 (231.7 to 233.2) | 0; 0; 0, 0 |
| `ngx-hang` | 121–122 s | 1.23 s | 0.00 s | 3.54 / 3.55 s | −7.8 (−8.9 to −7.0) | 0; 0; 0, 0 |
| `block` | 121–122 s | 1.11 s | 0.20 s | 4.26 / 4.26 s | 43.1 (41.9 to 44.2) | 0; 0; 0, 0 |

The first runs of `seg-kill`, `seg-freeze` and `origin-down` issued their failures over a fresh SSH
connection and landed up to 123.3 s in, outside criterion 1's 2 s; they were re-run, and are not
graded. Their outcomes were the same (0 lost, 0 holes, longest waits 3.6–4.8 s). The re-runs used
the segmenter with one change: a reset clears every stream's continuity state, so a discontinuity
resets it once rather than once per stream (the first `seg-freeze` reset it ten times in 0.6 s).

1. **H1 holds:** every segment the two hosts cut alike, and 0 mismatched datagrams in 3.8 million
   compared.
2. **H2 holds:** in every cell, 0 holes, 0 lost or retried segments, 0 playlist failures on either
   leg, and the merged output 0 lost and 0 continuity errors.
3. **H3 holds:** the longest wait for a new segment is 5.2 s, against the groomer's 8 s. Unfaulted,
   it is 3.5–3.7 s (the longest segment plus the playlist's second of caching). A failure the guard
   must detect (`seg-kill`, `seg-freeze`) added up to 1.5 s, by its 4 s threshold; a refused,
   hung or unreachable origin added at most 0.6 s, inside its 1 s timeout. T59's struck pathway
   lost 10.6–22 s.
4. **H4 holds:** |skew| ≤ 233 ms in every cell, with a 5th–95th percentile spread of at most
   2.3 ms over the cell, failure included.
5. **Failback holds:** A answered `/g/` again within 6.3 s of every restoration. After a packager
   restart its playlist stays withdrawn until a new window is whole, so B went on answering the
   playlist for 11.7–13.3 s.

**The skew on one path is not bounded at 50 ms.** Two cells of six exceeded a Class B receiver's
window (228 and 232 ms), though both legs read one playlist from one edge. Each leg's groomer reports
how much sooner than its starting point a later delivery came (`align_gain_us`). The difference
between the two legs' gains matched the skew to within 32 ms in eight of the nine cells run, void
runs included (in the two cells above, B gained 276–293 ms and A 47–75 ms). Each leg ties its clock to the soonest delivery
in its own 30 s window, and with a playlist cached 1 s and polled every 250 ms, one window's soonest
delivery can fall a quarter-second short of the path's. T60's follow-up grades the uncached
playlist against this.
