// EdgeGeometryFieldsTests (#119): select_topology / query_topology's edge
// results used to carry only curveType, length, and a rim-point center (plus
// circleCenter for select_topology). A straight edge is a vector in space:
// without endpoints and a unit direction, colinearity / endpoint-error checks
// against a source mesh are impossible from the tool surface alone. These
// tests pin the new endpoints/direction (line edges) and
// circleCenter/radius/axis/startAngle/endAngle (circular edges) fields on
// both tools, and that SelectionTools.edgeGeometryFields backs both
// identically.

import Foundation
import Testing
import simd
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("edge geometry fields (#119)")
struct EdgeGeometryFieldsTests {

    enum TestError: Error { case fixture(String) }

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-edgegeom-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "edgegeom", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    // ── decode mirrors ──────────────────────────────────────────────────

    struct AnchorSnapshotMirror: Decodable {
        let curveType: String?
        let length: Double?
        let endpoints: [[Double]]?
        let direction: [Double]?
        let circleCenter: [Double]?
        let radius: Double?
        let axis: [Double]?
        let startAngle: Double?
        let endAngle: Double?
    }
    struct SelectionEntryMirror: Decodable {
        let kind: String
        let anchor: AnchorSnapshotMirror
    }
    struct SelectionResultMirror: Decodable {
        let selections: [SelectionEntryMirror]
    }

    struct QueryResultMirror: Decodable {
        let id: String
        let curveType: String?
        let endpoints: [[Double]]?
        let direction: [Double]?
        let circleCenter: [Double]?
        let radius: Double?
        let axis: [Double]?
        let startAngle: Double?
        let endAngle: Double?
    }
    struct QueryReportMirror: Decodable {
        let results: [QueryResultMirror]
    }

    // ── select_topology ────────────────────────────────────────────────

    @Test("select_topology: line edge carries endpoints + unit direction, no circle fields")
    func selectTopologyLineEdge() async throws {
        // Shape.box is centered at the origin, not corner-anchored.
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([("box", box)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SelectionTools.selectTopology(bodyId: "box", kind: "edge", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(SelectionResultMirror.self, from: Data(result.text.utf8))
        #expect(!r.selections.isEmpty)

        for s in r.selections {
            let a = s.anchor
            #expect(a.curveType == "line")
            let ep = try #require(a.endpoints, "line edge missing endpoints")
            #expect(ep.count == 2)
            let p0 = SIMD3(ep[0][0], ep[0][1], ep[0][2])
            let p1 = SIMD3(ep[1][0], ep[1][1], ep[1][2])
            let dir = try #require(a.direction, "line edge missing direction")
            #expect(abs(simd_length(SIMD3(dir[0], dir[1], dir[2])) - 1.0) < 1e-9, "direction must be unit length")
            // direction must be parallel (up to sign) to endpoints[1] - endpoints[0].
            let raw = p1 - p0
            let rawLen = simd_length(raw)
            #expect(rawLen > 1e-9)
            let cosAngle = abs(simd_dot(simd_normalize(raw), SIMD3(dir[0], dir[1], dir[2])))
            #expect(cosAngle > 1 - 1e-6, "direction not parallel to endpoints delta")
            let lengthFromEndpoints = simd_distance(p0, p1)
            #expect(abs(lengthFromEndpoints - (a.length ?? -1)) < 1e-6, "endpoints distance should match reported length for a straight edge")

            #expect(a.circleCenter == nil)
            #expect(a.radius == nil)
            #expect(a.axis == nil)
            #expect(a.startAngle == nil)
            #expect(a.endAngle == nil)
        }
    }

    @Test("select_topology: circular edge carries circleCenter/radius/axis/startAngle/endAngle, no direction")
    func selectTopologyCircularEdge() async throws {
        let cyl = try #require(Shape.cylinder(radius: 5, height: 10))
        let store = try scene([("cyl", cyl)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SelectionTools.selectTopology(bodyId: "cyl", kind: "edge", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(SelectionResultMirror.self, from: Data(result.text.utf8))
        let circles = r.selections.filter { $0.anchor.curveType == "circle" }
        #expect(!circles.isEmpty, "a cylinder must have at least one circular rim edge")

        for s in circles {
            let a = s.anchor
            let radius = try #require(a.radius)
            #expect(abs(radius - 5.0) < 1e-6)
            let center = try #require(a.circleCenter)
            #expect(center.count == 3)
            let axis = try #require(a.axis)
            #expect(abs(simd_length(SIMD3(axis[0], axis[1], axis[2])) - 1.0) < 1e-9, "axis must be unit length")
            // A cylinder along Z: a rim circle's plane normal must be parallel to Z.
            #expect(abs(abs(axis[2]) - 1.0) < 1e-6, "cylinder rim axis should be parallel to Z")
            let start = try #require(a.startAngle)
            let end = try #require(a.endAngle)
            #expect(end > start)

            #expect(a.direction == nil, "a circular edge has no single direction")
        }
    }

    // ── query_topology (same fields, via IntrospectionTools) ─────────────

    @Test("query_topology: edge results carry the same geometry fields as select_topology")
    func queryTopologyEdgeFields() async throws {
        let cyl = try #require(Shape.cylinder(radius: 5, height: 10))
        let store = try scene([("cyl", cyl)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await IntrospectionTools.queryTopology(bodyId: "cyl", entity: "edge", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(QueryReportMirror.self, from: Data(result.text.utf8))
        #expect(!r.results.isEmpty)

        let circles = r.results.filter { $0.curveType == "circle" }
        #expect(!circles.isEmpty)
        for c in circles {
            #expect(c.radius != nil)
            #expect(c.circleCenter != nil)
            #expect(c.axis != nil)
            #expect(c.startAngle != nil)
            #expect(c.endAngle != nil)
        }

        let lines = r.results.filter { $0.curveType == "line" }
        for l in lines {
            #expect(l.endpoints?.count == 2)
            #expect(l.direction != nil)
        }
    }
}
