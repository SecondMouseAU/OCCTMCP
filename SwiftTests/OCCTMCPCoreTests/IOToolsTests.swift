// Unit tests for the IO tools' allowInvalid path (#41 Gap 2).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("read_brep allowInvalid")
struct IOToolsTests {

    /// Fresh tempdir scene + the path to an on-disk BREP of a deterministically
    /// invalid shape (a bowtie self-intersecting face).
    func freshSceneWithInvalidBrep() throws -> (store: ManifestStore, brep: String, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-io-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "io", bodies: []))

        let bowtie = Wire.polygon([SIMD2(0, 0), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 1)], closed: true)!
        let invalid = Shape.face(from: bowtie)!
        #expect(!invalid.isValid)
        let brep = "\(dir)/invalid.brep"
        try Exporter.writeBREP(shape: invalid, to: URL(fileURLWithPath: brep), allowInvalid: true)
        return (store, brep, dir)
    }

    @Test("read_brep rejects an invalid shape by default")
    func rejectsInvalidByDefault() async throws {
        let (store, brep, dir) = try freshSceneWithInvalidBrep()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = await IOTools.readBrep(
            inputPath: brep, bodyId: "x", allowInvalid: false,
            store: store, history: SceneHistory())
        #expect(result.isError)
        #expect((try? store.read())?.bodies.isEmpty == true)
    }

    @Test("read_brep allowInvalid loads an invalid shape into the scene")
    func loadsInvalidWhenAllowed() async throws {
        let (store, brep, dir) = try freshSceneWithInvalidBrep()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = await IOTools.readBrep(
            inputPath: brep, bodyId: "x", allowInvalid: true,
            store: store, history: SceneHistory())
        #expect(!result.isError, "unexpected error: \(result.text)")
        let bodies = (try store.read())?.bodies ?? []
        #expect(bodies.contains { $0.id == "x" })
        #expect(FileManager.default.fileExists(atPath: "\(dir)/x.brep"))
    }

    // ── #69: mesh import regression (STL dropped from the enum) ──────────

    @Test("import_file imports STL (auto + explicit format) and OBJ")
    func importsMesh() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-mesh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "io", bodies: []))

        let sphere = Shape.sphere(radius: 5)!
        let stl = "\(dir)/ref.stl"
        try Exporter.writeSTL(shape: sphere, to: URL(fileURLWithPath: stl))

        // Auto-detect from the .stl extension (the regression: 'stl' was dropped).
        let auto = await IOTools.importFile(inputPath: stl, format: .auto,
                                            store: store, history: SceneHistory())
        #expect(!auto.isError, "STL auto import failed: \(auto.text)")
        var bodies = (try store.read())?.bodies ?? []
        #expect(bodies.count == 1)
        if let id = bodies.first?.id {
            let loaded = try IntrospectionTools.loadShape(bodyId: id, store: store).shape
            let b = loaded.bounds
            #expect(b.max.x - b.min.x > 8)   // ~diameter 10
        }

        // Explicit `format` must be authoritative over a non-matching extension.
        let noext = "\(dir)/ref.dat"
        try FileManager.default.copyItem(atPath: stl, toPath: noext)
        let explicit = await IOTools.importFile(inputPath: noext, format: .stl,
                                                store: store, history: SceneHistory())
        #expect(!explicit.isError, "explicit STL import failed: \(explicit.text)")
        #expect(((try store.read())?.bodies.count ?? 0) == 2)

        // OBJ (was enum-listed but unimplemented).
        let obj = "\(dir)/ref.obj"
        try Exporter.writeOBJ(shape: sphere, to: URL(fileURLWithPath: obj))
        let objRes = await IOTools.importFile(inputPath: obj, format: .obj,
                                              store: store, history: SceneHistory())
        #expect(!objRes.isError, "OBJ import failed: \(objRes.text)")
        #expect(((try store.read())?.bodies.count ?? 0) == 3)
    }
}
