# Raw captures — re-grading T23 against #3529 on current `main`

Kept because two of the claims drawn from these runs are attributions to a single upstream PR, and
one of them **overturns an attribution this lab had previously made to its own groomer**. Both have to
be defensible from the measurements rather than from the write-up.
See [T23 § against #3529](../../test-23-pcr-discontinuity-classes.md#against-3529-current-main).

Builds. Under test: `moq` 0.11.0-`fd4f5d82e` (`fd4f5d82e399b1daca93fc28a1484e6533a9f4b5`), current
upstream `main`, containing the [#3529](https://github.com/moq-dev/moq/pull/3529) merge
`d4b5349f8ea402b4589b2f15d9efc9ecfa2915cb`. Baseline: `moq` 0.10.0-`d88c2ee99`, rebuilt from the same
worktree that produced § Against the fix. Groomer `mpegts-pacer` `5ab84cd` throughout, on a clean tree.

Held constant so the client build is the only variable: the six stimulus files unchanged from T23,
`t23-discontinuity.sh`, `t23-grade.py`, the same laptop host and loopback relay, 105 s per arm with the
event at 45 s, 4,000,000 b/s mux.

| File | What it is |
|---|---|
| `grade-all-arms.txt` | Full three-point grader output — source, export, paced — for all six arms on both builds, twelve runs. The two quantities that move are both on arm C: export `disc` 0 → 2, and the exported jump `unsignalled +29.050 s` → `signalled +30.000 s` at a rate ratio of 1.000 against the old 1.006. Arm D is the arm that must *not* move, and does not. |
| `pinned-cushion-2x2.csv` | Arm C and the control arm F on both builds with the groomer's cushion **pinned** at 200 ms, which is what makes the underrun figure attributable. The adaptive cushion had moved between sessions (200 → ~347 ms, control included), so the unpinned counts belong to the session rather than the build. Pinned: arm C **3,219 → 5** underruns against its own control's **189 → 6**. |
| `fence-on-current-main.csv` | The [#3533](https://github.com/moq-dev/moq/issues/3533) fence on current `main`, against the T27 continuous multi-track source on the cross-host rig, relay held at `bin-3515` so only the client differs. Columns are current `main`, pre-#3375 `025613d`, and the #3375 merge `0e61e35`. Current `main` is indistinguishable from #3375: 0.31 Mb/s from the first join across ~7 joins, against the control's 9.1–9.8 Mb/s. |

**Why the control arm matters more than usual here.** Content gaps rose on every arm between the two
sessions, 26–27 ms to 70–127 ms. The byte-identical control arm rose *further* than any of them, 27 ms
to 141 ms, which forbids reading any of it as a regression: the session's baseline moved and every arm
sat at or below its own control. The figures that survive are the ones measured *within* a session
against F, or with the adapting stage pinned.

**Flag counts are also taken directly off the wire**, not only through the grader, because one claim
is about where a flag originates: on `d88c2ee99` the exported TS carries **0** and the groomed TS
carries **1**, so `mpegts-pacer` was declaring the break itself; on `fd4f5d82e` it is **2 and 2**,
pure propagation.
