// VertexFitTools: `measure_vertex_fit` (#118). Exact per-vertex mesh-to-BREP
// distance table, the vertex-fit instrument neither existing distance tool
// provides:
//
//  - `measure_distance` is a body-to-body contact search capped at 32 pairs
//    (all distance 0 for overlapping bodies, useless as a fidelity figure).
//  - `measure_deviation` samples a MESHED tessellation of both bodies and
//    reports aggregate/sectioned statistics; it never returns a raw per-vertex
//    table against the source mesh's OWN vertices, and its distances are
//    approximate (point-to-nearest-triangle on a re-tessellation of the
//    target, not exact BRepExtrema against the target's real geometry).
//  - `find_correspondences` matches only against a target's TOPOLOGICAL
//    vertices (a handful on a typical solid), so most mesh vertices come back
//    "lost."
//  - `add_dimension` measures to a face CENTROID, not the nearest surface
//    point.
//
// A scene body is always stored as BREP (an STL import lands as a facet
// shell, one planar face per triangle, per `import_file`), so "the mesh
// body"'s own corner points are exactly `Shape.vertices()`: no re-meshing is
// needed, and the distances measured are the real BRepExtrema distance from
// each of THOSE points to the target body's real geometry, not a
// re-tessellated approximation. Per vertex: `Shape.vertex(at:)` builds a
// single-point Shape, `.distance(to:)` gets the exact distance, and
// `.distanceSolutionDetail(to:solutionIndex:0)` classifies the nearest
// BREP entity kind (vertex / edge / face) on the target. Entity INDEX
// (which specific face/edge) isn't resolved: `distanceSolutionDetail` only
// returns a parametric location on the entity, not its index, and reverse-
// matching that against every candidate face/edge per vertex would multiply
// the already-per-vertex BRepExtrema cost by the target's face/edge count.
//
// Response is a worst-N summary by default (`worstN`, largest-first), not the
// full per-vertex table: an unbounded per-vertex array is the wrong default
// for a mesh in the thousands of vertices (the same reasoning `measure_distance`
// caps `computeContacts` at 32 and `analyze_clearance` caps its own contact
// list). Pass `includeAllVertices: true` for the full table the way
// `execute_script` would otherwise have to build by hand.

import Foundation
import OCCTSwift
import simd

public enum VertexFitTools {

    public struct VertexFitEntry: Encodable {
        public let index: Int
        public let point: [Double]
        public let distance: Double
        /// Nearest entity kind on `toBodyId`: "vertex" / "edge" / "face".
        public let nearestKind: String
    }

    public struct VertexFitReport: Encodable {
        public let fromBodyId: String
        public let toBodyId: String
        /// Total vertices on `fromBodyId` (`Shape.vertices().count`).
        public let vertexCount: Int
        /// Vertices actually measured, after `maxVertices` stride-subsampling.
        public let sampledCount: Int
        /// 1 = every vertex measured; N = every Nth vertex measured.
        public let stride: Int
        public let mean: Double
        public let rms: Double
        public let max: Double
        public let p95: Double
        /// Worst `worstN` sampled vertices by distance, largest-first.
        public let worst: [VertexFitEntry]
        /// Every sampled vertex, in source order. Present only when
        /// `includeAllVertices: true` was requested.
        public let vertices: [VertexFitEntry]?
        public let warnings: [String]
    }

    public static func measureVertexFit(
        fromBodyId: String,
        toBodyId: String,
        maxVertices: Int = 2000,
        worstN: Int = 20,
        includeAllVertices: Bool = false,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard maxVertices > 0 else {
            return .init("maxVertices must be positive.", isError: true)
        }
        guard worstN >= 0 else {
            return .init("worstN must be non-negative.", isError: true)
        }

        let fromShape: Shape, toShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            toShape = try IntrospectionTools.loadShape(bodyId: toBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        let allVerts = fromShape.vertices()
        let n = allVerts.count
        guard n > 0 else {
            return .init("'\(fromBodyId)' has no vertices to measure.", isError: true)
        }

        let stride = n > maxVertices ? (n + maxVertices - 1) / maxVertices : 1
        var warnings: [String] = []
        if stride > 1 {
            warnings.append(
                "'\(fromBodyId)' has \(n) vertices; stride-subsampled to every \(stride)th one (~\(n / stride) samples) to honour maxVertices=\(maxVertices). Raise maxVertices for full coverage."
            )
        }

        var entries: [VertexFitEntry] = []
        entries.reserveCapacity((n + stride - 1) / stride)
        var failed = 0
        var i = 0
        while i < n {
            defer { i += stride }
            let p = allVerts[i]
            guard let vShape = Shape.vertex(at: p),
                  let distResult = vShape.distance(to: toShape) else {
                failed += 1
                continue
            }
            let kind: String
            if let detail = vShape.distanceSolutionDetail(to: toShape, solutionIndex: 0) {
                switch detail.supportType2 {
                case .vertex: kind = "vertex"
                case .onEdge: kind = "edge"
                case .inFace: kind = "face"
                }
            } else {
                kind = "unknown"
            }
            entries.append(VertexFitEntry(
                index: i, point: [p.x, p.y, p.z], distance: distResult.distance, nearestKind: kind
            ))
        }
        if failed > 0 {
            warnings.append("\(failed) sampled vertex/vertices failed the distance query and were skipped.")
        }
        guard !entries.isEmpty else {
            return .init("Distance computation produced no samples.", isError: true)
        }

        let dists = entries.map(\.distance).sorted()
        let mean = entries.reduce(0.0) { $0 + $1.distance } / Double(entries.count)
        let sumSq = entries.reduce(0.0) { $0 + $1.distance * $1.distance }
        let rms = (sumSq / Double(entries.count)).squareRoot()
        let p95 = DeviationTools.percentile(dists, 0.95)

        let worst = entries.sorted { $0.distance > $1.distance }.prefix(worstN)

        let report = VertexFitReport(
            fromBodyId: fromBodyId, toBodyId: toBodyId,
            vertexCount: n, sampledCount: entries.count, stride: stride,
            mean: mean, rms: rms, max: dists.last ?? 0, p95: p95,
            worst: Array(worst),
            vertices: includeAllVertices ? entries : nil,
            warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }
}
