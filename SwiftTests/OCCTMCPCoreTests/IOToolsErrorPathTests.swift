// A failed read_brep, import_file or export_scene must come back as an error result (isError
// true), and a manifest write that fails after the body file was written must not be swallowed
// (#218).

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("IO tools report failures as errors", .serialized)
struct IOToolsErrorPathTests {

    struct Fixture {
        let store: ManifestStore
        let boxPath: String
        var dir: String { (store.path as NSString).deletingLastPathComponent }
    }

    /// A scene holding a real box body "a", plus a loose box BREP and a loose STL-less path.
    func freshScene(bodies: Bool = true) throws -> Fixture {
        let dir = NSTemporaryDirectory() + "occtmcp-io-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        let loose = "\(dir)/loose.brep"
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: loose))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "io errors",
                bodies: bodies
                    ? [BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1])] : []
            ))
        return Fixture(store: store, boxPath: loose)
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    /// Mark manifest.json immutable: it stays readable but the atomic replace in
    /// `ManifestStore.write` fails, which injects a failed manifest write.
    func lockManifest(_ store: ManifestStore) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.path)
    }

    func cleanup(_ f: Fixture) {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.store.path)
        try? FileManager.default.removeItem(atPath: f.dir)
    }

    // ── read_brep ───────────────────────────────────────────────────────────

    @Test("read_brep: a missing file and an existing body id are errors")
    func readBrepErrors() async throws {
        let f = try freshScene()
        defer { cleanup(f) }
        let before = try bytes(f.store)

        let missing = await IOTools.readBrep(
            inputPath: "\(f.dir)/nope.brep", store: f.store, history: SceneHistory())
        #expect(missing.text.contains("BREP file not found"))
        #expect(missing.isError)

        let dup = await IOTools.readBrep(
            inputPath: f.boxPath, bodyId: "a", store: f.store, history: SceneHistory())
        #expect(dup.text.contains("already exists"))
        #expect(dup.isError)
        #expect(try bytes(f.store) == before)
    }

    @Test("read_brep: a failed manifest write is an error")
    func readBrepManifestWriteFails() async throws {
        let f = try freshScene()
        defer { cleanup(f) }
        try lockManifest(f.store)
        let before = try bytes(f.store)
        let result = await IOTools.readBrep(
            inputPath: f.boxPath, bodyId: "fresh", store: f.store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
        #expect(try bytes(f.store) == before)
    }

    // ── import_file ─────────────────────────────────────────────────────────

    @Test("import_file: a missing file and an undeterminable format are errors")
    func importFileErrors() async throws {
        let f = try freshScene()
        defer { cleanup(f) }
        let before = try bytes(f.store)

        let missing = await IOTools.importFile(
            inputPath: "\(f.dir)/nope.step", store: f.store, history: SceneHistory())
        #expect(missing.text.contains("File not found"))
        #expect(missing.isError)

        let noExt = "\(f.dir)/mystery"
        try "x".write(toFile: noExt, atomically: true, encoding: .utf8)
        let unknown = await IOTools.importFile(
            inputPath: noExt, store: f.store, history: SceneHistory())
        #expect(unknown.text.contains("Could not determine format"))
        #expect(unknown.isError)
        #expect(try bytes(f.store) == before)
    }

    @Test("import_file: a failed manifest write is an error")
    func importFileManifestWriteFails() async throws {
        let f = try freshScene()
        defer { cleanup(f) }
        try lockManifest(f.store)
        let before = try bytes(f.store)
        let result = await IOTools.importFile(
            inputPath: f.boxPath, format: .brep, store: f.store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
        #expect(try bytes(f.store) == before)
    }

    // ── export_scene ────────────────────────────────────────────────────────

    @Test("export_scene: no scene, unknown body ids and an empty scene are errors")
    func exportSceneErrors() async throws {
        let none = await IOTools.exportScene(
            format: .brep, outputPath: NSTemporaryDirectory() + "never-\(UUID()).brep",
            store: ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json"))
        #expect(none.text.contains("No scene loaded"))
        #expect(none.isError)

        let f = try freshScene()
        defer { cleanup(f) }
        let out = "\(f.dir)/out.brep"
        let unknown = await IOTools.exportScene(
            format: .brep, outputPath: out, bodyIds: ["a", "nope"], store: f.store)
        #expect(unknown.text.contains("Body ids not found: nope"))
        #expect(unknown.isError)

        let empty = try freshScene(bodies: false)
        defer { cleanup(empty) }
        let emptyResult = await IOTools.exportScene(
            format: .brep, outputPath: "\(empty.dir)/out.brep", store: empty.store)
        #expect(emptyResult.text.contains("No bodies to export"))
        #expect(emptyResult.isError)
        #expect(!FileManager.default.fileExists(atPath: out))
        #expect(!FileManager.default.fileExists(atPath: "\(empty.dir)/out.brep"))
    }
}
