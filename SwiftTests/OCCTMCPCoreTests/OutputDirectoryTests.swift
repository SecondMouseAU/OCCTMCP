// Tests for the host-supplied output directory (#195): two servers with different
// directories in one process, registry isolation, and the nil / env / explicit precedence.

import Foundation
import MCP
import ScriptHarness
import Testing

@testable import OCCTMCPCore

@Suite("Host-supplied output directory", .serialized)
struct OutputDirectoryTests {

    func makeScene(bodyId: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-outdir-\(UUID().uuidString)")
        let manifest = ScriptManifest(
            version: 1,
            timestamp: Date(),
            description: "scene \(bodyId)",
            bodies: [BodyDescriptor(id: bodyId, file: "\(bodyId).brep", color: [1, 0, 0, 1])]
        )
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(manifest)
        return dir
    }

    func connect(outputDirectory: URL?) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: outputDirectory)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func sceneText(_ client: Client) async throws -> String {
        let (content, _) = try await client.callTool(name: "get_scene", arguments: [:])
        guard case .text(let text, _, _) = content.first else { return "" }
        return text
    }

    @Test("two servers with different directories each see only their own scene, concurrently")
    func twoServersIsolated() async throws {
        let dirA = try makeScene(bodyId: "alpha")
        let dirB = try makeScene(bodyId: "beta")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let clientA = try await connect(outputDirectory: dirA)
        let clientB = try await connect(outputDirectory: dirB)

        await withTaskGroup(of: (String, String).self) { group in
            for _ in 0..<10 {
                group.addTask { ("a", (try? await self.sceneText(clientA)) ?? "") }
                group.addTask { ("b", (try? await self.sceneText(clientB)) ?? "") }
            }
            for await (which, text) in group {
                if which == "a" {
                    #expect(text.contains("alpha") && !text.contains("beta"))
                } else {
                    #expect(text.contains("beta") && !text.contains("alpha"))
                }
            }
        }
    }

    @Test("ProvenanceStore.shared is one stable instance per directory, distinct across directories")
    func provenanceStoreIdentity() async throws {
        let dirA = try makeScene(bodyId: "alpha")
        let dirB = try makeScene(bodyId: "beta")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        // #157: a store constructed per call raced on provenance.json, because each call got
        // its own actor. The concurrency tests in ProvenanceStoreTests build one private
        // instance, so they cannot see `shared` regress to a fresh instance per access.
        let (a1, a2) = await OCCTMCPPaths.withOutputDirectory(dirA) {
            (ProvenanceStore.shared, ProvenanceStore.shared)
        }
        let b = await OCCTMCPPaths.withOutputDirectory(dirB) { ProvenanceStore.shared }
        #expect(a1 === a2, "shared must return the same instance within one directory")
        #expect(a1 !== b, "different directories must not share one store")
    }

    @Test("selection and zone registries do not leak between directories")
    func registriesIsolated() async throws {
        let dirA = try makeScene(bodyId: "alpha")
        let dirB = try makeScene(bodyId: "beta")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let snapshot = AnchorSnapshot(center: [0, 0, 0], area: 1)
        await OCCTMCPPaths.withOutputDirectory(dirA) {
            await SelectionRegistry.shared.record(
                anchor: .face(bodyId: "alpha", index: 0), snapshot: snapshot)
        }
        let inA = await OCCTMCPPaths.withOutputDirectory(dirA) {
            await SelectionRegistry.shared.count()
        }
        let inB = await OCCTMCPPaths.withOutputDirectory(dirB) {
            await SelectionRegistry.shared.count()
        }
        #expect(inA == 1)
        #expect(inB == 0)

        // The same override resolves to the same instance every time.
        let aIdentity = await OCCTMCPPaths.withOutputDirectory(dirA) { SelectionRegistry.shared }
        let aAgain = await OCCTMCPPaths.withOutputDirectory(dirA) { SelectionRegistry.shared }
        let bIdentity = await OCCTMCPPaths.withOutputDirectory(dirB) { SelectionRegistry.shared }
        #expect(aIdentity === aAgain)
        #expect(aIdentity !== bIdentity)

        let zonesA = await OCCTMCPPaths.withOutputDirectory(dirA) { ZoneRegistry.shared }
        let zonesB = await OCCTMCPPaths.withOutputDirectory(dirB) { ZoneRegistry.shared }
        #expect(zonesA !== zonesB)
        let scenesA = await OCCTMCPPaths.withOutputDirectory(dirA) { SceneHistory.shared }
        let scenesB = await OCCTMCPPaths.withOutputDirectory(dirB) { SceneHistory.shared }
        #expect(scenesA !== scenesB)
    }

    @Test("nil keeps environment resolution and the legacy shared registries")
    func nilFallsBack() async throws {
        let env = ["OCCTMCP_OUTPUT_DIR": "/tmp/from-env"]
        #expect(OCCTMCPPaths.outputDir(env: env) == "/tmp/from-env")
        let inside = await OCCTMCPPaths.withOutputDirectory(nil) {
            OCCTMCPPaths.outputDir(env: env)
        }
        #expect(inside == "/tmp/from-env")
        let legacy = SelectionRegistry.shared
        let viaNil = await OCCTMCPPaths.withOutputDirectory(nil) { SelectionRegistry.shared }
        #expect(legacy === viaNil)
    }

    @Test("an explicit directory beats the environment variable")
    func explicitBeatsEnv() async throws {
        let dir = URL(fileURLWithPath: "/tmp/occtmcp-explicit")
        let env = ["OCCTMCP_OUTPUT_DIR": "/tmp/from-env"]
        let resolved = await OCCTMCPPaths.withOutputDirectory(dir) {
            OCCTMCPPaths.outputDir(env: env)
        }
        #expect(resolved.hasSuffix("/tmp/occtmcp-explicit"))
        let manifest = await OCCTMCPPaths.withOutputDirectory(dir) {
            OCCTMCPPaths.manifestPath(env: env)
        }
        #expect(manifest.hasSuffix("/occtmcp-explicit/manifest.json"))
    }

    @Test("the override reaches an actor hop and a child task")
    func propagatesThroughActorsAndChildTasks() async throws {
        let dir = try makeScene(bodyId: "gamma")
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = dir.standardizedFileURL.path
        let seen = await OCCTMCPPaths.withOutputDirectory(dir) {
            async let viaChild = Task { OCCTMCPPaths.outputDirectoryOverride }.value
            let viaActor = await SceneHistory.shared.probeOverride()
            return (await viaChild, viaActor)
        }
        #expect(seen.0 == expected)
        #expect(seen.1 == expected)
    }
}

extension SceneHistory {
    fileprivate func probeOverride() -> String? { OCCTMCPPaths.outputDirectoryOverride }
}
