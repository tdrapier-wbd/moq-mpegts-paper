# Test 69 — Access control and scrambling on the segmented lane

**State: run and graded.** Revocation at the edge took a median 24–28 s per PoP and up to 86 s;
expiry was exact. `tsp -O hls` carries a scrambled multiplex intact without `--intra-close`, and with
it publishes no segment until its input ends.

Part of [P1-al](planned-experiments.md#p1--establishes-where-one-architecture-is-superior); the MoQ
lanes' half is [T66](test-66-scrambled-carriage.md). Rigs:
[`t69-cloudfront.sh`](scripts/t69-cloudfront.sh) and [`t69-aes-origin.sh`](scripts/t69-aes-origin.sh)
(part C), [`t69-scrambled-hls.sh`](scripts/t69-scrambled-hls.sh) (part S).

## Objective

R7 on the segmented lane is derived ([Comparison](../docs/comparison.md) §7): where the CDN authorises
every request, revocation is bounded by the playlist's reload cadence, but no revocation has been
timed against a CDN. And the lane's only scrambled-source result is a negative one: our segmenter
names no segment of a scrambled multiplex ([T66](test-66-scrambled-carriage.md)). Two questions:

- **C. Common Access Token at the edge.** A segmented stream encrypted per segment (HLS AES-128),
  every request gated at CloudFront by a CTA-5007 token that a CloudFront Function validates, with
  revoked token IDs in a KeyValueStore. How long after a revocation does the edge refuse it, and what
  does the route keep and lose against BISS-CA?
- **S. A scrambled source through `tsp -O hls`.** Does TSDuck's packager cut a DVB-CISSA-scrambled
  multiplex, does the segmented chain carry it and its conditional-access PIDs, and does a descrambler
  after the receiver return the clear source?

**Falsifies:** Comparison §7's derivation, if the edge's own propagation, not the reload cadence,
sets the revocation bound; and the planned premise that the segmented lane cannot carry a scrambled
source, if `tsp -O hls` does.

## Environment

| | |
|---|---|
| Part C origin | the EC2 secondary: `tsp` from `contrib-10m.ts` (looped; rewinds do not matter to access) through `-O hls --duration 2 --live 6 --live-extra-segments 3 --intra-close`; [`t69-aes-seg.py`](scripts/t69-aes-seg.py) encrypts each segment (AES-128-CBC, the media sequence as IV, a new key every five segments) and writes the encrypted playlist; nginx on TCP 18310 serves the encrypted playlist, segments and keys only to requests carrying the origin secret CloudFront adds |
| Part C edge | one CloudFront distribution, `PriceClass_100`, legacy TTLs honouring the origin (playlist 1 s, segments and keys 60 s). A viewer-request CloudFront Function ([`t69-cat-gate.js`](scripts/t69-cat-gate.js), runtime 2.0) on every path: the token in `CTA-Common-Access-Token`, MAC checked by `cf.cwt.validateToken` (HS256, the key from the KeyValueStore), then `iss`, `exp`, `nbf` and `catu` (path prefix only; any other `catu` component or match type is refused), then the token's `cti` looked up in the same KeyValueStore's revocation keys |
| Part C viewers | the laptop: [`t69-cat.py`](scripts/t69-cat.py) mints tokens (COSE_Mac0, checked against RFC 8392's example token A.4); [`t69-cat-recv.py`](scripts/t69-cat-recv.py) fetches playlist, keys and segments and decrypts; [`t69-revoke.py`](scripts/t69-revoke.py) probes two PoPs at once, the one the laptop resolves and one reached by a pinned address, each `x-amz-cf-pop` read from the response |
| Part S | the laptop, loopback: T66's stimulus rebuilt by its recipe (120 s of the clip, BISS-CA's `CA_system_id` in the PMT and a CAT, ECM and EMM sections at 16 kb/s, DVB-CISSA in 10 s crypto-periods), `tsp --realtime … -O hls --duration 2 --live 6 --live-extra-segments 3` with and without `--intra-close`, nginx on 127.0.0.1:18690, [`b8-hls-recv.py`](scripts/b8-hls-recv.py) verbatim, then `tsp -P descrambler` (the same control words) → `mpegts-pacer` `97f3a38` 11 Mb/s → UDP → `tsp -I ip` |
| Builds | TSDuck 3.44-4676 at the origin, 3.45-4798 on the laptop; graded by [`t69-grade.py`](scripts/t69-grade.py), [`t66-grade.py`](scripts/t66-grade.py) and `ts-passthrough-identity.py` |

## Procedure

**Part C.** `t69-aes-origin.sh start` on the secondary; `t69-cloudfront.sh` `kvs`, `function`,
`test`, `publish` and `dist` create the KeyValueStore (the signing key under one key ID), the function
(its seven gate cases run through `test-function` before it is published) and the distribution; a
temporary TCP 18310 rule admits CloudFront, which the origin secret gates. Then, from the laptop:

1. **Gate control.** For the playlist, a segment and a key, at each PoP: no token, a token with one
   MAC byte flipped, an expired token, a token whose `catu` path prefix excludes the path, a token
   issued by another `iss`, and a valid token.
2. **Decryption.** `t69-cat-recv.py` for 150 s through CloudFront; graded against the origin's
   record of each segment's clear and encrypted SHA-256.
3. **Revocation.** Ten trials. Each mints a token with a fresh `cti`, probes the playlist at each PoP
   every 100 ms on one connection per PoP, waits a random 3–6 s (so the write lands at a random phase
   of the edge's cycles), writes the `cti` to the KeyValueStore with `cloudfront-keyvaluestore
   put-key`, and probes on until 20 consecutive refusals or 90 s. The zero is when the write returns,
   on the probe's own clock; when it started is logged beside it.
4. **A revoked viewer.** `t69-cat-recv.py` running when its token is revoked: what it hands on after
   the write returns.
5. **Expiry.** A token expiring 30 s after issue, probed at 100 ms through its expiry.

**Part S.** `t69-scrambled-hls.sh` builds and checks the stimulus (T66's criterion 1), then runs each
packager variant for 130 s with the receiver's verbatim output and the descrambled, groomed output
captured together.

## Pass criteria, fixed before the first run

**C, the token at the edge.**

1. **Control.** Each refusal case in step 1 is refused at both PoPs, for all three object types, and
   the valid token is admitted. Otherwise the gate is faulty and nothing below is graded.
2. **Decryption.** Over 150 s, every segment the receiver fetched decrypts to its clear bytes
   (SHA-256 equal to the origin's record), none of the ciphertexts equals its clear segment, and the
   run crosses at least two key changes.
3. **Revocation**, measured, not passed: per PoP, the median and maximum time from the end of the
   write to the first refusal over ten trials, and how many requests were admitted after the first
   refusal (requests served by edge servers that had not yet seen the write). *Predicted:* a few
   seconds, under 10 s, which would make the edge's propagation, not a 0.28–2 s reload cadence, the
   bound Comparison §7 derives.
4. **A revoked viewer**, measured: seconds of programme handed on after the write ends, and
   whether a refused key request or a refused segment request ends it.
5. **Expiry.** Every request after the token's `exp`, at the edge's second, is refused, and none
   before it.

**S, a scrambled source through `tsp -O hls`.**

6. **Control.** T66's criterion 1 on the rebuilt stimulus (its grader, unchanged).
7. **Cutting**, classified: per variant, segment count and EXTINF minimum, median and maximum, and
   how many segments begin with a packet on 111 that has `random_access_indicator` set. *Predicted:*
   `--intra-close` cannot see a picture type through scrambling, so neither variant cuts on random
   access points, and both still cut.
8. **Carriage.** With PIDs 0 and 0x64 removed from both, the receiver's output is the scrambled
   stimulus's packets in order, 0 foreign, gaps reported; the CAT, ECM and EMM PIDs occur as often as
   in the span covered; every PMT the packager wrote carries the BISS-CA CA_descriptor.
9. **Descrambled.** With PIDs 0 and 0x64 removed and `--groomed`, the captured output is the
   offline-descrambled control's packets, 0 foreign; the capture has 0 continuity errors on every
   other PID and no PCR interval over 40 ms; FFmpeg logs no error it does not log on the same span of
   the clear stimulus.

*Verdict:* C2, C5, S8 and S9 pass or fail; C3 and C4 are the measurements P1-al exists for; S7 is
classified.

## Results

**C, the token at the edge.** The laptop resolved Frankfurt (FRA60) for criteria 1–2 and London (LHR5)
for 3–5; the pinned address reached Düsseldorf (DUS51) throughout.

| # | Result | Grade |
|---|---|---|
| 1 | All 30 refusal cells refused at both PoPs with the case's own reason (`missing`, `mac`, `expired`, `iss` 401; `uri` 403); the 6 valid cells admitted | **pass** |
| 2 | 64 segments (156.0 s), each decrypting to the origin's clear SHA-256, no ciphertext equal to its clear bytes, no sequence hole; 14 key periods, 13 changes. FFmpeg logs one line, at the first segment's start, on bytes identical to the clear ones | **pass** |
| 3 | See the table below | measured |
| 4 | After the write ended the viewer was handed 12 segments, 29.9 s of programme; a refused playlist request (403 `revoked`) ended it at 29.6 s, before any key or segment was refused | measured |
| 5 | 398 requests at each PoP: none refused before `exp`, none admitted from it; the last admission 67 ms before `exp`, the first refusal 32–33 ms after it, on the viewer's clock | **pass** |

Revocation over ten trials, from the end of the write (0.76–0.88 s, median 0.82 s) to the first
refusal, probing every 100 ms with no sampling gap over 177 ms:

| PoP | Median | Min | Max | Admitted after the first refusal |
|---|---|---|---|---|
| London, resolved | 28.5 s | 23.1 s | 85.6 s | 0, in 10 trials |
| Düsseldorf, pinned | 24.3 s | 5.9 s | 53.2 s | 0, in 10 trials |

Of the 20 first refusals, 9 fell between 23 and 26 s, 3 between 31 and 33 s, 5 between 52 and 55 s,
one at 86 s and two under 15 s. Within one trial the PoPs differed by up to 52 s. The prediction (under
10 s) is falsified. Every refusal was generated by the function (`FunctionGeneratedResponse`) for
objects the edge was serving from cache: 7,269 admissions in the same probes were cache hits.

**S, a scrambled source through `tsp -O hls`.**

| | `--intra-close` | Without it |
|---|---|---|
| 6 (stimulus) | 753,959 payload packets on the four PIDs, all scrambled; 11 parity changes; 0 differ once descrambled offline: **pass** | (the same stimulus) |
| 7 (cutting) | **no cut**: the playlist stayed empty until the input ended, then listed one 119.9 s segment | 60 segments, EXTINF 0.138 / 2.022 / 2.113 s (the minimum is the last, at the input's end); 59 begin with a PES start on 111 (all but the first), 2 at a random-access point |
| 8 (carriage) | all 791,036 packets in order, 0 foreign, 0 gaps; CAT 238, ECM 1,274, EMM 1,274 as in the span; 962 of 962 PMTs with the CA_descriptor: **pass** | 777,675 packets in order from the join, 0 foreign, 0 gaps; CAT 235, ECM 1,253, EMM 1,253 as in the span; 1,005 of 1,005 PMTs: **pass** |
| 9 (descrambled) | **void**: the one segment arrived as a 142.7 MB burst, of which the pacer, capped at 14 s, emitted the last 4 s | 731,938 packets, the control's in order from 4.0 s into the stimulus to 35 packets before its end, 0 foreign, 0 gaps; 0 continuity errors, with or without the packager's PAT and PMT; PCR at most 25.0 ms; FFmpeg's log identical to the clear span's: **pass** |

Without `--intra-close`, the capture's head is the pacer dropping 12,703 late packets when the first
two segments arrived together. Its one stall is the receiver polling for 14.5 s after `ENDLIST`; no
run of null packets in the capture exceeds 27 ms.

## Conclusions

1. **A CDN that checks every request bounds revocation by its own propagation, not by the playlist
   cadence.** Through CloudFront's KeyValueStore the bound is tens of seconds: a median 24–28 s and a
   worst case of 86 s, set by whichever edge sees the write last. That is about 50 times MoQ's measured
   1.7 s ([T37](test-37-entitlement-revocation.md)), not Comparison §7's derived 0.28–0.30 s. Expiry
   is exact to the probe interval, so a tighter bound needs short-lived tokens re-issued by the
   entitlement service: design, not exercised here (`catr` was not run).
2. **The gate holds in front of the cache.** Revocation refused objects the edge held, so caching
   does not widen the bound beyond the propagation measured.
3. **The segmented lane can carry a scrambled multiplex, through a packager that does not look into
   the payload.** Without `--intra-close`, TSDuck's packager carries it byte for byte, its CA PIDs
   and BISS-CA's CA_descriptor with it, and a descrambler after the receiver returns the clear source.
   With `--intra-close`, the setting a clear feed is cut with, it cannot carry one live. The segments
   then begin on PES boundaries, 58 of 60 away from a random-access point, so a receiver joining at a
   segment waits inside it for the next one.
4. **What the route keeps and loses against BISS-CA** (derived from parts C and S and T66):

| | BISS-CA in the multiplex | The segmented route's own access |
|---|---|---|
| Protection ends | at the descrambler before the IRD | at the viewer, which decrypts; the CDN serves the keys in the clear |
| Entitlement | in-band, per receiver; not exercised | per token at every request: measured exact |
| Revocation | by entitlement message; not exercised | tens of seconds through the edge's store; expiry exact |
| What it needs of the lane | byte-faithful carriage, measured here and on MoQ's opaque lane | a programmable edge and a key service |

## Limits, stated in advance

- One distribution, two PoPs, one viewer host; the second PoP is reached by a pinned address, not by
  a viewer there. Each probe holds one connection, so it reads one edge server per PoP. The token's
  signing key is static; its rotation, CAT renewal (`catr`) and replay (`catreplay`) are not
  exercised.
- AES-128 keys are served through the same gated distribution, so CloudFront holds clear keys and
  ciphertext alike; a production route would serve keys from a key server of its own. The origin leg
  is plain HTTP.
- Part S: one clip, loopback, control words standing in for the key ladder, as T66.
