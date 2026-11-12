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

Filter arguments (`types`, `layers`, `kinds`, `rect`) must be arrays of the right type; a wrong
shape is an error, not an ignored filter. JSON `null` means the argument is absent.

## What is read, and what is not

- **DXF** (ASCII) is read: `LINE`, `CIRCLE`, `ARC`, `ELLIPSE`, `POINT`, `TEXT` / `MTEXT`,
  `LWPOLYLINE` / `POLYLINE` and `DIMENSION` from the `ENTITIES` section. The reader does not tell
  model space from paper space, so entities from both appear. Binary DXF is refused with a message.
- **DWG and JWW are not read yet.** `DWGLoader` is merged in OCCTSwiftIO (#53) but is not in a tagged
  release at this server's pin, and JWW has no entity model there yet (#54). Both return an error
  that says so. Convert the file to ASCII DXF meanwhile.
- **What the reader skips is reported, not hidden.** SwiftDXF models the entity types above and
  drops the rest of model space (`INSERT`, `HATCH`, `SPLINE`, `LEADER` and so on) and does not read
  the `BLOCKS` section, so a block insert places no geometry. `read_drawing` counts the skipped
  records from the raw file, by type and by layer, and warns when block inserts are among them.

## Identity and units

- **Entity ids.** An entity's id is `e` and its position in the model-space entity list (`e0`,
  `e1`, ...). SwiftDXF keeps no DXF handles, so the id is the index. It is stable for the same file
  bytes: `read_drawing` returns the file's SHA-256, and every result carries the file name and hash
  so a caller can tell when ids no longer mean what they did. Skipped records take no index.
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
`source` (`path`, `fileName`, `bytes`, `sha256`, `format`, `dxfVersion`, `reader`), `skipped`
(`total`, `byType`, `byLayer`) and `warnings`.

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
    "sha256": "5c9c59756de36f6cddd4c027d7eb956005d7d19ca3935f0737cf51b6e2f6f9a2"
  },
  "warnings": ["1 block insert(s) are not expanded, so the geometry they place is missing from the entity list.", "1 model-space entity record(s) were skipped; see `skipped`."]
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
| `types` | string[] | no | Any of `line`, `circle`, `arc`, `ellipse`, `point`, `text`, `polyline`, `dimension`. |
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
| `text` | `at`, `height`, `rotationDeg`, `text` |
| `point` | `at` |
| `dimension` | `dimension`, the record `list_drawing_dimensions` returns |

Bounds are tight for arcs (an arc of under half a turn does not contain its centre) and for the
arcs of a bulged polyline. An elliptical arc takes the bounds
of its whole ellipse, and text is its insertion point, because the reader keeps no text extent.

**Example**: the two walls of a slot.

```json
{ "inputPath": "/Users/me/drawings/slot.dxf", "layers": ["SLOT"] }
```

```json
{
  "total": 2, "offset": 0, "returned": 2, "truncated": false, "unit": "drawing units",
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c..." },
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
user's text override, absent when the dimension shows its own value),
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
  curves. An ellipse is cut into 48 chords, because OCCT's ellipse edge takes no major-axis
  direction, and the result says so in `notes`. A `text` entity has no geometry to measure: pass its
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
  "source": { "fileName": "slot.dxf", "sha256": "5c9c59756de36f6c..." }
}
```

That is the stored value of the slot's own dimension (`list_drawing_dimensions` returns 8 for it),
so a stale or overridden dimension shows up as a mismatch.

**Errors**: a missing file, an unsupported format, an id that is not `e<number>` or is out of range,
a `text` or `dimension` end for `distance`, and a non-line for `angle` each return `isError` with
the reason.
