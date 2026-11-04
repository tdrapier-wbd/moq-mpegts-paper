# Test 77 — A multi-programme segment through CloudFront

**State: run once; passed. CloudFront carried a three-programme segment byte for byte, uncached and cached, and all three programmes graded `CARRIED`.**

## Objective

The question [Evidence](evidence.md) §5 held open: can a CDN carry a multi-programme TS segment in practice? HLS forbids one ("Transport Stream Segments MUST contain a single MPEG-2 Program"), so a player may refuse it, but a primary-distribution receiver reads bytes, not the playlist's promise. What MoQ keeps as its carriage-fidelity advantage depends on whether the CDN itself alters, refuses or reorders such a segment. One cell answers that for CloudFront.

## Environment

[T10](test-10-mpts-multiservice.md)'s fixture, `mpts3.ts` from [`make-real-mpts.sh`](scripts/make-real-mpts.sh): 60 s, three programmes on independent clocks, each with its own PMT and PCR PID, one SDT listing all three, EIT present/following per service. Cut into 2 s segments by [`t61-epochseg.py`](scripts/t61-epochseg.py) `--file` (on programme 1's video random-access points; each segment an exact slice, so every programme rides in every segment), the same files placed under `/g/m/` on both origins of T76's distribution, behind its origin group and viewer gate. Fetched from the tertiary with `curl` and the viewer header: the playlist, then every listed segment twice, the second normally a cache hit.

## Pass criteria, fixed before running

1. **Bytes:** every segment through CloudFront, on both fetches, is byte-identical to the origin's file (SHA-1), with no `Content-Encoding`.
2. **Programmes:** the concatenation of the fetched segments, graded by [`t10-grade.py`](scripts/t10-grade.py) against the fixture, has all three programmes `CARRIED`.
3. **Reported:** each segment's size, `Content-Type`, `X-Cache` and time to first byte on both fetches.

_Predicted:_ identical bytes and all three programmes carried: a CDN does not parse a segment.

## Results

**Bytes (criterion 1) pass.** The playlist listed 29 segments, 144,526,504 bytes, about 5 MB each. On both fetches every segment returned 200 as `video/mp2t` with no `Content-Encoding`, and each matched the origin's SHA-1. `X-Cache` read `Miss` for all 29 on the first fetch and `Hit` for all 29 on the second; time to first byte had a median of 26.4 ms (16.3–36.8) uncached and 16.3 ms (14.1–30.2) cached.

**Programmes (criterion 2) pass.** The PAT is bit-identical, and each programme is `CARRIED`: its PMT bit-identical, its SDT entry identical, EIT present/following 6 of 6 sections identical, no continuity error, every PCR interval at most 25 ms with no PCR failing verification. The egress is the fixture less the segmenter's held head and tail: 348,716 of programme 1's 359,960 video packets.

## Conclusions

1. **A CDN does not stand between a multi-programme segment and its receiver.** CloudFront moved the bytes untouched and cached them; HLS's single-programme rule binds players, not the distribution.

## Limits

- One fixture, one distribution, an on-demand fetch by `curl`, not a live receiver; a player's single-programme assumption is not tested, only the CDN's carriage.
- The segmenter cuts on programme 1's random-access points, so programmes 2 and 3 start each segment wherever their own GOPs happen to be.

## Commands

```bash
python3 ~/p59/t61-epochseg.py ~/p59/www/g/m --file ~/t77/mpts3.ts --window 29 --extra 1000   # each origin
bash ~/p59/t77-mpts-cell.sh https://<cf>/g/m/index.m3u8 ~/p59/viewer-key ~/p59/t77out ~/p59/origin.sha1   # the tertiary
python3 ~/p59/t10-grade.py ~/p59/mpts3.ts ~/p59/t77out/egress.ts
```
