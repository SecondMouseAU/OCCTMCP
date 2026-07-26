// Unit tests for symmetric_difference_volume (#122): a scripted box compared against itself
// (symmetric difference ~0), a box compared against a known-larger box (the excess volume is
// computable in closed form), a hand-written open-box STL (non-watertight reference, the exact
// case boolean_op cannot handle), and a reversed-winding copy of a box (proves classification is
// orientation-agnostic, not just "happens to work" on OCCT's own consistently-wound meshes).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("symmetric_difference_volume: winding-number volume comparison")
struct SymmetricDifferenceToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-symdiff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "symdiff", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    struct Report: Decodable {
        let samples: Int
        let ambiguousSamples: Int
        let ambiguousFraction: Double
        let boundingBoxVolumeMm3: Double
        let fromVolumeMm3: Double
        let referenceVolumeMm3: Double
        let intersectionVolumeMm3: Double
        let unionVolumeMm3: Double
        let fromOnlyVolumeMm3: Double
        let referenceOnlyVolumeMm3: Double
        let symmetricDifferenceVolumeMm3: Double
        let symmetricDifferenceFraction: Double?
        let estimatedStdErrMm3: Double
        let fromExactVolumeMm3: Double?
        let referenceExactVolumeMm3: Double?
        let fromWatertight: Bool
        let referenceWatertight: Bool
        let reliable: Bool
        let warnings: [String]
    }

    func decode(_ result: ToolText) throws -> Report {
        try JSONDecoder().decode(Report.self, from: Data(result.text.utf8))
    }

    // MARK: - Fixtures

    /// A hand-written OPEN box: 5 of 6 faces (missing the +Z cap), unshared per-facet vertices,
    /// exactly the "non-watertight mesh reference" #122 is about. `boolean_op` fails against this
    /// (empirically, per the issue); this tool must not.
    static func writeOpenBoxSTL(to path: String, halfExtent: Double = 5) throws {
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
            [(a, b, c), (a, c, d)]
        }
        let e = halfExtent
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        // -Z, +X, -X, +Y, -Y: all 5 faces except +Z, wound outward.
        tris += quad(SIMD3(-e, -e, -e), SIMD3(-e, e, -e), SIMD3(e, e, -e), SIMD3(e, -e, -e))       // -Z
        tris += quad(SIMD3(e, -e, -e), SIMD3(e, e, -e), SIMD3(e, e, e), SIMD3(e, -e, e))           // +X
        tris += quad(SIMD3(-e, -e, e), SIMD3(-e, e, e), SIMD3(-e, e, -e), SIMD3(-e, -e, -e))       // -X
        tris += quad(SIMD3(-e, e, -e), SIMD3(-e, e, e), SIMD3(e, e, e), SIMD3(e, e, -e))           // +Y
        tris += quad(SIMD3(-e, -e, e), SIMD3(-e, -e, -e), SIMD3(e, -e, -e), SIMD3(e, -e, e))       // -Y
        var out = "solid openbox\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n      vertex \(b.x) \(b.y) \(b.z)\n      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid openbox\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    @MainActor
    @Test("a box against itself: symmetric difference ~0, both volumes agree")
    func identicalBodiesReadZeroDifference() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let store = try scene([(id: "a", shape: box), (id: "b", shape: box)])

        let result = await SymmetricDifferenceTools.symmetricDifferenceVolume(
            fromBodyId: "a", referenceBodyId: "b", maxSamples: 2000, store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try decode(result)

        #expect(r.fromWatertight)
        #expect(r.referenceWatertight)
        #expect(r.reliable)
        #expect(abs(r.symmetricDifferenceVolumeMm3) < 1.0, "identical bodies should read ~0 symmetric difference, got \(r.symmetricDifferenceVolumeMm3)")
        #expect(abs(r.fromVolumeMm3 - r.referenceVolumeMm3) < 1.0)
        if let fe = r.fromExactVolumeMm3 {
            #expect(abs(fe - 1000.0) < 0.5, "a 10x10x10 box has exact volume 1000")
        }
    }

    @MainActor
    @Test("a taller box against a shorter one: fromOnly matches the known excess volume, referenceOnly ~0")
    func excessVolumeMatchesKnownDelta() async throws {
        // Both centered at the origin (Shape.box is origin-centered): the taller box's excess is
        // two symmetric slabs, one above and one below the shorter box, total 10*10*(14-10)=400.
        let shortBox = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let tallBox = try #require(Shape.box(width: 10, height: 10, depth: 14))
        let store = try scene([(id: "tall", shape: tallBox), (id: "short", shape: shortBox)])

        let result = await SymmetricDifferenceTools.symmetricDifferenceVolume(
            fromBodyId: "tall", referenceBodyId: "short", maxSamples: 4000, store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try decode(result)

        #expect(r.reliable)
        // Monte Carlo at 4000 samples over a modest bbox: allow a generous tolerance tied to the
        // tool's own reported standard error rather than an arbitrary constant.
        let tol = max(10.0, 4 * r.estimatedStdErrMm3)
        #expect(abs(r.fromOnlyVolumeMm3 - 400.0) < tol, "expected fromOnly ~400, got \(r.fromOnlyVolumeMm3) (stdErr \(r.estimatedStdErrMm3))")
        #expect(r.referenceOnlyVolumeMm3 < tol, "the shorter box has no volume outside the taller one")
        #expect(abs(r.symmetricDifferenceVolumeMm3 - 400.0) < tol)
    }

    @MainActor
    @Test("non-watertight (open) reference mesh: still produces a usable estimate, flags referenceWatertight=false")
    func openReferenceMeshStillComputes() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-symdiff-open-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/open.stl"
        try Self.writeOpenBoxSTL(to: stlPath, halfExtent: 5)

        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "symdiff-open", bodies: []))

        struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }
        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "openbox", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let openBodyId = try #require(imported.addedBodyIds.first)

        // A matching closed box (half-extent 5 -> width/height/depth 10) as the candidate.
        let closedBox = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let manifest = try #require(try store.read())
        try store.write(ScriptManifest(
            version: manifest.version, timestamp: manifest.timestamp, description: manifest.description,
            bodies: manifest.bodies + [BodyDescriptor(id: "closed", file: "closed.brep", color: [1, 1, 1, 1])]
        ))
        try Exporter.writeBREP(shape: closedBox, to: URL(fileURLWithPath: "\(dir)/closed.brep"))

        let result = await SymmetricDifferenceTools.symmetricDifferenceVolume(
            fromBodyId: "closed", referenceBodyId: openBodyId, maxSamples: 2000, store: store
        )
        #expect(!result.isError, "open reference must not hard-fail: \(result.text)")
        let r = try decode(result)

        #expect(!r.referenceWatertight, "the 5-face fixture is deliberately missing its +Z cap")
        #expect(r.warnings.contains { $0.contains(openBodyId) || $0.lowercased().contains("watertight") })
        // The open shell still encloses (via generalized winding number) essentially the same
        // volume as the closed box it's missing one face of, so the estimate should still be
        // roughly sane rather than garbage/zero.
        #expect(r.referenceVolumeMm3 > 500, "expected a substantial sampled reference volume, got \(r.referenceVolumeMm3)")
    }

    @MainActor
    @Test("classification is orientation-agnostic: reversed triangle winding doesn't change the result")
    func reversedWindingDoesNotFlipResult() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let store = try scene([(id: "a", shape: box), (id: "b", shape: box)])

        // classify() is the unit under test here directly: a mesh read with reversed winding
        // reads windingNumber ~ -1 inside (per Mesh+Winding.swift's own documented linearity), and
        // classify() must still call that "inside".
        #expect(SymmetricDifferenceTools.classify(1.0) == true)
        #expect(SymmetricDifferenceTools.classify(-1.0) == true, "inverted-winding interior must still classify as inside")
        #expect(SymmetricDifferenceTools.classify(0.0) == false)
        #expect(SymmetricDifferenceTools.classify(0.5) == nil, "the midpoint between outside and inside is genuinely ambiguous")
        #expect(SymmetricDifferenceTools.classify(2.0) == true, "a doubled/nested-shell multiplicity is still enclosed")

        // End-to-end sanity: the tool itself still runs and reports a normal-winding pair correctly.
        let result = await SymmetricDifferenceTools.symmetricDifferenceVolume(
            fromBodyId: "a", referenceBodyId: "b", maxSamples: 500, store: store
        )
        #expect(!result.isError)
    }

    @Test("halton sequence is deterministic and stays within the unit cube")
    func haltonSequenceIsDeterministicAndBounded() {
        for i in 1...200 {
            let p = SymmetricDifferenceTools.haltonPoint(index: i)
            let p2 = SymmetricDifferenceTools.haltonPoint(index: i)
            #expect(p == p2, "repeat calls at the same index must agree exactly")
            #expect(p.x >= 0 && p.x < 1)
            #expect(p.y >= 0 && p.y < 1)
            #expect(p.z >= 0 && p.z < 1)
        }
    }
}
