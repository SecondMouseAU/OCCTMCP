// Unit tests for segment_mesh_zones' JSON shaping on a scripted box (no scan
// fixture needed: a box's 6 planar faces meet at 90-degree edges, well past
// both the default growing threshold (20 deg) and the merge-eligibility gate
// (50 deg), so each face segments as its own zone deterministically) and for
// ZoneSweepTool.detectRunsAndDeviations' pure change-point logic on synthetic
// per-station signals (no geometry at all).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("segment_mesh_zones: zone table shaping")
struct MeshZoneToolsTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-zonetools-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "zonetools", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    struct ZoneReport: Decodable {
        struct Entry: Decodable {
            struct BBox: Decodable { let min: [Double]; let max: [Double] }
            struct Fit: Decodable { let kind: String; let residualRmsMm: Double; let inlierRatio: Double }
            let id: String
            let triangleCount: Int
            let areaMm2: Double
            let areaFraction: Double
            let bbox: BBox
            let meanNormal: [Double]
            let boundaryLoops: Int
            let adjacentZones: [String]
            let fit: Fit
        }
        let bodyId: String
        let zoneCount: Int
        let truncatedTriangleCount: Int
        let zones: [Entry]
        let renderPath: String?
        let registeredBodyIds: [String]?
        let warnings: [String]
    }

    @MainActor
    @Test("a box segments into 6 planar zones, largest-first order preserved, ids stable, adjacency populated")
    func boxSegmentsIntoSixZones() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])
        let registry = ZoneRegistry()

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ZoneReport.self, from: Data(result.text.utf8))

        #expect(r.bodyId == "box")
        #expect(r.zoneCount == 6)
        #expect(r.truncatedTriangleCount == 0)
        #expect(r.zones.count == 6)
        #expect(r.renderPath == nil)   // render: false
        #expect(r.registeredBodyIds == nil)   // registerZones defaults false

        // Ids are the documented zone:<bodyId>#<n> shape, minted in the same
        // (largest-first) order SegmentedMesh.regions returns.
        for (i, zone) in r.zones.enumerated() {
            #expect(zone.id == "zone:box#\(i)")
        }
        let counts = r.zones.map(\.triangleCount)
        #expect(counts == counts.sorted(by: >), "zones must be largest-first")

        // Every zone is a flat box face: plane fit, near-zero residual, full inlier ratio.
        for zone in r.zones {
            #expect(zone.fit.kind == "plane")
            #expect(zone.fit.residualRmsMm < 1e-3)
            #expect(zone.fit.inlierRatio > 0.99)
            #expect(zone.triangleCount >= 2)
            #expect(zone.areaMm2 > 0)
            #expect(zone.areaFraction > 0 && zone.areaFraction < 1)
            #expect(zone.boundaryLoops == 1, "a single box face's submesh has exactly one boundary loop")
            // A box face is adjacent to 4 of the other 5 faces (all but the
            // opposite, parallel one) — proves the adjacency computation ran
            // (didn't fall back to the "welding dropped triangles" warning).
            #expect(zone.adjacentZones.count == 4, "expected 4 adjacent faces, got \(zone.adjacentZones)")
        }

        // Area fractions across all 6 faces should sum to ~1 (no truncation).
        let totalFraction = r.zones.reduce(0) { $0 + $1.areaFraction }
        #expect(abs(totalFraction - 1) < 1e-6)

        // Box surface area = 2*(10*20 + 10*30 + 20*30) = 2200 mm^2.
        let totalArea = r.zones.reduce(0) { $0 + $1.areaMm2 }
        #expect(abs(totalArea - 2200) < 1)

        // zones.json sidecar was written and is resolvable from a fresh registry.
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let reloaded = ZoneRegistry()
        await reloaded.loadSidecarIfNeeded(store: ZonesStore(outputDir: outputDir))
        #expect(await reloaded.zones(forBody: "box").count == 6)
    }

    @MainActor
    @Test("maxZones truncates and reports it; minRegionTriangles drops small regions and reports it")
    func truncationIsAlwaysReported() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        let capped = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, maxZones: 3, render: false, registry: ZoneRegistry(), store: store
        )
        let r = try JSONDecoder().decode(ZoneReport.self, from: Data(capped.text.utf8))
        #expect(r.zoneCount == 3)
        #expect(r.truncatedTriangleCount > 0)
        #expect(r.warnings.contains { $0.contains("maxZones=3") })
    }

    @MainActor
    @Test("registerZones registers capped scene bodies, largest-first, and warns on truncation")
    func registerZonesRespectsCap() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([(id: "box", shape: box)])

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, registerZones: true, registerCap: 2,
            render: false, registry: ZoneRegistry(), store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ZoneReport.self, from: Data(result.text.utf8))
        #expect(r.zoneCount == 6)
        let ids = try #require(r.registeredBodyIds)
        #expect(ids == ["box_zone0", "box_zone1"])
        #expect(r.warnings.contains { $0.contains("registerCap=2") })

        let manifest = try #require(try store.read())
        #expect(manifest.bodies.contains { $0.id == "box_zone0" })
        #expect(manifest.bodies.contains { $0.id == "box_zone1" })
        #expect(!manifest.bodies.contains { $0.id == "box_zone2" })
    }
}

@Suite("zone_continuity_sweep: change-point logic (pure)")
struct ZoneSweepMathTests {

    /// Synthetic signals from a plain offset array: station i's "profile" is
    /// just `offsets[i]`, and the comparison between any two stations is the
    /// absolute difference of their offsets. No geometry, no meshing —
    /// exactly the "pure function... testable without geometry" the plan
    /// calls for.
    func signalsFrom(_ offsets: [Double]) -> (Int, Int) -> ZoneSweepTool.Signals? {
        return { ref, cand in
            ZoneSweepTool.Signals(
                lateralOffsetMm: abs(offsets[cand] - offsets[ref]),
                profileRmsMm: 0, profileMaxMm: 0, arcLengthDeltaMm: 0
            )
        }
    }

    @Test("constant, deviation, constant: a mid-span plateau reads as one deviation interval")
    func constantDeviationConstant() {
        // 10 stations: flat (0) for 0-2, plateau (3.0) for 3-6, flat (0) for 7-9 —
        // mirrors the mini-carbody fixture's recess shape.
        let offsets = [0.0, 0.0, 0.0, 3.0, 3.0, 3.0, 3.0, 0.0, 0.0, 0.0]
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: offsets.count, missed: { _ in false }, signals: signalsFrom(offsets),
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        #expect(verdicts.map(\.rawValue) == ["constant", "constant", "constant", "deviating", "deviating", "deviating", "deviating", "constant", "constant", "constant"])
        #expect(runs.count == 3)
        #expect(runs[0].kind == "constant" && runs[0].startIndex == 0 && runs[0].endIndex == 2)
        #expect(runs[1].kind == "deviation" && runs[1].startIndex == 3 && runs[1].endIndex == 6)
        #expect(runs[2].kind == "constant" && runs[2].startIndex == 7 && runs[2].endIndex == 9)
    }

    @Test("all constant: a single run spans the whole sweep")
    func allConstant() {
        let offsets = [Double](repeating: 0.1, count: 8)
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: offsets.count, missed: { _ in false }, signals: signalsFrom(offsets),
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        #expect(verdicts.allSatisfy { $0 == .constant })
        #expect(runs.count == 1)
        #expect(runs[0].kind == "constant")
        #expect(runs[0].startIndex == 0 && runs[0].endIndex == 7)
    }

    @Test("missed stations are excluded from runs but don't break the surrounding ones")
    func missedStationsExcluded() {
        // Station 2 is missed (no profile there); everything else is flat.
        let offsets = [0.0, 0.0, 999.0, 0.0, 0.0]
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: offsets.count,
            missed: { $0 == 2 },
            signals: signalsFrom(offsets),
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        #expect(verdicts[2] == .missed)
        #expect(runs.count == 1)
        #expect(runs[0].kind == "constant")
        #expect(runs[0].startIndex == 0 && runs[0].endIndex == 4)
    }

    @Test("two separate excursions produce two separate deviation intervals, each with its own fresh reference")
    func twoExcursionsGiveTwoIntervals() {
        let offsets = [0.0, 0.0, 5.0, 0.0, 0.0, -4.0, 0.0, 0.0]
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: offsets.count, missed: { _ in false }, signals: signalsFrom(offsets),
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        _ = verdicts
        #expect(runs.map(\.kind) == ["constant", "deviation", "constant", "deviation", "constant"])
        #expect(runs[1].startIndex == 2 && runs[1].endIndex == 2)
        #expect(runs[3].startIndex == 5 && runs[3].endIndex == 5)
    }

    @Test("an incomparable pair (signals returns nil) is treated as deviating, never silently constant")
    func incomparablePairIsConservative() {
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: 3, missed: { _ in false },
            signals: { ref, cand in cand == 1 ? nil : ZoneSweepTool.Signals(lateralOffsetMm: 0, profileRmsMm: 0, profileMaxMm: 0, arcLengthDeltaMm: 0) },
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        #expect(verdicts[1] == .deviating)
        #expect(runs.map(\.kind) == ["constant", "deviation", "constant"])
    }

    @Test("every station missed: no runs, every verdict missed")
    func everyStationMissed() {
        let (verdicts, runs) = ZoneSweepTool.detectRunsAndDeviations(
            stationCount: 4, missed: { _ in true }, signals: { _, _ in nil },
            toleranceMm: 0.5, lateralToleranceMm: 0.5
        )
        #expect(verdicts.allSatisfy { $0 == .missed })
        #expect(runs.isEmpty)
    }
}
