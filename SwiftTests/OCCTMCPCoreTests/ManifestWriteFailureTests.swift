// align_bodies (apply: true) and segment_mesh_zones (registerZones: true) must not report success
// when the manifest write that makes their change visible fails (#218). The failed write is
// injected by marking manifest.json immutable: it stays readable but the atomic replace fails.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing
import simd

@testable import OCCTMCPCore

@Suite("A failed manifest write is an error result, not a swallowed one", .serialized)
struct ManifestWriteFailureTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-writefail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "write failures",
                bodies: bodies.map {
                    BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1])
                }))
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    /// Mark manifest.json immutable: it stays readable but the atomic replace in
    /// `ManifestStore.write` fails, which injects a failed manifest write.
    func lockManifest(_ store: ManifestStore) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: store.path)
    }

    func cleanup(_ store: ManifestStore) {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: store.path)
        try? FileManager.default.removeItem(atPath: dirOf(store))
    }

    @MainActor
    @Test("align_bodies apply=true: a failed manifest write is an error")
    func alignApplyManifestWriteFails() async throws {
        let base = try #require(Shape.box(width: 40, height: 30, depth: 20))
        let bump = try #require(Shape.box(width: 6, height: 6, depth: 6))
        let positionedBump = try #require(bump.translated(by: SIMD3<Double>(21, 16, 11)))
        let reference = try #require(base.union(positionedBump))
        let axis = simd_normalize(SIMD3<Double>(0.3, 0.5, 0.8))
        let rotated = try #require(
            reference.rotated(axis: axis, angle: 27.0 * Double.pi / 180.0))
        let source = try #require(rotated.translated(by: SIMD3<Double>(60, -35, 15)))

        let store = try scene([(id: "reference", shape: reference), (id: "source", shape: source)])
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)

        let result = await AlignTools.alignBodies(
            bodyId: "source", referenceBodyId: "reference", apply: true,
            store: store, history: SceneHistory())
        #expect(result.text.contains("Failed to write manifest"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(store) == before)
    }

    @MainActor
    @Test("segment_mesh_zones registerZones=true: a failed manifest write is an error")
    func registerZonesManifestWriteFails() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])
        defer { cleanup(store) }
        try lockManifest(store)
        let before = try bytes(store)

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, registerZones: true, registerCap: 2,
            render: false, registry: ZoneRegistry(), store: store)
        #expect(result.text.contains("Failed to write manifest"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(store) == before)

        // The zone BREPs written for the failed registration must not be left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dirOf(store))
            .filter { $0.hasPrefix("box_zone") }
        #expect(leftovers.isEmpty, "orphaned zone files: \(leftovers)")
    }

    @MainActor
    @Test("segment_mesh_zones registerZones=true still registers when the write succeeds")
    func registerZonesControl() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])
        defer { cleanup(store) }
        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, registerZones: true, registerCap: 2,
            render: false, registry: ZoneRegistry(), store: store)
        #expect(!result.isError, "\(result.text)")
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.count == 3)
        let zoneFiles = try FileManager.default.contentsOfDirectory(atPath: dirOf(store))
            .filter { $0.hasPrefix("box_zone") }
        #expect(zoneFiles.count == 2)
    }
}
