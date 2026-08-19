# Lab rigs

Runnable harnesses for experiments in this notebook. They take every machine-specific value
(interface, subscriber IP, rate, delay) from the environment and contain **no addresses,
credentials or personal paths** — the real values live in the git-ignored
`INSTRUCTIONS.local.md`.

| Script | Purpose |
|---|---|
| [`t8b-netns.sh`](t8b-netns.sh) | Self-contained contention rig: two network namespaces on one Linux host, bottleneck + deep queue downstream, base delay both ways. The primary rig for [T8b](../test-8b-congestion-control.md). |
| [`t8b-shaper.sh`](t8b-shaper.sh) | Shaped bottleneck on a real interface, applied to the media flows only via a `prio`+`u32` lane so SSH on a shared host is untouched. The corroborating real-path rig. |
| [`t8b-rtt-probe.sh`](t8b-rtt-probe.sh) | Standing-RTT sampler and percentile summary. For a fixed-rate feed, RTT is a buffer-headroom check (does queuing threaten `--latency-max`?), sampled over the same window as the capture. |
| [`t9-overhead-wan.sh`](t9-overhead-wan.sh) | Carriage overhead over a real path: origin relay and publisher remote, subscriber local, capture on the origin's egress. Legs for the deployed default, path MTU discovery, a GSO control, a video-only source, and SRT carrying the same clip over the same path. The rig for [T9](../test-9-performance.md)'s carriage figures. |
| [`t9-overhead-wan-cap.sh`](t9-overhead-wan-cap.sh) | The capture half, run on the origin: UDP datagram-size distribution and byte totals for both directions, as rates over the pcap's own span. |
| [`t9-overhead-lo.sh`](t9-overhead-lo.sh) | The same accounting with relay, publisher and subscriber on one host. Useful as a control; costs about a point of accuracy against a real path. |
| [`t9-netem-lane.sh`](t9-netem-lane.sh) | Impairment for the overhead legs, shaping only the two measured flows. Resolves the destination from the origin's view of the connection at setup time, and reports the shaper's own passed/dropped counters. |
| [`t12-dual-leg.sh`](t12-dual-leg.sh) | One source, two complete delivery legs (publisher → relay → subscriber → RTP/UDP egress), one capture of both. Four egress arms and a timed injection per run. The rig for [T12](../test-12-dual-path-handoff.md). |
| [`t12-merge-oracle.py`](t12-merge-oracle.py) | The receiver. Reconstructs from one capture what an ST 2022-7 sequence merge and an IRD-style input-select would have produced, and reports alignment yield, loss at the merged output, switch behaviour and leg skew. |
| [`t12-grade.sh`](t12-grade.sh) | Grades one captured run — oracle plus a TSDuck verdict on each reconstruction — into two CSVs. Reads only the capture, so a campaign can be re-graded when the oracle changes. |
| [`t12-matrix.sh`](t12-matrix.sh) | Runs the arm × injection matrix and grades every cell. |
| [`t12-analyse.sh`](t12-analyse.sh) | TSDuck verdict on a single reconstructed output: continuity, PCR interval distribution, `pcrverify`, bitrate. |
| [`t12-conflict-anatomy.py`](t12-conflict-anatomy.py) | When two legs disagree at the same RTP sequence number, says *how*: same packets with different PCR stamps, same packets with different stuffing, or different content. The distinction decides whether a receiver could recover the pair. |
| [`t12-maskcmp.py`](t12-maskcmp.py) | Compares the legs datagram by datagram at equal sequence numbers, raw and with the continuity counter masked, then attributes whatever survives the mask to a PID. Separates *the groomer placed different bytes* from *an upstream stage renumbered the same bytes*. |
| [`t12-seqskew.py`](t12-seqskew.py) | Differential arrival at equal sequence numbers, with no correlation step. |
| [`t12-resume.py`](t12-resume.py) | For a leg that stopped and came back: how far its numbering drifted from its partner's across the outage, measured without needing payload identity. |
| [`t12-placement.py`](t12-placement.py) | Strips stuffing and asks where one leg's programme sits in its partner's output. |
| [`t12-join-diagnostic.sh`](t12-join-diagnostic.sh) | A single stream-clocked leg joining a broadcast already in progress, run to read the groomer's own counters (`start_backlog`, `resyncs`, `dropped`) rather than to grade a pair. |
| [`ts-corrupt-header.py`](ts-corrupt-header.py) | Flips exactly one bit in one MP2, AC-3 or H.264 frame header of a real transport stream, located by walking the PID's PES payload rather than by offset. The damage artefact for demuxer-robustness arms. |
| [`moq-import-survival.sh`](moq-import-survival.sh) | Relay, subscriber and importer in one invocation; reports whether `moq import ts` survived a source, with its exit status. Run once per binary for a before/after on a demuxer fix. It keeps the subscriber's egress capture, which is what turns a survival arm into a fidelity arm. |
| [`ts-audio-frames.py`](ts-audio-frames.py) | Walks one PID's audio elementary stream frame by frame: per-frame offset, length and hash, resync gaps, whether MP2 frames carry a CRC, and whether the stream ends mid-frame. The trailing-partial figure is what decides whether looping a clip splices an audio frame at the wrap. |
| [`ts-splice-audit.py`](ts-splice-audit.py) | Does a capture contain an audio frame the source never had? Hashes every frame in the egress against the source's frame set, so a frame assembled across a splice is detected by construction rather than by listening. Also reports PES/frame alignment, leading continuation packets, and for AC-3 whether the mandatory `crc1` rejects each suspect frame. |
| [`make-eit-fixture.sh`](make-eit-fixture.sh) + [`eit-epg.xml`](eit-epg.xml) | Injects a synthetic EPG onto PID 0x0012 of a clip that has none, so the lane's EIT handling can be measured rather than inferred. `pf` gives p/f only; `full` adds schedule, which is the shape that prices catalog carriage. EIT packets come from the clip's existing stuffing, so the mux rate is unchanged. |
| [`eit-roundtrip.sh`](eit-roundtrip.sh) | Publishes an EIT-bearing fixture through a local relay and censuses which SI PIDs survive at the exporter. The measurement behind [T2](../test-2-media-aware-transparency.md)'s EIT row. |
| [`export-determinism.sh`](export-determinism.sh) | Two `moq export ts` subscribers of one broadcast, the second joining late. The 1+1 topology with the groomer removed, so what it measures is the exporter alone. |
| [`ts-table-anchor.py`](ts-table-anchor.py) | Where each leg puts its tables, in media time. Tags every table emission with the PTS of the frame that triggered it, so it answers whether the SI cadence is a property of the broadcast without needing the legs to be byte-identical. |
| [`ts-legcmp.py`](ts-legcmp.py) | Packet-by-packet comparison of two renderings of one broadcast, aligned with the continuity counter masked, attributing every residual difference to a PID. |
| [`t12-armd-join-local.sh`](t12-armd-join-local.sh) | T12 arm D's mid-stream-join cell with one publisher and one relay, so the only asymmetry is when each exporter tuned in. Records the RTP legs from the sockets, needing no capture privileges, and reports how many groups each leg abandoned. `TWO_PUB=1` restores the campaign's two-importer topology to price the publisher's contribution; `FILTER`/`FILTER_B` insert a filter below the exporter on both legs or on one; `PUB_CHAIN` replaces the publisher's `tsp` plugin chain, which is how an SI-bearing or clock-bearing source is put through the pair; `RELAY_ARGS` reaches the relay's cache settings. Detects the `--client-*` / `--connect-*` flag surface, and refuses to run against a relay it did not start. |
| [`ts-keyframe-pad.py`](ts-keyframe-pad.py) | The continuity-counter fix proposed on #2779, as a filter: restart every PID's counter at the video keyframe boundary and pad each span to a multiple of 16 so the restart stays continuous. Prices the scheme, and tests it against the groomer below it, without waiting for it to be built. |
| [`ts-stall.py`](ts-stall.py) | Stops one leg consuming for a while. The forcing function for "does either leg ever skip a group": on loopback nothing is ever late, so a zero has to be shown to be falsifiable before it means anything. |
| [`ts-eit-pending-version.py`](ts-eit-pending-version.py) | Marks the first occurrences of a new EIT version as `current_next_indicator = 0`, recomputing the CRC so the stream stays legal. Makes a real capture exercise the pending-version case, which a broadcast EPG generator does not produce. |
| [`si-catalog-cost.rs`](si-catalog-cost.rs) + [`si-catalog-cost.py`](si-catalog-cost.py) | What carried SI costs the hang catalog. The `.rs` drops into `rs/moq-mux/examples/` and records every catalog publish on all three tracks; the `.py` attributes them, separating the standing size a joiner pays from the republish burst at a table turnover. |
| [`make-mpts-fixture.sh`](make-mpts-fixture.sh) + [`make-mpts-si.py`](make-mpts-si.py), [`make-mpts-epg.py`](make-mpts-epg.py) | A distribution multiplex's SI grafted onto a single-programme clip: SDT and NIT for N services, and an EPG that rolls present/following on a fixed boundary. Every capture we hold has one service, so scaling questions cannot be answered without it. |
| [`t13-groom-matrix.sh`](t13-groom-matrix.sh) | Puts one `export ts` capture through every candidate CBR/PCR grooming chain — TSDuck `regulate`, `pcradjust` at the content rate and at a padded nominal rate, FFmpeg `-muxrate` and GStreamer `mpegtsmux bitrate=` with their PIDs pinned back, GStreamer again with SCTE-35 forwarded as section events, and the pacer as a control — leaving the outputs side by side. The rig for [T13](../test-13-downstream-grooming.md). |
| [`t13-grade.py`](t13-grade.py) | Grades a directory of groomed streams as an IRD would: PCR accuracy at both the 481 ns and 500 µs gates, PCR repetition, continuity, the buffer model, duration fidelity, and what happened to every PID relative to the ungroomed input. `rate` mode reports the content rate a null-free stream carries, which is the input each chain needs; `gstbranches` derives the per-stream GStreamer pipeline for a given mux, and reports which PIDs `tsdemux` will not hand to a muxer. |
| [`t13-cadence.sh`](t13-cadence.sh) | Runs each grooming stage live behind a local relay and measures what it puts on the socket, one leg at a time so contention is not recorded as jitter. Distinguishes a stage that emits a constant-rate stream from one that paces a wire. Measures the egress content rate from an ungroomed capture first, because a pass-through chain told to pace at the nominal rate spends the window draining its join backlog and reads as smoother than a correct run. |
| [`t13-cadence.py`](t13-cadence.py) | Timestamps every datagram off a loopback port, keeping both the arrival series and the stream as received, then reports the gap distribution and the delivered rate in 10 ms and 1 s windows. |
| [`t12-rtpcmp.py`](t12-rtpcmp.py) | Grades those recordings on the same metric as `t12-maskcmp.py`, and attributes the residue: which PID each surviving difference sits on, and whether the legs spent the same number of packets on each PID. |
| [`tdt-staleness.py`](tdt-staleness.py) | For every TDT/TOT section on PID 0x0014, reports the gap between the UTC the section asserts and the wall clock when it arrived. Fed a source re-stamped by `tsp -P timeref --start system`, that gap is the path's contribution. Compare legs by *spread*, not median: a growing spread is a clock derived from the media timeline, and a constant offset is usually a publisher that anchored before its peer connected. |
| [`tdt-transports.sh`](tdt-transports.sh) | Puts the same clock through plain UDP, SRT and RIST Main, using T15's roles and orderings. The UDP leg is the control that makes instrument drift separable from a transport property, which is the only reason the result is readable. |
| [`tdt-moq.sh`](tdt-moq.sh) | The same question of the media-aware lane, which stores a section and re-emits it on its own timer rather than forwarding it. Three arms place the source's TDT cadence above, below and either side of the exporter's 30 s re-emission interval, because that relationship — not the transport — is what sets how late the delivered clock is and whether a section gets sent twice. Injects a TOT compiled from XML as well, since `local_time_offset` descriptors are the part of the clock an exporter cannot invent and so the part worth checking byte-for-byte. |
| [`t3-opaque-lane.sh`](t3-opaque-lane.sh) | The opaque `m2ts` lane end to end, so [T3](../test-3-opaque-transparency.md)'s opaque arm is reproducible from the source tree rather than from a shell history — which is why its P2 PCR-accuracy cell could not simply be re-graded when the private checkout went. **It does not yet produce a capture:** the MoQ half connects and the subscriber reports `bytes_out` climbing, and zero bytes reach the reader, on four output configurations. Committed in that state deliberately, with the four attempts and the next step recorded in its header, because the blocked cell is documented against it. |
| [`t3-segmented-transparency.sh`](t3-segmented-transparency.sh) | Publishes a clip as TS-in-HLS, serves it, receives it back **ungroomed**, and cuts an equal-packet source reference offset to the media the receiver joined. Bounds the capture by packet count rather than wall clock, because `tsp -I hls --live` drains the live window faster than real time and a wall-clock window carries an unknown quantity of media. The segmented arm of [T3](../test-3-opaque-transparency.md). |
| [`t4-three-lane.sh`](t4-three-lane.sh) | Carries one clip from the EC2 origin to this workstation over **one of three data planes** — MoQ media-aware, byte-faithful SRT, or segmented HTTP — with everything else held identical: same clip, same origin pacing, same packet bound, same ungroomed measurement point, same instrument. A side-by-side assembled from separately-designed measurements is not a comparison, so the lanes are driven from one script and differ only in the transport. Starts its own origin-side sender so the sender's file position at the join is known and the local reference can be cut to match, and tears that sender down **by process group**: the standing relay and publishers on that box are `tsp`/`moq`/`ffmpeg` processes too, so a `pkill` by name would take the deployment down. The three-lane arm of [T4](../test-4-remote-e2e-srt.md). |
| [`t3-transparency.py`](t3-transparency.py) | Scores one egress capture against a source reference on T3's transparency inventory: service identity, the component census at original PIDs, PSI/SI survival with repetition against the P1 limits and version churn, mux structure, integrity, and both PCR gates. Adds a **packet-conservation** section, because a census is shaped as a loss detector and cannot see what a lane inserted; and reports the reference's stuffing by quarter, so a non-homogeneous window is declared rather than mistaken for a lane stripping padding. |
| [`t18-latency.py`](t18-latency.py) | The delivery-latency instrument. `tap` timestamps every PES presentation timestamp on one PID and passes the stream through unchanged, so the same tool sits inline at a source and reads a groomer's datagrams; it also saves the stream it timed, so a conformance gate can be applied to the same bytes whose latency was measured. `report` joins the two logs, **recovering the lane's timestamp shift per run rather than assuming it** — 0 for a byte-transparent tunnel, +1 tick for the media-aware lane — and fails loudly when the logs are not the same programme. `clock-server`/`clock-client` price a two-host measurement with NTP's four timestamps, reporting the offset from the lowest-delay sample with its own uncertainty. |
| [`t18-arm.sh`](t18-arm.sh) | One arm at one groomer cushion: source tap, the transport under test, reassembly, the groomer, and the same tap on the groomed RTP egress, then latency and PCR conformance from that one capture. Arms are plain UDP (the control), SRT, RIST Main, the media-aware MoQ lane, and segmented HTTP. Each arm gets its own port block, the receiver listens and the source calls on both tunnels — the reverse cannot work, since the receive stage starts last and a listening source is never called inside SRT's connect timeout — and teardown kills by **process group**, without which a subshell's `tsp` and taps outlive the run. The rig for [T18](../test-18-delivery-latency.md). |
| [`t18-sweep.sh`](t18-sweep.sh) | The ladder: every arm at every cushion, strictly one cell at a time, accumulating both halves of each result into one `summary.csv`. The segmented arm gets a deeper ladder because it cannot be run at the shallow end at all — a groomer given 250 ms of cushion mutes rather than paces a plane whose silences reach 4.01 s. |
| [`t18-wan.sh`](t18-wan.sh) + [`t18-wan-source.sh`](t18-wan-source.sh) | The same measurement over the open internet: source on the origin, receiver here. The topology inverts and that is forced rather than chosen — this receiver is behind NAT, so on every arm the origin listens and the receiver calls, which is exactly the arrangement the loopback rig cannot use. The clock is a **fixture**, brought up once by `clock-up` and only probed by a cell, because an SSH invocation does not return until the remote process it started exits; each cell brackets the offset before and after and reports the drift, so a cell that straddled a clock step is caught rather than quoted. The origin half tears down **by process group**, never by name: the standing relay and publishers on that box are `moq` and `tsp` processes too. |
| [`t5-impair-arm.sh`](t5-impair-arm.sh) | One impairment cell of [T5](../test-5-network-impairment.md), whole lane on the origin host so the shaping is controlled rather than inferred. Two things in it are load-bearing rather than incidental. `netem` is filtered into a `prio` band matching **one flow** — the origin's TCP source port, or a private relay's UDP port that is never the standing `:443` — because that box runs services which dial `localhost`, and a bare `netem` on `lo` would shape them silently along with the measurement. And `lo`'s MTU is pinned to 1500 for the run: loopback defaults to 65536, where `loss 1%` discards 1 % of ~37 kB super-packets instead of wire-sized ones, so the ladder measures nothing comparable to a path. The shaper's passed/dropped counters are read back onto every result line, since a filter that matches nothing shapes nothing and the cell then reads as "impairment made no difference" rather than as a rig failure. |
| [`t5-impair-sweep.sh`](t5-impair-sweep.sh) | The ladder against **both** data planes on one host, one shaper, one clip and one window. Running both is the point: T5's original two arms cannot be read side by side, because the media-aware numbers came off the real internet path on an older build and the opaque numbers off a ~0 RTT loopback with both QUIC hops shaped at once. Jitter is `slot`, not `delay X Y`, which reorders at these swings. |
| [`upstream-state.sh`](upstream-state.sh) | Reads every issue and PR number mentioned in the given files and reports its live state, distinguishing merged from closed and printing a merged PR's base branch. What to run first after time away, so a written claim about upstream is checked rather than trusted. |

**A fidelity rig needs an addition column, not only a survival census.** The natural shape of a
transparency check is to list what the source carried and look for it at egress, and nothing in that
shape can see packets the source never had. On the segmented-HTTP lane those packets — one PAT/PMT
pair per segment, 46 in a 60 s window — are the entire deviation, and they move file-domain PCR
accuracy from 37 ns to 302 µs while every survival row reads clean. `t3-transparency.py` counts them
by detecting back-to-back PAT→PMT pairs, which a source mux does not produce, and reports excess over
equal media so the figure does not depend on segment duration.

**Always attribute the residue.** A pair that is "97 % identical bar the continuity counter" has a
3 % that is *something*, and the percentage cannot say what. Both comparison tools now break it down
by PID and census the two legs, which is the difference between "what remains is a counter" and
"every SDT emission lands where the other leg has video". Where the legs spend a different number of
packets on a PID, one of them carried media the other placed elsewhere, and no field-masking will
reconcile them.

**Pair datagrams by RTP timestamp, not sequence number.** Under stream clocking both are functions of
the output slot, but the sequence number is 16 bits and wraps after 65 536 datagrams — under a minute
at 15 Mb/s. Past the wrap a late-joining leg is a whole epoch out from its partner and a comparison
keyed on the sequence number pairs unrelated slots, quietly. `t12-rtpcmp.py` keys on the 32-bit
timestamp and says so when a run wrapped; `t12-maskcmp.py` keys on the sequence number and is safe
only below that rate-times-duration product.

**Count distinct SI sections, not transmitted ones.** `moq-mux` dedupes SI by section identity and
only takes the catalog write lock when the bytes change, so a table's transmitted rate says nothing
about what carrying it would cost. On the EIT fixture the two differ by two orders of magnitude
(1,012 sections, 12 distinct). `tsp -P tables --pid <pid> --all-sections --log-hexa-line | sort -u`
is the whole method, and it is what separates EIT — which repeats byte-identically — from TDT/TOT,
where every section is new.

**Which comparison to trust.** `t12-merge-oracle.py` recovers the legs' sequence offset by voting on
payload identity and derives skew by pairing datagrams through that offset, so on a pair that differs
in *any* field it votes on a handful of datagrams and returns a spurious offset and a spurious skew —
it prints its vote share as a confidence, and a low one invalidates both. Where the legs are not
byte-identical, use `t12-maskcmp.py` and `t12-seqskew.py`, which compare at equal sequence numbers
and never correlate.

Both shaper rigs offer the same three queue disciplines at one bottleneck rate — `bloat`
(deep FIFO), `codel` (`fq_codel`), and `cake` — so the AQM counterfactual is a single-word
change with everything else held constant.

**Before trusting any measurement, calibrate:** confirm idle RTT sits at the configured base and
that a saturating flow (a loss-based CUBIC run doubles as one) drives it to base + queue depth. A
`tc` chain that looks correct can still queue in the wrong place. The procedure is in
[T8b](../test-8b-congestion-control.md) §0.

**On a shared host,** `t8b-shaper.sh` arms a watchdog (default 90 min) that tears the lane down on
its own, and `clear` removes it immediately. A shaped lane left behind is a trap for the next
person to use the box. `t12-dual-leg.sh` and `t9-netem-lane.sh` arm the same kind of watchdog.

**Three rules the overhead rigs exist to enforce**, each learned by getting it wrong:

- **Run off loopback and with `--server-quic-gso=false`.** On loopback the kernel coalesces sends into
  multi-kB segments, so a capture shows neither real datagrams nor a countable number of IP headers.
- **Never compare byte totals from two separately started windows.** Each side must reduce to a rate
  over a span it measures itself — the capture over the pcap's own first-to-last packet time, the
  payload over its own timer. A ~15 % window mismatch is indistinguishable from a ~15 % protocol
  overhead, and was mistaken for one.
- **Verify that an impairment reached the flow, and know where the capture tap sits relative to the
  shaper.** `t9-netem-lane.sh verify` prints passed/dropped counts for exactly that reason: a lane
  pinned to a stale address shapes nothing and the run then reads as "loss made no difference". On
  Linux the egress tap is *downstream* of the qdisc, so a capture on the sending host cannot see
  retransmitted bytes that the shaper then dropped; recover the sender's push rate from the counters.

**A demuxer-robustness arm proves nothing without its opposite arm.** `ts-corrupt-header.py` finds its
target by matching a sync pattern, and those patterns occur by chance inside compressed payload — so an
arm that survives may mean the parser recovered, or may mean the damaged byte was never a frame header.
Always run the same file against a build known to fail, and treat "survived on both" as inconclusive
rather than as a pass. The same applies to a looping source: a wrap is only fatal when it splits a
frame, which depends on where the clip was cut.

**Survival is the weakest question you can ask of a demuxer.** Once a parser stops aborting, "it
survived" stops discriminating: a build that recovers cleanly and a build that publishes a frame of
spliced garbage both survive, and both look healthy at the TS layer — 0 continuity errors, no
discontinuity flag, an unbroken PTS sequence, because the corrupt frame sits in the real frame's slot.
Grade fidelity instead, with `ts-splice-audit.py`: a frame whose bytes appear nowhere in the source
cannot be a frame the source produced, which is decidable and needs no listening test. This is exactly
how a fix that passes its own unit tests was shown not to reach real content — and, once upstream
rescoped it, how the replacement was confirmed to reach it (alien frames 3 → 0) and then shown to be
blind on a wrap that happens not to break the continuity counter. Both directions came from the same
one-line question.

**Define "the source" as the bytes the publisher actually sends, not the bytes you can parse.** The
audit's first version built its known-frame set from the first PUSI onward, because that is where PES
reassembly can begin. A clip cut out of a longer stream *opens* with continuation packets belonging to a
PES whose start was lost, and a demuxer that resyncs inside them emits frames that are perfectly correct
yet match nothing in that set — false aliens, and on one clip they outnumbered the real one 2:1. Any
comparison against a reference has this shape of error: the reference has to be built the way the thing
under test consumes it.

**A looping clip only exercises a continuity-based guard if its wrap actually breaks the counter.** Since
[#2823](https://github.com/moq-dev/moq/pull/2823) the importer drops a PES completed across a continuity
break, so whether a splice is *visible* depends on where the file was cut. Read the first continuity
counter each PID carries in the file, then walk candidate cut points tracking each PID's running counter:
a cut where `(last_cc + 1) % 16` equals that first value wraps **contiguously** and the break is
invisible — roughly one cut point in 16 per PID. To exercise the guard, cut where the counter breaks; to
exercise what it misses, cut where it does not, and require a non-zero trailing partial frame either way
(`ts-audio-frames.py`) or there is no spliced frame to find.

**Check that a fix's precondition exists in your content before reading a null result as a
regression.** A carried tail across a PES boundary only arises if the mux splits frames that way, and a
broadcast mux commonly does not — `ts-splice-audit.py` reports interior PES/frame alignment for that
reason. Where every audio PES holds a whole number of frames, the only mid-frame cut is the file end,
and a wrap then splices *inside* one PES rather than between two. Same symptom, different code path.

**The T12 rig grades itself before it grades MoQ.** Every run reports whether either leg was empty,
what the pacer dropped, and whether a relay failed to bind; a leaked relay from a previous run is
the failure mode to watch for, because the next run's publisher lands on it, the subscriber joins a
stale announce, and the leg goes quiet for reasons that have nothing to do with the condition under
test. Run the arm C control first: it must be hitless, or no other arm's number means anything.
