---
title: Engineering analysis
parent: Tool Reference
nav_order: 5
---

# Engineering analysis

Tools for manufacturing-readiness checks and geometry repair: wall-thickness analysis for sheet metal, casting, or 3D-printing; pairwise clearance / interference checks between assembly components; and ShapeFix-based healing of imported or non-watertight geometry before downstream operations.

## Tools

- [`check_thickness`](#check_thickness) · [`analyze_clearance`](#analyze_clearance) · [`heal_shape`](#heal_shape)

---

## `check_thickness`

UV-grid sample each face and cast an inward ray to the opposite wall; reports min/max/mean thickness and flags all samples below a minimum acceptable threshold.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | ID of the body to analyse. |
| `minAcceptable` | number | no | Thickness threshold (mm). Samples below this are flagged as thin regions. |
| `samplingDensity` | string (`"coarse"` \| `"medium"` \| `"fine"`) | no | Ray-casting grid density per face. Defaults to `"medium"` when omitted. |

**Returns** — JSON object with `min`, `max`, and `mean` thickness values (mm), plus a `thinRegions` array of sample locations where thickness fell below `minAcceptable`. Returns an error string if the body is not found.

**Example**

```json
// tool call arguments
{ "bodyId": "housing", "minAcceptable": 1.5, "samplingDensity": "fine" }
```
```json
// example result
{
  "min": 1.1,
  "max": 4.8,
  "mean": 2.9,
  "thinRegions": [
    { "faceIndex": 3, "u": 0.25, "v": 0.5, "thickness": 1.1 }
  ]
}
```

**Notes** — `samplingDensity: "fine"` increases accuracy at the cost of speed; use `"coarse"` for a quick sanity check on large bodies.

---

## `analyze_clearance`

Pairwise interference and minimum-clearance check between two or more bodies; each pair gets a `minDistance` and, optionally, up to 16 contact points.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyIds` | string[] (min 2) | yes | IDs of the bodies to check against each other. All pairs are evaluated. |
| `computeContacts` | boolean | no | When `true`, include up to 16 contact / near-contact point pairs per body pair. |

**Returns** — JSON array of pair results, each with `bodyA`, `bodyB`, `minDistance` (mm; ≈ 0 or negative indicates interference), and optionally `contacts` (array of point pairs). Returns an error string if fewer than two valid bodies are found.

**Example**

```json
// tool call arguments
{ "bodyIds": ["shaft", "housing", "bearing"], "computeContacts": true }
```
```json
// example result
{
  "pairs": [
    {
      "bodyA": "shaft",
      "bodyB": "housing",
      "minDistance": 0.05,
      "contacts": [
        { "pointA": [10.0, 0.0, 5.0], "pointB": [10.05, 0.0, 5.0] }
      ]
    },
    { "bodyA": "shaft",   "bodyB": "bearing", "minDistance": 0.0  },
    { "bodyA": "housing", "bodyB": "bearing", "minDistance": 1.2  }
  ]
}
```

**Notes** — A `minDistance` of 0 means the bodies are exactly touching; a negative value indicates interference (overlap). See [`measure_distance`](introspection.md#measure_distance) for a quick two-body gap check without contact points.

---

## `heal_shape`

Heal imported or non-watertight geometry via OCCT ShapeFix; returns before/after validity statistics. Records identity history when the topology is preserved, enabling [`remap_selection`](selection.md#remap_selection) to carry `selectionId`s across the repair.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | ID of the body to heal in place. |
| `outputBodyId` | string | no | If provided, the healed result is stored under this new ID and the original body is left unchanged. |

**Returns** — JSON object with `before` and `after` sections each containing validity flags and face/edge/vertex counts, plus a `topologyPreserved` boolean. Returns an error string if the body is not found or healing fails.

**Example**

```json
// tool call arguments
{ "bodyId": "imported_part", "outputBodyId": "imported_part_healed" }
```
```json
// example result
{
  "topologyPreserved": true,
  "before": { "valid": false, "faceCount": 24, "freeEdges": 3 },
  "after":  { "valid": true,  "faceCount": 24, "freeEdges": 0 }
}
```

**Notes** — Run [`validate_geometry`](introspection.md#validate_geometry) before and after to confirm the repair. If `topologyPreserved` is `false`, selection IDs minted before healing fall back to the centroid heuristic during remap rather than the history-based path. Use `outputBodyId` to keep the original body available for comparison with [`measure_deviation`](introspection.md#measure_deviation).
