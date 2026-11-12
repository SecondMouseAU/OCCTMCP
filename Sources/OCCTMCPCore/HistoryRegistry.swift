// HistoryRegistry: per-body RETAINED lineage of BRepGraphs (OCCTSwift's wrapper around OCCT's
// BRepGraph, renamed from TopologyGraph in OCCTSwift v1.15.0 / SecondMouseAU/OCCTSwift#333) with
// history records, used by remap_selection to walk selectionIds across chains of operations that
// participate in history capture.
//
// #90/#91/#93 full completion: a body keeps ONE BRepGraph across successive mutations, instead of
// a fresh disposable graph per call. Chain two history-bearing ops (apply_feature hole, then
// apply_feature fillet, same body) and hop 2 must absorb into the SAME graph object hop 1
// committed to. BRepGraph.add(_:absorbing:...)'s history absorption correlates by TShape object
// identity, and Shape.loadBREP mints a new TShape tree every call even for byte-identical content,
// so re-loading from disk between hops silently produces a zero-record absorb.
//
// `currentEditInput` (editing tools) and `currentInput(bodyId:body:outputDir:)` (reading tools,
// which may be handed the embedding host's own shape) are the two paths every history-aware tool
// uses to obtain its starting Shape: fingerprint match (mtime+size on the body's file) returns the
// cached liveShape/graph/root with no disk read; any mismatch (first touch, or an out-of-band
// rewrite, e.g. execute_script) triggers a fresh load and a fresh graph. `commit` absorbs a
// mutation's ShapeHistoryRef into the graph the lookup returned and writes the resulting lineage
// back. When there's no ref, or the
// absorb fails or no-ops (add() returns nil, or historyRecordCount doesn't grow, the TShape-
// identity gap surfacing despite currentInput's best effort), it falls back to a generation reset:
// a fresh graph built from the output alone, exactly today's behaviour.
//
// BRepGraph is a reference type (`final class`), so a graph object shared across two LineageEntry
// keys (a two-input boolean's `outId` plus `aBodyId`; apply_feature's output body plus its
// unchanged source body) mutates in place the instant `add(_:absorbing:...)` runs for either. No
// second write is needed for the side whose on-disk file didn't change. `absorb(into:root:...)`
// exists precisely for that side: it runs the absorb without touching the registry, so a bodyId
// whose file is unmodified never gets its liveShape/fingerprint overwritten with the OTHER side's
// output, which would silently corrupt the next read of that body.
//
// SecondMouseAU/OCCTSwift#336 (retracted in v1.15.2, not a bug): a two-hop chain (a second
// *WithFullHistory op onto the output of a prior one, rather than a freshly-loaded Shape) was
// reported to absorb zero records. Root cause: the repro tool's second cut was aimed at a corner
// outside the box's actual bounds, `Shape.box` being centered at the origin rather than
// corner-anchored, so the second op was a genuine geometric no-op; this repo's own
// HistoryRegistryLineageTests.retainedLineageSurvivesTwoHops carried the identical geometry
// mistake and is now fixed the same way. Two-hop (and longer) chains absorb correctly.

import Foundation
import OCCTSwift
import ScriptHarness
import simd

public enum HistoryRegistryError: Error, CustomStringConvertible {
    case graphBuildFailed(bodyId: String)

    public var description: String {
        switch self {
        case .graphBuildFailed(let bodyId):
            return "Failed to build a BRepGraph for body \"\(bodyId)\""
        }
    }
}

public actor HistoryRegistry {
    private static let scope = DirectoryScoped<HistoryRegistry> { HistoryRegistry() }
    public static var shared: HistoryRegistry { scope.current }

    /// mtime + size snapshot of a body's BREP file, used to detect out-of-band rewrites
    /// (execute_script, manual edits) between calls.
    ///
    /// Not a content hash: a heuristic guard, same spirit as an ETag.
    struct FileFingerprint: Equatable {
        let mtime: TimeInterval
        let size: Int64
    }

    /// Retained per-body lineage: the graph (may be shared with another body's entry), the EXACT
    /// live Shape object it was built from or last committed to (not a re-load: TShape identity
    /// matters, see file header), the node to use as `inputRoots` for the next
    /// `add(_:absorbing:...)`, and the fingerprint `currentInput` re-checks.
    struct LineageEntry {
        var graph: BRepGraph
        var liveShape: Shape
        var root: BRepGraph.NodeRef
        var fingerprint: FileFingerprint
        /// True when `liveShape` is the embedding host's own shape rather than one read from the
        /// file, so a lookup that has no host shape to offer rebuilds from the file instead.
        var fromHost = false
    }

    private var entries: [String: LineageEntry] = [:]

    public init() {}

    public func clear() {
        entries.removeAll()
    }

    public func count() -> Int {
        return entries.count
    }

    /// Lookup used by RemapTools' primary history rung.
    ///
    /// Unchanged contract from the pre-retention design, now backed by the retained lineage
    /// instead of a disposable per-call graph, so it sees history from every hop committed so
    /// far, not just the most recent one.
    public func graph(for bodyId: String) -> BRepGraph? {
        return entries[bodyId]?.graph
    }

    /// The retained graph's `instanceID` for `bodyId`, if any.
    ///
    /// Diagnostic and test-only: proves "one graph across mutations" by staying constant across
    /// a multi-hop chain.
    public func instanceID(for bodyId: String) -> UInt64? {
        return entries[bodyId]?.graph.instanceID
    }

    private static func fingerprint(atPath path: String) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        guard let date = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileFingerprint(mtime: date.timeIntervalSince1970, size: size)
    }

    /// Resolve the Shape + retained graph an editing tool starts from, for `bodyId` at `path`.
    ///
    /// Re-stats `path` (no content read) and compares against the cached fingerprint: a match
    /// returns the cached liveShape/graph/root with no disk I/O at all. Any mismatch (no entry
    /// yet, the file changed out from under the registry, or the cached lineage was built from an
    /// embedding host's shape) loads the file as BREP and starts a brand-new graph, caching it
    /// under `bodyId` before returning. An edit therefore always starts from the file, whatever a
    /// reading tool ran before it.
    ///
    /// For tools that write BREP back to `path`, which must also have checked the body is `brep`
    /// (`BodyLoader.editRefusal`). It never asks the embedding host for a shape. A tool that only
    /// reads the body calls `currentInput(bodyId:body:outputDir:)`.
    @discardableResult
    public func currentEditInput(
        bodyId: String,
        path: String
    ) throws -> (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool) {
        try resolveInput(bodyId: bodyId, path: path, lookup: .editing) {
            try Shape.loadBREP(fromPath: path)
        }
    }

    /// The same, for a tool that only reads `body`: the host's own shape when it supplies one,
    /// otherwise the body's file read by its manifest `format`.
    ///
    /// A host shape is cached by identity as well as by file fingerprint. The file need not change
    /// when the host swaps the shape it holds, so a cached lineage built from a different shape
    /// is rebuilt from the host's, keeping `GraphUID`s and `index` values those of the shape the
    /// host actually holds. A lineage built from the host's shape is not served to a lookup the
    /// host declines, which reads the file instead.
    @discardableResult
    public func currentInput(
        bodyId: String,
        body: BodyDescriptor,
        outputDir: String
    ) throws -> (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool) {
        try resolveInput(
            bodyId: bodyId, path: "\(outputDir)/\(body.file)",
            lookup: .reading(host: try BodyLoader.hostShape(for: body, outputDir: outputDir))
        ) {
            try BodyLoader.loadFromFile(body: body, outputDir: outputDir)
        }
    }

    /// The pre-#258 name of `currentEditInput(bodyId:path:)`, which reads the file as BREP.
    ///
    /// Kept so an embedding host that calls it still compiles. A reading tool should call
    /// `currentInput(bodyId:body:outputDir:)`, which reads by the body's manifest `format`.
    @available(
        *, deprecated,
        message:
            "reads BREP only: use currentEditInput(bodyId:path:) before an edit, or currentInput(bodyId:body:outputDir:) to read"
    )
    @discardableResult
    public func currentInput(
        bodyId: String,
        path: String
    ) throws -> (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool) {
        try currentEditInput(bodyId: bodyId, path: path)
    }

    /// Who is asking, which decides whether a cached lineage still answers.
    private enum Lookup {
        /// An editing tool: starts from the file, so a lineage built from a host's shape is not
        /// continued. What an edit runs on then never depends on which tool ran before it.
        case editing
        /// A reading tool, with the shape the host supplied for the body, nil when it supplied none.
        case reading(host: Shape?)

        var hostShape: Shape? {
            if case .reading(let host) = self { return host }
            return nil
        }

        func accepts(_ entry: LineageEntry) -> Bool {
            switch self {
            case .editing: return !entry.fromHost
            case .reading(let host):
                return host.map { $0.isSame(as: entry.liveShape) } ?? !entry.fromHost
            }
        }
    }

    private func resolveInput(
        bodyId: String,
        path: String,
        lookup: Lookup,
        load: () throws -> Shape
    ) throws -> (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool) {
        let fp = Self.fingerprint(atPath: path)
        if let entry = entries[bodyId], let fp, entry.fingerprint == fp, lookup.accepts(entry) {
            return (entry.liveShape, entry.graph, entry.root, false)
        }
        let hostShape = lookup.hostShape
        let shape = try hostShape ?? load()
        guard let graph = BRepGraph(shape: shape),
            let root = Self.trackableRoot(for: shape, in: graph)
        else {
            throw HistoryRegistryError.graphBuildFailed(bodyId: bodyId)
        }
        entries[bodyId] = LineageEntry(
            graph: graph,
            liveShape: shape,
            root: root,
            fingerprint: fp ?? FileFingerprint(mtime: 0, size: 0),
            fromHost: hostShape != nil
        )
        return (shape, graph, root, true)
    }

    /// `add(_:absorbing:...)`'s history absorption only tracks vertex, edge, face and solid nodes
    /// (`BRepTools_History::IsSupportedType`, see the `add` doc quoted in the file header); a
    /// `.compound` wrapper isn't itself trackable. Boolean-op and FeatureReconstructor outputs
    /// register as `.compound` even for a single-solid result (verified empirically during this
    /// change's development), so a NodeRef pointing at one can't be fed back in as a LATER add()
    /// call's `inputRoots`: the absorb runs, `add()` itself returns non-nil, but
    /// `historyRecordCount` never grows, a silent no-op that looks identical to "genuinely nothing
    /// changed" from the caller's side.
    ///
    /// Drill down to the wrapped solid whenever the resolved node
    /// isn't already a trackable kind; falls back to the raw (untrackable) node only if no solid
    /// child can be found at all, which keeps `currentInput`/`commit` working (degrading later
    /// chained absorbs to generation resets) rather than failing outright.
    static func trackableRoot(for shape: Shape, in graph: BRepGraph) -> BRepGraph.NodeRef? {
        guard let node = graph.findNode(for: shape) else { return nil }
        let raw = BRepGraph.NodeRef(kind: node.kind, index: node.index)
        switch node.kind {
        case .solid, .face, .edge, .vertex:
            return raw
        default:
            guard let solid = shape.subShapes(ofType: .solid).first,
                let solidNode = graph.findNode(for: solid)
            else {
                return raw
            }
            return BRepGraph.NodeRef(kind: solidNode.kind, index: solidNode.index)
        }
    }

    /// Absorb `ref` into `graph` (mutates it in place) WITHOUT touching the registry.
    ///
    /// Used for the
    /// side of a shared-graph mutation whose own on-disk file is unchanged, e.g. the b-side of a
    /// two-input boolean, so its entry's liveShape/fingerprint never gets overwritten with the
    /// other side's output. Returns the added result's topology-root node (re-resolved via
    /// `trackableRoot`, not the raw return value from `add()`; see that function's doc), or nil
    /// if the add failed or absorbed zero records (the TShape-identity gap, see file header).
    @discardableResult
    public func absorb(
        into graph: BRepGraph,
        root: BRepGraph.NodeRef,
        output: Shape,
        ref: ShapeHistoryRef,
        operationName: String
    ) -> BRepGraph.NodeRef? {
        let before = graph.historyRecordCount
        guard
            graph.add(output, absorbing: ref, inputRoots: [root], operationName: operationName)
                != nil,
            graph.historyRecordCount > before
        else {
            return nil
        }
        return Self.trackableRoot(for: output, in: graph)
    }

    /// Commit a mutation's output as the new lineage state for `bodyId`: the file at `path` now
    /// contains `output`.
    ///
    /// Only call this for the body whose file was actually (over)written; a
    /// body sharing the same graph object but whose own file is unchanged should use `absorb`
    /// instead (see `recordBooleanHistory`).
    ///
    /// Decision tree: when `ref` and `from` are both present, absorb into `from`'s graph; success
    /// (absorbed AND historyRecordCount grew) is a CONTINUATION, writing an entry that keeps
    /// `from.graph` (now mutated) with the new root. Anything else, no ref, no `from`, or a
    /// failed/no-op absorb, is a GENERATION RESET: a fresh graph built from `output` alone,
    /// discarding any prior history for this key (today's pre-retention behaviour, unchanged).
    @discardableResult
    public func commit(
        bodyId: String,
        path: String,
        output: Shape,
        ref: ShapeHistoryRef?,
        from prior: (graph: BRepGraph, root: BRepGraph.NodeRef)?,
        operationName: String
    ) -> Bool {
        let fp = Self.fingerprint(atPath: path) ?? FileFingerprint(mtime: 0, size: 0)

        if let ref, let prior,
            let newRoot = absorb(
                into: prior.graph, root: prior.root, output: output, ref: ref,
                operationName: operationName)
        {
            entries[bodyId] = LineageEntry(
                graph: prior.graph, liveShape: output, root: newRoot, fingerprint: fp)
            return true
        }

        guard let freshGraph = BRepGraph(shape: output),
            let root = Self.trackableRoot(for: output, in: freshGraph)
        else {
            entries.removeValue(forKey: bodyId)
            return false
        }
        entries[bodyId] = LineageEntry(
            graph: freshGraph, liveShape: output, root: root, fingerprint: fp)
        return false
    }

    /// Re-key a retained lineage across a rename so it survives `rename_body`. selectionIds embed
    /// bodyId, so old selection strings still go stale on rename (unchanged, documented
    /// behaviour); this only keeps the GRAPH's history alive under the new id.
    public func rename(bodyId: String, to newBodyId: String) {
        guard let entry = entries.removeValue(forKey: bodyId) else { return }
        entries[newBodyId] = entry
    }
}

extension HistoryRegistry {

    /// Boolean per-input history (#90/#93): absorb `ref` into BOTH input sides' retained graphs,
    /// one `add(_:absorbing:...)` call per side. `add()` requires the input and result to live in
    /// ONE graph instance, so a two-input boolean needs two independent graphs.
    ///
    /// The a-side graph becomes `outId`'s canonical graph too (arbitrary but consistent "primary"
    /// choice: `outId` resolves through the a-side graph for history purposes) via `commit`, which
    /// writes `outId`'s entry. The b-side only needs `absorb`: `bBodyId`'s own file is unchanged by
    /// a boolean (only `outId`'s output file is new), so writing a `commit`-style entry for it
    /// would overwrite its liveShape/fingerprint with `output` and corrupt the next read of that
    /// body. `bGraph`'s mutation is visible through `bBodyId`'s existing entry automatically since
    /// BRepGraph is a reference type.
    @discardableResult
    public func recordBooleanHistory(
        outId: String,
        outputPath: String,
        aLineage: (graph: BRepGraph, root: BRepGraph.NodeRef),
        bLineage: (graph: BRepGraph, root: BRepGraph.NodeRef),
        output: Shape,
        ref: ShapeHistoryRef,
        operationName: String
    ) -> Bool {
        absorb(
            into: bLineage.graph, root: bLineage.root, output: output, ref: ref,
            operationName: operationName)
        return commit(
            bodyId: outId, path: outputPath, output: output, ref: ref, from: aLineage,
            operationName: operationName)
    }
}
