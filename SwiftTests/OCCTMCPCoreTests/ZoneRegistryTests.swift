// Unit tests for ZoneRegistry: mint/resolve, persistence across a fresh
// actor instance (simulating a process restart), and MeshSignature staleness
// detection. No geometry involved — pure registry/state-machine behaviour.

import Foundation
import Testing
@testable import OCCTMCPCore

@Suite("ZoneRegistry")
struct ZoneRegistryTests {

    func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "occtmcp-zonereg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func sig(_ tri: Int = 100, min: [Double] = [0, 0, 0], max: [Double] = [10, 10, 10]) -> MeshSignature {
        MeshSignature(triangleCount: tri, bboxMin: min, bboxMax: max)
    }

    func record(_ bodyId: String, _ index: Int, tris: [Int] = [0, 1, 2]) -> ZoneRecord {
        ZoneRecord(
            zoneId: "zone:\(bodyId)#\(index)", bodyId: bodyId, index: index, triangleIndices: tris,
            areaMm2: 42, fit: ZoneFit(kind: "plane", params: [0, 0, 1, 0], residualRmsMm: 0.01, residualMaxMm: 0.02, inlierRatio: 1),
            params: SegmentParamsUsed(maxDihedralDegrees: 20, mergeRelativeTolerance: 0.004, maxMergeAngleDegrees: 50, minRegionTriangles: 8, maxZones: 64, deflection: 0.5),
            meshSignature: sig()
        )
    }

    @Test("mint + resolve: recordBatch mints, zone()/zones(forBody:)/nextIndex resolve correctly")
    func mintAndResolve() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ZonesStore(outputDir: dir)
        let registry = ZoneRegistry()

        #expect(await registry.nextIndex(bodyId: "box") == 0)

        await registry.recordBatch([record("box", 0), record("box", 1), record("other", 0)], store: store)

        #expect(await registry.nextIndex(bodyId: "box") == 2)
        #expect(await registry.nextIndex(bodyId: "other") == 1)
        #expect(await registry.nextIndex(bodyId: "unseen") == 0)

        let z0 = await registry.zone("zone:box#0")
        #expect(z0?.bodyId == "box")
        #expect(z0?.triangleIndices == [0, 1, 2])
        #expect(await registry.zone("zone:box#99") == nil)

        let boxZones = await registry.zones(forBody: "box")
        #expect(boxZones.map(\.index) == [0, 1])

        let everything = await registry.all()
        #expect(everything.count == 3)
    }

    @Test("recordBatch supersedes: re-segmenting a body with fewer zones drops the prior run's stale higher-numbered records, leaves other bodies untouched, and persists")
    func recordBatchSupersedesStaleZones() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ZonesStore(outputDir: dir)
        let registry = ZoneRegistry()

        // First segmentation: 3 zones for "box".
        await registry.recordBatch([record("box", 0), record("box", 1), record("box", 2)], store: store)
        // Another body, untouched by anything that follows.
        await registry.recordBatch([record("other", 0), record("other", 1)], store: store)
        #expect(await registry.zones(forBody: "box").count == 3)
        #expect(await registry.zones(forBody: "other").count == 2)

        // Re-segment "box" with params that yield fewer zones (same mesh,
        // different segmentation params — the case that used to leave
        // zone:box#2 stale-but-resolvable).
        await registry.recordBatch([record("box", 0), record("box", 1)], store: store)

        let boxZones = await registry.zones(forBody: "box")
        #expect(boxZones.map(\.index) == [0, 1])
        #expect(await registry.zone("zone:box#2") == nil)

        // "other" body's zones must be completely untouched.
        #expect(await registry.zones(forBody: "other").count == 2)

        // Persistence: a fresh actor instance reading the same sidecar sees
        // only the 2 superseding zones for "box", plus "other" unaffected.
        let reloaded = ZoneRegistry()
        await reloaded.loadSidecarIfNeeded(store: store)
        let reloadedBox = await reloaded.zones(forBody: "box")
        #expect(reloadedBox.map(\.zoneId).sorted() == ["zone:box#0", "zone:box#1"])
        #expect(await reloaded.zone("zone:box#2") == nil)
        #expect(await reloaded.zones(forBody: "other").count == 2)
        #expect(await reloaded.all().count == 4)
    }

    @Test("persist: a batch survives a fresh actor instance reading the same sidecar (process-restart simulation)")
    func persistsAcrossFreshInstance() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ZonesStore(outputDir: dir)

        let first = ZoneRegistry()
        await first.recordBatch([record("box", 0), record("box", 1)], store: store)

        #expect(FileManager.default.fileExists(atPath: store.path))

        // A brand-new actor instance (no in-memory state at all) pointed at
        // the SAME sidecar path must recover the prior zones on its first
        // touch, exactly the process-restart scenario the sidecar exists for.
        let reloaded = ZoneRegistry()
        await reloaded.loadSidecarIfNeeded(store: store)
        let zones = await reloaded.zones(forBody: "box")
        #expect(zones.count == 2)
        #expect(zones.map(\.zoneId).sorted() == ["zone:box#0", "zone:box#1"])
        // nextIndex must also reflect the reloaded state, not restart at 0 —
        // otherwise a restarted session would mint colliding zoneIds.
        #expect(await reloaded.nextIndex(bodyId: "box") == 2)
    }

    @Test("clear: per-body clear leaves other bodies' zones intact; nil clears everything; both persist")
    func clearScoping() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ZonesStore(outputDir: dir)
        let registry = ZoneRegistry()
        await registry.recordBatch([record("box", 0), record("box", 1), record("cyl", 0)], store: store)

        let clearedBox = await registry.clear(bodyId: "box", store: store)
        #expect(clearedBox == 2)
        #expect(await registry.zones(forBody: "box").isEmpty)
        #expect(await registry.zones(forBody: "cyl").count == 1)

        // The clear must have persisted too — a fresh instance sees the same state.
        let reloaded = ZoneRegistry()
        await reloaded.loadSidecarIfNeeded(store: store)
        #expect(await reloaded.all().count == 1)

        let clearedAll = await registry.clear(bodyId: nil, store: store)
        #expect(clearedAll == 1)
        #expect(await registry.all().isEmpty)
    }

    @Test("MeshSignature.matches: same triangleCount + bbox (within epsilon) matches; either diverging doesn't")
    func meshSignatureStaleness() {
        let a = sig(100, min: [0, 0, 0], max: [10, 10, 10])
        let sameWithinEpsilon = sig(100, min: [1e-9, 0, 0], max: [10, 10, 10 + 1e-9])
        #expect(a.matches(sameWithinEpsilon))

        let differentTriCount = sig(101, min: [0, 0, 0], max: [10, 10, 10])
        #expect(!a.matches(differentTriCount))

        let differentBbox = sig(100, min: [0, 0, 0], max: [10, 10, 12])
        #expect(!a.matches(differentBbox))
    }
}
