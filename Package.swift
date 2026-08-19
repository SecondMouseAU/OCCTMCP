// swift-tools-version: 6.1
//
// OCCTMCP: Swift port of the Node MCP server. Coexists with the original
// TypeScript implementation under src/ during the migration; once feature
// parity is reached the Node code can be removed.
//
// SwiftPM expects test sources under Tests/<TargetName>, but this repo's
// existing TypeScript test directory is `tests/` and the volume is
// case-insensitive (APFS default), so we point SPM at SwiftTests/ to avoid
// the clash.

import PackageDescription
import Foundation

// Prefer a local sibling checkout (../<name>) when present, else the published URL: so the whole
// OCCT ecosystem SHARES the single OCCTSwift/Libraries/OCCT.xcframework instead of each repo
// extracting its own 1.3 GB copy. CI / fresh clones (no sibling) use the URL pin. `#filePath`-relative
// so it's independent of build CWD. Guarded against SwiftPM's own checkout layout: a transitively-
// resolved checkout under a consumer's .build/ must never be treated as a local dev sibling
// (ecosystem issue OCCTSwiftScripts#69 / #70). Set OCCTMCP_FORCE_REMOTE_DEPS=1 to always use the
// URL pin even when a local sibling exists, for verifying what a fresh clone / CI actually
// resolves, without needing to touch or move anything under the sibling checkouts.
func useLocalSibling(_ name: String) -> Bool {
    guard ProcessInfo.processInfo.environment["OCCTMCP_FORCE_REMOTE_DEPS"] == nil else { return false }
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    return !manifestDir.contains("/.build/")
        && FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift")
}

func occtDep(_ name: String, from version: String) -> Package.Dependency {
    if useLocalSibling(name) {
        return .package(path: "../\(name)")
    }
    return .package(url: "https://github.com/SecondMouseAU/\(name).git", from: Version(version)!)
}

let package = Package(
    name: "OCCTMCP",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "OCCTMCPCore", targets: ["OCCTMCPCore"]),
        .executable(name: "occtmcp-server", targets: ["OCCTMCPServer"]),
    ],
    dependencies: [
        // Official MCP Swift SDK. `Value.numberValue` (proposed upstream
        // in modelcontextprotocol/swift-sdk#225, PR #226) is not yet in a
        // tagged release, so we back-port it locally in
        // Sources/OCCTMCPCore/Value+NumberValue.swift. Delete that file
        // and nothing else changes once the SDK ships the property.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // OCCT 8.0.0 GA cohort.
        //
        // OCCTSwift 1.1.0 closes gsdali/OCCTSwift#167: TopologyGraph
        // gains `findDerivedOrSelf(of:)` and `hasHistoryRecord(for:)`:
        // single-call disambiguation between untouched / modified /
        // deleted nodes. Lets RemapTools drop its v1.3
        // isIdentityPreserving flag workaround.
        //
        // OCCTSwift 1.0.4 closes gsdali/OCCTSwift#166: applyFillet /
        // applyChamfer go through *WithFullHistory and populate
        // BuildResult.histories[id] for every FeatureSpec kind.
        //
        // OCCTSwift 1.2.0 closes gsdali/OCCTSwift#168: TopologyGraph
        // gains a per-node attribute store (`attributes` /
        // `setAttribute` / `attribute`), a closed `AttrValue` enum, and
        // a Codable `GraphSnapshot` round-trip (`snapshot()` /
        // `init(snapshot:)`). Backs the `reconstruct_*` tool group
        // (OCCTMCP #33): LLM read/write over the attributed graph.
        //
        // OCCTSwiftViewport 1.0.2 closes #28: Metal point-sprite
        // pipeline. Combined with OCCTSwiftTools 1.1.0 wiring
        // pointRadius / vertexColors through to ViewportBody, the
        // pointCloud annotation now actually renders.
        //
        // Floored at 1.7.1 for OCCT 8.0.0p1: the redesigned BRepGraph/
        // TopologyGraph model. All sibling deps below are re-pinned to the
        // matching p1 cohort. 1.8.0 adds Exporter.writeBREP(allowInvalid:) for
        // read_brep / import_file `allowInvalid` (#41).
        occtDep("OCCTSwift", from: "3.0.0"),  // >=3.0.0 (#175): OCCT itself does not move; the kernel stays at 8.0.1, rebuilt as v3.0.0-kernel.1 to carry two patches the 2.0.0 asset was missing (OCCTSwift#905/#913). A Rule 2 major on a far smaller surface than 2.0.0: three breaks, full table in OCCTSwift docs/SEMVER.md#v300. Two are zero-hit here, audited at bump time: Selector.SubShapeType.compsolid renamed .compSolid, and Shape.ShapeFilterType.RawValue moving Int32 to Int as ShapeFilterType becomes a ShapeType typealias, which only breaks code that names or stores the raw type (both OCCTSwift#844). The third one bit hard: Shape.bounds/size/center, Wire.bounds, Edge.bounds and Face.bounds/exactBounds are now Optional (OCCTSwift#943), returning nil on OCCT's own Bnd_Box::IsVoid() instead of fabricating a (0,0,0)-(0,0,0) box that no caller could tell from a real zero-size shape at the world origin. 19 files under Sources/ and 5 under SwiftTests/ unwrap it, and NOT ONE defaults to zero: every answer this repo computes is handed to an LLM as a tool result, where a fabricated bounding box does not degrade gracefully, it reads as a measurement. Each unwrap goes into a failure path the code already had, in one of three shapes. (1) An explicit error to the caller, where the bbox IS the answer or sets the scale everything else is judged against: show_bounding_box, select_topology's body anchor (the anchor is the bbox centre), find_correspondences and remap_selection's tolerance, segment_mesh_zones, mesh_curvature's flatFraction threshold, symmetric_difference_volume's shared sampling box, cross_section_compare's default station point, and every deflection-defaulting tool via DeviationTools.defaultDeflection now returning Double? (12 call sites, each guarded ahead of its existing `defl > 0` check; ZoneSweepTool.resolveZoneMesh throws a new ZoneMeshResolutionError.noBoundingBox instead, matching its own error style). read_brep reads the extent BEFORE it writes the manifest, so an empty BREP is refused rather than registered as a body whose reported extent would have to be invented. (2) Omit the optional extra, where the bbox is context rather than the answer: compute_metrics leaves boundingBox absent exactly as its boundingBoxOptimal branch always has, detect_mesh_features drops containingZones with a warning (no MeshSignature means no staleness check), align_bodies reports that its large-residual check could not be scaled instead of dropping it silently. (3) The existing nil/lost path: remap_selection gives that body's selections the same "lost" fate an unloadable body already got, CorrespondenceTools.loadSourceCentroid and inferTranslation already returned Optional. Two things that look like breaks and are not: Shape.TopAbs_ShapeEnum survives as a deprecated typealias, and ThruSectionsBuilder.setCriteriumWeight returning Bool where it returned Void is @discardableResult. One new deprecation warning, not an error: Shape.transformed(matrix:) now prefers Matrix12Grouped over a raw [Double] (OCCTSwift#835), which is exactly the grouped-vs-interleaved footgun AlignTools documents at length; migrating it is a follow-up, not part of this repin. Verified by building against the real v3.0.0 sibling checkout, with tests, since grep is unreliable on .bounds/.size/.center (they collide with CoreGraphics, SwiftUI and this repo's own TriBVH and MeshSignature types). >=2.0.0 (#171): OCCT absorbed to 8.0.1; a correctness release (Pass 1a/1b duplication+bug-fix audit, OCCTSwift#377/#669), 17 breaking API changes (12 compile errors, 5 silent value changes), full table in OCCTSwift docs/SEMVER.md#v200. This repo's own audit found zero hits for 11 of the 12 compile-error symbols and the mass-property surface (#609); the two that DID need fixing: #605/#168 (Shape.centerOfMass returns nil instead of the bounding-box centre for anything with no enclosed volume: SelectionTools.vertexPoint(_:)/RemapTools/CorrespondenceTools now read Shape.vertices() for a vertex's real position instead) and #642/#699 (AAG.detectPockets()/detectHoles()'s floorFaceIndex/wallFaceIndices/faceIndex are now occurrence indices into orientedFaces(), not faces(): AnalysisTools.buildFeatureReport converts to the stable distinctFaceIndex before reporting to the LLM, GapFillerTools.mintFaceSelection now indexes orientedFaces() directly, AutoDimensionTool converts before calling edgesInFace(at:); all three only diverge on a body with a face shared between two solids, e.g. a boolean/pattern result, see AAGFaceIndexTests). Also, #541 changed Shape.faces() itself to the deduplicated convention BRepGraph already used, so TopologyIdentityTests' shared-face divergence fixture moved to the still-occurrence-based orientedFaces(). >=1.17.0: Pass 1a duplication/bug-fix audit (OCCTSwift#377/#380). TWO documented source breaks, neither reaching this repo (both audited at bump time, zero call sites): Surface.drawMesh/evaluateGrid now return a SurfaceGrid struct instead of [[SIMD3<Double>]] (#404, no shim possible since Swift can't overload on return type; note their old nestings were OPPOSITE, [u][v] vs [v][u]), and the no-tolerance Curve3D.interpolate(points:startTangent:endTangent:) overload is removed (#400, it shadowed its tolerance-aware sibling and pinned tolerance at 1e-6). Nine overlapping continuity enums consolidated into SurfaceContinuity + ParametricContinuity (#398), every retired name kept as a deprecated alias, so source-compatible. ELEVEN silent behaviour changes (no compiler diagnostic), the headline being Curve3D.length/arcLength* integrating per GeomAbs_CN span instead of one Gauss quadrature across the whole domain (#477: was up to 5% wrong on a multi-span BSpline, an accuracy fix on the ORDINARY path, not just a failure path); also Surface.approximated() no-arg defaults (tolerance 0.01 to 1e-3, maxDegree 10 to 8), Surface.curvatures(u:v:) solver resolution 1e-6 to 1e-7, Point2D.distance(to: Curve2D) with no projection -1 to .infinity (flips any `distance < tolerance` test), arcLength failure sentinels 0.0 to -1.0, Surface.normal(u:v:) at a near-degenerate point (now zero vector, matching normal(atU:v:), the spelling this repo actually calls), zero-radius circle/conic factories now nil, BRepGraph.sampleFaceUVGrid unpacking the written count. Audited: none reach this repo's own code (no arcLength on OCCT curves, ZoneSweepTool's arcLengthDeltaMm is polyline-based; no Curve2D/Point2D/approximated/curvatures/sampleFaceUVGrid/interpolate call sites), but every sibling now compiles against 1.17.0, so the test suite is the net for anything arriving transitively. Bridge C ABI changed: OCCTSWIFT_BRIDGE_PREBUILT consumers must take this release's OCCTBridge.xcframework; OCCT.xcframework is unchanged, still the v1.15.18 asset. >=1.15.2: docs+tests only, retracts #336 as not-a-bug (two-hop *WithFullHistory chaining always absorbed correctly; the reported "zero records" was a box-centering mistake in the repro's own geometry); >=1.15.0: TopologyGraph renamed to BRepGraph (OCCTSwift#333, TopologyGraph kept as a deprecated typealias); >=1.14.0: *WithFullHistory for translate/rotate/scale/mirror/patterns (OCCTSwift#331); >=1.13.0: *WithFullHistory for heal/sew/quilt/solid (OCCTSwift#327), heal_shape now records real history instead of the topology-count heuristic; >=1.12.9: OCCT kernel crash/hang fixes through #318 and #323 (patches 0003-0009); >=1.12.0: BRepGraph.add(_:absorbing:inputRoots:operationName:) absorbs a *WithFullHistory op's real BRepTools_History (OCCTSwift#290), replacing HistoryRegistry's hand-rolled centroid correlation (#90/#93); >=1.10.1: kernel fix for OCCTSwift#280 (XDE STEP read corrupting later STEP writes); 1.10.0 added O(edges) allEdgePolylines(Indexed) (#275)
        occtDep("OCCTSwiftMesh", from: "1.7.4"),  // >=1.7.4 (#171): fixes a Swift type-checker timeout in fitCylinder's residuals expression on some CI toolchains, no behaviour change. >=1.7.3: repin OCCTSwift floor to 2.0.0; audited against the full break table (including sub-shape-enumeration and AAG families), zero hits. >=1.7.0: segmentedRANSAC + segmentedAutoSelect Schnabel-style global-inlier extraction (OCCTSwiftMesh#27/#32) backing fit_primitives (#107), creaseEdges dihedral-fold rings (#28/#32) backing detect_mesh_features (#108); >=1.6.0: Mesh.slippage(forTriangles:maxSamples:) Gelfand-Guibas surface-kind classification with basis-invariant subspace analysis (OCCTSwiftMesh#26/#31) backing the #109 zone kind/axis integration; >=1.5.0: Mesh.aligned(to:options:) point-to-plane ICP with PCA pre-align + normal-space sampling (OCCTSwiftMesh#22/#25) backing align_bodies (#104); >=1.4.0: Mesh.vertexCurvatures Rusinkiewicz per-face tensor averaging (OCCTSwiftMesh#23/#24; curvature-seeded segmentation is a later follow-up, not consumed yet); >=1.3.0: SegmentedMesh.fitMergeSkipped (surfaced as a segment_mesh_zones warning) and the region-local fit-kind tie-break floor (shallow large-radius arcs stop misclassifying as plane in the zone table), OCCTSwiftMesh#20/#21; >=1.2.0: mesh foundations (welded/adjacency/components/subMesh/boundaryLoops/integrityReport) + Mesh.segmented(_:) dihedral region-growing with primitive-fit merge (OCCTSwiftMesh#16/#17), backing segment_mesh_zones / zone_continuity_sweep (#101/#102)
        // 1.0.4 adds DrawingComposer GA / assembly drawings (OCCTSwiftScripts#50):
        // Composer.render(spec:components:) / render(spec:document:): multi-body
        // drawings with a parts list + balloons. Surfaced via generate_drawing's
        // bodyIds.
        // v1.2.0 = OCCTSwift 1.7.1 floor (OCCT 8.0.0p1) + the graph-select verb /
        // convexity-attributed faceAdjacency (OCCTSwiftScripts #54/#55).
        // v1.4.0 = measure-deviation verb + metrics boundingBoxOptimal (#44) +
        // load-brep/import --allow-invalid (#41), used by the Node server.
        // v1.4.1 / Tools v1.2.1 = SecondMouseAU org migration: their manifests now
        // declare OCCTSwiftIO at SecondMouseAU, so the transitive pin re-homes
        // without a root-level OCCTSwiftIO override here (#53).
        //
        // v1.5.0 capped its own OCCTSwiftIO dependency to <1.1.0, which directly
        // conflicted with OCCTSwiftTools >=1.6.1's own OCCTSwiftIO >=1.7.0
        // requirement (below) and made the two unresolvable together. Fixed in
        // v1.5.1 (raises the OCCTSwiftIO floor to 1.7.5), closing
        // SecondMouseAU/OCCTSwiftScripts#80.
        occtDep("OCCTSwiftScripts", from: "1.6.0"),  // >=1.6.0 (#171): repin OCCTSwift floor to 2.0.0; fixes the confirmed selfIntersectionCount break (OCCTSwift#763, Heal/GraphValidate now use opt-in isSelfIntersecting(timeout:) via a new --self-intersection-timeout flag) and a second real AAG occurrence-index bug (OCCTSwift#642) in FeatureRecognize/GraphSelect/GraphML. v1.6.1 corrects v1.6.0's own release note: the recipe 02 spring-volume drift flagged there was NOT an OCCTSwift kernel regression (OCCTSwift#830 was reproduced and closed not-a-bug): the real bug was in that recipe's own analytic tangent placement, fixed upstream in OCCTSwiftScripts; unrelated to anything execute_script/export_scene calls here either way.
        occtDep("OCCTSwiftTools", from: "1.6.3"),  // >=1.6.3 (#171): repin OCCTSwift floor to 2.0.0. Mesh.Triangle.faceIndex (backing FaceIdentityTable) moved onto the same deduplicated enumeration Shape.faces() already uses (OCCTSwift#541/#613/#642), no production logic change (makeFaceIdentityTable() already computes dynamically), but fixed stale docs and a test's hardcoded pre-dedup face count. >=1.6.1: TopologyGraph renamed to BRepGraph (OCCTSwift#333), and re-pins OCCTSwift to >=1.15.0; >=1.3.1: linear extractEdgePolylines (OCCTSwift#275 Tools half)
        // Viewport floored at 1.1.20: 1.0.3 fixes an uncatchable quantize()
        // crash on body load (Viewport #30) that would trap the MCP server
        // during render-preview; 1.0.4 makes the package dependency-free;
        // 1.1.20 adds tap-to-measure (Viewport #68) and
        // ViewportBody.worldHitPoint(ray:triangleIndex:) ray to world
        // surface-point reconstruction that respects the body transform.
        occtDep("OCCTSwiftViewport", from: "1.1.23"),   // >=1.1.23: ViewportBody.directMesh (#76)
        occtDep("OCCTSwiftAIS", from: "1.3.1"),  // >=1.3.1: TopologyGraph renamed to BRepGraph (OCCTSwift#333), requires OCCTSwiftTools >=1.6.1
        // OCCTSwiftIO is a transitive dependency of OCCTSwiftScripts / OCCTSwiftTools,
        // declared open-endedly (`from: 1.0.x`-ish) in their manifests. Was capped to
        // the 1.0.x line here to dodge a heavy mesh-IO stack (SwiftPMX / SwiftGLTF /
        // ThreeMF / SwiftJWW / SwiftX / Nodal) that OCCTSwiftIO >=1.1.0 pulls in and
        // OCCTMCP doesn't need (BREP/STEP core only). That cap is no longer optional:
        // OCCTSwiftTools >=1.6.1 requires OCCTSwiftIO >=1.7.0 directly, so keeping
        // OCCTMCP's own cap just breaks resolution rather than avoiding the heavier
        // graph. Uncapped as of the #90/#91/#93/#97 repin; the heavy stack is now a
        // real (if unused) part of the dependency graph, accepted in exchange for the
        // whole OCCTSwift cohort staying current, including the BRepGraph rename.
        occtDep("OCCTSwiftIO", from: "1.7.7"),  // >=1.7.7 (#171): repin OCCTSwift floor to 2.0.0; audited against the full break table (including sub-shape-enumeration and AAG families), zero hits
    ],
    targets: [
        .target(
            name: "OCCTMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "OCCTSwift", package: "OCCTSwift"),
                .product(name: "OCCTSwiftMesh", package: "OCCTSwiftMesh"),
                .product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
                .product(name: "DrawingComposer", package: "OCCTSwiftScripts"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftAIS", package: "OCCTSwiftAIS"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OCCTMCPServer",
            dependencies: [
                "OCCTMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OCCTMCPCoreTests",
            dependencies: ["OCCTMCPCore"],
            path: "SwiftTests/OCCTMCPCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
