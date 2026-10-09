// GraphMLEdgeConvexityTests (#231): the in-process graph_ml passes the source shape to the
// exporter, so every nodes.edges[] entry carries `convexity` and `dihedralAngle`.

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import Testing

@Suite("graph_ml per-edge convexity (#231)")
struct GraphMLEdgeConvexityTests {

    typealias Row = [String: Any]

    struct Payload {
        let schemaVersion: String
        let edges: [Row]
    }

    /// Writes `shape` to a BREP, runs the real `graph_ml` tool on it and returns the parsed payload.
    func graphML(_ shape: Shape) async throws -> Payload {
        let dir = NSTemporaryDirectory() + "occtmcp-graphml-edge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/part.brep"
        try Exporter.writeBREP(shape: shape, to: URL(fileURLWithPath: path))
        let result = await AnalysisTools.graphML(brepPath: path)
        try #require(!result.isError, "graph_ml failed: \(result.text)")
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? Row)
        let meta = try #require(obj["meta"] as? Row)
        let nodes = try #require(obj["nodes"] as? Row)
        let edges = try #require(nodes["edges"] as? [Row])
        return Payload(
            schemaVersion: try #require(meta["schemaVersion"] as? String), edges: edges)
    }

    func convexities(_ edges: [Row]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for e in edges { counts[e["convexity"] as? String ?? "<absent>", default: 0] += 1 }
        return counts
    }

    @Test("a cube: all 12 edges convex at pi/2, schema 1.1.0")
    func cube() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        #expect(box.faces().count == 6)
        let p = try await graphML(box)
        #expect(p.schemaVersion == "1.1.0")
        try #require(p.edges.count == 12)
        for e in p.edges {
            #expect(e["convexity"] as? String == "convex")
            let angle = try #require(e["dihedralAngle"] as? Double)
            #expect(abs(angle - .pi / 2) < 1e-6)
        }
    }

    @Test("an L-shaped prism: exactly one concave edge at 3 pi/2")
    func lPrism() async throws {
        // Two boxes sharing the corner at the origin: x 0..20, y 0..10 and x 0..10, y 0..20, z 0..10.
        let a = try #require(
            Shape.box(origin: SIMD3(0, 0, 0), width: 20, height: 10, depth: 10))
        let b = try #require(
            Shape.box(origin: SIMD3(0, 0, 0), width: 10, height: 20, depth: 10))
        let union = try #require(a.union(b))
        // The inside corner is the only concave edge, so the union must be an L and not a box:
        // volume 2000 + 2000 - 1000 (the shared cube) = 3000.
        let volume = try #require(union.volume)
        #expect(abs(volume - 3000) < 1e-3)
        let p = try await graphML(union)
        #expect(p.schemaVersion == "1.1.0")
        try #require(p.edges.count >= 18)
        let counts = convexities(p.edges)
        #expect(counts["concave"] == 1)
        #expect(counts["unknown"] == nil)
        #expect(counts["<absent>"] == nil)
        let concave = try #require(p.edges.first { $0["convexity"] as? String == "concave" })
        let angle = try #require(concave["dihedralAngle"] as? Double)
        #expect(abs(angle - 3 * .pi / 2) < 1e-6)
    }

    @Test("an open shell: boundary edges are unknown with no dihedralAngle")
    func openShell() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let faces = box.subShapes(ofType: .face)
        try #require(faces.count == 6)
        // Drop one face: the four edges of the hole each bound a single face.
        let shell = try #require(Shape.shellFromFaces(Array(faces.dropLast())))
        #expect(shell.faces().count == 5)
        let p = try await graphML(shell)
        try #require(p.edges.count == 12)
        let counts = convexities(p.edges)
        #expect(counts["unknown"] == 4)
        #expect(counts["convex"] == 8)
        let unknown = p.edges.filter { $0["convexity"] as? String == "unknown" }
        try #require(unknown.count == 4)
        for e in unknown { #expect(e["dihedralAngle"] == nil) }
    }
}
