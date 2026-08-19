// EdgeChainMath: pure geometry backing `fit_edge_chain` (#121). No OCCT / MCP
// dependency, directly unit-testable on synthetic point arrays, mirroring the
// "pure, geometry-free function" split ProfileMath and ZoneSweepTool's
// detectRunsAndDeviations already established in this codebase.
//
// A raw STL has no curved edges by construction: an arc exists on the mesh
// only as a FIT over a chain of straight facet edges (a crease ring's own
// `vertexIndices`, or any other ordered 3D point chain the caller supplies,
// e.g. from `detect_mesh_features(includePoints: true)`). This segments such
// a chain into line and circular-arc runs.
//
// Line fit: least squares via PCA (centroid + the covariance's DOMINANT
// eigenvector, `SymmetryTools.symmetricEigen3x3`'s index 0). Arc fit: the
// points are first fit to a plane (centroid + the covariance's SMALLEST
// eigenvector, index 2, the least-variance direction of a near-planar point
// set), projected into that plane, then fit to a 2D circle via the classic
// Kasa algebraic least-squares fit on CENTERED coordinates (better
// conditioned than the raw 3-parameter linear system). Both reuse the same
// eigensolver `SymmetryTools` already established for exactly this "give me
// the covariance's principal axes" need, rather than a second Jacobi solver.
//
// Segmentation: a greedy maximal-run grower, the same "keep the frozen
// reference and extend while within tolerance" shape ZoneSweepTool's
// `detectRunsAndDeviations` uses for a different (1D station) problem. Grow a
// window one point at a time; a window still fits as long as EITHER a line OR
// an arc fits every point in it within `toleranceMm`; stop and emit a segment
// at the last point that still fit, then start the next segment there (shared
// endpoint, so segments chain without a gap). Multi-radius chains are exactly
// what forces a new segment: once the current arc's radius no longer explains
// the next point within tolerance, growth stops and a fresh arc fit takes
// over from there, catching the "single-circle-only fit collapses two real
// radii into one" failure #121 was filed against.

import Foundation
import simd

enum EdgeChainMath {

    struct LineFit {
        /// A point on the fitted line (the window's centroid).
        let point: SIMD3<Double>
        /// Unit direction, oriented from the window's first point toward its
        /// last (PCA's own eigenvector sign is otherwise arbitrary).
        let direction: SIMD3<Double>
        let maxResidual: Double
        let rmsResidual: Double
    }

    struct ArcFit {
        let center: SIMD3<Double>
        /// Unit normal of the arc's plane.
        ///
        /// WHICH of the two possible normal
        /// directions is picked is still arbitrary (inherent to the
        /// eigenvector recovery, the same caveat `AlignTools`/slippage
        /// classification's own `axisDirection` document elsewhere in this
        /// codebase), but it is chosen consistently with `startAngle`/
        /// `endAngle` below: rotating from `startAngle` to `endAngle` about
        /// `axis` by the right-hand rule always traces the arc in the
        /// chain's own point order (0 -> N), never backwards.
        let axis: SIMD3<Double>
        let radius: Double
        /// Unwrapped angles (radians) of the window's first/last point about
        /// `center` in the fitted plane, normalised so `endAngle > startAngle`
        /// always (their difference is the swept angle, matching the chain's
        /// own traversal direction, see `axis` above) even across the atan2
        /// branch cut.
        let startAngle: Double
        let endAngle: Double
        let maxResidual: Double
        let rmsResidual: Double
    }

    enum Fit {
        case line(LineFit)
        case arc(ArcFit)

        var maxResidual: Double {
            switch self {
            case .line(let f): return f.maxResidual
            case .arc(let f): return f.maxResidual
            }
        }
        var rmsResidual: Double {
            switch self {
            case .line(let f): return f.rmsResidual
            case .arc(let f): return f.rmsResidual
            }
        }
    }

    struct Segment {
        let startIndex: Int
        let endIndex: Int
        let fit: Fit
    }

    // MARK: - Fitting primitives

    static func centroid(_ points: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !points.isEmpty else { return .zero }
        var c = SIMD3<Double>.zero
        for p in points { c += p }
        return c / Double(points.count)
    }

    private static func covariance(_ points: [SIMD3<Double>], about c: SIMD3<Double>)
        -> (xx: Double, xy: Double, xz: Double, yy: Double, yz: Double, zz: Double)
    {
        var xx = 0.0
        var xy = 0.0
        var xz = 0.0
        var yy = 0.0
        var yz = 0.0
        var zz = 0.0
        for p in points {
            let d = p - c
            xx += d.x * d.x
            xy += d.x * d.y
            xz += d.x * d.z
            yy += d.y * d.y
            yz += d.y * d.z
            zz += d.z * d.z
        }
        return (xx, xy, xz, yy, yz, zz)
    }

    /// Least-squares line through `points`.
    ///
    /// Needs >= 2 points.
    static func fitLine(_ points: [SIMD3<Double>]) -> LineFit? {
        guard points.count >= 2 else { return nil }
        let c = centroid(points)
        let cov = covariance(points, about: c)
        let eig = SymmetryTools.symmetricEigen3x3(
            xx: cov.xx, xy: cov.xy, xz: cov.xz, yy: cov.yy, yz: cov.yz, zz: cov.zz)
        var dir = eig.vectors[0]
        // fully degenerate (all points coincident)
        guard simd_length(dir) > 1e-12 else { return nil }
        let chainDir = points[points.count - 1] - points[0]
        if simd_dot(dir, chainDir) < 0 { dir = -dir }

        var maxR = 0.0
        var sumSq = 0.0
        for p in points {
            let d = p - c
            let perp = d - simd_dot(d, dir) * dir
            let r = simd_length(perp)
            if r > maxR { maxR = r }
            sumSq += r * r
        }
        return LineFit(
            point: c, direction: dir, maxResidual: maxR,
            rmsResidual: (sumSq / Double(points.count)).squareRoot())
    }

    /// Least-squares circular arc through `points` (plane fit + 2D Kasa
    /// circle fit in-plane).
    ///
    /// Needs >= 3 points.
    static func fitArc(_ points: [SIMD3<Double>]) -> ArcFit? {
        guard points.count >= 3 else { return nil }
        let c = centroid(points)
        let cov = covariance(points, about: c)
        let eig = SymmetryTools.symmetricEigen3x3(
            xx: cov.xx, xy: cov.xy, xz: cov.xz, yy: cov.yy, yz: cov.yz, zz: cov.zz)

        // An orthonormal in-plane basis: eig.vectors[0]/[1] (the two largest-
        // variance directions) already span a near-planar point set's plane,
        // and are mutually orthonormal (Jacobi's V accumulates as a product
        // of orthogonal rotations). `axis` (below) is DERIVED as u x v rather
        // than taken from eig.vectors[2] directly, specifically so it stays
        // consistent with whichever v ends up used after the sign flip below
        // (eig.vectors[2] has no such guarantee: its sign is independently
        // arbitrary).
        let u = eig.vectors[0]
        var v = eig.vectors[1]
        guard simd_length(u) > 1e-12, simd_length(v) > 1e-12 else { return nil }

        var uv: [(u: Double, v: Double)] = []
        uv.reserveCapacity(points.count)
        for p in points {
            let d = p - c
            uv.append((simd_dot(d, u), simd_dot(d, v)))
        }

        // Kasa fit on CENTERED in-plane coordinates (Chernov & Lesort's
        // conditioning improvement over the raw 3-parameter linear system):
        // solve the 2x2 system for the center offset (uc, vc) relative to the
        // in-plane centroid, via the circle's algebraic moment equations.
        let n = Double(uv.count)
        let ubar = uv.reduce(0.0) { $0 + $1.u } / n
        let vbar = uv.reduce(0.0) { $0 + $1.v } / n
        var suu = 0.0
        var svv = 0.0
        var suv = 0.0
        var suuu = 0.0
        var svvv = 0.0
        var suvv = 0.0
        var svuu = 0.0
        for p in uv {
            let du = p.u - ubar
            let dv = p.v - vbar
            suu += du * du
            svv += dv * dv
            suv += du * dv
            suuu += du * du * du
            svvv += dv * dv * dv
            suvv += du * dv * dv
            svuu += dv * du * du
        }
        let rhsU = 0.5 * (suuu + suvv)
        let rhsV = 0.5 * (svvv + svuu)
        let det = suu * svv - suv * suv
        guard abs(det) > 1e-18 else { return nil }  // degenerate: points are colinear in-plane
        let uc = (rhsU * svv - rhsV * suv) / det
        let vc = (rhsV * suu - rhsU * suv) / det
        let radiusSq = uc * uc + vc * vc + (suu + svv) / n
        guard radiusSq > 0 else { return nil }
        let radius = radiusSq.squareRoot()

        let centerU = ubar + uc
        let centerV = vbar + vc
        let center3D = c + centerU * u + centerV * v

        var maxR = 0.0
        var sumSq = 0.0
        var angles: [Double] = []
        angles.reserveCapacity(uv.count)
        for p in uv {
            let du = p.u - centerU
            let dv = p.v - centerV
            let r = (du * du + dv * dv).squareRoot()
            let residual = abs(r - radius)
            if residual > maxR { maxR = residual }
            sumSq += residual * residual
            angles.append(atan2(dv, du))
        }

        // Unwrap the angle sequence so start/end span the true swept angle
        // across the atan2 branch cut, rather than jumping by ~2*pi at it.
        var unwrapped = angles
        for i in 1..<unwrapped.count {
            var delta = unwrapped[i] - unwrapped[i - 1]
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            unwrapped[i] = unwrapped[i - 1] + delta
        }

        // Normalise so endAngle > startAngle always matches the chain's own
        // traversal direction (point 0 -> point N), rather than a coin-flip
        // that depends on the PCA basis's arbitrary handedness. atan2(-dv,du)
        // == -atan2(dv,du) exactly, so negating every angle is equivalent to
        // using -v as the second basis vector; `axis` is flipped to match
        // (u, v, axis) stays a consistent right-handed frame, so a caller can
        // actually reason about which way "increasing angle" rotates.
        if unwrapped[unwrapped.count - 1] < unwrapped[0] {
            v = -v
            unwrapped = unwrapped.map { -$0 }
        }
        let axis = simd_normalize(simd_cross(u, v))

        return ArcFit(
            center: center3D, axis: axis, radius: radius,
            startAngle: unwrapped[0], endAngle: unwrapped[unwrapped.count - 1],
            maxResidual: maxR, rmsResidual: (sumSq / n).squareRoot()
        )
    }

    // MARK: - Segmentation

    /// Greedy maximal-run segmentation of an ordered point chain into line
    /// and arc runs.
    ///
    /// A window is grown while EITHER a line or an arc fits
    /// every point in it within `toleranceMm`; ties (both fit) prefer the
    /// LINE, the simpler model, unless the arc fits meaningfully better
    /// (its max residual under half the line's), matching the intuition that
    /// a "barely curved" run should read as straight.
    ///
    /// KNOWN LIMITATION for `closed` chains: segmentation always starts at
    /// index 0 and never tests continuity across the wrap (last point back to
    /// first) as part of the SAME run, so a true arc/line that happens to
    /// straddle the chain's own start point reads as two segments instead of
    /// one. The chain's start point is exactly as non-canonical here as it is
    /// for `ProfileMath.resampleClosed` (documented there for the same
    /// reason: `CreaseRing.vertexIndices` doesn't guarantee the seam sits
    /// anywhere meaningful). Not fixed here; flagged in the tool's warnings
    /// when `closed` is true, same as ProfileMath's own documented gap.
    static func segment(points: [SIMD3<Double>], toleranceMm: Double) -> [Segment] {
        let n = points.count
        guard n >= 2, toleranceMm > 0 else { return [] }

        var segments: [Segment] = []
        var i = 0
        while i < n - 1 {
            var end = i + 1  // a 2-point window always fits a line exactly (residual 0)
            while end + 1 < n {
                let window = Array(points[i...(end + 1)])
                let lineFit = fitLine(window)
                let arcFit = window.count >= 3 ? fitArc(window) : nil
                let lineOK = (lineFit?.maxResidual ?? .infinity) <= toleranceMm
                let arcOK = (arcFit?.maxResidual ?? .infinity) <= toleranceMm
                guard lineOK || arcOK else { break }
                end += 1
            }

            let window = Array(points[i...end])
            let lineFit = fitLine(window)
            let arcFit = window.count >= 3 ? fitArc(window) : nil
            let fit: Fit
            switch (lineFit, arcFit) {
            case (let l?, let a?):
                if a.maxResidual < l.maxResidual * 0.5 { fit = .arc(a) } else { fit = .line(l) }
            case (let l?, nil):
                fit = .line(l)
            case (nil, let a?):
                fit = .arc(a)
            case (nil, nil):
                // Defensive, not expected to fire on real input: coincident
                // points do NOT reach here (a fully-degenerate covariance
                // still leaves Jacobi's V at the identity basis, so
                // `fitLine`'s `eig.vectors[0]` stays unit-length and returns
                // a legitimate, if arbitrary-direction, zero-residual fit
                // rather than nil). This only guards a genuine breakdown of
                // `SymmetryTools.symmetricEigen3x3` producing a non-unit
                // eigenvector column, which its own normalisation already
                // treats as the zero vector. A synthetic zero-length line
                // keeps the segment list total either way.
                fit = .line(
                    LineFit(
                        point: points[i], direction: SIMD3(1, 0, 0), maxResidual: 0, rmsResidual: 0)
                )
            }
            segments.append(Segment(startIndex: i, endIndex: end, fit: fit))
            i = end
        }
        return segments
    }
}
