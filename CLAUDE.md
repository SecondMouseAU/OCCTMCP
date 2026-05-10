# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MCP server that gives LLMs the ability to author, inspect, and iterate on 3D CAD models with OpenCASCADE via the OCCTSwift family. Two implementations live side-by-side:

- **Swift** (`Sources/`, `Package.swift`) — the **primary**, in-process server. Uses the official Swift MCP SDK, calls OCCTSwift / OCCTSwiftMesh / OCCTSwiftTools / OCCTSwiftAIS / DrawingComposer directly. 50 typed tools. macOS 15+.
- **Node / TypeScript** (`src/`, `dist/`) — the original implementation. Shells out to the `occtkit` CLI via `OCCTSwiftScripts`. 36 tools (the pre-v0.4 surface; selection / remap / annotations are Swift-only).

Both speak stdio MCP and read/write the same `manifest.json` + `annotations.json` files in the output directory. Pick whichever fits the host: the Swift binary eliminates JSONL marshalling and per-call subprocess spawn; the Node server runs anywhere a Node 18+ runtime exists, but needs `occtkit` on `$PATH`.

The Swift port reached **v1.0.0** on 2026-05-09 and is published on the [Swift Package Index](https://swiftpackageindex.com/gsdali/OCCTMCP).

## Build & Run

### Swift (primary)

```bash
swift build -c release         # debug build is `swift build`
swift run occtmcp-server       # stdio transport
swift test                     # 22 swift-testing cases under SwiftTests/OCCTMCPCoreTests
```

`swift test` runs unit + integration tests against a tempdir. Integration tests spawn the built `occtmcp-server` binary and drive it over stdio (so a `swift build` must precede them; the harness itself does this).

### Node

```bash
npm run build    # tsc → dist/
npm start        # node dist/index.js (stdio transport)
npm run dev      # tsc --watch
npm test                  # node:test unit tests for scene-mutation logic (no occtkit)
npm run test:integration  # node:test end-to-end chain through occtkit (slow; ~30–120s)
```

`OCCTMCP_OUTPUT_DIR` redirects manifest reads/writes to a tempdir on both paths — the test suites use this.

## Swift Architecture

`Sources/OCCTMCPCore/` (library) + `Sources/OCCTMCPServer/` (executable that connects stdio).

- `Server.swift` — `createServer()` factory: registers all 50 tools with their JSON Schemas, returns an `MCP.Server` ready to bind to a transport. Tests import `createServer()` to introspect the registry without binding stdio. The `get_api_reference` tool's `mcp_tools` category dumps the live registry as JSON Schema for LLM auto-discovery.
- `Tools/` — one file per tool family:
  - `CoreTools.swift` — `get_scene`, `get_script`, `export_model`, `get_api_reference`
  - `ExecuteScriptTool.swift` — `execute_script` (writes Swift to tempfile, `occtkit run` via the resolved binary, parses manifest)
  - `SceneTools.swift` — `remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`, `export_scene` (pure manifest manipulation; `export_scene` runs a templated script via occtkit)
  - `IntrospectionTools.swift` — `validate_geometry`, `compute_metrics`, `query_topology`, `measure_distance` (in-process via OCCTSwift)
  - `FeatureTools.swift` — `recognize_features`, `apply_feature`
  - `ConstructionTools.swift` — `transform_body`, `boolean_op`, `mirror_or_pattern` (record history into `HistoryRegistry`)
  - `EngineeringTools.swift` — `check_thickness`, `analyze_clearance`
  - `HealingTools.swift` — `heal_shape` (records identity history if topology preserved)
  - `IOTools.swift` — `read_brep`, `import_file`, `inspect_assembly`, `set_assembly_metadata`
  - `MeshTools.swift` — `generate_mesh`, `simplify_mesh`
  - `RenderPreviewTool.swift` — `render_preview` (depends on Tools+Viewport per the layered architecture; reads annotations sidecar and overlays measurements / primitives via `AnnotationsRenderer`)
  - `DrawingTools.swift` — `generate_drawing`
  - `AnalysisTools.swift` — graph-level: `graph_validate`, `graph_compact`, `graph_dedup`, `graph_ml`, `feature_recognize`
  - `SelectionTools.swift` — `select_topology`
  - `RemapTools.swift` — `remap_selection` (consults `HistoryRegistry`, falls back to centroid heuristic)
  - `AnnotationsTools.swift` — `add_dimension`, `add_scene_primitive`, `remove_scene_annotation`
  - `GapFillerTools.swift` — `show_bounding_box`, `diff_overlay`, `select_by_feature`
  - `IntrospectionRegistryTools.swift` — `list_selections`, `clear_selections`, `list_annotations`
  - `AutoDimensionTool.swift` — `auto_dimension`
- `Manifest.swift` — `ScriptManifest` + `BodyDescriptor` Codable, plus `ManifestStore` (atomic JSON read/write)
- `Annotations.swift` — `AnnotationsSidecar` (`<output_dir>/annotations.json`): `dimensions[]` + `primitives[]`, `AnyCodable` for per-kind primitive params
- `AnnotationsRenderer.swift` — synthesises `ViewportBody` overlays from the sidecar (trihedron / workPlane / axis / pointCloud / boundingBox / diffMarker / 3D dimension leaders), and `ViewportMeasurement` entries (linear / angular / radial) for OffscreenRenderer's 2D label overlay. `pointCloud` routes through `OCCTSwiftTools.PointConverter.pointsToBody` (no per-point cap).
- `SelectionRegistry.swift` — actor-backed store of `selectionId → AnchorSnapshot`. `selectionId` format `sel:<bodyId>#<kind>[<idx>]` is self-describing and parseable.
- `HistoryRegistry.swift` — actor-backed `bodyId → TopologyGraph`. `recordIdentityHistory` (transforms — 1:1), `recordIdentityHistoryIfTopologyPreserved` (heals — guarded), `recordBooleanHistory` (boolean_op — translates `ShapeHistoryRef.record(of:)` outputs into `recordHistory` entries by centroid match within the modified∪generated set; records under result body and both inputs so a selectionId on either side remaps cleanly). `apply_feature` / `mirror_or_pattern` don't opt in yet — they fall back to `RemapTools`' centroid heuristic.
- `Paths.swift` — output dir resolution: `OCCTMCP_OUTPUT_DIR` env > iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) > local fallback (`~/.occtswift-scripts/output/`)
- `SceneHistory.swift` — in-memory ring buffer (last 10 manifest snapshots) backing `compare_versions`

`OCCTMCPServer/main.swift` connects `createServer()` to stdio.

### Layered architecture (post-Tools / AIS split)

OCCTSwift / OCCTSwiftViewport are kernel layers. `OCCTSwiftTools` is the bridge (Shape ↔ ViewportBody, plus Curve / Surface / Wire / **Point** converters). `OCCTSwiftAIS` is the interactive-services layer (selection, manipulators, dimensions). `render_preview` depends on **Tools + Viewport**. The whole cohort is now aligned at v1.0.x — Tools / AIS / Scripts v1.0 graduated their Viewport floors to 1.0.x, so the v0.10–v1.1 hold at Viewport 0.55.x is gone.

### History wiring (selectionId remap across mutations)

`remap_selection` resolves a `selectionId` against the post-mutation state of a body via:

1. `HistoryRegistry.graph(for: bodyId)` — if recorded, call `TopologyGraph.findDerivedOrSelf(originalRef:)` (OCCTSwift v1.1.0+):
   - Non-empty derivatives → fate ∈ {preserved, split}, confidenceMm = 0.
   - Empty result → explicitly recorded as deleted, fate = lost.
   - `[self]` (no record at all) → preserved at same index, confidenceMm = 0.
2. Centroid heuristic — load pre and post BREPs, find nearest face/edge/vertex within an epsilon. fate is preserved if within ε, lost otherwise. confidenceMm reports the centroid distance.

`recordSingleInputHistory` and `recordBooleanHistory` skip writing identity records (`original → [original]`) so they fall through to the implicit `[self]` branch above. Without this, an OCCT-reported "modified to same index" would be conflated with an explicit delete by `findDerivedOrSelf`.

Per-tool opt-in status:

| Tool             | History path                              | Notes |
|------------------|-------------------------------------------|-------|
| `transform_body` | implicit identity (no records written)    | every node maps 1:1; `findDerivedOrSelf` returns `[self]` |
| `heal_shape`     | implicit identity if pre/post counts match | falls back to heuristic if shape repair changed topology |
| `boolean_op`     | per-input history via `recordBooleanHistory` | OCCTSwift `*WithFullHistory` variants; recorded under output + both inputs |
| `apply_feature`  | per-feature history via `recordSingleInputHistory` | OCCTSwift v1.0.4 `FeatureReconstructor.BuildResult.histories[id]` — every spec kind (boolean / hole / second-additive / fillet / chamfer) populates a `ShapeHistoryRef` when the spec carries a non-nil id |

`mirror_or_pattern` doesn't fit `remap_selection`'s contract (it produces new bodies rather than mutating in place). For that case use `find_correspondences`, which takes a source body and target body and applies a transform to each source anchor's centroid before nearest-neighbour search on the target. Pure geometry, no OCCT history involved — pattern instances aren't OCCT-derivatives of the source.

`find_correspondences`'s `transform` is optional. Resolution order:
1. **Explicit hint** — `translate` / `mirror` / `rotate` / `compound { steps: [...] }` (the last one is a recursive composition applied in array order). Codable, so the same JSON shape works in tool args and on disk.
2. **`<output_dir>/provenance.json`** — `mirror_or_pattern` writes its mirror plane here for every output body it produces. (Linear / circular patterns produce N copies, which don't fit the single-target return shape, so they're skipped.)
3. **Bbox-translation inference** — if source and target bbox sizes match, transform is the centroid delta. Catch-all for `execute_script`-built duplicates that didn't record anything.

The response includes `transformSource ∈ {explicit, provenance, bbox-inference, identity-fallback}` so callers can tell which path resolved.

### Data flow for `execute_script`

1. Writes the LLM's Swift code to a per-call tempfile under `os.tmpdir()` and stashes the source for `get_script`.
2. Calls `occtkit run <tempfile>` via the resolved binary (PATH > sibling-repo `swift run -c release occtkit`). Cold start of the underlying SwiftPM workspace is 60+s on first call; subsequent calls amortise via OCCTSwiftScripts' serve mode where available.
3. Filters noisy OCCT bridge nullability warnings from build output; compiler diagnostics still reach the LLM under the `Script failed.` prefix.
4. Reads `manifest.json` from the output directory and returns it with build output. `executeScript` calls `snapshotScene()` before running so `compare_versions` has history.
5. Removes the tempfile in a `finally` block.

Writing `manifest.json` is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so emitting it triggers the live 3D reload.

The 2 min timeout is per-request.

## Node Architecture

The Node server is a single-process Node.js app (ESM, strict TypeScript):

- `src/index.ts` — `createServer()` factory + stdio binding
- `src/tools.ts` — Core: `execute_script`, `get_scene`, `get_script`, `export_model`, `get_api_reference`. Delegates to a long-lived `occtkit run --serve` child by default, falls back to one-shot `occtkit run <path>` if serve mode is unavailable
- `src/scene-tools.ts` — Pure-TS scene-mutation tools (`remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`, `export_scene`). `export_scene` is the exception: generates a one-shot Swift script run via `occtkit run`. Maintains an in-memory ring buffer of the last 10 manifest snapshots for `compare_versions`
- `src/api-tools.ts` — Wrappers around occtkit verbs (`validate_geometry` → `graph-validate`, `recognize_features` → `feature-recognize`, `apply_feature` → `reconstruct`, `generate_drawing` → `drawing-export`)
- `src/verb-tools.ts` — Wrappers around the rest of the occtkit verbs (compute_metrics / query_topology / measure_distance / check_thickness / analyze_clearance / generate_mesh / transform_body / boolean_op / mirror_or_pattern / heal_shape / read_brep / import_file / render_preview)
- `src/occtkit.ts` — Resolves how to invoke `occtkit`: prefers PATH, falls back to `swift run -c release occtkit` inside the sibling OCCTSwiftScripts repo
- `src/occtkit-serve.ts` — Singleton long-lived `occtkit run --serve` child. JSONL request/response over stdin/stdout. Per-request timeout kills the child and respawns on next call
- `src/paths.ts` — Same resolution rules as the Swift `Paths.swift`
- `src/api-reference.ts` — **Generated** OCCTSwift API reference, rewritten by `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`). Parses `~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift` and groups public funcs via the editorial `CATEGORIES` array. New OCCTSwift methods that don't match any category are surfaced in the generator's stderr "UNMATCHED" report — extend `CATEGORIES` (add a `markRx` or `nameRx` rule) when something important is missing.

The Node server does not expose the v0.4+ tool surface (selection / remap / annotations / history). Those are Swift-only.

## External Dependencies

### Swift implementation

- **OCCTSwift** ≥ 1.1.0 — kernel wrapper around OpenCASCADE; full per-input history coverage for booleans + every `FeatureSpec` kind in `BuildResult.histories[id]`, plus `TopologyGraph.findDerivedOrSelf` / `hasHistoryRecord` for unambiguous untouched-vs-deleted resolution
- **OCCTSwiftMesh** ≥ 1.0.0 — mesh-domain algorithms (QEM decimation today; smoothing / repair / remeshing in roadmap)
- **OCCTSwiftScripts** ≥ 1.0.2 — provides `occtkit` (only used by `execute_script` and `export_scene`); also ships `ScriptHarness` + `DrawingComposer` consumed in-process
- **OCCTSwiftTools** ≥ 1.1.0 — Shape↔ViewportBody bridge; ships `PointConverter` and wires `pointRadius` / `vertexColors` through to `ViewportBody`
- **OCCTSwiftViewport** ≥ 1.0.2 — Metal viewport + offscreen renderer; v1.0.2 added the point-sprite pipeline that makes `pointCloud` overlays actually render
- **OCCTSwiftAIS** ≥ 1.0.1 — selection, manipulators, dimensions
- **modelcontextprotocol/swift-sdk** ≥ 0.11.0 — MCP transport + types

### Node implementation

- **OCCTSwiftScripts** — provides `occtkit` on `$PATH` (`make install` from the OCCTSwiftScripts repo) or via sibling clone at `~/Projects/OCCTSwiftScripts` so `swift run -c release occtkit` works as the fallback
- **OCCTSwift** — required at `~/Projects/OCCTSwift/` only when regenerating `src/api-reference.ts` via `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`)
- **OCCTSwiftViewport** — Metal viewport that watches the output directory via `ScriptWatcher` and auto-reloads. Optional but expected if you want the live preview

## MCP Tools

50 tools across both implementations (Swift); 36 in Node (no selection / remap / annotations / history). See README.md for the categorized table — that's the LLM-facing surface and stays canonical.

## Script Template

Scripts passed to `execute_script` must follow this structure:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ... create geometry using OCCTSwift API ...

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "Description of the model")
```
