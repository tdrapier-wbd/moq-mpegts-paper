# Test 40 — Does the SRT contribution chain carry the #3533 content-join stall?

**State: run, conclusive.** The two-stage SRT ingest does **not** absorb the trigger. On builds through
`d518b61b`, a source whose content restarts on a continuous timeline stalls `moq export ts` permanently
when it arrives over SRT through the deployed chain shape, exactly as it does through the published
local-pipe reproducer. On **`5d0991b9`** (`main` after [#3793](https://github.com/moq-dev/moq/pull/3793),
which carries [#3784](https://github.com/moq-dev/moq/pull/3784) closing
[#3533](https://github.com/moq-dev/moq/issues/3533), the **0.31 Mb/s export stall is gone** — the
acceptance oracle reads full rate through the first join — but a **homogeneous** build hits a different
failure at the join: `moq import ts` exits with *frame timestamp is below the live edge*.

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

### `5d0991b9` — #3533 closed; a new join failure on the dev line

Re-run against **`5d0991b9`** after [#3784](https://github.com/moq-dev/moq/pull/3784) merged:

| Arm | Build | Relay | Baseline (≤20 s) | Through first join | Verdict |
|---|---|---|---:|---|---|
| `main-5d0991b9` | `5d0991b9` | standing `d518b61b` | 9.32 Mb/s | peak **9.86 Mb/s** at t=25 s; export exits at t=30 s with *TS track layout changed* | **No #3533 stall** — full rate until exit |
| `main-5d0991b9-swap` | `5d0991b9` | standing `5d0991b9` | — | import exits at first join: *frame timestamp is below the live edge*; export oracle ~0 Mb/s | **Join failure, not stall** |

Upstream's `export_test::discontinuity_flags_the_break_once_across_tracks` — which embeds the #3533
content-join fence — **passes** on this build (103/103 `export_test` cases).

## Conclusions

1. **The deployed contribution chain is exposed** — the SRT buffer, loopback multicast hop and second
   `tsp` instance do not absorb the join trigger ([T34](test-34-real-encoder-severity.md) remains
   load-bearing for a *real* encoder's severity).
2. **#3533's export stall is fixed on `5d0991b9`.** The 0.31 Mb/s residue signature does not appear;
   the unit test and the mixed-build T40 arm both show full rate through the first join.
3. **Continuous-source publishing on homogeneous `5d0991b9` still fails at the join** — import exits
   with *frame timestamp is below the live edge*. That is a separate defect from #3533 and it blocks
   the permanence re-soak and any long run on `ts-continuous-source.py` until it is resolved upstream.
4. **The pinned bisect pair remains the control** for the pre-fix stall signature; service builds may
   move independently.

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
