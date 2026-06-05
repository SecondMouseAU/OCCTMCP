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
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "1.2.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftMesh.git", from: "1.0.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", from: "1.0.3"),
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "1.1.1"),
        // Viewport floored at 1.0.4: 1.0.3 fixes an uncatchable quantize()
        // crash on body load (Viewport #30) that would trap the MCP server
        // during render-preview; 1.0.4 makes the package dependency-free.
        .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "1.0.4"),
        .package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "1.0.2"),
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
