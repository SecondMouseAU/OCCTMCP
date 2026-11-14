// DrawingReadTools+Hatch: a hatch's boundary paths as numbers (#271).

import Foundation
import OCCTSwiftIO

extension DrawingReadTools {

    /// One boundary path of a hatch.
    struct HatchPathRecord: Encodable {
        /// Whether it is the outer boundary; a path that is not is an island or a hole.
        let external: Bool
        /// `polyline` (vertices with bulges) or `edges` (a chain of lines, arcs, ellipse arcs and
        /// splines).
        let kind: String
        var vertices: [[Double]]?
        var bulges: [Double]?
        var closed: Bool?
        var edges: [HatchEdgeRecord]?
    }

    /// One edge of a hatch boundary path, in the drawing plane (z is 0).
    struct HatchEdgeRecord: Encodable {
        /// `line`, `arc`, `ellipse` or `spline`.
        let type: String
        var start: [Double]?
        var end: [Double]?
        var center: [Double]?
        var radius: Double?
        var startAngleDeg: Double?
        var endAngleDeg: Double?
        var majorAxis: [Double]?
        var ratio: Double?
        var startParam: Double?
        var endParam: Double?
        /// For an arc or an ellipse arc: whether the path travels it counter-clockwise.
        var counterClockwise: Bool?
        var degree: Int?
        var controlPoints: [[Double]]?
        var knots: [Double]?
    }

    /// A hatch boundary path as numbers.
    static func hatchPathRecord(_ path: DXF.Hatch.BoundaryPath) -> HatchPathRecord {
        func xy(_ p: DXF.Point2) -> [Double] { [p.x, p.y, 0] }
        switch path.geometry {
        case .polyline(let vertices, let closed):
            var record = HatchPathRecord(external: path.isExternal, kind: "polyline")
            record.vertices = vertices.map { DrawingEntities.xyz($0.point) }
            if vertices.contains(where: { $0.bulge != 0 }) { record.bulges = vertices.map(\.bulge) }
            record.closed = closed
            return record
        case .edges(let edges):
            var record = HatchPathRecord(external: path.isExternal, kind: "edges")
            record.edges = edges.map { edge in
                switch edge {
                case .line(let a, let b):
                    var out = HatchEdgeRecord(type: "line")
                    out.start = xy(a)
                    out.end = xy(b)
                    return out
                case .arc(let c, let r, let startDeg, let endDeg, let ccw):
                    var out = HatchEdgeRecord(type: "arc")
                    out.center = xy(c)
                    out.radius = r
                    out.startAngleDeg = startDeg
                    out.endAngleDeg = endDeg
                    out.counterClockwise = ccw
                    return out
                case .ellipse(let c, let m, let ratio, let startParam, let endParam, let ccw):
                    var out = HatchEdgeRecord(type: "ellipse")
                    out.center = xy(c)
                    out.majorAxis = xy(m)
                    out.ratio = ratio
                    out.startParam = startParam
                    out.endParam = endParam
                    out.counterClockwise = ccw
                    return out
                case .spline(let spline):
                    var out = HatchEdgeRecord(type: "spline")
                    out.degree = spline.degree
                    out.controlPoints = nonEmpty(spline.controlPoints.map(DrawingEntities.xyz))
                    out.knots = nonEmpty(spline.knots)
                    return out
                }
            }
            return record
        }
    }
}
