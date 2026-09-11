# Test 30 — Segmented-HTTP distributed resilience

**State: specified, not run.** The segmented lane's strongest theoretical claim is that independent
addressable objects and multiple delivery paths enable near-seamless failover without session state to
re-establish — but the evidence is one filesystem, co-started packagers, and [T6](test-6-relay-resilience.md)
drills reported as recovery times. This experiment would grade distributed resilience across two hosts,
including production-shaped join and silent misconfiguration; it has not run because the two-host segment
store and standby-join rig are specified under [P1-c](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)
and blocked on the second EC2 instance layout used for cross-host work.

## Objective

Determine whether segmented HTTP carrying MPEG-TS can achieve seamless or near-seamless
primary-distribution failover when redundancy is genuinely distributed: two packagers, two hosts, one
consistent object namespace, optional edge cache, and failures that split playlist from segment or
serve stale metadata.

The metric is **media lost at the groomed egress**, not time to first byte after reconnect. Compare
against [T29](test-29-moq-distributed-resilience.md) for the same failure classes where the mapping
is fair.

Specified as [P1-c](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) /
[P1-c](planned-experiments.md#p1--establishes-where-one-architecture-is-superior).

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

**Two production shapes were never measured.** [T12](test-12-dual-path-handoff.md) segmented remainder
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
| Baseline | Two `tsp -O hls` packagers (2 s segments, `--intra-close --align-first-segment`, window sizing from [T6](test-6-relay-resilience.md)), HTTP origin, receiver chain through [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) for conformant P1 egress ([T16](test-16-grooming-segmented-http.md)). |
| Store | v1: shared NFS or object store mounted at `<SEGMENT_STORE>` on both hosts — placeholder, not yet provisioned. v0 shakeout: one host, two packagers, local disk (replicates T6, not this test's claim). |
| Hosts | `<EC2_IP_A>` and `<EC2_IP_B>` in separate AZs for two-host arms; loopback only for control replay. |
| Receivers | `t6-hls-pull.py` as protocol-capable minimum; `tsp -I hls --live` and FFmpeg as shelf columns where
  [T6](test-6-relay-resilience.md) showed divergent error handling. |
| Edge (optional) | nginx `proxy_cache` then CloudFront distribution `<CDN_DISTRIBUTION>` when account exists — last in procedure. |
| Grader | Media lost, continuity errors, PCR discontinuity; **playlist-media consistency checks** (segment
  named in playlist present on store; media sequence monotonic); **silent misconfiguration detector**
  — byte-wise programme timeline versus source, not continuity alone ([T16](test-16-grooming-segmented-http.md)). |
| Source | Looped `<CLIP>`, paced; identical fan-out to both packagers via `tee` or duplicate regulate. |

## Procedure

**Control — T6 dual packager, co-started, one filesystem.** Replay hitless baseline with groomer inserted;
confirm 0 media lost on origin kill with `DUAL_NAMES=identical`.

**Cell 1 — Standby joins running feed ([P2-c](planned-experiments.md#p2--completeness) / T12 segmented remainder).**
Start packager A and receiver; at mid-stream start packager B into the same namespace. Prediction:
content-chosen segment boundaries align intra-coded pictures so B drops into the same naming sequence;
that is a prediction, not a result. Grade first 30 s after B joins for media lost and naming collisions.

**Cell 2 — Two hosts, one store.** Packager A on `<EC2_IP_A>`, packager B on `<EC2_IP_B>`, shared
`<SEGMENT_STORE>`. Fail: kill A while B runs; kill B while A runs; partition store visibility (iptables
drop between host and store). Grade merge at receiver without operator action.

**Cell 3 — Mid-write fetch.** Drive client fetch rate up against a shared-name pair while packagers
write in place (`tsp -O hls` default). Optional: artificial delay between playlist update and segment
close. Grade partial segments, continuity, and whether client retries recover without media lost.

**Cell 4 — Partial failures (F7 list).** One at a time: edge up, origin down; origin up, edge stale;
playlist references missing segment; segment present, playlist stale; premature deletion inside
availability window; two replicas disagree on bytes for the same URL.

**Cell 5 — Silent misconfiguration.** Deliberately desynchronise packagers (distinct `DUAL_NAMES` or
phase offset) while both serve; grade with timeline oracle, not continuity alone — reproducing the T6
failure class under distributed conditions.

**Cell 6 — Content Steering (optional, last).** Only when a client implements it; otherwise recorded as
blocked.

Each cell: three repeats unless deterministic; impairment via `netem` only where the cell specifies path
loss distinct from origin kill.

## Metrics

At groomed P1 egress unless the cell tests pre-groom receive:

- **Media lost (headline)** — seconds of programme missing or duplicated.
- **Continuity errors** — TSDuck; interpeted with segmented skip semantics ([method-notes](method-notes.md)
  on modulo-16 counters and post-window re-anchor).
- **Silent error flag** — programme timeline offset > 2 s from source while continuity and PCR checks
  pass — the T6 misconfiguration class.
- **Origin vs edge requests** — during failure, fraction served from cache versus origin (offload ratio).
- **Client detection** — whether the client logged inconsistency, retried, or exited ([T6](test-6-relay-resilience.md)
  receiver axis).
- **Recovery time** — secondary; time to stable operation per [T28](test-28-failure-injection-matrix.md)
  definition.

## Pass criteria, fixed before running

1. **Control.** Co-started identical-name pair on one store: origin kill with `t6-hls-pull.py` reports
   0 s media lost and 0 continuity errors at groomed egress — reproducing [T6](test-6-relay-resilience.md)
   before any distributed cell runs.
2. **Seamless (distributed).** For Cell 2 single packager kill with surviving packager healthy: 0 s
   media lost, 0 continuity errors, no operator action — *seamless* as defined in F7.
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
- **CloudFront / multi-CDN** blocked without account; nginx single-node cache is indicative, not
  multi-CDN proof.
- **Low-latency partial segments** and commercial ABR-to-TS gateways remain [T14](test-14-data-plane-comparison.md)
  measurement 1 / [B-4](planned-experiments.md#blocked-on-apparatus) — out of scope here.
- **Groomer cushion bisection** (1 s vs 8 s byte identity from [T12](test-12-dual-path-handoff.md))
  is a latency-cost question for segmented 1+1, not a resilience question; it may be run in the same
  rig but is not a pass criterion of this file.

## Why this has not run

[T6](test-6-relay-resilience.md) answered serving-node failover on loopback with co-started packagers;
[T12](test-12-dual-path-handoff.md) extended MoQ egress 1+1 and listed the segmented remainder cells
explicitly. [P1-c](planned-experiments.md#p1--establishes-where-one-architecture-is-superior) ranks the
two-host store behind cross-host fan-out ([T26](test-26-cross-host-fanout.md)) because both need the
second instance and the fan-out experiment deliberately saturates a box last. The standby-join cell
([P2-c](planned-experiments.md#p2--completeness)) is cheap once P1-5's steady state exists — it is
queued behind this file's Cell 2, not instead of it.
