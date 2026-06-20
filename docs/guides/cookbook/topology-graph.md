---
title: Topology graph
parent: Cookbook
nav_order: 11
---

# Topology graph

These tools operate directly on an **absolute BREP file path** rather than a scene body. Use them when you need raw graph analysis, compaction, deduplication, ML export, or local adjacency queries on a file outside the scene — or on a file you have just exported from it. For scene-aware equivalents that take a `bodyId`, see [`validate_geometry`](../../reference/introspection.md#validate_geometry) and [`recognize_features`](../../reference/analysis.md#recognize_features).

{: .note }
`graph_select` requires the Swift `occtmcp-server`. All other tools on this page are available on both servers.

The typical pipeline for a BREP received from an importer or a CAD export:

1. **`graph_validate`** — confirm the shape is topologically sound before doing anything else.
2. **`graph_compact`** — drop unreferenced nodes left by Boolean/healing operations.
3. **`graph_dedup`** — merge geometrically identical surfaces/curves (saves memory; makes ML graphs cleaner).
4. **`graph_select`** or **`graph_ml`** — local adjacency queries or full ML-ready export.
5. **`feature_recognize`** — identify pockets and holes for downstream machining analysis.

---

## 1. Validate the raw BREP

[`graph_validate`](../../reference/topology-graph.md#graph_validate) reports per-subshape errors and warnings without touching the file.

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket.brep"
}
```

```json
{
  "valid": true,
  "errors": [],
  "warnings": []
}
```

If `valid` is `false`, examine the `errors` list before proceeding. A shape with topology errors can still be loaded with [`read_brep`](../../reference/io.md#read_brep) using `allowInvalid: true` for measurement, but compact/dedup on an invalid shape may produce further corruption.

---

## 2. Compact — drop unreferenced nodes

[`graph_compact`](../../reference/topology-graph.md#graph_compact) rebuilds the shape and removes nodes that nothing references (common after Booleans and healing). Pass a distinct `output_path` to preserve the original.

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket.brep",
  "output_path": "/Users/me/.occtswift-scripts/output/bracket_compact.brep"
}
```

```json
{
  "output_path": "/Users/me/.occtswift-scripts/output/bracket_compact.brep",
  "nodesRemoved": 4
}
```

---

## 3. Dedup — merge shared surface/curve geometry

[`graph_dedup`](../../reference/topology-graph.md#graph_dedup) detects geometrically identical surfaces and curves and merges them into single graph nodes. This reduces file size and makes the gAAG cleaner for feature recognition and ML export.

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket_compact.brep",
  "output_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep"
}
```

```json
{
  "output_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep",
  "geometriesDeduped": 12
}
```

---

## 4a. Local adjacency with `graph_select` (Swift only)

[`graph_select`](../../reference/topology-graph.md#graph_select) answers focused neighbourhood questions without dumping the full graph. The `query` field selects the mode; supply the matching secondary parameter.

| `query` | secondary param | returns |
|---------|----------------|---------|
| `face-neighbors` | `face` (index) | adjacent faces + convexity + shared-edge count |
| `edge-faces` | `edge` (index) | face indices on both sides |
| `vertex-edges` | `vertex` (index) | edge indices incident to the vertex |
| `face-adjacency` | — | full attributed gAAG |
| `edges-class` | `class` (`boundary`/`non-manifold`/`seam`/`degenerate`) | matching edge indices |

Face indices follow `shape.faces()` order (same as [`query_topology`](../../reference/introspection.md#query_topology)'s `face[N]` scheme). Edge and vertex indices are `TopologyGraph` indices.

**Face neighbours with convexity:**

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep",
  "query": "face-neighbors",
  "face": 2
}
```

```json
{
  "face": 2,
  "neighbors": [
    { "face": 0, "convexity": "convex", "sharedEdgeCount": 1 },
    { "face": 3, "convexity": "concave", "sharedEdgeCount": 1 }
  ]
}
```

**Edge classification — find all boundary edges:**

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep",
  "query": "edges-class",
  "class": "boundary"
}
```

```json
{
  "class": "boundary",
  "edges": [7, 11, 14]
}
```

{: .note }
Node clients must use `graph_ml` (step 4b) to obtain adjacency data — `graph_select` is Swift only.

---

## 4b. Full ML export with `graph_ml`

[`graph_ml`](../../reference/topology-graph.md#graph_ml) runs `ScriptHarness BREPGraphJSONExporter` and augments the output with a `faceAdjacency` block: `{ face1, face2, convexity, sharedEdgeCount }` per gAAG edge. The optional `description` field is written verbatim into the JSON — useful for labelling training data.

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep",
  "description": "bracket v2 — clean"
}
```

```json
{
  "description": "bracket v2 — clean",
  "nodes": [
    { "kind": "face", "index": 0 },
    { "kind": "face", "index": 1 }
  ],
  "faceAdjacency": [
    { "face1": 0, "face2": 1, "convexity": "convex", "sharedEdgeCount": 1 },
    { "face1": 1, "face2": 2, "convexity": "concave", "sharedEdgeCount": 1 }
  ]
}
```

Face indices in `faceAdjacency` are in `shape.faces()` order, consistent with `graph_select` and `query_topology`.

---

## 5. Feature recognition on the raw path

[`feature_recognize`](../../reference/topology-graph.md#feature_recognize) applies AAG heuristics to detect pockets and holes directly from the BREP path. For a body already in the scene, use [`recognize_features`](../../reference/analysis.md#recognize_features) (takes a `bodyId`) instead.

```json
{
  "brep_path": "/Users/me/.occtswift-scripts/output/bracket_clean.brep"
}
```

```json
{
  "features": [
    { "kind": "hole",   "faces": [4, 5],    "diameter": 6.0 },
    { "kind": "pocket", "faces": [6, 7, 8], "depth": 5.0   }
  ]
}
```

Face indices in the `faces` arrays follow `shape.faces()` order.

---

## Related reference pages

- [Topology graph tools](../../reference/topology-graph.md) — full parameter tables for all six tools.
- [Inspection tools](../../reference/introspection.md) — `validate_geometry` and `recognize_features` (scene-aware wrappers).
- [Analysis tools](../../reference/analysis.md) — `graph_validate` / `graph_compact` / `graph_dedup` / `graph_ml` context.
