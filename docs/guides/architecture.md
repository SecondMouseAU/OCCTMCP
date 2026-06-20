---
title: Architecture
nav_order: 5
---

# Architecture

OCCTMCP is an MCP server that lets an LLM author, inspect, and iterate on 3D CAD models by calling typed tools over stdio. Two interchangeable server implementations speak the same protocol and read/write the same scene on disk.

---

## Two servers, one scene

| | Swift (`occtmcp-server`) | Node (`dist/index.js`) |
|---|---|---|
| **Runtime** | macOS 15+, Swift in-process | Node 18+, any OS |
| **Tools** | 59 | 37 |
| **OCCTSwift access** | Direct — no subprocess per call | Via `occtkit` CLI (shells out) |
| **Build** | `swift build -c release` | `npm run build` |

The Swift server is the primary implementation. Because it calls OCCTSwift, OCCTSwiftTools, OCCTSwiftAIS, OCCTSwiftMesh, and DrawingComposer in-process, it can expose higher-level operations — selection, remap, annotations, reconstruction, history wiring — without serialising through a JSONL subprocess boundary. The Node server wraps `occtkit` verbs, so it only covers the 37 tools that map directly onto CLI commands. The 22 Swift-only tools are: the entire `select_*` / `remap_selection` / `find_correspondences` group, all annotation tools, `graph_select`, `pick_surface_point`, `ping`, and the `reconstruct_*` group.

See the [Tool Reference](../reference/) for the full per-tool listing; each entry notes which server(s) expose it.

---

## The scene model

The scene is a directory (the **output directory**) containing:

- `manifest.json` — a `ScriptManifest` with one `BodyDescriptor` per body (id, name, colour, BREP path). Every tool that reads or mutates geometry looks up bodies by their string `bodyId` from this file.
- `*.brep` — one OpenCASCADE BREP file per body.
- `annotations.json` — a sidecar holding `dimensions[]` and `primitives[]` independently of the manifest, used by `add_dimension`, `add_scene_primitive`, and `render_preview`.

**Output directory resolution** (first match wins):
1. `OCCTMCP_OUTPUT_DIR` environment variable
2. iCloud Drive — `~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`
3. Local fallback — `~/.occtswift-scripts/output/`

Because both servers write to the same directory, OCCTSwiftViewport's `ScriptWatcher` detects the manifest update and triggers a live 3D reload automatically.

---

## How `execute_script` works

`execute_script` is the primary geometry-authoring tool. The flow:

1. Writes the LLM's Swift source to a temporary file.
2. Invokes `occtkit run <tempfile>` (Swift server) or the same via the long-lived `occtkit run --serve` child (Node server). If `occtkit` is not on `$PATH`, both fall back to `swift run -c release occtkit` inside a sibling OCCTSwiftScripts clone.
3. Filters OCCT bridge nullability warnings from the build output; compiler diagnostics still reach the caller on failure.
4. Reads `manifest.json` back and returns it with any build output.
5. Removes the temp file.

The cold-start cost of the underlying SwiftPM workspace is significant (60 s+) on the first call; subsequent calls amortise it via serve mode where available. The 2-minute per-request timeout applies.

Scripts must follow this shape exactly:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// build geometry — guard-unwrap optionals, never force-unwrap
// boolean operators: a - b (subtract), a + b (union), a & b (intersect)

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "what this model is")
```

---

## selectionId and history wiring

**selectionIds** are stable references to sub-shape topology — faces, edges, or vertices — across mutations. The format is `sel:<bodyId>#<kind>[<idx>]`, which is self-describing and parseable without additional context.

`select_topology` mints selectionIds. `remap_selection` carries them forward after a body has been mutated, using the following resolution chain:

### 1. HistoryRegistry (preferred)

The Swift server maintains an actor-backed `HistoryRegistry` that maps `bodyId → TopologyGraph`. After a mutation, the registry stores enough provenance for `remap_selection` to call `TopologyGraph.findDerivedOrSelf(originalRef:)` and determine whether the original sub-shape was **preserved**, **split**, or **lost**.

Tools that write history records:

| Tool | History path |
|---|---|
| `transform_body` | Implicit identity — no records written; every node maps 1:1, `findDerivedOrSelf` returns `[self]` |
| `heal_shape` | Implicit identity if pre/post topology counts match; falls back to centroid heuristic if shape repair changed topology |
| `boolean_op` | Per-input history via OCCTSwift's `*WithFullHistory` variants; recorded under the output body and both inputs |
| `apply_feature` | Per-feature history via `FeatureReconstructor.BuildResult.histories[id]`; covers boolean / hole / second-additive / fillet / chamfer |

### 2. Centroid heuristic (fallback)

When no history record exists (e.g. after `execute_script` or `mirror_or_pattern`), `remap_selection` loads the pre- and post-mutation BREPs, finds the nearest face / edge / vertex within an epsilon, and reports the centroid distance as `confidenceMm`.

### `find_correspondences`

`mirror_or_pattern` produces new bodies rather than mutating in place, so `remap_selection` does not apply. Use `find_correspondences` instead: it takes a source body and a target body and maps each source anchor's centroid through an optional transform before nearest-neighbour search on the target. The transform can be supplied explicitly, read from `provenance.json` (written by `mirror_or_pattern` for mirror outputs), or inferred from bounding-box centroid delta.

---

## The OCCTSwift ecosystem

The Swift server is built on a layered family of packages:

```
OCCTSwift          — OpenCASCADE kernel wrapper (Shape, BRep, topology, history)
OCCTSwiftViewport  — Metal viewport + offscreen renderer
      ↓ bridge
OCCTSwiftTools     — Shape ↔ ViewportBody conversion; Curve / Surface / Wire / Point converters
      ↓ services
OCCTSwiftAIS       — Selection, manipulators, 3D dimensions
OCCTSwiftMesh      — Mesh algorithms (QEM decimation, etc.)
DrawingComposer    — 2D drawing / general-arrangement output (via OCCTSwiftScripts)
```

`render_preview` depends on **OCCTSwiftTools + OCCTSwiftViewport** to compose body overlays (measurements, annotations, point clouds, bounding boxes). The Node server does not have in-process access to this stack — it shells to `occtkit` for every call.

For the ecosystem package versions and dependency pins, see `Package.swift` and the [OCCTMCP README](https://github.com/gsdali/OCCTMCP#mcp-tools).

---

## Source layout quick-reference

**Swift** — `Sources/OCCTMCPCore/` (library) + `Sources/OCCTMCPServer/main.swift` (stdio binding). Tools are grouped by family under `Sources/OCCTMCPCore/Tools/`.

**Node** — `src/index.ts` (server factory), `src/tools.ts` (core), `src/scene-tools.ts` (manifest manipulation), `src/verb-tools.ts` and `src/api-tools.ts` (occtkit verb wrappers), `src/occtkit-serve.ts` (long-lived child process).
