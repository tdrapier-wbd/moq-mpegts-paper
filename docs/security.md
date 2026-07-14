# Security

Status: working draft
Scope: the security model of the platform — the threat model, identity and
authentication, authorization, key management, data protection, abuse mitigation,
compliance, and security operations. This is the deep-dive companion to
[architecture](architecture.md) §10 (authentication) and §13 (multi-tenancy);
the entitlement grant model it enforces is in [entitlement](entitlement.md) and
the API-level controls in [control-plane](control-plane.md) §8.

---

## 1. Purpose and threat model

The platform carries high-value linear content across shared, multi-tenant, and
partly public infrastructure. Its security posture must reflect that the network
substrate is not trusted, the tenants do not trust each other, and some of the
content is commercially sensitive under contract.

- **Assets to protect.** In rough order of value: (1) content confidentiality and
  integrity for feeds where the contract requires it; (2) entitlement integrity —
  that only authorised endpoints receive a feed, which is simultaneously a
  security and a rights-compliance property; (3) tenant isolation; (4) the
  control plane itself (compromise of provisioning/entitlement issuance is the
  highest-impact target); (5) the signing keys underpinning entitlement.
- **Threat actors.** External network attackers (interception, injection, DDoS);
  a malicious or compromised tenant attempting to reach another tenant's content
  or starve shared infrastructure; a compromised endpoint or leaked token; a
  compromised federation peer; and insider/operator misuse.
- **Trust boundaries.** The principal boundaries are: management plane ↔ control
  plane; control plane ↔ data plane; between tenants; between the platform and a
  federation peer; and between the platform and the public network substrate.
  Each is enforced by a distinct mechanism (§2–§3).

## 2. Identity and authentication

The platform authenticates three distinct classes of principal, and conflating
them is itself a security error ([architecture](architecture.md) §10). The
mechanisms below (mTLS, JWTs, OIDC) are the credential *profile* this platform
adopts on top of MoQ's subscription-time authorization hook and standard PKI —
they are deployment choices, not wire-format guarantees of the transport
([transport](transport.md) §3.1).

- **Data-plane peers** (publishers, relays, gateways, federation peers)
  authenticate with **mTLS**, each holding an identity certificate from a
  cross-signed or enterprise PKI. mTLS suits long-lived machine-to-machine QUIC
  sessions and gives strong, revocable transport-layer identity.
- **Subscribers/endpoints** authenticate with **path-scoped JWTs** that also carry
  entitlement ([entitlement](entitlement.md)). For a consuming endpoint, identity
  and entitlement are answered together and bound in the same credential.
- **Management-plane callers** authenticate to the control-plane API via the
  tenant's identity system — **OIDC/federated SSO** for humans, scoped API
  credentials or workload identity for automation ([control-plane](control-plane.md)
  §8.1). These credentials are entirely separate from data-plane credentials.

## 3. Authorization

Authentication establishes *who*; authorization establishes *what is permitted*.

- **Publish/subscribe permissions.** MoQ exposes an authorization decision at the
  relay at the point of subscription; the platform's path-scoped tokens are checked
  there ([evidence](evidence.md) §6), so an unauthorised subscription is refused
  rather than accepted-then-torn-down.
- **Path-scoped authorization.** A token grants the narrowest namespace scope that
  satisfies the contract (least privilege; [entitlement](entitlement.md) §3).
- **Tenant boundary enforcement.** Every channel/track lives in a
  cryptographically scoped, hierarchical namespace
  ([control-plane](control-plane.md) §4.1); relays reject any subscription whose
  token scope does not match the target namespace. This is the primary technical
  control preventing cross-tenant access.

## 4. Key and secret management

- **Key lifecycle.** Token-signing private keys and mTLS CA/identity material are
  generated, stored, and used inside HSMs or a cloud KMS
  ([control-plane](control-plane.md) §8.2). Relays and gateways hold only the
  *public* keys needed to verify JWT signatures locally at the subscription edge;
  they never hold long-lived signing private keys.
- **Rotation.** Signing keys and certificates are rotated on a defined schedule
  and support overlapping validity so rotation does not interrupt live sessions.
  Local public-key verification means a rotated verification key must be
  distributed to the edge ahead of use — a control-plane push with its own
  consistency considerations.
- **Revocation.** Certificate revocation (data-plane peers) and token revocation
  (endpoints) are distinct paths: the former via PKI revocation/short-lived certs,
  the latter via the fast-path + short-TTL model in [entitlement](entitlement.md)
  §5.

## 5. Data protection

- **In transit.** All data-plane traffic runs over QUIC, which is encrypted by
  default (TLS 1.3); all control-plane traffic runs over TLS. There is no
  cleartext media or control path.
- **Content confidentiality beyond the transport.** QUIC protects data between
  hops, but a relay terminates the session and sees the (opaque) payload. This is
  *not* a regression relative to existing distribution — it is the broadcast norm:
  fibre contribution feeds are commonly carried in the clear or handed off in the
  clear at the demarcation point, and managed IP services (AWS MediaConnect)
  behave identically, with the flow accessible to the transport as opaque data.
  Where rights terms require content "secure end to end," that is in practice
  understood to mean the transport is encrypted and the relaying process is
  protected operationally (physical/data-centre access control, host hardening,
  tenancy isolation), not literal publisher-to-egress content encryption; this
  platform meets that bar. Where a contract instead requires the *operator itself*
  not to have access, transport encryption is insufficient and an additional
  content-encryption scheme is needed — whether that can be offered over MoQ
  without breaking relay fan-out and caching is an **open question** (§10), not
  claimed as solved.
- **At rest.** Logs, audit records, and any packet/stream captures are encrypted
  at rest, partitioned by tenant (§7), and subject to retention limits — captures
  in particular may contain content and must be tightly controlled.
- **Sensitive metadata.** Service identity, routing, and entitlement metadata can
  themselves be commercially sensitive (they reveal who receives what) and are
  treated as tenant-confidential.

## 6. Abuse and attack mitigation

- **Replay protection.** Tokens carry expiry and unique identifiers; short TTLs
  bound the value of a captured token, and the token identifier supports
  detection of anomalous reuse.
- **DDoS and flooding.** Public-facing control-plane endpoints sit behind
  rate-limiting and DDoS protection; critical infrastructure nodes prefer private
  peering or IP allow-listing ([control-plane](control-plane.md) §8.3). At the
  data plane, admission control and per-tenant quotas ([relay](relay.md) §7) bound
  the impact of subscription floods.
- **Token abuse.** A leaked token is bounded by its scope and TTL and can be
  revoked on the fast path; anomalous subscription patterns (impossible
  geography, excessive fan-out) should be detectable from the telemetry the relay
  already emits.
- **Cross-tenant abuse.** Namespace scoping (§3) plus quotas (blast-radius
  control; [control-plane](control-plane.md) §4) are the primary defences against
  a malicious tenant.

## 7. Compliance and auditability

- **Audit log schema.** Every control-plane action and every entitlement
  grant/refresh/revoke writes an immutable record: timestamp, operator/principal
  identity, tenant context, action, target resource, and correlation id
  ([control-plane](control-plane.md) §6.3, [entitlement](entitlement.md) §8).
- **Retention.** Audit and evidence retention is set per tenant/contract and per
  applicable regulation; capture retention is minimised because captures may
  contain content.
- **Evidence for incident response.** The correlated audit + telemetry trail
  supports reconstructing "who received what, when" for both security incidents
  and rights-compliance disputes.

## 8. Security operations

- **Incident response.** Security incidents follow the same severity discipline as
  operational ones ([operations](operations.md) §5), with content-exposure and
  entitlement-integrity incidents treated at the top severity.
- **Detection and triage.** Detection draws on the same dual-domain telemetry as
  operations, plus auth-failure and anomalous-subscription signals.
- **Recovery and postmortem.** Key compromise has a defined response (rotate,
  revoke, re-issue) that must be exercisable without a broadcast-visible outage,
  leaning on the same drain-and-restore discipline as change management
  ([operations](operations.md) §6).

## 9. Validation plan

- **Pen-test scope.** The control-plane API, the token issuance/verification path,
  tenant-isolation boundaries, and federation interconnects.
- **Red-team scenarios.** Cross-tenant access attempts; token theft and replay;
  a compromised endpoint; a compromised federation peer attempting to over-reach
  its negotiated scope; control-plane privilege escalation.
- **Security acceptance criteria.** No cross-tenant access under any tested
  path; revocation effective within the stated bounds ([entitlement](entitlement.md)
  §9); no cleartext media or control path; keys never present on edge nodes.

## 10. Open questions

- **End-to-end content encryption.** Can content be protected from the *operator*
  (publisher-to-egress) over MoQ without breaking relay fan-out and caching, and
  is that required for the target contracts? Currently unresolved.
- **Federation trust.** How is trust established, scoped, and *revoked* across a
  federation boundary with another operator, and how is a compromised peer
  contained ([architecture](architecture.md) §6.3)?
- **Key distribution consistency.** How are rotated verification keys distributed
  to the edge with strong enough consistency that a valid token is never rejected
  nor a revoked key honoured during the rotation window?
