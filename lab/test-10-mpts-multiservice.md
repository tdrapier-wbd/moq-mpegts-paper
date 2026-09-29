# Test 10 — MPTS / multiple concurrent services

**State: arms A, B and D run on build `ffa5b81b`, and the MoQ arms re-run on upstream `main`
`2b689c24` (P1, file domain, all roles co-resident on one host), with the change between the two
builds bisected to two commits; arms C and E not run.** A real three-programme multiplex — three PMTs, three PCR PIDs, one PAT
and one SDT listing all three — was carried through both data planes and graded per programme.

- **The MoQ lane refuses a multiplex whose programmes run on independent clocks, and not cleanly.**
  `moq import ts` accepts the stream, announces every programme's tracks as one flat broadcast, and
  about 2 s in the publisher exits with `frame timestamp is below the live edge`. Nothing gradable
  reaches the subscriber. The importer stamps its SI and section tracks from one clock that every
  programme's video advances; programmes 25,628 s apart drive it backwards.
- **On a common clock the same lane delivers, but flattens the multiplex into one programme.** With
  the three clocks re-timed to start within 0.82 s of each other the publisher completes, and the
  egress carries a PAT listing programme 1 only and one PMT listing all ten elementary streams under
  programme 1's PCR PID. Programmes 2 and 3 lose their PMTs and their PCRs, while the SDT and EIT
  carried through still advertise them.
- **The segmented lane carries the multiplex.** All three programmes arrive with PAT, PMTs, SDT and
  NIT bit-identical, EIT present/following identical per service, 0 continuity events and PCR
  intervals identical to source: pass criterion 2 as fixed. The 13-tick `pcrverify` gate fails on
  nearly every PCR, for the reason [T3](test-3-opaque-transparency.md) located on one programme: the
  packager adds a PAT/PMT pair at each segment head. In a multiplex that pair carries programme 1's
  PMT only.

- **On upstream `main` (`2b689c24`) the refusal is gone and the loss is silent.** Independent clocks
  complete with exit 0 while programmes 1 and 3 lose 96–98 % of their video packets; on a common
  clock SCTE-35 and part of programme 1's audio are lost. The flattening is unchanged. Programme 1
  alone is clean on `main`. Bisected, the two changes are two upstream commits: #3997 removed the
  refusal, and #4122 introduced the common-clock loss. That loss appears even when the programmes'
  clocks are within 40 ms of each other (median). Its cause is measured: the section clock is
  advanced through one lane shared by every programme's video, that lane keeps stepping back
  across programmes, and each step re-anchors the whole source forward. Giving the section clock
  one lane per video PID removes the loss.

The opaque lane that criterion 1 names is not in `ffa5b81b`: `moq import ts` takes no options, so the
media-aware lane is the only MoQ lane on the build under test, and arm A ran on it.

## Objective

Carry a multi-programme transport stream — or several single-programme broadcasts running
concurrently — through both data planes and verify that each service's PSI/SI, PCR cadence and
continuity counters survive at egress. On the MoQ lane, add relay fan-out under N services (distinct
broadcasts or distinct tracks within one MPTS) so the scaling question is channel count as well as
audience count.

Gate 1 (carriage fidelity) at multi-service scale is the acceptance gate. The campaign's residual
carriage advantage on mux content — now carried entirely by this cell rather than by
single-programme results — is the comparative stake; see [T14](test-14-data-plane-comparison.md)
measurement 3 and [B-5](planned-experiments.md#blocked-on-apparatus) in the planning record.

## What was already known, and what it left open

**Single-programme carriage is established on both lanes.** [T3](test-3-opaque-transparency.md)
confirmed bit-transparency and full service-layer carriage on the opaque lane across three clips.
[T14](test-14-data-plane-comparison.md) showed single-programme carriage in TS segments is verbatim
on the segmented lane. Neither result generalises to a multiplex without measurement.

**Multi-service SI cost is extrapolated, not measured.** [T17](test-17-si-snapshot-tracks.md) priced
snapshot-track carriage at ~29,912 B and four tracks per service, and scaled that to 40 services
(~1.1 MiB across 160 tracks) by multiplication from one service — not by running an MPTS. Whether an
exporter resolves 160 tracks from a real multiplex, whether join blocking scales linearly, and whether
sparse EIT reconstruction holds per service are all open. This run does not close them: its three
services are too few to fit a scaling curve, and on the MoQ lane the multiplex did not survive intact
long enough to price.

**Dual-path byte identity fails on multi-track content for a located upstream reason.**
[T12](test-12-dual-path-handoff.md) reached 75.56 % agreement on a seven-stream mux over independent
chains — the residue being the same packets in a different order, not damage — while single-track
content was byte-identical with zero residue. Multi-service at the egress merge is therefore genuinely
unmeasured even where single-service 1+1 is strong.

**Fan-out scaling is measured for one broadcast, not for N services.** [T26](test-26-cross-host-fanout.md)
established a linear relay cost curve for one publisher and one broadcast. The channel-count half —
does relay cost follow broadcasts rather than subscribers — is answered on the current build by
[T43](test-43-fanout-current-build.md) S2, which is why arm C was not run here.

**MPTS through a real CDN is blocked on apparatus.** HLS normatively requires single-programme TS
segments; publishing MPTS segments through a commercial CDN and grading what arrives is specified under
[T14](test-14-data-plane-comparison.md) measurement 3 and [B-5](planned-experiments.md#blocked-on-apparatus).
A byte cache does not parse the payload, so that cell is only interesting where the edge is
media-aware — asking it of a plain cache re-measures nginx.

## Environment

| | |
|---|---|
| Fixture | `mpts3.ts`, built by [`make-real-mpts.sh`](scripts/make-real-mpts.sh) from three single-programme clips in the lab inventory: 60 s, 19,891,902 b/s CBR, three programmes on independent clocks (analysis below). A common-clock variant, `mpts3-cc.ts`, re-times programmes 2 and 3 onto programme 1's clock. Each run is identified by its fixture's md5, because two builds of the recipe are not byte-identical. |
| MoQ lane | `moq 0.12.1` / `moq-relay 0.15.1`, build `ffa5b81b`, noq backend: `moq import ts` → `moq-relay` → `moq export ts`, the media-aware lane with SI snapshot tracks, relay on loopback with GSO off and `--auth-public` granted via [`moq-cli-flags.sh`](scripts/moq-cli-flags.sh). There is no opaque lane on this build. |
| Segmented lane | TSDuck 3.44: `tsp -O hls` packager (2 s segments, live window of 6) → `python3 -m http.server` origin → `tsp -I hls` receiver. The rig of [T3](test-3-opaque-transparency.md) / [T14](test-14-data-plane-comparison.md), except that the receiver starts at the first listed segment rather than the live edge (no `--live`), so the capture covers the whole source. |
| Grading | [`t10-grade.py`](scripts/t10-grade.py), per programme at P1: PAT entry, PMT sections (bit identity, then parsed structure), SDT entry, EIT p/f section set per service, continuity from `tsp -P continuity` data, PCR count and intervals per PCR PID, `pcrverify --pid <p> --absolute --jitter-max 13`, and every source elementary stream traced to the egress programme that lists it. |
| Topology | One Linux host; publisher, relay (or origin) and subscriber co-resident on loopback. Not a sizing topology, and nothing here is quoted as one. |
| Measurement point | P1 (file egress) only. |

## Procedure

**Fixture.** Programme 1 is the base mux — a real contribution feed with its own PIDs, TSID/ONID, NIT,
TDT, teletext and three SCTE-35 PIDs — padded by one null packet per packet so its PCRs stay exact at
the doubled rate. Programmes 2 and 3 are renumbered to services 2 and 3, moved to PIDs 0x02xx and
0x03xx, and merged into the padding with `tsp -P merge`, which restamps their PCRs; their PAT and SDT
entries are added to programme 1's tables in place, and EIT present/following for all three is
injected from the remaining padding. The script's header records the five construction pitfalls
that each broke an earlier build.

```
make-real-mpts.sh mpts3.ts 60
P2_OFFSET=25630.87 P3_OFFSET=25628.83 make-real-mpts.sh mpts3-cc.ts 60
```

**Grader self-test.** Before any lane was graded, `t10-grade.py` was run on four deliberately damaged
copies of the fixture and on the fixture against itself. It reported each fault as the fault: a
continuity break (programme 3: 0 → 1 event), a removed programme (programme 3 `ABSENT`), a programme
listed under another's PMT (programme 2 `FLATTENED`), and PCR damage (2 `pcrverify` failures on PID
785). The fixture against itself graded all three `CARRIED` with no fault.

**Arms A and B — MPTS through the MoQ lane.** [`t10-moq.sh`](scripts/t10-moq.sh) starts the relay,
starts `moq export ts` to file, then paces the fixture into `moq import ts` once with `tsp -P regulate
--pcr-synchronous` and lets the exporter drain for 15 s. Arm B is the same run graded for SI per
service, since the lane's SI snapshot tracks are always on. Two runs on `mpts3.ts`.

```
t10-moq.sh mpts3.ts runs/a-mpts a-mpts
t10-grade.py mpts3.ts runs/a-mpts/egress.ts --label a-mpts
```

**Discriminator A′ — the same lane on a common clock.** Two runs of `t10-moq.sh` on `mpts3-cc.ts`,
graded against `mpts3-cc.ts`. It changes one property of the input: the three programmes' clocks.
Programmes 2 and 3 are also stream-copy remuxed to apply the offset; their media is unchanged.

**Single-programme controls.** Each programme extracted from `mpts3.ts` with the rest replaced by
stuffing and its own EIT kept, then carried and graded exactly as arm A, so that a per-programme
difference can be charged to the multiplex rather than to the lane:

```
tsp -I file mpts3.ts -P zap <service> --stuffing --eit -O file spts<service>.ts
```

**Arm D — MPTS through the segmented lane.** [`t10-hls.sh`](scripts/t10-hls.sh) runs packager, origin
and receiver in one invocation.

```
t10-hls.sh mpts3.ts runs/d-mpts
t10-grade.py mpts3.ts runs/d-mpts/egress.ts --label d-mpts
```

**Bisect between the builds.** [`t10-bisect-step.sh`](scripts/t10-bisect-step.sh) is one `git
bisect run` step: it builds HEAD's `moq` and `moq-relay`, runs `t10-moq.sh` on both fixtures,
grades them, and judges one property against thresholds fixed from the endpoints' grades before the
bisect. For the common clock, old means SCTE-35 over PIDs 141–143 of at least 150 packets and
programme 1's audio of at least 8,000; new means SCTE-35 of at most 30; anything between is
skipped. With `JUDGE=ic` it judges the independent clock instead, where old is a publisher exit
other than 0. `BIN_ONLY=<dir>` grades a prebuilt pair, which is how the endpoints and the #4001
merge were checked first. Both bisects are first-parent, in a worktree of the upstream tree:

```
git bisect start --first-parent --term-old=old --term-new=new 2b689c24 ffa5b81b
git bisect run bash t10-bisect-step.sh <root>                # common clock: 8 steps
git bisect start --first-parent --term-old=old --term-new=new 66440a6c ffa5b81b
JUDGE=ic git bisect run bash t10-bisect-step.sh <root>       # independent clocks: 6 steps
```

**Section-clock dose.** [`t10-section-clock.py`](scripts/t10-section-clock.py) reads a fixture
directly and models the importer's section clock. It stamps each section start on PIDs 0x10, 0x11,
0x12, 0x14 and 141–143 with the latest video PTS from any programme, then reports each lane's backwards steps
over 500 ms and each programme's video offset from programme 1. Eight further common-clock fixtures
were built with one command, `P2_OFFSET=25629.956 P3_OFFSET=25628.636 make-real-mpts.sh <out.ts> 60`.
They differ only through the up-to-0.8 s variation in when `tsp merge` starts inserting, and all
have 0 continuity events and a clean `pcrverify`. Seven of them (b2 duplicates b1's three steps)
and `mpts3-cc.ts` were each run once through `t10-moq.sh` on `2f2ff7d3`,
`c87159d8` and `2b689c24`, and graded by `t10-grade.py`. The criterion was fixed after modelling and
before grading: #4122 is clean if and only if no section lane steps back past 500 ms, and its
parent is clean on every fixture.

**The #4122 discriminator builds.** [`t10-4122-patch.py`](scripts/t10-4122-patch.py) patches a
`2b689c24` tree two ways, asserting that each edit site matches exactly once. **A** only logs: one
line per anchor re-anchor (generation, source time, old and new offset), and one more when the
re-anchor came from the section-clock lane. **B** is A plus one section-clock lane per video PID in
place of the shared one. [`t10-4122-instr.sh`](scripts/t10-4122-instr.sh) builds both into the
bisect worktree, restores the tree, and runs b7, b3, b5, `mpts3-cc.ts` and a single-programme cut
(`tsp -P zap 1 --stuffing --eit`) through `t10-moq.sh` on each, graded by `t10-grade.py`. The
relay is `2b689c24`'s own. The predictions were fixed after reading the code and before building:
A's re-anchors all come from the section-clock lane, their count rises b7 < b3 < b5 < `mpts3-cc`,
and the single programme has none. B has SCTE-35 of at least 150 and PID 121 audio of at least
8,000 on b3, b5 and `mpts3-cc`; if SCTE-35 recovers and audio does not, the audio has a second
cause. The anchor's forward movement is summed from A's log lines.

**Arm C — several concurrent SPTS broadcasts (MoQ).** Not run; its channel-count question is
answered by [T43](test-43-fanout-current-build.md) S2.

**Arm E — MPTS through a real CDN.** Not run: it needs a CDN account the lab does not hold
([B-5](planned-experiments.md#blocked-on-apparatus)).

## Metrics

Per programme (or per concurrent broadcast), at P1 unless noted:

- **Structural fidelity** — PAT/PMT/SDT/NIT/TDT presence and byte identity against source; TSID/ONID
  and service name/type preserved; every elementary stream accounted for.
- **Continuity** — TSDuck continuity count; 0 is the broadcast-domain pass/fail ([method-notes](method-notes.md)
  on grep-based counting).
- **PCR conformance** — interval min/mean/max, fraction of intervals > 40 ms, `pcrverify` at 500 µs /
  13 absolute units, per PCR PID.
- **Carriage cost (media-aware lane)** — SI snapshot bytes and track count per service; cold-join
  time-to-first-byte with and without full EPG, attributed to bytes or round-trips.
- **Fan-out (Arm C)** — per-role CPU, RSS and delivered rate versus K, compared to the one-broadcast
  slopes from [T26](test-26-cross-host-fanout.md); binding resource named if a knee appears.
- **CDN arm (Arm E)** — deliver/not-deliver; analyser pass/fail per programme; gateway behaviour if
  tested.

Recovery time and session events are recorded for diagnosis but are not headline metrics.

## Pass criteria, fixed before running

1. **Per-programme Gate 1 on MoQ opaque (Arm A).** For every programme in the fixture: PSI/SI
   bit-identical to source at P1, 0 continuity errors, PCR intervals with 0 % > 40 ms on each PCR PID,
   and every elementary stream present with correct `stream_type` and descriptors.
2. **Per-programme Gate 1 on segmented local (Arm D).** If the packager emits a multiplex, the same
   criteria as (1) per programme at the HLS receiver egress. If the packager refuses or splits the
   MPTS, that outcome is reported as a lane limitation — not a failure of the rig — provided the
   behaviour is documented with the exact tool flags used.
3. **No cross-talk (Arm C).** Each of the K concurrent broadcasts delivers only its own programme's
   PAT/PMT set; any PAT referencing another broadcast's TSID is a fail.
4. **Fan-out linearity (Arm C).** Relay CPU and RSS versus K remain linear within the confidence of
   the fit (r² ≥ 0.95 on ≥ 5 points) until a stated stopping condition from [T26](test-26-cross-host-fanout.md)
   (per-subscriber delivery < 95 % of K = 1, or relay CPU saturation). Superlinear growth in relay
   cost with channel count is a finding.
5. **Media-aware SI (Arm B).** EIT section sets equal source for every service that carries EIT;
   carriage rate within ±10 % of source per EIT PID ([T17](test-17-si-snapshot-tracks.md) criterion 3);
   join cost recorded and compared to the single-service baseline — not pass/fail unless join blocking
   exceeds 1 s per additional 10 services (a falsifiable upper bound chosen before the run).
6. **CDN arm (Arm E), when runnable.** Delivered object must contain the MPTS payload unchanged at
   byte level, or the cell records the edge's rejection/splitting behaviour. Silent delivery of a
   truncated or single-programme extract without error is a fail.

As applied to this run: criterion 1 is graded on the media-aware lane, the only MoQ lane on the build
under test; criterion 5's join clause is recorded as time-to-first-byte only, because the T17 cold-join
instrument was not run; criteria 3, 4 and 6 belong to arms that were not run.

| Criterion | Arm | Outcome |
|---|---|---|
| 1 | A, independent clocks | **Fail — refused.** Nothing gradable delivered. |
| 1 | A′, common clock (discriminator, not the fixed arm) | **Fail — flattened.** Programme 1 structurally intact; programmes 2 and 3 without PAT entry, PMT or PCR. |
| 2 | D | **Pass.** Every programme's PSI/SI sections bit-identical, 0 continuity events, 0 % of PCR intervals > 40 ms, every elementary stream present with its `stream_type` and descriptors. The 13-tick `pcrverify` metric fails; it is not part of the criterion. |
| 5 | B, independent clocks | **Not gradable** — the run aborted before EIT reached the egress. |
| 5 | B on A′ | EIT section sets **equal** for all three services; EIT carriage rate **+64 to +67 %, outside ±10 %**; join not attributed. |

## Results

### The fixture

`mpts3.ts` (md5 `be654ba9604bea7c52038ba4b1804895`): 60 s, 793,559 packets, 19,891,902 b/s CBR,
19 PIDs, 0 continuity events, `pcrverify --absolute --jitter-max 13` 8,484 PCRs OK and 0 failing.

| Programme | PMT PID | PCR PID | Elementary streams | SDT service |
|---|---|---|---|---|
| 1 | 100 | 111 | AVC 111; MPEG-1 audio 121; AC-3 123; teletext 131; SCTE-35 141, 142, 143 (three CUEI registrations) | CNNI EMEA HD, type 0x19 |
| 2 | 512 | 529 | AVC 1080p 529 | T10 Video-only, type 0x01 |
| 3 | 768 | 785 | AVC 640×360 785; MPEG-1 audio 786 | T10 AV, type 0x01 |

| PCR PID | PCRs | max interval | intervals > 40 ms | first PCR |
|---|---|---|---|---|
| 111 | 2,457 | 24.95 ms | 0 % | 25,631.613 s |
| 529 | 3,028 | 21.17 ms | 0 % | 2.903 s |
| 785 | 3,002 | 24.19 ms | 0 % | 3.341 s |

The PAT (TSID 0) lists the three programmes. SDT actual (TSID 0 / ONID 0) lists all three services
with EIT present/following flagged; EIT p/f on PID 0x12 rolls every 20 s, six distinct sections per
service in the window, at 2.001 packets/s. The NIT and TDT are programme 1's own: the TDT appears four
times, and the NIT's service list names service 1 only.

`mpts3-cc.ts` (md5 `cc60866878b71578fe1ade51aba05add`) has the same structure, 0 continuity events and
8,513 PCRs within 13 ticks. Its first PCRs are 25,631.613 s (PID 111), 25,632.432 s (529, +0.82 s)
and 25,631.655 s (785, +0.04 s).

### Per programme, per lane

| Programme | MoQ, independent clocks (A/B, 2 runs) | MoQ, common clock (A′, 2 runs) | MoQ, programme alone (control, 1 run each) | Segmented (D, 1 run) |
|---|---|---|---|---|
| 1 — PCR 111, 7 ES | refused | CARRIED; PMT not bit-identical (lists three foreign ES); PCR max 25.0 / 175 ms, 0 / 0.044 % > 40 ms | CARRIED; PMT structure identical, bytes not; PCR max 325 ms, 0.043 % > 40 ms | CARRIED; PMT bit-identical; PCR intervals as source |
| 2 — PCR 529, 1 ES | refused | FLATTENED: no PAT entry, no PMT 512, no PCR on 529; ES listed in programme 1 | CARRIED; PMT bit-identical; PCR max 25.0 ms | CARRIED; PMT bit-identical; PCR intervals as source |
| 3 — PCR 785, 2 ES | refused | FLATTENED: no PAT entry, no PMT 768, no PCR on 785; ES listed in programme 1 | CARRIED; PMT bit-identical; PCR max 25.0 ms | CARRIED; PMT bit-identical; PCR intervals as source |
| PAT | — | programme 1 only | rebuilt, not bit-identical | bit-identical |
| SDT / NIT / TDT packets | — | sections identical, still listing services 1–3 / identical / 4 → 4 and 4 → 6 | sections identical / — / 4 → 4 (programme 1: 4 → 5) | bit-identical / bit-identical / 4 → 4 |
| EIT p/f per service | — | 6/6 identical; 2.001 → 3.284 and 3.345 packets/s | 6/6 identical; rate +2 to +6 % | 6/6 identical; 2.001 → 2.009 packets/s |
| Continuity events | — | 0 | 0 | 0 |
| `pcrverify`, 13 ticks (within / failing) | — | PID 111: 0 / 2,290 and 0 / 2,292 | 0 / 2,337, 0 / 2,349, 0 / 2,312 | 15 / 2,431, 28 / 2,987, 2 / 2,987 |
| Delivered | 160–171 kB, then abort | 57.3 of 60.0 s; TTFB 2.28 / 2.33 s | 57.8–58.7 of 59.9 s; TTFB 0.48 / 1.64 / 1.65 s | 59.74 of 59.98 s; head trimmed 0.24 s |

In every lane that delivered, every source elementary stream is present at egress with its
`stream_type` and descriptors. On the MoQ lane nothing is lost mid-stream: in the second A′ run every
stream's largest PTS step at egress equals its largest at source. What the lane does not deliver is
the head before the subscriber's first group (1.1–2.2 s by stream in that run) and the tail: every
egress stream stops at about the same instant, 0.4–2.0 s short of that stream's end at source, and
the rest is lost at teardown. Packet counts differ from source for two further reasons. The lane
re-packetises audio at one frame per PES (programme 1's MPEG-1 audio: 277 PES at source,
2,387 at egress), which adds about 19 % of packets on audio PIDs in the controls and in A′ alike.
Where a stream's first group opens on a large intra frame, the head loss costs a larger share of
packets than of frames (programme 3 video in A′: 14 % of packets, 6 % of frames).

The 13-tick `pcrverify` gate fails on every PCR of the MoQ lane, with one programme or three, because
the exporter re-stamps the PCR. Programme 1 shows occasional PCR intervals above 40 ms on this lane
whether it travels alone or in the multiplex (one control and one of the two A′ runs), so they are
not a multiplex effect. They do fail criterion 1's interval clause, and they are
[T13](test-13-downstream-grooming.md)'s territory.

### Arm A: the refusal

Both runs behaved the same way (TTFB 1.79 s and 1.81 s, publisher exit 1, egress 171,268 and
160,364 B). The importer announced one broadcast holding every programme's tracks —
`0.avc3 1.avc3 7.avc3 8.mp2 9.mp2 2.ts … 6.ts` and the SI snapshot tracks `0x0010-0x40.si`,
`0x0011-0x42.si`, `0x0012-0x4e.si`, `0x0014-0x70.si` — and about 2 s into the feed the publisher
stopped:

```
WARN moq_net::model::resume: no route can serve the rest of this group group=0 frame=17 err=transport: frame timestamp is below the live edge
Error: frame timestamp is below the live edge
Caused by:
    frame timestamp is below the live edge
```

The subscriber then failed on the broken broadcast, with `TS track layout changed after PAT/PMT was
emitted: '0.avc3' removed` in one run and `json: dropped` in the other.

The mechanism is in the importer's source and is confirmed by the discriminator. Private sections and
SI snapshots carry no PES timestamp, so `moq import ts` stamps them with the latest video PTS it has
seen (`last_pts`, `rs/moq-mux/src/container/ts/import.rs`). There is one such clock per input, and
its own comment states the limit: *"SPTS scope: one clock for the whole input. Under MPTS every
program's video advances it."* With programme 1's clock near 25,631 s and the other two near 3 s,
consecutive SI groups are stamped alternately from clocks 25,628 s apart. The track producer refuses
a timestamp below its live edge (`TimestampRewind`), and that error ends the publisher. A′ removes
the clock offset and nothing else, and the refusal goes with it.

It is not a clean refusal. The importer does not reject an MPTS when it parses a second PMT; it
accepts it, and fails later on a secondary symptom with an error that does not name the cause.
A clean refusal would name the multiplex.

### A′: the flattening

On a common clock the publisher completed (exit 0) in both runs, and 86.2 MB reached the egress
(86,219,996 and 86,195,556 B); the two runs graded alike on every structural point below. The egress
PAT lists programme 1 → PMT 100 only. That PMT, program 1 with PCR PID 111, lists all ten elementary
streams: programme 1's seven, then 529, 785 and 786, each with its source descriptors. PMT PIDs 512
and 768 do not appear, and PIDs 529 and 785 carry no PCR. The exporter builds one PAT entry and one
PMT from the catalog's single program record (`export.rs`), so this is the design's output for any
multiplex that survives import, not a fault of this run.

All egress streams are re-timed onto one clock: in the first 400,000 egress packets of the first
run, every PTS sits 0.10–0.47 s ahead of PCR 111, the re-homed streams included. A receiver therefore gets a playable
programme 1 with three extra streams in it. It also gets an SDT and EIT that still advertise services
2 and 3, and a PAT that does not list them — an internally inconsistent service layer.

The EIT carriage rate rose 64–67 % (2.001 → 3.284 and 3.345 packets/s) with three services' p/f
sections on one EIT snapshot track, against +2 to +6 % for each service alone. The sections themselves are the
source's. Which re-emission produces the extra packets was not isolated.

At teardown the subscriber exited with `TS track layout changed after PAT/PMT was emitted: '7.avc3'
removed` in one run and `json: dropped` in the other. The single-programme controls ended with the
same two errors, so this is the exporter's end-of-broadcast behaviour, not a multiplex effect.

### On upstream `main` at `2b689c24`: no refusal, and silent loss

The MoQ arms were re-run on `main` at `2b689c24` (`moq 0.12.8` / `moq-relay 0.15.8`), same rig and
fixtures: one run of `mpts3.ts`, two of `mpts3-cc.ts`, and one programme-1 control (`spts1.ts`).

| | Independent clocks (1 run) | Common clock (2 runs) | Programme 1 alone (1 run) |
|---|---|---|---|
| Publisher | exit 0, nothing logged | exit 0 | exit 0 |
| Structure | flattened as on `ffa5b81b`: PAT lists programme 1 only, one PMT with all ten ES under PCR 111 | the same | CARRIED, PMT structure identical |
| Programme 1 video (PID 111), packets | **8,424 of 359,960** | 338,723 and 355,920 of 359,960 | 349,302 of 359,273 |
| Programme 2 video (529) | 73,023 of 74,441 | 70,588 and 73,105 of 74,529 | — |
| Programme 3 video (785) | **546 of 14,398** | 12,605 and 12,929 of 14,956 | — |
| SCTE-35, per PID (141/142/143) | 3 / 3 / 2 of ~60 | **1 / 2 / 1 and 7 / 4 / 7** of ~60 | 57 / 57 / 57 |
| Programme 1 MPEG-1 audio (121) | 92 of 8,055 | 5,408 and 6,376 of 8,055 | 9,688 of 8,040 |
| EIT carriage rate (PID 0x12), source 2.001 packets/s | 0.005 | **4.791 and 0.484** (+139 %, −76 %) | 1.092 (source 1.003) |
| PCR 111, intervals > 40 ms | 0.34 %, largest step 51,197 s | 0.088 % and 0.312 % | 0 %, max 25.0 ms |
| Continuity events | 0 | 0 | 0 |

- **Independent clocks no longer abort; the output is corrupted instead.** The importer that exited
  on `TimestampRewind` on `ffa5b81b` now completes with exit 0 and logs nothing, while programme 1's
  and programme 3's video arrive at 2 % and 4 % of their packets. PCR 111 switches between clocks
  13 times in the egress, and audio and teletext PTS land on values absent from the source.
- **On a common clock, `main` loses content that `ffa5b81b` delivered.** Video is intact, but
  SCTE-35 arrives at 1–7 packets of ~60 per PID, programme 1's audio is 21–33 % short, and the EIT
  rate swings between runs. In the second common-clock run programme 1's MPEG-1 audio has eight
  holes of 2.7–4.1 s, each about 0.45 s shorter than the last; its AC-3 has nine, and programme 3's
  audio three of 0.8–1.8 s. The commit that introduces them is bisected below, and the loss is
  located in its section clock; the route from there to holes of that shape is not traced.
- **The loss is specific to the multiplex.** Programme 1 alone through `main` delivers its
  SCTE-35 (57 of ~60 per PID), its audio and its EIT at +9 %, as on `ffa5b81b`.
- **Two commits, bisected first-parent between the builds** (§ *Bisect between the builds*):

  | Property | Last old commit | First new commit | Old | New |
  |---|---|---|---|---|
  | Independent clocks refused | `cf0ef442` | `2299622e`, [#3997](https://github.com/moq-dev/moq/pull/3997) *every TS elementary stream re-anchors below the live edge* | publisher exit 1 | exit 0 |
  | Common clock clean | `2f2ff7d3` | `c87159d8`, [#4122](https://github.com/moq-dev/moq/pull/4122) *publish stdin imports on the broadcast clock* | SCTE-35 168, PID 121 audio 9,416 | SCTE-35 6, audio 5,504 |

  Between the two, at the #4001 merge `66440a6c`, the independent-clock input already completed
  with exit 0 and the common-clock input was still clean (SCTE-35 168, audio 9,416). #4122 also
  takes programme 3's video on independent clocks from 12,836 packets to 0. Each commit's parent
  was graded directly, not inferred, and both endpoints were re-graded before the bisect and
  reproduced (`ffa5b81b` SCTE-35 165, `2b689c24` 17).
- **So #3997 turns the refusal into a re-timing, and #4122 turns the re-timing into loss.** #3997
  is what its title says: a timestamp below a stream's live edge is re-anchored rather than
  refused, and that refusal is what ended arm A.
- **#4122's loss is the section clock re-anchoring the whole source, and it is measured.** #4122
  maps each input onto the broadcast clock through one anchor shared by every track (`Anchor`,
  `rs/moq-mux/src/clock.rs`). Each track keeps its own lane, and a backwards step of more than
  500 ms on a lane that is on the anchor's current generation (`MAX_REORDER`) re-anchors the whole
  source forward, at least to the end of everything published so far. The importer's section clock,
  `last_pts`, is advanced at every video PES through one lane (`media_unwrap`,
  `rs/moq-mux/src/container/ts/import.rs`), whichever programme the PES belongs to. On that lane,
  consecutive video PES alternate between programmes, in decode order, so the lane steps back past
  500 ms whenever a programme's offset and its B-frame reordering add up to more than that. It is
  also always on the current generation, because it adopts each re-anchor it causes, so every such
  step moves the anchor forward again. SCTE-35 and the SI tables are stamped from that ratcheting
  clock. Two patched builds of `2b689c24` settle it (§ *The #4122 discriminator builds*):

  | Fixture | A: re-anchors, all from the section-clock lane | A: anchor moved forward | A: SCTE-35 / PID 121 audio | B: re-anchors | B: SCTE-35 / PID 121 audio | Parent `2f2ff7d3`, same fixture |
  |---|---:|---:|---|---:|---|---|
  | b7 | 7 | 4.1 s | 153 / 9,348 | 0 | 171 / 9,532 | 170 / 9,532 |
  | b3 | 33 | 19.8 s | 62 / 7,496 | 0 | 169 / 9,540 | 168 / 9,240 |
  | b5 | 195 | 113.8 s | 21 / 6,584 | 0 | 171 / 9,532 | 168 / 9,536 |
  | `mpts3-cc` | 1,044 | 688.2 s | 17 / 7,056 | 0 | 174 / 9,620 | 168 / 9,420 |
  | programme 1 alone | 0 | — | 171 / 9,688 | 0 | 177 / 9,820 | — |

  Build A only logs, and it reproduces `main`'s loss. Build B gives the section clock one lane per
  video PID and changes nothing else. It removes every re-anchor, and SCTE-35 and programme 1's
  audio return to the parent's level on every fixture. The single-programme input never
  re-anchors on either build. So the loss is the ratchet: over a 60 s fixture the anchor moves
  4.1–688 s forward, and SCTE-35 loss rises with it. How the ratchet reaches the audio tracks, which
  have lanes of their own, is not traced. Removing it restores them. One run per cell; each
  prediction was fixed before the builds were run.
- **The dose run fixed the relationship before the mechanism was found.** It graded fixtures that
  differ only in how far apart the programmes' clocks sit. For each it also records the per-section
  lanes' backwards steps as modelled over the fixture's bytes (§ *Section-clock dose*); they are the
  quantity the refuted hypothesis turned on (§ *Corrections*):

  | Fixture | EIT steps > 500 ms (largest) | SCTE-35 lanes' steps > 500 ms | P2 / P3 median offset | SCTE-35 `2f2ff7d3` / `c87159d8` / `2b689c24` | PID 121 audio, same builds |
  |---|---|---|---|---|---|
  | b7 | 0 (160 ms) | 0 | −40 / +40 ms | 170 / 153 / 152 | 9,532 / 9,340 / 9,368 |
  | b3 | 0 (320 ms) | 0 | +130 / −120 ms | 168 / 71 / 38 | 9,240 / 8,240 / 5,380 |
  | b5 | 0 (280 ms) | 0 | +320 / +60 ms | 168 / 24 / 14 | 9,536 / 7,596 / 6,336 |
  | b8 | 1 (520 ms) | 0 | 0 / −420 ms | 170 / 12 / 9 | 9,532 / 7,972 / 8,232 |
  | b1 | 3 (640 ms) | 0 | −560 / −80 ms | 170 / 9 / 26 | 9,472 / 9,500 / 9,712 |
  | b4 | 8 (920 ms) | 0 | −20 / +760 ms | 167 / 5 / 9 | 9,512 / 860 / 1,432 |
  | `mpts3-cc` | 9 (720 ms) | 0 | +474 / −146 ms | 168 / 5 / 17 | 9,420 / 5,420 / 6,308 |
  | b6 | 10 (1,760 ms) | 6–8 | −1,520 / +200 ms | 160 / 3 / 3 | 8,864 / 8,200 / 8,124 |

  The parent is clean on all eight, so the commit attribution stands. b3 and b5 lose 58–92 % of
  SCTE-35 although no per-section lane steps back past the threshold. SCTE-35 loss grows with the
  offset between programmes. b7, the tightest, is 10 % short of its parent, and build A reproduces that
  loss while build B removes it, so it is real rather than run-to-run variation. Audio loss follows
  neither modelled measure: b1 is intact, and b4 loses 91 %. The importer logs nothing in any of
  these runs.

So on `main` the lane's MPTS failure moves from a loud refusal to silent loss, which is the worse
failure for a broadcaster: a monitoring chain that watches for a publisher exit sees nothing, and
continuity stays at 0.

### Arm D: carried, with a programme-1-only initialisation pair

The packager published 25 segments of 2.0–2.4 s (`EXT-X-BITRATE:19426`), and the playlist ends
with `#EXT-X-ENDLIST`. The receiver captured 790,446 packets. The first segment starts at an intra
frame, 3,163 packets (0.24 s) into the source; after that, the whole source is delivered.

With null, PAT and PMT-100 packets excluded, the egress packet sequence equals the source's exactly.
The packager adds one PAT and one PMT-100 packet at each segment head — 25 of each — as extra packets,
not substitutes. They are copies of source packets with the continuity counter renumbered, so
continuity stays at 0 events. Every later packet moves by up to 48 positions, which is what the
13-tick `pcrverify` gate sees; the PCR values and their intervals are the source's. This is the
mechanism [T3](test-3-opaque-transparency.md) measured on one programme and
[T16](test-16-grooming-segmented-http.md) closes by grooming. The one difference in a multiplex is that the
added pair carries programme 1's PMT only: a receiver that starts at a segment head is handed
programme 1's PMT at once, and programmes 2 and 3 at their source cadence.

The receiver log carries one line, `* Error: hls: no URL specified`, which was not explained. The
capture is complete, and it does not bear on any figure above.

## Limits

- **One host, P1 only.** No cross-host, wide-area or impaired path, and no hardware IRD (P2 remains
  [T7](test-7-timing-integrity.md)/P2).
- **One synthetic multiplex.** Three programmes built from three clips: one real contribution feed
  and two single-service clips re-addressed. Programmes 2 and 3 carry no SCTE-35 or teletext, the
  NIT is programme 1's own and names service 1 only, and nothing is scrambled. A commercial MPTS
  exercises more of the service layer than this; the MoQ result would not improve on it, because both
  defects are structural — one section clock and one program record.
- **The common clock is approximate.** Merge's start varies by up to ~0.8 s between builds, so A′'s
  clocks agree to 0.82 s, not exactly. The refusal disappearing on that input shows that clocks
  25,628 s apart trigger it on `ffa5b81b`. On `main`, no tested offset is safe: SCTE-35 is lost
  even on b7, whose programmes sit within 40 ms of each other (median). Tighter alignment than
  b7's is not reachable with the fixture builder, so whether any cross-programme offset is safe is
  not established.
- **The media-aware lane only.** The opaque lane of T3 is not in the build under test, so this is not
  a statement about opaque carriage of a multiplex.
- **Join cost is not measured.** Criterion 5's comparison with T17's cold-join baseline needs its
  instrument. A′'s time-to-first-byte (2.28 and 2.33 s) lies outside the controls' 0.48–1.65 s, and
  that difference cannot be attributed to SI join from this run.

## What remains open

- **Opaque carriage of a multiplex on MoQ** — the arm criterion 1 was written for. It needs a build
  with an opaque lane.
- **A multiplex-aware media-aware lane** — one section clock per programme, and one program record
  per PMT, so the exporter can rebuild the PAT and every PMT. Until then an MPTS on this lane has to be
  split into one broadcast per programme at ingest, and that split is itself untested here.
- **How #4122's ratchet reaches the audio tracks.** The mechanism is located and removing it
  restores the audio, but the path from the section clock's re-anchors to audio lanes that have
  their own offsets is not traced. It matters only while the anchor exists: upstream plans to
  refuse a multi-programme input by default and to remove the anchor from the importers.
- **Whether a single programme can trigger the same ratchet.** On one programme the shared lane
  sees one video PID, and it steps back only by that stream's B-frame reordering. Programme 1 alone
  never re-anchored here. A stream whose reordering spans more than 500 ms, or a programme with two
  video PIDs, would step it back that far; that is *reasoned* from the code and not run.
- **Arm E**, blocked on a CDN account ([B-5](planned-experiments.md#blocked-on-apparatus)), and the
  SI carriage-cost scaling of [T17](test-17-si-snapshot-tracks.md), which needs many more services
  than three.

## Corrections

- **#4122's re-anchor source.** Believed: the per-section lanes (SCTE-35, EIT) step back past
  500 ms when the programmes alternate, and each such step re-anchors the source. Modelled over the
  fixture bytes, they mostly do not, and the loss appeared anyway. True: the re-anchors come from
  the one lane through which every programme's video advances the section clock, upstream of the
  section lanes. Method rule: when state is shared, model the call site that writes it before
  modelling anything derived from it ([method notes](method-notes.md) §4, *A mechanism read from
  the source is a hypothesis*).
