// A failed sidecar write must not report success (#236). annotations.json and zones.json
// failures are error results. provenance.json failures are best effort by design: the scene
// change already landed in the manifest, so the tool succeeds and says the sidecar was not
// updated. Each failure is injected by marking the sidecar immutable: it stays readable, but the
// atomic replace (or the delete) fails.

import Foundation
import OCCTSwift
import ScriptHarness
import Testing
import simd

@testable import OCCTMCPCore

@Suite("A failed sidecar write is surfaced, not swallowed", .serialized)
struct SidecarWriteFailureTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-sidecarfail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try writeScene(store, bodies)
        return store
    }

    func writeScene(_ store: ManifestStore, _ bodies: [(id: String, shape: Shape)]) throws {
        let dir = dirOf(store)
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "sidecar failures",
                bodies: bodies.map {
                    BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1])
                }))
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func setImmutable(_ path: String, _ flag: Bool) throws {
        try FileManager.default.setAttributes([.immutable: flag], ofItemAtPath: path)
    }

    func cleanup(_ store: ManifestStore, locked: [String] = []) {
        for path in locked {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
        }
        try? FileManager.default.removeItem(atPath: dirOf(store))
    }

    func box() throws -> Shape {
        try #require(Shape.box(width: 10, height: 20, depth: 30))
    }

    /// An annotations.json holding one dimension and one primitive, so it exists to be locked.
    func seedAnnotations(_ store: ManifestStore) throws -> String {
        let sidecar = AnnotationsStore(outputDir: dirOf(store))
        var doc = AnnotationsSidecar()
        doc.dimensions.append(
            .init(
                id: "d1", kind: "linear", anchors: [:], value: 1, label: nil,
                anchorPoints: [[0, 0, 0], [1, 0, 0]]))
        doc.primitives.append(.init(id: "p1", kind: "trihedron", params: [:]))
        try sidecar.write(doc)
        return sidecar.path
    }

    // MARK: - annotations.json

    @Test("add_scene_primitive: a failed annotations write is an error")
    func addScenePrimitiveFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let path = try seedAnnotations(store)
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)
        let before = try bytes(path)

        let result = await AnnotationsTools.addScenePrimitive(
            kind: .trihedron, params: [:], id: "p2", store: store)
        #expect(result.text.contains("Failed to write annotations.json"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(path) == before)
    }

    @Test("add_scene_primitive: control, an unlocked write succeeds and persists")
    func addScenePrimitiveControl() async throws {
        let store = try scene([(id: "box", shape: try box())])
        defer { cleanup(store) }
        let result = await AnnotationsTools.addScenePrimitive(
            kind: .trihedron, params: [:], id: "p2", store: store)
        #expect(!result.isError, "\(result.text)")
        let doc = AnnotationsStore(outputDir: dirOf(store)).read()
        #expect(doc.primitives.map(\.id) == ["p2"])
    }

    @Test("remove_scene_annotation: a failed annotations write is an error for a dimension and a primitive")
    func removeSceneAnnotationFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let path = try seedAnnotations(store)
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)
        let before = try bytes(path)

        let ids = ["d1", "p1"]
        #expect(ids.count == 2)
        for id in ids {
            let result = await AnnotationsTools.removeSceneAnnotation(id: id, store: store)
            #expect(result.text.contains("Failed to write annotations.json"), "\(id): \(result.text)")
            #expect(result.isError, "\(id)")
        }
        #expect(try bytes(path) == before)
    }

    @Test("add_dimension: a failed annotations write is an error for each kind")
    func addDimensionFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let path = try seedAnnotations(store)
        defer { cleanup(store, locked: [path]) }
        let registry = SelectionRegistry()
        await registry.recordPointSnapshot(
            selectionId: "pick:a", snapshot: AnchorSnapshot(center: [0, 0, 0]))
        await registry.recordPointSnapshot(
            selectionId: "pick:b", snapshot: AnchorSnapshot(center: [10, 0, 0]))
        await registry.recordPointSnapshot(
            selectionId: "pick:c", snapshot: AnchorSnapshot(center: [0, 10, 0]))
        await registry.recordPointSnapshot(
            selectionId: "pick:edge",
            snapshot: AnchorSnapshot(center: [5, 0, 0], circleCenter: [0, 0, 0]))
        try setImmutable(path, true)
        let before = try bytes(path)

        let cases: [(AnnotationsTools.DimensionKind, [String: String])] = [
            (.linear, ["from": "pick:a", "to": "pick:b"]),
            (.angular, ["armA": "pick:b", "apex": "pick:a", "armB": "pick:c"]),
            (.radial, ["circularEdge": "pick:edge"]),
        ]
        #expect(cases.count == 3)
        for (kind, anchors) in cases {
            let result = await AnnotationsTools.addDimension(
                kind: kind, anchors: anchors, id: "new", store: store, registry: registry)
            #expect(
                result.text.contains("Failed to write annotations.json"), "\(kind): \(result.text)")
            #expect(result.isError, "\(kind)")
        }
        #expect(try bytes(path) == before)
    }

    @MainActor
    @Test("show_bounding_box: a failed annotations write is an error")
    func showBoundingBoxFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let path = try seedAnnotations(store)
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)
        let before = try bytes(path)

        let result = await GapFillerTools.showBoundingBox(bodyId: "box", store: store)
        #expect(result.text.contains("Failed to write annotations.json"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(path) == before)
    }

    @MainActor
    @Test("diff_overlay: a failed annotations write is an error")
    func diffOverlayFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let path = try seedAnnotations(store)
        defer { cleanup(store, locked: [path]) }
        let history = SceneHistory()
        await history.snapshot(store: store)
        try writeScene(store, [(id: "box", shape: try box()), (id: "extra", shape: try box())])
        try setImmutable(path, true)
        let before = try bytes(path)

        let result = await GapFillerTools.diffOverlay(since: 1, store: store, history: history)
        #expect(result.text.contains("Failed to write annotations.json"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(path) == before)
    }

    // MARK: - zones.json

    func zoneRecord(_ bodyId: String, _ index: Int) -> ZoneRecord {
        ZoneRecord(
            zoneId: "zone:\(bodyId)#\(index)", bodyId: bodyId, index: index,
            triangleIndices: [0, 1, 2], areaMm2: 42,
            fit: ZoneFit(
                kind: "plane", params: [0, 0, 1, 0], residualRmsMm: 0.01, residualMaxMm: 0.02,
                inlierRatio: 1),
            params: SegmentParamsUsed(
                maxDihedralDegrees: 20, mergeRelativeTolerance: 0.004, maxMergeAngleDegrees: 50,
                minRegionTriangles: 8, maxZones: 64, deflection: 0.5),
            meshSignature: MeshSignature(
                triangleCount: 100, bboxMin: [0, 0, 0], bboxMax: [10, 10, 10])
        )
    }

    @Test("ZoneRegistry.recordBatch and clear throw when zones.json cannot be written")
    func zoneRegistryThrows() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let zonesStore = ZonesStore(outputDir: dirOf(store))
        let registry = ZoneRegistry()
        try await registry.recordBatch([zoneRecord("box", 0)], store: zonesStore)
        defer { cleanup(store, locked: [zonesStore.path]) }
        try setImmutable(zonesStore.path, true)
        let before = try bytes(zonesStore.path)

        await #expect(throws: (any Error).self) {
            try await registry.recordBatch([zoneRecord("box", 1)], store: zonesStore)
        }
        await #expect(throws: (any Error).self) {
            _ = try await registry.clear(bodyId: nil, store: zonesStore)
        }
        #expect(try bytes(zonesStore.path) == before)
    }

    @Test("clear_zones: a failed zones write is an error")
    func clearZonesFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let zonesStore = ZonesStore(outputDir: dirOf(store))
        let registry = ZoneRegistry()
        try await registry.recordBatch([zoneRecord("box", 0)], store: zonesStore)
        defer { cleanup(store, locked: [zonesStore.path]) }
        try setImmutable(zonesStore.path, true)
        let before = try bytes(zonesStore.path)

        let result = await RegistryIntrospectionTools.clearZones(
            bodyId: nil, registry: registry, store: store)
        #expect(result.text.contains("Failed to write zones.json"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(zonesStore.path) == before)
    }

    @MainActor
    @Test("segment_mesh_zones: a failed zones write is an error")
    func segmentMeshZonesFails() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let zonesStore = ZonesStore(outputDir: dirOf(store))
        // Seed zones.json with a real run so it exists to be locked.
        let seeded = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, registerZones: false, registerCap: 0,
            render: false, registry: ZoneRegistry(), store: store)
        try #require(!seeded.isError, "\(seeded.text)")
        try #require(FileManager.default.fileExists(atPath: zonesStore.path))
        defer { cleanup(store, locked: [zonesStore.path]) }
        try setImmutable(zonesStore.path, true)
        let before = try bytes(zonesStore.path)

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, registerZones: false, registerCap: 0,
            render: false, registry: ZoneRegistry(), store: store)
        #expect(result.text.contains("Failed to write zones.json"), "\(result.text)")
        #expect(result.isError)
        #expect(try bytes(zonesStore.path) == before)
    }

    // MARK: - provenance.json (best effort by design)

    func provenanceRecord() -> ProvenanceRecord {
        ProvenanceRecord(
            sourceBodyId: "box",
            transform: .mirror(planeOrigin: .zero, planeNormal: SIMD3<Double>(1, 0, 0)))
    }

    @Test("ProvenanceStore upsert, remove and clear throw when provenance.json cannot be changed")
    func provenanceStoreThrows() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let dir = dirOf(store)
        let provenance = ProvenanceStore()
        try try await provenance.upsert(bodyId: "m", record: provenanceRecord(), outputDir: dir)
        let path = "\(dir)/provenance.json"
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)
        let before = try bytes(path)

        await #expect(throws: (any Error).self) {
            try try await provenance.upsert(bodyId: "n", record: provenanceRecord(), outputDir: dir)
        }
        await #expect(throws: (any Error).self) {
            try try await provenance.remove(bodyId: "m", outputDir: dir)
        }
        await #expect(throws: (any Error).self) {
            try try await provenance.clear(outputDir: dir)
        }
        #expect(try bytes(path) == before)
    }

    @Test("remove_body: a failed provenance write still removes the body and warns")
    func removeBodyWarns() async throws {
        let store = try scene([(id: "box", shape: try box()), (id: "m", shape: try box())])
        let dir = dirOf(store)
        try await ProvenanceStore().upsert(bodyId: "m", record: provenanceRecord(), outputDir: dir)
        let path = "\(dir)/provenance.json"
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)

        let result = await SceneTools.removeBody(bodyId: "m", store: store, history: SceneHistory())
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("Warning: failed to update provenance.json"), "\(result.text)")
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.map(\.id) == ["box"])
    }

    @Test("clear_scene: a failed provenance delete still clears the scene and warns")
    func clearSceneWarns() async throws {
        let store = try scene([(id: "box", shape: try box()), (id: "m", shape: try box())])
        let dir = dirOf(store)
        try await ProvenanceStore().upsert(bodyId: "m", record: provenanceRecord(), outputDir: dir)
        let path = "\(dir)/provenance.json"
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)

        let result = await SceneTools.clearScene(store: store, history: SceneHistory())
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("Warning: failed to clear provenance.json"), "\(result.text)")
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.isEmpty)
    }

    @Test("mirror_or_pattern: a failed provenance write still adds the body and warns")
    func mirrorWarns() async throws {
        let store = try scene([(id: "box", shape: try box())])
        let dir = dirOf(store)
        try await ProvenanceStore.shared.upsert(
            bodyId: "seed", record: provenanceRecord(), outputDir: dir)
        let path = "\(dir)/provenance.json"
        defer { cleanup(store, locked: [path]) }
        try setImmutable(path, true)

        var params = ConstructionTools.PatternParams()
        params.planeOrigin = .zero
        params.planeNormal = SIMD3<Double>(1, 0, 0)
        let result = await ConstructionTools.mirrorOrPattern(
            bodyId: "box", kind: .mirror, params: params, outputBodyId: "box_mirror",
            store: store, history: SceneHistory())
        #expect(!result.isError, "\(result.text)")
        #expect(result.text.contains("Warning: failed to write provenance.json"), "\(result.text)")
        let manifest = try #require(try store.read())
        #expect(manifest.bodies.contains { $0.id == "box_mirror" })
    }
}
