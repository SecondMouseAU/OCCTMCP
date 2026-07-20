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

    /// Per-body post-mutation `TopologyGraph`. Replaced when the body
    /// is re-mutated. Consumed by `RemapTools` via
    /// `TopologyGraph.findDerivedOrSelf` (OCCTSwift 1.1.0+).
    private var graphs: [String: TopologyGraph] = [:]

    public init() {}

    /// Record a post-mutation graph for `bodyId`. Replaces any prior
    /// entry for the same body — older selectionIds remap against the
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
    /// via OCCTSwift 1.12's `add(_:absorbing:inputRoots:operationName:)`
    /// (#90 / #93) — the kernel's own `BRepTools_History` correlates
    /// input sub-shapes to their result-side successors, so there is no
    /// centroid guessing left to misfire on symmetric/patterned geometry.
    ///
    /// `add(_:absorbing:...)` requires the input and result to live in
    /// ONE graph instance (NodeRefs/GraphUIDs are graph-scoped), so a
    /// two-input boolean needs two independent graphs — one rooted at
    /// `aShape`, one at `bShape` — each absorbing the same
    /// `ShapeHistoryRef` from its own side. `outId` resolves through the
    /// `a`-side graph (arbitrary but consistent choice of "canonical"
    /// graph for the result body); a selectionId taken on `bBodyId`
    /// still resolves correctly through the separately-recorded `b`-side
    /// graph.
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
        if let aGraph = TopologyGraph(shape: aShape),
           let aRoot = aGraph.findNode(for: aShape) {
            aGraph.add(
                output, absorbing: ref,
                inputRoots: [TopologyGraph.NodeRef(kind: aRoot.kind, index: aRoot.index)],
                operationName: operationName
            )
            graphs[aBodyId] = aGraph
            graphs[outId] = aGraph
        }
        if let bGraph = TopologyGraph(shape: bShape),
           let bRoot = bGraph.findNode(for: bShape) {
            bGraph.add(
                output, absorbing: ref,
                inputRoots: [TopologyGraph.NodeRef(kind: bRoot.kind, index: bRoot.index)],
                operationName: operationName
            )
            graphs[bBodyId] = bGraph
        }
    }

    /// Translate a single-input `ShapeHistoryRef` (gsdali/OCCTSwift#165
    /// Tier 2 / Tier 3 — fillet / chamfer / shell / defeature, plus
    /// `FeatureReconstructor.BuildResult.histories[id]`) via
    /// `add(_:absorbing:inputRoots:operationName:)` (#90 / #93). Same
    /// one-graph-instance requirement as `recordBooleanHistory`, just
    /// with a single input side.
    ///
    /// Operations without a `*WithFullHistory` variant (sewing, healing
    /// — SecondMouseAU/OCCTSwift#327) don't have a `ShapeHistoryRef` to
    /// absorb and so never reach this method; `heal_shape` still uses
    /// `recordIdentityHistoryIfTopologyPreserved`'s topology-count
    /// heuristic below, unchanged by this refactor.
    public func recordSingleInputHistory(
        bodyId: String,
        inputShape: Shape,
        output: Shape,
        ref: ShapeHistoryRef,
        operationName: String
    ) {
        guard let graph = TopologyGraph(shape: inputShape),
              let root = graph.findNode(for: inputShape) else { return }
        graph.add(
            output, absorbing: ref,
            inputRoots: [TopologyGraph.NodeRef(kind: root.kind, index: root.index)],
            operationName: operationName
        )
        graphs[bodyId] = graph
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
        // No history records to write — transforms preserve topology
        // 1:1 by construction. Register the post-mutation graph and
        // let RemapTools' `findDerivedOrSelf` resolve every node to
        // self (since none are mentioned in any record).
        _ = operationName
        guard let graph = TopologyGraph(shape: postMutationShape) else { return }
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
        // Topology preserved 1:1 — no records to write. RemapTools'
        // `findDerivedOrSelf` resolves every node to self.
        _ = operationName
        graphs[bodyId] = post
        return true
    }
}
