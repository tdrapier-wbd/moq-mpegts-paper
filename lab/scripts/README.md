# Lab rigs

Runnable harnesses for experiments in this notebook. They take every machine-specific value
(interface, subscriber IP, rate, delay) from the environment and contain **no addresses,
credentials or personal paths** — the real values live in the git-ignored
`INSTRUCTIONS.local.md`.

| Script | Purpose |
|---|---|
| [`t8b-netns.sh`](t8b-netns.sh) | Self-contained bufferbloat rig: two network namespaces on one Linux host, bottleneck + deep queue downstream, base delay both ways. The primary rig for [T8b](../test-8b-bufferbloat-cc.md). |
| [`t8b-shaper.sh`](t8b-shaper.sh) | Shaped bottleneck on a real interface, applied to the media flows only via a `prio`+`u32` lane so SSH on a shared host is untouched. The corroborating real-path rig. |
| [`t8b-rtt-probe.sh`](t8b-rtt-probe.sh) | Standing-RTT-under-load sampler and percentile summary. Goodput alone cannot distinguish a good controller from a bloated one, so RTT is sampled over the same window as the capture. |

Both shaper rigs offer the same three queue disciplines at one bottleneck rate — `bloat`
(deep FIFO), `codel` (`fq_codel`), and `cake` — so the AQM counterfactual is a single-word
change with everything else held constant.

**Before trusting any measurement, calibrate:** confirm idle RTT sits at the configured base and
that a saturating flow drives it to base + queue depth. A `tc` chain that looks correct can still
queue in the wrong place. The procedure is in [T8b](../test-8b-bufferbloat-cc.md) §0.

**On a shared host,** `t8b-shaper.sh` arms a watchdog (default 90 min) that tears the lane down on
its own, and `clear` removes it immediately. A shaped lane left behind is a trap for the next
person to use the box.
