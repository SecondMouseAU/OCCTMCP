// DistanceTargets: resolves one end of a `measure_distance` call (#249) to a
// Shape, either a whole body, a minted selectionId, or a `kind[index]`
// sub-shape reference.

import Foundation
import OCCTSwift
import ScriptHarness

extension IntrospectionTools {

    /// One resolved end of a distance measurement.
    struct DistanceTarget {
        let bodyId: String
        let shape: Shape
    }

    /// Failure to resolve a `from` / `to` reference.
    enum DistanceTargetError: Error, CustomStringConvertible {
        case missingBody(role: String)
        case badReference(role: String, ref: String)
        case outOfRange(role: String, ref: String, count: Int)
        case unresolved(role: String, ref: String)

        var description: String {
            switch self {
            case .missingBody(let role):
                let param = role == "from" ? "`fromBodyId`" : "`toBodyId`"
                return "`\(role)` needs a selectionId, or a body to measure (\(param))."
            case .badReference(let role, let ref):
                return
                    "`\(role)` '\(ref)' is neither a selectionId (sel:<bodyId>#face[N]) nor a face[N] / edge[N] reference."
            case .outOfRange(let role, let ref, let count):
                return "`\(role)` '\(ref)' is out of range (\(count) on the body)."
            case .unresolved(let role, let ref):
                return "`\(role)` '\(ref)' could not be resolved to geometry."
            }
        }
    }

    /// Resolve a `from` / `to` argument of `measure_distance`.
    ///
    /// With `ref` nil this is the whole body `bodyId`. A `ref` starting `sel:`
    /// is a selectionId; its index is a BRepGraph node index, so it resolves
    /// through the body's retained graph, never by `Shape.faces()` position. A
    /// `ref` of the form `face[N]` or `edge[N]` takes N as the `Shape.faces()`
    /// or `Shape.edges()` position, the label `query_topology` prints, on
    /// `bodyId` or, when that is nil, on `fallbackBodyId` (the `from` end's
    /// body), so two sub-shapes of one body need only one body id.
    static func resolveDistanceTarget(
        ref: String?,
        bodyId: String?,
        fallbackBodyId: String?,
        role: String,
        store: ManifestStore,
        registry: SelectionRegistry
    ) async throws -> DistanceTarget {
        guard let ref else {
            guard let bodyId else { throw DistanceTargetError.missingBody(role: role) }
            return DistanceTarget(
                bodyId: bodyId, shape: try loadShape(bodyId: bodyId, store: store).shape)
        }

        if ref.hasPrefix("sel:") {
            guard let anchor = await registry.anchor(for: ref) else {
                throw DistanceTargetError.badReference(role: role, ref: ref)
            }
            let loaded = try loadShape(bodyId: anchor.bodyId, store: store)
            guard let nodeKind = anchor.nodeKind, let index = anchor.index else {
                return DistanceTarget(bodyId: anchor.bodyId, shape: loaded.shape)
            }
            let lineage = try await HistoryRegistry.shared.currentInput(
                bodyId: anchor.bodyId, path: loaded.path)
            guard let sub = lineage.graph.shape(nodeKind: nodeKind, nodeIndex: index) else {
                throw DistanceTargetError.unresolved(role: role, ref: ref)
            }
            return DistanceTarget(bodyId: anchor.bodyId, shape: sub)
        }

        guard let open = ref.firstIndex(of: "["), ref.last == "]",
            let index = Int(ref[ref.index(after: open)..<ref.index(before: ref.endIndex)])
        else { throw DistanceTargetError.badReference(role: role, ref: ref) }
        let kind = String(ref[..<open])
        guard kind == "face" || kind == "edge" else {
            throw DistanceTargetError.badReference(role: role, ref: ref)
        }
        guard let body = bodyId ?? fallbackBodyId else {
            throw DistanceTargetError.missingBody(role: role)
        }
        let shape = try loadShape(bodyId: body, store: store).shape
        if kind == "face" {
            let faces = shape.faces()
            guard index >= 0, index < faces.count else {
                throw DistanceTargetError.outOfRange(role: role, ref: ref, count: faces.count)
            }
            guard let sub = Shape.fromFace(faces[index]) else {
                throw DistanceTargetError.unresolved(role: role, ref: ref)
            }
            return DistanceTarget(bodyId: body, shape: sub)
        }
        let edges = shape.edges()
        guard index >= 0, index < edges.count else {
            throw DistanceTargetError.outOfRange(role: role, ref: ref, count: edges.count)
        }
        guard let sub = Shape.fromEdge(edges[index]) else {
            throw DistanceTargetError.unresolved(role: role, ref: ref)
        }
        return DistanceTarget(bodyId: body, shape: sub)
    }
}
