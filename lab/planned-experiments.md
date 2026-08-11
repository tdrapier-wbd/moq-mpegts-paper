# Specified but not yet executed

These protocols were designed as part of the campaign and are recorded here so an external engineer
can execute them reproducibly. Most have **not been run**. Where an experiment has since been partly
executed it has its own per-test file, and the entry below is reduced to the protocol for the
*remaining* conditions plus a pointer — the measured results live in the per-test file, not here.
Placeholders `<EC2_IP>` / `<subscriber-home-ip>` carry the machine-specific values from
`INSTRUCTIONS.local.md`.

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

## Congestion control for a permanent fixed-rate trunk (extends T8)

Promoted to its own protocol with a runnable rig — see
[test-8b-congestion-control.md](test-8b-congestion-control.md). The under-provisioned
failure-mode run (C1) is done; the provisioned-path conditions (transient congestion, coexistence,
AQM, provisioning margin, soak) are pending. Until those run, the T8 controller ranking is scoped to
non-congestive impairment only.

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

The executed work — soaks, fan-out envelope, bitrate sweep, protocol overhead and the relay memory
finding — has its own file: [test-9-performance.md](test-9-performance.md). Publisher and subscriber
roles pass the stability criterion; the relay does not. The leak is now fully characterised: **~9 KiB
retained per ingested group, flat in subscriber count, causally confirmed by a matched GOP pair, and
bounded by neither documented cache control.** What remains, in priority order:

1. ~~**Per-subscriber or per-group?**~~ **Answered.** The slope is flat in N (+28.70 / +27.86 / +28.00
   / +28.13 MB/h for N = 1/2/4/8) while ingested groups hold at 3,200/h. Per-session state is fixed at
   +3.22 MB per subscriber and does not accumulate; egress was N × ingress at every leg, so send
   backlog is excluded across the sweep rather than just at N = 1.
2. ~~**Confirm it causally, then report.**~~ **Confirmed.** The matched GOP pair (identical content,
   encoder and 9.3 Mbps; only `-g` differs) doubled the slope when group rate doubled — +31.22 →
   +62.30 MB/h, ratio 1.995 against 2.000, kB/group equal to three significant figures. The
   registered prediction held. `--cache-duration 5s` left the rate unchanged at +27.00 MB/h, so
   **both documented knobs are excluded**. The draft
   (`docs/upstream/relay-memory-growth-issue.local.md`) is complete and ready to post.
3. **Characterise the allocation site**, if upstream wants more than the black-box shape. The release
   binaries are not built with a profiling allocator, so this needs a local rebuild with one before a
   heap profile can name the retained structure. Worth offering rather than promising.
4. **Re-test after any fix**, using `gop14` as the sensitive case — at 6,445 groups/h it shows a
   regression in half the time.
5. **The publisher thread count**, which grows and decelerates without settling.
6. A cross-machine fan-out to find the relay's own knee, overhead under loss versus SRT, and the
   groomer/pacer envelope.

### Evidence checklist for the audio-resync upstream report

Any audio elementary stream losing frame sync aborts `moq import` outright, while the video path
resynchronises through the same corruption; the mechanism is located in
[test-9-performance.md](test-9-performance.md). Remaining before posting:

- [x] Deterministic minimal reproducer with no timeline jump (unit level, `moq-mux` 0.9.4).
- [x] Root cause located and contrasted with the paths that do resync.
- [x] Generality across codecs (MP2, AC-3; video-only survives).
- [ ] End-to-end on real content: bit-flip one MP2 frame header mid-file (not a loop), capture the
      exit, with a corrupted-video-NAL control on the same file.
- [ ] Blast radius as measured: confirm video and SCTE-35 tracks die with the audio, and what the
      subscriber sees.
- [ ] Regression test in repo style asserting the *fixed* behaviour, ready to follow the issue.

A rig consequence that constrains any future long publisher run: looping a normal broadcast TS cannot
produce a long-lived publisher until this is fixed. A video-only remux is the workaround, at the cost
of not exercising the audio, SCTE-35 or teletext paths.

**Standing method** (used for the executed conditions, and for the remaining ones). Per role
(publisher, relay, subscriber + groomer/pacer), establish the steady-state resource envelope and its
scaling, and prove stability over long runs. The priority dimension is a **hours→days soak** to detect
memory leaks / unbounded growth — a resource leak is a production blocker, not a characterisation
note. Run on the Linux EC2 host so `pidstat`/`/proc` are available; pin builds and record them.

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

## Cross-implementation interop (T11)

Three other MoQ implementations now matter to this project
([interoperability](../docs/interoperability.md) §9), and "a MoQ relay is a neutral transport fabric"
is a load-bearing assumption that has only ever been tested against `moq-dev` peers. Three experiments,
in ascending cost. T11a is partly executed — the harness, the relay matrix and the isolated root cause
are in [test-11-interop.md](test-11-interop.md); the remaining legs are specified below.

**T11a — `moq-dev` client against a Cloudflare relay.** *Runnable now.* Cloudflare's managed relays
are provisioned by API and free during the beta; they serve MOQT drafts 14 and 16, and `moq-dev`
offers 14–19 by ALPN, so negotiation should succeed. Provision a relay, obtain publish and subscribe
tokens, and run the standard `moq import ts` → `moq export ts` round trip across it. Record: the
negotiated draft, whether the `hang` catalog survives a relay that has no catalog concept, round-trip
fidelity against the T1 baseline, and added latency. **This is the strongest available test of relay
neutrality** because it uses real third-party production infrastructure rather than a lab peer. Note
their relay treats publisher disconnect as terminal, so do not expect any source-failover behaviour —
verifying *that* is itself a result worth recording against [architecture](../docs/architecture.md)
§14.

**T11b — a `moq2ts` broadcast through a `moq-dev` relay.** *Runnable now, weaker result.* `moq2ts` is
publisher-only, so there is no MSFTS subscriber to close the loop; the question is only whether the
relay forwards objects whose catalog it cannot parse. Observe the relay's forwarding and announce
behaviour rather than decoding output. `moq-dev` is demand-driven (T11a), so the open part of the
preannounce split documented in `moqxr` PR #21 is the other direction: run with their default
(preannounce off) and then with it on, to establish whether an early `PUBLISH` poisons namespace
registration.

**T11c — the full suite against a `moq2ts` subscriber.** *Blocked until they publish one.* When it
exists, run T1–T3 transparency, T7 timing integrity and TR 101 290 conformance against their
implementation and contrast with ours. This is the comparison that would actually settle which lane
preserves what — particularly whether their null-stripping and SPTS-from-MPTS behaviour costs
conformance in the same places ours does, and whether the `mediatimeline` side track is a better
answer to wall-clock correlation than downstream PCR regeneration. Plan the matrix now so the run is
ready when the subscriber lands.

**Ecosystem contribution to consider alongside these:** a **broadcast profile** for the community
[`moq-interop-runner`](https://github.com/englishm/moq-interop-runner) — TS carriage fidelity, PSI/SI
survival, PCR integrity across a relay. The harness already exists and deliberately stops at the
protocol handshake, so this extends shared infrastructure rather than building a private rig, and
gives the transparent-TS profile a neutral conformance target.

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
