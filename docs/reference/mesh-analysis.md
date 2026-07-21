---
title: Mesh analysis (zones)
parent: Tool Reference
nav_order: 12
---

# Mesh analysis (zones)

The mesh-inspection surface for raw scans / STL skins (#101, #102): split a body's mesh into surface zones (plane / cylinder / sphere / cone, via OCCTSwiftMesh's dihedral region-growing with primitive-fit merge), then measure how far each zone's own cross-section stays constant along an axis (a loftable-extent map). Reach for this family when you have a scanned or imported mesh body and need to know what surfaces it's made of and how consistent each one is along its length, before committing to a reconstruction. Swift-only.

## Tools

[`segment_mesh_zones`](#segment_mesh_zones) · [`zone_continuity_sweep`](#zone_continuity_sweep) · [`list_zones`](#list_zones) · [`clear_zones`](#clear_zones)

---

## `segment_mesh_zones`

Split a body's mesh into surface zones. Each zone gets a stable `zone:<bodyId>#<n>` id (largest-first) and a fitted primitive (kind, params, residual, inlier ratio); every zone is minted into the zone registry (`<output_dir>/zones.json`) so a later `zone_continuity_sweep` can resolve one without re-segmenting.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to segment. |
| `maxDihedralDegrees` | number | no | Region-growing breaks where adjacent face normals exceed this angle. Default 20. |
| `mergeToleranceMm` | number | no | Absolute mm merge tolerance (converted internally to a fraction of the body's bbox diagonal). Default: library default (0.4% of bbox diagonal). |
| `minRegionTriangles` | integer (≥ 1) | no | Regions smaller than this after growing + merging are dropped and counted in `truncatedTriangleCount`. Default 8. |
| `maxZones` | integer (≥ 1) | no | Cap on returned zones; the largest are kept, the rest counted in `truncatedTriangleCount`. Default 64. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the body's bbox diagonal. |
| `registerZones` | boolean | no | If `true`, register each zone (up to `registerCap`, largest-first) as its own scene body `<bodyId>_zone<n>` (facet-shell BREP via `writeBREP(allowInvalid:)`). Default `false`. |
| `registerCap` | integer (≥ 0) | no | Max zones to register as bodies when `registerZones` is `true`. Default 32. |
| `render` | boolean | no | Render a categorical per-zone PNG with a legend. Default `true`. |
| `renderPath` | string | no | Override the default render path (`<output_dir>/<bodyId>_zones.png`). |
| `options` | object | no | Render options — same shape as [`render_preview`](mesh-visualization.md#render_preview)'s `options` (camera, width, height, background). |

**Returns** — `{ bodyId, zoneCount, truncatedTriangleCount, zones: [{ id, triangleCount, areaMm2, areaFraction, bbox, meanNormal, boundaryLoops, adjacentZones, fit: { kind, params, residualRmsMm, residualMaxMm, inlierRatio } }], renderPath?, registeredBodyIds?, warnings[] }`. Bounded output: no raw per-triangle arrays. Every truncation (a region dropped under `minRegionTriangles`, the largest-`maxZones` cap, a `registerCap` cutoff) is reported in `warnings`, never silent.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan", "minRegionTriangles": 20, "registerZones": true, "registerCap": 8 }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "zoneCount": 14,
  "truncatedTriangleCount": 312,
  "zones": [
    { "id": "zone:carbody_scan#0", "triangleCount": 4820, "areaMm2": 812000.0, "areaFraction": 0.31,
      "bbox": { "min": [0, -1500, 200], "max": [8000, -1480, 2600] },
      "meanNormal": [0.02, -0.999, 0.01], "boundaryLoops": 1,
      "adjacentZones": ["zone:carbody_scan#1", "zone:carbody_scan#3"],
      "fit": { "kind": "plane", "params": [0.02, -0.999, 0.01, 1499.4], "residualRmsMm": 3.2, "residualMaxMm": 11.5, "inlierRatio": 0.94 } }
  ],
  "renderPath": "/tmp/carbody_scan_zones.png",
  "registeredBodyIds": ["carbody_scan_zone0", "carbody_scan_zone1"],
  "warnings": ["registerCap=8 truncated registration: 6 zones were not registered as bodies."]
}
```

**Notes** — `adjacentZones` (which zones share a welded mesh edge) requires an internal weld pass to compute; if that weld drops a degenerate triangle (breaking the index correspondence `triangleIndices` relies on) the tool reports an honest empty `adjacentZones` plus a warning rather than risking a wrong attribution. Zone ids are stable within a session (backed by `zones.json`) and re-resolvable across calls, including after a server restart — a zone minted before a restart is still resolvable, but `zone_continuity_sweep` validates the body's mesh signature (triangle count + bbox) before trusting a resolved zone's `triangleIndices` and errors, asking you to re-run this tool, if the body changed.

**Drives** — `OCCTSwiftMesh` `Mesh.segmented(_:)` (dihedral region-growing + primitive-fit merge, OCCTSwiftMesh#16/#17); `ZoneRegistry`; `ChartRenderer`'s categorical palette + zone legend.

---

## `zone_continuity_sweep`

Per-zone (or whole-body) loftable-extent map: slices along an axis at N stations, compares each station's 2D profile against a running reference, and reports maximal within-tolerance runs (the completable / loftable extents) plus the deviation intervals between them — each with world `axisCoord` spans and magnitudes.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to sweep. |
| `zoneId` | string | no | A `zone:<bodyId>#<n>` id from `segment_mesh_zones`. Slicing only the zone's own triangles keeps a neighbouring feature from polluting its verdict. Omit to sweep the whole body. |
| `axis` | number[3] | no | `[x, y, z]` sweep axis. Default: the zone/body's principal axis via PCA over its triangle vertices. |
| `stations` | integer (≥ 2) | no | Number of evenly-spaced cut planes across the zone/body's axis extent (2% end margin). Default 32. |
| `toleranceMm` | number | no | Within-tolerance verdict threshold on profile RMS (mm). Default 0.5. |
| `lateralToleranceMm` | number | no | Within-tolerance verdict threshold on profile centroid offset (mm). Default: same as `toleranceMm`. |
| `deflection` | number | no | Mesh linear deflection for a whole-body sweep. Default 0.5% of the body's bbox diagonal. Ignored (and warned) for a `zoneId`-scoped sweep, which always re-meshes at the zone's own segmentation deflection so `triangleIndices` stay valid. |
| `render` | boolean | no | Render the zone/body coloured by nearest-station verdict. Default `true`. |
| `renderPath` | string | no | Override the default render path. |
| `chart` | boolean | no | Render a per-station `profileRmsMm`-vs-`axisCoord` strip chart PNG with the tolerance line. Default `false`. |
| `chartPath` | string | no | Override the default chart path. |
| `options` | object | no | Render options — same shape as [`render_preview`](mesh-visualization.md#render_preview)'s `options`. |

**Returns** — `{ bodyId, zoneId?, axis, axisSource ("explicit"|"pca"), overlap: [min, max], stations: [{ index, axisCoord, offset, lateralOffsetMm, profileRmsMm, profileMaxMm, arcLengthDeltaMm, openProfile, verdict }], runs: [{ startAxisCoord, endAxisCoord, stationCount, kind ("constant"|"deviation"), maxProfileRmsMm, maxLateralOffsetMm }], warnings[], renderPath?, chartPath? }`.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan", "zoneId": "zone:carbody_scan#0", "axis": [1, 0, 0], "stations": 40, "toleranceMm": 0.5 }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "zoneId": "zone:carbody_scan#0",
  "axis": [1, 0, 0],
  "axisSource": "explicit",
  "overlap": [40.0, 7960.0],
  "stations": [
    { "index": 0, "axisCoord": 200.0, "offset": 0.0, "lateralOffsetMm": 0.0, "profileRmsMm": 0.0, "profileMaxMm": 0.0, "arcLengthDeltaMm": 0.0, "openProfile": true, "verdict": "constant" }
  ],
  "runs": [
    { "startAxisCoord": 200.0, "endAxisCoord": 3180.0, "stationCount": 15, "kind": "constant", "maxProfileRmsMm": 0.31, "maxLateralOffsetMm": 0.28 },
    { "startAxisCoord": 3380.0, "endAxisCoord": 4020.0, "stationCount": 4, "kind": "deviation", "maxProfileRmsMm": 4.9, "maxLateralOffsetMm": 5.6 },
    { "startAxisCoord": 4220.0, "endAxisCoord": 7960.0, "stationCount": 20, "kind": "constant", "maxProfileRmsMm": 0.33, "maxLateralOffsetMm": 0.30 }
  ],
  "warnings": []
}
```

**Notes** — A station's signals are relative to the ACTIVE reference at that point in the sweep: a constant run's own seed station, or (throughout a deviation interval) the constant run that most recently closed — not a global first-station baseline. A wall-panel zone's own slice is almost always an OPEN polyline (`openProfile: true`); `profileRmsMm`/`profileMaxMm` are computed after removing the centroid (lateral) offset, so they measure residual SHAPE difference, not position. Stations that miss the zone/body entirely at that axial position report `verdict: "missed"` and are excluded from every run. This tool's own aggregation logic (the change-point run/interval detection) is independent of OCCTReconstruct's engine, per the ecosystem's mandatory-analytic-verification policy — agreement between the two, where both exist, is evidence, not a tautology.

**Known limitation** — `ProfileMath.profileDelta` resamples a CLOSED ring starting from `loop[0]`, and that start point is not a canonical property of the surface: `Mesh.crossSection`'s loop traversal doesn't guarantee the same physical point comes out first at every station. A whole-body sweep of a tube-like (closed cross-section) body can therefore report phantom `profileRmsMm` from two stations coming back rotated relative to each other, pairing arc-length fractions out of phase rather than any real shape change. Open-profile zone sweeps (the common case — a single wall's cut is almost always an open polyline) are unaffected: `profileDelta` already handles the open case's direction ambiguity by comparing both point orders. Until a circular-shift alignment lands for closed rings, prefer zone-scoped sweeps over whole-body sweeps for thin-wall / tube-like bodies.

**Drives** — `OCCTSwiftMesh` `Mesh.crossSection`; `ProfileMath` (shared with [`cross_section_compare`](introspection.md#cross_section_compare)); `ZoneRegistry`.

---

## `list_zones`

Return every zone in the zone registry (`<output_dir>/zones.json`), optionally filtered to one body.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | no | Restrict to this body's zones. Omit to list every zone across all bodies. |

**Returns** — `{ count, zones: [{ zoneId, bodyId, index, triangleCount, areaMm2, fitKind }] }`.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan" }
```
```json
// example result
{ "count": 14, "zones": [{ "zoneId": "zone:carbody_scan#0", "bodyId": "carbody_scan", "index": 0, "triangleCount": 4820, "areaMm2": 812000.0, "fitKind": "plane" }] }
```

---

## `clear_zones`

Drop zones from the zone registry and its `<output_dir>/zones.json` sidecar, optionally for one body only. Returns the count cleared.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | no | Clear only this body's zones. Omit to clear every zone. |

**Returns** — `{ cleared }`.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan" }
```
```json
// example result
{ "cleared": 14 }
```
