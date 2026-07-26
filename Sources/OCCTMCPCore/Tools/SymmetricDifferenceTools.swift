// SymmetricDifferenceTools: `symmetric_difference_volume` (#122). A volume-based
// certification metric to sit alongside `measure_deviation`: mean/RMS surface deviation is a
// cancellation-prone figure (a part undersized in one place and oversized in another reads
// BETTER, since the errors partly average out), and `boolean_op` cannot produce the direct
// geometric fix (a true symmetric-difference solid) against a mesh-only, possibly non-watertight
// reference: empirically, `subtract(solid, mesh)` and `subtract(mesh, solid)` both fail on a
// real STL reference (#122).
//
// Rather than hardening `boolean_op` for mesh operands (a much larger change touching OCCT's own
// boolean kernel, which has no native concept of "heal this mesh into a solid first"), this reports
// the two one-sided volumes and their sum via `OCCTSwiftMesh.Mesh.windingNumber(at:)` (>=1.7.0):
// the generalized winding number (Jacobson/Kavan/Sorkine-Hornung, SIGGRAPH 2013) is a direct
// solid-angle sum that degrades gracefully, staying a well-defined real number (not an undefined
// or arbitrary result) on the open/self-intersecting meshes a classical parity/ray-casting
// point-in-polyhedron test needs a genuinely closed surface to mean anything against. That is
// exactly "robust against a non-watertight reference," the issue's own ask.
//
// `windingNumber` is O(triangleCount) per call with no spatial acceleration (upstream's own docs:
// "acceptable at diagnostic sample counts, a few dozen points x a few hundred thousand triangles";
// a hierarchical evaluation is the scale-up path, not implemented there). A volumetric Monte Carlo
// estimate needs more than "a few dozen" points for useful precision, so sample points are placed
// via a deterministic 3D Halton sequence (low-discrepancy: converges faster than a naive uniform
// PRNG for the same budget, and, like every other diagnostic sampler in this codebase, repeat
// calls on identical input agree exactly) and `maxSamples` defaults conservatively (300) rather
// than the 2000-20000 range surface-deviation tools use, since each sample here costs O(triangleCount)
// per body rather than O(log triangleCount).
//
// Classification is orientation-agnostic on purpose: `windingNumber` is exactly linear in triangle
// orientation (reversing every triangle's winding negates it everywhere), so an inverted-winding
// mesh reads ~-1 inside rather than ~+1. Thresholding on `w > 0.5` would silently read such a
// mesh's entire interior as "outside" and report its whole volume as missing. Classifying by
// "confidently near ANY nonzero integer" (`round(w) != 0`) rather than "confidently near +1" makes
// the result correct regardless of the reference's winding convention, without needing a separate
// orientation pre-pass (`orientationReport` is deliberately not used here for exactly this reason:
// its own doc is explicit that exterior sampling is provably powerless to detect inversion on a
// closed solid).

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import simd

public enum SymmetricDifferenceTools {

    public struct SymmetricDifferenceReport: Encodable {
        public let fromBodyId: String
        public let referenceBodyId: String
        public let deflection: Double
        public let samples: Int
        public let ambiguousSamples: Int
        public let ambiguousFraction: Double
        public let boundingBoxVolumeMm3: Double
        /// Sampled total volume of `fromBodyId`, from `fromBodyId`'s OWN classification only
        /// (independent of whether `referenceBodyId` classified confidently at the same sample
        /// point). May differ slightly from `intersectionVolumeMm3 + fromOnlyVolumeMm3`, which
        /// use a different (jointly-confident) sample subset; both are honest, just different
        /// denominators.
        public let fromVolumeMm3: Double
        /// Sampled total volume of `referenceBodyId`, from `referenceBodyId`'s OWN classification
        /// only. See `fromVolumeMm3`.
        public let referenceVolumeMm3: Double
        public let intersectionVolumeMm3: Double
        public let unionVolumeMm3: Double
        /// Volume inside `fromBodyId` but not `referenceBodyId`: excess / over-build material.
        public let fromOnlyVolumeMm3: Double
        /// Volume inside `referenceBodyId` but not `fromBodyId`: missing / under-build material.
        public let referenceOnlyVolumeMm3: Double
        /// `fromOnlyVolumeMm3 + referenceOnlyVolumeMm3`, the direct geometric fidelity figure a
        /// mean/RMS surface deviation can hide via cancellation.
        public let symmetricDifferenceVolumeMm3: Double
        /// `symmetricDifferenceVolumeMm3 / unionVolumeMm3` (1 - IoU). 0 = identical volumes, 1 =
        /// completely disjoint. nil when the union itself sampled to ~0 (both bodies missed).
        public let symmetricDifferenceFraction: Double?
        /// Monte Carlo standard error on `symmetricDifferenceVolumeMm3`, treating "this sample
        /// landed in the symmetric-difference region" as a single Bernoulli trial. A measured
        /// value under ~2x this is noise-dominated at the current `maxSamples`, not necessarily a
        /// well-registered pair.
        public let estimatedStdErrMm3: Double
        /// Exact BREP mass-properties volume (`BRepGProp::VolumeProperties`), when computable.
        /// Reported as a cross-check only: it is exact for a genuine closed solid but can be
        /// silently wrong for an open/non-watertight shape, which is exactly the reference-body
        /// case this tool exists to handle. See `referenceWatertight`.
        public let fromExactVolumeMm3: Double?
        public let referenceExactVolumeMm3: Double?
        public let fromWatertight: Bool
        public let referenceWatertight: Bool
        /// false when `ambiguousFraction` exceeds `ambiguousWarnFraction` (the classification
        /// itself is too uncertain at this sample count), or when a body's sampled volume
        /// disagrees with its own exact BREP volume by more than noise can explain: either signal
        /// means the volumes above should not be trusted without raising `maxSamples`.
        public let reliable: Bool
        public let warnings: [String]
    }

    public static let defaultMaxSamples = 300
    /// Winding-number values within this of the nearest integer classify confidently; the rest
    /// are ambiguous. Width chosen so a genuinely closed, coherently-wound mesh (which reads
    /// almost exactly 0 or +-1 away from its own surface) never flags ambiguous by numerical
    /// noise alone, while a value near the 0.5 midpoint (a genuine open-shell / self-intersection
    /// symptom) reliably does.
    static let ambiguityBand = 0.25
    static let ambiguousWarnFraction = 0.15
    /// Floor on the exact-vs-sampled volume disagreement that triggers a warning; the actual
    /// threshold used is `max(this, 2 * relativeStdErr)`, since at low sample counts (or a body
    /// occupying only a modest fraction of the combined bbox) this fixed fraction alone can sit
    /// within a body's own Monte Carlo noise, which would otherwise flag a genuinely closed,
    /// correctly-sampled solid as possibly non-closed.
    static let exactVolumeDisagreementWarnFraction = 0.10

    @MainActor
    public static func symmetricDifferenceVolume(
        fromBodyId: String,
        referenceBodyId: String,
        deflection: Double? = nil,
        maxSamples: Int = defaultMaxSamples,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let fromShape: Shape, refShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            refShape = try IntrospectionTools.loadShape(bodyId: referenceBodyId, store: store).shape
        } catch {
            return .init("\(error)", isError: true)
        }

        guard maxSamples > 0 else {
            return .init("maxSamples must be positive.", isError: true)
        }
        let defl = deflection ?? DeviationTools.defaultDeflection(for: fromShape)
        guard defl > 0 else {
            return .init("deflection must be positive.", isError: true)
        }

        let meshParams = DeviationTools.standardMeshParameters(deflection: defl)

        guard let fromMesh = fromShape.mesh(parameters: meshParams), fromMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(fromBodyId)' for symmetric-difference volume.", isError: true)
        }
        guard let refMesh = refShape.mesh(parameters: meshParams), refMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(referenceBodyId)' for symmetric-difference volume.", isError: true)
        }

        let fromB = fromShape.bounds, refB = refShape.bounds
        let lo = simd_min(fromB.min, refB.min)
        let hi = simd_max(fromB.max, refB.max)
        let extent = hi - lo
        let bboxVolume = extent.x * extent.y * extent.z
        guard bboxVolume.isFinite, bboxVolume > 1e-12 else {
            return .init(
                "Combined bounding box of '\(fromBodyId)' and '\(referenceBodyId)' is degenerate (zero volume).",
                isError: true)
        }

        // Each body's OWN confident-classification count backs its OWN volume estimate
        // (`fromConfident`/`refConfident`), so noise in one body's mesh never contaminates the
        // other's `...VolumeMm3`. The joint (difference) buckets need BOTH bodies confident at
        // the same sample point, and are counted against their OWN confident subset
        // (`jointConfident`, tracked including the `(false, false)` "outside both" case): dividing
        // by the full sample count instead would silently treat every ambiguous sample as "outside
        // both bodies," biasing every joint figure low exactly where the reference is roughest.
        // Rescaling by the confident subset extrapolates instead: the ambiguous region is assumed
        // to partition like the region that DID classify, the same "exclude and rescale" approach
        // `DeviationTools.directedStats` already uses for its own signed aggregates.
        var insideBoth = 0, fromOnly = 0, referenceOnly = 0, outsideBoth = 0, jointAmbiguous = 0
        var fromConfident = 0, fromInside = 0
        var refConfident = 0, refInside = 0
        for i in 1...maxSamples {
            let p = lo + haltonPoint(index: i) * extent
            let ca = classify(fromMesh.windingNumber(at: p))
            let cb = classify(refMesh.windingNumber(at: p))
            if let ca = ca {
                fromConfident += 1
                if ca { fromInside += 1 }
            }
            if let cb = cb {
                refConfident += 1
                if cb { refInside += 1 }
            }
            guard let ca = ca, let cb = cb else {
                jointAmbiguous += 1
                continue
            }
            switch (ca, cb) {
            case (true, true): insideBoth += 1
            case (true, false): fromOnly += 1
            case (false, true): referenceOnly += 1
            case (false, false): outsideBoth += 1
            }
        }
        let jointConfident = insideBoth + fromOnly + referenceOnly + outsideBoth

        func fraction(_ count: Int, over denom: Int) -> Double {
            denom > 0 ? Double(count) / Double(denom) : 0
        }
        func vol(_ count: Int, over denom: Int) -> Double { fraction(count, over: denom) * bboxVolume }
        /// Relative standard error of a confident-subset proportion `count/denom`, propagated to
        /// the volume it scales: a Bernoulli proportion's absolute std error is
        /// `sqrt(p(1-p)/denom)`, and dividing by `p` (relative error is scale-invariant under the
        /// `x bboxVolume` step) gives the noise floor an exact-volume comparison has to clear
        /// before a disagreement means anything beyond sampling noise.
        func relativeStdErr(count: Int, denom: Int) -> Double {
            guard denom > 0 else { return 0 }
            let p = Double(count) / Double(denom)
            guard p > 1e-9 else { return 0 }
            return ((1 - p) / (p * Double(denom))).squareRoot()
        }

        let fromVolume = vol(fromInside, over: fromConfident)
        let referenceVolume = vol(refInside, over: refConfident)
        let intersection = vol(insideBoth, over: jointConfident)
        let fromOnlyVol = vol(fromOnly, over: jointConfident)
        let referenceOnlyVol = vol(referenceOnly, over: jointConfident)
        let symDiff = fromOnlyVol + referenceOnlyVol
        let union = intersection + fromOnlyVol + referenceOnlyVol
        let symDiffFraction: Double? = union > 1e-12 ? symDiff / union : nil

        let sdFrac = fraction(fromOnly + referenceOnly, over: jointConfident)
        let stdErr = jointConfident > 0
            ? bboxVolume * (sdFrac * (1 - sdFrac) / Double(jointConfident)).squareRoot() : 0

        let ambiguousFraction = Double(jointAmbiguous) / Double(maxSamples)
        var warnings: [String] = []
        var reliable = true
        if ambiguousFraction > ambiguousWarnFraction {
            reliable = false
            warnings.append(
                "\(jointAmbiguous)/\(maxSamples) samples (\(Int((ambiguousFraction * 100).rounded()))%) had an " +
                "uncertain winding-number classification for at least one body, likely a non-watertight, " +
                "self-intersecting, or very thin-walled region. The joint figures (intersectionVolumeMm3, " +
                "fromOnlyVolumeMm3, referenceOnlyVolumeMm3, symmetricDifferenceVolumeMm3) extrapolate from " +
                "the remaining confidently-classified samples and are not fully reliable at this sample count."
            )
        }
        if symDiff < 2 * stdErr {
            warnings.append(
                "symmetricDifferenceVolumeMm3 (\(fmt(symDiff))) is within 2x its own Monte Carlo standard " +
                "error (\(fmt(stdErr))); raise maxSamples to resolve a difference this small with confidence."
            )
        }

        let fromWatertight = fromMesh.integrityReport(weldTolerance: 0).isWatertight
        let refWatertight = refMesh.integrityReport(weldTolerance: 0).isWatertight
        if !fromWatertight {
            warnings.append(
                "'\(fromBodyId)' is not watertight; volumes are the generalized-winding-number " +
                "estimate (robust to this), not an exact mass-properties figure."
            )
        }
        if !refWatertight {
            warnings.append(
                "'\(referenceBodyId)' is not watertight; volumes are the generalized-winding-number " +
                "estimate (robust to this), not an exact mass-properties figure."
            )
        }

        // The comparison threshold is the LARGER of the fixed floor and a multiple of this body's
        // own Monte Carlo noise: at the default maxSamples (300), a body occupying a moderate
        // fraction of the combined bbox can have a relative standard error comparable to or
        // exceeding a fixed 10% on sampling noise alone, which would otherwise flag a genuinely
        // closed, correctly-sampled solid as possibly non-closed.
        let fromExact = fromShape.volumeInertia?.volume
        let refExact = refShape.volumeInertia?.volume
        if let fe = fromExact, abs(fe) > 1e-9 {
            let rel = abs(fe - fromVolume) / abs(fe)
            let threshold = max(exactVolumeDisagreementWarnFraction, 2 * relativeStdErr(count: fromInside, denom: fromConfident))
            if rel > threshold {
                reliable = false
                warnings.append(
                    "'\(fromBodyId)': sampled volume (\(fmt(fromVolume))) disagrees with the exact BREP " +
                    "volume (\(fmt(fe))) by \(Int((rel * 100).rounded()))%; raise maxSamples, or '\(fromBodyId)' " +
                    "may not be a genuinely closed solid."
                )
            }
        }
        if let re = refExact, abs(re) > 1e-9 {
            let rel = abs(re - referenceVolume) / abs(re)
            let threshold = max(exactVolumeDisagreementWarnFraction, 2 * relativeStdErr(count: refInside, denom: refConfident))
            if rel > threshold {
                reliable = false
                warnings.append(
                    "'\(referenceBodyId)': sampled volume (\(fmt(referenceVolume))) disagrees with the exact " +
                    "BREP volume (\(fmt(re))) by \(Int((rel * 100).rounded()))%, expected for a non-watertight " +
                    "reference (exact mass properties assume closure); raise maxSamples for a tighter sampled estimate."
                )
            }
        }

        let report = SymmetricDifferenceReport(
            fromBodyId: fromBodyId,
            referenceBodyId: referenceBodyId,
            deflection: defl,
            samples: maxSamples,
            ambiguousSamples: jointAmbiguous,
            ambiguousFraction: ambiguousFraction,
            boundingBoxVolumeMm3: bboxVolume,
            fromVolumeMm3: fromVolume,
            referenceVolumeMm3: referenceVolume,
            intersectionVolumeMm3: intersection,
            unionVolumeMm3: union,
            fromOnlyVolumeMm3: fromOnlyVol,
            referenceOnlyVolumeMm3: referenceOnlyVol,
            symmetricDifferenceVolumeMm3: symDiff,
            symmetricDifferenceFraction: symDiffFraction,
            estimatedStdErrMm3: stdErr,
            fromExactVolumeMm3: fromExact,
            referenceExactVolumeMm3: refExact,
            fromWatertight: fromWatertight,
            referenceWatertight: refWatertight,
            reliable: reliable,
            warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }

    // MARK: - Classification

    /// `true` = confidently inside, `false` = confidently outside, `nil` = ambiguous. Orientation-
    /// agnostic (see file header): a point is inside iff the winding number sits close to ANY
    /// nonzero integer, not specifically +1, so an inverted-winding or doubled (nested-shell)
    /// mesh still classifies correctly without a separate orientation check.
    static func classify(_ w: Double) -> Bool? {
        let r = w.rounded()
        guard abs(w - r) <= ambiguityBand else { return nil }
        return r != 0
    }

    // MARK: - Deterministic low-discrepancy sampling

    /// `index`th point of a 3D Halton sequence (bases 2, 3, 5), in `[0,1)^3`. Deterministic and
    /// reproducible: unlike a PRNG, two calls with the same `index` always agree, matching every
    /// other diagnostic sampler in this codebase (fixed Fibonacci-sphere / splitmix64 patterns).
    /// `index` should start at 1; index 0 is the degenerate all-zero point every base shares.
    static func haltonPoint(index: Int) -> SIMD3<Double> {
        SIMD3(halton(index, base: 2), halton(index, base: 3), halton(index, base: 5))
    }

    static func halton(_ index: Int, base: Int) -> Double {
        var result = 0.0
        var f = 1.0
        var i = index
        while i > 0 {
            f /= Double(base)
            result += f * Double(i % base)
            i /= base
        }
        return result
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.4g", v) }
}
