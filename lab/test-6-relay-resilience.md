# T6 — Relay resilience & active/active source failover

## Objective

Measure recovery time and stream continuity when a relay fails and when a subscriber reconnects,
separate *transport resilience* (does a client survive a relay restart / dropped session?) from
*service redundancy* (does an active/active pair fail over without the receiver noticing?), and
establish the ST 2022-7 output-determinism precondition for a hitless dual-path pair.

> Of the four issues this experiment reported upstream, **two were real defects and two were
> artefacts of our own harness**. Both artefacts, and the method rules that follow from them, are
> recorded under [Corrections](#corrections) — they are the most transferable output of this drill.

## Environment

- Media-aware lane, loopback. `moq` / `moq-relay` 0.8.7 (`feat/mux-ts-dvb-service-layer`), TSDuck
  3.44, Darwin 25.5.0. Source `~/CNNiEMEA2.ts` looped via `tsp regulate --pcr-synchronous`. All
  clients `--client-quic-gso=false`; negotiated wire **`moq-lite-05`** unless noted.
- Each drill runs relay(s) + publisher(s) + subscriber(s) + timed kills inside a single shell
  invocation (the local background-process constraint). Scripts and relay configs under
  `~/t6-redundancy/` (`failover.sh`, `cluster_failover.sh`, `reconnect.sh`, `graceful_exit.sh`,
  `renumber_takeover.sh`, `src_failover.sh`, `relayA.toml`, `relayB.toml`). A one-row-per-second byte
  sampler on each subscriber output makes the failure instant visible.
- ST 2022-7 determinism study: `mpegts-pacer` 0.1.0, TSDuck 3.44, FFmpeg 8.1 (Darwin 25.5.0).
- **Builds.** The drill outcomes below are the current state on the **0.14.8 release** (`moq-relay`
  0.14.8 / `moq-cli` 0.9.8 / `moq-net` 0.2.9). The same drills were run on each intervening release
  from 0.8.7 onward as the routing, detach and resume paths were rewritten upstream; the outcomes did
  not change, and the two places where a *result* moved are called out where they occur (the 4-packet
  startup offset, and the reconnect ceiling). Note some release binaries cosmetically self-report an
  older `--version` string than the release they are built from; trust the in-tree crate versions.

## Procedure

Three drills:

1. **Relay restart / QUIC reconnect / publisher + exporter lifecycle** (`reconnect.sh`). One relay,
   one `moq import ts` publisher, two `moq export ts` subscribers. Kill the relay mid-stream, restart
   on the same port, observe re-establishment and TS resume. A second pass sets
   `--client-quic-idle-timeout 3s` so a hard-killed (no CONNECTION_CLOSE) session is detected quickly
   instead of after the 30 s QUIC idle default.
2. **Active/active failover, single relay** (`failover.sh`). One relay, two publishers announcing the
   **same** broadcast (`red.hang`) as a hot pair, two subscribers. Kill the active; observe re-splice.
3. **Active/active failover, two-relay mesh** (`cluster_failover.sh`). `pubA→relayA:4443`,
   `pubB→relayB:5443`, `relayB` dials `relayA` as a cluster peer, both subscribers on `relayA`. Kill
   `pubA`; observe whether `relayA` fails its source over to `pubB` across the mesh.

**Kill semantics matter.** SIGKILL the whole `tsp | moq import` pipeline in one pass
(`pkill -KILL -P`). Killing `tsp` first feeds the importer a truncated stream + EOF, which shuts the
broadcast down *cleanly* — a different code path that grades graceful detach, not source failure.
**Grade beyond one idle timeout** (a hard kill sends no close frame; the relay serves the dead source
until `DEFAULT_IDLE_TIMEOUT` = 30 s). The drill derives its window from `IDLE_BUDGET` (default 30 s;
`SIDLE` sets `--server-quic-idle-timeout` for a fast variant).

For the graceful-exit case (`graceful_exit.sh`): `pubA` publishes a **finite** clip (so `tsp` reaches
EOF and the importer finishes without truncation) and the standby joins at t=2 (so the timeline offset
is negligible); `pubA` ends at t=25 with the standby announced since t=2.

## Results

### ST 2022-7 output-determinism precondition

ST 2022-7 reconstructs by matching RTP sequence numbers, so a dual-path pair is hitless only if the
two egress legs are **byte-identical and sequence-aligned**. Method: offline `cbr_file`
reproducibility (pace the same clip twice, compare SHA-256), a scheduler-level probe driving the real
scheduler with two seeded arrival/emit-jitter timelines over a 20 s VBR clip, and `run-twice`
determinism checks of FFmpeg (`-muxrate`) and TSDuck (`pcradjust`) references.

- **Single-leg CBR/PCR conformance holds** exactly as in T2/T3 (byte-locked PCR, 0 `pcrverify`
  violations @ 500 µs, 0 % > 40 ms). PCR is a pure function of output byte position
  (`byte_offset × 8 × 27 MHz ÷ mux_rate`), the same model FFmpeg and TSDuck use.
- **A single groomer is deterministic (offline / stream-clocked):** the same input paced twice
  yields identical SHA-256 (fixed-rate and `auto`), matching FFmpeg CBR remux and TSDuck `pcradjust`.
- **Two *independent live* pacers are not byte-identical.** The live real-time path gates its
  content-vs-null interleave on the wall-clock instant each datagram is emitted, so injecting as
  little as **50 µs** of emit-scheduling jitter into one leg reshuffles which stuffing slots carry
  content and diverges the two byte streams within ~30 ms — even though total content/null counts
  stay equal and each leg stays independently conformant. Non-determinism sources: wall-clock-gated
  content release; an evolving arrival-timing-dependent media-rate estimate; a first-arrival start
  anchor; and per-process RTP SSRC / timestamp / sequence origin.

Two routes close it: (a) drive live emission and RTP framing from *stream time* (lock the mux rate,
anchor to a stream-intrinsic point, derive RTP sequence/timestamp/SSRC from stream position); or (b)
the standard ST 2022-7 sender pattern — groom **once** and duplicate the identical RTP packets onto
both paths. Positioning: neither SRT nor Zixi hands a hardware IRD a native ST 2022-7 pair on its own,
so a MoQ subscriber + `mpegts-pacer` is no worse than an SRT/Zixi hand-off on this axis.

### Transport-resilience drills — working

- **Redundant outputs (fan-out).** Two independent `moq export ts` subscribers produce byte-identical,
  continuous captures. Fan-out to N subscribers → N pacers → N IRDs works today with no extra
  machinery.
- **Publisher transport reconnect.** After a relay restart the `moq import ts` publisher redials the
  same URL and re-announces automatically on each new session. (`rs/moq-native/src/reconnect.rs`,
  wired at `rs/moq-cli/src/main.rs`.)
- **The reconnect loop backs off.** Exponential backoff (initial 1 s, ×2, max 30 s, give-up 5 min);
  auth errors terminal.
- **A two-relay cluster forms and carries the media-aware TS end to end** (`moq-lite-05`), including
  two publishers of the same broadcast coexisting on separate relays without collision.
- **`moq export ts` subscriber survives session loss and resumes automatically** (fixed by
  [#2469](https://github.com/moq-dev/moq/pull/2469)). Across a relay kill+restart both exporters
  freeze at the kill, resume once the publisher re-announces, and are byte-identical before and after
  the gap. The gap = idle-timeout detection + reconnect backoff + re-announce: **automatic and
  bounded, not hitless**; the content gap is a clean object-boundary skip absorbed downstream.

### Limitations observed

- **Failure detection on a hard kill is gated by the QUIC idle timeout** (default 30 s,
  `--client-quic-idle-timeout`), so recovery is dominated by detection, not the ~1 s backoff. Idle
  timeout must stay **above** the keep-alive interval or a healthy reconnected publisher flaps at the
  keep-alive period.
- **Naive active/active on one relay collapses the stream.** Two publishers announcing the same
  broadcast to one relay do not form a standby pair — the moment the second announces, the relay
  declares the path `unroutable` and tears down **both** (`Error: moq: unroutable`). A 1+1 pair needs
  two relays and a shared `--origin`.

**Why the mesh needed a routing fix, which #2473 supplied.** Before that fix a two-relay mesh
tolerated the pair but did **not** fail over: with `pubA→relayA` / `pubB→relayB` meshed, both
coexist, but killing `pubA` left `relayA` unable to re-splice, and `sub1` stayed frozen for the rest
of the window — graded beyond one full idle timeout (a 68 s control), so this is the mechanism and
not the detection budget. The origin already implemented multi-source splice
(`rs/moq-net/src/model/origin.rs` `best_route`/`reselect`, unit test `test_route_failover`); the
drill never reached it. What #2473 adds is the *selection* rule that makes a relay offer a peer a
route other than the one it is already serving through. Our original diagnosis — that `relayB` never
emitted the standby announcement at all, suppressed by announce coalescing and the split-horizon
`exclude_hop` filter — was withdrawn (see [Corrections](#corrections)); what `relayA`'s route table
actually held before the fix was never re-established, and only the failure to reselect is measured.

This also explains why `moq-lite-06` cost routing is **necessary but not sufficient** on its own:
with both relays and all clients opted in (#2424 — a standby seeds a high `route.cost`, the winner's
drops to 0 while it carries), the mesh drill behaved exactly as before, because pricing decides
between the routes a relay is willing to offer and does not create one.

### Mesh source failover works, bounded by detection

[#2473](https://github.com/moq-dev/moq/pull/2473) (*"fail over across redundant publishers via
per-peer route selection"*, addressing #2461) is what makes the two-relay drill pass. It adds per-peer
announce selection (a relay advertises the best route whose hop chain *excludes* the requesting peer),
exclusion-aware serving, first-hop content identity in SETUP, and a `moq --origin <id>` knob so a 1+1
pair declares itself interchangeable. Model/wire unit tests pass
(`excluded_peer_receives_the_standby`, `standby_attach_announces_to_excluded_peer`,
`test_standby_join_splices_live_subscriber`, `origin_round_trip`, plus per-track regressions
`test_standby_missing_track_keeps_incumbent`, `test_unservable_track_retried_by_a_later_request`).

- **Failover works.** `sub1` on relay A resumes **~30 s after `pubA` is killed** and runs to the end
  of the window. The debug log shows the whole mechanism: relay A announces its local route
  (`announce broadcast=red.hang hops=1`); while relay B is merely carrying via relay A it correctly
  advertises nothing (`no advertisable route for this peer exclude_hop=…`); the instant standby `pubB`
  joins relay B it emits `announce broadcast=red.hang hops=2` to relay A, so relay A holds the standby
  **before** it needs it; on detection relay A reselects (`unannounce (filtered route)` →
  `reannounce`).
- **The shared-`--origin` teardown is fixed.** `sub3` on relay B survives `pubB`'s join with **zero
  `unroutable`** in any client log, where it previously died with `Error::Unroutable` (`code=30`).
- **Recovery latency is one QUIC idle timeout** — detection-bound, not mechanism-bound. Lower
  `--server-quic-idle-timeout` to shorten it.
- **Reliability:** with the pipeline SIGKILLed in one pass, **4 of 4 runs failed over at full rate**,
  resuming at 30, 32, 32 and 33 s. Recovery is *complete*, not merely present. Repeat runs across
  every subsequent release land in the same 29–34 s band.

One adjacent fix that does *not* touch this case, since it is easy to assume it would:
[#2556](https://github.com/moq-dev/moq/pull/2556) (*"prefer the newest route so a reconnect takes over
immediately"*) addresses a publisher reclaiming *its own* path on reconnect, and states outright that
shared-origin 1+1 standbys are unaffected. Its same-origin recency tie-break cannot fire here because
the active (local, `hops=1`) and standby (mesh, `hops=2`) routes differ on cost, so cost decides
before recency.

### Graceful source departure is not failed over at all

When the active publisher exits *cleanly* instead of being killed, the relay does **not** reselect
onto the announced standby; it propagates completion. Both media tracks log `subscribe complete`, the
catalog subscription is `canceled (idle)`, no route change is attempted, and the subscriber's `moq
export ts` **terminates** with `Error: TS track layout changed after PAT/PMT was emitted: '0.avc3'
removed`. Verified with `graceful_exit.sh` (finite clip, standby announced 23 s prior): `sub1` emits
**zero bytes for the remaining 24 s**. So the covered case is the *harder* one (host loss); the easier
and far more common one — SIGTERM to an encoder, a container rescheduled, a rolling restart — is
uncovered, and a shared `--origin` buys nothing here. Adjacent to but distinct from #2469 (which
fixed the exporter's `json: dropped` on session *loss*; here the session is healthy and it is the
*catalog* changing under the muxer). Plausibly intended MoQ semantics rather than a defect, and it
persists across every release tested. Proposed remedies: an announcement `epoch`
([#2330](https://github.com/moq-dev/moq/issues/2330)) or the typed announcement lifecycle
(#2216/#2217); an independent report on #2330 measures the same gap as a multi-second consumer outage.
The spec-level fix is moq-lite-06 **broadcast epochs / ended-broadcasts**
([#2611](https://github.com/moq-dev/moq/pull/2611), drafts), which is not yet on the wire.

### Single-relay reconnecting-publisher takeover is not clean

The scenario of [#2534](https://github.com/moq-dev/moq/pull/2534) (*"deliver groups from a takeover
source that restarted its numbering"*, closed unmerged as *"fixed by #2556"*) on the TS path, drilled
with `renumber_takeover.sh`: one relay, a `moq export ts` subscriber, pubA SIGKILLed after ~15 s, pubB
rejoining the **same** broadcast ~1 s later as a fresh session with restarted group numbering. The
same PR carries an independent production report — a `@moq/net` subscriber starved for the
broadcast's age after a publisher restart, bisected clean on v0.14.1 and broken from v0.14.2 (the
#2469 linger).

- *Fresh identity (no `--origin`):* the exporter **terminates** with `Error: json: dropped` the
  instant pubB attaches — the takeover replaces rather than splices, dropping the catalog
  subscription. Reproduced on every run.
- *Shared `--origin` (interchangeable source):* the exporter **survives** and delivery **resumes**,
  but only after a gap of ~the join delay (~17 s frozen for a 15 s pubA, then steady growth to the
  end). That 1:1-with-join-delay scaling is exactly the independent-copy timeline-offset artefact
  documented under [Corrections](#corrections) (both publishers replay the same clip from its start),
  so this drill **cannot** separate it from the #2534 splice-floor starvation — a timeline-aligned
  rerun (pubB's media clock continued from pubA's, not restarted) is needed to attribute it.

**Bottom line:** #2556 does **not** make the single-relay TS reconnecting-publisher takeover hitless —
fresh identity crashes the exporter, shared origin gaps it. The recommended posture (a fully doubled
chain with receiver-side ST 2022-7 selection) does not depend on this path, but a naive "publisher
reconnects to the same broadcast" is unsafe for a downstream `moq export ts`, and whether the
shared-origin residual gap is our clock skew or the #2534 splice-floor is still open.

### Single-source 1+1 failover — the requirement is a common source, not byte-identical numbering

The maintainer's position on #2545 is that *"if you're publishing two separate broadcasts (different
timestamps, codecs, segments) with the same name then failover is impossible … the application needs
to reinitialise everything on a switch"*. Testing that requires a rig built around **one source
feeding both publishers**, which is what a real 1+1 pair is — two views of a single feed, not two
encodes. (A drill that feeds the two publishers *independent copies* of a clip measures its own clock
skew instead; see [Corrections](#corrections).)

**Why the source matters, from the code.** A publisher's moq group sequence numbers are a per-importer
counter reset to 0 at its first keyframe (`append_group()` → `max_sequence + 1`, seeded 0, in
`rs/moq-net/src/model/track.rs`); PTS and track names come from the source bytes (PMT-derived
`unique_track` names; PCR/PTS from the TS). So two importers emit an *identical* broadcast only if
they consume the same bytes from the same keyframe. Prediction: co-started publishers align exactly;
a late/mid-stream joiner is offset in group numbering (its group 0 = the primary's group N).

**Rig** (`src_failover.sh`, two meshed relays 4443/5443, `sub1` on relay A watched for failover,
`sub3` on relay B; shared `--origin`; hard-kill = SIGKILL the active importer only, source survives):

- **E1 — byte-identical** (`MODE=gtee`): one `tsp regulate` source fanned by `gtee --output-error=warn`
  into two co-started importers (both open their fifo before the source flows, so both get byte 0).
  `gtee` keeps feeding the survivor when the killed importer's fifo reader closes (EPIPE, not block).
- **E2 — mid-stream standby** (`MODE=mcast`): one live multicast feed (`tsp -O ip 239.255.42.99:5000
  --local-address <en0> --ttl 1`, host-local); `pubB` joins the running feed ~11 s after `pubA`, so
  its group numbering is offset by construction. This is the production shape (publishers always join
  an already-running feed).

**Results** (hard kill, default 30 s idle unless noted):

- **E1 proves the broadcasts are identical in content.** `sub1` (relay A/pubA) and `sub3` (relay
  B/pubB) grow with **identical per-second deltas** before the kill, separated only by a **constant
  752-byte (= exactly 4 TS packets) startup offset** on one leg — so steady-state content is
  byte-identical and only the initial emission differs by a 4-packet preamble. (On builds before the
  codec/track split [#2636](https://github.com/moq-dev/moq/pull/2636) and the origin-model changes,
  the two legs were byte-for-byte equal including the preamble.) Kill pubA → `sub1` resumed **~31 s
  later**, output TS **0 CC errors**, one `current group evicted; skipping to next buffered group`.
  `gtee` kept feeding pubB throughout (sub3 uninterrupted).
- **E2 — the mid-stream offset does NOT break failover.** Despite pubB's group numbers being offset,
  `sub1` still reselected onto pubB and resumed **~30 s after the kill**, TS **0 CC errors**, and the
  exporter **subscribed once** (`catalog.json`, `0.avc3`, `1.ts`, `2.ts`, `3.ts`, `4.ts`, `0.mp2`,
  `0.ts`) and **never re-subscribed or reinitialised the catalog** across the switch — a single
  `current group evicted; skipping to next buffered group error=Hang(Moq(Remote(24)))`.
- **Mechanism.** The exporter navigates by track name + live edge, not absolute group number: on the
  reselect it drops the evicted (dead-pubA) group and resumes at pubB's current live edge. So the
  binding requirement is a **common source** — identical PMT/track layout and a consistent PTS
  timeline, both guaranteed by one feed — **not** byte-identical segmentation. Exact group-sequence
  identity is *sufficient* (E1) but not *necessary* (E2).

**"0 CC errors" is not "hitless."** Continuity_counter is a property of the exporter's single output
mux, which never resets, so it stays clean across the splice and the TS is structurally valid/playable.
The ~30 s outage instead shows up as a **PCR/PTS discontinuity** — `tsp analyze` reports `pcrleap=3`
on the video/PCR PID (PID 111) while CC errors stay 0 — i.e. the media clock jumps forward over a
content hole. Valid TS, but a real gap: **break-before-make**, not make-before-break.

**Can the gap shrink?** The ~30 s is the QUIC idle timeout (a hard kill sends no CONNECTION_CLOSE, so
the relay serves the dead source until idle expiry). It is tunable via `--server-quic-idle-timeout`
(with keep-alive kept below it):

| relay idle (`RIDLE`) | reselect after kill | outcome |
|---|---|---|
| 30 s (default) | ~30–31 s | ✅ clean |
| 10 s | ~11 s | ✅ clean |
| 5 s (keep-alive 1 s) | — | ❌ only the trailing buffered group drained, then stalled; failover did not complete |

So detection is reliably reducible to **~10 s**; a few seconds is fragile (the tight idle/keep-alive
starts tearing down healthy sessions). **Sub-second / hitless is not reachable by relay reselect**,
which is inherently detect-then-switch. True hitless needs make-before-break at the *receiver* —
subscribe to both legs concurrently and switch locally with zero detection delay (ST 2022-7 style).
The common-source result above is exactly what makes that receiver-side hitless switch feasible: the
two legs are the same broadcast, so an IRD can merge them. MoQ does not do this dual-carriage natively.

**Bearing on the maintainer's claim.** Confirmed in substance: with a common source the switch is not
hitless and the consumer does re-anchor to the new live edge. Refined in one respect: byte-identical
*segmentation* is not required — a mid-stream joiner with offset group numbers still fails over
cleanly, because the exporter skips to live rather than demanding group-number continuity. What would
genuinely make failover "impossible" is a divergent **track layout / codec** across the pair (two
independent encodes), which a single shared source rules out by construction.

### What the cluster/detach/resume rewrite changed

A dense sequence of upstream merges rewrote the exact routing, resume and detach paths these drills
exercise. **No drill outcome changed**, which is the main thing to record — but the machinery beneath
them did, and the resume path the mid-stream-standby drill exercises is now the hardened one. The
relevant PRs:

- **#2629 — MoQ Cluster extension over moq-transport.** Generalises the mesh machinery #2473 gave
  moq-lite (append own Hop ID, discard a path already containing our Hop ID = loop prevention,
  saturating link cost, advertise `0` while actively carrying then restore after a grace period, serve
  by per-peer exclusion) to the IETF draft-17+ path, and **consolidates the policy into one place**
  (`advertisable_routes` / `outgoing_cost` / `COST_LINGER` in `model/broadcast.rs`, called by both the
  lite and IETF publishers). Link cost is now **per-direction** (paid-egress model). Also fixed a
  pathless-advertisement interchangeability bug that "tore down the source a client was resolving a
  track through," and a reflected-replacement leaving a superseded route attached.
- **#2616 / #2654 / #2659 — namespace detach semantics.** An abnormally-lost namespace stream now
  detaches **abruptly**, holding the front open for the origin's linger (moq-relay gives its cluster
  origin a 5 s window) so a source re-attaching within the window splices back — the mesh analogue of
  the #2469 exporter linger. #2659 also fixed a bug live on `main`: on IETF v14-16 a routine
  `PUBLISH_NAMESPACE_DONE` decoded as `UnexpectedMessage` and closed the **whole session**.
- **#2664 — v14/v15 namespace lookup keyed by direction.** In a mesh where two relays advertise the
  same path to each other, a terminal message could tear down the wrong stream. IETF v14/15 only.
- **#2666 — origin resume/route hardening.** Fixes that touch our resume path directly: an
  empty-segment failover no longer turns a live-edge subscription into a **full-history backfill**; a
  standby joining a live front before it has created every track **no longer kills the incumbent's
  subscription** (the refuser is ruled out of that one track only); unbounded segment accumulation is
  pruned; a stranded logical track on takeover failure is aborted; fetch gained failover.

Two effects of this work are visible in the drills:

- **The resume path is hardened where it matters to us.** E2 (standby joining mid-stream) resumes as a
  buffered-group drain, **not a full-history backfill** — the #2666 live-edge fix holding. The
  incumbent is **never torn down by the partially-joined standby**, the case #2666 specifically
  hardens. `sub3` logs a transient `subscribe error … code=13` on every track at the kill instant,
  then reselects.
- **Two co-started exporters are no longer byte-identical from the first packet**, differing by the
  4-packet startup preamble described under E1 above. Steady-state content is unaffected.

Not drilled: a dedicated **relay↔relay transient-blip** to exercise #2616's abrupt-detach-with-linger
splice-back. It cannot be isolated cleanly in this single-host loopback rig without peer-link fault
injection, and upstream covers it with mutation-checked tests
(`a_lost_namespace_stream_leaves_the_linger_window_open`, `the_last_owner_out_decides_the_detach`). Left
as a future harness item (loopback `netem` on the cluster-peer connection).

### Spec cross-check: the standard specifies relay object-dedup that this implementation does not

An external briefing (Quortex, "Running Multiple Sources over Media over QUIC") describes MOQT
active-active as *relays de-duplicate bit-for-bit-identical sources at the object level, ST 2022-7
style*, whereas these drills show `moq-dev`/`moq-lite` doing **content-agnostic route selection**.
Checked against **draft-ietf-moq-transport-19**, the briefing is faithful to the draft; the divergence
is **implementation**, not spec:

- **§9.3 Multiple Publishers.** *"Relays MUST handle Objects for the same Track from multiple
  publishers and forward them to matching Established subscriptions. The Relay SHOULD attempt to
  deduplicate Objects before forwarding, subject to implementation constraints."* So relay object-dedup
  is the standard's model — a **SHOULD**, hedged by "implementation constraints."
- **§9.1 Caching Relays.** Dedup is keyed on **Full Track Name + Group ID + Object ID**; on a collision
  a relay *"MAY ignore subsequently received Objects"* (first-copy-wins, the ST 2022-7 analogue). A
  duplicate object with a *different* Forwarding Preference, Subgroup ID, Priority **or Payload** →
  the track is **Malformed**.
- **§2.4.2 Malformed Tracks.** On a Malformed track a relay *"MUST immediately terminate downstream
  subscriptions with PUBLISH_DONE"*. So the briefing's "two sources that disagree → treated as broken,
  data dropped, receivers disconnected" is **also** spec-accurate.
- **Make-before-break** is in the draft too (the network-migration text): the relay subscribes to both
  sessions and *"will attempt to deduplicate Objects received on both subscriptions … the subscriptions
  downstream from the relay do not observe this change."*

Two things separate that from what we measured, and both matter:

1. **`moq-dev`/`moq-lite` implements the permitted *alternative*, not object-dedup.** Its multi-source
   model is per-peer route selection + a `moq --origin` interchangeability declaration
   (`rs/moq-net/src/model/origin.rs` `best_route`/`reselect`); the relay never inspects object bytes and
   never de-duplicates at the object level. That is a legitimate reading of "SHOULD … subject to
   implementation constraints," but it means the **content-agnostic route-selection + break-before-make
   reselect** we characterise is *this implementation's* behaviour, **not** MOQT's ceiling. `moq-lite` is
   also a simplified variant, not the draft verbatim; the maintainer's "content-agnostic, won't bridge
   two broadcasts" is a (core-author) design stance that diverges from the §9.3 SHOULD.
2. **Even spec-conformant dedup needs identical object *identifiers*, not just identical media bytes.**
   Dedup keys on Group ID + Object ID (§9.1), and a MoQ group sequence number is a **per-importer counter
   reset to 0 at the first keyframe** (`append_group()`, `rs/moq-net/src/model/track.rs`) — so two
   independent publishers of one feed do **not** naturally share IDs (our E2 mid-stream joiner is offset
   by construction). A dedup relay would not recognise offset objects as duplicates. Spec dedup therefore
   demands encoder+publisher determinism down to **object segmentation and numbering** — the object-layer
   analogue of ST 2022-7's aligned RTP sequence numbers, and a strictly *stronger* bar than "bit-for-bit
   identical output." This is the same determinism wall the ST 2022-7 precondition study hit (two
   independent live pacers are not byte-identical; §"ST 2022-7 output-determinism precondition").

**Bearing on our conclusions.** Unchanged in substance — receiver-side ST 2022-7 selection over a common
source remains the robust, buildable-today posture, and it is *reinforced* by point 2 (aligning MoQ
object numbering across two publishers is at least as hard as the RTP-sequence alignment ST 2022-7 needs).
What changes is **framing**: "a seamless relay-side merge is out of scope" is true of *this
implementation*, not of the standard, which specifies object-dedup as a SHOULD. The genuinely
out-of-scope case in *both* spec and implementation is bridging two *different* broadcasts (timestamp
rewriting) — that is Malformed under §9.1, and is the "won't merge two broadcasts" the maintainer means.
Docs corrected accordingly ([evidence](../docs/evidence.md) §3.4, [architecture](../docs/architecture.md) §8.4/§5.1,
[architecture](../docs/architecture.md) §8.4, [architecture](../docs/architecture.md) §5.5/§14.5).

### Reconnect latency and media retention

- **[#2647](https://github.com/moq-dev/moq/pull/2647) — fail-fast retries (time-bounded jittered
  backoff).** Reconnect ceiling drops 30 s → 5 s and the loop is bounded by a ~10 s budget instead of
  the old 5-minute loop. `reconnect.sh` (kill relay t=12, restart t=24, `--client-quic-idle-timeout
  6s`): both exporters survive, skip the evicted group (`current group evicted; skipping to next
  buffered group error=Hang(Moq(Dropped))` — the resume path, not the fatal `json: dropped`), and
  **`sub1` resumes 4 s after the relay returns**, versus the whole-outage ~16-17 s (which is
  dominated by the fixed 12 s relay-down window). The reconnect log shows the new policy directly:
  capped jittered backoff waits of **0.637 s then 1.51 s**. Separately, `export ts` against a **dead**
  relay now **gives up** — `ERROR reconnect timed out after 10s: connect timed out after 30s` — instead
  of retrying for 5 minutes; wall-clock to the error is **bounded by the QUIC connect timeout** (≈ 30 s
  at the 30 s default, ≈ 17 s at `--client-quic-idle-timeout 8s`), so the 10 s budget stops the endless
  loop while the actual detection time is tunable via the connect/idle timeout. Net: worst-case
  re-attach tightened from ≤ 30 s to ≤ 5 s, and dead-relay detection from 5 min to tens of seconds —
  the axis that matters for supervisor-driven subscriber re-home.
- **[#2615](https://github.com/moq-dev/moq/pull/2615) — 30 s media-track retention + `moq import
  --latency-max`.** The `--latency-max` knob is present on `moq import`. The 30 s retention does **not**
  change live-edge follow: on resume the exporter skipped to the newest group (the reconnect above
  drained **+5.6 MB ≈ a few seconds**, not a 30 s / ~37 MB history replay), because the subscription's
  own `latency_max` still defaults to 0. No effect on our failover behaviour; retention is a relay-side
  *ceiling*, not a playout change.

### The #2701 takeover livelock — the most serious relay defect seen in this campaign

This is a different failure mode from anything these drills grade, and it is recorded because of its
severity and its operational consequence. `serve_track` cleared its
`dead` set on every successful takeover, which un-skipped a *closing but still attached* source; the
reselect then dispatched the corpse, the corpse failed instantly, and the fallback re-selected the
healthy standby — all resolving synchronously, so the task **spun inside a single poll** and pinned a
tokio worker. With as many spinning tasks as workers the process goes dark: no logs, no health
endpoint, no accepts, 100 % CPU, and no path back to a good state. Upstream attributes a production
relay-fleet wedge (three regions, 8+ hours) to it, triggered by **cluster peer session churn** — i.e.
by running exactly the clustered topology this project recommends. It was present in every build
drilled and signed off here, including the 0.14.7 release. These drills never hit it because
provoking it needs a specific wake ordering, which is why upstream's deterministic
`test_active_corpse_does_not_livelock_takeover` is the right net for it and a timed drill is not.
Operational consequence: a clustered relay needs **liveness** monitoring (does it still accept and
serve?), not just a process-alive check, because this failure keeps the process alive and unresponsive.

### Results table

| Scenario | Recovery time | Continuity | Result |
|---|---|---|---|
| Relay restart — **publisher** | ~1 s after detection (= QUIC idle timeout, 30 s default) | resumes (re-announces) | ✅ transport reconnect works |
| Relay restart — **`moq export ts` subscriber** | ~17 s (detection + backoff + re-announce) | freezes at a clean object boundary, then **resumes** | ✅ fixed by #2469 |
| End-to-end stream resumes after relay restart | ~17 s | **yes**, byte-identical across the gap | ✅ fixed by #2469 |
| Active/active — two publishers, **one relay** | n/a | **dies at 2nd announce** | ❌ `unroutable`, both torn down |
| Active/active — two publishers, **two-relay mesh** (hard kill) | **30–33 s** (one idle timeout) | resumes after detection | ✅ since #2473; ❌ before it |
| Active/active — **single source** into both publishers, co-started | ~31 s (one idle timeout); ~11 s at `RIDLE=10s` | resumes; 0 CC errors, PCR/PTS leap at splice | ✅ `sub1`/`sub3` identical per-second deltas pre-kill, separated by a constant 4-packet (752 B) startup offset |
| Active/active — **single source**, standby joins **mid-stream** (offset numbering) | ~30 s (one idle timeout) | resumes; 0 CC errors; exporter never re-subscribes | ✅ offset does not break failover; skips to live edge |
| Active/active — active source exits **gracefully** | none — subscriber terminates | no failover | ❌ on merged `main` |
| Active/active — single-relay **reconnecting** publisher (renumber takeover) | fresh id: none (exporter dies); shared origin: resumes after ~join-delay gap | fresh id: `json: dropped`; shared origin: resumes | 🟡 #2556 doesn't make it clean; shared-origin gap confounded with clock skew |
| Shared-`--origin` standby joins a **carrying** relay | survives; splice immediate | far-relay subscriber keeps flowing | ✅ fixed on merged `main` (was `Unroutable` code=30) |
| `moq-lite-06` cost/standby routing | — | — | 🟡 opt-in; **necessary-not-sufficient** |
| Redundant outputs (N subscribers) | n/a | byte-identical, continuous | ✅ |
| ST 2022-7 single-path loss (hitless drill) | **0 lost packets** at the merged output | **hitless** — blackout, 1 %/3 % loss and up to 200 ms skew all covered | ✅ measured in [T12](test-12-dual-path-handoff.md) against a reference receiver, both for one groomer duplicated onto both paths and for two independent stream-clocked pacers; the on-hardware merge is Gate 2 |

## Corrections

> The general method rules extracted from this section, together with those from every other
> experiment, are collected in [method-notes.md](method-notes.md). What stays here is the
> specific record of what this experiment got wrong.

Four issues were reported upstream from this work. **Two were real defects; two were artefacts of our
own harness.** The artefacts are the more useful record, because each yields a method rule that any
redundancy drill needs.

**Real — the shared-`--origin` `Unroutable` teardown.** A shared-origin standby joining a carrying
relay tore that relay's subscriber down. Real but pre-existing (it reproduces as `json: dropped`), and
now fixed: a standby wins dispatch the moment it attaches, *before* a real publisher has lazily created
every track, and a per-track refusal was being charged as a strike against the whole logical track.
Refusals are now scoped per track with fallback to the incumbent. The drill found a genuine bug the
unit tests missed, because a model-level standby accepts a track request immediately whereas a real
publisher does not.

**Real — the exporter's fatal `json: dropped`** on session loss, fixed by #2469.

**Retracted — "the standby route never reaches the relay serving the active source".** This was an
artefact of the drill, not a defect: announce-interest is unconditional across the cluster. The drill
killed the publisher at t=22 and graded at t=43 — **21 s into a 30 s idle timeout** — so *no* build
could have passed it. (The baseline "no failover on `moq-lite-05`" conclusion nevertheless stands,
corroborated by an extended-window control that stayed frozen for a full 68 s.) *Rule: grade beyond
one full idle timeout, or the drill measures the timeout rather than the mechanism.*

**Retracted — the "8–9 s stall at the standby join".** The reported symptom was that a subscriber on a
relay merely *carrying* the broadcast froze 8–9 s whenever a redundant publisher attached locally. It
does reproduce, but it is not a routing defect: two publishers replaying *independent copies of the
same clip from its start* leave the standby's media timeline lagging the active one by exactly the
join delay, so on splice the exporter is handed timestamps in the past and emits nothing until the new
source overtakes. The stall tracks the join delay with slope 1:

| `pubB` joins at | measured stall |
|---|---|
| t=4 | < 2 s (below the warn threshold) |
| t=10 | 9 s |
| t=20 | 18 s |

The relay's own switch is immediate (relay B logs `subscribe started` for all three tracks in the same
millisecond the standby connects). *Rule: any redundancy test whose sources are started independently
measures its own clock skew unless the feeds are timestamp-aligned.*

Both rules are baked into the drill offered upstream as
[#2545](https://github.com/moq-dev/moq/pull/2545) (`just test failover`), which generates its own
`ffmpeg` source clip (no private capture), grades failover and standby-join survival, reports the join
stall as a measured `WARN`, and depends on `moq --origin` from #2473 (exiting with a diagnostic on
builds without it). It was declined in favour of model unit tests that run on every PR;
[#2713](https://github.com/moq-dev/moq/pull/2713) carried its one load-bearing insight — that a
reselect must be graded *per track* — into those tests instead. See
[upstream-contributions.md](upstream-contributions.md) §3.

## Observations

- Endpoint *reconnect* is solid (publisher and, since #2469, the exporter). Active/active *source*
  failover across a mesh ships (#2473) but is **bounded, not hitless** (one idle timeout), and does
  not cover a graceful source exit at all. This survived the cluster-extension (#2629), detach
  (#2616/#2654/#2659/#2664) and resume-hardening (#2666) rewrite without regression, and the resume
  path the mid-stream-standby drill exercises is now the hardened one (#2666 keeps the incumbent when
  a partially-joined standby refuses a track, and stops an empty-segment failover from backfilling the
  whole history).
- The binding precondition for mesh source failover is a **common source** — identical PMT/track
  layout + consistent PTS — not byte-identical segmentation. A mid-stream/late-joining standby with
  offset group numbering still fails over cleanly (the exporter skips to the new live edge; it does
  not require group-number continuity). Enforce one ingest path into both publishers and the pair is
  interchangeable; keep a second ingest path as *source* redundancy upstream of the publishers.
- "0 CC errors" means the output TS stays structurally valid across the splice, **not** that the
  switch is gap-free: the outage is a PCR/PTS discontinuity (a content hole), sized by detection.
  Detection is reliably tunable to ~10 s via `--server-quic-idle-timeout`; sub-second/hitless is not a
  relay-reselect property and must live at the receiver (ST 2022-7 dual-subscribe over the common
  source).
- Recovery on a hard kill is architecturally detection-bound: a relay has no model of a broadcast's
  expected cadence, so it must wait for the transport to declare the peer gone.
- **Recommended posture, buildable today:** with the exporter crash fixed, no external subscriber
  supervisor is needed for relay maintenance/transient loss. Service redundancy still comes from a
  fully doubled chain — dual publishers → dual relays → dual subscribers → downstream ST 2022-7 /
  IRD failover — letting the *receiver* do hitless selection, and that now includes the grooming
  stage: [T12](test-12-dual-path-handoff.md) measured two independent groomers producing
  byte-identical legs, provided each keys placement to stream position rather than to its own emit
  clock. Two groomers keyed to their own emit clocks do not merge at all. Relay-mesh source failover
  does not change that recommendation now that #2473 has landed. Where quick reconnect matters, lower
  `--client-quic-idle-timeout` (keeping it above the keep-alive).

## Conclusion

Transport resilience holds; active/active source failover now ships, bounded by detection, with a
residual graceful-exit gap. The ST 2022-7 determinism precondition is characterised here (a single
deterministic/offline groom is byte-exact reproducible; two independent live pacers were not, at the
time this was measured — see below). Every
failover number in *this* file is a single-leg recovery time, so it is break-before-make by
construction; the dual-leg drill it points to has since run as
[T12](test-12-dual-path-handoff.md), which grades two concurrently live legs at a receiver and finds
the switch hitless — including the graceful exit that has no single-leg answer. T12 also closes the
determinism question for two live pacers, and the answer turns on whose clock chooses the slot: keyed
to their own emit instants they diverge structurally rather than through PCR re-stamping, and keyed
to stream position they are byte-identical. The full validated finding — including which of our reports were real vs
harness artefacts — is recorded in [`docs/evidence.md`](../docs/evidence.md) §3.4.

## References

- Redundancy model: [`docs/architecture.md`](../docs/architecture.md) §8.4–§6; [`docs/architecture.md`](../docs/architecture.md) §5 (ST 2022-7 §5.1); [`docs/architecture.md`](../docs/architecture.md) §8.4.
- Upstream: [#2469](https://github.com/moq-dev/moq/pull/2469), [#2473](https://github.com/moq-dev/moq/pull/2473), [#2534](https://github.com/moq-dev/moq/pull/2534) (renumbered-takeover, closed unmerged), [#2545](https://github.com/moq-dev/moq/pull/2545), [#2556](https://github.com/moq-dev/moq/pull/2556), [#2565](https://github.com/moq-dev/moq/pull/2565), #2424, #2461, [#2330](https://github.com/moq-dev/moq/issues/2330), #2216/#2217. Cluster/detach/resume rewrite: [#2629](https://github.com/moq-dev/moq/pull/2629) (cluster ext), [#2616](https://github.com/moq-dev/moq/pull/2616)/[#2654](https://github.com/moq-dev/moq/pull/2654)/[#2659](https://github.com/moq-dev/moq/pull/2659)/[#2664](https://github.com/moq-dev/moq/pull/2664) (detach), [#2666](https://github.com/moq-dev/moq/pull/2666) (resume/route hardening), [#2611](https://github.com/moq-dev/moq/pull/2611) (broadcast-epoch drafts), [#2636](https://github.com/moq-dev/moq/pull/2636) (codec/track split).
- Finding: [`docs/evidence.md`](../docs/evidence.md) §3.4.
