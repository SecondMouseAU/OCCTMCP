// What an `ExtraTool` can do inside one session (#261): hold state across calls, add a body to the
// scene and find it again by id through the same code the built-in tools use, report progress, and
// see a client's cancellation. The pairs here are the shape of the Drawings Toolbox's private tools
// (a stateful ledger, a solver that builds a solid), driven through a real client and server.

import Foundation
import Logging
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

/// State a handler holds between calls: the pattern an `ExtraTool` uses for a ledger or a solve.
private actor Ledger {
    private var entries: [String] = []
    private var cancelled = false

    func append(_ entry: String) { entries.append(entry) }
    var all: [String] { entries }
    func markCancelled() { cancelled = true }
    var wasCancelled: Bool { cancelled }
}

private func text(_ s: String, isError: Bool = false) -> CallTool.Result {
    .init(content: [.text(text: s, annotations: nil, _meta: nil)], isError: isError)
}

private func tool(_ name: String, properties: [String: Value] = [:]) -> Tool {
    Tool(
        name: name, description: "test tool \(name)",
        inputSchema: .object(["type": "object", "properties": .object(properties)]))
}

@Suite("ExtraTool in a session", .serialized)
struct ExtraToolSessionTests {

    func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-extra-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func connect(
        _ dir: URL, extras: [ExtraTool], write: ManifestWriteObserver? = nil,
        provider: BodyShapeProvider? = nil
    ) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(
            extraTools: extras, outputDirectory: dir, manifestWriteObserver: write,
            bodyShapeProvider: provider)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func call(
        _ client: Client, _ name: String, _ arguments: [String: Value] = [:]
    ) async throws -> (text: String, isError: Bool) {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var out = ""
        if case .text(let t, _, _) = content.first { out = t }
        return (out, isError == true)
    }

    /// The two tools of a stateful pair: `ledger_add` records, `ledger_list` reads back.
    fileprivate func ledgerTools(_ ledger: Ledger) -> [ExtraTool] {
        [
            ExtraTool(
                tool: tool("ledger_add", properties: ["entry": .object(["type": "string"])]),
                handler: { arguments in
                    await ledger.append(arguments["entry"]?.stringValue ?? "")
                    return text("recorded")
                }),
            ExtraTool(
                tool: tool("ledger_list"),
                handler: { _ in text(await ledger.all.joined(separator: ",")) }),
        ]
    }

    // ── state across calls ──────────────────────────────────────────────

    @Test("a state-setting tool and a state-reading tool agree across calls in one session")
    func statefulPair() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: ledgerTools(Ledger()))

        #expect(try await call(client, "ledger_list").text == "", "starts empty")
        for entry in ["a", "b", "c"] {
            let r = try await call(client, "ledger_add", ["entry": .string(entry)])
            #expect(r.text == "recorded" && !r.isError)
        }
        #expect(try await call(client, "ledger_list").text == "a,b,c")
        // A built-in call between two extra calls leaves the state alone.
        _ = try await call(client, "ping")
        #expect(try await call(client, "ledger_list").text == "a,b,c")
    }

    @Test("concurrent calls to a stateful tool all land")
    func concurrentCalls() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: ledgerTools(Ledger()))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { _ = try await self.call(client, "ledger_add", ["entry": "\(i)"]) }
            }
            try await group.waitForAll()
        }
        let listed = try await call(client, "ledger_list").text.split(separator: ",")
        #expect(Set(listed.map(String.init)) == Set((0..<20).map(String.init)), "got \(listed)")
    }

    @Test("two calls to one tool run at the same time, so a slow handler does not block others")
    func handlersOverlap() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let arrived = EventLog()
        // Each call waits for the other to arrive; a server that ran them one after the other
        // would time the first out before the second began.
        let meet = ExtraTool(
            tool: tool("rendezvous"),
            handler: { _ in
                arrived.add("arrived")
                for _ in 0..<300 {
                    if arrived.all.count >= 2 { return text("met") }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                return text("alone", isError: true)
            })
        let client = try await connect(dir, extras: [meet])
        async let first = call(client, "rendezvous")
        async let second = call(client, "rendezvous")
        let results = try await [first, second]
        #expect(results.map(\.text) == ["met", "met"], "\(results.map(\.text))")
    }

    @Test("a built-in answers while an extra handler is still running")
    func builtInAnswersDuringASlowHandler() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let finished = EventLog()
        let slow = ExtraTool(
            tool: tool("sleeper"),
            handler: { _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                finished.add("finished")
                return text("slept")
            })
        let client = try await connect(dir, extras: [slow])
        let pending = Task { try await self.call(client, "sleeper") }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Ordering, not a stopwatch: the sleeper has not finished when ping has answered.
        #expect(try await call(client, "ping").text == "pong")
        #expect(finished.all.isEmpty, "ping waited for the sleeping handler")
        #expect(try await pending.value.text == "slept")
    }

    // ── scene bodies ────────────────────────────────────────────────────

    /// A solver-shaped pair: `build_box` puts a solid in the scene, `body_volume` finds it again.
    func sceneTools() -> [ExtraTool] {
        [
            ExtraTool(
                tool: tool("build_box", properties: ["id": .object(["type": "string"])]),
                handler: { arguments in
                    let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
                    let id = try await SceneBodies.add(
                        shape: box, bodyId: arguments["id"]?.stringValue, idPrefix: "solved",
                        color: [0.2, 0.4, 0.8, 1])
                    return text(id)
                }),
            ExtraTool(
                tool: tool("body_volume", properties: ["bodyId": .object(["type": "string"])]),
                handler: { arguments in
                    let id = try #require(arguments["bodyId"]?.stringValue)
                    let shape = try SceneBodies.shape(ofBody: id)
                    return text("\(shape.volume ?? -1)")
                }),
        ]
    }

    @Test("a body a handler adds is in the scene directory and the manifest, and built-ins read it")
    func addedBodyReachesTheScene() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: sceneTools())

        let first = try await call(client, "build_box")
        try #require(!first.isError, "\(first.text)")
        #expect(first.text == "solved")
        #expect(
            try await call(client, "build_box").text == "solved_1", "second id is the next free")

        // On disk in the host's directory, not wherever the process default points.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(
            files == ["manifest.json", "manifest.lock", "solved.brep", "solved_1.brep"], "\(files)")
        let manifest = try #require(
            try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).read())
        #expect(manifest.bodies.compactMap(\.id) == ["solved", "solved_1"])
        #expect(manifest.bodies.first?.color == [0.2, 0.4, 0.8, 1])

        // A built-in tool reads the body the handler wrote, by the id the handler returned.
        let metrics = try await call(
            client, "compute_metrics", ["bodyId": "solved", "metrics": ["volume"]])
        try #require(!metrics.isError, "\(metrics.text)")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(metrics.text.utf8)) as? [String: Any])
        let volume = try #require(json["volume"] as? Double, "\(metrics.text)")
        #expect(abs(volume - 6000) < 1e-3, "volume \(volume)")
    }

    @Test("a handler's add is history that compare_versions diffs against")
    func addFeedsCompareVersions() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: sceneTools())
        _ = try await call(client, "build_box")
        _ = try await call(client, "build_box")

        let diff = try await call(client, "compare_versions")
        try #require(!diff.isError, "\(diff.text)")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(diff.text.utf8)) as? [String: Any])
        #expect(json["added"] as? [String] == ["solved_1"], "\(diff.text)")
    }

    @Test("a handler resolves a scene body by id, whatever its format")
    func handlerResolvesByIdAndFormat() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plate = try #require(Shape.box(width: 10, height: 10, depth: 5))
        try Exporter.writeSTEP(shape: plate, to: dir.appendingPathComponent("plate.step"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "host scene",
                bodies: [BodyDescriptor(id: "plate", file: "plate.step", format: "step")]))
        let client = try await connect(dir, extras: sceneTools())

        // A `step` body: the same format dispatch the built-in tools use (#258).
        let volume = try await call(client, "body_volume", ["bodyId": "plate"])
        try #require(!volume.isError, "\(volume.text)")
        #expect(abs((Double(volume.text) ?? 0) - 500) < 1e-3, "\(volume.text)")

        let missing = try await call(client, "body_volume", ["bodyId": "nope"])
        #expect(missing.isError)
        #expect(missing.text.contains("Body not found: nope"), "\(missing.text)")
    }

    @Test("a handler read goes through the host's body shape provider, as a built-in read does")
    func handlerReadUsesTheProvider() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let onDisk = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: onDisk, to: dir.appendingPathComponent("a.brep"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "host scene",
                bodies: [BodyDescriptor(id: "a", file: "a.brep")]))
        let hosted = try #require(Shape.box(width: 2, height: 3, depth: 4))
        let client = try await connect(
            dir, extras: sceneTools(),
            provider: { body, _ in body.id == "a" ? hosted : nil })

        let volume = try await call(client, "body_volume", ["bodyId": "a"])
        try #require(!volume.isError, "\(volume.text)")
        #expect(
            abs((Double(volume.text) ?? 0) - 24) < 1e-6, "the file's 1000 was read: \(volume.text)")
    }

    @Test("a handler's manifest write reaches the host observer under the handler's own name")
    func addIsObservedAsTheExtraTool() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seen = EventLog()
        let names = EventLog()
        let client = try await connect(dir, extras: sceneTools()) { _, tool in
            seen.add("write")
            names.add(tool ?? "<none>")
        }
        _ = try await call(client, "build_box")
        #expect(seen.all.count == 1 && names.all == ["build_box"], "\(names.all)")
    }

    @Test("adding a body whose id is taken fails the call and leaves the first body alone")
    func duplicateIdFails() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: sceneTools())

        _ = try await call(client, "build_box", ["id": "fixed"])
        let before = try Data(contentsOf: dir.appendingPathComponent("fixed.brep"))
        let again = try await call(client, "build_box", ["id": "fixed"])
        #expect(again.isError)
        #expect(again.text.contains("already exists"), "\(again.text)")
        #expect(try Data(contentsOf: dir.appendingPathComponent("fixed.brep")) == before)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasSuffix(".partial") }, "staging file left behind: \(files)")
    }

    // ── progress ────────────────────────────────────────────────────────

    func progressTool() -> ExtraTool {
        ExtraTool(
            tool: tool("slow_solve"),
            handler: { _ in
                for step in 1...3 {
                    await OCCTMCPContext.reportProgress(
                        Double(step), total: 3, message: "iteration \(step)")
                }
                return text("solved")
            })
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test("a handler reports progress to a client that sent a progress token")
    func progressReachesTheClient() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: [progressTool()])
        let received = EventLog()
        let messages = EventLog()
        await client.onNotification(ProgressNotification.self) { message in
            guard message.params.progressToken == .string("solve-1") else { return }
            received.add("\(message.params.progress)")
            messages.add(message.params.message ?? "")
        }

        let (content, isError) = try await client.callTool(
            name: "slow_solve", meta: Metadata(progressToken: .string("solve-1")))
        #expect(isError != true)
        if case .text(let t, _, _) = content.first { #expect(t == "solved") }

        #expect(await waitFor { received.all.count == 3 }, "got \(received.all)")
        #expect(received.all == ["1.0", "2.0", "3.0"])
        #expect(messages.all == ["iteration 1", "iteration 2", "iteration 3"])
    }

    @Test("with no progress token a handler's report is dropped and the call still succeeds")
    func noTokenNoProgress() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir, extras: [progressTool()])
        let received = EventLog()
        await client.onNotification(ProgressNotification.self) { message in
            received.add("\(message.params.progress)")
        }
        let r = try await call(client, "slow_solve")
        #expect(r.text == "solved" && !r.isError)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(received.all.isEmpty, "unrequested progress sent: \(received.all)")
    }

    @Test("reporting progress outside a tool call does nothing")
    func progressOutsideACall() async {
        await OCCTMCPContext.reportProgress(1, total: 2, message: "nobody is listening")
    }

    @Test("a server, and the state its handlers hold, are released once the session ends")
    func serverIsReleased() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        weak var weakServer: Server?
        weak var weakLedger: Ledger?
        do {
            let ledger = Ledger()
            weakLedger = ledger
            let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
            let server = await makeOCCTMCPServer(
                extraTools: ledgerTools(ledger), outputDirectory: dir)
            weakServer = server
            try await server.start(transport: serverTransport)
            let client = Client(name: "test", version: "1")
            _ = try await client.connect(transport: clientTransport)
            _ = try await call(client, "ledger_add", ["entry": "x"])
            // A call carrying a progress token builds the reporter, which refers back to the server.
            _ = try await client.callTool(
                name: "ledger_list", meta: Metadata(progressToken: .string("release")))
            await client.disconnect()
            await server.stop()
        }
        #expect(
            await waitFor { weakServer == nil && weakLedger == nil },
            "a server outlived its session")
    }

    // ── cancellation ────────────────────────────────────────────────────

    @Test("cancelling a request cancels the handler's task and sends no response")
    func cancellationReachesTheHandler() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = Ledger()
        let started = EventLog()
        let slow = ExtraTool(
            tool: tool("long_solve"),
            handler: { _ in
                started.add("started")
                do {
                    for _ in 0..<1000 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                } catch is CancellationError {
                    await ledger.markCancelled()
                    throw CancellationError()
                }
                return text("finished")
            })
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let recording = RecordingTransport(wrapping: serverTransport)
        let server = await makeOCCTMCPServer(extraTools: [slow], outputDirectory: dir)
        try await server.start(transport: recording)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let pending = try await client.send(CallTool.request(.init(name: "long_solve")))
        #expect(await waitFor { started.all.count == 1 }, "handler never started")
        try await client.cancelRequest(pending.requestID, reason: "test")

        var sawCancelled = false
        for _ in 0..<200 {
            if await ledger.wasCancelled {
                sawCancelled = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sawCancelled, "the handler ran on to its end")

        // A request the client cancelled gets no response, so nothing the server sent after the
        // initialize reply mentions the tool's result or an error for it.
        try await Task.sleep(nanoseconds: 300_000_000)
        let sent = await recording.sentText
        #expect(
            sent.contains { $0.contains("\"serverInfo\"") },
            "the recording transport captured nothing, so the checks below prove nothing")
        #expect(
            !sent.contains { $0.contains("\"result\"") && $0.contains("\"content\"") },
            "the server answered a cancelled request: \(sent)")
        #expect(
            !sent.contains { $0.contains("long_solve failed") },
            "a cancelled handler was reported as a failure: \(sent)")
    }
}

/// Wraps a transport and keeps every message the server sends through it.
private actor RecordingTransport: Transport {
    nonisolated let logger: Logger
    private nonisolated let inner: InMemoryTransport
    private var sent: [Data] = []

    init(wrapping inner: InMemoryTransport) {
        self.inner = inner
        self.logger = inner.logger
    }

    var sentText: [String] { sent.map { String(decoding: $0, as: UTF8.self) } }

    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }

    func send(_ data: Data) async throws {
        sent.append(data)
        try await inner.send(data)
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let inner = self.inner
        return AsyncThrowingStream { continuation in
            let forwarding = Task {
                do {
                    for try await data in await inner.receive() { continuation.yield(data) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in forwarding.cancel() }
        }
    }
}
