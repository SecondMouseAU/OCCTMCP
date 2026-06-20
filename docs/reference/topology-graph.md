---
title: Topology graph
parent: Tool Reference
nav_order: 10
---

# Topology graph

Low-level B-rep graph operations that work directly on an absolute BREP file path rather than a scene body. Use these when you need raw topology analysis, graph compaction, ML export, or local adjacency queries — call the scene-aware wrappers (`validate_geometry`, `recognize_features`) when working with bodies already loaded in the scene.

## Tools

- [`graph_validate`](#graph_validate) · [`graph_compact`](#graph_compact) · [`graph_dedup`](#graph_dedup) · [`graph_ml`](#graph_ml) · [`graph_select`](#graph_select) · [`feature_recognize`](#feature_recognize)

---

## `graph_validate`

Raw-path topology validation. Pass an absolute BREP path; use `validate_geometry` for the scene-aware version.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the BREP file to validate. |

**Returns** — Topology validity report for the shape at `brep_path`. Reports errors/warnings on individual sub-shapes.

**Example**

```json
// tool call arguments
{ "brep_path": "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/part.brep" }
```
```json
// example result
{ "valid": true, "errors": [], "warnings": [] }
```

**Notes** — For bodies already in the scene, prefer `validate_geometry` (takes a `bodyId`).

---

## `graph_compact`

Compact a BREP's topology graph (drops unreferenced nodes); writes the rebuilt shape to `output_path`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the source BREP file. |
| `output_path` | string | yes | Absolute path where the compacted BREP will be written. |

**Returns** — Confirmation that the compacted shape was written to `output_path`, plus node counts before and after.

**Example**

```json
// tool call arguments
{
  "brep_path": "/Users/me/.occtswift-scripts/output/part.brep",
  "output_path": "/Users/me/.occtswift-scripts/output/part_compact.brep"
}
```
```json
// example result
{ "output_path": "/Users/me/.occtswift-scripts/output/part_compact.brep", "nodesRemoved": 4 }
```

---

## `graph_dedup`

Deduplicate shared surface/curve geometry in a BREP's topology graph; writes the rebuilt shape to `output_path`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the source BREP file. |
| `output_path` | string | yes | Absolute path where the deduplicated BREP will be written. |

**Returns** — Confirmation that the deduplicated shape was written to `output_path`.

**Example**

```json
// tool call arguments
{
  "brep_path": "/Users/me/.occtswift-scripts/output/assembly.brep",
  "output_path": "/Users/me/.occtswift-scripts/output/assembly_dedup.brep"
}
```
```json
// example result
{ "output_path": "/Users/me/.occtswift-scripts/output/assembly_dedup.brep", "geometriesDeduped": 12 }
```

---

## `graph_ml`

Export a BREP's topology graph as ML-friendly JSON. Wraps `ScriptHarness BREPGraphJSONExporter`, augmented with a `faceAdjacency` block — the convexity-attributed gAAG edge attribute with face indices in `shape.faces()` order.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the BREP file. |
| `description` | string | no | Optional human-readable label written into the exported JSON. |

**Returns** — ML-friendly JSON containing nodes (faces, edges, vertices with UV/edge samples), edges (topology adjacency), and a `faceAdjacency` block with `{ face1, face2, convexity, sharedEdgeCount }` entries.

**Example**

```json
// tool call arguments
{
  "brep_path": "/Users/me/.occtswift-scripts/output/part.brep",
  "description": "bracket v2"
}
```
```json
// example result
{
  "description": "bracket v2",
  "nodes": [ { "kind": "face", "index": 0 }, "..." ],
  "faceAdjacency": [
    { "face1": 0, "face2": 1, "convexity": "convex", "sharedEdgeCount": 1 }
  ]
}
```

**Notes** — Face indices in `faceAdjacency` follow `shape.faces()` order, consistent with `query_topology`'s `face[N]` scheme.

---

## `graph_select`

Local B-rep graph adjacency/selection query — returns a focused neighbourhood rather than a full graph dump.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the BREP file. |
| `query` | string (`"face-neighbors"` \| `"edge-faces"` \| `"vertex-edges"` \| `"face-adjacency"` \| `"edges-class"`) | yes | Which adjacency/selection query to run. |
| `face` | integer | no | Face index (required for `face-neighbors`). Follows `shape.faces()` order. |
| `edge` | integer | no | Edge index (required for `edge-faces`). TopologyGraph index. |
| `vertex` | integer | no | Vertex index (required for `vertex-edges`). TopologyGraph index. |
| `class` | string (`"boundary"` \| `"non-manifold"` \| `"seam"` \| `"degenerate"`) | no | Edge class filter (required for `edges-class`). |

**Returns** — Depends on `query`:
- `face-neighbors` — adjacent face indices, convexity per shared edge, shared-edge count.
- `edge-faces` — face indices on both sides of the given edge.
- `vertex-edges` — edge indices incident to the given vertex.
- `face-adjacency` — full attributed face-adjacency graph (gAAG) for the shape.
- `edges-class` — indices of all edges matching the given `class`.

**Example**

```json
// tool call arguments — face neighbours with convexity
{
  "brep_path": "/Users/me/.occtswift-scripts/output/part.brep",
  "query": "face-neighbors",
  "face": 2
}
```
```json
// example result
{
  "face": 2,
  "neighbors": [
    { "face": 0, "convexity": "convex", "sharedEdgeCount": 1 },
    { "face": 3, "convexity": "concave", "sharedEdgeCount": 1 }
  ]
}
```

**Notes** — The correct secondary parameter to supply depends on `query`: `face` for `face-neighbors`, `edge` for `edge-faces`, `vertex` for `vertex-edges`, `class` for `edges-class`; none needed for `face-adjacency`. This tool is Swift only — Node clients must use `graph_ml` for adjacency data.

---

## `feature_recognize`

Detect pockets and holes via AAG heuristics. Pass an absolute BREP path; `recognize_features` is the scene-aware variant.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `brep_path` | string | yes | Absolute path to the BREP file to analyse. |

**Returns** — List of detected features (pockets, holes) with their face-index sets and geometry parameters.

**Example**

```json
// tool call arguments
{ "brep_path": "/Users/me/.occtswift-scripts/output/part.brep" }
```
```json
// example result
{
  "features": [
    { "kind": "hole", "faces": [4, 5], "diameter": 6.0 },
    { "kind": "pocket", "faces": [6, 7, 8], "depth": 5.0 }
  ]
}
```

**Notes** — For bodies already in the scene, prefer `recognize_features` (takes a `bodyId`). Face indices follow `shape.faces()` order.
