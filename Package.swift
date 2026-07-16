// swift-tools-version: 6.1
//
// OCCTMCP — Swift port of the Node MCP server. Coexists with the original
// TypeScript implementation under src/ during the migration; once feature
// parity is reached the Node code can be removed.
//
// SwiftPM expects test sources under Tests/<TargetName>, but this repo's
// existing TypeScript test directory is `tests/` and the volume is
// case-insensitive (APFS default), so we point SPM at SwiftTests/ to avoid
// the clash.

import PackageDescription
import Foundation

// Prefer a local sibling checkout (../<name>) when present, else the published URL — so the whole
// OCCT ecosystem SHARES the single OCCTSwift/Libraries/OCCT.xcframework instead of each repo
// extracting its own 1.3 GB copy. CI / fresh clones (no sibling) use the URL pin. `#filePath`-relative
// so it's independent of build CWD. Guarded against SwiftPM's own checkout layout: a transitively-
// resolved checkout under a consumer's .build/ must never be treated as a local dev sibling
// (ecosystem issue OCCTSwiftScripts#69 / #70).
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    if !manifestDir.contains("/.build/"),
       FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift") {
        return .package(path: "../\(name)")
    }
    return .package(url: "https://github.com/SecondMouseAU/\(name).git", from: Version(version)!)
}

// As occtDep, but pins to the package's minor line (`.upToNextMinor`) instead of
// the major. Used to cap a transitive dependency whose newer minors pull deps we
// don't want in the graph — see the OCCTSwiftIO note in `dependencies` below.
// Same checkout-layout guard as occtDep (ecosystem issue OCCTSwiftScripts#69 / #70).
func occtDepUpToNextMinor(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    if !manifestDir.contains("/.build/"),
       FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift") {
        return .package(path: "../\(name)")
    }
    return .package(url: "https://github.com/SecondMouseAU/\(name).git", .upToNextMinor(from: Version(version)!))
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
        // gains `findDerivedOrSelf(of:)` and `hasHistoryRecord(for:)` —
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
        // (OCCTMCP #33) — LLM read/write over the attributed graph.
        //
        // OCCTSwiftViewport 1.0.2 closes #28: Metal point-sprite
        // pipeline. Combined with OCCTSwiftTools 1.1.0 wiring
        // pointRadius / vertexColors through to ViewportBody, the
        // pointCloud annotation now actually renders.
        //
        // Floored at 1.7.1 for OCCT 8.0.0p1 — the redesigned BRepGraph/
        // TopologyGraph model. All sibling deps below are re-pinned to the
        // matching p1 cohort. 1.8.0 adds Exporter.writeBREP(allowInvalid:) for
        // read_brep / import_file `allowInvalid` (#41).
        occtDep("OCCTSwift", from: "1.10.0"),  // ≥1.10.0: O(edges) bulk allEdgePolylines(Indexed) (OCCTSwift#275)
        occtDep("OCCTSwiftMesh", from: "1.1.1"),
        // 1.0.4 adds DrawingComposer GA / assembly drawings (OCCTSwiftScripts#50):
        // Composer.render(spec:components:) / render(spec:document:) — multi-body
        // drawings with a parts list + balloons. Surfaced via generate_drawing's
        // bodyIds.
        // v1.2.0 = OCCTSwift 1.7.1 floor (OCCT 8.0.0p1) + the graph-select verb /
        // convexity-attributed faceAdjacency (OCCTSwiftScripts #54/#55).
        // v1.4.0 = measure-deviation verb + metrics boundingBoxOptimal (#44) +
        // load-brep/import --allow-invalid (#41), used by the Node server.
        // v1.4.1 / Tools v1.2.1 = SecondMouseAU org migration: their manifests now
        // declare OCCTSwiftIO at SecondMouseAU, so the transitive pin re-homes
        // without a root-level OCCTSwiftIO override here (#53).
        occtDep("OCCTSwiftScripts", from: "1.4.1"),
        occtDep("OCCTSwiftTools", from: "1.3.1"),  // ≥1.3.1: linear extractEdgePolylines (OCCTSwift#275 Tools half)
        // Viewport floored at 1.1.20: 1.0.3 fixes an uncatchable quantize()
        // crash on body load (Viewport #30) that would trap the MCP server
        // during render-preview; 1.0.4 makes the package dependency-free;
        // 1.1.20 adds tap-to-measure (Viewport #68) and
        // ViewportBody.worldHitPoint(ray:triangleIndex:) — ray → world
        // surface-point reconstruction that respects the body transform.
        occtDep("OCCTSwiftViewport", from: "1.1.23"),   // ≥1.1.23: ViewportBody.directMesh (#76)
        occtDep("OCCTSwiftAIS", from: "1.0.3"),
        // OCCTSwiftIO is a transitive dependency of OCCTSwiftScripts / OCCTSwiftTools,
        // declared open-endedly (`from: 1.0.x`) in their manifests. After the
        // SecondMouseAU migration its 1.1.0+ releases became reachable, and those
        // pull a heavy mesh-IO stack (SwiftPMX / SwiftGLTF / ThreeMF / SwiftJWW /
        // SwiftX) that doesn't resolve in this graph — OCCTMCP only needs the
        // BREP/STEP core. Cap it to the compatible 1.0.x line, which is the version
        // OCCTMCP has always built against. Also re-homes the pin to SecondMouseAU
        // (root URL wins), so no gsdali/OCCTSwiftIO leaks into the lockfile (#53).
        occtDepUpToNextMinor("OCCTSwiftIO", from: "1.0.1"),
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
