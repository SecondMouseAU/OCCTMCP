// #235 round three, introspection / selection / gap-filler tools: a body that cannot be loaded
// made the tool return the thrown error as plain text with isError false. Each case asserts
// isError, the tool-name prefix, the underlying reason, and that manifest.json is unchanged.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

/// A scene with "good" (a real box), "ghost" (no BREP file) and "junk" (a file that is not a BREP).
struct ThrownErrorSceneFixture {
    let dir: String
    let store: ManifestStore
    let noSceneStore: ManifestStore

    init() throws {
        dir = NSTemporaryDirectory() + "occtmcp-thrown-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/good.brep"))
        try "not a brep".write(toFile: "\(dir)/junk.brep", atomically: true, encoding: .utf8)
        store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "thrown errors",
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

@Suite("introspection / selection / gap-filler tools return a load failure as an error")
struct ThrownErrorIntrospectionSelectionTests {

    func check(_ result: ToolText, tool: String, reason: String, label: String) {
        #expect(result.isError, "\(tool) \(label): \(result.text)")
        #expect(result.text.hasPrefix("\(tool): "), "\(tool) \(label): \(result.text)")
        #expect(result.text.contains(reason), "\(tool) \(label): \(result.text)")
        // The prefix alone is not a reason: something must follow it.
        #expect(result.text.count > tool.count + 2, "\(tool) \(label): \(result.text)")
    }

    @Test("compute_metrics: a body that cannot load is an error")
    func computeMetrics() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await IntrospectionTools.computeMetrics(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "compute_metrics", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("query_topology: a body that cannot load is an error")
    func queryTopology() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await IntrospectionTools.queryTopology(
                bodyId: c.bodyId, entity: "face", store: f.storeFor(noScene: c.noScene))
            check(result, tool: "query_topology", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("measure_distance: either body failing to load is an error")
    func measureDistance() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let first = await IntrospectionTools.measureDistance(
                fromBodyId: c.bodyId, toBodyId: "good", store: f.storeFor(noScene: c.noScene))
            check(first, tool: "measure_distance", reason: c.reason, label: "\(c.label) first")
            let second = await IntrospectionTools.measureDistance(
                fromBodyId: "good", toBodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(second, tool: "measure_distance", reason: c.reason, label: "\(c.label) second")
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("select_topology: a body that cannot load is an error")
    func selectTopology() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await SelectionTools.selectTopology(
                bodyId: c.bodyId, kind: "face", store: f.storeFor(noScene: c.noScene),
                registry: SelectionRegistry())
            check(result, tool: "select_topology", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("show_bounding_box: a body that cannot load is an error and writes nothing")
    func showBoundingBox() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await GapFillerTools.showBoundingBox(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "show_bounding_box", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("select_by_feature: a body that cannot load is an error")
    func selectByFeature() async throws {
        let f = try ThrownErrorSceneFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await GapFillerTools.selectByFeature(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene),
                registry: SelectionRegistry())
            check(result, tool: "select_by_feature", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }
}
