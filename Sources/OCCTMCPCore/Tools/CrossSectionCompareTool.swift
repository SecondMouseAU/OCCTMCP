// CrossSectionCompareTool — `cross_section_compare` (#61). The highest-leverage
// detector for the failure that motivated #61/#62/#63: a reconstruction whose
// cross-section is the WRONG SHAPE everywhere, yet whose 3D mean deviation looks
// fine because the correct faces dominate the samples and the wrong arc averages
// out.
//
// It slices BOTH bodies at N stations along a shared axis, overlays the two 2D
// profiles per station, and reports a per-section signed-mean (the direct
// detector of a systematic section offset) plus a pose-robust radial shape
// scalar (catches wrong-shape that a Hausdorff misses). A systematically-wrong
// section shows two visibly different profiles AND a near-constant non-zero
// signedMean across the stack.
//
// Both bodies are meshed and sliced with OCCTSwiftMesh's `Mesh.crossSection`,
// which derives its (u, v) plane basis deterministically from the plane normal —
// so slicing both with the SAME `CutPlane` puts the two profiles in the SAME 2D
// frame, directly comparable with no pose alignment.
//
// Stations are placed across the OVERLAP of the two bodies' axis-extents (one
// shared world point + axis for both), so every station should cut both. A
// section can be a closed contour OR — for an open shell such as a raw-scan /
// STL skin — an open polyline; #66 originally consumed only closed contours, so
// an open reference read as un-sliced (`referenceContours: 0`) at most stations.
// Now the longest open path is used as the profile when no closed loop exists,
// and stations that sliced only one body are surfaced as `registrationSmell` /
// `warnings` rather than silently skewing the aggregate.

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import simd

public enum CrossSectionCompareTool {

    public struct SectionResult: Encodable {
        public let station: Int
        /// Offset of the cut plane along the axis from the overlap-range start.
        public let offset: Double
        /// Closed loops the plane cut in each body.
        public let fromContours: Int
        public let referenceContours: Int
        /// Open polylines the plane cut (an open shell / raw scan section yields
        /// these instead of a closed contour). A station with a non-zero open
        /// count but zero closed count still slices the body — it just isn't
        /// closed. Counting only `*Contours` is what made open reference meshes
        /// look un-sliced (#66).
        public let fromOpenPaths: Int
        public let referenceOpenPaths: Int
        /// True when exactly ONE body yielded any section (closed or open) at
        /// this station — a registration / axis-extent smell.
        public let registrationSmell: Bool
        /// True when the comparison profile used at this station was an open
        /// polyline (so signedMean uses the radial-from-centroid sign convention
        /// rather than inside/outside containment).
        public let openProfile: Bool
        public let fromArea: Double
        public let referenceArea: Double
        public let areaRatio: Double
        /// Distance between the two main loops' centroids, in the plane.
        public let centroidOffset: Double
        /// Signed mean point-to-profile deviation of the `from` loop vs the
        /// `reference` loop (+ = from is outside reference / proud).
        public let signedMean: Double
        public let rms: Double
        public let maxAbs: Double
        /// Pose-robust radial-signature L2 (0 = same shape). Independent of size
        /// and centre, so it flags a wrong shape even when areas match.
        public let shapeL2: Double
        public let imagePath: String?
    }

    public struct CompareReport: Encodable {
        public let from: String
        public let reference: String
        public let axis: [Double]
        public let deflection: Double
        public let stations: Int
        /// Shared axis-extent overlap `[lo, hi]` (signed distance from `through`
        /// along the axis) that the stations were placed across — both bodies
        /// span this range, so every station should cut both.
        public let overlap: [Double]
        /// Mean of the per-section signedMean — a non-zero value across the whole
        /// stack is the systematic-offset fingerprint. Averaged over stations that
        /// actually produced a comparison.
        public let meanSignedAcrossSections: Double
        public let maxAbsSignedSection: Double
        public let worstStation: Int
        /// Human-readable warnings — e.g. stations where only one body sliced
        /// (a registration smell), so the caller doesn't trust an aggregate that
        /// a handful of one-sided stations skewed (#66).
        public let warnings: [String]
        public let sections: [SectionResult]
    }

    public static func crossSectionCompare(
        fromBodyId: String,
        referenceBodyId: String,
        axis: SIMD3<Double>,
        stations: Int = 12,
        through: SIMD3<Double>? = nil,
        deflection: Double? = nil,
        outputDir: String? = nil,
        imagePrefix: String = "section",
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard simd_length(axis) > 1e-12 else {
            return .init("axis must be non-zero.", isError: true)
        }
        guard stations >= 1 else { return .init("stations must be ≥ 1.", isError: true) }

        let fromShape: Shape, refShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            refShape = try IntrospectionTools.loadShape(bodyId: referenceBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        let defl = deflection ?? DeviationTools.defaultDeflection(for: fromShape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }

        guard let fromMesh = mesh(fromShape, deflection: defl) else {
            return .init("Failed to tessellate '\(fromBodyId)'.", isError: true)
        }
        guard let refMesh = mesh(refShape, deflection: defl) else {
            return .init("Failed to tessellate '\(referenceBodyId)'.", isError: true)
        }

        let n = simd_normalize(axis)
        let nf = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        let pt = through ?? midpoint(of: fromShape)
        let ptf = SIMD3<Float>(Float(pt.x), Float(pt.y), Float(pt.z))

        // Axis range = OVERLAP of both meshes' projections, so every station cuts
        // both bodies.
        let (loA, hiA) = projectRange(fromMesh.vertices, origin: ptf, axis: nf)
        let (loB, hiB) = projectRange(refMesh.vertices, origin: ptf, axis: nf)
        let lo = Double(max(loA, loB)), hi = Double(min(hiA, hiB))
        guard hi - lo > 1e-9 else {
            return .init("Bodies do not overlap along the given axis — no shared sections.", isError: true)
        }
        let margin = (hi - lo) * 0.02
        let start = lo + margin, end = hi - margin
        let span = max(1e-9, end - start)
        let step = stations > 1 ? span / Double(stations - 1) : 0

        var results: [SectionResult] = []
        for s in 0..<stations {
            let t = stations > 1 ? start + Double(s) * step : (start + end) / 2
            let plane = CutPlane(point: pt + n * t, normal: n)
            let fromSec = fromMesh.crossSection(plane: plane)
            let refSec = refMesh.crossSection(plane: plane)

            let fromLoops = (fromSec?.contours ?? []).map { $0.points }
            let refLoops = (refSec?.contours ?? []).map { $0.points }
            let fromOpen = fromSec?.openPaths ?? []
            let refOpen = refSec?.openPaths ?? []

            // Prefer a closed contour; fall back to the longest open polyline so an
            // open shell (raw scan / STL skin) still yields a comparable profile.
            let fromMain = mainProfile(closed: fromSec?.contours ?? [], open: fromOpen)
            let refMain = mainProfile(closed: refSec?.contours ?? [], open: refOpen)

            let fromHit = !fromLoops.isEmpty || !fromOpen.isEmpty
            let refHit = !refLoops.isEmpty || !refOpen.isEmpty
            let smell = fromHit != refHit

            var imagePath: String? = nil
            if let outputDir {
                let path = "\(outputDir)/\(imagePrefix)_\(String(format: "%02d", s)).png"
                do {
                    try ChartRenderer.profileOverlay(
                        layers: [
                            .init(loops: refLoops, openPaths: refOpen, color: SIMD4(0.18, 0.42, 0.86, 1), label: "reference (\(referenceBodyId))"),
                            .init(loops: fromLoops, openPaths: fromOpen, color: SIMD4(0.86, 0.20, 0.18, 1), label: "from (\(fromBodyId))"),
                        ],
                        title: "station \(s)  offset \(String(format: "%.3g", t - lo))",
                        to: URL(fileURLWithPath: path)
                    )
                    imagePath = path
                } catch {
                    // A render failure shouldn't abort the numeric comparison.
                    imagePath = nil
                }
            }

            // Numeric comparison needs a usable profile from BOTH bodies (a closed
            // loop ≥3 pts, or an open polyline ≥2 pts).
            if let fromMain, let refMain, fromMain.usable, refMain.usable {
                let (signedMean, rms, maxAbs) = signedProfileDeviation(from: fromMain.points, reference: refMain.points, referenceClosed: refMain.closed)
                // Radial-signature shape scalar assumes a closed ring; skip it
                // (report 0) when either profile is open.
                let shapeL2 = (fromMain.closed && refMain.closed) ? radialShapeL2(fromMain.points, refMain.points, samples: 180) : 0
                let fa = fromMain.closed ? abs(shoelace(fromMain.points)) : 0
                let ra = refMain.closed ? abs(shoelace(refMain.points)) : 0
                let cFrom = centroid(fromMain.points), cRef = centroid(refMain.points)
                results.append(SectionResult(
                    station: s, offset: t - lo,
                    fromContours: fromLoops.count, referenceContours: refLoops.count,
                    fromOpenPaths: fromOpen.count, referenceOpenPaths: refOpen.count,
                    registrationSmell: smell,
                    openProfile: !(fromMain.closed && refMain.closed),
                    fromArea: fa, referenceArea: ra,
                    areaRatio: ra > 1e-12 ? fa / ra : 0,
                    centroidOffset: simd_distance(cFrom, cRef),
                    signedMean: signedMean, rms: rms, maxAbs: maxAbs,
                    shapeL2: shapeL2, imagePath: imagePath
                ))
            } else {
                results.append(SectionResult(
                    station: s, offset: t - lo,
                    fromContours: fromLoops.count, referenceContours: refLoops.count,
                    fromOpenPaths: fromOpen.count, referenceOpenPaths: refOpen.count,
                    registrationSmell: smell, openProfile: false,
                    fromArea: 0, referenceArea: 0, areaRatio: 0, centroidOffset: 0,
                    signedMean: 0, rms: 0, maxAbs: 0, shapeL2: 0, imagePath: imagePath
                ))
            }
        }

        let valid = results.filter { $0.rms > 0 || $0.maxAbs > 0 }
        let meanSigned = valid.isEmpty ? 0 : valid.reduce(0) { $0 + $1.signedMean } / Double(valid.count)
        let worst = results.enumerated().max(by: { abs($0.element.signedMean) < abs($1.element.signedMean) })

        var warnings: [String] = []
        let smellStations = results.filter { $0.registrationSmell }.map { $0.station }
        if !smellStations.isEmpty {
            warnings.append("\(smellStations.count)/\(results.count) stations sliced only one body (stations \(smellStations.map(String.init).joined(separator: ","))) — possible mis-registration or the bodies' axis-extents differ; aggregates exclude them.")
        }
        if valid.count < results.count {
            warnings.append("\(results.count - valid.count)/\(results.count) stations lacked a comparable profile in both bodies; aggregates are over the \(valid.count) that did.")
        }

        let report = CompareReport(
            from: fromBodyId, reference: referenceBodyId,
            axis: [axis.x, axis.y, axis.z], deflection: defl, stations: results.count,
            overlap: [lo, hi],
            meanSignedAcrossSections: meanSigned,
            maxAbsSignedSection: worst.map { abs($0.element.signedMean) } ?? 0,
            worstStation: worst?.offset ?? 0,
            warnings: warnings,
            sections: results
        )
        return IntrospectionTools.encode(report)
    }

    // MARK: - Mesh helpers

    static func mesh(_ shape: Shape, deflection: Double) -> Mesh? {
        var params = MeshParameters.default
        params.deflection = deflection
        params.internalVertices = true
        params.inParallel = true
        params.allowQualityDecrease = true
        return shape.mesh(parameters: params)
    }

    static func midpoint(of shape: Shape) -> SIMD3<Double> {
        let b = shape.bounds
        return (b.min + b.max) * 0.5
    }

    static func projectRange(_ verts: [SIMD3<Float>], origin: SIMD3<Float>, axis: SIMD3<Float>) -> (Float, Float) {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in verts {
            let d = simd_dot(v - origin, axis)
            if d < lo { lo = d }
            if d > hi { hi = d }
        }
        return (lo, hi)
    }

    // MARK: - 2D contour math

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
    /// the `from` point lies OUTSIDE the reference profile (proud), − inside (shy).
    ///
    /// When the reference is a closed loop the sign is inside/outside containment.
    /// When it is an OPEN polyline (open shell / raw scan) containment is
    /// undefined, so the sign falls back to a radial test against the reference
    /// centroid: a `from` point farther from the centroid than the reference
    /// boundary in its direction is proud (+), nearer is shy (−). For the roughly
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
    /// and return the RMS difference. 0 ⇒ same shape regardless of size/position.
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
}
