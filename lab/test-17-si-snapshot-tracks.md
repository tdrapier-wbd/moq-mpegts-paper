# T17 — standalone SI on snapshot tracks: EIT carriage and its join cost

## Objective

Every earlier experiment on the media-aware lane measured a stream whose service layer stopped at NIT
and SDT. EIT — the event schedule, and the largest SI table by a wide margin — was dropped at the
importer's gate, so [test 11](test-11-interop.md) could record that the DVB service layer survived
while the EPG did not. Upstream's answer is to take SI off the catalog entirely and give each
`(PID, table_id)` pair its own MoQ track with snapshot semantics
([`moq-dev/moq#2909`](https://github.com/moq-dev/moq/pull/2909)).

That design has one part which cannot be settled by reading the code. An EIT schedule sub-table is
**sparse**: it declares a `last_section_number` spanning its whole four-day range and transmits only
the segment-boundary sections that actually hold events. Completeness therefore cannot be decided by
counting sections, and the importer commits a generation when the transmission cycle is seen to wrap
instead. Whether that rule reconstructs the table faithfully is an empirical question.

Two things follow that are worth measuring rather than asserting:

1. **Does EIT round-trip, schedule included, section for section?**
2. **What does the service layer cost a joining receiver?** Export holds *all* output — tables and
   media alike — until every SI entry the catalog names has reduced its first snapshot, so SI moves
   off the join *bandwidth* path and onto the join *blocking* path. The size of an EPG makes that
   worth pricing: a full DVB planning horizon is eight days.

### Pass criteria (fixed before the runs)

1. **Fidelity.** For every EIT sub-table, the set of distinct sections on the exported TS equals the
   set on the source: no section missing, none added, sizes equal, and `last_section_number`
   preserved. A sub-table that arrives with a hole has failed, whether or not a decoder complains.
2. **The sparse path is actually exercised.** At least one schedule sub-table must transmit fewer
   sections than its `last_section_number` implies, or the run has only tested the contiguous path
   and says nothing about the interesting one.
3. **Carriage cost.** The EIT PID's rate on the egress is within ±10 % of the source's. Export
   re-emits at the ETSI TS 101 211 maximum interval rather than the source's observed cadence, so
   this is not a given.
4. **Join cost.** Time-to-first-byte for a cold exporter joining an already-running publisher is
   measured with and without the EPG, and the difference attributed to bytes or to round-trips.
5. **A control on the merge base.** Every figure is taken on the PR head *and* on its merge base
   through the same rig. Without it a rig fault reads as a finding, and on this run it very nearly
   did (see Corrections).

## Environment

| | |
|---|---|
| Under test | `moq-dev/moq` PR #2909 head, `5e29b0c87` |
| Control | `origin/dev` `7061bec07` — the PR's merge base, so a clean before/after |
| Build | one worktree, one shared cargo target, each arm's binaries copied out before switching |
| Test-suite control | the PR's own `moq-mux` suite passes on the build under test (565 tests) |
| Relay | local, loopback, GSO disabled |
| Source | CNN International EMEA HD, 9.95 Mbps CBR, H.264 + MP2 + AC-3 + teletext + 3× SCTE-35, NIT + SDT |
| EIT fixture | synthetic — 8 days, 24 events/day, ~120 B of descriptor per event |

The PR targets `dev`, not `main`, and the two have diverged; `dev` is the correct base and the only
one against which the PR merges cleanly.

No capture we hold carries EIT, so the EPG is generated. The pre-existing fixture
(`make-eit-fixture.sh full`) does carry schedule, and is already sparse, but it holds under a day of
EPG in one schedule table — 7 sections and 975 B in total. That is enough to ask whether carriage
works and far too small to price it, so this experiment adds a generator sized to the DVB planning
horizon:

```bash
# 8-day EPG for one service, anchored to the clip's own TDT epoch
python3 lab/scripts/make-eit-epg.py --out /tmp/epg8d.xml --days 8 --services 1

# inject p/f + schedule, reusing the clip's null stuffing so the mux rate is unchanged
tsp -I file ~/CNNiEMEA2.ts \
    -P sdt --service-id 1 --eit-pf 1 --eit-schedule 1 \
    -P eitinject --files /tmp/epg8d.xml --wait-first-batch --actual \
    -O file ~/CNNiEMEA2_eit_sched.ts
```

The result is the same 9,945,951 bps CBR stream as the source with clean continuity, carrying four
EIT sub-tables: p/f actual (0x4E) and schedule actual for days 0–3, 4–7 and 8 (0x50, 0x51, 0x52).

## Procedure

Both arms are built from one detached worktree with a shared cargo target, copying each arm's binaries
out before switching, so the second build is incremental and both arms exist at once:

```bash
git fetch origin pull/2909/head:refs/t2909/post
git worktree add --detach "$WT" refs/t2909/post
( cd "$WT" && CARGO_TARGET_DIR="$TARGET" cargo build --release --bin moq --bin moq-relay )
cp "$TARGET/release/moq"{,-relay} "$BIN/post/"
( cd "$WT" && git checkout --detach origin/dev && \
  CARGO_TARGET_DIR="$TARGET" cargo build --release --bin moq --bin moq-relay )
cp "$TARGET/release/moq"{,-relay} "$BIN/pre/"
```

Both rigs then start the relay, publisher and subscriber inside a single invocation, and both detect
which dial-side flag surface the binary speaks (see Corrections). `TGT` selects the arm:

```bash
# fidelity: round-trip the fixture and census the SI PIDs on both sides
TGT="$BIN/post" BUILD_DESC="PR#2909 5e29b0c87" \
  lab/scripts/eit-roundtrip.sh ~/CNNiEMEA2_eit_sched.ts 120

# join cost: publisher already running and SI already advertised, then five cold joins
TGT="$BIN/post" lab/scripts/si-join-cost.sh ~/CNNiEMEA2_eit_sched.ts epg8d 5 70
TGT="$BIN/post" lab/scripts/si-join-cost.sh ~/CNNiEMEA2.ts          noeit 5 70
```

Each figure is then re-taken with `TGT="$BIN/pre"` for the control.

The 70 s settle before the first join is deliberate: EIT schedule commits on transmission-cycle wrap
and the ETSI "later" cycle is 30 s, so a shorter settle measures acquisition rather than join.

## Results

### 1. EIT round-trips, schedule included

Distinct sections present, source against exported TS. The windows are not equal — 227 s of source
against the whole 119 s capture — deliberately, so that a section the source transmits only late still
counts against the egress rather than being excluded from both:

| sub-table | table_id | sections src / egress | `last_section_number` src / egress | missing | extra | sizes |
|---|---|---|---|---|---|---|
| EIT p/f actual | 0x4E | 2 / 2 | 1 / 1 | none | none | match |
| EIT schedule actual, days 0–3 | 0x50 | 32 / 32 | 248 / 248 | none | none | match |
| EIT schedule actual, days 4–7 | 0x51 | 32 / 32 | 248 / 248 | none | none | match |
| EIT schedule actual, day 8 | 0x52 | 3 / 3 | 16 / 16 | none | none | match |

Pass criterion 1 met. The control on `origin/dev` exports **zero** EIT packets from the same fixture,
which is the pre-PR behaviour: the importer drops every PID outside NIT and SDT.

Pass criterion 2 is met by construction and by measurement: sub-table 0x50 declares
`last_section_number = 248` and transmits 32 sections. Contiguity — all of `0..=last` present —
cannot be reached for EIT schedule, so the cycle-wrap rule is not a fallback there but the sole
commit path, and it reconstructs the table exactly.

An independent check that this is inherent to sparse tables rather than an artefact of the fixture:
TSDuck's own `tables` plugin will not print these sub-tables at all, and only `--all-sections`
reveals them, because it too completes a sub-table by counting sections.

### 2. Carriage is bitrate-neutral

Measured over a 118.7 s egress window, duration taken from the PCR span — the raw export is not CBR,
so `analyze`'s per-PID bitrate is meaningless on it:

| | EIT PID 0x0012 |
|---|---|
| source | 28,870 bps |
| egress | 28,445 bps |
| ratio | 0.985× |

Pass criterion 3 met, comfortably. Re-emitting at the spec maximum rather than at the source's
observed cadence costs nothing here.

### 3. The join cost is small, and scales with bytes rather than track count

Cold exporter joining a publisher already running with its SI already advertised, five joins each:

| | SI tracks | TTFB median | min / max |
|---|---|---|---|
| no EIT (NIT + SDT only) | 2 | 14 ms | 4 / 14 |
| 8-day EPG | 6 | 15 ms | 0 / 16 |

Four extra tracks and ~30 kB cost one millisecond. The subscriptions are issued together, so the
gate's cost is a bandwidth term rather than a round-trip per track — which is the property that lets
the design scale.

The tracks the exporter subscribed to, which is also the shape of the catalog's `mpegts.si` map:
`0x0010-0x40.si`, `0x0011-0x42.si`, `0x0012-0x4e.si`, `0x0012-0x50.si`, `0x0012-0x51.si`,
`0x0012-0x52.si`.

### 4. The price of an 8-day EPG

Snapshot payload, summed over the distinct sections of each sub-table:

| sub-table | sections | `last_section_number` | snapshot bytes |
|---|---|---|---|
| EIT p/f actual | 2 | 1 | 237 |
| EIT schedule, days 0–3 | 32 | 248 | 13,653 |
| EIT schedule, days 4–7 | 32 | 248 | 14,784 |
| EIT schedule, day 8 | 3 | 16 | 1,238 |
| **total, one service** | **69** | | **29,912** |

For scale, the one-day `full` fixture totals 975 B across two sub-tables — a thirtieth of this, which
is why it could not answer the cost question.

Scaled by service count, which is what a multi-programme primary-distribution multiplex does to it:

| | snapshot bytes | snapshot tracks |
|---|---|---|
| 1 service | 29,912 | 4 |
| 10 services | 299,120 | 40 |
| 40 services | 1,196,480 (1.14 MiB) | 160 |

A 40-service MPTS is the relevant shape, and there an exporter resolves 160 tracks and pulls ~1.1 MiB
before its first TS packet — on the order of a couple of hundred milliseconds at 50 Mbps. Bounded and
acceptable, but bounded by the EPG's size, and nothing in the gate distinguishes an EPG from a table
the stream cannot start without.

## Observations

**The export gate has no deadline, and an auxiliary table can now hold a programme dark.** Export
opens its output when every SI entry either has a snapshot or has reached a terminal state. Terminal
failure is handled deliberately and well — a failed or ended track logs and keeps its last snapshot
rather than killing the mux. What is not handled is a track that neither succeeds nor fails: one that
resolves and never delivers a complete group, or never resolves at all, leaves the gate shut, and the
exporter emits **no TS at all — media included — indefinitely**, with nothing logged past the
subscribe attempt. The common path is safe, because a snapshot group is finished synchronously and an
entry is advertised only after its first cut. The exposure is a stale announce, where the catalog
names an SI track that will not resolve. Before this design SI lived in the catalog and could not
independently gate media; now it can.

**The wrap rule cannot distinguish a skipped section number from a lost one.** In a sparse table both
are holes, and `last_section_number` does not betray the difference. A section lost or CRC-failed
before the cycle wraps yields a committed generation quietly missing a segment. Nothing in the
algorithm can do better — that is what sparseness costs — but it bounds how strong a fidelity
guarantee this carriage can claim.

**TDT/TOT is carried by neither side, by design on one and by omission on the other.** The importer
excludes it on sound grounds: a clock is not state, every section is new content, and an upstream
multiplexer's time carries an unknown delay. But nothing regenerates it downstream either, so the
egress has no time table at all (measured: 0 packets on 0x0014). A DVB receiver downstream of
`export ts` therefore has no TDT/TOT, which is a gap for a broadcast hand-off even though the
reasoning for not forwarding it is right — and one that grows more visible as the EPG survives, since
a schedule needs a clock to be placed against. Reported upstream as
[#2914](https://github.com/moq-dev/moq/issues/2914).

## Conclusions

1. **EIT carriage works, and the hard case works.** The sparse EIT schedule — the part that cannot be
   validated by section counting, and the part reading the code left open — round-trips with every
   section intact across four sub-tables, against zero on the merge base.
2. **The service layer is no longer the reason an MPEG-TS hand-off is lossy.** With NIT, SDT and now
   EIT surviving, the remaining named gap in the DVB service layer over this lane is TDT/TOT, and the
   right fix there is local regeneration rather than carriage.
3. **Neither cost that theory predicted is material.** Carriage is bitrate-neutral (0.985×) and the
   join gate costs 1 ms for four extra tracks. Both concerns were priced rather than argued, and both
   came out smaller than they went in.
4. **The residual risk is liveness, not latency.** An SI track that neither succeeds nor fails holds
   all output. This is worth a bounded gate upstream, and it is the one finding from this experiment
   that asks for a code change.

## Corrections

- **A sparse sub-table is invisible to `tsp -P tables`, and reading that as absence produced a false
  finding.** The census that opened this experiment used `tables` without `--all-sections` and
  reported the `full` fixture as carrying EIT p/f only, from which followed a conclusion that the
  fixture had never exercised the schedule path and that `eitinject` would not generate schedule from
  a `type="pf"` element. Both were wrong, and wrong for the same reason the experiment exists: a
  sub-table declaring `last_section_number = 48` while transmitting 7 sections never completes, so the
  section demux never emits it and the plugin prints nothing. With `--all-sections` the fixture shows
  420 schedule sections on table 0x50. The method rule: **an instrument that reports completed tables
  cannot be used to establish absence of a table that is designed never to complete.** Census SI with
  `--all-sections`. The genuine gap in the old fixture was size, not shape — under a day of EPG in one
  schedule table, which prices nothing.
- **A rig fault read as a total regression until the merge-base control ran.** The first round-trip on
  the PR head captured zero bytes, which matched a predicted failure of the export gate closely
  enough to be believed. It was not that: the dial-side flags were renamed on `dev` from `--client-*`
  to `--connect-*` with per-direction QUIC tuning merged into one `--quic-*` section, and the
  deprecated aliases warn and then do not take effect. Isolated one flag at a time, **both**
  `--client-connect` and `--client-quic-gso` fail independently — the first leaves the client with
  nothing to dial, the second leaves GSO on so the session stalls on macOS loopback — and in each case
  the warning fires naming the correct replacement, so the alias is parsed and only the propagation is
  missing. The base behaved identically, which is what exposed the rig rather than the PR. The method
  rule is pass criterion 5, and it earned its place: **run the control before believing a striking
  result, not after.** Both rigs now detect the flag surface instead of assuming one. Reported upstream
  as [#2913](https://github.com/moq-dev/moq/issues/2913).
