# Test 59 — Segmented 1+1 over CloudFront: two pathways, two receivers, an ST 2022-7 merge

**State: run, one topology (two receivers and a merge); the fallback topology waits on B-8's
fallback.** H2 and H4 hold; H1 holds, but its injection control matched too; H3 holds only for a
receiver whose window covers the skew, which a Class C receiver's did in two cells of seven. The
run found and fixed two defects in the stream-clocked groomer, one of which turned a packager
freeze into a permanently corrupt merge.

## Objective

P1-ai asks R2 (survivability) and R6 (redundancy) of the segmented lane on a real CDN rather than
T30's single nginx edge. The feeds are 24/7: every packager and receiver joins a running stream,
and a restarted one is a late joiner. T30 showed a late packager cannot join a shared namespace, so
here each pathway has its own packager, origin and namespace, and the protection is assembled
downstream: two receivers, each fetching one pathway into a stream-clocked groomer, whose RTP legs
an ST 2022-7 receiver merges. That is the topology the author takes as the safer production
assumption: the merge is done by the affiliate's receivers, not by one fetcher choosing a pathway.

The second topology P1-ai names, one receiver falling back between pathways by content, needs
B-8's fallback, which is not built; each leg's own loss below is its no-fallback baseline.

## Hypotheses, fixed before running

- **H1 (identity).** Legs from packagers started apart are byte-identical under equal RTP numbers
  when both packagers slice the source unchanged (`--slice-only`), and are not when each injects
  its own PAT and PMT per segment (TSDuck's default), because the injected packets differ in
  position and continuity counter between packagers.
- **H2 (skew).** A stream-clocked groomer fixes its wall-clock offset once, at its first output,
  from the live edge it holds then. A segmented leg's edge is between a fetch and a segment
  duration old at that instant, so the skew between two legs started apart is set by where each
  receiver started and ranges up to about one segment (2 s). A Class C receiver (450 ms) merges
  hitlessly only when the skew lands inside its window.
- **H3 (protection).** With H1 holding and the skew inside the merge window, no failure confined to
  one pathway costs the merged output a datagram.
- **H4 (offload).** Each segment leaves each origin a small number of times however many receivers
  fetch it through CloudFront.

## Environment

- **Source:** the live 24/7 feed (25 Mb/s CBR, one service, no null PID), delivered to the primary
  and to the secondary from one contribution path as byte-identical packets. Each packager reads
  its own host's copy.
- **Pathway A:** `tsp -O hls` on the primary into its own namespace `/a/`, served by an nginx
  origin on the primary. **Pathway B:** the same on the secondary, `/b/`. 2 s target duration,
  `--live 6 --live-extra-segments 3 --intra-close`; first segment name and media sequence are the
  wall clock in seconds, which a counter of 2 s segments never catches, so a restarted packager
  never reuses a name. The two packagers
  start minutes apart and run across all cells, as a 24/7 packager would.
- **CDN:** one CloudFront distribution, provisioned for the test and deleted after it, with one
  origin per pathway (`/a/*`, `/b/*`); legacy cache settings that honour the origin's
  `Cache-Control` (playlist `max-age=1`, segments `max-age=60`); error caching 1 s for 404 and 0 s for
  502 and 504. A viewer-request function admits only requests carrying a shared secret, and each
  origin answers only requests carrying CloudFront's origin secret.
- **Receivers:** both on the tertiary, each fetcher in its own network namespace (NAT to the host)
  so `netem` can impair one leg's path alone. Fetcher: `b8-hls-recv.py`, `t6-hls-pull.py` grown
  into B-8's first increment (retries a segment until it leaves the playlist, flags a media
  sequence going backwards, logs every request with CloudFront's cache result). Groomer:
  `mpegts-pacer --rtp --stream-clock` at 26 Mb/s, shared SSRC and sequence seed, latency 8 s, cap
  14 s, stall 1 s then mute; `5626c88` for the graded cells (*Groomer defects* below). Both legs are
  recorded from their sockets on the loopback into one pcap, one clock.
- **Grader:** `t55-grade.py` (identity at equal numbers; a 2022-7 receiver model; continuity of
  the merged output), with the window set to 450 ms and, separately, to cover the measured skew.

## Procedure

Cells of 300 s. Leg A's receiver starts at 0, leg B's at 20 s, so the receivers too join apart.
Events strike pathway A at 120 s; nothing strikes B.

| Cell | Event on pathway A |
|---|---|
| `clean` | none (the control) |
| `pack-kill` | packager killed at 120 s, restarted at 130 s under new wall-clock names |
| `pack-freeze` | packager stopped (`SIGSTOP`) for 10 s, then continued |
| `origin-down` | origin nginx stopped for 30 s |
| `recv-restart` | leg A's fetcher and groomer killed at 120 s, restarted at 130 s |
| `loss` | `netem` 2 % loss and 20 ms delay on leg A's path for 60 s |
| `inject` | both packagers restarted without `--slice-only`; clean (H1's control) |

## Pass criteria, fixed before running

1. **Void** unless both legs are captured over the cell, both packagers run except where the cell
   stops one, and the receivers' logs show CloudFront answering. Nothing else is graded unless, in
   `clean`, the legs match on every datagram both carry, with no conflict.
2. **Identity (H1):** in every interval with no event on either leg, every datagram leg B sends is
   matched by leg A's under the same number, with no conflict, in every `--slice-only` cell.
   `inject` is graded for the opposite: H1 holds if its legs conflict.
3. **Skew (H2):** the skew at equal numbers is reported per cell; H2 holds if it is constant within
   a cell except across a restarted leg, and differs between cells by up to a segment duration.
4. **Hitless (H3):** in each event cell the merged output loses no datagram, meets no conflict and
   has no continuity error, graded at a window covering the cell's skew. Graded again at 450 ms:
   the same, or the cell is reported as hitless only for a receiver whose window covers the skew.
5. **Protection restored:** after the event, leg A's datagrams match B's again, and the time to
   that is reported.

Reported, not graded: each leg's own loss (media lost with no partner, per failure class); the
pacers' late drops, withheld and muted counts; origin requests and bytes per segment against
segments delivered (offload); CloudFront's hit ratio as the receivers saw it; egress per leg.

## Limits

- One CDN and one distribution: both pathways share its configuration and its edge, so a
  distribution-wide fault (a cache policy, a function) strikes both. Production pathways would be
  separate distributions or CDNs.
- Both receivers on one host, in separate network namespaces: their paths diverge only from the
  host's interface. The affiliate deployment puts them on separate hosts.
- One run per cell, 300 s each; the 72 h soak is P1-aj.

## Results

*Groomer `5626c88`; graded from leg B's settling (40 s) to 12 s before the end, where both legs
drain. Skew is leg B's arrival less leg A's at equal numbers, median, with its spread in the cell.
"Wide" is a receiver window of the cell's largest skew plus 500 ms.* Every cell passes criterion 1:
both legs captured, CloudFront answering throughout (every segment a `Miss` at PoP DUB2-P1, one
receiver per pathway).

| Cell | Skew (spread) | Identity: matched, mismatched | Leg A's own loss | Merged, wide: lost, conflicts, CC errors | Class C receiver (450 ms) |
|---|---|---|---|---|---|
| `clean` | −498 ms (37) | 691,314; 0 | — | 0; 0; 0 | follows A; no event |
| `pack-kill` | +666 ms (51) | 664,999; 0 | 10.6 s hole | 0; 0; 0 | follows B; untouched |
| `pack-freeze` | +1,472 ms (30) | 664,715; 0 | 10.7 s hole | 0; 0; 0 | follows A; re-locks onto B 0.57 s back, a repeat |
| `origin-down` | −975 ms (37) | 635,131; 0 | 22 s muted | 0; 0; 0 | follows A; re-locks onto B 1.87 s ahead, a skip |
| `recv-restart` | −1,246 ms (125) | 645,064; 0 | 17.2 s absent | 0; 0; 0 | follows A; re-locks onto B 2.02 s ahead, a skip |
| `loss` | +189 ms (16) | 694,696; 0 | none | 0; 0; 0 | merges both; 0 lost |
| `inject` | −24 ms (8) | 692,071; 0 | — | 0; 0; 0 | merges both; 0 lost |

**Identity.** Every datagram both legs carried matched, in every cell, before and after every
event. `inject` matched too: both packagers, restarted minutes apart with TSDuck's default
per-segment PAT and PMT, wrote byte-identical segments (equal sizes, MD5s and `EXTINF`
sequences). The feed's random-access points are irregular, 0.4–1.3 s apart, and `--intra-close`
cuts at the first after 2 s, so two packagers settle on the same cut pictures and inject the same
tables; T30's clip did not. Identity under injection is the feed's, under `--slice-only` it is the
configuration's.

**Skew.** Constant within a cell to 8–51 ms, and 125 ms across `recv-restart`'s restarted leg;
between cells it ranged over 2.9 s (−1.42 s to +1.47 s with the pre-fix cells). Of the graded
cells only `loss` and `inject` landed inside 450 ms. Outside it, the Class C receiver plays one leg (the first to
arrive, or the one it last re-locked to) and ignores the other; a failure on that leg costs a
re-lock by about the skew plus the window, forward (programme skipped) when the other leg is
ahead, back (programme repeated) when it is behind. The grader's `lost` excludes these jumps;
they are read from its re-lock log.

**Each leg's own events.** A packager killed or frozen for 10 s cost its leg 10.6–10.7 s. The
30 s origin outage cost 22 s muted, the cushion having covered 8. A receiver restarted after 9 s
was absent 17.2 s, its cushion refilling, and returned under its partner's numbering. 2 % loss
with 20 ms added delay lengthened leg A's 6.2 MB fetches from 40–100 ms to 100–580 ms and cost
nothing. Both packagers' restarts took new wall-clock names, and no receiver fetched a name twice.

**CloudFront during the origin outage.** The edge kept answering the playlist with the last copy
it held: the receiver logged no failed request through 30 s of outage. When the origin returned,
the media sequence jumped 16 while the playlist lists 6: ten segments were listed and withdrawn
without this receiver seeing them, and nothing in HTTP said so. `b8-hls-recv.py` now logs the jump
(`msn-skip`, 10 unseen, replayed from that cell's playlist log).

**Offload** ([`t59-offload.sh`](scripts/t59-offload.sh), 102 s, no legs running). Four receivers
on pathway A, three at the Dublin edge and one at London: origin A served 41 of 42 segments
exactly twice, once per edge, and revalidated the playlist 1.99 times a second (once a second per
edge, 120 of 203 answered 304). The three Dublin receivers' 126 fetches were 42 misses and 84
hits: one origin fetch per segment per edge, however many receivers. Origin egress was 50 Mb/s
against 100 Mb/s delivered.

## Groomer defects found

The first four cells ran on `ea88793`, whose stream-clocked grid had two faults the synthetic and
looped sources of T12 and T55 never exercised. Both are fixed in `mpegts-pacer`, each with a test
that fails without it; the table above is the fixed build's.

- **Intact intervals read as missed stream.** The grid cut a run when a PCR interval reached twice
  the longest of the eight before it. The live feed's PCRs fall 0.18–25 ms apart (median 17.7 ms),
  which meets that rule about once in 650 intervals on an intact stream; each time the leg
  discarded the run and stayed silent for a release latency until it re-phased. It struck both legs
  alike: `pack-kill` on `ea88793` gave each leg three or four silences of 7–13 s besides the kill,
  three of them on both legs within 1.6 s of each other, and its merge carried 52 continuity errors. Fixed by also requiring a continuity
  counter to break across the interval (`c07a77a`).
- **A packager freeze read as a source splice.** On thaw, the frozen packager's open segment
  carries the last of the old content and the first of the new, 7.7 s further on, in one fetch.
  The grid read a jump no silence explained as a moved clock and re-based, so leg A's content went
  out 7.7 s early under leg B's numbers for the rest of the cell: 273,517 datagrams mismatched, as
  many conflicts at a 1.8 s window, and 191 continuity errors in the merge. `pcr_rebases` stayed 0,
  because grid re-bases were not counted. Fixed by reading a jump that lands no further ahead than
  the leg's buffer may hold as a gap, and counting grid re-bases (`5626c88`). A real splice
  forward by less than the cap's headroom (6 s here) is now played as a gap of that length.

## Conclusions

1. **Criterion 2 (H1) passes; its control does not behave as predicted.** `--slice-only` legs are
   identical in every cell. Injecting packagers were identical too, on this feed: production
   should use `--slice-only`, which does not depend on where the feed's pictures fall.
2. **Criterion 3 (H2) passes.** The skew is fixed at each leg's start, constant to tens of
   milliseconds, and spread over 2.9 s between starts; nothing in the chain bounds it.
3. **Criterion 4 (H3) passes at a window covering the skew and fails at 450 ms** in the three
   cells where the struck leg was the one the receiver followed: a 0.57 s repeat and skips of
   1.87 s and 2.02 s. A 24/7 pair of segmented legs is hitless only for a receiver whose window
   exceeds the largest skew two starts can produce, about 2 s on 2 s segments, unless the legs'
   start is made deterministic.
4. **Criterion 5 passes.** After every event the struck leg's datagrams matched its partner's
   again, with no mismatch; the time to it is the leg's own loss above.
5. **H4 holds.** Origin load is one fetch per segment per CloudFront edge, independent of
   receivers per edge; a shared mid-tier (Origin Shield, not enabled here) would make it one.
6. **The lane's failure signals sit outside HTTP.** A stale-served playlist through an origin
   outage fails no request, so a receiver's fallback trigger has to be a playlist that stops
   advancing, and its loss count has to include sequence numbers it never saw.
