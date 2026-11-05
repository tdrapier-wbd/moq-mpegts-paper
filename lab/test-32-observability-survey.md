# Test 32 — Observability: what commercial monitoring would have caught

**State: the fault-to-telemetry mapping is measured on both lanes and a documentary pass over public vendor documentation is done; what documentation cannot answer waits on vendor outreach.** The documentary pass finds that the capabilities the campaign had to build are sold, at the level of a datasheet; the open questions are their definitions and thresholds, which decide whether they catch the measured faults (_Outreach_, below). This is desk research and outreach, not a rig run.

Specified as [P2-a](planned-experiments.md#p2--completeness). The measured arms are **not** repeated here.

## Objective

Determine whether an operations team running hundreds of permanent feeds could **localise** the silent media-plane failure classes this campaign found, using **commercial monitoring** they can buy rather than custom tooling this lab built.

The reportable output is the list of induced faults for which **no** commercial telemetry on a lane distinguishes the failing component — extended from the MoQ-specific list T22/T24/T27 established to cover TR 101 290 analysers, IRD alarms, and ABR/OTT observability suites on the segmented lane.

## What each fault produces, as measured

The left-hand column the survey is scored against. Each row is cited from its experiment, not re-measured; the third column is what a product would need to catch it.

| Fault | What moves, and when | A product must | From |
| --- | --- | --- | --- |
| Source stalled, MoQ | nothing in publisher, relay or exporter for 120 s; the groomer's content-liveness alarm 1.69–1.88 s | alarm on PCR progression at the TS egress | [T22](test-22-silent-media-plane-failure.md) |
| Relay frozen, MoQ | QUIC's idle timeout at 34.3 s; clock progression at 1.9 s | the same | [T22](test-22-silent-media-plane-failure.md) |
| Groomer emitting under `--on-stall continue` | valid CBR with no programme, indefinitely | count as presence only packets that are neither null nor adaptation-field-only | [T22](test-22-silent-media-plane-failure.md) |
| Video PES dead, its PCR kept, MoQ | the whole of TR 101 290 P1 green; per-PID access-unit liveness names it at its learned threshold, 1.0–3.1 s at a groomed point | alarm on a PID that is present but carries no access units | [T24](test-24-partial-media-plane-stall.md), [T27](test-27-liveness-detector.md) |
| The same, segmented | a segmenter cutting only at random-access pictures closes no segment for 61 s, the audio withheld with it: every source sees only an absence (5.9–6.1 s, timed by the monitor). One that also cuts at a time bound contains it, and liveness names the video in 3.4 s | the above, and a playlist-staleness alarm that cannot name the cause | [T79](test-79-hls-telemetry-faults.md) |
| Audio PES dead | P1 `PID_error` in 7.0–8.2 s; per-PID liveness 0.7–1.4 s (MoQ, groomed) and 2.0–3.6 s (segmented receiver); CMCD's own keys never; the receiver's TR 101 290 counters as CMCD custom keys 8.1–8.2 s | a per-PID absence alarm below the failover budget | [T27](test-27-liveness-detector.md), [T79](test-79-hls-telemetry-faults.md) |
| Segmenter stalled 30 s, segmented | the origin answers 200 to every request; the media sequence freezes 31.5 s against ≤ 3.1 s; explicit records only on resumption (`msn-skip` at 30.2 s) | alarm on media-sequence advancement | [T22](test-22-silent-media-plane-failure.md), [T79](test-79-hls-telemetry-faults.md) |
| Origin down 30 s, segmented | the receiver's failed fetch and CMCD v2's `rc=0` within 0.02–0.20 s; 11–12 continuity errors at the hole, which `ffmpeg -c copy` reads as none | grade the bytes received, not a re-multiplexed copy | [T42](test-42-h3-receiver-fidelity.md), [T79](test-79-hls-telemetry-faults.md) |
| Client abuse (churn, slow, flood) | nothing: the victims are byte-identical to the control | nothing (the row stops the survey looking for a signal that should not exist) | [T25](test-25-isolation-under-abuse.md) |
| One leg of a redundant pair lost | a switch on absent packets (500 ms) costs 0.8–2.9 s of decoder hole; one on video-PID silence decides 1.3 s sooner, and holding both legs 2 s to cut at the last keyframe before the failure costs only the background's 0.2 s, for 2 s of latency | switch on video silence, with a hold and a keyframe-aligned cut | [T58](test-58-receiver-select.md), [T80](test-80-video-aware-receiver-switch.md) |
| A subscriber's report through a CDN | CloudFront's real-time logs parse CMCD version 1 only and keep a version 2 payload raw | a log pipeline that keeps v2 and its custom keys | [T79](test-79-hls-telemetry-faults.md) |
| A frozen picture in valid access units | untested; defeats every transport-layer detector | detect freeze in decoded pictures | — |

## Procedure

**Label the method.** This is a **structured comparison**, not a measurement campaign. Every conclusion that rests on vendor claims is labelled _specification_ or _datasheet_; only faults actually induced in the experiments above are labelled _measured_.

**Per lane, build a matrix:**

1. **Native telemetry** — what the lane emits without custom tooling (relay stats, exporter logs, HLS access logs, CDN metrics).
2. **Commercial monitoring fit** — which off-the-shelf products ingest that telemetry or probe the wire; deployment and upgrade surface.
3. **Per induced fault class** — walk the catalogue: which signals move, estimated time-to-alarm from product documentation, whether the alarm **localises** to publisher / relay / exporter / groomer / origin / edge / client.
4. **Gap list** — faults for which _no_ product in the survey exposes a distinguishing signal; note whether per-PID liveness, per-PID bitrate, PCR progression, or transport liveness is the closest offered mechanism and why it fails the T24 counterexample.

**Product classes:** TR 101 290 probes and multiviewers, IRD and multiplexer alarms and input redundancy, OTT/ABR monitors, CDN log pipelines and CMCD collectors, and MoQ-native tools. Public documentation first; hands-on confirmation only where access exists, recorded separately.

## Metrics

Per fault class × product (or product class):

- **Telemetry that moved** — yes/no; which metric (named).
- **Time to first alarm** — from documentation or measured trial; state domain.
- **Localisation** — component identified correctly, partially, or not at all.
- **False-positive risk** — would a healthy feed alarm on the thresholds the product documents?

The headline metric is **count of fault classes with no distinguishing commercial telemetry**, split by lane and by whether the closest offered detector is liveness, bitrate, or transport-level.

## Pass criteria, fixed before running

Judgement criteria, stated as judgement ([P2-a](planned-experiments.md#p2--completeness)):

1. **Completeness.** Every T22/T24/T27 fault class appears in the matrix with at least one commercial product class evaluated, or is explicitly marked _no product surveyed_ with reason.
2. **Honest labelling.** Measured faults cite [T22](test-22-silent-media-plane-failure.md), [T24](test-24-partial-media-plane-stall.md), or [T27](test-27-liveness-detector.md); vendor capabilities cite public documentation only unless a hands-on trial is recorded separately.
3. **The gap list is the deliverable.** The survey **passes** if the list of faults with no commercial localisation is published with mechanism-level explanation (e.g. "P1 green because partial PID loss is below threshold X").
4. **Liveness versus bitrate.** Any product claiming stream health via bitrate alone is scored against T24's audio arm: if documentation implies detection of a dead stream whose share is below stated mux variance, record _would not have caught T24 audio_ unless the product documents AU-level or equivalent framing-level liveness.
5. **Actionable procurement guidance.** For each gap, state whether the campaign's custom detector ([`ts-liveness.py`](scripts/ts-liveness.py)), upstream importer changes ([T27](test-27-liveness-detector.md) recommendation), or no software substitute exists on that lane.

## Documentary pass

_Specification_ throughout: what each vendor's public documentation states, read in November 2026, with nothing tried.

| Capability the faults need | Documented | What documentation leaves open |
| --- | --- | --- |
| A present PID carrying no media | Appear's decoder alarms separate _Video PID Missing_ (no packet on the PID for a second) from _Video Missing_ (no video data on it) ([alarm list](https://git.justnet.pl/attachments/download/7764/Appear%20-%20XC%20Platform%20-%20Alarm%20Descriptions.pdf)). Telestream Sentry alerts on a PID or programme going inactive, on audio silence and video freeze ([manual](https://primary.telestream.net/pdfs/user-guides/Sentry-Series-Video-Quality-Monitors-User-Manual-V10.6-077320205.pdf)); Bridge Technologies' VB330 on black, freeze and silence ([product](https://bridgetech.tv/products/vb330/)); TAG on no video and no audio ([wiki](https://community.tagvs.com/contentview/Wiki/2446885922)) | whether _inactive_ or _missing_ counts adaptation-field-only packets carrying the PCR as presence, which is T24's dead video; each threshold's floor |
| Per-PID bitrate | Sentry's bandwidth thresholds per PID; templates of expected PID bitrate ranges ([Mividi](https://netchange.nl/wp-content/uploads/2021/08/IMS-Product-Brief_en_letter.pdf)) | scored by criterion 4 |
| PCR progression | standard in every analyser; Elecard Boro raises _PCR Is Not Present_ after 3 s ([parameters](https://boro.elecard.com/docs/en/UserGuide/Introduction/parameters.html)) | none |
| Playlist advancement | Telestream Live ABR Monitor identifies stalled manifests ([datasheet](https://www.telestream.net/pdfs/datasheets/dat-Live-ABR-Monitor.pdf)); the VB330's OTT engine checks chunk counters per profile; AWS's open canary monitor alarms on staleness ([blog](https://aws.amazon.com/blogs/media/monitor-hls-and-dash-live-streams-using-a-canary-monitor/)) | the threshold against a 2 s segment, and per rendition |
| TR 101 290 on segments as received | the VB330's OTT engine downloads every chunk for analysis | whether the analysis reads the received bytes or a re-multiplexed copy (T42's defect), and whether a missing segment is graded as a continuity error |
| Switchover on content | Ateme's DR5000 fails over after a configured period of source inactivity ([manual](https://www.easymanua.ls/ateme/kyrion-dr5000/manual?p=67)), a packet-absence trigger; MediaKind's multiplexer switches on a missing component marked critical ([docs](https://docs.mediakind.com/beam/multiplexer/configure/input/)); Appear's service redundancy on any alarm on the main ([manual](https://www.easymanua.ls/appear-tv/dc100x/manual?p=299)) | whether a _video missing_ alarm can drive the switch, its hold, and where it cuts |
| CMCD v2 and custom keys | CloudFront parses v1 only (measured, T79). Akamai's DataStream 2 logs the whole payload, v1 or v2, as one raw field, for Adaptive Media Delivery ([data sets](https://techdocs.akamai.com/datastream2/docs/data-set-parameters)). Fastly describes v2 without a log configuration ([blog](https://www.fastly.com/blog/cmcdv2-leveling-up-your-video-streaming-telemetry)). Under CTA-5004-B a custom key needs a hyphenated prefix, and SVTA's Common Media Library, which players build on, drops one not enabled per target ([guide](https://cml.svta.org/packages/cmcd/guides/user-guide)) | whether a CDN log or collector keeps custom keys verbatim |
| MoQ-native | no TS probe documents MoQ input. moqtap Insight, a browser collector, reports per-track object and group cadence, gaps and stalls; a server-side collector is planned ([products](https://moqtap.com/products/)). The relay publishes stats tracks, off by default | per-track cadence is per-stream liveness on the media-aware lane and not on the opaque one (reasoned, not measured) |

**What it changes.** Every detector the campaign had to build has a commercial counterpart on paper, so the gap list will not read "nobody sells it". Whether each catches the measured fault turns on a definition or threshold the documentation omits, most sharply whether _missing_ means no packets or no media. One gap holds whatever the answers: a segmenter that cuts only at random-access pictures withholds a dead video stream's cause from every monitor downstream. No product ingests MoQ, so on that lane each is placed where every MoQ row was measured, at the edge gateway's TS egress.

## Outreach

What only a vendor can answer, in the order it would move the gap list. Each is cheapest as a fixture trial: the vendor plays the campaign's synthetic fault clips (never the contribution clip) through its product and reports which alarm fires, and when.

1. **TS probes and multiviewers:** does _PID missing_, _not active_ or _no video_ fire on a PID that still carries adaptation-field-only packets with the PCR, and at what minimum threshold per PID? Answered on T24's dead-video clip.
2. **IRDs and multiplexers with input redundancy:** can a content alarm (_video missing_) drive the switch rather than input inactivity; what hold does it apply, and does it cut at a keyframe? T80 measured 0.45–2.3 s of hole for a cut at the next keyframe and only the background's for the last before the failure.
3. **OTT monitors:** the stale-manifest threshold and whether it is per rendition; whether TR 101 290 runs on the segment bytes as fetched. Answered on T79's segmenter-stall and origin-outage arms.
4. **CDNs and CMCD collectors:** whether v2 is parsed, and whether a custom key such as `tr101290-pid_error` reaches a log field or survives verbatim. A replay like T79's answers it for any CDN with a test property.
5. **MoQ-native monitoring:** whether a collector outside the browser reads per-track cadence, which would put per-stream liveness on the media-aware lane without a TS probe.

## Limits, stated in advance

- **Not a product benchmark.** No scoring of vendors against each other; the question is coverage of _failure classes_, not UI quality or price.
- **Documentation may lag firmware.** Hands-on trials are opportunistic; datasheet conclusions carry _specification_ qualification.
- **Does not re-run the measured experiments.** All fault timings and detection latencies come from their files; contradictions would trigger a new rig experiment, not an update to this survey alone.
- **Security and pen-test scope excluded.** Deliberately matches [T25](test-25-isolation-under-abuse.md): operational failure modes, not adversarial worst case.
