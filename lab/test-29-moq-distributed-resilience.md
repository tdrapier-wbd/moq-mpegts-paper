# Test 29 — MoQ distributed resilience above egress 1+1

**State: specified, not run.** [T12](test-12-dual-path-handoff.md) established hitless 1+1 at the
*egress* for single-track content; [T6](test-6-relay-resilience.md) characterised relay reselect and
cluster failover as fast reconnect, not programme continuity. This experiment would grade resilience
*above* the groomed legs — multiple relays, multiple publishers, receiver-side relay selection — and
it has not run because the mesh topology and merge oracle for relay-level subscriptions are specified
but not built; the egress story is already strong and was deliberately finished first.

## Objective

Determine whether MoQ can meet primary-distribution redundancy requirements — *programme* continuous
through infrastructure failure, not merely session re-established quickly — when redundancy sits
above the egress 1+1 pair: multiple relays, optional publisher redundancy, and a receiver selecting
between upstream paths before grooming.

The hypothesis under test, stated in advance: **continuity at this layer requires the receiver to hold
two live subscriptions and merge in the byte or RTP domain**; relay reselect alone cannot be hitless
because the measured floor is one detection interval and the exporter resumes at the live edge
([T6](test-6-relay-resilience.md)). This test generalises the [T12](test-12-dual-path-handoff.md)
result upward in the topology stack.

Registered as [P1-b](planned-experiments.md#p1--establishes-where-one-architecture-is-superior).

## What is already known, and precisely what it leaves open

**Egress 1+1 is strong for single-track content and weak for multi-track.** Two independently
stream-clocked groomers across two availability zones, sharing nothing but a verified-identical source
file, delivered byte-identical RTP on 46,778 of 46,778 shared datagrams with zero residue on
single-track content ([T12](test-12-dual-path-handoff.md)). A seven-stream mux over the same topology
reached 75.56 % agreement — same packets in a different order — for a reason filed upstream as
[#2829](https://github.com/moq-dev/moq/issues/2829). Multi-track identity at merge is therefore an
upstream fix, not another egress-only cell.

**Relay reselect is bounded, not hitless.** [T6](test-6-relay-resilience.md) measured failover
detection at roughly 30–33 s by default and ~10 s with tuned idle timeout; recovery re-establishes
sessions but the exporter skips to the live edge, losing media produced during the outage. Cluster
failover between relays was exercised in T6 but graded as reconnect time, not media lost.

**The mesh variants are specified but not run.** [T12](test-12-dual-path-handoff.md) notes what
remains: relay B dialling relay A as a cluster peer (relay cluster configs per `INSTRUCTIONS.local.md`)
to verify relay reselect neither helps nor
interferes once the receiver switches; and **the receiver holding two relay subscriptions** rather
than two groomed legs. That second variant would also exercise subscription resumption across routes
sharing a first hop ([#3312](https://github.com/moq-dev/moq/pull/3312)).

**Publisher and path redundancy above egress are untested.** Two publishers of the same source feeding
two relays, with failure of one publisher, one relay, one network path, or the receiver's preferred
leg, has no designed media-domain record.

## Environment

| | |
|---|---|
| Baseline topology | Extend [T12](test-12-dual-path-handoff.md) arm D (stream-clocked groomer per leg) upward: source → {publisher(s)} → {relay(s)} → exporter → groomer → RTP/UDP, with failure injection points at each hop. |
| Hosts | Two EC2 instances in separate availability zones (`<EC2_IP_A>`, `<EC2_IP_B>`), matching the cross-host 1+1 topology already used in T12; loopback shakeout first. |
| Source | Video-only tightly VBV-constrained clip from T12 (2 Mbps CBR) for comparability; multi-track arm optional once [#2829](https://github.com/moq-dev/moq/issues/2829) lands. |
| Receiver | Reference merge oracle — [`t12-merge-oracle.py`](scripts/t12-merge-oracle.py) for groomed-leg selection; **new or extended oracle required** for pre-groom MoQ object or TS byte merge from two relay subscriptions (limitation acknowledged in advance). |
| Cluster | Two `moq-relay` instances with peer dial (`relayA.toml` / `relayB.toml` pattern from T6); GSO enabled on Linux per [T26](test-26-cross-host-fanout.md) correction. |
| Grading | Byte-domain or RTP-domain: media lost, continuity errors, PCR discontinuity; reconnect time recorded but subordinate. Impairment on path via `netem` where needed. |

## Procedure

Run in order of increasing topology depth; do not re-run T12 egress cells except as controls.

**Control — T12 arm D cross-host, single failure at egress path.** Confirm the existing hitless baseline
still holds on the current build before moving upstream.

**Variant 1 — Two relays, one publisher.** One `moq import ts` publisher fanning to relay A and relay
B (or one relay peering to the other). Receiver subscribes to both relays *before* grooming — two
`moq export ts` or one exporter with dual subscription if supported — then grooms and packetises.
Fail: kill relay A; kill relay B; 100 % loss on path to A; switch receiver preference from A to B
while both live.

**Variant 2 — Two publishers, two relays.** Independent publisher chains from the same paced source
(file fan-out via `tee` or duplicate regulate). Receiver merges upstream. Fail: kill publisher A;
kill publisher B; kill one relay; asymmetric delay on one path.

**Variant 3 — Cluster mesh with receiver-side selection.** `relayB` dials `relayA` as cluster peer;
subscribers attach to one relay but both paths carry the broadcast. Fail active relay; observe whether
cluster reselect substitutes for receiver merge or interferes with it. This is the meshed variant
left open in [T12](test-12-dual-path-handoff.md).

**Variant 4 — Preferred-leg failure.** Both paths healthy; receiver locked to leg A; fail A. Measures
whether selection rules match ST 2022-7 intent (immediate switch, no gap) when the failure is upstream
of the groomer.

Each failure: inject at known time, capture merged output (or single egress if merge is impossible),
grade against control. Three repeats per cell unless first run is deterministically identical.

## Metrics

Graded at the merged groomed egress (P1 file, RTP capture as in T12):

- **Media lost (headline)** — seconds of programme time absent or duplicated in the merged output.
- **Continuity errors** — count in the failure window.
- **PCR discontinuities** — count and maximum jump.
- **Hitless boolean** — true iff media lost = 0 and continuity errors = 0 for the failure event.
- **Reconnect time** — secondary; time to first byte on the surviving leg and time to stable merge.
- **Cluster/subscription events** — relay logs, resumption signals ([#3312](https://github.com/moq-dev/moq/pull/3312));
  diagnostic only.

Compare outcomes to [T30](test-30-segmented-distributed-resilience.md) equivalent cells where a
paired comparison is fair (same failure class, matched rate).

## Pass criteria, fixed before running

1. **Control reproduction.** T12-equivalent single-track cross-host arm D under one injected blackout
   matches the established hitless criterion: 0 media lost, 0 continuity errors — or the run stops and
   the build is not graded further.
2. **Hitless definition.** "Hitless" means 0 s media lost and 0 continuity errors at the merged
   output for the injected failure duration; any other outcome is reported as seconds of programme
   cost.
3. **Relay reselect alone (Variant 1, relay kill with single subscription).** Expected to *fail* hitless
   by design; pass criterion is documenting media lost ≥ detection interval minus exporter cushion, consistent
   with [T6](test-6-relay-resilience.md) — a falsifiable check that the experiment reached the known
   floor rather than a product pass.
4. **Dual-subscription merge (Variants 1–2, receiver holding both paths).** For single-track source:
   hitless (0 media lost, 0 continuity errors) for single relay failure, single publisher failure,
   and 5 s path blackout — the same failure classes [T12](test-12-dual-path-handoff.md) applied at egress.
   Any non-zero media lost is a fail of the hypothesis that upstream 1+1 can match egress 1+1.
5. **Cluster mesh (Variant 3).** Pass is *documented interaction*: cluster reselect neither improves nor
   degrades media lost versus dual-subscription without peering by more than 0.5 s programme time;
   unexpected duplication or time-travel is a fail.
6. **Multi-track.** Until [#2829](https://github.com/moq-dev/moq/issues/2829) is verified fixed,
   multi-track cells are run for regression recording only; hitless criterion is not applied to them.

## Limits, stated in advance

- **Software receiver only.** No hardware IRD merge; Gate 2 remains [T7](test-7-timing-integrity.md)/P2.
- **Single-track is the load-bearing case.** Multi-track residue at 75.56 % is a known upstream limit
  ([T12](test-12-dual-path-handoff.md)); this test does not re-litigate exporter interleaving except
  as an optional regression arm.
- **Independent restart of one leg** (continuity counters per process,
  [moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779)) remains blocked upstream; late-join
  and recovered-leg byte identity are T12/E, not this file.
- **Segmented lane comparison** is [T30](test-30-segmented-distributed-resilience.md); MoQ-specific
  subscription semantics are not mirrored there.
- **Geographic diversity** is two AZs in one region unless extended; RTT and loss profiles from
  [T26](test-26-cross-host-fanout.md) apply.

## Why this has not run

The campaign finished egress 1+1 first because it is what a broadcast head-end terminates ([T12](test-12-dual-path-handoff.md)),
and because relay reselect alone was already known to be insufficient ([T6](test-6-relay-resilience.md)).
Building Variant 1–3 needs a merge oracle that operates on dual relay subscriptions — the existing
[`t12-merge-oracle.py`](scripts/t12-merge-oracle.py) assumes two groomed RTP legs and cannot grade
pre-groom divergence. [P1-b](planned-experiments.md#p1--establishes-where-one-architecture-is-superior)
ranks this after the failure-injection grader ([T28](test-28-failure-injection-matrix.md)) and cross-host
fan-out ([T26](test-26-cross-host-fanout.md)), which supply apparatus and method rules this test inherits.
