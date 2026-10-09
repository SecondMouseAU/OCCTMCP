// A failed analysis tool call must come back as an error result (isError true), not as a success
// whose text describes the failure (#218).

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("Analysis tools report failures as errors")
struct AnalysisToolsErrorPathTests {

    /// A scene holding a real box "a" and "ghost", which has no BREP file.
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-analysis-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "analysis errors",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 0, 1, 1]),
                ]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func noSceneStore() -> ManifestStore {
        ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
    }

    // ── validate_geometry ───────────────────────────────────────────────────

    @Test("validate_geometry: no scene and unknown body are errors")
    func validateErrors() async throws {
        let none = await AnalysisTools.validateGeometry(store: noSceneStore())
        #expect(none.text.contains("No scene loaded"))
        #expect(none.isError)

        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let unknown = await AnalysisTools.validateGeometry(bodyId: "nope", store: store)
        #expect(unknown.text.contains("Body not found: nope"))
        #expect(unknown.isError)
    }

    // ── recognize_features / analyze_clearance ──────────────────────────────

    @Test("recognize_features: no scene, unknown body and missing BREP are errors")
    func recognizeErrors() async throws {
        let none = await AnalysisTools.recognizeFeatures(bodyId: "a", store: noSceneStore())
        #expect(none.text.contains("No scene"))
        #expect(none.isError)

        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let cases: [(body: String, text: String)] = [
            ("nope", "nope"),
            ("ghost", "ghost.brep"),
        ]
        #expect(cases.count == 2)
        for c in cases {
            let result = await AnalysisTools.recognizeFeatures(bodyId: c.body, store: store)
            #expect(result.text.contains(c.text), "\(c.body)")
            #expect(result.isError, "\(c.body)")
        }
    }

    @Test("analyze_clearance: fewer than two ids and an unloadable body are errors")
    func clearanceErrors() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let few = await AnalysisTools.analyzeClearance(bodyIds: ["a"], store: store)
        #expect(few.text.contains("needs at least 2 body ids"))
        #expect(few.isError)

        let missing = await AnalysisTools.analyzeClearance(bodyIds: ["a", "ghost"], store: store)
        #expect(missing.text.contains("ghost.brep"))
        #expect(missing.isError)
    }

    // ── graph_* tools taking a BREP path ────────────────────────────────────

    @Test("graph tools: a BREP path that does not exist is an error and writes nothing")
    func graphMissingFile() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-graph-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let missing = "\(dir)/missing.brep"
        let out = "\(dir)/out.brep"

        let results: [(String, ToolText)] = [
            ("graph_validate", await AnalysisTools.graphValidate(brepPath: missing)),
            ("graph_compact", await AnalysisTools.graphCompact(brepPath: missing, outputPath: out)),
            ("graph_dedup", await AnalysisTools.graphDedup(brepPath: missing, outputPath: out)),
            ("graph_ml", await AnalysisTools.graphML(brepPath: missing)),
            (
                "graph_select",
                await AnalysisTools.graphSelect(
                    brepPath: missing, query: "face-neighbors", face: 0, edge: nil, vertex: nil,
                    edgeClass: nil)
            ),
            ("feature_recognize", await AnalysisTools.featureRecognize(brepPath: missing)),
        ]
        #expect(results.count == 6)
        for (name, result) in results {
            #expect(result.text.contains("BREP file not found"), "\(name)")
            #expect(result.isError, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: out))
    }
}
