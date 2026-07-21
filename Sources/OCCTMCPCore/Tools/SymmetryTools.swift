// SymmetryTools — `detect_symmetry` (Phase 2 of the mesh-analysis
// expansion). PCA candidate mirror planes, verified with the existing
// signed-distance engine (DeviationTools) — pure MCP-side composition, no
// new OCCTSwiftMesh surface needed. Rotational/axis symmetry detection is
// deferred (see the tool's own description): this covers reflective
// (mirror-plane) symmetry only.
//
// Pipeline: mesh -> DeviationTools.TriMesh -> area-weighted centroid + the
// 3 eigenvectors of the area-weighted covariance of triangle centroids (a
// small symmetric-3x3 Jacobi solver, `symmetricEigen3x3` below — this
// tool is the first caller that needs all THREE principal axes;
// `ZoneSweepTool.principalAxis` only returns the dominant one via power
// iteration, which doesn't generalise to "give me all three"). Each
// eigenvector becomes a candidate mirror plane through the centroid.
//
// Verification: for each candidate, stride-subsample vertices (same
// maxSamples convention as DeviationTools.directedStats), reflect each
// across the plane, and measure its UNSIGNED nearest distance back to the
// mesh's OWN surface via `DeviationTools.signedQuery(..., signMode:
// .nearest)` — `.nearest` mode never engages the normal-compatibility gate
// (#72), so `.nearest` on the returned hit is always the honest closest-
// surface distance, exactly the "unsigned nearest distance" this needs.
// rms/p95/max of that per-candidate distance set is the residual; a
// candidate is `symmetric` when p95 <= toleranceMm.

import Foundation
import OCCTSwift
import simd
import ScriptHarness

public enum SymmetryTools {

    public struct SymmetryReport: Encodable {
        public let bodyId: String
        public let toleranceMm: Double
        public let samples: Int
        public let candidates: [CandidateEntry]
        public let bestPlane: CandidateEntry?
        public let warnings: [String]

        public struct CandidateEntry: Encodable {
            public let point: [Double]
            public let normal: [Double]
            public let rmsMm: Double
            public let p95Mm: Double
            public let maxMm: Double
            public let symmetric: Bool
        }
    }

    @MainActor
    public static func detectSymmetry(
        bodyId: String,
        maxSamples: Int = 2000,
        toleranceMm: Double = 0.5,
        deflection: Double? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        let defl = deflection ?? DeviationTools.defaultDeflection(for: shape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }
        guard maxSamples > 0 else { return .init("maxSamples must be positive.", isError: true) }
        guard toleranceMm >= 0 else { return .init("toleranceMm must be >= 0.", isError: true) }

        guard let tri = DeviationTools.TriMesh(shape: shape, deflection: defl) else {
            return .init("Failed to tessellate '\(bodyId)' for symmetry detection.", isError: true)
        }
        guard !tri.triangles.isEmpty else {
            return .init("'\(bodyId)' has no triangles to analyse.", isError: true)
        }

        // Area-weighted centroid of the triangle soup.
        var centroid = SIMD3<Double>(0, 0, 0)
        var totalArea = 0.0
        for (a, b, c) in tri.triangles {
            let pa = tri.vertices[Int(a)], pb = tri.vertices[Int(b)], pc = tri.vertices[Int(c)]
            let area = 0.5 * simd_length(simd_cross(pb - pa, pc - pa))
            centroid += (pa + pb + pc) / 3 * area
            totalArea += area
        }
        guard totalArea > 1e-12 else {
            return .init("'\(bodyId)' has zero surface area (degenerate mesh); cannot fit principal axes.", isError: true)
        }
        centroid /= totalArea

        // Area-weighted covariance about that centroid, then its
        // eigen-decomposition — the 3 principal axes.
        //
        // Each triangle's EXACT contribution to ∫∫(p-centroid)(p-centroid)ᵀ dA
        // is (area/12)·(9·m⊗m + A⊗A + B⊗B + C⊗C), where A/B/C are its own
        // (centroid-shifted) vertices and m = (A+B+C)/3 (a standard closed
        // form for a flat triangle's second moment, e.g. used for OBB
        // covariance in Gottschalk/Lin/Manocha "OBBTree" 1996; verified here
        // against a direct analytic double integral on a reference triangle).
        // Treating each triangle as a single POINT MASS at its own centroid
        // (the naive shortcut) is only a coarse approximation and is wrong
        // enough to matter on a low-triangle-count mesh: a box face split
        // into just 2 large triangles by one diagonal produces spurious
        // non-zero cross terms from that approximation alone (~1/4 of the
        // true diagonal terms in the box unit-test fixture below), enough to
        // rotate the "principal axes" well off the box's real (and exact)
        // coordinate-aligned symmetry planes.
        var cxx = 0.0, cxy = 0.0, cxz = 0.0, cyy = 0.0, cyz = 0.0, czz = 0.0
        func accumulate(_ p: SIMD3<Double>, weight: Double) {
            cxx += weight * p.x * p.x; cxy += weight * p.x * p.y; cxz += weight * p.x * p.z
            cyy += weight * p.y * p.y; cyz += weight * p.y * p.z; czz += weight * p.z * p.z
        }
        for (a, b, c) in tri.triangles {
            let pa = tri.vertices[Int(a)] - centroid
            let pb = tri.vertices[Int(b)] - centroid
            let pc = tri.vertices[Int(c)] - centroid
            let area = 0.5 * simd_length(simd_cross(pb - pa, pc - pa))
            guard area > 1e-15 else { continue }
            let w = area / 12.0
            accumulate((pa + pb + pc) / 3, weight: w * 9)
            accumulate(pa, weight: w)
            accumulate(pb, weight: w)
            accumulate(pc, weight: w)
        }
        let (_, axes) = symmetricEigen3x3(xx: cxx, xy: cxy, xz: cxz, yy: cyy, yz: cyz, zz: czz)

        // Stride-subsample vertices for verification (mirrors
        // DeviationTools.directedStats' maxSamples convention).
        let n = tri.vertices.count
        let stride = max(1, (n + maxSamples - 1) / maxSamples)
        var sampleIndices: [Int] = []
        sampleIndices.reserveCapacity((n + stride - 1) / stride)
        var vi = 0
        while vi < n { sampleIndices.append(vi); vi += stride }

        var warnings: [String] = []
        var candidateEntries: [SymmetryReport.CandidateEntry] = []
        for axis in axes {
            guard simd_length(axis) > 1e-9 else {
                warnings.append("A degenerate principal axis (zero-length eigenvector) was skipped.")
                continue
            }
            let unitAxis = simd_normalize(axis)
            var stamp = [Int](repeating: -1, count: tri.triangles.count)
            var dists: [Double] = []
            dists.reserveCapacity(sampleIndices.count)
            for (token, idx) in sampleIndices.enumerated() {
                let p = tri.vertices[idx]
                let reflected = p - 2 * simd_dot(p - centroid, unitAxis) * unitAxis
                if let hit = DeviationTools.signedQuery(
                    reflected, normal: nil, target: tri, k: 6,
                    stamp: &stamp, stampToken: token, signMode: .nearest
                ) {
                    dists.append(hit.nearest)
                }
            }
            guard !dists.isEmpty else {
                warnings.append("Candidate plane with normal [\(fmt(unitAxis))] produced no comparable samples; skipped.")
                continue
            }
            let sorted = dists.sorted()
            let rms = (dists.reduce(0) { $0 + $1 * $1 } / Double(dists.count)).squareRoot()
            let p95 = DeviationTools.percentile(sorted, 0.95)
            let maxD = sorted.last!
            candidateEntries.append(.init(
                point: [centroid.x, centroid.y, centroid.z],
                normal: [unitAxis.x, unitAxis.y, unitAxis.z],
                rmsMm: rms, p95Mm: p95, maxMm: maxD,
                symmetric: p95 <= toleranceMm
            ))
        }

        let sortedCandidates = candidateEntries.sorted { $0.p95Mm < $1.p95Mm }
        let bestPlane = sortedCandidates.first(where: \.symmetric)

        let report = SymmetryReport(
            bodyId: bodyId, toleranceMm: toleranceMm, samples: sampleIndices.count,
            candidates: sortedCandidates, bestPlane: bestPlane, warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }

    private static func fmt(_ v: SIMD3<Double>) -> String {
        String(format: "%.3g, %.3g, %.3g", v.x, v.y, v.z)
    }

    // MARK: - Symmetric 3x3 eigen-decomposition

    /// Classic cyclic Jacobi eigen-decomposition of a symmetric 3x3 matrix
    /// (given by its upper triangle). Each sweep zeroes the largest
    /// remaining off-diagonal entry via an explicit Givens rotation
    /// (`A' = GᵀAG`, `V' = VG`); a few dozen sweeps is always enough for a
    /// fixed 3x3 — no Accelerate dependency needed for a matrix this small.
    ///
    /// Returns eigenvalues and their unit eigenvectors, sorted by
    /// eigenvalue DESCENDING (largest-spread axis first). The eigenvectors
    /// are mutually orthonormal by construction (V accumulates as a
    /// product of orthogonal rotations).
    static func symmetricEigen3x3(xx: Double, xy: Double, xz: Double, yy: Double, yz: Double, zz: Double)
        -> (values: SIMD3<Double>, vectors: [SIMD3<Double>])
    {
        var a: [[Double]] = [[xx, xy, xz], [xy, yy, yz], [xz, yz, zz]]
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

        func matMul(_ x: [[Double]], _ y: [[Double]]) -> [[Double]] {
            var r = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    var s = 0.0
                    for k in 0..<3 { s += x[i][k] * y[k][j] }
                    r[i][j] = s
                }
            }
            return r
        }
        func transpose(_ x: [[Double]]) -> [[Double]] {
            var r = x
            for i in 0..<3 { for j in 0..<3 { r[i][j] = x[j][i] } }
            return r
        }

        for _ in 0..<60 {
            var p = 0, q = 1, best = abs(a[0][1])
            if abs(a[0][2]) > best { best = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > best { best = abs(a[1][2]); p = 1; q = 2 }
            if best < 1e-13 { break }

            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            // The rotation angle that zeroes a[p][q]: the standard
            // Numerical-Recipes (theta -> t -> c,s) form, numerically stable
            // as apq -> 0 (t -> 0 smoothly regardless of apq's sign, unlike
            // computing phi = 0.5*atan2(...) and taking cos/sin of it
            // directly, which can be unstable exactly at that limit).
            //
            // This pairs with a SPECIFIC placement of s in the rotation
            // matrix G below (g[p][q] = +s, g[q][p] = -s): for
            // A' = GᵀAG, that placement's off-diagonal term works out to
            // (app-aqq)·sc + apq·(c²-s²), whose zero condition is
            // tan(2θ) = 2apq/(aqq-app) = cot(2θ)⁻¹ where θ = atan(t) — i.e.
            // exactly the θ this formula solves for. The other placement
            // (g[p][q] = -s, g[q][p] = +s) needs the OPPOSITE-sign angle
            // formula; pairing this θ with that placement zeroes nothing
            // and instead makes a[p][q] grow (verified by a box unit test
            // that diverged, doubling a[p][q] every sweep, before this
            // placement was corrected to match).
            let theta = (aqq - app) / (2 * apq)
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1.0 / (t * t + 1).squareRoot()
            let s = t * c

            var g = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
            g[p][p] = c; g[q][q] = c; g[p][q] = s; g[q][p] = -s

            a = matMul(matMul(transpose(g), a), g)
            v = matMul(v, g)
        }

        let idx = [0, 1, 2].sorted { a[$0][$0] > a[$1][$1] }
        let values = SIMD3(a[idx[0]][idx[0]], a[idx[1]][idx[1]], a[idx[2]][idx[2]])
        let vectors = idx.map { i -> SIMD3<Double> in
            let raw = SIMD3(v[0][i], v[1][i], v[2][i])
            let len = simd_length(raw)
            return len > 1e-12 ? raw / len : SIMD3<Double>(0, 0, 0)
        }
        return (values, vectors)
    }
}
