// DrawingEntities: turns SwiftDXF entities into the plain records the drawing read tools return:
// an id, a type, a layer, the geometry as numbers and an axis-aligned bounding box. Every
// coordinate is in drawing units; nothing here converts to millimetres.

import Foundation
import OCCTSwiftIO

/// The entity-level view of one drawing: ids, geometry and bounds.
enum DrawingEntities {

    /// An entity's id: `e` and its position in the drawing's entity list.
    ///
    /// DXF handles are not kept by SwiftDXF, so identity is the index, which is stable for the same
    /// file bytes. `read_drawing` returns the file's SHA-256 so a caller can tell when ids no longer
    /// refer to what they did.
    static func id(_ index: Int) -> String { "e\(index)" }

    /// The index an id names, nil for anything that is not exactly what `id(_:)` returns.
    ///
    /// `e+5`, `e007` and `e-1` are refused, so an id has one spelling and never indexes backwards.
    static func index(of id: String) -> Int? {
        guard id.hasPrefix("e"), let n = Int(id.dropFirst()), n >= 0, id == Self.id(n) else {
            return nil
        }
        return n
    }

    // `DXF.Entity` gains cases when SwiftDXF does (0.3.0 adds `spline`, and OCCTSwiftIO 2.0.0-beta.5
    // requires it), so every switch over it ends in `@unknown default`: a build that resolves a newer
    // SwiftDXF compiles, and reads an entity it has no mapping for as type `other`, with no layer,
    // colour, bounds or geometry (nothing is made up), and `read_drawing` warns about it.

    static func typeName(_ entity: DXF.Entity) -> String {
        switch entity {
        case .line: return "line"
        case .circle: return "circle"
        case .arc: return "arc"
        case .ellipse: return "ellipse"
        case .point: return "point"
        case .text: return "text"
        case .polyline: return "polyline"
        case .dimension: return "dimension"
        @unknown default: return "other"
        }
    }

    /// The type names in the order the tools list them.
    static let typeNames = [
        "line", "circle", "arc", "ellipse", "point", "text", "polyline", "dimension",
    ]

    /// The entity's layer, nil for an entity this build has no mapping for (it is not made up).
    static func layer(_ entity: DXF.Entity) -> String? {
        switch entity {
        case .line(_, _, let layer, _), .circle(_, _, let layer, _), .arc(_, _, _, _, let layer, _),
            .ellipse(_, _, _, _, _, let layer, _), .point(_, let layer, _),
            .text(_, _, _, _, let layer, _), .polyline(_, _, let layer, _):
            return layer
        case .dimension(let d):
            return d.layer
        @unknown default:
            return nil
        }
    }

    /// The entity's AutoCAD Color Index, nil for an entity this build has no mapping for.
    static func color(_ entity: DXF.Entity) -> Int? {
        switch entity {
        case .line(_, _, _, let color), .circle(_, _, _, let color), .arc(_, _, _, _, _, let color),
            .ellipse(_, _, _, _, _, _, let color), .point(_, _, let color),
            .text(_, _, _, _, _, let color), .polyline(_, _, _, let color):
            return color
        case .dimension(let d):
            return d.color
        @unknown default:
            return nil
        }
    }

    static func xyz(_ p: DXF.Point) -> [Double] { [p.x, p.y, p.z] }

    // MARK: Geometry helpers

    /// An arc's sweep in degrees, counter-clockwise from `startDeg` to `endDeg`, in (0, 360].
    static func sweepDeg(startDeg: Double, endDeg: Double) -> Double {
        var sweep = (endDeg - startDeg).truncatingRemainder(dividingBy: 360)
        if sweep <= 0 { sweep += 360 }
        return sweep
    }

    /// The arc a polyline bulge describes, counter-clockwise.
    struct BulgeArc {
        let center: DXF.Point
        let radius: Double
        /// Start and end angle in radians, `start < end`, sweeping counter-clockwise.
        let start: Double
        let end: Double
        var length: Double { radius * (end - start) }
    }

    /// The arc a polyline bulge describes between two vertices.
    ///
    /// `bulge` is `tan(θ/4)` for the included angle θ, positive when the arc runs counter-clockwise
    /// from `a` to `b` and negative when it runs clockwise. Returns nil for a straight segment or
    /// coincident vertices.
    static func bulgeArc(from a: DXF.Point, to b: DXF.Point, bulge: Double) -> BulgeArc? {
        guard abs(bulge) > 1e-12, a.x != b.x || a.y != b.y else { return nil }
        let h = (1 / bulge - bulge) / 2
        let cx = (a.x + b.x) / 2 + h * (a.y - b.y) / 2
        let cy = (a.y + b.y) / 2 + h * (b.x - a.x) / 2
        let radius = ((a.x - cx) * (a.x - cx) + (a.y - cy) * (a.y - cy)).squareRoot()
        guard radius > 0 else { return nil }
        let phi1 = atan2(a.y - cy, a.x - cx)
        let theta = 4 * atan(bulge)
        return BulgeArc(
            center: DXF.Point(cx, cy, a.z), radius: radius,
            start: min(phi1, phi1 + theta), end: max(phi1, phi1 + theta))
    }

    /// Length of a polyline: straight segments plus the arc each bulged segment follows.
    static func polylineLength(_ vertices: [DXF.PolyVertex], closed: Bool) -> Double {
        guard vertices.count >= 2 else { return 0 }
        let count = vertices.count
        var total = 0.0
        for i in 0..<(closed ? count : count - 1) {
            let a = vertices[i]
            let b = vertices[(i + 1) % count]
            if let arc = bulgeArc(from: a.point, to: b.point, bulge: a.bulge) {
                total += arc.length
            } else {
                total += distance(a.point, b.point)
            }
        }
        return total
    }

    static func distance(_ a: DXF.Point, _ b: DXF.Point) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    // MARK: Bounds

    struct Bounds: Sendable {
        var min: DXF.Point
        var max: DXF.Point

        init(_ p: DXF.Point) {
            min = p
            max = p
        }

        mutating func include(_ p: DXF.Point) {
            min = DXF.Point(Swift.min(min.x, p.x), Swift.min(min.y, p.y), Swift.min(min.z, p.z))
            max = DXF.Point(Swift.max(max.x, p.x), Swift.max(max.y, p.y), Swift.max(max.z, p.z))
        }

        /// Whether the boxes overlap in the sheet plane (x and y; z is ignored).
        func intersects(xmin: Double, ymin: Double, xmax: Double, ymax: Double) -> Bool {
            max.x >= xmin && min.x <= xmax && max.y >= ymin && min.y <= ymax
        }

        func within(xmin: Double, ymin: Double, xmax: Double, ymax: Double) -> Bool {
            min.x >= xmin && max.x <= xmax && min.y >= ymin && max.y <= ymax
        }
    }

    /// Tight bounds of a counter-clockwise arc: its end points and any axis extreme it sweeps.
    private static func include(
        arc center: DXF.Point, radius: Double, start: Double, end: Double, into bounds: inout Bounds
    ) {
        func at(_ angle: Double) -> DXF.Point {
            DXF.Point(center.x + radius * cos(angle), center.y + radius * sin(angle), center.z)
        }
        bounds.include(at(start))
        bounds.include(at(end))
        // Angles of the four axis extremes that fall inside (start, end).
        let quarter = Double.pi / 2
        var extreme = (start / quarter).rounded(.up) * quarter
        while extreme < end {
            if extreme > start { bounds.include(at(extreme)) }
            extreme += quarter
        }
    }

    /// The axis-aligned bounds of an entity, nil when it has no position (an empty polyline).
    ///
    /// Arcs and bulged polyline segments are tight. An elliptical arc takes the bounds of its
    /// whole ellipse. Text is its insertion point, since the reader keeps no text extent.
    static func bounds(of entity: DXF.Entity) -> Bounds? {
        switch entity {
        case .line(let a, let b, _, _):
            var box = Bounds(a)
            box.include(b)
            return box
        case .circle(let c, let r, _, _):
            var box = Bounds(DXF.Point(c.x - r, c.y - r, c.z))
            box.include(DXF.Point(c.x + r, c.y + r, c.z))
            return box
        case .arc(let c, let r, let startDeg, let endDeg, _, _):
            let start = startDeg * .pi / 180
            let end = start + sweepDeg(startDeg: startDeg, endDeg: endDeg) * .pi / 180
            // Not seeded with the centre: an arc under half a turn does not contain it.
            var box = Bounds(DXF.Point(c.x + r * cos(start), c.y + r * sin(start), c.z))
            include(arc: c, radius: r, start: start, end: end, into: &box)
            return box
        case .ellipse(let c, let m, let ratio, _, _, _, _):
            let nx = -m.y * ratio
            let ny = m.x * ratio
            let ex = (m.x * m.x + nx * nx).squareRoot()
            let ey = (m.y * m.y + ny * ny).squareRoot()
            var box = Bounds(DXF.Point(c.x - ex, c.y - ey, c.z))
            box.include(DXF.Point(c.x + ex, c.y + ey, c.z))
            return box
        case .point(let p, _, _):
            return Bounds(p)
        case .text(let p, _, _, _, _, _):
            return Bounds(p)
        case .polyline(let vertices, let closed, _, _):
            guard let first = vertices.first else { return nil }
            var box = Bounds(first.point)
            for v in vertices { box.include(v.point) }
            let count = vertices.count
            if count >= 2 {
                for i in 0..<(closed ? count : count - 1) {
                    let a = vertices[i]
                    let b = vertices[(i + 1) % count]
                    if let arc = bulgeArc(from: a.point, to: b.point, bulge: a.bulge) {
                        include(
                            arc: arc.center, radius: arc.radius, start: arc.start, end: arc.end,
                            into: &box)
                    }
                }
            }
            return box
        case .dimension(let d):
            var box = Bounds(d.defPoint)
            box.include(d.textPosition)
            for p in [d.defPoint2, d.defPoint3, d.defPoint4, d.defPoint5] {
                if let p { box.include(p) }
            }
            return box
        @unknown default:
            return nil
        }
    }
}
