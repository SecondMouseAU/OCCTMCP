---
title: Import, export & assemblies
parent: Cookbook
nav_order: 8
---

# Import, export & assemblies

This recipe covers the four I/O tools in a realistic order: load native BREP and neutral-format
files, ship the scene to standard exchange formats, and walk / annotate an XCAF assembly.

All four tools run on both the Swift and Node servers.

---

## 1. Load a native BREP with `read_brep`

The simplest import — a single `.brep` file that is already on disk (written by a previous
`execute_script` run or a CAD tool).

```json
// tool call — read_brep
{
  "inputPath": "/Users/me/output/housing.brep",
  "bodyId": "housing",
  "color": [0.6, 0.65, 0.75]
}
```

```json
// example result
{ "bodyId": "housing", "name": "housing", "path": "/Users/me/output/housing.brep" }
```

The body is now in the scene manifest under id `"housing"` and live-reloads in the viewport.

<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>

<model-viewer src="models/import-export.glb" poster="images/import-export.png" alt="Imported L-bracket" camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1" style="width:100%;max-width:480px;height:360px;background:#eef1f5;border-radius:6px"></model-viewer>

<sub>🖱️ Drag to orbit · scroll to zoom · auto-rotating. (Model exported via `export_scene` → glTF.)</sub>

### Loading a loose-face / in-progress reconstruction

A mesh-reconstructed BREP often has open shells or non-manifold edges that fail the default validity
gate. Pass `allowInvalid: true` to bypass the gate and load the shape as-is so you can measure it:

```json
// tool call — read_brep (invalid reconstruction)
{
  "inputPath": "/Users/me/reconstruct/part_draft.brep",
  "bodyId": "draft",
  "allowInvalid": true
}
```

```json
// example result
{ "bodyId": "draft", "name": "draft", "path": "/Users/me/reconstruct/part_draft.brep" }
```

With `draft` in the scene you can call `validate_geometry` to enumerate defects, or
`measure_deviation` to certify it against a reference mesh — see the
[Measurement & verification](measurement.md) recipe for that flow.

Reference: [`read_brep`](../../reference/io.md#read_brep)

---

## 2. Import a STEP or IGES file with `import_file`

`import_file` handles STEP, IGES, OBJ, and BREP. A STEP assembly with multiple solids produces one
body per solid.

```json
// tool call — import_file (STEP)
{
  "inputPath": "/Users/me/Downloads/bracket_assy.step",
  "format": "step",
  "idPrefix": "bracket"
}
```

```json
// example result
{
  "added": [
    { "bodyId": "bracket_0", "name": "bracket_0" },
    { "bodyId": "bracket_1", "name": "bracket_1" },
    { "bodyId": "bracket_2", "name": "bracket_2" }
  ]
}
```

Use `idPrefix` so the auto-generated body IDs are human-readable and easy to reference in
subsequent tool calls.

### Importing a loose-face IGES for in-progress measurement

Same pattern as `read_brep`: add `allowInvalid: true` to skip the validity gate.

```json
// tool call — import_file (IGES, allowInvalid)
{
  "inputPath": "/Users/me/reconstruct/surface_draft.iges",
  "format": "iges",
  "idPrefix": "surf",
  "allowInvalid": true
}
```

```json
// example result
{ "added": [{ "bodyId": "surf_0", "name": "surf_0" }] }
```

Then pass `surf_0` to `measure_deviation` as the `bodyIdA` (reconstruction) and your reference mesh
as `bodyIdB` — detailed in [Measurement & verification](measurement.md).

Reference: [`import_file`](../../reference/io.md#import_file)

---

## 3. Export the scene with `export_scene`

Export the entire current scene or a named subset. The `format` and `outputPath` fields are
required; omit `bodyIds` to export everything.

### STEP (interop deliverable)

```json
// tool call — export_scene (STEP, whole scene)
{
  "format": "step",
  "outputPath": "/Users/me/output/assembly.step"
}
```

```json
// example result
{ "outputPath": "/Users/me/output/assembly.step", "exported": ["housing", "bracket_0", "bracket_1"] }
```

### STL (mesh for fabrication / slicing)

```json
// tool call — export_scene (STL, single body)
{
  "format": "stl",
  "outputPath": "/Users/me/output/housing.stl",
  "bodyIds": ["housing"]
}
```

```json
// example result
{ "outputPath": "/Users/me/output/housing.stl", "exported": ["housing"] }
```

### glTF / GLB (web / AR viewer)

```json
// tool call — export_scene (GLB, subassembly)
{
  "format": "glb",
  "outputPath": "/Users/me/output/bracket_assy.glb",
  "bodyIds": ["bracket_0", "bracket_1", "bracket_2"]
}
```

```json
// example result
{ "outputPath": "/Users/me/output/bracket_assy.glb", "exported": ["bracket_0", "bracket_1", "bracket_2"] }
```

`glb` produces a single binary glTF bundle. Use `bodyIds` to isolate a subassembly without
removing bodies from the scene.

Reference: [`export_scene`](../../reference/io.md#export_scene)

---

## 4. Walk an XCAF assembly with `inspect_assembly`

Before editing assembly metadata you need to know the component tree — particularly the
`componentId` indices used by `set_assembly_metadata`. Pass the STEP file directly via `inputPath`
(no scene import needed); use `depth` to limit how deep the traversal goes.

```json
// tool call — inspect_assembly
{
  "inputPath": "/Users/me/Downloads/bracket_assy.step",
  "depth": 3
}
```

```json
// example result
{
  "name": "BracketAssembly",
  "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
  "children": [
    {
      "name": "BaseFrame",
      "shape": "BaseFrame",
      "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
      "children": []
    },
    {
      "name": "MountingPlate",
      "shape": "MountingPlate",
      "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,15],[0,0,0,1]],
      "children": []
    }
  ]
}
```

`BaseFrame` is component 0, `MountingPlate` is component 1 (zero-based index into the XCAF shape
tree).

Reference: [`inspect_assembly`](../../reference/introspection.md#inspect_assembly)

---

## 5. Stamp metadata with `set_assembly_metadata`

Write structured metadata onto the document or a specific component, saving to `.xbf` (binary OCAF
format). The output is always `.xbf` regardless of the input format.

### Document-level stamp

```json
// tool call — set_assembly_metadata (document scope)
{
  "inputPath": "/Users/me/Downloads/bracket_assy.step",
  "outputPath": "/Users/me/output/bracket_assy_meta.xbf",
  "scope": "document",
  "metadata": {
    "title": "Bracket Assembly",
    "partNumber": "BKT-0017",
    "revision": "C",
    "material": "6061-T6 Aluminium",
    "drawnBy": "E. Lynch-Bell",
    "customAttrs": { "project": "OCCTMCP-demo", "supplier": "Acme Machining" }
  }
}
```

```json
// example result
{ "outputPath": "/Users/me/output/bracket_assy_meta.xbf" }
```

### Component-level stamp

Using `componentId: 1` to target `MountingPlate` (discovered in step 4 above):

```json
// tool call — set_assembly_metadata (component scope)
{
  "inputPath": "/Users/me/output/bracket_assy_meta.xbf",
  "outputPath": "/Users/me/output/bracket_assy_meta.xbf",
  "scope": "component",
  "componentId": 1,
  "metadata": {
    "partNumber": "MP-0003",
    "revision": "A",
    "material": "304 Stainless Steel",
    "weight": 0.42
  }
}
```

```json
// example result
{ "outputPath": "/Users/me/output/bracket_assy_meta.xbf" }
```

You can read from and write to the same output path to accumulate metadata in a single pass.

Reference: [`set_assembly_metadata`](../../reference/io.md#set_assembly_metadata)
