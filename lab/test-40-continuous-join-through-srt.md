# Test 40 — Does the SRT contribution chain carry the #3533 content-join stall?

**State: run, conclusive.** The two-stage SRT ingest does **not** absorb the trigger. A source whose
content restarts on a continuous timeline stalls `moq export ts` permanently on the post-#3375 build
when it arrives over SRT through the deployed chain shape, exactly as it does through the published
local-pipe reproducer. The pre-#3375 control, on the same host, same chain, same source, is healthy
throughout.

## Objective

[#3533](https://github.com/moq-dev/moq/issues/3533) is reported and reproduced against a **local
pipe**: generator → `tsp` → `moq import ts`. That establishes the defect but not the exposure. The
deployed contribution path is not a pipe — it is two systemd units joined by a loopback multicast
group ([T4](test-4-remote-e2e-srt.md) § *The standing live ingest*), and between the encoder and the
importer sit an SRT receive buffer, a jitter-absorbing re-emission, a multicast socket and a second
`tsp` instance. Any of those could in principle re-align the stream at the join and absorb the
trigger, which would mean the live feed never meets the defect and the fence
[T34](test-34-real-encoder-severity.md) is holding open is not actually load-bearing.

This asks the narrow question: **does the trigger survive the chain?** It is also written to be the
acceptance test for the eventual fix — when a build claims to close #3533, this is the rig that says
whether it did, against the path we actually run.

## Environment

| | |
|---|---|
| Host | Secondary, 8 vCPU / 15.7 GB, Ubuntu 26.04, `eu-west-1b` |
| Relay | The host's own standing relay, `https://localhost:443/anon` |
| Builds | `0e61e35` (#3375, the regression), `025613d` (its parent) — the pinned T27 bisect pair — and `d518b61b`, current `main` |
| Source | `t40_clip.ts`, the leading 200,000 packets of `CNNiEMEA2.ts` (~30 s, 9.95 Mbps CBR, 7 elementary streams) |
| Generator | [`ts-continuous-source.py`](scripts/ts-continuous-source.py), 40 passes |
| Rig | [`t40-continuous-join-srt.sh`](scripts/t40-continuous-join-srt.sh) |
| Window | 150 s, sampled every 5 s — four content joins inside the window |

Both arms ran on **one host**, sequentially, against one relay, with the same generator and the same
clip. That is deliberate and it is the instrument [T34](test-34-real-encoder-severity.md) argued for:
the two-host arrangement that also straddles #3375 varies host, kernel, core count and contribution
path alongside the build, and the single-host pinned-binary pair varies only the build.

The chain runs on its own ports (`SRT 9101`, group `239.255.0.9:5009`) and its own broadcast, so the
standing `srt-ingest` and `moq-live-publisher` units were untouched throughout.

## Procedure

The rig reproduces the deployed chain stage for stage, then drives it from a caller:

```bash
# stage 1 — the srt-ingest shape
tsp -I srt --listener 0.0.0.0:9101 --multiple --transtype live \
    --rcv-latency 2000 --udp-rcvbuf 16777216 \
    -O ip 239.255.0.9:5009 --local-address 127.0.0.1

# stage 2 — the moq-live-publisher shape
tsp -I ip 239.255.0.9:5009 --local-address 127.0.0.1 -O file - \
  | moq --client-connect https://localhost:443/anon --broadcast t40.<arm>.hang import ts

# the source — content restarts, timeline does not
python3 ts-continuous-source.py t40_clip.ts --passes 40 \
  | tsp -I file - -P regulate --pcr-synchronous --wait-min 5 \
        -O srt --caller 127.0.0.1:9101 --transtype live

# the subscriber under test
moq --broadcast t40.<arm>.hang export ts --latency-max 3s > /dev/null
```

The oracle is the subscriber's own emitted-byte counter, `/proc/<pid>/io` `wchar`, sampled every 5 s
and differenced. That is the same instrument #3533 reports against, so the numbers below are directly
comparable with the issue's table.

## Pass criteria, fixed before running

1. The pre-#3375 arm sustains its baseline rate across at least three content joins.
2. If the post-#3375 arm collapses, the collapse coincides with a join rather than with start-up.
3. A collapse counts as *permanent* only if **no** sample after it recovers above a third of
   baseline.

All three were met.

## Results

Per-subscriber emitted rate, Mb/s, one 150 s window per arm:

| t (s) | `025613d` (parent) | `0e61e35` (#3375) |
|---:|---:|---:|
| 10 | 9.92 | 9.92 |
| 15 | 9.43 | 9.43 |
| 20 | 9.71 | 9.71 |
| 25 | 9.77 | 7.02 |
| 30 — **first join** | 9.56 | **0.31** |
| 35 | 8.96 | 0.31 |
| 40 | 9.36 | 0.32 |
| … to 150 | median **9.29**, min 8.86, max 9.92 | median **0.31**, min 0.30, **max 0.32** |

- **The two arms are identical to the hundredth of a Mb/s until the join.** The generator is
  deterministic and the chain is the same, so the divergence is attributable to the build alone.
- **The stall is permanent.** Across 24 samples and four joins after the collapse, the post-#3375
  arm's *maximum* sample is 0.32 Mb/s against a 9.57 Mb/s pre-join median — no partial recovery in
  any sample. This matches #3533's reported 0.31 Mb/s residue on the local-pipe reproducer to within
  the sampling noise, which is corroboration that the same defect is being exercised and not a
  second one with a similar shape.
- **The residue is the PSI, AC-3 and teletext continuing while video and MPEG-1 audio stop**, as
  #3533 describes; 0.31 Mb/s of a 9.95 Mbps source is the right order for that remainder.
- The importer's own log shows the mechanism arriving: `audio stream lost frame sync and resynced
  pid=121 track=".mp2"` with the resync counter climbing one per join (`resyncs=20`,
  `discarded=7140` by the end of the window). The primary audio re-lock at the join is where the
  upstream quest note places the trigger, and it is visible here.

### Current `main` still carries it, on both hosts

The rig was then run against `d518b61b` — `main` as of 2026-09-18, **72 commits after the bisect
pair** — on each host in turn:

| Arm | Build | Host | Baseline | First collapse | Tail max | Verdict |
|---|---|---|---:|---:|---:|---|
| `post3375` | `0e61e35` | secondary | 9.71 | t=30 s | 0.32 | STALLED |
| `pre3375` | `025613d` | secondary | 9.71 | — | 9.92 | HEALTHY |
| `main-d518b61b` | `d518b61b` | secondary | 9.71 | t=30 s | 0.32 | STALLED |
| `primary-newbuild` | `d518b61b` | primary (2 vCPU) | 9.87 | t=30 s | 0.32 | STALLED |

**#3533 is unfixed on current `main`**, with a signature indistinguishable from the original
regression — same collapse point, same 0.31–0.32 Mb/s residue, same permanence. Ten days open with
no upstream comment.

The primary arm was run for a second reason: that host's rebuild produced a binary whose
`--version` reads `0.9.11-d518b61b` where the secondary's reads `0.11.2-d518b61b` from the same
commit and the same tree, which is the stale-version-string gotcha `INSTRUCTIONS` records. Rather
than argue from a cosmetic string, the defect was used as the oracle: `eab96019` (what the host ran
before) predates #3375 and is healthy here, `d518b61b` stalls. **The primary stalls**, so the binary
really is the new code. *A regression with a sharp signature is a build-identity test, and a better
one than a version string.*

## Conclusions

1. **The deployed contribution chain is exposed.** Neither the SRT receive buffer, nor the loopback
   multicast hop, nor the second `tsp` instance re-aligns the stream enough to hide the join. The
   fence [T34](test-34-real-encoder-severity.md) holds open is load-bearing: if the contribution
   encoder ever restarts content on a continuous timeline, a post-#3375 subscriber stops carrying
   video and primary audio and does not recover.
2. **The trigger is now synthesisable on demand**, which it was not before through this path. That
   removes the dependency on the live feed for exercising the defect, and it means the fix can be
   verified the day it lands rather than the next time a real encoder happens to produce a join.
3. **The single-host pinned-binary pair is the right control and it has now been captured**, so
   unifying the two hosts' builds no longer destroys anything. The bisect binaries in
   `~/t27/bisect/` are the control from here on, not the service builds.

## What this does not show

- **Nothing about a real encoder.** The generator's join is a hard cut at an IDR — ordinary in
  broadcast, but not the content a real feed carries, and the coded-frame size at the join is not
  typical. Whether a real encoder produces this junction at all is exactly what
  [T34](test-34-real-encoder-severity.md) exists to answer, and this does not pre-empt it.
- **Nothing about severity in the field.** A permanent stall is unambiguous here because the source
  keeps joining. A source that joins once and never again would show the same collapse, but the
  operational consequence depends on how a deployment notices — and
  [T27](test-27-liveness-detector.md) is where that belongs.

## Corrections

**What was believed:** that unifying the two hosts' builds had to wait for the real-encoder arm,
because the pair straddling #3375 was the only available `OLD`/`NEW` control.

**What is true:** the pinned bisect binaries are a strictly better control — same host, same kernel,
same chain, one variable — and they are unaffected by what the service units run. The two-host
arrangement was never the instrument; it was a coincidence that looked like one.

**Method rule:** *a control made of two production deployments is a coincidence, not an experiment.
If the same comparison can be made from pinned artefacts on one host, the deployments are free to
move.*
