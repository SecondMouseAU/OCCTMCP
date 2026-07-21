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
// which derives its (u, v) plane basis deterministically from the plane normal,
// so slicing both with the SAME `CutPlane` puts the two profiles in the SAME 2D
// frame, directly comparable with no pose alignment.
//
// Stations are placed across the OVERLAP of the two bodies' axis-extents (one
// shared world point + axis for both), so every station should cut both. A
// section can be a closed contour OR (for an open shell such as a raw-scan /
// STL skin) an open polyline; #66 originally consumed only closed contours, so
// an open reference read as un-sliced (`referenceContours: 0`) at most stations.
// Now the longest open path is used as the profile when no closed loop exists,
// and stations that sliced only one body are surfaced as `registrationSmell` /
// `warnings` rather than silently skewing the aggregate.
//
// The 2D profile helpers (envelope, radial signature, resampling) live in
// `ProfileMath.swift`, shared with ZoneSweepTool (#102). This file's own logic
// is unchanged by that split; it now calls `ProfileMath.*` instead of local
// functions of the same name.

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import simd

public enum CrossSectionCompareTool {

    public struct SectionResult: Encodable {
        public let station: Int
        /// Offset of the cut plane along the axis from the overlap-range start.
        public let offset: Double
        /// World coordinate of the cut plane ALONG the axis (signed projection of
        /// the plane point onto the axis direction). For a Z sweep through a body
        /// centred near the origin this is the plane's z — so "worst at z=+54"
        /// needs no mental math (#70).
        public let axisCoord: Double
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
        /// Signed mean deviation (+ = from is proud / outside the reference). In
        /// the default `envelope` mode this is candidate-vs-reference OUTER
        /// boundary per angular direction, so inner window-return / frame paths
        /// don't pollute it (#70); in `profile` mode it's point-to-main-loop.
        public let signedMean: Double
        public let rms: Double
        public let maxAbs: Double
        /// Pose-robust radial-signature L2 (0 = same shape). Independent of size
        /// and centre. In `envelope` mode it is defined for OPEN profiles too
        /// (the outer-envelope radial function needs no closed ring — #70).
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
        /// World axis coordinate of `worstStation` (see `SectionResult.axisCoord`).
        public let worstAxisCoord: Double
        /// Which comparison basis was used: `"envelope"` (outer boundary per
        /// angular direction — default) or `"profile"` (point-to-main-loop).
        public let referenceMode: String
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
        outerEnvelope: Bool = true,
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

        let axisBase = simd_dot(pt, n)   // world axis coord of `through`

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
            let fromMain = ProfileMath.mainProfile(closed: fromSec?.contours ?? [], open: fromOpen)
            let refMain = ProfileMath.mainProfile(closed: refSec?.contours ?? [], open: refOpen)

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
                let signedMean: Double, rms: Double, maxAbs: Double, shapeL2: Double
                if outerEnvelope {
                    // Compare against the reference's OUTER boundary per angular
                    // direction — inner window-return / frame paths (smaller radius)
                    // are excluded, so a thin-wall section stops polluting the
                    // aggregate. All section geometry feeds the envelope.
                    let candPts = fromLoops.flatMap { $0 } + fromOpen.flatMap { $0 }
                    let refPts = refLoops.flatMap { $0 } + refOpen.flatMap { $0 }
                    let e = ProfileMath.envelopeDeviation(candidate: candPts, reference: refPts)
                    (signedMean, rms, maxAbs, shapeL2) = (e.signedMean, e.rms, e.maxAbs, e.shapeL2)
                } else {
                    (signedMean, rms, maxAbs) = ProfileMath.signedProfileDeviation(
                        from: fromMain.points, reference: refMain.points, referenceClosed: refMain.closed)
                    shapeL2 = (fromMain.closed && refMain.closed)
                        ? ProfileMath.radialShapeL2(fromMain.points, refMain.points, samples: 180) : 0
                }
                let fa = fromMain.closed ? abs(ProfileMath.shoelace(fromMain.points)) : 0
                let ra = refMain.closed ? abs(ProfileMath.shoelace(refMain.points)) : 0
                let cFrom = ProfileMath.centroid(fromMain.points), cRef = ProfileMath.centroid(refMain.points)
                results.append(SectionResult(
                    station: s, offset: t - lo, axisCoord: axisBase + t,
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
                    station: s, offset: t - lo, axisCoord: axisBase + t,
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
            worstAxisCoord: worst?.element.axisCoord ?? 0,
            referenceMode: outerEnvelope ? "envelope" : "profile",
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
}
