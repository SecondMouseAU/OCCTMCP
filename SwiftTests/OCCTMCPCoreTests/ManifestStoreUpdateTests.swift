// ManifestStore.update: the advisory lock, the pre-write byte callback, and a malformed manifest
// being an error. The mutating tools are exercised through SceneTools (#250).

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("ManifestStore.update")
struct ManifestStoreUpdateTests {

    func makeStore(lockTimeout: TimeInterval = 30) -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-update-\(UUID().uuidString)"
        return ManifestStore(path: "\(dir)/manifest.json", lockTimeout: lockTimeout)
    }

    func manifest(_ ids: [String], description: String? = "test") -> ScriptManifest {
        ScriptManifest(
            version: 1, timestamp: Date(), description: description,
            bodies: ids.map { BodyDescriptor(id: $0, file: "\($0).brep") })
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    func cleanup(_ store: ManifestStore) {
        try? FileManager.default.removeItem(
            atPath: (store.path as NSString).deletingLastPathComponent)
    }

    @Test("update on an absent manifest passes nil and creates the file")
    func updateCreates() throws {
        let store = makeStore()
        defer { cleanup(store) }
        var sawNil = false
        let written = try store.update { current in
            sawNil = current == nil
            return manifest(["a"])
        }
        #expect(sawNil)
        #expect(written.bodies.map(\.id) == ["a"])
        #expect(try store.read()?.bodies.map(\.id) == ["a"])
    }

    @Test("the callback receives exactly the bytes that land on disk, before the rename")
    func callbackSeesWrittenBytes() throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest(["old"]))
        let before = try bytes(store)

        var seen: Data?
        var onDiskAtCallback: Data?
        try store.update(willWrite: { data in
            seen = data
            onDiskAtCallback = try? bytes(store)
        }) { current in
            let current = try current.requiringScene()
            return current.replacing(
                bodies: current.bodies + [BodyDescriptor(id: "new", file: "n")])
        }

        let after = try bytes(store)
        #expect(seen == after)
        #expect(onDiskAtCallback == before)
        #expect(after != before)
    }

    @Test("a callback that throws aborts the write")
    func callbackThrowAborts() throws {
        struct Veto: Error {}
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest(["old"]))
        let before = try bytes(store)

        #expect(throws: Veto.self) {
            try store.update(willWrite: { _ in throw Veto() }) { _ in manifest(["new"]) }
        }
        #expect(try bytes(store) == before)
    }

    @Test("a transform that throws aborts the write")
    func transformThrowAborts() throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest(["old"]))
        let before = try bytes(store)

        #expect(throws: ManifestError.bodyNotFound("x")) {
            try store.update { _ in throw ManifestError.bodyNotFound("x") }
        }
        #expect(try bytes(store) == before)
    }

    @Test("a second writer is held out until the first has committed")
    func lockExcludesConcurrentWriter() throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest([]))

        let firstInside = DispatchSemaphore(value: 0)
        let events = EventLog()
        let done = DispatchGroup()

        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            _ = try? store.update { current in
                events.add("first-enter")
                firstInside.signal()
                Thread.sleep(forTimeInterval: 0.3)
                events.add("first-leave")
                return try current.requiringScene().replacing(
                    bodies: [BodyDescriptor(id: "first", file: "first.brep")])
            }
        }
        firstInside.wait()
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            _ = try? store.update { current in
                events.add("second-enter")
                let current = try current.requiringScene()
                // The second writer must see the first one's result, not the pre-lock state.
                events.add("second-saw-\(current.bodies.compactMap(\.id).joined(separator: ","))")
                return current.replacing(
                    bodies: current.bodies + [
                        BodyDescriptor(id: "second", file: "second.brep")
                    ])
            }
        }
        done.wait()

        #expect(
            events.all == ["first-enter", "first-leave", "second-enter", "second-saw-first"])
        #expect(try store.read()?.bodies.map(\.id) == ["first", "second"])
    }

    @Test("many concurrent updates all land")
    func concurrentUpdatesAllLand() throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest([]))
        let count = 24
        DispatchQueue.concurrentPerform(iterations: count) { i in
            _ = try? store.update { current in
                let current = try current.requiringScene()
                return current.replacing(
                    bodies: current.bodies + [BodyDescriptor(id: "b\(i)", file: "b\(i).brep")])
            }
        }
        let ids = try #require(try store.read()).bodies.compactMap(\.id)
        #expect(Set(ids) == Set((0..<count).map { "b\($0)" }))
        #expect(ids.count == count)
    }

    @Test("a lock held by another holder makes update and write time out without writing")
    func heldLockTimesOut() throws {
        let store = makeStore(lockTimeout: 0.2)
        defer { cleanup(store) }
        try store.write(manifest(["old"]))
        let before = try bytes(store)

        let fd = open(store.lockPath, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }

        #expect(throws: ManifestError.lockTimeout(path: store.lockPath)) {
            try store.update { _ in manifest(["new"]) }
        }
        #expect(throws: ManifestError.lockTimeout(path: store.lockPath)) {
            try store.write(manifest(["new"]))
        }
        #expect(try bytes(store) == before)
    }

    @Test("a malformed manifest is an error from update and is not overwritten")
    func malformedThrows() throws {
        let store = makeStore()
        defer { cleanup(store) }
        try FileManager.default.createDirectory(
            atPath: (store.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: URL(fileURLWithPath: store.path))

        var transformRan = false
        do {
            try store.update { _ in
                transformRan = true
                return manifest(["x"])
            }
            Issue.record("update should have thrown")
        } catch let error as ManifestError {
            guard case .malformed(let path, _) = error else {
                Issue.record("expected malformed, got \(error)")
                return
            }
            #expect(path == store.path)
        }
        #expect(!transformRan)
        #expect(try bytes(store) == junk)

        #expect(throws: ManifestError.self) { try store.requireScene() }
        #expect(throws: ManifestError.self) { try store.requireSceneOrAbsent() }
    }

    @Test("an absent manifest is noScene, not malformed")
    func absentIsNoScene() throws {
        let store = makeStore()
        defer { cleanup(store) }
        #expect(throws: ManifestError.noScene) { try store.requireScene() }
        #expect(try store.requireSceneOrAbsent() == nil)
    }

    // ── tools ─────────────────────────────────────────────────────────

    @Test("remove_body, rename_body, set_appearance and clear_scene still work")
    func sceneToolsStillWork() async throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest(["a", "b", "c"]))
        let history = SceneHistory()

        let rename = await SceneTools.renameBody(
            bodyId: "a", newBodyId: "a2", store: store, history: history)
        #expect(!rename.isError, "\(rename.text)")
        let appearance = await SceneTools.setAppearance(
            bodyId: "b", update: .init(color: [1, 0, 0], opacity: 0.5, name: "Bee"),
            store: store, history: history)
        #expect(!appearance.isError, "\(appearance.text)")
        let remove = await SceneTools.removeBody(bodyId: "c", store: store, history: history)
        #expect(!remove.isError, "\(remove.text)")

        let current = try #require(try store.read())
        #expect(current.bodies.map(\.id) == ["a2", "b"])
        #expect(current.body(withId: "b")?.name == "Bee")
        #expect(current.body(withId: "b")?.color == [1, 0, 0, 0.5])

        let clear = await SceneTools.clearScene(store: store, history: history)
        #expect(!clear.isError, "\(clear.text)")
        #expect(try store.read()?.bodies.isEmpty == true)
    }

    @Test("concurrent set_appearance calls on different bodies both land")
    func concurrentToolCalls() async throws {
        let store = makeStore()
        defer { cleanup(store) }
        try store.write(manifest(["a", "b"]))
        async let first = SceneTools.setAppearance(
            bodyId: "a", update: .init(name: "first"), store: store, history: SceneHistory())
        async let second = SceneTools.setAppearance(
            bodyId: "b", update: .init(name: "second"), store: store, history: SceneHistory())
        let results = await [first, second]
        #expect(results.allSatisfy { !$0.isError })
        let current = try #require(try store.read())
        #expect(current.body(withId: "a")?.name == "first")
        #expect(current.body(withId: "b")?.name == "second")
    }

    @Test("a tool reports a malformed manifest as such, and leaves it alone")
    func toolsReportMalformed() async throws {
        let store = makeStore()
        defer { cleanup(store) }
        try FileManager.default.createDirectory(
            atPath: (store.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let junk = Data("{ not json".utf8)
        try junk.write(to: URL(fileURLWithPath: store.path))
        let history = SceneHistory()

        let remove = await SceneTools.removeBody(bodyId: "a", store: store, history: history)
        #expect(remove.isError)
        #expect(!remove.text.contains("No scene loaded"), "\(remove.text)")
        #expect(remove.text.contains("could not be parsed"), "\(remove.text)")

        let clear = await SceneTools.clearScene(store: store, history: history)
        #expect(clear.isError)
        #expect(!clear.text.contains("No scene loaded"), "\(clear.text)")

        // read_brep used to treat a malformed manifest as an empty scene and overwrite it.
        let box = try #require(Shape.box(width: 1, height: 1, depth: 1))
        let brepPath = (store.path as NSString).deletingLastPathComponent + "/in.brep"
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: brepPath))
        let imported = await IOTools.readBrep(inputPath: brepPath, store: store, history: history)
        #expect(imported.isError)
        #expect(imported.text.contains("could not be parsed"), "\(imported.text)")

        #expect(try bytes(store) == junk)
    }

    @Test("a tool on an absent manifest still says no scene is loaded")
    func toolsReportAbsent() async {
        let store = makeStore()
        defer { cleanup(store) }
        let result = await SceneTools.removeBody(
            bodyId: "a", store: store, history: SceneHistory())
        #expect(result.isError)
        #expect(result.text.contains("No scene loaded"))
    }
}

/// Thread-safe event recorder for the lock-ordering test.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
