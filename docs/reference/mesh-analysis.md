---
title: Mesh analysis (zones)
parent: Tool Reference
nav_order: 12
---

# Mesh analysis (zones)

The mesh-inspection surface for raw scans / STL skins (#101, #102, Phase 2 of the mesh-analysis expansion): split a body's mesh into surface zones (plane / cylinder / sphere / cone, via OCCTSwiftMesh's dihedral region-growing with primitive-fit merge), then measure how far each zone's own cross-section stays constant along an axis (a loftable-extent map). Phase 2 adds a general mesh-inspection base that doesn't need zones at all: an integrity check-list, a mesh-domain wall-thickness measurement, reflective-symmetry detection, and GOM-style two-body alignment. Phase 3 adds per-vertex discrete curvature, per-zone slippage classification (Gelfand-Guibas local slippage analysis, OCCTSwiftMesh#26/#31, integrated into `segment_mesh_zones`'s zone table and defaulting `zone_continuity_sweep`'s axis where eligible — answering the zone model's "loftable along WHICH axis" question), and `fit_primitives` (#107): a Schnabel-style RANSAC primitive report (OCCTSwiftMesh#27/#32) that claims GLOBAL inliers rather than `segment_mesh_zones`' edge-adjacent-only region growing, so it can unify a primitive (e.g. a cylinder interrupted by a boss) the zone table keeps split across regions. Reach for this family when you have a scanned or imported mesh body and need to know what surfaces it's made of, whether it's structurally sound, how thick its walls are, how symmetric it is, how curved it is at each point, whether the same primitive recurs elsewhere in the part, or whether it's actually registered to a reference body yet, before committing to a reconstruction or measuring deviation against that reference. Swift-only.

## Tools

[`segment_mesh_zones`](#segment_mesh_zones) · [`zone_continuity_sweep`](#zone_continuity_sweep) · [`list_zones`](#list_zones) · [`clear_zones`](#clear_zones) · [`mesh_diagnose`](#mesh_diagnose) · [`mesh_thickness`](#mesh_thickness) · [`detect_symmetry`](#detect_symmetry) · [`align_bodies`](#align_bodies) · [`mesh_curvature`](#mesh_curvature) · [`fit_primitives`](#fit_primitives)

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

**Returns** — `{ bodyId, zoneCount, truncatedTriangleCount, zones: [{ id, triangleCount, areaMm2, areaFraction, bbox, meanNormal, boundaryLoops, adjacentZones, fit: { kind, params, residualRmsMm, residualMaxMm, inlierRatio }, slippage?: { kind, axisPoint?, axisDirection?, pitchPerRadianMm?, confidence } }], renderPath?, registeredBodyIds?, warnings[] }`. Bounded output: no raw per-triangle arrays. Every truncation (a region dropped under `minRegionTriangles`, the largest-`maxZones` cap, a `registerCap` cutoff) is reported in `warnings`, never silent.

| field | meaning |
|-------|---------|
| `slippage.kind` | `"plane" \| "sphere" \| "cylinder" \| "extrusion" \| "revolution" \| "helix" \| "freeform"` — the zone's surface kind by local slippage analysis (Gelfand & Guibas, SGP 2004; OCCTSwiftMesh#26/#31), independent of (and a cross-check on) the region-fit `fit.kind` above. |
| `slippage.axisPoint` | A point on the characteristic axis: the rotation/screw axis for cylinder/revolution/helix, the sphere's center, a representative point for plane/extrusion. `null` for freeform. |
| `slippage.axisDirection` | Unit direction of the characteristic axis: rotation/screw axis for cylinder/revolution/helix, extrude direction for extrusion, the surface **NORMAL** for plane. `null` for sphere (no preferred axis) and freeform. **Sign is arbitrary** — inherent to the underlying eigenvector recovery, not a bug; a flipped sign is still the same axis. |
| `slippage.pitchPerRadianMm` | Translation per radian of rotation about `axisDirection`. Non-null only for `helix`. |
| `slippage.confidence` | `[0, 1]`, a spectral-gap diagnostic, **not a probability**: a wide gap between the slippable and non-slippable eigenvalues means a confident classification; a gap barely past the detection floor means the kind boundary itself is close to arbitrary. A near-symmetric body (whose true eigen-spectrum has no clean separation to begin with) reads as low-confidence rather than confidently wrong — treat a low `confidence` as "don't trust this classification," including for `zone_continuity_sweep`'s axis default below. |

`slippage` is omitted (the whole field, per zone) in the same case `adjacentZones` is: when the tool's internal weld pass drops a degenerate triangle, breaking the triangle-index correspondence both need (see **Notes** below) — the tool reports the honest omission plus a warning rather than risking a misattributed classification.

**Boundary erosion.** On a connected mesh, a zone-boundary vertex's normal blends the neighbouring zone's surface in (a fold-edge vertex averages both panels), which contaminates the classification — a small extrusion panel can read as `helix` when its boundary ring dominates the samples. The tool therefore erodes each zone to its interior triangles (all three vertices untouched by any other zone or unassigned triangle) before classifying. Zones too small to erode (fewer than 24 interior triangles, or under 25% of the zone) keep their full-region classification and are **named in a warning** instead of being reported clean — expect this on small zones (a door recess) and treat their `slippage` accordingly.

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
      "fit": { "kind": "plane", "params": [0.02, -0.999, 0.01, 1499.4], "residualRmsMm": 3.2, "residualMaxMm": 11.5, "inlierRatio": 0.94 },
      "slippage": { "kind": "plane", "axisPoint": [4000.0, -1490.0, 1400.0], "axisDirection": [0.02, -0.999, 0.01], "pitchPerRadianMm": null, "confidence": 0.91 } }
  ],
  "renderPath": "/tmp/carbody_scan_zones.png",
  "registeredBodyIds": ["carbody_scan_zone0", "carbody_scan_zone1"],
  "warnings": ["registerCap=8 truncated registration: 6 zones were not registered as bodies."]
}
```

**Notes** — `adjacentZones` (which zones share a welded mesh edge) and `slippage` both require the SAME internal weld pass to compute; if that weld drops a degenerate triangle (breaking the index correspondence `triangleIndices` relies on) the tool reports an honest empty `adjacentZones`, an omitted `slippage`, and a warning for each rather than risking a wrong attribution. Zone ids are stable within a session (backed by `zones.json`) and re-resolvable across calls, including after a server restart — a zone minted before a restart is still resolvable, but `zone_continuity_sweep` validates the body's mesh signature (triangle count + bbox) before trusting a resolved zone's `triangleIndices` and errors, asking you to re-run this tool, if the body changed. A `zones.json` sidecar written before #109 has no `slippage` key at all; it still loads (the field decodes as absent, not an error), and `list_zones`/`zone_continuity_sweep` treat that the same as a weld-guard omission.

**Drives** — `OCCTSwiftMesh` `Mesh.segmented(_:)` (dihedral region-growing + primitive-fit merge, OCCTSwiftMesh#16/#17) and `Mesh.slippage(forTriangles:maxSamples:)` (local slippage analysis, OCCTSwiftMesh#26/#31, >=1.6.0); `ZoneRegistry`; `ChartRenderer`'s categorical palette + zone legend.

---

## `zone_continuity_sweep`

Per-zone (or whole-body) loftable-extent map: slices along an axis at N stations, compares each station's 2D profile against a running reference, and reports maximal within-tolerance runs (the completable / loftable extents) plus the deviation intervals between them — each with world `axisCoord` spans and magnitudes.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to sweep. |
| `zoneId` | string | no | A `zone:<bodyId>#<n>` id from `segment_mesh_zones`. Slicing only the zone's own triangles keeps a neighbouring feature from polluting its verdict. Omit to sweep the whole body. |
| `axis` | number[3] | no | `[x, y, z]` sweep axis. Default: see `axisSource` selection rules below. |
| `stations` | integer (≥ 2) | no | Number of evenly-spaced cut planes across the zone/body's axis extent (2% end margin). Default 32. |
| `toleranceMm` | number | no | Within-tolerance verdict threshold on profile RMS (mm). Default 0.5. |
| `lateralToleranceMm` | number | no | Within-tolerance verdict threshold on profile centroid offset (mm). Default: same as `toleranceMm`. |
| `deflection` | number | no | Mesh linear deflection for a whole-body sweep. Default 0.5% of the body's bbox diagonal. Ignored (and warned) for a `zoneId`-scoped sweep, which always re-meshes at the zone's own segmentation deflection so `triangleIndices` stay valid. |
| `render` | boolean | no | Render the zone/body coloured by nearest-station verdict. Default `true`. |
| `renderPath` | string | no | Override the default render path. |
| `chart` | boolean | no | Render a per-station `profileRmsMm`-vs-`axisCoord` strip chart PNG with the tolerance line. Default `false`. |
| `chartPath` | string | no | Override the default chart path. |
| `options` | object | no | Render options — same shape as [`render_preview`](mesh-visualization.md#render_preview)'s `options`. |

**Returns** — `{ bodyId, zoneId?, axis, axisSource ("explicit"|"slippage"|"pca"), overlap: [min, max], stations: [{ index, axisCoord, offset, lateralOffsetMm, profileRmsMm, profileMaxMm, arcLengthDeltaMm, openProfile, verdict }], runs: [{ startAxisCoord, endAxisCoord, stationCount, kind ("constant"|"deviation"), maxProfileRmsMm, maxLateralOffsetMm }], warnings[], renderPath?, chartPath? }`.

**`axisSource` selection rules** (#109), most-preferred first:

1. **`"explicit"`** — the `axis` argument, when given, always wins outright, whole-body or zone-scoped.
2. **`"slippage"`** — a `zoneId`-scoped sweep whose stored zone (from `segment_mesh_zones`) has a `slippage.kind` in `{cylinder, extrusion, revolution, helix}`, a non-null `slippage.axisDirection`, AND `slippage.confidence >= 0.25` defaults the sweep axis to that `axisDirection`. **Plane is never eligible** — its slippage axis is the surface NORMAL, and sweeping a panel along its own normal is exactly wrong, not merely unhelpful — and neither is sphere/freeform (no preferred axis to begin with). When the zone's kind qualifies but `confidence < 0.25`, the tool falls back to PCA and adds a warning: `"zone has a low-confidence slippage classification (<kind>, confidence <value>); sweep axis fell back to PCA"`.
3. **`"pca"`** — every whole-body sweep (no zone-scoped slippage to consult at all), plus any zone-scoped sweep that didn't qualify for rung 2 (ineligible kind, missing slippage — e.g. an old-format `zones.json` record, or the zone's own weld guard failed at segmentation time — or low confidence). Principal axis via PCA over the zone/body's own triangle vertices, unchanged from pre-#109 behaviour.

**Not yet implemented (#109 follow-up):** revolve-aware stationing — angular stations about the axis instead of linear stations along it — for `revolution`-classified zones. A revolution zone today still gets linear stations along its rotation axis like every other kind; this is the remaining piece of the original `segment_mesh_zones`/`zone_continuity_sweep` zone-model design (#101/#102) still open.

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

**Returns** — `{ count, zones: [{ zoneId, bodyId, index, triangleCount, areaMm2, fitKind, slippageKind? }] }`. `slippageKind` (#109) mirrors the zone's own `slippage.kind` (see [`segment_mesh_zones`](#segment_mesh_zones)); `null`/absent for a zone with no slippage classification (a weld-guard omission at segmentation time, or a pre-#109 sidecar record).

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan" }
```
```json
// example result
{ "count": 14, "zones": [{ "zoneId": "zone:carbody_scan#0", "bodyId": "carbody_scan", "index": 0, "triangleCount": 4820, "areaMm2": 812000.0, "fitKind": "plane", "slippageKind": "plane" }] }
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

---

## `mesh_diagnose`

A printability-check-list integrity report over a body's mesh: watertight, edge/vertex-manifold, orientable, connected components, boundary loops, Euler characteristic / genus, duplicate/degenerate triangle counts, and sliver signals (`minAngleDegrees`, `aspectRatio`). `checks[]` derives pass/warn/fail verdicts from the raw counts so a caller doesn't have to re-encode the thresholds itself.

**IMPORTANT — self-intersection is NOT checked.** This is an upstream `OCCTSwiftMesh.Mesh.integrityReport(weldTolerance:)` limitation, not an oversight here: a self-intersecting closed manifold still reports `isWatertight: true`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to diagnose. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the body's bbox diagonal. |
| `weldToleranceMm` | number (≥ 0) | no | Absolute mm weld tolerance used internally before computing manifoldness. Default 0 (auto: 1e-6 x the mesh's bbox diagonal). |

**Returns** — `{ bodyId, triangleCount, isWatertight, isOrientable, nonManifoldEdgeCount, nonManifoldVertexCount, boundaryLoopCount, duplicateTriangleCount, degenerateTriangleCount, eulerCharacteristic, genus, componentCount, components: [{ triangleCount, areaMm2 }] (largest-first, capped 16 with a warning past that), minAngleDegrees: { min, p05 }, aspectRatio: { max, p95 }, checks: [{ check, status ("pass"|"warn"|"fail"), detail }], warnings[] }`.

`checks[]` covers: `watertight` (fail if not), `orientable` (fail if not, or `warn`/"not evaluated" when non-manifold edges are present, since orientability isn't meaningful there), `single_component` (warn if > 1), `non_manifold_edges` / `non_manifold_vertices` (fail if > 0), `degenerate_triangles` / `duplicate_triangles` (warn if > 0), `slivers` (warn if `minAngleDegrees.p05` < 5° or `aspectRatio.p95` > 20).

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan" }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "triangleCount": 48210,
  "isWatertight": false,
  "isOrientable": true,
  "nonManifoldEdgeCount": 0,
  "nonManifoldVertexCount": 0,
  "boundaryLoopCount": 3,
  "duplicateTriangleCount": 0,
  "degenerateTriangleCount": 2,
  "eulerCharacteristic": 1,
  "genus": null,
  "componentCount": 1,
  "components": [{ "triangleCount": 48210, "areaMm2": 2140500.0 }],
  "minAngleDegrees": { "min": 0.8, "p05": 6.2 },
  "aspectRatio": { "max": 210.0, "p95": 9.1 },
  "checks": [
    { "check": "watertight", "status": "fail", "detail": "Not watertight: 3 boundary loop(s), 0 non-manifold edge(s), 0 non-manifold vertex/vertices." },
    { "check": "orientable", "status": "pass", "detail": "Consistent winding across every 2-triangle edge." },
    { "check": "single_component", "status": "pass", "detail": "A single connected piece." },
    { "check": "non_manifold_edges", "status": "pass", "detail": "No non-manifold edges." },
    { "check": "non_manifold_vertices", "status": "pass", "detail": "No non-manifold vertices." },
    { "check": "degenerate_triangles", "status": "warn", "detail": "2 triangle(s) collapsed to an edge or point after welding." },
    { "check": "duplicate_triangles", "status": "pass", "detail": "No duplicate triangles." },
    { "check": "slivers", "status": "pass", "detail": "minAngleDegrees.p05=6.20°, aspectRatio.p95=9.10." }
  ],
  "warnings": []
}
```

**Notes** — `genus` is `null` unless `isWatertight && isOrientable` (and the Euler characteristic is consistent with a valid closed 2-manifold) — a raw scan with open boundaries (the common case) has no genus. `components` is capped at 16 entries (largest-first); `componentCount` is always the true total, and a truncation is reported in `warnings`.

**Drives** — `OCCTSwiftMesh` `Mesh.integrityReport(weldTolerance:)`. Also un-stubs `generate_mesh`'s `quality.nonManifoldEdges` (previously hardcoded `0`), which now delegates to the same call.

---

## `mesh_thickness`

Mesh-domain wall thickness via the ray method (normal-opposite, first-hit): the complement to [`check_thickness`](engineering.md#check_thickness), which works on BREP topology and degrades on facet shells (a raw STL import is one BREP face per facet). This tool never touches BREP topology at all — it samples the tessellated surface directly.

Samples up to `maxSamples` surface points (stride-subsampled mesh vertices) and, for each, casts a ray from just inside the surface along its inward normal against an internal triangle BVH; the first hit distance is the local thickness. Rays that exit without hitting anything (open shells) are excluded from the stats and counted in `noHitSamples`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to measure. |
| `maxSamples` | integer (≥ 1) | no | Cap on surface sample points (stride-subsampled). Default 2000. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the body's bbox diagonal. |
| `thresholdMm` | number (≥ 0) | no | If set, adds a `belowThreshold` section reporting samples thinner than this. |
| `coneAngleDegrees` | number (0–89) | no | Half-angle of a 5-ray averaging cone (center + 4 boundary rays, median taken — the SDF convention). 0 (default) casts a single ray. |
| `chart` | boolean | no | Render a `thicknessMm` histogram PNG. Default `false`. |
| `chartPath` | string | no | Override the default chart path (`<output_dir>/<bodyId>_thickness.png`). |

**Returns** — `{ bodyId, samples, noHitSamples, thicknessMm: { min, p05, median, mean, p95, max }, belowThreshold?: { thresholdMm, count, fraction, worst: [{ point, thicknessMm }] (capped 8) }, chartPath?, warnings[] }`. `belowThreshold.fraction` is of MEASURED samples (`samples - noHitSamples`), not of `samples`.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan", "thresholdMm": 1.5, "coneAngleDegrees": 5 }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "samples": 2000,
  "noHitSamples": 12,
  "thicknessMm": { "min": 0.8, "p05": 1.1, "median": 2.0, "mean": 2.05, "p95": 3.2, "max": 4.9 },
  "belowThreshold": {
    "thresholdMm": 1.5,
    "count": 34,
    "fraction": 0.017,
    "worst": [{ "point": [1200.0, -30.0, 15.0], "thicknessMm": 0.8 }]
  },
  "chartPath": null,
  "warnings": []
}
```

**Notes** — A sample near a face's own outer edge can legitimately overshoot a thinner opposing wall's smaller footprint and read through to a FAR wall instead — a real characteristic of single-ray thickness sampling near an edge, not a bug. `coneAngleDegrees` averaging (median of 5 rays) reduces but doesn't eliminate this. A large `noHitSamples` fraction (warned when > 20%) usually means an open shell along the sampled normals.

**Drives** — `TriBVH` (a small AABB BVH over triangles, Möller–Trumbore ray-triangle intersection) + `DeviationTools.TriMesh`. Pure MCP-side composition — no new OCCTSwiftMesh surface needed.

---

## `detect_symmetry`

Detect reflective (mirror-plane) symmetry: 3 candidate planes through the area-weighted centroid, each normal to one of the mesh's 3 principal axes (PCA), verified by reflecting sampled surface points across the plane and measuring their unsigned nearest distance back to the mesh's own surface. A candidate is `symmetric` when its p95 residual is within `toleranceMm`.

Rotational/axis symmetry detection is deferred to a later phase — this tool covers mirror-plane symmetry only.

**Known limitation — near-equal principal axes.** When two (or three) PCA eigenvalues are within ~5% of each other, the eigenvector pair in that subspace is ill-defined: any rotation of the two axes is an equally valid PCA result, so the candidate planes can come out rotated off the body's true mirror planes and a genuinely symmetric body (a square-section prism is the canonical case) can read asymmetric. The tool detects this and appends an explicit warning; treat non-symmetric verdicts for the affected candidates with suspicion. Continuous-symmetry bodies (cylinders) are unaffected — any plane through the axis mirrors. The reliable fallback for a specific suspected plane: mirror a copy of the body and `measure_deviation` against the original.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to analyse. |
| `maxSamples` | integer (≥ 1) | no | Cap on surface sample points (stride-subsampled). Default 2000. |
| `toleranceMm` | number (≥ 0) | no | A candidate plane is symmetric when its p95 residual is within this. Default 0.5. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the body's bbox diagonal. |

**Returns** — `{ bodyId, toleranceMm, samples, candidates: [{ point, normal, rmsMm, p95Mm, maxMm, symmetric }] (sorted best-first by p95Mm), bestPlane?, warnings[] }`. `bestPlane` is the best-scoring symmetric candidate, omitted if none passes.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan", "toleranceMm": 1.0 }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "toleranceMm": 1.0,
  "samples": 2000,
  "candidates": [
    { "point": [4000.0, 0.0, 900.0], "normal": [0.0, 1.0, 0.0], "rmsMm": 0.31, "p95Mm": 0.62, "maxMm": 1.4, "symmetric": true },
    { "point": [4000.0, 0.0, 900.0], "normal": [1.0, 0.0, 0.0], "rmsMm": 8.2, "p95Mm": 22.5, "maxMm": 41.0, "symmetric": false },
    { "point": [4000.0, 0.0, 900.0], "normal": [0.0, 0.0, 1.0], "rmsMm": 19.4, "p95Mm": 55.0, "maxMm": 90.0, "symmetric": false }
  ],
  "bestPlane": { "point": [4000.0, 0.0, 900.0], "normal": [0.0, 1.0, 0.0], "rmsMm": 0.31, "p95Mm": 0.62, "maxMm": 1.4, "symmetric": true },
  "warnings": []
}
```

**Notes** — The covariance behind the PCA axes uses the exact per-triangle second-moment formula (not a coarse "triangle centroid as point mass" approximation), which matters on coarsely-tessellated meshes: a box face split into just 2 large triangles is enough for the point-mass shortcut to introduce spurious cross-covariance terms and rotate the "principal axes" off the body's real symmetry planes.

**Drives** — `DeviationTools.signedQuery(..., signMode: .nearest)` for the unsigned residual measurement; a small internal symmetric-3x3 Jacobi eigensolver for the principal axes. Pure MCP-side composition.

---

## `align_bodies`

GOM-style alignment: register a SOURCE body onto a REFERENCE body via point-to-plane ICP (OCCTSwiftMesh#22/#25, closing #104). Scan-vs-CAD deviation measurement ([`measure_deviation`](introspection.md#measure_deviation), [`cross_section_compare`](introspection.md#cross_section_compare), the heatmap) is meaningless before the two bodies are actually in a shared frame — none of those tools do any registration step of their own. `align_bodies` is that step.

`mode` is the GOM-style alignment-mode enum, layered on the upstream primitive:
- `"bestFit"` (default) — the full pipeline: PCA/bbox pre-align (trying all 4 orientation-preserving sign combinations of the two dominant principal axes, keeping whichever gives the lowest quick correspondence residual), then point-to-plane ICP refinement with normal-space sampling and trimmed correspondence.
- `"preAlign"` — stops after the coarse PCA/bbox stage only (`maxIterations` forced to 0, and ignored if supplied) — GOM's "pre-align" tier, useful as a fast coarse pose or a starting point for a caller-driven refinement.

`localBestFit` / `3-2-1` / RPS-datum alignment (GOM's remaining tiers) are deferred — not required for this first version.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | The SOURCE (moving) body — the one registered onto `referenceBodyId`. |
| `referenceBodyId` | string | yes | The REFERENCE (fixed) body `bodyId` is aligned onto. Must differ from `bodyId`. |
| `mode` | string | no | `"bestFit"` (default) or `"preAlign"`. |
| `maxSamples` | integer (≥ 1) | no | Cap on source correspondence-search sample points (normal-space sampled — proportional to normal-direction diversity, so a small feature on an otherwise-flat surface isn't outvoted by the flat majority). Default 2000. |
| `trimFraction` | number (≥ 0) | no | Drop the worst fraction of surviving correspondences by point-to-plane residual each ICP iteration (trimmed ICP — robust to partial overlap between the two bodies). Default 0.1. |
| `correspondenceDistanceCapMm` | number (> 0) | no | Absolute mm cap rejecting correspondences farther apart than this. Default: auto, 0.15× the reference body's bounding-box diagonal. |
| `maxIterations` | integer (≥ 0) | no | Max ICP refinement iterations after pre-align. Default 50. Ignored (forced to 0) when `mode` is `"preAlign"`. |
| `deflection` | number | no | Mesh linear deflection for BOTH bodies (the same recipe as `measure_deviation`'s `TriMesh`). Default 0.5% of the SOURCE body's bbox diagonal. |
| `apply` | boolean | no | If `true`, write the recovered transform onto the source body **in place**. Default `false` (measure only). |

**Returns** — `{ bodyId, referenceBodyId, mode, transform, translationMm, rotationAxis, rotationAngleDegrees, residualRmsMm, iterations, converged, applied, warnings[] }`.

**Transform convention** — `transform` is a **4×4, ROW-MAJOR** array: `transform[i]` is row `i`, and `transform[i][j] * point[j]` summed over `j` (with `point = [x, y, z, 1]`) gives the transformed coordinate — the standard row-dot-column convention. It maps a point in the SOURCE body's frame into the REFERENCE body's frame. The trivial 4th row is always `[0, 0, 0, 1]`. `translationMm` is `[transform[0][3], transform[1][3], transform[2][3]]`. `rotationAxis`/`rotationAngleDegrees` is an axis-angle decomposition of the 3×3 rotation block (upper-left). This is the OPPOSITE convention from the underlying OCCTSwiftMesh primitive's `simd_double4x4`, which is column-major — converted carefully in `AlignTools.rowMajor(_:)`; do not assume the raw upstream layout when consuming this field.

**Known limitations** (from the upstream ICP primitive, see OCCTSwiftMesh's `docs/algorithms/alignment.md`):
- **Near-degenerate principal axes.** When the PCA pre-align's covariance eigenvalues are (near-)equal in a subspace, the eigenvector pair there is arbitrary, so all 4 sign-combination candidates can start from a bad pose and the subsequent ICP refinement — a local optimizer — may converge to a wrong pose or not at all. `converged == false` (bestFit mode only) or a large `residualRmsMm` is the signal; there is no automatic recovery — pre-transforming the source with a caller-side initial guess, or aligning a less symmetric sub-region, is the workaround.
- **Continuous / discrete symmetry.** A body with continuous symmetry about an axis (a cylinder) has an inherently unobservable rotation about that axis — any such rotation is an equally valid alignment, and which one comes back is a sampling artifact, not an error. A body with a discrete symmetry group (e.g. a plain rectangular box's 180°-rotation symmetries about its own principal axes) has multiple ICP-indistinguishable correct poses for the same reason.

**apply semantics** — `apply: true` mirrors [`transform_body`](construction.md#transform_body)'s in-place path exactly: a `SceneHistory` snapshot before the write, the recovered transform applied via `Shape.transformed(matrix:)` (OCCTSwift's one general-affine rotation+translation primitive — a single rigid-transform apply, not a decomposed rotate-then-translate pair), the BREP rewritten to the SAME file, and the same `HistoryRegistry` generation reset (`commit(ref: nil)`) `transform_body` uses today (no `*WithFullHistory` variant exists for an arbitrary caller-supplied matrix). `applied` in the response reflects whether the write actually happened; a failure to apply is an `isError` result, never silent. Omit `apply` (or leave it `false`) to only measure — the common case when composing with `measure_deviation` afterwards to check whether alignment actually helped.

**Example**

```json
// tool call arguments
{ "bodyId": "scan_body", "referenceBodyId": "cad_body", "mode": "bestFit", "apply": true }
```
```json
// example result
{
  "bodyId": "scan_body",
  "referenceBodyId": "cad_body",
  "mode": "bestFit",
  "transform": [
    [0.998, -0.052, 0.019, 12.4],
    [0.053, 0.997, -0.041, -3.1],
    [-0.016, 0.042, 0.999, 0.8],
    [0.0, 0.0, 0.0, 1.0]
  ],
  "translationMm": [12.4, -3.1, 0.8],
  "rotationAxis": [0.34, 0.61, 0.72],
  "rotationAngleDegrees": 3.4,
  "residualRmsMm": 0.21,
  "iterations": 14,
  "converged": true,
  "applied": true,
  "warnings": []
}
```

**Notes** — Both bodies are meshed at the SAME deflection (source-derived unless overridden), the same recipe `measure_deviation`/`mesh_diagnose`/`mesh_thickness` use. `bodyId == referenceBodyId` is a request error. `aligned()` returning `nil` (fewer than 3 points after welding on either side) is an `isError` result, not a silently-empty success.

**Drives** — `OCCTSwiftMesh` `Mesh.aligned(to:options:)` (point-to-plane ICP: Chen & Medioni's objective, Rusinkiewicz & Levoy's normal-space sampling, Low's linearized point-to-plane solve — OCCTSwiftMesh#22/#25); `Shape.transformed(matrix:)` for the `apply` path; `HistoryRegistry`/`SceneHistory` for the same generation-reset semantics `transform_body` uses.

---

## `mesh_curvature`

Per-vertex discrete curvature over a body's own mesh (Rusinkiewicz per-face tensor, `OCCTSwiftMesh.Mesh.vertexCurvatures()`, OCCTSwiftMesh#23/#24): principal curvatures `k1` (larger magnitude, convex-positive) / `k2`, `mean = (k1+k2)/2`, `gaussian = k1*k2`, plus a colored render and bounded stats. No reference body needed — this is a property of one mesh. Phase 3 of the mesh-analysis expansion, the single-body curvature render mode deferred from #101.

**UNITS** — `k1`/`k2`/`mean` are in **1/mm** (curvature = 1 / radius of curvature). `gaussian` is in **1/mm²** — a genuinely different unit (the product of two curvatures), not a typo. This matters for `highCurvatureFraction` below: its clamp is always computed from the SAME channel `colorBy` selects, never cross-compared against a different channel, so the unit difference never creates a silent mismatch.

**Welding is internal and mandatory.** `vertexCurvatures()`'s own precondition is a WELDED mesh — on unwelded input every vertex touches exactly one triangle, so curvature degrades to that triangle's own unaveraged value. This tool welds the tessellated mesh before computing anything; `triangleCount`/`vertexCount` in the response are the WELDED counts, and the render is built entirely from the welded mesh too, so there's no triangle-index correspondence problem between the stats and the render.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to analyse. |
| `deflection` | number | no | Mesh linear deflection. Default 0.5% of the body's bbox diagonal. |
| `colorBy` | string | no | `"mean"` (default) \| `"gaussian"` \| `"k1"` \| `"maxAbs"` (= `max(\|k1\|, \|k2\|)`). Which channel drives the render and `highCurvatureFraction`. |
| `clampPercentile` | number (0, 1] | no | The colormap is clamped symmetrically at the p-th percentile of `\|colorBy value\|` over all welded vertices. `1.0` = no clamp. Default 0.95. |
| `render` | boolean | no | Render a per-triangle colored PNG with a colorbar legend. Default `true`. |
| `renderPath` | string | no | Override the default render path (`<output_dir>/<bodyId>_curvature.png`). |
| `chart` | boolean | no | Render a histogram PNG of the `colorBy` channel. Default `false`. |
| `chartPath` | string | no | Override the default chart path (`<output_dir>/<bodyId>_curvature_hist.png`). |
| `options` | object | no | Render options — same shape as [`render_preview`](mesh-visualization.md#render_preview)'s `options`. |

**Returns** — `{ bodyId, triangleCount, vertexCount, colorBy, clampPercentile, k1: { min, p05, median, p95, max }, k2: {...}, mean: {...}, gaussian: {...}, flatFraction, highCurvatureFraction, renderPath?, chartPath?, warnings[] }`. `triangleCount`/`vertexCount` are the WELDED mesh's counts (see above).

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_panel", "colorBy": "mean", "clampPercentile": 0.95 }
```
```json
// example result
{
  "bodyId": "carbody_panel",
  "triangleCount": 48120,
  "vertexCount": 24380,
  "colorBy": "mean",
  "clampPercentile": 0.95,
  "k1": { "min": -0.42, "p05": -0.01, "median": 0.0, "p95": 0.08, "max": 0.55 },
  "k2": { "min": -0.30, "p05": -0.02, "median": 0.0, "p95": 0.02, "max": 0.20 },
  "mean": { "min": -0.20, "p05": -0.01, "median": 0.0, "p95": 0.04, "max": 0.30 },
  "gaussian": { "min": -0.05, "p05": -0.0004, "median": 0.0, "p95": 0.001, "max": 0.08 },
  "flatFraction": 0.81,
  "highCurvatureFraction": 0.048,
  "renderPath": "/tmp/carbody_panel_curvature.png",
  "chartPath": null,
  "warnings": ["values beyond ±0.04 1/mm clamped for color (clampPercentile=0.95)."]
}
```

**`flatFraction`** — colorBy-INDEPENDENT: the fraction of vertices with `max(\|k1\|, \|k2\|)` below `0.1 / bboxDiag` (1/mm), an absolute model-scale flatness threshold (a curvature radius past ~10x the body's own bounding-box diagonal reads as flat regardless of how curved the rest of the body is).

**`highCurvatureFraction`** — the fraction of vertices whose `\|colorBy value\|` exceeds the SAME clamp value used for the render. By construction this is close to `1 - clampPercentile` (that's exactly what "clamped for color" means) — `clampPercentile: 1.0` drives it to 0 (nothing can read strictly above the true max), and lowering `clampPercentile` reveals a growing tail. The underlying `k1`/`k2`/`mean`/`gaussian` stat blocks themselves do NOT change with `clampPercentile` — only the color scaling and this fraction do.

**Unweldable-soup warning** — fires only when the internal weld pass demonstrably failed to merge ANY vertex (`vertexCount == triangleCount * 3` after welding) — a mesh-TOPOLOGY fact, never a curvature-VALUE heuristic. This matters because a genuinely flat body (a box, away from its edges) also reads near-zero curvature almost everywhere, so "curvature reads near-zero" can't itself be the trigger without false-positiving on ordinary flat parts.

**Notes** — Zero-normal/degenerate vertices (excluded from the upstream fit entirely, per `vertexCurvatures()`'s own docs) participate in every stat and in `flatFraction` as flat (`k1 == k2 == 0`) — no special-casing beyond `flatFraction` itself. `gaussian`'s sign is diagnostic: positive at a dome/bowl (both principal curvatures the same sign), negative at a saddle.

**Drives** — `OCCTSwiftMesh` `Mesh.vertexCurvatures()` (Rusinkiewicz per-face curvature tensor averaged onto welded vertices, OCCTSwiftMesh#23/#24) + `Mesh.welded()`. Render reuses the band-group trick (`ChartRenderer.divergingColor` + `overlayColorbar`) `HeatmapTools`/`MeshZoneTools` established.

---

## `fit_primitives`

RANSAC primitive report over a body's (or one zone's) mesh: Schnabel-style GLOBAL-inlier primitive extraction (`OCCTSwiftMesh.Mesh.segmentedRANSAC(_:)` / `segmentedAutoSelect(dihedral:ransac:)`, OCCTSwiftMesh#27/#32, closing #107).

**Why this is a separate tool from `segment_mesh_zones`.** `segment_mesh_zones`' dihedral region-growing only ever absorbs edge-ADJACENT neighbours — right for a single continuous surface graph, but a genuinely cylindrical barrel interrupted by a boss (a raised feature that locally breaks the dihedral-continuity graph) reads as two or more zones there even though it is one cylindrical surface. RANSAC instead claims GLOBAL inliers: every triangle within tolerance of a fitted candidate counts, wherever it sits in the mesh, so it can unify what the zone table keeps split — the reverse-engineering question "does this same primitive recur elsewhere" that a per-region zone fit cannot answer.

`zoneId` (from [`segment_mesh_zones`](#segment_mesh_zones)) scopes the fit to just that zone's own triangles, re-meshed at the zone's own stored deflection with a `MeshSignature` staleness check — the identical resolution path [`zone_continuity_sweep`](#zone_continuity_sweep) uses. Omit it to fit the whole body.

`strategy` picks the extraction method:
- `"ransac"` (default) — `Mesh.segmentedRANSAC(_:)` only.
- `"auto"` — `Mesh.segmentedAutoSelect(dihedral:ransac:)`'s substantial-clean-coverage bake-off between dihedral region-growing and RANSAC; reports which one won via `strategyScores`.

**Server:** Swift only

**Parameters**

| name | type | required | description |
|------|------|:--------:|-------------|
| `bodyId` | string | yes | Body to fit. |
| `zoneId` | string | no | A `zone:<bodyId>#<n>` id from `segment_mesh_zones`, scoping the fit to just that zone's own triangles. Omit to fit the whole body. |
| `strategy` | string | no | `"ransac"` (default) or `"auto"`. |
| `inlierEpsilonMm` | number (> 0) | no | Absolute mm point-to-primitive distance for a triangle to count as an inlier. Default: library auto (0.5% of the fitted mesh's bbox diagonal). |
| `minSupportTriangles` | integer (≥ 1) | no | Minimum inlier-cluster triangle count for a candidate primitive to be accepted. Default: library default (30). For `strategy: "auto"`, also sets the dihedral bake-off candidate's `minRegionTriangles`. |
| `maxPrimitives` | integer (≥ 0) | no | Cap on returned primitives (largest-support-first kept). Dropped primitives are named in a warning with their own triangle count, kept separate from `uncoveredFraction`. |
| `deflection` | number | no | Mesh linear deflection for a whole-body fit. Default 0.5% of the body's bbox diagonal. Ignored (and warned) for a `zoneId`-scoped fit, which always re-meshes at the zone's own segmentation deflection. |
| `render` | boolean | no | Render a categorical per-primitive PNG with a legend. Default `true`. |
| `renderPath` | string | no | Override the default render path (`<output_dir>/<bodyId>_primitives.png`). |
| `options` | object | no | Render options — same shape as [`render_preview`](mesh-visualization.md#render_preview)'s `options`. |

**Returns** — `{ bodyId, zoneId?, strategy, strategyScores?: { dihedral, ransac, chosen }, primitives: [{ kind, params, residualRmsMm, residualMaxMm, inlierRatio, supportTriangles, supportFraction, areaMm2 }], uncoveredFraction, renderPath?, warnings[] }`. `primitives` is largest-support-first (matching `SegmentedMesh.regions`' own order). `strategyScores` is present only when `strategy: "auto"`. `kind`/`params` follow `FittedPrimitive.params`' per-kind layout: plane `[nx,ny,nz,d]`, sphere `[cx,cy,cz,r]`, cylinder `[px,py,pz,ax,ay,az,r]` (point on axis, unit axis direction, radius), cone `[apexX,apexY,apexZ,ax,ay,az,halfAngleRadians]`.

**`uncoveredFraction` vs. a `maxPrimitives` cap — kept strictly separate.** `uncoveredFraction` is the fraction of the fitted mesh's triangles that NO primitive ever claimed as an inlier, computed from the library's own `truncatedTriangleCount` BEFORE any `maxPrimitives` cap is applied (this tool always calls the upstream primitive with an unbounded region count, then applies `maxPrimitives` itself against the already-sorted result) — it never moves just because `maxPrimitives` got smaller. A separate cap-truncation warning (naming its own triangle count) fires when `maxPrimitives` actually drops primitives from the response; those triangles WERE claimed by a primitive and are never counted toward `uncoveredFraction`.

**Determinism** — inherited from the upstream primitive's deterministic splitmix64 candidate sampling (no system RNG anywhere in the pipeline): repeat calls with identical arguments against an unchanged body/zone return byte-identical primitive tables.

**Example**

```json
// tool call arguments
{ "bodyId": "carbody_scan", "strategy": "auto", "minSupportTriangles": 50 }
```
```json
// example result
{
  "bodyId": "carbody_scan",
  "zoneId": null,
  "strategy": "auto",
  "strategyScores": { "dihedral": 0.62, "ransac": 0.81, "chosen": "ransac" },
  "primitives": [
    { "kind": "cylinder", "params": [0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 6.0], "residualRmsMm": 0.08, "residualMaxMm": 0.31, "inlierRatio": 0.97, "supportTriangles": 4210, "supportFraction": 0.42, "areaMm2": 15200.0 },
    { "kind": "plane", "params": [0.0, 1.0, 0.0, 900.0], "residualRmsMm": 0.02, "residualMaxMm": 0.09, "inlierRatio": 0.99, "supportTriangles": 2100, "supportFraction": 0.21, "areaMm2": 8300.0 }
  ],
  "uncoveredFraction": 0.06,
  "renderPath": "/tmp/carbody_scan_primitives.png",
  "warnings": []
}
```

**Notes** — Both bodies/zones mesh at the standard `MeshParameters` recipe shared with `DeviationTools`/`MeshZoneTools`. A zoneId-scoped fit re-meshes at the zone's own stored deflection unconditionally (a `deflection` argument is ignored, with a warning, since `triangleIndices` would otherwise no longer line up with a freshly built mesh). Render reuses the band-group trick (`ChartRenderer.categoricalColor` + `overlayZoneLegend`) `segment_mesh_zones`/`zone_continuity_sweep` established, coloring each returned primitive's triangles as one flat-colored group.

**Drives** — `OCCTSwiftMesh` `Mesh.segmentedRANSAC(_:)` / `Mesh.segmentedAutoSelect(dihedral:ransac:)` (Schnabel-style global-inlier RANSAC extraction, OCCTSwiftMesh#27/#32); `ZoneRegistry` for `zoneId` resolution (the same rungs `zone_continuity_sweep` uses).

---

## Phase 3 backlog (filed, not yet implemented)

`mesh_curvature` and `fit_primitives` are the Phase 3 tools unblocked by already-released OCCTSwiftMesh primitives (per-zone slippage classification is likewise already integrated into `segment_mesh_zones`/`zone_continuity_sweep` — see above). The rest of Phase 3's design-intent surface (crease-edge feature outlines, curvature-ordered segmentation seeding, generalized winding number orientation) needs new upstream primitives; those are filed as issues rather than implemented ad hoc, per the ecosystem's factoring rule (OCCTMCP wraps, never implements mesh algorithms):

- [SecondMouseAU/OCCTSwiftMesh#28](https://github.com/SecondMouseAU/OCCTSwiftMesh/issues/28) — crease-edge detection (dihedral-fold rings) → [OCCTMCP#108](https://github.com/SecondMouseAU/OCCTMCP/issues/108) (`detect_mesh_features`)
- [SecondMouseAU/OCCTSwiftMesh#29](https://github.com/SecondMouseAU/OCCTSwiftMesh/issues/29) — curvature-ordered seeding for `segmented(_:)` (now that `vertexCurvatures()` exists)
- [SecondMouseAU/OCCTSwiftMesh#30](https://github.com/SecondMouseAU/OCCTSwiftMesh/issues/30) — generalized winding number orientation / inside-out check (upgrades the deviation suite's `ambiguousFraction ~ 1.0` inverted-winding heuristic)
