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
| [`t12-armd-join-local.sh`](t12-armd-join-local.sh) | T12 arm D's mid-stream-join cell with one publisher and one relay, so the only asymmetry is when each exporter tuned in. Records the RTP legs from the sockets, needing no capture privileges, and reports how many groups each leg abandoned. `TWO_PUB=1` restores the campaign's two-importer topology to price the publisher's contribution; `FILTER`/`FILTER_B` insert a filter below the exporter on both legs or on one; `RELAY_ARGS` reaches the relay's cache settings. |
| [`ts-keyframe-pad.py`](ts-keyframe-pad.py) | The continuity-counter fix proposed on #2779, as a filter: restart every PID's counter at the video keyframe boundary and pad each span to a multiple of 16 so the restart stays continuous. Prices the scheme, and tests it against the groomer below it, without waiting for it to be built. |
| [`ts-stall.py`](ts-stall.py) | Stops one leg consuming for a while. The forcing function for "does either leg ever skip a group": on loopback nothing is ever late, so a zero has to be shown to be falsifiable before it means anything. |
| [`t12-rtpcmp.py`](t12-rtpcmp.py) | Grades those recordings on the same metric as `t12-maskcmp.py`, and attributes the residue: which PID each surviving difference sits on, and whether the legs spent the same number of packets on each PID. |
| [`upstream-state.sh`](upstream-state.sh) | Reads every issue and PR number mentioned in the given files and reports its live state, distinguishing merged from closed and printing a merged PR's base branch. What to run first after time away, so a written claim about upstream is checked rather than trusted. |

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
how a fix that passes its own unit tests was shown not to reach real content.

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
