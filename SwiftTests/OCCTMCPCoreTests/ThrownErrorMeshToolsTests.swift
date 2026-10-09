// #235 round three, the mesh tool family: a body that cannot be loaded made each tool return the
// thrown error as plain text with isError false. Each case asserts isError, the tool-name prefix,
// the underlying reason, and that manifest.json is unchanged.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

/// A scene with "good" (a real box), "ghost" (no BREP file) and "junk" (a file that is not a BREP).
struct ThrownErrorMeshFixture {
    let dir: String
    let store: ManifestStore
    let noSceneStore: ManifestStore

    init() throws {
        dir = NSTemporaryDirectory() + "occtmcp-thrown-mesh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/good.brep"))
        try "not a brep".write(toFile: "\(dir)/junk.brep", atomically: true, encoding: .utf8)
        store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "thrown mesh errors",
                bodies: [
                    BodyDescriptor(id: "good", file: "good.brep", color: [1, 0, 0, 1]),
                    BodyDescriptor(id: "ghost", file: "ghost.brep", color: [0, 1, 0, 1]),
                    BodyDescriptor(id: "junk", file: "junk.brep", color: [0, 0, 1, 1]),
                ]))
        noSceneStore = ManifestStore(path: "\(dir)/none/manifest.json")
    }

    func manifestBytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: dir) }

    /// The ways `loadShape` throws, with the reason text each must carry.
    var loadFailures: [(label: String, bodyId: String, noScene: Bool, reason: String)] {
        [
            ("no scene", "good", true, "No scene loaded"),
            ("unknown body", "nope", false, "Body not found: nope"),
            ("missing brep", "ghost", false, "BREP file missing"),
            ("unreadable brep", "junk", false, "Failed to import BREP file"),
        ]
    }

    func storeFor(noScene: Bool) -> ManifestStore { noScene ? noSceneStore : store }
}

@Suite("mesh tools return a load failure as an error")
struct ThrownErrorMeshToolsTests {

    func check(_ result: ToolText, tool: String, reason: String, label: String) {
        #expect(result.isError, "\(tool) \(label): \(result.text)")
        #expect(result.text.hasPrefix("\(tool): "), "\(tool) \(label): \(result.text)")
        #expect(result.text.contains(reason), "\(tool) \(label): \(result.text)")
        // The prefix alone is not a reason: something must follow it.
        #expect(result.text.count > tool.count + 2, "\(tool) \(label): \(result.text)")
    }

    @Test("generate_mesh: a body that cannot load is an error")
    func generateMesh() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshTools.generateMesh(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "generate_mesh", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @Test("simplify_mesh: a body that cannot load is an error and writes no file")
    func simplifyMesh() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let out = "\(f.dir)/out.stl"
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshTools.simplifyMesh(
                bodyId: c.bodyId, outputPath: out, targetReduction: 0.5,
                store: f.storeFor(noScene: c.noScene))
            check(result, tool: "simplify_mesh", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    @MainActor
    @Test("segment_mesh_zones: a body that cannot load is an error")
    func segmentMeshZones() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshZoneTools.segmentMeshZones(
                bodyId: c.bodyId, render: false, registry: ZoneRegistry(),
                store: f.storeFor(noScene: c.noScene))
            check(result, tool: "segment_mesh_zones", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("detect_mesh_features: a body that cannot load is an error")
    func detectMeshFeatures() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshFeatureTools.detectMeshFeatures(
                bodyId: c.bodyId, render: false, registry: ZoneRegistry(),
                store: f.storeFor(noScene: c.noScene))
            check(result, tool: "detect_mesh_features", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("mesh_curvature: a body that cannot load is an error")
    func meshCurvature() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshCurvatureTools.meshCurvature(
                bodyId: c.bodyId, render: false, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "mesh_curvature", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("mesh_thickness: a body that cannot load is an error")
    func meshThickness() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshThicknessTools.meshThickness(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "mesh_thickness", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }

    @MainActor
    @Test("mesh_diagnose: a body that cannot load is an error")
    func meshDiagnose() async throws {
        let f = try ThrownErrorMeshFixture()
        defer { f.cleanup() }
        let before = try f.manifestBytes()
        let cases = f.loadFailures
        #expect(cases.count == 4)
        for c in cases {
            let result = await MeshDiagnoseTools.meshDiagnose(
                bodyId: c.bodyId, store: f.storeFor(noScene: c.noScene))
            check(result, tool: "mesh_diagnose", reason: c.reason, label: c.label)
        }
        #expect(try f.manifestBytes() == before)
    }
}
