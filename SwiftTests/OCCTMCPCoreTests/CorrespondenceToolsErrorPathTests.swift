// find_correspondences must report a missing scene, body or BREP as an error result (isError
// true), not as a successful call with the reason in the text (#218).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("find_correspondences reports failures as errors", .serialized)
struct CorrespondenceToolsErrorPathTests {

    /// A scene holding "good" (a real box), "ghost" (no BREP file) and "junk" (a BREP file that
    /// is not a BREP).
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-corr-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/good.brep"))
        try "not a brep".write(toFile: "\(dir)/junk.brep", atomically: true, encoding: .utf8)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "correspondence errors",
                bodies: [
                    BodyDescriptor(id: "good", file: "good.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 1, 0, 1]),
                    BodyDescriptor(id: "junk", file: "junk.brep", color: [0, 0, 1, 1]),
                ]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    @Test("find_correspondences: no scene is an error")
    func noScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await CorrespondenceTools.findCorrespondences(
            sourceSelectionIds: [], targetBodyId: "good", transform: nil,
            store: store, registry: SelectionRegistry())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("find_correspondences: unknown target, missing BREP and unreadable BREP are errors")
    func targetErrors() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
        let cases: [(body: String, text: String)] = [
            ("nope", "Target body not found: nope"),
            ("ghost", "Target BREP missing or unreadable"),
            ("junk", "Target BREP missing or unreadable"),
        ]
        #expect(cases.count == 3)
        for c in cases {
            let result = await CorrespondenceTools.findCorrespondences(
                sourceSelectionIds: [], targetBodyId: c.body, transform: nil,
                store: store, registry: SelectionRegistry())
            #expect(result.text.contains(c.text), "\(c.body): \(result.text)")
            #expect(result.isError, "\(c.body)")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == before)
    }
}
