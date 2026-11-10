# Test 61 — Source protection at the CDN: interchangeable origins in one CloudFront origin group

**State: run (six cells); every criterion holds in every cell. No failure confined to the primary's pathway left a hole in either receiver or the merge, and none kept a receiver waiting longer than 5.2 s. With stock `tsp` receivers (P1-aq, seven cells) every criterion holds but one clause of H1: two segments the frozen primary cut differ, and no receiver got them. On its own path's 30 s cut, `tsp` rejoined at the live edge 10.2 s after the restoration.**

## Objective

[T59](test-59-segmented-1plus1-cloudfront.md) protected the segmented lane as a broadcaster would: two pathways end to end, each its own packager, origin and path through the CDN, merged by ST 2022-7 at the receiver. The design under test here moves the source protection into the CDN, where CDNs already provide it: two origins in one origin group, which CloudFront fails over per request on an error status, a refused connection or a timeout. Downstream, two receivers of the one distribution are still merged by 2022-7 for the last mile, with [T60](test-60-aligned-leg-start.md)'s alignment.

Per-request failover is only invisible if the two origins are interchangeable: a viewer may take the playlist from one and the next segment from the other, and an edge caches whichever answered. T59's packagers were not (each named and numbered its segments from when it started), and T59 found the other half of the problem: an origin whose packager stopped goes on serving its last playlist with a 200, which no CDN fails over from. Two pieces are built for this test:

- an epoch-locked segmenter ([`t61-epochseg.py`](scripts/t61-epochseg.py)): each segment starts at the first random-access point at or after a multiple of D of content time and is named and numbered by that multiple, so packagers that join apart publish the same objects. It publishes only while it holds a full window of intact segments, so a pathway that has just joined or lost input answers 404 rather than a window its peer does not share;
- a staleness guard ([`t61-guard.py`](scripts/t61-guard.py)), a separate process that withdraws a playlist that has stopped advancing, so the origin answers 404 and the group fails over.

## Hypotheses, fixed before running

- **H1 (interchangeable).** Two packagers that join apart cut every segment they share identically: name, duration and bytes.
- **H2 (protection).** No failure confined to the primary origin's pathway (its packager dies or freezes; its origin refuses, hangs or becomes unreachable) leaves a hole in either receiver's output, and nor does the primary's return.
- **H3 (bounded).** The longest a receiver waits for a new segment through any of those failures stays inside the groomer's latency.
- **H4 (merge).** The two receivers' legs stay identical and in phase through each failure, and the 2022-7 merge loses nothing.

## Environment

T60's rig. A pathway is the segmenter (D = 2 s, six segments listed, three more kept, target duration 4 s), the guard (4 s) and T59's nginx origin, on the primary (pathway A, the group's primary) and the secondary (B), each reading its host's copy of the live feed. The guard's 4 s exceeds the longest cut interval the grid allows (D plus the feed's longest random-access spacing, 1.2 s): any less would withdraw both origins' playlists together on a long interval, since both cut at the same content. CloudFront: one distribution, `/g/*` on the origin group (A, failing over to B on 404, 500, 502, 503 or 504), one connection attempt, 1 s connection and response timeouts (the minimums), playlist cached 1 s and segments 60 s. Both receivers on the tertiary, on `/g/`, groomer `2eea651` at 26 Mb/s, latency 8 s, cap 14 s, `--align-ms 30000`.

## Procedure

One cell per failure, by [`t59-cell.sh`](scripts/t59-cell.sh) with `LEG_PATH=g`: leg A's receiver at 0 s, leg B's at 20 s, the failure on pathway A at 120 s, restored at 150 s, 300 s per cell, graded by [`t59-grade.sh`](scripts/t59-grade.sh) (merge at 450 ms; each leg's holes; continuity of the merged output) and [`t61-report.py`](scripts/t61-report.py) (each receiver's longest wait for a new segment; which origin served `/g/` when, from both origins' access logs).

| Cell | At 120 s, on A | At 150 s | What CloudFront should see |
| --- | --- | --- | --- |
| `clean` | nothing |  |  |
| `seg-kill` | packager killed | restarted | the guard's 404 |
| `seg-freeze` | packager stopped (SIGSTOP) | resumed | the guard's 404; on resuming, the packager's overflowed input resets it |
| `origin-down` | nginx stopped | started | a refused connection |
| `ngx-hang` | nginx stopped (SIGSTOP), listening | resumed | a response timeout |
| `block` | the origin port drops every packet | reopened | a connection timeout |

Identity across hosts is graded on the two segmenters' logs over the whole session. Each failure is issued over an SSH connection opened when the cell starts, so it lands within a fraction of a second of its time.

## Pass criteria, fixed before running

1. **Void** unless both legs emit from 60 s to the tail and the failure landed at 120 ± 2 s.
2. **H1:** every segment both segmenters cut in the session is identical in duration, size and hash; 0 mismatched datagrams between legs in every cell.
3. **H2:** in every cell, each leg 0 holes and 0 lost segments, and the merged output 0 lost and 0 continuity errors to the tail.
4. **H3:** each leg's longest wait between new segments under 8 s (the groomer's latency) in every cell; reported beside it, the failover onset (A's last `/g/` answer to B's first) and the failback (restoration to A's first `/g/` answer).
5. **H4:** |skew| < 450 ms in every cell, with its 5th–95th percentile spread under 50 ms.
6. **Failback:** A serves `/g/` again within 60 s of its restoration.

## Limits

- One failure at a time, always on the primary. A failure common to both origins (the feed itself) is an outage this design does not address, nor is a failure of the CDN: the author's scope is one CDN.
- Both receivers on one host, at one edge.
- While the primary is unreachable, every miss pays its timeout before failing over: 1 s here.
- An encoder timestamp discontinuity is not exercised. A backward jump resets both packagers (an outage of one window, 12 s); a forward one is a gap in the numbering both share.
- 30 s failures in 300 s cells: duration is the soak's question (P1-aj).

## Results

### Before the cells: identity across hosts

The two segmenters, started 3 s apart and run through every cell, cut 2,632 segments in common: every one identical in duration, size and hash, written on the two hosts within 3 ms of each other, each playlist within 4 ms. The segments only one host holds are those the other missed while its packager was killed, frozen or restarted. Durations ran 0.92–3.04 s.

### The cells

_Groomer `2eea651`, graded from 60 s (leg B's settling) to the tail. Skew is B's arrival less A's at equal RTP numbers, median and 5th–95th percentile. Failover onset: A's last `/g/` answer to B's first. Failback: the restoration to A's first `/g/` answer._ Every cell's legs reached the same CloudFront edge location.

| Cell | Failure at | Failover onset | Failback | Longest wait, A / B | Skew (ms) | Mismatched; holes; merged lost, CC |
| --- | --- | --- | --- | --- | --- | --- |
| `clean` | — | — | — | 3.69 / 3.61 s | −47.7 (−48.6 to −46.6) | 0; 0; 0, 0 |
| `seg-kill` | 120.2 s | 4.22 s | 6.27 s | 5.21 / 5.20 s | 228.4 (227.5 to 229.2) | 0; 0; 0, 0 |
| `seg-freeze` | 120.2 s | 3.62 s | 2.78 s | 3.66 / 3.63 s | −14.3 (−15.4 to −13.1) | 0; 0; 0, 0 |
| `origin-down` | 120.7 s | 1.72 s | 0.77 s | 4.42 / 4.41 s | 232.5 (231.7 to 233.2) | 0; 0; 0, 0 |
| `ngx-hang` | 121–122 s | 1.23 s | 0.00 s | 3.54 / 3.55 s | −7.8 (−8.9 to −7.0) | 0; 0; 0, 0 |
| `block` | 121–122 s | 1.11 s | 0.20 s | 4.26 / 4.26 s | 43.1 (41.9 to 44.2) | 0; 0; 0, 0 |

The first runs of `seg-kill`, `seg-freeze` and `origin-down` issued their failures over a fresh SSH connection and landed up to 123.3 s in, outside criterion 1's 2 s; they were re-run, and are not graded. Their outcomes were the same (0 lost, 0 holes, longest waits 3.6–4.8 s). The re-runs used the segmenter with one change: a reset clears every stream's continuity state, so a discontinuity resets it once rather than once per stream (the first `seg-freeze` reset it ten times in 0.6 s).

1. **H1 holds:** every segment the two hosts cut alike, and 0 mismatched datagrams in 3.8 million compared.
2. **H2 holds:** in every cell, 0 holes, 0 lost or retried segments, 0 playlist failures on either leg, and the merged output 0 lost and 0 continuity errors.
3. **H3 holds:** the longest wait for a new segment is 5.2 s, against the groomer's 8 s. Unfaulted, it is 3.5–3.7 s (the longest segment plus the playlist's second of caching). A failure the guard must detect (`seg-kill`, `seg-freeze`) added up to 1.5 s, by its 4 s threshold; a refused, hung or unreachable origin added at most 0.6 s, inside its 1 s timeout. T59's struck pathway lost 10.6–22 s.
4. **H4 holds:** |skew| ≤ 233 ms in every cell, with a 5th–95th percentile spread of at most 2.3 ms over the cell, failure included.
5. **Failback holds:** A answered `/g/` again within 6.3 s of every restoration. After a packager restart its playlist stays withdrawn until a new window is whole, so B went on answering the playlist for 11.7–13.3 s.

**The skew on one path is not bounded at 50 ms.** Two cells of six exceeded a Class B receiver's window (228 and 232 ms), though both legs read one playlist from one edge. Each leg's groomer reports how much sooner than its starting point a later delivery came (`align_gain_us`). The difference between the two legs' gains matched the skew to within 32 ms in eight of the nine cells run, void runs included (in the two cells above, B gained 276–293 ms and A 47–75 ms). Each leg ties its clock to the soonest delivery in its own 30 s window, and with a playlist cached 1 s and polled every 250 ms, one window's soonest delivery can fall a quarter-second short of the path's. T60's follow-up grades the uncached playlist against this.

## Stock receivers behind the group (P1-aq), criteria fixed before running

[T6](test-6-relay-resilience.md) found no stock TS client that survives an origin restart, its clients facing the origin; behind the group, neither receiver above saw a failed fetch. P1-aq puts TSDuck's `tsp --realtime -I hls --live` in both legs' fetchers, each under [`p1aq-stock-recv.py`](scripts/p1aq-stock-recv.py), which restarts it a second after it exits and logs each burst of output as a segment (`B8=<it> P1AQ_FETCHER=tsp t61-cell.sh CELL`). GStreamer is left out: its HLS elements send the viewer key on the first playlist request only. The rest is the environment above. The six cells, and a seventh on one receiver's path:

| Cell | At 120 s | At 150 s | What CloudFront should see |
| --- | --- | --- | --- |
| `leg-cut` | leg A's namespace drops every packet, both ways | restored | nothing |

1. **Void** as criterion 1 above; `leg-cut` also unless the drop began at 120 ± 2 s and ended at 150 ± 2 s.
2. **The six cells, each leg and the merge:** criteria 2–4 above, a leg's lost segments read as its holes (the stock fetcher logs none), and its fetcher's exits reported beside them.
3. **`leg-cut`, the merge:** leg B 0 holes, and the merged output 0 lost and 0 continuity errors to the tail. Leg A's hole is reported.
4. **`leg-cut`, the rejoin** ([`p1aq-rejoin.py`](scripts/p1aq-rejoin.py)): A's first datagram after its gap that is identical to B's under the same RTP number comes within 30 s of the restoration, so the pair is left unprotected no longer than the cut again. From it to the tail, none of A's datagrams is mismatched or unpaired against B, and the skew meets criterion 5 above. Reported: how A came back (its fetcher's exit and restart, or the connection resuming) and the content it skipped. The grader's negative control is `clean`, where it must find no gap in A over 1 s.

_Predicted:_ the six cells pass as with B-8, since no failed fetch reaches a receiver behind the group. On `leg-cut`, `tsp` either exits on the stalled fetch and its restart rejoins at the live edge within seconds, or waits on the dead connection past the restoration.

### P1-aq results

_The environment above but for the segmenter, T76's (`--peer`: a segment cut across a continuity error is compared with the peer's and deleted if it differs), and the fetchers, TSDuck 3.44's `tsp`. Columns as in the table above._

| Cell | Failure at | Failover onset | Failback | Longest wait, A / B | Skew (ms) | Mismatched; holes; merged lost, CC |
| --- | --- | --- | --- | --- | --- | --- |
| `clean` | — | — | — | 4.51 / 2.92 s | −139.8 (−154.7 to −124.3) | 0; 0; 0, 0 |
| `seg-kill` | 120.1 s | 5.04 s | 7.04 s | 4.54 / 5.13 s | 448.3 (443.7 to 451.9) | 0; 0; 0, 0 |
| `seg-freeze` | 120.1 s | 3.50 s | 8.10 s | 4.76 / 5.75 s | 20.0 (14.0 to 25.8) | 0; 0; 0, 0 |
| `origin-down` | 120.6 s | 0.18 s | 0.00 s | 4.53 / 5.00 s | 339.3 (333.1 to 344.9) | 0; 0; 0, 0 |
| `ngx-hang` | 120.1 s | 1.46 s | 0.00 s | 4.54 / 4.80 s | 203.9 (181.4 to 227.4) | 0; 0; 0, 0 |
| `block` | 120.2 s | 1.33 s | 0.36 s | 4.54 / 5.03 s | 112.9 (66.1 to 158.2) | 0; 0; 0, 0 |
| `leg-cut` | 120.2–150.1 s | — | — | 34.85 / 3.41 s | 365.0 (342.3 to 387.3) | 0; A 32.8 s, B 0; 0, 0 |

No fetcher exited during any failure: each `tsp` ran from its start to the cell's stop. At the stop, leg B's `tsp` ignored SIGTERM in `seg-kill`, `seg-freeze` and `block`, and its supervisor, waiting on it, held the groomer's input open; both stayed alive, sending nothing, until killed after the last cell. Leg B's count in every capture (626,804–631,401 datagrams over 254–256 s) shows that none reached a later cell's recorder. The supervisor now kills its fetcher 3 s after SIGTERM.

**Identity across hosts.** The two segmenters cut 1,228 segments in common over the matrix: 1,226 identical in duration, size and hash, written within 3 ms of each other. The other two are the primary's first after `seg-freeze`'s thaw, cut across its own freeze: 28.8 s and 1.0 MB against the secondary's 1.2 s and 3.8 MB, then 1.2 s against 2.4 s. Its peer check found both different and deleted them, and no receiver got either. The 33 segments only the secondary holds are those the primary missed while killed or frozen.

**The cut.** Leg A's `tsp` ended by itself, status 0, 11.3 s into the cut, its fetch stalled. Its two restarts inside the cut exited 1 after 10.0 s each, the second 3.4 s after the restoration; the third, 4.4 s after it, ran to the end. A's first datagram identical to B's under the same number came 10.2 s after the restoration, its content stepping 32.8 s across a silence of 32.8 s: it rejoined at the live edge, skipping what it missed. From there 357,279 of A's datagrams matched B's, 0 mismatched, at a skew of 365.0 ms (364.2 to 366.1). A's last 3.0 s, 7,416 datagrams after B's last, have no partner, as `clean`'s last 3.6 s (8,874) have none: the grader's tail, 288 s, runs past B's end. Origin B answered no `/g/` request: CloudFront saw nothing. On `clean`, the grader's negative control, A has no gap over 1 s.

1. **Void:** none. Every failure landed at 120.1–120.6 s, and the cut held from 120.2 to 150.1 s.
2. **The six cells:** H2 and H3 hold in every cell: each leg 0 holes and 0 lost segments, the merge 0 lost and 0 continuity errors, the longest wait 5.75 s against 8 s. H1 holds for the receivers, 0 mismatched datagrams in every cell, but not for every segment cut: the frozen primary's two differ.
3. **`leg-cut`, the merge, holds:** B 0 holes, the merge 0 lost and 0 continuity errors; A's hole 32.8 s.
4. **`leg-cut`, the rejoin, holds:** 10.2 s after the restoration against 30 s, 0 mismatched after it, its skew within criterion 5. Every datagram it left unpaired comes after B's last, as in the control.

As predicted, no failed fetch reached a stock receiver behind the group, and on its own path's cut `tsp` took the first branch: it exited on the stalled fetch, and its supervisor's restart rejoined at the live edge. Skew, which criterion 2 does not grade, reached 448.3 ms in `seg-kill`, and `block`'s 5th–95th percentile spread was 92 ms, past criterion 5's 50 ms; whether the cause is the one found above was not checked here.
