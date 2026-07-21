// Unit tests for align_bodies (#104): a box "reference" plus a "source" body built by applying a
// KNOWN rotation + translation to a copy of the same box (Shape.box is centered at the origin, not
// corner-anchored — see CLAUDE.md's OCCTSwift#336 write-up — so rotating about the origin then
// translating is a clean, exactly-invertible rigid transform on the BREP geometry itself, no
// meshing noise involved in constructing the fixture).
//
// Verification style: rather than reaching into AlignTools' own axis-angle/row-major helpers (which
// would make the test tautological), each test reconstructs the OCCTSwift matrix12 block straight
// from the tool's JSON `transform` field and calls `Shape.transformed(matrix:)` on the ACTUAL source
// shape, then compares the result's bounding box against the reference's. That's an independent,
// end-to-end check of "recovered transform composed with the known applied one ~ identity", using
// the same OCCT primitive align_bodies' own `apply: true` path uses.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("align_bodies: point-to-plane ICP registration")
struct AlignToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-align-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "align", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    /// A box with 3 DISTINCT dimensions plus a small corner nub, as the reference, plus a "source"
    /// built by rotating that same shape about the origin by a known non-axis-aligned angle and
    /// then translating it — a clean rigid-transform pair.
    ///
    /// The nub matters: a PLAIN rectangular box (even with 3 distinct dimensions, so PCA's
    /// eigenvalues themselves are non-degenerate) is still invariant under a 180° rotation about
    /// any of its 3 principal axes (its own D2h symmetry group) — ICP can't tell those poses apart
    /// from the true one, all scoring an equally-perfect zero residual. That's fine for recovering
    /// a KNOWN, deliberately-applied transform (tests 1/2/5 below, which never revisit an
    /// already-aligned pose), but test 3's "a second align_bodies now recovers ~identity" check
    /// needs a shape whose correct pose is actually UNIQUE. A small nub clearly protruding past the
    /// base box on all three axes, confined to one octant corner, breaks every one of the box's own
    /// 180°-rotation / mirror symmetries.
    func makeFixture() throws -> (reference: Shape, source: Shape) {
        let base = try #require(Shape.box(width: 40, height: 30, depth: 20))
        let bump = try #require(Shape.box(width: 6, height: 6, depth: 6))
        let positionedBump = try #require(bump.translated(by: SIMD3<Double>(21, 16, 11)))
        let reference = try #require(base.union(positionedBump))

        let axis = simd_normalize(SIMD3<Double>(0.3, 0.5, 0.8))
        let angle = 27.0 * Double.pi / 180.0
        let translation = SIMD3<Double>(60, -35, 15)
        let rotated = try #require(reference.rotated(axis: axis, angle: angle))
        let source = try #require(rotated.translated(by: translation))
        return (reference, source)
    }

    /// OCCTSwift's `Shape.transformed(matrix:)` wants the 9 rotation entries row-major, THEN the 3
    /// translation entries (see AlignTools.align3x4RowMajorBlock's doc comment) — reconstructed here
    /// straight from the tool's row-major JSON `transform`, independent of AlignTools' own helper.
    func matrix12(fromRowMajor rows: [[Double]]) -> [Double] {
        [
            rows[0][0], rows[0][1], rows[0][2],
            rows[1][0], rows[1][1], rows[1][2],
            rows[2][0], rows[2][1], rows[2][2],
            rows[0][3], rows[1][3], rows[2][3],
        ]
    }

    struct AlignReport: Decodable {
        let bodyId: String
        let referenceBodyId: String
        let mode: String
        let transform: [[Double]]
        let translationMm: [Double]
        let rotationAxis: [Double]
        let rotationAngleDegrees: Double
        let residualRmsMm: Double
        let iterations: Int
        let converged: Bool
        let applied: Bool
        let warnings: [String]
    }

    // ── 1. Known-transform recovery (bestFit) ───────────────────────────

    @MainActor
    @Test("bestFit recovers a known rotation + translation")
    func bestFitRecoversKnownTransform() async throws {
        let (reference, source) = try makeFixture()
        let store = try scene([(id: "reference", shape: reference), (id: "source", shape: source)])

        let result = await AlignTools.alignBodies(bodyId: "source", referenceBodyId: "reference", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(AlignReport.self, from: Data(result.text.utf8))

        #expect(r.mode == "bestFit")
        #expect(r.iterations > 0, "bestFit should run at least one ICP iteration on a non-trivial pose")

        let transformed = try #require(source.transformed(matrix: matrix12(fromRowMajor: r.transform)))
        let refBounds = reference.bounds
        let gotBounds = transformed.bounds
        #expect(simd_length(gotBounds.min - refBounds.min) < 0.1,
                "min corner off by \(simd_length(gotBounds.min - refBounds.min))mm")
        #expect(simd_length(gotBounds.max - refBounds.max) < 0.1,
                "max corner off by \(simd_length(gotBounds.max - refBounds.max))mm")
    }

    // ── 2. preAlign mode: coarse pose, zero ICP iterations ──────────────

    @MainActor
    @Test("preAlign mode returns the coarse PCA/bbox pose with zero ICP iterations")
    func preAlignReturnsCoarsePose() async throws {
        let (reference, source) = try makeFixture()
        let store = try scene([(id: "reference", shape: reference), (id: "source", shape: source)])

        let result = await AlignTools.alignBodies(
            bodyId: "source", referenceBodyId: "reference", mode: .preAlign, store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(AlignReport.self, from: Data(result.text.utf8))

        #expect(r.mode == "preAlign")
        #expect(r.iterations == 0, "preAlign must not run any ICP refinement iterations")
        #expect(!r.converged, "converged is not a meaningful signal with zero iterations")
        // preAlign must not fire the bestFit-only "did not converge" warning.
        #expect(!r.warnings.contains { $0.contains("did not converge") })

        let transformed = try #require(source.transformed(matrix: matrix12(fromRowMajor: r.transform)))
        let refBounds = reference.bounds
        let gotBounds = transformed.bounds
        // Coarse stage only — a looser envelope than bestFit's tight recovery ("within a few mm").
        #expect(simd_length(gotBounds.min - refBounds.min) < 5.0)
        #expect(simd_length(gotBounds.max - refBounds.max) < 5.0)
    }

    // ── 3. apply: true end-to-end ────────────────────────────────────────

    @MainActor
    @Test("apply: true writes the recovered transform onto the source body in place")
    func applyWritesTransformInPlace() async throws {
        let (reference, source) = try makeFixture()
        let store = try scene([(id: "reference", shape: reference), (id: "source", shape: source)])
        let beforeManifest = try #require(try store.read())
        let sourceBody = try #require(beforeManifest.body(withId: "source"))
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sourcePath = "\(outputDir)/\(sourceBody.file)"

        let result = await AlignTools.alignBodies(
            bodyId: "source", referenceBodyId: "reference", apply: true, store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(AlignReport.self, from: Data(result.text.utf8))
        #expect(r.applied)

        let afterManifest = try #require(try store.read())
        // >= not >: ManifestStore round-trips timestamps through ISO8601 (second-precision, no
        // fractional seconds), so two writes within the same wall-clock second — routine for a
        // fast in-process test — decode as EQUAL even though `store.write` did call `Date()` again.
        // The BREP re-load below is the real, unambiguous proof the write happened.
        #expect(afterManifest.timestamp >= beforeManifest.timestamp, "manifest timestamp must not go backwards")

        // The BREP file on disk now holds the aligned shape — the unambiguous proof the write
        // actually happened, independent of timestamp granularity.
        let rewritten = try Shape.loadBREP(fromPath: sourcePath)
        let refBounds = reference.bounds
        let gotBounds = rewritten.bounds
        #expect(simd_length(gotBounds.min - refBounds.min) < 0.1)
        #expect(simd_length(gotBounds.max - refBounds.max) < 0.1)

        // A second align_bodies call against the now-aligned body recovers ~identity.
        let second = await AlignTools.alignBodies(bodyId: "source", referenceBodyId: "reference", store: store)
        #expect(!second.isError, "unexpected error: \(second.text)")
        let r2 = try JSONDecoder().decode(AlignReport.self, from: Data(second.text.utf8))
        #expect(r2.rotationAngleDegrees < 1.0, "expected ~identity rotation, got \(r2.rotationAngleDegrees) degrees")
        let t2 = SIMD3<Double>(r2.translationMm[0], r2.translationMm[1], r2.translationMm[2])
        #expect(simd_length(t2) < 0.5, "expected ~identity translation, got \(r2.translationMm)")
    }

    // ── 4. Error paths ───────────────────────────────────────────────────

    @MainActor
    @Test("bodyId == referenceBodyId is an error")
    func sameBodyIsError() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        let result = await AlignTools.alignBodies(bodyId: "box", referenceBodyId: "box", store: store)
        #expect(result.isError)
        #expect(result.text.contains("distinct bodies"))
    }

    @MainActor
    @Test("an unknown reference body reports Body not found")
    func unknownReferenceBodyReportsNotFound() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        // loadShape's ToolError path — same convention every other tool in this family follows
        // (mesh_diagnose / mesh_thickness / detect_symmetry): the message names the missing body,
        // matching IntrospectionTools.ToolError.bodyNotFound's description.
        let result = await AlignTools.alignBodies(bodyId: "box", referenceBodyId: "does-not-exist", store: store)
        #expect(result.text.contains("Body not found: does-not-exist"))
    }

    // ── 5. JSON shaping: row-major transform convention ─────────────────

    @MainActor
    @Test("transform is row-major 4x4: translation sits at column index 3 of rows 0-2")
    func transformIsRowMajorWithTranslationInColumn3() async throws {
        let (reference, source) = try makeFixture()
        let store = try scene([(id: "reference", shape: reference), (id: "source", shape: source)])

        let result = await AlignTools.alignBodies(bodyId: "source", referenceBodyId: "reference", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(AlignReport.self, from: Data(result.text.utf8))

        #expect(r.transform.count == 4)
        for row in r.transform { #expect(row.count == 4) }
        #expect(r.translationMm.count == 3)
        #expect(r.transform[0][3] == r.translationMm[0])
        #expect(r.transform[1][3] == r.translationMm[1])
        #expect(r.transform[2][3] == r.translationMm[2])
        // The trivial 4th row of any rigid transform.
        #expect(abs(r.transform[3][0]) < 1e-9)
        #expect(abs(r.transform[3][1]) < 1e-9)
        #expect(abs(r.transform[3][2]) < 1e-9)
        #expect(abs(r.transform[3][3] - 1) < 1e-9)
    }
}
