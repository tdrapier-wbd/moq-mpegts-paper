# Cross-check: `moq-dev` and `moq2ts`

**State: what is outstanding between the two implementations. Two properties are open, both asked of `moq2ts` and gated on its side; four answered differences still stand, each with a next step; MSFTS carriage divides them both ways.**

`moq-dev` and OpenMOQ's `moq2ts` both carry MPEG-TS over MoQ. `moq-dev` does it in Rust, on `moq-lite` and MoQT, with its own catalog beside MSF. `moq2ts` does it in C++, publishing on `moqxr` and receiving on `moq5`, on MoQT under MSF and MSFTS. A defect found or fixed in one is a hypothesis about the other. This file holds only what is outstanding: each such question still unanswered, and each answered difference that still stands, with its evidence and what follows. Whether the two exchange media is interop, which is [T11](test-11-interop.md)'s.

## The loop

1. **Find.** [`cross-audit.sh`](scripts/cross-audit.sh) lists every `moq2ts` issue and pull request updated since a date, and every `moq-dev` `main` commit since a given one that touches its TS path (`moq-mux`'s TS container and catalog, `moq-srt`, `moq-msf`). It marks each `new` unless this file cites it, or `closed` if a settled item is updated again. Our own `moq-dev` posts reach it through the [upstream ledger](upstream-contributions.md). It runs in each session's tail beside the upstream and quest audits, and `STATUS.md` keeps the date and commit it last ran from.
2. **Triage.** An item gets a row only if it names a property the other implementation could share: a clause of MOQT, MSF or MSFTS, a carriage rule, a client's behaviour. Build, packaging and UI items get none.
3. **Answer** with the cheapest evidence that settles the question, at a named commit: _code_ (read), _check_ (a laptop script, `scripts/xc-*.sh`) or _test_ (cells in a `test-*.md`, criteria first). A row stays _open_ until one has run.
4. **Act.** A gap with evidence becomes a draft in `lab/upstream/`, posted only with the author's go-ahead, citing the other implementation's fix where there is one. Where `moq2ts`'s contributors already have an open issue on the point, our evidence goes there as a comment, not as a new issue.
5. **Close** a row when the answer is "not shared", or when the counterpart's fix has merged and been verified. A closed row leaves this file; its answer is kept in the lab notebook, and an item we posted keeps its outcome in the ledger.

## From `moq2ts`, asked of `moq-dev`

| `moq2ts` | Property | `moq-dev` | Evidence | Next |
| --- | --- | --- | --- | --- |
| [#46](https://github.com/openmoq/moq2ts/issues/46) ([#50](https://github.com/openmoq/moq2ts/pull/50)) | MSF -01 §6.1: a restarted publisher's Group IDs keep rising. Otherwise a caching relay serves the old catalog to a joining FETCH | Not promised: a MoQT Group ID is the group's start in the track's timescale, and no `moq` importer continues its timeline across a restart (`doc/bin/cli.md`, `main` `9039c61857`), so the IDs keep rising only if the restarted import's starts do | code | test, gated on a caching MoQT relay on the laptop: whether a restarted TS import's starts fall back |
| [#56](https://github.com/openmoq/moq2ts/pull/56) | An SRT source's link health, libsrt's RTT, loss, retransmits, late drops and buffered media, reported each second, also while no media flows | Not reported: `moq-srt` counts each connection's packet bytes ([#9397](https://github.com/moq-dev/moq/pull/9397)), but neither it nor `moq-cli`'s SRT import exposes RTT, loss or retransmits (`main` `ed3a2697c4`) | code | requested as [moq-dev#9776](https://github.com/moq-dev/moq/issues/9776) |
| [#72](https://github.com/openmoq/moq2ts/pull/72) (open) | One publisher sends several relays identical Objects at identical Locations, each path queued apart, so a receiver subscribed through two survives losing one | Shared with a hole: one `moq` import reaches two relays as a cluster node (`--cluster-connect`), but an export clustered to both is routed through one. When that relay dies, delivery stops at once; the export notices at its QUIC idle timeout (10 s by default), then ends, or with `--follow` resumes through the other relay at its newest group, losing what was published in between | check ([`xc-two-relays.sh`](scripts/xc-two-relays.sh), `main` `ed3a2697c4`) | reported as [moq-dev#9786](https://github.com/moq-dev/moq/issues/9786); the hole against a shorter `--quic-idle-timeout` |

## From `moq-dev`, asked of `moq2ts`

| `moq-dev` | Property | `moq2ts` | Evidence | Next |
| --- | --- | --- | --- | --- |
| --- | --- | --- | --- | --- |
| [#8382](https://github.com/moq-dev/moq/issues/8382) (fix [#8442](https://github.com/moq-dev/moq/pull/8442), merged) | A client resumed after a stop longer than its idle timeout waits for the relay's stateless reset, its RTT sample stretched by the stop ([T82](test-82-slow-unresponsive-subscribers.md)) | Unknown for the receiver, on `moq5` and picoquic | open | test, gated on a `moq5` build: the receiver is not packaged |
| [#8831](https://github.com/moq-dev/moq/pull/8831) (merged) | An SRT source that reconnects replaces the stale broadcast only once the new connection has declared tracks, and one that ends before declaring a track announces nothing | Not yet built: [#61](https://github.com/openmoq/moq2ts/pull/61)'s `--per-program`, open, ends the track at a PAT change and waits for the program | open | read #61's announce timing once it merges |
| [#8384](https://github.com/moq-dev/moq/issues/8384) (closed) | After its own reconnect, a subscriber cannot tell the publisher unchanged on a wire with no publisher instance ([T82](test-82-slow-unresponsive-subscribers.md) Part F) | MoQT carries no instance. What a receiver has instead is MSF -01 §6.1's rising Group IDs, which [#46](https://github.com/openmoq/moq2ts/issues/46) shows the catalog track does not yet keep | code | after #46: whether the receiver reconnects at all |

## Both ways

**MSFTS carriage.** `moq-dev`'s MSF reader skips any track packaged other than LOC, CMAF or legacy, and its MSF types have no `mpeg2ts` packaging. Its whole multiplex appears only in its own catalog's `mpegts` section. Neither implementation therefore finds the other's TS through MSF (code). That is [moq-dev#3731](https://github.com/moq-dev/moq/issues/3731)'s question, open. Its quest, `msfts-convergence`, awaits a re-plan, and `moq2ts`'s carriage is [named](https://github.com/moq-dev/moq/issues/3731#issuecomment-6769099729) there as its consumer.
