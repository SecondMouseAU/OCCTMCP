// ProfileMath — 2D cross-section profile helpers shared by CrossSectionCompareTool
// (#61/#70) and ZoneSweepTool (#102).
//
// Extracted verbatim from CrossSectionCompareTool (no behaviour change: every
// function here is byte-identical in logic to what CrossSectionCompareTool used
// to own inline). CrossSectionCompareTool now calls through to this file instead
// of defining these itself. New functions added for #102 (resampleOpen,
// profileDelta) live at the bottom, clearly separated, and are not used by
// CrossSectionCompareTool.

import Foundation
import OCCTSwiftMesh
import simd

enum ProfileMath {

    /// The best comparable profile a section offers: a closed loop when present,
    /// else the longest open polyline. `usable` gates the numeric comparison.
    struct Profile {
        let points: [SIMD2<Double>]
        let closed: Bool
        var usable: Bool { closed ? points.count >= 3 : points.count >= 2 }
    }

    /// Prefer the largest-area outermost closed contour; if the section is only
    /// open polylines (an open shell / raw scan), fall back to the longest one so
    /// the station still contributes a profile (#66).
    static func mainProfile(closed contours: [MeshContour], open openPaths: [[SIMD2<Double>]]) -> Profile? {
        if let ring = mainLoop(contours) { return Profile(points: ring, closed: true) }
        if let path = openPaths.max(by: { polylineLength($0) < polylineLength($1) }), path.count >= 2 {
            return Profile(points: path, closed: false)
        }
        return nil
    }

    /// Largest-area outermost (depth 0) loop of a section.
    static func mainLoop(_ contours: [MeshContour]) -> [SIMD2<Double>]? {
        let outer = contours.filter { $0.depth == 0 }
        let pool = outer.isEmpty ? contours : outer
        return pool.max(by: { $0.area < $1.area })?.points
    }

    static func polylineLength(_ path: [SIMD2<Double>]) -> Double {
        guard path.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 0..<(path.count - 1) { sum += simd_distance(path[i], path[i + 1]) }
        return sum
    }

    // MARK: - Outer-envelope comparison (#70)

    /// Signed deviation of the candidate's outer boundary vs the reference's
    /// outer boundary, both sampled as a radial function about the REFERENCE
    /// centroid so a lateral offset shows up as an asymmetric (proud one side /
    /// shy the other) signature rather than cancelling. Inner window-return /
    /// frame paths have a smaller radius per direction and are dropped by the
    /// max, so they no longer pollute the aggregate.
    static func envelopeDeviation(candidate candPts: [SIMD2<Double>],
                                  reference refPts: [SIMD2<Double>],
                                  bins: Int = 360)
        -> (signedMean: Double, rms: Double, maxAbs: Double, shapeL2: Double)
    {
        guard candPts.count >= 3, refPts.count >= 3 else { return (0, 0, 0, 0) }
        let c = centroid(refPts)
        let refEnv = outerEnvelope(points: refPts, center: c, bins: bins)
        let candEnv = outerEnvelope(points: candPts, center: c, bins: bins)
        var sum = 0.0, sumSq = 0.0, maxAbs = 0.0, count = 0.0
        for b in 0..<bins where refEnv[b] > 0 && candEnv[b] > 0 {
            let d = candEnv[b] - refEnv[b]           // + = candidate proud
            sum += d; sumSq += d * d
            if abs(d) > maxAbs { maxAbs = abs(d) }
            count += 1
        }
        guard count > 0 else { return (0, 0, 0, 0) }
        return (sum / count, (sumSq / count).squareRoot(), maxAbs,
                envelopeShapeL2(candEnv, refEnv))
    }

    /// Outer silhouette as a radial function: for each of `bins` angular sectors
    /// about `center`, the MAX point radius. Empty sectors (an open section /
    /// window cut) are filled by circular interpolation across their nearest
    /// occupied neighbours, so the envelope spans the opening at the outer skin.
    static func outerEnvelope(points: [SIMD2<Double>], center: SIMD2<Double>, bins: Int) -> [Double] {
        var env = [Double](repeating: 0, count: bins)
        var filled = [Bool](repeating: false, count: bins)
        let twoPi = 2.0 * Double.pi
        for p in points {
            let d = p - center
            let r = simd_length(d)
            guard r > 1e-12 else { continue }
            var a = atan2(d.y, d.x); if a < 0 { a += twoPi }
            var b = Int(a / twoPi * Double(bins))
            if b >= bins { b = bins - 1 }
            if !filled[b] || r > env[b] { env[b] = r; filled[b] = true }
        }
        fillGapsCircular(&env, filled)
        return env
    }

    static func fillGapsCircular(_ env: inout [Double], _ filled: [Bool]) {
        let n = env.count
        guard filled.contains(true), filled.contains(false) else { return }
        for i in 0..<n where !filled[i] {
            var df = 1; while !filled[(i + df) % n] { df += 1 }
            var db = 1; while !filled[(i - db + n) % n] { db += 1 }
            let fwd = env[(i + df) % n], bwd = env[(i - db + n) % n]
            env[i] = bwd + (fwd - bwd) * Double(db) / Double(db + df)
        }
    }

    /// Size- and pose-invariant shape distance between two radial envelopes:
    /// normalise each by its own mean radius, RMS of the per-sector difference.
    /// 0 => same silhouette. Works for open sections (the envelope is defined
    /// everywhere after gap-fill), unlike the closed-ring `radialShapeL2`.
    static func envelopeShapeL2(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        guard ma > 1e-12, mb > 1e-12 else { return 0 }
        var s = 0.0
        for i in a.indices { let d = a[i] / ma - b[i] / mb; s += d * d }
        return (s / Double(a.count)).squareRoot()
    }

    static func shoelace(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var s = 0.0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            s += a.x * b.y - b.x * a.y
        }
        return s * 0.5
    }

    static func centroid(_ ring: [SIMD2<Double>]) -> SIMD2<Double> {
        guard !ring.isEmpty else { return .zero }
        var c = SIMD2<Double>.zero
        for p in ring { c += p }
        return c / Double(ring.count)
    }

    /// Even-odd point-in-polygon.
    static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func pointToLoopDistance(_ p: SIMD2<Double>, _ loop: [SIMD2<Double>], closed: Bool = true) -> Double {
        guard loop.count >= 2 else { return loop.first.map { simd_distance(p, $0) } ?? .greatestFiniteMagnitude }
        var best = Double.greatestFiniteMagnitude
        let segs = closed ? loop.count : loop.count - 1
        for i in 0..<segs {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            best = min(best, pointSegmentDistance(p, a, b))
        }
        return best
    }

    static func pointSegmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        if len2 < 1e-18 { return simd_distance(p, a) }
        var t = simd_dot(p - a, ab) / len2
        t = max(0, min(1, t))
        return simd_distance(p, a + ab * t)
    }

    /// Signed point-to-profile deviation of `from` vs `reference`. Sign is + when
    /// the `from` point lies OUTSIDE the reference profile (proud), - inside (shy).
    ///
    /// When the reference is a closed loop the sign is inside/outside containment.
    /// When it is an OPEN polyline (open shell / raw scan) containment is
    /// undefined, so the sign falls back to a radial test against the reference
    /// centroid: a `from` point farther from the centroid than the reference
    /// boundary in its direction is proud (+), nearer is shy (-). For the roughly
    /// convex sections this tool targets the two conventions agree.
    static func signedProfileDeviation(from: [SIMD2<Double>], reference: [SIMD2<Double>], referenceClosed: Bool = true)
        -> (signedMean: Double, rms: Double, maxAbs: Double)
    {
        let cRef = referenceClosed ? .zero : centroid(reference)
        var sum = 0.0, sumSq = 0.0, maxAbs = 0.0
        for p in from {
            let d = pointToLoopDistance(p, reference, closed: referenceClosed)
            let signed: Double
            if referenceClosed {
                signed = contains(reference, p) ? -d : d
            } else {
                // Nearest reference vertex approximates the boundary radius in p's
                // direction; compare radii for a proud/shy sign.
                let nearest = reference.min(by: { simd_distance($0, p) < simd_distance($1, p) }) ?? cRef
                signed = simd_distance(p, cRef) >= simd_distance(nearest, cRef) ? d : -d
            }
            sum += signed
            sumSq += signed * signed
            if abs(signed) > maxAbs { maxAbs = abs(signed) }
        }
        let n = Double(from.count)
        return (sum / n, (sumSq / n).squareRoot(), maxAbs)
    }

    /// Arc-length resample of a closed loop to `n` evenly-spaced points.
    static func resampleClosed(_ loop: [SIMD2<Double>], _ n: Int) -> [SIMD2<Double>] {
        guard loop.count >= 2, n >= 3 else { return loop }
        var cum: [Double] = [0]
        var total = 0.0
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            total += simd_distance(a, b)
            cum.append(total)
        }
        guard total > 1e-12 else { return loop }
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        var seg = 0
        for k in 0..<n {
            let target = total * Double(k) / Double(n)
            while seg < loop.count && cum[seg + 1] < target { seg += 1 }
            let a = loop[seg % loop.count], b = loop[(seg + 1) % loop.count]
            let segLen = cum[seg + 1] - cum[seg]
            let t = segLen > 1e-12 ? (target - cum[seg]) / segLen : 0
            out.append(a + (b - a) * t)
        }
        return out
    }

    /// Pose-robust radial-signature L2. Resample both, take distance-from-centroid
    /// as a function of normalized arc length, scale each by its own mean radius,
    /// and return the RMS difference. 0 => same shape regardless of size/position.
    /// Both loops already share the section's (u, v) frame, so no rotation
    /// alignment is required.
    static func radialShapeL2(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>], samples: Int) -> Double {
        let ra = radialSignature(a, samples)
        let rb = radialSignature(b, samples)
        guard ra.count == rb.count, !ra.isEmpty else { return 0 }
        var s = 0.0
        for i in ra.indices { let d = ra[i] - rb[i]; s += d * d }
        return (s / Double(ra.count)).squareRoot()
    }

    static func radialSignature(_ loop: [SIMD2<Double>], _ n: Int) -> [Double] {
        let rs = resampleClosed(loop, n)
        let c = centroid(rs)
        var radii = rs.map { simd_distance($0, c) }
        let mean = radii.reduce(0, +) / Double(max(1, radii.count))
        if mean > 1e-12 { for i in radii.indices { radii[i] /= mean } }
        return radii
    }

    // MARK: - New for #102: open-polyline resample + reference-relative delta.
    //
    // Unused by CrossSectionCompareTool (zero behaviour change there). Added for
    // ZoneSweepTool, which slices a ZONE's own triangles rather than a whole
    // solid: the resulting section is very often a short OPEN polyline (a single
    // wall's cut, not a closed ring), where `envelopeDeviation` /
    // `radialShapeL2` (tuned for roughly star-shaped closed loops) aren't a good
    // fit. `profileDelta` instead resamples each profile with its OWN
    // closed/open convention, aligns their centroids (isolating shape difference
    // from lateral position), and reports both pieces in real mm.

    /// Arc-length resample of an OPEN polyline to `n` evenly-spaced points
    /// (no wraparound, unlike `resampleClosed`). `n == 1` returns the midpoint.
    static func resampleOpen(_ path: [SIMD2<Double>], _ n: Int) -> [SIMD2<Double>] {
        guard path.count >= 2, n >= 1 else { return path }
        var cum: [Double] = [0]
        var total = 0.0
        for i in 0..<(path.count - 1) {
            total += simd_distance(path[i], path[i + 1])
            cum.append(total)
        }
        guard total > 1e-12 else { return [SIMD2<Double>](repeating: path[0], count: n) }
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        var seg = 0
        for k in 0..<n {
            let target = n == 1 ? total / 2 : total * Double(k) / Double(n - 1)
            while seg < path.count - 2 && cum[seg + 1] < target { seg += 1 }
            let a = path[seg], b = path[seg + 1]
            let segLen = cum[seg + 1] - cum[seg]
            let t = segLen > 1e-12 ? (target - cum[seg]) / segLen : 0
            out.append(a + (b - a) * t)
        }
        return out
    }

    /// Reference-relative comparison of two profiles, in real mm (not the
    /// normalized shape scalars `radialShapeL2` / `envelopeShapeL2` return):
    /// resample each with its own closed/open convention, remove the lateral
    /// (centroid) offset, and report both the offset and the residual shape
    /// difference after removing it.
    ///
    /// `reference` and `candidate` may differ in closedness (a zone can, in
    /// principle, cut open at one station and closed at another); the
    /// arc-length-fraction correspondence used here is still well-defined, if
    /// not perfectly meaningful, across that mismatch, and never traps.
    ///
    /// An open polyline's point order (which end came out of `crossSection`
    /// first) is NOT a canonical property of the surface: two independent
    /// cuts of the SAME physical wall (different stations, same zone) can
    /// come back walked in opposite directions, which would otherwise pair
    /// point 0 near one wall's rim with point 0 near the other's opposite
    /// rim and read as a large shape difference that isn't really there. For
    /// an open `candidate`, both the as-resampled and reversed point orders
    /// are compared and the lower-RMS orientation wins; `lateralOffsetMm`
    /// (centroid-based) is unaffected by this either way.
    ///
    /// KNOWN LIMITATION: this reversal-invariance only covers OPEN profiles.
    /// A CLOSED ring is resampled starting from `loop[0]` (`resampleClosed`),
    /// and that start point is exactly as non-canonical for a closed loop as
    /// direction was for an open one: `Mesh.crossSection`'s loop traversal
    /// doesn't guarantee the same physical point comes out first at every
    /// station. Two stations of the same tube-like body can therefore come
    /// back rotated relative to each other, pairing arc-length fractions
    /// that are out of phase and reading as phantom shape deviation
    /// (`rmsMm`/`maxMm` inflated even though the true cross-section didn't
    /// change). Unlike the open-profile case, there is no cheap
    /// forward/backward check that fixes this — a rotation can land at any
    /// offset, not just reversed. The eventual fix is a best CIRCULAR SHIFT
    /// of the resampled candidate points against the resampled reference
    /// (try every rotation, or a coarse-to-fine search, keep the lowest
    /// RMS), mirroring what `forward`/`backward` already do for reversal.
    /// Not implemented yet: whole-body `zone_continuity_sweep` runs over a
    /// closed-ring profile are exposed to this; zone-scoped sweeps of a
    /// single (non-closed-ring) zone are not.
    static func profileDelta(reference: Profile, candidate: Profile, samples: Int = 32)
        -> (lateralOffsetMm: Double, rmsMm: Double, maxMm: Double, arcLengthDeltaMm: Double)?
    {
        guard reference.usable, candidate.usable else { return nil }
        let refPts = reference.closed ? resampleClosed(reference.points, samples) : resampleOpen(reference.points, samples)
        let candPts = candidate.closed ? resampleClosed(candidate.points, samples) : resampleOpen(candidate.points, samples)
        guard refPts.count == candPts.count, !refPts.isEmpty else { return nil }

        let cRef = centroid(refPts)
        let cCand = centroid(candPts)
        let lateral = simd_distance(cRef, cCand)

        func residual(_ pts: [SIMD2<Double>]) -> (rms: Double, maxD: Double) {
            var sumSq = 0.0, maxD = 0.0
            for i in refPts.indices {
                // Shift the candidate point back by its own centroid offset so
                // the comparison measures SHAPE, not the lateral shift already
                // captured in `lateral`.
                let aligned = pts[i] - cCand + cRef
                let d = simd_distance(refPts[i], aligned)
                sumSq += d * d
                if d > maxD { maxD = d }
            }
            return ((sumSq / Double(refPts.count)).squareRoot(), maxD)
        }

        let forward = residual(candPts)
        let best: (rms: Double, maxD: Double)
        if !candidate.closed {
            let backward = residual(Array(candPts.reversed()))
            best = forward.rms <= backward.rms ? forward : backward
        } else {
            best = forward
        }

        let refLen = reference.closed ? closedLength(reference.points) : polylineLength(reference.points)
        let candLen = candidate.closed ? closedLength(candidate.points) : polylineLength(candidate.points)

        return (lateral, best.rms, best.maxD, abs(candLen - refLen))
    }

    static func closedLength(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 2 else { return 0 }
        var sum = 0.0
        for i in ring.indices { sum += simd_distance(ring[i], ring[(i + 1) % ring.count]) }
        return sum
    }
}
