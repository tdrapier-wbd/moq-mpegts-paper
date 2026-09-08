# Raw captures — the #3375 continuous-source regression (T27)

Kept because the claim is an attribution to a single upstream commit, and an attribution has to be
defensible from the measurements rather than from the write-up.
See [T27](../../test-27-liveness-detector.md) and the
[draft report](../../../docs/upstream/3375-continuous-source-regression.local.md).

Topology throughout: source and subscribers on one EC2 host, relay alone on another,
`--client-quic-gso=true`, `--latency-max 3s` unless a column says otherwise. Rates are each
subscriber's *emitted* bytes from `/proc/<pid>/io` `wchar`, so a stalled exporter that is still
receiving shows as a low number rather than as a dead process.

| File | What it is |
|---|---|
| `vercmp-600s-clip.csv` | The first version comparison, on the full 600 s clip: two subscribers on T21's build, two on the build under test, one publisher, one relay, one join at t ≈ 600. Columns are `mbps_<n>_<latmax>-<build>`. The old build crosses the join at full rate; the new one collapses. |
| `bisect.out` | Full `git bisect run` log over the 53 commits between T21's build and the build under test, including each step's build and per-step verdict. |
| `bisect-verdicts.txt` | The six verdict lines only. Each carries the candidate's and the **control's** worst post-settle sample; the control is a known-good binary in the same run, healthy at ~9.1 Mb/s in every step. |
| `confirm-parent-vs-3375.csv` | The confirmation against `0e61e35`'s own parent `025613d`, two replicates per build, ~7 joins in 240 s on a 30 s clip. Column order is parent, #3375, parent, #3375. |
| `truerewind-parent-vs-3375.csv` | The same two builds on a source that *really* rewinds (`tsp --infinite`). The result is the inverse: the parent stalls at 0.00 Mb/s, #3375 sustains ~8.66 Mb/s. This is why the finding is "traded", not "broke". |
| `liveness-3375.jsonl`, `liveness-parent.jsonl` | Per-PID liveness detector output on each build's exporter, run simultaneously on the same source, relay and join. The parent's file contains `discontinuities 0`; the #3375 file contains the `-119.35 s` delivered-clock step and the two PIDs that never clear. |

**A note on reading the 30 s clip.** It is a byte truncation of the 600 s one to a whole number of
188-byte packets, so its join is not at a clean GOP boundary. That does not affect what is measured
here: the same collapse to the same figure occurs on the untruncated 600 s clip
(`vercmp-600s-clip.csv`), and the truncation exists only to make the join arrive every 30 s instead of
every 600 s.
