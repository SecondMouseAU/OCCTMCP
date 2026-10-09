// The scene tools must report "No scene loaded", a malformed colour and an unsatisfiable
// compare_versions request as error results (isError true), not as successful calls (#218).

import Foundation
import Testing
import ScriptHarness
@testable import OCCTMCPCore

@Suite("Scene tools report the remaining failures as errors", .serialized)
struct SceneToolsErrorPathTests {

    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-scene-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "scene errors",
                bodies: [BodyDescriptor(id: "alpha", file: "alpha.brep", color: [1, 0, 0, 1])]))
        try "DUMMY-A".write(toFile: "\(dir)/alpha.brep", atomically: true, encoding: .utf8)
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    @Test("remove_body, clear_scene, rename_body, set_appearance, compare_versions: no scene")
    func noScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let history = SceneHistory()
        let cases: [(label: String, result: ToolText)] = [
            ("remove_body", await SceneTools.removeBody(bodyId: "a", store: store, history: history)),
            ("clear_scene", await SceneTools.clearScene(store: store, history: history)),
            (
                "rename_body",
                await SceneTools.renameBody(
                    bodyId: "a", newBodyId: "b", store: store, history: history)
            ),
            (
                "set_appearance",
                await SceneTools.setAppearance(
                    bodyId: "a", update: .init(opacity: 0.5), store: store, history: history)
            ),
            ("compare_versions", await SceneTools.compareVersions(store: store, history: history)),
        ]
        #expect(cases.count == 5)
        for c in cases {
            #expect(c.result.text.contains("No scene loaded"), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
    }

    @Test("set_appearance: a colour that is not 3 or 4 components is an error, manifest untouched")
    func badColourLength() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let before = try bytes(store)
        let lengths = [0, 1, 2, 5]
        #expect(lengths.count == 4)
        for n in lengths {
            let result = await SceneTools.setAppearance(
                bodyId: "alpha",
                update: .init(color: Array(repeating: 0.5, count: n)),
                store: store, history: SceneHistory())
            #expect(result.text.contains("got length \(n)"), "length \(n): \(result.text)")
            #expect(result.isError, "length \(n)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("compare_versions: asking for more history than exists is an error")
    func notEnoughHistory() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let before = try bytes(store)
        let result = await SceneTools.compareVersions(
            since: 5, store: store, history: SceneHistory())
        #expect(result.text.contains("Not enough history"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }
}
