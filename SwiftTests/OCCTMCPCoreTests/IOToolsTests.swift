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
}
