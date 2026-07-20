// SelectionTools — select_topology picks faces / edges / vertices on a
// scene body and registers them with SelectionRegistry. Returns
// self-describing selectionIds plus an anchor snapshot (centroid +
// shape-specific metadata) so the LLM can both refer back and reason
// about what was picked.
//
// This is the foundation for the rest of v0.4 — remap_selection,
// add_dimension, add_scene_primitive, select_by_feature all consume
// selectionIds produced here.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

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

    /// Pick faces / edges / vertices matching `filter`. Each match is
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
        let shape = loaded.shape
        // #91: shape.faces()/.edges()/.vertices() enumeration order is
        // NOT guaranteed to equal TopologyGraph(shape:)'s own per-kind
        // node index order (verified false for edges/vertices — see
        // TopologyIdentityTests). remap_selection's history path
        // (RemapTools.remapViaHistory) reinterprets a selectionId's
        // embedded index as a TopologyGraph.NodeRef index, so that
        // index has to come from the graph, not the enumeration loop.
        let graph = TopologyGraph(shape: shape)

        var entries: [SelectionEntry] = []
        var totalScanned = 0

        switch kind {
        case "body":
            let anchor = TopologyAnchor.body(bodyId: bodyId)
            let bb = shape.bounds
            let center = [
                (bb.min.x + bb.max.x) * 0.5,
                (bb.min.y + bb.max.y) * 0.5,
                (bb.min.z + bb.max.z) * 0.5,
            ]
            let snapshot = AnchorSnapshot(center: center)
            await registry.record(anchor: anchor, snapshot: snapshot)
            entries.append(SelectionEntry(
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
                   let n = normal {
                    let cos = simd_dot(simd_normalize(dir), simd_normalize(n))
                    let limit = filter.normalTolerance ?? 0.01
                    if abs(cos - 1.0) > limit { continue }
                }
                let index = graphIndex(for: Shape.fromFace(face), kind: .face, in: graph, fallback: i)
                let anchor = TopologyAnchor.face(bodyId: bodyId, index: index)
                let snapshot = AnchorSnapshot(
                    center: [center.x, center.y, center.z],
                    normal: normal.map { [$0.x, $0.y, $0.z] },
                    area: area,
                    surfaceType: surfaceType
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
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
                // For circular edges, also capture the geometric centre
                // (centre of curvature). `center` is the rim point at
                // the parameter midpoint; circleCenter is the centre of
                // the circle — radial dimensions need both.
                let circleCenter: [Double]?
                if edge.isCircle, let bounds = edge.parameterBounds {
                    let mid = (bounds.first + bounds.last) * 0.5
                    if let c = edge.centerOfCurvature(at: mid) {
                        circleCenter = [c.x, c.y, c.z]
                    } else {
                        circleCenter = nil
                    }
                } else {
                    circleCenter = nil
                }
                let index = graphIndex(for: Shape.fromEdge(edge), kind: .edge, in: graph, fallback: i)
                let anchor = TopologyAnchor.edge(bodyId: bodyId, index: index)
                let snapshot = AnchorSnapshot(
                    center: center.map { [$0.x, $0.y, $0.z] } ?? [0, 0, 0],
                    length: length,
                    curveType: curveType,
                    circleCenter: circleCenter
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
                    selectionId: anchor.selectionId,
                    bodyId: bodyId,
                    kind: "edge",
                    anchorIndex: index,
                    anchor: snapshot
                ))
            }

        case "vertex":
            // Not shape.vertices() — that returns bare SIMD3 points with
            // no Shape wrapper to look up in the graph, and (per #91) its
            // order doesn't match the graph's vertex-kind index order
            // anyway. subShapes(ofType: .vertex) gives real vertex Shapes
            // to resolve through graphIndex(...).
            for (i, vertexShape) in shape.subShapes(ofType: .vertex).enumerated() {
                totalScanned += 1
                let index = graphIndex(for: vertexShape, kind: .vertex, in: graph, fallback: i)
                let point = vertexShape.centerOfMass ?? .zero
                let anchor = TopologyAnchor.vertex(bodyId: bodyId, index: index)
                let snapshot = AnchorSnapshot(
                    center: [point.x, point.y, point.z]
                )
                await registry.record(anchor: anchor, snapshot: snapshot)
                entries.append(SelectionEntry(
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

        return IntrospectionTools.encode(SelectionResult(
            selections: entries,
            total: totalScanned,
            truncated: truncated
        ))
    }

    // MARK: - Anchor helpers

    /// Centroid + outward normal at the face's UV midpoint. Both nil
    /// if the face's UV bounds can't be resolved.
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

    static func edgeLength(edge: Edge) -> Double {
        return edge.length
    }

    /// Resolve `sub`'s node index in `graph` for `kind` (#91). Falls
    /// back to `fallback` — the naive enumeration index — if the graph
    /// is absent or doesn't know the shape; should not happen in
    /// practice for a sub-shape freshly enumerated from the exact shape
    /// the graph was built from, but a stale fallback is safer than
    /// dropping the selection outright.
    static func graphIndex(
        for sub: Shape?,
        kind: TopologyGraph.NodeKind,
        in graph: TopologyGraph?,
        fallback: Int
    ) -> Int {
        guard let graph, let sub,
              let node = graph.findNode(for: sub), node.kind == kind else {
            return fallback
        }
        return node.index
    }
}
