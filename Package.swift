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
        // OCCTSwift 0.170.1 — kernel ShapeMeasurements; bridge cleanups
        // (issue #99 redistributions). When OCCT 8.0.0 GA tags, bump
        // to 1.0.0 on GA day.
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "0.170.1"),
        .package(url: "https://github.com/gsdali/OCCTSwiftMesh.git", from: "0.1.0"),
        // ScriptHarness + DrawingComposer. v0.9.0 is the first
        // post-Tools-split tag — drops the v0.4–v0.8 branch("main")
        // workaround and is the first SPI-eligible state.
        .package(url: "https://github.com/gsdali/OCCTSwiftScripts.git", from: "0.9.0"),
        // Tools is the Shape ↔ ViewportBody bridge (split out of
        // OCCTSwiftViewport in v0.55.0). v0.6.0 split file I/O into
        // a sibling OCCTSwiftIO package; we still consume CADFileLoader
        // / BodyUtilities from Tools so consumers don't need to import
        // OCCTSwiftIO directly.
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "0.6.0"),
        // v0.55.2 ships the headless measurement overlay
        // (OCCTSwiftViewport#26) — closes the dimension-text-overlay
        // item we deferred from v0.5. The new surface is
        // OffscreenRenderOptions.measurements: [ViewportMeasurement],
        // mapping directly onto AnnotationsSidecar.dimensions.
        .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "0.55.2"),
        // OCCTSwiftAIS: high-level scene mgmt — selection-from-topology,
        // history-based selection remap, dimensions, standard scene
        // objects. Powers the v0.4 net-new tools.
        .package(url: "https://github.com/gsdali/OCCTSwiftAIS.git", from: "0.7.2"),
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
