---
title: Drawing read
parent: Tool Reference
nav_order: 13
---

# Drawing read

Four read-only tools that let an agent read a 2D engineering drawing as a drawing: its entities,
layers, dimensions and measurements, as coordinates and numbers, never as an image. They are built
on OCCTSwiftIO's DXF import (SwiftDXF's entity model) and run in-process. A drawing is a file the
agent reads, not a scene body: none of these tools touches the scene or `manifest.json`.

## Tools

- [`read_drawing`](#read_drawing) · [`list_drawing_entities`](#list_drawing_entities) ·
  [`list_drawing_dimensions`](#list_drawing_dimensions) · [`measure_drawing`](#measure_drawing)

**Server:** Swift only. The Node server has no drawing reader.

Every tool takes `inputPath`, the absolute path of an **ASCII DXF** file (a leading `~` is
expanded). Parsed drawings are cached by path, size and modification time, so a run of calls on one
file parses it once and an edited file is read again. An edit that keeps the size and lands within
the filesystem's timestamp resolution of the previous read would be served from the cache; the
`sha256` in every result says which bytes were read.

Arguments must have the right type (`types`, `layers`, `kinds` arrays of strings, `rect` four
numbers, `limit` and `offset` integers, `mmPerUnit` a number); a wrong type is an error, not an
ignored argument; so is an argument name the tool does not take (`layer` for `layers`) and a
`limit` outside 1 to 5000. JSON `null` means the argument is absent. An entity id has one spelling,
exactly what the tools return, so `e+5` and `e007` are refused. A coordinate that is not finite (a
`1e999` in the file) is written as the string `"inf"`, `"-inf"` or `"nan"` instead of failing the
result.

## What is read, and what is not

- **DXF** (ASCII) is read: `LINE`, `CIRCLE`, `ARC`, `ELLIPSE`, `POINT`, `TEXT` / `MTEXT`,
  `LWPOLYLINE` / `POLYLINE`, `SPLINE` and `DIMENSION` from the `ENTITIES` section. The reader does not tell
  model space from paper space, so entities from both appear. Binary DXF is refused with a message.
- **DWG and JWW are not read yet.** `DWGLoader` is merged in OCCTSwiftIO (#53) but is not in a tagged
  release at this server's pin, and JWW has no entity model there yet (#54). Both return an error
  that says so. Convert the file to ASCII DXF meanwhile.
- **Extrusion directions are not read.** SwiftDXF 0.3 ignores DXF groups 210, 220 and 230, so an
  entity drawn in a mirrored or rotated coordinate system is read at its stored coordinates,
  unflipped, and nothing warns about it. SwiftDXF 0.4.0 reads them.
- **SwiftDXF is held on the 0.3 line.** OCCTSwiftIO 2.0.0-beta.5 requires SwiftDXF 0.3.0, but its
  floor admits 0.4.0, which it does not compile against (OCCTSwiftIO#60). This package declares
  SwiftDXF `.upToNextMinor(from: "0.3.0")`, so a resolve gives 0.3.0 and a host that embeds
  `OCCTMCPCore` gets the same. Moving to 0.4.0 (entity handles, hatch and leader entities, computed
  dimension values, block expansion) is tracked as OCCTMCP#271.
- **A newer SwiftDXF may add entity types.** An entity the tools have no mapping for is listed with
  type `other` and no layer, colour, bounds or geometry (nothing is made up), a layer filter never
  matches it, `read_drawing` warns about it and `measure_drawing` refuses it.
- **What the reader skips is reported, not hidden.** SwiftDXF models the entity types above and
  drops the rest of the `ENTITIES` section (`INSERT`, `HATCH`, `LEADER` and so on) and does not read
  the `BLOCKS` section, so a block insert places no geometry. `read_drawing` reports what SwiftDXF
  skipped (`Drawing.skipped`), by type and by layer, and warns when block inserts are among them.
  SwiftDXF counts an `INSERT`'s `ATTRIB` records as skipped entities of their own, so a block
  insert with attributes shows the attributes as well.

## Identity and units

- **Entity ids.** An entity's id is `e` and its position in the drawing's entity list (`e0`,
  `e1`, ...). SwiftDXF keeps no DXF handles, so the id is the index. It is stable for the same file
  bytes and this reader: `read_drawing` returns the file's SHA-256, and every result carries the file
  name, hash and SwiftDXF release line so a caller can tell when ids no longer mean what they did.
  `source.readerVersion` is that line (`0.3`, major and minor: the part that decides which entity
  types are modelled). A newer SwiftDXF that models more entity types shifts
  the ids after them: when SwiftDXF 0.3.0 began to model `SPLINE`, a spline took an index, so the ids
  after one in the same file are one higher than they were under 0.2. Skipped records take no
  index.
- **Units.** Coordinates and values are in **drawing units**. The drawing's units are the DXF
  `$INSUNITS` code, returned with its name and millimetres per unit (codes 0 to 24 as ezdxf lists
  them). A unitless or undeclared drawing has no millimetre figure and the tools say so; pass
  `mmPerUnit` to `measure_drawing` to supply one.

---

## `read_drawing`

Summarise a drawing: counts, layers, units, extents, the source record and what was skipped. Start
here.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF file. |

**Returns**: `entityCount`, `byType`, `layers` (each with its name, total and counts by type),
`units` (`insUnits`, `name`, `mmPerUnit`), `extents` (`declared` from the header's `$EXTMIN` /
`$EXTMAX`, `computed` from the entities, which can differ when an editor left the header stale),
`source` (`path`, `fileName`, `bytes`, `sha256`, `format`, `dxfVersion`, `reader`, `readerVersion`),
`skipped` (`total`, `byType`, `byLayer`) and `warnings`.

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
    "readerVersion": "0.3",
    "sha256": "5c9c59756de36f6cddd4c027d7eb956005d7d19ca3935f0737cf51b6e2f6f9a2"
  },
  "warnings": ["1 block insert(s) are not expanded, so the geometry they place is missing from the entity list.", "1 entity record(s) were skipped; see `skipped`."]
}
```

(`source.path` and `source.reader` are also returned and are left out above for width.)

---

## `list_drawing_entities`

List entities with identity, geometry and layer, filtered by type, layer or a rectangle on the
sheet.

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `inputPath` | string | yes | Absolute path of the DXF file. |
| `types` | string[] | no | Any of `line`, `circle`, `arc`, `ellipse`, `point`, `text`, `polyline`, `spline`, `dimension`. |
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
| `text` | `at`, `height`, `rotationDeg`, `text` |
| `point` | `at` |
| `dimension` | `dimension`, the record `list_drawing_dimensions` returns |

Bounds are tight for arcs (an arc of under half a turn does not contain its centre) and for the
arcs of a bulged polyline. A spline's box follows the curve (the curve flattened to within a
ten-thousandth of the size of its control data, so the box can fall short of it by that much), not
its control polygon, so a window that clears the curve does not touch it. An elliptical arc takes the bounds of its whole ellipse, and text is its
insertion point, because the reader keeps no text extent.

**Example**: the two walls of a slot.

```json
{ "inputPath": "/Users/me/drawings/slot.dxf", "layers": ["SLOT"] }
```

```json
{
  "total": 2, "offset": 0, "returned": 2, "truncated": false, "unit": "drawing units",
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c...", "readerVersion": "0.3" },
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
| `inputPath` | string | yes | Absolute path of the DXF file. |
| `layers` | string[] | no | Layer names to keep. |
| `kinds` | string[] | no | Any of `linear`, `aligned`, `angular`, `diameter`, `radius`, `angular3Point`, `ordinate`. |
| `limit` | integer | no | Page size, default 500, at most 5000. |
| `offset` | integer | no | Dimensions to skip, default 0. |

**Returns**: `total`, `offset`, `returned`, `truncated`, `units` and `dimensions`. Each dimension
has `id` (the same `e<index>` as in `list_drawing_entities`), `kind`, `valueKind` (`length` or
`angle`), `value` (the stored measurement, DXF group 42, absent when the file omits it, which ezdxf notes is
common), `valueUnit`, `valueMm`, `valueFromPoints` and `valueFromPointsMm` (see below), `text` (the
user's text override, absent when the dimension shows its own value: a text of exactly `<>` is
DXF's "show the measured value", `<> H7` is kept, and a single space, DXF's "suppress the text", is
returned as a single space),
`textPosition`, `definitionPoints`, `layer` and `color`.

- Each definition point carries its DXF `group` (10, 13, 14, 15 or 16) and, where SwiftDXF
  documents it, a `role`: a linear or aligned dimension has `dimensionLine`,
  `extensionLine1Origin` and `extensionLine2Origin`; a radius or diameter has `measuredFrom` and
  `measuredTo`. Other kinds return the groups with no role.
- `valueMm` is the value times millimetres per unit, for the length kinds only. An **angular**
  value is returned as stored: DXF does not declare its unit, so it has no `valueMm`.
- `valueFromPoints` is the length between the dimension's own definition points: the two extension
  line origins of an `aligned` dimension, the two ends of a `radius` or `diameter`. It is the value
  when the file stores none, and a check when it does: a stale or overridden dimension disagrees with
  its geometry (a stored 7 over extension lines 8 apart). It is absent for the other kinds. A
  `linear` dimension's measured direction is not modelled by the reader, so it has none.

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
| `inputPath` | string | yes | Absolute path of the DXF file. |
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
  says so in `notes` too. A `text` entity has no geometry to measure: pass its
  `at` point. A `dimension` has none either: measure the entities it dimensions, or pass its
  definition points from `list_drawing_dimensions` as points.
- **`angle`**: two `line` entities, or `vertex` with two points `a` and `b`. `value` is in degrees
  between 0 and 180 and runs between the lines' drawn directions (start to end); `acuteAngleDeg` is
  the angle between the lines as undirected lines, 0 to 90.
- **`radius`**: a `circle` or `arc` entity as `a`. Returns the radius and the `diameter`.

**Returns**: `measure`, `a` / `b` / `vertex` (what each end resolved to), `value` and `unit`
(`drawing units`, or `degrees` for an angle), `valueMm` (absent for an angle and when the units are
unknown), `mmPerUnit`, and `notes`.

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
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c...", "readerVersion": "0.3" }
}
```

That is the stored value of the slot's own dimension (`list_drawing_dimensions` returns 8 for it),
so a stale or overridden dimension shows up as a mismatch.

**Errors**: a missing file, an unsupported format, an id that is not `e<number>` or is out of range,
a `text` or `dimension` end for `distance`, and a non-line for `angle` each return `isError` with
the reason.
