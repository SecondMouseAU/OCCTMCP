// Every tool that changes the scene must rewrite manifest.json: OCCTSwiftViewport's
// ScriptWatcher watches that file, so a mutation that does not emit leaves the viewport
// stale. Other suites reach the manifest only indirectly, through a later tool that happens
// to need it; these read the file itself.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

@Suite("Scene-mutating tools emit manifest.json", .serialized)
struct ManifestEmissionTests {

    struct Scene {
        let dir: URL
        var manifestPath: String { dir.appendingPathComponent("manifest.json").path }

        /// Backdate the file so any rewrite is observable as a later mtime.
        func backdate() throws {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: manifestPath)
        }

        func mtime() throws -> Date {
            let attrs = try FileManager.default.attributesOfItem(atPath: manifestPath)
            return try #require(attrs[.modificationDate] as? Date)
        }

        func bodyIds() throws -> [String] {
            try #require(try ManifestStore(path: manifestPath).read()).bodies.compactMap(\.id)
        }
    }

    /// A scene holding two overlapping 10 mm boxes, "a" and "b".
    func makeScene() throws -> Scene {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-emit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let b = try #require(a.translated(by: SIMD3(5, 0, 0)))
        try Exporter.writeBREP(shape: a, to: dir.appendingPathComponent("a.brep"))
        try Exporter.writeBREP(shape: b, to: dir.appendingPathComponent("b.brep"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "emission",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "b", file: "b.brep", color: [0, 1, 0, 1]),
                ]))
        return Scene(dir: dir)
    }

    func connect(_ scene: Scene) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: scene.dir)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    /// Call `tool`, require success, and return the scene's manifest mtime afterwards.
    func call(
        _ client: Client, _ scene: Scene, _ tool: String, _ arguments: [String: Value]
    ) async throws -> Date {
        try scene.backdate()
        let before = try scene.mtime()
        let (content, isError) = try await client.callTool(name: tool, arguments: arguments)
        var text = ""
        if case .text(let t, _, _) = content.first { text = t }
        // Stop here on a tool error: the mtime and body-list checks below would only add
        // noise about a manifest the tool never reached.
        try #require(isError != true, "\(tool) errored: \(text)")
        let after = try scene.mtime()
        #expect(after > before, "\(tool) did not rewrite manifest.json")
        return after
    }

    @Test("transform_body rewrites the manifest")
    func transformBody() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        _ = try await call(
            client, scene, "transform_body",
            ["bodyId": .string("a"), "translate": .array([.double(20), .double(0), .double(0)])])
    }

    @Test("boolean_op rewrites the manifest and lists the output body")
    func booleanOp() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        _ = try await call(
            client, scene, "boolean_op",
            [
                "op": .string("union"), "aBodyId": .string("a"), "bBodyId": .string("b"),
                "outputBodyId": .string("merged"),
            ])
        #expect(try scene.bodyIds().contains("merged"))
    }

    @Test("mirror_or_pattern rewrites the manifest and lists the new body")
    func mirror() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        let before = try scene.bodyIds()
        _ = try await call(
            client, scene, "mirror_or_pattern",
            [
                "bodyId": .string("a"), "kind": .string("mirror"),
                "params": .object([
                    "planeOrigin": .array([.double(30), .double(0), .double(0)]),
                    "planeNormal": .array([.double(1), .double(0), .double(0)]),
                ]),
            ])
        #expect(try scene.bodyIds().count == before.count + 1)
    }

    @Test("heal_shape rewrites the manifest")
    func heal() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        _ = try await call(client, scene, "heal_shape", ["bodyId": .string("a")])
    }

    @Test("apply_feature rewrites the manifest")
    func feature() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        _ = try await call(
            client, scene, "apply_feature",
            [
                "bodyId": .string("a"),
                "feature": .object([
                    "id": .string("h"), "kind": .string("hole"),
                    "axis_point": .array([.double(0), .double(0), .double(0)]),
                    "axis_direction": .array([.double(0), .double(0), .double(1)]),
                    "diameter": .double(2),
                ]),
            ])
    }

    @Test("remove_body rewrites the manifest and drops the body")
    func remove() async throws {
        let scene = try makeScene()
        defer { try? FileManager.default.removeItem(at: scene.dir) }
        let client = try await connect(scene)
        _ = try await call(client, scene, "remove_body", ["bodyId": .string("b")])
        #expect(try scene.bodyIds() == ["a"])
    }
}
