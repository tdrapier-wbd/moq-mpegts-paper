# Test 65 — What an HLS input keeps: our segmented output against free HLS receivers

**State: run once, with a control source for the validator.** H1 fails on the broadcast clip, on the
clip's properties and on two of `tsp -O hls`'s; H2 and H3 hold. Rig:
[`t65-hls-profile.sh`](scripts/t65-hls-profile.sh); graders [`ts-si-survival.py`](scripts/ts-si-survival.py),
[`ts-pid-complete.py`](scripts/ts-pid-complete.py) and [`t65-seg-structure.py`](scripts/t65-seg-structure.py).

**Result.** An HLS input that hands on the segments' bytes (TSDuck, GStreamer's `hlsdemux`, ours) keeps
every DVB table and SCTE-35 section verbatim from either packager; FFmpeg's remux keeps the pictures,
sound and teletext and replaces the rest of the multiplex. Apple's validator fails every segment of the
broadcast clip from either packager on interlace and open GOP, which contribution feeds normally have,
and passes a progressive closed-GOP source from both. HLS conformance as Apple's validator reads it is
therefore neither necessary nor sufficient for an IRD-facing profile: the profile has to ask for
byte-faithful reception, and to allow interlaced, open-GOP video.

## Objective

Several IRD and gateway vendors list HLS input with transport-stream output, unmeasured
([comparison](../docs/comparison.md) §4.4). Whether the segmented lane can feed such an input directly
turns on two things no hardware is needed to measure: whether our packagers' output is HLS as the
reference validator reads it, and whether an HLS input built on a generic stack hands on the DVB
service information and SCTE-35 a broadcast receiver needs, or only the audio and video a player needs.
The answer is what a published receive profile ([economics](../docs/economics.md) §8.5) would have to
require of each side.

**Falsifies:** that a TS-in-HLS stream handed to an HLS input arrives with its DVB metadata whatever
stack the input is built on, so that conformance to HLS is all a receive profile need ask; and that
our epoch-locked segmenter's output is conformant HLS.

**Already known, not re-measured:** `tsp -O hls` into `tsp -I hls` is verbatim in payload, SDT, NIT,
CAT and TDT/TOT included ([T3](test-3-opaque-transparency.md)); Apple's validator passes `tsp -O hls`
on a complete playlist of a synthetic fixture with no DVB SI, which FFmpeg, VLC and a bare `curl`
loop read with PAT, PMT and stream inventory intact ([T11](test-11-interop.md)).

## Design

One host (the laptop), loopback, nginx as the origin. The source is the first 180 s of
`contrib-10m_eit_full.ts`: H.264 1080i25 (PCR), MP2, AC-3, teletext, three SCTE-35 PIDs, PAT, PMT,
NIT, SDT, EIT present/following and schedule, TDT; no CAT, no TOT. Both packagers read it at once,
each through its own `tsp -P regulate --pcr-synchronous`.

| Packager | Configuration |
|---|---|
| **P-T** `tsp -O hls` (TSDuck 3.45) | 2 s, `--intra-close --align-first-segment --live 6 --live-extra-segments 3` ([T3](test-3-opaque-transparency.md)'s) |
| **P-E** our epoch segmenter | `t61-epochseg.py`'s `Segmenter`, unchanged, as [T59](test-59-segmented-1plus1-cloudfront.md)–T63 run it: D = 2 s, window 6, extra 3, target 4, `--pdt`; fed from a pipe by [`t65-epochseg-stdin.py`](scripts/t65-epochseg-stdin.py) |

Against each packager, concurrently, for 120 s from a full live window:

| Receiver | Stands for |
|---|---|
| **R-tsp** `tsp -I hls --live` | the control: verbatim on P-T ([T3](test-3-opaque-transparency.md)) |
| **R-ff** FFmpeg 9.0.2, `-map 0 -c copy -copyts -f mpegts` | an input that demuxes and remuxes, configured to keep every stream it recognises |
| **R-gst** GStreamer 1.28.8, `souphttpsrc ! hlsdemux ! filesink` | an input that hands on the segments' bytes |
| **R-b8** [`b8-hls-recv.py`](scripts/b8-hls-recv.py) | our receiver, as T59–T63 run it |
| **V** `mediastreamvalidator` 1.26.143, 90 s | the conformance judge |

## Pass criteria (fixed before the first run)

- **C1, conformance.** Per packager, the validator reports 0 errors. Warnings are recorded with
  their text.
- **C2, structure.** Every segment the rig snapshots holds exactly one programme in its PAT, a PAT
  and a PMT, and opens at a random access point (its first video packet starts a PES and sets
  `random_access_indicator`). Whether its first two packets are the PAT and PMT, which RFC 8216 §3.2
  recommends, is recorded and is not a pass condition.
- **C3, kept.** On the source span the output covers (its first to last video PES, located in the
  source by PTS), a PSI/SI table or section-carrying PID is **kept** when the output carries at least
  the source's sections less two, every one byte-identical to a source section and CRC-valid; an
  elementary-stream PID is kept when `ts-pid-complete.py` reports no unit missing. A receiver
  **meets the profile** on a packager when every row is kept.

**Hypotheses, registered:** H1, both packagers pass C1 and C2. H2, R-tsp, R-gst and R-b8 meet the
profile on both packagers. H3, R-ff does not: it rewrites PAT, PMT and SDT and drops NIT, EIT and TDT.

**Void if** either grader, given the source against itself, does not pass it; if, given `neg.ts` (the
source less SDT 0x11, TDT 0x14, teletext 131 and SCTE-35 142), the SI grader does not read exactly the
SDT, TDT and 142 rows lost, or `ts-pid-complete.py` does not flag exactly 131 and 142; or if a
receiver's output covers under 60 s.

## Procedure

```bash
cd ~/t65 && head -c $((188 * 1190400)) ~/contrib-10m_eit_full.ts > src.ts          # 180 s
tsp -I file src.ts -P filter --negate --pid 0x11 --pid 0x14 --pid 131 --pid 142 -O file neg.ts
lab/scripts/t65-hls-profile.sh ~/t65/src.ts ~/t65/run1 120
python3 lab/scripts/t65-seg-structure.py ~/t65/run1/snap/t ~/t65/run1/snap/e
for r in tsp b8 gst ff; do for a in t e; do
	python3 lab/scripts/ts-si-survival.py ~/t65/src.ts ~/t65/run1/rx/$r-$a.ts
	python3 lab/scripts/ts-pid-complete.py ~/t65/src.ts ~/t65/run1/rx/$r-$a.ts
done; done
```

**The control source**, added after the first run to attribute what the validator found (it changes
no criterion): 180 s of FFmpeg `testsrc2`, 1080p25 H.264 with two B-frames and an IDR every 2 s
(`-g 50 -keyint_min 50 -sc_threshold 0`), MP2 and AC-3, 8 Mb/s, through the same rig for 100 s.
GStreamer's `hlsdemux` holds a live playlist open through `-e`'s end-of-stream, so the rig kills it
10 s after its window.

## Results

**Controls: valid.** Each grader passes the source against itself. On `neg.ts` the SI grader loses
exactly the SDT, TDT and PID 142 rows and `ts-pid-complete.py` flags exactly 131 and 142. Every
capture spans 120–172 s of source.

### C1: the validator

Segments processed: 42 (`tsp -O hls`) and 49 (ours) on the clip; 50 and 49 on the control. Each
issue is a MUST unless marked; counts are segments.

| Issue | P-T, clip | P-E, clip | P-T, control | P-E, control |
|---|---:|---:|---:|---:|
| Interlaced video, must be progressive | 42 | 48 | — | — |
| Segment holds no IDR frame | 37 | 43 | — | — |
| Format change without a discontinuity tag | 22 | 19 | — | — |
| Playlist and segment duration disagree | 4 | 3 | — | — |
| `EXTINF`, rounded, above `TARGETDURATION` | 9 | — | — | — |
| `EXT-X-INDEPENDENT-SEGMENTS` declared, segment does not start on a sync frame | 41 | — | — | — |
| Should declare `EXT-X-INDEPENDENT-SEGMENTS` (advisory) | — | — | — | 1 |

The first four rows are the clip's: 1080i25, open GOP (one segment in 42 opens on an IDR), and a
change the validator does not name that falls on about half the segments from either packager. None
survives the control. The last three are the packagers'. **`tsp -O hls` breaks two playlist rules**,
in 3.45 as run and, by its source, on `main`: it closes a segment at the first I-frame after `--duration`, up to
`--max-extra-duration` (2 s) later, while writing `--duration` as the target, so a clip whose random
access points (1.15 s apart here) do not divide the duration overshoots it; and it writes
`EXT-X-INDEPENDENT-SEGMENTS` whenever `--slice-only` is off, without `--intra-close` too, where no
segment opens at a random access point. Our segmenter's fixed target of 4 s covers its 1.20–2.84 s
segments (2.00 s on the control), and it omits the tag, which is right for open GOP and draws the advisory on closed GOP.

### C2: structure

| | Segments | One programme | PAT and PMT | Opens at a RAP | PAT, PMT first |
|---|---:|---:|---:|---:|---:|
| P-T, clip | 57 | 57 | 57 | 57 | 57 |
| P-E, clip | 67 | 67 | 67 | 67 | 0 |
| P-T, control | 57 | 57 | 57 | 57 | 57 |
| P-E, control | 57 | 57 | 57 | 57 | 0 |

Our segments open on the video packet and carry the PAT and PMT later; no receiver here, and not
the validator, objected.

### C3: what each receiver keeps (the clip)

| Receiver | P-T | P-E |
|---|---|---|
| R-tsp | all 10 SI rows and 7 PIDs kept | all kept |
| R-gst | all kept | all kept |
| R-b8 | all kept | all kept |
| R-ff | none of the 10 SI rows | none |

Kept means verbatim: on the six passing captures every section is a source section, none fails its
CRC, and no row is short. **FFmpeg replaces the multiplex**, the same on both packagers:

- its own PAT, PMT and SDT (0 % verbatim), under its defaults: service 1, transport stream 1,
  original network 65281, service and provider names `Service01` and `FFmpeg`;
- no NIT, EIT present/following, EIT schedule or TDT;
- every PID renumbered (PMT 4096, streams 256–262), and SCTE-35 carried as PES with stream ID 0xFC
  rather than as sections, which a splicer reading stream type 0x86 does not see;
- with its PIDs mapped back (figures from P-T), teletext complete; 511 of 4,446 video PES re-stamped one field (20 ms)
  early; audio re-packed (MP2 from nine frames a PES to five, AC-3 from nine to three), every PES
  stamped a constant off the source's frame times (MP2 8 ms; AC-3 24 ms modulo its 32 ms frame).

## Conclusions

1. **Two classes of HLS input, and only one serves an IRD.** Reception that hands on the segments'
   packets keeps the DVB layer whole; reception that demuxes and remuxes keeps what a player needs.
   Which class a product's HLS input is cannot be read from a datasheet that says "HLS in, TS out".
2. **Apple's validator is the wrong judge of a broadcast receive profile.** It rules on Apple's
   device requirements, and a contribution feed fails them whatever the packager. An HLS input
   that enforced them would refuse the feed.
3. **Our segmenter's planned fixes, corrected.** `EXT-X-INDEPENDENT-SEGMENTS` belongs only where every
   segment opens on an IDR (a closed-GOP source); on this clip it would be false. Cutting at the PAT
   before the random access point remains a SHOULD that no receiver here needed.
4. **`tsp -O hls` is not a conformant live packager for open-GOP contribution** on either rule above.
   A synthetic reproducer shows a third defect: without access unit delimiters it finds no open-GOP
   I-frame, and `--max-extra-duration` never forces the close, so a 30 s source became one segment.
   All three are reportable upstream to TSDuck.

## The receive profile these results imply (draft)

Measured here unless marked; *untested* clauses are design.

**The packager MUST:** carry one programme per segment, with a PAT and PMT in each; open each segment
at a random access point flagged by `random_access_indicator`, an I-frame that need not be an IDR;
leave the multiplex's SI and SCTE-35 in the segments unchanged; write a `TARGETDURATION` no rounded
`EXTINF` exceeds; declare `EXT-X-INDEPENDENT-SEGMENTS` only for closed-GOP sources; write
`EXT-X-PROGRAM-DATE-TIME` on every segment, for receivers released in phase
([T63](test-63-pdt-anchored-release.md)); mark a change of source with `EXT-X-DISCONTINUITY`
(*untested*). It SHOULD put the PAT and PMT first.

**The receiver MUST:** hand on each segment's packets unchanged and in order, every PID included
whether or not the PMT lists it; accept interlaced and open-GOP video; survive the failure of one
origin or pathway, which neither TSDuck's HLS input nor FFmpeg does
([T6](test-6-relay-resilience.md)) and ours does ([T59](test-59-segmented-1plus1-cloudfront.md),
[T61](test-61-origin-group-failover.md)); and pace its output to the PCR before an IRD
([T16](test-16-grooming-segmented-http.md)).

## Limits

No IRD is measured: the stacks stand in for what an HLS input may be built on, and which one a
product uses is not known. One clip, one run, loopback, healthy origin; a 120 s window holds 8 TDT
and 12 EIT schedule cycles. The clip has no CAT and no TOT, which T3 carried through TSDuck. What the
validator calls a format change on this clip is not identified.
