---
title: Drawing read
parent: Tool Reference
nav_order: 13
---

# Drawing read

Four read-only tools that let an agent read a 2D engineering drawing as a drawing: its entities,
layers, dimensions and measurements, as coordinates and numbers, never as an image. They are built
on OCCTSwiftIO's `DrawingLoader` (DXF, DWG and JWW, in SwiftDXF's entity model) and run in-process. A drawing is a file the
agent reads, not a scene body: none of these tools touches the scene or `manifest.json`.

## Tools

- [`read_drawing`](#read_drawing) · [`list_drawing_entities`](#list_drawing_entities) ·
  [`list_drawing_dimensions`](#list_drawing_dimensions) · [`measure_drawing`](#measure_drawing)

**Server:** Swift only. The Node server has no drawing reader.

Every tool takes `inputPath`, the absolute path of an **ASCII DXF, a DWG or a JWW** file (a leading
`~` is expanded); the format is told from the file's bytes, and its extension only when the bytes say
nothing. Every tool also takes two options that change what is read, [below](#read-options). Parsed
drawings are cached by path, size, modification time and those options, so a run of calls on one
file parses it once and an edited file is read again. An edit that keeps the size and lands within
the filesystem's timestamp resolution of the previous read would be served from the cache; the
`sha256` in every result says which bytes were read.

Arguments must have the right type (`types`, `layers`, `kinds` arrays of strings, `rect` four
numbers, `limit` and `offset` integers, `mmPerUnit` a number, `expandBlocks` and `skipPaperSpace`
true or false); a wrong type is an error, not an
ignored argument; so is an argument name the tool does not take (`layer` for `layers`) and a
`limit` outside 1 to 5000. JSON `null` means the argument is absent. An entity id has one spelling,
exactly what the tools return, so `e+5` and `e007` are refused. A coordinate that is not finite (a
`1e999` in the file) is written as the string `"inf"`, `"-inf"` or `"nan"` instead of failing the
result.

## What is read, and what is not

- **DXF** (ASCII), **DWG** and **JWW** are read, into one entity model: `LINE`, `CIRCLE`, `ARC`,
  `ELLIPSE`, `POINT`, `TEXT` / `MTEXT`, `LWPOLYLINE` / `POLYLINE`, `SPLINE`, `HATCH`, `LEADER` and
  `DIMENSION`. Binary DXF is refused with a message. A DWG is read in process by SwiftDWG
  (releases R2000 to R2018, and R14 for simple entities, lightweight polylines and hatches; R12 and
  earlier are refused with the release named), a JWW through SwiftJWW's DXF writer.
  `source.format` says which it was.
- **A JWW is read at full size.** Jw_cad draws at a scale (1:80, say), and the reader multiplies
  each layer group's lengths by its own scale, so an entity is its real size and not the drawn one.
  A JWW declares millimetres (SwiftJWW 2.0); see **Units** below.
  `layerGroupScales` in `read_drawing` says what was applied to each group that holds a top-level
  element (a group used only inside blocks is not listed). A block's members keep their own layer
  names but take the scale of the group of the reference that places them, so a layer `1-3` next to
  a listed group 1 can be at group 0's scale. A group that states no usable scale is read at drawn
  size (`scale` 1 in `layerGroupScales`) and the loader warns. Groups at different scales get a
  warning that names them, and each is at full size on its own, so a `measure_drawing` distance
  between entities of two groups is not the distance on the sheet. Every distance in such a drawing
  carries a note that says so, whichever entities it measures. JWW layers are named
  `<group>-<layer>` in hexadecimal, such as `0-E`. A dimension Jw_cad keeps as loose lines and text
  is rebuilt as a `DIMENSION` and marked `rebuilt: true`; a dimension value that nothing explains
  stays in the drawing as a loose text and has a warning that names it. Only the top level of a JWW
  is scanned for dimensions: loose dimension pieces inside a block are not rebuilt, and an older
  dimension record inside a block is not listed (OCCTSwiftIO 2.0.0-beta.10, known limits), so a JWW
  whose dimensions are loose pieces in blocks can show none in `rebuiltDimensions` or
  `list_drawing_dimensions`. A stored dimension record in a block is listed. An older record is one
  from a file before Jw_cad 4.20, which keeps no measured points: at the top level it is not a
  dimension either, it stays as a line and text, and a warning names its value. Inside a block it
  stays as a line and text too, as entities of that block, but with no warning.
- **A DWG's insert attributes are not read** (as of SwiftDWG 0.2.0 it does not decode `ATTRIB` and
  `ATTDEF`, SecondMouseAU/SwiftDWG#9), so the values in a DWG title block are missing.
- **A file that is damaged says so.** A DWG that is truncated or whose structure does not add up
  fails with SwiftDWG's reason. A DWG whose entities or table records it cannot read is read without
  them, and the loader's warning says how many (`warnings`).
- **Block references are expanded by default** (see [Read options](#read-options)).
- **Extrusion directions are read.** An entity on a `-z` plane comes back mirrored into the world;
  a tilted extrusion is read as written and the loader warns about it.
- **A newer SwiftDXF may add entity types.** An entity the tools have no mapping for is listed with
  type `other` and no layer, colour, bounds or geometry (nothing is made up), a layer filter never
  matches it, `read_drawing` warns about it and `measure_drawing` refuses it.
- **What the reader skips is reported, not hidden.** An entity type SwiftDXF does not read (an
  `MLINE`, say) is counted in `skipped`, by type and, where the format says, by
  layer. A DWG counts its skipped entities, and a JWW its solid fills, without their layer, so they
  are in `byType` and `total` but not in `byLayer`. An `INSERT` is not an entity, so SwiftDXF counts
  it as skipped until its block is expanded and then takes it out itself: an `INSERT` that is still
  in `skipped` was not expanded (`expandBlocks` is false, the file does not define its block, or the
  expansion limit stopped short), and a warning says which. SwiftDXF 0.6 reads an `INSERT`'s
  `ATTRIB` records with it, so they are no longer counted as skipped (up to 0.5 they were).
  A JWW solid fill inside a block is not counted: OCCTSwiftIO 2.0.0-beta.10 reports only top-level
  fills (SecondMouseAU/OCCTSwiftIO#81 fixes it after that release).
- **A hatch is not measurable**, and a spline leader is measured along its straight segments; see
  [`measure_drawing`](#measure_drawing).

## Read options

Every tool takes both, and every result echoes them under `source.options`, because the entity ids
depend on them.

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `expandBlocks` | boolean | `true` | Flatten block references (`INSERT`) into the entities, so a block insert places the geometry it stands for. Each expanded entity carries the references it came through in `via` and the block names in `blocks`. With `false`, inserts stay references: they are in `skipped`, and `read_drawing` warns that they are not expanded. |
| `skipPaperSpace` | boolean | `false` | Leave paper-space entities out, as a model-space read does. With `false` they are read, and the loader warns how many there are. |

## Identity and units

- **Entity ids.** An entity's id is `e` and its position in the drawing's entity list (`e0`,
  `e1`, ...). It is stable for the same file bytes, the same read options and the same readers:
  `read_drawing` returns the file's SHA-256, and every result carries the file name, hash, the
  release line of each reader that read the file (`source.readerVersions`, see **Readers** below)
  and the options, so a caller can tell when ids no longer mean what they did. SwiftDXF 0.5.0
  and later decode TEXT and MTEXT, so a `text` string can differ from the raw string in the file (`%%c`
  comes back as `⌀`). Turning block expansion on or off, or a newer SwiftDXF that models more
  types, shifts the ids after them. Skipped records take no index.
- **Readers.** A file goes through one reader or two, and a new release of either can shift its
  ids. `source.readerVersions` is an object with one entry for each reader that produced that
  file's entities, keyed by the reader's name, whose value is its release line (major and minor,
  such as `0.5`):

  | `source.format` | `source.readerVersions` | What read it |
  |-----------------|-------------------------|--------------|
  | `dxf` | `{ "SwiftDXF": "0.5" }` | SwiftDXF |
  | `dwg` | `{ "SwiftDXF": "0.5", "SwiftDWG": "0.2" }` | SwiftDWG turns the DWG into DXF text, which SwiftDXF reads |
  | `jww` | `{ "SwiftDXF": "0.5", "SwiftJWW": "1.5" }` | SwiftJWW's DXF writer turns the JWW into DXF text, which SwiftDXF reads |

  A reader the file did not go through is not listed, so a DXF is unaffected by a new SwiftJWW.
  `source.readerVersion` is the SwiftDXF line alone and equals `readerVersions.SwiftDXF`; it is
  kept for clients that already read it, and it does not move when only SwiftDWG or SwiftJWW does,
  so compare `readerVersions`. A line is major and minor, the part of a version that decides which
  entity types are modelled and so which ids an entity gets; a patch release does not change it.
  SwiftPM has no runtime query for a dependency's version, so each line is written in the code and
  one test per reader holds it to that reader's pin in `Package.resolved`. A host that embeds
  `OCCTMCPCore` and resolves a newer minor of a reader than the line recorded reports the recorded
  line with ids that differ; those tests read this repository's `Package.resolved` only.
- **Handles.** An id is a position, so it does not survive an edit that moves entities. Every entity
  and every dimension also carries `handle` (the DXF handle, group 5, absent when the file has none;
  a DWG keeps its own) and `locator` (the section and position, `ENTITIES:12`, present even without
  handles), and an entity that came out of a block expansion carries `via` (the references it came
  through, outermost first, each a handle or a locator) and `blocks` (their names). To find an
  entity again after an edit, match its `handle` in a fresh `list_drawing_entities`. An expanded
  entity keeps the handle of the entity inside its block, so two references to one block give entities
  with the same handle, told apart by `via`. A `source.bytes` is the size of the file the path
  resolves to, a symlink's target included.
- **Units.** Coordinates and values are in **drawing units**. The drawing's units are the DXF
  `$INSUNITS` code, returned with its name and millimetres per unit (codes 0 to 24 as ezdxf lists
  them). A unitless or undeclared drawing has no millimetre figure and the tools say so; pass
  `mmPerUnit` to `measure_drawing` to supply one. A JWW declares millimetres (SwiftJWW 2.0 writes
  `$INSUNITS` 4), so it has a `valueMm` like any drawing with a declared unit, and a JWW at full
  size is in those millimetres; up to SwiftJWW 1.5 it declared none, `read_drawing` warned of it
  and `mmPerUnit: 1` supplied the figure. An angle is in degrees and never has a millimetre figure,
  including the angle an angular dimension's own points give (`valueFromPoints`).

---

## `read_drawing`

Summarise a drawing: counts, layers, units, extents, the source record and what was skipped. Start
here.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF, DWG or JWW file. |

**Returns**: `entityCount`, `byType`, `layers` (each with its name, total and counts by type),
`units` (`insUnits`, `name`, `mmPerUnit`), `extents` (`declared` from the header's `$EXTMIN` /
`$EXTMAX`, `computed` from the entities, which can differ when an editor left the header stale),
`source` (`path`, `fileName`, `bytes`, `sha256`, `format` (`dxf`, `dwg` or `jww`), `dxfVersion` (a
DXF's `$ACADVER`), `formatVersion` (the format's own version: `$ACADVER`, the DWG version code,
the JWW file version), `reader`, `readerVersion` (the SwiftDXF release line), `readerVersions` (the
release line of every reader that read the file, see **Readers**), `options`), `skipped` (`total`,
`byType`, `byLayer`) and `warnings`. `warnings` carries the loader's own messages (missing or cyclic blocks,
paper space, entities that a non-uniform scale could not carry, a DWG's unreadable entities, a JWW's
unexplained dimension values and mixed or unstated scales) as well as the tool's (an empty drawing,
no usable units). A JWW also gets `layerGroupScales` (each with `group`, `layerNamePrefix` and
`scale`) and, when any were rebuilt, `rebuiltDimensions` (a count); a DXF or a DWG has neither.

**Example**

```json
{ "inputPath": "/Users/me/drawings/slot.dxf" }
```

```json
{
  "entityCount": 4,
  "byType": { "line": 2, "circle": 1, "dimension": 1 },
  "layers": [
    { "name": "DIMS", "total": 1, "byType": { "dimension": 1 } },
    { "name": "HOLES", "total": 1, "byType": { "circle": 1 } },
    { "name": "SLOT", "total": 2, "byType": { "line": 2 } }
  ],
  "units": { "insUnits": 4, "name": "millimetres", "mmPerUnit": 1 },
  "extents": {
    "declared": { "min": [0, 0, 0], "max": [60, 40, 0] },
    "computed": { "min": [0, -4, 0], "max": [33, 23, 0] }
  },
  "skipped": { "total": 1, "byType": { "INSERT": 1 }, "byLayer": { "BLOCKS": { "INSERT": 1 } } },
  "source": {
    "fileName": "slot.dxf", "bytes": 410, "format": "dxf", "dxfVersion": "AC1027",
    "formatVersion": "AC1027", "readerVersion": "0.6", "readerVersions": { "SwiftDXF": "0.6" },
    "options": { "expandBlocks": true, "skipPaperSpace": false },
    "sha256": "5c9c59756de36f6cddd4c027d7eb956005d7d19ca3935f0737cf51b6e2f6f9a2"
  },
  "warnings": ["1 entity record(s) were skipped; see `skipped`."]
}
```

(`source.path` and `source.reader` are also returned and are left out above for width.)

---

## `list_drawing_entities`

List entities with identity, geometry and layer, filtered by type, layer or a rectangle on the
sheet.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF, DWG or JWW file. |
| `types` | string[] | no | Any of `line`, `circle`, `arc`, `ellipse`, `point`, `text`, `polyline`, `spline`, `hatch`, `leader`, `dimension`, `solid`, `wipeout`, `face3d`, `tolerance`. |
| `layers` | string[] | no | Layer names to keep. |
| `rect` | number[4] | no | `[xmin, ymin, xmax, ymax]` on the sheet, in drawing units. |
| `rectMode` | string | no | `intersects` (default) keeps entities whose bounds overlap `rect`; `within` keeps those wholly inside it. |
| `limit` | integer | no | Page size, default 200, at most 5000. |
| `offset` | integer | no | Entities to skip, default 0. |

**Returns**: `total` (matches before paging), `offset`, `returned`, `truncated`, `unit`
(`drawing units`) and `entities`. Each entity has `id`, `type`, `layer`, `color` (the AutoCAD Color
Index; 256 is by-layer), `bounds` and its geometry:

| Type | Fields |
|------|--------|
| `line` | `start`, `end`, `length` |
| `circle` | `center`, `radius` |
| `arc` | `center`, `radius`, `startAngleDeg`, `endAngleDeg`, `sweepDeg`, `start`, `end`, `length` (counter-clockwise from start to end) |
| `ellipse` | `center`, `majorAxis` (relative to the center), `ratio`, `startParam`, `endParam` (radians) |
| `polyline` | `vertices`, `bulges` (only when a segment is curved; a bulge is `tan(θ/4)` of the arc leaving that vertex), `closed`, `length` |
| `spline` | `degree`, `closed`, `periodic`, `rational`, and as stored in the file: `controlPoints`, `knots` (the flat knot vector), `weights` (rational splines) and `fitPoints` (each left out when the file has none) |
| `hatch` | `patternName`, `solid`, `boundaryPaths`: each path has `external` (an outer boundary, otherwise an island or a hole) and `kind`, `polyline` (`vertices`, `bulges`, `closed`) or `edges` (a chain of `line`, `arc`, `ellipse` and `spline` edges, each as numbers in the drawing plane; an arc's or ellipse's angles always run counter-clockwise from start to end, and `counterClockwise` says which way the path travels it). Only the boundary and the fill kind are read, not the hatch lines. |
| `leader` | `vertices` (from the arrowhead end), `arrowhead`, `splinePath` (it curves through the vertices), `annotationHandle` (the text or block it is attached to), `styleName` |
| `solid` | `vertices` (the outline of the filled triangle or quadrilateral, in the order that walks it), `closed` |
| `wipeout` | `vertices` (the masking polygon in the world, without a closing vertex), `closed` |
| `face3d` | `vertices` (four corners in outline order, with z; a triangle repeats its third corner as its fourth), `closed` |
| `tolerance` | `at` (where the frame is placed), `rotationDeg`, `text` (the frame string as the file writes it), `styleName`; its box is its insertion point, since the frame's size comes from a dimension style the reader does not carry |
| `text` | `at`, `height`, `rotationDeg`, `text` |
| `point` | `at` |
| `dimension` | `dimension`, the record `list_drawing_dimensions` returns |

Bounds are tight for arcs (an arc of under half a turn does not contain its centre) and for the
arcs of a bulged polyline. A spline's box follows the curve (the curve flattened to within a
ten-thousandth of the size of its control data, so the box can fall short of it by that much), not
its control polygon, so a window that clears the curve does not touch it. A hatch's box is the union of its boundary paths, by the same rules (an
arc edge is tight, an ellipse edge takes its whole ellipse); a leader's is its vertices'. An
elliptical arc takes the bounds of its whole ellipse, and text is its insertion point, because the reader keeps no text extent.

**Example**: the two walls of a slot.

```json
{ "inputPath": "/Users/me/drawings/slot.dxf", "layers": ["SLOT"] }
```

```json
{
  "total": 2, "offset": 0, "returned": 2, "truncated": false, "unit": "drawing units",
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c...", "readerVersion": "0.5",
             "readerVersions": { "SwiftDXF": "0.5" },
             "options": { "expandBlocks": true, "skipPaperSpace": false } },
  "entities": [
    { "id": "e0", "type": "line", "layer": "SLOT", "color": 256, "start": [0, 0, 0], "end": [0, 20, 0], "length": 20,
      "bounds": { "min": [0, 0, 0], "max": [0, 20, 0] } },
    { "id": "e1", "type": "line", "layer": "SLOT", "color": 256, "start": [8, 0, 0], "end": [8, 20, 0], "length": 20,
      "bounds": { "min": [8, 0, 0], "max": [8, 20, 0] } }
  ]
}
```

---

## `list_drawing_dimensions`

Every `DIMENSION` in the drawing, with its value and the points that define it.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF, DWG or JWW file. |
| `layers` | string[] | no | Layer names to keep. |
| `kinds` | string[] | no | Any of `linear`, `aligned`, `angular`, `diameter`, `radius`, `angular3Point`, `ordinate`. |
| `limit` | integer | no | Page size, default 500, at most 5000. |
| `offset` | integer | no | Dimensions to skip, default 0. |

**Returns**: `total`, `offset`, `returned`, `truncated`, `units` and `dimensions`. Each dimension
has `id` (the same `e<index>` as in `list_drawing_entities`), `kind`, `valueKind` (`length` or
`angle`), `value` (the stored measurement, DXF group 42, absent when the file omits it, which ezdxf notes is
common, or stores zero or a negative number, which SolidWorks and McMaster files use for "none"),
`valueUnit`, `valueMm`, `valueFromPoints` and `valueFromPointsMm` (see below), `text` (the
user's text override, absent when the dimension shows its own value: a text of exactly `<>` is
DXF's "show the measured value", `<> H7` is kept, and a single space, DXF's "suppress the text", is
returned as a single space),
`textPosition`, `definitionPoints`, `layer`, `color`, `rotationDeg` (a linear dimension's measuring
direction, absent when the file gives none, which means horizontal), `obliqueAngleDeg`, `styleName`,
and where it is in the file: `handle`, `locator` and, for one that came out of a block expansion,
`via` and `blocks`. `rebuilt` is `true` for a dimension a JWW kept as loose pieces and the reader
rebuilt, and absent for one the file stores.

- Each definition point carries its DXF `group` (10, 13, 14, 15 or 16) and, where SwiftDXF
  documents it, a `role`: a linear or aligned dimension has `dimensionLine`,
  `extensionLine1Origin` and `extensionLine2Origin`; a radius or diameter has `measuredFrom` and
  `measuredTo`. Other kinds return the groups with no role.
- `valueMm` is the value times millimetres per unit, for the length kinds only. An **angular**
  value is returned as stored: DXF does not declare its unit, so it has no `valueMm`.
- `valueFromPoints` is the measurement the dimension's own geometry gives (SwiftDXF's
  `computedMeasurement`): the distance between the two extension-line origins along the dimension's
  `rotationDeg` for a `linear` one, between them for an `aligned` one, between the two ends of a
  `radius` or `diameter`. It is the value when the file stores none, and a check when it does: a
  stale or overridden dimension disagrees with its geometry (a stored 7 over extension lines 8
  apart). It is absent for an angular or ordinate dimension.

**Example**

```json
{ "inputPath": "/Users/me/drawings/slot.dxf" }
```

```json
{
  "total": 1, "offset": 0, "returned": 1, "truncated": false,
  "units": { "insUnits": 4, "name": "millimetres", "mmPerUnit": 1 },
  "dimensions": [
    {
      "id": "e3", "kind": "aligned", "valueKind": "length", "value": 8, "valueUnit": "drawing units", "valueMm": 8,
      "valueFromPoints": 8, "valueFromPointsMm": 8,
      "textPosition": [4, -4, 0], "layer": "DIMS", "color": 256,
      "definitionPoints": [
        { "group": 10, "role": "dimensionLine", "point": [0, -4, 0] },
        { "group": 13, "role": "extensionLine1Origin", "point": [0, 0, 0] },
        { "group": 14, "role": "extensionLine2Origin", "point": [8, 0, 0] }
      ]
    }
  ]
}
```

---

## `measure_drawing`

Distance, angle or radius between named entities or points.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF, DWG or JWW file. |
| `measure` | string | yes | `distance`, `angle` or `radius`. |
| `a` | string or number[] | for all | An entity id such as `"e12"`, or a point `[x, y]` or `[x, y, z]`. |
| `b` | string or number[] | `distance`, `angle` | The same. |
| `vertex` | number[] | no | For `angle` between points: the apex. |
| `mmPerUnit` | number | no | Millimetres per drawing unit, overriding the drawing's declared units. |

- **`distance`**: the minimum distance between `a` and `b`, each an entity or a point, with the
  nearest point on each (`pointOnA`, `pointOnB`). It is OCCT's exact extrema over edges built from
  the entities, so the width of a slot is the true gap between its two walls, whether they are lines
  or arcs, and a circle, an arc and a polyline (curved segments included) are measured along their
  curves. A spline whose control data defines a curve is an exact NURBS edge, over its valid
  parameter domain (clamped or unclamped knots, rational or not). One that does not (fit points
  only, a knot vector of the wrong length or order, an empty domain, a degree above the 25 OCCT's
  B-spline curves go to, or a closed spline whose ends
  do not meet, which SwiftDXF closes with a chord, as measured on the curve and not on the control
  points) is cut into chords within a tolerance of
  one ten-thousandth of the size of its control data, and the result says so in `notes`. An ellipse
  is cut into 48 chords, because OCCT's ellipse edge takes no major-axis direction, and the result
  says so in `notes` too. A `leader` is measured along the straight segments between its
  vertices (a spline leader curves through them, so the result says it is not exact). A `hatch`
  has no single edge to measure: measure the entities that bound it, or pass its boundary points
  from `list_drawing_entities` as points; so do a `solid`, a `wipeout` and a `face3d`, which have
  `vertices` and no single edge. A `text` or a `tolerance` entity has no geometry to measure: pass
  its `at` point. A `dimension` has none either: measure the entities it dimensions, or pass its
  definition points from `list_drawing_dimensions` as points.
- **`angle`**: two `line` entities, or `vertex` with two points `a` and `b`. `value` is in degrees
  between 0 and 180 and runs between the lines' drawn directions (start to end); `acuteAngleDeg` is
  the angle between the lines as undirected lines, 0 to 90.
- **`radius`**: a `circle` or `arc` entity as `a`. Returns the radius and the `diameter`.

**Returns**: `measure`, `a` / `b` / `vertex` (what each end resolved to), `value` and `unit`
(`drawing units`, or `degrees` for an angle), `valueMm` (absent for an angle and when the units are
unknown), `mmPerUnit`, and `notes` (an approximation, and for a JWW whose layer groups are at
different scales, the note that a distance across groups is not the sheet distance).

**Example**: the slot width, measured between its two named walls rather than read off a picture.

```json
{ "inputPath": "/Users/me/drawings/slot.dxf", "measure": "distance", "a": "e0", "b": "e1" }
```

```json
{
  "measure": "distance",
  "a": { "kind": "entity", "id": "e0", "type": "line" },
  "b": { "kind": "entity", "id": "e1", "type": "line" },
  "value": 8, "unit": "drawing units", "valueMm": 8, "mmPerUnit": 1,
  "pointOnA": [0, 0, 0], "pointOnB": [8, 0, 0],
  "notes": [],
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c...", "readerVersion": "0.5",
             "readerVersions": { "SwiftDXF": "0.5" },
             "options": { "expandBlocks": true, "skipPaperSpace": false } }
}
```

That is the stored value of the slot's own dimension (`list_drawing_dimensions` returns 8 for it),
so a stale or overridden dimension shows up as a mismatch.

**Errors**: a missing file, an unsupported format, an id that is not `e<number>` or is out of range,
a `text` or `dimension` end for `distance`, and a non-line for `angle` each return `isError` with
the reason.
