# Specified but not yet executed

These protocols were designed as part of the campaign and are recorded here so an external engineer
can execute them reproducibly.

**This file holds only what is outstanding.** Everything measured lives in the per-test file it
belongs to; where an experiment is partly executed, the entry here is reduced to the *remaining*
conditions plus a pointer. Nothing is marked done here — a completed item is deleted from this file,
not struck through, because a to-do list that accumulates its own history stops being readable as a
to-do list. Results, corrections and the reasoning behind them belong in `test-*.md`.

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
Titan). The precondition — which groomer topologies can produce a byte-identical pair — is already
characterised in [test-6-relay-resilience.md](test-6-relay-resilience.md), and the hand-off it enables
is graded in software in [T12](test-12-dual-path-handoff.md). This drill therefore starts from a
known-good sender pattern, and its open question is narrow: **does a real IRD's merge engine agree with
T12's reference receiver?**

---

## Dual-path 1+1: remaining conditions (T12)

All four arms are run; results and limitations are in
[test-12-dual-path-handoff.md](test-12-dual-path-handoff.md), rigs in [`scripts/t12-*`](scripts/).
What those results left open:

**Restart one leg of a live pair — blocked upstream.** A stream-clocked leg that mutes and returns
already rejoins its partner's numbering and phase correctly; the one thing stopping the pair being
byte-identical afterwards is the exporter's continuity counters, filed as
[moq-dev/moq#2779](https://github.com/moq-dev/moq/issues/2779). Once that lands, re-run the recovered-leg
and late-join cells expecting 100 % agreement.

That re-run also needs a grader the current one is not. `t12-merge-oracle.py` recovers the legs'
sequence offset by voting on payload identity and derives skew from it, so it cannot grade a pair that
differs in any field — it graded the join cell on 15 datagrams out of 23,175 and returned a spurious
offset and a 12 s skew that did not exist. Either give the oracle a masked-compare mode or wait for the
exporter fix; meanwhile use [`t12-seqskew.py`](scripts/t12-seqskew.py), which measures phase without
correlating.

**Two-host and meshed variants.** Both T12 legs ran on one host, sharing a clock, which flatters the
rate coherence [architecture](../docs/architecture.md) §14.1 requires of two gateways on free-running
oscillators; and both traversed the same physical path, so T12 graded the hand-off, not path
diversity. This matters more now than it did: arm D's identity claim rests on two groomers agreeing
about stream position, and on one host they agree about wall time as well. Repeat the arm C and arm D
cells across two hosts, and optionally with relay B dialling relay A as a cluster peer
(`~/t6-redundancy/relayA.toml`/`relayB.toml`), to check that relay reselect neither helps nor
interferes once the receiver is doing the switching.

The second host is a **second EC2 instance in a different AWS availability zone**, which is wanted in
its own right as the secondary relay. Until it exists this is blocked: the local re-run in
[T12](test-12-dual-path-handoff.md#what-the-fixes-are-worth-measured-on-the-pair) shares a host too,
so nothing measured so far separates "the legs agree about stream position" from "the legs share a
clock". Run it once the exporter fixes land, so the two-host result grades path diversity rather than
re-measuring defects already filed.

**Also unaddressed by T12:** SMPTE 2022-1 FEC; a full 10 Mbps mux rather than 2 Mbps on a 2-vCPU box;
a carrier rate matched to the content rate, to resolve whether the 1.4 % PCR-interval floor measured
there is an artefact of 55–60 % stuffing; and any hardware IRD merge, which is Gate 2.

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

Soaks, the fan-out envelope, the bitrate sweep, protocol overhead, the relay memory characterisation
and the audio-resync work are all executed and written up in
[test-9-performance.md](test-9-performance.md). What is left:

1. **Run a leg long enough to resolve the soft plateau.** The knee reproduced where predicted, but
   growth past it continues at ~+8 MB/h rather than stopping, and four hours cannot distinguish slow
   convergence from a second, shallower leak. A 12-hour leg on the default slot count would settle it.
   Related: the ceiling has a ~20–30 MB slot-independent term whose origin is unattributed — a third
   slot count (say 4,096) would test whether the two-point fit holds as a line.
2. **Re-test the memory behaviour after any upstream fix**, using `gop14` as the sensitive case — at
   6,445 groups/h it shows a regression in half the time. The fix has to come from `quinn-proto` and no
   released version past 0.11.16 changes the recycling behaviour, so this may wait a long time.
3. **What a real decoder does with an unflagged 24 ms audio hole, and with a substituted frame**, if
   [#2798](https://github.com/moq-dev/moq/issues/2798) needs it. A resync is signalled nowhere, but
   "unsignalled" only matters if something downstream would have acted on the signal. The splice case is
   the sharper half: a frame of spliced bytes decodes to *something*, and whether that is an inaudible
   glitch or a full-scale click decides how much the missing signal costs. An AC-3 decoder that honours
   `crc1` should conceal it; an MP2 decoder on this content has no CRC to check.
4. **Two residuals from the splice fix ([#2823](https://github.com/moq-dev/moq/pull/2823), merged and
   verified: the mixed frame is gone from the looped feed).** First, **the counter-contiguous wrap**,
   where the fix is blind and the mixed frame returns — reproduced on `main` with a 130,705-packet cut
   of the broadcast clip, chosen so the audio PID's counter runs straight through the wrap, and worth
   reporting as its own issue once the AC-3 question below is answered, since a CRC or a PES-length
   check would cover it. Second, **why AC-3 loses the 8 whole
   frames inside its truncated PES while MP2 keeps its 7**, when `salvages_partial_pes` is true for both
   and they take the same branch: either the salvage flush is not reaching the parser for AC-3 or the
   parser is discarding a confirmed frame, and ~256 ms of good audio per wrap turns on which. Also worth
   constructing the opposite case — a mux that *does* split audio frames across PES boundaries — to
   exercise the first commit's confirmation path, which no content we have reaches.
5. **The publisher thread count**, which grows and decelerates without settling.
6. **A cross-machine fan-out** to find the relay's own knee, overhead under loss versus SRT, and the
   groomer/pacer envelope.
7. **A full-feed publisher soak.** Every long run to date used a video-only source, because looping a
   normal broadcast TS killed the publisher at the wrap. `moq-mux` 0.9.5 lifts that, so a re-run can
   now exercise audio, SCTE-35 and teletext — the EC2 box needs upgrading past 0.9.9 first.

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

Pass criteria for any role: RSS growth slope statistically ≈ 0 over the soak, or a plateau with a
stated ceiling; fd, socket and thread counts stable and returning to baseline after join/leave and
relay-reconnect churn; bounded CPU with headroom. Pair the soak with the T7 ≥ 24 h PLL-lock soak so one
long run yields both verdicts. Re-running the fan-out sweep across two machines needs
N ∈ {1,5,10,25,50} subscribers on hosts separate from the relay, since a co-resident subscriber costs
more CPU than the relay serving it and the knee then belongs to the box.

**Carriage overhead: the opaque lane and loss above 1 % remain.** The media-aware lane and SRT are
measured on a real path ([T9](test-9-performance.md)). Two rules for whoever runs the rest, on top of
the three enforced by the rigs themselves ([`scripts/README.md`](scripts/README.md)) — the first pass
here produced a wrong number that survived two rounds of hypothesis:

- **State the budget in advance.** QUIC's per-packet cost is ~64 B (IP + UDP + short header + AEAD tag
  + `STREAM` header), so 5.5 % at a 1200 B datagram and 4.5 % at 1500 B, against SRT's 3.3 %. Without
  a prediction, a wrong measurement has nothing to fail against.
- **State the denominator.** Elementary-stream bytes, delivered TS and source TS differ by the stuffing
  and TS-header volumes; only the last is the like-for-like comparison against a byte pipe.

---

## Cross-implementation interop (T11)

Three other MoQ implementations now matter to this project
([interoperability](../docs/interoperability.md) §9), and "a MoQ relay is a neutral transport fabric"
is a load-bearing assumption that has only ever been tested against `moq-dev` peers.

**T11a — `moq-dev` against third-party relays.** *Partly run;* harness, relay matrix and the isolated
root cause are in [test-11-interop.md](test-11-interop.md), which carries its own list of remaining
legs. The one worth prioritising is **Cloudflare with a provisioned scope**: the anonymous attempt
negotiated draft 18 cleanly and returned no data, which is the expected outcome without publish and
subscribe tokens, so it has not yet tested anything. Done properly it is **the strongest available test
of relay neutrality**, because it uses third-party production infrastructure rather than a lab peer.
Record the negotiated draft, whether the `hang` catalog survives a relay with no catalog concept,
round-trip fidelity against the T1 baseline, and added latency. Their relay treats publisher disconnect
as terminal, so expect no source-failover behaviour — confirming that is itself a result worth
recording against [architecture](../docs/architecture.md) §14.

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
