// AnnotationsTools: add_dimension, add_scene_primitive,
// remove_scene_annotation. All three persist to the
// <output_dir>/annotations.json sidecar; render_preview reads it (in
// Phase 7.4) so the LLM can see dimensions / primitives in the
// rendered preview.
//
// Dimensions are computed at write time (length / angle / radius),
// resolved against the SelectionRegistry's anchor snapshots so we
// don't have to re-load the BREP just to get a centroid. Primitives
// are recorded as-is; their geometry is interpreted by the renderer.

import Foundation
import OCCTSwift
import simd

public enum AnnotationsTools {

    // MARK: - add_dimension

    public enum DimensionKind: String { case linear, angular, radial }

    public struct DimensionResult: Encodable {
        public let dimensionId: String
        public let kind: String
        public let value: Double
        public let unit: String
        public let anchorPoints: [[Double]]
    }

    public static func addDimension(
        kind: DimensionKind,
        anchors: [String: String],
        label: String? = nil,
        showDiameter: Bool = false,
        id: String? = nil,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir)
        var doc = sidecar.read()

        let dimId = id ?? "dim_\(UUID().uuidString.prefix(8))"

        switch kind {
        case .linear:
            guard let fromId = anchors["from"], let toId = anchors["to"] else {
                return .init("linear dimension requires anchors.from and anchors.to.")
            }
            guard let fromSnap = await registry.snapshot(for: fromId),
                let toSnap = await registry.snapshot(for: toId)
            else {
                return .init(
                    "Could not resolve linear anchors. Re-run select_topology if this is a fresh session."
                )
            }
            let a = SIMD3(fromSnap.center[0], fromSnap.center[1], fromSnap.center[2])
            let b = SIMD3(toSnap.center[0], toSnap.center[1], toSnap.center[2])
            let value = simd_length(b - a)
            let points = [
                [Double(a.x), Double(a.y), Double(a.z)],
                [Double(b.x), Double(b.y), Double(b.z)],
            ]
            doc.dimensions.removeAll { $0.id == dimId }
            doc.dimensions.append(
                .init(
                    id: dimId, kind: "linear",
                    anchors: ["from": fromId, "to": toId],
                    value: value, label: label, anchorPoints: points
                ))
            try? sidecar.write(doc)
            return IntrospectionTools.encode(
                DimensionResult(
                    dimensionId: dimId, kind: "linear", value: value, unit: "mm",
                    anchorPoints: points
                ))

        case .angular:
            guard let armA = anchors["armA"], let apex = anchors["apex"], let armB = anchors["armB"]
            else {
                return .init("angular dimension requires anchors.armA, anchors.apex, anchors.armB.")
            }
            guard let snapA = await registry.snapshot(for: armA),
                let snapApex = await registry.snapshot(for: apex),
                let snapB = await registry.snapshot(for: armB)
            else {
                return .init("Could not resolve angular anchors.")
            }
            let pA = SIMD3(snapA.center[0], snapA.center[1], snapA.center[2])
            let pV = SIMD3(snapApex.center[0], snapApex.center[1], snapApex.center[2])
            let pB = SIMD3(snapB.center[0], snapB.center[1], snapB.center[2])
            let v1 = simd_normalize(pA - pV)
            let v2 = simd_normalize(pB - pV)
            let cos = max(-1.0, min(1.0, simd_dot(v1, v2)))
            let radians = acos(cos)
            let degrees = radians * 180 / .pi
            let points = [
                [pA.x, pA.y, pA.z], [pV.x, pV.y, pV.z], [pB.x, pB.y, pB.z],
            ]
            doc.dimensions.removeAll { $0.id == dimId }
            doc.dimensions.append(
                .init(
                    id: dimId, kind: "angular",
                    anchors: ["armA": armA, "apex": apex, "armB": armB],
                    value: degrees, label: label, anchorPoints: points
                ))
            try? sidecar.write(doc)
            return IntrospectionTools.encode(
                DimensionResult(
                    dimensionId: dimId, kind: "angular", value: degrees, unit: "deg",
                    anchorPoints: points
                ))

        case .radial:
            guard let edgeId = anchors["circularEdge"] else {
                return .init("radial dimension requires anchors.circularEdge.")
            }
            guard let snap = await registry.snapshot(for: edgeId) else {
                return .init("Could not resolve circular edge.")
            }
            let rim = SIMD3(snap.center[0], snap.center[1], snap.center[2])
            // v0.7: prefer the geometric centre captured by select_topology.
            // Falls back to arc-length / 2π for legacy snapshots that
            // don't have circleCenter populated.
            let radius: Double
            let centerArr: [Double]
            if let c = snap.circleCenter, c.count == 3 {
                let centre = SIMD3(c[0], c[1], c[2])
                radius = simd_length(rim - centre)
                centerArr = c
            } else if let lengthArc = snap.length {
                radius = lengthArc / (2 * .pi)
                centerArr = snap.center  // best we can do without circleCenter
            } else {
                return .init(
                    "Could not resolve circular edge: re-run select_topology after upgrading to capture circleCenter."
                )
            }
            let value = showDiameter ? radius * 2 : radius
            // anchorPoints: [centre, rim]. Renderer draws a leader
            // between them; centre alone (legacy v0.5 shape) was just
            // a marker sphere with no rim attachment.
            let points = [centerArr, [rim.x, rim.y, rim.z]]
            doc.dimensions.removeAll { $0.id == dimId }
            doc.dimensions.append(
                .init(
                    id: dimId, kind: "radial",
                    anchors: ["circularEdge": edgeId],
                    value: value, label: label, anchorPoints: points
                ))
            try? sidecar.write(doc)
            return IntrospectionTools.encode(
                DimensionResult(
                    dimensionId: dimId, kind: showDiameter ? "diameter" : "radial",
                    value: value, unit: "mm",
                    anchorPoints: points
                ))
        }
    }

    // MARK: - add_scene_primitive

    public enum PrimitiveKind: String {
        case trihedron, workPlane, axis, pointCloud
    }

    public struct PrimitiveResult: Encodable {
        public let primitiveId: String
        public let kind: String
    }

    public static func addScenePrimitive(
        kind: PrimitiveKind,
        params: [String: AnyCodable],
        id: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir)
        var doc = sidecar.read()
        let primId = id ?? "prim_\(UUID().uuidString.prefix(8))"
        doc.primitives.removeAll { $0.id == primId }
        doc.primitives.append(.init(id: primId, kind: kind.rawValue, params: params))
        try? sidecar.write(doc)
        return IntrospectionTools.encode(
            PrimitiveResult(
                primitiveId: primId, kind: kind.rawValue
            ))
    }

    // MARK: - remove_scene_annotation

    public struct RemoveResult: Encodable {
        public let removed: Bool
        public let kind: String?
        public let id: String
    }

    public static func removeSceneAnnotation(
        id: String,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir)
        var doc = sidecar.read()
        if let dim = doc.dimensions.first(where: { $0.id == id }) {
            doc.dimensions.removeAll { $0.id == id }
            try? sidecar.write(doc)
            return IntrospectionTools.encode(RemoveResult(removed: true, kind: dim.kind, id: id))
        }
        if let prim = doc.primitives.first(where: { $0.id == id }) {
            doc.primitives.removeAll { $0.id == id }
            try? sidecar.write(doc)
            return IntrospectionTools.encode(RemoveResult(removed: true, kind: prim.kind, id: id))
        }
        return IntrospectionTools.encode(RemoveResult(removed: false, kind: nil, id: id))
    }
}
