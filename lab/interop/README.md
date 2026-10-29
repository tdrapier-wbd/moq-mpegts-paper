# Media-level interop test client (proof of concept)

A test client for [`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) that carries
an MPEG-TS fixture through a relay and validates what comes out the other side.

Prepared in support of
[englishm/moq-interop-runner#32](https://github.com/englishm/moq-interop-runner/issues/32), which
asks how media-level interop could be validated automatically. The issue names the blocker as
needing to capture "video frames as played back by a player". This is the argument that you do not:
**pick a fixture container that checks itself.**

## Why MPEG-TS makes a good fixture

Every PID in a transport stream carries a 4-bit continuity counter. Loss, duplication and reordering
are therefore detectable **from the received bytes alone** — no reference stream, no decoder, no
player, no frame capture. PSI/SI (PAT/PMT) adds cheap structural assertions on top, and TSDuck is a
mature, scriptable analyser that runs in CI without a media stack.

The whole oracle reduces to:

```bash
tsp -I file received.ts -P continuity -O drop    # silent == clean
```

This is demonstrated rather than asserted — see "Oracle sensitivity" below.

**Scope note.** This is interop testing, not conformance testing. It asks whether the subscriber got
what the publisher sent. It deliberately does *not* check TR 101 290, PCR jitter or CBR conformance:
those are properties of the publisher's pacing and of any downstream grooming, not of the relay under
test, and checking them here would make the harness a compliance arbiter — an explicit non-goal of
the project.

## Contents

| File | Purpose |
|---|---|
| `make-fixture.sh` | Generates the synthetic TS fixture. Run at container build time — nothing large or rights-encumbered is committed. |
| `validate-ts.sh` | The oracle. Emits `CHECK <name> <pass\|fail\|info> <detail>` per assertion. |
| `moq-ts-test-client` | Test client conforming to `docs/TEST-CLIENT-INTERFACE.md`: `RELAY_URL`/`TESTCASE`/`TLS_DISABLE_VERIFY`/`VERBOSE`, TAP v14 on stdout, exit 0/1/127. |

## Test cases

| Identifier | Procedure | Success criteria |
|---|---|---|
| `ts-carriage-integrity` | Subscriber joins, publisher sends the fixture paced to its own PCR, subscriber captures egress | Continuity clean, no sync loss, no TEI, PAT and PMT present, service count and elementary-stream inventory match the source |
| `ts-late-subscriber` | Publisher starts, subscriber joins 8 s in | Continuity clean from the join point, PSI present without waiting for a new session |

Byte-identity is reported but not required. A media-aware pipeline demuxes and remuxes, so the egress
legitimately differs from the source (chiefly null-packet stuffing, which is not carried). Byte-identity
becomes a hard requirement only for **transparent** carriage, where TS packets travel as opaque object
payloads; `--require-identical` switches that on.

## Usage

```bash
./make-fixture.sh fixture.ts

MOQ=/path/to/moq ./moq-ts-test-client -r https://localhost:4443 --tls-disable-verify
MOQ=/path/to/moq ./moq-ts-test-client -r https://cdn.moq.dev/anon -t ts-carriage-integrity
```

Environment: `MOQ` (path to the `moq` binary), `MOQ_TLS_FINGERPRINT` (for self-signed local relays),
`FIXTURE`, `WORKDIR`, `LATE_JOIN_SECONDS`, plus the four the interface contract defines.

## Oracle sensitivity

An oracle that never fails is worthless, so the failure modes are tested directly. Taking the clean
fixture and corrupting it three ways, all are caught with no reference stream:

| Mutation | Detected as |
|---|---|
| 500 packets removed mid-file | 3 discontinuities, located per PID and packet index |
| 20-packet run duplicated | 1 discontinuity at the splice |
| Two 10-packet blocks transposed | 3 discontinuities |

The generator applies the same oracle to its own output, so a fixture that would not pass the test is
never produced.

## Results

With `moq` 0.9.8 this client carried media through `moq-dev`'s relays only, because the publisher
then announced only when asked, which is fixed upstream. At `main`, `moq-dev`'s TS crosses seven of
nine third-party relays intact from the subscriber's join; imquic and red5 lose packets, and on three
relays a late subscriber never starts ([`lab/test-11-interop.md`](../test-11-interop.md)
§ *Results at `main`*). Every control-plane cell succeeds on those five, which is the argument for
the profile.

## Status

Superseded by the proposal to the runner,
[englishm/moq-interop-runner#159](https://github.com/englishm/moq-interop-runner/pull/159): the two
cases, the fixture generated at image build time and a TSDuck-based checker. This folder retires
once it merges.
