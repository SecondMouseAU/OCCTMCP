// A failed heal_shape must come back as an error result (isError true), and a manifest write
// that fails after the geometry was produced must not be swallowed (#218).

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("heal_shape reports failures as errors", .serialized)
struct HealingToolsErrorPathTests {

    /// A scene holding real boxes "a" and "b", and "ghost", which has no BREP file.
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-heal-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/b.brep"))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "heal errors",
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

    @Test("heal_shape: no scene is an error")
    func noScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await HealingTools.healShape(
            bodyId: "a", store: store, history: SceneHistory())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("heal_shape: unknown body, missing BREP file and existing output id are errors")
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
            let result = await HealingTools.healShape(
                bodyId: c.body, outputBodyId: c.out, store: store, history: SceneHistory())
            #expect(result.text.contains(c.text), "\(c.body)")
            #expect(result.isError, "\(c.body)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("heal_shape: a failed manifest write is an error, in place and to a new body")
    func manifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)
        let outputs: [String?] = [nil, "healed"]
        #expect(outputs.count == 2)
        for out in outputs {
            let result = await HealingTools.healShape(
                bodyId: "a", outputBodyId: out, store: store, history: SceneHistory())
            #expect(result.text.contains("Failed to write manifest"), "\(String(describing: out))")
            #expect(result.isError, "\(String(describing: out))")
        }
        #expect(try bytes(store) == before)
    }
}
