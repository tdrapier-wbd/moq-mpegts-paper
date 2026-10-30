# Test 30 — Segmented-HTTP distributed resilience

**State: every cell run but 6, blocked, no client steering.** A co-started pair sharing one
namespace on one host loses no programme when either packager dies, nor when the origin behind an
edge is down for 10 s. Across two hosts sharing an NFS store it did so only with a fixed input
bitrate, a store granting no delegations and a common start, which five co-starts of 23 missed
silently. A packager started into a running
namespace cannot join it with stock TSDuck. Disagreeing replicas and a stale edge lose most of the
programme, with no HTTP error that names the cause. A desynchronised pair is accepted silently, and
delivered as time travel or not according to a race.

## Objective

Determine whether segmented HTTP carrying MPEG-TS can achieve seamless or near-seamless
primary-distribution failover when redundancy is genuinely distributed: two packagers, two hosts, one
consistent object namespace, optional edge cache, and failures that split playlist from segment or
serve stale metadata.

The metric is **media lost at the groomed egress**, not time to first byte after reconnect. Compare
against [T29](test-29-moq-distributed-resilience.md) for the same failure classes where the mapping
is fair.

## What is already known, and precisely what it leaves open

**Co-started active/active on one filesystem is hitless without receiver merge.** [T6](test-6-relay-resilience.md)
showed a shared-feed pair with shared segment names fails over with no measurable interruption (3/3
runs) when both packagers write into one store and the standby was running from t = 0. Two packagers of
one feed are byte-identical at egress under those conditions.

**Misconfiguration is accepted silently.** The same T6 segmented arm documented a *misconfigured* pair
— distinct naming or phase — that delivered roughly ±20 s of time-travel passing every continuity and
PCR check. That failure class is not a stall; it is **silent wrong programme**, and any resilience
test that grades only gaps misses it.

**Grooming masks some failures and hides others.** [T16](test-16-grooming-segmented-http.md) showed the
same groomer that clears PCR conformance can delete programme while PCR statistics stay clean; packet
conservation must be scored as its own column ([method-notes](method-notes.md)). Segmented resilience
is graded *downstream of* a conformant groomer unless the cell explicitly tests ungroomed egress.

**Three shapes were unmeasured before this file.** [T12](test-12-dual-path-handoff.md) segmented remainder
and [T6](test-6-relay-resilience.md) together leave three cells: (1) a **standby packager joining an
already-running feed** — the shape co-start cannot measure; (2) **two hosts writing one store**, where
consistency is free on one filesystem and is the engineering across two; (3) **mid-write fetch**, because
`tsp -O hls` writes segments in place and a client fetching during write is a live hazard unprovoked in
clean runs.

**Multi-CDN, Content Steering and edge pathway selection** remain specification-only ([T11](test-11-interop.md)
cache offload at one nginx node; [T5](test-5-network-impairment.md) availability window at the edge of
loss).

## Environment

| | |
|---|---|
| Baseline | Two `tsp -O hls` packagers (TSDuck 3.44; 2 s segments, `--live 6 --live-extra-segments 3 --intra-close --align-first-segment`), nginx origin (`sendfile on`; playlist `max-age=1`, segments `max-age=60`), receiver `t6-hls-pull.py` (500 ms poll) into [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) given only a rate (T16 arm B, adaptive cushion). Rig: [`t30-segmented-resilience.sh`](scripts/t30-segmented-resilience.sh). |
| Store | Cells 0, 1, 3–5: one host, local disk. Cell 2: an NFS export (`sync`) from a third host, mounted at `<SEGMENT_STORE>` on both packager hosts for the run's duration (NFS 4.2, hard, `timeo=600`, `retrans=2`; client caching at its defaults). |
| Hosts | Single-host cells on one c6in.2xlarge over loopback. Cell 2: packager A on `<EC2_IP_A>`, packager B on `<EC2_IP_B>` (separate AZs), store and origin on the store host (B's AZ), receiver and groomer on A's host, reading the origin over the hosts' private network. |
| Receivers | `t6-hls-pull.py` is graded; `tsp -I hls --live` runs beside it as an ungroomed shelf column. FFmpeg is dropped: [T6](test-6-relay-resilience.md) showed it exits where `tsp` does. |
| Edge (Cell 4) | nginx `proxy_cache` in front of the origin, shaped like a CDN default: honours origin `Cache-Control`, caches 404 for 10 s (CloudFront's default error TTL), collapses concurrent misses, never marks an origin down. The shelf column reads the origin directly so it neither warms nor shields the edge. |
| Grader | At groomed egress: content lost and duplicated from video PTS ([`t28-content-lost.py`](scripts/t28-content-lost.py)); **timeline oracle** [`t30-timeline.py`](scripts/t30-timeline.py), which flags every arrival-order PTS step backward beyond 2 s as silent time travel (forward steps are holes, scored by the content grader); TSDuck continuity, groomed and raw. Playlist consistency from the receiver log (listed segment not fetchable) and the origin and edge access logs. Cell 3 adds [`t30-hammer.py`](scripts/t30-hammer.py): every newly listed segment fetched at once and at +50, +200 and +1,000 ms, and torn when any body differs from the last. |
| Source | Cells 0, 1, 3–5: `contrib-10m.ts` (578.9 s, no loop wrap inside a run), `tsp regulate` to a loopback multicast group, so a packager can join the running feed late; the packagers read the group with `tsp -I ip`. Cell 2: one source on A's host, to its loopback group for A and as a unicast copy of the same packets to B; it starts once both packagers' inputs are bound. |

## Procedure

Every run: packagers start, then the source; the receiver starts once the playlist lists three
segments; events are timed from the receiver's start (event at 40 s, run 100 s).

**Control — T6 dual packager, co-started, one filesystem.** Replay hitless baseline with groomer inserted;
confirm 0 media lost when the active packager is SIGKILLed with identical names. The kill is the
packager's, as in T6's hitless drill: a single origin killed for 10 s has no redundancy to exercise
and exceeds the 8 s cushion by construction (Cell 4 runs it behind an edge).

**Cell 1 — Standby joins running feed (T12's segmented remainder).**
Start packager A and receiver; at mid-stream start packager B into the same namespace, then SIGKILL A
30 s later. Two variants: *naive* (B's own numbering, from `seg-000000`) and *aligned* (B's first file
name and `--start-media-sequence` continue A's playlist; TSDuck takes a template's trailing digits as
the first number). Prediction: content-chosen segment boundaries align intra-coded pictures so B drops
into the same naming sequence; that is a prediction, not a result. Grade the 30 s after B joins for
media lost and naming collisions, and the kill for media lost. Added after the first batch, under the
same criterion: *aligned* with `--slice-only` on both packagers, which stops each injecting its own
PAT and PMT (the aligned variant's failure, *Results*), with a co-started control under the same flag.

**Cell 2 — Two hosts, one store.** Packager A on `<EC2_IP_A>`, packager B on `<EC2_IP_B>`, shared
`<SEGMENT_STORE>`; the origin serves the store from the store host, so no packager's failure takes it
down. Rig [`t30-cell2.sh`](scripts/t30-cell2.sh), driving
[`t30-cell2-host.sh`](scripts/t30-cell2-host.sh) on each host. First a calibration: the two
packagers co-started into directories of their own for 40 s, their segments compared by name and
hash. A shared namespace across hosts means what T6's did only if the two cut identically; if they
do not, the difference is the result and the shared runs are not run. Added after the stock chain
failed it (*Results*), under the same criteria: both packagers given the clip's PCR rate as a fixed
input bitrate (`tsp --bitrate`), calibrated again, and the shared runs made with it. Added after
the first batch, under the same criteria: the batch again with the store host's file leases
disabled (`fs.leases-enable=0`), so that its NFS server grants no delegations. Then a co-started control
with no fault, and three runs of each failure at 40 s, runs of 100 s, the single-host cells' groomer
and poll: SIGKILL A while B runs; SIGKILL B while A runs; A's host partitioned from the store for
10 s (its NFS traffic dropped both ways by a table of its own, then restored).

**Cell 3 — Mid-write fetch.** Drive client fetch rate up against a shared-name pair while packagers
write in place (`tsp -O hls` default). Optional: artificial delay between playlist update and segment
close. Grade partial segments, continuity, and whether client retries recover without media lost.

**Cell 4 — Partial failures (F7 list).** One at a time, receiver behind the edge: edge up, origin down
(origin SIGKILLed for 10 s); origin up, edge stale (edge holds the playlist 20 s, ignoring
`max-age=1`); playlist references missing segment (a newly listed segment deleted three times, 15 s
apart); segment present, playlist stale (playlist frozen 10 s while segments land); premature deletion
inside availability window (receiver paused 8 s, every listed segment but the newest deleted at +6 s,
with a pause-only control); two replicas disagree on bytes for the same URL (edge round-robins two
origins, the second packaging its own copy of the clip 20 s behind).

**Cell 5 — Silent misconfiguration.** Deliberately desynchronise packagers while both serve one
namespace: *independent-source* (B packages its own copy of the clip from 40 s, same naming; T6's
class) and *names-offset* (B co-started on the same source, numbering five segments ahead). Grade with
the timeline oracle, not continuity alone. Added after the first batch, because *independent-source*
numbers from `seg-000000` and so only rewrites names the receiver has already fetched:
*independent-aligned*, the same source with B's first name and media sequence continuing A's.

**Cell 6 — Content Steering (optional, last).** Only when a client implements it; otherwise recorded as
blocked.

Each cell: three repeats unless deterministic; impairment via `netem` only where the cell specifies path
loss distinct from origin kill.

## Metrics

At groomed P1 egress unless the cell tests pre-groom receive:

- **Media lost (headline)** — seconds of programme missing or duplicated.
- **Continuity errors** — TSDuck; interpreted with segmented skip semantics ([method-notes](method-notes.md)
  on modulo-16 counters and post-window re-anchor).
- **Silent error flag** — programme timeline offset > 2 s from source while continuity and PCR checks
  pass — the T6 misconfiguration class.
- **Origin vs edge requests** — during failure, fraction served from cache versus origin (offload ratio).
- **Client detection** — whether the client logged inconsistency, retried, or exited ([T6](test-6-relay-resilience.md)
  receiver axis).
- **Recovery time** — secondary; time to stable operation per [T28](test-28-failure-injection-matrix.md)
  definition.

## Pass criteria, fixed before running

1. **Control.** Co-started identical-name pair on one store: active-packager kill with `t6-hls-pull.py`
   reports 0 s media lost and 0 continuity errors at groomed egress — reproducing [T6](test-6-relay-resilience.md)
   before any distributed cell runs.
2. **Seamless (distributed).** For Cell 2 single packager kill with surviving packager healthy: 0 s
   media lost, 0 continuity errors, no operator action — *seamless* as defined in F7. The partition is
   graded on the same columns and reported beside, not under, this criterion: a hard mount stalls the
   cut-off packager and flushes its writes when the path returns, into a namespace the other has
   moved on, and that flush is the hazard it measures.
3. **Standby join (Cell 1).** Media lost in the 30 s after standby start ≤ 1 segment duration (2 s
   for default packager settings) and no naming collision that serves partial TS to the receiver; exceed
   is a fail of seamless join, not necessarily of the lane outright.
4. **Mid-write (Cell 3).** Zero occurrences of undecodable TS at groomed egress across three 60 s
   high-rate fetch runs; any occurrence is a fail. Recovery without operator action is required.
5. **Silent misconfiguration (Cell 5).** **Must fail the run if not detected:** timeline oracle flags
   offset > 2 s; passing continuity alone is insufficient. A grader that cannot catch T6's time-travel
   class fails criterion 0 of this experiment.
6. **Partial failure cells (Cell 4).** Each row produces a ranked media-lost figure; "playlist stale,
   segment fresh" and inverse are reported separately because the hypothesis expects opposite outcomes.
7. **Comparison note.** Outcomes ranked against [T29](test-29-moq-distributed-resilience.md) at matched
   failure duration; no lane declared superior without matched ingress rate and groomer conformance on
   pre-fault bytes.

## Limits, stated in advance

- **HTTP/1.1 origin unless noted.** [T20](test-20-segmented-http3.md) substrate-matched cells are
  separate; this test's distributed-store claim starts on the same stack as [T6](test-6-relay-resilience.md).
- **One clip, one region, one bitrate** — same cross-cutting limits as [T14](test-14-data-plane-comparison.md).
- **One edge, not a CDN.** The edge is one nginx shaped like a CDN default; CloudFront waits for
  B-7 ([P1-ai](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)).
- **Low-latency partial segments** and commercial ABR-to-TS gateways are out of scope: Low-Latency
  HLS is [not pursued](planned-experiments.md#deliberately-not-doing).
- **Groomer cushion bisection** (1 s vs 8 s byte identity from [T12](test-12-dual-path-handoff.md))
  is a latency-cost question for segmented 1+1, not a resilience question; it may be run in the same
  rig but is not a pass criterion of this file.
- **One receiver's policy.** `t6-hls-pull.py` remembers the names it has fetched and never fetches
  one twice. The naive join's dead end, the independent source's silence and Cell 2's hole at each
  500 follow from that policy; a receiver that follows the media sequence, or retries, would fail
  those rows differently.

## Results

*Measured on one host over loopback: TSDuck 3.44-4676, the system nginx, `t6-hls-pull.py` at a
500 ms poll (50 ms in Cell 3), `mpegts-pacer` adaptive at 11.438 Mb/s; events 40 s after the
receiver starts, runs of 100 s.* Programme lost is from video PTS at the groomed egress; the stall
is the longest run of seconds with no new receiver input (2 s is the segment cadence), beside the
groomer's muted output ([`t30-regrade.py`](scripts/t30-regrade.py)), which a stall that runs to the
end of a capture shows and PTS cannot.

| Cell, variant | Runs | Programme lost | Stall; muted | Continuity errors | Receiver saw |
|---|---|---|---|---|---|
| Control, active packager killed | 3 | 0 | 2 s; 0 | 0 | — |
| Join, naive | 2 | 0 while both write; after the kill, nothing to the run's end | 8 s while both write; 33 s after the kill, 24 s muted | 0 | nothing |
| Join, aligned | 3 | 0.92 s at the join | 2 s; 0 | 219–221, 208 on PAT and PMT | nothing |
| Join, aligned, `--slice-only` | 3 | 0.32 s in two holes, 0.03–0.06 s duplicated | 2 s; 0 | 30–39, in five bursts | nothing |
| Control, `--slice-only` | 1 | 0 | 1 s; 0 | 0 | — |
| Misconfig, independent source | 2 | 0 | 4 s; 0 | 0 | nothing |
| Misconfig, independent, aligned names | 2 | not measurable: two timelines 47 s apart, 14 steps back and 14 forward a run | 2 s; 0.9–1.0 s | 176–177; 10 on its input | nothing |
| Misconfig, names five ahead | 2 | 0; 7.2 s, after a 6.84 s step back | 2 s; 9 s, 0 muted | 0; 20 | nothing |
| Origin down 10 s behind the edge | 2 | 0 | 10 s; 0.5 s | 0 | 17 failed fetches (502), recovered |
| Edge holds the playlist 20 s | 1 | 24.8 s in four holes, then 12 s stalled at the end | 20 s; 17.1 s | 41 | nothing |
| A listed segment deleted, three times | 1 | 7.8 s, a segment each | 5 s; 0 | 32 | three 404s |
| Playlist frozen 10 s | 2 | 0.40–0.48 s | 11 s; 1.5–1.9 s | 67–72; 0 on its input | nothing |
| Receiver paused 8 s, listed segments deleted | 1 | 5.9 s | 9 s; 0.9 s | 10 | two 404s |
| Receiver paused 8 s, nothing deleted | 1 | 0 | 7 s; 0 | 0 | — |
| Replicas disagree behind the edge | 1 | 80.4 s in 11 holes, then 12 s stalled at the end | 18 s; 21.7 s | 97 | 35 404s |
| Mid-write: 50 ms poll, every new segment fetched four times | 3 | 0 | 2 s; 0 | 0 | — |

**Join.** Two packagers rewriting one playlist in place alternate in it, and the receiver read
listings that mixed them (one gave media sequence 0 over names to `seg-000019`). In the naive variant B
numbers from `seg-000000`, names the receiver has already fetched, so once A dies nothing new is
ever listed: the playlist stays fresh and the programme stops. Aligned, B's names continue A's and
the kill is hitless, but each packager stamps its own continuity counter on the PAT and PMT it
inserts at each segment's start, so every segment while both write carries a counter jump on PIDs 0
and 100. `--slice-only` removes the inserted tables, and TSDuck then refuses
`--align-first-segment`: B's cuts no longer fall where A's do, one name holds two segmentations, and
each switch between them costs a few packets on every PID. A co-started pair under the same flag is
clean, so the cost is the cuts', not the flag's.

**Misconfiguration.** With B numbering from `seg-000000` behind A, the playlist alternates between
media sequences 15–27 and 0–8 and the receiver, ignoring names it has fetched, delivers A alone.
Names five ahead: in one run the first listing was A's and the programme came through clean; in
the other it was B's, and the receiver delivered a 6.84 s step back, which the timeline oracle
flagged as time travel and continuity counted as 20 errors, as it would a lost segment. With B's names continuing A's, T6's class returns in
both runs: the receiver alternates between the two sources, 47 s apart, with no failed request,
and the oracle flags every step.

**Partial failures.** Behind the edge an origin outage costs nothing but the groomer's cushion,
which covers all but 0.5 s of a 10 s stall. Holding the playlist 20 s against a 12 s live window loses whole
segments with no failed request anywhere. Disagreeing replicas fail by absence, not time travel:
the second origin has not yet written the names the first lists, its 404s are cached at the edge
for 10 s, and retry cannot recover. A frozen playlist loses nothing at the receiver; the loss is the
groomer's, which drops 2,681 packets of the 12.2 MB catch-up burst against its 8 s cap.
`tsp -I hls`, reading the origin directly, exited when the origin went down and in one names-ahead
run; elsewhere it matched the groomed column.

**Mid-write.** TSDuck lists a segment only after closing it, so 39 segments fetched four times
each never differed, three runs out of three. The playlist, rewritten in place, was caught empty
once in about 19,600 requests: nginx aborted that response and the receiver's next poll succeeded.

### Cell 2 — two hosts, one store

*Measured on three hosts in one region (the packagers in two AZs, the store and origin in B's), NFS
4.2, the store's nginx reading the export from its own disk; otherwise as above.*

**Calibration.** Stock, the two packagers listed the same names and none of 9 segments was
identical: B's cuts fell 1.2 s of video behind A's, later 1.6–1.7 s, on every run and on a second
host for B. On one host they cut identically, whether both read the group, one read a loopback
fork, or one started 0.7 s or 20 s late, so the difference is the path between hosts. Deriving the bitrate from
PCRs (`-P pcrbitrate`) changed nothing; a fixed input bitrate (`tsp --bitrate`, the clip's PCR rate)
made the cuts identical, and equal to the stock cuts on the source's host. The PAT and PMT counters
were then 6 apart: a packager that misses the source's first tables numbers its own from elsewhere.
Starting the source only once both inputs were bound gave 9 of 9 identical.

| Store, run | Runs | Programme lost | Stall; muted | Continuity errors | Non-200 at the origin |
|---|---|---|---|---|---|
| Delegations granted: control | 3 | 0 | 2–3 s; 0 | 0, 0, 70 | 0, 0, 1 |
| kill A | 3 | 43.12 s twice; the rest of the run once | 37, 37, 57 s; 29.9, 29.9, 48.8 s | 46, 20, 0 | 25 each |
| kill B | 3 | 43.12 s; the rest of the run; 50.76 s in 7 holes | 37, 57, 25 s; 30.0, 48.8, 18.4 s | 20, 0, 80 | 25, 25, 27 |
| partition A | 3 | 12.0, 9.6, 48.64 s | 14, 10, 39 s; 5.1, 2.6, 31.6 s | 12, 11, 50 | 5, 6, 25 |
| No delegations: control | 1 | 0 | 3 s; 0 | 48 | 0 |
| kill A | 4 | 0 in three; 10.04 s in 4 holes | 2–5 s; 0 | 0 in three; 42 | 0 |
| kill B | 3 | 0 | 2–3 s; 0 | 0 | 0 |
| partition A | 3 | 0 | 2–3 s; 0 | 0 | 0 |

**Delegations.** Every non-200 was a 500 from the origin failing to open a file a packager had
just written (EAGAIN). Once one NFS client alone writes a file the server delegates it
to that client, and a local non-blocking open is refused while the delegation is recalled. The
receiver fetches each name once, so each 500 is a hole; after a kill the programme returned after
43 s or not at all. With the store host's leases disabled (`fs.leases-enable=0`) no request failed,
and a partitioned packager's flush, when its path returned, did no harm.

**Start race.** Five runs of 23 began with the pair apart despite the readiness wait, and no
response showed it: one with the table counters apart (70 errors on PAT and PMT, nothing lost); one
with the cuts apart (48 errors, one name holding two segmentations); three with the names one
apart, where the media sequence stepped back and 9–13 segments were served empty, one packager's
truncating open landing after its partner had listed the name. Only the last kind lost programme
without a fault: 10.04 s, before the kill.

`tsp -I hls` exited in five runs on a playlist not starting `#EXTM3U`: twice a 500's error page,
three times a playlist read mid-rewrite.

## Conclusions

1. **Criterion 1 passes.** T6's hitless co-started pair holds downstream of the groomer.
2. **Criterion 2 fails as designed, and holds only rebuilt.** Across hosts the stock packagers did
   not cut alike. With a fixed input bitrate every kill lost 43 s or more to the store's
   delegations; with those disabled too, six kills of seven lost nothing, and so did three
   partitions. The seventh lost 10 s to the third condition, a common start, which five co-starts
   in 23 missed with no response showing it. What one filesystem gives free, two hosts must
   rebuild, and the start is a race rather than a setting: this supports conclusion 3.
3. **Criterion 3 fails in every variant.** Naive meets the window and fails the kill: its names
   collide with fetched ones, so the standby never takes over. Aligned and `--slice-only` meet the
   2 s bound, and their collisions serve TS with continuity errors: each packager's own table
   counters, then cuts that no longer align. No stock TSDuck configuration lets a packager join a
   running namespace. A shared namespace survives a co-started pair only; a packager that can
   restart needs its own namespace, or a packager whose cuts and names follow from the content
   alone.
4. **Criterion 4 passes.** In-place segment writes never reached the receiver torn; the in-place
   playlist did, once, harmlessly.
5. **Criterion 5: the grader passes, the lane does not detect.** The oracle flagged every delivered
   jump; nothing in HTTP did, and the receiver accepted each. The one signal is the playlist's
   media sequence going backwards.
6. **Criterion 6, ranked:** disagreeing replicas (80 s) > a stale edge (25 s) > deleted segments
   (6–8 s) > a frozen playlist (0.4 s, the groomer's) > an origin outage behind an edge (0, 0.5 s
   muted). "Playlist stale, segment fresh" loses almost nothing; "playlist fresh, segment missing"
   loses each segment: opposite, as predicted. The two worst rows are the two whose cause no HTTP
   response names: a stale edge fails no request, and disagreeing replicas fail as missing segments.
7. **Criterion 7 has no comparison:** T29 has not run.

## Tooling: what the evaluation reuses and what it builds

**TSDuck carries everything that touches the transport stream. The one missing piece is HTTP-side,
and it sits in front of TSDuck, not instead of it.** Per stage: what serves it, what this file or
the one cited showed it lacks, and what closing the gap takes.

| Stage | Reuse | Gap | To close it | Upstream dependency |
|---|---|---|---|---|
| Package | `tsp -O hls` | the playlist is rewritten in place (Cells 1, 3); numbering restarts at 0, so a restarted packager reuses names a cache may still hold; a second packager cannot join a namespace (conclusion 3); across hosts the cuts differ unless the input bitrate is fixed (conclusion 2) | no code: one namespace per pathway; a first name derived from the wall clock, with `--start-media-sequence` | none on the path; optional TSDuck changes: write-then-rename, cuts, names and table counters set by the content |
| Receive | `tsp -I hls` byte-faithful in steady state; `--headers` adds a static header (a CAT, static CMCD keys) to every request | exits on one failed reload or fetch (*Results*, T6); no retry, no second pathway, no event log; an HTTP fault is invisible to TSDuck's metrics | **B-8**: a front end that owns HTTP and writes the TS to stdout | none |
| Rebuild cadence | `mpegts-pacer`, adaptive; `--stream-clock` for 1+1 | the cap drops a post-stall catch-up burst (*Results*, frozen playlist) | B-8 paces its catch-up, or the cap is set from the window (P1-ag) | none |
| Monitor the TS | `tsp -P influx` (TR 101 290 counters, PCR and PTS, bitrate per PID or service, to InfluxDB), `-P analyze`, `-P continuity`; the campaign's liveness probe | they grade continuity and PCR, not the programme timeline: a silent time jump shows at most as continuity errors, which benign cells raise too (Cell 5) | the timeline oracle's rule, run live | none |
| Select between legs | ST 2022-7 on two groomed legs ([T12](test-12-dual-path-handoff.md)); `tsswitch` for a marked switch | — | — | none |
| Scramble | `-P scrambler` / `-P descrambler`, DVB-CSA2 with a fixed control word | BISS-CA is absent; `-O hls --intra-close` publishes no segment of a scrambled stream until its input ends | `-O hls` without it, which cuts at PES starts ([T69](test-69-segmented-access-and-scrambling.md)) | none |
| Entitle | a CloudFront Function validating a CAT; `tsp --headers` for a token that outlives the session | renewal | in B-8 | B-7 |

**B-8, specified.** Grown from `t6-hls-pull.py`, which already holds the playlist loop, URI
bookkeeping and outage accounting: retry a failed reload or fetch for as long as the segment stays
in the window; on a second failure, or a playlist older than three target durations, continue from
a second pathway, locating the continuation by content (video PTS) rather than by name, because
each pathway has its own packager (conclusion 3); in a second mode, fetch both pathways and pass
each stretch of programme once; flag a listing whose media sequence goes backwards (Cell 5's only
signal); pace a catch-up to the mux rate; write one JSON line per fetch and
per anomaly (stall, retry, fallback, regression, 404); send CMCD v2 keys on each request and to an
event-mode collector, carrying TR 101 290 counters read from the downstream `tsp` as custom keys;
attach and renew a CAT. TS bytes go to stdout, into `tsp -I file -` or the groomer; it reads
timestamps and alters no packet.

**Why not a new receiver, and why not TSDuck first.** A new receiver would rebuild what TSDuck and
the groomer already do on the packet side. Patching `-I hls` puts a C++ change behind another
maintainer's release before the behaviour is settled; B-8 settles it first, and its retry and event
log can then be offered to TSDuck. **The 1+1 design has three routes, and only one needs TSDuck
changed.** Each pathway with its own packager and namespace, selected either by B-8 by content or
by two receivers whose stream-clocked groomers feed a 2022-7 merge: P1-ai measures both, with
existing tools and B-8. Or one namespace fed by packagers whose cuts and names follow from the
content alone, so that a restart rejoins: a TSDuck change, worth proposing only if the receiver
routes fail.

**The shortest path to concluding the lane:** B-8, and CloudFront for the campaign's account (B-7).
Everything else in P1-ag to P1-al runs on tools the campaign has.
