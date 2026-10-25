# Test 53 — Token interoperability across relay implementations

**State: run on loopback, drafts 16 and 18; graded.** H2 and H4 hold; H1 and H3 do not. Both relays
enforce what they can express, and every refusal delivered zero payload bytes. The estate does not
carry across as a token, and moqx v0.3.6 can withdraw a grant only by a restart.

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

## What the documentation says

Read before running. Two cells are corrected from the results.

| | `moq-relay` | moqx |
|---|---|---|
| Format | JWT | CAT (CTA-5007) as a CWT, per CAT4MOQ |
| Keys | HMAC, RSA, ECDSA, EdDSA; scoped keys; the relay can hold verifying material only | HMAC-SHA256 with a key ID; the relay holds the shared secret. **Each key verifies a grant on any namespace of its service** (arm P3k) |
| Carriage | URL `?jwt=`; the draft's `AUTHORIZATION TOKEN` in SETUP with Token Type 0; one on `SUBSCRIBE` or `PUBLISH_NAMESPACE` grants that request only, and is refused unless its Token Type is 0 | the draft's `AUTHORIZATION_TOKEN` of one configured Token Type (default 0, 16 for CAT4MOQ's wrapper), in SETUP and per request, several per message up to a cap |
| Grant | path prefixes for publish and subscribe, segment-aware | CAT4MOQ actions with namespace and track matches: exact, prefix, suffix or contains |
| Withdrawal | an authorization endpoint re-checked on a cadence ([T37](test-37-entitlement-revocation.md)), or expiry | **none on a live session** (Part C): expiry is checked at admission, and the documented `SIGHUP` reload is not in v0.3.6 |
| Anonymous access | a public path | `anonymous_claim`, a floor of actions on matching namespaces |

`moq` on `main` puts its token in the URL only. #6177 adds `--connect-token`, which `moq` writes as
moq-transport's `AUTHORIZATION TOKEN` with Token Type 0 in CLIENT_SETUP. OpenMOQ's origin publisher
(`openmoq-publisher`, moqxr) reads a token from a file and lets the Token Type be overridden. So the
message carries either format; Part A found the clients do not.

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

Single host (the laptop), loopback, as in T36: enforcement measured without a network in the way.

| Component | Build |
|---|---|
| `moq-relay`, `moq`, `moq auth` | `main` at `f13283b30`; re-run at `66af72315`, every verdict the same but A1x's and the C7–C8 reason |
| `moq` for the SETUP arms | #6177's branch at `9425db108` |
| moqx, `moqx-issuer` | release v0.3.6, macOS arm64 binaries |
| `openmoq-publisher` | release v0.4.10 (`d6a19ab`), macOS binary, not built from source |
| Authorization | `moq auth serve` over a directory of public keys, re-checking every 5 s; the relay on `--auth-url` |
| Source | the synthetic fixture at 1,200 s, on `moq-relay` and moqx's `/h4`; an MP4 of it for `openmoq-publisher` |
| Transport | moq-transport draft 16 and draft 18 over raw QUIC, each arm on both |
| Measurement | payload bytes at the receiver (8 s of `export ts`, or one group by `moq fetch`); client, relay and auth-server logs; moqx's admin `/state` |

Keys: `moq-relay` verifies ES256, one key per broadcaster scoped to its root, plus one HS256 key, so
that one arm compares like with like against moqx's HMAC. moqx holds one HMAC secret per broadcaster,
each with its own key ID. Clocks: one host, so expiry is read against one clock. The rig is
[`t53-token-interop.sh`](scripts/t53-token-interop.sh).

## Procedure

**The estate** is T36's. Broadcaster `bcast` publishes `ch1`, `ch1-intl`, `ch2` and
`nobody`; broadcaster `rival` publishes its own `ch1`. Affiliate A licenses `ch1`, B licenses `ch1`
and `ch2`, C licenses `ch2`. `ch1-intl` is the shared-stem trap and `nobody` the control.

**One entitlement record per affiliate** (principal, broadcaster, channels, actions, expiry) is
written once, then rendered to a JWT by `moq auth sign` and to a CAT by `moqx-issuer`. A record
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
payload bytes the subscriber received. **Disclosure**: each affiliate subscribes to `bcast`'s
announcements and the channels announced are recorded.

### Part C — expiry and withdrawal

A 30 s token on a live session, on each relay: whether the session ends at expiry, and how long
after it. Then the estate's withdrawal path on each: on `moq-relay`, the authorization endpoint at
T37's cadence; on moqx, removing the affiliate's key or narrowing its grant, by whatever reload the
release offers, timed from the change to the session's end, or recorded as continuing to expiry.

### Deviations, each forced by what the builds accept

1. **JWT grants are subtrees** (`ch1/**`), not exact paths. On draft 17 and later the relay reports
   a session's grant in AUTH_OK, which carries prefixes only, and closes a session whose grant is
   not a union of subtrees. Arm A1x keeps the exact form, to measure that.
2. **No client subscribes to moqx with a CAT.** `moq` holds a token as text, and
   `openmoq-publisher` only publishes. moqx's Part B arms are therefore publisher arms, P1–P9:
   `openmoq-publisher` with a CAT on `/pg`, where an anonymous receiver counts the bytes. The form
   of A2 there is P2 (`ch1`'s CAT publishing `ch2`). H4 is measured through `anonymous_claim` on
   `/h4`, which grants by the matcher a CAT's claim uses (moqx's documentation; read, not
   measured). A8 (publish-only subscribing) and A10 (the parent grant narrowing) have no moqx form,
   and `moqx-issuer` emits exact namespace grants only.
3. **C5 has no payload to count.** The arm ran `openmoq-publisher` with `--publish-catalog`, which
   announces every track with PUBLISH, and `moq-relay` refuses PUBLISH ("PUBLISH is not
   supported"), by design at every draft ([#3076](https://github.com/moq-dev/moq/issues/3076)). Its admission is read from the auth server's grant and the relay's announcement.
4. **Discovery on moqx** needs its own grant. `moq` opens with a root-wide SUBSCRIBE_NAMESPACE.
   `/h4` grants namespace subscription everywhere, and `/h4n` scopes it to `[bcast, ch1]`; both are
   reported.
5. **moqx's withdrawal is a restart** without the key, since v0.3.6 has no reload (Part C). A first
   attempt sent `SIGHUP` to a moqx started under `nohup`, which ignores the signal: nothing
   reloaded, and a new session with the removed key's CAT was admitted.

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

## Results

### Part A

Payload bytes at the receiver, draft 16 then draft 18.

| Arm | Bytes | Told or logged |
|---|---|---|
| C1 | 1,475,048 · 1,362,436 | admitted; the HS256 form 1,481,252 · 1,375,032 |
| C2 | 1,256,216 · 1,387,440 | admitted |
| C4 on `/t16` | — | admitted: the namespace and three publications in moqx's state, both drafts |
| C4 as Type 0 on `/t0` | — | admitted, likewise: moqx takes Type 0 carriage of a binary CWT |
| C4 on `/pg` | 77,556 · 66,200 | admitted; the anonymous receiver's bytes |
| C3 | 0 · 0 | `MALFORMED_AUTH_TOKEN` (0x16), which `moq` prints as "unknown code=22" |
| C5 | announced, no payload | the auth server granted `publish a5/**` on both drafts and the relay announced `a5`; the publisher's PUBLISH refused |
| C6 | 0 · 0 | `MALFORMED_AUTH_TOKEN` |
| C7 | 0 · 0 | the auth server: `InvalidToken`; at `66af72315`, `MALFORMED_AUTH_TOKEN` |
| C8 | 0 · 0 | the auth server: `InvalidToken`; at `66af72315`, `MALFORMED_AUTH_TOKEN` |
| C9 | 0 · 0 | unauthorized: moqx reads no URL token, and the service requires one in SETUP |
| C10 | 0 · 0 | unauthorized: a Type 0 token on a Type 16 service counts as none |

### Part B

| Arm | `moq-relay`, bytes and reason | moqx `/pg` publisher form | Same verdict |
|---|---|---|---|
| A1 licensed | 1,306,224 · 1,262,420 | P1 admitted, 101,650 · 132,380 | yes |
| A2 unlicensed channel | 0 · 0, not served | P2: "does not permit action" | yes |
| A3 other broadcaster | 0, "token root `bcast` does not overlap the dialed path `rival`" | P3: does not permit action | yes |
| A3k the rival's key signing for `bcast` | 0, "token capabilities exceed the key scope" | **P3k admitted, 79,486 · 134,281** | **no** |
| A4 expired | 0, expired | P4: expired | yes |
| A5 absent | 0, anonymous access not granted | P5: does not permit action | yes |
| A6a truncated | 0, a base64 error | P6a: malformed | yes |
| A6b signature altered | 0, a base64 error (changing the last character breaks the encoding before the signature is read) | P6b: invalid signature | yes |
| A6c claims widened after signing | 0, `InvalidSignature` | P6c, the namespace bytes changed `ch1`→`ch2`, publishing either: invalid signature | yes |
| A7 subscribe-only publishing | 0 at the parent-grant receiver; on draft 18 the publisher's session closed unauthorized | P7: does not permit action | yes |
| A8 publish-only subscribing | 0 · 0 | no form | — |
| A9 `ch1` reaching `ch1-intl` | 0 · 0 | P9, an exact grant: does not permit action (the prefix form is H4) | yes |
| A10 parent grant narrowing | 1,256,216 · 1,481,252 | no form | — |
| A1x the exact grant `ch1` | 1,300,020 · **0** | — | — |

A1x on draft 18: the relay logged "auth grant cannot be encoded as one AUTH_OK; refusing the token",
ended the session's lease, and the client was told unauthorized. `moq auth sign` issues the grant
without comment. **On `main` at `66af72315` the exact grant is admitted on both drafts**: 1,981,332 ·
1,900,116 bytes, beside A1's 1,787,504 · 1,956,328.

**Disclosure.** On `moq-relay`, both drafts, A was announced `ch1`, B `ch1` and `ch2`, C `ch2`:
exactly what each licenses. On moqx, announcements follow the `subscribe_namespace` grant, not the
subscribe grant. On `/h4` a subscriber licensed to subscribe under `[bcast, ch1]` alone was announced
all four broadcasts (`ch1`, `ch1/sub`, `ch1-intl`, `ch2`). On `/h4n`, with discovery scoped to
`[bcast, ch1]`, `moq`'s root-wide request was refused and the subscriber received nothing, its
licensed channel included.

### H4: moqx's prefix matcher (`/h4`, subscribe under `[bcast, ch1]`)

| Broadcast | Draft 16 | Draft 18 |
|---|---|---|
| `bcast/ch1` | 1,262,420 | 1,268,624 |
| `bcast/ch1/sub`, a child | 1,281,220 | 1,281,220 |
| `bcast/ch1-intl` | 0, unauthorized | 0, unauthorized |
| `bcast/ch2` | 0, unauthorized | 0, unauthorized |

The match is on namespace elements, not bytes.

### Part C (draft 18)

| Relay | Event | Measured |
|---|---|---|
| `moq-relay` | a token expiring 30 s into a live subscription | ended at +30 s; the client was told "authorization token expired" |
| `moq-relay` | the HS256 key deleted from the auth server's directory, re-checked every 5 s | ended at the session's next re-check, which fell at the deletion: the auth server refused ("the token's key is unknown") and the client was closed unauthorized within 1 ms. The bound is one cadence (T37) |
| moqx | a 30 s CAT on a live publisher | still publishing at +80 s, 50 s past expiry: its namespace and publications in moqx's state at every 10 s read, whole groups fetched at +70 s and +80 s. Fetches at +39 s to +60 s returned 5,432 bytes and "failed to read group 1", unexplained |
| moqx | `SIGHUP` | the process exits. v0.3.6 handles SIGTERM and SIGINT only, though its configuration reference says `SIGHUP` reloads the file |
| moqx | the key removed and moqx restarted | a new session with that key's CAT refused, "invalid authorization token signature"; a configured key's CAT admitted, 134,281 bytes. The restart ended every session on the relay |

## Grading

1. **Not void.** C1 and C2 were admitted with payload bytes. C4 was admitted, its payload counted on
   `/pg`, since no receiver can present a CAT on `/t16`. A2 was refused on `moq-relay` beside A1,
   and on moqx in its publisher form P2 beside P1.
2. **H1 does not hold.** C3 was refused: the Token Type 0 field carries across, but `moq` holds a
   token as text and moqx parses the field's bytes as a CWT. C4's Type 0 form shows moqx admitting
   the same field when the bytes are binary. C5 crossed the other way as far as admission, with no
   payload, because the arm's publishing mode was PUBLISH, which `moq-relay` does not take. The
   message is portable; `moq` does not carry moqx's token end to end, and `openmoq-publisher`
   carrying `moq-relay`'s was not measured in the mode that delivers (see Corrections).
3. **H2 holds.** C6–C10 were refused with zero payload bytes. No cross-format admission.
4. **H3 does not hold.**
   - Of the eleven arms with a form on both relays, ten agree. P3k does not: a moqx key is valid
     across its service, so one broadcaster's key mints a grant to another's namespace, which
     `moq-relay`'s scoped key refuses.
   - Disclosure diverges. `moq-relay` announces exactly the licensed channels; moqx announces what
     a separate discovery grant covers, and with `moq` as the client the narrow rendering refuses
     discovery outright.
   - `moq-relay`'s own verdict on an exact grant depended on the draft (A1x); on `66af72315` it does not.
   - A8 and A10 had no moqx form.
   - Every refusal on either relay delivered zero payload bytes.
5. **H4 holds** on moqx's matcher, through `anonymous_claim`: `ch1` and its child admitted,
   `ch1-intl` and `ch2` refused with zero bytes. Not measured with a CAT.
6. **Part C.** `moq-relay` ends a session at expiry, and within one re-check cadence of a
   withdrawal. moqx v0.3.6 does neither: a live session outlives its CAT, and a key is withdrawn
   only by a restart that ends every session.

## Conclusions

- **Enforcement transfers; the token does not.** Both relays refused everything outside a grant
  before any payload byte, and both match prefixes on namespace elements. Format, client carriage,
  key scope, disclosure and withdrawal all differ. What an operator can carry between them is the
  entitlement record, rendered for each relay. Control §3's claim holds for enforcement and needs
  this qualification for portability.
- **The rendering must add what each relay lacks.**
  - On moqx, discovery is a grant of its own.
  - On moqx, isolation between broadcasters needs one service each, since keys are not scoped.
    This is read from the configuration, not measured.
  - On a `moq-relay` build without #6621, a grant must be a union of subtrees for draft 17 and later.
- **On moqx v0.3.6 a token's lifetime does not bound access.** Expiry does not end a live session,
  and withdrawal before expiry is a restart. On `moq-relay` both are bounded: expiry exactly,
  withdrawal by one cadence.
- **An exact grant survives a wire upgrade only on a `moq-relay` build with #6621.** Without it, a
  grant that works on draft 16 is refused on draft 18, and the signer accepts it without warning.

**Defects found, reported upstream** (state in the
[ledger](upstream-contributions.md#token-interoperability--6566-and-6567-fixed-moqx786-open-moqxr83-a-mode)):
- `moq-relay`: the draft-17 refusal of exact grants, undocumented, with the token in the URL too
  ([#6566](https://github.com/moq-dev/moq/issues/6566); fixed, re-measured above).
- `moq`: it prints `MALFORMED_AUTH_TOKEN` as an unknown code
  ([#6567](https://github.com/moq-dev/moq/issues/6567); at `66af72315` it prints "malformed auth token"), and it
  cannot carry a binary token.
- moqx v0.3.6: the documented `SIGHUP` reload ends the process
  ([on #786](https://github.com/openmoq/moqx/issues/786#issuecomment-6370364516)).
- `openmoq-publisher`: it exits when a relay refuses PUBLISH; without `--publish-catalog` it
  publishes to `moq-relay` on draft 18 and exits on draft 16, refusing the relay's request ID
  ([moqxr#83](https://github.com/openmoq/moqxr/issues/83)).

## Limits

- One release of each relay on one host. CAT4MOQ is a draft profile, and moqx's `strict_claims`
  stayed off, as its documentation advises for interop.
- The translation of an entitlement record into CAT claims is ours. A grant that is right on one
  relay and wrong on the other may be the translation.
- moqx's subscriber-side grants were not measured with a CAT, only through `anonymous_claim` and
  publisher arms. Whether CAT4MOQ expects expiry to end a live session was not checked.
- No CDN-hosted relay: its key is not ours to provision.
- Not measured: verification cost, DPoP proofs, other CAT profiles, and the MoQ Auth extension's
  in-band renewal.

## Corrections

**`openmoq-publisher` and `moq-relay`.** Believed: `openmoq-publisher` cannot publish to
`moq-relay`, since it exits when the relay refuses PUBLISH. True: the arm ran it with
`--publish-catalog`, the mode that publishes by PUBLISH. Without it, v0.4.10 publishes by
PUBLISH_NAMESPACE and serves the relay's SUBSCRIBE on draft 18; on draft 16 it exits, refusing the
relay's request ID 1 as out of sequence (loopback, `moq-relay` at `f13283b30`, no token). C5's
admission stands; its delivery end to end is unmeasured. Rule ([method notes](method-notes.md) §4):
before reporting that a client cannot reach a relay, run it in each of its publishing modes.
