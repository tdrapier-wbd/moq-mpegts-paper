# Test 25 — Isolation under abuse: can one receiver degrade the others?

**State: pass criteria fixed, rig mechanically validated on the primary, measured run not yet
performed** — it needs the secondary, for the reason given under Environment. Specified as
[F11](planned-experiments.md#f11-isolation-under-abuse). Rig:
[`f11-isolation.sh`](scripts/f11-isolation.sh), graded with
[`t8b-c3-span.py`](scripts/t8b-c3-span.py).

## Objective

Establish whether one badly-behaved subscriber can degrade the service other subscribers of a
permanent feed receive through the same relay, and whether anything it costs the relay is
reclaimed when it leaves.

This is a viability question rather than a comparison. Both economic models in this paper assume
multi-tenancy, and [Comparison](../docs/comparison.md) §2 notes that a relay holding
per-subscription state is structurally more exposed than a cache serving idempotent GETs. That
observation has never been tested, and the paper should either support it or stop making it.

**Not a security assessment.** No attempt is made to find the worst achievable attack, to exhaust
the host, or to exploit anything. The arms are all things an ordinary client can do by accident —
a crashing receiver, a retry loop, a subscriber whose disk filled — which is what makes them
operational rather than adversarial.

## What is already known, and what it bounds

- Relay memory growth is **not** an audience term ([T9](test-9-performance.md), and T8b C6's
  per-slot accounting), which bounds one obvious attack: subscribers alone cannot make the relay
  grow without bound.
- Relay state *is* per-subscriber and per-track by construction, so subscription setup and teardown
  are the costs most likely to be exposed.
- A session killed without a `CONNECTION_CLOSE` is served until the idle timeout expires
  (30 s default) — measured in [T6](test-6-relay-resilience.md) as a property of failover, and it
  implies abandoned sessions are retained rather than reclaimed promptly.
- Nothing has been tested adversarially, on either lane.

## Environment

| | |
|---|---|
| Host | EC2 secondary, `c6in.2xlarge`, 8 vCPU / 15 GB, Ubuntu 26.04 |
| Why not the primary | 2 vCPU cannot separate a relay knee from a host knee — the trap [T9](test-9-performance.md) records, where co-resident subscribers cost more CPU than the relay serving them. An isolation result measured on a saturated host is a statement about the host. |
| Relay | loopback, `--auth-public ""`, `--internal-listen` + `--stats-enabled=true` |
| Publisher | `tsp -I file … --infinite -P regulate --pcr-synchronous` → `moq import ts`, one broadcast |
| Victims | 2 × `moq export ts --latency-max 2s`, captured to file, running the whole cell |
| Source | `~/CNNiEMEA2.ts`, 1080i25, ~9.95 Mb/s CBR |

## Procedure

One cell per arm, each four phases on **one** clock and **one** capture, so "it degraded" and "it
recovered" are the same measurement rather than two runs with two warm-ups:

| phase | window | what runs |
|---|---|---|
| settle | 0–15 s | victims only, relay warming |
| baseline | 15–60 s | victims only, **measured** |
| abuse | 60–120 s | the arm's abuser |
| recovery | 120–165 s | abuser gone, victims still measured |

Arms, all expressible through the `moq` CLI — which offers only `import` and `export`, so an abuser
is necessarily a subscriber that behaves badly rather than a custom client:

| arm | what it does | what it probes |
|---|---|---|
| `control` | nothing | the reference the others are read against |
| `storm` | 40 concurrent subscribers to the victims' own broadcast, killed and relaunched every 5 s | per-subscription setup cost; whether fan-out churn starves established readers of the same track |
| `ghost` | 40 subscribers to broadcasts that do not exist, distinct names, respawned every 2 s | whether an unsatisfiable subscription costs anything unreclaimable — the cheapest abuse, needing no knowledge of what the relay carries |
| `churn` | sessions opened and SIGKILLed after 0.3 s, never closed cleanly | connection-state reclamation against the idle timeout |
| `slow` | one subscriber that never drains its stdout, staying subscribed with a full pipe | whether one unresponsive reader's backpressure reaches the others — the arm most likely to find something, since the relay must either buffer without bound or drop |

**The instrument is the victims, never the abuser.** An abuser that gets poor service is not a
finding; an abuser that gets good service while the victims suffer is the entire point.

**The control is run in the same session as the arms.** This box is shared and its load varies; a
baseline from another day is not a baseline. This is the correction the C3 re-check
([T8b](test-8b-congestion-control.md)) forced — re-running that experiment's own pre arm returned
6.09 Mb/s where the record said 4.29, on the same binary and the same rig.

## Metrics

Per victim, per phase:

- **Delivered programme** — `keep_up` (media time delivered ÷ wall time elapsed; 1.0 is holding the
  live edge) and holes above 100 ms with the total programme time lost in them. Byte rate is
  recorded too but is *not* the criterion: a byte count cannot distinguish "held the live edge with
  holes punched in it" from "perfectly clean but falling further behind every second", and those
  are different operational outcomes.
- **Continuity errors** from TSDuck, which is the broadcast-domain pass/fail.

Per relay, sampled once a second from `/proc/<pid>`, per PID and not by command-line signature —
[T21](test-21-permanence-soak.md) attributed 137 MB of growth to a signature that also matched a
wrapper shell, and attribution is the whole point here:

- RSS, thread count, file-descriptor count, CPU ticks.
- The relay's **accept** series: `accept_failures_total` (by class, including `exhausted`) and
  `accept_stalled_seconds`. These are direct isolation measures rather than proxies — the first says
  the relay refused a connection, the second says how long it could not accept one at all, which is
  exactly "did the abuser stop other clients getting in".

  The metric names are recorded per run rather than trusted from a previous experiment, and the
  shakeout proved why: `/metrics` on `moq-relay` 0.14.14 carries **only** the accept series. The
  per-role traffic counters a previous experiment read there are no longer on that surface —
  `--stats-enabled` now publishes stats as a MoQ *broadcast* under `--stats-prefix` (default
  `.stats`), so reading them means subscribing to the relay rather than scraping it. Had the rig
  trusted the old names it would have recorded a flat zero, which is indistinguishable from "the
  abuse cost nothing" — the one false negative this experiment must not return. Delivered bytes are
  taken at the victims from `/proc` regardless, which is the better place for them: the receiver's
  view rather than the relay's claim.

## Pass criteria, fixed before running

0. **The arm must prove it ran.** The abuser's process group is counted every second, and a cell
   whose peak concurrent abuser count during the abuse phase is below two is *failed and discarded*,
   not reported. This is criterion zero because the rig's shakeout produced exactly the failure it
   guards against: the connection arguments did not survive the trip into the abuser's subshell,
   every abuser died on a CLI parse error before opening a connection, and all three arms duly
   reported victims with `keep_up` 1.001 and no continuity errors. A broken adversary and a
   perfectly isolated relay write the same row, so the load has to be evidenced independently of the
   victims' health. One abuser per arm keeps its stderr for the same reason.
1. **Victim continuity errors remain 0 in every phase of every arm.** Any non-zero count is a
   finding regardless of size.
2. **Victim `keep_up` during abuse is within 2 % of the same arm's baseline phase**, and the
   `control` arm establishes what that spread is with no abuser present. A drop beyond the control's
   own spread is degradation.
3. **No victim hole above 100 ms appears in an abuse phase that does not also appear in the
   control.**
4. **Relay RSS returns to within 10 % of its pre-abuse value within the 45 s recovery phase**, or
   the cost is retained rather than reclaimed, which is a finding whether or not the victims noticed.
5. Relay file descriptors and threads return to their pre-abuse values in the recovery phase.

**Any measurable degradation of an unrelated subscriber belongs in the paper regardless of
severity**, and so does its absence: "a relay is structurally more exposed than a cache" is a claim
this experiment can support or refute, and it is currently made without evidence.

## Limits, stated in advance

- Five arms is not an attack surface. The list is bounded by what the shipped CLI can express, so
  malformed control messages, protocol-level abuse and authenticated-but-hostile clients are all out
  of scope and stay out of the conclusions.
- One relay, loopback, no impairment, two victims. This measures isolation, not isolation at scale;
  the fan-out knee is [F5](planned-experiments.md)'s question.
- The segmented lane's half of F11 is **not** run here. It needs the HTTP/3 origin lane, and the
  honest expectation — a cache serving idempotent GETs has less to exploit — is exactly the kind of
  expectation that should be measured rather than assumed, so it stays open rather than being
  asserted.

## Results

Not yet run. The rig's mechanics are validated on the primary — relay, publisher, two victims and
each abuser arm start, the abuse phase is entered and left on schedule, abusers are confined to
their own process group and die with it, and captures grade cleanly — but those shakeouts were run
at `NSTORM`/`NGHOST` of 4–6 with 15 s phases on a 2 vCPU host, which is neither the specified load
nor a host that could separate a relay knee from its own. They are evidence that the instrument
works, and nothing at all about isolation.

## Corrections

**Believed:** the relay's per-role traffic counters could be read from `/metrics` with
`--stats-enabled=true`, as a previous experiment had done.
**True:** on `moq-relay` 0.14.14 that endpoint serves only the `accept` series; the traffic counters
are now published as a MoQ broadcast under `--stats-prefix`, so they are subscribed to rather than
scraped.
**Rule:** record the metric names a build actually exposes as part of the run, because a renamed
series reads as a flat zero and a flat zero is a plausible-looking result.

**Believed:** launching the abuser under `setsid` with its arguments passed through `bash -c` was
sufficient to run the arm.
**True:** a bash array does not survive that trip; passed as a string and expanded as an array it
becomes a single argument, and every abuser exited on a CLI parse error while the cell reported
clean victims.
**Rule:** an arm whose expected result is "nothing happened" must assert that the stimulus existed —
here as pass criterion zero — and must keep at least one adversary's stderr.
