// DeviationTools — surface-deviation (one-sided / symmetric Hausdorff) between
// two scene bodies. Where `measure_distance` returns the *minimum* gap (≈0 for
// an overlapping reconstruction-vs-source pair, hence useless as a fidelity
// figure), this samples one body's tessellated surface and projects each sample
// onto the other body's triangles to report the *worst* and RMS deviation in
// each direction. This is the metric a mesh→analytic reconstruction check needs
// (OCCTMCP #41): fromToTo surfaces departing from `to` (over-extension), and
// toToFrom (missing material / under-coverage).
//
// Mesh-based by design: both bodies are typically meshes (an STL source vs a
// STEP reconstruction), and meshing once + a KD-tree is far cheaper than N
// per-point BRep extrema. Fidelity scales with `deflection` — a finer mesh
// tightens the bound. The per-sample distance is exact point-to-triangle, so
// the only approximation is the tessellation itself, not nearest-vertex.

import Foundation
import OCCTSwift
import simd

public enum DeviationTools {

    public struct DirectionStat: Encodable {
        public let max: Double
        public let rms: Double
        public let mean: Double
        public let worstPoint: [Double]
        public let samples: Int
    }

    public struct DeviationReport: Encodable {
        public let from: String
        public let to: String
        public let deflection: Double
        /// Deviation of `from`'s surface measured against `to` (over-extension).
        public let fromToTo: DirectionStat
        /// Deviation of `to`'s surface measured against `from` (under-coverage).
        public let toToFrom: DirectionStat
        /// max(fromToTo.max, toToFrom.max) — the symmetric Hausdorff distance.
        public let symmetricHausdorff: Double
    }

    public static func measureDeviation(
        fromBodyId: String,
        toBodyId: String,
        deflection: Double? = nil,
        maxSamples: Int = 20_000,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let fromShape: Shape, toShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            toShape = try IntrospectionTools.loadShape(bodyId: toBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        // Default deflection scales with the model so the bound is meaningful
        // regardless of units/size: 0.5% of the `from` bbox diagonal, floored.
        let defl = deflection ?? defaultDeflection(for: fromShape)
        guard defl > 0 else {
            return .init("deflection must be positive.", isError: true)
        }

        guard let fromTris = TriMesh(shape: fromShape, deflection: defl) else {
            return .init("Failed to tessellate '\(fromBodyId)' for deviation.", isError: true)
        }
        guard let toTris = TriMesh(shape: toShape, deflection: defl) else {
            return .init("Failed to tessellate '\(toBodyId)' for deviation.", isError: true)
        }

        guard let fwd = directedDeviation(source: fromTris, target: toTris, maxSamples: maxSamples) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }
        guard let rev = directedDeviation(source: toTris, target: fromTris, maxSamples: maxSamples) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }

        let report = DeviationReport(
            from: fromBodyId,
            to: toBodyId,
            deflection: defl,
            fromToTo: fwd,
            toToFrom: rev,
            symmetricHausdorff: Swift.max(fwd.max, rev.max)
        )
        return IntrospectionTools.encode(report)
    }

    // ── tessellation snapshot ───────────────────────────────────────────

    /// Double-precision triangle soup + a KD-tree over vertices, with a
    /// vertex→incident-triangle adjacency for exact point-to-triangle queries.
    struct TriMesh {
        let vertices: [SIMD3<Double>]
        let triangles: [(UInt32, UInt32, UInt32)]
        let kd: KDTree
        let incident: [[Int]]   // vertexIndex → triangle indices

        init?(shape: Shape, deflection: Double) {
            var params = MeshParameters.default
            params.deflection = deflection
            params.internalVertices = true
            params.inParallel = true
            // Re-meshing keeps an existing finer/coarser triangulation unless we
            // allow it to be replaced, so the requested deflection actually takes
            // effect on an already-tessellated import (OCCTSwift #211).
            params.allowQualityDecrease = true
            guard let mesh = shape.mesh(parameters: params) else { return nil }

            let verts = mesh.vertices.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            let idx = mesh.indices
            guard !verts.isEmpty, idx.count >= 3, let kd = KDTree(points: verts) else { return nil }

            var tris: [(UInt32, UInt32, UInt32)] = []
            tris.reserveCapacity(idx.count / 3)
            var adj = [[Int]](repeating: [], count: verts.count)
            var t = 0
            while t + 2 < idx.count {
                let a = idx[t], b = idx[t + 1], c = idx[t + 2]
                let ti = tris.count
                tris.append((a, b, c))
                adj[Int(a)].append(ti)
                adj[Int(b)].append(ti)
                adj[Int(c)].append(ti)
                t += 3
            }
            self.vertices = verts
            self.triangles = tris
            self.kd = kd
            self.incident = adj
        }
    }

    // ── directed deviation: source samples → nearest point on target ─────

    static func directedDeviation(source: TriMesh, target: TriMesh, maxSamples: Int) -> DirectionStat? {
        let n = source.vertices.count
        guard n > 0 else { return nil }
        // Stride-subsample the source vertices to honour the sample cap.
        let stride = maxSamples > 0 ? Swift.max(1, (n + maxSamples - 1) / maxSamples) : 1
        let k = 6                      // candidate target vertices per query

        var maxD = 0.0
        var sumSq = 0.0
        var sum = 0.0
        var count = 0
        var worst = SIMD3<Double>(0, 0, 0)
        // Reused stamp array dedups incident triangles across the k candidates.
        var stamp = [Int](repeating: -1, count: target.triangles.count)

        var i = 0
        while i < n {
            let p = source.vertices[i]
            var best = Double.greatestFiniteMagnitude

            let neighbours = target.kd.kNearest(to: p, k: k)
            if neighbours.isEmpty {
                // Degenerate target KD result — fall back to nearest vertex.
                if let nv = target.kd.nearest(to: p) { best = nv.distance }
            } else {
                for (vi, _) in neighbours {
                    for ti in target.incident[vi] where stamp[ti] != i {
                        stamp[ti] = i
                        let (a, b, c) = target.triangles[ti]
                        let d = pointTriangleDistance(
                            p,
                            target.vertices[Int(a)],
                            target.vertices[Int(b)],
                            target.vertices[Int(c)]
                        )
                        if d < best { best = d }
                    }
                }
                // A nearest vertex with no incident triangles (isolated) — guard.
                if best == .greatestFiniteMagnitude, let nv = target.kd.nearest(to: p) {
                    best = nv.distance
                }
            }

            if best != .greatestFiniteMagnitude {
                if best > maxD { maxD = best; worst = p }
                sumSq += best * best
                sum += best
                count += 1
            }
            i += stride
        }

        guard count > 0 else { return nil }
        return DirectionStat(
            max: maxD,
            rms: (sumSq / Double(count)).squareRoot(),
            mean: sum / Double(count),
            worstPoint: [worst.x, worst.y, worst.z],
            samples: count
        )
    }

    // ── geometry helpers ────────────────────────────────────────────────

    static func defaultDeflection(for shape: Shape) -> Double {
        let b = shape.bounds
        let diag = simd_length(b.max - b.min)
        // 0.5% of the diagonal, with a 1µm floor for degenerate/tiny shapes.
        return Swift.max(diag * 0.005, 1e-6)
    }

    /// Exact distance from point `p` to triangle (a,b,c).
    /// Closest-point-on-triangle, Ericson "Real-Time Collision Detection" §5.1.5.
    static func pointTriangleDistance(
        _ p: SIMD3<Double>,
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>
    ) -> Double {
        let ab = b - a
        let ac = c - a
        let ap = p - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length(ap) }                 // vertex A

        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length(bp) }                // vertex B

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {                                // edge AB
            let v = d1 / (d1 - d3)
            return simd_length(p - (a + v * ab))
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length(cp) }                // vertex C

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {                                // edge AC
            let w = d2 / (d2 - d6)
            return simd_length(p - (a + w * ac))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {                  // edge BC
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length(p - (b + w * (c - b)))
        }

        // Interior — barycentric projection onto the triangle plane.
        let denom = 1.0 / (va + vb + vc)
        let v = vb * denom
        let w = vc * denom
        return simd_length(p - (a + ab * v + ac * w))
    }
}
