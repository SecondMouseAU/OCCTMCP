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
        /// Mean of the signed deviation (μ). Non-zero ⇒ systematic proud/shy bias.
        public let mean: Double
        /// Standard deviation (σ) of the signed deviation.
        public let std: Double
        /// Median signed deviation.
        public let median: Double
        /// 95th percentile of |deviation|.
        public let p95: Double
        public let signedMin: Double
        public let signedMax: Double
        public let maxAbs: Double
        public let tolerance: Double?
        /// Fraction of samples with |deviation| ≤ tolerance (0…1). Nil if no tol.
        public let withinTolerance: Double?
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

        // Stride-subsample the source vertices to honour the sample cap.
        let all = fromTris.vertices
        let stride = maxSamples > 0 ? max(1, (all.count + maxSamples - 1) / maxSamples) : 1
        var points: [SIMD3<Double>] = []
        points.reserveCapacity((all.count + stride - 1) / stride)
        var i = 0
        while i < all.count { points.append(all[i]); i += stride }

        let signed = DeviationTools.signedDistances(of: points, to: refTris)
        guard !signed.isEmpty else { return .init("No samples produced.", isError: true) }

        // Aggregate stats.
        let n = Double(signed.count)
        let sum = signed.reduce(0, +)
        let mean = sum / n
        let sumSq = signed.reduce(0) { $0 + $1 * $1 }
        let variance = max(0, sumSq / n - mean * mean)
        let std = variance.squareRoot()
        let sortedSigned = signed.sorted()
        let median = DeviationTools.percentile(sortedSigned, 0.5)
        let absSorted = signed.map { abs($0) }.sorted()
        let p95 = DeviationTools.percentile(absSorted, 0.95)
        let maxAbs = absSorted.last ?? 0
        let signedMin = sortedSigned.first ?? 0
        let signedMax = sortedSigned.last ?? 0

        var within: Double? = nil
        if let tol = tolerance, tol >= 0 {
            let ok = signed.reduce(0) { $0 + (abs($1) <= tol ? 1 : 0) }
            within = Double(ok) / n
        }

        // Buckets across the signed range.
        var lo = signedMin, hi = signedMax
        if hi - lo < 1e-9 { lo -= 0.5; hi += 0.5 }
        let nb = max(2, bins)
        let bw = (hi - lo) / Double(nb)
        var counts = [Int](repeating: 0, count: nb)
        for v in signed {
            var b = Int((v - lo) / bw)
            if b >= nb { b = nb - 1 }
            if b < 0 { b = 0 }
            counts[b] += 1
        }
        let buckets = (0..<nb).map { Bucket(lo: lo + Double($0) * bw, hi: lo + Double($0 + 1) * bw, count: counts[$0]) }

        // Optional PNG.
        var imagePath: String? = nil
        if let outputPath {
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
            samples: signed.count, mean: mean, std: std, median: median, p95: p95,
            signedMin: signedMin, signedMax: signedMax, maxAbs: maxAbs,
            tolerance: tolerance, withinTolerance: within, buckets: buckets, imagePath: imagePath
        )
        return IntrospectionTools.encode(report)
    }
}
