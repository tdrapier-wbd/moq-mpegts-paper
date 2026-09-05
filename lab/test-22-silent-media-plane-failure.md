# T22 — silent media-plane failure: the feed stops, the transport does not

> **State:** complete for the MoQ media-aware lane. Six arms, one of them a control.
>
> **The transport never detects a stalled source.** With the source frozen for **120 s** while every
> process stayed running and every session stayed established, the publisher, relay and exporter logged
> **nothing at all** — no error, no timeout, no reconnect, no warning. An alarm set on process liveness
> or session state reports green for the whole outage. This is not a threshold artefact: the 30 s and
> 120 s arms agree, and the 120 s arm rules out the QUIC idle timeout as an eventual backstop.
>
> **The media plane detects it in about one cushion.** The groomer's content-liveness alarm fired
> **1.69–1.88 s** after the last advancing media in every injected arm, against a configured 1 s stall
> timeout plus the cushion's grace. PCR progression at the graded output stopped within the observation
> tick, **0.1 s**. Both are available to an operator; neither needs the transport's cooperation.
>
> **A frozen relay is the one case the transport eventually catches, 18× slower.** QUIC's idle timeout
> fired at **34.3 s** and took the egress chain down with it, against **1.88 s** for the media plane on
> the same run.
>
> **The groomer's stall policy decides whether the failure is silent downstream, and the cost is
> measured.** Under `--on-stall mute` the carrier stops 0.1 s after the programme does, and the outage
> is visible to anything watching for bytes. Under `--on-stall continue` the carrier **never stops** —
> byte-perfect CBR, valid PCR, no programme — for as long as the source is gone. That configuration
> converts a detectable failure into an undetectable one, and it is the default behaviour of any pacer
> that has not been told otherwise.
>
> **Recovery is clean and is scored on media, not on the session.** Media returned **0.02–1.02 s** after
> the source resumed, stable output within **0.92 s**, and the programme clock skipped **exactly** the
> wall-clock outage in every arm (28,458 ms over 28.4 s; 119,365 ms over 119.3 s). No duplicate media,
> no stale replay, no attempt to catch up.
>
> **The control arm fires nothing.** No detector, no false positive, across a 75 s undisturbed run.

## Objective

Can an operations system reliably detect "the feed has stopped" when the underlying transport is still
technically healthy?

Every failure drill in the campaign so far has removed a process, and a removed process is the easy
case: the socket closes, the peer notices, something reconnects. [T6](test-6-relay-resilience.md) times
that recovery and [T12](test-12-dual-path-handoff.md) grades the handover. The failure a
primary-distribution operator is least protected against is the other one — every component still
running, still connected, and the programme off air.

The campaign had an observed instance of this and no designed test.
[T5](test-5-network-impairment.md) found a segmented client losing 82 s of programme while the origin
returned nothing but 200s; [T9](test-9-performance.md) and T6 found a relay livelocked at 100 % CPU
with no accepts for hours; T12 found, incidentally, that a groomer asked only to hold rate emitted a
byte-perfect carrier with no programme in it for 26 s and that both merge policies read it as healthy.
None of those measured **how long each candidate detector takes to fire**, which is the only figure an
operator can design an alarm against.

## Method

**Nothing is killed.** `SIGSTOP` produces exactly the condition of interest: the process exists, its
sockets stay open, its connection state is untouched, and it does no work. `SIGCONT` resumes it, so the
recovery half is scored on the same run.

**Detection latency is measured from the last advancing media, not from the injection.** Those differ
by however much media was already downstream of the fault — measured here at **1.81–1.92 s**, the
groomer's cushion plus the exporter's `--latency-max`. That interval is not error: it is the part of
the outage the buffer paid for, and it belongs in the result. Anchoring on the injection would credit
the buffer's depth to the detector.

**The carrier and the programme clock are recorded separately**, at 100 ms, because the premise of the
failure is that they disagree. `lab/scripts/t22-wire-observer.py` logs bytes arrived and whether a PCR
advanced, per tick; `lab/scripts/t22-grade.py` turns the traces into latencies.

Four detectors are timed, in the order an operator would reach for them:

| Detector | What it watches | Whose cooperation it needs |
|---|---|---|
| `session` | transport errors, closes, timeouts, reconnects | the transport's — this is the **control** |
| `carrier` | bytes arriving at the graded output | none |
| `pcr` | PCR progression past the TR 101 290 P1 repetition limit | none |
| `groomer` | the pacer's own content-liveness alarm | the groomer's |

The `session` reading is filtered: every run opens with `moq_native::reconnect connecting/connected`,
and a detector credited with those would be credited with noticing the failure before it happened. Only
non-benign lines after the last advancing media count.

## Environment

- **Host:** EC2 secondary, `c6in.2xlarge`, 8 vCPU / 15 GB, `eu-west-1b`. Loopback; the point is
  detection, not the path.
- **Build:** `moq` / `moq-relay` from `~/bin-3006` (0.9.15 / 0.14.14); `mpegts-pacer` at `41e6181`.
- **Chain:** `tsp -I file --infinite -P regulate --pcr-synchronous` → `moq import ts` → relay →
  `moq export ts --latency-max 500ms` → `mpegts-pacer - 11000000 --latency-ms 1000 --max-latency-ms
  2500 --stall-ms 1000` → observer.
- **Rig:** `lab/scripts/t22-silent-stall.sh`, graded by `lab/scripts/t22-grade.py`.
- 25 s of settling before every injection, so the cushion is at its set point and the latency is not
  measured against a priming transient.

## Results

All times in seconds from the last advancing media. "—" means the detector never fired.

| Arm | Policy | Stall | Buffer absorbed | `carrier` | `pcr` | `groomer` | `session` |
|---|---|---:|---:|---:|---:|---:|---|
| control | mute | — | — | — | — | — | — (0 lines) |
| source frozen | mute | 30 s | 1.92 | 0.1 | 0.1 | **1.88** | — (0 lines) |
| source frozen | continue | 30 s | 1.81 | **—** | 0.1 | **1.69** | — (0 lines) |
| publisher frozen | mute | 30 s | 1.82 | 0.1 | 0.1 | **1.70** | 30.3 (at resume) |
| relay frozen | mute | 30 s | 1.91 | 0.1 | 0.1 | **1.88** | ~30 (at resume) |
| **source frozen** | mute | **120 s** | 1.92 | 0.1 | 0.1 | **1.88** | **— (0 lines)** |
| **relay frozen** | mute | **120 s** | 1.91 | 0.1 | 0.1 | **1.88** | **34.3** |

The `pcr` and `carrier` figures are observation-limited: the tick is 100 ms, so 0.1 is the floor the
instrument can report, not the detector's floor. A PCR-progression alarm cannot in principle fire
faster than the P1 repetition limit it is testing against, so its true floor is 40 ms.

### The 120 s arms are the ones that settle it

The 30 s arms all showed the transport saying something at about 30 s, which is ambiguous: a QUIC idle
timeout and the resume were within a second of each other. The longer arms separate them.

- **Source frozen for 120 s: the transport still said nothing.** Zero non-benign lines across
  publisher, relay and exporter logs for the entire outage. The publisher's session to the relay carries
  no media and neither end minds, because from QUIC's point of view an idle stream is not an error. So
  the invisibility is not a race with a timeout — a stalled source is invisible to the transport
  indefinitely.
- **Relay frozen for 120 s: the transport fired at 34.3 s**, `ConnectionLost(TimedOut)` followed by
  `current group evicted; skipping to next buffered group`, and the egress chain exited at that point.
  This arm has no respawn loop, so "media did not return after `SIGCONT`" measures that the chain exits,
  not that recovery is impossible — [T6](test-6-relay-resilience.md) measures the reconnect, at ~4 s
  once the relay is back.

### Recovery, scored on media

| Arm | Off air | Programme clock skipped | Media back after resume | Stable after resume |
|---|---:|---:|---:|---:|
| source frozen, mute, 30 s | 28.4 s | 28,458 ms | 0.02 s | ≈0 s |
| source frozen, continue, 30 s | 28.5 s | 28,541 ms | 0.01 s | ≈0 s |
| publisher frozen, 30 s | 29.3 s | 29,334 ms | 0.82 s | 0.72 s |
| relay frozen, 30 s | 29.4 s | 29,471 ms | 1.02 s | 0.92 s |
| source frozen, 120 s | 119.3 s | 119,365 ms | 0.04 s | ≈0 s |

The programme clock skip matches the wall-clock outage to within 0.1 s in every arm. The lane resumes
at the live edge: it does not replay what it missed and it does not attempt to catch up, so the outage
appears downstream as a clean discontinuity of exactly its own length. For primary distribution that is
the right behaviour — the alternative is a feed that runs late for ever after a hiccup — but it means
**the programme lost is gone**, and the only mitigation is redundancy, not buffering.

## What this establishes

1. **Session state is not a media-plane health signal, and the gap is unbounded.** For the failure most
   likely to occur — an encoder or input that stops while its machine stays up — the transport reports
   healthy for as long as the failure lasts. Any monitoring design that alarms on connection state or
   process liveness will miss it entirely. This was suspected from three incidental observations; it is
   now measured, with a control.
2. **The media plane detects it in about one cushion, and two independent detectors agree.** The
   groomer's own alarm at 1.7–1.9 s and PCR progression at the wire are separate mechanisms with
   separate failure modes, and either is sufficient. F3's pass criterion — at least one detector inside
   one groomer cushion, with no false positive on the control — is met.
3. **PCR progression is the detector to build on.** It needs nothing from MoQ, nothing from the
   groomer, and no cooperation from the sender; it is a property of the bytes. It is also the detector
   that already exists in every broadcast monitoring product, which matters more for adoption than
   anything the groomer can offer.
4. **The stall policy is a monitoring decision disguised as a pacer flag.** `continue` holds a
   conformant carrier over a dead source indefinitely. It is the correct choice only where something
   *else* is watching content liveness, and the measurement is that nothing downstream of the carrier
   can be.
5. **The buffer buys 1.8–1.9 s and no more.** That is the outage a viewer does not see, and it is set by
   the cushion plus `--latency-max`. Anything longer is on air.

## Limits

- One host, loopback. Detection latencies on a real path would add the path's own delay, which is small
  against 1.9 s but not zero.
- `SIGSTOP` freezes a process cleanly. A real encoder that stalls may half-work — emitting some tracks
  and not others, or emitting stale timestamps — and this experiment does not cover partial stalls.
  That is a materially different failure and the detectors above are not obviously sufficient for it.
- The relay arm's post-resume behaviour is bounded by the rig having no respawn loop, as noted.
- Detection is measured; **response** is not. Nothing here says how long an operations system takes to
  act on the signal, only when the signal becomes available.
