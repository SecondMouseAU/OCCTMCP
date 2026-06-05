// ReconstructTools — the `reconstruct_*` MCP tool group (OCCTMCP #33).
//
// Read and write an attributed reconstruction graph from an LLM. Backed by
// OCCTSwift 1.2.0's `NodeAttributeStore` + Codable `GraphSnapshot`, held in
// the actor-backed `ReconstructRegistry` keyed by sessionId.
//
//   reconstruct_get_graph        read   export the attributed graph as JSON
//   reconstruct_set_decision     write  annotate decidedBy + accept/reject a node
//   reconstruct_force_fit        write  override a node's fitted surface type
//   reconstruct_confirm_instances write confirm/reject a congruence cluster
//   reconstruct_export_session   read   round-trip the graph snapshot to a file
//   reconstruct_import_session   write  reload a snapshot from a file
//
// Scope boundary: OCCTMCP is the read/write layer only. The reconstruction
// engine (surface fitting, congruence detection, the math behind residuals
// and confidence) lives in OCCTReconstruct. `force_fit` records the
// override for the engine to honour on its next pass — it does not re-fit
// here. Nodes are addressed by the self-describing string `<kind>:<index>`
// (e.g. `face:3`), parseable in both directions.

import Foundation
import OCCTSwift
import ScriptHarness

public enum ReconstructTools {

    // ── reconstruct_get_graph ───────────────────────────────────────────
    // Resolves the session: an existing one by `sessionId`, or a fresh one
    // built from a body's BREP when `bodyId` is supplied (sessionId defaults
    // to the bodyId). Returns topology counts + every annotated node + any
    // instance clusters.

    public static func getGraph(
        sessionId: String? = nil,
        bodyId: String? = nil,
        store: ManifestStore = ManifestStore(),
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        guard let sid = sessionId ?? bodyId else {
            return .init("reconstruct_get_graph requires `sessionId` or `bodyId`.", isError: true)
        }
        if await registry.hasSession(id: sid) == false {
            guard let bodyId else {
                return .init(
                    "No session '\(sid)'. Provide `bodyId` to start a new reconstruction session from a scene body.",
                    isError: true
                )
            }
            do {
                let loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
                guard let graph = TopologyGraph(shape: loaded.shape) else {
                    return .init("Failed to build a topology graph for body '\(bodyId)'.", isError: true)
                }
                await registry.store(id: sid, graph: graph)
            } catch {
                return .init("\(error)", isError: true)
            }
        }
        guard let state = await registry.state(id: sid) else {
            return .init("No session '\(sid)'.", isError: true)
        }
        return IntrospectionTools.encode(state)
    }

    // ── reconstruct_set_decision ────────────────────────────────────────

    public static func setDecision(
        sessionId: String,
        node: String,
        decidedBy: String? = nil,
        accepted: Bool? = nil,
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        if decidedBy == nil && accepted == nil {
            return .init(
                "reconstruct_set_decision requires at least one of `decidedBy` or `accepted`.",
                isError: true
            )
        }
        if let d = decidedBy, !["geometric", "ml", "human"].contains(d) {
            return .init("`decidedBy` must be one of: geometric, ml, human.", isError: true)
        }
        let outcome = await registry.setDecision(
            id: sessionId, nodeStr: node, decidedBy: decidedBy, accepted: accepted
        )
        return encodeWrite(outcome, sessionId: sessionId, tool: "reconstruct_set_decision")
    }

    // ── reconstruct_force_fit ───────────────────────────────────────────
    // Records the forced surface type as an attribute. The actual re-fit is
    // performed by the OCCTReconstruct engine on its next pass — out of
    // scope for this read/write layer.

    public static func forceFit(
        sessionId: String,
        node: String,
        surfaceType: String,
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        if surfaceType.trimmingCharacters(in: .whitespaces).isEmpty {
            return .init("reconstruct_force_fit requires a non-empty `surfaceType`.", isError: true)
        }
        let outcome = await registry.forceFit(
            id: sessionId, nodeStr: node, surfaceType: surfaceType
        )
        return encodeWrite(outcome, sessionId: sessionId, tool: "reconstruct_force_fit")
    }

    // ── reconstruct_confirm_instances ───────────────────────────────────

    public static func confirmInstances(
        sessionId: String,
        clusterId: String,
        nodes: [String],
        confirmed: Bool = true,
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        if nodes.isEmpty {
            return .init("reconstruct_confirm_instances requires a non-empty `nodes` array.", isError: true)
        }
        let outcome = await registry.confirmInstances(
            id: sessionId, clusterId: clusterId, nodeStrs: nodes, confirmed: confirmed
        )
        switch outcome {
        case .noSession(let id):
            return .init(ReconstructError.noSession(id).description, isError: true)
        case .badNodes(let ns):
            return .init(
                "reconstruct_confirm_instances: could not parse nodes: \(ns.joined(separator: ", ")). Use `<kind>:<index>`, e.g. `face:3`.",
                isError: true
            )
        case .ok(let cid, let members, let conf):
            struct Result: Encodable {
                let sessionId: String
                let clusterId: String
                let confirmed: Bool
                let members: [String]
            }
            return IntrospectionTools.encode(
                Result(sessionId: sessionId, clusterId: cid, confirmed: conf, members: members)
            )
        }
    }

    // ── reconstruct_export_session ──────────────────────────────────────
    // Byte-stable (canonicalEncoder) snapshot to disk. Default path is
    // <output_dir>/reconstruct/<sessionId>.session.json.

    public static func exportSession(
        sessionId: String,
        path: String? = nil,
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        let snapshot: GraphSnapshot
        do {
            snapshot = try await registry.makeSnapshot(id: sessionId)
        } catch let e as ReconstructError {
            return .init(e.description, isError: true)
        } catch {
            return .init("reconstruct_export_session failed: \(error)", isError: true)
        }
        let outPath = path ?? "\(OCCTMCPPaths.outputDir())/reconstruct/\(sessionId).session.json"
        do {
            let data = try GraphSnapshot.canonicalEncoder().encode(snapshot)
            let url = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return .init("reconstruct_export_session: write failed: \(error)", isError: true)
        }
        struct Result: Encodable {
            let sessionId: String
            let path: String
            let annotatedNodeCount: Int
            let formatVersion: Int
        }
        return IntrospectionTools.encode(Result(
            sessionId: sessionId,
            path: outPath,
            annotatedNodeCount: snapshot.attributes.annotatedNodeCount,
            formatVersion: snapshot.formatVersion
        ))
    }

    // ── reconstruct_import_session ──────────────────────────────────────
    // Reload a snapshot file into a session and return its state. sessionId
    // defaults to the file's stem (sans .session.json / .json).

    public static func importSession(
        path: String,
        sessionId: String? = nil,
        registry: ReconstructRegistry = .shared
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: path) else {
            return .init("reconstruct_import_session: file not found: \(path)", isError: true)
        }
        let snapshot: GraphSnapshot
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            snapshot = try JSONDecoder().decode(GraphSnapshot.self, from: data)
        } catch {
            return .init("reconstruct_import_session: decode failed: \(error)", isError: true)
        }
        let graph: TopologyGraph
        do {
            graph = try TopologyGraph(snapshot: snapshot)
        } catch {
            return .init("reconstruct_import_session: rebuild failed: \(error)", isError: true)
        }
        let sid = sessionId ?? (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".session.json", with: "")
            .replacingOccurrences(of: ".json", with: "")
        await registry.store(id: sid, graph: graph)
        guard let state = await registry.state(id: sid) else {
            return .init("reconstruct_import_session: session unavailable after import.", isError: true)
        }
        return IntrospectionTools.encode(state)
    }

    // ── shared single-node write encoder ────────────────────────────────

    private static func encodeWrite(
        _ outcome: ReconstructWriteOutcome, sessionId: String, tool: String
    ) -> ToolText {
        switch outcome {
        case .noSession(let id):
            return .init(ReconstructError.noSession(id).description, isError: true)
        case .badNode(let n):
            return .init(
                "\(tool): could not parse node '\(n)'. Use `<kind>:<index>`, e.g. `face:3`.",
                isError: true
            )
        case .ok(let node, let attributes):
            struct Result: Encodable {
                let sessionId: String
                let node: String
                let attributes: [String: AnyCodable]
            }
            return IntrospectionTools.encode(
                Result(sessionId: sessionId, node: node, attributes: attributes)
            )
        }
    }
}
