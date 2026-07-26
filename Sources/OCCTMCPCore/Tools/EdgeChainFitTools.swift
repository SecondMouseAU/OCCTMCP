// EdgeChainFitTools: `fit_edge_chain` (#121). Segments an ordered 3D point
// chain (a mesh crease/boundary chain, or any other polyline) into line and
// circular-arc runs: per-segment kind, endpoints, direction (line) or
// center/radius/axis/startAngle/endAngle (arc), and fit residuals. The
// geometry lives in `EdgeChainMath.swift`; this file is the MCP glue.
//
// Takes `points` directly rather than a bodyId + selectionId: the natural
// source is `detect_mesh_features(includePoints: true)`'s per-ring polyline
// (#120), but any ordered chain works, and this tool has no OCCT dependency
// at all as a result. `fit_primitives`/`segment_mesh_zones` RANSAC-fit
// SURFACES (cylinder/sphere/cone/plane) over a mesh's triangles; nothing
// upstream of this fits a circle/arc to an EDGE chain, which is the case a
// raw STL's blend radii only exist as (a chain of straight facet edges
// approximating a curve, #121).

import Foundation
import simd

public enum EdgeChainFitTools {

    public struct SegmentEntry: Encodable {
        public let startIndex: Int
        public let endIndex: Int
        public let pointCount: Int
        public let kind: String   // "line" | "arc"
        public let startPoint: [Double]
        public let endPoint: [Double]
        /// Unit direction, oriented start point to end point. Present for
        /// "line" segments only.
        public let direction: [Double]?
        /// Present for "arc" segments only.
        public let center: [Double]?
        public let radius: Double?
        public let axis: [Double]?
        public let startAngle: Double?
        public let endAngle: Double?
        public let maxResidualMm: Double
        public let rmsResidualMm: Double
    }

    public struct EdgeChainFitReport: Encodable {
        public let pointCount: Int
        public let closed: Bool
        public let toleranceMm: Double
        public let segmentCount: Int
        public let segments: [SegmentEntry]
        public let warnings: [String]
    }

    public static func fitEdgeChain(
        points: [SIMD3<Double>],
        closed: Bool = false,
        toleranceMm: Double? = nil
    ) async -> ToolText {
        guard points.count >= 2 else {
            return .init("fit_edge_chain requires at least 2 points.", isError: true)
        }
        let tol = toleranceMm ?? defaultTolerance(points)
        guard tol > 0 else {
            return .init("toleranceMm must be positive.", isError: true)
        }

        let segs = EdgeChainMath.segment(points: points, toleranceMm: tol)

        var warnings: [String] = []
        if closed {
            warnings.append(
                "closed:true is not yet segmented across the wrap (last point back to first): the chain is treated as open, starting at index 0. A run that truly straddles the chain's own start point reads as two segments instead of one."
            )
        }

        let entries = segs.map { seg -> SegmentEntry in
            let start = points[seg.startIndex], end = points[seg.endIndex]
            switch seg.fit {
            case .line(let l):
                return SegmentEntry(
                    startIndex: seg.startIndex, endIndex: seg.endIndex,
                    pointCount: seg.endIndex - seg.startIndex + 1, kind: "line",
                    startPoint: [start.x, start.y, start.z], endPoint: [end.x, end.y, end.z],
                    direction: [l.direction.x, l.direction.y, l.direction.z],
                    center: nil, radius: nil, axis: nil, startAngle: nil, endAngle: nil,
                    maxResidualMm: l.maxResidual, rmsResidualMm: l.rmsResidual
                )
            case .arc(let a):
                return SegmentEntry(
                    startIndex: seg.startIndex, endIndex: seg.endIndex,
                    pointCount: seg.endIndex - seg.startIndex + 1, kind: "arc",
                    startPoint: [start.x, start.y, start.z], endPoint: [end.x, end.y, end.z],
                    direction: nil,
                    center: [a.center.x, a.center.y, a.center.z], radius: a.radius,
                    axis: [a.axis.x, a.axis.y, a.axis.z],
                    startAngle: a.startAngle, endAngle: a.endAngle,
                    maxResidualMm: a.maxResidual, rmsResidualMm: a.rmsResidual
                )
            }
        }

        return IntrospectionTools.encode(EdgeChainFitReport(
            pointCount: points.count, closed: closed, toleranceMm: tol,
            segmentCount: entries.count, segments: entries, warnings: warnings
        ))
    }

    /// 0.5% of the chain's own bbox diagonal, the same scaling convention
    /// `DeviationTools.defaultDeflection` uses, with the same 1um floor.
    static func defaultTolerance(_ points: [SIMD3<Double>]) -> Double {
        guard !points.isEmpty else { return 1e-6 }
        var lo = points[0], hi = points[0]
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return Swift.max(simd_length(hi - lo) * 0.005, 1e-6)
    }
}
