// Integration test for #101/#102: a synthetic "mini carbody" fixture (a
// 100x30x20mm extruded rectangular box whose front wall has a 20mm-wide,
// 3mm-deep recess in the middle, connected by shallow 15mm ramps rather than
// a sharp step) carries the whole pipeline: import_file(stl) ->
// segment_mesh_zones -> zone_continuity_sweep -> list_zones -> clear_zones.
//
// Why ramps, not a step: segment_mesh_zones' region-growing is a real
// dihedral-angle gate (default maxDihedralDegrees=20), and a 90-degree step
// is a genuine feature boundary, not tessellation confetti the merge pass
// exists to undo — it would (correctly) split the front wall into THREE
// separate zones (before/recess/after) rather than the single zone
// zone_continuity_sweep is meant to sweep across. A shallow ramp
// (atan(3/15) =~ 11.3 degrees, comfortably under the 20 degree default)
// keeps the whole front wall growing as ONE region while still producing
// the "constant / deviation / constant" loftable-extent signature the tool
// exists to detect — this is exactly what a real panel-with-a-shallow-dent
// would segment as.
//
// The STL is hand-written as raw per-triangle vertex lines (no index
// sharing at all across triangles) to genuinely exercise the weld path
// every adjacency-based OCCTSwiftMesh primitive here depends on
// (Mesh.welded / triangleAdjacency / boundaryLoops / segmented all document
// needing a welded mesh to see real adjacency).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("mesh zone tools: mini-carbody integration (#101/#102)")
struct MeshZoneIntegrationTests {

    // MARK: - Fixture

    /// Perimeter-ordered quad -> 2 triangles, winding corrected so the face
    /// normal points (roughly) toward `outward`. `outward` only needs the
    /// right SIGN, not the exact direction — used for a tilted ramp panel too.
    static func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, outward: SIMD3<Double>)
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        let n = simd_cross(b - a, c - a)
        if simd_dot(n, outward) >= 0 {
            return [(a, b, c), (a, c, d)]
        } else {
            return [(a, c, b), (a, d, c)]
        }
    }

    /// Builds the mini-carbody as a raw triangle soup and writes it as an
    /// ASCII STL (unshared vertices, 3 fresh `vertex` lines per facet,
    /// mirroring MeshTools.writeMesh's STL writer format).
    static func writeMiniCarbodySTL(to path: String) throws {
        let W = 30.0, H = 20.0
        // (x, y) breakpoints of the front wall's profile: flat, ramp down,
        // recess flat (the "middle 20mm"), ramp up, flat.
        let bp: [(x: Double, y: Double)] = [(0, 0), (25, 0), (40, 3), (60, 3), (75, 0), (100, 0)]

        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for i in 0..<(bp.count - 1) {
            let a = bp[i], b = bp[i + 1]
            tris += quad(SIMD3(a.x, a.y, 0), SIMD3(b.x, b.y, 0), SIMD3(b.x, b.y, H), SIMD3(a.x, a.y, H), outward: SIMD3(0, -1, 0))
        }
        for i in 0..<(bp.count - 1) {
            let a = bp[i], b = bp[i + 1]
            tris += quad(SIMD3(a.x, a.y, H), SIMD3(b.x, b.y, H), SIMD3(b.x, W, H), SIMD3(a.x, W, H), outward: SIMD3(0, 0, 1))
        }
        for i in 0..<(bp.count - 1) {
            let a = bp[i], b = bp[i + 1]
            tris += quad(SIMD3(a.x, a.y, 0), SIMD3(b.x, b.y, 0), SIMD3(b.x, W, 0), SIMD3(a.x, W, 0), outward: SIMD3(0, 0, -1))
        }
        tris += quad(SIMD3(0, W, 0), SIMD3(100, W, 0), SIMD3(100, W, H), SIMD3(0, W, H), outward: SIMD3(0, 1, 0))
        tris += quad(SIMD3(0, 0, 0), SIMD3(0, W, 0), SIMD3(0, W, H), SIMD3(0, 0, H), outward: SIMD3(-1, 0, 0))
        tris += quad(SIMD3(100, 0, 0), SIMD3(100, W, 0), SIMD3(100, W, H), SIMD3(100, 0, H), outward: SIMD3(1, 0, 0))

        var out = "solid minicarbody\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid minicarbody\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func freshScene() throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-zoneit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "mini carbody", bodies: []))
        return (store, dir)
    }

    // MARK: - Decodable mirrors

    struct ZoneReport: Decodable {
        struct Entry: Decodable {
            let id: String
            let triangleCount: Int
            let meanNormal: [Double]
        }
        let bodyId: String
        let zoneCount: Int
        let zones: [Entry]
        let registeredBodyIds: [String]?
        let warnings: [String]
    }
    struct SweepReport: Decodable {
        struct Run: Decodable {
            let startAxisCoord: Double
            let endAxisCoord: Double
            let stationCount: Int
            let kind: String
            let maxProfileRmsMm: Double
            let maxLateralOffsetMm: Double
        }
        struct Station: Decodable {
            let index: Int
            let axisCoord: Double
            let verdict: String
            let openProfile: Bool
        }
        let axisSource: String
        let overlap: [Double]
        let stations: [Station]
        let runs: [Run]
        let warnings: [String]
    }
    struct ListZonesReport: Decodable {
        struct Summary: Decodable { let zoneId: String; let bodyId: String }
        let count: Int
        let zones: [Summary]
    }
    struct ClearZonesReport: Decodable { let cleared: Int }
    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    @MainActor
    @Test("import -> segment -> sweep -> list -> clear: full pipeline on the mini-carbody fixture")
    func fullPipeline() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let stlPath = "\(dir)/minicarbody.stl"
        try Self.writeMiniCarbodySTL(to: stlPath)

        // ── import_file ──────────────────────────────────────────────
        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "carbody", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)
        #expect(bodyId == "carbody")

        // ── segment_mesh_zones (registerZones exercised with a cap) ────
        let registry = ZoneRegistry()
        let segResult = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, registerZones: true, registerCap: 3,
            render: false, registry: registry, store: store
        )
        #expect(!segResult.isError, "segment_mesh_zones failed: \(segResult.text)")
        let zr = try JSONDecoder().decode(ZoneReport.self, from: Data(segResult.text.utf8))

        // Six logical faces: front (a single zone despite the ramped
        // recess), top, bottom, back, left cap, right cap.
        #expect(zr.zoneCount == 6)
        let registered = try #require(zr.registeredBodyIds)
        #expect(registered.count == 3, "registerCap=3 should cap registration")
        #expect(zr.warnings.contains { $0.contains("registerCap=3") })

        // Identify the front-wall zone by its mean normal (strongly -Y) —
        // NOT by array position, which depends on OCCT's own face ordering
        // after the STL round-trip, not this test's triangle emission order.
        let front = try #require(zr.zones.first { $0.meanNormal.count == 3 && $0.meanNormal[1] < -0.5 })
        #expect(front.triangleCount == 10, "5 front-wall segments x 2 triangles")

        // ── zone_continuity_sweep on the front zone, explicit axis ──────
        let sweepResult = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, zoneId: front.id, axis: SIMD3(1, 0, 0), stations: 32,
            render: false, registry: registry, store: store
        )
        #expect(!sweepResult.isError, "zone_continuity_sweep failed: \(sweepResult.text)")
        let sr = try JSONDecoder().decode(SweepReport.self, from: Data(sweepResult.text.utf8))

        #expect(sr.axisSource == "explicit")
        #expect(sr.warnings.filter { $0.contains("missed the zone") }.isEmpty, "the front zone spans the whole axis; no station should miss it")
        #expect(sr.stations.allSatisfy { $0.openProfile }, "a single-wall zone slice is always an open 2-point segment, never a closed loop")

        // constant (flat1) -> deviation (ramp + recess + ramp) -> constant (flat2).
        #expect(sr.runs.map(\.kind) == ["constant", "deviation", "constant"], "runs: \(sr.runs)")
        let deviation = sr.runs[1]
        // The recess is 3mm deep; the deviation interval's peak lateral
        // offset should read close to that (ramps only ever partially
        // deviate, so the PEAK — reached during the recess's flat bottom —
        // is what should approach 3mm).
        #expect(deviation.maxLateralOffsetMm > 2.0 && deviation.maxLateralOffsetMm < 3.3,
                "expected ~3mm peak offset, got \(deviation.maxLateralOffsetMm)")
        // The recess's true flat extent is x in [40,60]; ramps push the
        // detected (tolerance-crossing) interval a bit wider, generously
        // bounded here rather than pinned to an exact station.
        #expect(deviation.startAxisCoord > 15 && deviation.startAxisCoord < 40, "deviation start: \(deviation.startAxisCoord)")
        #expect(deviation.endAxisCoord > 60 && deviation.endAxisCoord < 85, "deviation end: \(deviation.endAxisCoord)")
        #expect(sr.runs[0].endAxisCoord < deviation.startAxisCoord)
        #expect(deviation.endAxisCoord < sr.runs[2].startAxisCoord)
        // The flanking runs are genuinely flat: near-zero peak signal.
        #expect(sr.runs[0].maxLateralOffsetMm < 0.5)
        #expect(sr.runs[2].maxLateralOffsetMm < 0.5)

        // ── list_zones ───────────────────────────────────────────────
        let listResult = await RegistryIntrospectionTools.listZones(bodyId: bodyId, registry: registry, store: store)
        let lr = try JSONDecoder().decode(ListZonesReport.self, from: Data(listResult.text.utf8))
        #expect(lr.count == 6)
        #expect(lr.zones.allSatisfy { $0.bodyId == bodyId })

        // ── clear_zones ──────────────────────────────────────────────
        let clearResult = await RegistryIntrospectionTools.clearZones(bodyId: bodyId, registry: registry, store: store)
        let cr = try JSONDecoder().decode(ClearZonesReport.self, from: Data(clearResult.text.utf8))
        #expect(cr.cleared == 6)

        let listAfterClear = await RegistryIntrospectionTools.listZones(bodyId: bodyId, registry: registry, store: store)
        let lrAfter = try JSONDecoder().decode(ListZonesReport.self, from: Data(listAfterClear.text.utf8))
        #expect(lrAfter.count == 0)

        // A stale zoneId (from before the clear) now resolves to nothing —
        // zone_continuity_sweep should error clearly, not crash or silently
        // sweep the whole body.
        let staleSweep = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, zoneId: front.id, render: false, registry: registry, store: store
        )
        #expect(staleSweep.isError)
    }

    @MainActor
    @Test("zone_continuity_sweep on the WHOLE body (no zoneId) still resolves and slices closed loops")
    func wholeBodySweepIsClosedLoops() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/minicarbody.stl"
        try Self.writeMiniCarbodySTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "carbody2", store: store, history: SceneHistory()
        )
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let sweepResult = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, axis: SIMD3(1, 0, 0), stations: 16, render: false, store: store
        )
        #expect(!sweepResult.isError, "unexpected error: \(sweepResult.text)")
        let sr = try JSONDecoder().decode(SweepReport.self, from: Data(sweepResult.text.utf8))
        // The whole solid's cross-section at any interior station is a
        // closed rectangular ring, unlike the single-wall zone slice above.
        #expect(sr.stations.contains { !$0.openProfile })
    }
}
