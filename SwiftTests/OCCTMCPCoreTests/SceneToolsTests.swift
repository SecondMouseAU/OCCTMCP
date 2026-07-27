// Unit tests for the scene-mutation tools — mirror tests/unit/
// scene-mutation.test.mjs from the Node side.

import Foundation
import Testing
import ScriptHarness
@testable import OCCTMCPCore

@Suite("Scene-mutation tools")
struct SceneToolsTests {

    /// Build a fresh tempdir, seed it with `alpha`+`beta` bodies and a
    /// matching manifest, return a ManifestStore pointing at it. The
    /// caller is responsible for SceneHistory.shared.clear().
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-swifttest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let manifest = ScriptManifest(
            version: 1,
            timestamp: Date(),
            description: "Test scene",
            bodies: [
                BodyDescriptor(id: "alpha", file: "alpha.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "beta", file: "beta.brep", color: [0, 1, 0, 1]),
            ]
        )
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        try "DUMMY-A".write(toFile: "\(dir)/alpha.brep", atomically: true, encoding: .utf8)
        try "DUMMY-B".write(toFile: "\(dir)/beta.brep", atomically: true, encoding: .utf8)
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        return (store.path as NSString).deletingLastPathComponent
    }

    // ── remove_body ─────────────────────────────────────────────────────────

    @Test("remove_body deletes manifest entry and BREP file")
    func removesBody() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.removeBody(bodyId: "alpha", store: store, history: history)
        #expect(result.text.contains("Removed body \"alpha\""))

        let updated = try store.read()
        #expect(updated?.bodies.count == 1)
        #expect(updated?.bodies.first?.id == "beta")
        #expect(!FileManager.default.fileExists(atPath: "\(dirOf(store))/alpha.brep"))
        #expect(FileManager.default.fileExists(atPath: "\(dirOf(store))/beta.brep"))
    }

    @Test("remove_body errors on unknown id")
    func removesBodyMissing() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.removeBody(bodyId: "nope", store: store, history: history)
        #expect(result.text.contains("Body not found: nope"))
    }

    @Test("remove_body also drops the body's provenance record (#132)")
    func removesBodyDropsProvenance() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let provenance = ProvenanceStore()
        await provenance.upsert(
            bodyId: "alpha",
            record: ProvenanceRecord(
                sourceBodyId: "beta",
                transform: .mirror(planeOrigin: .zero, planeNormal: [0, 0, 1])
            ),
            outputDir: dirOf(store)
        )
        #expect(await provenance.read(outputDir: dirOf(store))["alpha"] != nil)

        _ = await SceneTools.removeBody(bodyId: "alpha", store: store, history: history)

        #expect(await provenance.read(outputDir: dirOf(store))["alpha"] == nil)
    }

    // ── clear_scene ─────────────────────────────────────────────────────────

    @Test("clear_scene removes every body and its BREP")
    func clearScene() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.clearScene(keepHistory: false, store: store, history: history)
        #expect(result.text.contains("Cleared 2 bodies"))

        let updated = try store.read()
        #expect(updated?.bodies.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: "\(dirOf(store))/alpha.brep"))
        #expect(!FileManager.default.fileExists(atPath: "\(dirOf(store))/beta.brep"))
    }

    @Test("clear_scene wipes every provenance record (#132)")
    func clearSceneWipesProvenance() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let provenance = ProvenanceStore()
        await provenance.upsert(
            bodyId: "alpha",
            record: ProvenanceRecord(
                sourceBodyId: "beta",
                transform: .mirror(planeOrigin: .zero, planeNormal: [0, 0, 1])
            ),
            outputDir: dirOf(store)
        )
        #expect(await provenance.read(outputDir: dirOf(store))["alpha"] != nil)

        _ = await SceneTools.clearScene(keepHistory: false, store: store, history: history)

        #expect(await provenance.read(outputDir: dirOf(store)).isEmpty)
    }

    // ── rename_body ─────────────────────────────────────────────────────────

    @Test("rename_body changes the id")
    func renameBody() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.renameBody(
            bodyId: "alpha", newBodyId: "alpha2", store: store, history: history)
        #expect(result.text.contains("\"alpha\" → \"alpha2\""))

        let updated = try store.read()
        #expect(updated?.bodies.first(where: { $0.file == "alpha.brep" })?.id == "alpha2")
    }

    @Test("rename_body rejects collisions")
    func renameBodyCollision() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.renameBody(
            bodyId: "alpha", newBodyId: "beta", store: store, history: history)
        #expect(result.text.contains("already exists"))
    }

    // ── set_appearance ──────────────────────────────────────────────────────

    @Test("set_appearance updates color, opacity, and name")
    func setAppearanceUpdates() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.setAppearance(
            bodyId: "alpha",
            update: .init(color: [0.2, 0.4, 0.6], opacity: 0.5, name: "Alpha part"),
            store: store,
            history: history
        )
        #expect(result.text.contains("Updated appearance of \"alpha\""))

        let updated = try store.read()
        let alpha = updated?.body(withId: "alpha")
        #expect(alpha?.color == [0.2, 0.4, 0.6, 0.5])
        #expect(alpha?.name == "Alpha part")
    }

    @Test("set_appearance rejects empty input")
    func setAppearanceEmpty() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.setAppearance(
            bodyId: "alpha", update: .init(), store: store, history: history)
        #expect(result.text.contains("No appearance fields provided"))
    }

    // ── compare_versions ────────────────────────────────────────────────────

    @Test("compare_versions reports added bodies")
    func compareVersionsAdds() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        // Snapshot first, then mutate
        await history.snapshot(store: store)
        let cur = try store.read()!
        var bodies = cur.bodies
        bodies.append(BodyDescriptor(id: "gamma", file: "gamma.brep"))
        let updated = ScriptManifest(
            version: cur.version, timestamp: Date(), description: cur.description,
            bodies: bodies, graphs: cur.graphs, metadata: cur.metadata
        )
        try store.write(updated)

        let result = await SceneTools.compareVersions(since: 1, store: store, history: history)
        #expect(result.text.contains("\"added\""))
        #expect(result.text.contains("\"gamma\""))
    }

    @Test("compare_versions errors when history is too shallow")
    func compareVersionsShallow() async throws {
        let store = try freshScene()
        let history = SceneHistory()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SceneTools.compareVersions(since: 5, store: store, history: history)
        #expect(result.text.contains("Not enough history"))
    }
}
