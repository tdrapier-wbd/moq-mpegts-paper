# T6 — Relay resilience & active/active source failover

## Objective

Measure recovery time and stream continuity when a relay fails and when a subscriber reconnects,
separate *transport resilience* (does a client survive a relay restart / dropped session?) from
*service redundancy* (does an active/active pair fail over without the receiver noticing?), and
establish the ST 2022-7 output-determinism precondition for a hitless dual-path pair.

> This experiment reached several wrong conclusions along the way; per lab discipline those are
> preserved here alongside the corrections rather than erased. Two of the four issues we reported
> were real; two were our own harness (see Corrections).

## Environment

- Media-aware lane, loopback. `moq` / `moq-relay` 0.8.7 (`feat/mux-ts-dvb-service-layer`), TSDuck
  3.44, Darwin 25.5.0. Source `~/CNNiEMEA2.ts` looped via `tsp regulate --pcr-synchronous`. All
  clients `--client-quic-gso=false`; negotiated wire **`moq-lite-05`** unless noted.
- Each drill runs relay(s) + publisher(s) + subscriber(s) + timed kills inside a single shell
  invocation (the local background-process constraint). Scripts and relay configs under
  `~/t6-redundancy/` (`failover.sh`, `cluster_failover.sh`, `reconnect.sh`, `graceful_exit.sh`,
  `relayA.toml`, `relayB.toml`). A one-row-per-second byte sampler on each subscriber output makes
  the failure instant visible.
- ST 2022-7 determinism study (2026-07-20): `mpegts-pacer` 0.1.0, TSDuck 3.44-4676, FFmpeg 8.1
  (Darwin 25.5.0).
- Builds across the campaign: drills on 0.8.7; #2473 verified on head `cc11cbaf` (`moq 0.9.3`,
  2026-07-27); #2473 merged `b624c7c0` (2026-07-28); re-verified on the `moq-net 0.2.5` / `moq-cli
  0.9.5` release (2026-07-30).

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

### ST 2022-7 output-determinism precondition (§10.4)

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
  declares the path `unroutable` and tears down **both** (`Error: moq: unroutable`).
- **Two-relay mesh tolerated the pair but did NOT fail over on `moq-lite-05`** (pre-#2473). With
  `pubA→relayA` / `pubB→relayB` meshed, both coexist, but killing `pubA` left `relayA` unable to
  re-splice: `relayB` never re-announced its local `red.hang` back to `relayA` (announce coalescing
  keeps one best route per path; split-horizon `exclude_hop` suppressed the return route), so
  `relayA` had **no standby route to reselect**. The origin implements multi-source splice
  (`rs/moq-net/src/model/origin.rs` `best_route`/`reselect`, unit test `test_route_failover`) but was
  not fed a second live route.
- **`moq-lite-06-wip` cost routing is opt-in and, alone, insufficient.** With both relays and all
  clients opted in (#2424: a standby seeds a high `route.cost`; the winner's cost drops to 0 when it
  carries), the mesh drill behaved **exactly as on `moq-lite-05`** — pricing has nothing to rank
  because the standby route is never advertised across the mesh. Cost routing is
  **necessary-but-not-sufficient**.

### Upstream fix #2473 — the two-relay drill now passes (2026-07-27 → merged 2026-07-28)

[#2473](https://github.com/moq-dev/moq/pull/2473) (*"fail over across redundant publishers via
per-peer route selection"*, addressing #2461) adds per-peer announce selection (a relay advertises
the best route whose hop chain *excludes* the requesting peer), exclusion-aware serving, first-hop
content identity in SETUP, and a `moq --origin <id>` knob so a 1+1 pair declares itself
interchangeable. Model/wire unit tests pass (`excluded_peer_receives_the_standby`,
`standby_attach_announces_to_excluded_peer`, `test_standby_join_splices_live_subscriber`,
`origin_round_trip`, plus per-track regressions `test_standby_missing_track_keeps_incumbent`,
`test_unservable_track_retried_by_a_later_request`). Live drill (head `cc11cbaf`, `moq 0.9.3`):

- **Failover works.** `sub1` on relay A resumed **30–33 s after `pubA` was killed** and ran to the
  end of the window (+22.5 MB and +25.3 MB in two full-rate runs). The debug log shows the whole
  mechanism: relay A announces its local route (`announce broadcast=red.hang hops=1`); while relay B
  is merely carrying via relay A it correctly advertises nothing (`no advertisable route for this
  peer exclude_hop=…`); the instant standby `pubB` joins relay B it emits `announce broadcast=red.hang
  hops=2` to relay A, so relay A holds the standby **before** it needs it; on detection relay A
  reselects (`unannounce (filtered route)` → `reannounce`).
- **The shared-`--origin` teardown is fixed.** `sub3` on relay B now survives `pubB`'s join (+9.7 MB)
  with **zero `unroutable`** in any client log, where it previously died with `Error::Unroutable`
  (`code=30`).
- **Recovery latency is one QUIC idle timeout** — detection-bound, not mechanism-bound. Lower
  `--server-quic-idle-timeout` to shorten it; upstream is weighing a lower default (~10 s).
- **Reliability:** with the pipeline SIGKILLed in one pass, **4 of 4 runs failed over at full rate**,
  resuming at 30, 32, 32 and 33 s. Recovery is *complete*, not merely present.

Re-verified on the **0.2.5 release** (`moq-net 0.2.5` / `moq-cli 0.9.5`, 2026-07-30): three runs
resumed at 30, 31 and 33 s — unchanged. The intervening fix
[#2556](https://github.com/moq-dev/moq/pull/2556) (*"prefer the newest route so a reconnect takes
over immediately"*) does not touch this case: it addresses a publisher reclaiming *its own* path on
reconnect and states outright that shared-origin 1+1 standbys are unaffected. Its same-origin recency
tie-break cannot fire here because the active (local, `hops=1`) and standby (mesh, `hops=2`) routes
differ on cost, so cost decides before recency.

### Confirmed gap — graceful source departure is not failed over at all

When the active publisher exits *cleanly* instead of being killed, the relay does **not** reselect
onto the announced standby; it propagates completion. Both media tracks log `subscribe complete`, the
catalog subscription is `canceled (idle)`, no route change is attempted, and the subscriber's `moq
export ts` **terminates** with `Error: TS track layout changed after PAT/PMT was emitted: '0.avc3'
removed`. Verified with `graceful_exit.sh` (finite clip, standby announced 23 s prior): `sub1` emits
**zero bytes for the remaining 24 s**. So the covered case is the *harder* one (host loss); the easier
and far more common one — SIGTERM to an encoder, a container rescheduled, a rolling restart — is
uncovered, and a shared `--origin` buys nothing here. Adjacent to but distinct from #2469 (which
fixed the exporter's `json: dropped` on session *loss*; here the session is healthy and it is the
*catalog* changing under the muxer). Plausibly intended MoQ semantics rather than a defect. Still
reproduces unchanged on the 0.2.5 release. Proposed remedies: an announcement `epoch`
([#2330](https://github.com/moq-dev/moq/issues/2330)) or the typed announcement lifecycle
(#2216/#2217); an independent report on #2330 measures the same gap as a multi-second consumer outage.

### Corrections (do not rewrite history)

Of the four issues reported on this work, **two were real** and **two were our own harness**:

- **Real — the shared-`--origin` `Unroutable` teardown** (finding 2). A shared-origin standby joining
  a carrying relay tore that relay's subscriber down. Real but pre-existing (reproduces on `main` as
  `json: dropped`); now fixed — a standby wins dispatch the moment it attaches, before a real
  publisher has lazily created every track, and a per-track refusal was being charged as a strike
  against the whole logical track. Refusals are now scoped per track with fallback to the incumbent.
  Re-verified: far-relay subscriber survives with zero `unroutable`. The drill found a genuine bug the
  unit tests missed, because a model-level standby accepts a track request immediately whereas a real
  publisher does not.
- **Real — the exporter's fatal `json: dropped`** on session loss, fixed by #2469 (above).
- **🔻 Retracted — "the standby route never reaches the relay serving the active source"** (finding 1)
  was an artefact of our drill, not a defect: announce-interest is unconditional across the cluster.
  Our timeline killed the publisher at t=22 and graded at t=43 — **21 s into a 30 s idle timeout** —
  so *no* build could have passed it. (The baseline "no failover on `moq-lite-05`" conclusion
  nevertheless stands, corroborated by an extended-window control that stayed frozen for a full 68 s.)
- **🔻 Retracted — the "8–9 s stall at the standby join"** was our harness too. We reported that a
  subscriber on a relay merely *carrying* the broadcast froze 8–9 s whenever a redundant publisher
  attached locally (`sub3`, `pubB` joining at t=10: 175 k, 162 k, 90 k, eight seconds of zero, then
  13 k, 125 k, 179 k). It reproduces on merged `main` but is not a routing defect: our two publishers
  replay *independent copies of the same clip from its start*, so the standby's media timeline lags
  the active one by exactly the join delay, and on splice the exporter is handed timestamps in the
  past and emits nothing until the new source overtakes. The stall tracks the join delay with slope 1:

  | `pubB` joins at | measured stall |
  |---|---|
  | t=4 | < 2 s (below the warn threshold) |
  | t=10 | 9 s |
  | t=20 | 18 s |

  The relay's own switch is immediate (relay B logs `subscribe started` for all three tracks in the
  same millisecond the standby connects). **Generalisable rule: any redundancy test whose sources are
  started independently measures its own clock skew unless the feeds are timestamp-aligned.**

The corrected drill (both the timeline and kill semantics, documented in-script) is contributed
upstream as [#2545](https://github.com/moq-dev/moq/pull/2545) (`just test failover`): it generates its
own `ffmpeg` source clip (no private capture), grades failover and standby-join survival, reports the
join stall as a measured `WARN`, and depends on `moq --origin` from #2473 (exits with a diagnostic on
builds without it).

### Results table

| Scenario | Recovery time | Continuity | Result |
|---|---|---|---|
| Relay restart — **publisher** | ~1 s after detection (= QUIC idle timeout, 30 s default) | resumes (re-announces) | ✅ transport reconnect works |
| Relay restart — **`moq export ts` subscriber** | ~17 s (detection + backoff + re-announce) | freezes at a clean object boundary, then **resumes** | ✅ fixed by #2469 |
| End-to-end stream resumes after relay restart | ~17 s | **yes**, byte-identical across the gap | ✅ fixed by #2469 |
| Active/active — two publishers, **one relay** | n/a | **dies at 2nd announce** | ❌ `unroutable`, both torn down |
| Active/active — two publishers, **two-relay mesh** (hard kill) | **30–33 s** (one idle timeout) | resumes after detection | ✅ on merged `main` (`b624c7c0`, #2473); ❌ before it |
| Active/active — active source exits **gracefully** | none — subscriber terminates | no failover | ❌ on merged `main` |
| Shared-`--origin` standby joins a **carrying** relay | survives; splice immediate | far-relay subscriber keeps flowing | ✅ fixed on merged `main` (was `Unroutable` code=30) |
| `moq-lite-06` cost/standby routing | — | — | 🟡 opt-in; **necessary-not-sufficient** |
| Redundant outputs (N subscribers) | n/a | byte-identical, continuous | ✅ |
| ST 2022-7 single-path loss (hitless drill) | TBM | target: hitless | ⬜ Gate 3; precondition met by a deterministic/offline or duplicate-single groomer, not by two independent live pacers |

## Observations

- Endpoint *reconnect* is solid (publisher and, since #2469, the exporter). Active/active *source*
  failover across a mesh now ships (#2473) but is **bounded, not hitless** (one idle timeout), and
  does not cover a graceful source exit at all.
- Recovery on a hard kill is architecturally detection-bound: a relay has no model of a broadcast's
  expected cadence, so it must wait for the transport to declare the peer gone.
- **Recommended posture, buildable today:** with the exporter crash fixed, no external subscriber
  supervisor is needed for relay maintenance/transient loss. Service redundancy still comes from a
  fully doubled chain — dual publishers → dual relays → dual subscribers → dual pacers → downstream
  ST 2022-7 / IRD failover — letting the *receiver* do hitless selection. Relay-mesh source failover
  does not change that recommendation now that #2473 has landed. Where quick reconnect matters, lower
  `--client-quic-idle-timeout` (keeping it above the keep-alive).

## Conclusion

Transport resilience holds; active/active source failover now ships, bounded by detection, with a
residual graceful-exit gap. The ST 2022-7 determinism precondition is characterised (single
deterministic/offline groom is byte-exact reproducible; two independent live pacers are not yet). The
on-hardware hitless ST 2022-7 drill under loss (Gate 3) remains outstanding. The full validated
finding — including which of our reports were real vs harness artefacts — is recorded in
[`docs/evidence.md`](../docs/evidence.md) §7.

## References

- Redundancy model: [`docs/relay.md`](../docs/relay.md) §5–§6; [`docs/architecture.md`](../docs/architecture.md) §14 (ST 2022-7 §14.1); [`docs/transport.md`](../docs/transport.md) §8.
- Upstream: [#2469](https://github.com/moq-dev/moq/pull/2469), [#2473](https://github.com/moq-dev/moq/pull/2473), [#2545](https://github.com/moq-dev/moq/pull/2545), [#2556](https://github.com/moq-dev/moq/pull/2556), #2424, #2461, [#2330](https://github.com/moq-dev/moq/issues/2330), #2216/#2217.
- Finding: [`docs/evidence.md`](../docs/evidence.md) §7.
