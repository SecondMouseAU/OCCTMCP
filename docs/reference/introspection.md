---
title: Introspection & measurement
parent: Tool Reference
nav_order: 3
---

# Introspection & measurement

These tools read the current scene without modifying it: validating geometry, querying topology, computing physical properties, measuring distances and surface deviations, and inspecting assembly hierarchies. Reach for them after `execute_script` builds a body, or any time you need ground-truth numbers before making a design decision.

## Tools

[`validate_geometry`](#validate_geometry) · [`compute_metrics`](#compute_metrics) · [`query_topology`](#query_topology) · [`measure_distance`](#measure_distance) · [`measure_deviation`](#measure_deviation) · [`deviation_histogram`](#deviation_histogram) · [`cross_section_compare`](#cross_section_compare) · [`recognize_features`](#recognize_features) · [`inspect_assembly`](#inspect_assembly)

Signed / spatially-resolved surface comparison — the certify-a-reconstruction toolset (#61–#63, #66, #70) — also renders to PNG via [`signed_deviation_heatmap`](mesh-visualization.md#signed_deviation_heatmap) and [`overlay_render`](mesh-visualization.md#overlay_render).

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

Signed, spatially-resolved surface deviation between two scene bodies — the primary metric for certifying a reconstruction against its source mesh. As of #62 the report is a full vector (not just a min gap), with an optional per-station sweep along an axis.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | Source body (e.g. the reconstruction). |
| `toBodyId` | string | yes | Reference body (e.g. the input mesh). |
| `deflection` | number | no | Mesh linear deflection in model units. Smaller = finer tessellation = tighter bound. Default: 0.5% of the from-body bbox diagonal. |
| `maxSamples` | integer | no | Max source surface samples per direction (stride-subsampled). Default 20000. |
| `sectionAxis` | number[3] | no | `[x,y,z]` axis to bin the forward samples along. With `sections`, adds a per-station `signedMean` sweep. |
| `sections` | integer | no | Number of along-axis bins for the per-section sweep (≥2). Requires `sectionAxis`. |

**Returns** — JSON object:
- `fromToTo` / `toToFrom` — directed deviation each way: `{ max, rms, mean, p95, signedMean, signedMin, signedMax, worstPoint, samples }`. `signedMean ≠ 0` reveals a systematic proud(+) / shy(−) bias a Hausdorff hides; `fromToTo` catches over-extension, `toToFrom` under-coverage.
- `symmetricHausdorff` — the single worst-case surface distance in either direction.
- `sections` (optional) — when `sectionAxis`+`sections` given, an array of `{ offset, signedMean, rms, samples }` per station; a near-constant non-zero `signedMean` across stations is the systematic section-error fingerprint.

All distances are in model units. Sign convention: **+ proud** (from outside the reference), **− shy**.

**Example**

```json
// tool call arguments
{ "fromBodyId": "recon", "toBodyId": "source_mesh", "deflection": 0.1, "sectionAxis": [0,0,1], "sections": 6 }
```
```json
// example result (abridged)
{
  "fromToTo": { "max": 0.18, "rms": 0.06, "mean": 0.04, "p95": 0.15, "signedMean": -0.03, "signedMin": -0.18, "signedMax": 0.05, "worstPoint": [42.1, 7.3, 0.0], "samples": 17230 },
  "toToFrom": { "max": 0.22, "rms": 0.08, "mean": 0.05, "p95": 0.19, "signedMean": 0.02, "signedMin": -0.06, "signedMax": 0.22, "worstPoint": [41.9, 7.1, 0.0], "samples": 17230 },
  "symmetricHausdorff": 0.22,
  "sections": [ { "offset": 5.0, "signedMean": -0.03, "rms": 0.05, "samples": 2900 } ]
}
```

**Notes** — Unlike [`measure_distance`](#measure_distance) (minimum gap, ≈0 for overlapping bodies), this samples each body's tessellated surface. Fidelity scales with `deflection`. Import the reference mesh with [`import_file`](io.md#import_file)`(format: "stl")` or load an invalid in-progress reconstruction with [`read_brep`](io.md#read_brep)`(allowInvalid: true)` before calling.

---

## `deviation_histogram`

Signed point-to-surface deviation *distribution* between two bodies — the statistical companion to `measure_deviation`, with an optional histogram PNG (#62). Swift-only.

**Server:** Swift

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | Candidate body. |
| `referenceBodyId` | string | yes | Reference body. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the from-body bbox diagonal. |
| `tolerance` | number | no | If set, the report includes `withinTolerance` (fraction of samples with `|dev| ≤ tolerance`). |
| `outputPath` | string | no | Write a histogram PNG here. Omit for numbers only. |

**Returns** — `{ mean, std, median, p95, signedMin, signedMax, maxAbs, withinTolerance?, buckets: [{ lo, hi, count }], samples }`. Sign convention: + proud, − shy.

---

## `cross_section_compare`

Slice **both** bodies at N stations across their shared axis-extent overlap and compare the 2D profiles — the highest-leverage detector of a reconstruction whose cross-section is the wrong shape everywhere yet whose 3D mean looks fine (#61, #66, #70). Swift-only.

**Server:** Swift

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | Candidate body (e.g. the reconstruction). |
| `referenceBodyId` | string | yes | Reference body (e.g. the source mesh). |
| `axis` | number[3] | yes | `[x,y,z]` section sweep axis (e.g. the carbody longitudinal axis). |
| `stations` | integer | no | Number of evenly-spaced cut planes across the shared overlap. Default 12. |
| `through` | number[3] | no | A point the axis passes through. Default: from-body bbox centre. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the from-body bbox diagonal. |
| `outerEnvelope` | boolean | no | Compare against the reference's **outer boundary per angular direction** (default `true`) so inner window-return / frame paths of a thin-wall or scanned part don't pollute the metric. `false` = raw point-to-main-loop. |
| `outputDir` | string | no | Directory for per-station overlay PNGs. Omit for numbers only. |
| `imagePrefix` | string | no | Filename prefix for station PNGs. Default `"section"`. |

**Returns** — a report with `overlap` (`[lo,hi]` shared axis extent), `referenceMode` (`"envelope"` | `"profile"`), `meanSignedAcrossSections`, `maxAbsSignedSection`, `worstStation` / `worstAxisCoord`, `warnings[]`, and a `sections[]` array. Each section carries `station`, `axisCoord` (**world** position along the axis), `offset` (overlap-relative), `signedMean` / `rms` / `maxAbs`, `centroidOffset`, `areaRatio`, `shapeL2` (pose-invariant shape scalar — defined for open profiles too), `fromContours` / `referenceContours` / `fromOpenPaths` / `referenceOpenPaths`, `openProfile`, `registrationSmell`, and `imagePath`.

**Notes** — Handles open-shell references (raw scan / STL skin) whose sections are open arcs. `registrationSmell` flags a station that sliced only one body (mis-registration / differing extents). Pair with [`import_file`](io.md#import_file)`(format: "stl")` to get the reference mesh into the scene.

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
