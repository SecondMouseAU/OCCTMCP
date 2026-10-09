// A failed transform_body, boolean_op or mirror_or_pattern must come back as an error result
// (isError true), not as a success whose text happens to describe the failure (#218). A manifest
// write that fails after the geometry was produced is a failure too: it must not be swallowed.

import Foundation
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("Construction tools report failures as errors", .serialized)
struct ConstructionToolsErrorPathTests {

    /// A scene holding two real 10 mm boxes "a" and "b", plus "ghost", which has no BREP file.
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-construct-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let a = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let b = try #require(a.translated(by: SIMD3(5, 0, 0)))
        try Exporter.writeBREP(shape: a, to: URL(fileURLWithPath: "\(dir)/a.brep"))
        try Exporter.writeBREP(shape: b, to: URL(fileURLWithPath: "\(dir)/b.brep"))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "construction errors",
                bodies: [
                    BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "b", file: "b.brep", color: [0, 1, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 0, 1, 1]),
                ]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    /// Mark manifest.json immutable: it stays readable, but the atomic replace in
    /// `ManifestStore.write` fails, which injects a failed manifest write.
    func lockManifest(_ store: ManifestStore) throws {
        try FileManager.default.setAttributes(
            [.immutable: true], ofItemAtPath: store.path)
    }

    func cleanup(_ store: ManifestStore) {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.path)
        try? FileManager.default.removeItem(atPath: dirOf(store))
    }

    // ── transform_body ──────────────────────────────────────────────────────

    @Test("transform_body: no scene is an error")
    func transformNoScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await ConstructionTools.transformBody(
            bodyId: "a", options: .init(scale: 2), store: store, history: SceneHistory())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("transform_body: unknown body is an error and the manifest is untouched")
    func transformUnknownBody() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let result = await ConstructionTools.transformBody(
            bodyId: "nope", options: .init(scale: 2), store: store, history: SceneHistory())
        #expect(result.text.contains("Body not found: nope"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @Test("transform_body: a body with no BREP file is an error")
    func transformMissingFile() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let result = await ConstructionTools.transformBody(
            bodyId: "ghost", options: .init(scale: 2), store: store, history: SceneHistory())
        #expect(result.text.contains("BREP file missing"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @Test("transform_body: an existing output id is an error")
    func transformOutputExists() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let result = await ConstructionTools.transformBody(
            bodyId: "a", options: .init(scale: 2, inPlace: false, outputBodyId: "b"),
            store: store, history: SceneHistory())
        #expect(result.text.contains("already exists"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @Test("transform_body: a failed manifest write is an error")
    func transformManifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)
        let result = await ConstructionTools.transformBody(
            bodyId: "a", options: .init(scale: 2), store: store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @Test("transform_body to a new body: a failed manifest write is an error")
    func transformNewBodyManifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let result = await ConstructionTools.transformBody(
            bodyId: "a", options: .init(scale: 2, inPlace: false, outputBodyId: "a2"),
            store: store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
    }

    // ── boolean_op ──────────────────────────────────────────────────────────

    @Test("boolean_op: no scene is an error")
    func booleanNoScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await ConstructionTools.booleanOp(
            op: .union, aBodyId: "a", bBodyId: "b", store: store, history: SceneHistory())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("boolean_op: an unknown operand is an error, for either side")
    func booleanUnknownOperand() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let sides = [("nope", "b"), ("a", "nope")]
        #expect(sides.count == 2)
        for (aId, bId) in sides {
            let result = await ConstructionTools.booleanOp(
                op: .union, aBodyId: aId, bBodyId: bId, store: store, history: SceneHistory())
            #expect(result.text.contains("Body not found: nope"), "\(aId),\(bId)")
            #expect(result.isError, "\(aId),\(bId)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("boolean_op: an existing output id is an error")
    func booleanOutputExists() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let result = await ConstructionTools.booleanOp(
            op: .union, aBodyId: "a", bBodyId: "b", outputBodyId: "ghost",
            store: store, history: SceneHistory())
        #expect(result.text.contains("already exists"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @Test("boolean_op: a failed manifest write is an error")
    func booleanManifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)
        let result = await ConstructionTools.booleanOp(
            op: .union, aBodyId: "a", bBodyId: "b", outputBodyId: "merged",
            store: store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    // ── mirror_or_pattern ───────────────────────────────────────────────────

    @Test("mirror_or_pattern: no scene is an error")
    func patternNoScene() async {
        let store = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")
        let result = await ConstructionTools.mirrorOrPattern(
            bodyId: "a", kind: .mirror, params: .init(), store: store, history: SceneHistory())
        #expect(result.text.contains("No scene loaded"))
        #expect(result.isError)
    }

    @Test("mirror_or_pattern: unknown body, missing BREP file and existing output id are errors")
    func patternInputErrors() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let cases: [(body: String, out: String?, text: String)] = [
            ("nope", nil, "Body not found: nope"),
            ("ghost", nil, "BREP file missing"),
            ("a", "b", "already exists"),
        ]
        #expect(cases.count == 3)
        for c in cases {
            let result = await ConstructionTools.mirrorOrPattern(
                bodyId: c.body, kind: .mirror, params: .init(), outputBodyId: c.out,
                store: store, history: SceneHistory())
            #expect(result.text.contains(c.text), "\(c.body)")
            #expect(result.isError, "\(c.body)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("mirror_or_pattern: each kind with its required parameters missing is an error")
    func patternMissingParams() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        let before = try bytes(store)
        let cases: [(kind: ConstructionTools.PatternKind, text: String)] = [
            (.mirror, "mirror requires"),
            (.linear, "linear requires"),
            (.circular, "circular requires"),
        ]
        #expect(cases.count == 3)
        for c in cases {
            let result = await ConstructionTools.mirrorOrPattern(
                bodyId: "a", kind: c.kind, params: .init(), store: store, history: SceneHistory())
            #expect(result.text.contains(c.text), "\(c.kind)")
            #expect(result.isError, "\(c.kind)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("mirror_or_pattern: a failed manifest write is an error")
    func patternManifestWriteFails() async throws {
        let store = try freshScene()
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)
        var params = ConstructionTools.PatternParams()
        params.planeNormal = SIMD3(1, 0, 0)
        params.planeOrigin = SIMD3(30, 0, 0)
        let result = await ConstructionTools.mirrorOrPattern(
            bodyId: "a", kind: .mirror, params: params, outputBodyId: "mirrored",
            store: store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"))
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }
}
