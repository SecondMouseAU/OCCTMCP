// #235 round three, the deviation, heatmap, symmetry and thickness tools: a body that cannot be
// loaded made each tool return the thrown error as plain text with isError false. Each case
// asserts isError, the tool-name prefix, the underlying reason, and that manifest.json (and any
// output file) is untouched.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing
import simd

@testable import OCCTMCPCore

/// A scene with "good" (a real box), "ghost" (no BREP file) and "junk" (a file that is not a BREP).
struct ThrownErrorDeviationFixture {
    let dir: String
    let store: ManifestStore
    let noSceneStore: ManifestStore

    init() throws {
        dir = NSTemporaryDirectory() + "occtmcp-thrown-dev-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/good.brep"))
        try "not a brep".write(toFile: "\(dir)/junk.brep", atomically: true, encoding: .utf8)
        store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "thrown deviation errors",
                bodies: [
                    BodyDescriptor(id: "good", file: "good.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 1, 0, 1]),
                    BodyDescriptor(id: "junk", file: "junk.brep", color: [0, 0, 1, 1]),
                ]))
        noSceneStore = ManifestStore(path: "\(dir)/none/manifest.json")
    }

    func manifestBytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: dir) }

    /// The ways `loadShape` throws, with the reason text each must carry.
    var loadFailures: [(label: String, bodyId: String, noScene: Bool, reason: String)] {
        [
            ("no scene", "good", true, "No scene loaded"),
            ("unknown body", "nope", false, "Body not found: nope"),
            ("missing brep", "ghost", false, "BREP file missing"),
            ("unreadable brep", "junk", false, "Failed to import BREP file"),
        ]
    }

    func storeFor(noScene: Bool) -> ManifestStore { noScene ? noSceneStore : store }
}

@Suite("deviation / heatmap / symmetry / thickness tools return a load failure as an error")
struct ThrownErrorDeviationToolsTests {

    func check(_ result: ToolText, tool: String, reason: String, label: String) {
        #expect(result.isError, "\(tool) \(label): \(result.text)")
        #expect(result.text.hasPrefix("\(tool): "), "\(tool) \(label): \(result.text)")
        #expect(result.text.contains(reason), "\(tool) \(label): \(result.text)")
        // The prefix alone is not a reason: something must follow it.
        #expect(result.text.count > tool.count + 2, "\(tool) \(label): \(result.text)")
    }

    @Test("measure_deviation: either body failing to load is an error")
    func measureDeviation() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await DeviationTools.measureDeviation(
                fromBodyId: c.bodyId, toBodyId: "good", store: f.storeFor(noScene: c.noScene))
            check(first, tool: "measure_deviation", reason: c.reason, label: "\(c.label) first")
            let second = await DeviationTools.measureDeviation(
                fromBodyId: "good", toBodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(second, tool: "measure_deviation", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("deviation_histogram: either body failing to load is an error and writes no image")
    func deviationHistogram() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let out = "\(f.dir)/hist.png"
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await DeviationHistogramTool.deviationHistogram(
                fromBodyId: c.bodyId, referenceBodyId: "good", outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(first, tool: "deviation_histogram", reason: c.reason, label: "\(c.label) first")
            let second = await DeviationHistogramTool.deviationHistogram(
                fromBodyId: "good", referenceBodyId: c.bodyId, outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(
                second, tool: "deviation_histogram", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @Test("cross_section_compare: either body failing to load is an error")
    func crossSectionCompare() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await CrossSectionCompareTool.crossSectionCompare(
                fromBodyId: c.bodyId, referenceBodyId: "good", axis: SIMD3(0, 0, 1),
                outputDir: f.dir, store: f.storeFor(noScene: c.noScene))
            check(
                first, tool: "cross_section_compare", reason: c.reason, label: "\(c.label) first")
            let second = await CrossSectionCompareTool.crossSectionCompare(
                fromBodyId: "good", referenceBodyId: c.bodyId, axis: SIMD3(0, 0, 1),
                outputDir: f.dir, store: f.storeFor(noScene: c.noScene))
            check(
                second, tool: "cross_section_compare", reason: c.reason,
                label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("signed_deviation_heatmap: either body failing to load is an error and writes no image")
    func signedDeviationHeatmap() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let out = "\(f.dir)/heat.png"
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await HeatmapTools.signedDeviationHeatmap(
                fromBodyId: c.bodyId, referenceBodyId: "good", outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(
                first, tool: "signed_deviation_heatmap", reason: c.reason,
                label: "\(c.label) first")
            let second = await HeatmapTools.signedDeviationHeatmap(
                fromBodyId: "good", referenceBodyId: c.bodyId, outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(
                second, tool: "signed_deviation_heatmap", reason: c.reason,
                label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @MainActor
    @Test("overlay_render: either body failing to load is an error and writes no image")
    func overlayRender() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let out = "\(f.dir)/overlay.png"
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await HeatmapTools.overlayRender(
                solidBodyId: c.bodyId, meshBodyId: "good", outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(first, tool: "overlay_render", reason: c.reason, label: "\(c.label) first")
            let second = await HeatmapTools.overlayRender(
                solidBodyId: "good", meshBodyId: c.bodyId, outputPath: out,
                store: f.storeFor(noScene: c.noScene))
            check(second, tool: "overlay_render", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @MainActor
    @Test("detect_symmetry: a body that cannot load is an error")
    func detectSymmetry() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await SymmetryTools.detectSymmetry(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "detect_symmetry", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("check_thickness: a body that cannot load is an error")
    func checkThickness() async throws {
        let f = try ThrownErrorDeviationFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await EngineeringTools.checkThickness(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "check_thickness", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }
}
