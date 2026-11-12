# Knowledge Log

## 2026-11-12

* **Update**: #261. An `ExtraTool` handler can now add a body to the scene and find one again by id through the code the built-in tools use: `SceneBodies.add(shape:)` (the staged write, manifest lock, history snapshot and write observer that `read_brep` and `import_file` now share, with body ids checked to be usable as file names), `SceneBodies.body(withId:)` and `SceneBodies.shape(ofBody:)` (format dispatch and the host's shape provider). `OCCTMCPContext.reportProgress` sends MCP progress for a handler when the client asked for it. `ExtraToolSessionTests` pins the rest of the contract through a real client and server: state held by a handler survives between calls, calls run concurrently, the scene directory and a client's cancellation reach the handler's task (moving dispatch onto `Task.detached` fails these), and a server is released with its handlers' state once its session ends. A request the client cancelled now gets no response, as the MCP spec asks (`registerTools` rethrows the cancellation). An add refuses a file name another body already has (case-insensitively) rather than overwriting that body's file, which `read_brep` and `import_file` now also do, and pushes the scene it replaced onto the history only once its write has succeeded.
* **Update**: #260. Four read-only drawing tools, 79 to 83 tools: `read_drawing`, `list_drawing_entities`, `list_drawing_dimensions` and `measure_drawing`, built on OCCTSwiftIO's DXF import (`OCCTSwiftIO` becomes a direct product of `OCCTMCPCore`; it was already in the graph). They return coordinates and numbers, never images, and never touch the scene. Entity ids are `e<index>` and stable only for the same bytes, so every result carries the file's SHA-256; what the reader skips (block inserts, hatches, splines) is counted from the raw file and reported; distances are exact OCCT extrema over edges built from the entities. A dimension's `valueFromPoints` (aligned, radius and diameter) is the length between its own definition points, the value when the file stores none and a check when it does. DXF only: `DWGLoader` is merged upstream (OCCTSwiftIO#53) but unreleased and JWW has no entity model yet (OCCTSwiftIO#54), and both return an error saying so. Page: `docs/reference/drawing-read.md`.
* **Update**: #265. `execute_script` could hang forever after its child had exited: `runProcess` called `Process.waitUntilExit()` after awaiting the pipe drains, and with no termination handler that waits on the run loop of the launching thread, which the task may have left. `runProcess` now waits on `ProcessExit`, built on `Process.terminationHandler`. Added the rule to `CLAUDE.md` Invariants and `Tools/ProcessExit.swift` to the `swift-server.md` catalogue.

## 2026-10-15

* **Update**: #250. `ManifestStore.update(willWrite:_:)`: advisory `flock` on `manifest.lock`, a callback that receives the exact bytes under the lock before the atomic rename, and every mutating tool moved onto it (re-applying its change to the manifest read under the lock). `write` takes the same lock. A malformed manifest is `ManifestError.malformed` everywhere, not "No scene loaded", and `read_brep`, `import_file` and `segment_mesh_zones` no longer overwrite it. Source-compatible: `ManifestStore.init(path:)` gained a defaulted `lockTimeout`.

## 2026-10-11

* **Update**: #234. `inspect_assembly` and `set_assembly_metadata` read `.xbf` input with `Document.loadOCAF(from:)` (the OCAF reader) instead of `Document.load(from:)` (the STEP reader), so the documented set-then-inspect round trip works. OCCT's `Open` segfaults on an empty file or a non-OCAF file, so `loadXBF` checks the `BINFILE` header first and refuses anything else with an error result.

## 2026-10-07 (b)

* **Update**: `policies/prove-the-test-fails.md` adopted in full from OCCTSwift (it was a pointer), with a "What this repo adds" section recording the shapes found by the #211 audit. No ecosystem issue filed, by decision.

## 2026-10-07

* **Update**: CI hardening. `tests.yml` gained a `changes` job, a Node job and a `ci-gate` aggregate; `integration.yml` added for the nightly Node end-to-end run. Added `policies/prove-the-test-fails.md` (pointer to the OCCTSwift canonical text) and `references/ci.md`. Test audit: integration tests now read `result.isError` (the old `resp["error"] == nil` could not see a tool failure, and hid two `apply_feature` calls sent with camelCase keys the decoder rejects); `ExtraToolTests`, `FaceAdjacencyTests`, `VoidBoundingBoxTests` tightened. Bundle confirmed on OKF 0.2 by hand; the hub's `okf validate --strict` would not build on the local toolchain.

## 2026-10-02

* **Update**: Rebased the OKF 0.2 router onto main (29 commits behind). Ported what main's CLAUDE.md gained since: `ExtraTool` (#196), `FaceAdjacency`/`OppositeFaces` (#199, #201), the host output-directory override in the `Paths.swift` entry (#195), the reworded `SelectionBridgeTools` entry, and the OCCTSwiftInteraction-era dependency bullets. Added the four files the catalogue had never listed (`Provenance.swift`, `AssemblyTools.swift`, `RayPickTool.swift`, `Value+NumberValue.swift`) and a current-pins table for the v1.37.1 beta line. Cleared em-dashes from the pages this bundle owns. Two invariants joined CLAUDE.md: the `swift-format --strict` gate, and the task-local `Task.detached` hazard.

## 2026-09-06

* **Update**: Bundle on OKF 0.2. CLAUDE.md became a router: 378 lines to 75. The per-file Swift catalogue, the Node server, execute_script and its template moved into components/ and references/; the history/remap writeup and the dependency-floor rationale, 230 lines between them, moved into references/.
