---
title: Mesh & visualization
parent: Tool Reference
nav_order: 9
---

# Mesh & visualization

Tools for converting B-rep bodies into triangle meshes, decimating those meshes, rendering headless PNG previews of the scene, ray-casting a pixel back to a world-space surface point, and producing multi-view ISO 128-30 DXF technical drawings. Reach for this family when you need a visual snapshot, a lightweight mesh export, or a production drawing.

## Tools

[`generate_mesh`](#generate_mesh) · [`simplify_mesh`](#simplify_mesh) · [`render_preview`](#render_preview) · [`signed_deviation_heatmap`](#signed_deviation_heatmap) · [`overlay_render`](#overlay_render) · [`pick_surface_point`](#pick_surface_point) · [`generate_drawing`](#generate_drawing)

---

## `generate_mesh`

Tessellate a scene body into triangles and return quality metrics; optionally write the mesh to `.stl` or `.obj`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to tessellate. |
| `linearDeflection` | number | no | Maximum linear chord deviation (mm). Controls mesh fineness. |
| `angularDeflection` | number | no | Maximum angular deviation (radians). |
| `outputPath` | string | no | Write path for `.stl` or `.obj` output. Omit to receive metrics only. |
| `returnGeometry` | boolean | no | If `true`, inline the triangle geometry in the response. |

**Returns** — Quality metrics (triangle count, min/max edge length, etc.). If `outputPath` is given, the mesh file is written. If `returnGeometry` is `true`, vertex + triangle data is included in the response.

**Example**

```json
// tool call arguments
{ "bodyId": "part", "linearDeflection": 0.1, "outputPath": "/tmp/part.stl" }
```
```json
// example result
{
  "triangleCount": 1248,
  "minEdgeLength": 0.08,
  "maxEdgeLength": 3.4,
  "outputPath": "/tmp/part.stl"
}
```

**Drives** — `OCCTSwiftMesh` tessellation pipeline; `OCCTSwift` BREP → mesh bridge.

---

## `simplify_mesh`

QEM mesh decimation via OCCTSwiftMesh (vendored meshoptimizer). Outputs `.stl` or `.obj`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body whose mesh to decimate. |
| `outputPath` | string | yes | Write path for the simplified `.stl` or `.obj` file. |
| `linearDeflection` | number | no | Linear chord deviation for the initial tessellation step. |
| `angularDeflection` | number | no | Angular deviation for the initial tessellation step (radians). |
| `targetReduction` | number | no | Fraction of triangles to remove, e.g. `0.5` removes half. |
| `targetTriangleCount` | integer (≥ 1) | no | Absolute triangle count target. Takes effect alongside or instead of `targetReduction`. |
| `maxHausdorffDistance` | number | no | Quality gate: abort if the Hausdorff error exceeds this distance (mm). |
| `preserveBoundary` | boolean | no | Lock boundary edges during decimation. |
| `preserveTopology` | boolean | no | Prevent changes that would alter the mesh's genus. |

**Returns** — Triangle count before and after, achieved Hausdorff distance, and the written `outputPath`.

**Example**

```json
// tool call arguments
{
  "bodyId": "housing",
  "outputPath": "/tmp/housing_lod.obj",
  "targetReduction": 0.7,
  "preserveBoundary": true
}
```
```json
// example result
{
  "inputTriangles": 8400,
  "outputTriangles": 2520,
  "hausdorffDistance": 0.22,
  "outputPath": "/tmp/housing_lod.obj"
}
```

**Drives** — `OCCTSwiftMesh` QEM decimator (meshoptimizer).

---

## `render_preview`

Headless Metal render of the current scene (or a named subset of bodies) to a PNG file. Overlays sidecar annotations (dimensions, primitives, bounding boxes, diff markers) and renders measurement labels.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `outputPath` | string | yes | Write path for the PNG file. |
| `bodyIds` | string[] | no | Restrict the render to these bodies. Omit to render the full scene. |
| `options` | object | no | Rendering options — see sub-fields below. |
| `options.camera` | string | no | Preset viewpoint: `"iso"` `"front"` `"back"` `"top"` `"bottom"` `"left"` `"right"`. |
| `options.cameraPosition` | number[3] | no | Explicit camera eye position `[x, y, z]`. Overrides preset. |
| `options.cameraTarget` | number[3] | no | Explicit look-at point `[x, y, z]`. |
| `options.cameraUp` | number[3] | no | Camera up vector `[x, y, z]`. |
| `options.displayMode` | string | no | `"wireframe"` `"shaded"` `"shadedWithEdges"` `"flat"` `"xray"` `"rendered"`. |
| `options.background` | string | no | `"light"` \| `"dark"` \| `"transparent"` \| `"#rrggbb"` / `"#rrggbbaa"`. |
| `options.width` | integer (≥ 1) | no | Output image width in pixels. |
| `options.height` | integer (≥ 1) | no | Output image height in pixels. |
| `options.renderAnnotations` | boolean | no | Overlay sidecar annotations (Trihedron / WorkPlane / Axis / BoundingBox / DiffMarker). Default `true`. |

**Returns** — Path to the written PNG and image dimensions. Returns an error if the scene is empty or Metal is unavailable.

**Example**

```json
// tool call arguments
{
  "outputPath": "/tmp/preview.png",
  "options": {
    "camera": "iso",
    "displayMode": "shadedWithEdges",
    "background": "light",
    "width": 1200,
    "height": 900
  }
}
```
```json
// example result
{
  "outputPath": "/tmp/preview.png",
  "width": 1200,
  "height": 900
}
```

**Notes** — Pass the same `options.camera` / `width` / `height` values to `pick_surface_point` so pixel coordinates map to the same ray. Annotation overlays read from `annotations.json` in the output directory.

**Drives** — `OCCTSwiftViewport` `OffscreenRenderer`; `OCCTSwiftTools` Shape → `ViewportBody` bridge; `AnnotationsRenderer` for sidecar overlays.

---

## `signed_deviation_heatmap`

Render `fromBodyId`'s surface coloured by **signed** distance to `referenceBodyId` — proud (over-build) red, on-target near-white, shy (under-build) blue — via a diverging colormap with a colorbar legend (#63). Shows exactly *where* a reconstruction departs, which a scalar deviation can't. Swift-only.

**Server:** Swift

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `fromBodyId` | string | yes | Body whose surface is coloured. |
| `referenceBodyId` | string | yes | Body measured against. |
| `outputPath` | string | yes | PNG output path. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the from-body bbox diagonal. |
| `bands` | integer | no | Colormap band count. Default 11. |
| `clamp` | number | no | `|signed| ≥ clamp` saturates to full red/blue. Default: p95 of `|signed|`. |
| `options` | object | no | Render options — same shape as [`render_preview`](#render_preview)'s `options` (camera, width, height, background). |

**Returns** — `{ outputPath, bands, triangles, clamp, signedMin, signedMax, signedMean }`.

---

## `overlay_render`

Render the reference mesh (`meshBodyId`, semi-transparent amber) superimposed over the opaque candidate solid (`solidBodyId`, steel-grey) — see in 3D exactly where the reconstruction departs from the source mesh (#63). Swift-only.

**Server:** Swift

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `solidBodyId` | string | yes | Opaque candidate solid. |
| `meshBodyId` | string | yes | Translucent reference mesh, drawn over the solid. |
| `outputPath` | string | yes | PNG output path. |
| `transparency` | number | no | Mesh overlay transparency (0 = opaque, 1 = invisible). |
| `options` | object | no | Render options — same shape as [`render_preview`](#render_preview)'s `options`. |

**Returns** — `{ outputPath }` (plus render metadata). Pairs naturally with [`import_file`](io.md#import_file)`(format: "stl")` to bring the reference mesh in first.

---

## `pick_surface_point`

Cast a ray through pixel (`screenX`, `screenY`) of a `render_preview`-framed view and return the nearest world-space surface point on a body, plus the `bodyId` and a `selectionId`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `screenX` | number | yes | Pixel X coordinate (top-left origin) within the `options.width × options.height` image. |
| `screenY` | number | yes | Pixel Y coordinate (top-left origin) within the `options.width × options.height` image. |
| `options` | object | no | Camera / framing — same shape as `render_preview.options` (`camera`, `cameraPosition`/`Target`/`Up`, `width`, `height`). Must match the preview you are picking into. |
| `id` | string | no | Optional explicit `selectionId` to assign to the picked point. |

**Returns** — World-space `point [x, y, z]`, `bodyId`, and `selectionId`. The `selectionId` is a valid anchor for `add_dimension`, enabling you to measure to an arbitrary surface point rather than a topology centroid.

**Example**

```json
// tool call arguments
{
  "screenX": 612,
  "screenY": 480,
  "options": { "camera": "iso", "width": 1200, "height": 900 }
}
```
```json
// example result
{
  "point": [12.4, 0.0, 8.7],
  "bodyId": "part",
  "selectionId": "sel:part#surfacePoint[0]"
}
```

**Notes** — Always pass the same `options` that were used in the preceding `render_preview` call; mismatched framing will produce incorrect world coordinates. The returned `selectionId` can be passed directly to `add_dimension` as an anchor.

---

## `generate_drawing`

Render a multi-view ISO 128-30 DXF technical drawing. Pass `bodyId` for a single-part drawing with sections and dimensions, or `bodyIds` (two or more bodies) for a general-arrangement assembly sheet with a parts list and numbered balloons.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `outputPath` | string | yes | Write path for the `.dxf` file. |
| `spec` | object | yes | `DrawingSpec` object: `{ sheet, title?, views, sections?, dimensions?, ... }`. See `OCCTSwiftScripts/Sources/DrawingComposer/Spec.swift`. Per-view sections/dimensions are not applied on general-arrangement sheets. |
| `bodyId` | string | no | Single body — produces a standard part drawing. |
| `bodyIds` | string[] | no | Two or more bodies — produces a general-arrangement assembly sheet. Takes precedence over `bodyId`. |

**Returns** — Path to the written `.dxf` file and a summary of views generated. Returns an error if neither `bodyId` nor `bodyIds` resolves to a loaded body.

**Example**

```json
// tool call arguments
{
  "bodyId": "bracket",
  "outputPath": "/tmp/bracket.dxf",
  "spec": {
    "sheet": "A3",
    "title": "Bracket — Rev A",
    "views": ["front", "top", "right", "iso"]
  }
}
```
```json
// example result
{
  "outputPath": "/tmp/bracket.dxf",
  "views": ["front", "top", "right", "iso"],
  "bodyCount": 1
}
```

**Notes** — For assembly sheets (`bodyIds`), per-view sections and dimensions in the `spec` are ignored; the sheet receives a shared multi-body view with an auto-generated parts list and one balloon per body. `bodyIds` takes precedence over `bodyId` when both are supplied.

**Drives** — `DrawingComposer` (from `OCCTSwiftScripts`); ISO 128-30 projection engine in `OCCTSwift`.
