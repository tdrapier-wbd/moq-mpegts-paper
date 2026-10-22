# Test 53 — Token interoperability across relay implementations

**State: specified, not run.** The arms that carry a token in SETUP from `moq` need upstream's
in-band token work ([#6177](https://github.com/moq-dev/moq/pull/6177), open) or its branch.

## Objective

[Control](../docs/control-plane.md) §3 holds that the transport contributes the enforcement point,
not the token format, and that the entitlement service is transport-independent. Every enforcement
result behind it ([T36](test-36-entitlement-enforcement.md)–[T38](test-38-entitlement-estate.md)) is
one implementation, `moq-relay`, and [Evidence](../docs/evidence.md) §3.10 lists a second
implementation as unmeasured. This test puts one entitlement estate in front of two relay
implementations, `moq-relay` and moqx (OpenMOQ's relay, [T11](test-11-interop.md)), and asks which of
three layers carries across:

1. **Carriage.** Can one client present a credential to both relays the same way?
2. **Format.** Does a token minted for one relay verify on the other?
3. **Grant semantics.** Rendered from one entitlement record into each relay's format, does the
   estate get the same verdict on both, refused before any payload byte?

It also records what each implementation offers the estate beyond admission: who holds the signing
key, how a grant is withdrawn, and what an affiliate is told.

## What is known, read from the documentation and not measured

| | `moq-relay` | moqx |
|---|---|---|
| Format | JWT | CAT (CTA-5007) as a CWT, per CAT4MOQ |
| Keys | HMAC, RSA, ECDSA, EdDSA; scoped keys; the relay can hold verifying material only | HMAC-SHA256 with a key ID; the relay holds the shared secret |
| Carriage | URL `?jwt=`; the draft's `AUTHORIZATION TOKEN` in SETUP with Token Type 0; one on `SUBSCRIBE` or `PUBLISH_NAMESPACE` grants that request only, and is refused unless its Token Type is 0 | the draft's `AUTHORIZATION_TOKEN` of one configured Token Type (default 0, 16 for CAT4MOQ's wrapper), in SETUP and per request, several per message up to a cap |
| Grant | path prefixes for publish and subscribe, segment-aware | CAT4MOQ actions with namespace and track matches: exact, prefix, suffix or contains |
| Withdrawal | an authorization endpoint re-checked on a cadence ([T37](test-37-entitlement-revocation.md)), or expiry | expiry; the relay calls no grant service |
| Anonymous access | a public path | `anonymous_claim`, a floor of actions on matching namespaces |

`moq` on `main` puts its token in the URL only. #6177 adds `--connect-token`, which `moq` writes as
moq-transport's `AUTHORIZATION TOKEN` with Token Type 0 in CLIENT_SETUP. OpenMOQ's origin publisher
(`openmoq-publisher`, moqxr) reads a token from a file and lets the Token Type be overridden. So
the carriage is common, and the formats differ.

## Hypotheses, fixed before running

- **H1, carriage is portable.** A CAT in CLIENT_SETUP as Token Type 0, from `moq`, is admitted by
  moqx configured `token_type: 0`. So is a JWT in the same carriage from `openmoq-publisher`, by
  `moq-relay`.
- **H2, format is not.** A JWT is refused by moqx and a CAT by `moq-relay`, in every carriage, with
  zero payload bytes.
- **H3, the semantics agree where both can express the grant.** T36's estate gets the same verdict
  on both relays, arm for arm.
- **H4, the arm most likely to surprise.** A CAT namespace `prefix` grant on channel `ch1` does not
  reach `ch1-intl`. T36 found `moq-relay`'s matching segment-aware; a match on bytes would hand an
  affiliate a sibling channel while every grant read correctly.

## Environment

Single host, loopback, as in T36: enforcement measured without a network in the way.

| Component | Build |
|---|---|
| `moq-relay`, `moq`, `moq token` | `main`, the hash recorded with the results; the SETUP arms from #6177 until it merges |
| moqx, `moqx-issuer` | the latest release's macOS arm64 binaries, the version recorded |
| `openmoq-publisher` | moqxr built from source, for the arms that need a second client; if it does not build, those arms are recorded as not run |
| Source | the synthetic fixture, published to each relay by an admitted publisher |
| Transport | moq-transport draft 16 and draft 18 over raw QUIC (the pairing T11 established), each arm on both |
| Measurement | payload bytes at the receiver; client and relay logs; T36's wiretap for wire volume |

Keys: `moq-relay` verifies ES256 from a public key file, as in T36, plus one HS256 key, so that one
arm compares like with like against moqx's HMAC. moqx holds one HMAC key per broadcaster, each with
its own key ID. Clocks: one host, so expiry is read against one clock.

## Procedure

**The estate** is T36's, renamed. Broadcaster `bcast-a` publishes `ch1`, `ch1-intl`, `ch2` and
`none`; broadcaster `bcast-b` publishes its own `ch1`. Affiliate A licenses `ch1`, B licenses `ch1`
and `ch2`, C licenses `ch2`. `ch1-intl` is the shared-stem trap and `none` the control.

**One entitlement record per affiliate** (principal, broadcaster, channels, actions, expiry) is
written once, then rendered to a JWT by `moq token sign` and to a CAT by `moqx-issuer`. A record
that one format cannot express is recorded as inexpressible for that relay, not failed.

### Part A — carriage against format

Each arm opens one session and subscribes to one licensed channel, except the publisher arms,
which publish to one.

| Arm | Client | Carriage | Token | Relay | Expected |
|---|---|---|---|---|---|
| C1 | `moq` | URL `?jwt=` | JWT | `moq-relay` | admitted (T36's baseline) |
| C2 | `moq` (#6177) | SETUP, Type 0 | JWT | `moq-relay` | admitted |
| C3 | `moq` (#6177) | SETUP, Type 0 | CAT | moqx, `token_type: 0` | admitted (H1) |
| C4 | `openmoq-publisher` | SETUP, Type 16 | CAT | moqx, `token_type: 16` | admitted (moqx's own control) |
| C5 | `openmoq-publisher` | SETUP, Type 0 | JWT | `moq-relay` | admitted (H1) |
| C6 | `moq` (#6177) | SETUP, Type 0 | JWT | moqx, `token_type: 0` | refused (H2) |
| C7 | `moq` (#6177) | SETUP, Type 0 | CAT | `moq-relay` | refused (H2) |
| C8 | `moq` | URL `?jwt=` | CAT | `moq-relay` | refused (H2) |
| C9 | `moq` | URL `?jwt=` | CAT | moqx | refused; records whether moqx reads the URL at all |
| C10 | `moq` (#6177) | SETUP, Type 0 | CAT | moqx, `token_type: 16` | refused: the Token Type a default leaves mismatched |

### Part B — the estate on both relays

T36's arms A1–A10 on both relays, through `moq` (#6177) in SETUP as Token Type 0, each relay with
its own rendering of the same record: licensed, unlicensed channel, other broadcaster, expired,
absent, truncated, signature altered, claims widened after signing, subscribe-only publishing,
publish-only subscribing, `ch1` reaching `ch1-intl` (H4), and the parent grant narrowing to a child.
Each arm is graded as T36 grades it: what the client was told, what the relay logged, and the
payload bytes the subscriber received. **Disclosure**: each affiliate subscribes to `bcast-a`'s
announcements and the channels announced are recorded.

### Part C — expiry and withdrawal

A 30 s token on a live session, on each relay: whether the session ends at expiry, and how long
after it. Then the estate's withdrawal path on each: on `moq-relay`, the authorization endpoint at
T37's cadence; on moqx, removing the affiliate's key or narrowing its grant, by whatever reload the
release offers, timed from the change to the session's end, or recorded as continuing to expiry.

## Pass criteria, fixed before running

1. **The test is void** unless C1, C2 and C3 or C4 are admitted with payload bytes, and A2 is
   refused on each relay. A refusal on a relay counts only beside an admission on that relay in
   the same carriage.
2. **H1 holds** if C3, and C5 where it runs, are admitted with payload bytes.
3. **H2 holds** if C6–C10 are refused with zero payload bytes. A cross-format admission is a defect,
   reported to the implementation that made it.
4. **H3 holds** if every Part B arm gets the same verdict on both relays, every refusal on either
   delivers zero payload bytes, and each affiliate is announced exactly its licensed channels on
   both. A divergence is reported with the grant each relay derived.
5. **H4 holds** if `ch1`'s grant reaches neither `ch1-intl` nor any of its tracks on moqx.
6. **Part C is recorded, not graded**: the time from expiry to session end on each relay, and
   whether moqx can withdraw a grant before expiry.

## Limits, stated in advance

- One release of each relay on one host. CAT4MOQ is a draft profile, and moqx's `strict_claims`
  stays off, as its documentation advises for interop.
- The translation of an entitlement record into CAT claims is ours. A grant that is right on one
  relay and wrong on the other may be the translation.
- No CDN-hosted relay: its key is not ours to provision.
- Not measured: verification cost, DPoP proofs, other CAT profiles, and the MoQ Auth extension's
  in-band renewal.
