// Unit tests for symmetric_difference_volume (#122): a scripted box compared against itself
// (symmetric difference ~0), a box compared against a known-larger box (the excess volume is
// computable in closed form), a hand-written open-box STL (non-watertight reference, the exact
// case boolean_op cannot handle), a genuinely reversed-winding raw mesh built directly via
// `OCCTSwiftMesh.Mesh`'s own vertex/index initializer (proves classification is orientation-
// agnostic on the REAL `windingNumber(at:)` output), and a hand-written STL whose per-facet
// winding is locally inconsistent (graceful degradation: high ambiguity, not a silent wrong
// answer).
//
// NOTE on why the reversed-winding mesh is built directly rather than via a `Shape`: OCCT's own
// `Shape.mesh()` re-tessellates a valid solid to consistently outward-facing triangles regardless
// of the shape's own topological orientation (empirically confirmed: a `.mirrored()` box's mesh
// still reads `windingNumber ~= +1`, not `~= -1`), and a raw STL with every facet's vertex order
// reversed does not reliably come back as a clean GLOBAL inversion after round-tripping through
// `Shape.loadSTL` either (it can come back locally INCONSISTENT instead, i.e. `isOrientable ==
// false`; see `inconsistentWindingStillFlagsAmbiguous` below, which exercises exactly that case).
// `OCCTSwiftMesh.Mesh(vertices:indices:)` sidesteps both of those and is the only reliable way,
// within the APIs available here, to construct a genuinely globally-inverted mesh for a test.

import Foundation
import Testing
import OCCTSwift
import OCCTSwiftMesh
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("symmetric_difference_volume: winding-number volume comparison")
struct SymmetricDifferenceToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-symdiff-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "symdiff", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return (store, dir)
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

    /// A fully CLOSED box (all 6 faces), every OTHER face's triangle vertex order reversed
    /// relative to `writeOpenBoxSTL`'s `quad()` (alternating outward/inward per face rather than
    /// uniformly, deliberately): after round-tripping through `Shape.loadSTL` -> `Shape.mesh()`,
    /// this comes back with `isOrientable == false` (a locally-inconsistent mesh), not a cleanly
    /// globally-inverted one. Used to prove graceful degradation (high `ambiguousFraction`,
    /// `reliable: false`), not orientation-agnosticism itself; see `boxMesh(reversed:)` below for
    /// the fixture that tests that.
    static func writeInconsistentWindingBoxSTL(to path: String, halfExtent: Double = 5) throws {
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, reversed: Bool) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
            reversed ? [(a, c, b), (a, d, c)] : [(a, b, c), (a, c, d)]
        }
        let e = halfExtent
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        tris += quad(SIMD3(-e, -e, -e), SIMD3(-e, e, -e), SIMD3(e, e, -e), SIMD3(e, -e, -e), reversed: false)  // -Z
        tris += quad(SIMD3(-e, -e, e), SIMD3(-e, e, e), SIMD3(e, e, e), SIMD3(e, -e, e), reversed: true)       // +Z (flipped)
        tris += quad(SIMD3(e, -e, -e), SIMD3(e, e, -e), SIMD3(e, e, e), SIMD3(e, -e, e), reversed: false)      // +X
        tris += quad(SIMD3(-e, -e, e), SIMD3(-e, e, e), SIMD3(-e, e, -e), SIMD3(-e, -e, -e), reversed: true)   // -X (flipped)
        tris += quad(SIMD3(-e, e, -e), SIMD3(-e, e, e), SIMD3(e, e, e), SIMD3(e, e, -e), reversed: false)      // +Y
        tris += quad(SIMD3(-e, -e, e), SIMD3(-e, -e, -e), SIMD3(e, -e, -e), SIMD3(e, -e, e), reversed: true)   // -Y (flipped)
        var out = "solid inconsistentbox\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n      vertex \(b.x) \(b.y) \(b.z)\n      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid inconsistentbox\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A genuine closed-box `OCCTSwiftMesh.Mesh`, built directly from vertex/index arrays (see
    /// the file header for why this, rather than a `Shape`, is what actually exercises a globally
    /// reversed winding). `reversed` swaps each triangle's last two indices, negating every
    /// triangle's contribution to `windingNumber` (Mesh+Winding.swift's documented linearity).
    /// Every face's standard (non-reversed) split was hand-verified outward via the right-hand
    /// rule (`cross(v1-v0, v2-v0)` points away from the origin for each of the 6 faces).
    static func boxMesh(halfExtent e: Double = 5, reversed: Bool) -> Mesh {
        let ef = Float(e)
        let v: [SIMD3<Float>] = [
            SIMD3(-ef, -ef, -ef), SIMD3(-ef, ef, -ef), SIMD3(ef, ef, -ef), SIMD3(ef, -ef, -ef),
            SIMD3(-ef, -ef, ef), SIMD3(-ef, ef, ef), SIMD3(ef, ef, ef), SIMD3(ef, -ef, ef),
        ]
        let quads: [[UInt32]] = [
            [0, 1, 2, 3],  // -Z
            [4, 7, 6, 5],  // +Z
            [3, 2, 6, 7],  // +X
            [0, 4, 5, 1],  // -X
            [1, 5, 6, 2],  // +Y
            [0, 3, 7, 4],  // -Y
        ]
        var indices: [UInt32] = []
        for q in quads {
            indices += reversed ? [q[0], q[2], q[1], q[0], q[3], q[2]] : [q[0], q[1], q[2], q[0], q[2], q[3]]
        }
        return Mesh(vertices: v, indices: indices)!
    }

    // MARK: - Tests

    @MainActor
    @Test("a box against itself: symmetric difference ~0, both volumes agree")
    func identicalBodiesReadZeroDifference() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let (store, dir) = try scene([(id: "a", shape: box), (id: "b", shape: box)])
        defer { try? FileManager.default.removeItem(atPath: dir) }

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
        let (store, dir) = try scene([(id: "tall", shape: tallBox), (id: "short", shape: shortBox)])
        defer { try? FileManager.default.removeItem(atPath: dir) }

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

    @Test("classify() is orientation-agnostic on the pure function")
    func classifyIsOrientationAgnostic() {
        #expect(SymmetricDifferenceTools.classify(1.0) == true)
        #expect(SymmetricDifferenceTools.classify(-1.0) == true, "inverted-winding interior must still classify as inside")
        #expect(SymmetricDifferenceTools.classify(0.0) == false)
        #expect(SymmetricDifferenceTools.classify(0.5) == nil, "the midpoint between outside and inside is genuinely ambiguous")
        #expect(SymmetricDifferenceTools.classify(2.0) == true, "a doubled/nested-shell multiplicity is still enclosed")
    }

    @Test("a genuinely reversed-winding mesh: windingNumber itself reads ~-1 inside, and classify() still calls it inside")
    func reversedWindingMeshClassifiesCorrectly() {
        let normal = Self.boxMesh(reversed: false)
        let reversed = Self.boxMesh(reversed: true)
        let center = SIMD3<Double>(0, 0, 0)
        let outside = SIMD3<Double>(20, 20, 20)

        let wNormalCenter = normal.windingNumber(at: center)
        let wReversedCenter = reversed.windingNumber(at: center)
        #expect(abs(wNormalCenter - 1.0) < 0.01, "expected the normally-wound box to read ~+1 at its center, got \(wNormalCenter)")
        #expect(abs(wReversedCenter + 1.0) < 0.01, "expected the reversed-wound box to read ~-1 at its center (proving genuine inversion), got \(wReversedCenter)")

        #expect(SymmetricDifferenceTools.classify(wNormalCenter) == true)
        #expect(SymmetricDifferenceTools.classify(wReversedCenter) == true, "an inverted-winding interior must still classify as inside")
        #expect(SymmetricDifferenceTools.classify(normal.windingNumber(at: outside)) == false)
        #expect(SymmetricDifferenceTools.classify(reversed.windingNumber(at: outside)) == false)
    }

    @MainActor
    @Test("a locally-inconsistent-winding STL reference: high ambiguity and reliable=false, not a silent wrong answer")
    func inconsistentWindingStillFlagsAmbiguous() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-symdiff-inconsistent-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/inconsistent.stl"
        try Self.writeInconsistentWindingBoxSTL(to: stlPath, halfExtent: 5)

        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "symdiff-inconsistent", bodies: []))

        struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }
        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "inconsistentbox", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let inconsistentBodyId = try #require(imported.addedBodyIds.first)

        let normalBox = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let manifest = try #require(try store.read())
        try store.write(ScriptManifest(
            version: manifest.version, timestamp: manifest.timestamp, description: manifest.description,
            bodies: manifest.bodies + [BodyDescriptor(id: "normal", file: "normal.brep", color: [1, 1, 1, 1])]
        ))
        try Exporter.writeBREP(shape: normalBox, to: URL(fileURLWithPath: "\(dir)/normal.brep"))

        let result = await SymmetricDifferenceTools.symmetricDifferenceVolume(
            fromBodyId: "normal", referenceBodyId: inconsistentBodyId, maxSamples: 2000, store: store
        )
        #expect(!result.isError, "a locally-inconsistent reference must not hard-fail: \(result.text)")
        let r = try decode(result)

        #expect(r.ambiguousFraction > SymmetricDifferenceTools.ambiguousWarnFraction, "expected a substantial ambiguous fraction from the inconsistent winding, got \(r.ambiguousFraction)")
        #expect(!r.reliable, "an unreliable classification must be flagged, not silently reported as clean")
        #expect(r.warnings.contains { $0.lowercased().contains("uncertain") || $0.lowercased().contains("ambiguous") })
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
