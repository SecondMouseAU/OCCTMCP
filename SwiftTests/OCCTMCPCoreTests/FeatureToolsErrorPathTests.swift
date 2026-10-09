// A failed apply_feature must come back as an error result (isError true), and a manifest write
// that fails after the geometry was produced must not be swallowed (#218).

import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("apply_feature reports failures as errors", .serialized)
struct FeatureToolsErrorPathTests {

    /// A scene holding a real 40 mm box "a", a second body "b", and "ghost", which has no BREP.
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-feature-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 40, height: 40, depth: 40))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/b.brep"))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "feature errors",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "b", file: "b.brep", color: [0, 1, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 0, 1, 1]),
                ]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    /// Mark manifest.json immutable: it stays readable but the atomic replace in
    /// `ManifestStore.write` fails, which injects a failed manifest write.
    func lockManifest(_ store: ManifestStore) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.path)
    }

    func cleanup(_ store: ManifestStore) {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.path)
        try? FileManager.default.removeItem(atPath: dirOf(store))
    }

    func hole(at x: Double, _ y: Double) -> Value {
        .object([
            "id": .string("h1"),
            "kind": .string("hole"),
            "axis_point": .array([.double(x), .double(y), .double(0)]),
            "axis_direction": .array([.double(0), .double(0), .double(1)]),
            "diameter": .double(4),
        ])
    }

    @Test("apply_feature: no scene is an error")
    func noScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await FeatureTools.applyFeature(
            bodyId: "a", feature: hole(at: 5, 5), store: store, history: SceneHistory())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("apply_feature: unknown body, missing BREP file and existing output id are errors")
    func inputErrors() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let cases: [(body: String, out: String?, text: String)] = [
            ("nope", nil, "Body not found: nope"),
            ("ghost", nil, "BREP file missing"),
            ("a", "b", "already exists"),
        ]
        #expect(cases.count == 3)
        for c in cases {
            let result = await FeatureTools.applyFeature(
                bodyId: c.body, feature: hole(at: 5, 5), outputBodyId: c.out,
                store: store, history: SceneHistory())
            #expect(result.text.contains(c.text), "\(c.body)")
            #expect(result.isError, "\(c.body)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("apply_feature: a failed manifest write is an error, in place and to a new body")
    func manifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)
        let outputs: [String?] = [nil, "drilled"]
        #expect(outputs.count == 2)
        for out in outputs {
            let result = await FeatureTools.applyFeature(
                bodyId: "a", feature: hole(at: 5, 5), outputBodyId: out,
                store: store, history: SceneHistory())
            #expect(result.text.contains("Failed to write manifest"), "\(String(describing: out))")
            #expect(result.isError, "\(String(describing: out))")
        }
        #expect(try bytes(store) == before)
    }
}
