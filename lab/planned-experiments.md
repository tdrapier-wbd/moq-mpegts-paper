# Specified but not yet executed

These protocols were designed as part of the campaign but have **not been run**. They are recorded
here so an external engineer can execute them reproducibly; no results exist yet. Placeholders
`<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from `INSTRUCTIONS.local.md`.

---

## Hardware TR 101 290 P1/P2 soak (T7, P2 — Gate 2)

The load-bearing open test. Feed the live groomed egress to a hardware IRD + TR 101 290 analyser and
confirm PLL lock and a clean P1/P2 result over a **sustained soak (target ≥ 24 h, ideally 72 h)** —
short runs can pass by luck; only hours→days surface slow clock drift, buffer-model violations, and
rare discontinuity handling. Run jointly with the resource soak below so one long run yields both
verdicts. Exercise the boundaries a groomer must handle beyond steady state:

- source-clock drift; PCR discontinuities / 33-bit wrap; mid-stream PID / PCR-PID change;
- ST 2022-7 determinism under loss (the on-hardware hitless-switch drill), verifying the two egress
  legs stay byte-identical under *divergent* object-loss recovery, not only in the clean case.

Where access exists, corroborate with a second analyser (Elecard / R&S MTS4EA / Tektronix MTS / Ateme
Titan). The output-determinism *precondition* (which groomer topologies can produce a byte-identical
pair) is already characterised in [test-6-relay-resilience.md](test-6-relay-resilience.md).

---

## Congestion control under a real bottleneck + bufferbloat (extends T8)

The [T8](test-8-srt-vs-moq.md) loss/reorder/jitter matrix is over-provisioned (offered ≪ capacity),
so it measures non-congestive impairment resilience, not congestion control. The one meaningful CC
test is **bufferbloat under a shaped bottleneck**, specified to the upstream maintainer's exact
profile (mirrors `just demo cc compare bloat`, the measurement behind the #2468 quinn-BBRv1 default:
CUBIC p50 RTT ~558 ms vs BBRv1 ~90 ms).

**Profile.** 10 Mb/s source → rate-limited to **5 Mb/s**, **100 ms base RTT**, **500 ms queue depth
before dropping**. A good controller approaches 5 Mb/s delivered with standing RTT near 100 ms; CUBIC
is expected to fill the queue and sit near ~500 ms; BBR should hold both high goodput and low latency.
Headline metrics measured *together*: delivered goodput (→ 5 Mb/s, healthy ≈ 90–100 % of cap — not
100 % of source) and standing RTT under load (100 ms good ↔ 500 ms bloated).

**Controllers:** CUBIC (`loss`), BBRv1 (quinn, now default), BBRv2 (quiche, now default), SRT. BBRv3
(noq/iroh) is blocked pending the #768 subtract-overflow panic fix. Pin
`--*-quic-congestion-control` on every run.

**Rig (same EC2 → home path and SSH-safe `prio`+`u32` lane as T8, but the shaped band is a rate
limiter with a deep, controlled queue — not `netem loss/reorder`):**

- Bottleneck + base delay: `tc … htb rate 5mbit` (or `tbf`) + `netem delay 50ms` each way (→ 100 ms
  RTT). Report delivered as **% of the 5 Mb/s cap**.
- Queue depth (the bufferbloat knob): size the leaf queue to ~500 ms at 5 Mb/s (≈ 312 KB ≈ 210 ×
  1500 B) via `bfifo limit 312500` for the bloated case; then re-run with `fq_codel` / `cake bandwidth
  5mbit` for the AQM counterfactual.
- RTT-under-load probe: QUIC RTT estimate from the endpoints and/or an independent `ping` through the
  shaped band.
- Source: CBR file replay (`tsp regulate`) exposes goodput + bufferbloat but cannot back off; pair one
  run with an adaptive/VBR encoder (libx264 ABR chasing the send-rate estimate) for rate-following.
- Fairness: 2× and 3× concurrent MoQ flows sharing the one 5 Mb/s `htb` class; per-flow share via
  Jain's index.

| # | Sub-condition | Shaper | What it isolates |
|---|---|---|---|
| 6a | Bufferbloat (headline) | `htb 5mbit` + `netem delay 50ms` ×2 + `bfifo` ~500 ms | goodput→5 Mb/s **and** standing RTT (100 ↔ 500 ms) |
| 6b | AQM counterfactual | `htb 5mbit` + 100 ms RTT + `fq_codel` / `cake 5mbit` | does modern AQM tame CUBIC's bloat? |
| 6c | Cap below source | `htb {5,3} mbit`, CBR vs adaptive source | failure mode: overflow (CBR) vs back-off (ABR) |
| 6d | Fairness | `htb 5mbit`, N ∈ {2,3} flows | per-flow share; BBRv1 fairness |

Interpretation criteria (agreed up front): goodput ≈ 90–100 % of cap for a healthy controller; BBR
holds standing RTT near the 100 ms base while CUBIC bloats toward ~500 ms, and AQM pulls CUBIC back
down (reproducing the maintainer's ~558 → ~90 ms delta validates the #2468 flip on this path);
endorse a default only if it shares a bottleneck acceptably (BBRv1 fairness is the thing to watch).
Until this runs, the T8 controller ranking is scoped to non-congestive impairment only.

---

## LEO / Starlink satellite-handover impairment (candidate — extends T5/T8)

The [T5](test-5-network-impairment.md) runs used *steady* impairment. On Starlink (LEO) the perceived
damage is not steady-state loss but the **satellite-to-satellite handover** — a periodic pulse
(~every 15 s) of elevated delay and **bursty** loss lasting ~1 s, against an otherwise near-clean
baseline. Because QUIC treats a loss burst very differently from uniform Bernoulli loss, this is a
plausible cause of the periodic degradation reported by collaborators on satellite-backhauled
contribution.

A collaborator's `netem` sketch (a **candidate**, not yet run or calibrated) models it as a
clean-ish baseline with a periodic 1 s handover pulse. As written it drives an `ifb0` ingress-redirect
qdisc rather than the SSH-safe egress `prio` band, so it needs adapting to the media-only filter
before running on a shared host:

```bash
#!/bin/bash
# S3: "Starlink medium-degraded", ~25% worse than APNIC/MMSys'24 measurements.
BASELINE="delay 50ms 8ms 25% loss 0.3%"
tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
while true; do
    sleep 11
    tc qdisc change dev ifb0 root netem limit 20000 delay 150ms 20ms loss 10%   # handover pulse
    sleep 1
    tc qdisc change dev ifb0 root netem limit 20000 $BASELINE
done
```

If run it belongs alongside the T8 impairment matrix (condition 5, bursty/correlated loss) so both
transports meet the same pulse; the metric to watch is not average throughput but **per-pulse
recovery** (does each 1 s burst cause a bounded, self-clearing dip, or accumulate into
starvation/collapse over successive handovers?). Open items before trusting the numbers: (a) calibrate
period/hold/loss against a real Starlink capture rather than the assumed 15 s / 1 s / 10 %; (b) run it
correlated with the T5 reordering finding (a handover that also reorders is the genuine worst case);
(c) apply via the SSH-safe media-only filter, not a blanket `ifb0` qdisc, on any shared host.

---

## System performance & resource utilisation (T9)

Per role (publisher, relay, subscriber + groomer/pacer), establish the steady-state resource envelope
and its scaling, and prove stability over long runs. The priority dimension is a **hours→days soak**
to detect memory leaks / unbounded growth — a resource leak is a production blocker, not a
characterisation note. Run on the Linux EC2 host so `pidstat`/`/proc` are available; pin builds and
record them.

```bash
# steady-state per role (fixed 10 Mbps CNNiEMEA2 loop), ≥ 300 s after warm-up
pidstat -h -r -u -d -t -p <PID> 1 300 > perf_<role>.log
while :; do printf '%s fds=%s thr=%s\n' "$(date +%s)" \
  "$(ls /proc/<PID>/fd | wc -l)" "$(ls /proc/<PID>/task | wc -l)"; sleep 1; done > fds_<role>.log

# soak (≥ 24 h, ideally 72 h): coarse sampler + RSS-vs-time slope (slope ~0 = no leak)
while :; do printf '%s ' "$(date +%s)"; ps -o rss=,%cpu=,nlwp= -p <PID>; sleep 60; done > soak_<role>.log
awk '{n++;x=$1;y=$2;sx+=x;sy+=y;sxy+=x*y;sxx+=x*x}
  END{b=(n*sxy-sx*sy)/(n*sxx-sx*sx); printf "RSS slope = %.4f MB/hour\n", b*3600/1024}' soak_<role>.log
```

Sweeps: bitrate ~2 / 10 / 27 Mbps (reuse the T1 clips); fan-out N ∈ {1,5,10,25,50} subscribers against
one relay broadcast, recording relay CPU/RSS/fd at each N (the fan-out knee). Overhead: per hop,
`tcpdump` a fixed window and compare wire bytes to TS payload. Pass criteria: RSS growth slope
statistically ≈ 0 over the soak for every role; fd/socket/thread counts stable and return to baseline
after join/leave and relay-reconnect churn; bounded CPU with headroom; per-core throughput and
fan-out knee documented. Pair the soak with the T7 ≥ 24 h PLL-lock soak.

---

## MPTS / multiple concurrent services (T10)

Carry a multi-program TS (or several SPTS broadcasts concurrently) through the opaque lane and verify
per-service PSI/SI, PCR and CC integrity at egress, plus relay fan-out behaviour under N services.
Primary distribution is frequently MPTS; the campaign to date is SPTS-only. Gate 1 (fidelity) at
multi-service scale.

---

## Office-network reproduction of T3/T4

Re-run the opaque lane (T3) and the remote end-to-end SRT chain (T4) from the office network. The
office has ample upload capacity (removing the ~2 Mbps home-uplink ceiling that capped T4's SRT leg)
but may impose UDP/QUIC throttling or DPI a home link does not. This tests two things at once: (a) the
opaque lane and full-rate SRT contribution without the access-link bottleneck, and (b) whether
MoQ/QUIC survives an enterprise network posture that polices or rate-limits UDP — a real deployment
risk. Record connect success, negotiated draft, throughput, and any QUIC fallback/blocking.
