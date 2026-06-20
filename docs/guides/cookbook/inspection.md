---
title: Inspection
parent: Cookbook
nav_order: 4
---

# Inspection

A four-step workflow for interrogating an existing body without modifying it: confirm it is
topologically sound, measure its physical properties (including a tight bounding box for curved
geometry), find faces or edges of interest by type, then detect pockets and holes automatically.

All four tools run on both the Swift `occtmcp-server` and the Node server.

---

## 1. Validate geometry

Before doing any measurement, confirm the body is valid. An invalid shell or degenerate edge will
silently corrupt downstream metric results.

See [`validate_geometry`](../../reference/introspection.md#validate_geometry).

```json
// tool call arguments
{ "bodyId": "housing" }
```

```json
// example result
{ "bodyId": "housing", "valid": true, "issues": [] }
```

If `valid` is `false`, the `issues` array lists the violations (open shells, bad orientation,
degenerate edges). Fix them with [`heal_shape`](../../reference/healing.md#heal_shape) before
proceeding, then re-validate.

---

## 2. Compute metrics

Retrieve volume, surface area, center of mass, and bounding box in one call.

See [`compute_metrics`](../../reference/introspection.md#compute_metrics).

### Default bounding box (Bnd_Box)

```json
// tool call arguments
{
  "bodyId": "housing",
  "metrics": ["volume", "surfaceArea", "centerOfMass", "boundingBox"]
}
```

```json
// example result
{
  "volume": 18432.6,
  "surfaceArea": 7804.1,
  "centerOfMass": [0.0, 0.0, 24.5],
  "boundingBox": { "min": [-40.0, -30.0, 0.0], "max": [40.0, 30.0, 49.0] }
}
```

### Tight bounding box for curved geometry

`boundingBox` uses OCCT's `Bnd_Box`, which encloses the **control-point hull** of B-spline
surfaces rather than the actual surface. For a cylindrical housing this can add several millimetres
to each axis. Request `boundingBoxOptimal` instead — it calls `BRepBndLib::AddOptimal`, which
samples the exact surface and returns the tight envelope.

`boundingBoxOptimal` is intentionally excluded from the default-all set; you must list it
explicitly:

```json
// tool call arguments
{
  "bodyId": "housing",
  "metrics": ["boundingBox", "boundingBoxOptimal"]
}
```

```json
// example result
{
  "boundingBox":        { "min": [-40.3, -30.3, 0.0], "max": [40.3, 30.3, 49.0] },
  "boundingBoxOptimal": { "min": [-40.0, -30.0, 0.0], "max": [40.0, 30.0, 49.0] }
}
```

The difference is small on planar solids; on bodies with large-radius fillets or blended surfaces
the `Bnd_Box` over-report can exceed 1–2 % of the overall extent. Use `boundingBoxOptimal` whenever
the bbox drives a fit-check or clearance decision.

---

## 3. Query topology

Find faces or edges of a specific geometric type and get their stable index-based IDs.

See [`query_topology`](../../reference/introspection.md#query_topology).

### Planar faces (e.g. datum planes, mounting pads)

```json
// tool call arguments
{
  "bodyId": "housing",
  "entity": "face",
  "filter": { "surfaceType": "plane" },
  "limit": 20
}
```

```json
// example result
[
  { "id": "face[0]", "surfaceType": "plane", "area": 2400.0, "centroid": [0.0, 0.0, 49.0] },
  { "id": "face[1]", "surfaceType": "plane", "area": 2400.0, "centroid": [0.0, 0.0,  0.0] }
]
```

### Cylindrical faces (e.g. bore walls, pin seats)

```json
// tool call arguments
{
  "bodyId": "housing",
  "entity": "face",
  "filter": { "surfaceType": "cylinder" }
}
```

```json
// example result
[
  { "id": "face[2]", "surfaceType": "cylinder", "area": 9483.5, "centroid": [0.0, 0.0, 24.5] },
  { "id": "face[3]", "surfaceType": "cylinder", "area": 1884.9, "centroid": [0.0, 0.0, 24.5] }
]
```

The returned IDs (`face[N]`, `edge[N]`, `vertex[N]`) are stable across calls on the same BREP and
can be passed directly to
[`select_topology`](../../reference/selection.md#select_topology) (Swift only) to mint a
`selectionId` for remap and annotation workflows.

---

## 4. Recognize features

Detect pockets and holes via OCCTSwift's Attributed Adjacency Graph (AAG) heuristics.

See [`recognize_features`](../../reference/introspection.md#recognize_features).

```json
// tool call arguments
{ "bodyId": "housing", "kinds": ["pocket", "hole"] }
```

```json
// example result
{
  "features": [
    { "kind": "hole",   "faces": ["face[4]", "face[5]"],   "diameter": 8.0,  "depth": 20.0 },
    { "kind": "hole",   "faces": ["face[6]", "face[7]"],   "diameter": 8.0,  "depth": 20.0 },
    { "kind": "hole",   "faces": ["face[8]", "face[9]"],   "diameter": 8.0,  "depth": 20.0 },
    { "kind": "hole",   "faces": ["face[10]", "face[11]"], "diameter": 8.0,  "depth": 20.0 },
    { "kind": "pocket", "faces": ["face[12]", "face[13]", "face[14]", "face[15]"],
                        "depth": 5.0 }
  ]
}
```

The face IDs in each feature's `faces` array correspond directly to the IDs returned by
`query_topology`, so you can cross-reference feature membership with surface type or area.

For the full graph-level pipeline — a labelled `TopologyGraph` written for downstream
reconstruction — see
[`feature_recognize`](../../reference/topology-graph.md#feature_recognize) in the Topology graph
family.

---

## What next?

- Measure minimum clearance between two bodies or certify surface deviation against a reference
  mesh → [Measurement & verification](measurement.md)
- Pick specific faces or edges as stable `selectionId`s and carry them through a mutation →
  [Selection & remap](selection-and-remap.md) (Swift only)
- Repair an invalid or imported body before inspecting → [Healing](healing.md)
