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
// so it's independent of build CWD.
func occtDep(_ name: String, from version: String) -> Package.Dependency {
    let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    if FileManager.default.fileExists(atPath: manifestDir + "/../\(name)/Package.swift") {
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
        occtDep("OCCTSwift", from: "1.8.0"),
        occtDep("OCCTSwiftMesh", from: "1.1.1"),
        // 1.0.4 adds DrawingComposer GA / assembly drawings (OCCTSwiftScripts#50):
        // Composer.render(spec:components:) / render(spec:document:) — multi-body
        // drawings with a parts list + balloons. Surfaced via generate_drawing's
        // bodyIds.
        // v1.2.0 = OCCTSwift 1.7.1 floor (OCCT 8.0.0p1) + the graph-select verb /
        // convexity-attributed faceAdjacency (OCCTSwiftScripts #54/#55).
        // v1.4.0 = measure-deviation verb + metrics boundingBoxOptimal (#44) +
        // load-brep/import --allow-invalid (#41), used by the Node server.
        occtDep("OCCTSwiftScripts", from: "1.4.0"),
        occtDep("OCCTSwiftTools", from: "1.1.2"),
        // Viewport floored at 1.1.20: 1.0.3 fixes an uncatchable quantize()
        // crash on body load (Viewport #30) that would trap the MCP server
        // during render-preview; 1.0.4 makes the package dependency-free;
        // 1.1.20 adds tap-to-measure (Viewport #68) and
        // ViewportBody.worldHitPoint(ray:triangleIndex:) — ray → world
        // surface-point reconstruction that respects the body transform.
        occtDep("OCCTSwiftViewport", from: "1.1.20"),
        occtDep("OCCTSwiftAIS", from: "1.0.3"),
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
