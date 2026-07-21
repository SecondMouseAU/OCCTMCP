// Unit tests for mesh_diagnose: a scripted closed box (every check should
// pass, Euler characteristic 2, genus 0) and a hand-written STL fixture with
// three triangles fanned around a shared edge (a classic non-manifold-edge
// case, also leaving the shell open — every boundary/manifold check should
// fire).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("mesh_diagnose: integrity check-list shaping")
struct MeshDiagnoseToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-diagnose-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "diagnose", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    struct DiagnoseReport: Decodable {
        struct Component: Decodable { let triangleCount: Int; let areaMm2: Double }
        struct MinAngle: Decodable { let min: Double; let p05: Double }
        struct Aspect: Decodable { let max: Double; let p95: Double }
        struct Check: Decodable { let check: String; let status: String; let detail: String }
        let bodyId: String
        let triangleCount: Int
        let isWatertight: Bool
        let isOrientable: Bool
        let nonManifoldEdgeCount: Int
        let nonManifoldVertexCount: Int
        let boundaryLoopCount: Int
        let duplicateTriangleCount: Int
        let degenerateTriangleCount: Int
        let eulerCharacteristic: Int
        let genus: Int?
        let componentCount: Int
        let components: [Component]
        let minAngleDegrees: MinAngle
        let aspectRatio: Aspect
        let checks: [Check]
        let warnings: [String]
    }

    @MainActor
    @Test("a closed box: every check passes, Euler characteristic 2, genus 0")
    func closedBoxAllPass() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        let result = await MeshDiagnoseTools.meshDiagnose(bodyId: "box", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DiagnoseReport.self, from: Data(result.text.utf8))

        #expect(r.bodyId == "box")
        #expect(r.triangleCount > 0)
        #expect(r.isWatertight)
        #expect(r.isOrientable)
        #expect(r.nonManifoldEdgeCount == 0)
        #expect(r.nonManifoldVertexCount == 0)
        #expect(r.boundaryLoopCount == 0)
        #expect(r.duplicateTriangleCount == 0)
        #expect(r.degenerateTriangleCount == 0)
        #expect(r.eulerCharacteristic == 2)
        #expect(r.genus == 0)
        #expect(r.componentCount == 1)
        #expect(r.components.count == 1)
        #expect(r.warnings.isEmpty)

        for check in r.checks {
            #expect(check.status == "pass", "expected pass for \(check.check), got \(check.status): \(check.detail)")
        }
        #expect(r.checks.map(\.check).contains("watertight"))
        #expect(r.checks.map(\.check).contains("slivers"))
    }

    /// Three triangles fanned around a shared spine edge — that edge has
    /// valence 3 (non-manifold), and every triangle's other two edges are
    /// free (the shell is open). Written as a raw ASCII STL (unshared
    /// vertices per facet), mirroring MeshZoneIntegrationTests' STL writer;
    /// the internal weld pass in integrityReport is what re-merges the
    /// spine's coincident vertices back into a single shared edge.
    static func writeFanSTL(to path: String) throws {
        let spineA = SIMD3<Double>(0, 0, 0)
        let spineB = SIMD3<Double>(0, 0, 1)
        let tips: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 1, 0)]
        var out = "solid fan\n"
        for tip in tips {
            let n = simd_normalize(simd_cross(spineB - spineA, tip - spineA))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(spineA.x) \(spineA.y) \(spineA.z)\n"
            out += "      vertex \(spineB.x) \(spineB.y) \(spineB.z)\n"
            out += "      vertex \(tip.x) \(tip.y) \(tip.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid fan\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @MainActor
    @Test("three triangles fanned around a shared edge: non-manifold edge + open boundary, checks fire")
    func fannedEdgeIsNonManifoldAndOpen() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-diagnose-fan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/fan.stl"
        try Self.writeFanSTL(to: stlPath)

        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "fan", bodies: []))

        struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }
        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "fan", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await MeshDiagnoseTools.meshDiagnose(bodyId: bodyId, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DiagnoseReport.self, from: Data(result.text.utf8))

        #expect(r.triangleCount >= 3, "OCCT's mesher may add internal subdivision vertices; at least the 3 input facets must survive")
        #expect(!r.isWatertight)
        #expect(r.nonManifoldEdgeCount >= 1, "the shared spine edge (valence 3) must be flagged non-manifold")
        #expect(r.boundaryLoopCount > 0, "every triangle's fan edges are free — the shell is open")
        #expect(r.componentCount == 1, "all three triangles are connected via the shared spine")

        let byName = Dictionary(uniqueKeysWithValues: r.checks.map { ($0.check, $0) })
        #expect(byName["watertight"]?.status == "fail")
        #expect(byName["non_manifold_edges"]?.status == "fail")
        #expect(byName["orientable"]?.status == "warn", "orientability isn't meaningful with a non-manifold edge present")
        #expect(byName["single_component"]?.status == "pass")
    }
}
