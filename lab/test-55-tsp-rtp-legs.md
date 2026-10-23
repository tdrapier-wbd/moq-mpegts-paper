# Test 55 — ST 2022-7 legs from passthrough exports through TSDuck's RTP output

**State: run on the laptop, through a relay on EC2, and on an EC2 host; graded. H1 holds once `tsp`'s
initial load is bounded; H3 holds; H2 does not, because a killed leg also costs packets at the merge.
Two co-started legs make a pair, but no leg event the export's delay does not absorb leaves one: the
route protects the RTP paths, not the MoQ legs.**

## Objective

Upstream is removing `export ts --sync` and its RTP egress work, naming passthrough as the mode for
2022-7 output; RTP framing is left to an external tool. This test takes two `export ts
--passthrough` legs, each piped into `tsp -O ip --rtp`, and asks whether they give a pair a 2022-7
receiver can merge, and through which failures.

`tsp` numbers each datagram from its own count, starting at `--start-sequence-number`, and stamps it
from the stream's PCR. Two legs therefore carry the same datagrams under the same numbers only if
they cut the same packets from the same first packet and neither skips nor restarts.
[T12](test-12-dual-path-handoff.md)'s stream-clocked groomer instead derives each number from the
datagram's slot on the source's timeline, and on the opaque lane it kept a pair mergeable through a
late join, a blackout of each leg and a killed export. That is the comparison.

## Hypotheses, fixed before running

- **H1.** Two co-started legs, both with `--enforce-burst` and the same start number and SSRC, send
  identical datagrams under equal numbers, so a 2022-7 receiver merges them. This protects against
  loss on the RTP paths, and against any MoQ-leg impairment the transport recovers without loss.
- **H2.** A leg that joins late, or is restarted, carries the same programme under other numbers,
  and usually cut at other packet boundaries. A 2022-7 receiver then ignores it or mixes it in, so
  the pair cannot regain protection without restarting both legs.
- **H3.** A leg whose export stalls or loses its path keeps its numbers only if its export resumes
  without skipping a packet.

## Environment

| Component | Build |
|---|---|
| `moq`, `moq-relay` | `main` (Deviations 3) |
| `tsp` | TSDuck 3.45 (laptop), 3.44 (EC2 host) |
| Source | a 10-minute single-programme contribution clip, about 9.9 Mb/s, published by `import ts --passthrough` |
| Receiver | [`t55-grade.py`](scripts/t55-grade.py): a sequence-number merge modelled on 2022-7, with a 450 ms window (Class C) |

Local: the laptop, loopback. Over EC2: the importer and both legs on the laptop, the relay on an EC2
host; the blackout cell on the EC2 host, on loopback, since it drops a leg's QUIC flow with
`iptables`.

## Procedure

The rig is [`t55-tsp-rtp-legs.sh`](scripts/t55-tsp-rtp-legs.sh). Each leg is
`moq export ts --passthrough --delay 2s | tsp --realtime -O ip --rtp --enforce-burst --packet-burst 7
--start-sequence-number 1000 --ssrc-identifier <x>`, to ports 5100 and 5200, recorded from the
sockets. Cells:

| Cell | What happens to leg A |
|---|---|
| `costart` | nothing: both legs started before the importer, so both begin at its first packet |
| `late` | leg B starts 8 s after leg A |
| `kill` | its export killed at 40 s; the leg restarted 10 s later with the same configuration |
| `stall` | its export stopped (SIGSTOP) at 40 s for 1 s, then for 10 s |
| `blackout` | its QUIC path dropped at 40 s for 1 s, then for 10 s (EC2, loopback) |

## Pass criteria, fixed before running

1. **Void** unless both legs are recorded over the whole run in `costart`, every datagram carries
   seven packets, and the reference was captured.
2. **H1 holds** if in `costart` every datagram of leg B matches leg A's under the same number, and
   the receiver's output has no lost datagram, no conflict, no continuity error and no packet out of
   the reference's order.
3. **A cell is hitless** if the receiver's output has no conflict and no packet out of the
   reference's order, and loses nothing the surviving leg carried. **It restores protection** if,
   once leg A is back, its datagrams match leg B's under equal numbers.
4. **H2 holds** if `late` and `kill` are hitless through the event but do not restore protection.
   **H3 holds** if each `stall` and `blackout` arm restores protection exactly when leg A's export
   skipped no packet.

### Deviations

1. **`--initial-input-packets 7` on each leg after the first run.** By default `tsp` reads half its
   16 MB buffer before processing, and sent each leg's first 7.7 s as one burst: 7,301 datagrams in
   the first second against 944 a second after. Every later cell ran with the option.
2. **The receiver re-locks.** The first model froze at the first hole it could not skip; it now
   re-locks when it has played nothing for one window, as a receiver resynchronises. The first run
   was re-graded with it.
3. **Builds.** Laptop: `main` `f13283b30`, TSDuck 3.45. Over EC2: the same clients against a relay
   on `main` `f2fca6fd2` in eu-west-1. EC2 host: `f2fca6fd2` and TSDuck 3.44 throughout. Runs are
   90 s.

## Results

Datagrams of leg B matching leg A's under the same number, before and after the event; then what
the receiver made of the pair.

| Cell | Where | Matched before | After | Receiver | Merged output |
|---|---|---|---|---|---|
| `costart`, default load | laptop | 80,273 of 80,277 | — | 5,207 skipped at the start on both legs, one re-lock | 11 continuity errors, all at the skip |
| `costart` | laptop | 80,273, none differing | — | nothing lost, no conflict | clean |
| `costart` | via EC2 | 80,273, none differing; skew −2.6 to +4.7 ms | — | nothing lost, no conflict | clean |
| `late` (B 8.6 s after A) | laptop, via EC2 | — | 0: none of B's 75,497 datagrams equals any of A's | A alone; B's numbers behind, ignored | clean, unprotected |
| `kill`, restart 10 s later | laptop | 33,055 | 0 of 37,766 | **1 conflict** at the kill; the restart's numbers ignored | **1 continuity error** |
| `kill` | via EC2 | 33,032 | 0 of 37,781 | **1 conflict**; likewise | **1 continuity error** |
| `stall` 1 s | laptop, via EC2 | 33,078 · 33,055 | all, none differing | nothing lost, no conflict | clean, protected |
| `stall` 10 s | laptop | 33,055 | 0: A's export ended | B alone | clean, unprotected |
| `blackout` 1 s | EC2 host | 33,078 | **923, then none: 44,887 differ** | B's copy first each time; 44,887 conflicts | clean, unprotected |
| `blackout` 10 s | EC2 host | 33,055 | 0: A's export ended | B alone | clean, unprotected |

**At a kill, `tsp` flushes a short datagram.** On end of input it sends what it holds, despite
`--enforce-burst`: four packets on the laptop, one via EC2, under a number leg B fills with seven.
It arrived first, by 3.25 ms and 7.39 ms, so a first-copy receiver played it and lost the rest of
that datagram. **A restarted leg counts from its start number again**, so it never rejoins.

**A blackout of 1 s made the export skip.** It logged `current group evicted; skipping to next
buffered group`, then `media skipped upstream; resuming at the next group … skipped=520.037ms`.
`tsp` numbers by its own count, so from then on leg A carried the programme 468 numbers behind
leg B, matching on content (44,886 datagrams found at that offset) and differing at every shared
number. A 1 s stop of the process skipped nothing: the 2 s delay covered it. After 10 s of either,
the export's session had ended and the export exited.

## Grading

1. **Not void.** Both legs ran the whole `costart` run, every datagram carried seven packets once
   the initial load was bounded, and the reference was captured.
2. **H1 holds** with the initial load bounded, on the laptop and through a relay on EC2. With the
   default load it does not: the start burst overruns any receiver window on both legs alike.
3. **Hitless:** `costart`, `late`, both `stall` arms and the 10 s `blackout`. **Not hitless:**
   `kill`, by one datagram, and the 1 s `blackout` by its conflicts, though none reached the output.
   **Protection restored:** only after the 1 s `stall`.
4. **H2 does not hold.** `late` is hitless and never protected, as predicted; `kill` loses packets at
   the merge as well. **H3 holds:** the one arm whose export skipped nothing is the one that
   restored protection.

## Conclusions

- **`tsp -O ip --rtp` turns two co-started passthrough legs into a 2022-7 pair**, given
  `--enforce-burst`, one start number and SSRC, and a bounded initial load. That protects the RTP
  paths beyond `tsp`.
- **It does not protect the MoQ legs.** A late join, a restart, a skip, or a stall past the
  export's delay leaves a pair that no longer merges, until both legs restart together; a kill also
  costs a datagram. A skipped leg is the worst case: it keeps sending the right programme under the
  wrong numbers, which a receiver cannot tell from a healthy leg until the other fails.
- **The stream-clocked groomer is what makes the route survive leg failure.** On the opaque lane it
  kept a pair merging through a late join, each leg's loss and a killed export
  ([T12](test-12-dual-path-handoff.md)), because it numbers each datagram by its slot on the
  source's timeline, not by a count. For P0-k and P1-b the legs are passthrough exports, each through
  a stream-clocked groomer; `tsp` serves where a pair can be restarted together.

## Limits

- One clip, one source rate, 90 s runs, one run per cell. The receiver is a model, not a hardware
  merge, and its window is Class C.
- The blackout ran on loopback on one host, where QUIC's recovery after a 1 s outage is the
  loopback's, not a WAN path's.
