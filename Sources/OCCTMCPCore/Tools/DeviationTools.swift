// DeviationTools — surface-deviation between two scene bodies. Where
// `measure_distance` returns the *minimum* gap (≈0 for an overlapping
// reconstruction-vs-source pair, hence useless as a fidelity figure), this
// samples one body's tessellated surface and projects each sample onto the
// other body's triangles to report deviation in each direction.
//
// As of #62 the report is a *vector*, not a lone scalar. A symmetric Hausdorff
// hides systematic shape error — a reconstructed carbody whose cross-section is
// the wrong shape *everywhere* still reads as a small mean, because the correct
// faces dominate the samples and the wrong arc averages out. The fix is to also
// report the **sign** (so a constant proud/shy bias shows up as a non-zero
// `signedMean`), a robust **p95** worst-case, and an optional **per-section**
// signed-mean array along an axis (a near-constant non-zero signedMean across
// the stack is the fingerprint of a systematic section offset).
//
// Mesh-based by design: both bodies are typically meshes (an STL source vs a
// STEP reconstruction), and meshing once + a KD-tree is far cheaper than N
// per-point BRep extrema. Fidelity scales with `deflection`. The per-sample
// distance is exact point-to-triangle; the sign comes from the nearest target
// triangle's outward face normal (OCCT meshes a solid with consistent outward
// winding), so signed distance is + outside the reference (proud / over-build)
// and − inside it (shy / missing material).

import Foundation
import OCCTSwift
import simd

public enum DeviationTools {

    public struct DirectionStat: Encodable {
        /// Worst unsigned distance.
        public let max: Double
        /// Unsigned RMS.
        public let rms: Double
        /// Unsigned mean.
        public let mean: Double
        /// 95th percentile of |distance| — a robust worst-case that an outlier
        /// triangle can't dominate.
        public let p95: Double
        /// Mean of the *signed* distance. ≠ 0 ⇒ a systematic proud (+) / shy (−)
        /// bias — the figure a symmetric Hausdorff throws away.
        public let signedMean: Double
        /// Most-shy (most negative) signed sample — deepest under-build.
        public let signedMin: Double
        /// Most-proud (most positive) signed sample — worst over-build.
        public let signedMax: Double
        public let worstPoint: [Double]
        public let samples: Int
    }

    /// One station of an along-axis section sweep over the forward (from→to)
    /// samples. A near-constant non-zero `signedMean` across stations is the
    /// fingerprint of a systematic section-shape error.
    public struct SectionStat: Encodable {
        /// Offset of the bin centre along the section axis, measured from the
        /// minimum sample projection.
        public let offset: Double
        public let signedMean: Double
        public let rms: Double
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
        /// Forward (from→to) signed samples binned along `sectionAxis`. Present
        /// only when a section axis + count was requested.
        public let sections: [SectionStat]?
    }

    public static func measureDeviation(
        fromBodyId: String,
        toBodyId: String,
        deflection: Double? = nil,
        maxSamples: Int = 20_000,
        sectionAxis: SIMD3<Double>? = nil,
        sectionCount: Int = 0,
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

        guard let (fwd, fwdSamples) = directedStats(source: fromTris, target: toTris, maxSamples: maxSamples) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }
        guard let (rev, _) = directedStats(source: toTris, target: fromTris, maxSamples: maxSamples) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }

        var sections: [SectionStat]? = nil
        if let axis = sectionAxis, sectionCount >= 2, simd_length(axis) > 1e-12 {
            sections = sectionize(samples: fwdSamples, axis: simd_normalize(axis), bins: sectionCount)
        }

        let report = DeviationReport(
            from: fromBodyId,
            to: toBodyId,
            deflection: defl,
            fromToTo: fwd,
            toToFrom: rev,
            symmetricHausdorff: Swift.max(fwd.max, rev.max),
            sections: sections
        )
        return IntrospectionTools.encode(report)
    }

    // ── tessellation snapshot ───────────────────────────────────────────

    /// One sampled source point and its signed distance to the target.
    struct SignedSample {
        let point: SIMD3<Double>
        let signed: Double
    }

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

        /// Outward face normal of triangle `ti` (unit, or zero if degenerate).
        func faceNormal(_ ti: Int) -> SIMD3<Double> {
            let (a, b, c) = triangles[ti]
            let n = simd_cross(vertices[Int(b)] - vertices[Int(a)],
                               vertices[Int(c)] - vertices[Int(a)])
            let len = simd_length(n)
            return len > 1e-18 ? n / len : SIMD3<Double>(0, 0, 0)
        }
    }

    // ── directed deviation: source samples → nearest point on target ─────

    /// Directed deviation with sign. Returns the aggregate `DirectionStat` plus
    /// the per-sample signed list (for sectioning / histograms).
    static func directedStats(source: TriMesh, target: TriMesh, maxSamples: Int)
        -> (DirectionStat, [SignedSample])?
    {
        let n = source.vertices.count
        guard n > 0 else { return nil }
        // Stride-subsample the source vertices to honour the sample cap.
        let stride = maxSamples > 0 ? Swift.max(1, (n + maxSamples - 1) / maxSamples) : 1
        let k = 6                      // candidate target vertices per query
        // Reused stamp array dedups incident triangles across the k candidates.
        var stamp = [Int](repeating: -1, count: target.triangles.count)

        var samples: [SignedSample] = []
        samples.reserveCapacity((n + stride - 1) / stride)
        var dists: [Double] = []
        dists.reserveCapacity(samples.capacity)

        var maxD = 0.0
        var sumSq = 0.0
        var sum = 0.0
        var signedSum = 0.0
        var signedMin = Double.greatestFiniteMagnitude
        var signedMax = -Double.greatestFiniteMagnitude
        var worst = SIMD3<Double>(0, 0, 0)

        var i = 0
        while i < n {
            let p = source.vertices[i]
            if let hit = signedQuery(p, target: target, k: k, stamp: &stamp, stampToken: i) {
                let signed = hit.distance
                let d = abs(signed)
                if d > maxD { maxD = d; worst = p }
                sumSq += d * d
                sum += d
                signedSum += signed
                if signed < signedMin { signedMin = signed }
                if signed > signedMax { signedMax = signed }
                dists.append(d)
                samples.append(SignedSample(point: p, signed: signed))
            }
            i += stride
        }

        let count = samples.count
        guard count > 0 else { return nil }
        dists.sort()
        let stat = DirectionStat(
            max: maxD,
            rms: (sumSq / Double(count)).squareRoot(),
            mean: sum / Double(count),
            p95: percentile(dists, 0.95),
            signedMean: signedSum / Double(count),
            signedMin: signedMin == .greatestFiniteMagnitude ? 0 : signedMin,
            signedMax: signedMax == -.greatestFiniteMagnitude ? 0 : signedMax,
            worstPoint: [worst.x, worst.y, worst.z],
            samples: count
        )
        return (stat, samples)
    }

    /// Result of a signed-distance query: the signed distance itself, plus
    /// whether the SIGN is trustworthy.
    ///
    /// The sign comes from a single "winning" nearest triangle's face normal.
    /// Against an open, thin-walled reference (both an outer skin and an inner
    /// wall a small gap apart — the raw-scan/STL-skin case in #72) the winner
    /// can be either surface depending on sub-deflection noise, so the sign
    /// flips per-sample with no real positional meaning even though the
    /// *magnitude* stays correct. `ambiguous` is set when another candidate
    /// triangle comparably close to the winner disagrees on which side of the
    /// surface `p` sits — callers should grey out / exclude the sign channel
    /// (not the magnitude) wherever this is true.
    struct SignedHit {
        let distance: Double
        let ambiguous: Bool
    }

    /// Signed distance from `p` to the target surface, using a shared `stamp`
    /// array for incident-triangle dedup across the k nearest candidates.
    /// `stampToken` must be unique per query (the source sample index works).
    static func signedQuery(
        _ p: SIMD3<Double>, target: TriMesh, k: Int,
        stamp: inout [Int], stampToken: Int
    ) -> SignedHit? {
        var best = Double.greatestFiniteMagnitude
        var bestClosest = SIMD3<Double>(0, 0, 0)
        var bestTri = -1
        // Every candidate triangle's (distance, side) — used below to check
        // whether comparably-close candidates agree with the winner's sign.
        var candidates: [(distance: Double, positive: Bool)] = []

        let neighbours = target.kd.kNearest(to: p, k: k)
        if neighbours.isEmpty {
            if let nv = target.kd.nearest(to: p) {
                // No triangle context — report unsigned (sign 0).
                return SignedHit(distance: nv.distance, ambiguous: false)
            }
            return nil
        }
        for (vi, _) in neighbours {
            for ti in target.incident[vi] where stamp[ti] != stampToken {
                stamp[ti] = stampToken
                let (a, b, c) = target.triangles[ti]
                let cp = closestPointOnTriangle(p, target.vertices[Int(a)],
                                                target.vertices[Int(b)],
                                                target.vertices[Int(c)])
                let d = simd_length(p - cp)
                let positive = simd_dot(p - cp, target.faceNormal(ti)) >= 0
                candidates.append((d, positive))
                if d < best { best = d; bestClosest = cp; bestTri = ti }
            }
        }
        if bestTri < 0 {
            // Nearest vertex had no incident triangles (isolated) — fall back.
            if let nv = target.kd.nearest(to: p) { return SignedHit(distance: nv.distance, ambiguous: false) }
            return nil
        }
        let nrm = target.faceNormal(bestTri)
        let side = simd_dot(p - bestClosest, nrm) >= 0
        let signedDist = side ? best : -best

        // Tie band: candidates within 15% of the winning distance are "comparably
        // close" — if any of them disagree on side, the winner was a coin flip.
        let tieBand = best * 1.15 + 1e-9
        let ambiguous = candidates.contains { $0.distance <= tieBand && $0.positive != side }

        return SignedHit(distance: signedDist, ambiguous: ambiguous)
    }

    /// Per-vertex signed-distance field for an arbitrary mesh's vertices against
    /// a reference `TriMesh`. Used by the heatmap (per-triangle centroid) and the
    /// histogram. No subsampling — every supplied point is queried.
    static func signedDistances(of points: [SIMD3<Double>], to target: TriMesh) -> [SignedHit] {
        var stamp = [Int](repeating: -1, count: target.triangles.count)
        var out = [SignedHit](repeating: SignedHit(distance: 0, ambiguous: false), count: points.count)
        for (i, p) in points.enumerated() {
            if let hit = signedQuery(p, target: target, k: 6, stamp: &stamp, stampToken: i) {
                out[i] = hit
            }
        }
        return out
    }

    // ── per-section binning ──────────────────────────────────────────────

    /// Bin forward samples by their projection onto `axis` (unit) into `bins`
    /// equal-width stations, reporting per-station signed-mean / RMS.
    static func sectionize(samples: [SignedSample], axis: SIMD3<Double>, bins: Int) -> [SectionStat] {
        guard !samples.isEmpty, bins >= 2 else { return [] }
        var ts = [Double](repeating: 0, count: samples.count)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for (i, s) in samples.enumerated() {
            let t = simd_dot(s.point, axis)
            ts[i] = t
            if t < lo { lo = t }
            if t > hi { hi = t }
        }
        let span = hi - lo
        guard span > 1e-12 else { return [] }
        let width = span / Double(bins)

        var signedSum = [Double](repeating: 0, count: bins)
        var sqSum = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        for (i, s) in samples.enumerated() {
            var b = Int((ts[i] - lo) / width)
            if b >= bins { b = bins - 1 }
            if b < 0 { b = 0 }
            signedSum[b] += s.signed
            sqSum[b] += s.signed * s.signed
            counts[b] += 1
        }

        var out: [SectionStat] = []
        out.reserveCapacity(bins)
        for b in 0..<bins where counts[b] > 0 {
            let c = Double(counts[b])
            out.append(SectionStat(
                offset: (Double(b) + 0.5) * width,
                signedMean: signedSum[b] / c,
                rms: (sqSum[b] / c).squareRoot(),
                samples: counts[b]
            ))
        }
        return out
    }

    // ── geometry helpers ────────────────────────────────────────────────

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[Swift.min(Swift.max(idx, 0), sorted.count - 1)]
    }

    static func defaultDeflection(for shape: Shape) -> Double {
        let b = shape.bounds
        let diag = simd_length(b.max - b.min)
        // 0.5% of the diagonal, with a 1µm floor for degenerate/tiny shapes.
        return Swift.max(diag * 0.005, 1e-6)
    }

    /// Closest point on triangle (a,b,c) to `p`.
    /// Ericson "Real-Time Collision Detection" §5.1.5.
    static func closestPointOnTriangle(
        _ p: SIMD3<Double>,
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>
    ) -> SIMD3<Double> {
        let ab = b - a
        let ac = c - a
        let ap = p - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }                               // vertex A

        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }                              // vertex B

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {                                // edge AB
            let v = d1 / (d1 - d3)
            return a + v * ab
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }                              // vertex C

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {                                // edge AC
            let w = d2 / (d2 - d6)
            return a + w * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {                  // edge BC
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + w * (c - b)
        }

        // Interior — barycentric projection onto the triangle plane.
        let denom = 1.0 / (va + vb + vc)
        let v = vb * denom
        let w = vc * denom
        return a + ab * v + ac * w
    }

    /// Exact distance from point `p` to triangle (a,b,c). Retained for callers
    /// that only need the magnitude.
    static func pointTriangleDistance(
        _ p: SIMD3<Double>,
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>
    ) -> Double {
        simd_length(p - closestPointOnTriangle(p, a, b, c))
    }
}
