# Test 51 — Same-epoch importers that number groups alike

**State: run. After a hard kill the fix passes, but so does the attribution control, so that arm
credits nothing end to end. A clean exit switches inside the export's delay (arm 2): on both lanes
the fix meets every criterion, where the stack without it rewinds (demultiplexed) or repeats 0.6 s
at the switch (passthrough). The graceful-exit gap, which the change does not address, still ends
two of the fix's five demultiplexed serving runs before any switch.**

## Objective

On moq-lite 07 a relay resumes a subscription on another route of the same epoch from the newest
group it handed out, at the same frame. [T6](test-6-relay-resilience.md) § *Single-relay standby*
measured what that does to two `moq import ts` of one stream sharing an `--epoch`: each numbers its
groups from its own start, the resume lands on other media, and with the standby started earlier two
of three exports ended on a timestamp below the previous group's start
([#4354](https://github.com/moq-dev/moq/issues/4354)). Upstream's `hop-aligned-import` quest asks
that such importers publish identical tracks. Our build numbers every media group by the second of
the epoch's catalog clock it opens in: a group opens at the first start in a second (a video
keyframe, any audio frame, a data unit, a passthrough group start), later starts in that second
join it, a second with no start gets an empty group, and a process publishes nothing from the
second it started in. If the relay's resume then lands on the same media, the standby arm passes
where main fails, and P1-p ([planned experiments](planned-experiments.md)) has the build it waits for.

## Environment

- **Builds:** the fix, `hop-aligned-import` ([#5895](https://github.com/moq-dev/moq/pull/5895)),
  stacked on `ts-passthrough-epoch-cuts` ([#5894](https://github.com/moq-dev/moq/pull/5894)) and, for
  arm 1, on `epoch-anchor` ([#5625](https://github.com/moq-dev/moq/pull/5625)) before it merged; the
  **main control**, upstream `main` at the stack's merge-base; and the **attribution control**, the
  stack without this change. Each arm's results name its commits. Release, built on the host below.
- **Host:** the EC2 tertiary (8 vCPU), everything on loopback. No build runs during a batch; the
  load average is recorded at each batch's start.
- **Rig:** [`t6-relay-kill.sh`](scripts/t6-relay-kill.sh) `MODE=standby`, T6's single-relay standby
  arm: one relay, one live source (a 120 s clip through `tsp regulate --pcr-synchronous` to one UDP
  receiver, whose file each publisher follows from its own start: `FEED=file`), two publishers of one
  broadcast sharing one `--epoch`, two exporters, each publisher's input tapped (`TAP=1`). Every process
  on `moq-lite-07-wip` (`MOQ_CONNECT_VERSION`, `MOQ_LISTEN_VERSION`). 6 s idle timeout, 2 s
  keep-alive, the standby started 2 s after the first publisher, subscribers started after both,
  SIGKILL at 15 s, sampled to 60 s, so a run ends inside one lap of the clip.
- **Lanes:** demultiplexed (`import ts`, `export ts --delay 1s`) and passthrough
  (`IMPORT_ARGS=--passthrough`, `EXPORT_ARGS="--passthrough --delay 1s"`).

```sh
MOQ_CONNECT_VERSION=moq-lite-07-wip MOQ_LISTEN_VERSION=moq-lite-07-wip \
MODE=standby FEED=file TAP=1 HOP=1 LATE_SUBS=1 KILL_WHICH=newest SIG=KILL KILL=15 END=60 \
SRC=<clip> EXPORT_ARGS="--delay 1s" lab/scripts/t6-relay-kill.sh <bin-dir> <out-dir>
```

## Procedure

Per lane and build, six runs: three with `KILL_WHICH=newest`, three with `oldest`. Which publisher
serves is a race between equal routes, so the serving one is read from the publisher logs (the one
that received media subscriptions); a run that signalled the idle publisher is a do-nothing twin.
The passthrough captures are walked against the clip with
[`ts-passthrough-identity.py`](scripts/ts-passthrough-identity.py).

## Pass criteria (fixed before the first run)

A run is void if the relay log shows a session on any version but `moq-lite-07-wip`, or if either
capture holds under 5 MB at the kill.

1. **The fix fails over without a rewind.** In every run on the fix whose signalled publisher was
   serving, both exporters are alive at 60 s with no `Error:` line, and each capture grows again
   after the kill. At least two such runs per lane, at least one of them with the standby started
   earlier (the newest publisher serving and signalled), the case that ended T6's exports.
2. **The passthrough lane continues the source.** On the fix, every passthrough capture has
   0 foreign packets: after the switch it carries only source bytes ahead of where it stood, gaps
   allowed. A resume onto another group repeats or skips back, which `export ts --passthrough` need
   not refuse but the walk finds.
3. **The twins prove the rig ran.** Every run that signalled the idle publisher keeps both exporters
   alive with no error, on every build.
4. **Main fails.** On the main control at least one run per lane whose signalled publisher was
   serving ends an exporter on a timestamp rewind or, on the passthrough lane, leaves foreign packets.
   A lane whose control does not fail in six runs is inconclusive, whatever the fix does. If main
   refuses `--epoch` on a lane, that lane's control is the attribution control, and the report says
   so.

The attribution control is graded by criterion 4 too and decides only whom the result credits: if it
passes, the alignment came from the stack beneath this change.

The unit tests on the branch carry what this rig cannot reach (two importers started at different
offsets, across a wrap, across a flagged jump, after a restart, publish the same group sequences and
frames), and one of them fails without the change.

### Arm 2: a switch inside the export's delay (fixed before its first run)

The hard kill resumes after the export's delay, where a misaligned resume is dropped as late
([Results](#results)). Arm 2 sends `SIG=TERM`: the importer closes its session, and on `moq-lite-07`
the relay resumes on the survivor at the signal ([T6](test-6-relay-resilience.md)). Same rig and
inputs, `KILL_WHICH=newest` only (the case where a misaligned resume lands on older media), six runs
per lane and build; the rig records the signal's time. Validity as above, and a serving run *counts*
only if the survivor's first media fetch follows the signal by less than the export's 1 s delay.

1. **The fix survives the switch.** Every counted run on the fix keeps both exporters alive at 60 s
   with no `Error:` line, each capture growing after the signal; at least two per lane.
2. **The passthrough lane continues the source.** 0 foreign packets in every fix passthrough capture.
3. **Twins** as criterion 3 above.
4. **The attribution control fails.** At least one counted run per lane ends an exporter or, on
   passthrough, leaves foreign packets. A build and lane with fewer than two counted runs after six
   gets six more, once; a lane still short, or whose attribution control does not fail, is
   inconclusive. Main is graded the same way and reported.

A lane meeting 1–4 credits the change with preventing #4354's rewind end to end.

## Results

### Arm 1: a hard kill

All 36 runs valid: every session on `moq-lite-07-wip`, every capture 19 MB at the kill, both inputs
byte-identical over their overlap. Builds: the fix `6eb86ffc8`, main `8bcbc7dfd`, the attribution
control `fbdc096b5`. A run is *serving* when the killed publisher held the media subscriptions; in
brackets, those where it was the newest, T6's failing case.

| Lane | Build | Serving runs (newest) | Exporters ended | Foreign packets |
|---|---|---|---|---|
| demultiplexed | fix | 4 (3) | 0 | — |
| demultiplexed | main | 2 (1) | 0 | — |
| demultiplexed | attribution | 4 (1) | 0 | — |
| passthrough | fix | 3 (1) | 0 | 0 in all 12 captures |
| passthrough | main | 2 (1) | **both, in the newest run**: *frame timestamp … below the previous group's start* | 0 |
| passthrough | attribution | 2 (1) | 0 | 0 |

Every twin kept both exporters alive with no error. Every serving run that continued lost the same
53,336 source packets (8.1 s) at the kill, on every build: the relay resumes only after the 6 s idle
timeout. Criteria 1–3 are met; criterion 4 is met on passthrough and not on the demultiplexed lane,
which is therefore inconclusive. The attribution control passes both lanes.

**The arm cannot see the alignment it was built to test.** The relay's resume requests name the
group. On the fix it asked the survivor for group 121090 (passthrough) or 121091–121092
(demultiplexed), catalog seconds both publishers number alike; on main and the attribution control it
asked for the killed publisher's own count (31, 19), another group on the survivor. The attribution
control survived that misaligned resume, presumably because those frames were past the export's 1 s
delay and dropped as late; why main's passthrough exporters refused theirs is not established (one run
each). After a SIGKILL, detected later than the delay, survival does not separate an aligned resume
from a misaligned one: this arm shows the change keeps failover working and passthrough free of foreign
bytes, not that it prevents #4354's rewind. A switch inside the delay would separate them: a graceful
withdrawal, or an idle timeout shorter than the delay.

### Arm 2: a clean exit

Builds, on `main` after #5625 merged: the fix `477278148`, the attribution control `79772dcb2`, main
`50da59e67`. The fix is #5895's head before its review fixes, none of which this rig reaches (they
change the loss path, a clock break before a video track's first keyframe, and fMP4). All 48 runs
valid: the 36 planned and six more each on the fix's demultiplexed lane and main's passthrough lane,
which had one counted run in their first six. In every counted run the survivor was subscribed
8–13 ms after the signal, from its newest group (`start_group: None`): a clean exit takes the relay's
re-subscription, not a hard kill's same-frame resume. The criteria named a fetch; they are applied to
this first media request.

| Lane | Build | Counted runs | Exporters ended | Passthrough captures at the switch |
|---|---|---|---|---|
| demultiplexed | fix | 3 | 0 | — |
| demultiplexed | attribution | 4 | both, in all 4: *frame timestamp … below the previous group's start* | — |
| demultiplexed | main | 4 | both, in all 4: the rewind (3), `not found` or `unroutable` (1) | — |
| passthrough | fix | 4 | 0 | 0 foreign packets in all 12 |
| passthrough | attribution | 4 | 0 | all 8 repeat: 4,081 packets (0.6 s) in six, about 6,350 with a skip forward in one run's two |
| passthrough | main | 4 | both in 3, one in 1: the rewind | the fourth's other capture repeats the same 4,081 |

The 23 twins kept both exporters alive with no error. In two more of the fix's demultiplexed runs the
signalled publisher was serving, no track moved to the survivor, and both exporters ended on
`moq: not found`. That, and main's `not found` or `unroutable` run, is the graceful-exit gap
([upstream ledger](upstream-contributions.md), *A graceful exit is not failed over*), not the rewind:
at the signal the importer drops its tracks, and a track whose `not found` reaches the relay before
the broadcast's withdrawal ends at the subscriber instead of moving. The walk only searches forward,
so it counts a repeat as foreign packets from the switch on; the repeats were located by matching
each captured packet in the clip.

Criteria 1–4 are met on both lanes: on this base the change prevents #4354's rewind end to end. The
graceful-exit gap still ends a clean exit before any switch in two of the fix's five demultiplexed
serving runs; closing it is upstream's, not this change's.

## Corrections

**The rig did not feed the standby the stream the criteria assume.** T6's standby arm gave the second
publisher a `tsp -P fork` copy on its own UDP port. Tapped, that copy started at the clip's first packet,
about 2 s behind live, and had 107–186 holes per run, all whole datagrams lost while it caught up; the
first publisher's input matched the clip with none. The standby's groups then differed wherever a
datagram was lost, and the relay's same-frame resume landed on other bytes: on the fix, two of six
passthrough captures repeated 653–816 packets where the relay switched publishers at start-up. Every
run of the first batch had that feed, so the batch is void on both lanes and reported nowhere. The
second batch uses `FEED=file`, under which both inputs are byte-identical over their overlap, and a run
is also void if they are not ([`t51-feedcheck.py`](scripts/t51-feedcheck.py)); the criteria are otherwise unchanged. Method rule:
tap the inputs of consumers fed one stream and compare them before grading what they publish
([method notes](method-notes.md), *Verify the stimulus*).
