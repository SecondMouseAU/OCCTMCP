// DeviationHistogramTool — `deviation_histogram` (#62).
//
// Where `measure_deviation` aggregates to a handful of scalars, this returns the
// full *distribution* of the signed point-to-surface deviation of `fromBodyId`
// against `referenceBodyId`: μ, σ, median, p95, the proud/shy extremes, the
// fraction within ±tolerance, and a bucket histogram — plus an optional PNG.
//
// Read the shape, not just the number: a tight unimodal histogram centred on 0
// is honest noise; a histogram with a non-zero mean or two separate humps is a
// *systematic* shape error (the carbody-cross-section bug that motivated #61/#62)
// even when the headline mean looks small.

import Foundation
import OCCTSwift
import simd

public enum DeviationHistogramTool {

    public struct Bucket: Encodable {
        public let lo: Double
        public let hi: Double
        public let count: Int
    }

    public struct HistogramReport: Encodable {
        public let from: String
        public let reference: String
        public let deflection: Double
        public let samples: Int
        /// Samples backing the signed figures + buckets — those whose sign is
        /// trustworthy (#72). Magnitude figures (p95/maxAbs/withinTolerance) use
        /// all `samples`.
        public let signedSamples: Int
        /// Samples whose sign couldn't be established. Near `samples` ⇒ the
        /// reference is open / thin-walled (or inverted-winding) and the
        /// distribution's SIGN axis is not meaningful for this pair.
        public let ambiguousSamples: Int
        public let ambiguousFraction: Double
        /// Which correspondence rule chose each sample's reference triangle.
        public let signMode: String
        /// Mean of the signed deviation (μ). Non-zero ⇒ systematic proud/shy bias.
        /// nil when `signedSamples == 0` — no trustworthy sign to average, which
        /// zero would misreport as "perfectly centred".
        public let mean: Double?
        /// Standard deviation (σ) of the signed deviation. nil as for `mean`.
        public let std: Double?
        /// Median signed deviation. nil as for `mean`.
        public let median: Double?
        /// 95th percentile of the distance to the NEAREST reference surface.
        /// Unaffected by `signMode` — a magnitude, not a side.
        public let p95: Double
        /// Extremes of the signed deviation. nil as for `mean`.
        public let signedMin: Double?
        public let signedMax: Double?
        /// Largest distance to the nearest reference surface. As `p95`, a pure
        /// magnitude — so `maxAbs` can be smaller than `|signedMin|` against an
        /// open thin-walled reference, where the nearest surface and the
        /// corresponding one are different surfaces (#72).
        public let maxAbs: Double
        public let tolerance: Double?
        /// Fraction of samples within `tolerance` of the nearest reference
        /// surface (0…1). Nil if no tol. A magnitude test, so `signMode` doesn't
        /// move it.
        public let withinTolerance: Double?
        /// The signed distribution. Empty when `signedSamples == 0`.
        public let buckets: [Bucket]
        public let imagePath: String?
    }

    public static func deviationHistogram(
        fromBodyId: String,
        referenceBodyId: String,
        deflection: Double? = nil,
        bins: Int = 40,
        maxSamples: Int = 50_000,
        tolerance: Double? = nil,
        signMode: DeviationTools.SignMode = .robust,
        outputPath: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let fromShape: Shape, refShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            refShape = try IntrospectionTools.loadShape(bodyId: referenceBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        let defl = deflection ?? DeviationTools.defaultDeflection(for: fromShape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }

        guard let fromTris = DeviationTools.TriMesh(shape: fromShape, deflection: defl) else {
            return .init("Failed to tessellate '\(fromBodyId)'.", isError: true)
        }
        guard let refTris = DeviationTools.TriMesh(shape: refShape, deflection: defl) else {
            return .init("Failed to tessellate '\(referenceBodyId)'.", isError: true)
        }

        // Stride-subsample the source vertices to honour the sample cap, carrying
        // each sample's own outward normal so `.robust` can reject the far side
        // of a thin wall as its counterpart (#72). `.nearest` never consults them,
        // so don't pay for them there.
        let wantNormals = signMode == .robust
        let all = fromTris.vertices
        let stride = maxSamples > 0 ? max(1, (all.count + maxSamples - 1) / maxSamples) : 1
        var points: [SIMD3<Double>] = []
        var normals: [SIMD3<Double>] = []
        points.reserveCapacity((all.count + stride - 1) / stride)
        if wantNormals { normals.reserveCapacity(points.capacity) }
        var i = 0
        while i < all.count {
            points.append(all[i])
            if wantNormals { normals.append(fromTris.vertexNormal(i)) }
            i += stride
        }

        let hits = DeviationTools.signedDistances(
            of: points, normals: wantNormals ? normals : nil, to: refTris, signMode: signMode)
        guard !hits.isEmpty else { return .init("No samples produced.", isError: true) }

        // The distribution is a SIGNED quantity, so it's built from sign-reliable
        // samples only (#72) — a flipped sign plants a mirror hump at −d and reads
        // as the two-humped systematic error this tool exists to spot. The
        // magnitude-only figures below are a different measurement entirely: they
        // track the NEAREST reference surface, unchanged by signMode, where the
        // signed values track the surface each sample corresponds to.
        let magnitudes = hits.map { $0.nearest }
        let signed = hits.filter { !$0.ambiguous }.map { $0.signed }
        let ambiguous = hits.count - signed.count

        // Aggregate stats. Signed ones are nil when nothing had a trustworthy
        // sign — zero would read as "perfectly centred" rather than "unavailable".
        let n = Double(signed.count)
        let mean = signed.isEmpty ? nil : signed.reduce(0, +) / n
        var std: Double? = nil
        if let mean {
            let sumSq = signed.reduce(0) { $0 + $1 * $1 }
            std = max(0, sumSq / n - mean * mean).squareRoot()
        }
        let sortedSigned = signed.sorted()
        let median = signed.isEmpty ? nil : DeviationTools.percentile(sortedSigned, 0.5)
        let absSorted = magnitudes.sorted()
        let p95 = DeviationTools.percentile(absSorted, 0.95)
        let maxAbs = absSorted.last ?? 0
        let signedMin = sortedSigned.first
        let signedMax = sortedSigned.last

        var within: Double? = nil
        if let tol = tolerance, tol >= 0 {
            let ok = magnitudes.reduce(0) { $0 + ($1 <= tol ? 1 : 0) }
            within = Double(ok) / Double(magnitudes.count)
        }

        // Buckets across the signed range. Empty when no sample had a trustworthy
        // sign: there is no signed distribution to bucket, and inventing one from
        // guessed signs is the failure this whole change is about.
        let nb = max(2, bins)
        var buckets: [Bucket] = []
        if var lo = signedMin, var hi = signedMax {
            if hi - lo < 1e-9 { lo -= 0.5; hi += 0.5 }
            let bw = (hi - lo) / Double(nb)
            var counts = [Int](repeating: 0, count: nb)
            for v in signed {
                var b = Int((v - lo) / bw)
                if b >= nb { b = nb - 1 }
                if b < 0 { b = 0 }
                counts[b] += 1
            }
            buckets = (0..<nb).map { Bucket(lo: lo + Double($0) * bw, hi: lo + Double($0 + 1) * bw, count: counts[$0]) }
        }

        // Optional PNG — only when there's a signed distribution to draw.
        var imagePath: String? = nil
        if let outputPath, let mean, let std {
            do {
                try ChartRenderer.histogram(
                    values: signed, tolerance: tolerance, bins: nb,
                    title: "signed deviation  \(fromBodyId) → \(referenceBodyId)  (μ=\(String(format: "%.3g", mean)), σ=\(String(format: "%.3g", std)))",
                    to: URL(fileURLWithPath: outputPath)
                )
                imagePath = outputPath
            } catch {
                return .init("Histogram render failed: \(error)", isError: true)
            }
        }

        let report = HistogramReport(
            from: fromBodyId, reference: referenceBodyId, deflection: defl,
            samples: hits.count, signedSamples: signed.count,
            ambiguousSamples: ambiguous,
            ambiguousFraction: Double(ambiguous) / Double(hits.count),
            signMode: signMode.rawValue,
            mean: mean, std: std, median: median, p95: p95,
            signedMin: signedMin, signedMax: signedMax, maxAbs: maxAbs,
            tolerance: tolerance, withinTolerance: within, buckets: buckets, imagePath: imagePath
        )
        return IntrospectionTools.encode(report)
    }
}
