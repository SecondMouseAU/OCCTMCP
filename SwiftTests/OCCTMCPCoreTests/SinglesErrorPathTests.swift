// Single-site error paths from #218 round two: each of these tools described a failure in the
// result text but returned isError false. Every case here asserts isError, the error text, and
// that nothing was written (manifest.json bytes, or the absent output file).

import Foundation
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

/// A scene with one real 10 mm box "box", one empty scene, and a missing one.
struct SinglesFixture {
    let dir: String
    let store: ManifestStore
    let emptyStore: ManifestStore
    let missingStore: ManifestStore

    init() throws {
        dir = NSTemporaryDirectory() + "occtmcp-singles-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/box.brep"))
        store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "singles errors",
                bodies: [BodyDescriptor(id: "box", file: "box.brep", color: [1, 0, 0, 1])]))
        try FileManager.default.createDirectory(
            atPath: "\(dir)/empty", withIntermediateDirectories: true)
        emptyStore = ManifestStore(path: "\(dir)/empty/manifest.json")
        try emptyStore.write(
            ScriptManifest(version: 1, timestamp: Date(), description: "empty", bodies: []))
        missingStore = ManifestStore(path: "\(dir)/missing/manifest.json")
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: dir) }
}

@Suite("select_topology / query_topology / remap_selection report failures as errors")
struct SelectionIntrospectionRemapErrorPathTests {

    @Test("select_topology: an unknown kind is an error")
    func selectUnknownKind() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let result = await SelectionTools.selectTopology(
            bodyId: "box", kind: "wire", store: f.store, registry: SelectionRegistry())
        #expect(result.text.contains("Unknown kind 'wire'"), "\(result.text)")
        #expect(result.isError)
        #expect(try f.bytes(f.store) == before)
    }

    @Test("query_topology: an unknown entity is an error")
    func queryUnknownEntity() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let result = await IntrospectionTools.queryTopology(
            bodyId: "box", entity: "shell", store: f.store)
        #expect(result.text.contains("Unknown entity 'shell'"), "\(result.text)")
        #expect(result.isError)
        #expect(try f.bytes(f.store) == before)
    }

    @Test("remap_selection: no scene is an error")
    func remapNoScene() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let result = await RemapTools.remapSelection(
            selectionIds: [], store: f.missingStore, registry: SelectionRegistry())
        #expect(result.text.contains("No scene loaded"), "\(result.text)")
        #expect(result.isError)
    }
}

@Suite("pick_surface_point / render_preview report failures as errors")
struct RenderPickErrorPathTests {

    @MainActor
    @Test("pick_surface_point: no scene is an error")
    func pickNoScene() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let result = await RayPickTool.pickSurfacePoint(
            screenX: 10, screenY: 10, store: f.missingStore, registry: SelectionRegistry())
        #expect(result.text.contains("No scene loaded"), "\(result.text)")
        #expect(result.isError)
    }

    @MainActor
    @Test("render_preview: no scene, unknown body ids and an empty scene are errors")
    func renderErrors() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let png = "\(f.dir)/preview.png"
        let cases: [(label: String, result: ToolText, text: String)] = [
            (
                "no scene",
                await RenderPreviewTool.render(outputPath: png, store: f.missingStore),
                "No scene loaded"
            ),
            (
                "unknown ids",
                await RenderPreviewTool.render(
                    outputPath: png, bodyIds: ["box", "ghost"], store: f.store),
                "Body ids not found: ghost"
            ),
            (
                "empty scene",
                await RenderPreviewTool.render(outputPath: png, store: f.emptyStore),
                "No bodies to render"
            ),
        ]
        #expect(cases.count == 3)
        for c in cases {
            #expect(c.result.text.contains(c.text), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
        #expect(!FileManager.default.fileExists(atPath: png))
        #expect(try f.bytes(f.store) == before)
    }
}

@Suite("diff_overlay reports failures as errors")
struct GapFillerErrorPathTests {

    @Test("diff_overlay: no scene and too little history are errors, annotations untouched")
    func diffOverlayErrors() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let noScene = await GapFillerTools.diffOverlay(
            since: 1, store: f.missingStore, history: SceneHistory())
        #expect(noScene.text.contains("No scene loaded"), "\(noScene.text)")
        #expect(noScene.isError)

        let shortHistory = await GapFillerTools.diffOverlay(
            since: 3, store: f.store, history: SceneHistory())
        #expect(shortHistory.text.contains("Not enough history"), "\(shortHistory.text)")
        #expect(shortHistory.isError)
        #expect(try f.bytes(f.store) == before)
        #expect(!FileManager.default.fileExists(atPath: "\(f.dir)/annotations.json"))
    }
}

@Suite("simplify_mesh reports bad arguments as errors")
struct MeshToolsErrorPathTests {

    @Test("simplify_mesh: neither or both targets, and a bad output extension, are errors")
    func simplifyArguments() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let out = "\(f.dir)/out.stl"
        let cases: [(label: String, result: ToolText, text: String)] = [
            (
                "neither target",
                await MeshTools.simplifyMesh(bodyId: "box", outputPath: out, store: f.store),
                "Pass exactly one of"
            ),
            (
                "both targets",
                await MeshTools.simplifyMesh(
                    bodyId: "box", outputPath: out, targetTriangleCount: 10,
                    targetReduction: 0.5, store: f.store),
                "Pass exactly one of"
            ),
            (
                "bad extension",
                await MeshTools.simplifyMesh(
                    bodyId: "box", outputPath: "\(f.dir)/out.ply", targetTriangleCount: 10,
                    store: f.store),
                "outputPath must end in .stl or .obj"
            ),
        ]
        #expect(cases.count == 3)
        for c in cases {
            #expect(c.result.text.contains(c.text), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
        #expect(!FileManager.default.fileExists(atPath: out))
        #expect(try f.bytes(f.store) == before)
    }
}

@Suite("add_dimension reports missing and unresolvable anchors as errors")
struct AnnotationsToolsErrorPathTests {

    @Test("add_dimension: missing anchors and unresolvable anchors are errors, no sidecar written")
    func dimensionErrors() async throws {
        let f = try SinglesFixture()
        defer { f.cleanup() }
        let before = try f.bytes(f.store)
        let registry = SelectionRegistry()
        let cases: [(label: String, result: ToolText, text: String)] = [
            (
                "linear missing",
                await AnnotationsTools.addDimension(
                    kind: .linear, anchors: [:], store: f.store, registry: registry),
                "linear dimension requires anchors.from and anchors.to"
            ),
            (
                "angular missing",
                await AnnotationsTools.addDimension(
                    kind: .angular, anchors: [:], store: f.store, registry: registry),
                "angular dimension requires anchors.armA"
            ),
            (
                "angular unresolved",
                await AnnotationsTools.addDimension(
                    kind: .angular,
                    anchors: ["armA": "sel:x#vertex[0]", "apex": "sel:x#vertex[1]", "armB": "sel:x#vertex[2]"],
                    store: f.store, registry: registry),
                "Could not resolve angular anchors"
            ),
            (
                "radial missing",
                await AnnotationsTools.addDimension(
                    kind: .radial, anchors: [:], store: f.store, registry: registry),
                "radial dimension requires anchors.circularEdge"
            ),
            (
                "radial unresolved",
                await AnnotationsTools.addDimension(
                    kind: .radial, anchors: ["circularEdge": "sel:x#edge[0]"],
                    store: f.store, registry: registry),
                "Could not resolve circular edge"
            ),
        ]
        #expect(cases.count == 5)
        for c in cases {
            #expect(c.result.text.contains(c.text), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
        #expect(!FileManager.default.fileExists(atPath: "\(f.dir)/annotations.json"))
        #expect(try f.bytes(f.store) == before)
    }
}
