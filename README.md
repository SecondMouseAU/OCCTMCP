# OCCTMCP

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTMCP%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/SecondMouseAU/OCCTMCP)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FSecondMouseAU%2FOCCTMCP%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/SecondMouseAU/OCCTMCP)
[![License: LGPL v2.1+](https://img.shields.io/badge/License-LGPL--2.1--or--later-blue.svg)](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html)

MCP server that gives LLMs the ability to author, inspect, and iterate on 3D CAD models with [OpenCASCADE](https://www.opencascade.com/) via the [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift) family.

Part of the [OCCTSwift ecosystem](https://github.com/SecondMouseAU/OCCTSwift/blob/main/docs/ecosystem.md) — see the ecosystem map for how this package sits on top of the kernel, viewport, bridge, and AIS layers. SemVer-stable from v1.0.0.

The Swift implementation calls OCCT directly in-process — no subprocess, no JSONL marshalling — and exposes 67 typed MCP tools that cover authoring, scene reads, mutation, introspection, construction, analysis, I/O, mesh, drawing, selection / remap, mesh-zone analysis, and dimension overlays.

## How It Works

```
LLM picks a typed tool (boolean_op, transform_body, render_preview, …)
  → OCCTMCP runs the OCCT operation directly via OCCTSwift / Tools / AIS / Mesh
  → Writes BREP/STEP/PNG + manifest.json + annotations.json
  → OCCTSwiftViewport (optional) auto-reloads the 3D model
```

For novel geometry the typed tools don't cover, the LLM falls back to `execute_script`: arbitrary Swift code with the full OCCTSwift API, compiled and run in-process.

## Tools

67 tools, organized below. Call `get_api_reference({ category: "mcp_tools" })` to dump every tool's JSON Schema in one shot — useful for LLM auto-discovery. Most flows can answer "what's the volume?", "make it red", "boolean-subtract these", "render a preview", "add a dimension between these two faces", "export to STEP", and "draw this" without ever touching `execute_script`.

### Authoring

| Tool | Purpose |
|------|---------|
| `execute_script` | Write & execute arbitrary Swift CAD code (full OCCTSwift API) |
| `get_script` | Read the most recent script's source |
| `get_api_reference` | Browse OCCTSwift API by category |

### Scene reads

| Tool | Purpose |
|------|---------|
| `get_scene` | Read current scene manifest (bodies, colors, materials) |
| `export_model` | List exported BREP / STEP / STL / OBJ file paths |
| `compare_versions` | Diff current scene vs N runs ago (added / removed / appearance / file changed) |

### Scene mutation

| Tool | Purpose |
|------|---------|
| `remove_body` | Delete a body from the scene (manifest + BREP file) |
| `clear_scene` | Wipe all bodies, optionally keep diff history |
| `rename_body` | Change a body's id |
| `set_appearance` | Update color / opacity / roughness / metallic / display name |

### Introspection

| Tool | Purpose |
|------|---------|
| `validate_geometry` | Per-body topology validation (isValid, error counts) |
| `compute_metrics` | Volume, area, centroid, bounding box, principal axes |
| `query_topology` | Find faces / edges / vertices matching criteria, return stable IDs |
| `measure_distance` | Min distance + contacts between two bodies |
| `measure_deviation` | Signed, spatially-resolved surface deviation between two bodies — max / rms / mean / p95 / `signedMean` (systematic proud(+)/shy(−) bias) each way + worstPoint, plus an optional per-section signedMean sweep along an axis. The certify-a-reconstruction metric (`measure_distance` is min-only). See `signMode` under [Deviation & reconstruction QA](#deviation--reconstruction-qa) for what the sign is worth against an open thin-walled reference |
| `recognize_features` | Pockets and holes via AAG heuristics |
| `inspect_assembly` | Walk an XCAF assembly tree (STEP / IGES / XBF) |

### Construction

| Tool | Purpose |
|------|---------|
| `apply_feature` | Drill / fillet / chamfer / extrude / revolve / thread / boolean (FeatureSpec) |
| `transform_body` | Translate / rotate / uniform-scale (records identity history for remap) |
| `boolean_op` | Union / subtract / intersect / split (records per-input history for remap) |
| `mirror_or_pattern` | Mirror / linear / circular pattern → N new bodies |

### Engineering analysis

| Tool | Purpose |
|------|---------|
| `check_thickness` | Wall-thickness analysis with thin-region flags |
| `analyze_clearance` | Pairwise interference / minimum clearance |
| `heal_shape` | Heal imported / non-watertight geometry; before/after stats |

### Deviation & reconstruction QA

Signed, spatially-resolved comparison of a reconstruction against its source mesh. Where `measure_deviation`'s scalars can hide a *systematic* shape error (a wrong cross-section that averages out), these expose **where** and **which way** the candidate departs. Pure-Swift rendering — no Python/matplotlib.

**Which way is out?** `measure_deviation`, `deviation_histogram` and `signed_deviation_heatmap` share one signed-distance engine, so they share a `signMode` knob. The sign of a deviation depends on which reference triangle a sample is judged against, and against an **open, thin-walled** reference (a raw scan / STL skin) the nearest one is often the wrong one: a candidate flank sitting 4.5 mm inside a 2 mm wall is only 2.5 mm from the wall's *inner* surface, so that surface wins on proximity and — facing the cavity — reports **+2.5 proud for a part that is 4.5 shy**. Wrong side, wrong magnitude, nothing tying to flag it. `signMode: "robust"` (the default since v1.17.0) rejects reference triangles whose outward normal opposes the sample's own before the nearest survivor wins, recovering both figures; samples with no compatible surface in reach are reported `ambiguous` and withheld from the signed statistics rather than guessed. `signMode: "nearest"` restores the pre-v1.17 raw nearest-triangle sign, which is correct against a watertight / single-surface reference. An `ambiguousFraction` near 1.0 means the reference's winding is likely inverted relative to the sampled body; where nothing has a trustworthy sign the signed figures come back **null** rather than a zero that would read as "perfectly centred".

The two families of number answer **different questions**, and `signMode` moves only the second:

| Family | Measures to | Moved by `signMode`? |
|--------|-------------|----------------------|
| Unsigned — `max` / `rms` / `mean` / `p95` / `worstPoint` / `symmetricHausdorff` / `maxAbs` / `withinTolerance` | the **nearest** reference surface, whatever it is | No — same meaning as pre-v1.17 |
| Signed — `signedMean` / `signedMin` / `signedMax` / `sections` / histogram buckets / heatmap colours | the surface the sample **corresponds to** | Yes |

Against a watertight reference these are the same surface and the families agree. Against an open thin-walled one they diverge on purpose: `max: 2.5` next to `signedMin: -4.5` says the nearest reference geometry is an inner wall 2.5 away while the skin that flank belongs to is 4.5 above it. Both true. A gap between them is itself the tell that the reference is thin-walled.

| Tool | Purpose |
|------|---------|
| `deviation_histogram` | Signed point-to-surface deviation distribution: μ / σ / median / p95 / proud-shy extremes, percent within ±tolerance, bucket histogram + optional PNG. A non-zero mean or bimodal shape ⇒ systematic error |
| `cross_section_compare` | Slice both bodies at N stations across their shared axis-extent overlap; per-section signed-mean / RMS / area-ratio / centroid-offset + a pose-robust radial shape scalar, with overlay PNGs. Default `outerEnvelope` mode compares against the reference's outer boundary per angular direction so inner window-return / frame paths of a thin-wall or scanned part don't pollute the aggregate; each station reports `axisCoord` (world position along the axis). Handles open-shell references (raw scan / STL skin) whose sections are open arcs, reports the `overlap` range, and warns on stations that sliced only one body. The highest-leverage detector of a wrong-shape section |
| `signed_deviation_heatmap` | Render the candidate surface coloured by signed distance (proud = red, shy = blue) through a diverging colormap with a colorbar legend. Triangles whose sign can't be established against an open/thin-walled reference render grey (`ambiguousTriangles`/`ambiguousFraction`, excluded from signedMin/Max/Mean) rather than a coin-flip red/blue — see `signMode` above |
| `overlay_render` | Render the reference mesh semi-transparent over the opaque candidate solid — see the departure in 3D |

### Mesh analysis (zones)

The mesh-inspection surface for raw scans / STL skins: split a body's mesh into surface zones (plane / cylinder / sphere / cone, via OCCTSwiftMesh's dihedral region-growing + primitive-fit merge), then measure how far each zone's own cross-section stays constant along an axis (a loftable-extent map). Both are pure mesh-domain composition — the aggregation/verdict logic here is independent of OCCTReconstruct's own engine, per the mandatory-analytic-verification policy.

| Tool | Purpose |
|------|---------|
| `segment_mesh_zones` | Split a body's mesh into surface zones; each zone gets a stable `zone:<bodyId>#<n>` id, a fitted primitive (kind/params/residual), and (optionally) a categorical PNG render and/or its own registered scene body |
| `zone_continuity_sweep` | Sweep a zone (or whole body) along an axis; report maximal within-tolerance runs (loftable extents) and deviation intervals between them, each with world `axisCoord` spans and magnitudes |
| `list_zones` | Inspect the zone registry (`<output_dir>/zones.json`) |
| `clear_zones` | Wipe the zone registry, optionally for one body |

### Selection & remap

| Tool | Purpose |
|------|---------|
| `select_topology` | Pick faces / edges / vertices, get a stable `selectionId` |
| `remap_selection` | Carry `selectionId`s across mutations of the same body (history-based for transform / heal / boolean / apply_feature; centroid heuristic fallback otherwise) |
| `find_correspondences` | Map `selectionId`s from a source body onto a target body that's a known transform of the source — `mirror_or_pattern` outputs are the typical case |
| `select_by_feature` | Bulk pick by feature kind (e.g. all hole edges) |
| `list_selections` | Inspect the in-memory selection registry |
| `clear_selections` | Wipe the registry |

### Annotations & overlays

| Tool | Purpose |
|------|---------|
| `add_dimension` | Add a linear / angular / radial dimension; renders in `render_preview` |
| `add_scene_primitive` | Add trihedron / workPlane / axis / pointCloud / boundingBox / diffMarker |
| `auto_dimension` | Heuristic dimension drop for the principal extents |
| `show_bounding_box` | Add a body's AABB as an overlay |
| `diff_overlay` | Visualize the diff between two snapshots |
| `remove_scene_annotation` | Remove a dimension or primitive by id |
| `list_annotations` | Inspect the annotations sidecar |

### I/O

| Tool | Purpose |
|------|---------|
| `read_brep` | Load a `.brep` from disk into the scene (`allowInvalid` loads a loose-face / invalid shape for measurement) |
| `import_file` | Multi-format import (STEP / IGES / STL / OBJ); optional XCAF assembly; `allowInvalid` for in-progress reconstructions |
| `export_scene` | Export to STEP / IGES / BREP / STL / OBJ / glTF / GLB |
| `set_assembly_metadata` | Modify XCAF document or per-component metadata |

### Mesh & visualisation

| Tool | Purpose |
|------|---------|
| `generate_mesh` | Tessellate to triangles + quality metrics |
| `simplify_mesh` | QEM mesh decimation to .stl/.obj — wraps OCCTSwiftMesh's `Mesh.simplified` (vendored meshoptimizer) |
| `render_preview` | One-shot PNG render with measurement labels and primitive overlays. Mesh-scale bodies (imported scans, >10k edges) render via a linear path in seconds — edge overlays kept up to 100k edges, surface-only beyond |
| `pick_surface_point` | Cast a render_preview-framed ray through a pixel → world surface point + selectionId (usable as an `add_dimension` anchor) |
| `generate_drawing` | Multi-view ISO 128-30 DXF technical drawing — `bodyId` for a single part, or `bodyIds` (2+) for a general-arrangement assembly sheet with a parts list + balloons |

### Topology graph (low-level)

| Tool | Purpose |
|------|---------|
| `graph_validate` | Validate a BREP's topology graph (raw path) |
| `graph_compact` | Drop unreferenced graph nodes; write rebuilt BREP |
| `graph_dedup` | Deduplicate shared surface / curve geometry |
| `graph_ml` | Export topology + UV/edge samples as ML-friendly JSON |
| `graph_select` | Local graph adjacency / selection: face neighbours (+ convexity), edge faces, vertex edges, face-adjacency (gAAG), edge classes |
| `feature_recognize` | Pockets + holes (raw BREP path; `recognize_features` is the scene-aware wrapper) |

### Reconstruction graph (read/write)

LLM read/write over an attributed reconstruction graph — annotate per-node decisions and persist them. Backed by OCCTSwift 1.2.0's `NodeAttributeStore` + Codable `GraphSnapshot`. Nodes are addressed as `<kind>:<index>` (e.g. `face:3`). The reconstruction *engine* (surface fitting, congruence detection) lives in [OCCTReconstruct](https://github.com/SecondMouseAU/OCCTReconstruct); these tools are the annotate-and-persist layer — `reconstruct_force_fit` records an override for the engine to honour, it does not re-fit here.

| Tool | Purpose |
|------|---------|
| `reconstruct_get_graph` | Export the attributed graph as JSON — topology counts, annotated nodes (with `reconstruct.*` attributes), instance clusters. Starts a session from a `bodyId` or reads an existing one by `sessionId` |
| `reconstruct_set_decision` | Annotate a node's `decidedBy` (geometric / ml / human) and/or accept-reject a proposed fit |
| `reconstruct_force_fit` | Override a node's fitted surface type (e.g. force `cylinder`) |
| `reconstruct_confirm_instances` | Confirm / reject a congruence cluster ("these N nodes are one part definition") |
| `reconstruct_export_session` | Write the session snapshot to disk (byte-stable JSON) |
| `reconstruct_import_session` | Reload a snapshot file into a session |

## Implementations

This repo ships two implementations side-by-side:

- **Swift** (`Sources/`, `Package.swift`) — the **primary** server. In-process against OCCTSwift / OCCTSwiftMesh / OCCTSwiftTools / OCCTSwiftAIS / DrawingComposer using the [official Swift MCP SDK](https://swiftpackageindex.com/modelcontextprotocol/swift-sdk). 67 tools. macOS 15+ (the OCCT.xcframework arm64 platform).
- **Node / TypeScript** (`src/`, `dist/`) — the original implementation. Shells out to the `occtkit` CLI for everything Swift-side. 37 tools (the pre-v0.4 surface; selection / remap / annotations are Swift-only). Useful if you can't run a macOS binary.

Both speak stdio MCP and read/write the same manifest format.

## Prerequisites

- macOS 15+ (for the Swift implementation)
- Swift 6.1+ / Xcode 16+
- For the Node implementation only: Node.js 18+, plus a sibling clone of [OCCTSwiftScripts](https://github.com/SecondMouseAU/OCCTSwiftScripts) so `occtkit` is on `$PATH` (or `make install` it)

## Setup

### Swift implementation (recommended)

```bash
git clone https://github.com/SecondMouseAU/OCCTMCP.git
cd OCCTMCP
swift build -c release
```

In Claude Code's `.mcp.json`:

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "/path/to/OCCTMCP/.build/release/occtmcp-server"
    }
  }
}
```

The Swift package is published on the [Swift Package Index](https://swiftpackageindex.com/SecondMouseAU/OCCTMCP).

### Node implementation

```bash
git clone https://github.com/SecondMouseAU/OCCTMCP.git
cd OCCTMCP
npm install
npm run build
```

In `.mcp.json`:

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "node",
      "args": ["/path/to/OCCTMCP/dist/index.js"]
    }
  }
}
```

## Example

The LLM can author CAD models by composing typed tools — most everyday flows never touch `execute_script`:

```text
boolean_op(op: "subtract", aBodyId: "block", bBodyId: "hole", outputBodyId: "drilled")
  → "drilled" body added to the scene
select_topology(bodyId: "drilled", kind: "face", limit: 1)
  → returns selectionId "sel:drilled#face[12]"
add_dimension(kind: "linear", anchors: [...]) ; render_preview()
```

For novel geometry, drop into `execute_script` with the full OCCTSwift API:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

let box = Shape.box(width: 40, height: 30, depth: 20)!
let hole = Shape.cylinder(radius: 5, height: 30)!
    .translated(by: SIMD3(20, -1, 10))!
let result = box.subtracting(hole)!
let filleted = result.filleted(radius: 2.0)!

try ctx.add(filleted, id: "part", color: C.steel, name: "Bracket")
try ctx.emit(description: "Filleted bracket with mounting hole")
```

## API Categories

The `get_api_reference` tool provides documentation for:

- **primitives** — box, cylinder, sphere, cone, torus, wedge
- **sweeps** — extrude, revolve, pipe sweep, loft, ruled
- **booleans** — union, subtract, intersect, section
- **modifications** — fillet, chamfer, shell, offset, draft, defeature
- **transforms** — translate, rotate, scale, mirror
- **wires** — rectangle, circle, polygon, spline, helix, offset
- **curves2d/3d** — line, arc, ellipse, bspline, bezier, interpolate
- **surfaces** — plane, cylinder, cone, sphere, extrusion, revolution, plate
- **analysis** — volume, area, distance, bounds, validation
- **import_export** — STL, STEP, IGES, BREP, OBJ, PLY
- **mcp_tools** — every MCP tool's JSON Schema (handy for LLM auto-discovery)

## Versioning

OCCTMCP follows [Semantic Versioning](https://semver.org/). The Swift port reached **v1.0.0** on 2026-05-09 — feature-complete against the original Node implementation, plus a layer of selection / remap / annotation tools that are Swift-only.

Releases are tagged on GitHub. The `main` branch is what SPI tracks.

## License

LGPL-2.1-or-later — same as [OCCTSwift](https://github.com/SecondMouseAU/OCCTSwift).
