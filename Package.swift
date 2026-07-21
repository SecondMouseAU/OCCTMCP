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
        occtDep("OCCTSwift", from: "1.15.2"),  // >=1.15.2: docs+tests only, retracts #336 as not-a-bug (two-hop *WithFullHistory chaining always absorbed correctly; the reported "zero records" was a box-centering mistake in the repro's own geometry); >=1.15.0: TopologyGraph renamed to BRepGraph (OCCTSwift#333, TopologyGraph kept as a deprecated typealias); >=1.14.0: *WithFullHistory for translate/rotate/scale/mirror/patterns (OCCTSwift#331); >=1.13.0: *WithFullHistory for heal/sew/quilt/solid (OCCTSwift#327), heal_shape now records real history instead of the topology-count heuristic; >=1.12.9: OCCT kernel crash/hang fixes through #318 and #323 (patches 0003-0009); >=1.12.0: BRepGraph.add(_:absorbing:inputRoots:operationName:) absorbs a *WithFullHistory op's real BRepTools_History (OCCTSwift#290), replacing HistoryRegistry's hand-rolled centroid correlation (#90/#93); >=1.10.1: kernel fix for OCCTSwift#280 (XDE STEP read corrupting later STEP writes); 1.10.0 added O(edges) allEdgePolylines(Indexed) (#275)
        occtDep("OCCTSwiftMesh", from: "1.2.0"),  // >=1.2.0: mesh foundations (welded/adjacency/components/subMesh/boundaryLoops/integrityReport) + Mesh.segmented(_:) dihedral region-growing with primitive-fit merge (OCCTSwiftMesh#16/#17), backing segment_mesh_zones / zone_continuity_sweep (#101/#102)
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
        occtDep("OCCTSwiftScripts", from: "1.5.1"),
        occtDep("OCCTSwiftTools", from: "1.6.1"),  // >=1.6.1: TopologyGraph renamed to BRepGraph (OCCTSwift#333), and re-pins OCCTSwift to >=1.15.0; >=1.3.1: linear extractEdgePolylines (OCCTSwift#275 Tools half)
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
        occtDep("OCCTSwiftIO", from: "1.7.0"),
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
