# Lab rigs

Runnable harnesses for experiments in this notebook. They take every machine-specific value
(interface, subscriber IP, rate, delay) from the environment and contain **no addresses,
credentials or personal paths** — the real values live in the git-ignored
`INSTRUCTIONS.local.md`.

| Script | Purpose |
|---|---|
| [`t8b-netns.sh`](t8b-netns.sh) | Self-contained contention rig: two network namespaces on one Linux host, bottleneck + deep queue downstream, base delay both ways. The primary rig for [T8b](../test-8b-congestion-control.md). |
| [`t8b-shaper.sh`](t8b-shaper.sh) | Shaped bottleneck on a real interface, applied to the media flows only via a `prio`+`u32` lane so SSH on a shared host is untouched. The corroborating real-path rig. |
| [`t8b-rtt-probe.sh`](t8b-rtt-probe.sh) | Standing-RTT sampler and percentile summary. For a fixed-rate feed, RTT is a buffer-headroom check (does queuing threaten `--latency-max`?), sampled over the same window as the capture. |
| [`t12-dual-leg.sh`](t12-dual-leg.sh) | One source, two complete delivery legs (publisher → relay → subscriber → RTP/UDP egress), one capture of both. Four egress arms and a timed injection per run. The rig for [T12](../test-12-dual-path-handoff.md). |
| [`t12-merge-oracle.py`](t12-merge-oracle.py) | The receiver. Reconstructs from one capture what an ST 2022-7 sequence merge and an IRD-style input-select would have produced, and reports alignment yield, loss at the merged output, switch behaviour and leg skew. |
| [`t12-grade.sh`](t12-grade.sh) | Grades one captured run — oracle plus a TSDuck verdict on each reconstruction — into two CSVs. Reads only the capture, so a campaign can be re-graded when the oracle changes. |
| [`t12-matrix.sh`](t12-matrix.sh) | Runs the arm × injection matrix and grades every cell. |
| [`t12-analyse.sh`](t12-analyse.sh) | TSDuck verdict on a single reconstructed output: continuity, PCR interval distribution, `pcrverify`, bitrate. |
| [`t12-conflict-anatomy.py`](t12-conflict-anatomy.py) | When two legs disagree at the same RTP sequence number, says *how*: same packets with different PCR stamps, same packets with different stuffing, or different content. The distinction decides whether a receiver could recover the pair. |
| [`t12-maskcmp.py`](t12-maskcmp.py) | Compares the legs datagram by datagram at equal sequence numbers, raw and with the continuity counter masked. Separates *the groomer placed different bytes* from *an upstream stage renumbered the same bytes*. |
| [`t12-seqskew.py`](t12-seqskew.py) | Differential arrival at equal sequence numbers, with no correlation step. |
| [`t12-resume.py`](t12-resume.py) | For a leg that stopped and came back: how far its numbering drifted from its partner's across the outage, measured without needing payload identity. |
| [`t12-placement.py`](t12-placement.py) | Strips stuffing and asks where one leg's programme sits in its partner's output. |
| [`t12-join-diagnostic.sh`](t12-join-diagnostic.sh) | A single stream-clocked leg joining a broadcast already in progress, run to read the groomer's own counters (`start_backlog`, `resyncs`, `dropped`) rather than to grade a pair. |

**Which comparison to trust.** `t12-merge-oracle.py` recovers the legs' sequence offset by voting on
payload identity and derives skew by pairing datagrams through that offset, so on a pair that differs
in *any* field it votes on a handful of datagrams and returns a spurious offset and a spurious skew —
it prints its vote share as a confidence, and a low one invalidates both. Where the legs are not
byte-identical, use `t12-maskcmp.py` and `t12-seqskew.py`, which compare at equal sequence numbers
and never correlate.

Both shaper rigs offer the same three queue disciplines at one bottleneck rate — `bloat`
(deep FIFO), `codel` (`fq_codel`), and `cake` — so the AQM counterfactual is a single-word
change with everything else held constant.

**Before trusting any measurement, calibrate:** confirm idle RTT sits at the configured base and
that a saturating flow (a loss-based CUBIC run doubles as one) drives it to base + queue depth. A
`tc` chain that looks correct can still queue in the wrong place. The procedure is in
[T8b](../test-8b-congestion-control.md) §0.

**On a shared host,** `t8b-shaper.sh` arms a watchdog (default 90 min) that tears the lane down on
its own, and `clear` removes it immediately. A shaped lane left behind is a trap for the next
person to use the box. `t12-dual-leg.sh` arms the same kind of watchdog on its per-leg lane.

**The T12 rig grades itself before it grades MoQ.** Every run reports whether either leg was empty,
what the pacer dropped, and whether a relay failed to bind; a leaked relay from a previous run is
the failure mode to watch for, because the next run's publisher lands on it, the subscriber joins a
stale announce, and the leg goes quiet for reasons that have nothing to do with the condition under
test. Run the arm C control first: it must be hitless, or no other arm's number means anything.
