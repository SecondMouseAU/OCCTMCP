// TopologyIdentityTests (#91): select_topology (SelectionTools.swift)
// used to enumerate shape.faces()/.edges()/.vertices() directly and
// encode the loop index into the selectionId; remap_selection's history
// path (RemapTools.remapViaHistory) reinterprets that same integer as a
// BRepGraph.NodeRef(kind:, index:) index. Nothing previously
// asserted that Shape enumeration order equals BRepGraph(shape:)'s
// own per-kind node index order for the same shape; IntegrationTests
// covered it only incidentally, through whichever scenarios it happened
// to exercise.
//
// It turns out that assumption is FALSE for edges and vertices (true
// only for faces): see `rawEnumerationIndexDivergesFromGraphIndex`
// below, which proves it on a plain box. SelectionTools.graphIndex(...)
// / RemapTools' matching fix now resolve every selectionId's embedded
// index through BRepGraph.findNode(for:) instead of trusting the
// enumeration loop; `graphIndexRoundTripsToGraphNode` verifies that
// resolution is actually correct rather than just present.
//
// Runs fully in-process, no server binary required. Uses a box with
// unequal dimensions so no two faces/edges/vertices share a centroid,
// so a mismatch can't hide behind a tie.

import Foundation
import Testing
import simd
import OCCTSwift
@testable import OCCTMCPCore

@Suite("BRepGraph node-index resolution (#91)")
struct TopologyIdentityTests {

    @Test("select_topology's graphIndex(...) resolves faces/edges/vertices to the correct graph node")
    func graphIndexRoundTripsToGraphNode() throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let graph = try #require(BRepGraph(shape: box))

        for (i, face) in box.faces().enumerated() {
            let faceShape = try #require(Shape.fromFace(face))
            let index = SelectionTools.graphIndex(for: faceShape, kind: .face, in: graph, fallback: i)
            let reconstructed = try #require(graph.shape(nodeKind: .face, nodeIndex: index))
            let a = try #require(reconstructed.centerOfMass)
            let b = try #require(faceShape.centerOfMass)
            #expect(simd_distance(a, b) < 1e-6, "face \(i): graphIndex \(index) doesn't round-trip to the same node")
        }

        for (i, edge) in box.edges().enumerated() {
            let edgeShape = try #require(Shape.fromEdge(edge))
            let index = SelectionTools.graphIndex(for: edgeShape, kind: .edge, in: graph, fallback: i)
            let reconstructed = try #require(graph.shape(nodeKind: .edge, nodeIndex: index))
            let a = try #require(reconstructed.centerOfMass)
            let b = try #require(edgeShape.centerOfMass)
            #expect(simd_distance(a, b) < 1e-6, "edge \(i): graphIndex \(index) doesn't round-trip to the same node")
        }

        for (i, vertexShape) in box.subShapes(ofType: .vertex).enumerated() {
            let index = SelectionTools.graphIndex(for: vertexShape, kind: .vertex, in: graph, fallback: i)
            let reconstructed = try #require(graph.shape(nodeKind: .vertex, nodeIndex: index))
            let a = try #require(reconstructed.centerOfMass)
            let b = try #require(vertexShape.centerOfMass)
            #expect(simd_distance(a, b) < 1e-6, "vertex \(i): graphIndex \(index) doesn't round-trip to the same node")
        }
    }

    @Test("raw Shape enumeration index diverges from the graph's own index for edges/vertices: proves graphIndex(...) isn't a no-op")
    func rawEnumerationIndexDivergesFromGraphIndex() throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let graph = try #require(BRepGraph(shape: box))

        let edgeDivergences = box.edges().enumerated().filter { (i, edge) in
            guard let edgeShape = Shape.fromEdge(edge), let node = graph.findNode(for: edgeShape) else { return false }
            return node.index != i
        }
        #expect(
            !edgeDivergences.isEmpty,
            "expected at least one edge where Shape.edges() order != graph index; if this ever becomes empty, OCCTSwift's edge ordering changed and graphIndex(...)'s fallback path is doing all the work again (worth re-checking, not a real failure)"
        )

        let vertexDivergences = box.subShapes(ofType: .vertex).enumerated().filter { (i, vShape) in
            guard let node = graph.findNode(for: vShape) else { return false }
            return node.index != i
        }
        #expect(
            !vertexDivergences.isEmpty,
            "expected at least one vertex where subShapes(ofType: .vertex) order != graph index; if this ever becomes empty, OCCTSwift's vertex ordering changed (worth re-checking, not a real failure)"
        )
    }

    /// #94: the single-box test above shows FACE order coincidentally
    /// matching graph index order ("apparently by coincidence" per the
    /// header comment); only edges/vertices diverge for a single shell.
    /// A shared face between two shells breaks that coincidence: splitting
    /// a box at its midplane produces two solids that both reference the
    /// SAME cut face (same underlying TShape). `Shape.faces()` walks
    /// solid-by-solid and lists that shared face once per solid (12 total
    /// for two 6-face halves), while `BRepGraph` de-duplicates it into a
    /// single node (11 total, `shellCount == 2`), so the two orderings
    /// can't agree past that point. `SelectionTools.graphIndex(...)` must
    /// still round-trip every enumerated face to the correct graph node
    /// despite the divergence, including both raw-enumeration occurrences
    /// of the shared face landing on the SAME graph node.
    @Test("multi-shell body with a face shared between shells: face enumeration order diverges from graph index order, and graphIndex(...) still resolves correctly")
    func multiShellSharedFaceDivergence() throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let pieces = try #require(box.split(atPlane: SIMD3<Double>(0, 0, 0), normal: SIMD3<Double>(0, 0, 1)))
        #expect(pieces.count == 2)
        let compound = try #require(Shape.compound(pieces))
        let graph = try #require(BRepGraph(shape: compound))

        #expect(graph.shellCount == 2, "expected a two-shell compound; got \(graph.shellCount) shells")
        #expect(
            compound.faces().count != graph.faceCount,
            "expected the shared cut face to be counted twice by raw enumeration (\(compound.faces().count)) but once by the graph (\(graph.faceCount)); if these ever match, the split no longer shares the cut face's TShape and this test needs a different repro"
        )

        let faceDivergences = compound.faces().enumerated().filter { (i, face) in
            guard let faceShape = Shape.fromFace(face), let node = graph.findNode(for: faceShape) else { return false }
            return node.index != i
        }
        #expect(!faceDivergences.isEmpty, "expected at least one face where Shape.faces() order != graph index across the shared-face compound")

        for (i, face) in compound.faces().enumerated() {
            let faceShape = try #require(Shape.fromFace(face))
            let index = SelectionTools.graphIndex(for: faceShape, kind: .face, in: graph, fallback: i)
            let reconstructed = try #require(graph.shape(nodeKind: .face, nodeIndex: index))
            let a = try #require(reconstructed.centerOfMass)
            let b = try #require(faceShape.centerOfMass)
            #expect(simd_distance(a, b) < 1e-6, "compound face \(i): graphIndex \(index) doesn't round-trip to the same node")
        }
    }
}
