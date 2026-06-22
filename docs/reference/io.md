---
title: I/O
parent: Tool Reference
nav_order: 8
---

# I/O

Tools for bringing geometry into the scene from disk, exporting the scene to standard CAD formats, and annotating XCAF assembly documents with structured metadata. Use these when loading existing BREPs or neutral-format files, shipping deliverables, or stamping part numbers and materials onto an assembly.

## Tools

- [`read_brep`](#read_brep) · [`import_file`](#import_file) · [`export_scene`](#export_scene) · [`set_assembly_metadata`](#set_assembly_metadata)

---

## `read_brep`

Add a `.brep` file from disk to the scene as a new body.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `inputPath` | string | yes | Path to the `.brep` file to load. |
| `bodyId` | string | no | ID to assign in the scene manifest; auto-generated if omitted. |
| `color` | number[] | no | RGB or RGBA colour for the body (values 0–1). |
| `allowInvalid` | boolean | no | Load a topologically invalid / loose-face shape as-is (skip the validity write-gate) so `compute_metrics` / `measure_deviation` / `validate_geometry` can run on an in-progress reconstruction. Default `false`. |

**Returns** — The updated scene manifest entry for the new body, including its assigned `bodyId` and bounding info. Returns an error if the file does not exist or fails to parse (and `allowInvalid` is `false`).

**Example**

```json
// tool call arguments
{ "inputPath": "/Users/me/output/part.brep", "bodyId": "part", "color": [0.7, 0.7, 0.8] }
```
```json
// example result
{ "bodyId": "part", "name": "part", "path": "/Users/me/output/part.brep" }
```

**Notes** — Set `allowInvalid: true` when loading a mesh-reconstructed solid that has open shells or non-manifold edges; the shape is added as-is so you can immediately call `validate_geometry` to inspect its defects or `measure_deviation` to certify it against a reference mesh. The validity gate is re-applied on the next `export_scene` call.

---

## `import_file`

Multi-format CAD import (STEP / IGES / BREP / OBJ). Adds the imported shape as a single body.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `inputPath` | string | yes | Path to the file to import. |
| `format` | `"auto"` \| `"step"` \| `"iges"` \| `"obj"` \| `"brep"` | no | File format; defaults to `"auto"`, inferred from extension (`.step`/`.stp`, `.iges`/`.igs`, `.obj`, `.brep`/`.brp`). |
| `idPrefix` | string | no | Prefix for auto-generated body IDs when the file contains multiple parts. |
| `allowInvalid` | boolean | no | Import a topologically invalid / loose-face shape as-is (skip the validity write-gate) so the analysis tools can measure an in-progress reconstruction. Default `false`. |

**Returns** — The scene manifest entries for all bodies added, each with its `bodyId`. Returns an error if the format is unrecognised or import fails.

**Example**

```json
// tool call arguments
{ "inputPath": "/Users/me/models/bracket.step", "format": "step", "idPrefix": "bracket" }
```
```json
// example result
{ "added": [{ "bodyId": "bracket_0", "name": "bracket_0" }] }
```

**Notes** — Like `read_brep`, `allowInvalid: true` bypasses the write-gate so you can load a loose-face or open-shell STEP file produced by a reconstruction tool and immediately measure it with `measure_deviation` or `validate_geometry`. STEP assemblies with multiple solids produce one body per solid, each prefixed with `idPrefix`.

BREP (`.brep` / `.brp`) is a single shape, so it imports as one body. On the **Swift** server it loads in-process via `Shape.loadBREP`. On the **Node** server it is routed to the occtkit `load-brep` verb — occtkit's `import` verb itself has no BREP loader — so `import_file` is a single entry point for every format on both servers (you don't need to fall back to `read_brep` for BREP).

---

## `export_scene`

Export the current scene (or a named subset of bodies) to STEP / IGES / BREP / STL / OBJ / glTF / GLB.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `format` | `"step"` \| `"iges"` \| `"brep"` \| `"stl"` \| `"obj"` \| `"gltf"` \| `"glb"` | yes | Output format. |
| `outputPath` | string | yes | Destination file path (must be writable). |
| `bodyIds` | string[] | no | Subset of body IDs to export; omit to export the entire scene. |

**Returns** — Confirmation with the written `outputPath` and the list of body IDs exported. Returns an error if no scene bodies exist or the path is not writable.

**Example**

```json
// tool call arguments
{ "format": "step", "outputPath": "/Users/me/output/assembly.step" }
```
```json
// example result
{ "outputPath": "/Users/me/output/assembly.step", "exported": ["base", "bracket", "lid"] }
```

**Notes** — `glb` produces a single binary glTF bundle suitable for web viewers. Use `bodyIds` to isolate a subassembly without removing bodies from the scene. Internally this runs a one-shot templated script via `occtkit` on both the Swift and Node servers.

---

## `set_assembly_metadata`

Write XCAF document- or component-level metadata onto an OCAF document and save as binary `.xbf`. Mirrors `occtkit set-metadata`.

**Server:** Swift + Node

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `inputPath` | string | yes | STEP or XBF input file. |
| `outputPath` | string | yes | Output `.xbf` path. |
| `metadata` | object | yes | Metadata fields to write (see sub-fields below). |
| `scope` | `"document"` \| `"component"` | no | Whether to target the whole document or a specific component. |
| `componentId` | integer | no | Component index to target when `scope` is `"component"`. |

`metadata` sub-fields (all optional within the object):

| name | type | description |
|------|------|-------------|
| `title` | string | Assembly or component title. |
| `partNumber` | string | Part number. |
| `revision` | string | Revision string. |
| `material` | string | Material name. |
| `weight` | number | Weight value. |
| `drawnBy` | string | Author or drafter name. |
| `customAttrs` | object (string→string) | Arbitrary key/value pairs. |

**Returns** — Confirmation with the written `outputPath`. Returns an error if the input file cannot be read or the output path is not writable.

**Example**

```json
// tool call arguments
{
  "inputPath": "/Users/me/output/assembly.step",
  "outputPath": "/Users/me/output/assembly_meta.xbf",
  "scope": "document",
  "metadata": {
    "title": "Mounting Bracket",
    "partNumber": "MB-0042",
    "revision": "B",
    "material": "6061-T6 Aluminium",
    "drawnBy": "E. Lynch-Bell",
    "customAttrs": { "project": "OCCTMCP-demo" }
  }
}
```
```json
// example result
{ "outputPath": "/Users/me/output/assembly_meta.xbf" }
```

**Notes** — The output is always `.xbf` (binary OCAF format), regardless of the input format. To target a specific sub-component, set `scope: "component"` and provide `componentId` (zero-based index into the XCAF shape tree). Use `inspect_assembly` (see [Introspection & measurement](introspection.md#inspect_assembly)) to discover component indices first.
