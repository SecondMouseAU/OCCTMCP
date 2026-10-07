# CLAUDE.md

**Start at [`okf/index.md`](okf/index.md)**, this repo's OKF 0.2 knowledge bundle: what the repo
is, what it depends on, its components, and the mandatory policies. Read the one page a task
needs, when it needs it. Do not read the bundle up front, and never `@`-import it: `@` inlines a
file into every session, which is the cost this layout exists to avoid.

| Before you | Read |
|---|---|
| touch an OCCT or OCCTSwift API | [`okf/policies/context-first.md`](okf/policies/context-first.md) |
| change a tool in the Swift server | [`okf/components/swift-server.md`](okf/components/swift-server.md) |
| touch selection, remap, or anything history-aware | [`okf/references/history-and-remap.md`](okf/references/history-and-remap.md) |
| change the Node server | [`okf/components/node-server.md`](okf/components/node-server.md) |
| write or debug a script for `execute_script` | [`okf/references/script-template.md`](okf/references/script-template.md), [`okf/components/execute-script.md`](okf/components/execute-script.md) |
| write or change a test, or a CI job | [`okf/policies/prove-the-test-fails.md`](okf/policies/prove-the-test-fails.md) |
| bump a dependency floor | [`okf/references/external-dependencies.md`](okf/references/external-dependencies.md) |
| write a new type, helper, or tool | [`okf/policies/search-before-building.md`](okf/policies/search-before-building.md) |
| add a file, or split one | [`okf/policies/code-structure.md`](okf/policies/code-structure.md) |
| format or name anything | [`okf/policies/code-style.md`](okf/policies/code-style.md) |
| write prose, a comment, a commit or a PR body | [`okf/policies/writing-style.md`](okf/policies/writing-style.md) |
| open an issue | [`okf/policies/issue-tracking.md`](okf/policies/issue-tracking.md) |
| ship or release a change | [`okf/policies/docs-current.md`](okf/policies/docs-current.md) |

The LLM-facing tool table lives in [`README.md`](README.md) and stays canonical there: 79 tools in
Swift, 37 in Node. One copy is what stops the two from drifting.

---

Everything below is what a session in this checkout needs in hand: how to build it, how to run it,
and the invariants that break it. Durable what and why lives in `okf/`.

## Build and run

Two implementations live side by side. **Swift is primary** (in-process, calls OCCTSwift
directly, macOS 15+); Node is the original (shells out to `occtkit`, runs anywhere on Node 18+).
Both speak stdio MCP and read and write the same `manifest.json` and `annotations.json` in the
output directory.

```bash
# Swift, primary
swift build -c release         # debug build is `swift build`
swift run occtmcp-server       # stdio transport
swift test                     # swift-testing cases under SwiftTests/OCCTMCPCoreTests

# Node
npm run build                  # tsc into dist/
npm start                      # node dist/index.js (stdio transport)
npm run dev                    # tsc --watch
npm test                       # node:test unit tests for scene-mutation logic (no occtkit)
npm run test:integration       # end-to-end through occtkit (slow)
```

`swift test` runs unit and integration tests against a tempdir. The integration tests spawn the
built `occtmcp-server` and drive it over stdio, so a `swift build` must precede them; the harness
does that itself.

## Invariants

- **A fresh clone resolves differently from this checkout.** Local builds may pick up sibling
  checkouts. Verify what CI actually resolves with
  `OCCTMCP_FORCE_REMOTE_DEPS=1 swift build` and the same for `swift test`, before believing a
  dependency bump works.
- **Writing `manifest.json` is the side effect that matters.** OCCTSwiftViewport's `ScriptWatcher`
  watches that file, so emitting it is what triggers the live 3D reload. A tool that changes the
  scene without emitting leaves the viewport stale.
- **`BRepGraph.GraphUID` is instance-scoped.** It is `Codable` but does not survive a
  `GraphSnapshot` restore or a process restart: a rebuild mints a new `instanceID`. Re-mint from
  `(kind, index)` after reloading.
- **`findNode(for:)` matches by `TShape` object identity, not geometric equality.** A `Shape`
  re-derived from fitted parameters or a separate BREP round-trip returns `nil` even in the same
  location. Resolve against the graph's own face `Shape`, not a freshly fitted one.
- **`face[i]` / `edge[i]` labels from `query_topology` and `check_thickness` are in
  `Shape.faces()` enumeration order, not `BRepGraph` node-index order.** They are a different
  index space; do not hand-build a `selectionId` from them.
- **`execute_script` cold start is 60+ seconds** on the first call, while the underlying SwiftPM
  workspace builds. The request timeout is 2 minutes, per request.
- **CI fails a PR on `swift-format lint --strict`, and a bare doc comment is the usual cause.** A
  `///` comment must be one summary sentence, then a blank `///` line, before any further text.
  The local `swift-format` can refuse the repo's `.swift-format` (missing key
  `orderedImports.shouldGroupImports`): lint against a copy with `"shouldGroupImports": false`
  added. Also run `swiftlint lint --strict --config .swiftlint.yml` on the changed files only (it
  otherwise scans `.build`) and `python3 scripts/check-style-manifest.py --base origin/main`.
- **`makeOCCTMCPServer(outputDirectory:)` is a task-local, so `Task.detached` drops it.** Do not use
  `Task.detached` on a tool path; see `Paths.swift` in
  [`okf/components/swift-server.md`](okf/components/swift-server.md).
