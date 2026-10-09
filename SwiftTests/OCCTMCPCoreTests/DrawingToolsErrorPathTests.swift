// A failed generate_drawing must come back as an error result (isError true) and must not
// leave an output file behind (#218).

import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("generate_drawing reports failures as errors")
struct DrawingToolsErrorPathTests {

    /// A scene holding a real box "a" and "ghost", which has no BREP file.
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-drawing-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "drawing errors",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 0, 1, 1]),
                ]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    @Test("generate_drawing: no scene is an error")
    func noScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await DrawingTools.generateDrawing(
            bodyIds: ["a"], outputPath: NSTemporaryDirectory() + "never-\(UUID()).dxf",
            spec: .object([:]), store: store)
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("generate_drawing: bad arguments are errors and write no file")
    func badArguments() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let out = "\(dirOf(store))/out.dxf"
        let cases: [(ids: [String], spec: Value, text: String)] = [
            ([], .object([:]), "requires `bodyId`"),
            (["nope"], .object([:]), "Body not found: nope"),
            (["ghost"], .object([:]), "BREP file missing"),
            (["a"], .string("not an object"), "`spec` must be a JSON object"),
            (["a"], .object(["views": .string("not an array")]), "Invalid DrawingSpec"),
        ]
        #expect(cases.count == 5)
        for c in cases {
            let result = await DrawingTools.generateDrawing(
                bodyIds: c.ids, outputPath: out, spec: c.spec, store: store)
            #expect(result.text.contains(c.text), "\(c.text)")
            #expect(result.isError, "\(c.text)")
        }
        #expect(!FileManager.default.fileExists(atPath: out))
    }
}
