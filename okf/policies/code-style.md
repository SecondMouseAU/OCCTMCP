---
type: policy
title: Code style
description: Swift naming/API shape follows the Swift API Design Guidelines, formatting follows Google's Swift Style Guide via swift-format, and doc comments stay terse; docs/ is the single source of truth for design rationale, not a second copy of it. Rolled out gradually via an exemption manifest, not a big-bang sweep.
tags: [policy, style, swift, docs, agents]
timestamp: 2026-08-12
---

# Code style

**Naming and API shape** follow the
[Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) as-is:
clarity at the point of use over brevity, methods without side effects read as noun phrases,
methods with side effects as imperative verbs, boolean properties/methods read as assertions.

**Swift formatting** follows [Google's Swift Style Guide](https://google.github.io/swift/),
enforced by `swift-format` (`.swift-format`: 100-column limit, 4-space indent, the ecosystem's
one deliberate divergence from Google's own 2-space default, chosen to avoid a repo-wide reformat
diff with no readability gain).

**No C++ bridge layer exists in this repo** (confirmed on rollout day: no `.cpp`/`.mm`/`.h`/
`.hpp`/`.cc` under `Sources/`), so `.clang-format` and the clang-format CI step from the
`OCCTSwift` reference rollout don't apply here. If a bridge layer is ever added, it should adopt
OCCT's own vendored `.clang-format` at that point, matching
[OCCTSwift's own approach](https://github.com/SecondMouseAU/OCCTSwift/blob/main/okf/policies/code-style.md).

**SwiftLint is scoped to `orphaned_doc_comment` only** (`.swiftlint.yml`, `only_rules`, not the
default set). SwiftLint's defaults duplicate `swift-format`'s formatting opinions (can disagree
with them on the same line) and separately add a large code-quality/complexity surface
(`identifier_name`, `cyclomatic_complexity`, `function_body_length`, `nesting`, ...) that overlaps
[code-structure](code-structure.md) rather than this policy; a file that needs a structural pass
runs one as its own scoped initiative, not as a side effect of a style-lint gate.
`orphaned_doc_comment` catches something `swift-format` has no equivalent for. It found zero
violations against `Sources/` on rollout day.

**Doc comments stay terse.** A `///` comment is a single-sentence summary plus only the
`Parameter`/`Returns`/`Throws` tags that add something the summary doesn't already say. Design
rationale, extended examples, and issue cross-references belong in `docs/`, not duplicated in
source: `docs/` is the single source of truth for *why* and *how*, per
[GitLab's documentation style guide](https://docs.gitlab.com/development/documentation/styleguide/)
("share the link to the documentation instead of rephrasing the information").

## Gradual rollout: the exemption manifest, not a big-bang sweep

This repo measured 90 Swift files (~27,665 lines across `Sources/` and `SwiftTests/`) and ~5,400
pre-existing `swift-format` diagnostics against `Sources/` alone on rollout day: large enough
that a whole-tree gate would fail every PR against work nobody has touched, the same reasoning
that put [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) (not
[OCCTSwiftScripts](https://github.com/SecondMouseAU/OCCTSwiftScripts), small enough to sweep in
one PR) on the gradual-adoption path. Instead:

- `scripts/style-manifest-swift.txt` lists every `Sources/**/*.swift` file that existed at
  rollout. A listed file is exempt from `swift-format` until touched.
- **If you touch a listed file, you fix it and remove it from the manifest in the same PR.**
  `scripts/check-style-manifest.py` (logic copied unchanged from OCCTSwift's own already-debugged
  version, adapted only to drop the bridge-manifest reference this repo doesn't need) enforces
  this mechanically: a manifest file appearing in a PR's diff while still listed at `HEAD` fails
  the build. This is the CI-enforceable version of the rollout's own stated principle: fix what
  you touch, not the whole tree at once.
- The manifest only shrinks. A new file is never grandfathered onto it; new code complies from
  creation, checked by the same `swift-format`/SwiftLint steps running unconditionally against
  anything not already listed.
- `SwiftTests/` is out of scope for both the manifest and the CI gate for now (same as OCCTSwift's
  `Tests/` exclusion), consistent with the policy's own naming/formatting focus on the public and
  internal library surface first.

Why: the ecosystem-wide proposal and evidence (comment:code ratios, a live doc-drift bug found in
OCCTSwift's `docs/reference/CurveAdaptors.md`) live in
[`ecosystem` docs/code-style-policy-proposal-2026-08.md](https://github.com/SecondMouseAU/ecosystem/blob/main/docs/code-style-policy-proposal-2026-08.md).
Rollout sequencing (the "MCP cluster" step, after `OCCTSwift`) is in that document's §4. Filed and
tracked as [OCCTMCP#173](https://github.com/SecondMouseAU/OCCTMCP/issues/173).

Ecosystem standard: see
[OKF-STANDARD.md](https://github.com/SecondMouseAU/ecosystem/blob/main/OKF-STANDARD.md).
