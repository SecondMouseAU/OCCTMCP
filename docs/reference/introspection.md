---
title: Introspection & measurement
parent: Tool Reference
nav_order: 3
---

# Introspection & measurement

These tools read the current scene without modifying it: validating geometry, querying topology, computing physical properties, measuring distances and surface deviations, and inspecting assembly hierarchies. Reach for them after `execute_script` builds a body, or any time you need ground-truth numbers before making a design decision.

## Tools

[`validate_geometry`](#validate_geometry) · [`compute_metrics`](#compute_metrics) · [`query_topology`](#query_topology) · [`measure_distance`](#measure_distance) · [`measure_deviation`](#measure_deviation) · [`recognize_features`](#recognize_features) · [`inspect_assembly`](#inspect_assembly)

---

## `validate_geometry`

Per-body topology validation against OCCTSwift's `TopologyGraph.validate()`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | no | Specific body to validate. If omitted, validates every BREP body in the scene. |

**Returns** — JSON object with a per-body validity report: `valid` boolean and a list of any violations found (open shells, bad orientation, degenerate edges, etc.). Returns an error string if the body is not found.

**Example**

```json
// tool call arguments
{ "bodyId": "housing" }
```
```json
// example result
{ "bodyId": "housing", "valid": true, "issues": [] }
```

**Drives** — `GraphIO` + `TopologyGraph.validate()` in-process (no subprocess).

---

## `compute_metrics`

Compute volume, surface area, center of mass, bounding box, and/or principal axes for a scene body.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to measure. |
| `metrics` | string[] | no | Subset to compute. Default: all except `boundingBoxOptimal`. Items: `volume`, `surfaceArea`, `centerOfMass`, `boundingBox`, `boundingBoxOptimal`, `principalAxes`. `boundingBoxOptimal` (tight AddOptimal extent) is opt-in — list it explicitly. |

**Returns** — JSON object keyed by requested metric name. `boundingBox` and `boundingBoxOptimal` each return `{ min: [x,y,z], max: [x,y,z] }`. `centerOfMass` returns `[x,y,z]`. `principalAxes` returns three orthogonal unit vectors. Returns an error string if the body is not found.

**Example**

```json
// tool call arguments
{ "bodyId": "part", "metrics": ["volume", "surfaceArea", "boundingBoxOptimal"] }
```
```json
// example result
{
  "volume": 5890.3,
  "surfaceArea": 2104.7,
  "boundingBoxOptimal": { "min": [0.0, 0.0, 0.0], "max": [25.0, 20.0, 15.0] }
}
```

**Notes** — `boundingBox` uses `Bnd_Box` and over-reports extents for curved B-spline faces (it encloses the control-point hull, not the actual surface). Use `boundingBoxOptimal` (`BRepBndLib::AddOptimal`) when you need the tight envelope, at a small extra compute cost. `boundingBoxOptimal` is intentionally excluded from the default-all set.

**Drives** — direct OCCTSwift property calls (no `occtkit` subprocess).

---

## `query_topology`

Find faces, edges, or vertices on a body matching optional criteria. Returns stable index-based IDs (`face[N]`, `edge[N]`, `vertex[N]`) that can be passed to selection tools.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to query. |
| `entity` | string (enum) | yes | Entity kind: `face`, `edge`, or `vertex`. |
| `filter` | object | no | Optional filter: `surfaceType`, `curveType`, `minArea`, `maxArea`. |
| `limit` | integer (≥1) | no | Maximum number of results to return. |

**Returns** — Array of matching topology entries, each with its stable ID, geometric properties (type, area/length as applicable), and centroid. Returns an empty array when no entities match the filter.

**Example**

```json
// tool call arguments
{ "bodyId": "bracket", "entity": "face", "filter": { "surfaceType": "plane" }, "limit": 10 }
```
```json
// example result
[
  { "id": "face[0]", "surfaceType": "plane", "area": 400.0, "centroid": [0.0, 0.0, 10.0] },
  { "id": "face[2]", "surfaceType": "plane", "area": 400.0, "centroid": [0.0, 0.0, -10.0] }
]
```

**Notes** — The returned IDs can be passed directly to [`select_topology`](selection.md#select_topology) to mint a `selectionId` for use in remap and annotation workflows.

---

## `measure_distance`

Minimum distance between two scene bodies. Returns ≈0 if the bodies overlap or touch.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | First body. |
| `toBodyId` | string | yes | Second body. |
| `computeContacts` | boolean | no | Also return up to 32 contact pairs (closest point pairs). |

**Returns** — JSON object with `distance` (minimum gap in model units). If `computeContacts` is true, also includes `contacts`: array of up to 32 pairs, each with `pointOnFrom` and `pointOnTo` coordinates.

**Example**

```json
// tool call arguments
{ "fromBodyId": "shaft", "toBodyId": "bearing", "computeContacts": true }
```
```json
// example result
{
  "distance": 0.05,
  "contacts": [
    { "pointOnFrom": [12.5, 0.0, 30.0], "pointOnTo": [12.55, 0.0, 30.0] }
  ]
}
```

**Notes** — This is the **minimum gap** metric — not surface deviation. For comparing a reconstruction against a reference mesh use [`measure_deviation`](#measure_deviation) instead. A result of ≈0 means bodies are touching or penetrating; it does not indicate the amount of overlap.

---

## `measure_deviation`

Surface deviation (directed + symmetric Hausdorff) between two scene bodies — the primary metric for certifying a reconstruction against its source mesh.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | Source body (e.g. the reconstruction). |
| `toBodyId` | string | yes | Reference body (e.g. the input mesh). |
| `deflection` | number | no | Mesh linear deflection in model units. Smaller = finer tessellation = tighter bound. Default: 0.5% of the from-body bbox diagonal. |
| `maxSamples` | integer | no | Max source surface samples per direction (stride-subsampled). Default 20000. |

**Returns** — JSON object with three top-level keys:
- `fromToTo` — directed deviation from `from`'s surface to `to`: `{ max, rms, mean, worstPoint }`. Measures over-extension.
- `toToFrom` — directed deviation from `to`'s surface to `from`: `{ max, rms, mean, worstPoint }`. Measures under-coverage.
- `symmetricHausdorff` — `max(fromToTo.max, toToFrom.max)`: the single worst-case surface distance in either direction.

All distances are in model units.

**Example**

```json
// tool call arguments
{ "fromBodyId": "recon", "toBodyId": "source_mesh", "deflection": 0.1 }
```
```json
// example result
{
  "fromToTo": { "max": 0.18, "rms": 0.06, "mean": 0.04, "worstPoint": [42.1, 7.3, 0.0] },
  "toToFrom": { "max": 0.22, "rms": 0.08, "mean": 0.05, "worstPoint": [41.9, 7.1, 0.0] },
  "symmetricHausdorff": 0.22
}
```

**Notes** — Unlike [`measure_distance`](#measure_distance) (minimum gap, ≈0 for overlapping bodies), `measure_deviation` samples each body's tessellated surface and reports worst/RMS/mean deviation in both directions. `fromToTo` catches over-extension (the reconstruction sticks out beyond the reference); `toToFrom` catches under-coverage (the reference has surface the reconstruction misses). Fidelity scales with `deflection` — reduce it for tighter bounds at higher compute cost. Load invalid in-progress reconstructions with [`read_brep`](io.md#read_brep)`(allowInvalid: true)` before calling this tool.

---

## `recognize_features`

Detect pockets and holes via OCCTSwift's Attributed Adjacency Graph (AAG) heuristics.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to analyse. |
| `kinds` | string[] (enum) | no | Feature kinds to detect: `pocket`, `hole`. Default: both. |

**Returns** — JSON object with a `features` array. Each entry includes the feature `kind`, the face indices that make up the feature, and geometric properties (e.g. diameter for holes, depth for pockets).

**Example**

```json
// tool call arguments
{ "bodyId": "flange", "kinds": ["hole"] }
```
```json
// example result
{
  "features": [
    { "kind": "hole", "faces": ["face[4]", "face[5]"], "diameter": 6.0, "depth": 12.0 },
    { "kind": "hole", "faces": ["face[8]", "face[9]"], "diameter": 6.0, "depth": 12.0 }
  ]
}
```

**Notes** — For the full graph-level feature recognition pipeline (B-Rep graph output, `featureNodeIds`) see [`feature_recognize`](topology-graph.md#feature_recognize) in the Topology graph family. This tool returns a lightweight per-body feature list; `feature_recognize` writes a labelled `TopologyGraph` for downstream reconstruction use.

---

## `inspect_assembly`

Walk an XCAF assembly hierarchy and return the component tree with transforms.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | no | Scene body (BREP — returns a degenerate single-node response). |
| `inputPath` | string | no | Absolute path to a STEP, IGES, or XBF file for the full tree. |
| `depth` | integer (≥0) | no | Maximum tree depth to traverse. Default: unlimited. |

**Returns** — JSON assembly tree: each node has `name`, `shape` (if a leaf), `transform` (4×4 matrix), and a `children` array. A BREP `bodyId` returns a single-node tree.

**Example**

```json
// tool call arguments
{ "inputPath": "/Users/me/Downloads/assembly.step", "depth": 3 }
```
```json
// example result
{
  "name": "Assembly",
  "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
  "children": [
    { "name": "BaseFrame", "shape": "BaseFrame", "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]], "children": [] },
    { "name": "Lid", "shape": "Lid", "transform": [[1,0,0,50],[0,1,0,0],[0,0,1,0],[0,0,0,1]], "children": [] }
  ]
}
```

**Notes** — Pass `inputPath` (not `bodyId`) to get the full multi-level component tree from a STEP/IGES/XBF file. Use [`import_file`](io.md#import_file) first if you want the assembly bodies added to the scene.
