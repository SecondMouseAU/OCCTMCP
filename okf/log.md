# Knowledge Log

## 2026-10-07

* **Update**: CI hardening. `tests.yml` gained a `changes` job, a Node job and a `ci-gate` aggregate; `integration.yml` added for the nightly Node end-to-end run. Added `policies/prove-the-test-fails.md` (pointer to the OCCTSwift canonical text) and `references/ci.md`. Test audit: integration tests now read `result.isError` (the old `resp["error"] == nil` could not see a tool failure, and hid two `apply_feature` calls sent with camelCase keys the decoder rejects); `ExtraToolTests`, `FaceAdjacencyTests`, `VoidBoundingBoxTests` tightened. Bundle confirmed on OKF 0.2 by hand; the hub's `okf validate --strict` would not build on the local toolchain.

## 2026-10-02

* **Update**: Rebased the OKF 0.2 router onto main (29 commits behind). Ported what main's CLAUDE.md gained since: `ExtraTool` (#196), `FaceAdjacency`/`OppositeFaces` (#199, #201), the host output-directory override in the `Paths.swift` entry (#195), the reworded `SelectionBridgeTools` entry, and the OCCTSwiftInteraction-era dependency bullets. Added the four files the catalogue had never listed (`Provenance.swift`, `AssemblyTools.swift`, `RayPickTool.swift`, `Value+NumberValue.swift`) and a current-pins table for the v1.37.1 beta line. Cleared em-dashes from the pages this bundle owns. Two invariants joined CLAUDE.md: the `swift-format --strict` gate, and the task-local `Task.detached` hazard.

## 2026-09-06

* **Update**: Bundle on OKF 0.2. CLAUDE.md became a router: 378 lines to 75. The per-file Swift catalogue, the Node server, execute_script and its template moved into components/ and references/; the history/remap writeup and the dependency-floor rationale, 230 lines between them, moved into references/.
