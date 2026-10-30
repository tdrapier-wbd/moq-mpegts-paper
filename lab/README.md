# Laboratory notebook — MoQ ⇄ MPEG-TS validation campaign

This directory is the engineering notebook for the MoQ MPEG-TS primary-distribution evaluation. It
holds the campaign **plan** — the objective, the gate mapping and the pass criteria fixed before the
numbers were known — and the campaign **record**: for each experiment, the objective, environment,
exact procedure, measured results and conclusion, written so that an external engineer can reproduce
it. It is the executable companion to [evidence](evidence.md) §1.2, which defines the
validation pyramid and the acceptance gates.

Four other files here are not experiments. [`evidence.md`](evidence.md) gathers the results by
question, with the method, the instruments and the limits of the evidence; where an observation here
has become a finding, a test file points to it rather than restating it.
[`method-notes.md`](method-notes.md) is the rulebook to consult before designing or grading an
experiment. [`upstream-contributions.md`](upstream-contributions.md) records what was found, reported
and verified in other people's projects, including the review of the MSFTS carriage specification.
[`planned-experiments.md`](planned-experiments.md) is the roadmap of what remains. The paper in
[`docs/`](../docs/) states what has been learned, and cites `evidence.md` for it.

> **On honesty.** The plan is written to be disproven. Results that reached the wrong conclusion and
> were later corrected are recorded in the per-test files, which state the current finding and, where
> the correction carries a lesson, why the earlier reading was wrong.

> Machine-specific detail — addresses, the EC2 host IP, absolute paths, TLS fingerprints, build
> locations, credentials — is not in this public notebook. It lives in the git-ignored
> `INSTRUCTIONS.local.md`, and public commands use placeholders such as `<EC2_IP>` and
> `<subscriber-home-ip>`. Every rig script is committed.

## Objective

Validate whether MPEG-TS transported via MoQ can meet professional broadcast distribution
requirements — specifically, whether a groomed MoQ egress is **bit-transparent** to the transport
stream, **timing-conformant** to TR 101 290 P1/P2 on real hardware, and **resilient** under realistic
network impairment and infrastructure failure.

The thesis fails if any of the following holds and cannot be remedied:

- MoQ carriage is *not* bit-transparent (continuity errors, dropped signalling, or structural
  corruption survive a lossless path).
- Groomed egress cannot pass **TR 101 290 P1/P2 on a hardware IRD** (the make-or-break gate —
  [evidence](evidence.md) §1.2, Gate 2).
- Impairment or failure behaviour is qualitatively worse than the incumbent IP transports
  (SRT/Zixi/RIST) it would replace, at matched conditions.

The campaign does not attempt to prove economic superiority, which is a separate, route-specific
exercise ([economics](../docs/economics.md)); its desk working is kept here as an analysis
([cost-model.md](cost-model.md)).

**Ordering.** Run cheap-and-decisive first: T1 (reference) → T2 (media-aware fidelity) → T3 (opaque
fidelity, Gate 1) → T7 file-based, then T7 hardware (Gate 2, make-or-break) → T4/T5/T6 (real path,
impairment, resilience — Gate 3). If Gate 2 fails, stop and fix grooming before investing in scale
work: a resilient path that a hardware IRD rejects is not a product.

## Experiments

Every experiment the campaign has specified, run or not, has its own file, structured as Objective /
Environment / Procedure / Results / Observations / Conclusion / References. **The file is
authoritative** for its measurements, scope and qualifications, and its `State:` line for how far it
has got. The *Current finding* column is an index entry, not a summary of the evidence: one line, and
no number without the conditions its file states. The rung and gate are from
[evidence](evidence.md) §1.2.

| # | Experiment | Rung · gate | State | Current finding | File |
|---|---|---|---|---|---|
| T1 | Baseline TS characterisation (P0 reference) | reference · precondition for Gate 1 | complete | The four-clip source set is clean and representative, so downstream deltas are honest | [test-1](test-1-baseline-ts.md) |
| T2 | Transport transparency — media-aware lane | 1–3 · Gate 1 (reference lane) | complete | Every elementary stream and the DVB service layer round-trip; the lane's own PCR cadence does not | [test-2](test-2-media-aware-transparency.md) |
| T3 | Transport transparency — the opaque lane and segmented HTTP | 1–3 · **Gate 1 (product lane)** | complete | `moq-dev`'s passthrough is byte-identical on all three inventory clips, PCR accuracy at 481 ns included; segmented HTTP adds one PAT/PMT pair per segment | [test-3](test-3-opaque-transparency.md) |
| T4 | Remote relay end-to-end + SRT contribution | 2 · Gates 1 and 3 | complete, all three lanes | Three data planes graded over one internet path by one instrument; the service layer survives it | [test-4](test-4-remote-e2e-srt.md) |
| T5 | Network impairment | 2 · Gates 1 and 3 | complete | Loss behaviour is the congestion controller's, not the lane's; its reordering cell is superseded by T20 | [test-5](test-5-network-impairment.md) |
| T6 | Relay resilience and active/active source failover | 6 · Gate 3 | partial | Relay failover is bounded by the QUIC idle timeout and is not hitless; a graceful source exit still ends the export; the shared-hop and shared-epoch arms measured a mechanism upstream has since removed | [test-6](test-6-relay-resilience.md) |
| T7 | Timing integrity (TR 101 290) | 3 (file), 4 (**hardware**) · **Gate 2** | P1 complete; P2 open | The re-stamp arithmetic is right on file, which is necessary and not sufficient | [test-7](test-7-timing-integrity.md) |
| T8 | SRT against MoQ | 7 · feeds economics §4, §9 | partial | Graded on throughput and continuity at a matched controller, MoQ and SRT are on par through 10 % loss; graded on content, T28 finds SRT loses less | [test-8](test-8-srt-vs-moq.md) |
| T8b | Congestion control for a permanent fixed-rate trunk | 7 · extends T8 | complete, C1–C7 | **No controller recommendation is supportable**; provisioning margin, queue discipline and the receiver's budget govern the feed | [test-8b](test-8b-congestion-control.md) |
| T9 | System performance and resource utilisation | 5 · feeds architecture §9, economics §3 | partial | Publisher and subscriber pass; relay growth is root-caused to `quinn-proto` stream recycling; its N = 55 knee was the test box (T26) | [test-9](test-9-performance.md) |
| T10 | MPTS / multiple concurrent services | 3 + 5 · Gate 1 | arms A, B, D run on two builds; C, E not run | The segmented lane carries a three-programme multiplex; the MoQ lane's handling varies by build, and on `main` a programme must be selected | [test-10](test-10-mpts-multiservice.md) |
| T11 | Cross-implementation interop | 7 · transport neutrality | T11a run at `main`; T11b, T11c, T11d run | `moq-dev`'s TS crosses seven of nine third-party relays intact from the join, two of them (libquicr, moqx) in both of the runner proposal's cases; imquic and red5 lose packets; OpenMOQ's TS (MSFTS with a fix, and moq5) crosses a `moq-dev` relay byte-exact; `moq-dev`'s demultiplexed TS crosses moq5's relay, its passthrough does not; neither catalog finds the other's TS track; on draft 22, `moq2ts` and `moq-dev` part at the first SUBSCRIBE either way | [test-11](test-11-interop.md) |
| T12 | End-to-end 1+1 dual-path delivery and hand-off | 6 · Gate 3 | complete for a co-started pair, arms A–D; opaque-lane late join passed | Two stream-clocked groomers are byte-identical and hitless **on single-track content**; a multi-track mux over independent chains does not merge at the byte; on the opaque lane, with the pacer fixed, a late join and a leg's loss and return are hitless (one clip, one host) | [test-12](test-12-dual-path-handoff.md) |
| T13 | Off-the-shelf CBR/PCR grooming of an MPEG-TS egress | 4 · Gate 2 | complete for four tools on both data planes | **It depends on the lane**: `tsp` grooms a segmented egress to all four criteria; behind a MoQ egress nothing off the shelf passes | [test-13](test-13-downstream-grooming.md) |
| T14 | MoQ against segmented HTTP on one route | 7 · Gates 1 and 2 | partial | Segmented HTTP is verbatim in payload for one programme and much coarser at the hand-off; hardware and MPTS-through-CDN need kit this lab lacks | [test-14](test-14-data-plane-comparison.md) |
| T15 | RIST and SRT on T14's cadence instrument | 7 · extends T14 | complete on a healthy path | RIST and SRT are transparent to their source's cadence, where MoQ sets its own granularity | [test-15](test-15-point-to-point-cadence.md) |
| T16 | Grooming a segmented-HTTP egress | 4 · Gate 2, alternative plane | complete on a healthy path | The same groomer, unchanged, takes a segmented egress to the MoQ lane's conformance; cushion depth is the operative variable | [test-16](test-16-grooming-segmented-http.md) |
| T17 | Standalone SI on snapshot tracks | 2–3 · closes the EIT residual | complete; design merged | Neither plane loses an EPG; carriage is bitrate-neutral and the join costs 1 ms | [test-17](test-17-si-snapshot-tracks.md) |
| T18 | Delivery latency at equal conformance, four data planes | 1 · supports Gate 2 | complete, loopback and internet | **It refuted its premise**: on the media-aware lane latency and PCR conformance are independent, and the fastest cushions are not P1/P2-conformant on any lane | [test-18](test-18-delivery-latency.md) |
| T19 | The PCR grid, and a CBR wire from a media-aware source | supports Gate 2 | complete; criteria 1–3 met, 4 not | **The lane passes PCR repetition on the wire** after three upstream fixes and three groomer fixes, and **fails its own latency criterion** at that configuration | [test-19](test-19-pcr-grid-verification.md) |
| T20 | The segmented lane over HTTP/3 | Gate 1 · substrate matching | complete | T5's reordering separation was a packet-size artefact; through a byte-faithful receiver the HLS wire is PCR-conformant and the impairment cells are re-measured | [test-20](test-20-segmented-http3.md) |
| T21 | Permanence soak of the complete media-aware lane | Gate 2 over time | complete; the seven-day live arm meets its resource and unattended criteria, its PCR criterion graded at ±18.5 µs | **169 h unattended on the live feed with every resource series flat**; each media-plane event was damage arriving in the contribution | [test-21](test-21-permanence-soak.md) |
| T22 | Silent media-plane failure | R8 | complete, both lanes | **Neither lane's transport detects a stalled source**; only the segmented lane's playlist moves | [test-22](test-22-silent-media-plane-failure.md) |
| T23 | Which PCR timeline events the lane survives | Gate 2 | complete, re-graded against both fixes | The 33-bit rollover always carried; since #3375 and #3529 every placed class sits at the control's content gap | [test-23](test-23-pcr-discontinuity-classes.md) |
| T24 | A partial media-plane stall | R8 · corrects T22 | complete | The lane contains the failure, but **TR 101 290 P1 cannot see it**; only per-PID access-unit liveness caught every arm | [test-24](test-24-partial-media-plane-stall.md) |
| T25 | Isolation under abuse | R2/R7 | complete, both lanes | **Both planes isolate the victims' media**; abuse costs the MoQ relay memory through abandoned-session retention, which the idle timeout sets | [test-25](test-25-isolation-under-abuse.md) |
| T26 | Cross-host fan-out and the knee | R2 | complete | The relay's marginal cost is small, constant and linear and relay CPU binds first, on 0.14.15 (quinn); the current build does not reproduce the slope (T43) | [test-26](test-26-cross-host-fanout.md) |
| T27 | The per-PID liveness detector | R8 | complete | The detector survives the distribution path and catches the audio case; its first live run found a real fault | [test-27](test-27-liveness-detector.md) |
| T28 | Failure injection, scored in media lost | 6 · Gate 3 | partial; infrastructure axis run on MoQ and SRT | **Graded on content, SRT loses less programme than MoQ under all three shapes**, by a margin build and QUIC backend set; restarting a publisher, or a relay that does not keep its reset key, costs MoQ its 10 s idle timeout, an exporter costs SRT its 5 s peer idle | [test-28](test-28-failure-injection-matrix.md) |
| T29 | MoQ distributed resilience above the 1+1 pair | 6 · Gate 3 | specified, not run | — | [test-29](test-29-moq-distributed-resilience.md) |
| T30 | Segmented distributed resilience | 6 · Gate 3 | every cell run but 6; criteria 1, 4, 5 (grader), 6 met, 2 and 3 failed | A co-started pair is hitless on one host, and across two only with a fixed bitrate, no store delegations and a common start; a late packager cannot join its namespace; disagreeing replicas and a stale edge lose most of the programme without an error that names the cause | [test-30](test-30-segmented-distributed-resilience.md) |
| T31 | Congestion and capacity step ladders | 7 · R4/R5 | partial; the delay matrix run, sustained and transient; the relay's queue read from qlog on the transient | **MoQ loses picture at every sustained shortfall, including 0.9×**, and no release delay up to 6 s prevents it; a transient's loss at 20 ms RTT is mostly the relay abandoning groups; the segmented lane loses less by falling behind rather than discarding | [test-31](test-31-congestion-capacity-ladders.md) |
| T32 | Would commercial monitoring have caught T22, T24, T27? | R8 | fault-to-telemetry mapping measured; vendor survey not started | The mapping is measured on both lanes; what remains is vendor outreach | [test-32](test-32-observability-survey.md) |
| T33 | Gate 2 preparation: boundary fixtures and harness | 3–4 · **de-risks Gate 2** | run; nine of ten criteria met | Every buildable boundary condition carried with zero continuity errors; the harness is rehearsed with its pass table fixed | [test-33](test-33-gate2-preparation.md) |
| T34 | A real encoder against the continuous-source fence | 2 · Gate 3 | one real step graded | **The real feed steps back where its contribution switches between two encodes, unflagged**: both legs' imports end and a subscriber loses 9.8 s; the nine exits first captured were mis-stamped SCTE-35 cues | [test-34](test-34-real-encoder-severity.md) |
| T36 | Entitlement enforcement | control plane | complete; six of six criteria, and FETCH and TRACK_STATUS refused outside the grant | The relay admits exactly what a credential names, **before any media is delivered** | [test-36](test-36-entitlement-enforcement.md) |
| T37 | Provisioning and de-provisioning | control plane | complete; criterion 2 failed | **The binding finding is correctness**: three `Cache-Control` forms disable re-checking silently, so a withdrawn grant never takes effect | [test-37](test-37-entitlement-revocation.md) |
| T38 | The affiliate estate | control plane | complete; six of seven criteria, and four of four behind an auth server | **The key-per-entitlement estate scales**, because neither the relay nor the auth server holds keys; a deleted key stops a live session only on a re-check | [test-38](test-38-entitlement-estate.md) |
| T39 | Observability across the administrative boundary | R8 · control plane | Part A passed; Part B needs a small client written | A client-edge process catches a partial fault no relay-side telemetry can express; nothing shipped can carry it back | [test-39](test-39-cross-boundary-observability.md) |
| T40 | The content-join stall through the SRT chain | 2 · Gate 3 | complete, conclusive | The SRT ingest carries #3533's trigger; on `main` at `9d2a4f6e` the chain is healthy through every join | [test-40](test-40-continuous-join-through-srt.md) |
| T41 | Which TS stream kinds re-anchor below the live edge | 3 · Gate 3 | complete, conclusive; a flagged rewind carried by restart measured | **#3798 has two parts** (no re-anchor; one re-anchor only), so the fix had to be cumulative; fixed on `main` at `9d2a4f6e`. Restarted under a new epoch, a flagged rewind costs ~3 s pipe-fed and 1+1 stays identical in 8 of 13 runs; a 1+1 ingest pair keeps both legs but costs up to the legs' skew more | [test-41](test-41-import-reanchor-coverage.md) |
| T42 | A byte-faithful HTTP/3 HLS receiver | 3 · closes P0-e | built and validated | The old receiver reported clean carriage unconditionally; the new one matches `tsp -I hls` hash for hash | [test-42](test-42-h3-receiver-fidelity.md) |
| T43 | Fan-out on the current build | R2 | S1–S3 run; the hour deferred | **T26's model does not transfer to the current build**, and each carried channel is a cost of its own | [test-43](test-43-fanout-current-build.md) |
| T44 | The transmux lane against a calibrated T-STD model | 3 · R3 | complete, conclusive | **The lane's P1/P2-conformant wire is not a conformant transport stream**; a T-STD re-multiplexer repairs it offline | [test-44](test-44-tstd-grading.md) |
| T45 | A live T-STD re-multiplexer behind the lane | 3 · R3, P0-l | questions 1–3 answered; on the merged export, 1+1 across hosts identical | **A live re-multiplexer makes the wire T-STD-conformant**, at 2.20 s presentation latency on `ffa5b81b` (loopback, one clip, one run) | [test-45](test-45-live-tstd-remux.md) |
| T46 | Two T-STD checks cross-validated | instrument validation · R3 | complete, offline | The two agree on all 35 files on upstream `main`'s merged check; every earlier disagreement traced to upstream's check, since fixed, and `ts-tstd.py`'s own defects are fixed with no verdict moved | [test-46](test-46-tstd-check-cross-validation.md) |
| T47 | The upstream fixed-delay TS export (#4645, merged) | 3 · R3, P0-m | merged build graded on loopback, across hosts and under loss, and for 35 min across source joins | **Every track and buffer at joins across a whole GOP**; it stops between 2 and 3 % loss at 1 s; 500 ms does not last a whole capture; on later `main` no re-request dies on a late unit, and a replacement is followed only under `--stitch` | [test-47](test-47-fixed-delay-export.md) |
| T48 | The passthrough TS export on real captures (our quest implementation, merged) | 3 · R3 | complete; criteria 1–4 pass on a dedicated host and on the live feed across hosts, 5 fails on its accounting | **Each leg is the source's bytes and a leg 8 s late is the same stream**, on the live feed over the internet too, with every PCR within 2 ms; at 10 % loss it delivers 6–7 % of the video, as little as every MoQ export graded on content there | [test-48](test-48-passthrough-export.md) |
| T50 | Deterministic TS legs, `export ts --sync` (our `ts-hitless`, #5949, merged) | 6 · R6 | run; passes but 3 as written, 6 in the port's first second, 7 partial; the mode is being removed upstream | **Legs that joined apart or lost complementary content write the same packets on a broadcast mux** once each group opens where the encoder's HRD says the one before has arrived; anchored at its first release, a group that overran the video lane splits the legs at any mux rate | [test-50](test-50-deterministic-ts-legs.md) |
| T51 | Same-epoch importers that number groups alike (our `hop-aligned-import`, [#5895](https://github.com/moq-dev/moq/pull/5895)) | 6 · R6 | run; declined upstream | **On a clean exit the change removed #4354's rewind on both lanes**, where the stack without it rewinds or repeats 0.6 s; upstream closed it and removed the shared epoch, so no merged build has the pair | [test-51](test-51-same-epoch-groups.md) |
| T52 | Fan-out and permanence through a CDN-hosted relay | R2, P1-j | ramps and the demultiplexed 72 h soak run | — | [test-52](test-52-cdn-relay-fanout.md) |
| T53 | Token interoperability across relay implementations | R7, P1-ac | run; H2 and H4 hold, H1 and H3 do not | **Enforcement transfers and the token does not**: both relays refuse outside a grant before any payload byte, but format, client carriage, key scope, disclosure and withdrawal differ, and moqx v0.3.6 withdraws a grant only by a restart | [test-53](test-53-token-interop.md) |
| T54 | Dependency risk: what following upstream cost (desk) | P2-n | complete | **The cost of pre-1.0 is in following upstream, not in running it**: one migration reached every rig, then a breaking change about weekly, mostly on `main` before any release; the standing units held a build for 23 days | [test-54](test-54-dependency-risk.md) |
| T55 | 2022-7 legs from `tsp`'s RTP output on passthrough exports | 6 · R6, P0-k, P1-b | run; H1 and H3 hold, H2 does not; the stream-clocked arm's fix holds | **Co-started legs make a pair; no leg event the export's delay does not absorb leaves one**: `tsp` numbers by its own count, so a late join, restart or skip loses protection, and a kill also costs a datagram. Stream-clocked groomers kept legs started apart paired through a restart and a 1 s stall, and lost nothing when a 10 s stall ended a leg | [test-55](test-55-tsp-rtp-legs.md) |
| T56 | Media-aware failover: what a decoder sees, and how small it can be made | 6 · R6, P1-ab | run; C4 and R1 pass, C0, C2, C3, C5 and one-source C6 fail | **Every leg event is a switch in the relay**, a standby's start included. On later `main` a switch keeps the export's delay, so an arrival loses next to no programme and a hard kill only its detection interval, ending no export; no idle timeout takes a hard kill under a second as a decoder sees it. Selection at the receiver avoided every relay switch | [test-56](test-56-media-aware-failover.md) |
| T57 | Source-to-egress media timing across hosts on one clock | P1-aa | complete; C2 passes, C1 fails on arrivals | **Across hosts an export holds its delay on the media clocks for 72 h and runs at its source's rate**: 4,031.8 ms with no drift at 0.004 ppm, 0.014 ppm off the source; timed on arrivals, each multiplexer's scheduling moves it by tens of milliseconds a minute | [test-57](test-57-cross-host-timing.md) |
| T58 | 1+1 on the media-aware lane, selected at the receiver | 6 · R6, P1-af | run; C0 and C3 hold, C2 and C4 fail | **Legs started and restarted apart cost nothing; every fault but an outage under the receive timeout costs 0.6–3.6 s of hole**: a switch that detects on silence waits for the export's delay and a second of padding after a hard kill, and a cut across missing programme corrupts to the next random-access point | [test-58](test-58-receiver-select.md) |
| T59 | Segmented 1+1 over CloudFront: two pathways, two receivers, a 2022-7 merge | 6 · R2, R6, P1-ai | run, the two-receiver topology; H2 and H4 hold, H3 only at a window covering the skew | **Every single-pathway failure is hitless at a window covering the skew, which each start sets at random up to ±1.5 s**: a Class C receiver follows one leg and skips or repeats up to 2 s when it fails; the run fixed two groomer defects the live feed exposed | [test-59](test-59-segmented-1plus1-cloudfront.md) |
| T60 | Aligned leg start: two segmented legs that join apart, in phase | 6 · R6, P1-ai | run; H1 holds on one pathway and fails across two; the follow-up's H5 and H6 fail | **Aligning each leg on its path's fastest delivery does not bound the skew between paths**: each leg's window samples its own delivery (the playlist's visibility and the segment's hand-off to the groomer), and an uncached playlist narrows the spread without bounding it | [test-60](test-60-aligned-leg-start.md) |
| T61 | Source protection in the CDN: interchangeable origins in one CloudFront origin group | 6 · R2, R6, P1-ai | run (six cells); every criterion holds | **No failure of the primary's pathway cost either receiver a segment**: epoch-locked packagers on two hosts cut identical segments, a staleness guard turns a frozen packager into a 404, and the origin group fails over on it, on a refused connection or on its timeout | [test-61](test-61-origin-group-failover.md) |
| T62 | Permanence of the single-CDN design: 72 h through one origin group | 6 over time · P1-aj | run, 72 h; C2 fails, the rest hold | **Over 72 h the design added no failure of its own, and six continuity breaks in the contribution cost 54 s on both pathways at once**: the segmenters' withdrawal, not redundancy, sets availability; the groomer soaked left PTS 4.7 h from PCR after a splice | [test-62](test-62-origin-group-soak.md) |
| T63 | Receivers at different edges in phase: release on the origin's program date-time | 6 · R6, P1-ai | run; H1 and H2 fail; the follow-up's H5–H8 hold | **Receivers at two CloudFront edges, released on the origin's program date-time, start within 1.1 ms of each other** (ten trials, one host), once the groomer takes a segment in fast; unreleased, the same edges spread to 379 ms | [test-63](test-63-pdt-anchored-release.md) |
| T64 | A synthetic unflagged encoder switch | 2 · P1-an | the reproducer built and replayed; upstream's tolerance is T67's | **A public stimulus reproduces T34's switch both ways**: back, the import exits with the live error and 2.48–2.52 s is lost against the capture's 2.8 s; forward, every export ends on its clock check | [test-64](test-64-synthetic-encoder-switch.md) |
| T65 | What an HLS input keeps: our segmented output against free HLS receivers | 3 · R3 | run once, with a validator control; H1 fails on the clip, H2 and H3 hold | **An HLS input that hands on the segments' bytes keeps every DVB table and SCTE-35 section verbatim; FFmpeg's remux replaces the multiplex**, and Apple's validator fails a contribution clip on interlace and open GOP whatever the packager (loopback, one clip) | [test-65](test-65-ird-hls-profile.md) |
| T66 | A scrambled multiplex through the opaque lane, the groomer and a descrambling receiver | 1 · R7, P1-al | run twice; the second holds every criterion | **A DVB-CISSA-scrambled multiplex crosses the opaque lane and the groomer byte for byte, its CA PIDs with it, and a descrambler before the pacer returns the clear source**; the media-aware lane announces no broadcast, and our segmenter names no segment (loopback, one clip; no key ladder) | [test-66](test-66-scrambled-carriage.md) |
| T67 | The import's own restart at an unflagged encoder switch | 2 · P1-an | run; every criterion holds | **Upstream's import now republishes itself at an unflagged switch, back or forward, and no export ends**: 1.36 s lost on T64's stimulus and 1.6 s on T34's capture, against 2.4–2.8 s behind a supervisor, all but the truncated picture the restarted import's catalog hold (loopback, late October 2026 `main`) | [test-67](test-67-import-step-restart.md) |
| T68 | The segmented chain's cushion, catch-up and path faults | 6 · R5, R6, P1-ag | run; every criterion holds but criterion 7's second half, the receiver's | **Two independent chains of the current segmented design are byte-identical from a 3 s cushion (hold and alignment) or 1.5 s (neither), not 8 s, the floor set by the clip's cuts; a 10 s frozen playlist costs what the cushion fails to cover, and the cap never binds** (loopback, one clip); **under T28's path faults at matched latency the origin's controller decides: nothing lost on BBR, more than the MoQ lane on CUBIC** | [test-68](test-68-segmented-chain-cushion-faults.md) |
| T69 | Access and scrambling on the segmented lane: a CAT gate at CloudFront, and a scrambled source through `tsp -O hls` | 1 · R7, P1-al | run once; every graded criterion holds, the revocation prediction falsified | **Revocation through CloudFront's KeyValueStore takes a median 24–28 s per PoP and up to 86 s, and expiry is exact; without `--intra-close`, `tsp -O hls` carries a scrambled multiplex byte for byte and a descrambler after the receiver returns the clear source**, while with it no segment is published (two PoPs; loopback, one clip) | [test-69](test-69-segmented-access-and-scrambling.md) |
| T70 | The segmented chain's latency against the 5–10 s budget, over the internet path | 1 · R4, P1-ah | run; every criterion holds | **At its floors the current chain delivers in 2.6–4.5 s, P1/P2- and buffer-model-conformant: 2,604 ms at 1 s epochs without the receiver's hold, 4,475 ms at 2 s with it; the floors are the clip's cuts, as on loopback** (one 12 ms path, one clip, unimpaired) | [test-70](test-70-segmented-latency-budget.md) |
| T71 | The latency ordering on a long, lossy path: SRT and both MoQ lanes at a 1 s budget, about 120 ms away, clean and at 0.1 % and 1 % loss | 1 · R4, P1-ad | run; criteria 1–4 hold, the ordering survives 0.1 % and not 1 % | **At a 1 s budget 116 ms away SRT and the opaque lane deliver in about 1.03–1.05 s and the media-aware lane in 1.28 s; at 1 % loss only SRT stays whole, each MoQ lane losing under a second in one replicate of three**, and on CUBIC neither MoQ lane carries the programme at 0.1 % (one path, one clip, random loss) | [test-71](test-71-long-lossy-path.md) |
| T72 | The segmented lane through a CDN edge under T28's path faults | 1 · R5 | run; every criterion holds | **Through a CloudFront edge the segmented chain loses nothing under 5–10 % last-mile loss or 5–20 % reorder at 100 ms RTT, at 5.91 s and 11.87 s: T68's BBR row, where the origin's CUBIC loses 60–71 s**; a 5 s outage still costs 8.8 s at 5.91 s (one point of presence, Bernoulli loss, HTTP/1.1) | [test-72](test-72-segmented-cdn-edge-impairment.md) |

**Retired roadmap IDs** resolve to the experiment that discharged or holds them: P0-e → [T42](test-42-h3-receiver-fidelity.md), P0-f → [T22](test-22-silent-media-plane-failure.md)
and [T24](test-24-partial-media-plane-stall.md), P0-g → [T21](test-21-permanence-soak.md), P0-i → [T8b](test-8b-congestion-control.md), P0-j → [T34](test-34-real-encoder-severity.md),
P0-l and P1-u → [T45](test-45-live-tstd-remux.md), P0-m → [T47](test-47-fixed-delay-export.md), P1-a, P1-c, P1-am and P2-l → [T30](test-30-segmented-distributed-resilience.md), P1-ag → [T68](test-68-segmented-chain-cushion-faults.md), [P1-aj](planned-experiments.md#p1--establishes-where-one-architecture-is-superior), P1-d → [T31](test-31-congestion-capacity-ladders.md), P1-e and P2-m → [T10](test-10-mpts-multiservice.md),
P1-f → [T26](test-26-cross-host-fanout.md), P1-g → [T9](test-9-performance.md), P1-h → [T11](test-11-interop.md), P1-i → [T14](test-14-data-plane-comparison.md), P1-k → [T38](test-38-entitlement-estate.md), P1-m, P1-q, P1-y and P1-z → [T28](test-28-failure-injection-matrix.md),
P1-aa → [T57](test-57-cross-host-timing.md), P1-ab → [T56](test-56-media-aware-failover.md), P1-ad → [T71](test-71-long-lossy-path.md), P1-af → [T58](test-58-receiver-select.md), P1-ah → [T70](test-70-segmented-latency-budget.md), P1-ai → [T59](test-59-segmented-1plus1-cloudfront.md), [T61](test-61-origin-group-failover.md) and [T63](test-63-pdt-anchored-release.md), P1-al → [T66](test-66-scrambled-carriage.md) and [T69](test-69-segmented-access-and-scrambling.md), P1-an → [T67](test-67-import-step-restart.md), P1-n → [T13](test-13-downstream-grooming.md), P1-o → [T50](test-50-deterministic-ts-legs.md), P1-p → [T6](test-6-relay-resilience.md), P1-r, P1-s, P1-w and P1-x → [T41](test-41-import-reanchor-coverage.md),
P1-v → [T14](test-14-data-plane-comparison.md), P2-b → [T25](test-25-isolation-under-abuse.md), P2-d → [P1-b](planned-experiments.md#p1--establishes-where-one-architecture-is-superior), P2-h and P1-t → [T48](test-48-passthrough-export.md), P2-n → [T54](test-54-dependency-risk.md).

### Pass criteria (agreed in advance)

These are the criteria fixed for T1–T8 before they ran. Later experiments state theirs the same way,
at the top of their own files.

- **T1 — Baseline.** No pass/fail: T1 defines the reference. Met if the source set is clean (0
  CC/transport/discontinuity errors) and representative (synthetic + broadcast mux + real
  contribution captures).
- **T2 — Media-aware transparency.** (a) All clips round-trip, all elementary components carry with
  0 CC, the open-GOP feed round-trips deterministically; (b) downstream timing conformance
  (`mpegts-pacer`): exact CBR, ≈ 0 % of PCR intervals > 40 ms, 0 `pcrverify` violations at 500 µs at
  P1.
- **T3 — Opaque transparency (Gate 1).** Bit-transparency at P1 — TSID/ONID, service name/type, all
  PSI/SI (PAT/PMT/SDT/NIT/TDT/CAT), PMT PID, PCR PID, every elementary stream and every SCTE-35 PID
  preserved verbatim; 0 CC/transport errors; CBR and PCR conformance (0 % > 40 ms) preserved when fed
  the raw source.
- **T4 — Remote E2E + SRT.** Relay reachable over the internet; live SRT contribution chain completes
  end-to-end with 0 CC.
- **T5 — Network impairment.** Loss behaviour is *graceful and bounded* (proportionate throughput
  reduction, recovery observed), not catastrophic; where loss exceeds recovery capacity within the
  buffer, the redundancy path (T6 / ST 2022-7) is the mitigation, not the transport alone.
- **T6 — Serving-node resilience (Gate 3).** ST 2022-7 dual-path drill is **hitless** at the IRD under
  single-path loss (the two egress legs' RTP datagrams identical, header and payload); relay-failover recovery
  is bounded and documented, re-establishing without operator intervention; subscriber-reconnect join
  latency is bounded with defined catch-up behaviour.
- **T7 — Timing integrity (Gate 2, make-or-break).** A clean **TR 101 290 P1/P2 pass on a real
  hardware IRD, on the live wire (P2), sustained** (≥ 72 h, set by the PCR base's 26.51 h wrap period
  rather than chosen), including ST 2022-7 behaviour under loss, with the T-STD buffer model confirmed
  valid under drift/discontinuity. Until this exists, the grooming design is "structurally sound and
  software-validated," not "proven broadcast-acceptable."
- **T8 — SRT against MoQ (comparative, not pass/fail).** Latency competitive if MoQ + pacer delivery
  latency is within a stated margin of SRT at matched buffer; loss recovery competitive if recovery
  and delivered-rate curves are within a stated margin and the failure mode is no worse; egress
  quality at least matches (P1); overhead/CPU recorded as economic inputs.

### Desk analyses

| Analysis | Purpose | State | File |
|---|---|---|---|
| Always-on cost model (v1) | Price the T9/T8 capacity constants at public list rates: MoQ vs SRT vs MediaConnect vs Cloudflare vs DIY, 1 channel and a transponder's worth, 1+1 | complete, list prices only | [cost-model.md](cost-model.md), rerun with `python3 lab/cost-model.py` |

Every rate is a constant at the top of the script, so re-pricing against a different tariff is a
one-line edit.

## Where the campaign stands, and what is left

What is and is not established is stated once, in [evidence](evidence.md) §2, and the limits
of the evidence in §4. What is outstanding, what blocks it and in what order to run it is stated
once, in [planned-experiments.md](planned-experiments.md), ranked P0/P1/P2 by what a result could
change. Neither is restated here. Read every row of the table above against the limits in
evidence §4, above all that **nothing has been fed to a hardware IRD or graded by a hardware
analyser**: "complete" means complete in software.

The programme has two strands: the original asks which of two data planes can be run permanently, at
scale, by an operations team; the second scores against [control-plane.md](../docs/control-plane.md).
**Three milestones lie beyond the gates, and a deployment decision needs each:** *operations*, a
platform a broadcast NOC can monitor and support under an SLA (R8); *entitlement and security*,
whose enforcement is measured and whose remainder is design; and *dependency risk*, a lane built on
a fast-moving upstream that speaks draft protocol versions.

## Shared test environment and conventions

### Reference topology

```
Source TS (file or live SRT/RTP)
   → Publisher (media-aware `moq import ts`  OR  opaque `moq import ts --passthrough`)
   → [impairment node: tc/netem]
   → MoQ relay (localhost or AWS EC2)
   → Subscriber (`moq export ts --delay`, or `--passthrough` on the opaque lane)
   → RTP/UDP (multicast, ST 2022-7) → hardware IRD + TR 101 290 analyser
   → (egress + source captured to TSDuck)
```

### Measurement points

- **P0 — Source.** Input TS before the publisher; establishes the reference (T1).
- **P1 — Egress (file).** Subscriber's groomed output captured to file, analysed with TSDuck.
  Cheap; catches gross faults; **not** sufficient for hardware acceptance: it grades the bytes of a
  stage that may have run offline, and nothing about arrival.
- **P2 — Egress (live wire).** The output as it leaves the gateway in real time: in software, a socket
  capture graded from its bytes; for acceptance, the input of a hardware IRD and TR 101 290 analyser
  (T7). PCR repetition (interval between PCR values) and accuracy (±500 ns, value against byte
  position) grade the same bytes identically at P1 and P2. Only P2 with arrival timestamps grades
  arrival regularity (PCR overall jitter, the delay factor, frequency offset and drift), and only
  hardware decides IRD lock and acceptance.

### Tooling

| Purpose | Tool |
|---|---|
| TS structural / conformance analysis | **TSDuck** 3.44-4676 (`tsp`, `pcrverify`, `pcrextract`, `analyze`, `continuity`, `pat`/`pmt`/`sdt`) |
| Real-time source pacing | TSDuck `regulate` (PCR-based; `--pcr-synchronous` for looped files) |
| Media-aware lane | `moq-dev` `moq` (import/export) + `moq-relay` (public reference implementation) |
| Opaque lane | `moq-dev` `moq import ts --passthrough` and `moq export ts --passthrough` ([T48](test-48-passthrough-export.md)) |
| CBR/PCR grooming | The merged `moq export ts --delay` on a CBR source; TSDuck `pcradjust` + `regulate` for a VBR one. [`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) 0.1.0, the groomer of record for T2–T21, takes no new features; its `--stream-clock` mode, one per passthrough leg, is the 2022-7 route ([T55](test-55-tsp-rtp-legs.md)); its live adapter was the `moq_egress` example, then `ts_egress`, then the crate's binary, and records name whichever they ran against |
| Network impairment | Linux `tc` / `netem` (optionally `tbf`/`htb` for rate); the shaped-bottleneck rigs are described in `INSTRUCTIONS.local.md` |
| Hardware conformance | Hardware IRD + TR 101 290 analyser (P2; access-dependent) |

### Recurring reproduction commands (P1 analysis)

```bash
# structure / services / PIDs / bitrate
tsp -I file <clip> -P analyze -O drop
# continuity-counter integrity (no output = 0 errors)
tsp -I file <clip> -P continuity -O drop
# PCR accuracy vs estimated CBR (µs, then absolute PCR units: 27 units = 1 µs, 13 ≈ 481 ns)
tsp -I file <clip> -P pcrverify --jitter-max 500 -O drop
tsp -I file <clip> -P pcrverify --absolute --jitter-max 13 -O drop
# PCR interval min/mean/max + % > 40 ms (TR 101 290 P1), from the CSV's 27 MHz offset column
tsp -I file <clip> -P pcrextract --pcr --csv -o <clip>_pcr.csv -O drop
awk -F, 'NR>1{cur=$7; if(prev!=""){d=(cur-prev)/27000; n++; sum+=d;
  if(d>max)max=d; if(min==""||d<min)min=d; if(d>40)over++} prev=cur}
  END{printf "intervals=%d min=%.2f mean=%.2f max=%.2f ms  >40ms=%d (%.4f%%)\n",
  n, min, sum/n, max, over, (over/n)*100}' <clip>_pcr.csv
```

### Conventions

- Every result records **units**, the **measurement point** (P0/P1/P2), the **tool + version**,
  the **source clip**, and the **build under test**.
- Unmeasured quantities are `TBM` (to be measured) — never blank, never guessed.
- Raw captures and analyser exports are the evidence of record; they are large binaries and are not
  committed. The commands above regenerate them from the source clips.
- A result table too large to read inline is committed as CSV in [`results/`](results/) and
  summarised in its per-test file. The rigs are in [`scripts/`](scripts/), named per test; only
  machine-specific values are held out, in `INSTRUCTIONS.local.md`.

### macOS loopback gotchas (local runs)

- Disable UDP GSO on relay and clients, or QUIC handshakes time out on loopback.
- Connect over `https://` and pin the relay's certificate fingerprint explicitly; the `http://`
  fingerprint bootstrap is broken in recent builds.
- Start the publisher before the subscriber, or subscribing to a not-yet-announced broadcast returns
  relay `code=4`.
