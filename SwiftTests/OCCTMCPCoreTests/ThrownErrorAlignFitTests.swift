// #235 round three, align / auto-dimension / fit / vertex-fit / zone-sweep tools: a body that
// cannot be loaded made each tool return the thrown error as plain text with isError false. Each
// case asserts isError, the tool-name prefix, the underlying reason, and that manifest.json is
// unchanged.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

/// A scene with "good" (a real box), "ghost" (no BREP file) and "junk" (a file that is not a BREP).
struct ThrownErrorAlignFixture {
    let dir: String
    let store: ManifestStore
    let noSceneStore: ManifestStore

    init() throws {
        dir = NSTemporaryDirectory() + "occtmcp-thrown-align-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/good.brep"))
        try "not a brep".write(toFile: "\(dir)/junk.brep", atomically: true, encoding: .utf8)
        store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "thrown align errors",
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

@Suite("align / dimension / fit / sweep tools return a load failure as an error")
struct ThrownErrorAlignFitTests {

    func check(_ result: ToolText, tool: String, reason: String, label: String) {
        #expect(result.isError, "\(tool) \(label): \(result.text)")
        #expect(result.text.hasPrefix("\(tool): "), "\(tool) \(label): \(result.text)")
        #expect(result.text.contains(reason), "\(tool) \(label): \(result.text)")
        // The prefix alone is not a reason: something must follow it.
        #expect(result.text.count > tool.count + 2, "\(tool) \(label): \(result.text)")
    }

    @Test("align_bodies: either body failing to load is an error and applies nothing")
    func alignBodies() async throws {
        let f = try ThrownErrorAlignFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            // Distinct from the failing body (the no-scene case fails on "good" itself).
            let partner = c.bodyId == "good" ? "ghost" : "good"
            let first = await AlignTools.alignBodies(
                bodyId: c.bodyId, referenceBodyId: partner, apply: true,
                store: f.storeFor(noScene: c.noScene), history: SceneHistory())
            check(first, tool: "align_bodies", reason: c.reason, label: "\(c.label) first")
            let second = await AlignTools.alignBodies(
                bodyId: partner, referenceBodyId: c.bodyId, apply: true,
                store: f.storeFor(noScene: c.noScene), history: SceneHistory())
            check(second, tool: "align_bodies", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("auto_dimension: a body that cannot load is an error")
    func autoDimension() async throws {
        let f = try ThrownErrorAlignFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await AutoDimensionTool.autoDimension(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene),
                registry: SelectionRegistry())
            check(result, tool: "auto_dimension", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("fit_primitives: a body that cannot load is an error")
    func fitPrimitives() async throws {
        let f = try ThrownErrorAlignFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await FitPrimitivesTools.fitPrimitives(
                bodyId: c.bodyId, render: false, registry: ZoneRegistry(),
                store: f.storeFor(noScene: c.noScene))
            check(result, tool: "fit_primitives", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("measure_vertex_fit: either body failing to load is an error")
    func measureVertexFit() async throws {
        let f = try ThrownErrorAlignFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            // Distinct from the failing body (the no-scene case fails on "good" itself).
            let partner = c.bodyId == "good" ? "ghost" : "good"
            let first = await VertexFitTools.measureVertexFit(
                fromBodyId: c.bodyId, toBodyId: partner, store: f.storeFor(noScene: c.noScene))
            check(first, tool: "measure_vertex_fit", reason: c.reason, label: "\(c.label) first")
            let second = await VertexFitTools.measureVertexFit(
                fromBodyId: partner, toBodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(second, tool: "measure_vertex_fit", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("zone_continuity_sweep: a body that cannot load is an error")
    func zoneContinuitySweep() async throws {
        let f = try ThrownErrorAlignFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await ZoneSweepTool.zoneContinuitySweep(
                bodyId: c.bodyId, render: false, registry: ZoneRegistry(),
                store: f.storeFor(noScene: c.noScene))
            check(result, tool: "zone_continuity_sweep", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }
}
