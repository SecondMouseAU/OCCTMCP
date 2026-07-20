# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MCP server that gives LLMs the ability to author, inspect, and iterate on 3D CAD models with OpenCASCADE via the OCCTSwift family. Two implementations live side-by-side:

- **Swift** (`Sources/`, `Package.swift`) — the **primary**, in-process server. Uses the official Swift MCP SDK, calls OCCTSwift / OCCTSwiftMesh / OCCTSwiftTools / OCCTSwiftAIS / DrawingComposer directly. 63 typed tools. macOS 15+.
- **Node / TypeScript** (`src/`, `dist/`) — the original implementation. Shells out to the `occtkit` CLI via `OCCTSwiftScripts`. 37 tools (the pre-v0.4 surface; selection / remap / annotations are Swift-only).

Both speak stdio MCP and read/write the same `manifest.json` + `annotations.json` files in the output directory. Pick whichever fits the host: the Swift binary eliminates JSONL marshalling and per-call subprocess spawn; the Node server runs anywhere a Node 18+ runtime exists, but needs `occtkit` on `$PATH`.

The Swift port reached **v1.0.0** on 2026-05-09 and is published on the [Swift Package Index](https://swiftpackageindex.com/gsdali/OCCTMCP).

## Build & Run

### Swift (primary)

```bash
swift build -c release         # debug build is `swift build`
swift run occtmcp-server       # stdio transport
swift test                     # 60 swift-testing cases under SwiftTests/OCCTMCPCoreTests
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

- `Server.swift` — `createServer()` factory: registers all 63 tools with their JSON Schemas, returns an `MCP.Server` ready to bind to a transport. Tests import `createServer()` to introspect the registry without binding stdio. The `get_api_reference` tool's `mcp_tools` category dumps the live registry as JSON Schema for LLM auto-discovery.
- `Tools/` — one file per tool family:
  - `CoreTools.swift` — `get_scene`, `get_script`, `export_model`, `get_api_reference`
  - `ExecuteScriptTool.swift` — `execute_script` (writes Swift to tempfile, `occtkit run` via the resolved binary, parses manifest)
  - `SceneTools.swift` — `remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`, `export_scene` (pure manifest manipulation; `export_scene` runs a templated script via occtkit)
  - `IntrospectionTools.swift` — `validate_geometry`, `compute_metrics`, `query_topology`, `measure_distance` (in-process via OCCTSwift)
  - `DeviationTools.swift` — `measure_deviation` (meshes both bodies, KD-tree → exact point-to-triangle distance both directions. As of #62 the report is a *vector*: max / rms / mean / p95 / `signedMean` (+ proud / − shy) / signedMin/Max, plus an optional per-section signedMean sweep when `sectionAxis`+`sections` is given. Also the shared signed-distance engine (`TriMesh`, `signedQuery`, `signedDistances`, `closestPointOnTriangle`) reused by every other signed diagnostic. The certify-a-reconstruction metric `measure_distance` can't give since it's min-only — #41/#62). **`SignMode` (#72)**: the sign comes from whichever reference triangle a sample is judged against, and taking the *nearest* one breaks against an open thin-walled reference — a flank 4.5 inside a 2 wall is only 2.5 from the wall's inner surface, which therefore wins and (facing the cavity) reports +2.5 proud for a 4.5-shy part, confidently and untied, so #74's coin-flip guard never fires. Default `.robust` gates the correspondence on normal agreement (`signedQuery` takes the sample's OWN outward normal — `TriMesh.vertexNormal` for vertex samples, the winding normal for the heatmap's per-triangle centroids — and rejects reference triangles whose normal opposes it); if the whole k-neighbourhood is the far wall it widens once to `widenedK`, and if no compatible surface is in reach the sample is flagged `ambiguous`. `.nearest` restores pre-1.17 behaviour. **`SignedHit` carries two distances and they must not be conflated**: `nearest` (closest surface, full stop) backs the unsigned figures (max/rms/mean/p95/worstPoint/symmetricHausdorff/maxAbs/withinTolerance) so `signMode` never moves them — they mean in 1.17 what they meant before; `signed` backs the sign channel (signedMean/Min/Max, `sectionize`, buckets, heatmap colour) and is the distance to the CORRESPONDING surface, so `abs(signed) ≥ nearest` under `.robust`. `max: 2.5` beside `signedMin: −4.5` is correct and diagnostic, not a bug. Signed aggregates use sign-reliable samples only and are **nil** when none are (zero would read as "perfectly centred"); `sectionize` still takes its axis span from ALL samples so `offset` doesn't re-base. `ambiguousFraction` ≈ 1.0 ⇒ the reference's winding is likely inverted relative to the sampled body. Sizing gotcha: these meshes are unshared triangle soups (3 verts per triangle, no sharing — 576 tris ⇒ 1728 verts), so `widenedK` must be several × what a shared-index mesh would need; 256 was silently too small and greyed out the very case the gate exists to fix
  - `DeviationHistogramTool.swift` — `deviation_histogram` (#62): signed point-to-surface distribution (μ/σ/median/p95/extremes, percent-within-±tol, buckets) + optional histogram PNG. Takes `signMode` (#72); the distribution and its buckets are built from sign-reliable samples only — a flipped sign plants a mirror hump at −d and reads as exactly the bimodal systematic error this tool exists to spot — while magnitude-only figures (p95 / maxAbs / withinTolerance) keep every sample
  - `CrossSectionCompareTool.swift` — `cross_section_compare` (#61): slices BOTH bodies (meshed) with the SAME `OCCTSwiftMesh.Mesh.crossSection` `CutPlane` at N stations along a shared axis — identical (u,v) basis ⇒ directly comparable 2D profiles — per-section signedMean/RMS/area-ratio/centroid-offset + a pose-robust radial-signature shape scalar, with overlay PNGs. The detector for a systematic wrong-section. Stations span the two bodies' shared axis-extent overlap (reported as `overlap`); a section may be a closed contour OR an open polyline, so an open-shell reference (raw scan / STL skin) whose sections are open arcs still produces a comparison instead of reading as un-sliced — #66 (the fix falls back to the longest open path, flags open-profile stations, and warns on stations that sliced only one body). #70 (v2): default `outerEnvelope` mode compares the candidate against the reference's OUTER boundary per angular sector (radial max about the reference centroid, gap-filled across openings) so inner window-return / frame paths of a thin-wall / scanned part stop polluting the aggregate; `outerEnvelope:false` restores raw point-to-main-loop. Each station also reports `axisCoord` (world position along the axis, not just overlap-relative `offset`), and `envelopeShapeL2` gives a shape scalar that's defined for open profiles too
  - `HeatmapTools.swift` — `signed_deviation_heatmap` + `overlay_render` (#63): the heatmap colours per-triangle signed distance via the diverging colormap by grouping a band's triangles into one flat-coloured `ViewportBody` (OffscreenRenderer has no per-triangle/per-vertex *surface* colour pass — only the point pass reads `vertexColors`), then composites a colorbar legend; `overlay_render` draws the reference mesh translucent (OffscreenRenderer's transparent pass: effective opacity < 1) over the opaque solid. #72 (two parts): #74 made `signedQuery` return `ambiguous` when a comparably-close candidate triangle disagrees on side, and the heatmap renders those grey instead of red/blue, excluded from `signedMin`/`signedMax`/`signedMean` and reported as `ambiguousTriangles`/`ambiguousFraction`. That covers genuine ties but NOT the reported case — an inner wall winning by a clear margin ties with nothing, so it stayed red. The v1.17.0 half adds the `signMode` correspondence gate in `DeviationTools` (see above); the heatmap passes each triangle's winding normal as the sample normal and grey now also means "no compatible reference surface in reach". A mostly-grey render ⇒ trust the magnitude or `cross_section_compare`, not the sign
  - `ChartRenderer.swift` — pure-Swift Core Graphics + Core Text PNG helper (histogram, 2D profile overlay, colorbar legend) and the shared diverging colormap. Headless; no Python/matplotlib, no AppKit
  - `FeatureTools.swift` — `recognize_features`, `apply_feature`
  - `ConstructionTools.swift` — `transform_body`, `boolean_op`, `mirror_or_pattern` (record history into `HistoryRegistry`)
  - `EngineeringTools.swift` — `check_thickness`, `analyze_clearance`
  - `HealingTools.swift` — `heal_shape` (records identity history if topology preserved)
  - `IOTools.swift` — `read_brep`, `import_file`, `inspect_assembly`, `set_assembly_metadata`
  - `MeshTools.swift` — `generate_mesh`, `simplify_mesh`
  - `RenderPreviewTool.swift` — `render_preview` (depends on Tools+Viewport per the layered architecture; reads annotations sidecar and overlays measurements / primitives via `AnnotationsRenderer`). #75: shapes above `meshDirectEdgeThreshold` (10k edges — an STL lands as one face per facet, so a 442k-tri scan is ~1.3M edges) bypass `shapeToBodyAndMetadata` and take `meshDirectBody` instead: tessellation-only, crease-smoothed, linear. Historically that guarded the O(edges²) per-edge extraction hang; since OCCTSwift 1.10.0 + OCCTSwiftTools 1.3.1 (OCCTSwift#275) both paths are linear, and the threshold guards weight only (per-segment pick indices / B-rep vertex arrays / polyline allocations nothing consumes at scan scale). Edge overlays on the mesh-direct path come from the O(edges) bulk `allEdgePolylines` (dense — render/raycast never consume per-edge pick indices) up to `edgeOverlayCap` (100k edges); beyond the cap bodies render surface-only (facet wireframe = noise + memory churn). `pick_surface_point` and `overlay_render` route through the same `viewportBody(for:)` guard. #76 step 3: sub-threshold B-reps pass `directMesh: true` to Tools (skips interleave + NormalSmoothing — analytic normals need neither) unless `isLikelyFacetShell` (E/F ratio outside 1.85–2.55 at ≥64 faces: sewn soups ≈1.5, unsewn ≈3.0) says the body needs the smoothing weld; `AnnotationsRenderer` primitives are always direct
  - `DrawingTools.swift` — `generate_drawing`
  - `AnalysisTools.swift` — graph-level: `graph_validate`, `graph_compact`, `graph_dedup`, `graph_ml`, `feature_recognize`
  - `SelectionTools.swift` — `select_topology`. #91: the index embedded in a `selectionId` (`sel:<bodyId>#face[<idx>]`) has to be a `BRepGraph` node index — that's what `RemapTools.remapViaHistory` feeds into `findDerivedOrSelf(of:)` — not a raw `Shape.faces()/.edges()/.vertices()` enumeration index. Those turned out NOT to be the same index space for edges/vertices (verified false on a plain box — `TopologyIdentityTests`; true only for faces, apparently by coincidence). `SelectionTools.graphIndex(for:kind:in:fallback:)` resolves the real graph index via `BRepGraph.findNode(for:)` for every kind
  - `RemapTools.swift` — `remap_selection` (consults `HistoryRegistry`, falls back to centroid heuristic). The centroid-heuristic path also mints selectionIds (via `pickClosest` → `registry.record`), so `remapOne` uses the same `SelectionTools.graphIndex(...)` resolution as `select_topology` — both selectionId-minting paths have to agree on the graph-index convention (#91)
  - `AnnotationsTools.swift` — `add_dimension`, `add_scene_primitive`, `remove_scene_annotation`
  - `GapFillerTools.swift` — `show_bounding_box`, `diff_overlay`, `select_by_feature`
  - `IntrospectionRegistryTools.swift` — `list_selections`, `clear_selections`, `list_annotations`
  - `AutoDimensionTool.swift` — `auto_dimension`
  - `ReconstructTools.swift` — `reconstruct_get_graph`, `reconstruct_set_decision`, `reconstruct_force_fit`, `reconstruct_confirm_instances`, `reconstruct_export_session`, `reconstruct_import_session` (LLM read/write over the attributed reconstruction graph; #33)
- `ReconstructRegistry.swift` — actor-backed `sessionId → BRepGraph`. Holds the per-node attribute overlay (OCCTSwift 1.2.0 `NodeAttributeStore`) for a reconstruction session; all graph reads/writes are actor-isolated. `reconstruct.*` namespaced keys (`decidedBy`, `accepted`, `forcedSurfaceType`, `instanceCluster`, `instanceConfirmed`). Nodes addressed as `<kind>:<index>`. The reconstruction *engine* (fitting, congruence) lives in OCCTReconstruct — `force_fit` records an override, it does not re-fit. Persistence via `BRepGraph.snapshot()` / `GraphSnapshot` round-trip.
- `Manifest.swift` — `ScriptManifest` + `BodyDescriptor` Codable, plus `ManifestStore` (atomic JSON read/write)
- `Annotations.swift` — `AnnotationsSidecar` (`<output_dir>/annotations.json`): `dimensions[]` + `primitives[]`, `AnyCodable` for per-kind primitive params
- `AnnotationsRenderer.swift` — synthesises `ViewportBody` overlays from the sidecar (trihedron / workPlane / axis / pointCloud / boundingBox / diffMarker / 3D dimension leaders), and `ViewportMeasurement` entries (linear / angular / radial) for OffscreenRenderer's 2D label overlay. `pointCloud` routes through `OCCTSwiftTools.PointConverter.pointsToBody` (no per-point cap).
- `SelectionRegistry.swift` — actor-backed store of `selectionId → AnchorSnapshot`. `selectionId` format `sel:<bodyId>#<kind>[<idx>]` is self-describing and parseable.
- `HistoryRegistry.swift` — actor-backed `bodyId → LineageEntry { graph, liveShape, root, fingerprint }`. As of #90/#91/#93 full completion, a body's `BRepGraph` is **retained across successive mutations** rather than rebuilt disposably per call: `currentInput(bodyId:path:)` re-stats the body's file and returns the cached `(shape, graph, root)` on a fingerprint match. No disk read: critical, since `add(_:absorbing:...)`'s absorb correlates by `TShape` object identity, and `Shape.loadBREP` mints a new `TShape` tree every call even for byte-identical content. It reloads fresh on any mismatch (first touch, or an out-of-band rewrite, e.g. `execute_script`). `commit(bodyId:path:output:ref:from:operationName:)` absorbs `ref` into the retained graph and returns `true` (continuation) when `historyRecordCount` actually grows, else falls back to a **generation reset**, a fresh graph built from `output` alone, and returns `false`. `absorb(into:root:output:ref:operationName:)` is the same primitive without a registry write, for the side of a shared-graph mutation whose own file is unchanged (boolean_op's b-side). `graph.add(...)`'s returned NodeRef is never trusted directly: `trackableRoot(for:in:)` re-resolves via `findNode(for:)` and drills a `.compound` result down to its wrapped `.solid` child, since `add(_:absorbing:...)` only tracks vertex/edge/face/solid nodes and boolean/`FeatureReconstructor` outputs register as `.compound` even for single-solid results. Since `BRepGraph` is a reference type, a graph shared across two `LineageEntry` keys (boolean_op's `outId` plus `aBodyId`; `apply_feature`'s output body plus its unchanged source body) mutates in place for both the instant `add()` runs, so no second registry write is needed for the side whose file didn't change. **Known gap:** chaining a SECOND `*WithFullHistory` op onto the *output* of a prior one (rather than a freshly-loaded shape) currently absorbs zero records regardless of retention: [SecondMouseAU/OCCTSwift#336](https://github.com/SecondMouseAU/OCCTSwift/issues/336). A body mutated twice in a row still degrades to a generation reset on hop 2 today; single-hop absorption is unaffected. See `HistoryRegistryLineageTests.swift` (in-process, asserts on `graph.instanceID`/`graph.contains(uid:)` directly, the rigorous check; the two-hop hop-2 assertions are wrapped in `withKnownIssue` pending #336) and `IntegrationTests.swift`'s two-hop test (black-box; proves `remap_selection` stays correct end-to-end but can't distinguish genuine chaining from a lucky generation-reset fallback, since both report `confidenceMm: 0`).
- `Paths.swift` — output dir resolution: `OCCTMCP_OUTPUT_DIR` env > iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) > local fallback (`~/.occtswift-scripts/output/`)
- `SceneHistory.swift` — in-memory ring buffer (last 10 manifest snapshots) backing `compare_versions`

`OCCTMCPServer/main.swift` connects `createServer()` to stdio.

### Layered architecture (post-Tools / AIS split)

OCCTSwift / OCCTSwiftViewport are kernel layers. `OCCTSwiftTools` is the bridge (Shape ↔ ViewportBody, plus Curve / Surface / Wire / **Point** converters). `OCCTSwiftAIS` is the interactive-services layer (selection, manipulators, dimensions). `render_preview` depends on **Tools + Viewport**. The whole cohort is now aligned at v1.0.x — Tools / AIS / Scripts v1.0 graduated their Viewport floors to 1.0.x, so the v0.10–v1.1 hold at Viewport 0.55.x is gone.

### History wiring (selectionId remap across mutations)

`select_topology` resolves through `HistoryRegistry.currentInput(bodyId:path:)` rather than a
disposable per-call graph. This establishes (or reuses) the SAME retained graph a later
history-aware mutation will absorb into, and mints a `BRepGraph.GraphUID` per anchor
(`SelectionRegistry.recordGraphUID`), a side-table keyed by selectionId (not a field on
`AnchorSnapshot`, which is `Encodable` straight into LLM-facing responses).

`remap_selection` resolves a `selectionId` against the post-mutation state of a body via three
rungs, most-preferred first:

1. **GraphUID** (#93): `registry.graphUID(for: id)` then `historyRegistry.graph(for: bodyId).node(forUID:)`,
   then the same `findDerivedOrSelf` walk as rung 2. Preferred because a UID survives index
   renumbering within the graph across multiple hops, unlike a selectionId's embedded literal
   index. Falls through to rung 2 if the UID doesn't resolve (e.g. it was minted from a
   disposable graph, or by a call site that doesn't mint UIDs yet).
2. **Recorded history graph, anchor's embedded index**: `HistoryRegistry.graph(for: bodyId)` then
   `BRepGraph.findDerivedOrSelf(of:)`:
   - Non-empty derivatives: fate in {preserved, split}, confidenceMm = 0.
   - Empty result: explicitly recorded as deleted, fate = lost.
   - `[self]` (no record at all): preserved at same index, confidenceMm = 0. This is also what a
     **generation reset** looks like from the outside; a fresh graph with zero history records
     resolves every node to `[self]` unconditionally, which is indistinguishable from genuine
     "untouched" through this API alone (see the `HistoryRegistry.swift` bullet above re #336).
3. **Centroid heuristic** (unchanged, last resort): load pre and post BREPs, find nearest
   face/edge/vertex within an epsilon. fate is preserved if within ε, lost otherwise.
   confidenceMm reports the centroid distance.

After any rung-1/rung-2 (history-based) remap, `RemapTools.refreshAfterHistoryRemap` re-mints a
fresh GraphUID for the new anchor **from the retained lineage graph only**, never from the
disposable `currentGraph` rung 3 uses, so a multi-hop remap chain stays UID-exact instead of
degrading to rung 2 (or rung 3) after one hop.

Per-tool history path, via `HistoryRegistry.currentInput`/`commit`/`absorb`:

| Tool             | History path                              | Notes |
|------------------|-------------------------------------------|-------|
| `transform_body` | generation reset (`commit(ref: nil)`)     | no `*WithFullHistory` variant wired in yet: OCCTSwift#331 (shipped v1.14.0) added `translated`/`rotated`/`scaled`/`mirrored`/pattern `*WithFullHistory` upstream, but OCCTMCP hasn't switched this call site over |
| `heal_shape`     | real history via `healedWithFullHistory()` (OCCTSwift v1.13.0/#327) | falls back to plain `healed()` + generation reset if the `*WithFullHistory` variant returns nil, or its absorb doesn't grow `historyRecordCount` |
| `boolean_op`     | per-input history via `HistoryRegistry.recordBooleanHistory` | two independent graphs (NodeRefs/GraphUIDs are graph-scoped): a-side's graph becomes `outId`'s canonical graph too (`commit`, writes an entry); b-side only needs `absorb` (no entry write; `bBodyId`'s own file is unchanged, so writing one would overwrite its liveShape/fingerprint with the OTHER side's output) |
| `apply_feature`  | per-feature history via `commit`, chained via `absorb` if `result.histories` has >1 entry | absorbs ONCE per graph object regardless of in-place vs new-`outputBodyId`: the source body's own entry (when different from the mutated one) shares the SAME graph object reference (`BRepGraph` is a reference type) and sees the absorbed history for free, no second write |
| `mirror_or_pattern` | generation reset for the output body only; source body's entry untouched | same #331 gap as `transform_body`; source's file didn't change so its lineage stays as-is |

`mirror_or_pattern` also doesn't fit `remap_selection`'s contract (it produces new bodies rather than mutating in place). For that case use `find_correspondences`, which takes a source body and target body and applies a transform to each source anchor's centroid before nearest-neighbour search on the target. Pure geometry, no OCCT history involved: pattern instances aren't OCCT-derivatives of the source.

**Persistence caveat:** `BRepGraph.GraphUID` is `Codable` but **instance-scoped**: it does not
survive `GraphSnapshot` restore or a process restart (a rebuild mints a new `instanceID`; re-mint
from `(kind, index)` after reloading). A retained graph's `snapshot()` also serializes the
*pre-mutation* `sourceBREP` captured at construction, not updated by later `add()` calls.

**Cross-referencing hazard:** `query_topology` / `check_thickness` emit informational
`face[i]`/`edge[i]` labels in `Shape.faces()`/`.edges()` **enumeration order**, not `BRepGraph`
node-index order: the same divergence `TopologyIdentityTests` proves for edges/vertices. Don't
feed those labels' indices into a `selectionId` by hand; they're a different index space.

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

- **OCCTSwift** ≥ 1.15.0: kernel wrapper around OpenCASCADE. **v1.15.0 renamed `TopologyGraph` to
  `BRepGraph`** (OCCTSwift#333, filed and shipped same-day; old name kept as a deprecated
  typealias for one or more releases, but OCCTMCP has already migrated every reference). v1.14.0
  adds `*WithFullHistory` for `translated`/`rotated`/`scaled`/`mirrored`/`linearPattern`/
  `circularPattern` (OCCTSwift#331), not yet wired into `transform_body`/`mirror_or_pattern`,
  which still do a generation reset. v1.13.0 adds `*WithFullHistory` for heal/sew/quilt/solid
  (OCCTSwift#327): `heal_shape` now records real history instead of the old topology-count
  heuristic. **Known gap (OCCTSwift#336):** a `*WithFullHistory` op chained onto the OUTPUT of a
  prior `*WithFullHistory` op (rather than a freshly-loaded `Shape`) currently absorbs zero
  records, verified independent of OCCTMCP's own code (reproduces against a brand-new
  `BRepGraph`), so a body mutated twice in a row still degrades to a generation reset on the
  second hop; see the `HistoryRegistry.swift` bullet above. v1.12.0 adds
  `BRepGraph.add(_:absorbing:inputRoots:operationName:)`, which imports a `*WithFullHistory` op's
  real `BRepTools_History` into the graph in one call (OCCTSwift#290): `HistoryRegistry` builds a
  RETAINED graph from a body's lineage and absorbs each mutation into it directly (#90/#91/#93;
  originally a disposable per-call graph rebuilt from scratch every time, and before that
  hand-correlating output sub-shapes to input sub-shapes by nearest centroid, which could
  misassign under symmetric/patterned geometry, the same failure family #72 guards against for
  signed distance). v1.10.1 rebuilds OCCT with the OCCTSwift#280 kernel fix (an XDE STEP read —
  `inspect_assembly` — used to silently corrupt every later STEP write — `export_scene` —
  dropping faces on indirect surfaces while still reporting valid); v1.9.0 makes the bulk
  `allEdgePolylines` O(edges) and v1.10.0 adds `allEdgePolylinesIndexed` (OCCTSwift#275 — consumed
  by `render_preview`'s mesh-direct edge overlays and, via Tools 1.3.1, every
  `shapeToBodyAndMetadata` call); full per-input history coverage for booleans + every
  `FeatureSpec` kind in `BuildResult.histories[id]`, plus `BRepGraph.findDerivedOrSelf` /
  `hasHistoryRecord` for unambiguous untouched-vs-deleted resolution. v1.2.0 adds the `BRepGraph`
  per-node attribute store (`attributes` / `setAttribute` / `attribute`, closed `AttrValue` enum)
  and Codable `GraphSnapshot` round-trip (`snapshot()` / `init(snapshot:)`) backing the
  `reconstruct_*` tool group (#33). v1.8.0 adds `Exporter.writeBREP(allowInvalid:)` backing
  `read_brep` / `import_file`'s `allowInvalid` (#41)
- **OCCTSwiftMesh** ≥ 1.0.0: mesh-domain algorithms (QEM decimation today; smoothing / repair / remeshing in roadmap)
- **OCCTSwiftScripts** ≥ 1.5.1: provides `occtkit` (only used by `execute_script` and `export_scene`); also ships `ScriptHarness` + `DrawingComposer` consumed in-process. `ExecuteScriptTool.scriptsPin` must track this pin (#42) and points at the SecondMouseAU URL. v1.5.0 capped its own OCCTSwiftIO dependency to `<1.1.0`, conflicting with OCCTSwiftTools ≥1.6.1's own OCCTSwiftIO `>=1.7.0` requirement (below) and making the two unresolvable together; fixed in v1.5.1 (raises the OCCTSwiftIO floor to 1.7.5), closing SecondMouseAU/OCCTSwiftScripts#80
- **OCCTSwiftTools** ≥ 1.6.1: Shape↔ViewportBody bridge; ships `PointConverter` and wires `pointRadius` / `vertexColors` through to `ViewportBody`. v1.6.1 renamed `TopologyGraph` to `BRepGraph` (OCCTSwift#333) and re-pins OCCTSwift to ≥1.15.0; v1.3.1 makes `extractEdgePolylines` (inside every `shapeToBodyAndMetadata`) a single O(edges) bulk pass via `allEdgePolylinesIndexed` (OCCTSwift#275 Tools half)
- **OCCTSwiftViewport** ≥ 1.1.23: Metal viewport + offscreen renderer; v1.0.2 added the point-sprite pipeline that makes `pointCloud` overlays actually render; v1.1.23 adds the opt-in `ViewportBody.directMesh` path (de-interleaved position/normal GPU buffers, normals verbatim, no NormalSmoothing) used by `HeatmapTools`' band bodies (#76). `RenderPreviewTool.meshDirectBody` stays on the interleaved layout on purpose: facet-per-face STL imports need the smoothing pass
- **OCCTSwiftAIS** ≥ 1.3.1: selection, manipulators, dimensions. v1.3.1 renamed `TopologyGraph` to `BRepGraph` (OCCTSwift#333) and requires OCCTSwiftTools ≥1.6.1
- **OCCTSwiftIO** ≥ 1.7.0: transitive dependency of OCCTSwiftScripts / OCCTSwiftTools (BREP/STEP/mesh-format import/export core), now a direct root pin. Was capped to the 1.0.x line (`.upToNextMinor`) to dodge a heavy mesh-IO stack (SwiftPMX / SwiftGLTF / ThreeMF / SwiftJWW / SwiftX / Nodal / Zip) that OCCTSwiftIO ≥1.1.0 pulls in and OCCTMCP doesn't use. That cap stopped being optional once OCCTSwiftTools ≥1.6.1 started requiring OCCTSwiftIO ≥1.7.0 directly: keeping OCCTMCP's own cap just broke resolution instead of avoiding the heavier graph. Uncapped as of the #90/#91/#93/#97 repin; the heavy stack is now a real (if unused) part of the dependency graph, accepted in exchange for the whole cohort staying current
- **modelcontextprotocol/swift-sdk** ≥ 0.11.0: MCP transport + types

Verify what a fresh clone / CI actually resolves (not the local sibling-checkout shortcut below) with `OCCTMCP_FORCE_REMOTE_DEPS=1 swift build` / `swift test`.

### Node implementation

- **OCCTSwiftScripts** ≥ 1.4.0 — provides `occtkit` on `$PATH` (`make install` from the OCCTSwiftScripts repo) or via sibling clone at `~/Projects/OCCTSwiftScripts` so `swift run -c release occtkit` works as the fallback. v1.3.0 adds the `measure-deviation` verb and the `metrics` `boundingBoxOptimal` field (Node `measure_deviation` / `compute_metrics`); v1.4.0 adds `load-brep` / `import` `--allow-invalid` (Node `read_brep` / `import_file` `allowInvalid`, #41)
- **OCCTSwift** — required at `~/Projects/OCCTSwift/` only when regenerating `src/api-reference.ts` via `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`)
- **OCCTSwiftViewport** — Metal viewport that watches the output directory via `ScriptWatcher` and auto-reloads. Optional but expected if you want the live preview

## MCP Tools

63 tools in Swift; 37 in Node (no selection / remap / annotations / history / reconstruct). See README.md for the categorized table — that's the LLM-facing surface and stays canonical.

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
