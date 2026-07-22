---
title: Mesh analysis (zones)
parent: Tool Reference
nav_order: 12
---

# Mesh analysis (zones)

The mesh-inspection surface for raw scans / STL skins (#101, #102, Phase 2 of the mesh-analysis expansion): split a body's mesh into surface zones (plane / cylinder / sphere / cone, via OCCTSwiftMesh's dihedral region-growing with primitive-fit merge), then measure how far each zone's own cross-section stays constant along an axis (a loftable-extent map). Phase 2 adds a general mesh-inspection base that doesn't need zones at all: an integrity check-list, a mesh-domain wall-thickness measurement, reflective-symmetry detection, and GOM-style two-body alignment. Reach for this family when you have a scanned or imported mesh body and need to know what surfaces it's made of, whether it's structurally sound, how thick its walls are, how symmetric it is, or whether it's actually registered to a reference body yet, before committing to a reconstruction or measuring deviation against that reference. Swift-only.

## Tools

[`segment_mesh_zones`](#segment_mesh_zones) · [`zone_continuity_sweep`](#zone_continuity_sweep) · [`list_zones`](#list_zones) · [`clear_zones`](#clear_zones) · [`mesh_diagnose`](#mesh_diagnose) · [`mesh_thickness`](#mesh_thickness) · [`detect_symmetry`](#detect_symmetry) · [`align_bodies`](#align_bodies)

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
