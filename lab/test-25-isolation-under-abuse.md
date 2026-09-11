# Test 25 — Isolation under abuse: can one receiver degrade the others?

**State: complete. The media plane is isolated, and the relay's memory cost is explained, bounded and
tunable.** Every arm leaves the victims within 8 KB of the control across 198 MB at 0 continuity
errors. `storm` does drive relay RSS from 87 MB to **1.9 GB in 60 s**, and four further measurements
say what that is: it is **abandoned sessions retained until the QUIC idle timeout**, each still
accumulating media it will never deliver.

- It is **not cumulative**. Four identical abuse cycles reach 1,911 → 1,949 → 1,955 → 1,959 MB: the
  first storm sets the high-water and the rest reuse it.
- It is **not the group cache**. Capping it at 256 MiB leaves the peak *unchanged* (1,930 MB against
  1,911), so the documented memory bound does not cover this at all.
- It is **not concurrency**. The same 42 concurrent subscribers held for the same 60 s without churn
  cost **143.8 MB**, one thirteenth as much.
- It **scales with the idle timeout**, which is the mechanism and the mitigation: 30 s → 10 s takes
  the peak from 1,911 MB to **488.8 MB**, a 4.5× reduction in growth for a 3× reduction in retention.

So this is an operational property with a knob on it rather than a defect, and **no upstream report is
warranted** — see [Open](#open). Specified as [P2-b](planned-experiments.md#p2--completeness).
Rig: [`f11-isolation.sh`](scripts/f11-isolation.sh), graded with
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
  per-slot accounting), which appeared to bound one obvious attack: subscribers alone cannot make the
  relay grow without bound. **This experiment shows that bound applies to a steady audience only** —
  see Results. Subscription *churn* is an unbounded term, and 40 subscribers cycling every 5 s cost
  1.8 GB in a minute.
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

Three further variants of `storm` isolate the mechanism behind its cost, each changing one thing and
nothing else. `--cache-capacity 256MiB` asks whether the memory is cached group payload;
`STORM_PERIOD=3600`, which spawns one generation and holds it, separates churn from concurrency at
equal peak abuser count; and `--server-quic-idle-timeout 10s` varies how long an abandoned session is
retained. The rig exposes all three as `CACHE_CAPACITY`, `STORM_PERIOD` and `IDLE_TIMEOUT`, and prints
what it used, because a cell run with a non-default bound and reported as a default one is worse than
no cell at all.

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
- **`keep_up` is only valid for a cell shorter than one lap of the source clip.** The source loops
  with `tsp --infinite`, so its PCR timeline rewinds every ~600 s and the delivered *span* — last PCR
  minus first — saturates at the clip length. The five 165 s cells report `keep_up` 1.001 correctly;
  the 765 s cycle cells report 0.779, which is 596.27 s of span in a 765 s window and is arithmetic,
  not loss. Those cells are read on delivered bytes, holes and continuity, all of which stay valid,
  and the 405 s cells return `keep_up` 1.000 as a check on that reading. A permanence measurement
  would need [`ts-continuous-source.py`](scripts/ts-continuous-source.py) instead; an isolation
  measurement does not, since every arm and the control lap identically.
- The segmented lane's half of F11 is **not** run here. It needs the HTTP/3 origin lane, and the
  honest expectation — a cache serving idempotent GETs has less to exploit — is exactly the kind of
  expectation that should be measured rather than assumed, so it stays open rather than being
  asserted.

## Results

**The media plane is isolated. The relay's memory is not, and the cost is not given back.** One cell
per arm on the secondary, 40 concurrent abusers where the arm specifies them, abuser liveness confirmed
at 42 concurrent for `storm` and `ghost`.

### What the victims saw: nothing

| arm | victim 1 bytes | victim 2 bytes | `keep_up` | holes > 100 ms | continuity errors |
|---|---:|---:|---:|---:|---:|
| `control` | 198,111,016 | 198,111,016 | 1.001 | 0 | **0** |
| `storm` | 198,112,520 | 198,112,144 | 1.001 | 0 | **0** |
| `ghost` | 198,112,144 | 198,112,144 | 1.001 | 0 | **0** |
| `churn` | 198,111,580 | 198,111,392 | 1.001 | 0 | **0** |
| `slow` | 198,104,248 | 198,104,248 | 1.001 | 0 | **0** |

Every arm delivers within **8 KB of the control across 198 MB** — a spread of 0.004 %, well inside
anything this rig could call an effect — at `keep_up` 1.001 and a 165.15 s media span in a 165 s
window. **Pass criteria 1, 2 and 3 are met by every arm**, including `slow`, the arm expected to be
worst because the relay must either buffer without bound or drop.

### What the relay paid: up to 22× its working set, not returned within the window

Relay RSS, sampled per PID once a second:

| arm | baseline end | abuse peak | recovery end | reclaimed |
|---|---:|---:|---:|---:|
| `control` | 87.1 MB | 94.9 MB | 99.7 MB | — |
| `slow` | 87.6 MB | 95.0 MB | 102.8 MB | — (no effect) |
| `churn` | 87.6 MB | **754.1 MB** | 746.3 MB | **1 %** |
| `ghost` | 87.8 MB | **903.6 MB** | 440.0 MB | **51 %** |
| `storm` | 87.6 MB | **1907.9 MB** | 1759.7 MB | **8 %** |

**`storm` takes the relay from 87 MB to 1.9 GB in 60 seconds** — 22× — and 45 s later it is still
holding 1.76 GB. `churn`, which is one session at a time opened and SIGKILLed after 0.3 s, reaches
754 MB and gives back 1 %. `ghost` — subscriptions to broadcasts *that do not exist*, the cheapest
abuse available and one needing no knowledge of what the relay carries — reaches 903 MB and returns
about half. **Pass criterion 4 fails for three of the five arms.** Threads (9) and file descriptors
(12–13) are flat throughout in every arm, so this is not connection or stream handle accumulation, and
criterion 5 passes.

`accept_failures_total` and `accept_stalled_seconds` stay at **0** across every phase of every arm: the
relay never refused or delayed a connection, so nothing here is admission-control pressure. It absorbed
the abuse and paid for it in memory.

**Read "reclaimed" in that table as "within 45 s", not as "ever" or "at all".** A single cell cannot
distinguish a cost paid once from a cost paid per episode, and the difference decides whether this is
a provisioning number or a fatal one. The next section settles it: the cost is paid once and reused.

### What the 1.9 GB actually is

The five arms above establish that the cost exists. They do not say what it is, and the four
measurements that follow were run to separate mechanisms that the single-cell result cannot: each
varies exactly one thing against the `storm` arm and leaves the rest of the cell identical.

| variant | what changed | abuse-1 peak | growth over baseline |
|---|---|---:|---:|
| `storm` as run above | — | 1,911.5 MB | 1,833 MB |
| cache capped | `--cache-capacity 256MiB` | 1,930.2 MB | 1,852 MB |
| **held** | `STORM_PERIOD` 5 s → 3600 s, so one generation | **143.8 MB** | **65 MB** |
| **shorter retention** | `--server-quic-idle-timeout` 30 s → 10 s | **488.8 MB** | **410 MB** |

**It is not the group cache.** `moq-relay`'s own configuration documents the cache as "unbounded
unless `cache.capacity` or `cache.headroom`", which made an unbounded cache the obvious explanation
and the arms above were all run with the default. Setting an explicit 256 MiB cap — confirmed applied,
the relay logging `cache capacity set capacity=268435456` — leaves the peak **unchanged**, marginally
higher and well inside the run-to-run spread. Whatever holds this memory is not charged to the cache
budget, so **the one documented memory bound the relay offers does not bound it.**

**It is not concurrency.** Holding the same 40 subscribers for the whole abuse phase instead of
killing and relaunching them every 5 s costs 65 MB against 1,833 MB, at an identical peak of 42
concurrent abusers — 1.6 MB per subscriber, consistent with the ~3.22 MB per-subscriber baseline
[T9](test-9-performance.md) measured. **Twenty-eight times the memory for the same audience**, the
only difference being that the subscriptions were repeatedly created and destroyed.

**It is abandoned-session retention, and the retention window sets the price.** A subscriber killed
with `SIGKILL` sends no `CONNECTION_CLOSE`, so the relay cannot distinguish it from a silent peer and
serves it until the idle timeout expires — 30 s by default, which [T6](test-6-relay-resilience.md)
measured as a property of failover. At a 5 s churn period that means roughly seven generations coexist
inside the relay, so "40 abusers" understates what it holds by nearly an order of magnitude. Cutting
the timeout to 10 s cuts growth 4.5×. The scaling is steeper than the 2.3× the generation count alone
predicts, which is consistent with each retained session also accumulating undelivered media for as
long as it is retained: at 9.95 Mb/s a session held 30 s accrues ~37 MB, and 1,833 MB over 42 sessions
is ~44 MB each.

That last figure is the one worth carrying forward. **A dead peer is not flow-controlled.** The `slow`
arm — a subscriber that stays connected and stops reading — cost nothing measurable, because QUIC flow
control pushes back on a live receiver that will not drain. A killed peer offers no such feedback, so
the relay queues for the full retention window at the full media rate.

### What this establishes, and the claim it revises

[Comparison](../docs/comparison.md) §2 asserts that a relay holding per-subscription state is
structurally more exposed than a cache serving idempotent GETs, and this experiment existed because
that claim had no evidence. **It now has some, and it is narrower than the assertion:** the exposure is
real and large, it is reached by an ordinary client using only the shipped CLI, and it lands entirely on
the relay's memory rather than on any other subscriber's stream.

It also **qualifies this campaign's own finding that relay memory is not an audience term**
([T9](test-9-performance.md), T8b C6). That result holds for a *steady* audience and is confirmed here
by the held variant at 1.6 MB per subscriber. It does not extend to subscription churn: 40 subscribers
arriving and leaving every 5 s cost 1.8 GB in a minute, where the same 40 established subscribers cost
65 MB. **The growth term is subscription lifetime against churn rate, not concurrency** — which is the
distinction the "not an audience term" phrasing elides, and it is now stated wherever that finding is.

**For an operator the whole result reduces to two numbers.** Provision the relay for
`abandoned-session rate × idle timeout × media rate`, which is what an audience of crashing receivers
costs; and know that `--server-quic-idle-timeout` is the control on it, at the cost of declaring live
but silent peers dead sooner. The default 30 s is a failover-detection choice
([T6](test-6-relay-resilience.md)), so the two requirements pull against each other and the trade-off
should be made deliberately rather than inherited.

### Open

**Whether the retained memory is reclaimed slowly or never was the wrong question**, and the cycle
re-run answered a better one. Across four abuse cycles with a 120 s recovery each, the relay reaches
1,911 MB on the first and 1,959 MB on the fourth, recovering to 1,721 / 1,896 / 1,905 / 1,909 MB. So
it is *neither*: barely reclaimed on a two-minute timescale, and not re-paid on subsequent episodes.
The high-water is retained and then **reused**, which is why pass criterion 4 fails while the
exposure is still bounded — by peak concurrent retained sessions, not by how many storms arrive.

**One candidate upstream report is identified and deliberately not filed.** The reportable claim would
be that a stalled or dead subscriber's queue is not charged against `cache.capacity`, which is the
relay's only documented memory bound. Three reasons to hold it: the behaviour is fully explained by
documented mechanisms (idle timeout) and has a documented mitigation; the pool-versus-RSS attribution
rests on RSS alone, and stating it properly needs the relay's own `pool.used()` series read through
the `--stats-prefix` broadcast to show the queue is outside the budget; and two well-evidenced reports
are already open on this component ([#3493](https://github.com/moq-dev/moq/issues/3493),
[#3491](https://github.com/moq-dev/moq/issues/3491)). Reading the pool series is the one measurement
that would turn this into a filing, and it is cheap.

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
