# Operations

Status: working draft
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
([architecture](architecture.md) §12), and alerting must bridge them.

- **Golden signals (systems domain).** Latency, traffic, errors, saturation
  across publishers, relays, and gateways; session and subscription counts; cache
  behaviour; congestion/loss per path.
- **Broadcast-specific probes (broadcast domain).** TR 101 290 P1/P2 status, PCR
  interval statistics, continuity-counter integrity, service presence, and ST
  2022-7 path health — measured read-only at the egress gateway.
- **Alert thresholds and routing.** Broadcast-domain alarms (a P1/P2 excursion)
  are routed to the NOC with the same severity discipline as a satellite feed
  alarm; systems-domain alerts (a saturating relay) are routed to platform
  on-call *before* they become a broadcast-domain symptom. The two are correlated
  by a common end-to-end identifier ([architecture](architecture.md) §12.3) so a
  broadcast symptom can be traced to its systems cause.

## 4. Runbooks

The core runbooks map to the operational workflows in
[architecture](architecture.md) §15:

- **Feed bring-up.** Provision channel/route, configure publisher and gateway,
  issue entitlement, confirm green TR 101 290 at egress; record the elapsed time
  as the "channel in minutes" metric ([architecture](architecture.md) §15.1).
- **Failover/failback.** Shift to the redundant disjoint path, confirm the IRD's
  ST 2022-7 switch was hitless, service the drained element, restore. The IRD
  should observe nothing ([architecture](architecture.md) §15.3).
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

## 9. Operational readiness checklist

Before a route carries contracted content:

- **People** — NOC trained on the platform's alarms in *their* vocabulary;
  on-call rotations staffed; escalation paths agreed with the tenant.
- **Process** — runbooks (§4) rehearsed; incident severities and comms templates
  agreed; change/rollback procedures defined.
- **Tooling** — dual-domain monitoring wired up and correlated; TR 101 290
  probing at egress; audit trail flowing.
- **Drills** — failover, revocation, and regional-failure drills executed and
  timed at least once against the real topology, not just in theory.

## 10. Open questions

- What is the realistic fully-loaded operational cost (NOC + on-call + tooling)
  for an always-on contracted feed, and how does it compare with the incumbent's
  operational cost? (Feeds directly into [economics](economics.md).)
- How is operational responsibility divided across a federation boundary, where
  part of the path is operated by another party ([architecture](architecture.md)
  §6)?
- Which broadcast-domain alarms can be safely auto-remediated (e.g. automatic
  reroute on a P1 excursion) versus which must always involve a human, given the
  cost of a wrong automated action on a contracted feed?
