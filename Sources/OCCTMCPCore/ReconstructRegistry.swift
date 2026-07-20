// ReconstructRegistry: actor-backed store of `sessionId → BRepGraph`
// for the `reconstruct_*` tool group (OCCTMCP #33).
//
// A "reconstruction session" is a live `BRepGraph` plus a `GraphUID`-keyed
// per-node attribute overlay (#95; see the class doc comment below). The
// reconstruction *engine* (surface fitting, congruence detection, the
// math behind residuals/confidence) lives downstream in OCCTReconstruct.
// OCCTMCP only reads and writes the attributed graph so an LLM-in-the-loop
// can annotate decisions (`decidedBy`, accept/reject, forced surface type,
// instance clusters) and have them persist via `GraphSnapshot`.
//
// All graph access is funnelled through the actor so the (`@unchecked
// Sendable`) `BRepGraph` reference type is never mutated concurrently:
// the tool layer builds a graph (from a body's BREP or an imported
// snapshot), hands it to `store(id:graph:)`, and never touches it again.
// Every subsequent read/write goes through an actor-isolated method.

import Foundation
import OCCTSwift

/// Namespaced attribute keys this layer reads/writes. The store is generic;
/// these are the keys the `reconstruct_*` tools own. Engine-written keys
/// (e.g. `reconstruct.residualRMS`, `reconstruct.confidence`) round-trip
/// through `get_graph` / `export_session` untouched.
public enum ReconstructKeys {
    public static let decidedBy = "reconstruct.decidedBy"
    public static let accepted = "reconstruct.accepted"
    public static let forcedSurfaceType = "reconstruct.forcedSurfaceType"
    public static let instanceCluster = "reconstruct.instanceCluster"
    public static let instanceConfirmed = "reconstruct.instanceConfirmed"
}

/// A Sendable, Encodable snapshot of a session's state for `get_graph` /
/// `import_session` responses. Lists topology counts plus every annotated
/// node (nodes carrying no attributes are omitted) and any instance
/// clusters derived from `reconstruct.instanceCluster`.
public struct ReconstructGraphState: Encodable, Sendable {
    public struct TopologyCounts: Encodable, Sendable {
        public let solids: Int
        public let shells: Int
        public let faces: Int
        public let wires: Int
        public let edges: Int
        public let vertices: Int
        public let compounds: Int
        public let totalNodes: Int
    }
    public struct NodeAttrs: Encodable, Sendable {
        public let node: String                       // "<kind>:<index>", e.g. "face:3"
        public let attributes: [String: AnyCodable]
    }
    public struct InstanceCluster: Encodable, Sendable {
        public let clusterId: String
        public let members: [String]
        public let confirmed: Bool
    }

    public let sessionId: String
    public let topology: TopologyCounts
    public let annotatedNodeCount: Int
    public let nodes: [NodeAttrs]
    public let instanceClusters: [InstanceCluster]
}

/// Outcome of a single-node write (`set_decision` / `force_fit`).
public enum ReconstructWriteOutcome: Sendable {
    case ok(node: String, attributes: [String: AnyCodable])
    case noSession(String)
    case badNode(String)
}

/// Outcome of a cluster write (`confirm_instances`).
public enum ReconstructClusterOutcome: Sendable {
    case ok(clusterId: String, members: [String], confirmed: Bool)
    case noSession(String)
    case badNodes([String])
}

public enum ReconstructError: Error, CustomStringConvertible, Sendable {
    case noSession(String)
    public var description: String {
        switch self {
        case .noSession(let id):
            return "No reconstruction session '\(id)'. Run reconstruct_get_graph or reconstruct_import_session first."
        }
    }
}

public actor ReconstructRegistry {
    public static let shared = ReconstructRegistry()

    /// #95/#92: node addressing and attribute storage are both `GraphUID`-based,
    /// not raw `NodeRef(kind, index)`. The `<kind>:<index>` wire format
    /// (`format`/`parse`) is unchanged for the agent-facing protocol (every
    /// existing `reconstruct_*` caller and stored `GraphSnapshot` still
    /// sees/round-trips the same strings), but internally:
    ///
    /// - `nodeUIDs` caches `wireString → GraphUID`: the FIRST resolution of a
    ///   given wire string parses it and mints a UID for whatever node it
    ///   named at the time (`resolveUID(id:nodeStr:in:)`); every later
    ///   resolution of the SAME string re-resolves via that UID rather than
    ///   the string's embedded index, returning `nil` (a clear "unknown
    ///   node" outcome) if the UID no longer resolves in this graph, never a
    ///   silent wrong-node match.
    /// - `attrStore` holds every `reconstruct.*` attribute keyed by
    ///   `GraphUID` directly, not by `BRepGraph.NodeRef`. A `GraphUID` never
    ///   encodes an index, so an attribute set before a hypothetical future
    ///   `compact()`/`deduplicate()` on a live session keeps applying to the
    ///   SAME node after one, without any re-keying step: there is no
    ///   pre-compaction/post-compaction index to migrate between. `store(
    ///   id:graph:)` converts an imported `GraphSnapshot`'s NodeRef-keyed
    ///   attributes into this UID-keyed form once, at session start;
    ///   `makeSnapshot(id:)` converts back to NodeRef-keyed (the only wire
    ///   format `GraphSnapshot`/`BRepGraph.snapshot()` understands) by
    ///   resolving each UID to its CURRENT node right before serializing.
    ///
    /// Verified (regression test `resolveSurvivesCompaction`) against a real
    /// `compact()` renumbering: a node's full attribute set, including
    /// attributes set both before and after the renumbering, is intact and
    /// attached to the SAME logical node afterwards, not split across the
    /// old and new indices or misattributed to whatever else now sits at
    /// the wire string's literal index. `AnalysisTools.graph_compact` /
    /// `graph_dedup` remain one-shot and file-path-only today and never
    /// touch a live session graph, so this is a guard-rail against a future
    /// `reconstruct_*` tool wiring one in, not a path exercised in
    /// production yet.
    private var sessions: [String: BRepGraph] = [:]
    private var nodeUIDs: [String: [String: BRepGraph.GraphUID]] = [:]
    private var attrStore: [String: [BRepGraph.GraphUID: [String: BRepGraph.AttrValue]]] = [:]

    public init() {}

    // MARK: lifecycle

    public func hasSession(id: String) -> Bool { sessions[id] != nil }

    /// Register (or replace) the graph backing a session. A replacement
    /// graph is always a NEW `BRepGraph` instance, so any UIDs cached
    /// under `id` from the old instance are foreign to it and must be
    /// dropped rather than left to resolve `nil` forever. Any attributes
    /// already on `graph` (from `BRepGraph(snapshot:)` rebuilding an
    /// imported session) are NodeRef-keyed; convert them into this
    /// registry's UID-keyed `attrStore` once, here, rather than reading
    /// `graph.attributes` directly on every subsequent call.
    public func store(id: String, graph: BRepGraph) {
        sessions[id] = graph
        nodeUIDs[id] = nil
        var byUID: [BRepGraph.GraphUID: [String: BRepGraph.AttrValue]] = [:]
        for (ref, attrs) in graph.attributes.storage {
            if let uid = graph.uid(ofNodeKind: Int(ref.kind.rawValue), index: ref.index) {
                byUID[uid] = attrs
            }
        }
        attrStore[id] = byUID
    }

    public func sessionIds() -> [String] { sessions.keys.sorted() }

    public func clear() {
        sessions.removeAll()
        nodeUIDs.removeAll()
        attrStore.removeAll()
    }

    /// Resolve `nodeStr` to the `GraphUID` it currently names in `id`'s
    /// session graph. First resolution of a given string: parse the wire
    /// format and mint a UID for future calls. Later resolutions of the
    /// SAME string: re-validate the cached UID against the graph rather
    /// than re-parsing the string's embedded index, returning `nil` if the
    /// UID no longer resolves.
    private func resolveUID(id: String, nodeStr: String, in g: BRepGraph) -> BRepGraph.GraphUID? {
        if let uid = nodeUIDs[id]?[nodeStr] {
            return g.node(forUID: uid) != nil ? uid : nil
        }
        guard let node = Self.parse(nodeStr),
              let uid = g.uid(ofNodeKind: Int(node.kind.rawValue), index: node.index) else {
            return nil
        }
        nodeUIDs[id, default: [:]][nodeStr] = uid
        return uid
    }

    // MARK: read

    public func state(id: String) -> ReconstructGraphState? {
        guard let g = sessions[id] else { return nil }
        let s = g.stats
        let counts = ReconstructGraphState.TopologyCounts(
            solids: s.solids, shells: s.shells, faces: s.faces, wires: s.wires,
            edges: s.edges, vertices: s.vertices, compounds: s.compounds,
            totalNodes: s.totalNodes
        )

        // Resolve each attributed UID to its CURRENT node. A UID that no
        // longer resolves (its node was deleted since annotation) is
        // skipped rather than reported at a stale or reused index.
        var resolved: [(ref: BRepGraph.NodeRef, attrs: [String: BRepGraph.AttrValue])] = []
        for (uid, attrs) in attrStore[id] ?? [:] {
            guard let r = g.node(forUID: uid), let kind = BRepGraph.NodeKind(rawValue: Int32(r.kind)) else { continue }
            resolved.append((BRepGraph.NodeRef(kind: kind, index: r.index), attrs))
        }
        resolved.sort { Self.nodeOrder($0.ref, $1.ref) }

        var nodes: [ReconstructGraphState.NodeAttrs] = []
        var clusters: [String: (members: [String], confirmed: Bool)] = [:]
        for (ref, attrs) in resolved {
            nodes.append(.init(node: Self.format(ref), attributes: Self.anyCodableMap(attrs)))

            if let cid = attrs[ReconstructKeys.instanceCluster]?.stringValue {
                let confirmed = attrs[ReconstructKeys.instanceConfirmed]?.boolValue ?? false
                var entry = clusters[cid] ?? (members: [], confirmed: false)
                entry.members.append(Self.format(ref))
                entry.confirmed = entry.confirmed || confirmed
                clusters[cid] = entry
            }
        }
        let clusterList = clusters.keys.sorted().map { cid in
            ReconstructGraphState.InstanceCluster(
                clusterId: cid, members: clusters[cid]!.members, confirmed: clusters[cid]!.confirmed
            )
        }
        return ReconstructGraphState(
            sessionId: id, topology: counts,
            annotatedNodeCount: nodes.count,
            nodes: nodes, instanceClusters: clusterList
        )
    }

    // MARK: write

    public func setDecision(
        id: String, nodeStr: String, decidedBy: String?, accepted: Bool?
    ) -> ReconstructWriteOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        guard let uid = resolveUID(id: id, nodeStr: nodeStr, in: g) else { return .badNode(nodeStr) }
        if let d = decidedBy { attrStore[id, default: [:]][uid, default: [:]][ReconstructKeys.decidedBy] = .string(d) }
        if let a = accepted { attrStore[id, default: [:]][uid, default: [:]][ReconstructKeys.accepted] = .bool(a) }
        return .ok(node: nodeStr, attributes: Self.anyCodableMap(attrStore[id]?[uid] ?? [:]))
    }

    public func forceFit(
        id: String, nodeStr: String, surfaceType: String
    ) -> ReconstructWriteOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        guard let uid = resolveUID(id: id, nodeStr: nodeStr, in: g) else { return .badNode(nodeStr) }
        attrStore[id, default: [:]][uid, default: [:]][ReconstructKeys.forcedSurfaceType] = .string(surfaceType)
        return .ok(node: nodeStr, attributes: Self.anyCodableMap(attrStore[id]?[uid] ?? [:]))
    }

    public func confirmInstances(
        id: String, clusterId: String, nodeStrs: [String], confirmed: Bool
    ) -> ReconstructClusterOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        let parsed = nodeStrs.map { (raw: $0, uid: resolveUID(id: id, nodeStr: $0, in: g)) }
        let bad = parsed.filter { $0.uid == nil }.map { $0.raw }
        guard bad.isEmpty else { return .badNodes(bad) }
        for entry in parsed {
            guard let uid = entry.uid else { continue }
            attrStore[id, default: [:]][uid, default: [:]][ReconstructKeys.instanceCluster] = .string(clusterId)
            attrStore[id, default: [:]][uid, default: [:]][ReconstructKeys.instanceConfirmed] = .bool(confirmed)
        }
        return .ok(clusterId: clusterId, members: nodeStrs, confirmed: confirmed)
    }

    // MARK: persistence

    /// `BRepGraph.snapshot()` is the only public source of a session's
    /// `brep` (`sourceBREP` is internal to OCCTSwift), so it still runs
    /// here for that half; its own `.attributes` field is discarded and
    /// rebuilt from `attrStore`, resolving each UID to its CURRENT node
    /// right before serializing (the wire format `GraphSnapshot` round-trips
    /// is NodeRef-keyed, not UID-keyed: a UID is only durable within the
    /// `BRepGraph` instance that minted it, per `BRepGraph.GraphUID`'s own
    /// documented instance-scoping, so it can't be the persisted form).
    public func makeSnapshot(id: String) throws -> GraphSnapshot {
        guard let g = sessions[id] else { throw ReconstructError.noSession(id) }
        let base = try g.snapshot()
        return GraphSnapshot(
            brep: base.brep,
            attributes: Self.nodeAttributeStore(from: attrStore[id] ?? [:], graph: g),
            formatVersion: base.formatVersion
        )
    }

    // MARK: helpers

    private static func anyCodableMap(_ attrs: [String: BRepGraph.AttrValue]) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in attrs { out[k] = anyCodable(v) }
        return out
    }

    private static func nodeAttributeStore(
        from byUID: [BRepGraph.GraphUID: [String: BRepGraph.AttrValue]], graph: BRepGraph
    ) -> NodeAttributeStore {
        var store = NodeAttributeStore()
        for (uid, attrs) in byUID {
            guard let r = graph.node(forUID: uid), let kind = BRepGraph.NodeKind(rawValue: Int32(r.kind)) else { continue }
            let ref = BRepGraph.NodeRef(kind: kind, index: r.index)
            for (k, v) in attrs { store.set(k, v, for: ref) }
        }
        return store
    }

    private static func nodeOrder(_ a: BRepGraph.NodeRef, _ b: BRepGraph.NodeRef) -> Bool {
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        return a.index < b.index
    }

    static func anyCodable(_ v: BRepGraph.AttrValue) -> AnyCodable {
        switch v {
        case .bool(let b):    return .bool(b)
        case .int(let i):     return .number(Double(i))
        case .double(let d):  return .number(d)
        case .string(let s):  return .string(s)
        case .ints(let a):    return .array(a.map { .number(Double($0)) })
        case .doubles(let a): return .array(a.map { .number($0) })
        }
    }

    // Self-describing "<kind>:<index>" node addressing (parseable both ways).
    static func kindName(_ k: BRepGraph.NodeKind) -> String {
        switch k {
        case .solid:      return "solid"
        case .shell:      return "shell"
        case .face:       return "face"
        case .wire:       return "wire"
        case .edge:       return "edge"
        case .vertex:     return "vertex"
        case .compound:   return "compound"
        case .compSolid:  return "compsolid"
        case .coedge:     return "coedge"
        case .product:    return "product"
        case .occurrence: return "occurrence"
        }
    }

    static func kind(from name: String) -> BRepGraph.NodeKind? {
        switch name.lowercased() {
        case "solid":      return .solid
        case "shell":      return .shell
        case "face":       return .face
        case "wire":       return .wire
        case "edge":       return .edge
        case "vertex":     return .vertex
        case "compound":   return .compound
        case "compsolid":  return .compSolid
        case "coedge":     return .coedge
        case "product":    return .product
        case "occurrence": return .occurrence
        default:           return nil
        }
    }

    static func format(_ ref: BRepGraph.NodeRef) -> String {
        "\(kindName(ref.kind)):\(ref.index)"
    }

    static func parse(_ s: String) -> BRepGraph.NodeRef? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let k = kind(from: String(parts[0])),
              let idx = Int(parts[1]) else { return nil }
        return BRepGraph.NodeRef(kind: k, index: idx)
    }
}
