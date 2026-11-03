# Test 76 — Seven days through one origin group, with a withdrawal rule that spares shared damage (P1-aj)

**State: the rule proven offline; the soak running its 168 h, its first minutes clean (no PCR
interval over 40 ms, no continuity error, PTS inside the band, the merge losing nothing).**

## Objective

[T62](test-62-origin-group-soak.md) ran the single-CDN design for 72 h and added no failure of its
own, but its availability was set by the segmenter's withdrawal rule: six continuity breaks in the
contribution, each seen by both segmenters at the same content, withdrew both playlists and cost
54 s, so 1+1 covered none of it. Its groomer also carried a wrong clock for 43 h, which no
criterion graded. P1-aj asks for the gate's 7 days with both fixed: a rule that withdraws only a
pathway whose segments differ from its peer's, the groomer whose re-base moves the PCR with the
content, and PTS graded against PCR on the merged wire.

## The rule

`t61-epochseg.py --peer` ([script](scripts/t61-epochseg.py)). Every segment's SHA-1 is written
beside it as `seg-K.sha1`. A segment cut across a continuity error is held out of the playlist
while the peer's sidecar for K is read over the hosts' private network (origin header, up to 3 s):

| The peer's digest for K | Read as | Action |
|---|---|---|
| the same | damage both pathways carry | published; no withdrawal |
| different | this pathway's own damage | its segment and sidecar deleted, so the CDN's request for K fails over to the peer; the playlist withdrawn until a window of segments is cut again, as T61's rule |
| none by the deadline | the peer down, or not cutting K: nothing to differ from | published, logged as unverified |

A stall over 0.5 s, a lost sync byte and the PTS going back still withdraw at once, on whichever
pathway sees them. Without `--peer` the segmenter is T61's, unchanged.

**Offline proof** ([`t76-withdraw-test.sh`](scripts/t76-withdraw-test.sh)): 40 s of the clip, and
the same with 600 packets removed at 18 s (inside T62's 96–1,139). All 15 checks hold: without
`--peer` the error withdraws; two pathways cutting the damaged stream both publish it, never
withdraw, and cut byte-identical segments; a damaged pathway whose peer cut the clean stream
deletes its segment and withdraws, keeping only segments identical to its peer's, while the clean
one never asks; an unreachable peer leaves the segment published and unverified.

## Environment

T62's rig and graders ([`p1aj-soak.sh`](scripts/p1aj-soak.sh), [`t62-grade.py`](scripts/t62-grade.py)),
with three changes:

- **Segmenters:** `--pdt --peer http://<peer-private-address>:18310/g/ --peer-header
  X-P59-Origin:<secret file> --peer-wait 3` on the primary (A) and the secondary (B).
- **Groomers:** the stream-clocked pacer at `97f3a38`, whose re-base moves the emitted PCR with the
  content ([T65](test-65-ird-hls-profile.md)), `--align-ms 30000`, release 1.5 s after the date.
- **In-flight grading:** [`t21-pcr-monitor.py`](scripts/t21-pcr-monitor.py) `--pts` adds each
  minute's PTS against the last PCR before each PES start, per PID. On the clip it reads 442–1,333
  ms for video and 27–75 ms for audio and teletext.

A new distribution with T61's origin group and viewer gate; leg A at the edge its resolver gives,
leg B pinned to a Düsseldorf PoP. Both origins also carry the live feed's standing units, as in
T62; anything else run on the three hosts during the soak is logged with its start and stop.

## Pass criteria, fixed before running

1. **Void** if the run ends before 168 h for a cause outside the chain; a cause inside it is a
   result.
2. **C1, the merged wire:** in every minute, 0 PCR intervals over 40 ms and 0 continuity errors,
   except minutes attributed to damage in the contribution: a damaged segment both segmenters cut
   at the same K, or a reset both made at the same content. Each exception listed.
3. **C2, programme lost only where the contribution lost it:** 0 datagrams lost on the merged wire
   and 0 mismatched, except in the window of a reset both segmenters made (a stall or a PTS step).
   Damage both carried and damage one carried alone cost nothing. Each leg's own losses reported
   with their causes.
4. **C3, the skew:** within 450 ms throughout; hourly median and drift reported.
5. **C4, resources:** every role's memory grows slower than 1.60 MB/h by a least-squares slope.
6. **C5, events traced:** every segmenter reset, damaged segment and its answer, guard withdrawal,
   origin failover, receiver retry, loss, playlist failure, and groomer stall, mute or late drop has
   a cause in the logs.
7. **C6, the wrap:** across each PTS wrap the numbering stays consecutive on both pathways, and C1
   holds in the five minutes either side.
8. **C7, the clock:** in every minute every PES's PTS lies 0–2,000 ms ahead of the PCR before it
   (`lead_out=0`), except minutes attributed as in C1; each PID's hourly minimum and maximum
   reported.
9. **C8, the rule:** every damaged segment answered within the 3 s wait; each shared one published
   on both pathways with no withdrawal; each unshared one withdrawing one pathway only, the merge
   losing nothing for it.

*Predicted:* at T62's rate about 14 contribution breaks in 168 h, each shared and costing nothing
beyond what the contribution itself lacked; an unflagged timebase step, if one comes, still
withdraws both (its PTS goes back), costing 6–12 s once; the clock in band throughout.

## Limits

- One feed, one distribution, both receivers on one host, at two edges; leg B's pinned edge may be
  withdrawn by CloudFront, which its losses would then show.
- The rule's unshared branch meets the live feed only if one pathway is damaged alone; T62 saw no
  such case, so that branch may remain proven offline only.
- A timebase step still withdraws both pathways: the epoch numbering cannot go back. Riding through
  one would need a discontinuity-aware numbering, which is not built.
- No failure is injected; T61 covers the failure classes.
- C7 reads PTS against the last PCR, not an interpolated one: up to one PCR interval (40 ms) of
  error, against a 2 s band.

## Commands

```bash
bash lab/scripts/t76-withdraw-test.sh                                   # the offline proof
SEG_ARGS='--pdt --peer http://<peer>:18310/g/ --peer-header X-P59-Origin:/home/ubuntu/p59/origin-secret' \
  bash ~/p59/t61-origin.sh start                                        # each origin
sudo PACER=~/pacer-97f3a38/mpegts-pacer RELEASE_MS=1500 bash ~/p59/p1aj-soak.sh start DIR 168 \
  https://<cf-domain>/g/index.m3u8 https://<cf-domain>/h/index.m3u8     # the tertiary
python3 lab/scripts/t62-grade.py DIR                                    # at the end
```
