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
        let toBounds = to.bounds
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
