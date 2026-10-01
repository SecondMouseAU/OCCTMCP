// OppositeFaces: advisory "face on the far side" hints for planar faces
// (#199). A candidate is anti-parallel, lies behind the face along its
// outward normal, and overlaps it when both are projected into the face's
// plane. `exact` compares the two face outlines; `bbox` compares projected
// bounding boxes and can over-report on L-shaped faces.

import Foundation
import OCCTSwift
import simd

public enum OppositeFaces {

    public enum Method: String {
        case exact
        case bbox
    }

    /// The opposite face found for one face.
    public struct Hit: Encodable, Equatable {
        public let index: Int
        public let distance: Double
        /// The method that decided this hit.
        ///
        /// `bbox` under an `exact` request means the outline could not be traced.
        public let method: String
    }

    struct PlaneFace {
        let index: Int
        let face: Face
        let center: SIMD3<Double>
        let normal: SIMD3<Double>
        let bounds: (min: SIMD3<Double>, max: SIMD3<Double>)
    }

    typealias Basis = (u: SIMD3<Double>, v: SIMD3<Double>)

    /// Resolves opposite faces against one shape's planar faces.
    public final class Finder {
        private let planes: [Int: PlaneFace]
        private let ordered: [PlaneFace]
        private let method: Method
        private var outlineCache: [Int: [SIMD3<Double>]?] = [:]
        /// Pair tests that fell back from `exact` to the box test.
        public private(set) var fallbackCount = 0

        public init(faces: [Face], method: Method) {
            var planes: [Int: PlaneFace] = [:]
            for (index, face) in faces.enumerated() where face.surfaceType == .plane {
                let (center, normal) = SelectionTools.faceCenterAndNormal(face: face)
                guard let normal, face.uvBounds != nil, let bounds = face.bounds else { continue }
                let length = simd_length(normal)
                guard length > 1e-12 else { continue }
                planes[index] = PlaneFace(
                    index: index, face: face, center: center, normal: normal / length,
                    bounds: bounds)
            }
            self.planes = planes
            self.ordered = planes.values.sorted { $0.index < $1.index }
            self.method = method
        }

        /// The nearest overlapping anti-parallel face behind `index`, if any.
        public func opposite(of index: Int) -> Hit? {
            guard let base = planes[index] else { return nil }
            var candidates: [(plane: PlaneFace, distance: Double)] = []
            let extent = simd_length(base.bounds.max - base.bounds.min)
            for other in ordered where other.index != index {
                guard simd_dot(base.normal, other.normal) < -0.9999 else { continue }
                let behind = -simd_dot(other.center - base.center, base.normal)
                guard behind > max(1e-6, 1e-9 * extent) else { continue }
                candidates.append((other, behind))
            }
            candidates.sort { ($0.distance, $0.plane.index) < ($1.distance, $1.plane.index) }
            for candidate in candidates {
                let (overlaps, used) = overlap(base, candidate.plane)
                if overlaps {
                    // Count only fallbacks that produced a reported hit; a pair the bbox test
                    // rejected changes no result.
                    if method == .exact && used == .bbox { fallbackCount += 1 }
                    return Hit(
                        index: candidate.plane.index, distance: candidate.distance,
                        method: used.rawValue)
                }
            }
            return nil
        }

        private func overlap(_ base: PlaneFace, _ other: PlaneFace) -> (Bool, Method) {
            let basis = Self.basis(for: base.normal)
            let extent = simd_length(base.bounds.max - base.bounds.min)
            if method == .exact, let first = outline(of: base), let second = outline(of: other) {
                let a = first.map { Self.project($0, origin: base.center, basis: basis) }
                let b = second.map { Self.project($0, origin: base.center, basis: basis) }
                return (PolygonOverlap.overlaps(a, b, scale: extent), .exact)
            }
            let a = Self.projectedBox(base.bounds, origin: base.center, basis: basis)
            let b = Self.projectedBox(other.bounds, origin: base.center, basis: basis)
            let tolerance = max(1e-9, 1e-6 * extent)
            let overlapU = min(a.max.x, b.max.x) - max(a.min.x, b.min.x)
            let overlapV = min(a.max.y, b.max.y) - max(a.min.y, b.min.y)
            return (overlapU > tolerance && overlapV > tolerance, .bbox)
        }

        private func outline(of plane: PlaneFace) -> [SIMD3<Double>]? {
            if let cached = outlineCache[plane.index] { return cached }
            let extent = simd_length(plane.bounds.max - plane.bounds.min)
            let traced = Self.tracedOuterOutline(plane.face, extent: extent)
            outlineCache[plane.index] = .some(traced)
            return traced
        }

        static func basis(for normal: SIMD3<Double>) -> Basis {
            let axis: SIMD3<Double> = abs(normal.x) < 0.6 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let u = simd_normalize(simd_cross(normal, axis))
            return (u, simd_cross(normal, u))
        }

        static func project(_ point: SIMD3<Double>, origin: SIMD3<Double>, basis: Basis)
            -> SIMD2<Double>
        {
            let d = point - origin
            return SIMD2(simd_dot(d, basis.u), simd_dot(d, basis.v))
        }

        static func projectedBox(
            _ box: (min: SIMD3<Double>, max: SIMD3<Double>), origin: SIMD3<Double>, basis: Basis
        ) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
            var lo = SIMD2<Double>(repeating: .infinity)
            var hi = SIMD2<Double>(repeating: -.infinity)
            for ix in 0..<2 {
                for iy in 0..<2 {
                    for iz in 0..<2 {
                        let corner = SIMD3(
                            ix == 0 ? box.min.x : box.max.x, iy == 0 ? box.min.y : box.max.y,
                            iz == 0 ? box.min.z : box.max.z)
                        let p = project(corner, origin: origin, basis: basis)
                        lo = simd_min(lo, p)
                        hi = simd_max(hi, p)
                    }
                }
            }
            return (lo, hi)
        }

        /// The face's outer wire as one closed point loop, or nil if its edges do not chain.
        static func tracedOuterOutline(_ face: Face, extent: Double) -> [SIMD3<Double>]? {
            guard let wire = face.outerWire else { return nil }
            let deflection = max(1e-6, 0.005 * extent)
            var pieces = wire.allEdgePolylines(deflection: deflection, maxPointsPerEdge: 400)
                .filter { $0.count >= 2 }
            guard !pieces.isEmpty else { return nil }
            let tolerance = max(1e-7, 1e-5 * extent)
            var loop = pieces.removeFirst()
            while !pieces.isEmpty {
                guard let tail = loop.last else { return nil }
                var matched = false
                for (i, piece) in pieces.enumerated() {
                    if simd_distance(piece[0], tail) <= tolerance {
                        loop.append(contentsOf: piece.dropFirst())
                    } else if let end = piece.last, simd_distance(end, tail) <= tolerance {
                        loop.append(contentsOf: piece.reversed().dropFirst())
                    } else {
                        continue
                    }
                    pieces.remove(at: i)
                    matched = true
                    break
                }
                if !matched { return nil }
            }
            guard loop.count >= 4, let head = loop.first, let tail = loop.last,
                simd_distance(head, tail) <= tolerance
            else { return nil }
            loop.removeLast()
            return loop
        }
    }
}

/// Positive-area overlap test for two simple 2D polygons.
enum PolygonOverlap {

    static func overlaps(_ first: [SIMD2<Double>], _ second: [SIMD2<Double>], scale: Double)
        -> Bool
    {
        let tolerance = max(1e-9, 1e-6 * scale)
        let offset = max(10 * tolerance, 1e-3 * scale)
        let a = counterClockwise(first)
        let b = counterClockwise(second)
        guard a.count >= 3, b.count >= 3 else { return false }

        for i in 0..<a.count {
            for j in 0..<b.count
            where properlyCross(a[i], a[(i + 1) % a.count], b[j], b[(j + 1) % b.count]) {
                return true
            }
        }
        for p in a where strictlyInside(p, b, tolerance) { return true }
        for p in b where strictlyInside(p, a, tolerance) { return true }

        // Coincident boundaries: probe just inside each edge of one polygon.
        for (poly, other) in [(a, b), (b, a)] {
            for i in 0..<poly.count {
                let p = poly[i]
                let q = poly[(i + 1) % poly.count]
                let direction = q - p
                let length = simd_length(direction)
                guard length > tolerance else { continue }
                let inward = SIMD2(-direction.y, direction.x) / length
                // Clamp to the edge length so the probe stays inside a thin polygon.
                let probe = (p + q) * 0.5 + inward * min(offset, 0.1 * length)
                if strictlyInside(probe, poly, tolerance)
                    && strictlyInside(probe, other, tolerance)
                {
                    return true
                }
            }
        }
        return false
    }

    private static func counterClockwise(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var area = 0.0
        for i in 0..<points.count {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            area += p.x * q.y - q.x * p.y
        }
        return area < 0 ? points.reversed() : points
    }

    private static func properlyCross(
        _ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>
    ) -> Bool {
        let r = p2 - p1
        let s = q2 - q1
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-15 else { return false }
        let d = q1 - p1
        let t = (d.x * s.y - d.y * s.x) / denominator
        let u = (d.x * r.y - d.y * r.x) / denominator
        let margin = 1e-7
        return t > margin && t < 1 - margin && u > margin && u < 1 - margin
    }

    private static func strictlyInside(
        _ point: SIMD2<Double>, _ polygon: [SIMD2<Double>], _ tolerance: Double
    ) -> Bool {
        var inside = false
        var nearest = Double.infinity
        for i in 0..<polygon.count {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            let edge = b - a
            let lengthSquared = simd_dot(edge, edge)
            let t =
                lengthSquared > 0 ? max(0, min(1, simd_dot(point - a, edge) / lengthSquared)) : 0
            nearest = min(nearest, simd_distance(point, a + edge * t))
        }
        return inside && nearest > tolerance
    }
}
