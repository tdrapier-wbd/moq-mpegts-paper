# Evidence: What the Prototype Proved (the Credibility Spine)

Status: working draft
Scope: the concrete engineering learnings that ground the claims made in the
[README](../README.md), [vision](vision.md), and [architecture](architecture.md).
These are not hypotheticals; they are things that were
built, measured, or filed upstream in two working repositories
(`moq-publisher-subscriber`, currently private, an engineered opaque MPEG-TS
lane; and issues/PRs/discussions against `moq-dev`, the upstream MoQ
implementation).

This document exists so that the rest of the repository can make claims and cite
evidence for them here, rather than restating the evidence inline. It is the
*narrative* credibility spine; the *executable* companion — exact methods,
commands, and measured result tables (baseline TS, both transport lanes, remote
end-to-end, and network impairment) — lives in [test-plan](test-plan.md), which
this document cites for the hard numbers. The two are kept separate deliberately:
this is the "what we learned and why it matters" for readers of the paper; the
test plan is the "how to reproduce and falsify it" for a sceptical engineer.

---

## 1. The transport is real but unstable — and we architected around it

We transport live MPEG-TS over MoQ end-to-end, over the public internet, via a
cloud (AWS EC2) relay, out to broadcast egress — now demonstrated with a live SRT
contribution feed traversing the whole chain with 0 continuity errors
([test-plan](test-plan.md) §8). On the IETF path we conform to
the MSFTS `m2ts` packaging draft (`draft-gregoire-moq-msfts`) and publish an MSF
catalog. **But** the MoQ wire protocol is moving under us:

- We target **draft-14** (`moq-transport` 0.14.2), which was the production Rust
  transport available when this work was built; it is no longer the only one, and
  the interop target has since moved to later drafts ([transport](transport.md)
  §5.1). Drafts 15–18 are, in the working group's words, "almost a
  completely new protocol": ALPN changes (`moq-00` → `moqt-NN`), control moves to
  per-request bidirectional streams, seven control messages removed, TLV→TV
  parameters, new data-plane encoding. A draft-14 and a draft-18 endpoint cannot
  even agree on an ALPN. Draft-19 now exists.
- **Strategic mitigation already implemented:** our MPEG-TS/MSFTS application
  layer (framing, catalog, reassembly) is *independent of the MoQT draft* and is
  covered byte-for-byte by round-trip and property tests, so a transport upgrade
  is a thin-glue swap, not a media-layer rewrite. This is the concrete basis for
  the "transport is swappable" hedge in [transport](transport.md) §5.2.

**Implication:** the transport is not a place to build a moat; it is a dependency
to track and abstract. (Supports [vision](vision.md) §6, [transport](transport.md),
and the transport-stability risk in the [README](../README.md).)

## 2. The broadcast-grade edge is work that sensibly sits outside transport core

Our subscriber implements an IRD-facing egress layer: RTP/UDP (PT 33) and raw
UDP, multicast, SMPTE 2022-1 FEC, ST 2022-7 hitless dual-path, adaptive de-jitter
pacing, a decoder-safe start gate, and read-only TR 101 290 monitoring. Upstream
has reasonably scoped an opaque TS lane out of core (#1861: "breaks interop with
players that don't support TS") and a generic per-transport egress sink out of
core (#1839: asking for a concrete customer need first). Those are sensible
boundaries for a general-purpose transport, not a shortcoming: they simply mark
where broadcast-specific adaptation belongs — at the platform layer rather than in
the protocol. (Supports [architecture](architecture.md) §4.2 and §7.)

## 3. "Broadcast-grade" ≠ "plays in ffplay" — the PCR/IRD problem is inherent

MoQ delivers objects/groups in bursts, so a reconstructed MPEG-TS has PCR
*intervals* that no longer track a constant mux rate — the bytes (including the
PCR values themselves) are intact, but the delivery *cadence* is not. Soft players
tolerate it; **hardware IRDs lock a PLL to PCR and raise TR 101 290 P1/P2
alarms.** Measured on the media-aware lane, 13–26% of PCR intervals exceeded the
40 ms limit depending on source, both on loopback and over the public-internet
EC2 path ([test-plan](test-plan.md) §6, §8); the opaque lane, fed raw, holds
0% > 40 ms on file ([test-plan](test-plan.md) §7). To be precise about attribution: this cadence problem is the part that
is inherent to MoQ's object model (the same way SRT/Zixi/RIST are bursty on the
wire and groom the TS before hand-off); it is *not* the same as the separate
PCR/PTS *regeneration* problem the media-aware re-mux path has, which the opaque
lane sidesteps by carrying the values verbatim. We built the piece that fixes it:
the public [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) groomer —
byte-locked CBR, monotonic PCR re-stamp, and PCR re-insertion — which the upstream
transport does not provide. Fed the bursty media-aware egress it takes 13–26% of
PCR intervals > 40 ms to **0%**, with **0 `pcrverify` violations at 500 µs**
([test-plan](test-plan.md) §6.7): the pacer delivers CBR/PCR conformance at P1. The
measurement above is file-based and therefore *necessary but not
sufficient*: it confirms the re-stamp arithmetic, but not the real-time pacing
jitter of a software CBR pacer or PCR_accuracy (±500 ns) at the physical output,
which only a hardware analyser/IRD on the live egress can confirm — so the
hardware pass remains the open, load-bearing test. (Supports
[architecture](architecture.md) §7.2.)

## 4. Upstream participation

We file issues upstream (`moq-dev/moq`), (`mondain/msfts`) and are discussing this with a variety of vendors. 
We track the draft migration. The relationship is collaborative: the aim is to feed broadcast
requirements upstream and stay aligned with core, not to fork around it. This is
not aspirational; it is already happening.

## 5. Real broadcast feeds broke naive media-aware import — and opaque carriage sidesteps it

Initially, a real CNN International capture (open-GOP H.264 using recovery-point SEI, ~1 IDR
per 15s) failed to produce a video rendition through the media-aware import path
as it stood (keyframe detection keyed only on IDR NAL type), which then tripped a
misleading SCTE-35/no-video export error. This is common for contribution feeds,
not a niche quirk. **Our opaque m2ts lane carries the TS verbatim** — preserving
SDT/service identity, PMT PID, SCTE-35, teletext, and continuity counters that a
media-aware re-mux discarded — so it sidesteps the whole failure class. This is now
measured end-to-end: on the opaque lane the egress reproduces the source
byte-for-byte (full PSI/SI, SCTE-35, teletext, TSID/ONID, CBR, 0% PCR > 40 ms),
whereas the media-aware lane drops SI and renumbers the PMT
([test-plan](test-plan.md) §7, with the decisive side-by-side in §7.7).

Two honest caveats on this evidence: it records behaviour *as measured at the
time*, and upstream has since **materially closed the gap** — #2072/#2066 fixed the
open-GOP import failure, and [#2440](https://github.com/moq-dev/moq/pull/2440) (a draft
PR) now **preserves the DVB service layer through the media-aware lane** (SDT/NIT,
service name/type, PMT PID, TSID/ONID), leaving only the dynamic TDT/TOT/EIT tables
unpreserved ([test-plan](test-plan.md) §7.7). So this should not be read as a permanent
limitation of media-aware carriage; the point it supports is that opaque carriage is a
lower-risk path *today* (and #2440 was not yet on the EC2 `main` build at test time),
not that media-aware carriage is unviable. (Supports [architecture](architecture.md)
§4.2.)

## 6. The entitlement substrate exists

MoQ's authorization hook at subscription time, plus its relay/subscription and
caching semantics, is a credible *substrate* for **dynamic, revocable,
multi-tenant entitlement and API-driven provisioning** — the control-plane
thesis. Two honest boundaries: the credential profile we enforce there
(path-scoped JWTs, mTLS peer identity, `exp` expiry) is our deployment choice
layered on that hook, not a wire primitive MoQ guarantees across implementations;
and the multi-region cluster mesh (shared subscription/cache state, shortest-path
routing) is distributed-systems work the platform must build, not a behaviour the
base transport supplies. The hooks and semantics are there; the broadcast-grade
*product* on top of them is not. (Supports [architecture](architecture.md) §10–§11.)

## 7. Under real internet loss, MoQ's resilience is a congestion-control choice — and BBR closes the gap to SRT

A granular head-to-head against SRT over the **real EC2→home internet path**, driven
by a `netem` impairment matrix (uniform/bursty loss, reordering, jitter, latency,
bandwidth caps, combined WAN), first looked *catastrophic* for MoQ: under quinn's
**default CUBIC** controller it collapsed under uniform loss ≥ 2 % (53 % delivered at
2 %, 13 % at 10 %), 25 % reordering (20 %), and a combined WAN profile (14 %), while SRT
held full rate throughout ([test-plan](test-plan.md) §12.10). **That first conclusion
was wrong — the collapse was a default-configuration artefact, not a protocol limit.**
A recently merged knob ([PR #2432](https://github.com/moq-dev/moq/pull/2432)) exposes
`--server/client-quic-congestion-control {loss|delay}`; switching the relay to `delay`
= **BBR** (BBRv1 on the quinn backend) removes the collapse entirely — MoQ is then
full-rate and byte-complete through 10 % uniform loss, 25 % reordering, and the WAN
profile, **on par with SRT**. The fix is **sender-local and per-connection**: not on
the wire, not negotiated, no draft/version change, and it preserves relay ⇄ subscriber
interop (a BBR sender talks to any QUIC receiver). Because MoQ is hop-by-hop QUIC it can
even be enabled on just the lossy relay→subscriber hop, using the short relay-edge RTT
as the retransmit loop. (Supports the graceful-congestion claim in the
[README](../README.md), directly informs the "SRT advantage too narrow" thesis-risk
head-to-head, [transport](transport.md) §3.1, and [relay](relay.md) §5.)

The one residual weakness is narrower than it first appears. "Extreme jitter" was the
last condition where MoQ under BBR still under-delivered — but a controlled test
isolates the cause as **packet reordering, not delay variation**: true *in-order*
jitter (`netem slot`, a FIFO that varies timing without letting packets overtake)
delivers **97 %** at 60 ± 30 ms, whereas *non-ordered* jitter of the same magnitude
(independent per-packet delay, which reorders) collapses to ~7–13 %. The mechanism is
QUIC's in-order-stream head-of-line blocking under heavy reordering, so this is a
**QUIC loss-detection / reorder-threshold tuning item, not a CC or protocol flaw** — and
terrestrial paths reorder far less than `netem`'s model; unbounded reordering is mainly
a LEO/mobile-handover concern ([test-plan](test-plan.md) §12.10.1, §9.9). Two honest
boundaries: this is a single home path, one run per condition, forward-path-only
impairment; and BBR here is **BBRv1** (quinn) — BBRv2/v3 (quiche/noq backends) and BBR's
own known trade-offs (fairness, a very-high-loss cliff) remain to be characterised.

## 8. Transport resilience is only half-wired, and active/active source failover is not yet reachable

We audited the shipped `moq-dev` (`moq`/`moq-relay` **0.8.7 @ `5eaf99bc`**) for the
redundancy an active/active broadcast chain needs, combining **source inspection** of
the Rust crates with **experimental drills** on the media-aware TS lane
([test-plan](test-plan.md) §10.5). Every conclusion below is tagged with its basis.
The redundancy model MoQ is built around is sound — thin, single-homed,
auto-reconnecting endpoints with redundancy living in the relay mesh and hitless
selection at the receiver — but two load-bearing pieces are not delivered on the
shipped default wire (`moq-lite-05`).

**Confirmed working.**

- **Redundant *outputs* (fan-out).** Two independent `moq export ts` subscribers
  produced **byte-identical, continuous captures** of the same broadcast in every
  drill (*experiment*, [test-plan](test-plan.md) §10.5.2). Fanning one feed to N
  subscribers → N pacers → N IRDs needs no extra machinery.
- **Publisher transport reconnect.** `moq import ts` uses a reconnect loop
  (*source*: `rs/moq-native/src/reconnect.rs`, wired at `rs/moq-cli/src/main.rs`) that
  redials the same relay with exponential backoff (initial 1 s, ×2, max 30 s; auth
  errors terminal) and **re-announces the broadcast on every new session**
  (*experiment*: relay logs repeated `session accepted role=Publisher` after a
  restart, [test-plan](test-plan.md) §10.5.2).
- **Two-relay clustering carries the media-aware feed and tolerates a duplicate
  publisher.** A relay dialling a peer forms a bidirectional cluster session and both
  publishers of the same broadcast *coexist* without collision (*experiment*,
  [test-plan](test-plan.md) §10.5.2; *source*: `rs/moq-relay/src/cluster.rs`).
- **The `moq export ts` subscriber survives session loss and resumes (fixed by #2469).**
  *This was a confirmed limitation* — the exporter exited with `Error: json: dropped`
  the instant its session dropped, because an origin front closed synchronously on
  source detach. We filed it as
  [moq-dev/moq#2459](https://github.com/moq-dev/moq/issues/2459); it was fixed in
  [#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast *linger* across an
  ungraceful source loss; a consuming session lingers for `backoff.timeout + 1 s`).
  **Verified** (main @ `7c976cd7`, `moq 0.9.1`): under a relay kill+restart both
  exporters stayed alive, skipped the evicted group instead of dying, reconnected, and
  resumed byte-identical output ~17 s after the kill (*experiment*: `sizes_r.csv`,
  [test-plan](test-plan.md) §10.5.3). Recovery is automatic and bounded, not hitless.

**Confirmed limitations.**

- **Failure detection on a hard kill is gated by the QUIC idle timeout** (default
  30 s, `--client-quic-idle-timeout`; must stay above the 5 s keep-alive), so recovery
  time is dominated by detection, not by the ~1 s reconnect backoff (*experiment*,
  [test-plan](test-plan.md) §10.5.3).
- **Naive active/active does not work.** Two publishers on the *same* broadcast at one
  relay collapse the stream — the second announce makes the path `unroutable` and tears
  down *both* (*experiment*, §10.5.3). Across a *two-relay mesh* the pair coexists but
  the relay does **not** fail its source over when the active publisher dies: the
  standby's route is never propagated back (announce coalescing keeps one best route
  per path; split-horizon `exclude_hop` suppresses the return route), so there is
  nothing to reselect (*experiment* §10.5.3; *source*: `rs/moq-net/src/model/origin.rs`
  — the multi-source splice `best_route`/`reselect`/`test_route_failover` exists but is
  not fed a second live route on the wire).

**Work-in-progress — tested, and necessary but not sufficient.** The cost/standby
routing that would *rank* a hot standby as a same-path backup (#2424) lives in
**`moq-lite-06-wip`** (*source*: `rs/moq-net/src/lite/version.rs`,
`rs/moq-net/src/lite/announce.rs`, `rs/moq-net/src/model/broadcast.rs`), which is
deliberately excluded from the default advertised set/ALPN list and negotiates only
when both peers opt in (*source*: `rs/moq-net/src/version.rs` — `Versions::all()` and
`ALPNS`). Re-running the two-relay mesh drill with lite-06 negotiated end-to-end
(`--server-version` + `--client-version`, cluster log `connected version=moq-lite-06-wip`)
**still froze on active-source death, exactly as on `moq-lite-05`** — relay A only ever
held its own local route; relay B never advertised its standby publisher across the
cluster link (*experiment*, §10.5.4). So cost routing is **necessary but not
sufficient**: the blocker is standby-route propagation across the mesh, not route
pricing, and active/active source failover is not a capability today on either version.

**Upstream fix under review — [#2473](https://github.com/moq-dev/moq/pull/2473) (issue
#2461), reviewed + tested 2026-07-24.** #2473 targets exactly this blocker with per-peer
announce selection (advertise the best route whose hop chain *excludes* the requesting
peer), exclusion-aware serving, first-hop content identity, and a `moq --origin` knob for
declaring a 1+1 pair interchangeable. Its **model/wire unit tests pass** on our build
(*experiment*: `test_route_failover`, `test_dispatch_excludes_requester`,
`test_dispatch_all_tainted_unroutable`, `test_publisher_mismatch_parks`). **But the
end-to-end two-relay drill still does not fail over**: across single-dial, full-mesh, and
carrying-peer topologies (both publishers sharing `--origin`), relay A never held a second
route and `sub1` froze permanently on `pubA` death (*experiment*: `cluster_failover.sh` on
`moq-dev @ baeb69b4` with `main`/#2469 merged in). The per-peer *selection* landed, but the
standby *announcement* is still never presented to the node serving the active source —
which is satisfied by its local source and never solicits the peer's standby. Two side
findings: #2473 **predates #2469** and needs its linger for the splice to survive the
source loss (merged locally; suite stays green), and a shared-`--origin` local standby
joining a carrying relay tears down that relay's local subscriber with `Error::Unroutable`
(`code=30`). Feedback + the drill are drafted for the maintainers
(`docs/upstream/pr2473-feedback.md`, `docs/upstream/cluster_failover.sh`). So active/active
source failover remains **not a capability today**, but a targeted fix is in flight and the
remaining gap is now precisely characterised (standby-announce propagation to the
active-serving node).

**Recommended workarounds (buildable now).** The exporter session-loss crash is now
fixed upstream (#2469, verified), so no external subscriber supervisor is needed for
relay maintenance/transient loss; achieve service redundancy with a
fully-doubled chain (dual publishers → dual relays → dual subscribers → dual pacers →
downstream ST 2022-7 / IRD failover), letting the *receiver* do hitless selection
(§10.4, [architecture](architecture.md) §14.1) rather than relying on relay-mesh source
failover. (Supports [transport](transport.md) §8, [relay](relay.md) §5.1, and the
resilience model in [architecture](architecture.md) §14.)
