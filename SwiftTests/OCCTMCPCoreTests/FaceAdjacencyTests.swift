// FaceAdjacencyTests (#199, #201): query_topology's includeNeighbors /
// oppositeFaces, and graph_select's face indices in Shape.faces() space.

import Foundation
import Testing
import simd
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("Face adjacency and opposite faces (#199, #201)")
struct FaceAdjacencyTests {

    typealias Row = [String: Any]

    func scene(_ shape: Shape, id: String = "part") throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-faceadj-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "faceadj",
                bodies: [BodyDescriptor(id: id, file: "\(id).brep", color: [1, 1, 1, 1])]))
        try Exporter.writeBREP(shape: shape, to: URL(fileURLWithPath: "\(dir)/\(id).brep"))
        return (store, dir)
    }

    func query(
        _ shape: Shape, entity: String = "face", filter: IntrospectionTools.TopologyFilter = .init(),
        limit: Int? = nil, relations: IntrospectionTools.FaceRelations
    ) async throws -> (text: ToolText, rows: [Row]) {
        let (store, dir) = try scene(shape)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let result = await IntrospectionTools.queryTopology(
            bodyId: "part", entity: entity, filter: filter, limit: limit, relations: relations,
            store: store)
        guard !result.isError,
            let obj = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? Row,
            let rows = obj["results"] as? [Row]
        else { return (result, []) }
        return (result, rows)
    }

    func relations(
        neighbors: Bool = false, opposite: Bool = false, method: String = "exact"
    ) -> IntrospectionTools.FaceRelations {
        var r = IntrospectionTools.FaceRelations()
        r.includeNeighbors = neighbors
        r.oppositeFaces = opposite
        r.oppositeMethod = method
        return r
    }

    func vector(_ row: Row, _ key: String) -> SIMD3<Double> {
        let a = (row[key] as? [Double]) ?? [0, 0, 0]
        return SIMD3(a[0], a[1], a[2])
    }

    func index(_ row: Row) -> Int { row["index"] as? Int ?? -1 }

    func face(_ rows: [Row], normal: SIMD3<Double>, where match: (SIMD3<Double>) -> Bool) -> Row? {
        rows.first { simd_dot(vector($0, "normal"), normal) > 0.999 && match(vector($0, "center")) }
    }

    @Test("box: every face has 4 convex neighbours and the right opposite")
    func box() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        for method in ["exact", "bbox"] {
            let (result, rows) = try await query(
                box, relations: relations(neighbors: true, opposite: true, method: method))
            #expect(!result.isError, "unexpected error: \(result.text)")
            #expect(rows.count == 6)
            for row in rows {
                let neighbors = try #require(row["neighbors"] as? [Row])
                #expect(neighbors.count == 4 && row["neighborCount"] as? Int == 4)
                #expect(row["neighborsTruncated"] as? Bool == false)
                for n in neighbors {
                    #expect(n["convexity"] as? String == "convex")
                    #expect(n["sharedEdgeCount"] as? Int == 1)
                }
                let opposite = try #require(row["oppositeFace"] as? Row)
                let other = try #require(rows.first { index($0) == opposite["index"] as? Int })
                #expect(simd_dot(vector(row, "normal"), vector(other, "normal")) < -0.999)
                let separation = abs(
                    simd_dot(vector(row, "center") - vector(other, "center"), vector(row, "normal")))
                #expect(abs((opposite["distance"] as? Double ?? -1) - separation) < 1e-6)
                #expect(opposite["method"] as? String == method)
            }
            let dims = Set(
                rows.compactMap { ($0["oppositeFace"] as? Row)?["distance"] as? Double }.map {
                    Int($0.rounded())
                })
            #expect(dims == [10, 20, 30])
        }
    }

    /// Stair: a 20x20x10 slab with a 10x10x5 block on one top quadrant.
    func stair() throws -> Shape {
        let slab = try #require(
            Shape.box(origin: SIMD3(-10, -10, -5), width: 20, height: 20, depth: 10))
        let step = try #require(Shape.box(origin: SIMD3(0, 0, 5), width: 10, height: 10, depth: 5))
        return try #require(slab.union(step))
    }

    @Test("stair: concave neighbour, and a touching-only coplanar face is not the opposite")
    func stairBlock() async throws {
        let (result, rows) = try await query(
            try stair(), relations: relations(neighbors: true, opposite: true))
        #expect(!result.isError, "unexpected error: \(result.text)")
        // The step's x=0 wall faces -x and spans z in [5, 10].
        let wall = try #require(
            face(rows, normal: SIMD3(-1, 0, 0)) { $0.x > -1e-6 && $0.x < 1e-6 && $0.z > 5.1 })
        let neighbors = try #require(wall["neighbors"] as? [Row])
        #expect(neighbors.contains { $0["convexity"] as? String == "concave" })
        // The slab's x=10 face only touches the wall's z range at z=5, so it must lose to the
        // step's own x=10 face even though both sit at distance 10.
        let opposite = try #require(wall["oppositeFace"] as? Row)
        let target = try #require(rows.first { index($0) == opposite["index"] as? Int })
        #expect(vector(target, "center").z > 5.1)
        #expect(abs((opposite["distance"] as? Double ?? 0) - 10) < 1e-6)
    }

    /// An L-shaped prism with a small plate floating inside its notch.
    func notchWithPlate() throws -> Shape {
        let block = try #require(
            Shape.box(origin: SIMD3(-10, -10, 0), width: 20, height: 20, depth: 5))
        let notch = try #require(
            Shape.box(origin: SIMD3(0, 0, -1), width: 11, height: 11, depth: 7))
        let lBlock = try #require(block.subtracting(notch))
        let plate = try #require(Shape.box(origin: SIMD3(3, 3, 1), width: 4, height: 4, depth: 2))
        return try #require(Shape.compound([lBlock, plate]))
    }

    @Test("exact rejects a candidate sitting in the L's missing quadrant, bbox accepts it")
    func exactVersusBBox() async throws {
        let shape = try notchWithPlate()
        let (_, exactRows) = try await query(shape, relations: relations(opposite: true))
        let (_, boxRows) = try await query(
            shape, relations: relations(opposite: true, method: "bbox"))
        func lTop(_ rows: [Row]) -> Row? {
            rows.first {
                simd_dot(vector($0, "normal"), SIMD3(0, 0, 1)) > 0.999
                    && abs(vector($0, "center").z - 5) < 1e-6
            }
        }
        let exact = try #require(lTop(exactRows)?["oppositeFace"] as? Row)
        let loose = try #require(lTop(boxRows)?["oppositeFace"] as? Row)
        // Exact skips the plate's underside (z=1, distance 4) and lands on the L's own base.
        #expect(abs((exact["distance"] as? Double ?? 0) - 5) < 1e-6)
        // The box test cannot tell the plate lies in the notch.
        #expect(abs((loose["distance"] as? Double ?? 0) - 4) < 1e-6)
    }

    @Test("polygon overlap: identical, nested, crossing, touching and disjoint")
    func polygonOverlap() {
        let square = [SIMD2(0.0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        func shifted(_ dx: Double, _ dy: Double, _ size: Double = 10) -> [SIMD2<Double>] {
            [SIMD2(dx, dy), SIMD2(dx + size, dy), SIMD2(dx + size, dy + size),
                SIMD2(dx, dy + size)]
        }
        #expect(PolygonOverlap.overlaps(square, square, scale: 10))
        #expect(PolygonOverlap.overlaps(square, shifted(2, 2, 3), scale: 10))
        #expect(PolygonOverlap.overlaps(square, shifted(5, 5), scale: 10))
        #expect(PolygonOverlap.overlaps(square, shifted(0, 0, 5), scale: 10))
        #expect(!PolygonOverlap.overlaps(square, shifted(10, 0), scale: 10))
        #expect(!PolygonOverlap.overlaps(square, shifted(20, 20), scale: 10))
        let ell = [
            SIMD2(0.0, 0), SIMD2(10, 0), SIMD2(10, 5), SIMD2(5, 5), SIMD2(5, 10), SIMD2(0, 10),
        ]
        #expect(!PolygonOverlap.overlaps(ell, shifted(6, 6, 3), scale: 10))
        #expect(PolygonOverlap.overlaps(ell, shifted(1, 1, 3), scale: 10))
    }

    @Test("cylinder: caps are opposites, the lateral face has none")
    func cylinder() async throws {
        let cylinder = try #require(Shape.cylinder(radius: 5, height: 12))
        let (result, rows) = try await query(
            cylinder, relations: relations(neighbors: true, opposite: true))
        #expect(!result.isError, "unexpected error: \(result.text)")
        #expect(rows.count == 3)
        for row in rows {
            if row["surfaceType"] as? String == "plane" {
                let opposite = try #require(row["oppositeFace"] as? Row)
                #expect(abs((opposite["distance"] as? Double ?? 0) - 12) < 1e-6)
            } else {
                #expect(row["oppositeFace"] == nil)
            }
        }
    }

    @Test("neighborLimit caps the list but neighborCount stays true")
    func neighborLimit() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        var r = relations(neighbors: true)
        r.neighborLimit = 2
        let (result, rows) = try await query(box, relations: r)
        #expect(!result.isError)
        #expect(rows.count == 6)
        for row in rows {
            #expect((row["neighbors"] as? [Row])?.count == 2)
            #expect(row["neighborCount"] as? Int == 4)
            #expect(row["neighborsTruncated"] as? Bool == true)
        }
    }

    @Test("face-count guard needs a limit or filter, and is overridable")
    func guardBehaviour() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        var r = relations(neighbors: true)
        r.maxUnlimitedFaces = 3
        let refused = try await query(box, relations: r)
        #expect(refused.text.isError && refused.text.text.contains("`limit` or a `filter`"))
        #expect(try await query(box, limit: 3, relations: r).text.isError == false)
        var narrow = IntrospectionTools.TopologyFilter()
        narrow.minArea = 500
        let filtered = try await query(box, filter: narrow, relations: r)
        #expect(!filtered.text.isError && filtered.rows.count == 2)
        r.maxUnlimitedFaces = 10
        #expect(try await query(box, relations: r).rows.count == 6)
    }

    @Test("neighbours and opposites are errors for non-face entities and bad methods")
    func misuse() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let edge = try await query(box, entity: "edge", relations: relations(neighbors: true))
        #expect(edge.text.isError)
        #expect(edge.text.text.contains("face"))
        let method = try await query(box, relations: relations(opposite: true, method: "fuzzy"))
        #expect(method.text.isError)
    }

    @Test("flags off: face rows carry exactly the pre-#199 keys")
    func flagsOff() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let (result, rows) = try await query(box, relations: relations())
        #expect(!result.isError)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? Row)
        #expect(obj["warnings"] == nil)
        #expect(rows.count == 6)
        for row in rows {
            #expect(Set(row.keys) == ["id", "index", "surfaceType", "area", "center", "normal"])
        }
    }

    @Test("neighbors[].index is the faces() index select_topology uses")
    func selectTopologyRoundTrip() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let (store, dir) = try scene(box)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let queried = await IntrospectionTools.queryTopology(
            bodyId: "part", entity: "face", relations: relations(neighbors: true), store: store)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(queried.text.utf8)) as? Row)
        let rows = try #require(obj["results"] as? [Row])
        #expect(rows.count == 6)
        let selected = await SelectionTools.selectTopology(
            bodyId: "part", kind: "face", store: store, registry: SelectionRegistry())
        let selectionObj = try #require(
            try JSONSerialization.jsonObject(with: Data(selected.text.utf8)) as? Row)
        let selections = try #require(selectionObj["selections"] as? [Row])
        for row in rows {
            for n in try #require(row["neighbors"] as? [Row]) {
                let k = try #require(n["index"] as? Int)
                let anchor = try #require(selections[k]["anchor"] as? Row)
                let center = try #require(anchor["center"] as? [Double])
                let expected = vector(try #require(rows.first { index($0) == k }), "center")
                #expect(simd_distance(SIMD3(center[0], center[1], center[2]), expected) < 1e-9)
            }
        }
    }

    // ── shared-face compound (#201) ────────────────────────────────────

    func sharedFaceCompound() throws -> Shape {
        let box = try #require(
            Shape.box(origin: SIMD3(-10, -10, -10), width: 20, height: 20, depth: 20))
        let pieces = try #require(box.split(atPlane: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0)))
        return try #require(Shape.compound(pieces))
    }

    @Test("shared-face compound: adjacency lives in faces() space and merges occurrences")
    func sharedFaceCompoundAdjacency() throws {
        let compound = try sharedFaceCompound()
        let faceCount = compound.faces().count
        #expect(
            compound.orientedFaces().count > faceCount,
            "fixture must share a face, else the two index spaces coincide")
        let graph = FaceAdjacency.faceAdjacency(shape: compound)
        #expect(graph.faceCount == faceCount)
        var seen = Set<[Int]>()
        for pair in graph.pairs {
            #expect(pair.lower < pair.upper && pair.upper < faceCount)
            #expect(seen.insert([pair.lower, pair.upper]).inserted, "pair listed twice")
        }
        let shared = Dictionary(grouping: compound.orientedFaces(), by: \.index)
            .filter { $0.value.count > 1 }.keys
        let wall = try #require(shared.first)
        let neighbours = try #require(graph.neighbours[wall])
        #expect(neighbours.count == 8, "four faces from each solid, merged onto one wall")
        #expect(Set(neighbours.map(\.index)).count == 8 && !neighbours.contains { $0.index == wall })
        #expect(neighbours.allSatisfy { $0.sharedEdgeCount == 1 })
        for n in neighbours {
            #expect(graph.neighbours[n.index]?.contains { $0.index == wall } == true)
        }
    }

    @Test("graph_select bounds-checks against faces().count, not the occurrence count")
    func graphSelectBounds() async throws {
        let compound = try sharedFaceCompound()
        let faceCount = compound.faces().count
        #expect(AAG(shape: compound).nodes.count > faceCount)
        let dir = NSTemporaryDirectory() + "occtmcp-graphselect-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let brep = "\(dir)/c.brep"
        try Exporter.writeBREP(shape: compound, to: URL(fileURLWithPath: brep))

        let past = await AnalysisTools.graphSelect(
            brepPath: brep, query: "face-neighbors", face: faceCount, edge: nil, vertex: nil,
            edgeClass: nil)
        #expect(past.isError && past.text == "face-neighbors requires `face` in 0..<\(faceCount)")

        let adjacency = await AnalysisTools.graphSelect(
            brepPath: brep, query: "face-adjacency", face: nil, edge: nil, vertex: nil,
            edgeClass: nil)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(adjacency.text.utf8)) as? Row)
        #expect(obj["faceCount"] as? Int == faceCount)
        for pair in try #require(obj["adjacencies"] as? [Row]) {
            let a = try #require(pair["face1"] as? Int)
            let b = try #require(pair["face2"] as? Int)
            #expect(a < b && b < faceCount)
        }

        let wall = try #require(
            Dictionary(grouping: compound.orientedFaces(), by: \.index)
                .first { $0.value.count > 1 }?.key)
        let one = await AnalysisTools.graphSelect(
            brepPath: brep, query: "face-neighbors", face: wall, edge: nil, vertex: nil,
            edgeClass: nil)
        let oneObj = try #require(
            try JSONSerialization.jsonObject(with: Data(one.text.utf8)) as? Row)
        #expect((oneObj["neighbors"] as? [Row])?.count == 8)
    }
}
