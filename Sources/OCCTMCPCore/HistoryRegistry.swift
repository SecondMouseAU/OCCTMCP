// HistoryRegistry — per-body cache of post-mutation TopologyGraphs
// with history records, used by remap_selection to walk selectionIds
// across operations that participate in history capture.
//
// v0.6 wires `transform_body` (1:1 identity history — every
// face/edge/vertex in the post-mutation graph corresponds to the same
// index in the pre-mutation graph). remap_selection consults the
// registry first; absent a recorded graph, it falls back to the
// centroid-distance heuristic from v0.4.
//
// Future tools that should opt in to history capture:
//   - boolean_op (BRepAlgoAPI_BooleanOperation.Modified/Generated/IsDeleted)
//   - apply_feature (FeatureReconstructor's BuildHistory by id)
//   - heal_shape (ShapeFix history accessors)
//   - mirror_or_pattern (1:1 within each repetition; pattern instances
//     map to source by modulo)
//
// Each pays off only when the underlying OCCT op surfaces history;
// transforms are the only "free" case because they preserve topology.

import Foundation
import simd
import OCCTSwift

public actor HistoryRegistry {
    public static let shared = HistoryRegistry()

    /// Per-body cached state. `isIdentityPreserving` is true when the
    /// recorded mutation didn't change topology indices — every
    /// pre-mutation node maps to the same index post-mutation. Used so
    /// remap_selection can short-circuit `findDerived` (which OCCT
    /// only populates for *changed* nodes — explicit
    /// "original==replacement" identity records are no-ops in OCCT) and
    /// just return the same index. Cleared/replaced when the body is
    /// re-mutated.
    public struct Entry: Sendable {
        public let graph: TopologyGraph
        public let isIdentityPreserving: Bool
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Record a post-mutation graph for `bodyId`. Replaces any prior
    /// entry for the same body — older selectionIds remap against the
    /// most recent state only.
    public func record(bodyId: String, graph: TopologyGraph) {
        entries[bodyId] = Entry(graph: graph, isIdentityPreserving: false)
    }

    public func entry(for bodyId: String) -> Entry? {
        return entries[bodyId]
    }

    public func graph(for bodyId: String) -> TopologyGraph? {
        return entries[bodyId]?.graph
    }

    public func clear() {
        entries.removeAll()
    }

    public func count() -> Int {
        return entries.count
    }
}

extension HistoryRegistry {

    /// Translate per-input boolean history (gsdali/OCCTSwift#165 Tier 1)
    /// into TopologyGraph.recordHistory entries on the post-mutation
    /// graph for the result body. Each input subshape on a-shape and
    /// b-shape gets its own per-kind record; output sub-shapes are
    /// matched by centroid distance among the *modified ∪ generated*
    /// set returned by `ShapeHistoryRef.record(of:)` — much narrower
    /// than the global centroid heuristic remap_selection used pre-v0.10.
    ///
    /// Records under both `outId` (the new body) and `aBodyId` /
    /// `bBodyId` so a selectionId on either input remaps cleanly. The
    /// recorded post-graph is the SAME object on all three keys, so
    /// findDerived resolves identically — selection IDs use the
    /// shared NodeRef space of the result graph.
    public func recordBooleanHistory(
        bodyId outId: String,
        aBodyId: String,
        bBodyId: String,
        aShape: Shape,
        bShape: Shape,
        output: Shape,
        ref: ShapeHistoryRef,
        operationName: String
    ) {
        guard let postGraph = TopologyGraph(shape: output) else { return }
        postGraph.isHistoryEnabled = true

        // Pre-compute output sub-shape centroids so per-input lookup
        // is O(N+M) total rather than O(N*M).
        let postFaces = output.subShapes(ofType: .face)
        let postEdges = output.subShapes(ofType: .edge)
        let postVertices = output.subShapes(ofType: .vertex)
        let faceCentres: [SIMD3<Double>] = postFaces.map { $0.centerOfMass ?? .zero }
        let edgeCentres: [SIMD3<Double>] = postEdges.map { $0.centerOfMass ?? .zero }
        let vertexCentres: [SIMD3<Double>] = postVertices.map { $0.centerOfMass ?? .zero }

        recordSide(
            inputShape: aShape, postGraph: postGraph,
            faceCentres: faceCentres, edgeCentres: edgeCentres, vertexCentres: vertexCentres,
            ref: ref, operationName: operationName
        )
        recordSide(
            inputShape: bShape, postGraph: postGraph,
            faceCentres: faceCentres, edgeCentres: edgeCentres, vertexCentres: vertexCentres,
            ref: ref, operationName: operationName
        )

        // Same graph under all three keys so remap_selection finds it
        // regardless of which input the selectionId was originally
        // recorded against.
        let entry = Entry(graph: postGraph, isIdentityPreserving: false)
        entries[outId] = entry
        entries[aBodyId] = entry
        entries[bBodyId] = entry
    }

    /// Translate a single-input `ShapeHistoryRef` (gsdali/OCCTSwift#165
    /// Tier 2 / Tier 3 — fillet / chamfer / shell / defeature, plus
    /// `FeatureReconstructor.BuildResult.histories[id]`) into
    /// `TopologyGraph.recordHistory` entries on the post-mutation graph.
    /// Same per-kind matching logic as `recordBooleanHistory`'s
    /// per-side path, just without a second input shape.
    public func recordSingleInputHistory(
        bodyId: String,
        inputShape: Shape,
        output: Shape,
        ref: ShapeHistoryRef,
        operationName: String
    ) {
        guard let postGraph = TopologyGraph(shape: output) else { return }
        postGraph.isHistoryEnabled = true
        let postFaces = output.subShapes(ofType: .face)
        let postEdges = output.subShapes(ofType: .edge)
        let postVertices = output.subShapes(ofType: .vertex)
        let faceCentres: [SIMD3<Double>] = postFaces.map { $0.centerOfMass ?? .zero }
        let edgeCentres: [SIMD3<Double>] = postEdges.map { $0.centerOfMass ?? .zero }
        let vertexCentres: [SIMD3<Double>] = postVertices.map { $0.centerOfMass ?? .zero }

        recordSide(
            inputShape: inputShape, postGraph: postGraph,
            faceCentres: faceCentres, edgeCentres: edgeCentres, vertexCentres: vertexCentres,
            ref: ref, operationName: operationName
        )
        entries[bodyId] = Entry(graph: postGraph, isIdentityPreserving: false)
    }

    private func recordSide(
        inputShape: Shape,
        postGraph: TopologyGraph,
        faceCentres: [SIMD3<Double>],
        edgeCentres: [SIMD3<Double>],
        vertexCentres: [SIMD3<Double>],
        ref: ShapeHistoryRef,
        operationName: String
    ) {
        recordKind(
            inputs: inputShape.subShapes(ofType: .face),
            kind: .face,
            postCentres: faceCentres,
            postGraph: postGraph,
            ref: ref,
            operationName: operationName
        )
        recordKind(
            inputs: inputShape.subShapes(ofType: .edge),
            kind: .edge,
            postCentres: edgeCentres,
            postGraph: postGraph,
            ref: ref,
            operationName: operationName
        )
        recordKind(
            inputs: inputShape.subShapes(ofType: .vertex),
            kind: .vertex,
            postCentres: vertexCentres,
            postGraph: postGraph,
            ref: ref,
            operationName: operationName
        )
    }

    private func recordKind(
        inputs: [Shape],
        kind: TopologyGraph.NodeKind,
        postCentres: [SIMD3<Double>],
        postGraph: TopologyGraph,
        ref: ShapeHistoryRef,
        operationName: String
    ) {
        for (inputIndex, input) in inputs.enumerated() {
            let record = ref.record(of: input)
            if record.isDeleted && record.modified.isEmpty && record.generated.isEmpty {
                postGraph.recordHistory(
                    operationName: operationName,
                    original: TopologyGraph.NodeRef(kind: kind, index: inputIndex),
                    replacements: []   // explicitly deleted
                )
                continue
            }
            var postIndices: [Int] = []
            for outShape in (record.modified + record.generated) {
                guard let centre = outShape.centerOfMass else { continue }
                if let postIdx = nearestIndex(of: centre, in: postCentres) {
                    if !postIndices.contains(postIdx) { postIndices.append(postIdx) }
                }
            }
            // Empty post-set after a non-deleted record means the
            // builder reported derivatives we couldn't resolve — leave
            // unrecorded so remap_selection's heuristic can still make
            // a guess rather than locking in "lost".
            guard !postIndices.isEmpty else { continue }
            postGraph.recordHistory(
                operationName: operationName,
                original: TopologyGraph.NodeRef(kind: kind, index: inputIndex),
                replacements: postIndices.map {
                    TopologyGraph.NodeRef(kind: kind, index: $0)
                }
            )
        }
    }

    private func nearestIndex(of point: SIMD3<Double>, in centres: [SIMD3<Double>]) -> Int? {
        var bestIdx: Int? = nil
        var bestDist = Double.infinity
        for (i, c) in centres.enumerated() {
            let d = simd_distance(point, c)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    /// Convenience for the common "post-mutation graph with 1:1
    /// identity history" pattern used by topology-preserving tools
    /// (transforms, in-place healings, …). Records every node in the
    /// post-mutation graph as deriving from the same-indexed node in
    /// the (notional) pre-mutation graph — find_derived will return
    /// the same index, which is what we want.
    public func recordIdentityHistory(
        bodyId: String,
        postMutationShape: Shape,
        operationName: String
    ) {
        // OCCT's history API treats `original == replacement` records
        // as no-ops — `findDerived` returns empty for an identity-only
        // record. Don't write anything; just register the post graph
        // with the identity-preserving flag so RemapTools can
        // short-circuit `findDerived` empties to "preserved at same
        // index".
        _ = operationName
        guard let graph = TopologyGraph(shape: postMutationShape) else { return }
        entries[bodyId] = Entry(graph: graph, isIdentityPreserving: true)
    }

    /// Conditional version of `recordIdentityHistory` — only records
    /// if the pre/post topology counts match (face / edge / vertex).
    /// Returns true when history was captured, false when the
    /// post-mutation shape's topology differs and the heuristic should
    /// take over downstream. Used by tools like `heal_shape` whose
    /// operation usually preserves topology but might rewire edges
    /// when fixing real defects.
    @discardableResult
    public func recordIdentityHistoryIfTopologyPreserved(
        bodyId: String,
        preMutationShape: Shape,
        postMutationShape: Shape,
        operationName: String
    ) -> Bool {
        guard let pre = TopologyGraph(shape: preMutationShape),
              let post = TopologyGraph(shape: postMutationShape) else {
            return false
        }
        guard pre.faceCount == post.faceCount,
              pre.edgeCount == post.edgeCount,
              pre.vertexCount == post.vertexCount else {
            return false
        }
        // Same reasoning as `recordIdentityHistory` — skip the
        // self-referencing record loop and just flag the entry.
        _ = operationName
        entries[bodyId] = Entry(graph: post, isIdentityPreserving: true)
        return true
    }
}
