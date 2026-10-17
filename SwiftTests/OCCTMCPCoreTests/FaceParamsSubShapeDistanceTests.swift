// FaceParamsSubShapeDistanceTests (#249): cylinder and sphere face rows carry
// radius / axis / axisPoint / sphereCenter on query_topology, select_topology
// and get_selection, and measure_distance accepts selectionIds or face[N] /
// edge[N] references so two faces of one body (or a face and an edge) can be
// measured.

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("face params and sub-shape distance (#249)")
struct FaceParamsSubShapeDistanceTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-faceparams-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map {
            BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1])
        }
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(version: 1, timestamp: Date(), description: "t", bodies: descriptors))
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func rows(_ text: String, key: String) throws -> [[String: Any]] {
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(obj[key] as? [[String: Any]])
    }

    func faceRow(_ r: [[String: Any]], surfaceType: String) throws -> [String: Any] {
        try #require(r.first { $0["surfaceType"] as? String == surfaceType })
    }

    // MARK: - query_topology

    @Test("a cylinder face row carries radius, a unit axis and a point on the axis")
    func cylinderFace() async throws {
        let cyl = try #require(Shape.cylinder(radius: 5, height: 10))
        let moved = try #require(cyl.translated(from: .zero, to: SIMD3(3, 4, 0)))
        let store = try scene([("cyl", moved)])
        let result = await IntrospectionTools.queryTopology(
            bodyId: "cyl", entity: "face", store: store)
        #expect(!result.isError, "\(result.text)")
        let row = try faceRow(try rows(result.text, key: "results"), surfaceType: "cylinder")
        #expect(abs(try #require(row["radius"] as? Double) - 5) < 1e-6)
        let axis = try #require(row["axis"] as? [Double])
        #expect(abs(abs(axis[2]) - 1) < 1e-6 && abs(axis[0]) < 1e-6 && abs(axis[1]) < 1e-6)
        let p = try #require(row["axisPoint"] as? [Double])
        // The point lies on the translated axis x=3, y=4.
        #expect(abs(p[0] - 3) < 1e-6 && abs(p[1] - 4) < 1e-6)
        #expect(row["sphereCenter"] == nil)
    }

    @Test("a sphere face row carries radius and centre, and no axis")
    func sphereFace() async throws {
        let sphere = try #require(Shape.sphere(radius: 7))
        let moved = try #require(sphere.translated(from: .zero, to: SIMD3(1, 2, 3)))
        let store = try scene([("ball", moved)])
        let result = await IntrospectionTools.queryTopology(
            bodyId: "ball", entity: "face", store: store)
        let row = try faceRow(try rows(result.text, key: "results"), surfaceType: "sphere")
        #expect(abs(try #require(row["radius"] as? Double) - 7) < 1e-6)
        let c = try #require(row["sphereCenter"] as? [Double])
        #expect(abs(c[0] - 1) < 1e-6 && abs(c[1] - 2) < 1e-6 && abs(c[2] - 3) < 1e-6)
        #expect(row["axis"] == nil && row["axisPoint"] == nil)
    }

    @Test("a planar face row carries none of the analytic parameters")
    func planarFace() async throws {
        let store = try scene([("box", try #require(Shape.box(width: 10, height: 20, depth: 30)))])
        let result = await IntrospectionTools.queryTopology(
            bodyId: "box", entity: "face", store: store)
        for row in try rows(result.text, key: "results") {
            #expect(row["radius"] == nil && row["axis"] == nil)
            #expect(row["axisPoint"] == nil && row["sphereCenter"] == nil)
        }
    }

    // MARK: - select_topology / get_selection

    @Test("select_topology and get_selection snapshots carry the cylinder parameters")
    func selectionSnapshots() async throws {
        let store = try scene([("cylsel", try #require(Shape.cylinder(radius: 4, height: 9)))])
        let registry = SelectionRegistry()
        var cylinderOnly = SelectionTools.Filter()
        cylinderOnly.surfaceType = "cylinder"
        let result = await SelectionTools.selectTopology(
            bodyId: "cylsel", kind: "face", filter: cylinderOnly,
            store: store, registry: registry)
        let sel = try #require(try rows(result.text, key: "selections").first)
        let anchor = try #require(sel["anchor"] as? [String: Any])
        #expect(abs(try #require(anchor["radius"] as? Double) - 4) < 1e-6)
        #expect(anchor["axis"] != nil && anchor["axisPoint"] != nil)

        // get_selection resolves a host entry through the same path.
        let faces = try #require(Shape.cylinder(radius: 4, height: 9)).faces()
        let index = try #require(
            faces.firstIndex { String(describing: $0.surfaceType) == "cylinder" })
        let resolved = await SelectionBridgeTools.resolveSelection(
            entry: .init(bodyId: "cylsel", kind: "face", index: index, uid: nil),
            store: store, registry: registry)
        #expect(resolved.error == nil, "\(resolved.error ?? "")")
        #expect(abs(try #require(resolved.anchor?.radius) - 4) < 1e-6)
        #expect(resolved.anchor?.axis != nil && resolved.anchor?.axisPoint != nil)
    }

    // MARK: - measure_distance

    func distance(_ text: String) throws -> Double {
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(obj["minDistance"] as? Double)
    }

    /// Two parallel faces of the 10 x 20 x 30 box, found by their `query_topology` labels.
    func parallelPair(_ store: ManifestStore, body: String) async throws -> (Int, Int) {
        let result = await IntrospectionTools.queryTopology(
            bodyId: body, entity: "face", relations: relationsWithOpposites(), store: store)
        let faces = try rows(result.text, key: "results")
        for f in faces {
            if let opp = f["oppositeFace"] as? [String: Any], let j = opp["index"] as? Int,
                let i = f["index"] as? Int, abs((opp["distance"] as? Double ?? 0) - 10) < 1e-6
            {
                return (i, j)
            }
        }
        throw Failure.noPair
    }

    func relationsWithOpposites() -> IntrospectionTools.FaceRelations {
        var r = IntrospectionTools.FaceRelations()
        r.oppositeFaces = true
        return r
    }

    enum Failure: Error { case noPair }

    @Test("face[N] references measure two faces of one body")
    func faceFaceByLabel() async throws {
        let store = try scene([("boxd", try #require(Shape.box(width: 10, height: 20, depth: 30)))])
        let (a, b) = try await parallelPair(store, body: "boxd")
        let result = await IntrospectionTools.measureDistance(
            fromBodyId: "boxd", from: "face[\(a)]", to: "face[\(b)]", store: store)
        #expect(!result.isError, "\(result.text)")
        #expect(abs(try distance(result.text) - 10) < 1e-6)
        let contacts = await IntrospectionTools.measureDistance(
            fromBodyId: "boxd", from: "face[\(a)]", to: "face[\(b)]",
            computeContacts: true, store: store)
        #expect(!contacts.isError)
        #expect(contacts.text.contains("\"contacts\""))
    }

    @Test("selectionIds measure a face against an edge on one body")
    func selectionIdFaceEdge() async throws {
        let store = try scene([("boxe", try #require(Shape.box(width: 10, height: 20, depth: 30)))])
        let registry = SelectionRegistry()
        let faceSel = await SelectionTools.selectTopology(
            bodyId: "boxe", kind: "face", filter: .init(), store: store, registry: registry)
        let edgeSel = await SelectionTools.selectTopology(
            bodyId: "boxe", kind: "edge", filter: .init(), store: store, registry: registry)
        let faces = try rows(faceSel.text, key: "selections")
        let edges = try rows(edgeSel.text, key: "selections")
        // Every edge of a box either lies on a given face (0) or is off it
        // (10, 20 or 30), so some face/edge pair is non-zero and some is zero.
        var seen = Set<Double>()
        for f in faces {
            for e in edges {
                let r = await IntrospectionTools.measureDistance(
                    from: f["selectionId"] as? String, to: e["selectionId"] as? String,
                    store: store, registry: registry)
                #expect(!r.isError, "\(r.text)")
                seen.insert((try distance(r.text) * 1e3).rounded() / 1e3)
            }
        }
        #expect(seen.contains(0))
        #expect(seen.contains { $0 > 1 })
    }

    @Test("whole-body fromBodyId and toBodyId still measure body to body")
    func wholeBodiesUnchanged() async throws {
        let a = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let b = try #require(
            Shape.box(width: 10, height: 10, depth: 10)?.translated(
                from: .zero, to: SIMD3(25, 0, 0)))
        let store = try scene([("ba", a), ("bb", b)])
        let r = await IntrospectionTools.measureDistance(
            fromBodyId: "ba", toBodyId: "bb", store: store)
        #expect(abs(try distance(r.text) - 15) < 1e-6)
    }

    @Test("bad references are errors, never a silent whole-body measurement")
    func badReferences() async throws {
        let store = try scene([("boxf", try #require(Shape.box(width: 10, height: 20, depth: 30)))])
        let cases: [(from: String?, to: String?, body: String?)] = [
            ("face[99]", "face[0]", "boxf"),
            ("blob", "face[0]", "boxf"),
            ("vertex[0]", "face[0]", "boxf"),
            ("face[0]", "face[1]", nil),
            ("sel:nosuch#face[0]", "face[0]", "boxf"),
        ]
        for c in cases {
            let r = await IntrospectionTools.measureDistance(
                fromBodyId: c.body, from: c.from, to: c.to, store: store)
            #expect(r.isError, "expected an error for \(c)")
        }
    }
}
