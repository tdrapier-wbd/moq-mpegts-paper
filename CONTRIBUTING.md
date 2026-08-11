# Contributing

This repository is a public technical reference exploring Internet-native primary
distribution for professional broadcast using Media over QUIC (MoQ). It is a set
of living documents, not a product. Its explicit purpose is to be **tested,
challenged, and — where wrong — corrected quickly**. Comment, disagreement, and
counter-evidence are the point, not a nuisance.

This document explains how to engage.

---

## Who this is for

The intended contributors mirror the intended readers: broadcast engineers and
CTOs, principal/architecture-level engineers, CDN and hyperscaler product teams,
broadcast vendors, and standards contributors. You do not need to agree with the
thesis to contribute — the most valuable contributions are often the ones that
disprove part of it.

## What we are looking for

In rough order of value:

1. **Falsification and counter-evidence.** If a claim is wrong, overstated, or
   contradicted by real deployment experience, say so — ideally with a concrete
   example, measurement, or reference. The repository would rather be corrected
   than flattered.
2. **Technical correction.** Errors of fact about broadcast engineering, MoQ, the
   MPEG-TS/MSFTS carriage, TR 101 290, ST 2022-7, IRD behaviour, or the transport
   drafts.
3. **Missing considerations.** Requirements, failure modes, trade-offs, or
   scenarios the documents do not yet address.
4. **Clarity and structure.** Places where the argument is unclear, where two
   documents contradict each other, or where content is in the wrong document.
5. **Standards alignment.** Pointers to relevant IETF MoQ, SMPTE, or related work
   that the documents should track or reconcile with.

## How to contribute

- **Open an Issue** to raise a correction, challenge a claim, or ask a question.
  This is the default and lowest-friction path. Reference the specific document
  and section (e.g. "architecture.md §4.2").
- **Start a Discussion** for open-ended questions, design debates, or topics that
  are not yet a concrete change — for example the open questions listed at the end
  of most documents.
- **Open a Pull Request** for concrete text changes. Small, focused PRs against a
  single document are easiest to review. For substantial rewrites, open an Issue
  or Discussion first so the direction can be agreed before you invest the effort.

## Editorial principles

Contributions are held to the same standard as the existing text. Please:

- **Write for a technically sophisticated reader.** Assume familiarity with
  broadcast engineering; do not re-explain the basics.
- **Justify architectural statements.** Every claim should have a technical
  rationale, and trade-offs should be stated, not hidden.
- **State uncertainty explicitly.** Where something is unproven or contested, say
  so, rather than presenting an opinion as a fact. It is better to write "this is
  unproven" than to overclaim. A useful habit is to distinguish what is
  *established*, what is *likely*, and what is *uncertain*.
- **Avoid marketing, hype, and startup language.** This is reference material, not
  promotion. Keep commercial and go-to-market argument out of the technical
  documents.
- **Cross-link, don't duplicate.** The reference architecture
  ([`docs/architecture.md`](docs/architecture.md)) is the integrative overview;
  the topic documents are the deep dives. Add detail in the right place and link
  to it rather than restating it.
- **Write the current state, not the sequence that produced it.** Both the paper and the
  notebook describe what is understood now. When something changes, replace the stale
  statement where it is made rather than appending a correction after it, and merge repeated
  discussions of the same point into one authoritative explanation. Where a correction carries
  a lesson worth keeping, the per-test file records it once in a `Corrections` section — the
  correction survives, the blow-by-blow does not.
- **Use Mermaid for diagrams** so they render in the repository and stay
  diff-friendly.

## Confidentiality

This is a public repository. **Do not contribute commercially sensitive or
confidential information** — including but not limited to a specific route's cost,
transponder or fibre lease rates, any incumbent's actual or depreciated route cost,
customer names or pricing, vendor contract or discount terms, or private
implementation internals.

**Published list prices are a different matter and are welcome.** Provider tariffs,
marketplace software rates, reserved-capacity tiers and surveyed market prices are
public and verifiable, and the economics document
([`docs/economics.md`](docs/economics.md) §4) models the always-on case openly with
them. When contributing such a figure, cite the source and the date it was
retrieved, prefer a machine-readable price list over a rendered page, and keep the
working in [`lab/cost-model.md`](lab/cost-model.md) so it stays auditable.

If a point can only be made with confidential data, describe the *method* and leave
the numbers out — or, better, express the result as a threshold derived from public
figures, as §4.4 does for the satellite comparison.

The same applies to infrastructure detail in the notebook. `lab/` is public, so commands and
procedures there use placeholders — `<EC2_IP>`, `<subscriber-home-ip>` — rather than real
addresses, paths, credentials or TLS fingerprints. If you contribute a procedure, keep that
convention.

## A note on AI assistance

Parts of these documents were drafted with AI assistance and then reviewed. That
is disclosed openly. Contributions may be AI-assisted too, but the contributor is
responsible for the accuracy, originality, and confidentiality of anything they
submit — the same standard as any other contribution.

## Document map

If you are not sure where a change belongs, the [README](README.md) has the full
document map. In brief, the **paper** (`docs/`): [`vision`](docs/vision.md) (why),
[`transport`](docs/transport.md) (why MoQ specifically), [`architecture`](docs/architecture.md)
(how, integrative), [`implementation`](docs/implementation.md) (build and test), the topic
deep-dives (`relay`, `control-plane`, `entitlement`, `security`, `interoperability`,
`operations`), [`economics`](docs/economics.md) (cost framework), and
[`evidence`](docs/evidence.md) (what the prototype showed).

The **validation campaign** lives in [`lab/`](lab/README.md) — both the plan (objectives,
acceptance gates, pass criteria) and the per-test engineering notebook (procedures, commands,
measured results). Code this project contributes back to the ecosystem lives in
[`interop/`](interop/README.md); the CBR groomer is the separate
[`mpegts-pacer`](https://github.com/tdrapier-wbd/mpegts-pacer) crate.

A correction to a *measured result* is best raised as an Issue with the counter-measurement, since
changing a number usually means re-running something rather than editing prose.

Thank you for helping make this more accurate.
