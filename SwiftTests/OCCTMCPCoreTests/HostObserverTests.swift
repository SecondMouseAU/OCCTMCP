// Host observers (#248, #253): manifest writes carry the tool name, and every call reports its
// start and finish. The write observer is applied inside `ManifestStore`, so a tool cannot skip it.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@Suite("Host observers", .serialized)
struct HostObserverTests {

    func makeScene() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-observer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let b = try #require(a.translated(by: SIMD3(5, 0, 0)))
        try Exporter.writeBREP(shape: a, to: dir.appendingPathComponent("a.brep"))
        try Exporter.writeBREP(shape: b, to: dir.appendingPathComponent("b.brep"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "observer",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "b", file: "b.brep", color: [0, 1, 0, 1]),
                ]))
        return dir
    }

    func connect(
        _ dir: URL, write: ManifestWriteObserver? = nil, call: ToolCallObserver? = nil
    ) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(
            outputDirectory: dir, manifestWriteObserver: write, toolCallObserver: call)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    @Test("each mutating tool reports its own name once per manifest write")
    func writeObserverNamesTool() async throws {
        let calls: [(String, [String: Value])] = [
            ("transform_body", ["bodyId": "a", "translate": [20, 0, 0]]),
            ("rename_body", ["bodyId": "a", "newBodyId": "a2"]),
            ("set_appearance", ["bodyId": "b", "opacity": 0.5]),
            ("heal_shape", ["bodyId": "b"]),
            (
                "boolean_op",
                [
                    "op": "union", "aBodyId": "a2", "bBodyId": "b", "outputBodyId": "m",
                ]
            ),
            ("remove_body", ["bodyId": "m"]),
            ("clear_scene", [:]),
        ]
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Recorder()
        let client = try await connect(dir) { _, tool in seen.add(tool ?? "<none>") }
        for (name, arguments) in calls {
            let before = seen.all.count
            let (content, isError) = try await client.callTool(name: name, arguments: arguments)
            var text = ""
            if case .text(let t, _, _) = content.first { text = t }
            try #require(isError != true, "\(name) errored: \(text)")
            #expect(Array(seen.all.dropFirst(before)) == [name], "\(name)")
        }
    }

    @Test("a write outside any tool call reports no tool, and no observer changes nothing")
    func noToolOutsideCall() throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
        let seen = Recorder()
        try OCCTMCPContext.$manifestWriteObserver.withValue({ _, tool in
            seen.add(tool ?? "<none>")
        }) {
            try store.update { $0! }
        }
        #expect(seen.all == ["<none>"])
        try store.update { $0! }
    }

    @Test("a throwing write observer aborts the write")
    func throwingObserverAborts() async throws {
        struct Veto: Error {}
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir) { _, _ in throw Veto() }
        let (_, isError) = try await client.callTool(
            name: "remove_body", arguments: ["bodyId": "b"])
        #expect(isError == true)
        let ids = try #require(
            try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).read()
        ).bodies.compactMap(\.id)
        #expect(ids == ["a", "b"])
    }

    @Test("the call observer sees start then finish with the outcome, even for an error")
    func callObserverOutcome() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = Recorder()
        let client = try await connect(dir, call: { event in
            switch event.phase {
            case .started: seen.add("start \(event.name) \(event.arguments["bodyId"]?.stringValue ?? "")")
            case .finished(let isError): seen.add("end \(event.name) \(isError)")
            }
        })
        _ = try await client.callTool(name: "ping", arguments: [:])
        _ = try await client.callTool(name: "remove_body", arguments: ["bodyId": "nope"])
        for _ in 0..<100 where seen.all.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(
            seen.all == [
                "start ping ", "end ping false", "start remove_body nope", "end remove_body true",
            ])
    }

    @Test("a slow call observer does not delay the tool result")
    func slowObserverOffCriticalPath() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, call: { _ in Thread.sleep(forTimeInterval: 1.5) })
        let start = Date()
        _ = try await client.callTool(name: "ping", arguments: [:])
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}
