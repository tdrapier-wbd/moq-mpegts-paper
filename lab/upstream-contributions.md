# Upstream contributions

What this campaign found, reported and verified in other people's projects. It is kept separate from
the experiment record because the argument is different from "does MoQ suit broadcast primary
distribution", and because much of the campaign's effort lives here in a way the per-experiment results
alone do not show.

**Why it belongs in the repository at all.** [Comparison](../docs/comparison.md) §13 scores
operational maturity against a pre-1.0 ecosystem. This file is the concrete form: what a broadcaster
procures is an implementation, not a specification, so much of what reads as "MoQ does X" is really
"this build does X" — and several gaps recorded here have since closed. That is implementations
maturing *with* a specification rather than after it; the gaps were real, and they closed fast.

Each item states what was found, how it was verified, and what remains open. Where a fix was verified
here rather than taken on trust, the before/after rigs are named.

Four kinds of thing are recorded: defects verified against before-and-after builds; test coverage and
fixtures contributed where the tree could not yet produce the stream in dispute; a review of the
*specification* rather than an implementation (§7); and requirements filed early and then withdrawn on
this campaign's own measurements (§8), where the ratio is the point.

---

## 1. Media-aware carriage: what a real contribution feed breaks

### The lane this campaign measures did not exist when it started

The first reports asked whether a broadcast feed survives the round-trip at all; it did not. A real
contribution capture published and subscribed back produced continuously undecodable H.264
(`non-existing PPS 0 referenced`), because the import/export path kept a single SPS and a single PPS
and a source carrying several lost all but the last seen. PES **DTS was not authored at all**, so
B-frame content — 12,480 B-frames in the capture — emitted a decode timeline a player had to be told
to ignore. Reported as [#1798](https://github.com/moq-dev/moq/issues/1798) and
[#1836](https://github.com/moq-dev/moq/issues/1836), fixed by
[#1812](https://github.com/moq-dev/moq/pull/1812) and
[#1843](https://github.com/moq-dev/moq/pull/1843).

The larger carriage question went to [#1799](https://github.com/moq-dev/moq/issues/1799), which
presented media-aware and byte-opaque options **neutrally** and asked for a direction rather than
advocating one. Upstream chose verbatim per-PID carriage under an `mpegts` catalog section
([#1815](https://github.com/moq-dev/moq/pull/1815)), so ancillary PIDs — DVB teletext, AC-3, all three
SCTE-35 PIDs — survive as opaque tracks while video and audio stay typed and playable without TS
support. CLI wiring was out of scope in that PR, leaving the lane library-only until
[#1842](https://github.com/moq-dev/moq/pull/1842) closed
[#1835](https://github.com/moq-dev/moq/issues/1835).

### The harness that found most of what follows

The MPEG-TS/IRD compliance harness this campaign uses was offered upstream as
[#2024](https://github.com/moq-dev/moq/pull/2024): relay round trip, TSDuck parsing, and PCR interval,
accuracy, mux-rate stability and continuity graded against IRD expectations. It landed as
[#2011](https://github.com/moq-dev/moq/pull/2011), hardened in
[#2043](https://github.com/moq-dev/moq/pull/2043), as `just test ts`. The open-GOP break below was
found by pointing the merged harness at a real capture whose source file was clean; the round trip
failed.

### Open-GOP keyframe detection — closed

An open-GOP H.264 capture (recovery-point SEI, one IDR every 15 s) produced **no video rendition**
through media-aware import, because keyframe detection keyed only on the IDR NAL type. Reported as
[#2050](https://github.com/moq-dev/moq/issues/2050); closed by catalog-reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)) together with recovery-point-SEI detection
([#2066](https://github.com/moq-dev/moq/pull/2066)). Verified ([T2](test-2-media-aware-transparency.md)):
the feed round-trips deterministically, every stream, PID, `stream_type` and descriptor intact.

### Open-GOP leading pictures at tune-in — fixture and measurement contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)

Upstream's consumer-side quest for leading pictures (decoded after a recovery point, presented before
it) waited on a measurement of what a viewer does with them
([#2067](https://github.com/moq-dev/moq/issues/2067)), and the fixture that issue proposed is not open
GOP: every keyframe is an IDR.

**Contributed as [#4501](https://github.com/moq-dev/moq/pull/4501)**, merged (`test(ts)` and quest
files only). `just test ts --open-gop` round-trips a generated x264 `open-gop=1` clip with three
leading pictures per recovery point, graded access unit by access unit: 60 of 60 leading pictures
across 20 recovery points in decode order, random-access indicator set on every random-access access
unit, recovery-point SEI intact, `compliance.py` passing.

**The viewer is where it breaks, and how depends on the decoder.** Measured through `<moq-watch>` in
Chromium 153 on macOS, 120 s clip, one continuous subscriber and eight cold joins per decoder setting:

- **Continuous playback** decoded every leading picture on both decoder paths; frames were identical.
- **VideoToolbox at a cold join** (macOS default) never outputs the orphaned leading pictures, with
  no error — the viewer starts at the keyframe.
- **Software decoder at a cold join** (`prefer-software`) raised `EncodingError` in 8 of 8 joins before
  any frame, and `<moq-watch>` closed its decoder, so the join showed no video.
- **Control with leading pictures removed** joined cleanly in 8 of 8 software joins; the error is the
  leading pictures, not starting at a non-IDR keyframe.
- **Latency skip** into a later group orphans that group's leading pictures the same way.

The numbers sit in the upstream leading-picture quest (`quest/m1/open-gop-leading-pictures.md`), which
the PR unblocks: trim before decode, and drive the software decoder in the test.

The PR also found the exporter authoring DTS after PTS on B pictures, fixed by #4500 (§ *The video DTS
reserve*).

**Open:** the consumer-side trim itself; Linux, not measured, where the software-decoder outcome is
expected wherever no hardware H.264 exists.

### The exporter locked its PSI on half a catalog — closed, by a better fix than the one proposed

`export ts` built PAT and PMT once a header and video track had resolved, then aborted with
`TS track layout changed after PAT/PMT was emitted` when a later track arrived — a race decided by
codec, not timing: AAC registers on its first PES, H.264 waits for inline SPS in a keyframe, so
audio-first streams reliably lock PSI on an audio-only layout
([#1979](https://github.com/moq-dev/moq/issues/1979)).

This campaign proposed gating PSI on the PMT's declared elementary-stream count as `expected_tracks`
([#1980](https://github.com/moq-dev/moq/pull/1980)). Upstream read the problem as container-finality
signalling in general, not MPEG-TS alone, and closed it with catalog reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)): one reservation per PMT-declared track until its
config resolves, catalog withheld until the last drops — the same rule without a container-specific
catalog field, and the gate the open-GOP fix above requires.

### The DVB service layer — closed

The `mpegts` catalog modelled per-PID PMT info and verbatim elementary streams only, so `export ts`
rebuilt just PAT and PMT and lost service name and provider, service type, NIT, TSID, ONID and the
PMT's own PID. Reported as [#2433](https://github.com/moq-dev/moq/issues/2433), prototyped as
[#2434](https://github.com/moq-dev/moq/pull/2434). Upstream declined DVB-specific shape in favour of
proxying PIDs ([#2440](https://github.com/moq-dev/moq/pull/2440): service record through the catalog,
SI rebuilt on export keyed by PID). Measured before and after in
[T2](test-2-media-aware-transparency.md).

Carriage keyed by PID, not by table, is why the EIT question below is one PID carrying two tables,
not a new field.

### EIT, and where carried SI should live — the question we priced

#2440 left EIT and TDT/TOT out. On a synthetic fixture (no capture here carries EIT), census showed
**opposite revision rates**: EIT repeats byte-identically between event transitions; every TDT/TOT
section is new content and therefore a republish for a table that says only "now". Reported as
[#2800](https://github.com/moq-dev/moq/issues/2800).

Fixtures had to land before behaviour could be argued about: [#2828](https://github.com/moq-dev/moq/pull/2828)
synthesises EIT from any clip (TSDuck, service triplet from PAT/SDT, EPG anchored to TDT; CBR padding
because `tsp` replaces rather than creates packets); [#2920](https://github.com/moq-dev/moq/pull/2920)
adds sparse multi-day schedule and pending-version shapes, wired into `just test` with source-side
positive controls. Procedure and census in
[T2](test-2-media-aware-transparency.md#eit-measured-on-a-synthetic-fixture-and-what-carrying-it-would-cost).

The first carriage attempt was [#2824](https://github.com/moq-dev/moq/pull/2824) (EIT p/f in the
catalog), shaped by a mis-filed ask: carriage is keyed by PID, 0x0012 holds present/following *and*
schedule, so an allowlist change that bounded only p/f could not price what it would admit. Verified
byte-identical across a version roll; **closed unmerged** when design moved to snapshot tracks — the measurement grades a design step, not
shipped behaviour
([T2](test-2-media-aware-transparency.md#eit-pf-survives-the-round-trip-on-2824s-branch-verified-on-the-same-fixture)).

**Does carried SI belong in the catalog or on its own track?**
[#2882](https://github.com/moq-dev/moq/issues/2882); this campaign priced it. The catalog is
whole-state, so one changed section rewrites the document and every subscriber pays at join.
Measured against service count
([T2](test-2-media-aware-transparency.md#what-carried-si-costs-the-catalog-and-why-it-is-a-scaling-question)):

| services | standing catalog | SI share | junction cost |
|---|---:|---:|---|
| 1 | 2,180 B | 34.8 % | 2 republishes in 0.11 s |
| 12 | 6,746 B | 79.2 % | 20 republishes in 0.11 s |
| 40 | 18,428 B | 92.7 % | 61 republishes in 1.27 s |

**The bandwidth is noise** — 1.12 MB against a multiplex of tens of Mb/s. What the numbers indict is
the *join* (18 kB read before media discovery, 93 % of it service information) and the *parsing*.

**A multi-section table is assembled in the catalog in public:** at 40 services the SDT sits at 1 of 2
sections for 5.2 s across 53 publishes while section 0 declares `last_section_number = 1` — incomplete
rather than merely stale; no catalog tuning fixes a whole-state document revised one section at a time.

Those measurements supported per-table snapshot tracks on **coherence grounds rather than bandwidth**,
while showing the tables #2440 shipped would gain nothing from it. Settled in favour of tracks in
[#2909](https://github.com/moq-dev/moq/pull/2909), reviewed here in
[T17](test-17-si-snapshot-tracks.md), including the sparse-schedule case that section counting cannot
validate.

### TDT/TOT — carriage closed, then emission timing

Reported as [#2914](https://github.com/moq-dev/moq/issues/2914), where exclusion was deliberate (a
clock is not state; upstream multiplexer time carries unknown delay). Two findings moved the argument,
one correcting a position this repository had supplied upstream:

- **A clock synthesised from the host would break the EPG that now survives** — EIT times are absolute
  UTC, so clock and schedule must share one time base; relaying EIT verbatim while minting TDT locally
  misplaces every event by the offset between clocks.
- **TOT carries policy, not merely time** — DST dates and per-country offsets are the operator's; no
  exporter can invent them.

Both tables are now proxied from the source on a latest-value slot that removed the content-hash
identity a clock-like table would have churned through. Measured: tables arrive and TOT descriptors are
byte-identical to the source's.

**Emission timing remains the stage distinction.** A constant-delay tunnel forwards each tick — RIST and
SRT deliver TDT with inter-section gaps matching a no-transport control to two decimal places
([T15](test-15-point-to-point-cadence.md)). A stage that rebuilds the multiplex re-emits on its own
grid (~14 s late against a source true to half a second, and below that rate re-sends a time already
asserted, stepping a trusting receiver's clock backwards). Filed as
[#2934](https://github.com/moq-dev/moq/issues/2934): treat the interval as a floor on repetition and
emit on change. **Closed** via [#3793](https://github.com/moq-dev/moq/pull/3793);
`export_test::si_revision_does_not_wait_for_the_interval` passes on `5d0991b9`.

### A liveness risk introduced by the fix — closed by deleting the gate

As proposed, export opened only once every SI entry held a snapshot or reached a terminal state.
Terminal failure was handled (log, keep last snapshot); **a track that neither succeeded nor failed
was not**, leaving the gate shut with no TS emitted, media included, and nothing logged past the
subscribe attempt.

The first fix bounded the wait; the second removed the gate entirely — the answer the join measurement
supports. Nothing in SI is required before a stream begins: PAT/PMT are built locally, receivers
acquire the service layer mid-stream by design, and a late entry matches tuning in just before an SDT
repetition. Any gate lets one stale announce hold the programme dark, and no timeout makes that trade
principled — while the measured 15 ms time-to-first-byte
([T17](test-17-si-snapshot-tracks.md#3-the-join-cost-is-small-and-scales-with-bytes-rather-than-track-count))
means the healthy case still leads with its tables without promising to.

### PCR clustering: reported, fixed upstream in three steps, nothing further owed

**Report** ([#2937](https://github.com/moq-dev/moq/issues/2937)). The exporter conserved the PCR
mean and destroyed its spacing. Against a source at an even 24.65 ms, `moq export ts` written
straight to file ([T8b](test-8b-congestion-control.md), no groomer) gave a median interval of
0.011 ms, 85 % under 1 ms and 361–399 intervals above 100 ms, because PCR rode the first packet of
each PES unit with no interval-based path. [T18](test-18-delivery-latency.md) showed a downstream CBR
groomer cannot repair it: across eight times the cushion depth, violations held at 491–503 while its
PCR insertions fell from 137 to 0 with carrier surplus. The issue asked for the exporter to own PCR
placement in the time domain, engaging the closed history of
[#1989](https://github.com/moq-dev/moq/pull/1989), [#1992](https://github.com/moq-dev/moq/pull/1992)
and [#1988](https://github.com/moq-dev/moq/pull/1988).

**Fixed in three steps, each graded by [T19](test-19-pcr-grid-verification.md):**

| Step | Change | Verification |
|---|---|---|
| [#2967](https://github.com/moq-dev/moq/pull/2967) | one PCR per 25 ms media-time grid on adaptation-field-only packets; PCR reserved bits corrected | file, P0: every interval 25.000 ms; above 40 ms 210 → 0; sub-millisecond 85.4 % → 0 % |
| [#2984](https://github.com/moq-dev/moq/issues/2984) → [#3006](https://github.com/moq-dev/moq/pull/3006) | stdout paced on each frame's timestamp, which it had discarded, leaving 87.2 % of PCR packets back to back | pipe: on grid 27.4 % → 56.9 %; end to end unchanged, because a groomer consumes bytes, not arrival times |
| [#3334](https://github.com/moq-dev/moq/issues/3334) → [#3351](https://github.com/moq-dev/moq/pull/3351) | export sliced on the PCR grid, so a PCR can sit inside a frame's bytes | file/pipe: byte adjacency 50.31 % → 0 %, releases outside ±10 ms 491/799 → 0–4/745; wire, a contribution clip: adjacency 0.0 %, 2 of 4,779 outside ±10 ms |

**State.** Closed; nothing further is owed upstream. The cadence question is settled negatively:
with all three exporter domains fixed, the wire still carries 12.2 % of intervals above 40 ms,
because a coded frame's bytes belong to its 40 ms of media; the downstream groomer clears the gate
(T19 measurement 11, `evidence.md` §3.2). Test contribution
[#3335](https://github.com/moq-dev/moq/pull/3335) added `test/ts/pcr-timing.py` upstream; #3006's
release contract still has no regression test there. Open: the share above 40 ms varies by clip
(25.2 % synthetic CBR, 13.9 % and 9.1 % on two contribution captures, 0 % on a 27.5 Mb/s broadcast
mux), unexplained. On our side, the byte-locking groomer, which treated value and position cadence
as interchangeable, shed 67.2 % of the T19 fixture; `mpegts-pacer` now guards against it.

### A rewound timeline stalls the whole programme, not just the SI cadence — measurements contributed, issue fixed and closed, **fix later found to regress the complement** (next section)

**Report.** [#2833](https://github.com/moq-dev/moq/issues/2833) already described the mechanism: the
exporter's last-emission time only advances, so after a backwards jump nothing is due until the
timeline catches up. This campaign added a
[comment](https://github.com/moq-dev/moq/issues/2833#issuecomment-5554907607) with what
[T23](test-23-pcr-discontinuity-classes.md) measured rather than a new issue: the exporter stops
emitting everything, not only SDT and NIT, for a time linear in the rewind (1 s costs 268 ms, 10 s
costs 9,446 ms), and recovers in one burst that overran a groomer's 8 s cushion. Forward jumps recover
in 238 ms, and PCR base rollover is carried correctly.

**State.** [#3375](https://github.com/moq-dev/moq/pull/3375) merged citing the comment, closing #2833:
the exporter restarts on a rewind and flags the first new PCR. We supplied the verification it shipped
without, every T23 arm at the control's content gap
([comment](https://github.com/moq-dev/moq/pull/3375#issuecomment-5557693602),
[T23 § against the fix](test-23-pcr-discontinuity-classes.md#against-the-fix-3375)).
[#3529](https://github.com/moq-dev/moq/pull/3529) closed the forward-jump flag gap #3375 left: arm C
now emits the flag and a faithful 11 ms jump, not 961 ms short
([T23 § against #3529](test-23-pcr-discontinuity-classes.md#against-3529-current-main)). The exporter
reports what the source declared and infers no break from a timestamp step, so an unsignalled jump
stays unflagged by design.

### #3375 regressed the complement: a *non*-rewinding source now stalls video and primary audio — reported as [#3533](https://github.com/moq-dev/moq/issues/3533)

**Report.** #3375 fixed the rewind case, but on a continuous timeline with content joins, which is
what a real encoder emits, the fixed exporter stalled video and MPEG-1 audio for good
([T27](test-27-liveness-detector.md)): `git bisect` names #3375, whose parent held 9.0–9.8 Mb/s across
seven joins where #3375 fell to 0.31 Mb/s from the first. The exporter itself introduced a backwards
step of one pass length that is not on the wire; T27 bounds the attribution away from the source, the
relay and the publisher. From the diff, one track's backwards report fenced every track into the old
generation, and a track whose source never rewinds could not re-join. Which audio comparison reported
a backward step with no backward PCR step is not established.

**State.** [#3533](https://github.com/moq-dev/moq/issues/3533) closed by
[#3784](https://github.com/moq-dev/moq/pull/3784) in [#3793](https://github.com/moq-dev/moq/pull/3793):
`export_test` passes and [T40](test-40-continuous-join-through-srt.md) no longer reads the stall through
SRT. On that build `moq import ts` can still exit at the first join with *frame timestamp is below the
live edge* (T40 § `main-5d0991b9-swap`), a separate monotonic-timeline check filed as
[#3798](https://github.com/moq-dev/moq/issues/3798), because the #3533 fix's `reanchor()` applies to
legacy audio only.

### The mux rate the lane could not carry — closed upstream, citing this campaign's groomer

**The finding.** `moq export ts` carried content only: null packets do not cross MoQ, so
reconstructed streams had no stuffing and no declared multiplex rate —
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer)'s README line that the rate is *"not
recoverable from MoQ"* is quoted in the fix.

**Closed** by [#3831](https://github.com/moq-dev/moq/pull/3831): import measures whole-multiplex
rate on the PCR PID (nulls included), publishes `mpegts.muxRate` once half-second windows agree
within 2 %; export balances null stuffing ahead of each clock packet without delaying media;
`--mux-rate` overrides; absent rate exports byte-identically to before.

**Verified here** ([T13](test-13-downstream-grooming.md) § *The exporter now stuffs and declares a
rate*, file domain, `0.11.2-615d166d`): stuffing **4.93 %** vs source **4.69 %**; declared
**9,981,799 b/s** vs **9,945,951 b/s** (**+0.36 %**); explicit `--mux-rate` **+0.25 %**; continuity
clean. **PCR accuracy and repetition are unmoved** (P2: 0/1,807 vs 0/1,892 inside 481 ns; P1: 11.34
% vs 11.21 % above 40 ms) — the P2 gate becomes answerable on ungroomed egress but still fails
comprehensively; a groomer remains required for both PCR criteria. The absent-rate path is untested
on a genuinely variable source (filtering nulls from CBR still yields a stable lower rate).

### `ffmpeg -c copy` drops most of a broadcast multiplex — reported as [#5950](https://github.com/moq-dev/moq/issues/5950)

[T4](test-4-remote-e2e-srt.md): piped through `ffmpeg -c copy` before `import ts`, a broadcast TS
keeps only the streams ffmpeg maps, so most PIDs never reach MoQ. **Fixed by
[#6004](https://github.com/moq-dev/moq/pull/6004), merged**: the docs say to pipe the source's
bytes, and the first PMT logs each elementary stream's outcome.

---

## 2. Audio robustness: three defects, two closed

### Frame-sync loss killed the whole publisher — closed in two days

**The finding.** A single damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the
publisher outright and took every other track with it — video, teletext, all three SCTE-35 PIDs —
while the video path resynchronised through identical corruption. The report paired a deterministic
one-bit reproducer (monotonic PTS, no discontinuity) with a one-line root cause — the legacy-audio
PES loop propagates header-parse failure with `?` and never scans for the next sync word — against
the module's own *"rejected, never mis-described"* principle and the TS and video resync precedents
already in-tree.

Reported [#2729](https://github.com/moq-dev/moq/issues/2729), fixed
[#2751](https://github.com/moq-dev/moq/pull/2751) within two days: scan forward to the next
sync-word candidate and **confirm before trust** (64 KiB bound), matching the TS layer's rule.
Verified on three one-byte mutants of a 20 s DVB capture:

| Arm | one-byte change | pre-fix | post-fix |
|---|---|---|---|
| MP2 header | sync `0xFF` → `0xFE` | **died at 12 s**, rc=1 | end of file, rc=0 |
| H.264 start code (control) | `0x01` → `0x00` | survived | survived |
| Full A/V looped | none — `--infinite` wrap | **died at first wrap** | 2+ wraps |

By PTS set: one **24 ms** MP2 frame dropped at the damage point; video, AC-3, teletext and SCTE-35
untouched. The fix also closed AAC split across a PES boundary. **Correction:** the original
video+AC-3 loop row does not reproduce — wrap fatality depends on cut position splitting an audio
frame, not codec alone; the MP2 single-bit arm remains decisive.

### A splice publishes a *substituted* frame — closed, with two measured residuals

A corrupt byte drops a frame; a splice with an intact header publishes a **substituted** frame
(bytes from both sides), invisible on continuity or timestamps. Alien detection: a frame whose bytes
appear nowhere in the source elementary stream (`ts-splice-audit.py`).

Split [#2802](https://github.com/moq-dev/moq/issues/2802); first fix
[#2823](https://github.com/moq-dev/moq/pull/2823) extended confirmation to a frame beginning in a
carried tail. **Tested on real content, the first fix changed nothing:** 3 alien frames per audio
PID before and after, same hashes and positions — this mux never splits audio across a PES boundary,
so the carried tail is always empty and foreign bytes join the same truncated PES at the wrap. The
route that works was already implemented for sections: `SectionReassembler` drops partials on
continuity gap, discontinuity or transport error; the PES path had not read the counter. Upstream
reproduced in-tree and **rescoped the PR to five commits**, generalising those rules to PES PIDs.
Merged; verified across four arms: no mixed frame remains.

**Two measured residuals.** (1) Counter-contiguous wraps (~one cut in sixteen per PID; **4,062 of
30,000** positions contiguous for at least one audio PID) bypass the guard — **1 alien AC-3 frame**
per wrap at such a cut; AC-3 CRC would catch it but **0 of 826 MP2 frames** here carry CRC. (2) AC-3
salvage: **~256 ms** of good audio lost per splice post-merge (8 complete frames absent by hash);
MP2 loses nothing on the same branch.

### A recovered stream is signalled nowhere — closed, exactly as asked, and it exposed a bigger gap

Reported [#2798](https://github.com/moq-dev/moq/issues/2798), scoped to observability. **Closed by
[#3372](https://github.com/moq-dev/moq/pull/3372)** (`d554c75d5`): `tracing::warn!` on a *completed*
resync and per-PID counters on `Import::stats` — `resyncs`, `discarded`, `unconfirmed` — documented
as what an operator alarms on, with no protocol change. [T24](test-24-partial-media-plane-stall.md)
verified independently on 60 s suppressed audio (`discarded=466 resyncs=1`). **Two residues:** the
warning fires on recovery, so it is late by the outage's duration; and it exists for **audio only**
— T24 measured **57 s** without video access units and got no log, counter or stats entry, because
`Stats` was audio-frame-sync by design, though the importer already demuxes every elementary stream.
Filed [#3489](https://github.com/moq-dev/moq/issues/3489) as an extension, not a behaviour change;
implemented in the next section.

What #3372 answered: after resync the subscriber TS carries **0 continuity errors**, **0 signalled
discontinuities**, and audio stepping 24 ms → 48 ms across the hole, with no log, counter or
discontinuity signal above TS — policy in the doc comment, so silence is intended. **A TR 101 290
monitor at egress therefore sees a fully conformant stream with no indication that anything was
lost** ([Architecture](../docs/architecture.md) §6.2). While the splice defect stood, substitution
was worse than a drop; #2823 turned substitution back into a gap without touching reporting. Two
importers on identical input dropped the same frame — not a 1+1 redundancy risk. What remains: **the
fix converted a maximally loud failure into a completely silent one** — the lab discovered mid-frame
wrap only because the source crashed 216 times.

### Per-stream liveness in the TS importer — contributed as [#4502](https://github.com/moq-dev/moq/pull/4502) and [#4506](https://github.com/moq-dev/moq/pull/4506), both merged

**The defect** is #3489, as filed above. `Import::stats` had a row only for audio that had lost frame
sync, so a video, Opus, verbatim-PES or SCTE-35 PID had none, and an absent row read as healthy.

**The contribution.** #4502 gives every carried elementary stream a `StreamStats` row with `units`, the
access units delivered, and `quiet`, the transport time since the last one or since the PMT declared
the PID. `quiet` runs on the PCR, not on the media clock that stops with the stream it has to catch,
and ignores a PCR step over 1 s, so one corrupt PCR cannot add hours of silence to every PID, the
failure [T27](test-27-liveness-detector.md)'s detector hit. `moq import ts` logs `elementary stream
stopped delivering access units` once per silence; #4506 moves that logger into `moq-mux` and has the
SRT publisher name the affected ingest.

**Verification**, P0, on the PR builds before merge: in-process tests on fixture files, with no wire
and no cross-host run. With #3489's stimulus (one PID's PES suppressed for a window, its PCR kept in
adaptation-only packets, continuity renumbered), the HEVC, MP2 and SCTE-35 arms each stop counting
across the window while the unsuppressed control advances; `quiet` grows within 50 ms of the elapsed
program clock, a peer stream keeps counting, and the stream recovers afterwards. Through SRT, only the
suppressed feed's video PID is logged. There is no *before* figure, because `main` had neither the
fields nor the rows.

**Open.** No threshold and no TR 101 290 `PID_error` counter exist; the monitoring plan
[#4496](https://github.com/moq-dev/moq/pull/4496) adopts these rows as that check. If the PCR PID itself
stops, every `quiet` freezes instead of growing; the log lines still fire, because they compare counts,
but a consumer reading `quiet` alone would miss it. A sparse stream such as SCTE-35 is logged as stopped
between cues, by design. Nothing has run against a live feed; the arm that would settle it is T24's
60 s video suppression, repeated on a build that carries both changes.

### Per-stream liveness at the TS exporter — contributed as [#4577](https://github.com/moq-dev/moq/pull/4577), merged

**The defect** is the egress half of [#3489](https://github.com/moq-dev/moq/issues/3489). In
[#3533](https://github.com/moq-dev/moq/issues/3533), video and primary audio stalled at the exporter
while PSI and the other PIDs kept flowing, and only [T27](test-27-liveness-detector.md)'s per-PID
detector on a subscriber found it; `Export` reported nothing per PID. The upstream quest set the shape:
the importer's rows at egress, `quiet` on the output's own PCR, and no ETSI counters. It also corrected a
stale attribution: the exporter and the `test/ts` graders gave TR 101 290 a 40 ms PCR repetition limit,
where V1.4.1 sets 100 ms, and its Note 2 records that the 40 ms precondition was removed from
TS 101 154 in 2005.

**The contribution.** `Export::stats` returns one row per elementary stream in the PMT, its liveness
meter on the PCR the exporter writes and its `units` credited when a span leaves the mux buffer, so a
rewind does not count what it discards; `moq export ts` logs through the importer's logger. The PR also
moves the `test/ts` repetition defaults to 100 ms.

**Verification**, P0 and P1, on the PR before `main` was merged into it; it has not been repeated on the
merged build. At P0, on H.264 plus two AAC tracks, stopping video and one audio track halfway through a
6 s run freezes those two rows, whose `quiet` reaches 2.975 s and 3.0 s of the 3 s stall, while the
surviving audio keeps counting and the PAT keeps repeating. At P1, live and co-resident on a local
relay, `contrib-10m.ts` with its MP2 PID dropped about 19 s in made `export ts` log `pid=121
track=".mp2" units=729 quiet=Some(850ms)` once, about a second after the publisher's own line, while
the PAT, video, AC-3 and teletext held their rates. There is no *before* figure, because `main` had no
egress rows.

**Open.** Sparse SCTE-35 PIDs flap in the shared logger, somewhat more at egress than at ingest (21
lines against 16 over the same run), because the exporter delivers by group. A whole-programme stall is
not reported at egress: the output PCR stops with it, so every `quiet` freezes, and the CLI samples
only when a frame goes out; that stays the job of the wire monitor downstream. The corrected default
loosens the hard `pcr-value-interval` check from 40 ms to 100 ms, so a regression that spaced PCRs
between the two would now pass. Nothing has run against a live feed cross-host.

### TR 101 290 counters at ingest — contributed as [#4750](https://github.com/moq-dev/moq/pull/4750), merged

**The defect** is the ingest half of [#1838](https://github.com/moq-dev/moq/issues/1838). `moq import
ts` and the SRT gateway graded nothing of the feed they received beyond PSI CRCs and the liveness rows
above, so a feed that lost sync, dropped packets, ran its PAT late or gapped its PCR was invisible at
ingest until something downstream failed. The upstream quest set the scope: the TR 101 290 V1.4.1
checks a contribution feed is graded on, at ETSI's fixed limits, as counters only.

**The contribution.** A private `ts::health` module counts `TS_sync_loss`, `Sync_byte_error`,
`PAT_error_2`, `Continuity_count_error`, `PMT_error_2`, `Transport_error`, `PCR_repetition_error`,
`PCR_discontinuity_indicator_error` and `PTS_error` beside the existing `CRC_error`, publishes nothing
new, and logs one line with every total whenever any moves, from the CLI and the SRT gateway alike.
Table and PTS intervals run on the PCR-stepped program clock. `PID_error` is left to the liveness rows,
and `PCR_accuracy_error` is not measured: the importer has no arrival clock precise enough.

**Verification on the PR**, P0 (file) and P1 (live, co-resident). At P0, 13 tests, one stimulus per
check with a control each way, in whole packets and in 100-byte pieces; five of six mutants killed, one
equivalent. Every `test_data` capture reads zero except `kyrion_mpeg2av_ac3.ts`,
which reads two `PAT_error_2` and two `PMT_error_2` against a PAT repetition TSDuck measures at 811 ms.
On the 72 s `t23_F` excerpt of `contrib-10m.ts` the clean file reads zero, twenty packet-aligned 7-packet
drops read 28 continuity errors (split 20, 3, 4 and 1 over four PIDs, exactly TSDuck's `continuity`
plugin on the same file), one TEI packet reads one transport error, and twenty unaligned 1,456-byte cuts
read 20 sync losses and 40 sync-byte errors. At P1, PCR-paced by `tsp` into `moq import ts` on a local
relay, the same counts are logged. Through `moq-srt`, fed by `srt-live-transmit` 1.5.6 from a pipe,
`ts_sync_loss` climbs from the first second, before any drop, to 900: that is the sender's zero-padding
of short reads, recorded under [#4581](https://github.com/moq-dev/moq/issues/4581) below, which the
counter now shows directly. Decode throughput, best of 20, is 1,091 MB/s before and 1,054–1,086 MB/s
after on the excerpt.

**On the merged build** (P1, the same rig and excerpt) the counts are unchanged: the clean feed logs
no line, the aligned drops read `continuity_count_error=28` twice, TEI on either PID reads
`transport_error=1`, and the SRT arm, whose padding is not deterministic, reads 906 sync losses and 29
continuity errors against 900 and 29.

**State:** merged, with the maintainer's fix for a `PTS_error` that kept growing on a PID a PMT
revision dropped. A resource point from review holds: every importer keeps continuity state, the last
payload packet included, for every non-null PID it sees, at most about 1.5 MB per importer, and
`Programs` does not cap how many importers the first PAT creates. Our two offered follow-ups (keep the
packet only for PIDs the PMT lists, or grade the all-PID checks once in `Programs`) have had no answer.

**Open.** An unsignalled forward PCR jump below the importer's 1 s step bound stretches the program
clock, so the PCR checks count the jump and any table or PTS the stretch makes late counts as well; the
tests assert this rather than hide it. Interval resolution is the PCR spacing. The counters stop at
ingest, which leaves egress grading to the wire monitor downstream. Nothing has run cross-host.

---

## 3. Resilience and redundancy

### The exporter died on session loss — closed

`moq export ts` exited the instant its session dropped — the single most consequential
transport-resilience gap for primary distribution, because a broadcast subscriber must ride out relay
maintenance unattended. The reconnect loop stayed alive; the sink task was fatal
([#2459](https://github.com/moq-dev/moq/issues/2459)). Closed by
[#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast *linger*): the relay keeps the broadcast
announced for the reconnect window and a re-attaching source splices back; a clean unannounce still
tears down immediately. Measured surviving relay kill and restart with byte-identical output.
[#2647](https://github.com/moq-dev/moq/pull/2647): re-attach within seconds of a relay returning; a
dead relay errors in tens of seconds — the axis for a supervisor deciding to re-home a subscriber.

### A cancelled write dropped bytes and said nothing — closed, in a different repository

Exporting over the WebSocket fallback transport produced a flood of `WrongSize` / `FrameTooLarge` group
evictions and then killed the process, while the identical broadcast over QUIC on the same path was
clean. Reported as [#2265](https://github.com/moq-dev/moq/issues/2265) as two defects rather than one.
The framing half root-caused in `web-transport`: `SendStream::write_buf` removed bytes from the
caller's buffer and *then* awaited queue capacity, so dropping that future stranded the chunk with no
error — the stream finishing cleanly **with a hole in the middle**
([moq-dev/web-transport#323](https://github.com/moq-dev/web-transport/pull/323)). Callers hit it
constantly because the publisher races `write_all` against a priority-change channel on every group
boundary while the outbound queue holds eight frames. **The trigger is egress backpressure, not
WebSocket.** The fallback transport is only where this rig was slow enough to see it, which matters for
§6 clients that abandon QUIC on a 200 ms timer. Both halves closed with that fix — with corrupt frames
gone there was nothing left to be fatal about — so the resilience half was never addressed on its own
terms; §2's audio work is the part that did land.

### Active/active source failover: shipped, bounded; three defects reported

**Report.** Two publishers announcing one broadcast to one relay tore each other down, and across a
mesh the pair never failed over: the relay offered a peer no route but the one it serves through.
[#2473](https://github.com/moq-dev/moq/pull/2473) (issue
[#2461](https://github.com/moq-dev/moq/issues/2461)) added per-peer selection excluding the
requesting peer, first-hop identity in SETUP and a declared pair, later the shared epoch;
[#2629](https://github.com/moq-dev/moq/pull/2629) extended it to draft 17 and later.

**Verification** ([T6](test-6-relay-resilience.md)), on builds with the shared epoch: on one relay
a hard kill fails over within the idle timeout; in the mesh, for the dead publisher's relay, bounded
by the later of detection and the standby's group lag.

**State, item by item:**

- **A graceful exit was not failed over** before #5967: completion propagated and the subscriber
  ended. [#2610](https://github.com/moq-dev/moq/issues/2610) specified a publisher-minted epoch plus
  `Ended`; since importers mint their own (#5967), a clean exit is a marked switch under 2 s.
- **[#4352](https://github.com/moq-dev/moq/issues/4352): a shared-hop standby that arrives after the
  subscribers ends them `not found`**, on one relay and in the mesh, because it refuses every track
  until it has parsed its PMT and the relay keeps the refusal. **Fixed by our
  [#5517](https://github.com/moq-dev/moq/pull/5517), merged**: an importer announces once its
  catalog lists the tracks, so the standby is never asked early; every exporter in a mesh runs on
  through it on `f13283b30`.
- **[#4354](https://github.com/moq-dev/moq/issues/4354): a switch to a same-hop standby ended
  `export ts` on a timestamp rewind**, with identical inputs too ([T51](test-51-same-epoch-groups.md)).
  **Closed by removing the shared importer epoch** ([#5967](https://github.com/moq-dev/moq/pull/5967),
  merged): each importer mints its own epoch, and a takeover is a marked programme switch. It
  reverted our shared clock and grid cuts ([#5625](https://github.com/moq-dev/moq/pull/5625),
  [#5894](https://github.com/moq-dev/moq/pull/5894), both merged), and
  [#5895](https://github.com/moq-dev/moq/pull/5895) (groups by the catalog clock) closed unmerged.
  A shared epoch stays only for replicas of one publisher's bytes. Measured in [T6](test-6-relay-resilience.md).
- **[#6062](https://github.com/moq-dev/moq/issues/6062): a relay lost under one importer resumes at
  a later group** on moq-lite 07, skipping 7.02 s of programme unflagged
  ([T6](test-6-relay-resilience.md)), where upstream documents a resume at the first frame lacked.
  **Fixed** by [#6183](https://github.com/moq-dev/moq/pull/6183) (merged): the dead relay's reset
  group no longer reads as a cut, and a resumed copy keeps the cached groups its max age (half the
  delay) holds. Not re-measured.

### A multi-programme TS through `import ts` — reported, and answered by programme selection

The importer scopes itself to single-programme input in a code comment, and a real MPTS shows what
that costs ([T10](test-10-mpts-multiservice.md)). On both builds the exporter flattens the multiplex
into one PAT entry and one PMT carrying every programme's streams, while the carried SDT and EIT still
list the other services. On `ffa5b81b` programmes on independent clocks abort the publisher with
*frame timestamp is below the live edge*. On `main` at `2b689c24` the same input completes with exit
0 and loses most of two programmes' video, and even on a common clock SCTE-35 and part of programme
1's audio are lost; programme 1 alone is clean. The ask is framed as "refuse an MPTS loudly, or select
one programme on purpose", not as MPTS support. Reported as
[#4353](https://github.com/moq-dev/moq/issues/4353). Bisected since: #3997 removed the refusal, and
#4122 introduced the common-clock loss; the bisect is on the issue. The measured mechanism is the
section lane through which every programme's video advances the section clock; a build that gives that
clock one lane per video PID removes every re-anchor and restores SCTE-35 and audio to the parent's
level (T10 § *On upstream `main`*). Upstream's planned default refusal of multi-programme input, and
its removal of the anchor, would each moot it; the A/B result is on the issue.

**The refusal has since landed, with selection**, in [#4505](https://github.com/moq-dev/moq/pull/4505)
(next entry). On `main` at `6f1a9e33` an unselected multiplex is refused with exit 1, and on the T10
rig every programme is carried on `mpts3.ts` and `mpts3-cc.ts` alike, independent clocks included, in
four of four runs (T10 § *The split on the T10 rig*). **Closed by us** as answered by #4505 and
#4580 ([comment](https://github.com/moq-dev/moq/issues/4353#issuecomment-6084813480)). What a
selected programme still carried of the other services is the next entry.

### A selected programme still carried the whole multiplex's SI — contributed as [#4580](https://github.com/moq-dev/moq/pull/4580), merged

**The defect.** [#4505](https://github.com/moq-dev/moq/pull/4505) answered the selection half of
[#4353](https://github.com/moq-dev/moq/issues/4353): `moq import ts --program <n>` imports one programme
of a multiplex, and `--program all` publishes each as its own broadcast. SI capture was left as it was,
so a selected programme's broadcast still carried the source's SDT actual and every service's EIT.
Measured on `main` at `6f1a9e33` with a three-service MPTS and `--program 1`, the `export ts` output
carries only programme 1's PIDs, yet `tsp -P analyze` counts three services, two of them with no PIDs,
and EIT present/following rides along for all three. A receiver scanning that stream finds two ghost
services.

**The contribution.** The upstream quest (`quest/m2/ts-program-si.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. Under an
explicit selection, the importer's SI capture drops EIT actual sub-tables for other service_ids and
rebuilds each SDT actual snapshot as one section holding only the selected service's entry, with a
fresh CRC-32/MPEG-2. NIT, BAT, SDT other, EIT other and TDT/TOT pass through.

**Verification**, P0 and P1. At P0, five in-process tests use a synthetic two-service multiplex whose
SDT spans two sections; four fail with the selection disabled. At P1, a 30 s PCR-paced build of T10's
`mpts3.ts` was run through `import ts --program <n>` on a local relay and captured from `export ts`: on
`main` `6f1a9e33` with `--program 1`, three services and three EIT present/following services; on the
#4580 branch, one service and one EIT for each selected programme (including one 59-byte SDT section for
programme 1 and one 38-byte section for programme 3). TSDuck decodes the rebuilt SDT; local
`just check`, the `test/ts` default, real-capture and open-GOP arms, and upstream CI passed. These
figures were measured on the PR before merge and have not been repeated on the merged build.

**Merged** into `main`. Review added CRC rejection for corrupt SDT sections and committing a selected
SDT revision only once every section has arrived.

**Open.** The `test/ts` `--pair` arm fails its NIT and SDT/BAT anchor checks on `main` at `6f1a9e33` and
on the branch alike: the grader attributes both exporters' emission points to a timer started with each
exporter rather than to the media. That arm is not in CI and has no quest. Nothing has run against a
live multi-programme feed or cross-host.

### A PSI table spanning packets, or one bad CRC, ended a TS ingest — contributed as [#4584](https://github.com/moq-dev/moq/pull/4584), merged

**The defect.** The importer read the PAT and PMT through the `mpeg2ts` 0.6.1 reader, which parses a
table from a single packet, rejects a nonzero `pointer_field`, and ends the import on any error. A valid
PMT too long for one packet, a PAT listing more than about 40 programmes, or one flipped bit in a PAT
repetition's CRC therefore ended `moq import ts`. `--program all` found the PAT in a single packet too.

**The contribution.** The upstream quest (`quest/m1/ts-psi-reassembly.md`, planned in
[#4507](https://github.com/moq-dev/moq/pull/4507)) settled the shape, and the PR follows it. The
importer owns the packet demux: the PAT and every PMT go through the section reassembler already used
for SCTE-35 and SI. A section whose CRC-32/MPEG-2 fails is dropped whole and the last good table stays
in force; each drop counts in a stream-wide `crc_error` in the importer's stats.

**Verification**, P0 and P1. At P0, tests cover a PMT spanning two packets, a PAT behind a nonzero
`pointer_field`, a fifty-programme PAT, and corrupt repetitions. `decode` throughput on
`kyrion_mpeg2av_ac3.ts` roughly doubled: from 876–894 MB/s on `main` at `6f1a9e33` to 1,780–1,815 MB/s
on the branch. At P1, the `test/ts` default, real-capture and open-GOP arms matched on both builds; one
bit flipped in the 20th PAT's CRC made the publisher on `main` exit after 0.5 s with *CRC32 mismatch*,
while the branch dropped one section and passed every check; a PMT padded to two packets imported on the
branch but `export ts` then failed on write length. Local `just check` and upstream CI passed. These
figures were measured on the PR before merge and have not been repeated on the merged build (including
the maintainer's change to `--program all`, which seeds each programme's importer with the assembled PAT
rather than replaying bytes).

**Merged** into `main`.

**Open.** The exporter still writes the PMT through `mpeg2ts`, which cannot emit a section longer than
one packet (*failed to write whole buffer*), so a long PMT now imports but does not round-trip. Sections
dropped for other reasons (a malformed adaptation field, a parse failure) are not counted yet, since the
TS import health quest owns `PAT_error` and `PMT_error`. Nothing has run against a live feed with long
PSI.

### Three values the exporter mints per process — two closed, one declined and since planned as an opt-in

A 1+1 pair cannot be byte-identical while the exporter renders anything from its own process state
rather than from the broadcast. Three such values were isolated ([T12](test-12-dual-path-handoff.md)):

- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video: measured at **0.00 %** frame agreement for SDT and NIT over a 45 s overlap. Fixed by
  [#2825](https://github.com/moq-dev/moq/pull/2825), which takes a single-track pair to 100 %. Its
  due check changed from `!=` to `>` before merging, worth 5.9 points of agreement (T12), so evidence
  measured only on a pre-merge PR is provisional. Its residual, the cadence's origin, is below.
- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %. Filed as
  [#2779](https://github.com/moq-dev/moq/issues/2779), and prototyped here: padding each span to a
  multiple of 16 packets takes the same pair from 0.4 % to 99.9 % on single-track content and from 24.6 %
  to 93.6 % on multi-track, at **10–18 kb/s per PID** almost regardless of payload. **Declined upstream.**
  [#3868](https://github.com/moq-dev/moq/pull/3868) closed the issue as won't-fix. **Byte-identical 1+1
  from two independent exporters is not obtainable from upstream today** without the padding filter or a
  receiver that merges on something other than the whole packet. **`export ts --sync`**, which
  restarts counters per group for legs of one broadcast, is our [#5949](https://github.com/moq-dev/moq/pull/5949), merged.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the earliest
  frame, so legs whose bytes arrive at different moments order the same media differently. Multi-track
  content therefore stops at 94–96 % even when co-started, and at **75.56 %** once the two chains are
  fully independent. Filed as [#2829](https://github.com/moq-dev/moq/issues/2829). **Fixed by
  [#4001](https://github.com/moq-dev/moq/pull/4001)** (§ *#2829 and #3948, closed by #4001*). Measured
  on fully independent chains across two availability zones: a single-track feed is byte-identical on
  all **46,778** shared datagrams; a seven-stream mux reaches **75.56 %**, with identical per-PID packet
  counts and **98.414 %** alignment once displacement is allowed (T12). The counter fix above was
  conditional on it.

### The residual #2825 left, and the measurement that can see it — contributed as [#3947](https://github.com/moq-dev/moq/pull/3947)

The maintainer asked for a measurement against a real stream, runnable on `test/smoke/` fixtures,
because the two late-join tests in [#2825](https://github.com/moq-dev/moq/pull/2825) compare two
exporters *inside one process* and are blind to anything keyed to process start.
`test/ts/table-anchor.py` plus `run.sh --pair` subscribes twice against one broadcast with the second
leg joining late; **agreement** is the PTS of the frame each table was emitted against, counted only
inside the media time the two captures share. **Merged.** On it, with the second leg 5 s in, PAT and
PMT read **97.58 %** and SDT/BAT **0.00 %**: both legs emit every 2.000 s, 0.261 s out of phase, a
timer started with the exporter rather than an anchor in the media. Filed as
[#3948](https://github.com/moq-dev/moq/issues/3948), fixed by
[#4001](https://github.com/moq-dev/moq/pull/4001): on the same gate SDT/BAT reads **90.91 %**
(§ *#2829 and #3948, closed by #4001*).

### A takeover livelock — closed

Cluster peer churn pinned every worker inside one poll: the relay stayed alive at 100 % CPU, serving
nothing, for hours. Fixed by [#2701](https://github.com/moq-dev/moq/pull/2701); the lesson, monitor
liveness rather than process existence, is [Architecture](../docs/architecture.md) §9.1.

### A failover drill — declined

[#2545](https://github.com/moq-dev/moq/pull/2545) (two relays, the idle timeout in the loop) was
**declined** as covered by unit tests; its insight landed as
[#2713](https://github.com/moq-dev/moq/pull/2713): reselection is decided per track.

### What a redundant pair must share — merged as [#5412](https://github.com/moq-dev/moq/pull/5412), its shared epoch since removed

A quest-only PR replacing `plan-ts-alignment`: a shared `--epoch` (refusals built as
[#5480](https://github.com/moq-dev/moq/pull/5480)); passthrough cuts on its grid; `--sync` legs whose
counters restart per group, released by clock recovery rather than wall time; and RTP legs that stay silent rather than send a datagram they cannot fill.
**Merged.** #5967 has since removed the shared importer epoch and its alignment (§ *Active/active
source failover*), so we closed our co-start test
[#5955](https://github.com/moq-dev/moq/pull/5955); #6554, merged, removed `--sync` (#5949).

### A restarted relay cannot reset its predecessor's connections — reported as [#5861](https://github.com/moq-dev/moq/issues/5861)

[T28](test-28-failure-injection-matrix.md) criterion 9: a killed relay cost the MoQ lane about
twice SRT's loss, because each relay process drew a random stateless-reset key, so its resets for
its predecessor's connections failed validation and clients waited out the idle timeout. Another
contributor's [#5910](https://github.com/moq-dev/moq/pull/5910) reads the key from a file
(`--listen-reset-secret`). After [our review](https://github.com/moq-dev/moq/pull/5910#issuecomment-6268205598)
its docs share a key only across one relay's restarts or a balancer routing by connection ID
(RFC 9000 §21.11). **Fixed by #5910, merged.** With the key kept, a restart costs 4.20 s of video,
not 14.16 s (P1-z).

### Where `--sync` legs place a group after a loss — asked as [#5864](https://github.com/moq-dev/moq/issues/5864)

[T50](test-50-deterministic-ts-legs.md): a leg that lost the group before one that overran its lane
laid it apart. Anchoring each group at its HRD's buffering period removed that, and is our
[#5949](https://github.com/moq-dev/moq/pull/5949). **Decided and closed: that anchor is the rule**
(quest `ts-hitless`), identity promised only where the stream carries a NAL HRD buffering period;
a packet plan declined, H.265 is `ts-hitless-h265`. #5949, merged, implements it. On a source
without one, a late leg's video differs from its partner's for up to 100 s:
[#6546](https://github.com/moq-dev/moq/issues/6546), closed with `--sync`'s removal.

---

## 4. Congestion control

The loss collapse this campaign measured under QUIC's default CUBIC was reported into the discussion on
[#2432](https://github.com/moq-dev/moq/pull/2432), which exposes
`--server/client-quic-congestion-control {loss|delay}`. Upstream has since made **BBRv1 the default on
quinn** ([#2468](https://github.com/moq-dev/moq/pull/2468)), with the defaults described as
backend-specific — quiche to BBRv2, and noq back to CUBIC because BBRv3 carries a subtract-overflow
panic under high loss ([noq #768](https://github.com/n0-computer/noq/issues/768)). The noq half is not
what the code does: from `fd4f5d82e` to `ffa5b81b` every backend resolves an unset controller to
`delay`, which on noq is BBRv3 ([method-notes](method-notes.md) § *The default congestion controller
changed to the one known to abort*). noq #768 closed with no fix linked, so
whether the noq a current build links still panics is not established here.

**Upstream methodology guidance, adopted here:** the one meaningful congestion-control test is
bufferbloat under a shaped bottleneck, not random loss — *"the best congestion control in the face of
random loss is zero congestion control"* — so the CUBIC-collapse result is about **loss-signal
interpretation**, not congestion-control quality. That is why [T8b](test-8b-congestion-control.md)
exists. The open question on #2432 — whether BBRv2 on quiche is a first-class supported choice for a
permanent fixed-rate trunk — is **unanswered**, and one under-provisioned condition is not enough to
press it.

### The subscriber dies under contention — reported, fixed on the media path, then on the catalog track

**Report.** [#3491](https://github.com/moq-dev/moq/issues/3491): `moq export ts` exits with `Error:
hang: moq error: old` when two subscribers pull separate broadcasts through one relay across a shared,
under-provisioned bottleneck. Competing flows cause it, not a steady shortfall, and every graded
capture has 0 continuity errors, so a monitor sees a conformant stream that simply stops
([T8b](test-8b-congestion-control.md)). The filing named no cause: a draft's attribution to
[#3271](https://github.com/moq-dev/moq/pull/3271) was withdrawn before filing, on the rules in
[`method-notes.md`](method-notes.md) §1.

**Fix.** [#3515](https://github.com/moq-dev/moq/pull/3515): a group's consumer reported it finished
when the producer had, not when its own read cursor had, so a group retention later aborted had already
been reported as ending cleanly. The container consumer now skips an evicted group. The catalog
consumer had no such skip and failed with `json: old` on `catalog.json`; reported as
[#3897](https://github.com/moq-dev/moq/issues/3897), closed by
[#3907](https://github.com/moq-dev/moq/pull/3907), which makes a snapshot consumer discard a group it
cannot finish (`Old`, `Evicted`, `Lagged`), in `moq-binary` too.

**Verification.** [T26](test-26-cross-host-fanout.md) put 450 subscriber sessions through cross-host
fan-out on a build with #3515, through episodes at 3–37 % of nominal delivery for 45 s, and none exited
with `Old` or any error. T8b's three-flow re-run, with a pre-fix control in the same session: 4 of 15
cells exited without either fix, 1 of 15 and 1 of 10 with #3515 alone, 0 of 10 with both. Since 0 of
10 is also the commonest outcome of an unchanged build at that rate, the weight rests on the
conjunction of the closed code path, upstream's regression tests and a control that still provokes the
defect.

**State:** closed. A second exit on the same track, when the publisher leaves, is in § *The liveness
exit*.

### The qlog loss trigger is computed backwards — fixed in quinn and in noq, released in neither

Both QUIC stacks the lane has run on label every declared loss in their qlog by the reordering
threshold, whichever rule fired. The trigger is computed as
`time_sent.saturating_duration_since(now) >= loss_delay`, which subtracts the present from the send
time, saturates to zero and is never true, so the `TimeThreshold` branch is dead. The line is identical
in `quinn-proto` 0.11.17 and on quinn's `main`, and in the noq fork (`noq-proto` 1.3.0). It cost the
campaign a published attribution that had to be withdrawn
([T28](test-28-failure-injection-matrix.md) § *Corrections*). The fix is reversing the operands.
**Reported** as [quinn-rs/quinn#2895](https://github.com/quinn-rs/quinn/issues/2895) and pointed to from
[n0-computer/noq#825](https://github.com/n0-computer/noq/issues/825).

**quinn: fixed on `main`** by [quinn-rs/quinn#2896](https://github.com/quinn-rs/quinn/pull/2896), with
a regression test that forces one loss by each rule and reads the trigger back from the qlog. The test
fails without the fix, with both losses labelled `ReorderingThreshold`, and passes with it. It is gated
on the `qlog` feature, which quinn's PR CI does not enable. No quinn release carries the fix yet:
`quinn-proto` 0.11.19 still carries the reversed operands, so 0.11.17 through 0.11.19 labels are still
unreliable.

**noq: fixed on `main`** by [n0-computer/noq#827](https://github.com/n0-computer/noq/pull/827). It has
the same fix, with the test adapted to noq's qlog factory and per-path statistics, and it fails and
passes the same way. noq's CI runs it, since its tests run with all features. No noq release carries it
yet: `noq-proto` 1.3.0 predates the merge, so `noq-proto` 1.2.0 and 1.3.0 labels are unreliable.

T28's attribution depends on neither, because it rests on the acknowledgement frames.

### QUIC settings for provisioned paths — proposed as [#5953](https://github.com/moq-dev/moq/issues/5953)

[T28](test-28-failure-injection-matrix.md)'s gaps to SRT trace to four QUIC defaults: a controller
that yields to random loss, reorder thresholds that declare overtaken packets lost, a probe backoff
that delays recovery after an outage, and the idle timeout. The issue proposes opt-in settings for
each, citing the measured effect of relaxing it. **Decided:** the probe timer re-arms when the peer
is heard again, by default (merged as our [#6178](https://github.com/moq-dev/moq/pull/6178)); declined on random-loss and
`netem`-reorder evidence, a rate-holding controller, exposed reorder thresholds and a profile. Closed.

---

## 5. Relay memory

The relay retained memory in proportion to content carried — ~27–31 MB/hour on a 9.3 Mbps channel —
bounded by neither documented cache control. Reported as
[#2745](https://github.com/moq-dev/moq/issues/2745) with a controlled GOP pair confirming causation
(at identical bitrate and content, doubling the group rate doubled the slope: +31.22 → +62.30 MB/h,
ratio 1.995 against 2.000).

**Root-caused upstream within a day, and the correction is partly against us**: it is `quinn-proto`
recycling one receive-stream state, with its assembler chunk heap, per stream the connection has ever
accepted — **not moq state at all**. And it **plateaus** once every slot is filled, at ~100 MB above
baseline per publisher connection, reached after ~10,000 ingested groups. Every leg we had measured
was shorter than that knee, so the original "linear, 650 MB/day" reading was a measurement-window
artefact ([method-notes](method-notes.md) §3). Confirmed afterwards: baseline +108 MB against +97 MB
predicted; per-slot cost 9.14 and 10.54 KiB against upstream's 9.9 KiB; ~8 MB/h past the knee; capping
streams cuts the ceiling only 3.3× for a 9.8× slot reduction because 20–30 MB is slot-independent.
**No released version of the QUIC library removes it**, so plan for the overhead.

[T8b](test-8b-congestion-control.md) C6 (14.006 h), offered on #2745, shows post-knee growth is **not**
noise: another ~100 MB toward baseline +200.5 MB (**2.03×** the slot ceiling), slope decaying from
+24.60 to +1.82 MB/h and still not flat at end. Pre-knee slope is flat across N = 0, 1, 2 and 4
subscribers; the four-subscriber leg reached baseline +108.1 MB at its knee and 189.5 MB at 4 h —
neither five times a per-connection cost nor materially above two connections. Posted as a data point
([comment `5367857020`](https://github.com/moq-dev/moq/issues/2745#issuecomment-5367857020)), not a
re-open: what changed is the constant a deployment budgets.

### The relay's plateau is confirmed at 24 h — and the publisher is the role that actually leaks

The question C6 could not close was whether the soft second term converges (+1.82 MB/h at 14 h).
[T21](test-21-permanence-soak.md)'s 24 h soak closes it: relay growth past warm-up follows a
**logarithm** (R²=0.9895 vs 0.9097 for a line), quarterly slopes halving — 9.85, 4.56, 2.42, 1.75 MB/h.
The run reaches baseline +242.6 MB at 24 h, past C6's +200.5 MB asymptote; log extrapolation ~519 MB at
a year. Posted on #2745 as a data point: the asymptote is extrapolated, not observed, and both legs
are single runs on one topology.

**The same run found growth that is not the relay's:** over 24 h the relay grew 243 MB and
**`moq import ts` grew 137 MB**, so end-point totals make the relay look worse when it is the better
process. The publisher fits a **line** (R²=0.9898 vs 0.8960 log / 0.9655 sqrt; quarterly slopes
2.36–2.87 MB/h; largest drawdown 9.2 MB) at +2.83 MB/h (~24 GB/year) — it ratchets rather than caching.
For permanent primary distribution the publisher is the process never meant to restart. **No upstream
issue describes publisher RSS over long runs** (#2745 and #3128 are relay-side).

[**#3493**](https://github.com/moq-dev/moq/issues/3493) — **closed** via
[#3793](https://github.com/moq-dev/moq/pull/3793) (`5d0991b9`). Re-soaks **`3493-check-2h`** and
**`3493-loop-2h`** invalidated when import hit [#3798](https://github.com/moq-dev/moq/issues/3798)
at ~600 s / ~631 s. On upstream `main` `9d2a4f6e`, 24 h re-soak `p0h-24h` confirms the fix: importer
slope +0.23 MB/h vs original +2.83 ([T21 § *The #3493
re-soak*](test-21-permanence-soak.md#the-3493-re-soak)). The report was **deliberately held** until
per-process attribution: RSS by command-line signature also matched the wrapper shell. A 6 h re-run
sampling each PID puts growth at **+2.91 MB/h in `moq import ts` itself** vs +2.83 by signature; the
issue carries fits, per-PID confirmation, and caveats (exporter +14.5 MB at 5 h; 6 h cannot read
relay shape).

---

## 5b. Authorization, entitlement and subscriber observability

The first three filings, each saying a design does not generalise, were **accepted in substance**
together and planned into quests by [#3619](https://github.com/moq-dev/moq/pull/3619).

### The mTLS identity never reaches the authorization decision — open, and conceded on every point

[#3603](https://github.com/moq-dev/moq/issues/3603) argued that a client certificate authenticates a
peer and is then discarded, so mTLS can only express unrestricted access. The reply granted all three
parts: the auth-proxy API on **`main`** **already** forwards the mTLS identity per connection so the auth
server can answer for it, and the default token path cannot because its cache is keyed per key. On scoping,
mTLS is what the maintainer uses for cluster sync, and per-identity scoping is preferred over a global
config option; on the startup warning the maintainer agreed the current approach is confusing and not good
security practice. **Closed by us as fixed** on `main` at `f8215bc47`, read from the code: a
certificate admits nothing on its own, its name, fingerprint, expiry and issuer reach the auth server,
and a client CA beside `--auth-public` is refused at startup
([comment](https://github.com/moq-dev/moq/issues/3603#issuecomment-6084812116)).

### The revalidation window — closed, and folded into a rethink of the whole auth line

[#3605](https://github.com/moq-dev/moq/issues/3605) reported that `max-age=0` and an omitted
`Cache-Control` silently disable revalidation permanently, and that the 2× revocation window is
undocumented outside the source. Closed as completed and absorbed into
[#3682](https://github.com/moq-dev/moq/pull/3682), which makes `moq auth serve` the reference auth
server: the behaviour was accepted as wrong, and the remedy replaces the surface rather than patching
it. Whether that closes the hazard is not yet checkable; T37 measured a component being redesigned.

### Token interoperability — [#6566](https://github.com/moq-dev/moq/issues/6566) and [#6567](https://github.com/moq-dev/moq/issues/6567) fixed, [moqx#786](https://github.com/openmoq/moqx/issues/786#issuecomment-6370364516) open, [moqxr#83](https://github.com/openmoq/moqxr/issues/83) a mode

[T53](test-53-token-interop.md), re-checked on each project's `main` before posting: `moq-relay`
refused on draft 18 an exact-path grant draft 16 admits, undocumented; `moq` printed a
MALFORMED_AUTH_TOKEN close (0x16) as `unknown code=22`; SIGHUP, which moqx v0.3.6's docs say
reloads, ends the process; `openmoq-publisher` exited when `moq-relay` refused PUBLISH. **State.**
#6566 fixed by [#6621](https://github.com/moq-dev/moq/pull/6621) (AUTH_OK carries the grant's
patterns), #6567 by [#6612](https://github.com/moq-dev/moq/pull/6612): on `66af72315` the exact
grant delivers on draft 18 and `moq` prints "malformed auth token". moqx#786 unanswered.
moqxr#83: the exit is `--publish-catalog`'s; without it v0.4.10 publishes on draft 18 and exits on
draft 16 ([reported back](https://github.com/openmoq/moqxr/issues/83#issuecomment-6398652913);
T53 § *Corrections*).

### Subscriber-reported health telemetry — accepted, re-planned as solicited viewer feedback; schema and reporters merged

[#3608](https://github.com/moq-dev/moq/issues/3608) was filed **as aspirational** because no control
plane in current use gives an origin this visibility. Upstream accepted it and planned it as hang
tracks ([#4510](https://github.com/moq-dev/moq/pull/4510), `quest/m1/stats/`). **A publisher
names one `stats` snapshot track in its catalog; a publisher that wants to hear from viewers solicits it
with an `echo: { path }` section, and each viewer then publishes one `.echo` broadcast under that path**
carrying, per rendition, what it received, decoded, played late and stalled on, with its transport
counters; a preflight run reports which media layer is broken. Reporting is opt-in, trust is the
token prefix, and **self-reports are never billing, authorization or route-selection input**; the relay
keeps aggregated histograms only.
**Contributed, [#5367](https://github.com/moq-dev/moq/pull/5367), merged**: a catalog entry names
its track apart from its key, so the snapshots can key by rendition and two broadcasts' same-named
tracks share one catalog; rebinding an export when a key's track changes is deferred to
[#5406](https://github.com/moq-dev/moq/pull/5406).

**The TS half was `quest/m2/ts-health-stats.md`**: `ts::stats`'s TR 101 290 counters and per-PID
liveness in both reports ([T39](test-39-cross-boundary-observability.md)).
[#5360](https://github.com/moq-dev/moq/issues/5360) asked for it and MSF carriage; MSF is parked.
**The maintainer [gave us](https://github.com/moq-dev/moq/pull/5643#issuecomment-6222787706) it and
`stats/rust`**, with the export's re-timing in its own section. On #5643, merged:
[#5848](https://github.com/moq-dev/moq/pull/5848), the CLI flags and sinks;
[#5849](https://github.com/moq-dev/moq/pull/5849), `mpegts` at both edges and `release` (drops,
trims, gaps, margin, offset, drift). **Contributed, merged**: [#6552](https://github.com/moq-dev/moq/pull/6552),
`import --echo-path`, a CLI publisher soliciting what `export --echo` reports (P1-l's gate);
[#6654](https://github.com/moq-dev/moq/pull/6654), the shared model that grades either report and names its observer.
**The relay's half, [#6791](https://github.com/moq-dev/moq/pull/6791), closed unmerged**: egress `lag`
histograms and `dropped` counters per broadcast, parked until moq-net exposes QUIC acknowledgments.

### Where the specification half of this belongs, and it is mostly not MSFTS

The upstream questline settles the *mechanism*. The open question is where the **convention** is written
down. **The working group has the same mechanism in MSF**: a catalog's `publishTracks` names tracks its
receiver publishes back, and draft-wilaw-moq-cmcd-event-timeline (individual, `-00`) carries CMCD v2
Event Mode reports over Event Timeline tracks named there. CMCD's vocabulary is a player's — buffer,
bitrate, play state, starvation and errors, per media type — with no key for container health, and the
draft enables only the keys it lists, so CMCD's custom keys are unavailable as written.
[wilaw/CMCD-over-MSF-event-timeline#4](https://github.com/wilaw/CMCD-over-MSF-event-timeline/issues/4)
asks for container health as its own Event Timeline type beside the CMCD track (or custom keys), with
[a concrete type](https://github.com/wilaw/CMCD-over-MSF-event-timeline/issues/4#issuecomment-6218256377)
whose fields are `ts::stats`'s (unanswered), and a
[comment on its #3](https://github.com/wilaw/CMCD-over-MSF-event-timeline/issues/3#issuecomment-6127631320)
supports reports tied to a track. MSFTS is the wrong home for almost all of it: subscriber
health applies identically to LOC, CMAF and `m2ts`, and MSFTS §4's disciplined scope list is the reason
not to fork the work into one packaging extension. **One paragraph does belong in MSFTS:** a generic telemetry convention cannot know
that transport-stream health needs TR 101 290 P1, PCR repetition and accuracy, and per-PID access-unit rate
— nor that **the standard P1 set does not detect the failures this carriage actually produces** (57 s
missing video with 0 continuity errors and PCR identical to the control
[T24](test-24-partial-media-plane-stall.md); #3533's signature of PSI, AC-3 and teletext continuing while
video stops). The `m2ts`-specific claim is per-PID access-unit observation *in addition to* P1 counters,
with the reporting mechanism out of scope — an Implementation Considerations paragraph pointing at the
separate quest work.

### BISS-CA over MoQ: the native mechanism answers access, not operator-blindness

Two vendors at IBC 2026 proposed BISS-CA on top of MoQ for conditional access. Assessed from the
specifications; **nothing about scrambling is measured here** — the Gate 2 pass table records "Not
exercised: nothing in the campaign scrambles" against its scrambled-packet rows. The question is whether
the platform operator must be unable to *see* the content. Admission works — eight refusing arms delivered
zero payload bytes ([T36](test-36-entitlement-enforcement.md)) — and the key estate scales
([T38](test-38-entitlement-estate.md)). But the relay terminates the session and sees plaintext, so the
native mechanism decides *who may subscribe*, not *who may comprehend*; the transport stream on UDP or
RTP into an IRD has no MoQ protection on its final hop. BISS-CA, in-content and receiver-terminated,
covers that gap.

**The decisive constraint is that BISS-CA forecloses the media-aware lane:** CISSA scrambles TS
payloads, so the demuxing importer cannot produce media tracks; it requires opaque carriage, which
`moq-dev` carries byte-transparently on `main` ([T48](test-48-passthrough-export.md)). **Verdict: do
not build it** unless a rights deal requires operator-blind carriage; MSFTS §10 already permits
BISS-CA on transparent carriage. The paper's statement is [`control-plane.md`](../docs/control-plane.md)
§7.3 and §9.

### FEC is a transport question, and the campaign's contribution to it is the comparison

Raised as a possible MSFTS topic; it is not one. FEC trades latency against loss below the object layer
and applies to every streaming format equally, so it belongs in the transport or QoS discussion. **MoQ
sheds whole groups**, so loss granularity is a GOP while FEC and ARQ recover partial damage. Measured:
impairments shed programme in group-sized units; the lane loses more picture than a 5 s outage lasted in
all but one cell ([T28](test-28-failure-injection-matrix.md),
[T31](test-31-congestion-capacity-ladders.md)). **FEC and the relay's latency budget compete for the same
milliseconds**, and any proposal must be scored against raising `--latency-max` and against SRT ARQ at an
equivalent budget (2000 ms spanning ~100 RTT at 18.6 ms RTT here is heuristic, not an SRT property).

**The matched SRT arm has been run** ([T28](test-28-failure-injection-matrix.md) § *The matched ladder*;
[`evidence.md`](evidence.md) *Matched against SRT, and graded on content*). At measurement
point P1, on a single host at 20 Mb/s and 100 ms RTT, build `53f8aa99d`, SRT's `--latency` was set to the
MoQ lane's measured median at each budget. Unimpaired, both grade 0.000 s lost. **Graded on content, SRT
loses less programme than the media-aware lane under every impairment shape run** — under a 5 s outage, MoQ
loses roughly three to four times the video duration SRT loses at every `--max-age`, while MoQ delivery
latency rises with the allowance and is not bounded by it. How much MoQ loses depends on build and QUIC
stack; continuity-error counts must not rank the lanes because the MoQ exporter re-synthesises counters.
MoQ-only ladder non-monotonicity remains *likely rather than established* at one sample per cell. **Venue:
IETF MoQ list first** (`moq@ietf.org`); position in `lab/discussions/fec-arq-venue.local.md`. **A list
message can now open with the measured MoQ-versus-SRT table and its qualifications.**

## 5c. The TS export's schedule and lifecycle, and import robustness

Every fix below that is described as on `main` is in no release yet: moq-cli 0.14.3 and moq-relay
0.17.3 were cut from the `release` branch without them.

### The determinism measurement, posted to #2829

The head-to-head pair comparison was posted on [#2829](https://github.com/moq-dev/moq/issues/2829): two
`moq export ts` processes of one broadcast share **4.97 %** of packets over 50,000; 94.02 % differ in
continuity counter and 27.93 % in the interleave ([T13](test-13-downstream-grooming.md) § *The
head-to-head*).

It accepts [#2779](https://github.com/moq-dev/moq/issues/2779)'s closure as won't-fix in
[#3868](https://github.com/moq-dev/moq/pull/3868): with the counter out of scope upstream,
renumbering must happen downstream, and a downstream filter is capped by the interleave — 100.00 %
on single-track with the counter masked against 94.09 % on the real multi-track feed. #4001 has since fixed the interleave;
the byte schedule remains ([method-notes](method-notes.md) §6).

### The byte schedule — a successor to #3334, not a reopen of it

Filed as [**#3925**](https://github.com/moq-dev/moq/issues/3925): conformant egress, a deterministic 1+1
pair and [#3923](https://github.com/moq-dev/moq/issues/3923)'s sink all wait on it. **The care needed was
not to read as regression:** [#3334](https://github.com/moq-dev/moq/issues/3334) and
[#3351](https://github.com/moq-dev/moq/pull/3351) genuinely fixed adjacency (50.31 % → 0 % adjacent PCR;
491/799 → 0–4/745 releases outside ±10 ms) ([T19](test-19-pcr-grid-verification.md) meas. 9–10). What
#3925 reports is the **next property #3351 does not grade: not-adjacent is not evenly spaced.** On
`53f8aa99d`, PCR values are exact at 25.00 ms (0/6,173 over 40 ms P1) and aggregate rate is within 0.21 %,
while bytes between consecutive PCRs run 188 B to 870,628 B (median **1,316 B**, 4.2 % of mean); only
**3.3 %** of intervals carry an instantaneous rate within 1 % of nominal
([T13](test-13-downstream-grooming.md) § *The residual measured*).

**The grader is [#4493](https://github.com/moq-dev/moq/pull/4493)**, merged as `18d7c2530` (`test(ts)` only).
It adds `pcr-schedule` to `test/ts/pcr-timing.py` — bytes between consecutive PCRs on one PID, never
pooled, against `--mux-rate`, tolerance ±1 % or one packet — report-only unless `--schedule-pct-min` is set.
Verified on upstream `main` `9d2a4f6e9`, file domain, harness loopback: `moq export ts` of the real news cut
returns **3.09 %** of intervals within tolerance (exit 1 at `--schedule-pct-min 99`) and median **1,316 /
31,081 B**, reproducing the T13 residual while the source clip grades 100 % (30,644 / 30,644 B). The
harness's generated `ffmpeg -muxrate` clip grades 100 % (25,004 / 25,004 B) and its export 92–97 % over
three 20 s runs (31,208 / 31,250 B), because that fixture is mostly padding.

**Closed:** [#3925](https://github.com/moq-dev/moq/issues/3925), by us, as answered by #4645's PCR grid:
on `f8215bc47` over 35 min every PCR checked is within ±481 ns of its byte position
([comment](https://github.com/moq-dev/moq/issues/3925#issuecomment-6084812727)). Still ours: a burst
fixture for the recipe gate; unpadded export start; and `pcr-value-interval` pooling across PIDs.

### The byte schedule itself — contributed as [#4579](https://github.com/moq-dev/moq/pull/4579), overtaken by the maintainer's fixed-delay export

**Report.** #3925's defect: with a mux rate, the export padded to the right average but heaped each
keyframe between two PCRs, so a receiver clocking off arrival could not lock.

**Contributed.** The byte-schedule quest: closed spans queue in a backlog, and every 25 ms slot emits
its PCR, media up to the rate, then nulls, so a PCR's value follows its byte position. Verified on the
loopback harness against `main` `6f1a9e33`, on a 60 s cut of the reference clip at 11 Mb/s: PCR
intervals within ±1 % rose from **3.27 %** to **75.3 %** (**99.1 %** with `--max-age 1s`), T-STD TB
overflows fell from 384,910 to 90,150, at 500–706 ms of added delay; on the generated clip, from
34.5 % to 93.5 %.

**State.** Closed by its author for [#4645](https://github.com/moq-dev/moq/pull/4645), merged, which
paces a constant-rate schedule against a fixed `--delay` instead; #4579's closing comment keeps these
figures as the before-state.

### T-STD conformance of the TS export — taken up upstream, and merged as the fixed-delay export, which carries every track of a broadcast clip with its clock in tolerance

**Report.** [T44](test-44-tstd-grading.md) found the lane's P1/P2-conformant wire fails 13818-1
T-STD on its packet order, and [T45](test-45-live-tstd-remux.md) that a live re-multiplexer repairs
it on one host. With the MSFTS co-author's review of transmux carriage, that moved the maintainer to
treat a TS export as a remux with a fixed delay: the plan in `quest/m1/tstd/`
([#4637](https://github.com/moq-dev/moq/pull/4637): a fixed-delay release stage, a full T-STD check
in `test/ts/compliance.py`, PCRs on the mux-rate byte grid) and its implementation,
[#4645](https://github.com/moq-dev/moq/pull/4645), each of whose heads
[T47](test-47-fixed-delay-export.md) graded. What the campaign contributed to it:

- **The check's defects.** Upstream's check ([#4643](https://github.com/moq-dev/moq/pull/4643),
  reaching `main` with [#4640](https://github.com/moq-dev/moq/pull/4640)) and
  [`ts-tstd.py`](scripts/ts-tstd.py) were cross-validated on 35 files
  ([T46](test-46-tstd-check-cross-validation.md)). Four defects in upstream's, two of which fail
  clean streams, were [reported on #4640](https://github.com/moq-dev/moq/pull/4640#issuecomment-5938368125)
  with clause references: TB-to-B delivery by whole packet, floating-point drift in the AVC leak,
  units after the last packet left unassessed, and a truncated last unit graded as underflow. All
  four were fixed before the merge, after which the two agree on all 35 files.
- **The anchor.** On `559a35244` acquisition and steering both took the most slack across tracks,
  which on a TS source is video sent up to 0.97 s ahead, so most joins dropped every audio and
  teletext frame as late. Our late-track test and fix (anchor and steer on the track sent latest,
  waiting for every catalog track) were cherry-picked into `fe7cec106` with authorship.
- **Mocked-time export tests** on the t0ms fork (join skip, mid-stream skip, a drifting source
  clock, 1+1 identity), which found why a 1+1 pair diverged: slot fractions and skips counted per
  receiver, and no tie-break on equal decode times, which the merged head breaks by PID.
- **A `--linger` misread** that ended the export within 7 s of a join, gone before the merge; the
  CLI half is #4947 (§ *The liveness exit, implemented*).

**Verified on the merged export** (T47, loopback, across hosts, 0 % and 1 % loss, 500 ms to 1 s):
every track on every join tried, and a co-started 1+1 pair byte-identical through the groomer, the
only difference with counters rewritten being where each places a TDT revision
([T13](test-13-downstream-grooming.md#on-4645s-pcr-grid-the-deterministic-mode-runs-and-a-co-started-pair-merges-at-the-byte)).
At 10 % loss the video is lost to group eviction, which is `main`'s and not the export's.

**TS passthrough.** We proposed passthrough and clock-recovery quests in
[#4670](https://github.com/moq-dev/moq/pull/4670); the maintainer merged passthrough and folded clock
recovery into #4645. The import is ours, [#5003](https://github.com/moq-dev/moq/pull/5003), merged
after the maintainer's rework rule: a flagged forward PCR jump carries into the timestamps behind a
break marker, and any step back ends the import. Its relay test is byte-identical from the first
group through a flagged 20 s jump and fails without the marker. The export half, graded in
[T48](test-48-passthrough-export.md), merged as [#5349](https://github.com/moq-dev/moq/pull/5349);
under 10 % loss its drop count reads 0 across 99 gaps, because the groups the relay evicts never reach
the deadline check. `ts-passthrough-export` stays open under the acceptance
[#5327](https://github.com/moq-dev/moq/pull/5327) set: the T-STD verdict and release schedule in CI,
wider fixtures and counted group omissions.

**The system buffers.** `tstd/psi-runs` is our merged [#5606](https://github.com/moq-dev/moq/pull/5606):
padded export paces its tables against Bsys too, and `compliance.py` grades both system buffers,
hard, along each program's PAT and PMT timeline.
Before, eight aligned video PIDs' tune-in tables peak at 2,767 B in Bsys's 1,536; after, every TS
arm passes, and a DVB replay matches `main`'s video lead and buffer peaks.

**Open:** where TDT/TOT revisions are placed, which decides a late-joining 1+1 pair; release-clock
statistics that count neither a skipped group nor an absent track, and an `out_of_tolerance` count
that climbs through every start; and the join-dependent latency at 500 ms, which on `f8215bc47` is
whether the clock anchors on AC-3 ([T47](test-47-fixed-delay-export.md) conclusion 20;
[reported on #4645](https://github.com/moq-dev/moq/pull/4645#issuecomment-6083705934)). Detail lives in T44–T48,
measurement points in [`evidence.md`](evidence.md) §3.16.

### A UDP sink for `export ts` — declined; RTP legs for ST 2022-7, [#6304](https://github.com/moq-dev/moq/pull/6304), closed with `--sync`

**Report.** [#1839](https://github.com/moq-dev/moq/issues/1839) (an egress layer) and
[#3923](https://github.com/moq-dev/moq/issues/3923) (a `--udp` sink) were closed not planned: `tsp`
does the socket work. RTP for a 2022-7 pair was the exception argued: a per-process packetizer
numbers the datagrams it sent, so a late join or a restart shifts one leg's numbers.

**Contributed.** `export ts --sync --rtp udp://HOST:PORT`: RFC 2250 datagrams on the slot grid,
numbered by timeline position, withholding any the leg cannot vouch for. Legs joined apart or losing
complementary groups sent byte-identical datagrams; four tests fail without the withholding.

**State.** Closed unmerged: [#6554](https://github.com/moq-dev/moq/pull/6554), merged, removed
`--sync`, which the legs need. In-process RTP would be passthrough only, numbered by source packet
position, scoped against a named receiver.

### Four closed as completed by a planning document that changed no code

[#3987](https://github.com/moq-dev/moq/pull/3987), quest files only, closed
[#3798](https://github.com/moq-dev/moq/issues/3798), [#3925](https://github.com/moq-dev/moq/issues/3925),
[#3926](https://github.com/moq-dev/moq/issues/3926) and [#3731](https://github.com/moq-dev/moq/issues/3731);
each defect was intact on `ffa5b81b`. Since, #3731 reopened as `quest/m3/msfts-convergence.md`, with T11c's discovery result
[posted](https://github.com/moq-dev/moq/issues/3731#issuecomment-6223909800). Method rule:
[`method-notes.md`](method-notes.md) § *A closed issue is a claim about a tracker, not about a binary*.

### #2829 and #3948, closed by #4001 — real code, and verified

[#2829](https://github.com/moq-dev/moq/issues/2829) and
[#3948](https://github.com/moq-dev/moq/issues/3948) closed via
[#4001](https://github.com/moq-dev/moq/pull/4001) (`66440a6c`), which changes the exporter: the
earliest pending frame waits, bounded by `max_age`, until every other track has shown it cannot
precede it, and unchanged SI repeats are floored on the media-time grid. Verified against `84b34f54`, two replicates each, raw exporter output ([T12](test-12-dual-path-handoff.md) §
*After the media-time interleave*):

| Issue | `84b34f54` | `66440a6c` | Verdict |
|---|---|---|---|
| #2829 — interleave by arrival | 98.33 %, 98.90 % of cross-PID adjacent pairs in the same order | **100.00 %, 100.00 %** | **fixed** |
| #3948 — SI phase set by exporter start | SDT 0.00 %, NIT 0.00 % | **SDT 91.67 %, 95.65 %**; NIT 66.67 %, 80.00 % | **fixed for the repeats**; the late leg adds one or two emissions of each table |

Residue outside both issues: TDT/TOT off-grid; one–two PCR-only packets per 40 s between legs
(24.7–24.9 % groomed slots identical); CC per process
([#2779](https://github.com/moq-dev/moq/issues/2779) abandoned). Byte-identical pairs now wait on
[#3925](https://github.com/moq-dev/moq/issues/3925) /
[#4645](https://github.com/moq-dev/moq/pull/4645), not interleave.

**#4001 costs the subscriber most of its delivery under random loss.** At 10 % uniform loss with no
rate cap, a subscriber built at #4001 delivers 0.49–0.67 Mb/s where its parent `044ca571` delivers
10.40 Mb/s, on either congestion controller and against either relay; at 0 % loss the builds are
indistinguishable ([T8b](test-8b-congestion-control.md) § *C7*). It was still present on `main` at
`6f1a9e33`, at 15–18 % of its 0 % control. **Reported as [#4613](https://github.com/moq-dev/moq/issues/4613),
fixed by our [#4618](https://github.com/moq-dev/moq/pull/4618), merged as `e488e699`.** Each source skip
under loss is a rewind, and `rewind()` renewed the hold's full `max_age` budget, so the next stall
skipped again. An instrumented build of `main` at `5124f8134` with only the hold varied gives 1.13 Mb/s
at 10 % loss as it stands, 9.80 with the hold disabled and 8.37 with it capped at 200 ms; the PR before
merge gives 9.70 and 9.87 at 10 % loss, and 9.84 at 0 % against 9.85 unfixed. The merged commit also
clears the stall in `resume()`, which the measured arms predate. **Those rates are egress, which the
export pads:** graded on content, the merged build (`83ce47fe`) carries 8.0 % and 2.6 % of the video at
10 % loss, as little as the standing `84b34f54` (2.7 %), so the fix ends the exporter's stall but not
the loss #4613 reports ([T8b](test-8b-congestion-control.md) § *C7*). **Corrected on #4613**
([comment](https://github.com/moq-dev/moq/issues/4613#issuecomment-6131858696)), offering a fresh
issue for the loss.

### The video DTS reserve froze at the PMT — contributed as [#4500](https://github.com/moq-dev/moq/pull/4500), merged and verified on `main`

**The defect.** `moq export ts` sized each video rendition's decode-clock reserve from catalog
`jitter` only until the PMT; without `jitter`, a 16-tick fallback held for the whole run, so two
legs of one broadcast could run different DTS and PCR values and B-frames on the fallback decoded
after presentation. Since #4001, mux order is interleaved regardless; the reserve affects DTS and
PCR values only.

**The contribution.** After the PMT, the reserve follows `jitter` and `framerate`, or without
`jitter` the SPS reorder depth times frame period at a fixed rate, grow-only to 2 s. Observed
reordering can exceed declared depth (IBBP declares 1, lands 2; 25i declares 120 ms, lands 240 ms).
One tick per frame decoded since the high-water frame covers x264 B-pyramid.

**Before and after**, PR before merge, P1, two `export ts` legs on one relay (second joining 10–20 s
in), `main` at `9d2a4f6e` vs PR:

| Source | `main` | PR |
|---|---|---|
| x264 B-pyramid over FLV: no `jitter`, no fixed frame rate | Both legs stay on 16 ticks; 347 of 672 and 233 of 455 frames decode after their PTS | Both legs settle at 10,802 ticks within the first group; 4 late frames per leg before that; joiner matches runner; shared PCR intervals identical with CC masked |
| 25i broadcast H.264 over TS: `jitter` in catalog before tables | 0 late frames; 36,000 ticks both legs | The same |

Neither build's TS legs are byte-identical (null slot placement — #3925; CC per process — #3868).

**After merge** (`7efe9b5ea`), P1, `main` at `6f1a9e33`: [T10](test-10-mpts-multiservice.md) 25i
programme captures show 4 late frames of 2,063 (access units 2–5), reserve rising 16 → 36,000 ticks
in the first group; programme 2 video has 0 late of 1,468. Since
[#4574](https://github.com/moq-dev/moq/pull/4574), a growing reserve flags PCR discontinuity.
**Open:** no live source publishes `jitter` after the tables (unit test only); x264/FLV paths
without published `framerate` leave a late joiner differing until deepest reordering is muxed; FLV
export reserve unchanged.

### The liveness exit, implemented — contributed as [#4504](https://github.com/moq-dev/moq/pull/4504), merged and verified on `main`

**Report.** [#3926](https://github.com/moq-dev/moq/issues/3926) asked whether `export ts`'s exit on
a dead publisher (`Error: json: dropped`, nothing recovered from a restart) was intended, and for a
clean exit on "publisher gone" distinct from an error, so a supervisor could tell them apart. The
same exit on the subscriber's own session loss is by design since
[#2704](https://github.com/moq-dev/moq/pull/2704) removed linger
([T28](test-28-failure-injection-matrix.md), [T6](test-6-relay-resilience.md)). **Contributed:**
`export ts --linger <duration>` (default `0s`), for `quest/m1/export-linger.md`. Any end of the
broadcast waits for its path to return; the resume keeps the PIDs, flags the PCR discontinuity and
re-sends PAT and PMT; the exit code is the last end's, 0 for a clean end and 1 for a drop.

**Verified** on `main` at `6f1a9e33`: `--linger` carries the
exporter across a clean end, a `SIGKILL` and a relay restart, with the exit codes as specified,
which closed #3926 ([T13](test-13-downstream-grooming.md) § *Liveness*).

**Follow-ups:**

| Item | Defect | State |
|---|---|---|
| [#4767](https://github.com/moq-dev/moq/issues/4767) | a resume flagged the discontinuity up to four times | closed against [#4845](https://github.com/moq-dev/moq/pull/4845); `main` flags each resume once since #4645 |
| [#4945](https://github.com/moq-dev/moq/issues/4945) | after [#4741](https://github.com/moq-dev/moq/pull/4741), the relay handed a replacement publisher the killed session's subscriptions before it published | split into [#4942](https://github.com/moq-dev/moq/pull/4942)'s publisher epochs and [#4915](https://github.com/moq-dev/moq/pull/4915); with both merged, 4 of 4 runs on `moq-lite-07` resume 8 of 8 crashes continuity-clean |
| [#5052](https://github.com/moq-dev/moq/issues/5052) | a re-request onto a live route died on its first late video unit | fixed by our [#5109](https://github.com/moq-dev/moq/pull/5109) and, for epochless tracks, by `broadcast-epoch/no-stitch` ([#5108](https://github.com/moq-dev/moq/pull/5108), [#5137](https://github.com/moq-dev/moq/pull/5137), [#5147](https://github.com/moq-dev/moq/pull/5147)); verified in [T47](test-47-fixed-delay-export.md) |
| [#6802](https://github.com/moq-dev/moq/issues/6802) | under `--follow`, a hard kill's eviction ended an export on a missed decode deadline, 3 of 13 runs ([T56](test-56-media-aware-failover.md)) | fixed by [#6873](https://github.com/moq-dev/moq/pull/6873); not re-measured |
| [#6877](https://github.com/moq-dev/moq/issues/6877) | a standby's arrival pre-empts the serving leg; a switch empties the follower's delay ([T56](test-56-media-aware-failover.md), [T58](test-58-receiver-select.md)) | standby ask declined; delay kept since [#6919](https://github.com/moq-dev/moq/pull/6919), its return to `--delay` in [#7049](https://github.com/moq-dev/moq/pull/7049); not re-measured |
| [#4947](https://github.com/moq-dev/moq/pull/4947), ours | a failed export lingered as though its broadcast had ended | merged (`1ec21ac23`): it lingers only if the broadcast closes within 1 s; crash-replace runs end 1.04 s after the failure, against 60.04 s |
| [#5328](https://github.com/moq-dev/moq/pull/5328#issuecomment-6123559371)'s same-instance resume | measured for its quest | closed with [#5545](https://github.com/moq-dev/moq/pull/5545)'s tests; the named CLI test passes 40 of 40 on `90500867d` |

[#5347](https://github.com/moq-dev/moq/issues/5347): in 1 of 4 `moq-lite-06` crash runs under
`--stitch`, the relay's `Error::Dropped` went out as `Internal` and the follower took it for a
refusal. **Closed** by the maintainer's [#5729](https://github.com/moq-dev/moq/pull/5729): a lost
route now ends `Unroutable` and the follower no longer matches errors; not re-run. A crash under a fresh epoch
is followed only under `--stitch`; the fMP4 and MKV exporters have no linger; only the exit code,
not the error text, tells a crash from a clean end.

### A PMT longer than one packet ended the export — reported as [#5110](https://github.com/moq-dev/moq/issues/5110), fixed by [#5220](https://github.com/moq-dev/moq/pull/5220)

`mpeg2ts` serialised the rebuilt PMT into one packet, so a playout recording with eleven AC-3
services (a 391-byte section over three packets) was imported whole and exported not at all on
`f8215bc47` ([T45](test-45-live-tstd-remux.md)). #5220 writes it whole
([reported on the PR](https://github.com/moq-dev/moq/pull/5220#issuecomment-6114047794)), verified on
`main` at `90500867d` on the same recording. **Closed.**

### Video overran its transport buffer where the multiplex outran its Rx — reported as [#5142](https://github.com/moq-dev/moq/issues/5142), fixed by [#5207](https://github.com/moq-dev/moq/pull/5207) and [#5306](https://github.com/moq-dev/moq/pull/5306)

`Slot::layout` spaced each PID by its own count, so PIDs with equal counts coincided and video ran
back to back between them: a unit test of one full slot of a 25 Mb/s broadcast peaked video TB at
1,067 B on `f8215bc47`, against 459 B for the same packets in smooth weighted round-robin
([T45](test-45-live-tstd-remux.md)). #5207 interleaves each slot, with our test as the regression;
the residue at the slot's edges, program tables written twice ahead of a capped video lane, was
[reported on #5304](https://github.com/moq-dev/moq/pull/5304#issuecomment-6125008012) and removed by
#5306's planner. On `main` with #5306 (`0d9e9ff78`) the 110 s cut overruns neither video nor system
TB. **Closed.**

### #3798's plan asks for a reproduction, and the campaign has one — plus a correction to its scope

Quest #3798 names three triggers and reproduces none of them in-tree. Its claim that
`LegacyStream::reanchor` is set only once, so that a second unflagged loop wrap lands below the
live edge again, is what decides between a cumulative and a one-shot fix.
[T41](test-41-import-reanchor-coverage.md) confirms it: H.264 aborts on wrap **1.00** and legacy
audio on wrap **1.98**, so the offset must grow with each wrap. **It also corrects the quest's
scope.** AC-3 fails at the same 1.98 as MPEG-1 Layer II because `DolbyDigitalUpToSixChannelAudio`
goes through `legacy_stream`, which the tree documents as covering MP2, AC-3 and E-AC-3; the
dividing line is the stream type, not the codec. Both points were posted to #3798 with the fixture
recipe.

**State: moot.** Since #4543 every unflagged wrap ends the import by design, on every stream kind
(`83ce47fe`, [T41](test-41-import-reanchor-coverage.md)). The exit-code baseline for #3926 went to
that issue the same way: its plan specifies 0 for a clean end and 1 for a drop, and the build of the
time exited **1 in both cases, including when the publisher itself exited 0**.

### A loop wrap moved audio against video — contributed as [#4513](https://github.com/moq-dev/moq/pull/4513), closed in favour of [#4543](https://github.com/moq-dev/moq/pull/4543)

**The defect.** #3997 let each elementary stream grow its own shift at each unflagged wrap; audio
and video tails differ, so A-V drift grows every pass (quest estimated ~12 ms; byte-cut loop
measures far more). Visible where the importer publishes source timestamps (SRT gateway; all
importers once `remove-live` lands). `import ts` live mode re-anchors one offset — drift already
under one 90 kHz tick.

**[#4513](https://github.com/moq-dev/moq/pull/4513):** one shift per importer, PCR-bounded hold;
fails on `main` at 6.7 → 138.7 ms over four passes (6.7 ms source).

**Before and after** `[unmerged]`, P1, co-resident: first 100,000 packets of `contrib-5m.ts` looped 56
s, `main` at `6a016409` vs PR:

| Pass | `main`, `import srt`: AC-3 | MP2 | PR both codecs |
|---|---|---|---|
| 1 | 448 ms | 832 ms | 0.000 ms |
| 2 | 776 ms | beyond ±1 s | 0.000 ms |
| 3 | 984 ms | beyond ±1 s | 0.000 ms |

`import ts`: constant 0.000 ms (MP2) or one tick (AC-3) every pass.

**Superseded by [#4543](https://github.com/moq-dev/moq/pull/4543)**, which landed on the `dev` line
that became `main`: the importer publishes verbatim timestamps and **ends on any
rewind**, while a flagged forward discontinuity still publishes. The drift table is the record
against the pre-flip `main`.

**What #4543 does instead**, P1, co-resident: the `dev` line at `9a80e875` (since become `main`)
against the pre-flip `main` at `6a016409`; [T23](test-23-pcr-discontinuity-classes.md) arms from
`contrib-10m.ts`, event at 30 s, 60 s PCR-paced. The `--linger` column cherry-picks #4504.

| Stimulus at 30 s | Pipe `import ts` | SRT `export ts` | SRT `--linger 10s` |
|---|---|---|---|
| A: 1 s back, flagged | import exit 1 | subscriber exit 1; caller redials | resumes, 1.38 s / 1.14 s stalls |
| E: encoder restart, flagged | import exit 1 | as A | 1.46 s stall one run; other run no catalog in 10 s → exit 1 |
| C: 30 s forward, flagged | full window | parse failures below | full window; 0.45 s stall |
| F: control | full window | full window | full window |

Error: *frame timestamp is below the previous group's start*. Over SRT, redial with `--linger` costs 1.1–1.5 s in four of five A and E runs,
and without it the whole feed. One E run that did not resume was not reproduced; `srt-live-transmit`'s
zero-fill is a candidate ([method-notes](method-notes.md#2-instruments-and-reading-what-they-tell-you)).

**State.** A TS rewind, flagged or not, ends the importer: republishing inside it
([#4582](https://github.com/moq-dev/moq/issues/4582)) was closed as not planned, for a supervisor
publishing a new broadcast under a new epoch ([T41](test-41-import-reanchor-coverage.md) § *A
flagged rewind carried as a new broadcast*). A co-started 1+1 pair stayed byte-identical across it
in 8 of 13 runs; the other five, reported as [#5101](https://github.com/moq-dev/moq/issues/5101),
were closed as not planned: identity across a republish is not a goal. The export ends on a
replacement unless `--stitch` asks for a full program switch. In
[#7102](https://github.com/moq-dev/moq/issues/7102) a real contribution switching encodes unflagged
ended both legs at once ([T34](test-34-real-encoder-severity.md); our synthetic reproducer,
[T64](test-64-synthetic-encoder-switch.md), [posted](https://github.com/moq-dev/moq/issues/7102#issuecomment-6496334839)); upstream tolerates it: the
export re-acquires the clock ([#7165](https://github.com/moq-dev/moq/pull/7165), merged) and the
import restarts under a fresh epoch
([#7144](https://github.com/moq-dev/moq/pull/7144), merged, closing it).

### One malformed packet ends a TS ingest — reported as [#4581](https://github.com/moq-dev/moq/issues/4581), fixed by [#4733](https://github.com/moq-dev/moq/pull/4733), merged

**The defect.** `import ts` and the SRT gateway end the whole ingest on the first unparseable
packet; `transport_error_indicator` drops are already correct.

**Measured** on the `dev` line and on the pre-flip `main`, P1, co-resident pipe, 72 s
`contrib-10m.ts`, one damage at 20 s:

| Damage | `dev` @ `9a80e875` | `main` @ `6a016409` |
|---|---|---|
| Video PES header/timestamp zeroed, TEI clear | exit 1 *Unexpected marker bits* | same |
| H.264 NAL `forbidden_zero_bit` set | exit 1 | same |
| Same PES damage, TEI set | carries on | carries on |
| ~24 seven-packet continuity gaps | carries on | carries on |

SRT parse storms traced to **`srt-live-transmit` zero-padding short reads**
([srt#3388](https://github.com/Haivision/srt/issues/3388)/[#3389](https://github.com/Haivision/srt/pull/3389),
merged unreleased —
[method-notes](method-notes.md#2-instruments-and-reading-what-they-tell-you)).
Pipe arms isolate the importer defect.

**The fix, [#4733](https://github.com/moq-dev/moq/pull/4733), measured on its head `aae930a23`:** it
refuses a damaged PES, adaptation field or access unit whole, clears the PID and resumes video at the
next keyframe. On the same pipe rig the PES and NAL arms run the full 60 s with one `dropped a damaged
TS unit` line, against exit 1 on the base `764b2868b`; TEI and twenty aligned 7-packet drops complete.
P0 frame counts on the same capture:

| Input | `764b2868b` | #4733 at `aae930a23` |
|---|---|---|
| Clean | 2,492 | 2,492 |
| One TEI on video | 2,491 | 2,479 |
| Twenty aligned 7-packet drops | 2,471 | 2,114 |

A drop costs one frame on the base and the rest of its GOP on #4733 (~1.2 s here) — intentional, but
trades concealed artefacts for up to one GOP freeze per break (15 % vs 1 % video on this feed).
Misaligned-drop arm through `tsp` stops at 6.6 s on every build (file input desync), grading none.

**On the merged build** (P1, the same pipe rig and capture) every arm runs the full 61.7 s, the damaged
ones with one `dropped a damaged TS unit` line, and each delivers the same 73,849,972 B as on
`aae930a23`, a figure the padded mux rate sets rather than the content. The P0 frame counts were not
repeated on it.

**State:** merged; #4581 closed. **Open:** the loopback SRT loss rate (to 6 % at 10 Mb/s) is
unexplained, and a libsrt-to-libsrt comparison is not yet usable.

### A full-rate live feed stops the export — reported as [#5362](https://github.com/moq-dev/moq/issues/5362), fixed by [#5363](https://github.com/moq-dev/moq/pull/5363) and [#5516](https://github.com/moq-dev/moq/pull/5516)

**Report.** [T45](test-45-live-tstd-remux.md)'s live-feed arm: a hardware encoder's 25 Mb/s CBR
multiplex with no nulls, conformant as a source, stops `main`'s export within 10 s on AC-3 whose
PES begin mid-frame. Fixing that exposes a video cap about 2.9 % below the level's leak; fixing
both, the output needs 25.017 Mb/s of packets, a frame a PES for each audio and separate clock
packets. The issue asks whether the cap is a deliberate margin and whether the PCR may ride in the
video's adaptation field or several audio frames share a PES.

**Contributed.** #5363 carries an unfinished AC-3 frame into the next PES and drops fragments at a
join or a lost PES. Before: the capture stops at 8–10 s. After: all 926 AC-3 frames before the
video limit at 39 s are the source's, in order, PTS exact. #5516 builds both quests: `b581c27ed` stops at 31 s, #5516 runs 280 s at the source's
25 Mb/s and passes T45's criteria.

**State.** Both merged, #5363 reworked and #5516 extended by the maintainer; #5362 closed into two
quests, both questions answered yes. `main` (`a7b421617`) passes on the capture.
[#5553](https://github.com/moq-dev/moq/pull/5553) merged sending ahead within the delay, with the
maintainer's fix releasing a packed PES against its first frame's deadline; the merged build grades
the same on the feed (T45).

### Keyframe parameter sets ahead of the AUD — reported as [#5951](https://github.com/moq-dev/moq/issues/5951)

[T11](test-11-interop.md): `export ts` and the elementary exporters write a keyframe's SPS and PPS
before its access unit delimiter, which H.264 and HEVC put first. **Fixed by
[#6001](https://github.com/moq-dev/moq/pull/6001), merged**; at `f13283b30` a keyframe through the
CDN relay has its source's NAL order (T11).

### A PMT revision kept stale track names — contributed as [#6208](https://github.com/moq-dev/moq/pull/6208) (import), [#6289](https://github.com/moq-dev/moq/pull/6289) (export) and [#6689](https://github.com/moq-dev/moq/pull/6689) (PAT)

**Report.** Upstream's fidelity audit (quest `ts-reliability/pmt-lifecycle`): a PMT that
retypes, re-describes or drops a stream left its track and catalog entry in place, and program
descriptors and identity were read once. P0-k's PID-change fixture revises its PMT.

**Contributed.** The import half: a changed or dropped listing ends its track and catalog entry,
a changed stream reopens under a new name, `programDescriptors` follows the PMT, an identity
change refuses; so do a PID listed twice and 65,536 stream revisions. The export half revises the
PMT at the next version, dropping a PID after its tail. The PAT half's import follows a moved PMT
and unannounces a dropped program; a restored one is a new epoch.

**State.** All three merged, #6689 finished by the maintainer. A running export follows a moved
PMT in upstream's [#7182](https://github.com/moq-dev/moq/pull/7182), open.

---

## 6. Interoperability

### The announce convention — reported as a hazard, not a bug, and fixed

`moq-dev`'s publisher withheld its namespace announcement until a peer asked for it, and only
`moq-dev`'s own relay asked, so against any other relay it negotiated and then sent no control
message. Proactive announce is a MAY in the drafts, so it was reported as interop hazard
[#2730](https://github.com/moq-dev/moq/issues/2730), not as a protocol violation. **Fixed:** at `main`
the publisher announces on connect, and `moq-dev`'s TS crosses seven of nine third-party relays
intact from the join ([T11](test-11-interop.md) § *Results at `main`*).

### The empty namespace prefix — a specification inconsistency, converged

The subscriber opens discovery on an *empty* namespace prefix, which moxygen rejected.
[moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457) closed in favour of
the empty tuple, and at `main` every relay that sets up a session accepts it (T11).

### A media-level interop profile — contributed

The community interop matrix is control-plane only, so `setup-only` can report green where no media byte
flows — **an entire failure class is invisible to the matrix the ecosystem reads.** The argument to
[englishm/moq-interop-runner#32](https://github.com/englishm/moq-interop-runner/issues/32) is that
media-level validation does not require decoding played video: **pick a fixture container that checks
itself.** Every MPEG-TS PID carries a 4-bit continuity counter, so loss, duplication and reordering are
detectable from the received bytes alone, and the checker shows its sensitivity to all three.

Two harness suggestions went with it: a control-plane test of zero-field namespace subscription (data
for moq-wg#1457), and recording the transport negotiated beside the draft. **State:** another
contributor took it up as a `media` area (CMSF first); [our
reply](https://github.com/englishm/moq-interop-runner/issues/32#issuecomment-6218255528) backs it and
keeps T-STD out of pass/fail. **The MPEG-TS half is proposed in
[englishm/moq-interop-runner#159](https://github.com/englishm/moq-interop-runner/pull/159), open:** a
fixture generated at build time, a TSDuck-backed checker with 13 sensitivity tests, and the cases
`ts-carriage-integrity` and `ts-late-subscriber`, both passing on `moq-dev`'s passthrough through its relay.

### A flag-alias regression — reported, fixed, verified, closed

Dial-side flags renamed on the development branch warned and then did not take effect: the alias
parsed and was never propagated ([#2913](https://github.com/moq-dev/moq/issues/2913), found by a
merge-base control, [method-notes](method-notes.md) §1). **Fixed, verified here, and closed:** client
and relay reject renamed settings outright and print the mapping, as the report argued, since the
silent failure left GSO on with nothing logged. Operationally, relay `--server-quic-gso` became
`--quic-gso` in the same rename; detect the surface from `moq --connect … --help` rather than assuming.

### Corroboration from an independent stack

`moqxr` [PR #21](https://github.com/mondain/moqxr/pull/21) reports the same preannounce split from the
publisher side, resolved by a default-off opt-in, and the idle timeout we measured: a publisher with
no subscriber dies at about 32 s. The idle timeout constrains more than one stack.

### OpenMOQ's MSFTS publisher through `moq-relay` — reported as [openmoq/moqxr#57](https://github.com/openmoq/moqxr/issues/57)

[T11b](test-11-interop.md#t11b--openmoqs-msfts-publisher-through-a-moq-dev-relay) put the headless
MSFTS example in `moqxr` 0.4.4 through a `moq-dev` relay and found four publisher-side problems, filed
as one issue.

- **A:** every object FINs its subgroup, so only object 0 is sent. The issue carries the one-line
  fix.
- **B:** on draft 18 a cancelled subscription is never released, so every moq-lite subscriber through
  `moq-relay` is refused as a duplicate.
- **C:** one group for the life of the stream, which the relay's group caps end at about 27 s at
  10 Mb/s.
- **D:** drafts 14, 16 and 17 fail on the relay's SUBSCRIBE_NAMESPACE.

With the fix to A, the byte-level result stands on draft 18. The WebTransport failure belongs to
`moq-dev`, whose `reliable-reset` quest plans the missing `reset_stream_at` parameter, so the issue
only notes it. **Closed by us** once the maintainer pointed to its successor,
`moq2ts`, below.

### `moq2ts`'s paced publisher and its final group — reported as [openmoq/moq2ts#8](https://github.com/openmoq/moq2ts/issues/8)

[T11d](test-11-interop.md#t11d--moq2ts-headless-publisher-and-receiver-criteria-fixed-before-the-first-run):
`moq2ts-cli --paced` sends a segment's bytes per fragment duration rather than at the source's rate,
and its receiver gets the final group twice; otherwise the loop is byte-exact. Draft-22 interop
with `moq-dev` waits on both adopting the framing moq-wg/moq-transport#2015 merged. Verified on
`4717ce3`: pacing follows the PCR, closing `--paced`. Verified on `a734a91` with moqxr v0.4.8:
interrupts exit cleanly, and the final group repeats with the receiver on moq5 `main` but not with
[openmoq/moq5#54](https://github.com/openmoq/moq5/pull/54). **Closed fixed: #54 merged.**

### moq5's relay and a late subscriber — reported as [openmoq/moq5#51](https://github.com/openmoq/moq5/issues/51)

[T11c](test-11-interop.md#t11c--moq5-against-moq-dev-both-ways-criteria-fixed-before-the-first-run)
direction 1: a passthrough import's catalog, published once before `moq5-relay` subscribed upstream,
never reached a late `moq export ts`, on drafts 16, 18 and 22. **Closed by the maintainer**: draft
22's fill, served only from the relay's retained log, is fixed on moq5 `main`, and on 16 and 18 the
repro needed `export ts --passthrough`. Verified: with it, all three drafts pass on `main` (T11
§ *Corrections*).

### A refused TRACK_STATUS fails the subscription — reported as [#5954](https://github.com/moq-dev/moq/issues/5954)

[T11](test-11-interop.md)'s CDN-hosted moqx relay refuses TRACK_STATUS with an undefined code, and
`moq-net` falls back to SUBSCRIBE only on NOT_SUPPORTED, so the export exits. **Fixed by
[#5991](https://github.com/moq-dev/moq/pull/5991), merged**: a subscribing reader registers before
its demand is visible, so it sends SUBSCRIBE; only fetch- and query-only demand still uses
TRACK_STATUS.

### A CDN-hosted moqx relay at a join — reported on [openmoq/moqx#795](https://github.com/openmoq/moqx/issues/795#issuecomment-6289975173) and as [#842](https://github.com/openmoq/moqx/issues/842)

[T11](test-11-interop.md): an unforwarded joining FETCH loses the head of the group in progress,
the SI track's object included. TRACK_STATUS's undefined code (#842, closed) reads as INTERNAL_ERROR;
[#843](https://github.com/openmoq/moqx/issues/843) asks for defined codes. Our STOP_SENDING ends the
subscription: [#817](https://github.com/openmoq/moqx/issues/817), whose open fix covers it.
**Open:** a local moqx on draft 16, v0.3.6 or the fixed snapshot, serves the joining FETCH (our
groups restart at 0, short of #795's precondition); on draft 18 the node refuses it, unforwarded, to
a track's opener, losing a once-published catalog ([T52](test-52-cdn-relay-fanout.md)); on the
latest image 14 openers of 14, no later joiner; no mid-group join lost its session
([re-tested](https://github.com/openmoq/moqx/issues/795#issuecomment-6418121868)); cause: the
opener shares the publisher's I/O thread ([#883](https://github.com/openmoq/moqx/issues/883)). The snapshot's
64-bit Hop ID ([moq#6545](https://github.com/moq-dev/moq/issues/6545)) is fixed by
[#6614](https://github.com/moq-dev/moq/pull/6614).

---

## 6b. FFmpeg: an HLS client that asks for HTTP/3 and carries the media over HTTP/1.1

Building the HTTP/3 path for [T20](test-20-segmented-http3.md) surfaced a defect that invalidates naive
HLS-over-HTTP/3 measurements with FFmpeg.

**The defect.** FFmpeg's HLS demuxer builds child URL options with `ffio_copy_url_options()`, whitelisting
names from the parent — including `prefer_libcurl` but not `http_version`, `tls_verify` or `ca_file`
(`libavformat/libcurl.c`). Segments therefore fetch by libcurl at libcurl's default HTTP version. With
`-prefer_libcurl 1 -http_version 3only`, the playlist negotiates HTTP/3 while segment connections offer
`http/1.1`; origin logs show `proto=HTTP/3.0 alpn=h3` on the playlist and `ALPN: server accepted
http/1.1` on media. Nothing in the client reports the split. Missing TLS options surface the bug on
self-signed origins (`Error when loading first segment`); publicly trusted origins succeed over TCP
quietly.

**The fix** (local to this campaign's build, documented in T20) adds `http_version`, `tls_verify` and
`ca_file` to that whitelist. **Verification:** against an nginx vhost with no TCP listener, a 60 s HLS
run logs 54 of 54 requests as `HTTP/3.0 alpn=h3` and the capture holds 109,657 UDP datagrams and zero
TCP; media md5 matches the HTTP/1.1 arm (`7f3402ea…`). Without the patch the same command cannot
complete against a TCP-less origin and completes over TCP against a trusted one.

**Status:** [FFmpeg #24752](https://code.ffmpeg.org/FFmpeg/FFmpeg/issues/24752); whitelist unchanged
on master `45f3fecca` (2026-09-22) by reading; open PR
[#24565](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/24565) fixes a related whitelist gap for
`local_addr`.

## 6c. TSDuck: an HLS packager whose playlist overstates its segments

**The report** ([tsduck/tsduck#1752](https://github.com/tsduck/tsduck/issues/1752)), from
[T65](test-65-ird-hls-profile.md): with `--intra-close`, `--max-extra-duration` never forces a close,
so a stream on which no I-frame is found becomes one segment; `EXTINF` exceeds `TARGETDURATION`, an
RFC 8216 MUST; and `EXT-X-INDEPENDENT-SEGMENTS` is written whether or not segments are independent.
**Verification:** on 3.45-4798, a public FFmpeg reproducer gives one 29.64 s segment, segments of
2.56–2.63 s under a target of 2, and validator errors -50061 and 535038; `master` has each defect, by
reading. **State:** open.

---

## 7. The carriage specification: MSFTS

Almost everything above targets an *implementation*. `draft-gregoire-moq-msfts` registers `m2ts`/`mpeg2ts`
packaging in the MSF catalog, so it fixes whole-transport-stream carriage for any implementation. It was
reviewed from one declared position — a whole multiplex to a hardware IRD, as SRT, Zixi and RIST carry
it today — because fidelity requirements need a named receiver.

The review opened as [mondain/msfts#7](https://github.com/mondain/msfts/issues/7); the author turned each
point into draft text. Summary of the first wave:

| Found | Changed |
|---|---|
| Per-programme retain list silently drops fixed-PID SI (NIT, SDT/BAT, EIT, TDT/TOT, ATSC PSIP) — **no service identity, EPG or broadcast time** if implemented verbatim | [#11](https://github.com/mondain/msfts/pull/11): states the loss, retention guidance, `m2tsSiPids` |
| Null removal changes byte distance between PCRs (CBR clock recovery) | [#10](https://github.com/mondain/msfts/pull/10): warns, advisory `m2tsMuxRate` |
| Continuity counters and PIDs *described* but not forbidden to rewrite | [#12](https://github.com/mondain/msfts/pull/12): MUST NOT rewrite; note on inter-packet PCR timing |
| No transparent whole-multiplex mode | [#8](https://github.com/mondain/msfts/pull/8): `m2tsMpts` |
| Filtering MPTS without SI rewrite ([#13](https://github.com/mondain/msfts/issues/13)) | [#19](https://github.com/mondain/msfts/pull/19) |
| No first-class native SPTS ([#14](https://github.com/mondain/msfts/issues/14)) | [#18](https://github.com/mondain/msfts/pull/18) |

Three further first-revision findings
([#15](https://github.com/mondain/msfts/issues/15)–[#17](https://github.com/mondain/msfts/issues/17)):
the 192-octet arrival-time prefix had no clock, units, layout or wrap — two implementations could
not interoperate on pacing; `m2tsMuxRate` did not say the egress recovers clock from carried PCR
(rate is stuffing target) nor whether the figure counts 188- or 192-octet packets; null removal was
declared via [#21](https://github.com/mondain/msfts/pull/21)'s `m2tsModified` but not
distinguishable from programme filter or PAT rewrite. #16 and #17 closed with
[#35](https://github.com/mondain/msfts/pull/35) (#16 fixed, #17 declined), #15 after
[#40](https://github.com/mondain/msfts/pull/40) reconciled Egress Timing with the arrival-time
definition.

**Not measurement.** The `m2ts` carriage measured here is `moq-dev`'s passthrough, byte-verbatim
([T48](test-48-passthrough-export.md)); the review establishes that the specification no longer
permits a silent departure from verbatim.

### The three named modes are published, and the gap they leave is output timing

In -01, §5.5 subsumed #8, #14, #18 and #19 into three modes: unmodified SPTS or whole multiplex,
modified programme-level, and modified ES-level. **None required the egress to time its output**, and
the property that decides an IRD's lock is PCR arrival, not byte accuracy: raw `moq export ts` at
`eab960192` put 8.19 % of PCR intervals above 40 ms on the wire, cross-host, where a rate-controlled
egress puts none ([T4](test-4-remote-e2e-srt.md), [T19](test-19-pcr-grid-verification.md),
[T21](test-21-permanence-soak.md)). The asks, in descending priority: a declared mux rate on ES-level
tracks ([#25](https://github.com/mondain/msfts/issues/25)), a normative egress-timing duty on the
subscriber that produces TS ([#32](https://github.com/mondain/msfts/issues/32)), arrival-time stamps as
the specified mechanism ([#15](https://github.com/mondain/msfts/issues/15)), and the PSI interval
honoured at output ([#26](https://github.com/mondain/msfts/issues/26)). #35 answered #32 with a conditional MUST in
Egress Timing and made the ES-level mux rate RECOMMENDED. **State:** superseded; -02 removed the
modified modes, and #48 removed the output rules (below).

### The 2026-09-17 round: eleven issues filed, plus one comment and one cross-venue pair

Eleven issues, [#24](https://github.com/mondain/msfts/issues/24)–[#34](https://github.com/mondain/msfts/issues/34),
with a [#15 comment](https://github.com/mondain/msfts/issues/15#issuecomment-5714034547) and
[moq-dev#3731](https://github.com/moq-dev/moq/issues/3731) cross-linked with #33.
[#35](https://github.com/mondain/msfts/pull/35) answered most, [#36](https://github.com/mondain/msfts/pull/36)
closed #33 and [#40](https://github.com/mondain/msfts/pull/40) closed #15. Declined, with reasons: field
reduction (#17, #27's CA-PID list), #29's source PID inventory, which the pipeline that dropped PIDs
would make agree with itself, and #34, since modified carriage passes TR 101 290 P1 on the packets it
carries. **State:** closed; what they added has gone with the modified modes (§ *The -02 revision*).

### moq-dev#3731 answered, and our re-assessment returned: agreement on the diagnosis, a concession on mux rate, one structural disagreement left

| Asked | Answered |
|---|---|
| MSFTS compatibility objective? | Convergence on **conversion, not verbatim transport** |
| Mode 3 right design? | No — "worst of both worlds" |
| Timing reference with media? | PCR "kind of dumb"; "IDK it doesn't really matter" |
| §5.5.3 group-alignment MUST? | Prefer timestamps; **optional acceptable** |
| SI in catalog or tracks? | No position |
| Observed mux rate recorded? | **Yes** — catalog `maxBitrate`, pad on export |

**The mux-rate answer is banked.** Both venues landed the same semantics in the same week: a stuffing
target rather than a timing source, counted over 188-octet packets after null removal, with
`mpegts.muxRate` and `mpeg2tsMuxRate` naming the same quantity.

**"Just always pad" was corrected on substance.** Padding to a declared rate makes the *total* bitrate
correct without making byte *positions* correct, and a receiver that clocks on packet arrival grades the
positions. The measurements that size that gap were kept out of the design thread deliberately and filed
as [#3925](https://github.com/moq-dev/moq/issues/3925).

**PCR needs clarifying rather than contesting.** Transmitting PCR across the network is not what recovers
a decoder's clock, and this campaign's architecture agrees: the egress re-synthesises PCR on its own grid
([T19](test-19-pcr-grid-verification.md)). The risk is that *"kind of dumb"* hardens into a reason not
to regenerate PCR correctly either, and the entire IRD-facing case depends on that regeneration. The reply
endorsed the draft's Egress Timing position that delivery-schedule conformance belongs where the
subscriber hands packets to its receiver, but it never stated explicitly that we regenerate rather than
transmit PCR.

**Group alignment is settled for us in the optional formulation**
([#31](https://github.com/mondain/msfts/issues/31)). The reply went once, on 2026-09-22, after
[#35](https://github.com/mondain/msfts/pull/35) published; it reported four of six points resolved,
with the payload unit (filtered 188-octet packets against access units) left with the editor at #33.

### The maintainer's objection to the round, and why the volume half of it is right

The editor objected to the volume of AI-written issues, and on volume he was right: he authored every
one of the sixteen PRs merged on the draft after our issues, so eleven issues in one day were eleven
patches by one volunteer. Later asks went as pull requests, sized to the objection (the rule is in
[`method-notes.md`](method-notes.md) §6). One point holds without qualification: the `moq-dev`
implementation is not the draft's reference, so an argument in that venue stands on the draft's text
and the base specifications, and where the two projects disagree it is a convergence question for both.

### The output contract: what a rebuilding subscriber emits, filed as #37 and merged

[#37](https://github.com/mondain/msfts/issues/37) asked what a subscriber that rebuilds a transport
stream must output: every table at its standard's interval, the first output after a join, no unchanged
TDT/TOT re-emitted, the output where an Object is missing, and the same packets from two subscribers,
which makes every regenerated field a function of the tracks. It named the per-process continuity
counter ([#3868](https://github.com/moq-dev/moq/issues/3868)) as a constraint rather than asking for
deterministic counters as though they were free. [#34](https://github.com/mondain/msfts/issues/34) was
reopened, since ES-level carriage regenerates counters, adaptation fields and PCR, so a stopped stream
arrives as clean syntax. The text went as [#38](https://github.com/mondain/msfts/pull/38)–[#40](https://github.com/mondain/msfts/pull/40),
all merged; review narrowed identical output to two instances of one implementation, the section
timestamp to `"section"` Objects, and #38 to the PCR PID. **State:** merged into -01, and removed with
the Rebuilt Output section in -02.

### The retain list drops the CAT, so conditional access cannot survive program-level filtering

Filed as [#27](https://github.com/mondain/msfts/issues/27). §10 claims the packaging preserves scrambling
and conditional-access information present in the source transport stream. §5.5.2's per-programme retain
list keeps the PAT, the selected PMT, and packets whose PID is listed in the PMT, including the PCR_PID
and the PIDs of all elementary streams, but it does **not** include the Conditional Access Table at PID
0x0001, even though the paragraph that enumerates dropped fixed-PID tables names NIT, SDT, EIT and
TDT/TOT explicitly.

That omission matters because of the reference direction in the standards. ISO/IEC 13818-1 requires
system-wide conditional-access management information to be referenced from the CAT, and EBU Tech
3292-s1 §4.2.2.2 restates that in the CAT a `CA_PID` names the **EMM** stream, while in the PMT or an
elementary-stream loop it names the **ECM** stream. The EMM stream is not reachable from the PMT at all,
and dropping the CAT leaves nothing in the retained track pointing at it. The ECM PID is referenced from
the PMT, but by a CA_descriptor rather than in the elementary-stream loop, so the retain list's wording
also puts ECM at risk.

The failure is silent and total. The receiver gets scrambled elementary streams and entitlement control
messages, has no entitlement management messages, can never obtain the session key, and never descrambles
a packet, while every validation rule in §5.1 and §8 passes. §5.5.2's saving clause requires publishers
filtering scrambled streams to retain the conditional-access packets required for descrambling, but it
does not tell the implementer that the table locating those packets is the one the retain list discarded.
The finding has the same shape as the accepted #11 and #13/#19 work: a table on a fixed PID, outside the
PAT/PMT reference graph, dropped by a filter that only follows that graph. **Nothing here is measured** —
this campaign scrambles nothing — so the finding is a reading of specifications, not an observed product
defect. It was filed from a BISS-CA deployment question and closed when the CAT entered the retain list in
the #35 round.

A second, structural half remains for demuxed carriage in -01: ES-level tracks exclude PAT, PMT and nulls,
and the SI and programme fields MUST be absent, so there is no carriage path for the CAT, for CA_descriptors
in the PMT, or for any association between a scrambled stream and its ECM. A publisher also cannot identify
access points or reassemble PES inside encrypted payloads. §10's preservation claim cannot hold for that
mode, and the draft should have said so (-01 scope; demuxed modes removed in -02, below).

### Three further defects in the new sections, and one unimplementable MUST

Issues #28–#31, from reading §5.5 against the implementation, all closed with
[#35](https://github.com/mondain/msfts/pull/35): carriage mode was inferred from three fields rather
than declared (#28, answered by a table); `m2tsModified: false` was an assertion common tooling breaks
silently, `ffmpeg -c copy` reducing a 13-PID mux to five ([T4](test-4-remote-e2e-srt.md); #29, a
Security Considerations note); an object count bounds bytes, not time, on a VBR multiplex (#30, the
SHOULD deleted); and group alignment cannot be met literally across AAC and video cadences (#31,
relaxed to SHOULD).

### Mode 3 and the reference implementation are not the same thing, and that is the convergence problem

At #33 filing, MSFTS mode 3 carried **188-octet TS packets** per PID with counters inside the
packets; `moq-dev` carried **decoded access units** (and `N.ts` PES, SCTE sections), discarded
counters, regenerated PCR on a 25 ms grid, and cut groups at keyframes (video) or every audio frame.
PAT/PMT lived in `initDataList` in MSFTS versus catalog regeneration in moq-dev; SI as ES tracks
versus catalog snapshots (EIT/TDT/TOT were gaps on `origin/main` then, since closed on snapshot
tracks). [#36](https://github.com/mondain/msfts/pull/36) added `media-frames` LOC carriage as the
second route; #33 closed noting catalog-vs-tracks and PES-unit differences for moq-dev convergence.

**Fourth mode.** The reference implementation is not MSFTS mode 3 as first published. It is
access-unit carriage with transport-stream re-synthesis at egress, a fourth mode the -01 draft did
not name as such. Filtered-TS carriage preserves continuity counters, adaptation fields and PES
framing exactly, and is a PID filter rather than a demuxer, so it carries what the publisher does
not understand. Access-unit carriage is what makes the lane media-aware: keyframes define group
boundaries so joins land on an IDR by construction, per-frame objects give frame-level priority and
shedding, and codec configuration reaches the catalog so a subscriber initialises without parsing
TS. That is the mechanism behind this campaign's latency result, and its price is precisely what the
measurements show lost: continuity counters, stuffing, mux rate and PCR spacing, all of which the
egress must reconstruct. Draft ES-level carriage sat between the two coherent designs and collected
cost without benefit. If `moq-dev` contributes demuxed spec text, four implementation-held facts
matter: why access units rather than filtered TS packets, why audio cuts a group per frame, whether
SI belongs in the catalog or as tracks, and what the exporter must reconstruct and cannot,
coordinated with wire conformance measurements. The cheapest convergence win, a declared mux rate
after null strip, landed on both sides ([#3831](https://github.com/moq-dev/moq/pull/3831) and draft
#25; [`evidence.md`](evidence.md) §3.5).

### The -02 revision: verbatim-only carriage ([#41](https://github.com/mondain/msfts/pull/41))

[#41](https://github.com/mondain/msfts/pull/41) ("Keep the verbatim family and simplify the draft
for -02") merged, and -02 is the submitted revision.

**Scope.** -02 is **verbatim-only**: `es-units`, `media-frames`, LOC tracks and the Rebuilt Output
section are **removed**; demuxed carriage is **deferred** to `draft-lcurley-moq-mpegts`. The sections
above on the modified modes are the record of -01 and of the convergence argument with `moq-dev`, not
the current MSFTS scope.

**Adopted from our feedback:** a **188-octet `unmodified-program` baseline** every TS-output
subscriber **MUST** support; an **output rule** for unmodified modes (pass the reconstructed stream
unchanged apart from switching signals, catalog PAT/PMT at join, prefix removal), making **byte
identity between subscribers** a black-box test; optional **reference programme** on a multiplex
(`mpeg2tsProgramNumber` / `mpeg2tsPcrPid`) to pace on; **Groups SHOULD NOT last longer than 2
seconds**; softer continuity-counter wording ("can show" a gap) with subscriber **SHOULD** report
each gap's Location and duration; one-sentence **scope-out of error correction**;
[#42](https://github.com/mondain/msfts/issues/42) (**T-STD** conformance in unmodified modes)
answered for conformance testing.

**Not taken up:** a normative time reference; the `es-packets` schedule; `discontinuity_indicator` on
non-continuity PIDs. (The CAT rewrite, the peak-rate window and `version_number` after a switch came
in #46, below.) Egress-timing promotion
 ([#32](https://github.com/mondain/msfts/issues/32)) is partially addressed by unmodified output rules and
#42 T-STD scope for verbatim modes; demuxed timing and ES recombination obligations that lived in -01 are
out of MSFTS until `draft-lcurley-moq-mpegts`.

**Later feedback on -02.** Six points on its text (the 2-second Group bound against the random access
rule, a multiplex with no reference program to pace on, where a timing method would go, `es-packets`
without arrival times, whether a baseline subscriber can take `per-program`, and the two meanings of
`mpeg2tsProgramNumber`) were answered by [#46](https://github.com/mondain/msfts/pull/46): a multiplex
paces on the PAT's first program by default; the timing method and `es-packets` timing were not taken
up. That feedback offered neither the test vectors the co-author asked for nor a companion draft on
TS-output health. [#47](https://github.com/mondain/msfts/issues/47) asked for
one testable output rule in every mode, and was answered by
[#48](https://github.com/mondain/msfts/pull/48), merged after our review. **State:** MSFTS now specifies
only the Objects, the Groups and the catalog, and leaves subscriber output to the receiver's standards,
so every output rule above and the Group bound are gone; we closed #47 on that answer.

---

## 8. What was asked for at the start, what was retracted, and on what evidence

Four early requirements, filed before most measurements; three were closed by us when measurement
contradicted the ask.

| Filed | Asked for | What we did | What forced it |
|---|---|---|---|
| [#1799](https://github.com/moq-dev/moq/issues/1799) | direction: media-aware vs byte-opaque | **closed by us** when children resolved | direction settled by children |
| [#1861](https://github.com/moq-dev/moq/issues/1861) | second byte-verbatim opaque lane | **retracted by us** | #2440 → EIT-only gap; wire economics reversed; 1+1 byte identity another way |
| [#1839](https://github.com/moq-dev/moq/issues/1839) | generic TS egress sink with PCR-aware pacing | **partly landed, remainder retracted** | [#1845](https://github.com/moq-dev/moq/pull/1845); maintainer declined per-transport modules |
| [#1838](https://github.com/moq-dev/moq/issues/1838) | TR 101 290 monitoring | **corrected in place**; closed via [#4496](https://github.com/moq-dev/moq/pull/4496); liveness and ingest counters merged since (§2) | half the original checks targeted moq egress timing; programme presence and moq-layer counters still open |

- **#1861 was retracted on the economics.** Over a WAN beside SRT, the media-aware lane puts 0.982×
  the source rate on the wire against SRT's 1.037×, because it does not carry null stuffing a
  receiver regenerates ([T9](test-9-performance.md), [T14](test-14-data-plane-comparison.md)); and
  1+1 byte identity was reached by deriving stream positions from the stream
  ([T12](test-12-dual-path-handoff.md)). Scrambled carriage and true MPTS stay out of reach for a
  demux/re-mux lane and belong to the packaging discussion (§7).
- **#1839's remainder** went after the maintainer declined a module per transport without a
  customer; a transport-agnostic pacer replaced it ([T13](test-13-downstream-grooming.md)).
- **#1838 was corrected rather than withdrawn.** PCR and mux-rate checks on moq's egress target a
  stream no IRD sees, and would sit in alarm on a healthy chain (1,523 of 1,524 PCRs outside ±500 ns
  ungroomed, none after grooming; [T7](test-7-timing-integrity.md), T13), so they are the groomer's.
  What grooming does not restore (sync, PAT/PMT, continuity, PID, transport error, CRC, PTS) is the
  defensible egress list. TR 101 290 is blind to the chain's worst failure, a groomer holding a
  byte-perfect carrier against a dead upstream with no programme packets (T12: zero input-select
  switches from 50 to 500 ms), which needs a count of programme-packet presence; at ingest, moq-layer
  counters (resyncs, bytes discarded per track) carry more than the ETSI list. The exporter still
  reports no TR 101 290 counters.

---

## 9. Documentation

Upstream review of [#2830](https://github.com/moq-dev/moq/pull/2830) objected to a grooming recipe invoking
a tool with no supported install path — prompting [T13](test-13-downstream-grooming.md), which graded
off-the-shelf options and concluded the **requirement should be stated with named options and measured
limits**, not a single mandated tool. That holds whether or not our tool installs; the gap is closed (egress
adapter is the crate binary, not an example).
