---
title: Meshing & drawings
parent: Cookbook
nav_order: 9
---

# Meshing & drawings

Three tools cover the mesh-and-drawing pipeline: [`generate_mesh`](../../reference/mesh-visualization.md#generate_mesh) tessellates a B-rep body and returns quality metrics; [`simplify_mesh`](../../reference/mesh-visualization.md#simplify_mesh) decimates that mesh with QEM and writes a `.stl` or `.obj`; and [`generate_drawing`](../../reference/mesh-visualization.md#generate_drawing) produces a multi-view ISO 128-30 DXF — a standard part sheet from a single body, or a general-arrangement assembly sheet with a parts list and balloons from two or more. Both servers support all three tools.

---

## Step 1 — Tessellate with quality metrics

Call `generate_mesh` first to inspect surface quality and decide whether you need a tighter mesh or a decimated export.

`linearDeflection` (mm) is the dominant knob: smaller values produce more triangles and a more faithful mesh. `angularDeflection` (radians) caps the angle between adjacent triangle normals and matters most on curved faces. Omit `outputPath` if you only need the metrics.

```json
{
  "bodyId": "housing",
  "linearDeflection": 0.05,
  "angularDeflection": 0.3
}
```

```json
{
  "triangleCount": 9214,
  "minEdgeLength": 0.04,
  "maxEdgeLength": 2.1
}
```

To write a fine mesh at the same time, add `outputPath`:

```json
{
  "bodyId": "housing",
  "linearDeflection": 0.05,
  "angularDeflection": 0.3,
  "outputPath": "/tmp/housing_fine.stl"
}
```

```json
{
  "triangleCount": 9214,
  "minEdgeLength": 0.04,
  "maxEdgeLength": 2.1,
  "outputPath": "/tmp/housing_fine.stl"
}
```

Use `returnGeometry: true` if the client needs the vertex and triangle data inlined in the response rather than written to disk.

---

## Step 2 — Decimate with simplify_mesh

`simplify_mesh` runs QEM decimation (OCCTSwiftMesh / vendored meshoptimizer) and always writes a file — `outputPath` is required. Target the triangle budget with `targetReduction` (fraction to remove) or `targetTriangleCount` (absolute cap); both can be set together.

Use `maxHausdorffDistance` as a quality gate: the tool aborts if the achieved surface error exceeds the threshold. `preserveBoundary` locks seam edges; `preserveTopology` prevents genus changes.

```json
{
  "bodyId": "housing",
  "outputPath": "/tmp/housing_lod.obj",
  "linearDeflection": 0.1,
  "targetReduction": 0.75,
  "maxHausdorffDistance": 0.5,
  "preserveBoundary": true
}
```

```json
{
  "inputTriangles": 9214,
  "outputTriangles": 2304,
  "hausdorffDistance": 0.31,
  "outputPath": "/tmp/housing_lod.obj"
}
```

Check `hausdorffDistance` against your tolerance budget. If it is close to `maxHausdorffDistance`, loosen `targetReduction` or tighten `linearDeflection` on the upstream tessellation step.

---

## Step 3 — Single-part technical drawing

`generate_drawing` writes a DXF via [DrawingComposer](../../reference/mesh-visualization.md#generate_drawing). Pass `bodyId` for a single-part sheet; the `spec` object controls the sheet size, title block, and which ISO projection views to render.

```json
{
  "bodyId": "housing",
  "outputPath": "/tmp/housing.dxf",
  "spec": {
    "sheet": "A3",
    "title": "Housing — Rev B",
    "views": ["front", "top", "right", "iso"]
  }
}
```

```json
{
  "outputPath": "/tmp/housing.dxf",
  "views": ["front", "top", "right", "iso"],
  "bodyCount": 1
}
```

The DXF is the output — open it in any CAD viewer or convert to PDF with a DXF-aware tool. `spec` also accepts `sections` and `dimensions` sub-objects (see `OCCTSwiftScripts/Sources/DrawingComposer/Spec.swift`) for section cuts and driven dimensions on part sheets.

---

## Step 4 — General-arrangement assembly sheet

Pass `bodyIds` (two or more) instead of `bodyId` to produce an assembly sheet. `generate_drawing` renders a shared multi-body view and auto-generates a parts list with one balloon per body. `bodyIds` takes precedence over `bodyId` when both are supplied. Per-view `sections` and `dimensions` in the `spec` are ignored on assembly sheets.

```json
{
  "bodyIds": ["housing", "cover", "shaft", "bearing"],
  "outputPath": "/tmp/assembly_ga.dxf",
  "spec": {
    "sheet": "A2",
    "title": "Gearbox Assembly — GA Sheet",
    "views": ["front", "top", "iso"]
  }
}
```

```json
{
  "outputPath": "/tmp/assembly_ga.dxf",
  "views": ["front", "top", "iso"],
  "bodyCount": 4
}
```

Body names shown in the parts list come from the manifest. Use [`rename_body`](../../reference/scene.md#rename_body) before generating the drawing if the default ids are not human-readable.

---

## Putting it together

A typical workflow for a new part:

1. Build or import the body (`execute_script` / `import_file`).
2. `generate_mesh` — verify triangle count and edge length distribution.
3. `simplify_mesh` — produce a lightweight `.obj` for the game engine / web viewer.
4. `generate_drawing` with `bodyId` — produce the engineering DXF for the fabricator.

For an assembly:

1. Load or build each component; confirm body ids with [`get_scene`](../../reference/core.md#get_scene).
2. `generate_drawing` with `bodyIds` — one call, shared views, parts list, balloons.
