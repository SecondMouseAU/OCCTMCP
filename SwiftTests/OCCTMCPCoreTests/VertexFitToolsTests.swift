// Tests for measure_vertex_fit (#118): exact per-vertex mesh-to-BREP distance
// table. Fixture is two boxes far apart along X so every "from" vertex's
// nearest point on "to" is a straight perpendicular drop onto a single flat
// face, giving an exact, independently computable expected distance
// (point.x - toBounds.max.x) without assuming which corner-vs-center
// convention Shape.box(origin:...) uses internally.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("measure_vertex_fit (#118)")
struct VertexFitToolsTests {

    enum TestError: Error { case fixture(String) }

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-vertexfit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "vertexfit", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    struct EntryMirror: Decodable {
        let index: Int
        let point: [Double]
        let distance: Double
        let nearestKind: String
    }
    struct ReportMirror: Decodable {
        let fromBodyId, toBodyId: String
        let vertexCount, sampledCount, stride: Int
        let mean, rms, max, p95: Double
        let worst: [EntryMirror]
        let vertices: [EntryMirror]?
        let warnings: [String]
    }

    /// Small "from" box far along +X from a centered "to" box, so every
    /// "from" vertex projects perpendicularly onto "to"'s +X face.
    func farBoxScene() throws -> (store: ManifestStore, toMaxX: Double) {
        guard let to = Shape.box(width: 10, height: 10, depth: 10) else {
            throw TestError.fixture("failed to build 'to' box")
        }
        guard let from = Shape.box(origin: SIMD3(20, -1, -1), width: 2, height: 2, depth: 2) else {
            throw TestError.fixture("failed to build 'from' box")
        }
        let toBounds = try #require(to.bounds)
        // Sanity: the "from" box's Y/Z extent must sit strictly inside the
        // "to" box's Y/Z extent, or the nearest point wouldn't be a straight
        // drop onto the flat +X face (the property this whole fixture relies
        // on) regardless of which corner Shape.box(origin:...) anchors from.
        let fromVerts = from.vertices()
        for v in fromVerts {
            guard v.y > toBounds.min.y, v.y < toBounds.max.y, v.z > toBounds.min.z, v.z < toBounds.max.z else {
                throw TestError.fixture("'from' box Y/Z extent not inside 'to' box; fixture assumption broken")
            }
            guard v.x > toBounds.max.x else {
                throw TestError.fixture("'from' box not entirely beyond 'to' box's +X face; fixture assumption broken")
            }
        }
        let store = try scene([("from", from), ("to", to)])
        return (store, toBounds.max.x)
    }

    @Test("exact per-vertex distance + face classification against a known flat face")
    func exactDistanceAndKind() async throws {
        let (store, toMaxX) = try farBoxScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await VertexFitTools.measureVertexFit(fromBodyId: "from", toBodyId: "to", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ReportMirror.self, from: Data(result.text.utf8))

        #expect(r.vertexCount == 8, "a box has 8 corner vertices")
        #expect(r.sampledCount == 8)
        #expect(r.stride == 1)
        #expect(r.warnings.isEmpty)
        #expect(r.vertices == nil, "includeAllVertices defaults to false")
        #expect(r.worst.count == 8, "worstN defaults to 20, above the 8 available")

        for e in r.worst {
            let expected = e.point[0] - toMaxX
            #expect(abs(e.distance - expected) < 1e-6, "vertex \(e.index): distance \(e.distance) != expected \(expected)")
            #expect(e.nearestKind == "face", "a perpendicular drop onto a flat face should classify as 'face', got \(e.nearestKind)")
        }
        // Largest-first.
        for i in 0..<(r.worst.count - 1) {
            #expect(r.worst[i].distance >= r.worst[i + 1].distance)
        }
        #expect(abs(r.max - (r.worst.first?.distance ?? -1)) < 1e-9)
        #expect(r.max > r.mean)
    }

    @Test("maxVertices stride-subsamples with a warning; worstN and includeAllVertices are respected")
    func samplingKnobs() async throws {
        let (store, _) = try farBoxScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let capped = await VertexFitTools.measureVertexFit(
            fromBodyId: "from", toBodyId: "to", maxVertices: 4, store: store)
        #expect(!capped.isError, "unexpected error: \(capped.text)")
        let rCapped = try JSONDecoder().decode(ReportMirror.self, from: Data(capped.text.utf8))
        #expect(rCapped.vertexCount == 8)
        #expect(rCapped.stride == 2, "ceil(8/4) = 2")
        #expect(rCapped.sampledCount == 4)
        #expect(rCapped.warnings.contains { $0.contains("stride-subsampled") })

        let worstOne = await VertexFitTools.measureVertexFit(
            fromBodyId: "from", toBodyId: "to", worstN: 1, store: store)
        let rWorstOne = try JSONDecoder().decode(ReportMirror.self, from: Data(worstOne.text.utf8))
        #expect(rWorstOne.worst.count == 1)

        let full = await VertexFitTools.measureVertexFit(
            fromBodyId: "from", toBodyId: "to", includeAllVertices: true, store: store)
        let rFull = try JSONDecoder().decode(ReportMirror.self, from: Data(full.text.utf8))
        #expect(rFull.vertices?.count == rFull.sampledCount)
    }

    // ── real STL import: does Shape.vertices() dedupe shared corners? ────

    /// Writes a cube as 12 unshared-per-facet triangles (3 verts each, the
    /// naive STL convention import_file's own STL path uses) so this can
    /// check, empirically, whether `Shape.vertices()` returns 8 (deduped
    /// corners) or up to 36 (one instance per triangle corner) on a REAL
    /// STL-imported facet shell, `measure_vertex_fit`'s own documented
    /// primary use case. Every existing VertexFitToolsTests fixture uses a
    /// primitive `Shape.box`, where OCCT shares TopoDS_Vertex objects across
    /// faces by construction, so it can't answer this question.
    static func writeCubeSTL(to path: String, half: Double = 5) throws {
        let h = half
        let corners: [SIMD3<Double>] = [
            SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
            SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
        ]
        // (face vertex indices, outward normal) for each of the 6 faces, 2 triangles each.
        let faces: [([Int], SIMD3<Double>)] = [
            ([0, 1, 2, 3], SIMD3(0, 0, -1)), ([4, 5, 6, 7], SIMD3(0, 0, 1)),
            ([0, 1, 5, 4], SIMD3(0, -1, 0)), ([2, 3, 7, 6], SIMD3(0, 1, 0)),
            ([1, 2, 6, 5], SIMD3(1, 0, 0)), ([3, 0, 4, 7], SIMD3(-1, 0, 0)),
        ]
        var out = "solid cube\n"
        func facet(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ n: SIMD3<Double>) {
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n"
            for v in [a, b, c] { out += "      vertex \(v.x) \(v.y) \(v.z)\n" }
            out += "    endloop\n  endfacet\n"
        }
        for (idx, n) in faces {
            let a = corners[idx[0]], b = corners[idx[1]], c = corners[idx[2]], d = corners[idx[3]]
            facet(a, b, c, n)
            facet(a, c, d, n)
        }
        out += "endsolid cube\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test("real STL import: Shape.vertices() count and measure_vertex_fit against an actual mesh/STL body")
    func realSTLImportVertexCount() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-vertexfit-stl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "vertexfit stl", bodies: []))

        let half = 5.0
        let stlPath = "\(dir)/cube.stl"
        try Self.writeCubeSTL(to: stlPath, half: half)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "cube", store: store, history: SceneHistory())
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        struct ImportReport: Decodable { let addedBodyIds: [String] }
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let stlBodyId = try #require(imported.addedBodyIds.first)

        // Reference body well outside the cube along +X, same "known flat
        // face" trick as farBoxScene, so every measured vertex has an exact,
        // independently computable expected distance.
        guard let refShape = Shape.box(origin: SIMD3(3 * half, -half, -half), width: half, height: 2 * half, depth: 2 * half) else {
            throw TestError.fixture("failed to build reference box")
        }
        let refPath = "\(dir)/ref.brep"
        try Exporter.writeBREP(shape: refShape, to: URL(fileURLWithPath: refPath))
        let existing = try #require(try store.read())
        let updated = ScriptManifest(
            version: existing.version, timestamp: existing.timestamp, description: existing.description,
            bodies: existing.bodies + [BodyDescriptor(id: "ref", file: "ref.brep", color: [1, 1, 1, 1])]
        )
        try store.write(updated)

        // Expected distances derived from the reference box's ACTUAL bounds
        // (not an assumed corner-vs-center placement convention), the same
        // robustness approach farBoxScene uses above.
        let refBounds = try #require(refShape.bounds)
        let expectedNear = refBounds.min.x - half        // cube's near face (x=+half) to ref's near face
        let expectedFar = refBounds.min.x - (-half)       // cube's far face (x=-half) to ref's near face

        let result = await VertexFitTools.measureVertexFit(
            fromBodyId: stlBodyId, toBodyId: "ref", includeAllVertices: true, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ReportMirror.self, from: Data(result.text.utf8))

        // The actual question this test exists to answer: does a naive-STL
        // facet shell give Shape.vertices() the 8 true corners, or up to 36
        // (12 triangles x 3, unshared)? Confirmed empirically: import_file's
        // STL path sews/heals on import, so Shape.vertices() returns the
        // true 8 deduped corners, not 36 raw per-facet ones. measure_vertex_fit
        // doesn't need its own deduplication logic as a result; if this ever
        // regresses (a future import_file change that stops sewing), this
        // assertion catches it rather than silently inflating vertexCount
        // and wasting sample budget on duplicate points.
        #expect(r.vertexCount == 8, "expected import_file's STL sewing to dedupe to 8 true corners, got \(r.vertexCount); if import_file's sewing behavior changed, measure_vertex_fit's docs/behavior need revisiting for duplicate-vertex handling")

        // Whatever the count, every DISTINCT corner position must report the
        // exact expected distance: two families exist (the cube's near face,
        // x=+half, and far face, x=-half), each a straight drop onto the
        // reference box's near face, independent of duplication.
        let allEntries = try #require(r.vertices, "includeAllVertices:true should populate `vertices`")
        let byPosition = Dictionary(grouping: allEntries) { e in
            "\(e.point[0].rounded()),\(e.point[1].rounded()),\(e.point[2].rounded())"
        }
        #expect(!byPosition.isEmpty)
        for (_, group) in byPosition {
            let d = group[0].distance
            let isNear = abs(d - expectedNear) < 1e-6
            let isFar = abs(d - expectedFar) < 1e-6
            #expect(isNear || isFar, "corner group \(group.map(\.point)) reported distance \(d), expected \(expectedNear) or \(expectedFar)")
            for e in group {
                #expect(abs(e.distance - d) < 1e-9, "duplicate instances of the same corner disagree on distance")
            }
        }
    }

    @Test("dispatch: missing body reports 'not found', not a crash")
    func missingBody() async throws {
        let store = try scene([])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let result = await VertexFitTools.measureVertexFit(fromBodyId: "nope", toBodyId: "also-nope", store: store)
        // Matches every other IntrospectionTools.loadShape-backed tool
        // (measure_deviation, cross_section_compare, ...): the catch block
        // returns the error's description without isError:true.
        #expect(result.text.contains("not found"))
    }
}
