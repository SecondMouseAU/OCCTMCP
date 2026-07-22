# Mesh-analysis expansion: research synthesis, proposal, and plan

Date: 2026-07-21. Trigger: OCCTMCP #101 (`segment_mesh_zones`) and #102 (`zone_continuity_sweep`),
both serving OCCTReconstruct's zone model for the kiha40 carbody reconstruction. Scope: use the two
requests as the spearhead of a broad, phased expansion of raw-mesh analysis in the MCP.

Note on the zone model source: the "2026-07-21, Ed" zone-model note referenced by the issues is not
committed anywhere in the ecosystem (verified by exhaustive grep). The committed equivalent is the
constant-runs vs transition-zones model in OCCTReconstruct
`okf/decisions/bodyshell-loft-reconstruction.md` and `okf/references/kiha40-fixture.md`, which this
plan treats as the zone model's documented form.

---

## 1. Research findings (condensed)

### 1.1 What OCCTMCP has today

- An imported STL becomes a one-face-per-facet BREP shell (`IOTools.swift:154`, round-tripped
  through `writeBREP(allowInvalid:)`), indistinguishable in the manifest from a real B-rep body.
  Every tool loads it via `IntrospectionTools.loadShape` -> `loadBREP`.
- Mesh-capable today (they re-mesh the shape and work on triangles): `measure_deviation`,
  `deviation_histogram`, `cross_section_compare`, `signed_deviation_heatmap`, `overlay_render`,
  `generate_mesh`, `simplify_mesh`, `render_preview`. Degrade or fail on facet shells (they consume
  `faces()`/`edges()`/analytic topology): `query_topology`, `validate_geometry`,
  `recognize_features`, `check_thickness`, `select_topology`, `compute_metrics` (volume/COM),
  graph tools.
- Reusable engine in `DeviationTools`: `TriMesh` (double-precision soup + vertex KD-tree + incident
  adjacency), `signedQuery`/`signedDistances` with the `.robust` normal-gated sign mode,
  `closestPointOnTriangle`, `sectionize`, `defaultDeflection`. Missing: weld, triangle adjacency,
  curvature, connected components, triangle-level BVH.
- Cross-section machinery (`CrossSectionCompareTool`) is strong and directly reusable for #102:
  shared-frame `CutPlane` slicing, open-profile fallback, `outerEnvelope` per-sector radial max,
  `radialShapeL2`/`envelopeShapeL2` pose-invariant shape scalars. OCCTSwiftMesh also ships an
  unused sweep helper `Mesh.crossSections(axis:through:spacing:margin:)`.
- Rendering: OffscreenRenderer has no per-triangle surface color pass; the heatmap's proven
  workaround is one flat-colored `ViewportBody.directMesh` per color group. Per-zone coloring is
  the same trick with a categorical palette (ChartRenderer has only the diverging map today) plus
  a legend compositor.
- `generate_mesh`'s quality report stubs `nonManifoldEdges: 0` (`MeshTools.swift:182`).
- Body ids are a flat namespace; nothing registers derived sub-bodies today. The heatmap's
  transient (never-persisted) ViewportBody groups are the lightweight precedent.

### 1.2 Ecosystem: where primitives can live

- **OCCTSwiftMesh v1.1.6** (public, gsdali): extends `OCCTSwift.Mesh`; public surface is QEM
  `simplified(_:)` + `crossSection`/`crossSections` only. No public normals, adjacency,
  components, or segmentation. Deps: OCCTSwift + vendored MIT meshoptimizer only. Charter
  ("mesh-domain post-processing, robust on open unwelded scan meshes") fits segmentation;
  published roadmap (smoothing/repair/remeshing) does not yet list it. Stale `version` constant
  (1.1.0) worth fixing in passing.
- **OCCTSwiftMesh is the common upstream** of both OCCTMCP and OCCTReconstruct: the correct,
  direction-preserving home for shared primitives. OCCTMCP must not depend on OCCTReconstruct
  (private, and deliberately downstream of the MCP's annotate-and-persist layer).
- **Reference implementation to port** (OCCTReconstruct `Sources/ReconstructCompute/`, pure
  Swift+simd, no third-party entanglement, uniform LGPL-2.1):
  - `IndexedMesh` (welded shared-vertex mesh) + `faceNormals()` + `triangleAdjacency()` +
    `connectedComponents()` + `subMesh(triangleIndices:)`.
  - `segmentSmoothRegions(maxDihedralDegrees: 20)`: deterministic DFS flood over edge-adjacent
    triangles gated on face-normal dot >= cos(threshold). First-order only; no curvature term
    despite #101's wording.
  - `RegionMerging.merge(...)`: the mandatory companion. Union-find over adjacent regions, sorted
    smoothest-boundary-first with deterministic tie-breaks; a merge is accepted only if the union
    still fits ONE primitive (plane/cylinder/sphere/cone via `PrimitiveFitting` + `Linalg` Jacobi
    eigen) within `max(0.004 x bboxDiag, 1e-6)` and does not degrade the parents' fit beyond
    slack. Without it, curved bodies "shatter into confetti" (pinned by
    `SegmentationBakeoffTests`). Caps: 60 passes, `maxRegionsToMerge = 1500`.
  - Also available to crib later: `PrimitiveRANSAC` (Schnabel-style) + `AutoSegmenter` bake-off,
    `BodySignature`/`Instancing` (PCA + mirror congruence), `boundaryLoops`, `creaseEdges`,
    generalized-winding-number repair, `RayCast`.
- **OCCTSwiftReconstructMesh is ruled out** as a home: private, viewport-heavy app; its vendored
  ReconstructCompute slice omits exactly the segmentation/merge/fitting files.
- **SwiftMeshHeal 0.2.1** (SecondMouseAU, pure Swift, dependency-free): watertightness, boundary
  loops, non-manifold edge counts, Liepa hole fill, through-opening classification. A candidate
  backing for a future mesh-domain diagnose/heal surface, or its metrics can be reimplemented in
  OCCTSwiftMesh foundations (decision left to the OCCTSwiftMesh issue discussion).
- Note on representations: `OCCTSwift.Mesh` is an indexed type, but OCCT tessellation and STL
  loading produce (near-)unshared vertices in practice. Every adjacency-based algorithm therefore
  needs a weld pass first. Welding at the root also removes the reason `widenedK` had to be
  oversized in the deviation engine.

### 1.3 Field survey (what the mature tools and literature say)

- The consensus scan->CAD pipeline: (1) acquisition/registration, (2) mesh repair/cleanup,
  (3) segmentation into surface regions, (4) surface classification + fitting, (5) design-intent
  extraction (axes, symmetry, patterns), (6) verification against the scan. OCCTMCP has 1 and 6;
  the gap is mesh-domain 2-5. #101 is stage 3; #102 is stages 4/5.
- #101 is Geomagic Design X's "Auto Segment"; #102 is its "extract design intent" stage. No
  open-source or MCP tool does per-zone loftable-extent measurement well: a genuine differentiator.
- Region growing parameter convention worth copying (CGAL): `maximum_angle` (deg),
  `maximum_distance` (absolute mm, not bbox fractions), `minimum_region_size`. Seed low-curvature
  first; unassigned high-curvature strips are desirable output (fillet/blend candidates).
- **Slippage analysis** (Gelfand-Guibas 2004) is the canonical "loftable extent" method: 6x6
  covariance of per-sample rows [(p x n), n]; near-zero eigenvalues classify plane / cylinder /
  sphere / extrusion (with direction) / revolution (with axis) / helix. Cheap special case: pure
  extrusion direction = smallest eigenvector of the normal covariance. This unifies zone
  classification and axis detection and is the phase-3 crown jewel.
- CloudCompare's M3C2 independently validates the #72 `signMode` design (normal-gated
  correspondence is the field's answer to sign ambiguity on thin/noisy data).
- Curvature for scan data: Rusinkiewicz per-face tensor averaging (robust to noise/irregular
  tessellation) over Meyer cotan (needs the obtuse-triangle clamp; blows up on slivers). All
  curvature work requires welded connectivity and sliver handling first.
- Integrity metrics are the cheapest, most decision-relevant LLM signals and should gate
  everything: watertight, edge/vertex manifold, orientable, component table, boundary loops,
  Euler/genus, degenerate/sliver counts, self-intersection. Open3D's API shape is the model.
  Generalized winding number is the principled upgrade path for the "is the winding inverted"
  heuristic (`ambiguousFraction ~ 1.0`).
- ICP: point-to-plane converges far faster on engineering surfaces; **normal-space sampling is
  mandatory for a carbody side** (near-flat with small features slides otherwise). GOM's alignment
  taxonomy (pre-align / best-fit / local best-fit / 3-2-1 / RPS/datum) is the argument-enum to
  copy. Scan-vs-CAD deviation is meaningless before alignment: `align_bodies` is the single
  highest-leverage tool after the two requests.
- Signal design for LLM consumers: booleans and small counts first; bounded scalars with units
  and frames; fixed-size distributions (never raw per-element arrays); stable addressable IDs for
  zones/stations (mirroring selectionIds); explicit ambiguity channels; a rendered image per
  claim. QIF's {feature, nominal, actual, deviation, tolerance, pass/fail} shape for
  measurements; printability-API check-list shape for diagnose. No serious mesh-inspection MCP
  exists yet.
- Wall thickness on meshes: ray method (normal-opposite, cone-averaged / SDF; finds thin walls)
  + sphere method (max inscribed; finds thick masses); report both as histogram + below-threshold
  zones. Nearly free on the existing KD/BVH engine.

### 1.4 Libraries and licenses (commercial binary distribution)

- Nothing on Swift Package Index merits a hard dependency (Euclid/iOverlay/KDTree/swift-icp:
  inspire-only or too immature). Apple Accelerate/simd covers all needed linear algebra (3x3
  eigen for PCA/fitting); no Eigen needed for our own Swift code.
- Porting references (safe): **PMP library (MIT)** primary reference for half-edge/curvature/
  integrity; libigl **core only** (MPL-2.0; never the `copyleft/` GPL subtree; GitHub's GPL label
  is a misclassification) with file-whitelist if vendoring; Open3D/trimesh as API-shape models.
- Vendor-worthy (the meshoptimizer model), only when the phase needs them: **Clipper2 (BSL-1.0**,
  self-contained, no binary attribution required) for 2D profile booleans/offset;
  **small_gicp (MIT**, header-only, active) if ICP is vendored rather than ported.
- Excluded on license: CGAL (GPL packages), VCGlib/MeshLab (GPL), TEASER++ (GPL pmc dep),
  mcut. MPL-2.0 rules if used: keep MPL files intact in their own files, offer their source
  including modifications, keep headers. No new LGPL deps (relink obligation on iOS/macOS).
- Default posture: **pure-Swift ports into OCCTSwiftMesh** (the reference segmentation stack
  already exists in-ecosystem to port); vendoring only where a library is clearly better than a
  port (Clipper2, small_gicp).

---

## 2. Proposal

### 2.1 Positioning

Build OCCTMCP into the first serious mesh-inspection MCP surface: the missing stages (repair-
diagnosis, segmentation, classification, design-intent measurement, alignment) of the scan->CAD
pipeline, with the existing deviation suite as the verification stage it already is. Every tool
follows the established output grammar: compact JSON (bounded, unit-carrying, stable IDs,
ambiguity channels) + a rendered PNG per claim.

### 2.2 Factoring rules (per ecosystem convention and user direction)

1. Algorithm primitives live in **OCCTSwiftMesh**, added via **filed issues** (not authored ad
   hoc); OCCTMCP consumes released versions through pin bumps. OCCTMCP never depends on
   OCCTReconstruct.
2. Pure Swift + simd/Accelerate by default; vendor only Clipper2 / small_gicp if and when their
   phases need them; no GPL, no new LGPL.
3. OCCTMCP owns: tool schemas, JSON report shaping, rendering (band-trick + palettes + legends),
   registries/sidecars, and MCP-side composition of primitives.
4. Zone measurements in the MCP must remain an independent check of OCCTReconstruct's engine
   (mandatory-analytic-verification policy): sharing low-level primitives via OCCTSwiftMesh is
   acceptable; the MCP's aggregation/verdict layer must not be the engine's code.

### 2.3 Proposed tool surface (phased)

| Phase | Tool | What it delivers |
|---|---|---|
| 1 | `segment_mesh_zones` (#101) | Zone table + per-zone categorical render + optional zone sub-body registration |
| 1 | `zone_continuity_sweep` (#102) | Per-zone loftable-extent map: within-tolerance runs + deviation intervals + annotated render |
| 2 | `mesh_diagnose` | Integrity check-list: watertight, manifold, components, boundary loops, genus, slivers, orientation |
| 2 | `align_bodies` | PCA pre-align + point-to-plane ICP (normal-space sampling), GOM-style mode enum, transform + residuals |
| 2 | `mesh_thickness` | Ray/SDF + inscribed-sphere thickness on raw meshes (mesh-domain complement to BREP `check_thickness`) |
| 2 | `detect_symmetry` | Candidate mirror planes/axes (PCA) verified via the signed-distance engine, residual-quantified |
| 3 | `fit_primitives` | Per-zone/whole-body RANSAC primitive report (plane/cylinder/sphere/cone, params + residuals) |
| 3 | slippage classification | Zone kind = extrude/revolve/helix + axis/pitch, folded into `segment_mesh_zones` + `zone_continuity_sweep` |
| 3 | `detect_mesh_features` | Crease-edge rings outlining recessed/raised features (doors, panels) on raw meshes |

Node server: none of this ports (established: post-v0.4 surface is Swift-only).

### 2.4 Key design decisions

- **Zone identity**: new actor-backed `ZoneRegistry` mapping `zone:<bodyId>#<n>` ->
  {triangle indices, params, fit, axis hints}, persisted to a `zones.json` sidecar (same pattern
  as `annotations.json`) so `zone_continuity_sweep(zoneId:)` resolves zones minted earlier
  without re-segmentation drift. Zone numbering: largest-first with the reference impl's
  deterministic tie-break.
- **Zone bodies**: render groups are transient ViewportBodies (`<bodyId>#zone<n>`, heatmap
  precedent). Manifest registration of per-zone sub-bodies is **opt-in**
  (`registerZones: true`, ids `<bodyId>_zone<n>`, facet-shell BREPs via
  `writeBREP(allowInvalid:)`), capped (default 32) so every existing measurement tool works
  per-zone downstream without flooding the scene.
- **Scale strategy for 400k+ tri scans**: weld first (fixes adjacency + the `widenedK` root
  cause); document and expose optional pre-decimation (`simplify_mesh` already reports achieved
  Hausdorff, so segmentation on a decimated mesh carries a quantified geometric error bound);
  merge-cap raised/configurable with pre-merge of coplanar confetti.
- **Sweep verdicts** (#102): per-station signals = lateral centroid offset, profile RMS/max vs
  running reference profile (reusing envelope + radial-signature machinery), arc-length delta;
  change-point pass = maximal within-tolerance runs (report as loftable extents, world
  `axisCoord` spans) + deviation intervals with magnitudes. Tolerances in mm, never bbox
  fractions.
- **Rendering**: categorical palette (colorblind-safe, ~12 distinguishable hues + overflow
  hashing) + zone legend compositor added to `ChartRenderer`; per-zone and per-station-verdict
  renders reuse the flat-color-group trick unchanged.

---

## 3. Detailed plan

### Phase 0: OCCTSwiftMesh foundations (blocks everything)

**File issue OCCTSwiftMesh: "Mesh foundations: weld, adjacency, normals, components, sub-mesh,
integrity metrics".** Contents:
- `Mesh.welded(tolerance:)` (grid-hash merge by tolerance; auto tolerance from bbox like
  `crossSection`'s weld default), `faceNormals()`, `vertexNormals()`, `triangleAdjacency()`,
  `connectedComponents()`, `subMesh(triangleIndices:)`, `boundaryLoops()`.
- Integrity report struct: watertight, edge/vertex-manifold counts, orientable, duplicate/
  degenerate/sliver counts (Verdict-style min-angle + aspect histograms), Euler characteristic /
  genus, per-component triangle count + area. Port/crib from ReconstructCompute
  (`SubMesh.swift`, `MeshSegmentation.swift`, `IndexedMesh.swift`) with provenance noted;
  SwiftMeshHeal overlap resolved in-issue.
- Fix the stale `version` constant while in there.

**Estimated size**: the ports exist and are small; the new work is the weld and the integrity
aggregation. Target release: OCCTSwiftMesh v1.2.0.

### Phase 1: the two requested tools (OCCTMCP v1.20)

**File issue OCCTSwiftMesh: "Region segmentation: dihedral region-growing + primitive-fit merge
(port of the OCCTReconstruct reference)".** Contents:
- Port `segmentSmoothRegions` + `RegionMerging` + `PrimitiveFitting` + `Linalg` onto welded
  `Mesh`; public API sketch:
  `Mesh.segmented(_ options: SegmentOptions) -> SegmentedMesh` with
  `SegmentOptions { maxDihedralDegrees = 20, mergeRelativeTolerance = 0.004,
  maxMergeAngleDegrees = 50, minRegionTriangles, maxRegions }` and
  `SegmentedMesh { regions: [MeshRegion], fits: [FittedPrimitive] }`,
  `MeshRegion { triangleIndices, area, bbox, meanNormal, boundaryLoopCount }`.
- Determinism guarantees carried over (tie-breaks); merge-cap behavior configurable; document
  the shatter-without-merge failure mode and the decimate-first recipe for scan-scale inputs.
- Explicitly out of scope for this issue: curvature seeding, RANSAC strategy, slippage (later
  issues). Target release: OCCTSwiftMesh v1.3.0 (or folded with foundations into one 1.2.0
  release if preferred).

**OCCTMCP work (#101 `segment_mesh_zones`)**, new `Tools/MeshZoneTools.swift`:
- Pipeline: load body -> mesh -> weld -> segment -> zone table JSON
  (`{id, triangleCount, areaMm2, areaFraction, bbox, meanNormal, boundaryLoops, adjacentZones,
  fit {kind, params, residualRmsMm}}`) -> categorical per-zone render (+legend) -> mint
  `zone:<bodyId>#<n>` in `ZoneRegistry` + `zones.json` -> optional capped sub-body registration.
- Single-body normal/curvature-change render mode (no reference needed) exposed as a render
  option, per the issue.
- `ChartRenderer`: categorical palette + `overlayZoneLegend`.

**OCCTMCP work (#102 `zone_continuity_sweep`)**, new `Tools/ZoneSweepTool.swift`:
- Resolve zone (or whole body) -> subMesh -> stations along axis (default: zone principal axis
  via PCA; explicit axis override) -> per-station profile vs running profile (refactor the
  profile/envelope/resampling helpers out of `CrossSectionCompareTool` into a shared internal
  `ProfileMath`) -> signals: lateral offset, RMS/max, arc-length delta -> maximal
  within-tolerance runs + deviation intervals (world `axisCoord` spans) -> JSON table +
  zone-colored-by-verdict render + optional per-station strip chart (`ChartRenderer`).
- Warnings channel: stations that missed the zone, open-profile stations, sparse stations.

**Registry/schema plumbing**: register both tools in `Server.swift` (65 tools), `ZoneRegistry`
actor + sidecar, `list_zones`/`clear_zones` housekeeping (fold into
`IntrospectionRegistryTools` pattern; count them in the tool total).

### Phase 2: inspection base (OCCTMCP v1.21, issues filed per tool)

- `mesh_diagnose` on foundations' integrity report; fixes `generate_mesh`'s stubbed
  `nonManifoldEdges` by the way. Printability-check-list JSON shape.
- **File issue OCCTSwiftMesh: "Point-to-plane ICP with normal-space sampling + PCA pre-align"**
  (port; small_gicp as reference/vendor fallback). MCP `align_bodies` wraps it with the GOM
  alignment enum, returns 4x4 + residual stats, and (opt-in) applies via `transform_body` so
  history/remap stays consistent.
- `mesh_thickness`: ray/SDF + shrinking-sphere on the existing TriMesh engine (MCP-side first;
  move to OCCTSwiftMesh if OCCTReconstruct wants it too).
- `detect_symmetry`: PCA candidate planes + signed-distance verification (MCP-side, reuses the
  deviation engine as-is).
- **File issue OCCTSwiftMesh: "Discrete curvature (Rusinkiewicz per-face tensor)"**: feeds
  curvature-ordered seeding, sliver-robust; PMP (MIT) as reference. Wire into `segment_mesh_zones`
  seeding + optional curvature render mode when it lands.

### Phase 3: design intent (sequenced after the zone model proves out)

- **File issue OCCTSwiftMesh: "Slippage analysis (Gelfand-Guibas) per region"**: 6x6 constraint
  covariance, eigen-ratio thresholds after unit-box normalization; classify
  plane/cylinder/sphere/extrude(direction)/revolve(axis)/helix(pitch). Folds into
  `segment_mesh_zones` (zone kind + axis) and gives `zone_continuity_sweep` its default axis
  per-zone. The differentiator feature.
- `fit_primitives` (RANSAC strategy surfaced), `detect_mesh_features` (crease rings), GWN
  orientation check upgrading the inverted-winding heuristic. Each as its own
  OCCTSwiftMesh-issue + MCP-tool pair.

### Release / repin sequencing

1. OCCTSwiftMesh issues filed (foundations, segmentation) -> reviewed -> released (v1.2.x/1.3.x)
   with docs per release policy.
2. OCCTMCP: repin OCCTSwiftMesh, implement Phase 1 tools + registry + renders + tests + docs,
   release v1.20.0 (serverVersion bump per convention), close #101/#102.
3. Phases 2/3 repeat the pattern per tool; docs updated in the same PR as each tool
   (docs-current policy).

### Test plan

- OCCTSwiftMesh: synthetic-fixture unit tests: box -> 6 zones; 12-facet coarse cylinder ->
  merge reunifies barrel + 2 caps (the shatter regression pin, mirroring
  `SegmentationBakeoffTests`); open half-cylinder shell; weld idempotence; determinism (two runs
  byte-identical).
- OCCTMCP: unit tests for zone JSON shaping + run/interval change-point logic on synthetic
  profiles; integration test: scripted extruded-profile body with a mid-span recess (a mini
  carbody: constant run, deviation interval, constant run) -> `import_file` STL ->
  `segment_mesh_zones` -> `zone_continuity_sweep` asserting the extent map. Kiha40 fixture
  stays local-only (provenance; public repo gets synthetic fixtures).
- Perf smoke: 442k-tri scan through weld+segment+sweep within the 2 min request budget on the
  reference machine; document decimate-first guidance with measured numbers.

### Risks and mitigations

- Scan noise shatters segmentation despite merge: mitigations layered (weld, optional
  pre-decimation with Hausdorff bound, configurable merge cap, later curvature seeding).
- Merge pass at scan scale exceeds `maxRegionsToMerge`: pre-merge coplanar confetti cheaply
  before the fit-gated pass; make cap explicit in the report (no silent truncation).
- Zone renumbering across calls confusing the LLM: `ZoneRegistry` + sidecar makes zone ids
  stable within a session and re-resolvable; renders always carry the id -> color legend.
- Independence-of-verification: keep MCP aggregation code separate from OCCTReconstruct's
  `SectionCompare` even where results should agree; agreement between the two is then evidence,
  not tautology.
- Float (`Mesh`) vs Double (`TriMesh`) precision: weld/fit in Float is fine at mm scan scale;
  the sweep's profile math stays in the existing Double pipeline.

## 4. Immediate next actions (on approval)

1. File the two OCCTSwiftMesh issues (foundations; segmentation port) with the API sketches
   above.
2. Comment on OCCTMCP #101/#102 linking them and recording the design decisions (zone ids,
   opt-in registration, decimate-first, axis defaults).
3. Implement Phase 1 in OCCTMCP behind the new pins once OCCTSwiftMesh releases land.
