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
        // Distinct extents (10/20/30) => distinct eigenvalues => the
        // degenerate-axes ambiguity warning must NOT fire here.
        #expect(!r.warnings.contains { $0.contains("ill-defined") })
    }

    @MainActor
    @Test("a square-section prism fires the degenerate-eigenvalue ambiguity warning")
    func squarePrismWarnsOnDegenerateAxes() async throws {
        // Two equal cross-section extents => the two matching eigenvalues
        // are equal, so the eigenvector pair in that subspace is arbitrary.
        // On this axis-aligned, symmetrically-tessellated fixture the
        // returned axes still happen to land on the true mirror planes (the
        // covariance is already near-diagonal), so candidates still verify —
        // the point of the warning is that this is LUCK, not a guarantee,
        // and the caller must be told the orientations were ill-defined.
        let prism = try #require(Shape.box(width: 10, height: 10, depth: 30))
        let store = try scene([(id: "prism", shape: prism)])

        let result = await SymmetryTools.detectSymmetry(bodyId: "prism", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(SymmetryReport.self, from: Data(result.text.utf8))

        #expect(r.candidates.count == 3)
        #expect(r.warnings.contains { $0.contains("ill-defined") },
                "equal cross-section eigenvalues must surface the ambiguity warning; warnings: \(r.warnings)")
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
        // Which plane is which: the fixture's recess is in the front wall (the Y axis), so the
        // plane whose normal is along Y must be the one that breaks, and the X and Z planes must
        // stay exactly symmetric.
        func axisIndex(_ c: SymmetryReport.Candidate) -> Int {
            let a = c.normal.map { abs($0) }
            return a.firstIndex(of: a.max() ?? 0) ?? -1
        }
        let byAxis = Dictionary(grouping: r.candidates, by: axisIndex)
        #expect(Set(byAxis.keys) == [0, 1, 2], "expected one candidate per principal axis, got \(byAxis.keys.sorted())")

        let front = try #require(byAxis[1]?.first, "no candidate with its normal along Y")
        #expect(!front.symmetric, "the front-wall recess must break the Y-normal plane")
        // The recess is 3 mm deep. Measured p95 is 2.08 mm and rms 0.88 mm.
        #expect(front.p95Mm > 1.5 && front.p95Mm < 3.0, "front-plane p95 \(front.p95Mm)")
        #expect(front.rmsMm > 0.5 && front.rmsMm < 1.5, "front-plane rms \(front.rmsMm)")

        for axis in [0, 2] {
            let c = try #require(byAxis[axis]?.first, "no candidate with its normal along axis \(axis)")
            #expect(c.symmetric, "the plane normal to axis \(axis) is intact and must stay symmetric")
            #expect(c.p95Mm < 1e-6, "axis \(axis) p95 should be numerical noise, got \(c.p95Mm)")
        }
        #expect(r.candidates.filter { !$0.symmetric }.count == 1, "exactly one plane is broken")
        let best = try #require(r.bestPlane, "two symmetric planes exist, so bestPlane must be set")
        #expect(best.symmetric)
        #expect(axisIndex(best) != 1, "bestPlane must not be the broken plane")
    }
}
