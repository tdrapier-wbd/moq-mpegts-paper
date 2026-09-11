# Test 36 — Entitlement enforcement: what the relay refuses, and whether it leaks before it refuses

**State: run, 2026-09-11. All six pass criteria met.** The first of three experiments that put
measurement behind [Control](../docs/control-plane.md). This one asks the static question: presented
with a credential, does the relay admit exactly the paths the credential names, refuse everything
else, and refuse it *before* any media byte reaches the caller.

**Headline: it does, and the margin is not close.** Every one of the eight refusing arms delivered
**exactly zero payload bytes** — not a partial group, not a stray packet — and each affiliate was
announced precisely the channels it licenses and no others, so entitlement governs disclosure as
well as delivery. Two results qualify that. First, refusal arrives by *two different mechanisms*
depending on where the credential fails, and one of them produces **no error to the client and no
line in the relay log at all**; a log-based rig would have had nothing to read on those arms, which
is the clearest possible vindication of measuring at the receiver. Second, the admitted arms miss
the TR 101 290 P2 PCR gate — but so does the unauthenticated control, identically, so the miss is
the ungroomed MoQ egress and not the cost of authorization.

## Objective

Establish, by measurement rather than by reading the protocol, whether MoQ's subscription-time
authorization hook enforces a broadcaster-to-affiliate entitlement model correctly. Specifically,
whether the four behavioural criteria [Control](../docs/control-plane.md) §8 proposes —
enforcement correctness, isolation correctness, key handling, and no cleartext path — hold against a
relay configured the way a distributor would configure one.

The commercial shape behind the question: one broadcaster publishes several channels; several
affiliates each license a different subset; each affiliate holds its own credential; an affiliate
must receive exactly what it licenses and must not receive, or learn about, anything else.

## What is already known, and precisely what it leaves open

[Evidence](../docs/evidence.md) §3.10 records the only established fact: MoQ carries authorization
information at the point of subscription and a relay can accept or refuse there, so **the enforcement
point exists and is native**. That is an architectural reading of the protocol. It says nothing about
whether the enforcement is correct, complete, or free of a delivery window before refusal.

Three things in particular were open, and each was a way the model could be right in design and
wrong in practice. All three are now settled, in the affirmative:

- **Whether refusal precedes delivery.** [Control](../docs/control-plane.md) §3 asserts there is "no
  window in which an unauthorised subscription is accepted and then torn down". That is a claim about
  bytes on a wire, and it is now checked against one: zero payload bytes on every refusing arm.
- **Whether the path algebra matches how channels are actually named.** Grants are path prefixes and
  matching is segment-aware, so `cnn` should not cover `cnn-intl`. Broadcast channel naming is full
  of shared stems, and a prefix model that got this wrong would hand affiliates feeds they had not
  licensed while every configuration file looked correct. It does not get it wrong.
- **Whether an unlicensed channel is confidential or merely undeliverable.** [Control](../docs/control-plane.md)
  §7.3 treats service identity and routing metadata as tenant-confidential, on the reasoning that it
  reveals who receives what. Refusing to *deliver* channel X is a weaker property than refusing to
  *disclose that X exists*, and the two are separately testable. Both hold: an unlicensed channel is
  neither delivered nor disclosed.

### Apparatus check, already performed — not a result of this experiment

Before specifying the runs it was worth confirming the instrument exists. On the build under test,
`moq token generate` mints a signing key carrying an optional immutable scope, and `moq token sign`
refuses to mint a token whose grants fall outside that scope: a key scoped to one broadcaster's root
declined to sign a grant rooted at another's, declined to turn a subscribe-only scope into a publish
grant, and declined to widen to the empty root. **This is a property of the command-line tool, not of
the relay, and it is not what this experiment measures.** It is recorded because it establishes that
the credential-minting half of the apparatus works, so the runs below can proceed without building
one.

## Environment

Single host, loopback, so that enforcement is measured without a network in the way. One relay, one
publisher carrying a known clip, and a subscriber per arm.

| Component | Build |
|---|---|
| Relay | `moq-relay` 0.14.16-`fd4f5d82e` |
| Publisher / subscriber | `moq` 0.11.0-`fd4f5d82e` |
| Credential tooling | `moq token generate` / `sign` / `verify` from the same build |
| Source | 30 s of the reference CNN clip: 198,404 packets, 9,945,951 b/s, 0 invalid syncs, 0 transport errors, looped and paced at its own PCR rate |
| Capture | `lab/scripts/t36-wiretap.py`, a userspace datagram forwarder, plus the subscriber's own output |

**The capture instrument is a substitution, and the reason matters.** `tcpdump` on this host needs
root to open `/dev/bpf` and interactive `sudo` was not available, so the specified interface capture
could not run. The substitute forwards UDP between subscriber and relay in userspace and therefore
sees exactly the same bytes. Working through it exposed something the original specification had
wrong: **QUIC encrypts its payload, so a capture yields ciphertext and cannot count payload bytes at
all.** The headline measurement — payload delivered before refusal — can only be taken at the
receiving endpoint, after decryption, and that is where it is taken here: the subscriber's own
output file. The wiretap supplies the two things it genuinely can, namely the wire-level byte volume
(which separates a handshake from a media flow by three orders of magnitude) and the
cleartext scan. This is a correction to the protocol's method, not a relaxation of its criterion.

**Every credential in every arm is ES256**, generated with a separate public key file, so the relay
holds verifying material only. The convenience-HS256 caveat the protocol reserved does not apply to
any figure below.

The relay is configured with a per-affiliate key directory (`--auth-key-dir`), which is the
standalone-relay form and the one a distributor could operate without also building an
authorization service. The unified `--auth-api` form is exercised in
[T37](test-37-entitlement-revocation.md), where it is needed for revocation.

The namespace is laid out the way the entity model in [Control](../docs/control-plane.md) §2 implies:
a tenant root per broadcaster, a channel beneath it, tracks beneath that.

## Procedure

**Fix the estate first, then run every arm against it unchanged.** Two broadcasters are provisioned
so that cross-tenant arms have somewhere to reach; one publishes channels whose names deliberately
share a stem.

Each arm attempts one subscribe with one credential and is graded on three things at once: what the
relay logged, what the subscriber received, and what crossed the wire.

The estate as provisioned: broadcaster `wbd` publishing `cnn`, `cnn-intl`, `tnt` and `nobody`;
broadcaster `rival` publishing its own `cnn`. Affiliate A licenses `cnn`, affiliate B licenses `cnn`
and `tnt`, affiliate C licenses `tnt`. `cnn-intl` and `nobody` are licensed by no one — the first is
the shared-stem trap, the second a control. Every channel is live and paced throughout.

| Arm | Credential | Target | Expected | **Result** | **Payload bytes** |
|---|---|---|---|---|---|
| A1 | in-scope, unexpired | licensed channel | admitted | **admitted** | **7,122,944** |
| A2 | in-scope, unexpired | unlicensed channel, same broadcaster | refused | **refused** | **0** |
| A3 | in-scope, unexpired | channel under the other broadcaster | refused | **refused** | **0** |
| A4 | expired | licensed channel | refused | **refused** | **0** |
| A5 | absent | licensed channel | refused | **refused** | **0** |
| A6a | truncated token | licensed channel | refused | **refused** | **0** |
| A6b | signature altered | licensed channel | refused | **refused** | **0** |
| A6c | claims widened after signing | licensed channel | refused | **refused** | **0** |
| A7 | subscribe-only | publish to a licensed channel | refused | **refused** | **0** |
| A8 | publish-only | subscribe to the same channel | refused | **refused** | **0** |
| A9 | grant for `cnn` | `cnn-intl` | refused | **refused** | **0** |
| A10 | grant for the parent path | a child beneath it | admitted, narrowing correctly | **admitted, narrowed correctly** | **7,183,856** |

Arms A9 and A10 were nominated in advance as the two most likely to surprise, because they are where
a prefix model and an operator's mental model can diverge silently. Neither did: the segment-aware
matching holds, `cnn` does not reach `cnn-intl`, and the parent grant confers every child without
reaching past the tenant boundary.

### Refusal arrives by two different mechanisms, and only one of them says so

The wire-volume figures separate the refusing arms into two groups, and the client logs explain why.

| Group | Arms | Server→client wire bytes | What the client is told |
|---|---|---|---|
| Rejected at connect | A3, A4, A5, A6a–c, A7, A8 | 9,562 – 12,731 over 34–45 datagrams | session closed, `code=6 reason=unauthorized`; the client retries and gives up |
| Refused by absence | A2, A9 | 3,469 – 3,813 over 19–30 datagrams | **nothing at all** — the connection is admitted and the broadcast simply never appears |

The second group is the interesting one. The credential is valid for the connection path, so the
session is established; the unlicensed channel is then neither announced nor delivered. From the
affiliate's side this is indistinguishable from a channel that is off air. **The relay emitted no
refusal line for either arm** — a rig that counted denials in the relay log would have scored A2 and
A9 as "no decision taken" while enforcement was in fact working perfectly. Both admitted arms, by
contrast, moved 7,271,944–7,499,474 bytes over more than 6,600 datagrams, so the two populations are
separated by three orders of magnitude and no judgement call is involved in telling them apart.

Operationally this is a good failure mode for confidentiality and a poor one for diagnosis: an
affiliate whose licence has lapsed and an affiliate whose feed has failed present identically, and
neither the affiliate nor the relay operator has a signal that distinguishes them.

**For every refusing arm the receiver is the measurement, not the log**, for the reason the two
refusal mechanisms above make concrete.

### Announcement leakage: entitlement governs disclosure, not only delivery

Graded across the whole estate by connecting with each credential in turn and recording every
broadcast the relay announces.

| Credential | Licensed | Announced |
|---|---|---|
| Affiliate A | `cnn` | `cnn` |
| Affiliate B | `cnn`, `tnt` | `cnn`, `tnt` |
| Affiliate C | `tnt` | `tnt` |
| Broadcaster parent grant | all of `wbd` | `cnn`, `cnn-intl`, `nobody`, `tnt` |

Each affiliate is announced exactly its licensed set. The parent-grant row is what makes the other
three mean something: it shows the relay knows about all four channels on the same connection path
and is genuinely filtering the announcement per credential, rather than the unlicensed channels
being invisible for some unrelated reason. An affiliate cannot enumerate its broadcaster's estate,
and cannot tell that `cnn-intl` exists.

### Wire confidentiality

The scan found **no 188-byte-strided sync structure on any of the twelve arms**, including the two
admitted ones while they were carrying more than 7 MB of programme apiece.

That zero is only worth quoting because the detector was shown to work first. Fed 65,535 bytes of
the cleartext clip it reports a hit; fed 65,535 random bytes — the ciphertext analogue — it reports
none. The boundary the protocol set out to fix is confirmed rather than disputed: the payload is
confidential on the wire, and the relay, which terminates the session, sees it.

### The path algebra, measured directly

Criterion 5 asks whether a parent grant confers its children and stops at the tenant boundary. The
broadcaster's grant — rooted at `wbd`, subscribing the empty prefix — was pointed at each channel in
turn:

| Target | Bytes delivered |
|---|---|
| `wbd/cnn` | 4,328,136 |
| `wbd/tnt` | 5,702,416 |
| `wbd/cnn-intl` | 7,196,076 |
| `rival/cnn` | **0** |

It reaches every child of its own root, including the shared-stem channel that affiliate A's
narrower grant could not reach, and stops dead at the other broadcaster. Grants rebase onto the
connection path exactly as the claims model predicts.

### Media cost of authorization

Graded against an unauthenticated control on the same host, in the same session, carrying the same
clip through a relay configured with public access instead of a key directory.

| Arm | Packets | Continuity errors | Bad sync | Transport errors | PCR within 481 ns | Jittered PCR per 1,000 packets |
|---|---|---|---|---|---|---|
| Control, unauthenticated | 36,396 | **0** | 0 | 0 | 0 | 5.52 |
| A1, affiliate grant | 37,888 | **0** | 0 | 0 | 0 | 5.28 |
| A10, parent grant | 38,212 | **0** | 0 | 0 | 0 | 4.66 |
| *Validation file* | *37,848* | *1* | *0* | *0* | *0* | *5.28* |

The validation row is not an arm. It is A1 with forty packets excised from the middle, run to
confirm the continuity counter fires at all before any zero from it was published — the check
[`method-notes.md`](method-notes.md) §2 requires, and which six earlier rigs in this campaign
skipped. The counter matches the plugin's data (`missing N packets`) and not the word
"discontinuity", which appears only in its help text.

**No arm meets the TR 101 290 P2 PCR gate of 481 ns, and neither does the control.** That is the
ungroomed MoQ egress, which this campaign has measured before; it is not a cost of authorization.
Per-packet jitter on the two authorized arms is marginally *lower* than on the unauthenticated
control, which is within run-to-run noise and is reported only to make the point that the difference
does not run the other way.

## Verdict against the pass criteria, fixed before running

| # | Criterion | Result |
|---|---|---|
| 1 | Every arm A2–A9 refused; one admission fails the experiment | **Pass** — all ten refusing runs refused |
| 2 | Payload bytes before refusal exactly zero on every refusing arm | **Pass** — exactly 0, on all ten |
| 3 | No affiliate announced a broadcast it does not license | **Pass** — announced set equals licensed set for all three |
| 4 | No recognisable clip plaintext on any captured link | **Pass** — 0 hits from a detector shown to fire on cleartext |
| 5 | A10 admits and narrows correctly | **Pass** — confers every child, stops at the tenant boundary |
| 6 | Admitted arms media-clean, and no worse than without authorization | **Pass** — 0 continuity errors, PCR no worse than the control |

Criterion 2 is the one the experiment existed to settle, and the figure is the strongest form the
answer could take: not "small", not "one packet", but zero on every arm.
[Control](../docs/control-plane.md) §3's claim that there is "no window in which an unauthorised
subscription is accepted and then torn down" is **supported by measurement** for this relay, on
loopback, under the arms specified here.

## Limits, stated in advance

- **Loopback only.** This measures enforcement logic, not enforcement under load or latency. The
  estate-scale question is [T38](test-38-entitlement-estate.md) and the timing question is
  [T37](test-37-entitlement-revocation.md).
- **This is not a penetration test.** The arms are the failure modes the design names, exercised
  honestly; they are not an adversarial search for ones it does not name.
  [Control](../docs/control-plane.md) §8 proposes red-teaming as separate work and this does not
  substitute for it.
- **It does not address content confidentiality from the operator.** The relay terminates the session
  and sees the payload. That is the documented design and an acknowledged open question
  ([Control](../docs/control-plane.md) §7.3, §9); nothing here tests a scheme that would change it.
- **One implementation.** Everything measured is a property of this relay. The credential profile —
  path-scoped JWTs, expiry, mTLS peer identity — is a deployment choice rather than a wire primitive
  guaranteed across implementations ([Evidence](../docs/evidence.md) §3.10), so a pass here does not
  generalise to another MoQ relay.
- **The capture is a userspace forwarder, not an interface capture**, for the reason given under
  Environment. It sees the same bytes; it is not the same instrument, and it would not see traffic
  that bypassed it.
- **Ten refusing runs, not a distribution.** Each arm was run once. The protocol asked for
  subscribe-to-refusal timing as a distribution over repeats and that was not collected here,
  because the two refusal mechanisms turned out to need separating first. Revocation timing *is*
  measured as a distribution, in [T37](test-37-entitlement-revocation.md).

## Corrections

**A capture cannot measure payload bytes on an encrypted transport.** The protocol specified
"payload bytes delivered before refusal, from capture — not from a relay log line", correctly
rejecting the log but wrongly assuming a capture could supply the alternative. QUIC encrypts the
payload, so a capture of this traffic yields ciphertext and can report only volume. The measurement
has to be taken at the receiving endpoint after decryption. The method rule this yields: **name the
domain a byte count is taken in — wire or decrypted — and check that the chosen instrument can see
that domain before fixing it in a pass criterion.**

**A refusal that produces no log line is still a refusal.** Two arms were enforced correctly with no
relay log entry and no client-visible error. Any rig that scores enforcement by counting denials
will report those cases as "not tested" rather than "passed", and would have done so here.

## Open

**Refusal by absence is undiagnosable.** An affiliate with a lapsed licence and an affiliate whose
feed has failed see exactly the same thing: a connection that works and a broadcast that never
appears. Neither end gets a signal distinguishing them. That is sound for confidentiality — the
absence of a channel is not disclosed — but it means a distributor's first-line support cannot tell
a rights problem from an outage without consulting the authorization endpoint's own records. Whether
that trade should be made deliberately, and whether an explicit "not entitled" response should be
offered to credentials that are valid for the connection, is a design question this experiment
raises and does not settle.
