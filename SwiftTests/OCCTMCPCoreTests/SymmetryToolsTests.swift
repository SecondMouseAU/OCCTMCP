// Unit tests for detect_symmetry: a box (symmetric about all 3 principal
// planes) and the Phase 1 mini-carbody fixture (MeshZoneIntegrationTests'
// writeMiniCarbodySTL — its front wall has a recess the back wall doesn't,
// which breaks the front/back mirror plane while leaving the other two
// principal planes intact).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("detect_symmetry: PCA candidate mirror planes")
struct SymmetryToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-symmetry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "symmetry", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    struct SymmetryReport: Decodable {
        struct Candidate: Decodable {
            let point: [Double]; let normal: [Double]
            let rmsMm: Double; let p95Mm: Double; let maxMm: Double; let symmetric: Bool
        }
        let bodyId: String
        let toleranceMm: Double
        let samples: Int
        let candidates: [Candidate]
        let bestPlane: Candidate?
        let warnings: [String]
    }
    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    @MainActor
    @Test("a box is symmetric about all 3 principal planes")
    func boxIsFullySymmetric() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        let result = await SymmetryTools.detectSymmetry(bodyId: "box", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(SymmetryReport.self, from: Data(result.text.utf8))

        #expect(r.bodyId == "box")
        #expect(r.candidates.count == 3)
        for c in r.candidates {
            #expect(c.symmetric, "expected every principal plane of a box to be symmetric: p95=\(c.p95Mm)")
            #expect(c.p95Mm < 0.1, "a box's mirror residual should be near-zero meshing noise")
        }
        #expect(r.bestPlane != nil)
        // candidates sorted best-first (ascending p95).
        let p95s = r.candidates.map(\.p95Mm)
        #expect(p95s == p95s.sorted())
    }

    @MainActor
    @Test("the mini-carbody fixture's recessed front wall breaks the front/back mirror plane")
    func miniCarbodyBreaksOnePlane() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-symmetry-carbody-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/minicarbody.stl"
        try MeshZoneIntegrationTests.writeMiniCarbodySTL(to: stlPath)

        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "mini carbody symmetry", bodies: []))

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "carbody", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await SymmetryTools.detectSymmetry(bodyId: bodyId, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(SymmetryReport.self, from: Data(result.text.utf8))

        #expect(r.candidates.count == 3)
        let broken = r.candidates.filter { !$0.symmetric }
        #expect(!broken.isEmpty, "the front-wall recess should break at least one principal mirror plane")
        for c in broken {
            // The recess is 3mm deep; a broken plane's residual should be a
            // sensible fraction of that, not a wild outlier from a
            // meshing artifact.
            #expect(c.p95Mm > 0.5 && c.p95Mm < 10, "broken-plane p95 should be in a sensible range for a 3mm recess, got \(c.p95Mm)")
        }
    }
}
