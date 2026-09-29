#!/usr/bin/env python3
"""T10 #4122 discriminator patches. A: log re-anchors. B: A plus one section-clock lane per video PID."""
import sys

variant = sys.argv[1]
root = sys.argv[2]


def edit(path, old, new):
    p = f"{root}/{path}"
    s = open(p).read()
    n = s.count(old)
    if n != 1:
        sys.exit(f"{path}: expected 1 match, found {n}: {old[:60]!r}")
    open(p, "w").write(s.replace(old, new))


edit(
    "rs/moq-mux/src/clock.rs",
    "\t\tself.offset = Some(base as i128 - src as i128);\n\t\tself.generation += 1;\n",
    "\t\ttracing::warn!(generation = self.generation + 1, src, now, old = ?self.offset, "
    "new = base as i128 - src as i128, \"t10: anchor re-anchored\");\n"
    "\t\tself.offset = Some(base as i128 - src as i128);\n\t\tself.generation += 1;\n",
)
edit(
    "rs/moq-mux/src/clock.rs",
    "\t/// Translate one of `lane`'s timestamps, sampling the arrival time.\n",
    "\tpub(crate) fn generation(&self) -> u64 {\n\t\tself.generation\n\t}\n\n"
    "\t/// Translate one of `lane`'s timestamps, sampling the arrival time.\n",
)

lane = "&mut self.media_unwrap" if variant == "A" else "self.section_unwrap.entry(pid).or_default()"
edit(
    "rs/moq-mux/src/container/ts/import.rs",
    "\t\t\t\tlet pts = unwrap_pts(\n\t\t\t\t\t&mut self.media_unwrap,\n"
    "\t\t\t\t\tpes.header.pts.map(|t| t.as_u64()),\n\t\t\t\t\tself.anchor.as_mut(),\n\t\t\t\t)?;\n",
    "\t\t\t\tlet before = self.anchor.as_ref().map(|a| a.generation());\n"
    f"\t\t\t\tlet pts = unwrap_pts(\n\t\t\t\t\t{lane},\n"
    "\t\t\t\t\tpes.header.pts.map(|t| t.as_u64()),\n\t\t\t\t\tself.anchor.as_mut(),\n\t\t\t\t)?;\n"
    "\t\t\t\tif self.anchor.as_ref().map(|a| a.generation()) != before {\n"
    "\t\t\t\t\ttracing::warn!(pid = ?pid, \"t10: section-clock lane re-anchored the source\");\n"
    "\t\t\t\t}\n",
)

if variant == "B":
    edit(
        "rs/moq-mux/src/container/ts/import.rs",
        "\tmedia_unwrap: PtsUnwrap,\n",
        "\tmedia_unwrap: PtsUnwrap,\n\tsection_unwrap: HashMap<Pid, PtsUnwrap>,\n",
    )
    edit(
        "rs/moq-mux/src/container/ts/import.rs",
        "\t\t\tmedia_unwrap: PtsUnwrap::default(),\n",
        "\t\t\tmedia_unwrap: PtsUnwrap::default(),\n\t\t\tsection_unwrap: HashMap::new(),\n",
    )
    edit(
        "rs/moq-mux/src/container/ts/import.rs",
        "\t\tself.media_unwrap.discontinuity();\n\t\tself.last_pts = None;\n",
        "\t\tself.media_unwrap.discontinuity();\n\t\tfor unwrap in self.section_unwrap.values_mut() {\n"
        "\t\t\tunwrap.discontinuity();\n\t\t}\n\t\tself.last_pts = None;\n",
    )
print(f"patched {variant}")
