// Unit tests for the reconstruct_* tool group (OCCTMCP #33): per-node
// attribute writes over OCCTSwift 1.2.0's NodeAttributeStore, and the
// GraphSnapshot export/import round-trip that must preserve every
// annotation. Runs fully in-process — no occtkit, no manifest — by
// building a box graph directly and driving the ReconstructRegistry.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

private extension AnyCodable {
    /// Test-side unwrap for the string payload (the get_graph attributes map
    /// carries reconstruct.* values as AnyCodable).
    var asString: String? { if case let .string(s) = self { return s } else { return nil } }
}

@Suite("reconstruct_* graph read/write", .serialized)
struct ReconstructToolsTests {

    /// Fresh registry + a box-backed graph stored under `id`.
    private func makeSession(id: String) async throws -> ReconstructRegistry {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let graph = try #require(TopologyGraph(shape: box))
        let registry = ReconstructRegistry()
        await registry.store(id: id, graph: graph)
        return registry
    }

    @Test("node addressing round-trips through parse/format")
    func nodeAddressing() {
        for kindName in ["face", "edge", "vertex", "solid", "shell", "wire", "compound"] {
            let s = "\(kindName):7"
            let ref = ReconstructRegistry.parse(s)
            #expect(ref != nil)
            #expect(ReconstructRegistry.format(ref!) == s)
        }
        #expect(ReconstructRegistry.parse("bogus:1") == nil)
        #expect(ReconstructRegistry.parse("face") == nil)
        #expect(ReconstructRegistry.parse("face:notanint") == nil)
    }

    @Test("set_decision writes decidedBy + accepted onto a node")
    func setDecisionWrites() async throws {
        let registry = try await makeSession(id: "s1")
        let outcome = await registry.setDecision(
            id: "s1", nodeStr: "face:0", decidedBy: "human", accepted: true
        )
        guard case let .ok(node, attrs) = outcome else {
            Issue.record("expected .ok, got \(outcome)")
            return
        }
        #expect(node == "face:0")
        #expect(attrs[ReconstructKeys.decidedBy]?.asString == "human")
        if case .bool(let b)? = attrs[ReconstructKeys.accepted] { #expect(b) } else { Issue.record("accepted not a bool") }
    }

    @Test("set_decision on unknown session reports noSession")
    func setDecisionNoSession() async {
        let registry = ReconstructRegistry()
        let outcome = await registry.setDecision(id: "ghost", nodeStr: "face:0", decidedBy: "ml", accepted: nil)
        guard case .noSession = outcome else {
            Issue.record("expected .noSession, got \(outcome)")
            return
        }
    }

    @Test("confirm_instances tags every member and surfaces as a cluster")
    func confirmInstancesClusters() async throws {
        let registry = try await makeSession(id: "s2")
        let outcome = await registry.confirmInstances(
            id: "s2", clusterId: "wheel", nodeStrs: ["face:0", "face:1", "face:2"], confirmed: true
        )
        guard case .ok = outcome else {
            Issue.record("expected .ok, got \(outcome)")
            return
        }
        let state = try #require(await registry.state(id: "s2"))
        let cluster = try #require(state.instanceClusters.first { $0.clusterId == "wheel" })
        #expect(cluster.members.count == 3)
        #expect(cluster.confirmed)
    }

    @Test("export → import round-trip preserves all annotations")
    func snapshotRoundTrip() async throws {
        let registry = try await makeSession(id: "src")
        _ = await registry.setDecision(id: "src", nodeStr: "face:0", decidedBy: "geometric", accepted: false)
        _ = await registry.forceFit(id: "src", nodeStr: "face:1", surfaceType: "cylinder")
        _ = await registry.confirmInstances(id: "src", clusterId: "c1", nodeStrs: ["face:2", "face:3"], confirmed: true)

        // Export → JSON bytes → decode → rebuild into a brand-new registry.
        let snapshot = try await registry.makeSnapshot(id: "src")
        let data = try GraphSnapshot.canonicalEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(GraphSnapshot.self, from: data)
        let rebuilt = try TopologyGraph(snapshot: decoded)
        let registry2 = ReconstructRegistry()
        await registry2.store(id: "dst", graph: rebuilt)

        let state = try #require(await registry2.state(id: "dst"))
        // Annotated nodes: face:0, face:1, face:2, face:3 → 4.
        #expect(state.annotatedNodeCount == 4)

        let face0 = try #require(state.nodes.first { $0.node == "face:0" })
        #expect(face0.attributes[ReconstructKeys.decidedBy]?.asString == "geometric")

        let face1 = try #require(state.nodes.first { $0.node == "face:1" })
        #expect(face1.attributes[ReconstructKeys.forcedSurfaceType]?.asString == "cylinder")

        let cluster = try #require(state.instanceClusters.first { $0.clusterId == "c1" })
        #expect(cluster.members.sorted() == ["face:2", "face:3"])
        #expect(cluster.confirmed)

        // Byte-stable: re-encoding the rebuilt snapshot reproduces the bytes.
        let snapshot2 = try await registry2.makeSnapshot(id: "dst")
        let data2 = try GraphSnapshot.canonicalEncoder().encode(snapshot2)
        #expect(data == data2)
    }

    @Test("getGraph builds a fresh session from a manifest body id")
    func getGraphFromBody() async throws {
        // Drive the tool layer end to end against a tempdir manifest so the
        // bodyId → BREP → graph path is covered, not just the registry.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("occtmcp-recon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let box = try #require(Shape.box(width: 5, height: 5, depth: 5))
        let brepPath = tmp.appendingPathComponent("part.brep")
        try box.writeBREP(to: brepPath)

        let manifest = ScriptManifest(
            description: "test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", format: "brep")]
        )
        let store = ManifestStore(path: tmp.appendingPathComponent("manifest.json").path)
        try store.write(manifest)

        let registry = ReconstructRegistry()
        let result = await ReconstructTools.getGraph(
            sessionId: nil, bodyId: "part", store: store, registry: registry
        )
        #expect(!result.isError)
        #expect(result.text.contains("\"faces\""))
        #expect(await registry.hasSession(id: "part"))
    }
}
