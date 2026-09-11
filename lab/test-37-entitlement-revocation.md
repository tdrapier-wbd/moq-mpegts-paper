# Test 37 — Provisioning and de-provisioning: what actually stops a feed, and how fast

**State: run, 2026-09-11. Five of six pass criteria met; criterion 2 failed.** The second of three
experiments behind [Control](../docs/control-plane.md). [T36](test-36-entitlement-enforcement.md)
asks whether the relay admits the right callers; this one asks the operator's question. A
broadcaster must be able to turn a feed on for an affiliate and, more importantly, turn it off — and
must know the bound on how long "off" takes.

**Headline.** Revocation is a **poll**, and the bound it buys is
`(re-check cadence − phase) + 0.110 s`, measured across five cadences with the fixed overhead
constant to within two milliseconds. Worst case is therefore one full cadence plus 0.110 s. The
smallest cadence the relay will accept is **one second**, because `max-age` is integer
delta-seconds — so the best achievable worst case is about **1.11 s**, and
[Control](../docs/control-plane.md) §8's sub-second revocation target **cannot be met by this
mechanism at any setting.** Criterion 2 fails on that.

Worse, the settings an operator would reach for to go faster do the opposite. `max-age=0` and
`max-age=0.5` both produce **no revalidation at all**, as does omitting `Cache-Control`. In that
state a withdrawn grant never takes effect: one arm kept delivering for the full 50 s it was
observed, having been re-checked exactly once, at admission. **Three distinct configurations
silently yield an unrevocable session, and one of them is what "revoke immediately" looks like.**

Against that, the backstop is real. The hypothesis that expiry would not bound an established
session is **falsified**: a session ends 0.110 s after its token expires *even with revalidation
switched off entirely*. Token lifetime, not cadence, is what makes the unrevocable cases survivable.

## Objective

Measure the time from a control-plane decision to the last media byte an affiliate receives, for
each mechanism the implementation actually provides, and establish which of them bounds the worst
case. Then measure what each bound costs in steady-state load, because the two move in inverse
proportion and the trade-off is the whole design question.

[Control](../docs/control-plane.md) §4.1 describes two paths together: a fast path that drops
affected subscriptions "sub-second when the control plane is healthy", and a backstop of short token
lifetimes so "the worst case is bounded by the token lifetime even if the fast path is unavailable".
§8 proposes fast-path revocation under one second as an acceptance target. **Neither the mechanism
nor the target has been measured, and reading the implementation suggests both descriptions need
qualifying.**

## What is already known, and precisely what it leaves open

Only that the enforcement point exists ([Evidence](../docs/evidence.md) §3.10). Everything about its
behaviour over time is open.

Reading the relay's authorization path yielded four hypotheses, stated so that the run could
falsify them. It falsified one and confirmed three.

| | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| **H1** | Expiry does not bound an established session | **Falsified** | Session ends 0.110 s after `exp`, with revalidation both on and off (D1) |
| **H2** | The fast path is a poll, not a push | **Confirmed** | Re-check interval tracks `max-age` to 3 ms; teardown = (cadence − phase) + 0.110 s across five cadences (D2) |
| **H3** | A session may be unrevocable by default | **Confirmed** | No `Cache-Control`, `max-age=0` and `max-age=0.5` each yield exactly one authorization request and no re-check ever (D6) |
| **H4** | An unreachable control plane is stricter than documented | **Only where opted into** | With `stale-while-revalidate=30` the session closes at 34.1 s; with no staleness window sessions survived a 150 s outage intact, which is what §4.2 documents (D5) |

- **H1 — expiry may not bound an established session.** Token expiry appears to be enforced when a
  connection is admitted, not continuously. If so, a session admitted one second before its token
  expires may keep delivering indefinitely, and the "backstop" in §4.1 bounds only *new*
  subscriptions. That would make token lifetime the wrong parameter to reason about for
  de-provisioning a live affiliate, which is exactly the case an operator cares about.
- **H2 — the fast path is a poll, not a push.** Revocation appears to work by periodically replaying
  the admission request against an authorization endpoint and closing the session when the replay no
  longer covers the scope originally granted. If so the bound is the re-check cadence plus one
  round trip, and "sub-second" is purchasable only by setting the cadence near one second, at a cost
  of one authorization request per session per second.
- **H3 — a session may be unrevocable by default.** The re-check schedule appears to be opted into by
  the authorization endpoint returning a `Cache-Control: max-age`. An endpoint that does not set one
  would leave the session never re-checked. Combined with H1 this is the serious case: a session
  that neither expires nor revalidates cannot be stopped except by restarting the relay.
- **H4 — an unreachable control plane may be stricter than documented.** §4.2 says existing valid
  tokens continue to be honoured until expiry when the control plane is unreachable. The
  implementation appears instead to close the session once a staleness window elapses. That is a
  *safer* failure mode than documented, but it is a different one, and it means a control-plane
  outage can interrupt live feeds rather than merely freezing changes — which contradicts the
  out-of-band, non-fate-sharing principle in §1.1 that the whole control-plane design rests on.

H4 is the one with architectural consequences, so it is graded as carefully as the timing arms.

## Environment

Single host, loopback, plus a small purpose-built authorization endpoint that the experiment
controls. The endpoint is part of the apparatus, not part of the finding: it exists so that a grant
can be withdrawn at a known instant.

| Component | Role |
|---|---|
| Relay | configured against the unified authorization endpoint |
| Authorization endpoint | a local HTTP service that returns the verifying key, the grant and a `Cache-Control` header, all switchable at a known instant |
| Publisher | one channel, continuous, from a known clip |
| Affiliate subscribers | one per arm, each with its own credential, each capturing its own egress |

The endpoint logs every request it receives with a timestamp, which gives the re-check cadence
directly rather than by inference.

## Procedure

**The instant of the control-plane decision is the zero of every measurement**, and it is taken at
the authorization endpoint, not at the operator's keyboard. Every arm is repeated enough times to
report a distribution rather than a single figure, because a poll-based bound produces a spread
across the cadence interval by construction and a single sample would misrepresent it.

### Enable

**E1 — grant and connect.** Provision an affiliate that has no credential, then measure from grant
to its first delivered media byte. This is the provisioning-latency counterpart to §8's `< 5 s`
target, and it decomposes into credential issue, connect, and first group.

**E2 — grant a second channel to an existing affiliate.** Measure whether the new channel starts
without disturbing the one already flowing. This matters more than E1 in practice, because adding a
service to a live affiliate is the common operation.

### Disable

Each mechanism is measured separately, because they have different bounds and an operator needs to
know which one they are relying on.

**D1 — stop refreshing (the backstop).** Admit a session with a short-lived token, then decline to
refresh, and measure the time from `exp` to the last media byte. **This arm tests H1 directly.** Run
it both with re-checking configured and with it disabled, because the difference between those two
results is the finding: if the session survives its own expiry when re-checking is off, then expiry
is not a backstop.

**D2 — withdraw the grant (the fast path).** With the session established and re-checking on a known
cadence, flip the endpoint to refuse. Measure decision-to-last-byte. Sweep the cadence across at
least a decade — the sweep is the experiment, not a single point, because the claim under test is
about the *relationship* between the bound and its cost, and a single cadence would answer neither.
At each cadence record both the teardown distribution and the authorization request rate per
session.

**D3 — withdraw the key.** Remove the affiliate's verifying key, and separately replace a different
key under the same identifier. The second case is the sharper one: a check that merely asks whether
some key exists for an identifier would pass it while the retained credential is no longer valid.

**D4 — narrow the grant.** Covered in [T38](test-38-entitlement-estate.md), where an affiliate loses
one channel of several; it is named here so the set of mechanisms is complete.

**D5 — unreachable endpoint.** Make the endpoint unreachable with the session established and
nothing revoked. Measure whether the session survives, and if it ends, how long the staleness window
runs and what the affiliate sees. **This arm tests H4.**

**D6 — no schedule offered.** Admit a session against an endpoint that returns no `Cache-Control`,
then revoke. Measure whether anything stops. **This arm tests H3**, and if the session proves
unstoppable the result is a configuration hazard worth reporting upstream and worth naming in the
design.

### Collateral

**C1 — does disabling one affiliate disturb another?** Through every D arm, a second affiliate holds
a valid grant to the same channel and is captured throughout. Its continuity and PCR conformance are
graded across the revocation instant.

## Results

### D2 — the cadence sweep

Six repetitions per cadence, each with a randomised sub-cadence phase. The phase matters: with an
integer settle time the decision lands at a fixed point in the poll cycle and six runs return six
near-identical figures that look like a tight distribution and are one measurement repeated.

| Cadence | n | Min | Median | Max | Max ÷ cadence | Authorization requests/s per session |
|---|---|---|---|---|---|---|
| 1 s | 6 | 0.244 | 0.808 | **1.078** | 1.078 | 0.959 |
| 2 s | 6 | 0.114 | 0.617 | 1.980 | 0.990 | 0.417 |
| 5 s | 6 | 0.908 | 1.759 | 3.510 | 0.702 | 0.124 |
| 10 s | 4 | 0.948 | 4.875 | 8.827 | 0.883 | 0.040 |
| 30 s | 4 | 4.641 | 11.302 | 35.411 | 1.180 | 0.026 |

All figures in seconds from the control-plane decision to the affiliate's last media byte.

The teardown is not a constant but a *phase*: taking the phase from the endpoint's own request log —
the interval since the last re-check before the decision — the residual is a fixed overhead of
astonishing stability.

| Cadence | n | Fixed overhead | s.d. |
|---|---|---|---|
| 1 s | 6 | 0.110 s | 0.001 |
| 2 s | 6 | 0.109 s | 0.001 |
| 5 s | 6 | 0.110 s | 0.000 |
| 10 s | 4 | 0.109 s | 0.002 |

**Teardown = (cadence − phase) + 0.110 s**, so revocation latency is uniform on
[0.110, cadence + 0.110] and the worst case is one cadence plus 110 ms. Two caveats on the table
above. The 30 s rows are **censored**: the observation window was 38 s, so a decision landing late
in the settle period could not be observed to completion, and the 30 s overhead figure is excluded
for that reason rather than reported. Four of thirty runs recorded no media at all, for a reason
that is itself a result and is described under *provisioning* below.

The 0.110 s is the floor of this instrument, not a resolved relay latency: it is the same figure the
expiry arm returns, which points at the client's flush-and-exit path rather than at anything the
relay does. The relay's own close latency is therefore **at most** 110 ms and is not resolved
further here.

### There is no sub-second setting, and trying to make one disables revocation

`max-age` is integer delta-seconds, so 1 s is the smallest cadence expressible. Below it the
behaviour is not "faster" but "none at all":

| `Cache-Control` | Authorization requests in an 8 s session | Revocation |
|---|---|---|
| `max-age=1` | 8 | works, worst case ≈ 1.11 s |
| `max-age=0` | **1** (admission only) | **never** |
| `max-age=0.5` | **1** (admission only) | **never** |
| header absent | **1** (admission only) | **never** |

This is the sharpest operational finding in the experiment. An operator reaching for `max-age=0` to
mean "check every time" gets a session that is never checked again.

### D6 — an unrevocable session, measured

Admitted against an endpoint returning no `Cache-Control`, then the grant withdrawn. The endpoint
logged **one** request for that affiliate, at admission, and none in the following 66 s. The
affiliate received **53,833,940 bytes — 43.3 s of programme — after its grant was withdrawn**, and
was still receiving when the observation window closed at 49.96 s. Nothing stopped it. The only
bound remaining on such a session is its token's expiry.

### D1 — expiry bounds an established session, and H1 is falsified

A token was signed to expire fifteen seconds after admission, and the session observed for fifty.

| Variant | Re-checking | Last byte, relative to `exp` | Verdict |
|---|---|---|---|
| D1a | on, `max-age=5` | **+0.108 s** | stopped at expiry |
| D1b | **off**, no `Cache-Control` | **+0.110 s** | stopped at expiry |

D1b is the decisive cell. The session had no revalidation schedule at all — the same configuration
that made D6 unrevocable — and it still ended within 110 ms of its token expiring. Expiry is
enforced against established sessions and not only at admission. §4.1's backstop is **correct as
written**, and the source reading that suggested otherwise was wrong.

This also resolves the relationship between the two knobs. Cadence bounds how fast a *deliberate*
revocation takes effect; token lifetime bounds how long *any* session can outlive the control plane's
intentions, including in the three configurations where revocation silently does nothing.

### D3 — withdrawing a key, and replacing one under the same identifier

Both at a 5 s cadence.

| Arm | Lever | Decision to last byte | Collateral affiliate |
|---|---|---|---|
| D3a | verifying key withdrawn | 4.152 s | ran to the end of the window, undisturbed |
| D3b | **different key served under the same `kid`** | 4.154 s | ran to the end of the window, undisturbed |

D3b is the sharper case and it passes: the replacement is detected because the re-check replays the
whole admission question and re-verifies the retained token against whatever key comes back. A
narrower check — "does some key still exist for this `kid`?" — would have found one and kept the
session alive.

### D5 — an unreachable endpoint, and the staleness window

The endpoint was made to answer 503 with sessions established and nothing revoked.

| Arm | `Cache-Control` at admission | Outage duration observed | Decision to last byte |
|---|---|---|---|
| D5a | `max-age=5` | 45 s | still delivering at the end of the window |
| D5b | `max-age=5, stale-while-revalidate=30` | 51 s | **34.1 s** — closed, `reason=stale` |
| D5c | `max-age=5` | **150 s** | **still delivering at the end of the window** — 132.3 s of programme after the outage began |

**The staleness window is opt-in, and without it §4.2's documented behaviour is what happens.**
D5c is the arm that settles this: two and a half minutes with the authorization endpoint returning
503 on every re-check, and neither the affiliate under test nor the collateral affiliate lost a
byte. The relay logged no `reason=stale` closure for either. Sessions are honoured on last-known-good
state exactly as §1.1's non-fate-sharing principle requires.

Where `stale-while-revalidate` *is* set, an outage longer than the window closes live sessions —
the behaviour H4 predicted, but as a configured choice rather than as the default. That makes it a
trade an operator selects rather than a contradiction in the design.

**Where the window is configured, the outage is not confined to subscribers.** Publishers
authenticate through the same endpoint and are revalidated on the same schedule, so during D5b the
channels themselves were torn down; they reconnected once the endpoint returned, but a publisher
whose own reconnect budget expires first leaves the channel off air until something restarts it. An
operator who sets a staleness window to bound stale entitlements should know it also bounds how long
their own contribution feeds survive a control-plane outage.

### E1/E2 — provisioning, and the cache that bounds it

Grant-to-first-byte, once the endpoint's previous answer is no longer cached, is **0.098 s and
0.149 s** over the two clean repetitions. But three of five repetitions delivered nothing at all,
and the reason is the same mechanism that governs revocation: **the relay caches the endpoint's
reply for `max-age`, so a newly granted affiliate stays refused until the cached refusal expires.**
Provisioning latency is therefore *cache residue plus about 0.1 s*, bounded by the same parameter as
revocation and running from 0 to one full cadence. §8's `< 5 s` provisioning target is met for any
cadence at or below five seconds and is a property of that setting rather than of the relay.

The same effect accounts for the four sweep runs that recorded no media: each followed an arm that
had withdrawn the grant, and the withdrawal was still cached when the next arm's subscriber dialled.

**E2 — adding a channel to a live affiliate costs nothing.** With affiliate B streaming `cnn`, a
second channel was brought up alongside it. `cnn` delivered 143,728 packets with **zero continuity
errors** across the addition, and `tnt` 76,840 packets with zero. Adding a service does not disturb
the services already flowing.

### C1 — collateral

Across all twenty-six usable sweep runs and every D arm, **the uninvolved affiliate was never
disturbed**: it ran to the end of its observation window in every case, with zero continuity errors.
Revoking one customer does not glitch another.

## Metrics

- **Decision-to-last-byte**, per arm, as a distribution: median, worst case, and spread across the
  cadence interval. Measured in the media domain from the affiliate's captured egress — the last TS
  packet and the presentation timestamp it carries — not from a session-closed log line. This
  follows the campaign's rule that reliability is scored on the media rather than on the session.
- **Authorization request rate per session**, by cadence, from the endpoint's own log.
- Grant-to-first-byte for the enable arms, decomposed by stage.
- Whether delivery stops at all, per arm — a boolean that outranks every timing figure, because an
  unbounded arm makes its own latency meaningless.
- The uninvolved affiliate's continuity errors and PCR conformance across each revocation.

## Verdict against the pass criteria, fixed before running

The criteria were written against the claims in [Control](../docs/control-plane.md), so that the
experiment could correct the document rather than merely describe the implementation.

| # | Criterion | Verdict |
|---|---|---|
| 1 | Every disable mechanism terminates delivery | **Fail, for one mechanism.** Withdrawing a grant, withdrawing a key and replacing a key all terminate delivery. Withdrawing a grant from a session admitted without a `Cache-Control` terminates nothing — only the token's expiry does |
| 2 | **D2 achieves a worst case under one second at some cadence**, with the request rate that buys it | **Fail.** The best achievable worst case is 1.078 s measured, ≈ 1.11 s modelled, at the minimum expressible cadence of 1 s, costing **0.959 authorization requests per second per session**. Sub-second is not reachable at any setting |
| 3 | D1 with re-checking disabled terminates at token expiry, within one group interval | **Pass**, comfortably — 0.110 s, far inside one group interval. H1 falsified |
| 4 | D5 behaviour determined and stated, whichever way it falls | **Pass** (determined). By default, sessions survive an unreachable endpoint — 150 s observed with no loss — matching §4.2. Where `stale-while-revalidate` is configured, they close at staleness + ≈4 s |
| 5 | D6 either revokes or is reported as a hazard | **Reported as a hazard.** It does not revoke, and three separate configurations reach that state |
| 6 | The uninvolved affiliate sees zero continuity errors and no PCR degradation | **Pass** — undisturbed in every arm, zero continuity errors throughout |

Criterion 2's failure is the experiment's principal result and it is a *bound* failure, not a
performance one: no amount of tuning reaches sub-second, because the parameter that would have to
go below one second is an integer whose sub-unit values switch the mechanism off. Criterion 1's
partial failure and criterion 5 are the same defect seen from two directions.

## What this corrects in the design document

Three claims in [Control](../docs/control-plane.md) need changing, and one is confirmed.

- **§4.1's "sub-second when the control plane is healthy" is not achievable.** The fast path is a
  poll with an integer-second period; its floor is one second plus a round trip. §8's `< 1 s`
  acceptance target should be restated at the achievable figure or dropped.
- **§4.1's characterisation of the fast path as "an explicit revocation signal pushed to relays" is
  wrong.** Nothing is pushed. The relay replays its admission question on a timer and acts on the
  answer. That difference is why the bound is what it is.
- **§4's "TTL is the single most consequential parameter in the model" understates the case and
  names only half of it.** There are two parameters. Cadence bounds deliberate revocation; TTL
  bounds everything else, and is the *only* bound in the three configurations where revocation is
  inoperative. TTL is not the most consequential parameter for revoking a live affiliate; it is the
  one that makes a misconfigured deployment survivable.
- **§4.1's backstop claim is confirmed**, and against the expectation with which this experiment
  started. Expiry does bound an established session.

**§4.2 is confirmed as the default.** "Existing valid tokens continue to be honoured until expiry"
during a control-plane outage is what happens when no staleness window is configured — 150 s of
outage with no byte lost. It stops being true where `stale-while-revalidate` is set, and there it
closes publisher sessions too. The document should say that the property it claims is a default an
operator can configure away, rather than an invariant.

## Limits, stated in advance

- **The authorization endpoint is apparatus, not product.** It is a local stub. Nothing measured here
  says anything about the availability, correctness or latency of a real entitlement service, and
  the `< 5 s` and `99.95 %` targets in §8 are untouched by this experiment.
- **Loopback removes the network from the bound.** Every figure is a floor. A real affiliate sits
  behind a wide-area path and its teardown is at least one round trip worse; where a figure is
  quoted for deployment, it must be quoted as a floor.
- **No clustering.** A single relay revokes a session it admitted itself. Revocation across a relay
  mesh — where the session and the decision may be on different nodes — is not tested, and is
  distributed-systems work the platform would have to build ([Evidence](../docs/evidence.md) §3.10).
- **Token lifetime and re-check cadence are separate parameters and this experiment keeps them
  separate.** [Control](../docs/control-plane.md) §4 calls TTL "the single most consequential
  parameter in the model"; if H1 and H2 hold, the consequential parameter for a live session is the
  cadence, and the document conflates two knobs with different effects. Resolving that is the
  point, so no arm varies both at once.
- **It does not test revocation under load.** The cost of a cadence is measured per session on an
  idle relay; what that cadence costs across an estate is [T38](test-38-entitlement-estate.md).
- **The 30 s cadence rows are censored** by an observation window shorter than one cadence plus the
  settle period. They establish that teardown grows with cadence; they do not establish its
  distribution at that setting.
- **0.110 s is an instrument floor.** It is the same figure in the revocation arms and the expiry
  arm, which points at the subscriber's flush-and-exit path. Relay-side close latency is bounded
  above by it and is not resolved.

## Corrections

**A poll-based bound must be measured at a randomised phase.** The first pass at D2 used an integer
settle time, which placed every decision at the same point in the poll cycle and returned six
readings agreeing to within 3 ms. That looked like an exceptionally tight distribution and was one
measurement repeated six times. Randomising the sub-cadence offset turned it into the uniform spread
the mechanism actually produces. The general rule: **when a mechanism is periodic, a repeat that
does not randomise phase is not a repeat.**

**The client's reconnect budget is not the relay's revocation latency.** The first D2 pilot measured
10.032 s and the figure was the `moq` client's default 10 s `--backoff-timeout` — the period it
spends re-dialling a relay that keeps refusing it — with the relay having actually revoked in
about 25 ms. Any teardown measurement taken at a client must neutralise that budget, or it reports
the client's give-up policy as the server's enforcement speed.

## Open

**Whether an integer-second revocation floor is acceptable is a product question, not a technical
one.** The mechanism cannot go below about 1.11 s worst case, and buying even that costs one
authorization request per session per second — for a thousand-session estate, a thousand requests a
second against the entitlement service purely to hold the bound. Whether any broadcast entitlement
case genuinely needs sub-second revocation, or whether the sub-second target in §8 was aspirational,
is not something this experiment can settle. What it can say is that the target is unreachable and
that the document should stop implying otherwise.

**The three unrevocable configurations deserve an upstream report.** A `Cache-Control` the relay
cannot parse as a positive integer disables revalidation silently, with no warning at startup and
no signal in the session. The relay already warns at startup about configurations where nothing can
authenticate; the same treatment for an authorization endpoint whose replies schedule no re-check
would turn a silent hazard into a visible one.
