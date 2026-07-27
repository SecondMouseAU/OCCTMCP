// Direct unit tests for ZoneSweepTool.resolveZoneMesh (#154): the shared
// bodyId/zoneId/deflection resolution helper extracted in #153 (#134) to
// back both zone_continuity_sweep and fit_primitives had none of its six
// error cases (unknownZoneId, zoneBodyMismatch, nonPositiveDeflection,
// tessellationFailed, staleZone, subMeshExtractionFailed) or its
// deflection-mismatch warning path under direct test coverage. A
// regression here would silently break both callers at once, with nothing
// short of an integration test noticing, and neither tool had an
// integration test exercising these branches either. Exercises the helper
// directly via `@testable import OCCTMCPCore`, the same
// test-the-shared-primitive-itself approach `ZoneSweepMathTests`
// (MeshZoneToolsTests.swift) already uses for `detectRunsAndDeviations`.
//
// `tessellationFailed` is not covered here: it fires when
// `Shape.mesh(parameters:)` itself returns nil or an empty mesh, which has
// no reliable, deterministic geometric trigger available from this test
// target (unlike the other five, each reachable by constructing an
// otherwise-valid ZoneRecord/argument combination by hand).

import Foundation
import Testing
import OCCTSwift
@testable import OCCTMCPCore

@Suite("ZoneSweepTool.resolveZoneMesh: shared zoneId/deflection resolution (#154)")
struct ZoneMeshResolutionTests {

    // MARK: - Fixtures

    func freshZonesStore(_ label: String) -> ZonesStore {
        let dir = NSTemporaryDirectory() + "occtmcp-zonemesh-\(label)-\(UUID().uuidString)"
        return ZonesStore(outputDir: dir)
    }

    /// A ZoneRecord with deliberately dummy geometry (`triangleIndices`,
    /// `fit`/`params` numbers): only `bodyId`/`meshSignature`/
    /// `params.deflection` matter to the branches under test here, mirroring
    /// `SelectSweepAxisTests.record(...)` in SlippageIntegrationTests.swift.
    func fixtureRecord(
        zoneId: String, bodyId: String, deflection: Double,
        triangleIndices: [Int] = [0, 1, 2],
        meshSignature: MeshSignature
    ) -> ZoneRecord {
        ZoneRecord(
            zoneId: zoneId, bodyId: bodyId, index: 0, triangleIndices: triangleIndices, areaMm2: 1,
            fit: ZoneFit(kind: "plane", params: [], residualRmsMm: 0, residualMaxMm: 0, inlierRatio: 1),
            params: SegmentParamsUsed(
                maxDihedralDegrees: 20, mergeRelativeTolerance: 0.004, maxMergeAngleDegrees: 50,
                minRegionTriangles: 8, maxZones: 64, deflection: deflection
            ),
            meshSignature: meshSignature
        )
    }

    /// The REAL signature of `shape` meshed at `deflection` via the exact
    /// same canonical recipe `resolveZoneMesh` itself re-meshes with
    /// (`DeviationTools.standardMeshParameters`), for the tests that need
    /// the zone table to genuinely agree with what `resolveZoneMesh` will
    /// recompute (the deflection-warning and whole-body-mesh-count checks),
    /// as opposed to the staleZone/subMeshExtractionFailed tests, which
    /// deliberately disagree with it.
    func realSignature(of shape: Shape, deflection: Double) throws -> (signature: MeshSignature, triangleCount: Int) {
        let mesh = try #require(shape.mesh(parameters: DeviationTools.standardMeshParameters(deflection: deflection)))
        let bb = shape.bounds
        let sig = MeshSignature(
            triangleCount: mesh.triangleCount,
            bboxMin: [Double(bb.min.x), Double(bb.min.y), Double(bb.min.z)],
            bboxMax: [Double(bb.max.x), Double(bb.max.y), Double(bb.max.z)]
        )
        return (sig, mesh.triangleCount)
    }

    // MARK: - unknownZoneId

    @Test("a zoneId absent from the registry throws unknownZoneId, naming the id")
    func unknownZoneIdThrows() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        var warnings: [String] = []
        do {
            _ = try await ZoneSweepTool.resolveZoneMesh(
                shape: box, bodyId: "box", deflection: nil, zoneId: "zone:box#99",
                verb: "sweep", registry: ZoneRegistry(), zonesStore: freshZonesStore("unknown"),
                warnings: &warnings
            )
            Issue.record("expected unknownZoneId to throw")
        } catch let error as ZoneSweepTool.ZoneMeshResolutionError {
            guard case .unknownZoneId(let id) = error else {
                Issue.record("expected unknownZoneId, got \(error)")
                return
            }
            #expect(id == "zone:box#99")
        }
        #expect(warnings.isEmpty)
    }

    // MARK: - zoneBodyMismatch

    @Test("a zoneId registered against a different body throws zoneBodyMismatch, naming both bodies")
    func zoneBodyMismatchThrows() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let registry = ZoneRegistry()
        let zonesStore = freshZonesStore("mismatch")
        let dummySignature = MeshSignature(triangleCount: 12, bboxMin: [0, 0, 0], bboxMax: [1, 1, 1])
        let rec = fixtureRecord(zoneId: "zone:other#0", bodyId: "other", deflection: 0.5, meshSignature: dummySignature)
        await registry.recordBatch([rec], store: zonesStore)

        var warnings: [String] = []
        do {
            _ = try await ZoneSweepTool.resolveZoneMesh(
                shape: box, bodyId: "box", deflection: nil, zoneId: "zone:other#0",
                verb: "sweep", registry: registry, zonesStore: zonesStore, warnings: &warnings
            )
            Issue.record("expected zoneBodyMismatch to throw")
        } catch let error as ZoneSweepTool.ZoneMeshResolutionError {
            guard case .zoneBodyMismatch(let zoneId, let ownerBodyId, let requestedBodyId) = error else {
                Issue.record("expected zoneBodyMismatch, got \(error)")
                return
            }
            #expect(zoneId == "zone:other#0")
            #expect(ownerBodyId == "other")
            #expect(requestedBodyId == "box")
        }
        #expect(warnings.isEmpty)
    }

    // MARK: - nonPositiveDeflection

    @Test("a non-positive explicit deflection on a whole-body resolve throws nonPositiveDeflection", arguments: [0.0, -1.0])
    func nonPositiveDeflectionThrows(deflection: Double) async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        var warnings: [String] = []
        do {
            _ = try await ZoneSweepTool.resolveZoneMesh(
                shape: box, bodyId: "box", deflection: deflection, zoneId: nil,
                verb: "sweep", registry: ZoneRegistry(), zonesStore: freshZonesStore("nonpositive"),
                warnings: &warnings
            )
            Issue.record("expected nonPositiveDeflection to throw for deflection=\(deflection)")
        } catch let error as ZoneSweepTool.ZoneMeshResolutionError {
            guard case .nonPositiveDeflection = error else {
                Issue.record("expected nonPositiveDeflection, got \(error)")
                return
            }
        }
    }

    // MARK: - staleZone

    @Test("a stored MeshSignature that no longer matches the current mesh throws staleZone")
    func staleZoneThrows() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let (realSig, _) = try realSignature(of: box, deflection: 0.5)
        // Tamper with just the triangle count: the body's real mesh at this
        // same deflection will never match it again.
        let staleSig = MeshSignature(triangleCount: realSig.triangleCount + 1, bboxMin: realSig.bboxMin, bboxMax: realSig.bboxMax)
        let registry = ZoneRegistry()
        let zonesStore = freshZonesStore("stale")
        let rec = fixtureRecord(zoneId: "zone:box#0", bodyId: "box", deflection: 0.5, meshSignature: staleSig)
        await registry.recordBatch([rec], store: zonesStore)

        var warnings: [String] = []
        do {
            _ = try await ZoneSweepTool.resolveZoneMesh(
                shape: box, bodyId: "box", deflection: nil, zoneId: "zone:box#0",
                verb: "sweep", registry: registry, zonesStore: zonesStore, warnings: &warnings
            )
            Issue.record("expected staleZone to throw")
        } catch let error as ZoneSweepTool.ZoneMeshResolutionError {
            guard case .staleZone(let zoneId, let bodyId) = error else {
                Issue.record("expected staleZone, got \(error)")
                return
            }
            #expect(zoneId == "zone:box#0")
            #expect(bodyId == "box")
        }
    }

    // MARK: - subMeshExtractionFailed

    @Test("an empty triangleIndices set throws subMeshExtractionFailed rather than returning an empty mesh")
    func subMeshExtractionFailedThrows() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let (realSig, _) = try realSignature(of: box, deflection: 0.5)
        let registry = ZoneRegistry()
        let zonesStore = freshZonesStore("submesh")
        let rec = fixtureRecord(zoneId: "zone:box#0", bodyId: "box", deflection: 0.5, triangleIndices: [], meshSignature: realSig)
        await registry.recordBatch([rec], store: zonesStore)

        var warnings: [String] = []
        do {
            _ = try await ZoneSweepTool.resolveZoneMesh(
                shape: box, bodyId: "box", deflection: nil, zoneId: "zone:box#0",
                verb: "sweep", registry: registry, zonesStore: zonesStore, warnings: &warnings
            )
            Issue.record("expected subMeshExtractionFailed to throw")
        } catch let error as ZoneSweepTool.ZoneMeshResolutionError {
            guard case .subMeshExtractionFailed(let zoneId) = error else {
                Issue.record("expected subMeshExtractionFailed, got \(error)")
                return
            }
            #expect(zoneId == "zone:box#0")
        }
    }

    // MARK: - deflection-mismatch warning

    @Test(
        "a caller-supplied deflection differing from the zone's own is ignored, warned about with the calling verb, and re-meshes at the zone's own deflection",
        arguments: ["sweep", "fit"]
    )
    func deflectionMismatchWarns(verb: String) async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let zoneDeflection = 0.5
        let (sig, triangleCount) = try realSignature(of: box, deflection: zoneDeflection)
        let registry = ZoneRegistry()
        let zonesStore = freshZonesStore("mismatch-warn-\(verb)")
        let rec = fixtureRecord(
            zoneId: "zone:box#0", bodyId: "box", deflection: zoneDeflection,
            triangleIndices: Array(0..<triangleCount), meshSignature: sig
        )
        await registry.recordBatch([rec], store: zonesStore)

        var warnings: [String] = []
        let resolution = try await ZoneSweepTool.resolveZoneMesh(
            shape: box, bodyId: "box", deflection: 1.23, zoneId: "zone:box#0",
            verb: verb, registry: registry, zonesStore: zonesStore, warnings: &warnings
        )
        #expect(resolution.zoneRecord?.zoneId == "zone:box#0")
        #expect(resolution.mesh.triangleCount == triangleCount)
        #expect(warnings.count == 1)
        let warning = try #require(warnings.first)
        #expect(warning.contains("1.23"))
        #expect(warning.contains("\(zoneDeflection)"))
        #expect(warning.contains("ignored for a zoneId-scoped \(verb)"))
    }

    @Test("no caller-supplied deflection on a zoneId-scoped resolve never warns")
    func noExplicitDeflectionNoWarning() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let zoneDeflection = 0.5
        let (sig, triangleCount) = try realSignature(of: box, deflection: zoneDeflection)
        let registry = ZoneRegistry()
        let zonesStore = freshZonesStore("no-warn")
        let rec = fixtureRecord(
            zoneId: "zone:box#0", bodyId: "box", deflection: zoneDeflection,
            triangleIndices: Array(0..<triangleCount), meshSignature: sig
        )
        await registry.recordBatch([rec], store: zonesStore)

        var warnings: [String] = []
        let resolution = try await ZoneSweepTool.resolveZoneMesh(
            shape: box, bodyId: "box", deflection: nil, zoneId: "zone:box#0",
            verb: "sweep", registry: registry, zonesStore: zonesStore, warnings: &warnings
        )
        #expect(resolution.zoneRecord?.zoneId == "zone:box#0")
        #expect(warnings.isEmpty)
    }

    // MARK: - whole-body path (zoneId: nil)

    @Test("zoneId: nil resolves the whole body's mesh, zoneRecord nil, no warnings")
    func wholeBodyPathReturnsFullMesh() async throws {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let expectedDeflection = DeviationTools.defaultDeflection(for: box)
        let expectedMesh = try #require(box.mesh(parameters: DeviationTools.standardMeshParameters(deflection: expectedDeflection)))

        var warnings: [String] = []
        let resolution = try await ZoneSweepTool.resolveZoneMesh(
            shape: box, bodyId: "box", deflection: nil, zoneId: nil,
            verb: "sweep", registry: ZoneRegistry(), zonesStore: freshZonesStore("whole-body"),
            warnings: &warnings
        )
        #expect(resolution.zoneRecord == nil)
        #expect(resolution.mesh.triangleCount == expectedMesh.triangleCount)
        #expect(warnings.isEmpty)
    }
}
