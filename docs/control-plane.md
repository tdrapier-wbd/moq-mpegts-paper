# Control Plane

Status: working draft
Scope: the provisioning, entitlement, policy, and observability control layer for
the distribution platform. This is the deep-dive companion to
[architecture](architecture.md) §9 and assumes that context rather than restating
the end-to-end system. Authentication is developed in full in
[security](security.md) and the entitlement grant model in
[entitlement](entitlement.md); this document covers how the control plane
provisions and governs, and links out rather than duplicating.

---

## 1. Purpose

The control plane is the authoritative orchestration and governance layer: out-of-band management of the media lifecycle without runtime dependencies or fate-sharing with the data plane ([architecture](architecture.md) §9.2). It provisions routes, manages dynamic and revocable entitlements, enforces multi-tenant isolation, and exposes visibility to the NOC.

It is decoupled from transport mechanics. MoQ is the preferred data plane, but the control plane interacts only with abstractions: it resolves routing, authorization, and tenant-lifecycle policy, then projects materialized configuration onto the data-plane components (publishers, relays, edge gateways). The intent is that a wire-protocol, ALPN, or draft migration (e.g. draft-14 → draft-18) requires no change to control-plane logic.

The design below is a *proposed* control plane, not a description of a shipped one; concrete API shapes and targets are illustrative sketches to be validated, not commitments.

---

## 2. Entities

Six first-class, versioned, auditable entities model the distribution landscape:

* **Tenant** — an isolated administrative, cryptographic, and billing domain: a broadcaster, business unit, or authorized partner.
* **Channel / Service** — a logical, transport-independent feed from a publisher source; encapsulates track metadata without binding to physical instances.
* **Endpoint / Subscriber** — a consumer of a channel: an edge gateway (grooming for hardware IRDs), a native MoQ subscriber, or a federation interconnect crossing administrative boundaries.
* **Policy** — declarative rules for routing, redundancy (e.g. link-disjoint paths), geographic placement (data-sovereignty/rights), and resource allocation.
* **Entitlement / Token** — a time-bounded, signed, revocable grant authorizing a specific endpoint to subscribe to a channel over a route.
* **Route / Path** — the materialized end-to-end path (publisher → relay mesh → gateway/subscriber), tied to QoS and high-availability policy.

---

## 3. API surface

The control plane should expose a versioned, idempotent API (REST or gRPC) for orchestration, dashboards, and automation. Two properties are load-bearing rather than cosmetic:

- **Idempotency.** Every state-modifying call carries an idempotency key, because provisioning is driven by automation that retries and a retried "create route" must not create two routes.
- **Versioning.** Version pinning (`/v1/` vs `/v2/`) lets a tenant's own orchestration, on its own release cycle, avoid being forced to upgrade in lockstep.

An illustrative surface mirrors the entity model: create/update/suspend/delete for tenants, channels, routes, and endpoints; grant/refresh/revoke for entitlements (the grant model, token design, and revocation semantics are in [entitlement](entitlement.md)). Mutations follow an explicit lifecycle: `Draft → Provisioned → Active → Suspended → Revoked/Torn-Down`.

---

## 4. Multi-tenant isolation

Multi-tenancy lets tenants share the commodity relay fabric while operating under strong logical and cryptographic isolation within the control plane. The isolation model is developed further in [security](security.md).

### 4.1 Namespace model
Every channel, track, and routing entity is bound to a cryptographically enforced, hierarchically scoped namespace unique to that tenant (e.g., `moq://tenant-id/channel-id/track-id`). Relays reject any subscription attempt where the presented token scopes do not match the target track namespace.

### 4.2 Resource quotas
To prevent a single tenant from starving shared infrastructure (e.g., during unpredicted traffic spikes or logic loops in third-party automation), the control plane enforces hard quotas on:
* Maximum concurrent active routes per tenant.
* Aggregate ingress and egress bandwidth allocations.
* Maximum endpoints/subscribers per channel namespace.

### 4.3 Blast-radius controls
Tenants are isolated at the telemetry, logging, and audit trail layers, ensuring no cross-tenant data visibility. At the data plane layer, if a tenant's traffic causes localized link saturation, the fabric uses priority queueing and resource quotas to *bound* the degradation. This reduces, but does not fully eliminate, impact on neighboring tenants sharing the physical relay clusters: quotas cap a tenant's admitted volume, but once a shared relay's CPU, NIC, or an upstream link is saturated, latency and jitter coupling can still cross tenants. Where a contract requires hard isolation rather than bounded coupling, the answer is a dedicated relay cluster for that tenant ([architecture](architecture.md) §13.2), not queueing alone.

---

## 5. Policy & orchestration

The control plane translates high-level business logic into declarative policy maps pushed directly to the edge and core fabric.

### 5.1 Subscription policy
Defines who can subscribe, admission rules, and fallback behavior. Enforces a strict *deny-by-default* posture. If an entitlement token is absent, malformed, or expired, the relay or edge gateway immediately blocks or terminates the subscription.

### 5.2 Routing policy
Decoupled from transport mechanics, this policy dictates topology paths based on:
* **Geographic constraints:** Pinning routes to specific regional clusters to strictly satisfy regulatory data sovereignty or content distribution rights.
* **Link exclusion:** Dynamically route around links reporting elevated packet loss or latency jitter.

### 5.3 Failover policy
Governs redundant path strategies. For high-value contracted content, the policy enforces the instantiation of two completely link-disjoint paths across the relay fabric (Active/Active dual publication), enabling seamless, hitless deduplication at the egress edge gateway.

### 5.4 Compliance policy
Automates compliance tracking by forcing the logging of every routing modification and authorization grant to an immutable ledger for audit review.

---

## 6. Observability hooks

The control plane orchestrates telemetry but stays out of the high-throughput logging path, acting as a correlation engine.

### 6.1 Metrics and events emitted
The control plane exposes lifecycle events via structured webhooks and event streams:
* `route.provisioning_started` / `route.provisioning_completed`
* `entitlement.revoked` (Emitted globally with sub-second timestamps)
* `sla.violation` (Triggered when control plane operations exceed latency SLOs).

### 6.2 Alerting integration
System-domain events (such as a database replication delay or webhook delivery failure) are standardly exported to Prometheus/Alertmanager format. Broadcast-domain alerts generated at the edge (e.g., TR 101 290 P1/P2 violations or PCR interval excursions) are aggregated and mapped to the corresponding control-plane tenant and route identifiers.

### 6.3 Audit trail model
Every API call writes an immutable, structured record containing timestamp, operator identity, tenant context, specific action performed, target resource identifiers, and a unique correlation token. This enables unified, end-to-end forensic analysis during incidents and provides evidence for rights-compliance audits.

---

## 7. Reliability & scaling

### 7.1 High-availability architecture
The control plane would run multi-region and active-active, distributing operational traffic across stateless control nodes.

### 7.2 State and consistency model
State separates into two tiers:
1.  **Authoritative store** — a strongly consistent, replicated consensus store for tenant records, policy, and entitlements, so no two conflicting views of authorization can exist.
2.  **Runtime projections** — data-plane nodes hold a local, eventually consistent cache of pushed config and policy. Control transactions complete in seconds, decoupled from the millisecond requirements of media processing.

This asymmetry — a strongly consistent but slower control plane, a fast but eventually-consistent data plane — is deliberate.

### 7.3 Out-of-band & regional failover
Control-plane and data-plane failure boundaries are independent. If the control plane partitions or fails entirely, established media flows continue on last-known-good configuration; only *change* operations are suspended. On a severe regional failure, the routing engine re-homes edge gateways and re-routes active subscriptions to healthy regions.

---

## 8. Security boundaries

The full security model — threat model, identity, key management, abuse mitigation — is in [security](security.md). The control-plane-specific points:

- **Three principal boundaries** (management-plane callers via OIDC/SSO or scoped workload identity; data-plane peers via mTLS; subscribers/endpoints via path-scoped JWTs), kept distinct to reduce credential sharing and boundary escape ([security](security.md) §2).
- **Secret handling.** Token-signing keys and mTLS material live in HSMs or a cloud KMS; relays and gateways hold only the public keys needed to verify JWTs locally, never long-lived private keys ([security](security.md) §4).
- **API hardening.** Public-facing endpoints sit behind rate-limiting and DDoS protection, with private peering or IP allow-listing preferred for critical nodes ([security](security.md) §6).

---

## 9. Acceptance criteria

The following SLO targets are **proposed and illustrative**, not measured results. They are engineering goals for a broadcast-acceptable control plane and should be treated as starting hypotheses to be validated (and likely revised) in a real deployment, not as committed figures. In particular, the availability target below is deliberately modest because the control plane is out-of-band: a control-plane outage suspends *changes* but does not interrupt established media flows (§7.3), so its availability requirement is lower than the data plane's.

| Metric | Proposed target | Measurement boundary |
| :--- | :--- | :--- |
| **Control Plane Availability** | `99.95%` | Annual uptime of the API provisioning surface. |
| **Route Provisioning Latency** | `< 5.0 seconds` | Elapsed time from `POST /v1/routes` to green data plane configuration across all affected nodes. |
| **Fast-Path Revocation Latency** | `< 1.0 second` | Time from `POST /v1/entitlements/revoke` to active subscription teardown at the relay. |
| **Token Renewal Success Rate** | `99.999%` | Percentage of legitimate token refresh requests succeeding before expiration. |

---

## 10. Open questions

1.  **Cross-Operator Federation Scalability:** How will multi-tenant isolation and token-mapping verification scale when entitlements undergo translation across an untrusted federation boundary separating two completely distinct operators?
2.  **Token TTL Optimization:** What is the ideal balance for token time-to-live (TTL)? Shorter TTLs compress the worst-case revocation window if the control plane partitions, but they increase steady-state renewal traffic and control-plane processing overhead roughly in inverse proportion to the TTL (halving the TTL roughly doubles the renewal rate).
3.  **Automated Policy Conflict Resolution:** When layered compliance policies conflict (e.g., a data-sovereignty constraint clashes with a dynamic failover path rerouting around a congested global link), what deterministic hierarchy should the orchestration engine follow to resolve the path selection safely?