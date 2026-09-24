# Test 41 — Which TS stream kinds re-anchor below the live edge, and for how many wraps?

**State: run, conclusive.** `moq import ts` aborts with *frame timestamp is below the live edge* on
the **first** unflagged backward timestamp for H.264, and on the **second** for legacy audio (MPEG-1
Layer II and AC-3). Legacy audio therefore has re-anchoring that works exactly once: it absorbs one
content join or loop wrap and fails at the next. Measured on `ffa5b81b`, which is `main` after
[#3987](https://github.com/moq-dev/moq/pull/3987) closed
[#3798](https://github.com/moq-dev/moq/issues/3798) — a closure that added a plan and no code, so the
defect is live.

## Objective

[#3798](https://github.com/moq-dev/moq/issues/3798) is measured in
[T21](test-21-permanence-soak.md) and [T40](test-40-continuous-join-through-srt.md) as an outcome: a
continuous source publishes for about ten minutes and then the importer exits. That is enough to
block the permanence soak but not enough to describe the defect, because the campaign's clips carry
seven elementary streams and the abort takes the whole import down, so whichever PID fails first
hides the behaviour of the other six.

Upstream's plan for the fix (`quest/m1/ts-import-reanchor.md`, merged in
[#3987](https://github.com/moq-dev/moq/pull/3987)) makes two structural claims and states that
neither has been reproduced in-tree — *"Known triggers, none yet reproduced in-tree"*:

1. Only the legacy path re-anchors. H.264, H.265, AAC, Opus, verbatim PES and sections abort on the
   first timestamp below the producer's live edge.
2. The legacy path's shift *"is set once, so a second unflagged loop wrap lands below the edge
   again"*.

Claim 2 is the one that decides the shape of the fix — whether it is "apply the existing re-anchor to
every stream kind" or "apply it **and** make it cumulative" — and it is cheap to measure. This
experiment isolates one elementary stream per arm so that an abort can be attributed to a stream
kind, and counts wraps rather than seconds so the answer is a number of joins survived rather than an
elapsed time that depends on the fixture's length.

## Environment

| | |
|---|---|
| Host | Secondary, 8 vCPU / 15.7 GB, Ubuntu 26.04, `eu-west-1b` |
| Build | **`ffa5b81b`** (noq), `moq 0.12.1`, built by [`ec2-build-main.sh`](scripts/ec2-build-main.sh) |
| Relay | Dedicated, same build, `127.0.0.1:4493`, `--quic-congestion-control loss` |
| Source | `clip30.ts`, the leading ~30 s of `CNNiEMEA2.ts` |
| Fixtures | [`t41-make-fixtures.sh`](scripts/t41-make-fixtures.sh) — one elementary stream each, own PCR |
| Rig | [`t41-reanchor-coverage.sh`](scripts/t41-reanchor-coverage.sh) |
| Domain | **wire**, at **P1**; one sample per arm |

The whole chain is one build, on one host, against one relay, with three fixtures cut from one clip.
The only variable between arms is the elementary stream's codec.

### The fixtures need their own PCR, and two obvious ways of cutting them do not provide one

`tsp -P filter` keeps the PIDs asked for but does not move the PCR, so an audio-only filter output
reports `pcrbitrate=0` and is not a valid transport stream; `-P pcradjust` does not rescue it,
because it rewrites PCRs that exist and cannot mint them. The audio arms are therefore remuxed with
`ffmpeg`, whose mpegts muxer does synthesise a PCR PID, and only the video arm — which already
carries the service PCR — is cut with `tsp`. Every fixture is validated for a non-zero `pcrbitrate`
before use, because a fixture without PCR measures nothing and fails for an unrelated reason.

| Fixture | Elementary stream | Bytes | Declared rate | Wrap period |
|---|---|---:|---:|---:|
| `fx-h264` | H.264 video, PID 111 (high profile, B-frames) | 34,217,692 | 9,051,630 b/s | 30.2 s |
| `fx-legacy` | MPEG-1 Layer II audio, PID 121 | 1,506,444 | 400,000 b/s | 30.1 s |
| `fx-ac3` | AC-3 audio, PID 123 | 1,505,128 | 400,000 b/s | 30.1 s |

`fx-h264` keeps the source PMT, which still *declares* the audio, teletext and SCTE-35 PIDs, but
`tsp -P analyze` confirms all of them carry **0 packets** — only PAT (242), PMT (243) and video
(181,524) are populated. A declared-but-empty PID writes no frames and so cannot be what aborts,
which is what makes the attribution to H.264 sound.

## Procedure

Each arm loops one fixture with `tsp --infinite`, which restarts both PCR and PTS **without** setting
the discontinuity indicator — the unflagged backward jump claim 2 is about — and publishes it:

```bash
tsp --realtime -I file fx-<kind>.ts --infinite -P regulate --pcr-synchronous -O file - \
  | moq --connect-tls-insecure --connect https://127.0.0.1:4493 \
        --broadcast t41.fx-<kind>.hang import ts
```

The oracle is the importer's own exit: the arm is watched until the publishing process disappears,
and the elapsed time is divided by the fixture's wrap period to give the wrap index it died on. The
rig waits for the process to *appear* before it starts watching for it to disappear, because absence
is also what "has not started yet" looks like and polling for it first scores every arm as an instant
failure — see [method-notes](method-notes.md) § *A `pgrep` wait loop matches the command that
contains it* for the neighbouring trap.

## Pass criteria, fixed before running

This is a characterisation of a known defect, so "pass" marks a claim confirmed rather than a gate
cleared:

1. Every arm must publish successfully before its first wrap, or the arm is void — an abort at
   start-up measures the fixture, not the defect.
2. Claim 1 holds if the H.264 arm dies on wrap 1 and at least one other arm does not.
3. Claim 2 holds if a re-anchoring arm dies on wrap 2 rather than surviving three.
4. Any arm surviving three wraps is reported as re-anchoring cumulatively already.

All four were met or discharged.

## Results

| Fixture | Stream kind | Wrap period | Died at | **Wrap index** | Error |
|---|---|---:|---:|---:|---|
| `fx-h264` | H.264 video | 30.2 s | 30.3 s | **1.00** | *frame timestamp is below the live edge* |
| `fx-legacy` | MPEG-1 Layer II | 30.1 s | 59.6 s | **1.98** | *frame timestamp is below the live edge* |
| `fx-ac3` | AC-3 | 30.1 s | 59.6 s | **1.98** | *frame timestamp is below the live edge* |

**H.264 does not re-anchor at all.** It aborts 0.1 s after its first wrap, which is the first frame
carrying a timestamp below the edge. This confirms claim 1 and it is the behaviour the campaign has
been seeing all along: every clip in the lab is video-bearing, so every observed #3798 abort has been
this arm, and the ten-minute figure in [T21](test-21-permanence-soak.md) is the length of
`CNNiEMEA2.ts` rather than a property of the defect.

**Legacy audio re-anchors exactly once.** Both legacy arms publish through their first wrap and abort
on the second, at a wrap index of 1.98 — just inside the second wrap, which is where the first frame
below the *re-anchored* edge falls. **This confirms claim 2 and is the part upstream records as
unreproduced.** The consequence for the fix is direct: lifting the existing `reanchor` into every
stream kind would move every arm from wrap 1 to wrap 2 and leave the defect in place for any source
that joins more than once, which is every looping playout and every channel that takes more than one
break. The offset has to grow, not merely exist.

**AC-3 re-anchors too, which the plan's wording does not say.** The plan describes the re-anchoring
path as *"legacy MPEG audio"* and lists AC-3 among the kinds that abort immediately. The measurement
puts AC-3 at wrap 1.98, identical to MPEG-1 Layer II, and the source agrees: `StreamType::
DolbyDigitalUpToSixChannelAudio` and `…ForAtsc` both dispatch to `legacy_stream`, and
`rs/moq-mux/src/container/ts/import.rs` documents `LegacyStream` as *"one stream of legacy broadcast
audio (MP2, AC-3, E-AC-3), carried verbatim"*. So the dividing line is the `LegacyStream` type and not
the MPEG-1 codec, and it already covers three codecs. This is a clarification of the plan rather than
a contradiction of it, but it changes which arms a fix has to touch.

### What the source says, and why it was read as well as measured

The mechanism is short enough to state exactly, and reading it turns the measurement from a
correlation into an explanation. `reanchor` exists only in `impl LegacyStream`; every other stream
kind calls `Producer::write` directly. Inside it:

```rust
if let Some(delta) = self.shift {
    return Ok(Some(pts.checked_add(delta.convert(pts.scale())?)?));
}
```

The first backward timestamp computes `delta = edge - pts` and stores it. Every later frame is
shifted by that same stored `delta`, which is correct for the remainder of the current loop and wrong
for the next one, because the second wrap's timestamps are below the edge the *first* shift
established. `discontinuity()` sets `self.shift = None`, which is why a source that flags its breaks
is unaffected and why the defect needs an *unflagged* wrap to appear at all.

## Conclusions

1. **The defect has two separate parts, and only one of them is widely visible.** Non-legacy streams
   have no re-anchoring; legacy streams have re-anchoring that survives one join. A fix that
   addresses only the first leaves every multi-join source failing on its second join.
2. **Upstream's claim 2 is confirmed by measurement**, which is what its plan asks for and records as
   missing. The rig and fixtures are small, deterministic and contributed
   ([upstream-contributions](upstream-contributions.md)).
3. **`LegacyStream` covers MP2, AC-3 and E-AC-3.** Any enumeration of "which kinds re-anchor" should
   name the type rather than the codec.
4. **No campaign result changes.** Every #3798 observation in this repository was taken on a
   video-bearing clip, which is the wrap-1 arm, so the recorded symptom and its timing stand.

## What this does not show

- **Nothing about B-frames specifically.** The plan's first hypothesis is that a new IDR after a join
  can land below the last P-frame's PTS *on a continuous PCR*, with no wrap at all. This experiment
  uses a wrap, which is a different and blunter trigger, so it neither confirms nor refutes that
  path. The H.264 fixture does carry B-frames, but the arm does not isolate them.
- **Nothing about sections.** The plan's third hypothesis concerns SCTE-35 and teletext taking
  `last_pts` from a B-frame's lower PTS. No section-only fixture was built, because a section stream
  with its own PCR and no media is not a stream any encoder emits and the arm would have been
  contrived.
- **Nothing about AAC, Opus, H.265 or verbatim PES.** They are presumed to behave as H.264 does
  because they share the direct-`write` path, but presumption is not measurement and the campaign's
  clips do not carry them.
- **One sample per arm.** The result is a wrap index, not a rate, and the two legacy arms agreeing to
  0.01 is corroboration; but a defect that depends on where a frame falls relative to a boundary
  could in principle land differently on a fixture whose wrap does not coincide with a frame
  boundary.
