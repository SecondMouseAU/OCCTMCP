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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        // OCCT 8.0.0 GA shipped 2026-05-09. The whole OCCT-Swift
        // family tagged v1.0 alongside it; this cohort is what we pin
        // against now. OCCTSwift 1.0.3 closes gsdali/OCCTSwift#165:
        //   Tier 1 (v1.0.2): per-input boolean history → boolean_op
        //   Tier 2 (v1.0.3): fillet/chamfer/shell/defeature history
        //   Tier 3 (v1.0.3): FeatureReconstructor.BuildResult.histories
        // → drives apply_feature's history-based remap_selection in v1.1.
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "1.0.3"),
        .package(url: "https://github.com/gsdali/OCCTSwiftMesh.git", from: "1.0.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", from: "1.0.0"),
        // OCCTSwiftTools 1.0.1 ships PointConverter
        // (gsdali/OCCTSwiftTools#18) — drives the pointCloud uncap in
        // AnnotationsRenderer.
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "1.0.1"),
        // OCCTSwiftViewport v1.0.0 is independently tagged but the
        // rest of the v1.0 cohort (Tools / AIS / Scripts) still pins
        // Viewport `from: 0.55.0` (<1.0.0), so we hold here too. Bump
        // when those packages bump.
        .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "0.55.2"),
        .package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "1.0.0"),
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
