# Test 78 — A segmented origin under many edges

**State: run once. Every step kept up and there is no knee within 128 edges: at 3.2 Gb/s nginx took 2.4 % of a core and the host 3.8 % of its CPU.**

## Objective

The question [Evidence](evidence.md) §5 held open: what does a segmented origin cost at fan-out? At two receivers no origin process took over 6 % of a core and memory stayed flat for 72 h ([T62](test-62-origin-group-soak.md)); the only origin measured under load was `python3 -m http.server`. A CDN without an origin shield sends the origin one request stream per edge cache, so the question is how the design's origin (nginx in front of the live segmenter, on a host that also carries the live feed) behaves as that count grows, and where it stops keeping up.

## Environment

Pathway B of T76's rig on the secondary (c6in.2xlarge, 8 vCPU): nginx with 2 workers and `sendfile`, the segmenter cutting the live 26 Mb/s feed into 2 s segments, the guard; the host's standing live-feed units beside it. The load from the tertiary over the private network: [`t78-edge-load.py`](scripts/t78-edge-load.py), N simulated edges in 8 processes, each polling the playlist once a second, as an edge revalidating a `max-age=1` object, and fetching each newly listed segment once, with the origin header. Steps of N = 4, 16, 64 and 128 edges, 120 s each, 30 s apart. [`t78-drive.sh`](scripts/t78-drive.sh) samples the origin every 5 s: CPU of nginx (all workers), the segmenter and the guard; the host's CPU and its egress.

## Pass criteria, fixed before running

1. **Keeping up:** at each step, report the segment fetches' total time (median, 99th percentile, maximum), the playlist's time to first byte, and every error. A step keeps up when its 99th percentile segment fetch is under 1 s (half a segment) and nothing fails.
2. **The knee:** the smallest N that does not keep up, or the segmenter logging a stall or reset during a step; none within the ramp is reported as "above 128".
3. **Cost:** per step, nginx's and the segmenter's CPU (% of a core) and the host's egress (Gb/s), and their slope per edge.
4. **Stop rule:** the ramp stops at the first step where the host's CPU passes 75 %, any live-feed unit restarts, or the segmenter resets; that step is the result.

_Predicted:_ nginx serving from the page cache keeps up through 128 edges (3.3 Gb/s), its CPU growing linearly at a few per cent of a core per 10 edges; the segmenter unaffected.

## Results

All four steps ran; the stop rule never fired, the segmenter logged no reset, and every live-feed unit on the host stayed active with no restart. CPU is per cent of one core, the host's of all eight.

| Edges | Load (Gb/s) | Segment fetch p50 / p99 / max (ms) | Playlist TTFB p99 (ms) | Errors | nginx | Segmenter | Host CPU | Origin egress (Gb/s) |
| --: | --: | --- | --: | --: | --: | --: | --: | --: |
| 4 | 0.10 | 8.1 / 9.4 / 9.7 | 0.5 | 0 | 0.1 % | 2.6 % | 2.3 % | 0.10 |
| 16 | 0.40 | 7.2 / 10.0 / 11.2 | 0.4 | 0 | 0.3 % | 2.8 % | 2.5 % | 0.39 |
| 64 | 1.57 | 6.7 / 11.6 / 14.5 | 0.4 | 0 | 1.2 % | 2.8 % | 3.1 % | 1.58 |
| 128 | 3.19 | 8.4 / 18.2 / 33.3 | 0.6 | 0 | 2.4 % | 2.8 % | 3.8 % | 3.21 |

1. **Every step keeps up** (criterion 1): the 99th percentile fetch stays under 20 ms against a 1 s bound, with no error.
2. **The knee is above 128** (criterion 2).
3. **Cost** (criterion 3): nginx grows linearly at about 0.02 % of a core per edge (0.75 % per Gb/s), a tenth of the prediction; the segmenter is flat, untouched by the load; egress is 25 Mb/s per edge, the feed's rate, as each edge fetches each segment once.

## Conclusions

1. **At fan-out the origin's CPU is not what binds.** On this slope nginx would reach one core near 5,000 independent request streams; long before that the host's network allowance sets the limit.
2. **The live feed's host can carry the origin**: a 128-edge load beside it moved no live-feed unit and no segmenter boundary.

## Limits

- An edge here is a synthetic fetcher in the same region and AZ class, on a private network: no internet path, no TLS, and no request collapsing. CloudFront's regional caches would collapse many edges into fewer origin streams, so N is the number of independent origin request streams, not of PoPs.
- One origin host, one feed rate, 2 s segments; nginx at its rig defaults.

## Commands

```bash
bash lab/scripts/t78-drive.sh "4 16 64 128"     # from the laptop: the ramp, the sampler, results to ~/p59-local/t78/
```
