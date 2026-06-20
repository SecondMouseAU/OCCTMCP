---
title: Annotations & overlays
parent: Tool Reference
nav_order: 7
---

# Annotations & overlays

These tools write to (or read from) the `annotations.json` sidecar in the output directory; all
overlays are rendered when you call [`render_preview`](mesh-visualization.md#render_preview). Every
tool in this family is **Swift only** — the Node server does not expose them.

## Tools

- [`add_dimension`](#add_dimension) · [`add_scene_primitive`](#add_scene_primitive) · [`auto_dimension`](#auto_dimension) · [`show_bounding_box`](#show_bounding_box) · [`diff_overlay`](#diff_overlay) · [`remove_scene_annotation`](#remove_scene_annotation) · [`list_annotations`](#list_annotations)

---

## `add_dimension`

Compute a linear, angular, or radial dimension from `selectionId` anchors and persist it to `annotations.json`; `render_preview` overlays it as a leader line with label.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `kind` | string (`"linear"` \| `"angular"` \| `"radial"`) | yes | Dimension type. `linear` needs `anchors.from` + `anchors.to`; `angular` needs `anchors.armA`, `anchors.apex`, `anchors.armB`; `radial` needs `anchors.circularEdge`. |
| `anchors` | object (string values) | yes | Map of anchor role → `selectionId`. Required keys depend on `kind` (see above). |
| `id` | string | no | Stable identifier for the dimension entry; auto-generated if omitted. |
| `label` | string | no | Override the computed label text. |
| `showDiameter` | boolean | no | For `radial`: display diameter (2r) instead of radius. |

**Returns** — Confirmation with the assigned `id` and the persisted dimension record, or an error if an anchor `selectionId` cannot be resolved.

**Example**

```json
// tool call arguments
{
  "kind": "linear",
  "anchors": {
    "from": "sel:part#face[0]",
    "to":   "sel:part#face[1]"
  },
  "id": "dim-height",
  "label": "H"
}
```
```json
// example result
{
  "id": "dim-height",
  "kind": "linear",
  "label": "H",
  "computedValue": 25.0
}
```

**Notes** — `selectionId` values are minted by [`select_topology`](selection.md#select_topology). After a mutation, call [`remap_selection`](selection.md#remap_selection) to update stale ids before re-adding dimensions.

---

## `add_scene_primitive`

Add a visual annotation primitive (trihedron, work plane, axis, or point cloud) to `annotations.json`; rendered as a 3-D overlay by `render_preview`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `kind` | string (`"trihedron"` \| `"workPlane"` \| `"axis"` \| `"pointCloud"`) | yes | Primitive type. Determines the required shape of `params`. |
| `params` | object | yes | Kind-specific parameters. `trihedron`: `{origin, axisLength}`; `workPlane`: `{origin, normal, size, color}`; `axis`: `{from, to, color, radius}`; `pointCloud`: `{points, colors?, pointRadius}`. |
| `id` | string | no | Stable identifier for this primitive; auto-generated if omitted. |

**Returns** — Confirmation with the assigned `id` and the persisted primitive record.

**Example**

```json
// tool call arguments
{
  "kind": "workPlane",
  "id": "wp-top",
  "params": {
    "origin": [0, 0, 50],
    "normal": [0, 0, 1],
    "size": 40,
    "color": "cyan"
  }
}
```
```json
// example result
{ "id": "wp-top", "kind": "workPlane" }
```

**Notes** — `pointCloud` routes through `OCCTSwiftTools.PointConverter`; there is no per-point cap. Remove any primitive with [`remove_scene_annotation`](#remove_scene_annotation).

---

## `auto_dimension`

Run AAG hole detection on a body, then add a radial dimension to each detected hole's circular rim edge in one call — shortcut for the `recognize_features → select_topology → add_dimension` loop.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to scan for holes. |
| `showDiameter` | boolean | no | If `true`, each dimension shows the diameter (2r) instead of the radius. Default `false`. |

**Returns** — List of `{ dimensionId, selectionId }` pairs, one per hole detected. Returns an empty list if no holes are found.

**Example**

```json
// tool call arguments
{ "bodyId": "bracket", "showDiameter": true }
```
```json
// example result
{
  "dimensions": [
    { "dimensionId": "auto-dim-0", "selectionId": "sel:bracket#edge[4]" },
    { "dimensionId": "auto-dim-1", "selectionId": "sel:bracket#edge[9]" }
  ]
}
```

**Drives** — AAG (attributed adjacency graph) hole recognition via `OCCTSwiftTools`, then [`add_dimension`](#add_dimension) per hole.

---

## `show_bounding_box`

Compute a body's axis-aligned bounding box and register it as a `boundingBox` scene primitive in `annotations.json`. Also returns the extents inline so the LLM can reason about size without a separate `compute_metrics` call.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body whose bounding box to compute and display. |
| `primitiveId` | string | no | Stable id for the registered primitive; auto-generated if omitted. |

**Returns** — `{ primitiveId, min, max, extent, center }` — all coordinates in model units.

**Example**

```json
// tool call arguments
{ "bodyId": "housing", "primitiveId": "bbox-housing" }
```
```json
// example result
{
  "primitiveId": "bbox-housing",
  "min":    [0.0,  0.0,  0.0],
  "max":    [80.0, 50.0, 30.0],
  "extent": [80.0, 50.0, 30.0],
  "center": [40.0, 25.0, 15.0]
}
```

**Notes** — Uses the default `Bnd_Box` (may slightly over-report on curved B-spline faces). For a tight box use [`compute_metrics`](introspection.md#compute_metrics) with `"boundingBoxOptimal"`.

---

## `diff_overlay`

Visualise a recent scene change. For each body added, removed, or modified since N runs ago, register a tinted `diffMarker` primitive at its bounding-box centre (added = green, removed = red, changed = yellow).

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `since` | integer (≥ 1) | no | Number of runs back to diff against. Defaults to 1 (last run). Maximum 10 (ring-buffer depth). |

**Returns** — `{ added, removed, changed }` arrays of body ids, plus `primitiveIds` for the registered markers. Returns empty arrays if nothing changed.

**Example**

```json
// tool call arguments
{ "since": 1 }
```
```json
// example result
{
  "added":      ["boss"],
  "removed":    [],
  "changed":    ["bracket"],
  "primitiveIds": ["diff-0", "diff-1"]
}
```

**Notes** — Diffs the same in-memory ring buffer used by [`compare_versions`](scene-mutation.md#compare_versions). Primitives persist in `annotations.json` until removed with [`remove_scene_annotation`](#remove_scene_annotation).

---

## `remove_scene_annotation`

Remove a dimension or scene primitive from `annotations.json` by id.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `id` | string | yes | The `id` of the dimension or primitive to remove. |

**Returns** — `{ found: boolean }` — `true` if the id existed and was removed; `false` if it was not found (no error is thrown).

**Example**

```json
// tool call arguments
{ "id": "dim-height" }
```
```json
// example result
{ "found": true }
```

---

## `list_annotations`

Read the `annotations.json` sidecar and return its full contents — both dimensions and scene primitives.

**Server:** Swift only

No parameters.

**Returns** — `{ dimensions: [...], primitives: [...] }` — the raw sidecar arrays. Returns empty arrays if the file does not exist yet.

**Example**

```json
// tool call arguments
{}
```
```json
// example result
{
  "dimensions": [
    { "id": "dim-height", "kind": "linear", "label": "H", "computedValue": 25.0 }
  ],
  "primitives": [
    { "id": "wp-top", "kind": "workPlane" }
  ]
}
```
