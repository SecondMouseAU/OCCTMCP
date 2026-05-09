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

    /// `bodyId → TopologyGraph` — populated by tools that opt into
    /// history capture. Eviction is automatic when the body is
    /// re-mutated (the new graph replaces the old).
    private var graphs: [String: TopologyGraph] = [:]

    public init() {}

    /// Record a post-mutation graph for `bodyId`. Replaces any prior
    /// graph for the same body — older selectionIds remap against the
    /// most recent state only.
    public func record(bodyId: String, graph: TopologyGraph) {
        graphs[bodyId] = graph
    }

    public func graph(for bodyId: String) -> TopologyGraph? {
        return graphs[bodyId]
    }

    public func clear() {
        graphs.removeAll()
    }

    public func count() -> Int {
        return graphs.count
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
        graphs[outId] = postGraph
        graphs[aBodyId] = postGraph
        graphs[bBodyId] = postGraph
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
        graphs[bodyId] = postGraph
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
        guard let graph = TopologyGraph(shape: postMutationShape) else { return }
        // Faces / edges / vertices are the only kinds we surface as
        // selectionIds, so we only need to record those.
        for kind in [TopologyGraph.NodeKind.face, .edge, .vertex] {
            let count: Int
            switch kind {
            case .face:    count = graph.faceCount
            case .edge:    count = graph.edgeCount
            case .vertex:  count = graph.vertexCount
            default:       count = 0
            }
            for i in 0..<count {
                let ref = TopologyGraph.NodeRef(kind: kind, index: i)
                graph.recordHistory(
                    operationName: operationName,
                    original: ref,
                    replacements: [ref]
                )
            }
        }
        graphs[bodyId] = graph
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
        for kind in [TopologyGraph.NodeKind.face, .edge, .vertex] {
            let count: Int
            switch kind {
            case .face:    count = post.faceCount
            case .edge:    count = post.edgeCount
            case .vertex:  count = post.vertexCount
            default:       count = 0
            }
            for i in 0..<count {
                let ref = TopologyGraph.NodeRef(kind: kind, index: i)
                post.recordHistory(
                    operationName: operationName,
                    original: ref,
                    replacements: [ref]
                )
            }
        }
        graphs[bodyId] = post
        return true
    }
}
