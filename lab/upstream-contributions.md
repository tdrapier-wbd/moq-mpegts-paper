# Upstream contributions

What this campaign found, reported and verified in other people's projects. It is kept separate from
the experiment record for two reasons: it is a different argument from "does MoQ suit broadcast
primary distribution", and it accounts for a large share of the campaign's effort in a way the
results alone do not show.

**Why it belongs in the repository at all.** [Comparison](../docs/comparison.md) §14 scores
operational maturity against a pre-1.0 ecosystem. This file is the concrete form of that: what a
broadcaster procures is an implementation, not a specification, so much of what reads as "MoQ does X"
is really "this build does X" — and several gaps recorded here have since closed. That is the
expected shape of implementations maturing *with* a specification rather than after it, and it cuts
both ways: the gaps were real, and they closed fast.

Each item states what was found, how it was verified, and what remains open. Where a fix was verified
here rather than taken on trust, the before/after rigs are named.

---

## 1. Media-aware carriage: what a real contribution feed breaks

### Open-GOP keyframe detection — closed

A CNN International capture (open-GOP H.264 signalling recovery-point SEI, roughly one IDR every
15 s) produced **no video rendition at all** through media-aware import, because keyframe detection
keyed only on the IDR NAL type. Open-GOP is common on contribution feeds, not a niche quirk.

Closed upstream by two changes the round-trip needs **together** — catalog-reservation gating
([#2072](https://github.com/moq-dev/moq/pull/2072)), which makes the exporter withhold PSI until every
PMT-reserved track resolves, and recovery-point-SEI detection
([#2066](https://github.com/moq-dev/moq/pull/2066)), without which an IDR-less feed's video never
resolves and the gate stays shut. With #2072 alone the catalog never publishes.

Verified here rather than taken on trust ([T2](test-2-media-aware-transparency.md)): the same feed
round-trips deterministically with every elementary stream, PID, `stream_type` and PMT descriptor
intact, and all three SCTE-35 splice PIDs included.

### The DVB service layer — closed

The `mpegts` catalog modelled per-PID PMT info and verbatim elementary streams only, with no field for
service identity or standalone SI, so `export ts` rebuilt just PAT and PMT. Service name and provider,
service type, NIT, TSID, ONID and the PMT's own PID were all lost.

[#2440](https://github.com/moq-dev/moq/pull/2440) threads a service record through the catalog and
rebuilds the SI on export. Measured before and after in [T2](test-2-media-aware-transparency.md).

### EIT, and where carried SI should live — the question we priced

#2440 left EIT and TDT/TOT out. Measuring the residual on a synthetic fixture — no capture held here
carries EIT — split the two, because **they revise at opposite rates**: EIT repeats byte-identically
between event transitions, so carrying it costs little, while every TDT/TOT section is new content and
therefore a republish, for a table that says nothing but "now".

That split led to [#2824](https://github.com/moq-dev/moq/pull/2824), which carried EIT present/following
only, verified byte-identical here across a version roll (v0 ×27 then v1 ×28, no flapping, no stale
version left behind) and with a purpose-built fixture for its `current_next_indicator` guard, which
nothing in the existing captures exercised.

The design question behind it — **does carried SI belong in the catalog or on its own track?** — was
raised as [#2882](https://github.com/moq-dev/moq/issues/2882), and this campaign priced it rather than
arguing it. The catalog is whole-state, so one changed section rewrites the whole document and every
subscriber pays at join. Measured against service count:

| services | standing catalog | SI share | junction cost |
|---|---:|---:|---|
| 1 | 2,180 B | 34.8 % | 2 republishes in 0.11 s |
| 12 | 6,746 B | 79.2 % | 20 republishes in 0.11 s |
| 40 | 18,428 B | 92.7 % | 61 republishes in 1.27 s |

**The bandwidth is noise** — 1.12 MB against a multiplex of tens of Mb/s. What the numbers indict is
the *join* (18 kB read before media discovery, 93 % of it service information) and the *parsing*.

And a second finding was not about scale at all: **a multi-section table is assembled in the catalog
in public.** At 40 services the SDT sits at 1 of its 2 sections for 5.2 s across 53 publishes, and
section 0 declares `last_section_number = 1` — so an exporter re-emitting that state puts a table on
the wire that announces two sections and transmits one. Incomplete rather than merely stale. No
tuning of the catalog fixes it; the fault is that a whole-state document is revised one section at a
time.

Those measurements supported the move to per-table snapshot tracks **on coherence grounds rather than
bandwidth grounds**, and also showed that the tables #2440 shipped would gain nothing from it. The
question is settled in favour of tracks and implemented in
[#2909](https://github.com/moq-dev/moq/pull/2909), reviewed here by measuring it
([T17](test-17-si-snapshot-tracks.md)) — including the sparse-schedule case that cannot be validated
by counting sections.

### TDT/TOT — open, and the argument moved

Reported as [#2914](https://github.com/moq-dev/moq/issues/2914). The exclusion is deliberate and
correctly argued upstream — a clock is not state, and an upstream multiplexer's time carries unknown
delay — but nothing regenerates it downstream either, so the egress carries no time table at all.

Two findings from this campaign bound the design argument, and one of them corrects our own earlier
position:

- **The incumbent tunnels proxy the clock and are right to.** RIST and SRT forward TDT with
  inter-section gaps matching a no-transport control to two decimal places
  ([T15](test-15-point-to-point-cadence.md)), because a constant-delay pipe that never repeats a
  section is late by its path and by nothing else. That is a property of *that class of machine*, not
  an argument about time tables, and it does not transfer to a stage that re-emits SI on a cadence of
  its own.
- **A clock synthesised from the host would break the EPG that now survives.** EIT event times are
  absolute UTC, so a clock and the schedule read against it must share one time base. Relaying EIT
  verbatim while minting TDT locally misplaces every event by the offset between the two clocks.

So the defensible design anchors on the source's time and advances it locally — neither pure
forwarding nor pure synthesis.

### A liveness risk introduced by the fix — open

Export opens its output once every SI entry either holds a snapshot or has reached a terminal state,
and terminal *failure* is handled deliberately: the track logs and keeps its last snapshot rather than
killing the mux. **A track that neither succeeds nor fails is not covered.** It leaves the gate shut
and the exporter emits no TS at all, media included, with nothing logged past the subscribe attempt.
Before SI moved to its own tracks it lived in the catalog and could not independently gate media.

---

## 2. Audio robustness: three defects, two closed

### Frame-sync loss killed the whole publisher — closed in two days

**The finding.** A single damaged byte in an MP2, AC-3 or E-AC-3 frame header terminated the
publisher outright and took every other track with it — video, teletext, all three SCTE-35 PIDs —
while the video path resynchronised through identical corruption. For a contribution feed that is the
wrong way round to fail.

**Why the report was strong rather than marginal**, and this generalises to reporting into any
upstream project:

- A **deterministic minimal reproducer** with no timeline discontinuity of any kind: one valid MP2
  frame, then a second with its sync word changed from `0xFF` to `0xFE`, same PID, monotonic PTS, no
  loop. A single flipped bit is sufficient.
- A **one-line root cause**: the legacy-audio PES loop propagates a header-parse failure straight out
  of the demuxer with `?`. There is no attempt to scan forward for the next sync word, so a lost sync
  is unrecoverable by construction rather than by policy.
- A **documented design principle the behaviour contradicts** — the module's own doc comment says
  malformed input is *"rejected, never mis-described"*, and resyncing to the next valid frame honours
  that exactly. Rejecting the damaged frame is right; killing the session is the part that does not
  follow.
- **Two in-repo precedents for the correct behaviour**: the TS container layer resyncs byte-wise with
  three tests pinning it, and the video path resyncs structurally through Annex-B start-code
  scanning — which is precisely why a video-only loop survives.

Reported as [#2729](https://github.com/moq-dev/moq/issues/2729), fixed by
[#2751](https://github.com/moq-dev/moq/pull/2751) within two days. The upstream change scans forward
to the next sync-word candidate and **confirms it before trusting it** — a frame is accepted only once
a second header parses exactly where the first says the frame ends, the same confirm-before-trust rule
the TS layer already applied. The scan is bounded at 64 KiB and only a *confirmed* frame resets that
budget.

**Verified here against both builds**, on three copies of a 20 s cut of a real 9.95 Mbps DVB capture
each differing from the clean original by **exactly one byte**:

| Arm | one-byte change | pre-fix | post-fix |
|---|---|---|---|
| MP2 header | sync `0xFF` → `0xFE` | **died at 12 s**, rc=1 | ran to end of file, rc=0 |
| H.264 start code (control) | `0x01` → `0x00` | survived | survived |
| Full A/V looped | none — `--infinite` wrap | **died at the first wrap** | survived 2+ wraps |

Comparing the damaged run against a clean control **by PTS set on every elementary stream**: exactly
one 24 ms MP2 frame dropped at the damage point, nothing published that the clean run did not publish,
and video, AC-3, teletext and all three SCTE-35 PIDs untouched. One damaged byte cost one 24 ms audio
frame instead of the whole broadcast.

The fix also reached a defect we had not found — AAC frames split across a PES boundary were never
reassembled at all, so a legal mux could kill a broadcast with no corruption involved.

**A correction to our own report.** The video+AC-3 row of the original table does not reproduce as
stated: re-run, the pre-fix build survived a looped video+AC-3 clip for 50 s. **A loop wrap is fatal
only when it splits an audio frame**, which is a property of where the cut falls, not of the codec.
The codec-generality claim rests on the unit reproducers and on AC-3 having the identical parse shape,
not on that row. The MP2 single-bit arm is unaffected and remains decisive.

### A splice publishes a *substituted* frame — closed, with two measured residuals

**A bit error and a splice are not the same defect, and closing the first left the second open.**
Where the damage is a corrupt byte, the parser rejects the frame and drops it. Where it is a *splice*
— a feed restarting, a dropped PES, a looping file wrapping mid-frame — the header is intact and only
the bytes after it are foreign, so the frame is published: **not a frame lost but a frame
substituted**, carrying audio from both sides of the discontinuity. That is the harder case to detect
downstream, because a substituted frame of the right length in the right place leaves the timeline
intact — no continuity error, no discontinuity flag, evenly spaced timestamps.

**Detection is decidable without a listening test.** A frame is *alien* if its bytes appear nowhere in
the source's audio elementary stream — a frame assembled across a splice is made of bytes from both
sides of it, so it can match nothing in the source. `ts-splice-audit.py` does exactly that.

Split out upstream as [#2802](https://github.com/moq-dev/moq/issues/2802) and first fixed in
[#2823](https://github.com/moq-dev/moq/pull/2823) by extending frame confirmation to a frame beginning
in a carried tail. **Tested here against real content, and the first fix changed nothing**: 3 alien
frames per audio PID before and after, same hashes, same positions, with the audio byte-identical
between the arms across three wraps. The reason is the finding rather than the null result — this mux
never splits an audio frame across a PES boundary, so the carried tail the fix guards is always empty,
and at the wrap the foreign bytes join the *same* truncated PES rather than the next one. The
confirmation *rule* would have caught it; it is the gate that misses.

**The route that does work was already in the stream and already implemented next door.** The wrap
breaks the transport continuity counter on every PID, and `SectionReassembler` in the same file
already drops its partial on a counter gap, a declared discontinuity or a transport error — for
private sections. The PES path never read the counter. Reported with that argument, upstream
reproduced it in-tree before touching anything and **rescoped the PR from one commit to five**,
generalising those continuity rules into a shared check applied to PES PIDs too. Merged; re-verified
here across four arms, and the mixed frame is gone from both audio PIDs on current `main`.

**Two residuals survive, both measured.**

- **The guard trusts one signal, so a counter-contiguous wrap is invisible again.** A cut whose last
  packet on a PID leaves the counter equal to the one the file opens with wraps contiguously — about
  one cut point in sixteen per PID, and 4,062 of 30,000 positions scanned do it for at least one audio
  PID. Cutting at exactly such a point puts the original bug back on merged `main`: 1 alien AC-3 frame
  per wrap, each rejected by its own `crc1`. **The guard is sound; its trigger is probabilistic on the
  one signal it consults.** A codec CRC would close it, and AC-3's rejects every mixed frame measured
  — but it cannot be the general answer, because 0 of this clip's 826 MP2 frames carry a CRC at all.
- **The salvage does not deliver what it promises, for AC-3.** On a break the truncated PES is meant
  to be flushed so the whole frames it already carried still publish. MP2 behaves that way — its 7
  complete frames publish before and after the fix. AC-3 does not: its 8 complete frames are published
  pre-fix and **absent from every wrap post-merge**, searched by hash across the whole capture. That
  is **~256 ms of good audio lost per splice on AC-3**, where MP2 loses nothing. Both PIDs take the
  same branch of the same match, so the asymmetry is downstream of it.

### A recovered stream is signalled nowhere — open, and it is the architecturally important one

Reported as [#2798](https://github.com/moq-dev/moq/issues/2798), scoped to observability rather than
correctness.

The subscriber's TS after a resync carries **0 continuity errors** (identical to the clean control),
**0 signalled discontinuities** on any PID, and an audio timeline that simply steps 24 ms → 48 ms
across the hole. Nor is it visible above the TS: the resync path emits no log call at any level,
exposes no counter, and does not touch the discontinuity counter that already exists for timeline
rewinds. The upstream doc comment states the policy deliberately, so the silence is intended rather
than an oversight.

**A TR 101 290 monitor at egress therefore sees a fully conformant stream with no indication that
anything was lost.** For an architecture that treats the ingest edge as the place where a contribution
feed's defects are absorbed ([Architecture](../docs/architecture.md) §6.2), **the absorbing needs to
be observable.**

Two things sharpen it. The splice case was worse while it stood — a *substituted* frame leaves no
evidence at all, where a dropped frame at least shows in a frame count — and #2823 turned the
substitution back into a gap while leaving the reporting half untouched. And **the 1+1 worry does not
survive measurement**, which is worth saying: two importers fed the same damaged source dropped
precisely the same frame, so the resync is deterministic on identical input and this is not a
redundancy risk. What remains is narrower and still real: **the fix converted a maximally loud failure
into a completely silent one.** Our own source was only discovered to be wrapping mid-frame *because*
it crashed 216 times; the same condition now produces a stream that looks healthy. The ask is a
warning on a completed resync and a counter to alarm on a *rate* of them, neither of which touches the
protocol.

---

## 3. Resilience and redundancy

### The exporter died on session loss — closed

`moq export ts` exited the instant its session dropped, which was the single most consequential
transport-resilience gap for primary distribution, since a broadcast subscriber must ride out relay
maintenance unattended. Closed by [#2469](https://github.com/moq-dev/moq/pull/2469) (broadcast
*linger*): the relay keeps the broadcast announced for the reconnect window and a re-attaching source
splices back into the same broadcast, while a clean unannounce still tears down immediately. Measured
surviving a relay kill and restart, resuming byte-identical output automatically.

[#2647](https://github.com/moq-dev/moq/pull/2647) tightened it further, so the exporter re-attaches
within seconds of a relay returning while a genuinely *dead* relay errors in tens of seconds instead
of retrying silently — the axis that matters for a supervisor deciding to re-home a subscriber.

### Active/active source failover — shipped, bounded

**The problem as found.** Two publishers announcing the same broadcast to one relay did not form a
standby pair: the moment the second announced, the relay declared the path unroutable and tore down
**both**. Across a two-relay mesh the pair coexisted but never failed over — graded well beyond one
full idle timeout, so this was the mechanism and not the detection budget.

The relay's forwarding core already contained a multi-source route table with a `reselect` path
covered by a unit test; the drill never reached it. What was missing was the *selection* rule that
makes a relay offer a peer a route other than the one it is already serving through.

[#2473](https://github.com/moq-dev/moq/pull/2473) (issue
[#2461](https://github.com/moq-dev/moq/issues/2461)) supplies it: per-peer announce selection
advertising the best route whose hop chain *excludes* the requesting peer, exclusion-aware serving,
first-hop content identity declared in SETUP rather than inferred per announce, and a
`moq --origin <id>` knob so a 1+1 pair declares itself interchangeable — explicitly, because the relay
is content-agnostic and will not infer it. [#2629](https://github.com/moq-dev/moq/pull/2629) later
generalised the same routing policy to the IETF draft-17+ path.

Cost routing alone ([#2424](https://github.com/moq-dev/moq/pull/2424)) could not close it: with both
relays and all clients opted in, the mesh behaved exactly as before, because **pricing decides between
the routes a relay is willing to offer and does not create one.**

**What remains open.** A graceful source exit is not failed over at all: the relay propagates
completion and the subscriber terminates, because it cannot distinguish "this source is done, and so
is the content" from "this source is done, but an interchangeable one exists". This reads as intended
semantics rather than a defect — it is covered by upstream's model tests — but failover then covers
the *harder* failure mode (host loss) and not the easier, far more common one. The remedy is semantic
and is specified in [#2610](https://github.com/moq-dev/moq/issues/2610) as a publisher-minted epoch
plus an explicit `Ended` flag. **Specified, not shipped.**

### Three values the exporter mints per process — one closed, two open

A 1+1 pair cannot be byte-identical while the exporter renders anything from its own process state
rather than from the broadcast. Three such values were isolated ([T12](test-12-dual-path-handoff.md)):

- **SI emission cadence**, anchored to process start, landed tables on slots where the partner carried
  video: measured at **0.00 %** frame agreement for SDT and NIT over a 45 s overlap. Fixed by
  [#2825](https://github.com/moq-dev/moq/pull/2825), which takes a single-track pair to 100 %. The
  review mattered: the form first proposed inflated PSI (PAT 1,959/1,946 across two legs against
  111/111 for the merged form) and **landed inconsistently, costing 5.9 points of agreement** — a
  one-character change from `!=` to `>` in the due check, which stops a backwards timestamp counting
  as a new slot. **It merged in the `>` form, changing its own measured result**, which is the
  argument for treating unmerged-code evidence as provisional.
- **Continuity counters**, numbered from process state, leave exporters that did not start together
  permanently offset by a constant — the single field whose masking lifts agreement to ~98 %. Filed as
  [#2779](https://github.com/moq-dev/moq/issues/2779). **Open**, and prototyped here rather than only
  described: restarting each PID's counter at the video keyframe boundary and padding every span to a
  multiple of 16 packets takes the same pair from 0.4 % to 99.9 % identical on single-track content
  and from 24.6 % to 93.6 % on multi-track, with both legs continuity-clean. The cost is small in
  aggregate and regressive in detail — 1.5–1.7 % of packets, but **10–18 kb/s per PID almost
  regardless of what that PID carries**, because a PID emitting one or two packets per group is nearly
  always 14 or 15 short of a multiple of 16.
- **Audio/video interleave**: the exporter emits the earliest *available* frame rather than the
  earliest frame, so legs whose bytes arrive at different moments order the same media differently.
  Multi-track content therefore stops at 94–96 % even when co-started. Filed as
  [#2829](https://github.com/moq-dev/moq/issues/2829). **Open**, and the counter fix above is
  conditional on it: the counter becomes an index within a span, so wherever the legs order media
  differently the renumbering diverges with it.

### A takeover livelock — closed

A relay could stay *running* and stop *serving*: a livelock pinned every worker thread inside one
poll, leaving the process alive at 100 % CPU with no logs, no health endpoint and no accepts for
hours, triggered by cluster peer churn. Fixed by
[#2701](https://github.com/moq-dev/moq/pull/2701). The operational lesson outlived the fix and is in
[Architecture](../docs/architecture.md) §9.1: **relay monitoring must test liveness rather than
process existence.**

### A drill contributed back

The two method rules the redundancy work produced — grade beyond one full idle timeout, and never
start a redundancy test's sources independently — are baked into the drill contributed upstream as
[#2545](https://github.com/moq-dev/moq/pull/2545) (`just test failover`), which generates its own
source clip so it depends on no private capture, grades failover and standby-join survival, and
reports the join stall as a measured warning.

**Two of our four reports from that work were artefacts of our own harness**, and both are recorded
with their method rules in [method-notes](method-notes.md) §1 and §5. That ratio is worth stating
openly: a drill that finds bugs in the system under test will also find bugs in itself, and telling
them apart is most of the work.

---

## 4. Congestion control

The loss collapse this campaign measured under QUIC's default CUBIC was reported into the discussion
on [#2432](https://github.com/moq-dev/moq/pull/2432), which exposes
`--server/client-quic-congestion-control {loss|delay}`. Upstream has since made **BBRv1 the default on
quinn** ([#2468](https://github.com/moq-dev/moq/pull/2468)), with the defaults now backend-specific —
quiche to BBRv2, and noq back to CUBIC because BBRv3 carries a subtract-overflow panic under high loss
([noq #768](https://github.com/n0-computer/noq/issues/768)).

**Upstream methodology guidance, adopted here:** the one meaningful congestion-control test is
bufferbloat under a shaped bottleneck, not random loss — *"the best congestion control in the face of
random loss is zero congestion control"* — so the CUBIC-collapse result is about **loss-signal
interpretation**, not congestion-control quality. That is why
[T8b](test-8b-congestion-control.md) exists and why its results are scoped the way they are.

The open question put back to the maintainer on #2432 is whether BBRv2 on quiche is a first-class
supported choice for a permanent fixed-rate trunk, or whether the quinn-BBRv1 intermittency observed
under a shaped bottleneck is a fixable bug. **Unanswered, and one under-provisioned condition is not
enough to press it.**

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
was shorter than that knee, so the original "linear, 650 MB/day, fails the stability criterion"
reading was a measurement-window artefact ([method-notes](method-notes.md) §3).

Confirmed on our own rig afterwards: the slope holds for three windows and breaks in exactly the
window containing the predicted knee, at baseline + 108 MB against a predicted + 97 MB, with two
independent fits putting the per-slot cost at 9.14 and 10.54 KiB against upstream's predicted 9.9 KiB.
Two caveats the prediction did not cover: growth continues at ~8 MB/h past the knee rather than
stopping, and capping streams reduces the ceiling only 3.3× for a 9.8× slot reduction, because
20–30 MB of it is slot-independent.

**No released version of the QUIC library removes it**, so plan for the overhead rather than waiting
for it to go away.

---

## 6. Interoperability

### The announce convention — reported as a hazard, not a bug

`moq-dev`'s publisher withholds its namespace announcement until a peer explicitly asks for it, and
only `moq-dev`'s own relay asks. Every other relay expects a publisher to announce on connect, so the
publisher negotiates, reports no error, and then sends no control message at all.

**Checked against the drafts before reporting, because "interop hazard" and "protocol violation"
warrant very different reports.** Announcing proactively is a **MAY**; the obligation only bites once
someone has subscribed. So `moq-dev` is fully conformant and simultaneously unable to interoperate
with any relay that does not interrogate publishers — which is the normal case. Reported on that basis
as [#2730](https://github.com/moq-dev/moq/issues/2730).

### The empty namespace prefix — a specification inconsistency

The subscriber opens discovery on an *empty* namespace prefix, which one relay rejects outright. The
draft says a namespace of zero fields is a protocol violation, while the working group has stated it
intends to allow an empty tuple for exactly this "give me everything" discovery case. **Neither
implementation is wrong; the specification is**, and it is tracked as
[moq-wg/moq-transport#1457](https://github.com/moq-wg/moq-transport/issues/1457). Our contribution is
a concrete interop data point for that issue.

### A media-level interop profile — contributed

The community interop matrix is control-plane only, so a `setup-only` check reports green against
relays through which not one media byte flows. **An entire class of failure is invisible to the test
the ecosystem reads.**

The argument made to [englishm/moq-interop-runner#32](https://github.com/englishm/moq-interop-runner/issues/32)
is that validating media-level interop does *not* require capturing video frames as played back by a
player: **pick a fixture container that checks itself.** Every PID in a transport stream carries a
4-bit continuity counter, so loss, duplication and reordering are detectable from the received bytes
alone. The whole oracle reduces to one command, and its sensitivity to all three failure modes is
demonstrated rather than asserted. The client is public in [`interop/`](../interop/README.md).

Two harness-level suggestions went with it: a control-plane test for zero-field namespace-subscription
handling (which would generate data for moq-wg#1457), and recording the transport actually used
alongside the negotiated draft — because the client abandons QUIC for a WebSocket fallback on a fixed
200 ms timer, so **any relay much further away than that is silently carried over TCP**, and the
transport under test is not the one you think.

### A flag-alias regression — reported

Dial-side flags renamed on the development branch warn and then do not take effect: isolated one at a
time, both the connect flag and a QUIC tuning flag fail independently, and in each case the warning
fires naming the correct replacement, so the alias is parsed and only the propagation is missing.
Reported as [#2913](https://github.com/moq-dev/moq/issues/2913). Found only because a merge-base
control was run ([method-notes](method-notes.md) §1).

### Corroboration from an independent stack

`moqxr` [PR #21](https://github.com/mondain/moqxr/pull/21) independently reports the same
preannounce split from the other side — including the case where an early publish disturbs namespace
registration so that every later subscribe is rejected — and resolved it by making preannounce opt-in
and default-off. The same PR reports the same idle-timeout behaviour we measured: a publisher with no
subscriber attached dies at ~32 s to the default QUIC idle timeout. **Useful corroboration from an
entirely different stack that the idle timeout is a first-order operational constraint rather than an
artefact of one implementation.**

---

## 7. Documentation

The upstream review of [#2830](https://github.com/moq-dev/moq/pull/2830) objected to a grooming recipe
that invoked a tool with no supported installation path. That objection is what prompted
[T13](test-13-downstream-grooming.md), which graded every off-the-shelf candidate an engineer would
reach for and concluded that **the requirement should be stated precisely with the off-the-shelf
options and their measured limits named, rather than any single tool being named as the answer.**

That conclusion holds whether or not our own tool can be installed — which it now can — because it was
never contingent on that. The installability gap is closed: the egress adapter is now the crate's own
binary rather than an example.
