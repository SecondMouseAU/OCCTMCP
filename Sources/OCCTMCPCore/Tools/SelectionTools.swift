// SelectionTools: select_topology picks faces / edges / vertices on a
// scene body and registers them with SelectionRegistry. Returns
// self-describing selectionIds plus an anchor snapshot (centroid +
// shape-specific metadata) so the LLM can both refer back and reason
// about what was picked.
//
// This is the foundation for the rest of v0.4: remap_selection,
// add_dimension, add_scene_primitive, select_by_feature all consume
// selectionIds produced here.

import Foundation
import OCCTSwift
import ScriptHarness
import simd

public enum SelectionTools {

    public struct Filter {
        public var surfaceType: String?
        public var curveType: String?
        public var minArea: Double?
        public var maxArea: Double?
        public var minLength: Double?
        public var maxLength: Double?
        public var normalDirection: SIMD3<Double>?
        public var normalTolerance: Double?
        public init() {}
    }

    public struct SelectionEntry: Encodable {
        public let selectionId: String
        public let bodyId: String
        public let kind: String
        public let anchorIndex: Int?
        public let anchor: AnchorSnapshot
    }

    public struct SelectionResult: Encodable {
        public let selections: [SelectionEntry]
        public let total: Int
        public let truncated: Bool
    }

    /// Pick faces / edges / vertices matching `filter`.
    ///
    /// Each match is
    /// registered with SelectionRegistry under `sel:<bodyId>#<kind>[<idx>]`.
    public static func selectTopology(
        bodyId: String,
        kind: String,
        filter: Filter = .init(),
        limit: Int? = nil,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        // #91: shape.faces()/.edges()/.vertices() enumeration order is
        // NOT guaranteed to equal the graph's own per-kind node index
        // order (verified false for edges/vertices, per
        // TopologyIdentityTests). remap_selection's history path
        // (RemapTools.remapViaHistory) reinterprets a selectionId's
        // embedded index as a BRepGraph.NodeRef index, so that index
        // has to come from the graph, not the enumeration loop.
        //
        // #93: resolve through the HistoryRegistry-retained lineage
        // instead of a disposable per-call graph: establishes (or
        // reuses) the SAME graph object a later history-aware mutation
        // (apply_feature, boolean_op, heal_shape, ...) will absorb into,
        // so a GraphUID minted here still resolves after the mutation
        // instead of being permanently unresolvable.
        let lineage: (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool)
        do {
            lineage = try await HistoryRegistry.shared.currentInput(
                bodyId: bodyId, path: loaded.path)
        } catch {
            return .init("\(error)")
        }
        let shape = lineage.shape
        let graph = lineage.graph

        var entries: [SelectionEntry] = []
        var totalScanned = 0

        switch kind {
        case "body":
            let anchor = TopologyAnchor.body(bodyId: bodyId)
            // A body anchor IS its bbox centre, so with no bounding box there is
            // nothing to anchor to and no selection to mint (OCCTSwift #943).
            guard let bb = shape.bounds else {
                return .init(DeviationTools.noBoundingBoxMessage(bodyId), isError: true)
            }
            let center = [
                (bb.min.x + bb.max.x) * 0.5,
                (bb.min.y + bb.max.y) * 0.5,
                (bb.min.z + bb.max.z) * 0.5,
            ]
            let snapshot = AnchorSnapshot(center: center)
            await registry.record(anchor: anchor, snapshot: snapshot)
            entries.append(
                SelectionEntry(
                    selectionId: anchor.selectionId,
                    bodyId: bodyId,
                    kind: "body",
                    anchorIndex: nil,
                    anchor: snapshot
                ))
            totalScanned = 1

        case "face":
            for (i, face) in shape.faces().enumerated() {
                totalScanned += 1
                let surfaceType = String(describing: face.surfaceType)
                if let want = filter.surfaceType, want != surfaceType { continue }
                let area = face.area()
                if let lo = filter.minArea, area < lo { continue }
                if let hi = filter.maxArea, area > hi { continue }

                let (center, normal) = faceCenterAndNormal(face: face)
                if let dir = filter.normalDirection,
                    let n = normal
                {
                    let cos = simd_dot(simd_normalize(dir), simd_normalize(n))
                    let limit = filter.normalTolerance ?? 0.01
                    if abs(cos - 1.0) > limit { continue }
                }
                let index = graphIndex(
                    for: Shape.fromFace(face), kind: .face, in: graph, fallback: i)
                // #182: mint the uid before constructing the anchor, so
                // `record` writes anchor + snapshot + uid in one call
                // instead of a separate recordGraphUID follow-up.
                let uid = graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: index)
                let anchor = TopologyAnchor.face(bodyId: bodyId, index: index, uid: uid)
                let snapshot = AnchorSnapshot(
                    center: [center.x, center.y, center.z],
                    normal: normal.map { [$0.x, $0.y, $0.z] },
                    area: area,
                    surfaceType: surfaceType
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(
                    SelectionEntry(
                        selectionId: anchor.selectionId,
                        bodyId: bodyId,
                        kind: "face",
                        anchorIndex: index,
                        anchor: snapshot
                    ))
            }

        case "edge":
            for (i, edge) in shape.edges().enumerated() {
                totalScanned += 1
                let curveType = String(describing: edge.curveType)
                if let want = filter.curveType, want != curveType { continue }
                let length = edgeLength(edge: edge)
                if let lo = filter.minLength, length < lo { continue }
                if let hi = filter.maxLength, length > hi { continue }

                let center = edgeMidpoint(edge: edge)
                let geom = edgeGeometryFields(edge: edge)
                let index = graphIndex(
                    for: Shape.fromEdge(edge), kind: .edge, in: graph, fallback: i)
                let uid = graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.edge.rawValue), index: index)
                let anchor = TopologyAnchor.edge(bodyId: bodyId, index: index, uid: uid)
                let snapshot = AnchorSnapshot(
                    center: center.map { [$0.x, $0.y, $0.z] } ?? [0, 0, 0],
                    length: length,
                    curveType: curveType,
                    circleCenter: geom.circleCenter,
                    endpoints: geom.endpoints,
                    direction: geom.direction,
                    radius: geom.radius,
                    axis: geom.axis,
                    startAngle: geom.startAngle,
                    endAngle: geom.endAngle
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(
                    SelectionEntry(
                        selectionId: anchor.selectionId,
                        bodyId: bodyId,
                        kind: "edge",
                        anchorIndex: index,
                        anchor: snapshot
                    ))
            }

        case "vertex":
            // Not shape.vertices(): that returns bare SIMD3 points with
            // no Shape wrapper to look up in the graph, and (per #91) its
            // order doesn't match the graph's vertex-kind index order
            // anyway. subShapes(ofType: .vertex) gives real vertex Shapes
            // to resolve through graphIndex(...).
            for (i, vertexShape) in shape.subShapes(ofType: .vertex).enumerated() {
                totalScanned += 1
                guard let point = vertexPoint(vertexShape) else { continue }
                let index = graphIndex(for: vertexShape, kind: .vertex, in: graph, fallback: i)
                let uid = graph.uid(
                    ofNodeKind: Int(BRepGraph.NodeKind.vertex.rawValue), index: index)
                let anchor = TopologyAnchor.vertex(bodyId: bodyId, index: index, uid: uid)
                let snapshot = AnchorSnapshot(
                    center: [point.x, point.y, point.z]
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(
                    SelectionEntry(
                        selectionId: anchor.selectionId,
                        bodyId: bodyId,
                        kind: "vertex",
                        anchorIndex: index,
                        anchor: snapshot
                    ))
            }

        default:
            return .init("Unknown kind '\(kind)'. Expected one of: body, face, edge, vertex.")
        }

        let truncated = limit.map { entries.count > $0 } ?? false
        if let n = limit { entries = Array(entries.prefix(n)) }

        return IntrospectionTools.encode(
            SelectionResult(
                selections: entries,
                total: totalScanned,
                truncated: truncated
            ))
    }

    // MARK: - Anchor helpers

    /// Centroid + outward normal at the face's UV midpoint.
    ///
    /// Both nil if the face's UV bounds can't be resolved.
    static func faceCenterAndNormal(face: Face) -> (SIMD3<Double>, SIMD3<Double>?) {
        guard let uv = face.uvBounds else {
            return (SIMD3<Double>.zero, nil)
        }
        let u = (uv.uMin + uv.uMax) * 0.5
        let v = (uv.vMin + uv.vMax) * 0.5
        let center = face.point(atU: u, v: v) ?? SIMD3<Double>.zero
        let normal = face.normal(atU: u, v: v)
        return (center, normal)
    }

    static func edgeMidpoint(edge: Edge) -> SIMD3<Double>? {
        guard let bounds = edge.parameterBounds else { return nil }
        let mid = (bounds.first + bounds.last) * 0.5
        return edge.point(at: mid)
    }

    /// A single-vertex Shape's real position (#168). `Shape.centerOfMass`
    /// used to return the bounding-box centre for ANY shape, which happened
    /// to be right for a vertex (a point's own bbox is itself), but as of
    /// OCCTSwift 2.0.0 (#605) it's the real BRepGProp centre of mass and
    /// returns nil for anything enclosing no volume, a vertex included.
    /// `Shape.vertices()` is the vertex's actual coordinate and always
    /// resolves for a genuine vertex sub-shape; every vertex-anchor site
    /// should go through this one helper rather than `centerOfMass`, so a
    /// future upstream mass-property change has one place to audit.
    static func vertexPoint(_ vertexShape: Shape) -> SIMD3<Double>? {
        return vertexShape.vertices().first
    }

    static func edgeLength(edge: Edge) -> Double {
        return edge.length
    }

    /// Geometric detail for an edge (#119): endpoints for every edge kind, a
    /// unit direction for LINE edges (a straight edge is a vector in space;
    /// without this, colinearity / endpoint-error checks against a source
    /// mesh need `execute_script`), and radius/axis/startAngle/endAngle for
    /// CIRCULAR edges (alongside `circleCenter`, computed the same way
    /// `selectTopology` already does for its own edge case).
    static func edgeGeometryFields(edge: Edge) -> (
        endpoints: [[Double]]?, direction: [Double]?,
        circleCenter: [Double]?, radius: Double?, axis: [Double]?,
        startAngle: Double?, endAngle: Double?
    ) {
        let ep = edge.endpoints
        let endpoints: [[Double]]? = [
            [ep.start.x, ep.start.y, ep.start.z], [ep.end.x, ep.end.y, ep.end.z],
        ]

        var direction: [Double]? = nil
        if edge.isLine {
            let d = ep.end - ep.start
            let len = simd_length(d)
            if len > 1e-12 { direction = [d.x / len, d.y / len, d.z / len] }
        }

        var circleCenter: [Double]? = nil
        var radius: Double? = nil
        var axis: [Double]? = nil
        var startAngle: Double? = nil
        var endAngle: Double? = nil
        if edge.isCircle, let bounds = edge.parameterBounds {
            let mid = (bounds.first + bounds.last) * 0.5
            if let c = edge.centerOfCurvature(at: mid) {
                circleCenter = [c.x, c.y, c.z]
            }
            // `curve3D` must stay alive for as long as `circleProperties` is
            // used: CircleProperties wraps the SAME native handle without
            // retaining its parent Curve3D, so a temporary (e.g.
            // `edge.curve3D?.circleProperties`, never bound to a name) gets
            // deallocated the instant this expression finishes, releasing
            // the handle circleProperties still points at (a real crash,
            // caught by EdgeGeometryFieldsTests).
            if let curve = edge.curve3D {
                let props = curve.circleProperties
                radius = props.radius
                let n = simd_cross(props.xAxis.direction, props.yAxis.direction)
                let len = simd_length(n)
                if len > 1e-12 { axis = [n.x / len, n.y / len, n.z / len] }
            }
            startAngle = bounds.first
            endAngle = bounds.last
        }

        return (endpoints, direction, circleCenter, radius, axis, startAngle, endAngle)
    }

    /// Resolve the node index of `sub` in `graph` for `kind` (#91).
    ///
    /// Falls back to `fallback` (the naive enumeration index) if the graph
    /// is absent or doesn't know the shape; should not happen in practice
    /// for a sub-shape freshly enumerated from the exact shape the graph
    /// was built from, but a stale fallback is safer than dropping the
    /// selection outright.
    static func graphIndex(
        for sub: Shape?,
        kind: BRepGraph.NodeKind,
        in graph: BRepGraph?,
        fallback: Int
    ) -> Int {
        guard let graph, let sub,
            let node = graph.findNode(for: sub), node.kind == kind
        else {
            return fallback
        }
        return node.index
    }
}
