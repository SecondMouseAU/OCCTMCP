// SceneBodies (#261): adding a shape to the scene and resolving a body by id, the code
// `read_brep`, `import_file` and an `ExtraTool` handler share.

import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

/// Holds tasks until `open()`, then releases them together.
private actor StartGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    var waitingCount: Int { waiting.count }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

@Suite("SceneBodies", .serialized)
struct SceneBodiesTests {

    /// A scene directory inside its own root, so a body file that escapes the scene lands in the
    /// root, where a test can look for it and `cleanUp` removes it, not in the system temp directory.
    func makeStore() throws -> (dir: URL, store: ManifestStore) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-scenebodies-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("scene")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, ManifestStore(path: dir.appendingPathComponent("manifest.json").path))
    }

    /// Remove the scene and the root it was made in.
    func cleanUp(_ dir: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    func box() throws -> Shape { try #require(Shape.box(width: 10, height: 10, depth: 10)) }

    @Test("a first add creates the scene with the given description")
    func firstAddCreatesTheScene() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        let id = try await SceneBodies.add(
            shape: try box(), description: "built by a host", store: store, history: SceneHistory())
        #expect(id == "body")
        let manifest = try #require(try store.read())
        #expect(manifest.description == "built by a host")
        #expect(manifest.bodies.compactMap(\.id) == ["body"])
        #expect(
            manifest.bodies.first?.file == "body.brep" && manifest.bodies.first?.format == "brep")
    }

    @Test("an add to an existing scene keeps its bodies and description")
    func addKeepsTheScene() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        try Exporter.writeBREP(shape: try box(), to: dir.appendingPathComponent("old.brep"))
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "existing",
                bodies: [BodyDescriptor(id: "old", file: "old.brep")]))
        _ = try await SceneBodies.add(
            shape: try box(), bodyId: "new", description: "ignored", store: store,
            history: SceneHistory())
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.compactMap(\.id) == ["old", "new"])
        #expect(manifest.description == "existing")
    }

    @Test("the previous scene is pushed onto the history before the write")
    func addSnapshotsHistory() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        let history = SceneHistory()
        _ = try await SceneBodies.add(
            shape: try box(), bodyId: "one", store: store, history: history)
        #expect(await history.count() == 0, "no scene yet, nothing to snapshot")
        _ = try await SceneBodies.add(
            shape: try box(), bodyId: "two", store: store, history: history)
        #expect(await history.count() == 1)
        let previous = try #require(await history.snapshot(since: 1))
        #expect(previous.bodies.compactMap(\.id) == ["one"], "snapshot must precede the add")
        // An add that is refused before anything is written leaves the history alone.
        await #expect(throws: ManifestError.bodyIdTaken("two")) {
            _ = try await SceneBodies.add(
                shape: try box(), bodyId: "two", store: store, history: history)
        }
        #expect(await history.count() == 1, "a refused add pushed a snapshot")
    }

    @Test("adds racing for one id: exactly one wins, and the scene holds one intact body")
    func racingForOneId() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        let history = SceneHistory()
        let gate = StartGate()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let shape = Shape.box(width: 10, height: 10, depth: 10) else {
                        return false
                    }
                    // Every task has built its shape and passed no id check before any of them adds.
                    await gate.wait()
                    return
                        (try? await SceneBodies.add(
                            shape: shape, bodyId: "same", store: store, history: history)) != nil
                }
            }
            // Open only once every task has built its shape and is waiting.
            for _ in 0..<500 where await gate.waitingCount < 8 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await gate.open()
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(wins == 1, "\(wins) adds claimed one id")
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.compactMap(\.id) == ["same"])
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["manifest.json", "manifest.lock", "same.brep"], "\(files)")
        let shape = try SceneBodies.shape(ofBody: "same", store: store)
        #expect(abs((shape.volume ?? 0) - 1000) < 1e-6)
    }

    @Test("adds racing for one prefix each get their own id, none fails")
    func racingForOnePrefix() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        let history = SceneHistory()
        let gate = StartGate()
        let ids = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let shape = Shape.box(width: 10, height: 10, depth: 10) else {
                        return nil
                    }
                    await gate.wait()
                    return try? await SceneBodies.add(
                        shape: shape, idPrefix: "part", store: store, history: history)
                }
            }
            // Open only once every task has built its shape and is waiting.
            for _ in 0..<500 where await gate.waitingCount < 8 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await gate.open()
            var got: [String] = []
            for await id in group { if let id { got.append(id) } }
            return got
        }
        let expected = ["part"] + (1..<8).map { "part_\($0)" }
        #expect(Set(ids) == Set(expected), "ids handed out: \(ids.sorted())")
        #expect(ids.count == 8, "\(8 - ids.count) adds failed")
        let manifest = try #require(try store.read())
        #expect(Set(manifest.bodies.compactMap(\.id)) == Set(expected))
        for id in expected {
            let shape = try SceneBodies.shape(ofBody: id, store: store)
            #expect(abs((shape.volume ?? 0) - 1000) < 1e-6, "\(id)")
        }
    }

    @Test("read_brep and import_file refuse an id that cannot name a file")
    func builtInToolsRefuseUnusableIds() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        let brep = dir.appendingPathComponent("input.brep")
        try Exporter.writeBREP(shape: try box(), to: brep)
        let step = dir.appendingPathComponent("input.step")
        try Exporter.writeSTEP(shape: try box(), to: step)

        for bad in ["../escape", ".hidden", "a/b"] {
            let read = await IOTools.readBrep(
                inputPath: brep.path, bodyId: bad, store: store, history: SceneHistory())
            #expect(
                read.isError && read.text.contains("Invalid body id")
                    && !read.text.contains("manifest"),
                "read_brep \(bad): \(read.text)")
            let imported = await IOTools.importFile(
                inputPath: step.path, idPrefix: bad, store: store, history: SceneHistory())
            #expect(
                imported.isError && imported.text.contains("Invalid body id")
                    && !imported.text.contains("manifest"),
                "import_file \(bad): \(imported.text)")
        }
        // A file named with a leading dot has a default id that is refused, and the error says how out.
        let hidden = dir.appendingPathComponent(".scratch.brep")
        try Exporter.writeBREP(shape: try box(), to: hidden)
        let defaulted = await IOTools.readBrep(
            inputPath: hidden.path, store: store, history: SceneHistory())
        #expect(
            defaulted.isError && defaulted.text.contains("Invalid body id"), "\(defaulted.text)")
        let named = await IOTools.readBrep(
            inputPath: hidden.path, bodyId: "scratch", store: store, history: SceneHistory())
        #expect(!named.isError, "\(named.text)")
        #expect(
            !FileManager.default.fileExists(
                atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.brep").path))
    }

    @Test("a manifest write that fails once the body file is in place removes the file")
    func rollsBackOnWriteFailure() async throws {
        struct Veto: Error {}
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        _ = try await SceneBodies.add(
            shape: try box(), bodyId: "kept", store: store, history: SceneHistory())
        let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
        do {
            let veto: ManifestWriteObserver = { _, _ in throw Veto() }
            try await OCCTMCPContext.$manifestWriteObserver.withValue(veto) {
                _ = try await SceneBodies.add(
                    shape: try box(), bodyId: "lost", store: store, history: SceneHistory())
            }
            Issue.record("add succeeded although the manifest write was vetoed")
        } catch is Veto {
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["kept.brep", "manifest.json", "manifest.lock"], "\(files)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == before)
    }

    @Test("an id that cannot name a file is refused and nothing is written")
    func invalidIds() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        for bad in ["", ".hidden", "a/b", "../escape"] {
            await #expect(throws: SceneBodiesError.invalidBodyId(bad), "id \"\(bad)\"") {
                _ = try await SceneBodies.add(
                    shape: try box(), bodyId: bad, store: store, history: SceneHistory())
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.brep").path))
    }

    @Test("a malformed manifest is not overwritten and no body file is written")
    func malformedManifest() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: store.path))
        await #expect(throws: ManifestError.self) {
            _ = try await SceneBodies.add(shape: try box(), store: store, history: SceneHistory())
        }
        #expect(try String(contentsOfFile: store.path, encoding: .utf8) == "{ not json")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == [
                "manifest.json"
            ])
    }

    @Test(
        "a body file that cannot be written fails the add with writeFailed and changes nothing",
        .enabled(if: getuid() != 0, "root can write into a read-only directory"))
    func unwritableDirectory() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        do {
            _ = try await SceneBodies.add(shape: try box(), store: store, history: SceneHistory())
            Issue.record("add into a read-only directory succeeded")
        } catch let error as SceneBodiesError {
            guard case .writeFailed = error else {
                Issue.record("expected writeFailed, got \(error)")
                return
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("body(withId:) and shape(ofBody:) name what is wrong")
    func resolveErrors() async throws {
        let (dir, store) = try makeStore()
        defer { cleanUp(dir) }
        #expect(throws: IntrospectionTools.ToolError.self) {
            _ = try SceneBodies.body(withId: "x", store: store)
        }
        let id = try await SceneBodies.add(shape: try box(), store: store, history: SceneHistory())
        #expect(try SceneBodies.body(withId: id, store: store).file == "body.brep")
        let shape = try SceneBodies.shape(ofBody: id, store: store)
        #expect(abs((shape.volume ?? 0) - 1000) < 1e-6)
        #expect(throws: IntrospectionTools.ToolError.self) {
            _ = try SceneBodies.shape(ofBody: "missing", store: store)
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("body.brep"))
        #expect(throws: IntrospectionTools.ToolError.self) {
            _ = try SceneBodies.shape(ofBody: id, store: store)
        }
    }
}
