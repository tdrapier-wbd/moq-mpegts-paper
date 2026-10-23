# Test 54 — Dependency risk: what following upstream cost

**State: complete (desk study).** In 45 days the moq CLI shipped 22 releases and three breaking
minors. One migration reached every rig. After it, a breaking change reached a rig about once a
week, four of the five on `main` before any release. The standing units ran two builds in the
window, and the last upgrade cost a build and a scripted swap.

## Objective

[Comparison](../docs/comparison.md)'s operational-maturity row calls MoQ a pre-1.0 ecosystem. This
study measures what that meant for the campaign, from its own builds:
- each breaking change since moq 0.11 that reached the rigs, the standing units or the wire, with
  its cost to adopt;
- the protocol version each build spoke;
- the pinning policy in practice, and the last upgrade's cost under it.

## Method

Sources:
- upstream's release tags and changelogs for the CLI, `moq-relay` and `moq-net`;
- the source of each build the standing units ran;
- this repository's history and the campaign's run records.

The window runs from CLI 0.11.0 (2026-09-09) to 0.14.8 (2026-10-23). A change *reached* us if a rig,
a standing unit or the negotiated wire had to change, or broke. A count of changelog entries marked
breaking includes library API changes, which the CLI-driven rigs never see.

## Results

### Releases

| Release (CLI · relay · net) | Date | Entries marked breaking (CLI · relay · net) |
|---|---|---|
| 0.12.0 · 0.15.0 · 0.3.0 | 2026-09-23 | 22 · 15 · 17 |
| 0.13.0 · 0.16.0 | 2026-09-30 | 1 · 1 (auth parity) |
| 0.14.0 · 0.17.0 | 2026-10-03 | 1 · 1 (cluster gossip removed) |

The three breaking minors came in 11 days, then none for 20 days. The CLI's patch releases 0.14.3
to 0.14.8 are cut from backport branches: none is an ancestor of `main`, which still reports
0.14.2 · 0.17.2 · 0.3.10 while carrying changes no release has, and which lists one unreleased
breaking relay change (token roles hold path patterns directly, and unsupported roles are refused
before admission).

### What the standing units ran

| Build | Upstream base | Held | Wire offered first | Also offered |
|---|---|---|---|---|
| `84b34f54`, `main` | CLI 0.11.2 plus 571 commits, a day before 0.12.0's tag and with most of its breaking changes | 23 days | moq-lite-05 | lite-04 to lite-01, drafts 22 to 14; lite-06 only when pinned |
| `3c0daa21`, `main` | CLI 0.14.2 plus 935 commits | current | moq-lite-06 | lite-05 to lite-01, drafts 22 to 14; lite-07 only when pinned |

Both builds offer the other's default, so a fleet mixing them would negotiate lite-05. This is read
from the offered lists, not measured.

### Breaking changes that reached us

| Change | Upstream | What it reached | Cost |
|---|---|---|---|
| Dial and listen flags renamed (`--client-*` to `--connect-*`, `--server-*` to `--listen*`, `--latency-max` to `--max-age`), old names refused | 0.12.0 | every rig | one hardening pass over 75 rig scripts (+1,866 / −334 lines) and a swap script that migrates flags; until then about fifty rigs were refused by the new CLI |
| `--auth-public ""` inverted, from everything public to nothing | 0.12.0 | the standing units and every rig with a public path | silent: sessions up, zero bytes. Caught by an egress check, now in the swap and status scripts |
| `moq token` became `moq auth`; `--listen` requires `--auth-url` or `--auth-public` | 0.12.0 | the entitlement rigs | rewritten |
| quinn removed | 0.12.0 | the backend comparisons, which took the BBR generation from the QUIC backend | those cells cannot be re-run on a current build |
| Relay config: `[server]` became `[listen]`, `[iroh]` refused | `main` in the 0.12.0 cycle | rigs taking a relay TOML | each takes a stripped copy of its tree's config |
| An import ends on a backward timestamp | 0.14.0 | looped fixtures, a join rig, the live import | fixtures longer than any run ([T53](test-53-token-interop.md)'s 1,200 s); the live import ends on a source step ([Evidence](../docs/evidence.md) §3.13) |
| A redundant publisher's identity, `--hop`, became `--epoch`, which was later removed | `main` only | the same-epoch and redundancy rigs ([T6](test-6-relay-resilience.md), [T51](test-51-same-epoch-groups.md)) | per-build flags in each rig; T51's change has no merged build |
| The session's grant reported in AUTH_OK, prefixes only | `main` only | the entitlement estate on draft 17 and later | an exact grant refused on draft 18 ([T53](test-53-token-interop.md)); grants rendered as subtrees |
| The export's `--delay` redefined (runs that far behind the source), default 500 ms to 1 s | `main` only | the export rigs and the status script | the status script detects `--delay` |

**Did not reach us:** 0.13.0's auth parity, 0.14.0's gossip removal (the rigs join clusters by
`--cluster-connect`), and 0.12.0's library API changes, since the campaign drives the CLI only.

### The last upgrade, `84b34f54` to `3c0daa21`

It crossed 0.13.0, 0.14.0 and three weeks of `main`. The work was:
- one build on the build host (about 15 minutes), copied byte-identical to the other hosts and
  checked against its checksum sidecar;
- the units swapped by a script, with unit backups kept as the rollback set;
- one status-script change, and no flag migration.

The wire moved from lite-05 to lite-06 on both ends at once. The import's end on a backward
timestamp is the one behaviour change the live feed exhibits.

## Pinning policy

As practised, and the policy this study supports:

1. **Pin a `main` snapshot by hash, not a release.** The campaign's fixes land on `main`; the
   0.14.x patch releases are a backport branch without its TS fixes. An operator pinned to releases
   misses fixes. One pinned to `main` takes breaking changes before any release announces them.
2. **Hold one build on the standing units until a result needs a newer one.** The first was held 23
   days, and the previous build stays installed as the rollback set.
3. **Upgrade as one procedure.** Build once and copy with a checksum. Audit the rigs' flags. Swap
   with backups. Grade the upgrade on delivered bytes, never on a unit reporting active: two of the
   changes above fail silently.
4. **Pin the wire on any leg between implementations** ([T11](test-11-interop.md),
   [T52](test-52-cdn-relay-fanout.md), [T53](test-53-token-interop.md)), since the default moves
   with the build.

## Conclusions

- **The cost of pre-1.0 is in following upstream, not in running it.**
  - On `3c0daa21` the live import ran one invocation for 169 h
    ([T21](test-21-permanence-soak.md)).
  - The one large migration (0.12.0) reached every rig and was absorbed in one pass.
  - After that, breaking changes reached a rig about once a week, four of the five on `main` before
    any release.
- **Two of the nine changes alter behaviour without an error**: the inverted public path and the
  redefined export delay. The upgrade check therefore has to read the output.
- **For Comparison's row:** "pre-1.0 ecosystem" holds. Its weight is a standing upgrade procedure
  and a rig audit per build, not instability in service.

## Limits

- One operator's rigs, driven through the CLI. A library integrator would have met 0.12.0's 54 API
  entries.
- Cost is counted in rig changes and procedure, not person-hours.
- Forty-five days of a project that releases daily.
