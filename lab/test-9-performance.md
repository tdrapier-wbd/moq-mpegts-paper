# Test 9 — System performance & resource utilisation

**Pyramid (§6):** operational envelope. **Gate (§7):** feeds [operations](../docs/operations.md) and
[economics](../docs/economics.md) §8 (not a fidelity/resilience gate). **State:** partially run
(2026-08-07) — the **memory-stability** question is answered for two builds and the **fan-out
envelope** is measured to N = 25; protocol overhead and the ≥ 24 h multi-role soak are outstanding.

## Objective

Per role (publisher / relay / subscriber + groomer-pacer), establish the steady-state resource
envelope (CPU, RSS, fds, threads) and how it scales, prove **stability over long runs** (no memory
leak / unbounded growth — a production blocker, not a characterisation note), and record protocol
overhead. The priority dimension is a **hours→days soak** with an RSS-vs-time slope ≈ 0.

### Pass criteria (agreed in advance)

- RSS growth slope statistically ≈ 0 over the soak for **every** role (≥ 24 h, ideally 72 h).
- fd / socket / thread counts stable, returning to baseline after join/leave and relay-reconnect churn.
- Bounded CPU with documented headroom; per-core throughput and the fan-out knee documented.
- Per-hop wire overhead within budget (wire bytes vs TS payload over a fixed window).

## Environment

- **EC2 relay box** (`<EC2_IP>`, eu-west-1, 2 vCPU / 3.8 GB, **no swap**) running the *deployed*
  build `moq 0.8.7 / moq-relay 0.13.7 @ 5e0e98c1`, with two standing publishers and a default
  (unbounded) cache. This is the box the leak was observed on; it is a production-like standing
  service, not a controlled rig.
- **Local (controlled probes)** on the **0.14.8 release** (`moq-relay` 0.14.8 / `moq-cli` 0.9.8 /
  `moq-net` 0.2.9, origin/main `c8b11b10` = release #2672), Darwin 25.5.0. Rigs in `~/t6-redundancy/`:
  `t9_soak.sh` (phased steady / subscriber-churn / publisher-churn), `leak_probe.sh` (publishers with
  **no** subscriber — the EC2 condition), `session_leak.sh` (retained memory per completed session).
- **Source:** `~/CNNiEMEA2.ts` looped via `tsp regulate --pcr-synchronous` (≈ 9.93 Mbps).
- macOS lacks `pidstat`/`/proc`, so local sampling is `ps`/`lsof`; `/proc` and `journalctl` are used
  on EC2.

## The relay's cache is unbounded by default

Worth stating before any measurement, because it frames what "expected" memory looks like.
`moq-relay`'s group cache is **unbounded unless configured**: `CacheConfig` documents *"Unbounded when
unset"* for both `cache.capacity` and `cache.duration`, and resolves to `cache::Pool::unbounded()`
with a `Duration::MAX` age ceiling. With no knobs set, the only bound is each track's own retention
window, which defaults to `DEFAULT_LATENCY_MAX = 5 s`.

So a *healthy* relay should hold roughly five seconds of media per track — single-digit MB at
10 Mbps — and anything at the GB scale is anomalous rather than "the cache doing its job". That
distinction is what turned the observation below from a shrug into a finding. Operationally, bound
relay memory explicitly (`--cache-capacity`, or `--cache-headroom` for the governor) in any
deployment regardless.

## Confirmed: the deployed 0.13.7 relay leaks ~21 MB/hour to an OOM kill

**Correction to the 2026-08-06 entry below: the "flat plateau, no OOM" reading was wrong.** It was not
a plateau; it was a relay approaching the cliff. Roughly nine hours later the kernel killed it:

```
Aug 07 01:00:57 systemd[1]: moq-relay.service: The kernel OOM killer killed some processes in this unit.
Aug 07 01:00:57 systemd[1]: moq-relay.service: Main process exited, code=killed, status=9/KILL
Aug 07 01:00:57 systemd[1]: moq-relay.service: Failed with result 'oom-kill'.
Aug 07 01:00:57 systemd[1]: moq-relay.service: Consumed 16min 59.032s CPU time over
                            6d 18h 40min 56.947s wall clock time, 3.2G memory peak.
```

systemd restarted it, giving a fresh process and a second, independent growth measurement. **Three
measurements over different timescales agree on the rate:**

| Measurement | Elapsed | Growth | Rate |
|---|---|---|---|
| Lifetime to the OOM kill | 6 d 18 h 41 m | 3,208 MB peak | **19.7 MB/h** |
| Fresh process after restart | 9 h 03 m | 204 MB | **22.7 MB/h** |
| Live sampling (`/proc/<pid>/status`) | 40 s | 204736 → 204972 kB | **21.2 MB/h** |

A constant rate across three orders of magnitude of elapsed time is linear unbounded growth, not a
cache converging on a working set. Extrapolated, it kills a 3.8 GB box roughly weekly, which is what
happened.

**What the growth is *not* driven by**, which narrows it usefully:

- **Not media volume.** The relay served **zero subscriber sessions** (`journalctl | grep -c
  "role=Some(Subscriber)"` = 0). At 21 MB/h it is also three orders of magnitude below the ~4.5 GB/h
  of media the publishers represent, so it is not cached payload.
- **Not CPU / not the #2701 wedge.** 17 minutes of CPU over 6.8 days (~0.17 %). The
  [#2701](https://github.com/moq-dev/moq/pull/2701) livelock is a *spin* failure that burns 100 % CPU;
  this is a distinct, quiet memory failure.
- **Not fds or threads.** Steady at 10 fds and 3 threads throughout.
- **Not high session churn**, though sessions are the one thing that did accumulate: 52 sessions in
  9 hours, which works out at ~3.5 MB per session if the growth is charged to them.

## Not reproduced on 0.14.8 (2026-08-07)

Three controlled probes on the 0.14.8 release, sized so that the EC2 rate would be plainly visible.
**None reproduces it.**

| Probe | Condition | RSS behaviour | Verdict |
|---|---|---|---|
| `leak_probe.sh` | 2 publishers, **0 subscribers** (the EC2 condition), 15 min | 14.25 → 15.39 → 14.42 → **12.98 MB**, CPU 0.0 | flat/declining; EC2 rate predicts ~19.5 MB |
| `t9_soak.sh` phase A | 1 publisher + 1 steady subscriber, 4 min | ramps to ~95 MB and holds (±6 MB) | bounded working set |
| `session_leak.sh` | 40 connect/disconnect subscriber sessions in 4 rounds | 100 → 151 → 162 → 181 → **149 MB** | oscillates and returns; no staircase |

The idle probe is the decisive one, because it replicates the exact EC2 condition — publishers
attached, nothing consuming — and because its baseline is rock steady (CPU 0.0, no media actually
flowing, since the relay only pulls a track once something subscribes). Against that quiet baseline a
21 MB/h leak would be unmissable; instead RSS *fell*.

The session probe is worth reading carefully, because at first glance round 1 looks like the ~3.5
MB/session the EC2 arithmetic suggests: +50.7 MB retained after ten completed sessions (5.07
MB/session). But it does not compound. Retained-per-session **decays** across rounds — 5.07, 3.10,
2.69, 1.23 MB — and round 4 came back *down* to 149 MB, below round 3's 181 MB. That is a bounded
working set being re-used, not memory lost per session. Throughout every probe, **fds held at 17 and
threads at 12**.

**The honest limit of this result.** Ten- to sixty-minute runs cannot exclude a ~20 MB/h leak in the
*churn* regime, where the band is ±30 MB. What they do establish is that the specific 0.13.7 failure
mode — steady linear growth in the idle, publisher-only regime — does not occur on 0.14.8. Between the
two builds sit the cache and resume rewrites ([#2615](https://github.com/moq-dev/moq/pull/2615) media
retention and pool bounds, [#2657](https://github.com/moq-dev/moq/pull/2657)
`--cache-latency-default`, [#2666](https://github.com/moq-dev/moq/pull/2666), which explicitly pruned
unbounded segment accumulation), any of which is a plausible fix. Confirming the negative properly is
the ≥ 24 h soak below.

**Not reported upstream.** A leak that only reproduces on 0.13.7 — nine releases and two cache
rewrites behind `main` — is not actionable for maintainers; the evidence is recorded here instead. It
would become reportable if the ≥ 24 h soak on a current build shows a non-zero slope.

## Fan-out envelope on 0.14.8 (2026-08-07)

`fanout.sh`: one relay, one ~9.9 Mbps publisher, N subscribers on the *same* broadcast. CPU is a
delta of cumulative CPU time over a fixed 20 s window (not `ps -o %cpu`, which on macOS is a decaying
average that lags a step change), taken after a 30 s settle at each step.

| N subscribers | Relay RSS | Relay CPU | Aggregate egress | Egress per subscriber |
|---:|---:|---:|---:|---:|
| 1 | 71.0 MB | 5.2 % | 9.5 Mbps | 9.50 Mbps |
| 5 | 86.2 MB | 27.9 % | 47.9 Mbps | 9.58 Mbps |
| 10 | 104.4 MB | 53.9 % | 96.5 Mbps | 9.65 Mbps |
| 25 | 122.4 MB | 143.6 % | 247.6 Mbps | 9.90 Mbps |

**No knee up to 25 subscribers / ~250 Mbps.** Three things to take from it:

- **CPU is the binding resource and it is strikingly linear.** Cost per Mbps of egress is
  0.547 / 0.583 / 0.559 / 0.580 % across the sweep — flat within noise, i.e. ~**0.57 % CPU per Mbps**,
  or ~5.5 % per 10 Mbps subscriber. Extrapolated, **one core sustains ~175 Mbps ≈ 17-18 subscribers**
  at this bitrate; the 143.6 % at N = 25 is ~1.4 cores. Relay sizing is therefore a straightforward
  egress-bitrate calculation, and fan-out capacity is a core count.
- **Memory scales sublinearly**, as a shared cache should: 71 → 122 MB across a 25× fan-out, a
  marginal ~2.1 MB per additional subscriber against a ~69 MB fixed cost. Memory is not the
  constraint for fan-out.
- **Delivery does not degrade with N.** Per-subscriber egress holds at 9.5-9.9 Mbps throughout, so the
  relay is serving every subscriber the full feed at 25× fan-out rather than thinning under load.

Caveats: loopback (no real network stack cost, no TLS-over-WAN, no congestion control doing real
work), a single broadcast, and macOS. Treat the *shape* (linear in egress, sublinear in memory) as the
result and the absolute constants as indicative.

## Preliminary observation as recorded (2026-08-06) — superseded, kept per lab discipline

While assessing the box for T9, the standing `moq-relay` (build `0.13.7`, ~6 days uptime, two standing
publishers) was found at **VmRSS ≈ 3.2 GB** — ~84 % of the 3.8 GB box, with only 3 threads and 10 fds.
It was read at the time as an observation rather than a finding, on three grounds:

- **"Flat, not climbing."** Sampled over ~20 s it held at 3,208 MB (3208624 → 3208508 → 3208308 kB) and
  `dmesg` showed no OOM-kills, so it was read as a **plateau** — a default cache pool filling toward
  system memory. *This was the error: a 20 s window cannot distinguish a plateau from 21 MB/h, and the
  process was in fact ~9 hours from being OOM-killed.* The `dmesg` check was accurate but premature.
- **Old build, unknown history** — 0.13.7 predates the cache/retention work, so it could not be
  attributed to current code. *This part held up, and is now the leading explanation.*
- **It blocked the controlled test there** — ~116 MB free and no swap left no room for a fan-out sweep
  without risking the standing service. *Still true; the controlled probes were run locally instead.*

The lesson recorded: **sample a suspected leak over minutes, not seconds, and check `journalctl`/
systemd accounting rather than `dmesg` alone** (systemd logged both the OOM kill and the 3.2 GB peak
that `dmesg` did not surface).

## Still outstanding

- **≥ 24 h multi-role soak** with an RSS-vs-time slope per role, on a pinned current build. This is
  what converts "not reproduced in an hour" into "no leak". Pair it with the T7 ≥ 24 h PLL-lock soak
  so one run yields both verdicts.
- **Fan-out beyond N = 25**, and on Linux over a real path rather than macOS loopback — to find the
  knee this sweep did not reach and to price the network stack honestly.
- **Bitrate sweep** ≈ 2 / 10 / 27 Mbps (reuse the T1 clips), to confirm the per-Mbps CPU constant
  holds across bitrates rather than just across fan-out.
- **Protocol overhead.** Per hop, `tcpdump` a fixed window and compare wire bytes to TS payload.
- **Bounded-cache control.** Re-run the envelope with `--cache-capacity` set, to record a bounded
  steady state alongside the unbounded default.

```bash
# soak (>= 24 h): coarse sampler + RSS-vs-time slope (slope ~0 = no leak)
while :; do printf '%s ' "$(date +%s)"; ps -o rss=,%cpu=,nlwp= -p <PID>; sleep 60; done > soak_<role>.log
awk '{n++;x=$1;y=$2;sx+=x;sy+=y;sxy+=x*y;sxx+=x*x}
  END{b=(n*sxy-sx*sy)/(n*sxx-sx*sx); printf "RSS slope = %.4f MB/hour\n", b*3600/1024}' soak_<role>.log
```

> **Fitting caveat learned here:** fit the slope only over samples *past* warm-up. A regression through
> the initial ramp (RSS reaching its working set in the first minute) manufactures a huge fake slope —
> an early phased run reported "+680 MB/hour" for a relay that was simply settling to ~95 MB.

## References

- Plan: [planned-experiments.md](planned-experiments.md) (T9), [README](README.md) roadmap.
- Reconnect/retention behaviour the soak interacts with: [evidence](../docs/evidence.md) §7,
  [#2469](https://github.com/moq-dev/moq/pull/2469), [#2647](https://github.com/moq-dev/moq/pull/2647),
  [#2615](https://github.com/moq-dev/moq/pull/2615).
- The distinct relay-wedge failure mode: [#2701](https://github.com/moq-dev/moq/pull/2701),
  [test-6](test-6-relay-resilience.md).
