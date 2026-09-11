# Test 38 — The estate: many channels, many affiliates, and a licensing matrix with holes

**State: run, 2026-09-11. Six of seven pass criteria met; criterion 4 met on CPU and not gradeable on
memory.** The third of three experiments behind
[Control](../docs/control-plane.md). [T36](test-36-entitlement-enforcement.md) grades one credential
against one path and [T37](test-37-entitlement-revocation.md) grades one revocation against the
clock. This one asks whether the model survives the shape a real distributor actually has: several
channels, several affiliates, and a licensing matrix that is deliberately not full.

**Headline.** The matrix is enforced combinatorially — all twenty-eight cells correct, every
licensed pair delivering and every unlicensed pair refusing. And **narrow topology does achieve
surgical de-provisioning**: withdrawing one channel from an affiliate that holds a key per channel
left the channel it kept running to the end of the observation window, uninterrupted and
indistinguishable from a session that had nothing done to it. Under broad topology the same
operation took the kept channel down for **2.78 s** and required re-provisioning it under a new
credential, because **the revocable unit is the key, not the grant inside the token.** That is the
de-provisioning-granularity term the design document's scope trade-off does not consider, and it
decides the topology.

**The sharpest result is about mTLS, and it is a warning.** A client presenting a certificate signed
by the relay's configured root, carrying **no token at all**, was served every channel in the
estate — including the channel no affiliate licenses and **the other broadcaster's channel**. mTLS
confers unrestricted access at whatever path is dialled. It cannot express a licensing matrix, and
an operator who issues per-affiliate certificates expecting them to scope access gets the opposite
of what they intended.

## Objective

Three questions, in descending order of how likely they are to change a design.

1. **Does per-channel de-provisioning cost an interruption on the channels an affiliate keeps?** If
   narrowing a grant closes the session the affiliate then reconnects into, then dropping one
   service of five glitches the other four — and the mitigation is a session per channel rather
   than a session per affiliate. That is a topology decision, taken once, and it is expensive to
   reverse.
2. **Is the matrix enforced combinatorially?** Every licensed pair delivers and every unlicensed
   pair refuses, across the whole matrix rather than at the one or two points a smoke test would
   touch.
3. **What does entitlement cost the scaling model?** [T26](test-26-cross-host-fanout.md) measured an
   unauthenticated relay at **0.806 % of a core and 1.39 MB per subscriber**, linear and well fitted.
   Whether authorization perturbs that, and whether the re-check traffic
   [T37](test-37-entitlement-revocation.md) characterises becomes material across an estate, is
   measurable against a known baseline.

## What is already known, and precisely what it leaves open

[T26](test-26-cross-host-fanout.md) gives the fan-out model for an unauthenticated relay, including
that the binding resource is relay CPU and that saturation is a collapse rather than a graceful
degradation. [T25](test-25-isolation-under-abuse.md) establishes that one abusive receiver can cost
the relay a large multiple of its working set without the other receivers noticing. Neither involved
credentials at all.

What was open is everything about authorization at scale, and one question in particular that neither
the protocol nor the design document settles: **the grain at which a session should be scoped.**
[Control](../docs/control-plane.md) §4 states the scope-granularity trade-off as blast radius against
renewal traffic and defaults to narrow. There is a **third term** the document does not consider, and
the measurement below shows it dominates the other two: **de-provisioning granularity.** Narrow is
not merely the safer default against a leak — it is the only topology under which one channel can be
withdrawn from an affiliate without interrupting the channels it keeps.

## Environment

Two hosts, following the rule that fan-out figures taken on one box measure the box: subscribers are
driven from a second host so the cost figures are comparable with
[T26](test-26-cross-host-fanout.md)'s.

| Component | Role |
|---|---|
| Relay host | one relay, authorization configured, resource-sampled throughout |
| Subscriber host | all affiliate subscribers, one process per affiliate-channel session |
| Publisher | several channels under one broadcaster root, each a continuous known clip |
| Authorization endpoint | the stub from [T37](test-37-entitlement-revocation.md), extended to serve a matrix |

The matrix is fixed before any run and is deliberately irregular — some affiliates take one channel,
some take most, at least two take overlapping but unequal subsets, and at least one channel is
licensed by nobody. The irregularity is the point: a full matrix would pass a model that simply
ignored scope.

## Procedure

### Part 1 — the matrix

For every affiliate-channel pair, attempt a subscribe with that affiliate's credential and grade
delivery. The whole matrix is run, not a sample, because the failure this detects is a scope
boundary that leaks in one direction only.

The unlicensed-by-nobody channel is the control: if any affiliate reaches it, the leak is in the
grant model rather than in one credential.

### Part 2 — session topology

The same matrix is served two ways, and everything in Parts 3 and 4 is measured under both.

| Topology | Credential | Sessions per affiliate |
|---|---|---|
| **Broad** | one token naming every channel the affiliate licenses | one |
| **Narrow** | one token per licensed channel | one per channel |

**Part 2 is what makes the experiment decide something rather than describe something.** The two
topologies are the choice a deployment has to make, and the arms exist so the choice can be made on
measurement.

### Part 3 — narrowing a grant

With an affiliate licensed for several channels and all of them flowing, withdraw exactly one at the
authorization endpoint. Capture every channel that affiliate holds, throughout.

The measurement is on **the channels that were not withdrawn**: whether they are interrupted, for how
long, and whether the interruption is a clean gap or a continuity break. Under the broad topology
the hypothesis is that they are interrupted; under the narrow topology the hypothesis is that they
are untouched. Both are stated in advance, and the interesting outcome is the size of the gap rather
than its existence.

Run the converse too — *adding* a channel to a live affiliate under both topologies — because a grant
that widens may also re-scope the session, and an operator adding a service should not have to
schedule it as an outage.

### Part 4 — cost against the T26 baseline

Sweep affiliate count under both topologies, holding the channel set fixed, sampling relay CPU, RSS
and egress on the same instruments [T26](test-26-cross-host-fanout.md) used, so the comparison is
against a figure rather than against an impression. At each point also record the authorization
request rate, which under the narrow topology multiplies by the number of licensed channels.

Repeat the sweep at two re-check cadences taken from [T37](test-37-entitlement-revocation.md)'s
sweep — one slack, one at whatever cadence bought a sub-second revocation — so the estate-level
price of a tight revocation bound is measured rather than extrapolated.

### Part 5 — keys and certificates

**Rotation.** Rotate an affiliate's verifying key with overlapping validity, as
[Control](../docs/control-plane.md) §7.2 requires, and confirm that live sessions are not
interrupted and that a token signed by the retired key stops being accepted at the right moment.
The document names distribution of rotated keys to the edge as an open question (§9); this measures
whether the window can be made clean at all.

**Certificates.** Repeat the matrix of Part 1 with per-affiliate client certificates instead of
tokens, since mutual TLS is the other credential the design specifies and the one a broadcaster is
more likely to already operate. Grade the same admit/refuse matrix, and separately grade whether
certificate withdrawal works as a de-provisioning path and on what timescale — it is a different
mechanism from token revocation and it may well have a different bound.

**Key handling.** Confirm on the asymmetric arms that the relay holds no signing material, which is
§7.2's requirement and the one criterion in §8 that can be checked by inspection rather than by
timing.

## Results

### Part 1 — the matrix

Seven credentials against four channels, every cell attempted. Delivery is graded on payload bytes
reaching the subscriber, as in [T36](test-36-entitlement-enforcement.md).

| Credential | Licensed | `cnn` | `cnn-intl` | `tnt` | `nobody` |
|---|---|---|---|---|---|
| Affiliate A | `cnn` | **deliver** | refuse | refuse | refuse |
| Affiliate B | `cnn`, `tnt` | **deliver** | refuse | **deliver** | refuse |
| Affiliate C | `tnt` | refuse | refuse | **deliver** | refuse |
| Affiliate D (broad) | `cnn`, `tnt` | **deliver** | refuse | **deliver** | refuse |
| Affiliate E, `cnn` key | `cnn` | **deliver** | refuse | refuse | refuse |
| Affiliate E, `tnt` key | `tnt` | refuse | refuse | **deliver** | refuse |
| Affiliate F | `cnn-intl` | refuse | **deliver** | refuse | refuse |

Twenty-eight cells, twenty-eight correct. The `nobody` column is the control and is empty, so no
credential reaches a channel simply because it exists. Affiliate F is the counterpart control: it
holds the *only* grant to `cnn-intl` and gets it, which shows the empty cells elsewhere in that
column are scope decisions rather than an unreachable channel.

### Parts 2 and 3 — topology decides whether de-provisioning is surgical

One affiliate holds two channels and loses one of them. The measurement is on the channel it keeps.

| | Broad — one key covering both channels | Narrow — one key per channel |
|---|---|---|
| Withdrawn channel, last byte | +0.40 s | +0.11 s |
| **Kept channel, last byte** | **+0.63 s — taken down with it** | **+27.96 s — ran to the end of the window** |
| Kept channel, continuity errors | 0 | **0** |
| Kept channel, packets | 71,044 then 121,705 after re-provisioning | **229,743, continuous** |
| Re-provisioning needed | yes — a new credential and a new session | none |
| Kept channel resumes | +3.41 s | n/a, never stopped |
| **Service interruption on the kept channel** | **2.78 s** | **none** |

**The revocable unit is the key, not the grant inside the token.** Under the authorization-endpoint
model the lever available to withdraw an entitlement is to stop serving the verifying key for a
`kid`. A token's own claims cannot be narrowed after issue. So an affiliate whose channels all
authenticate under one key cannot lose one of them without losing all of them, and the survivors
have to be re-provisioned under a fresh credential. An affiliate with a key per channel loses
exactly the channel withdrawn.

**Criterion 2's "no measurable gap" needed a control to be answerable honestly.** The kept channel
under narrow topology shows five pauses longer than half a second in its delivery trace, the
largest 3.195 s. An undisturbed session on the same channel, with nothing done to it at all, shows
four such pauses with the largest at 3.013 s. The pauses are the transport's ordinary delivery
burstiness, not the de-provisioning: with zero continuity errors in both, no media was lost in
either, and the narrow kept channel is indistinguishable from a session that was left alone.
Without that control run the arm would have reported a 3.2 s interruption that does not exist.

**The converse — adding a channel — costs nothing under either topology.** Measured in
[T37](test-37-entitlement-revocation.md) E2: with one channel flowing, a second was brought up
alongside it and the first delivered 143,728 packets with zero continuity errors across the
addition.

### Part 4 — what entitlement costs the scaling model

Four arms on one host: an unauthenticated relay, and three authenticated arms differing only in
re-check cadence. Twenty subscribers on one channel, CPU taken as a cumulative-CPU-time delta across
a fifteen-second timed dwell, fitted linearly in subscriber count.

| Arm | Authorization | Re-check | CPU %/core per subscriber | r² | Fixed CPU (intercept) |
|---|---|---|---|---|---|
| Control | none | — | **0.0920** | 0.986 | 0.227 % |
| Authenticated | `--auth-api` | none (no `max-age`) | **0.0920** | 0.970 | 0.400 % |
| Authenticated | `--auth-api` | 10 s | **0.0920** | 0.958 | 0.453 % |
| Authenticated | `--auth-api` | 1 s | **0.1173** | 0.980 | 0.493 % |

**Authorization is free per subscriber until the re-check cadence gets tight.** The marginal slope is
identical to three decimal places across the control, the unrevalidated arm and the ten-second arm.
Admission is a once-per-session cost and disappears into the intercept, which rises by 0.17 to
0.23 percentage points — a fixed charge on the relay, not a charge per subscriber.

At a one-second cadence the slope rises **27 %**, to 0.1173. That is the mechanism
[T37](test-37-entitlement-revocation.md) characterises arriving at estate scale: re-check is **per
session**, so twenty subscribers at a one-second cadence is twenty requests per second, and a cost
that was fixed becomes marginal. Set beside T37's finding that revocation latency is
`(cadence − phase) + 0.110 s`, the price of pulling the revocation bound down toward a second is a
27 % increase in the per-subscriber CPU slope — which is the term that sets the fan-out ceiling.

**The RSS half of criterion 4 is not gradeable in this rig, and the figures are withheld rather than
quoted.** RSS fits were poor — r² of 0.80, 0.77, 0.01 and 0.44 — and the one-second arm fitted a
*negative* slope, which is not a memory behaviour. The intercepts rise monotonically with arm order
(14.5, 17.5, 57.5 and 71.1 MB), which is the relay retaining the previous arm's peak across a
twenty-five-second settle rather than a cost of authorization. The campaign's rule applies: a delta
that cannot be attributed to a mechanism is not quoted. Measuring per-subscriber RSS under
authorization needs a relay restarted between arms, and is left open.

### Part 5 — keys and certificates

**Rotation with overlapping validity is clean.** A successor key was added to the estate alongside
the predecessor, the affiliate brought up a session on the new credential while the old one was
still running, and the predecessor was then retired. The predecessor's session ended **0.122 s**
after retirement — inside one re-check cadence — and the successor's ran on undisturbed. Make-
before-break works, and the overlap window is the operator's to choose.

**Key handling passes by inspection, and by a stronger route than expected.** All eleven keys the
authorization endpoint can serve are ES256 public keys carrying `key_ops: ["verify"]` and no private
scalar. More to the point, the relay was never given key material at all: its entire authorization
configuration is `--auth-api http://…`, so there is no key directory on the relay host to inspect.
[Control](../docs/control-plane.md) §7.2's requirement is met structurally rather than by discipline.

**Per-affiliate mTLS certificates cannot express a licensing matrix.** With the relay configured to
accept client certificates from an affiliate CA, a client presenting a valid certificate and **no
token** was served:

| Target | Result |
|---|---|
| `wbd/cnn` | 7,260,560 bytes |
| `wbd/cnn-intl` | 6,736,040 bytes |
| `wbd/tnt` | 7,263,380 bytes |
| `wbd/nobody` — licensed by nobody | 2,408,656 bytes |
| **`rival/cnn` — the other broadcaster** | **7,093,804 bytes** |

Everything. The relay treats a verified client certificate as an unrestricted credential for
whatever path is dialled, and the authorization endpoint is told only that *some* certificate was
presented — never which one. The peer's identity never reaches the place where entitlement is
decided, so certificate-based per-affiliate scoping is not merely unimplemented but not expressible.

This does not contradict [Control](../docs/control-plane.md) §3, which already assigns mTLS to
data-plane peers and JWTs to subscribers. It shows why that split is load-bearing rather than
stylistic, and what the cost of ignoring it would be: a single affiliate certificate is a master key
to every tenant on the relay. Certificate withdrawal as a de-provisioning path was not measured
separately, because an all-or-nothing credential has no per-channel de-provisioning behaviour to
measure.

## Metrics

- Admit/refuse per matrix cell, as a matrix, scored against the licensing matrix fixed in advance.
- **Interruption on retained channels during a withdrawal**: duration, continuity errors and PCR
  conformance, per topology. The headline result.
- Relay CPU, RSS and egress per subscriber, per topology, fitted the way
  [T26](test-26-cross-host-fanout.md) fitted them, and reported as a delta against that baseline.
- Authorization request rate at the relay and at the endpoint, by affiliate count, topology and
  cadence.
- Interruption and acceptance behaviour across a key rotation window.
- Whether any signing material is present on the relay host.

## Pass criteria, fixed before running

1. **Every licensed cell delivers and every unlicensed cell refuses.** One wrong cell fails the
   experiment. The nobody-licensed channel delivers to nobody.
2. **Under the narrow topology, withdrawing one channel leaves the affiliate's other channels with
   zero continuity errors and no measurable gap.** If even the narrow topology interrupts, the
   finding is that per-channel de-provisioning is not surgical at any grain, which is a material
   limitation of the model and must be stated as one.
3. **The broad-topology result is reported whichever way it falls**, with the gap measured. No pass
   condition is set for it: the experiment exists to find out, and both answers are publishable.
4. **Per-subscriber CPU and RSS stay within 20 % of the [T26](test-26-cross-host-fanout.md)
   baseline** at the slack cadence. A larger delta is a finding about the cost of entitlement and
   must be attributed to a mechanism before it is quoted.
5. **Key rotation with overlapping validity interrupts nothing**, and the retired key stops being
   accepted within one re-check cadence of its retirement.
6. **No signing material on the relay host** on the asymmetric arms.
7. **Adding a channel to a live affiliate interrupts nothing** under at least one topology, and which
   one is stated.

## Verdict against the pass criteria

| # | Criterion | Result |
|---|---|---|
| 1 | Every licensed cell delivers, every unlicensed cell refuses | **Pass** — 28 of 28 cells correct; the nobody-licensed channel delivers to nobody |
| 2 | Narrow topology: kept channels keep zero continuity errors and no measurable gap | **Pass** — 229,743 packets, 0 continuity errors, and the delivery trace is indistinguishable from an undisturbed control |
| 3 | Broad-topology gap reported whichever way it falls | **Reported** — the kept channel is taken down at +0.63 s and resumes at +3.41 s under a fresh credential: **2.78 s** |
| 4 | Per-subscriber CPU and RSS within 20 % of baseline at the slack cadence | **CPU pass, RSS not gradeable** — CPU slope identical to the same-host unauthenticated control at 10 s cadence (0.0920 %/core, 0 % delta); RSS fits too poor to attribute and the figures are withheld |
| 5 | Key rotation with overlapping validity interrupts nothing, retired key stops within one cadence | **Pass** — successor undisturbed, predecessor stopped 0.122 s after retirement |
| 6 | No signing material on the relay host | **Pass** — every servable key is `key_ops: ["verify"]` with no private scalar, and the relay was given no key material at all |
| 7 | Adding a channel to a live affiliate interrupts nothing, topology stated | **Pass under narrow topology** — 143,728 packets, 0 continuity errors on the incumbent channel across the addition. Not measured under broad |

Six of seven met; criterion 4 met on CPU and not answerable on RSS in this rig.

**And one finding sits outside the criteria because no criterion anticipated it**: per-affiliate mTLS
certificates confer unrestricted cross-tenant access. Criterion 1 would have been *failed* by the
certificate arm had it been graded as a matrix — which is the right way to read it, and is why the
result is reported as a warning rather than folded into a pass.

## Limits, stated in advance

- **Scale is modest.** This is tens of affiliates and a handful of channels, not the thousand-
  destination estate the economics turn on ([Economics](../docs/economics.md) §6). It measures the
  *shape* of the cost so it can be extrapolated with its assumptions visible; it does not measure
  the estate.
- **One relay.** Entitlement across a relay mesh, where the admitting node and the revoking decision
  may not be the same node, is untested and is the harder problem.
- **Synthetic licensing matrix.** It is irregular by construction, but it is invented. A real
  affiliate estate has structure — regional groupings, tiering, overlapping windows — that may
  exercise the path algebra differently.
- **Rights windows are not modelled.** Every grant here is on or off. Time-bounded licensing, where
  an affiliate takes a channel for three hours on Saturdays, is the case
  [Control](../docs/control-plane.md) §4 calls *temporary* and it is not exercised; whether scheduled
  grant and expiry compose cleanly with the re-check cadence is left open.
- **Nothing here tests the integration surface**, which [Control](../docs/control-plane.md) §6 argues
  is what actually determines whether this layer delivers anything. A correct mechanism driven by a
  stub is not evidence that it can be driven by a broadcaster's rights and scheduling systems, and
  the document is explicit that the integration, not the mechanism, is the load-bearing commercial
  assumption.

Two limits emerged in the running and belong with the ones fixed in advance.

- **The cost ladder is a comparison of slopes on one host, not a reproduction of
  [T26](test-26-cross-host-fanout.md).** T26's per-subscriber figures were measured cross-host on EC2;
  this ladder is loopback on the development machine, over twenty subscribers rather than eighty. The
  absolute per-subscriber cost here is a property of this hardware and is not comparable with T26's.
  What *is* comparable, and what criterion 4 is therefore graded on, is the authenticated arms against
  an unauthenticated relay **on the same host in the same session**.
- **mTLS de-provisioning was not measured** because there is nothing per-channel to measure: the
  credential is all-or-nothing, so withdrawal can only be withdrawal of everything, which is
  certificate revocation rather than entitlement.

## Corrections

**The CPU instrument was wrong the first time and the figures were discarded.** The first ladder
sampled `ps -o %cpu`, which on Darwin is a decaying average over up to a minute of real time. With a
twelve-second dwell per step that average never settled, so each reading carried the previous step's
load: the zero-subscriber point read *higher* than the five-subscriber point in two of three arms,
which is the signature of the contamination rather than a relay behaviour. Re-instrumented to read
cumulative process CPU time either side of the dwell and divide by the wall interval, which averages
over exactly the window of interest and needs no settling. **Method rule: a per-interval CPU figure
must come from a CPU-time delta over that interval, not from a platform utilisation field whose
averaging window is longer than the interval.**

**A "3.2 s interruption" that was not one.** The narrow topology's kept channel showed a 3.195 s gap
in its delivery trace after the withdrawal, and the arm was about to be written up as a near-miss on
criterion 2. An undisturbed control session on the same channel showed a 3.013 s gap with nothing
done to it at all. **Method rule: a gap in a delivery trace is only evidence of damage if a session
with the intervention removed does not show the same gap; with zero continuity errors, a pause is
delivery burstiness and no media was lost.**

## Open

- **Per-subscriber RSS under authorization is unmeasured**, for the instrument reason in Part 4. It
  needs a relay restarted between arms.
- **`--server-tls-root` is a cross-tenant master key and the relay says nothing about it.** A valid
  client certificate admits the peer to every path on the relay, including other tenants', and the
  authorization endpoint is not told which certificate was presented, so it cannot object. An
  operator who configures client-certificate authentication alongside a token-based licensing matrix
  has silently bypassed the matrix. This is worth an upstream report: at minimum the peer's
  certificate subject should reach `AuthApiRequest`, so the endpoint can scope what a certificate
  admits.
- **De-provisioning at the grant level rather than the key level does not exist.** Narrowing an
  affiliate's entitlement requires a key per unit of entitlement, so the key estate has to be sized
  by the licensing matrix rather than by the affiliate count. Whether that scales to a real estate —
  hundreds of affiliates times tens of channels, each a key the endpoint must serve and the relay
  must cache — is untested and is the practical objection to the recommended topology.
- **Rights windows**, per the limits above.
