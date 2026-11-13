// DrawingMeasureTool: measure_drawing (#260). Distance, angle or radius between named drawing
// entities or points, in drawing units and, when the drawing declares its units, in millimetres.
// Distances between entities are exact OCCT extrema over edges built from the entities, so a
// slot width is the true gap between two lines or arcs, not a count of pixels or a vertex pair.

import Foundation
import MCP
import OCCTSwift
import OCCTSwiftIO

extension DrawingReadTools {

    /// One end of a measurement: an entity named by id, or a point on the sheet.
    enum MeasureEnd {
        case entity(index: Int, entity: DXF.Entity)
        case point(DXF.Point)
    }

    struct EndRecord: Encodable {
        /// `entity` or `point`.
        let kind: String
        let id: String?
        let type: String?
        let point: [Double]?
    }

    struct MeasureResult: Encodable {
        let source: SourceRef
        let measure: String
        let a: EndRecord?
        let b: EndRecord?
        let vertex: EndRecord?
        /// The result in `unit`.
        let value: Double
        /// `drawing units` for a distance or radius, `degrees` for an angle.
        let unit: String
        /// The result in millimetres.
        ///
        /// Absent for an angle, and when the drawing's units are unknown.
        let valueMm: Double?
        let mmPerUnit: Double?
        /// For `radius`: the matching diameter, in drawing units.
        let diameter: Double?
        /// For `angle`: the angle between the two lines as undirected lines, folded into [0, 90].
        let acuteAngleDeg: Double?
        /// For `distance`: the nearest point on each end, in drawing units.
        let pointOnA: [Double]?
        let pointOnB: [Double]?
        let notes: [String]
    }

    struct MeasureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // ── argument parsing ────────────────────────────────────────────────

    /// An end given as an entity id (`e12`) or a point `[x, y]` / `[x, y, z]`.
    static func parseEnd(
        _ value: Value?, role: String, in drawing: DXF.Drawing
    ) throws -> MeasureEnd {
        guard let value else { throw MeasureError("`\(role)` is required.") }
        if let id = value.stringValue {
            guard let index = DrawingEntities.index(of: id) else {
                throw MeasureError(
                    "`\(role)` \"\(id)\" is not an entity id (e<number>) or a point.")
            }
            guard index < drawing.entities.count else {
                throw MeasureError(
                    "`\(role)` \"\(id)\" is out of range: the drawing has \(drawing.entities.count) entities."
                )
            }
            return .entity(index: index, entity: drawing.entities[index])
        }
        return .point(try parsePoint(value, role: role))
    }

    static func parsePoint(_ value: Value?, role: String) throws -> DXF.Point {
        guard let array = value?.arrayValue, array.count == 2 || array.count == 3 else {
            throw MeasureError("`\(role)` must be an entity id or a point [x, y] or [x, y, z].")
        }
        let numbers = array.compactMap { $0.numberValue }
        guard numbers.count == array.count, numbers.allSatisfy(\.isFinite) else {
            throw MeasureError("`\(role)` has a coordinate that is not a finite number.")
        }
        return DXF.Point(numbers[0], numbers[1], numbers.count == 3 ? numbers[2] : 0)
    }

    static func endRecord(_ end: MeasureEnd) -> EndRecord {
        switch end {
        case .entity(let index, let entity):
            return EndRecord(
                kind: "entity", id: DrawingEntities.id(index),
                type: DrawingEntities.typeName(entity), point: nil)
        case .point(let p):
            return EndRecord(kind: "point", id: nil, type: nil, point: DrawingEntities.xyz(p))
        }
    }

    // ── shapes for OCCT extrema ─────────────────────────────────────────

    private static let zAxis = SIMD3<Double>(0, 0, 1)

    private static func simd(_ p: DXF.Point) -> SIMD3<Double> { SIMD3(p.x, p.y, p.z) }

    // Why this is not OCCTSwiftIO's `DXFLoader`: its `load(from:)` is internal and merges every entity
    // into one compound, dropping z, so there is no edge per entity to measure from. The line, circle,
    // arc, bulge and ellipse recipes below follow it (same chord count, same bulge centre formula);
    // when OCCTSwiftIO exposes per-entity shapes this file should take them instead.

    /// The edges an entity draws, as OCCT shapes, and what to tell the caller when they only
    /// approximate it (nil when they are exact).
    ///
    /// An ellipse is cut into 48 chords, as OCCTSwiftIO's own DXF loader does, because OCCT's
    /// ellipse edge takes no major-axis direction. A spline whose control data defines a curve is an
    /// exact NURBS edge; one that does not (fit points only, a knot vector that is the wrong
    /// length) is cut into chords within a tolerance. Everything else is exact.
    static func shapes(for entity: DXF.Entity) throws -> (shapes: [Shape], approximation: String?) {
        var shapes: [Shape] = []
        var approximation: String?
        func add(_ shape: Shape?) { if let shape { shapes.append(shape) } }

        switch entity {
        case .line(let a, let b, _, _):
            if a != b { add(Shape.edgeFromPoints(simd(a), simd(b))) }
        case .circle(let c, let r, _, _):
            if r > 0 {
                add(
                    Shape.edgeFromCircle(
                        center: simd(c), axis: zAxis, radius: r, p1: 0, p2: 2 * .pi))
            }
        case .arc(let c, let r, let startDeg, let endDeg, _, _):
            if r > 0 {
                let p1 = startDeg * .pi / 180
                let p2 =
                    p1 + DrawingEntities.sweepDeg(startDeg: startDeg, endDeg: endDeg) * .pi / 180
                add(Shape.edgeFromCircle(center: simd(c), axis: zAxis, radius: r, p1: p1, p2: p2))
            }
        case .polyline(let vertices, let closed, _, _):
            if vertices.count == 1 { add(Shape.vertex(at: simd(vertices[0].point))) }
            if vertices.count >= 2 {
                for i in 0..<(closed ? vertices.count : vertices.count - 1) {
                    let a = vertices[i]
                    let b = vertices[(i + 1) % vertices.count]
                    if let arc = DrawingEntities.bulgeArc(
                        from: a.point, to: b.point, bulge: a.bulge)
                    {
                        add(
                            Shape.edgeFromCircle(
                                center: simd(arc.center), axis: zAxis, radius: arc.radius,
                                p1: arc.start, p2: arc.end))
                    } else if a.point != b.point {
                        add(Shape.edgeFromPoints(simd(a.point), simd(b.point)))
                    }
                }
            }
        case .ellipse(let c, let m, let ratio, let startParam, let endParam, _, _):
            approximation =
                "An ellipse end is approximated by 48 chords, so the distance to it is "
                + "accurate to the chord error, not exact."
            let majorR = (m.x * m.x + m.y * m.y).squareRoot()
            if majorR > 0 {
                let tilt = atan2(m.y, m.x)
                var end = endParam
                if end <= startParam { end += 2 * .pi }
                func at(_ t: Double) -> SIMD3<Double> {
                    let ex = majorR * cos(t)
                    let ey = majorR * ratio * sin(t)
                    return SIMD3(
                        c.x + ex * cos(tilt) - ey * sin(tilt),
                        c.y + ex * sin(tilt) + ey * cos(tilt), c.z)
                }
                var previous = at(startParam)
                for i in 1...48 {
                    let next = at(startParam + (end - startParam) * Double(i) / 48)
                    add(Shape.edgeFromPoints(previous, next))
                    previous = next
                }
            }
        case .spline(let spline):
            if let edge = exactEdge(for: spline) {
                add(edge)
            } else {
                let tolerance = max(DrawingEntities.splineSize(spline) * 1e-4, 1e-9)
                let points = spline.flattened(tolerance: tolerance)
                if points.count == 1 { add(Shape.vertex(at: simd(points[0]))) }
                for (a, b) in zip(points, points.dropFirst()) where a != b {
                    add(Shape.edgeFromPoints(simd(a), simd(b)))
                }
                approximation =
                    "A spline end is approximated by chords within "
                    + "\(String(format: "%.3g", tolerance)) drawing units, because its control data "
                    + "does not define an exact curve, so the distance to it is accurate to that "
                    + "error, not exact."
            }
        case .point(let p, _, _):
            add(Shape.vertex(at: simd(p)))
        case .text:
            throw MeasureError(
                "A text entity has no measurable geometry; pass its `at` point as a point instead.")
        case .dimension:
            throw MeasureError(
                "A dimension entity has no measurable geometry; measure the entities it dimensions, "
                    + "or pass its definition points from list_drawing_dimensions as points."
            )
        @unknown default:
            throw MeasureError(
                "This entity type is not one the drawing tools measure; use a point instead.")
        }
        return (shapes, approximation)
    }

    /// The exact NURBS edge of a spline whose control data defines a curve, nil when it does not.
    ///
    /// DXF stores one flat knot vector; OCCT takes each distinct knot with its multiplicity, and
    /// runs the edge over the curve's valid domain, which for an unclamped vector is narrower than
    /// the knot vector. The file is untrusted, so what OCCTSwift would trap on or read as a C buffer
    /// is checked here: the degree must be at least 1 and below the number of control points
    /// (OCCTSwift narrows it to 32 bits, which traps for a degree outside that range), knots must
    /// be finite, and weights must be one positive number per control point (SwiftDXF ignores any
    /// others too, and so does this: the curve is then non-rational). A knot vector of the wrong
    /// length, out of order or spanning nothing is left to OCCT, which refuses it with nil.
    /// Fit-point splines, anything OCCT refuses, and a closed spline whose curve's ends do not meet
    /// (SwiftDXF closes it with a chord) fall back to chords.
    private static func exactEdge(for spline: DXF.Spline) -> Shape? {
        let poles = spline.controlPoints
        let degree = spline.degree
        guard degree >= 1, poles.count > degree,
            spline.knots.allSatisfy(\.isFinite)
        else { return nil }
        // SwiftDXF closes a closed spline with a chord when the curve's own ends differ, so the exact
        // edge is only right when they meet. They are the curve's ends, not its first and last
        // control points: an unclamped curve does not reach its poles.
        if spline.isClosed, let domain = spline.parameterDomain,
            let start = spline.point(at: domain.lowerBound),
            let end = spline.point(at: domain.upperBound),
            DrawingEntities.distance(start, end) > 1e-9
        {
            return nil
        }

        var knots: [Double] = []
        var multiplicities: [Int32] = []
        for knot in spline.knots {
            if knot == knots.last {
                multiplicities[multiplicities.count - 1] += 1
            } else {
                knots.append(knot)
                multiplicities.append(1)
            }
        }
        let oneEach = spline.weights.count == poles.count
        let positive = spline.weights.allSatisfy { $0 > 0 && $0.isFinite }
        let weights: [Double]? = oneEach && positive ? spline.weights : nil
        guard
            let curve = Curve3D.bspline(
                poles: poles.map(simd), weights: weights, knots: knots,
                multiplicities: multiplicities, degree: degree)
        else { return nil }
        return Shape.edgeFromCurve(curve)
    }

    private static func shape(for end: MeasureEnd, role: String) throws -> (Shape, String?) {
        switch end {
        case .point(let p):
            guard let vertex = Shape.vertex(at: simd(p)) else {
                throw MeasureError("`\(role)` could not be built as a point.")
            }
            return (vertex, nil)
        case .entity(let index, let entity):
            let built = try shapes(for: entity)
            guard !built.shapes.isEmpty, let compound = Shape.compound(built.shapes) else {
                throw MeasureError(
                    "`\(role)` (\(DrawingEntities.id(index))) has no measurable geometry: it is empty or degenerate."
                )
            }
            return (compound, built.approximation)
        }
    }

    // ── measure_drawing ─────────────────────────────────────────────────

    public static func measureDrawing(
        inputPath: String, measure: String, a: Value?, b: Value?, vertex: Value?,
        mmPerUnit override: Double?
    ) async -> ToolText {
        if let override, !(override > 0 && override.isFinite) {
            return .init("`mmPerUnit` must be a positive number.", isError: true)
        }
        let loaded: LoadedDrawing
        switch await load(inputPath) {
        case .loaded(let value): loaded = value
        case .failed(let failure): return failure
        }
        let mmPerUnit = override ?? loaded.mmPerUnit
        var notes: [String] = []
        if override == nil, loaded.mmPerUnit == nil {
            notes.append(
                "The drawing declares no usable units, so no millimetre figure is given. "
                    + "Pass `mmPerUnit` to supply one.")
        }
        if override != nil, let declared = loaded.mmPerUnit, declared != override {
            notes.append(
                "`mmPerUnit` \(override!) overrides the drawing's declared \(declared) mm per unit."
            )
        }
        func mm(_ value: Double) -> Double? { mmPerUnit.map { value * $0 } }
        // Only a distance or a radius has a millimetre figure to explain; an angle does not.
        let unitNotes = notes
        notes = []

        do {
            switch measure {
            case "distance":
                notes = unitNotes
                let endA = try parseEnd(a, role: "a", in: loaded.drawing)
                let endB = try parseEnd(b, role: "b", in: loaded.drawing)
                let (shapeA, approximationA) = try shape(for: endA, role: "a")
                let (shapeB, approximationB) = try shape(for: endB, role: "b")
                guard let result = shapeA.distance(to: shapeB) else {
                    throw MeasureError("OCCT could not compute the distance between `a` and `b`.")
                }
                // One note per kind of approximation, even when both ends are the same kind.
                let approximations = Set([approximationA, approximationB].compactMap { $0 })
                notes.append(contentsOf: approximations.sorted())
                return encode(
                    MeasureResult(
                        source: sourceRef(loaded), measure: measure, a: endRecord(endA),
                        b: endRecord(endB), vertex: nil, value: result.distance,
                        unit: "drawing units", valueMm: mm(result.distance), mmPerUnit: mmPerUnit,
                        diameter: nil, acuteAngleDeg: nil,
                        pointOnA: [
                            result.pointOnShape1.x, result.pointOnShape1.y, result.pointOnShape1.z,
                        ],
                        pointOnB: [
                            result.pointOnShape2.x, result.pointOnShape2.y, result.pointOnShape2.z,
                        ],
                        notes: notes))

            case "angle":
                if vertex != nil {
                    let apex = try parsePoint(vertex, role: "vertex")
                    let p = try parsePoint(a, role: "a")
                    let q = try parsePoint(b, role: "b")
                    let degrees = try angleDeg(
                        (p.x - apex.x, p.y - apex.y, p.z - apex.z),
                        (q.x - apex.x, q.y - apex.y, q.z - apex.z))
                    return encode(
                        MeasureResult(
                            source: sourceRef(loaded), measure: measure,
                            a: .init(
                                kind: "point", id: nil, type: nil, point: DrawingEntities.xyz(p)),
                            b: .init(
                                kind: "point", id: nil, type: nil, point: DrawingEntities.xyz(q)),
                            vertex: .init(
                                kind: "point", id: nil, type: nil, point: DrawingEntities.xyz(apex)),
                            value: degrees, unit: "degrees", valueMm: nil, mmPerUnit: nil,
                            diameter: nil, acuteAngleDeg: min(degrees, 180 - degrees),
                            pointOnA: nil, pointOnB: nil, notes: []))
                }
                let endA = try parseEnd(a, role: "a", in: loaded.drawing)
                let endB = try parseEnd(b, role: "b", in: loaded.drawing)
                guard case .entity(_, .line(let a0, let a1, _, _)) = endA,
                    case .entity(_, .line(let b0, let b1, _, _)) = endB
                else {
                    throw MeasureError(
                        "`angle` takes two line entities, or a `vertex` point with two points `a` and `b`."
                    )
                }
                let degrees = try angleDeg(
                    (a1.x - a0.x, a1.y - a0.y, a1.z - a0.z), (b1.x - b0.x, b1.y - b0.y, b1.z - b0.z)
                )
                notes.append(
                    "The angle runs between the lines' drawn directions (start to end); "
                        + "acuteAngleDeg is the angle between the lines themselves.")
                return encode(
                    MeasureResult(
                        source: sourceRef(loaded), measure: measure, a: endRecord(endA),
                        b: endRecord(endB), vertex: nil, value: degrees, unit: "degrees",
                        valueMm: nil, mmPerUnit: nil, diameter: nil,
                        acuteAngleDeg: min(degrees, 180 - degrees), pointOnA: nil, pointOnB: nil,
                        notes: notes))

            case "radius":
                notes = unitNotes
                let endA = try parseEnd(a, role: "a", in: loaded.drawing)
                let radius: Double
                switch endA {
                case .entity(_, .circle(_, let r, _, _)), .entity(_, .arc(_, let r, _, _, _, _)):
                    radius = r
                default:
                    throw MeasureError("`radius` takes a circle or arc entity as `a`.")
                }
                return encode(
                    MeasureResult(
                        source: sourceRef(loaded), measure: measure, a: endRecord(endA), b: nil,
                        vertex: nil, value: radius, unit: "drawing units", valueMm: mm(radius),
                        mmPerUnit: mmPerUnit, diameter: radius * 2, acuteAngleDeg: nil,
                        pointOnA: nil, pointOnB: nil, notes: notes))

            default:
                return .init(
                    "`measure` must be \"distance\", \"angle\" or \"radius\".", isError: true)
            }
        } catch {
            return .init("\(error)", isError: true)
        }
    }

    /// The angle in degrees, in [0, 180], between two direction vectors.
    private static func angleDeg(
        _ u: (Double, Double, Double), _ v: (Double, Double, Double)
    ) throws -> Double {
        let lu = (u.0 * u.0 + u.1 * u.1 + u.2 * u.2).squareRoot()
        let lv = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        guard lu > 0, lv > 0 else {
            throw MeasureError("A zero-length line or a coincident point has no direction.")
        }
        let cosine = (u.0 * v.0 + u.1 * v.1 + u.2 * v.2) / (lu * lv)
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }
}
