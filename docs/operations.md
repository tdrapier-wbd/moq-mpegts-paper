# Operations

Status: working draft
Layer: **above the transport** — the operating model, service levels, egress monitoring and runbooks
are owned by the distributor whichever data plane carries the bytes. What differs between them is the
set of failure modes to watch for upstream of the groomer, collected in §9; §3's systems-domain
signals are the MoQ-specific exception.
Scope: how the platform is run for contracted content — the operating model,
service levels, monitoring, runbooks, incident and change management, and the
readiness a broadcast NOC would require. This is the deep-dive companion to the
observability treatment in [architecture](architecture.md) §12 and §15; it
assumes that context and develops the operational detail.

---

## 1. Operating model

Primary distribution is operated to a standard that is unusual in general
software: the expectation is not "high availability" in the web sense but "no
visible failure during contracted content" ([vision](vision.md) §2). That
standard shapes the entire operating model.

> **Readiness caveat.** This operating model — green TR 101 290 at egress,
> hitless failover on the last hop, drilled runbooks — is written as the target
> state. It presumes the platform's single make-or-break validation (a clean
> TR 101 290 P1/P2 pass on real hardware IRDs, with ST 2022-7 determinism under
> loss) has been achieved; that is still open ([interoperability](interoperability.md)
> §6, [architecture](architecture.md) §17). Until it passes, these runbooks are
> *designed and rehearsable* but not *proven* for contracted content.

- **NOC expectations.** The platform is operated by, or integrated with, a
  broadcast NOC that already runs satellite and fibre feeds. The platform must
  present itself in that NOC's existing terms — signal conformance, error seconds,
  path health — rather than requiring a new operational vocabulary
  ([architecture](architecture.md) §12.1).
- **Day-1 vs Day-2.** Day-1 (bring-up, provisioning, entitlement) is API-driven
  and fast ([architecture](architecture.md) §15.1). Day-2 (monitoring, failover,
  incident response, change) is where most operational cost lives and where the
  broadcast standard is highest. The two have different tooling and different
  people, and the model keeps them distinct.

## 2. Service levels and SLOs

The platform is measured on four classes of SLO. **All numeric targets below are
proposed and illustrative** — engineering hypotheses to validate in a real
deployment, not committed figures, consistent with the repository's stance on not
presenting unvalidated numbers as fact.

- **Availability (data plane).** The broadcast-facing target: contracted feeds
  deliver without visible failure. This is higher than the control-plane
  availability target, because the two are independent ([architecture](architecture.md)
  §9.2) — the data plane must survive a control-plane outage.
- **Latency.** Bounded, stable end-to-end latency within the route's budget; the
  relay contributes a per-hop budget ([relay](relay.md) §8).
- **Quality (TR 101 290).** Continuous P1/P2 conformance at egress, with error
  seconds tracked per feed. This is the broadcast-specific SLO that has no
  web-software analogue.
- **Control-plane.** Provisioning and revocation latency, and control-plane
  availability — proposed targets are in [control-plane](control-plane.md) §9.

## 3. Monitoring and alerting

The platform must be observable in two languages simultaneously
([architecture](architecture.md) §12), and alerting must bridge them. The broadcast-domain
half is identical on either data plane; the systems-domain half below is written against a
MoQ relay fabric, and §9 gives the segmented-HTTP equivalents.

- **Golden signals (systems domain).** Latency, traffic, errors, saturation
  across publishers, relays, and gateways; session and subscription counts; cache
  behaviour; congestion/loss per path.
- **Broadcast-specific probes (broadcast domain).** TR 101 290 P1/P2 status, PCR
  interval statistics, continuity-counter integrity, service presence, and ST
  2022-7 path health — measured read-only at the egress gateway.
- **Programme content, not carrier presence.** The single most important probe on a
  groomed leg, and the least obvious. A groomer asked only to hold a rate will hold it
  against a dead upstream: byte-perfect constant-bitrate carrier — correct rate, valid
  transport stream, PCRs present and accurate — containing no programme packets at all,
  for as long as it is left running. Loss, continuity, bitrate and silence checks all
  report healthy, and a receiver selecting on packet arrival will hold a dead leg
  indefinitely ([evidence](evidence.md) §7). Two things follow, and both are needed:
  - **Configure the groomer to stop.** `mpegts-pacer` treats content silence past a
    grace period as absence rather than jitter and mutes: it stops emitting, holds its
    output byte clock, and stops inserting PCR. Set the grace period above the feed's
    worst legitimate delivery gap and well below the failover budget — 1 s is the
    default and what the measurements use. This is what turns an undetectable failure
    into a leg that visibly stops, and nothing at the receiver substitutes for it.
  - **Alarm on the absence of programme packets** regardless, counting only packets that
    are neither null **nor adaptation-field-only**, since the groomer's own PCR
    insertions are neither null nor content. The mute is a configured behaviour of one
    groomer; a leg groomed by other equipment, or with detection disabled, still
    presents the dead carrier.

  On an *ungroomed* leg neither applies: the carrier stops with the content.
- **A leg that comes back is not yet a pair that came back.** A stream-clocked leg that
  mutes and resumes re-enters on its partner's numbering and carrying programme again,
  which an arrival-clocked one does not — but the two legs are still not byte-identical,
  because the exporter behind the returning leg renumbers continuity counters from its
  own process state ([evidence](evidence.md) §7). Alarm on a pair that is live-live but
  no longer merging: every per-leg indicator reads green while the protection is gone.
  Until the upstream fix lands, treat leg recovery as restoring *input-failover*
  redundancy only, and restore the merge by restarting both legs together.
- **Alert thresholds and routing.** Broadcast-domain alarms (a P1/P2 excursion)
  are routed to the NOC with the same severity discipline as a satellite feed
  alarm; systems-domain alerts (a saturating relay) are routed to platform
  on-call *before* they become a broadcast-domain symptom. The two are correlated
  by a common end-to-end identifier ([architecture](architecture.md) §12.3) so a
  broadcast symptom can be traced to its systems cause.
- **Relay liveness, not just process health.** A relay can stay *running* and stop
  *serving*. Two failure modes observed in evaluation make this concrete: a
  takeover livelock that pinned every worker thread inside one poll, leaving the
  process alive at 100 % CPU with no logs, no health endpoint and no accepts for
  hours ([#2701](https://github.com/moq-dev/moq/pull/2701), triggered by cluster
  peer churn); and unbounded memory growth ending in an OOM kill. The severe form of
  the memory failure belonged to an older release; current builds show a bounded
  load-dependent growth that levels off (next point), which an RSS-trend alarm must be
  tuned not to mistake for the real thing. Neither mode is caught by a liveness check
  that only asks whether the process exists. Probe the relay the way a client would —
  complete a session and read a byte — and alarm on **RSS trend** (a climb that
  continues past the first few hours of a connection, not just a threshold) alongside
  CPU pinned at a whole-core multiple.
- **Bound relay memory explicitly.** `moq-relay`'s group cache is **unbounded by
  default**; only each track's own retention window (5 s by default) limits it.
  With no flags set, the group cache pool is unbounded *and* has no age ceiling: the
  only thing bounding relay memory is each publisher's own advertised retention
  window, which is not the operator's to control. Three knobs exist and they are not
  interchangeable. `--cache-capacity` is a soft target that counts **payload bytes,
  not process memory**. `--cache-headroom` runs a governor that yields memory back
  when the system needs it. `--cache-duration` caps how long non-latest groups are
  retained and *clamps down* a publisher asking for more. Set an explicit bound on
  every deployed relay; it is measured to cost nothing (identical CPU, resident memory
  within 1.5 MB), and it protects against the cache filling for other reasons.

  **But no cache bound will stop the current growth, and both knobs have been tested.**
  Capping capacity at 32 MiB left the rate unchanged, with the relay running to more
  than twice the cap above its baseline and no inflection where the cap should bind;
  an age ceiling of `--cache-duration 5s` likewise left it unchanged. Neither can help,
  because the memory is not the relay's to evict: it is held by the QUIC library
  beneath it.
- **Budget the per-connection QUIC stream overhead, and cap it if you need to.**
  `quinn-proto` keeps a slot for every stream a peer may open and recycles a freed
  stream's reassembly buffer rather than releasing it. MoQ opens a stream per group,
  so a relay accumulates roughly **9 KiB for every group it ingests** —
  ~27–31 MB/hour on a 9.3 Mbps channel — until every slot is occupied, at which point
  it stops. `moq-relay` allows 10,000 streams per connection, putting the ceiling at
  **roughly 100 MB above baseline per publisher connection**, reached over the first
  few hours ([moq-dev/moq#2745](https://github.com/moq-dev/moq/issues/2745)).

  What this means in practice. **Size for publisher connections, not audience** — the
  overhead is flat in subscriber count, so a lightly-watched relay pays the same as a
  busy one, while per-session state is separate and well-behaved (a fixed ~3.2 MB per
  subscriber at join that does not accumulate). Expect a relay's resident memory to
  climb for the first few hours after a publisher connects and then level off; alarm
  on a trend that is *still* climbing well past that, which is the signature of a real
  problem rather than this one. A lower latency target reaches the same ceiling sooner
  rather than settling higher, so it changes the shape of the curve and not the budget.

  `--server-quic-max-streams` is the one control that binds it, but it is
  **sub-proportional**: measured on our own rig, cutting slots by 9.8× reduced retained
  memory by only 3.3×, because 20–30 MB of the ceiling is independent of slot count.
  A capped relay levelled at 91 MB where an uncapped one on identical media reached
  190 MB — worth having on a memory-constrained host, at the cost of concurrent-stream
  headroom on busy connections, but not a way to configure the overhead away. Two
  further practical notes from that verification: the plateau is **soft**, still
  creeping at ~8 MB/hour after the knee, so set alarm thresholds above the ceiling
  rather than at it; and no released QUIC library version fixes this, so plan for the
  overhead rather than waiting for it to go away
  ([lab T9](../lab/test-9-performance.md)).

## 4. Runbooks

The core runbooks map to the operational workflows in
[architecture](architecture.md) §15:

- **Feed bring-up.** Provision channel/route, configure publisher and gateway,
  issue entitlement, confirm green TR 101 290 at egress; record the elapsed time
  as the "channel in minutes" metric ([architecture](architecture.md) §15.1).
- **Failover/failback.** Shift to the redundant disjoint path, confirm the IRD's
  ST 2022-7 switch was hitless, service the drained element, restore. The IRD
  should observe nothing ([architecture](architecture.md) §15.3). Two constraints
  from measurement ([evidence](evidence.md) §7). A leg that restarts alone rejoins
  its partner's numbering and schedule, so **input-select protection returns
  immediately**, but it does not return to byte-identity, because `moq export ts`
  renders continuity counters from process state — so a **sequence-merge** receiver
  needs *both* legs restarted together, while an input-select receiver does not.
  And the leg being drained must be confirmed dead by **content**, not by carrier,
  or the receiver will keep selecting it.
- **Entitlement incidents.** Emergency disable / revoke under time pressure; the
  runbook must be simple enough to execute correctly under stress
  ([entitlement](entitlement.md) §9).
- **Degraded-quality triage.** Use the correlation id to trace a P1/P2 or delivery
  alarm to a congested path, saturated gateway, or failing publisher, then apply
  reroute/scale/failover ([architecture](architecture.md) §15.4).

## 5. Incident management

- **Severity model.** Severity is defined primarily by *impact on contracted
  content*: loss or impairment of a live contracted feed is the top severity,
  above any purely internal systems degradation that the redundancy layers are
  masking.
- **Escalation matrix.** Broadcast-impacting incidents escalate to the NOC and the
  affected tenant immediately; systems incidents escalate to platform on-call.
- **Communication.** Tenant-facing communication for broadcast-impacting incidents
  follows the same expectations as existing distribution contracts (timely, with
  a named accountable party) — the "someone to sue" property that
  [vision](vision.md) §2 identifies as central to the buyer.
- **Post-incident review.** Every broadcast-impacting incident produces a review
  with the end-to-end evidence trail (audit records plus correlated telemetry).

## 6. Change management

Because redundancy is end-to-end ([architecture](architecture.md) §14), most
change is performed *without* a maintenance window visible to the feed:

- **Release strategy.** Drain a single layer to its redundant path, change it,
  restore, then repeat on the other path. This applies to relay/gateway/publisher
  upgrades and, critically, to **transport-draft migrations**. The
  transport-independent layering keeps the *media/grooming* code out of the change,
  but the migration itself is not trivial: it still means new relay/gateway builds
  on the new ALPN and control semantics, a window of multi-draft coexistence while
  peers upgrade, and a per-route drain/restore with rollback
  ([transport](transport.md) §5.2). The drain-and-restore discipline is what makes
  that migration *hitless*, not what makes it small.
- **Maintenance windows.** Reserved for changes that cannot be made hitless;
  scheduled with tenants per contract.
- **Rollback.** Every change has a defined rollback to last-known-good, and the
  data plane's ability to run on cached configuration ([control-plane](control-plane.md)
  §7.3) means a failed control-plane change does not interrupt live feeds.

## 7. Capacity and cost operations

- **Forecasting.** Relay capacity (throughput/fan-out) and gateway capacity
  (real-time timing headroom) are forecast separately because they scale on
  different axes ([relay](relay.md) §6, [architecture](architecture.md) §7.3).
- **Scaling playbooks.** Add edge relays/gateways per region ahead of demand;
  the fan-out model means inter-region capacity scales with distinct tracks, not
  subscriber count.
- **Cost guardrails.** Egress cost can dominate the economic model
  ([economics](economics.md)); operational guardrails track egress per tenant and
  per route against budget, and quotas cap runaway cost from misbehaving
  automation ([control-plane](control-plane.md) §4.2).

## 8. Support model

- **On-call.** Follow-the-sun platform on-call plus broadcast NOC coverage; the
  broadcast standard effectively requires 24/7 attention for contracted content,
  which is itself a real cost input to [economics](economics.md).
- **Customer/tenant interfaces.** A clear path for a tenant to raise and track
  incidents, and to see their own routes, entitlements, and conformance status
  (tenant-isolated; [control-plane](control-plane.md) §4.3).
- **Vendor escalation.** Defined escalation to upstream/transport, cloud, and
  hardware-IRD vendors, since a broadcast-impacting fault may originate outside the
  platform's own components.

## 9. What changes on a segmented-HTTP data plane

Almost nothing in §§1–8 does. The operating model, the SLO classes, the egress TR 101 290
probing, the groomer silence detection and the ST 2022-7 runbooks are all owned by the
distributor and are written against the *hand-off*, which does not know how the feed
arrived. What differs is the set of failure modes the NOC watches for upstream of the
groomer, and they are worth naming because they are unfamiliar to a broadcast NOC:

| Concern | On MoQ | On segmented HTTP |
|---|---|---|
| Liveness signal | subscription state; relay memory and per-connection ceiling (§3) | playlist freshness — a stalled packager looks like a served-but-stale playlist, not a dropped connection |
| Silent failure mode | publisher with no subscriber dies at ~30 s to the QUIC idle timeout ([evidence](evidence.md) §7) | **a cache serving the last good segment indefinitely.** There is no connection to drop, so the classic "is it still up?" alarm does not fire |
| Buffer to alarm on | milliseconds; a stall is visible almost immediately | seconds; multi-second silences are *normal* here, so an alarm threshold set below the segment duration will chatter and one set above it is slow. Measured, the groomer derives ~9 s from the arrival pattern against the MoQ lane's ~1 s ([T16](../lab/test-16-grooming-segmented-http.md)) |
| Third-party surface | the relay, which you or a vendor run | the CDN — cache TTLs, purge behaviour and edge-node health, largely unobservable from your side |
| Recovery | reconnect and resubscribe | re-fetch; the segment is still addressable, which is genuinely easier ([alternatives](alternatives.md) §3) |

The second and third rows are the ones that catch people. Segmented HTTP's failure modes
are *quieter* than MoQ's: a stale playlist and a warm cache produce no error anywhere,
and the first symptom is content that has stopped advancing. A NOC moving from MoQ to
segmented HTTP should expect to replace connection-liveness alarms with playlist-age and
media-timestamp-advance alarms, and to widen its groomer-underrun thresholds to match the
larger buffer — which the groomer will do for itself, since it sizes the threshold from the
arrival pattern it observes rather than from a configured value
([implementation](implementation.md) §9.1). **The number to plan around is that a
segment-fetching leg cannot report a dead source faster than a segment period**, so
~9 s of detection latency on a 2 s-segment feed is the cost of the data plane and not
something a threshold can tune away. An operator whose failover budget is tighter than that
needs MoQ, or needs a second monitored path.

## 10. Operational readiness checklist

Before a route carries contracted content:

- **People** — NOC trained on the platform's alarms in *their* vocabulary;
  on-call rotations staffed; escalation paths agreed with the tenant.
- **Process** — runbooks (§4) rehearsed; incident severities and comms templates
  agreed; change/rollback procedures defined.
- **Tooling** — dual-domain monitoring wired up and correlated; TR 101 290
  probing at egress; audit trail flowing.
- **Configuration** — congestion controller pinned explicitly rather than left to the
  backend default, and chosen against the route's own conditions
  ([relay](relay.md) §7); relay memory bound and its per-connection ceiling budgeted
  (§3); groomer silence detection enabled on every groomed leg (§3).
- **Drills** — failover, revocation, and regional-failure drills executed and
  timed at least once against the real topology, not just in theory.

## 11. Open questions

- What is the realistic fully-loaded operational cost (NOC + on-call + tooling)
  for an always-on contracted feed, and how does it compare with the incumbent's
  operational cost? (Feeds directly into [economics](economics.md).)
- How is operational responsibility divided across a federation boundary, where
  part of the path is operated by another party ([architecture](architecture.md)
  §6)?
- Which broadcast-domain alarms can be safely auto-remediated (e.g. automatic
  reroute on a P1 excursion) versus which must always involve a human, given the
  cost of a wrong automated action on a contracted feed?
