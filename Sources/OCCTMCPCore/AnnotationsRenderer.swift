// AnnotationsRenderer — turn the AnnotationsSidecar's primitives and
// dimensions into ViewportBody geometry that OffscreenRenderer can
// draw. As of v0.10 the supported set is:
//
//   trihedron     — 3 cylinders + 3 spheres at the tips
//   workPlane     — thin box at origin, oriented to the supplied normal
//   axis          — cylinder from→to, radius from params
//   boundingBox   — 12 thin cylinders forming the wireframe of the bbox
//   diffMarker    — thin transparent box at the affected body's bbox
//   pointCloud    — point-only ViewportBody via OCCTSwiftTools'
//                   PointConverter (gsdali/OCCTSwiftTools#18, v1.0.1+).
//                   Renderer dispatches on body primitive kind so no
//                   sphere synthesis happens — the 256-cap from v0.6
//                   is gone.
//   dimension     — emitted as ViewportMeasurement (.distance / .angle
//                   / .radius) and overlaid by OffscreenRenderer's 2D
//                   measurement pass (OCCTSwiftViewport#26, v0.55.2+).
//                   Includes value labels, arrow tips, leader lines —
//                   no in-Swift cylinder synthesis needed any more.
//                   The v0.6 3D-leader fallback is retained for legacy
//                   sidecars whose annotation entries don't carry
//                   anchorPoints (older add_dimension responses pre-
//                   dating circleCenter capture).

import Foundation
import simd
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

@MainActor
public enum AnnotationsRenderer {

    /// Retained for back-compat (read by callers that probed the old
    /// cap). v0.10 lifted the limit by routing through
    /// OCCTSwiftTools.PointConverter, which produces a point-only
    /// ViewportBody — no sphere synthesis, no cap.
    @available(*, deprecated, message: "v0.10 removed the sphere-per-point fallback; PointConverter handles arbitrary cloud sizes.")
    public static let maxPointCloudPoints = Int.max

    /// Synthesise ViewportBodies for every renderable primitive +
    /// dimension in the sidecar. Bodies are tagged with the
    /// primitive/dimension id and a representative colour.
    public static func bodies(from sidecar: AnnotationsSidecar) -> [ViewportBody] {
        var out: [ViewportBody] = []
        for prim in sidecar.primitives {
            switch prim.kind {
            case "trihedron":
                if let bodies = trihedron(prim) { out.append(contentsOf: bodies) }
            case "workPlane":
                if let body = workPlane(prim) { out.append(body) }
            case "axis":
                if let body = axis(prim) { out.append(body) }
            case "boundingBox":
                if let body = boundingBox(prim) { out.append(body) }
            case "diffMarker":
                if let body = diffMarker(prim) { out.append(body) }
            case "pointCloud":
                if let body = pointCloud(prim) { out.append(body) }
            default:
                continue   // future kinds — silently skip
            }
        }
        // Dimensions are no longer synthesised as 3D leader cylinders —
        // they're overlaid as ViewportMeasurements via the v0.55.2
        // OffscreenRenderer surface (see `measurements(from:)`).
        return out
    }

    /// v0.9: translate sidecar dimensions into ViewportMeasurement
    /// values that OffscreenRenderer's headless overlay pass renders
    /// as proper 2D leader lines + arrow tips + value labels. Mapping
    /// is direct:
    ///   linear  → .distance(start, end)
    ///   angular → .angle(pointA, vertex, pointB)
    ///   radial  → .radius(center, edgePoint)
    /// Returns an empty array if the sidecar has no dimensions or all
    /// are missing anchor points (very old sidecars).
    public static func measurements(from sidecar: AnnotationsSidecar) -> [ViewportMeasurement] {
        return sidecar.dimensions.compactMap { dim in
            guard let pts = dim.anchorPoints else { return nil }
            switch dim.kind {
            case "linear":
                guard pts.count >= 2 else { return nil }
                return .distance(.init(
                    id: dim.id,
                    start: simd3f(pts[0]),
                    end: simd3f(pts[1]),
                    label: dim.label
                ))
            case "angular":
                guard pts.count >= 3 else { return nil }
                return .angle(.init(
                    id: dim.id,
                    pointA: simd3f(pts[0]),
                    vertex: simd3f(pts[1]),
                    pointB: simd3f(pts[2]),
                    label: dim.label
                ))
            case "radial":
                guard pts.count >= 2 else { return nil }
                return .radius(.init(
                    id: dim.id,
                    center: simd3f(pts[0]),
                    edgePoint: simd3f(pts[1]),
                    showDiameter: false,   // already encoded in `value`
                    label: dim.label
                ))
            default:
                return nil
            }
        }
    }

    private static func simd3f(_ pts: [Double]) -> SIMD3<Float> {
        guard pts.count >= 3 else { return SIMD3<Float>(0, 0, 0) }
        return SIMD3(Float(pts[0]), Float(pts[1]), Float(pts[2]))
    }

    // MARK: - Per-kind synthesis

    private static func trihedron(_ prim: PrimitiveAnnotation) -> [ViewportBody]? {
        let origin = vec3(prim.params["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let length = scalar(prim.params["axisLength"]) ?? 10.0
        let armRadius = max(length * 0.025, 0.01)
        let jointRadius = armRadius * 1.6

        var bodies: [ViewportBody] = []
        let axes: [(SIMD3<Double>, SIMD4<Float>)] = [
            (SIMD3(1, 0, 0), .init(0.85, 0.2, 0.2, 1)),  // X red
            (SIMD3(0, 1, 0), .init(0.2, 0.7, 0.25, 1)),  // Y green
            (SIMD3(0, 0, 1), .init(0.2, 0.4, 0.85, 1)),  // Z blue
        ]
        for (i, (dir, color)) in axes.enumerated() {
            guard let cyl = Shape.cylinder(at: origin, direction: dir, radius: armRadius, height: length) else {
                continue
            }
            let tipCenter = origin + dir * length
            let tip = Shape.sphere(center: tipCenter, radius: jointRadius)
            let merged: Shape? = (tip != nil) ? Shape.compound([cyl, tip!]) ?? cyl : cyl
            if let body = makeViewportBody(merged ?? cyl, id: "\(prim.id)_axis_\(i)", color: color) {
                bodies.append(body)
            }
        }
        return bodies.isEmpty ? nil : bodies
    }

    private static func workPlane(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        let origin = vec3(prim.params["origin"]) ?? SIMD3<Double>(0, 0, 0)
        let normal = (vec3(prim.params["normal"]) ?? SIMD3<Double>(0, 0, 1))
        let size = scalar(prim.params["size"]) ?? 100
        let color = vec4(prim.params["color"]) ?? SIMD4<Float>(0.5, 0.6, 0.85, 0.25)

        // Build a thin slab whose "depth" axis points along the normal.
        // OCCTSwift's box(at:direction:width:height:depth:) takes the
        // direction as the depth axis — we want the slab thin along
        // `normal`, sized `size × size` in the plane.
        let halfSize = size * 0.5
        let baseOrigin = origin - simd_normalize(normal) * 0.05
        guard let slab = Shape.box(
            at: baseOrigin,
            direction: simd_normalize(normal),
            width: size,
            height: size,
            depth: 0.1   // 0.1 mm thick
        ) else { return nil }
        // Translate so the slab is centred on `origin` rather than starting at it.
        let centred = slab.translated(by: SIMD3<Double>(-halfSize, -halfSize, 0)) ?? slab
        return makeViewportBody(centred, id: prim.id, color: color)
    }

    private static func axis(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let from = vec3(prim.params["from"]),
              let to = vec3(prim.params["to"]) else { return nil }
        let direction = to - from
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let radius = scalar(prim.params["radius"]) ?? 0.5
        let color3 = vec3Float(prim.params["color"]) ?? SIMD3<Float>(1, 1, 1)
        let color = SIMD4<Float>(color3, 1)
        guard let cyl = Shape.cylinder(
            at: from,
            direction: simd_normalize(direction),
            radius: radius,
            height: length
        ) else { return nil }
        return makeViewportBody(cyl, id: prim.id, color: color)
    }

    private static func boundingBox(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let minP = vec3(prim.params["min"]),
              let maxP = vec3(prim.params["max"]) else { return nil }
        let extent = maxP - minP
        let edgeRadius = max(simd_length(extent) * 0.005, 0.05)

        // 12 edges of an axis-aligned box.
        let corners: [(SIMD3<Double>, SIMD3<Double>, Double)] = [
            // bottom face (z = min)
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(maxP.x, minP.y, minP.z), SIMD3(0, 1, 0), extent.y),
            (SIMD3(minP.x, maxP.y, minP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(0, 1, 0), extent.y),
            // top face (z = max)
            (SIMD3(minP.x, minP.y, maxP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(maxP.x, minP.y, maxP.z), SIMD3(0, 1, 0), extent.y),
            (SIMD3(minP.x, maxP.y, maxP.z), SIMD3(1, 0, 0), extent.x),
            (SIMD3(minP.x, minP.y, maxP.z), SIMD3(0, 1, 0), extent.y),
            // verticals
            (SIMD3(minP.x, minP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(maxP.x, minP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(maxP.x, maxP.y, minP.z), SIMD3(0, 0, 1), extent.z),
            (SIMD3(minP.x, maxP.y, minP.z), SIMD3(0, 0, 1), extent.z),
        ]
        var edges: [Shape] = []
        for (origin, dir, length) in corners {
            guard length > 1e-6,
                  let cyl = Shape.cylinder(at: origin, direction: dir, radius: edgeRadius, height: length) else {
                continue
            }
            edges.append(cyl)
        }
        guard let compound = Shape.compound(edges) else { return nil }
        let color = SIMD4<Float>(0.9, 0.5, 0.05, 1)
        return makeViewportBody(compound, id: prim.id, color: color)
    }

    private static func diffMarker(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard let center = vec3(prim.params["center"]),
              let extent = vec3(prim.params["extent"]) else { return nil }
        let color = vec4(prim.params["color"]) ?? SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
        // Slightly inflate the marker so it surrounds the original bbox
        // without z-fighting it.
        let pad = simd_length(extent) * 0.015
        let padded = extent + SIMD3<Double>(repeating: pad)
        let originAtCorner = center - padded * 0.5
        guard let box = Shape.box(
            origin: originAtCorner,
            width: padded.x,
            height: padded.y,
            depth: padded.z
        ) else { return nil }
        return makeViewportBody(box, id: prim.id, color: color)
    }

    private static func pointCloud(_ prim: PrimitiveAnnotation) -> ViewportBody? {
        guard case .array(let pts)? = prim.params["points"] else { return nil }
        let radius = scalar(prim.params["pointRadius"]) ?? 0.5
        let defaultColor = vec4(prim.params["defaultColor"]) ?? SIMD4<Float>(1, 0.85, 0.2, 1)

        // v0.10: route through OCCTSwiftTools' PointConverter
        // (gsdali/OCCTSwiftTools#18). The 256-sphere cap from v0.6 is
        // gone — PointConverter produces a point-only ViewportBody and
        // the renderer dispatches on the body's primitive kind.
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(pts.count)
        for entry in pts {
            guard case .array(let coord) = entry, coord.count == 3,
                  case .number(let x) = coord[0],
                  case .number(let y) = coord[1],
                  case .number(let z) = coord[2] else { continue }
            positions.append(SIMD3(Float(x), Float(y), Float(z)))
        }
        guard !positions.isEmpty else { return nil }

        let perPointColors: [SIMD4<Float>]?
        if case .array(let colorEntries)? = prim.params["colors"], colorEntries.count == positions.count {
            var parsed: [SIMD4<Float>] = []
            parsed.reserveCapacity(colorEntries.count)
            for entry in colorEntries {
                guard case .array(let rgb) = entry, rgb.count >= 3,
                      case .number(let r) = rgb[0],
                      case .number(let g) = rgb[1],
                      case .number(let b) = rgb[2] else { return nil }
                let a: Float = (rgb.count == 4) ? {
                    if case .number(let v) = rgb[3] { return Float(v) } else { return 1 }
                }() : 1
                parsed.append(SIMD4(Float(r), Float(g), Float(b), a))
            }
            perPointColors = parsed
        } else {
            perPointColors = nil
        }

        return PointConverter.pointsToBody(
            positions,
            id: prim.id,
            color: defaultColor,
            pointRadius: Float(radius),
            perPointColors: perPointColors
        )
    }

    private static func dimension(_ dim: DimensionAnnotation) -> ViewportBody? {
        guard let pts = dim.anchorPoints, !pts.isEmpty else { return nil }

        // Convert anchor points back to SIMD3<Double>.
        let world: [SIMD3<Double>] = pts.compactMap {
            $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil
        }
        guard !world.isEmpty else { return nil }

        // Match the dimension layer to a consistent palette so the LLM
        // can spot dimensions versus structural geometry at a glance.
        let color = SIMD4<Float>(0.95, 0.65, 0.05, 1)

        switch dim.kind {
        case "linear":
            guard world.count >= 2 else { return nil }
            return linearDimension(from: world[0], to: world[1], id: dim.id, color: color)
        case "angular":
            guard world.count >= 3 else { return nil }
            return angularDimension(armA: world[0], apex: world[1], armB: world[2], id: dim.id, color: color)
        case "radial":
            // v0.7: anchorPoints is [centre, rim] — draw a leader
            // cylinder + rim arrow cap. Falls back to a marker sphere
            // when the snapshot is legacy (centre only).
            if world.count >= 2 {
                return radialLeader(centre: world[0], rim: world[1], id: dim.id, color: color)
            }
            return radialMarker(at: world[0], id: dim.id, color: color)
        default:
            return nil
        }
    }

    // MARK: - Dimension helpers

    private static func linearDimension(
        from: SIMD3<Double>, to: SIMD3<Double>, id: String, color: SIMD4<Float>
    ) -> ViewportBody? {
        let direction = to - from
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let dir = simd_normalize(direction)
        let radius = max(length * 0.005, 0.05)
        guard let leader = Shape.cylinder(at: from, direction: dir, radius: radius, height: length) else { return nil }
        // Two arrow caps as cones (use cylinders for v0.6 — small
        // segments that visually flag the endpoints).
        let capHeight = max(length * 0.05, 0.5)
        let capRadius = radius * 3
        let fromCap = Shape.cylinder(
            at: from - dir * capHeight,
            direction: dir,
            radius: capRadius,
            height: capHeight
        )
        let toCap = Shape.cylinder(
            at: to,
            direction: dir,
            radius: capRadius,
            height: capHeight
        )
        var pieces = [leader]
        if let c = fromCap { pieces.append(c) }
        if let c = toCap { pieces.append(c) }
        guard let compound = Shape.compound(pieces) else {
            return makeViewportBody(leader, id: id, color: color)
        }
        return makeViewportBody(compound, id: id, color: color)
    }

    private static func angularDimension(
        armA: SIMD3<Double>, apex: SIMD3<Double>, armB: SIMD3<Double>,
        id: String, color: SIMD4<Float>
    ) -> ViewportBody? {
        // Render the two arms as thin cylinders from apex outward and
        // a small sphere at the apex. Skip the arc itself in v0.6 —
        // arc geometry needs Wire.arcOf3Points or similar; the visual
        // hint of "two arms meeting" is enough for LLM confirmation.
        let armARadius: Double = max(simd_length(armA - apex) * 0.005, 0.05)
        let armBRadius: Double = max(simd_length(armB - apex) * 0.005, 0.05)
        let dirA = armA - apex
        let dirB = armB - apex
        let lenA = simd_length(dirA)
        let lenB = simd_length(dirB)
        guard lenA > 1e-6, lenB > 1e-6 else { return nil }
        var pieces: [Shape] = []
        if let c = Shape.cylinder(at: apex, direction: simd_normalize(dirA), radius: armARadius, height: lenA) {
            pieces.append(c)
        }
        if let c = Shape.cylinder(at: apex, direction: simd_normalize(dirB), radius: armBRadius, height: lenB) {
            pieces.append(c)
        }
        if let s = Shape.sphere(center: apex, radius: max(armARadius, armBRadius) * 1.5) {
            pieces.append(s)
        }
        guard !pieces.isEmpty, let compound = Shape.compound(pieces) else { return nil }
        return makeViewportBody(compound, id: id, color: color)
    }

    private static func radialMarker(at center: SIMD3<Double>, id: String, color: SIMD4<Float>) -> ViewportBody? {
        guard let sphere = Shape.sphere(center: center, radius: 0.5) else { return nil }
        return makeViewportBody(sphere, id: id, color: color)
    }

    private static func radialLeader(
        centre: SIMD3<Double>, rim: SIMD3<Double>, id: String, color: SIMD4<Float>
    ) -> ViewportBody? {
        let direction = rim - centre
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let dir = simd_normalize(direction)
        let radius = max(length * 0.005, 0.05)
        let capRadius = radius * 3
        let capHeight = max(length * 0.06, 0.5)
        var pieces: [Shape] = []
        if let leader = Shape.cylinder(at: centre, direction: dir, radius: radius, height: length) {
            pieces.append(leader)
        }
        if let rimCap = Shape.cylinder(
            at: rim,
            direction: dir,
            radius: capRadius,
            height: capHeight
        ) {
            pieces.append(rimCap)
        }
        // Small marker at the centre to make it visually distinct from
        // a linear dimension (whose endpoints both get arrow caps).
        if let centreMarker = Shape.sphere(center: centre, radius: capRadius) {
            pieces.append(centreMarker)
        }
        guard !pieces.isEmpty, let compound = Shape.compound(pieces) else { return nil }
        return makeViewportBody(compound, id: id, color: color)
    }

    // MARK: - Param helpers

    private static func vec3(_ value: AnyCodable?) -> SIMD3<Double>? {
        guard case .array(let arr)? = value, arr.count == 3,
              case .number(let x) = arr[0],
              case .number(let y) = arr[1],
              case .number(let z) = arr[2] else { return nil }
        return SIMD3(x, y, z)
    }
    private static func vec3Float(_ value: AnyCodable?) -> SIMD3<Float>? {
        guard let v = vec3(value) else { return nil }
        return SIMD3(Float(v.x), Float(v.y), Float(v.z))
    }
    private static func vec4(_ value: AnyCodable?) -> SIMD4<Float>? {
        guard case .array(let arr)? = value, arr.count == 4,
              case .number(let r) = arr[0],
              case .number(let g) = arr[1],
              case .number(let b) = arr[2],
              case .number(let a) = arr[3] else { return nil }
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
    private static func scalar(_ value: AnyCodable?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    private static func makeViewportBody(_ shape: Shape, id: String, color: SIMD4<Float>) -> ViewportBody? {
        // Every caller passes a synthesized B-rep primitive (trihedron cones,
        // axis cylinders, plane/box slabs, leader spheres) — analytic normals,
        // never a facet shell — so the direct-mesh bridge is unconditionally
        // safe here (#76 step 3).
        let (vb, _) = CADFileLoader.shapeToBodyAndMetadata(shape, id: id, color: color, directMesh: true)
        return vb
    }
}
