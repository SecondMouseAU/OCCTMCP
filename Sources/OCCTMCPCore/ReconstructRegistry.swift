// ReconstructRegistry — actor-backed store of `sessionId → TopologyGraph`
// for the `reconstruct_*` tool group (OCCTMCP #33).
//
// A "reconstruction session" is a live `TopologyGraph` plus its per-node
// attribute overlay (OCCTSwift 1.2.0's `NodeAttributeStore`). The
// reconstruction *engine* — surface fitting, congruence detection, the
// math behind residuals/confidence — lives downstream in OCCTReconstruct.
// OCCTMCP only reads and writes the attributed graph so an LLM-in-the-loop
// can annotate decisions (`decidedBy`, accept/reject, forced surface type,
// instance clusters) and have them persist via `GraphSnapshot`.
//
// All graph access is funnelled through the actor so the (`@unchecked
// Sendable`) `TopologyGraph` reference type is never mutated concurrently:
// the tool layer builds a graph (from a body's BREP or an imported
// snapshot), hands it to `store(id:graph:)`, and never touches it again —
// every subsequent read/write goes through an actor-isolated method.

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

    private var sessions: [String: TopologyGraph] = [:]

    public init() {}

    // MARK: lifecycle

    public func hasSession(id: String) -> Bool { sessions[id] != nil }

    /// Register (or replace) the graph backing a session.
    public func store(id: String, graph: TopologyGraph) { sessions[id] = graph }

    public func sessionIds() -> [String] { sessions.keys.sorted() }

    public func clear() { sessions.removeAll() }

    // MARK: read

    public func state(id: String) -> ReconstructGraphState? {
        guard let g = sessions[id] else { return nil }
        let s = g.stats
        let counts = ReconstructGraphState.TopologyCounts(
            solids: s.solids, shells: s.shells, faces: s.faces, wires: s.wires,
            edges: s.edges, vertices: s.vertices, compounds: s.compounds,
            totalNodes: s.totalNodes
        )
        let storage = g.attributes.storage
        let orderedRefs = storage.keys.sorted(by: Self.nodeOrder)

        var nodes: [ReconstructGraphState.NodeAttrs] = []
        var clusters: [String: (members: [String], confirmed: Bool)] = [:]
        for ref in orderedRefs {
            guard let attrs = storage[ref] else { continue }
            var out: [String: AnyCodable] = [:]
            for (k, v) in attrs { out[k] = Self.anyCodable(v) }
            nodes.append(.init(node: Self.format(ref), attributes: out))

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
            annotatedNodeCount: g.attributes.annotatedNodeCount,
            nodes: nodes, instanceClusters: clusterList
        )
    }

    // MARK: write

    public func setDecision(
        id: String, nodeStr: String, decidedBy: String?, accepted: Bool?
    ) -> ReconstructWriteOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        guard let node = Self.parse(nodeStr) else { return .badNode(nodeStr) }
        if let d = decidedBy { g.setAttribute(ReconstructKeys.decidedBy, .string(d), for: node) }
        if let a = accepted { g.setAttribute(ReconstructKeys.accepted, .bool(a), for: node) }
        return .ok(node: nodeStr, attributes: Self.attrsOut(g, node))
    }

    public func forceFit(
        id: String, nodeStr: String, surfaceType: String
    ) -> ReconstructWriteOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        guard let node = Self.parse(nodeStr) else { return .badNode(nodeStr) }
        g.setAttribute(ReconstructKeys.forcedSurfaceType, .string(surfaceType), for: node)
        return .ok(node: nodeStr, attributes: Self.attrsOut(g, node))
    }

    public func confirmInstances(
        id: String, clusterId: String, nodeStrs: [String], confirmed: Bool
    ) -> ReconstructClusterOutcome {
        guard let g = sessions[id] else { return .noSession(id) }
        let parsed = nodeStrs.map { (raw: $0, ref: Self.parse($0)) }
        let bad = parsed.filter { $0.ref == nil }.map { $0.raw }
        guard bad.isEmpty else { return .badNodes(bad) }
        for entry in parsed {
            guard let ref = entry.ref else { continue }
            g.setAttribute(ReconstructKeys.instanceCluster, .string(clusterId), for: ref)
            g.setAttribute(ReconstructKeys.instanceConfirmed, .bool(confirmed), for: ref)
        }
        return .ok(clusterId: clusterId, members: nodeStrs, confirmed: confirmed)
    }

    // MARK: persistence

    public func makeSnapshot(id: String) throws -> GraphSnapshot {
        guard let g = sessions[id] else { throw ReconstructError.noSession(id) }
        return try g.snapshot()
    }

    // MARK: helpers

    private static func attrsOut(_ g: TopologyGraph, _ node: TopologyGraph.NodeRef) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in g.attributes.storage[node] ?? [:] { out[k] = anyCodable(v) }
        return out
    }

    private static func nodeOrder(_ a: TopologyGraph.NodeRef, _ b: TopologyGraph.NodeRef) -> Bool {
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        return a.index < b.index
    }

    static func anyCodable(_ v: TopologyGraph.AttrValue) -> AnyCodable {
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
    static func kindName(_ k: TopologyGraph.NodeKind) -> String {
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

    static func kind(from name: String) -> TopologyGraph.NodeKind? {
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

    static func format(_ ref: TopologyGraph.NodeRef) -> String {
        "\(kindName(ref.kind)):\(ref.index)"
    }

    static func parse(_ s: String) -> TopologyGraph.NodeRef? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let k = kind(from: String(parts[0])),
              let idx = Int(parts[1]) else { return nil }
        return TopologyGraph.NodeRef(kind: k, index: idx)
    }
}
