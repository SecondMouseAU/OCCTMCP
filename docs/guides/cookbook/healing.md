---
title: Healing
parent: Cookbook
nav_order: 10
---

# Healing

A four-step repair workflow for imported geometry that arrives with open shells, free edges, or
invalid flags: import with the validity gate bypassed, validate to see what is wrong, heal with
ShapeFix, then validate again to confirm the repair.

All tools in this recipe run on both the Swift `occtmcp-server` and the Node server.

---

## 1. Import with `allowInvalid`

By default `import_file` refuses to add a shape that fails OCCT's validity checks. Pass
`allowInvalid: true` to load the raw geometry so the analysis tools can run on it.

See [`import_file`](../../reference/io.md#import_file).

```json
// tool call arguments
{
  "inputPath": "/path/to/received_part.step",
  "idPrefix": "imported",
  "allowInvalid": true
}
```

```json
// example result
{
  "bodyId": "imported_1",
  "name": "received_part",
  "faceCount": 28,
  "valid": false
}
```

The `bodyId` assigned (here `"imported_1"` from the `idPrefix`) is what every subsequent call
uses.

---

## 2. Validate — before

Confirm exactly which validity violations are present before attempting repair.

See [`validate_geometry`](../../reference/introspection.md#validate_geometry).

```json
// tool call arguments
{ "bodyId": "imported_1" }
```

```json
// example result
{
  "bodyId": "imported_1",
  "valid": false,
  "issues": [
    "open shell: 3 free edge(s)",
    "bad edge orientation on face[17]"
  ]
}
```

The `issues` array identifies what ShapeFix will target. Keep this result — it is the baseline
you compare against after healing.

---

## 3. Heal

Run OCCT ShapeFix via [`heal_shape`](../../reference/engineering.md#heal_shape). Supply
`outputBodyId` to preserve the original under its own ID so you can compare before and after with
[`measure_deviation`](../../reference/introspection.md#measure_deviation) if needed.

```json
// tool call arguments
{
  "bodyId": "imported_1",
  "outputBodyId": "imported_1_healed"
}
```

```json
// example result
{
  "topologyPreserved": true,
  "before": { "valid": false, "faceCount": 28, "freeEdges": 3 },
  "after":  { "valid": true,  "faceCount": 28, "freeEdges": 0 }
}
```

The `before` / `after` sections show face counts and free-edge counts so you can confirm the
repair at a glance. `topologyPreserved: true` means the face and edge indices are unchanged —
`heal_shape` records identity history in this case, so any `selectionId`s minted on
`imported_1` remap cleanly onto `imported_1_healed` via
[`remap_selection`](../../reference/selection.md#remap_selection) (Swift only).

When `topologyPreserved` is `false` — ShapeFix had to merge or split faces — selection remap
falls back to the centroid heuristic rather than the history-based path.

---

## 4. Validate — after

Re-run validation on the healed body to confirm it passes.

```json
// tool call arguments
{ "bodyId": "imported_1_healed" }
```

```json
// example result
{
  "bodyId": "imported_1_healed",
  "valid": true,
  "issues": []
}
```

An empty `issues` array and `valid: true` means the body is ready for downstream operations:
boolean ops, feature recognition, thickness checks, and so on.

---

## What next?

- Inspect the healed body's volume, area, and bounding box →
  [Inspection](inspection.md)
- Check wall thickness for sheet-metal or casting constraints →
  [Engineering analysis reference](../../reference/engineering.md#check_thickness)
- Pick faces on the healed body as stable `selectionId`s →
  [Selection & remap](selection-and-remap.md) (Swift only)
