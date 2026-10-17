# Test 49 — A closed origin and an authenticated fan-out edge

**State: run. Six of seven criteria met; criterion 3 fails as written, and the failure is the
export's, not the edge's.** A closed origin refuses the anonymous and holds a token to its paths; a
leaf edge dialing it with a subscribe-only token carries every PES of the feed unchanged to recipients
it admits by their own keys; revoking a recipient, or the edge, cuts exactly what it should within
one re-check; and a 20 s auth-server outage cuts nothing. The upstream build needs no change for our
fan-out: what remains is deployment.

## Objective

Our standing relays admit anyone with `--auth-public "**"`, and the security group alone keeps the
internet out. Closing them (stage 1) puts each relay behind `moq auth serve`, gives our publishers a
publish token, and lets outside recipients in only through an edge relay that holds its own
subscribe-only token at the origin and admits each recipient with that recipient's own key.
[T38](test-38-entitlement-estate.md) measured the edge's per-recipient admission and revocation
behind an *anonymous* origin. This rehearses the parts it left open before any standing unit is
restarted: that a closed origin refuses what it should and admits our publisher; that a leaf edge
dialing it with a token (which `moq auth serve` never marks as a cluster peer, only certificates)
still carries the feed; and what an auth-server outage or a revoked edge does to a live publisher
and its recipients.

## Environment

- **Build:** `3c0daa21b`, the standing units' binaries (`~/bin-3c0daa21`), release.
- **Host:** the EC2 tertiary, everything on loopback: two `moq auth serve` processes on unix sockets
  (`--key-dir`, `--expires 1h --revalidate 5s`, no anonymous rule), an origin relay on `--auth-url`,
  an edge relay on its own `--auth-url` that dials the origin with `--cluster-connect` and
  `--cluster-token`, and a publisher (`import ts`, the standing units' mode) reading a 120 s clip
  paced on its PCR. ES256 keys from `moq auth generate`, tokens from `moq auth sign`.
- **Rig:** [`t49-closed-origin-edge.sh`](scripts/t49-closed-origin-edge.sh); content compared with
  [`ts-pair-diff.py`](scripts/ts-pair-diff.py), continuity with TSDuck.

## Arms and pass criteria (fixed before the first run)

1. **The origin refuses the anonymous.** A publisher without a token, and a subscriber without a
   token, are refused: zero payload bytes, and the anonymous publisher's broadcast is not visible to
   an authorised subscriber.
2. **A token's path binds.** A publish token for another broadcast cannot publish ours; a subscribe
   token for another broadcast receives zero bytes of ours.
3. **The edge carries the feed.** A recipient on the edge and a subscriber on the origin, both
   started together, receive the same media: `ts-pair-diff.py` finds no payload-octet difference over
   the common span (continuity counters and PCR octets may differ, since each export numbers its
   own), and TSDuck reports no continuity error in either.
4. **The edge refuses what the origin would.** An anonymous recipient and a recipient whose token
   names another broadcast receive zero bytes from the edge.
5. **Revoking a recipient is local.** Deleting a recipient's public key stops that recipient within
   the 5 s re-check plus 1 s; a second recipient on the same edge keeps receiving.
6. **An auth outage does not cut a live publisher.** With the origin's auth server stopped for 20 s
   (four re-check periods) and then restarted, the publisher stays connected and the edge recipient
   loses no continuity.
7. **Revoking the edge revokes its recipients, and only them.** Deleting the edge's key at the origin
   stops the edge's recipients within the re-check plus 1 s while a direct origin subscriber keeps
   receiving; restoring the key lets a new recipient session receive again.

A criterion's arm counts only if its control (the same arm with a valid token) delivers.

## Results

One run of the arms and one control run (`MODE=control`: two exports on the origin and one on the
edge, 60 s), on the tertiary, idle otherwise. The valid-token sessions are every arm's control: the
origin subscriber received 123 MB and the first edge recipient 88 MB, both continuity-clean.

| # | Measured | Verdict |
|---|---|---|
| 1 | The anonymous publisher is refused at the session (`unauthorized`, exit 1, 0.08 s); an authorised probe of its broadcast receives 0 bytes; the anonymous subscriber is refused (exit 1) | pass |
| 2 | The wrong-path publisher is admitted to its own scope and its announce of ours is dropped: the probe of our broadcast receives 0 bytes; the wrong-token subscriber receives 0 bytes | pass |
| 3 | Every PES matched by PID and header is identical (5,028 of 5,028; 4,188 in the control), continuity clean in both, but 3,163 of 465,704 packets differ, in two stretches of 0.45 s and 0.12 s | **fail as written** |
| 4 | Anonymous and wrong-broadcast recipients receive 0 bytes from the edge | pass |
| 5 | The revoked recipient's last byte 4.15 s after its key was deleted (exit 1); the other recipient kept receiving | pass |
| 6 | Through the 20 s outage the publisher stayed connected (alive at the end of the run), and the origin subscriber and the edge recipient kept receiving; the origin logged retries with backoff | pass |
| 7 | The edge's recipient's last byte 0.59 s after the edge's key was deleted (exit 1), the origin subscriber unaffected; after the key was restored a new recipient received 18 MB | pass |

**Criterion 3.** The control separates the cause: the two exports on the origin are byte-identical
over all 389,324 packets they share, while the edge export diverges at the same media position as in
the arms run (packet 123,853 after the anchor) and realigns about 0.45 s later. Within a stretch the
PES sequence, timestamps and payloads are the same and the PID interleave differs at 45 positions,
which shifts the packetization (and with it continuity counters and adaptation-field stuffing) of
the packets around them. The stretches were written about 1 s before the revocation and outage
events that follow them, so neither caused them. The edge delivers the same media, and the demuxing
export packetizes it according to its delivery timing: the gap between "the same content" and "the
same bytes" that upstream's `ts-hitless` quest exists to close. The criterion asked for payload
identity at the packet level, which only the passthrough lane (`import ts --passthrough`, as in
[T48](test-48-passthrough-export.md)) can promise across delivery paths; the standing units use the
demuxed lane.

**Two behaviours an operator meets:**

- **A path refusal is silent.** A session without a credential is refused with an error; a valid
  credential used outside its paths is not. The wrong-path publisher stays connected with no error
  and no relay log line while publishing nothing, and the wrong-token subscribers wait out their
  timeout (exit 124). This is [T36](test-36-entitlement-enforcement.md)'s second refusal mechanism,
  still present on the build under test; it keeps a broadcast's existence from those not entitled to
  it. For stage 1 it means a mis-scoped publish token looks like a healthy unit, so the egress monitor,
  not the publisher's status, is the check after a token change.
- **Losing the edge's grant ends its recipients' sessions** (exit 1) rather than stalling them; they
  reconnect once the edge is readmitted.

## Limits

One run per arm. The auth outage was 20 s against a 1 h `--expires`; sessions admitted before an
outage survive until their grant's bound, but what happens to a session started during one (a
publisher restarting, say) was not measured. The edge carried one broadcast over loopback; a public
edge's certificate, its recipients' security-group rules, and the SRT recipient legs are deployment
steps this does not test.
