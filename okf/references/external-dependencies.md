---
type: reference
title: External dependencies, and what each version floor buys
resource: https://github.com/SecondMouseAU/OCCTMCP/blob/main/Package.swift
tags: [reference, dependencies, versions, spm, occtswift, occt]
description: Every dependency of both implementations with the reason its floor is where it is, so a bump is a decision rather than a guess.
generated: { by: human:gsdali, at: 2026-09-06 }
sources:
  - { id: occtswift-830, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/830, usage_count: 1 }
  - { id: occtswift-905, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/905, usage_count: 1 }
  - { id: occtswift-844, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/844, usage_count: 1 }
  - { id: occtswift-943, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/943, usage_count: 1 }
  - { id: occtswift-835, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/835, usage_count: 1 }
  - { id: occtswift-377, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/377, usage_count: 3 }
  - { id: occtswift-380, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/380, usage_count: 1 }
  - { id: occtswift-404, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/404, usage_count: 1 }
  - { id: occtswift-400, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/400, usage_count: 1 }
  - { id: occtswift-398, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/398, usage_count: 1 }
  - { id: occtswift-477, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/477, usage_count: 1 }
  - { id: occtswift-333, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/333, usage_count: 1 }
  - { id: occtswift-331, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/331, usage_count: 2 }
  - { id: occtswift-327, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/327, usage_count: 1 }
  - { id: occtswift-336, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/336, usage_count: 2 }
  - { id: occtswift-290, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/290, usage_count: 1 }
  - { id: occtswift-280, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/280, usage_count: 1 }
  - { id: occtswift-275, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/275, usage_count: 2 }
  - { id: occtmcp-122, resource: https://github.com/SecondMouseAU/OCCTMCP/issues/122, usage_count: 1 }
  - { id: occtmcp-107, resource: https://github.com/SecondMouseAU/OCCTMCP/issues/107, usage_count: 1 }
  - { id: occtswift-763, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/763, usage_count: 1 }
  - { id: occtswift-642, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/642, usage_count: 1 }
  - { id: occtswiftscripts-80, resource: https://github.com/SecondMouseAU/OCCTSwiftScripts/issues/80, usage_count: 1 }
  - { id: occtswift-541, resource: https://github.com/SecondMouseAU/OCCTSwift/issues/541, usage_count: 1 }
usage_window: { from: 2026-07-27, to: 2026-09-07 }
---

# External dependencies, and what each version floor buys

## Current pins (the v1.37.1 beta line)

`Package.swift` is the source of truth; this is what it says as of v1.37.1-beta.3. The entries
under "Swift implementation" below record why each floor moved over time and still describe the
history, so their version numbers are older than these.

| Package | Pin | Why |
|---|---|---|
| OCCTSwift | `exact: "4.0.0-beta.4"` | Exact, not `from:`: `v4.0.0-kernel.N` tags are pre-releases of the same package and sort above every beta, so a `from: "4.0.0-beta.4"` range silently resolves to the newest kernel tag. Move it deliberately when the next beta ships. |
| OCCTSwiftMesh | `from: "1.7.6-beta.1"` | The beta that shares the OCCTSwift 4 pin. |
| OCCTSwiftScripts | `from: "1.7.1-beta.1"` | Same. Provides `occtkit` plus the in-process `ScriptHarness` and `DrawingComposer`. |
| OCCTSwiftInteraction | `from: "3.0.0-beta.1"` | Vends `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit`. |
| OCCTSwiftIO | `from: "2.0.0-beta.1"` | Same. |
| OCCTSwiftViewport | `from: "1.2.0"` | Not on the beta line. |
| swift-sdk | `from: "0.11.0"` | MCP transport and types. |

A consumer only gets a pre-release by naming it, so the stable line stays at v1.37.0 until the
siblings go stable. The bump rule when they do: re-check each pin against what a fresh clone
resolves (`OCCTMCP_FORCE_REMOTE_DEPS=1 swift build`), not against local sibling checkouts.

## Swift implementation

- **OCCTSwift** ≥ 3.0.0: kernel wrapper around OpenCASCADE. **v3.0.0 (#175) is a Rule 2 major on a
  much smaller surface than v2.0.0.** OCCT itself does not move: the kernel stays at 8.0.1, rebuilt
  as `v3.0.0-kernel.1` to carry two patches the 2.0.0 asset was missing (OCCTSwift#905/#913). Three
  breaks, full table in OCCTSwift `docs/SEMVER.md#v300`. Two are zero-hit here:
  `Selector.SubShapeType.compsolid` renamed `.compSolid`, and `Shape.ShapeFilterType.RawValue`
  moving `Int32` to `Int` as `ShapeFilterType` becomes a `ShapeType` typealias (both
  OCCTSwift#844). The third one reaches almost every tool: `Shape.bounds`/`size`/`center`,
  `Wire.bounds`, `Edge.bounds` and `Face.bounds`/`exactBounds` are now **Optional**
  (OCCTSwift#943), returning `nil` on OCCT's own `Bnd_Box::IsVoid()` rather than fabricating a
  `(0,0,0)-(0,0,0)` box that no caller could tell apart from a genuine zero-size shape at the world
  origin. **No call site here defaults to zero.** Every answer this repo computes leaves as an LLM
  tool result, where an invented bounding box does not degrade, it reads as a measurement. Each
  unwrap routes into a failure path the code already had, in one of three shapes. (1) *An explicit
  error*, wherever the box IS the answer or sets the scale everything else is judged against:
  `show_bounding_box`, `select_topology`'s body anchor (the anchor is the bbox centre),
  `find_correspondences`' match tolerance, `segment_mesh_zones`, `mesh_curvature`'s `flatFraction`
  threshold, `symmetric_difference_volume`'s shared sampling box, `cross_section_compare`'s default
  station point, and every deflection-defaulting tool, since `DeviationTools.defaultDeflection` now
  returns `Double?` (12 call sites, each guarded ahead of its existing `defl > 0` check;
  `ZoneSweepTool.resolveZoneMesh` throws a new `ZoneMeshResolutionError.noBoundingBox` instead,
  matching its own error style). `read_brep` reads the extent **before** it writes the manifest, so
  an empty BREP is refused rather than registered as a body whose reported extent would have to be
  invented. (2) *Omit the optional extra*, where the box is context rather than the answer:
  `compute_metrics` leaves `boundingBox` absent exactly as its `boundingBoxOptimal` branch always
  has, `detect_mesh_features` drops `containingZones` with a warning (no `MeshSignature` means no
  staleness check), `align_bodies` reports that its large-residual check could not be scaled
  instead of dropping it silently. (3) *The existing nil/lost path*: `remap_selection` gives that
  body's selections the same `"lost"` fate an unloadable body already got;
  `CorrespondenceTools.loadSourceCentroid` and `inferTranslation` already returned Optional. Two
  things that look like breaks and are not: `Shape.TopAbs_ShapeEnum` survives as a deprecated
  typealias, and `ThruSectionsBuilder.setCriteriumWeight` returning `Bool` where it returned `Void`
  is `@discardableResult`. One new deprecation warning, not an error: `Shape.transformed(matrix:)`
  now prefers `Matrix12Grouped` over a raw `[Double]` (OCCTSwift#835), which is exactly the
  grouped-vs-interleaved footgun `AlignTools` documents at length below; migrating it is a
  follow-up, not part of the repin.
  **v2.0.0 (#171) was the previous correctness major**
  (Pass 1a/1b duplication+bug-fix audit, OCCTSwift#377/#669; OCCT absorbed to 8.0.1), 17 breaking
  API changes, full table in OCCTSwift `docs/SEMVER.md#v200`. Two needed a source fix here: #605
  (`Shape.centerOfMass` returns `nil` instead of the bounding-box centre for anything enclosing no
  volume: every vertex-anchor site now reads `Shape.vertices()` via the new
  `SelectionTools.vertexPoint(_:)` helper instead) and #642/#699 (`AAG.detectPockets()`/
  `detectHoles()`'s `floorFaceIndex`/`wallFaceIndices`/`faceIndex` are occurrence indices into
  `orientedFaces()` now, not `faces()`: `AnalysisTools.buildFeatureReport` converts to the stable
  `distinctFaceIndex` before reporting to the LLM, `GapFillerTools.mintFaceSelection` indexes
  `orientedFaces()` directly, `AutoDimensionTool` converts before calling `edgesInFace(at:)`; all
  three only diverge on a body with a face shared between two solids, e.g. a boolean/pattern
  result, see `AAGFaceIndexTests`). Also #541 changed `Shape.faces()` itself to the deduplicated
  convention `BRepGraph` already used, so `TopologyIdentityTests`' shared-face divergence fixture
  moved to the still-occurrence-based `orientedFaces()`. The remaining breaks had zero call sites
  in this repo. **v1.17.0** is Pass 1a of the
  OCCTSwift#377 duplication audit (OCCTSwift#380), and carries two documented source breaks plus
  eleven silent behaviour changes. Neither break reaches this repo (zero call sites, audited at
  bump time): `Surface.drawMesh`/`evaluateGrid` return a `SurfaceGrid` struct instead of
  `[[SIMD3<Double>]]` (OCCTSwift#404; no deprecation shim is possible, Swift cannot overload on
  return type alone, and the two old nestings were OPPOSITE, `[u][v]` vs `[v][u]`, so a mechanical
  rewrite of an `evaluateGrid` caller transposes its data), and the no-`tolerance`
  `Curve3D.interpolate(points:startTangent:endTangent:)` overload is removed (OCCTSwift#400: it
  shadowed its tolerance-aware sibling, so `tolerance:` was unreachable and pinned at `1e-6`).
  Nine overlapping continuity enums consolidated into `SurfaceContinuity` +
  `ParametricContinuity` (OCCTSwift#398), every retired name kept as a deprecated alias, so
  source-compatible. Of the eleven silent behaviour changes the headline is
  `Curve3D.length`/`arcLength*` integrating per `GeomAbs_CN` span instead of a single Gauss
  quadrature across the whole domain (OCCTSwift#477: up to 5% wrong on a multi-span BSpline, an
  accuracy fix on the ORDINARY path, not a failure-path sentinel); the rest are
  `Surface.approximated()` no-arg defaults (`tolerance` 0.01 to 1e-3, `maxDegree` 10 to 8),
  `Surface.curvatures(u:v:)` resolution 1e-6 to 1e-7, `Point2D.distance(to: Curve2D)` returning
  `.infinity` instead of `-1` when there is no projection (which flips the sense of any
  `distance < tolerance` test), `arcLength` failure sentinels 0.0 to -1.0,
  `Surface.normal(u:v:)` returning a zero vector at a near-degenerate point (now matching
  `normal(atU:v:)`, which is the spelling this repo's own two call sites use, so unaffected),
  zero-radius circle/conic factories returning nil, and `BRepGraph.sampleFaceUVGrid` unpacking
  the written count. None reach this repo's own code: there are no `arcLength` calls on OCCT
  curves (`ZoneSweepTool`'s `arcLengthDeltaMm` is polyline-based, via
  `ProfileMath.polylineLength`/`closedLength` over mesh cross-sections), and no
  `Curve2D`/`Point2D`/`approximated`/`curvatures`/`sampleFaceUVGrid`/`interpolate` call sites at
  all. Every sibling package now compiles against 1.17.0 though (all of them floor OCCTSwift with
  `from:`, so 1.17.0 satisfies the whole cohort), so the test suite is the only net for a change
  arriving transitively. **Bridge ABI:** v1.17.0 changed `OCCTBridge`'s C ABI, so a build with
  `OCCTSWIFT_BRIDGE_PREBUILT=1` must take this release's `OCCTBridge.xcframework`; a v1.16.1
  bridge binary silently mismatches this Swift layer and surfaces as missing bridge symbols.
  `OCCT.xcframework` is unchanged and stays pinned at its v1.15.18 asset, so this bump carries no
  kernel patch changes. **v1.15.0 renamed `TopologyGraph` to
  `BRepGraph`** (OCCTSwift#333, filed and shipped same-day; old name kept as a deprecated
  typealias for one or more releases, but OCCTMCP has already migrated every reference). v1.14.0
  adds `*WithFullHistory` for `translated`/`rotated`/`scaled`/`mirrored`/`linearPattern`/
  `circularPattern` (OCCTSwift#331), not yet wired into `transform_body`/`mirror_or_pattern`,
  which still do a generation reset. v1.13.0 adds `*WithFullHistory` for heal/sew/quilt/solid
  (OCCTSwift#327): `heal_shape` now records real history instead of the old topology-count
  heuristic. **OCCTSwift#336 retracted, v1.15.2:** a `*WithFullHistory` op chained onto the OUTPUT
  of a prior `*WithFullHistory` op absorbs correctly; the originally-reported "absorbs zero
  records" was a box-centering mistake in the repro's own geometry (`Shape.box` is centered at
  the origin, not corner-anchored), not a defect in `add(_:absorbing:...)`; see the
  `HistoryRegistry.swift` bullet above. v1.12.0 adds
  `BRepGraph.add(_:absorbing:inputRoots:operationName:)`, which imports a `*WithFullHistory` op's
  real `BRepTools_History` into the graph in one call (OCCTSwift#290): `HistoryRegistry` builds a
  RETAINED graph from a body's lineage and absorbs each mutation into it directly (#90/#91/#93;
  originally a disposable per-call graph rebuilt from scratch every time, and before that
  hand-correlating output sub-shapes to input sub-shapes by nearest centroid, which could
  misassign under symmetric/patterned geometry, the same failure family #72 guards against for
  signed distance). v1.10.1 rebuilds OCCT with the OCCTSwift#280 kernel fix (an XDE STEP read
  (`inspect_assembly`) used to silently corrupt every later STEP write (`export_scene`),
  dropping faces on indirect surfaces while still reporting valid); v1.9.0 makes the bulk
  `allEdgePolylines` O(edges) and v1.10.0 adds `allEdgePolylinesIndexed` (OCCTSwift#275: consumed
  by `render_preview`'s mesh-direct edge overlays and, via Tools 1.3.1, every
  `shapeToBodyAndMetadata` call); full per-input history coverage for booleans + every
  `FeatureSpec` kind in `BuildResult.histories[id]`, plus `BRepGraph.findDerivedOrSelf` /
  `hasHistoryRecord` for unambiguous untouched-vs-deleted resolution. v1.2.0 adds the `BRepGraph`
  per-node attribute store (`attributes` / `setAttribute` / `attribute`, closed `AttrValue` enum)
  and Codable `GraphSnapshot` round-trip (`snapshot()` / `init(snapshot:)`) backing the
  `reconstruct_*` tool group (#33). v1.8.0 adds `Exporter.writeBREP(allowInvalid:)` backing
  `read_brep` / `import_file`'s `allowInvalid` (#41)
- **OCCTSwiftMesh** ≥ 1.7.5: mesh-domain algorithms. v1.7.5 repins OCCTSwift to ≥3.0.0 (#175/#176); no source change, this package reads no bounding box off any OCCTSwift type at all (its own `MeshContour.bounds` is unrelated, a non-Optional 2D pair computed from the contour's own points). v1.7.4 fixes a Swift type-checker timeout in `PrimitiveFitter.fitCylinder`'s residuals expression on some CI toolchains, no behaviour change. v1.7.3 repins OCCTSwift to ≥2.0.0 (#171); audited against the full v2.0.0 break table (sub-shape-enumeration and AAG families included), zero hits, this package's own per-triangle/per-face indexing is independent of OCCTSwift's face-occurrence-indexed entry points. v1.7.0 also adds `Mesh.windingNumber(at:) -> Double` (OCCTSwiftMesh#30, van Oosterom-Strackee solid-angle sum, O(triangleCount) per call, no spatial acceleration): the generalized winding number, robust (a well-defined real number, not undefined) on open/self-intersecting meshes where a classical parity/ray-casting point-in-polyhedron test needs genuine closure to mean anything. Consumed by `symmetric_difference_volume` (OCCTMCP#122). v1.7.0 (OCCTSwiftMesh#27/#28/#32, Phase 3: creases, winding number, curvature seeding, RANSAC) adds `Mesh.segmentedRANSAC(_:)`/`segmentedAutoSelect` (Schnabel-style global-inlier primitive extraction, splitmix64-deterministic candidates, tangent-plane inlier gate robust to flipped scan winding, backing `fit_primitives`, OCCTMCP#107) and `Mesh.creaseEdges(minAngleDegrees:) -> CreaseDetectionResult` (dihedral-fold-edge detection: edges whose two triangles' normals differ by at least `minAngleDegrees` chained into closed `CreaseRing`s and open paths via junction-aware deterministic chaining, a Y/T crease intersection splits cleanly rather than being wandered through, with unchained leftovers reported in `unchainedCreaseEdgeCount`, never dropped; `CreaseRing.order` sorts largest-first). Requires a WELDED mesh (on unwelded input every edge is used by exactly one triangle, so the dihedral angle is undefined and everything reads "boundary"). Backs `detect_mesh_features` (#108). v1.6.0 (OCCTSwiftMesh#26/#31) adds `Mesh.slippage(forTriangles:maxSamples:) -> SlippageResult`: local slippage analysis (Gelfand & Guibas, SGP 2004) classifying a region's surface kind (plane/sphere/cylinder/extrusion/revolution/helix/freeform) and recovering its characteristic axis via a basis-invariant subspace classification (a 6x6 "slippage covariance" `Σ cᵢcᵢᵀ`, `cᵢ = [pᵢ×nᵢ, nᵢ]`; slippable-count `d` picked by spectral gap, not a fixed threshold; for `d>=2` a Gram-matrix rank over the slippable eigenvectors' rotational parts, invariant to which particular orthonormal basis Jacobi returned, the upstream PR's review round caught and fixed a real bug where naive per-eigenvector classification silently misread a rotated plane as a sphere and a rotated cylinder as freeform). Backs `segment_mesh_zones`'s per-zone `slippage` field and `zone_continuity_sweep`'s slippage-axis default (#109, Phase 3 of the mesh-analysis expansion), reusing the SAME welded-mesh + triangle-count guard `adjacentZones` established. v1.5.0 (OCCTSwiftMesh#22/#25) adds `Mesh.aligned(to:options:) -> AlignResult?`: point-to-plane ICP registration (Chen & Medioni's objective, Rusinkiewicz & Levoy's normal-space sampling, Low's linearized point-to-plane solve), with `Mesh.AlignOptions` (`maxIterations`, `correspondenceDistanceCap`, `trimFraction`, `preAlign`, `normalSpaceSampling`, `maxSamples`) and `AlignResult` (`transform: simd_double4x4` mapping the SOURCE mesh's original vertices into the reference's frame, `residualRMS`, `iterations`, `converged`); welds both meshes internally, so callers don't pre-weld. Backs `align_bodies` (#104), closing the Phase 2 mesh-analysis expansion's 4th tool. v1.4.0 (OCCTSwiftMesh#23/#24) adds `Mesh.vertexCurvatures` (Rusinkiewicz per-face tensor averaging), consumed by `mesh_curvature` (Phase 3); curvature-ordered segmentation seeding remains a filed follow-up (OCCTSwiftMesh#29). v1.3.0 (OCCTSwiftMesh#20/#21) adds `SegmentedMesh.fitMergeSkipped` (`true` when even the coplanar pre-merge couldn't get the raw region count under the internal fit-gated-merge cap, so `regions`/`fits` are the unmerged seed regions, `segment_mesh_zones` surfaces this as a warning) and a region-local fit-kind tie-break floor (shallow large-radius arcs stop misclassifying as plane in the zone table). v1.2.0 (OCCTSwiftMesh#16/#17) adds the mesh connectivity/quality toolkit (`welded`/`faceNormals`/`vertexNormals`/`triangleAdjacency`/`connectedComponents`/`subMesh`/`boundaryLoops`/`integrityReport`) and `Mesh.segmented(_:)` (dihedral region-growing + primitive-fit merge into plane/cylinder/sphere/cone regions), backing `segment_mesh_zones`/`zone_continuity_sweep` (#101/#102). `mesh_thickness`/`detect_symmetry`'s own primitives (`TriBVH`, `symmetricEigen3x3`) remain MCP-side composition, not upstream surface. QEM decimation (`simplified(_:)`) and `crossSection`/`crossSections` predate v1.2.0; smoothing / repair / remeshing remain roadmap
- **OCCTSwiftScripts** ≥ 1.7.0-rc1 (a prerelease, named exactly because SwiftPM does not float to one; moves to the final 1.7.0 with OCCTSwiftInteraction 2.0.0): allows OCCTSwiftInteraction 2.x, which this repo's old `from: "0.1.0"` made unsatisfiable for a consumer such as ACADStudio (SwiftPM reads `from:` as up to the next major, so that was `0.1.0..<1.0.0`, an implicit upper bound rather than only a floor) (SwiftPM then silently backtracked to OCCTMCP 1.35.0 and failed on colliding target names). ≥ 1.6.2: provides `occtkit` (only used by `execute_script` and `export_scene`); also ships `ScriptHarness` + `DrawingComposer` consumed in-process. `ExecuteScriptTool.scriptsPin` must track this pin (#42) and points at the SecondMouseAU URL. v1.6.2 repins OCCTSwift to ≥3.0.0 (#175/#176): unwraps the six now-Optional bounding-box accessors, throwing a named `ScriptError` on a nil box instead of the old fabricated zero-size one, in `QueryTopology`/`LoadBrep`/`MeasureDeviation`/`RenderPreview`/`Metrics`; none of this reaches OCCTMCP's own Swift implementation either way, since it only shells out to `occtkit run` for arbitrary LLM-authored scripts. v1.6.0 repins OCCTSwift to ≥2.0.0 (#171): fixes the confirmed `.selfIntersectionCount` break (OCCTSwift#763) in `Heal`/`GraphValidate`, both now use opt-in `isSelfIntersecting(timeout:)` via a new `--self-intersection-timeout` flag instead of the removed, always-fabricated-zero field, and a second real AAG occurrence-index bug (OCCTSwift#642) in `FeatureRecognize`/`GraphSelect`/`GraphML`, none of which this repo's own Swift implementation calls (it only shells out to `occtkit run` for arbitrary LLM-authored scripts via `execute_script`/`export_scene`; `recognize_features`/`graph_select`/`graph_ml` here are native Swift, not `occtkit` verbs). **v1.6.1 corrects v1.6.0's own release note**: the recipe 02 spring-volume drift flagged there was *not* an OCCTSwift kernel regression, [OCCTSwift#830](https://github.com/SecondMouseAU/OCCTSwift/issues/830) was reproduced by the maintainer and closed not-a-bug; the real bug was an analytic tangent-placement mistake in that recipe's own code (assumed `Wire.helix`'s `clockwise: true`, called it with the default `false`), exposed for the first time by an unrelated, intentional OCCTSwift fix (#598, landed just before 2.0.0) that made `mode: .correctedFrenet` finally run real corrected Frenet. Fixed upstream in OCCTSwiftScripts; not consumed by this repo either way. v1.5.0 capped its own OCCTSwiftIO dependency to `<1.1.0`, conflicting with OCCTSwiftTools ≥1.6.1's own OCCTSwiftIO `>=1.7.0` requirement (below) and making the two unresolvable together; fixed in v1.5.1 (raises the OCCTSwiftIO floor to 1.7.5), closing SecondMouseAU/OCCTSwiftScripts#80
- **OCCTSwiftInteraction** 2.0.0-rc2 (a prerelease, pinned exactly; ecosystem#42/#43/#52): the one package that vends `OCCTSwiftTools`, `OCCTSwiftAIS` and `OCCTSwiftCADKit` (the three standalone repos merged into it). Module names are unchanged, so no `import` moved; only the `package:` label on each product in `Package.swift` did. The resolved graph contains no `occtswifttools`, `occtswiftais` or `occtswiftcadkit` package at all. Also the wire-format home for the viewport selection bridge (`get_selection` / `highlight_selection`, #189/#190, `SelectionBridgeTools.swift`).
- **OCCTSwiftTools** (now a product of OCCTSwiftInteraction, see above; the figures in this bullet are the last standalone line, ≥ 1.6.4): Shape↔ViewportBody bridge; ships `PointConverter` and wires `pointRadius` / `vertexColors` through to `ViewportBody`. v1.6.4 repins OCCTSwift to ≥3.0.0 (#175/#176); no library source change (`Sources/` reads none of the six now-Optional accessors), requires OCCTSwiftIO ≥1.7.8. v1.6.3 repins OCCTSwift to ≥2.0.0 (#171): `Mesh.Triangle.faceIndex` (backing `FaceIdentityTable`) moved onto the same deduplicated enumeration `Shape.faces()` already uses (OCCTSwift#541/#613/#642), no production logic change, but fixed stale docs and a test's hardcoded pre-dedup face count. v1.6.1 renamed `TopologyGraph` to `BRepGraph` (OCCTSwift#333) and re-pins OCCTSwift to ≥1.15.0; v1.3.1 makes `extractEdgePolylines` (inside every `shapeToBodyAndMetadata`) a single O(edges) bulk pass via `allEdgePolylinesIndexed` (OCCTSwift#275 Tools half)
- **OCCTSwiftViewport** ≥ 1.2.0: Metal viewport + offscreen renderer; v1.2.0 fixes a Swift 6 concurrency crash where unannotated `MTLCommandBufferHandler` closures inherited `@MainActor` on Xcode 16.4 (a SIGTRAP after every test had reported green; masked on Xcode 26.x, so the floor is what carries the fix to an affected machine); v1.0.2 added the point-sprite pipeline that makes `pointCloud` overlays actually render; v1.1.23 adds the opt-in `ViewportBody.directMesh` path (de-interleaved position/normal GPU buffers, normals verbatim, no NormalSmoothing) used by `HeatmapTools`' band bodies (#76). `RenderPreviewTool.meshDirectBody` stays on the interleaved layout on purpose: facet-per-face STL imports need the smoothing pass
- **OCCTSwiftAIS** (now a product of OCCTSwiftInteraction, see above; the figures in this bullet are the last standalone line, ≥ 1.3.2): selection, manipulators, dimensions. **v1.3.2 absorbs OCCTSwift 3.0.0 (#175/#176), transitively via OCCTSwiftTools 1.6.4, this package declares no direct OCCTSwift pin of its own, only OCCTSwiftTools.** Real source breaks despite no version to bump: `AreaSelection`'s rubber-band bbox test now folds the (now-Optional) bounds read into the enclosing condition instead of matching any selection drawn over the origin the way the old fabricated `(0,0,0)-(0,0,0)` box did; `DimensionAnchor`'s four resolvers used to default to `.zero` on failure (the same defect one level up) and now propagate the Optional, so `resolve(_:)` and all four resolvers return `SIMD3<Float>?`, `anchorPoints` returns an empty array, and `add(_:)` registers a dimension without pushing a measurement instead of drawing it at the origin. All types involved are internal, so no public API signature changed. **OCCTMCP's own `Package.swift` floor had to move from `from: "1.3.1"` to `from: "1.3.2"`**: nothing in the version-range math forces this bump on its own (AIS's own Tools requirement is satisfied equally by 1.6.1 through 1.6.4), so `swift package resolve` silently keeps resolving 1.3.1, which still compiles fine against OLDER OCCTSwift but fails to compile the moment Tools resolves to 1.6.4 and pulls in OCCTSwift 3.0.0's Optional bounds, until the floor is bumped explicitly. Caught only by `OCCTMCP_FORCE_REMOTE_DEPS=1 swift build` against the real published graph, not by the local-sibling-checkout build PR #176 originally verified with, nor by grep. v1.3.1 renamed `TopologyGraph` to `BRepGraph` (OCCTSwift#333) and requires OCCTSwiftTools ≥1.6.1
- **OCCTSwiftIO** ≥ 1.8.0 (adds `DirectoryWatcher`, OCCTSwiftIO#43; not used here, the floor moves so the fleet states one baseline): transitive dependency of OCCTSwiftScripts / OCCTSwiftTools (BREP/STEP/mesh-format import/export core), now a direct root pin. v1.7.8 repins OCCTSwift to ≥3.0.0 (#175/#176); no library source change, three test call sites (`DXFLoaderTests`/`JWWLoaderTests`) unwrap through an existing `try #require`. v1.7.7 repins OCCTSwift to ≥2.0.0 (#171); audited against the full v2.0.0 break table, zero hits. Was capped to the 1.0.x line (`.upToNextMinor`) to dodge a heavy mesh-IO stack (SwiftPMX / SwiftGLTF / ThreeMF / SwiftJWW / SwiftX / Nodal / Zip) that OCCTSwiftIO ≥1.1.0 pulls in and OCCTMCP doesn't use. That cap stopped being optional once OCCTSwiftTools ≥1.6.1 started requiring OCCTSwiftIO ≥1.7.0 directly: keeping OCCTMCP's own cap just broke resolution instead of avoiding the heavier graph. Uncapped as of the #90/#91/#93/#97 repin; the heavy stack is now a real (if unused) part of the dependency graph, accepted in exchange for the whole cohort staying current
- **modelcontextprotocol/swift-sdk** ≥ 0.11.0: MCP transport + types

Verify what a fresh clone / CI actually resolves (not the local sibling-checkout shortcut below) with `OCCTMCP_FORCE_REMOTE_DEPS=1 swift build` / `swift test`.

## Node implementation

- **OCCTSwiftScripts** ≥ 1.4.0: provides `occtkit` on `$PATH` (`make install` from the OCCTSwiftScripts repo) or via sibling clone at `~/Projects/OCCTSwiftScripts` so `swift run -c release occtkit` works as the fallback. v1.3.0 adds the `measure-deviation` verb and the `metrics` `boundingBoxOptimal` field (Node `measure_deviation` / `compute_metrics`); v1.4.0 adds `load-brep` / `import` `--allow-invalid` (Node `read_brep` / `import_file` `allowInvalid`, #41)
- **OCCTSwift**: required at `~/Projects/OCCTSwift/` only when regenerating `src/api-reference.ts` via `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`)
- **OCCTSwiftViewport**: Metal viewport that watches the output directory via `ScriptWatcher` and auto-reloads. Optional but expected if you want the live preview
