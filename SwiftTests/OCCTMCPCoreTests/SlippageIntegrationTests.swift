// Tests for #109: slippage integration into segment_mesh_zones (per-zone
// `slippage` classification via OCCTSwiftMesh's `Mesh.slippage(forTriangles:
// maxSamples:)`, OCCTSwiftMesh#26/#31) and zone_continuity_sweep (defaulting
// the sweep axis to a qualifying zone's slippage axis).
//
// Fixtures:
//   - a hand-written "panel cube": 6 flat square panels positioned like a
//     cube's faces but each INSET from the true edges by a small gap, so no
//     two panels share a vertex. This matters: a genuinely CLOSED box (the
//     scripted `Shape.box()` fixture the OTHER zone tools tests use) welds
//     all 6 faces into one connected mesh, and `vertexNormals()` at a
//     shared edge/corner vertex averages ACROSS the adjacent, differently
//     oriented faces — contaminating a face-region's own sample set with
//     blended normals that aren't this face's true (flat) normal at all.
//     Empirically (this file's development) that contamination was enough
//     to make a plain box's own faces misclassify as sphere/revolution/
//     freeform depending on grid resolution, even though each face is
//     perfectly flat: an OCCTSwiftMesh consumer detail worth documenting,
//     not a bug in this integration. Disjoint (non-touching) panels sidestep
//     it entirely: no shared vertices, no cross-face normal blending, at any
//     resolution. Also empirically, panel ASPECT RATIO matters independent
//     of the above (an elongated rectangular panel — the box's original
//     10x20x30 asymmetric dimensions in particular — could misclassify too,
//     matching the upstream docs' own "Elongated regions" caveat about
//     isotropic normalization on far-from-square patches); square panels
//     (a cube) sidestep that too. `Shape.box()` itself was also ruled out
//     independently: OCCT tessellates a flat quad face as just 2 triangles
//     (4 vertices) regardless of deflection/size, below the algorithm's
//     6-sample floor.
//   - a hand-written multi-ring, multi-segment OPEN cylindrical shell
//     ("tube barrel"), written the same way MeshZoneIntegrationTests writes
//     its mini-carbody: raw unshared-vertex triangle soup, so the import
//     path genuinely produces a soup and exercises the SAME welded-mesh +
//     triangle-count guard `adjacentZones` already relies on. Multiple
//     Z-rings (not a single quad strip / fan), per upstream's own fixture
//     notes (docs/algorithms/slippage.md) about degenerate point sets
//     leaving the discrete covariance's near-zero eigenvalues far from
//     where a continuous surface would put them.
//   - the mini-carbody fixture from MeshZoneIntegrationTests, reused as-is,
//     for the "a plane zone never uses its slippage axis" sweep case.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("segment_mesh_zones: slippage classification (#109)")
struct SlippageClassificationTests {

    // MARK: - Fixtures

    func freshScene(_ label: String) throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-slippage-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: label, bodies: []))
        return (store, dir)
    }

    /// 6 flat SQUARE panels positioned like a cube's faces, each inset by
    /// `gap` from the true cube edges so no two panels share a vertex (see
    /// the file header for why: shared-edge normal blending and elongated
    /// aspect ratios both corrupt plane classification, and disjoint square
    /// panels sidestep both). Written as raw unshared triangle soup, same
    /// convention as `writeOpenTubeSTL`/`MeshZoneIntegrationTests.
    /// writeMiniCarbodySTL`.
    static func writeDisjointPanelCubeSTL(to path: String, size: Double = 30, gridN: Int = 6, gap: Double = 2) throws {
        func gridQuads(
            originU: Double, sizeUV: Double, originV: Double,
            toPoint: (Double, Double) -> SIMD3<Double>, outward: SIMD3<Double>
        ) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
            var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
            let coords = (0...gridN).map { originU + sizeUV * Double($0) / Double(gridN) }
            for i in 0..<gridN {
                for j in 0..<gridN {
                    let p00 = toPoint(coords[i], coords[j]), p10 = toPoint(coords[i + 1], coords[j])
                    let p11 = toPoint(coords[i + 1], coords[j + 1]), p01 = toPoint(coords[i], coords[j + 1])
                    tris += MeshZoneIntegrationTests.quad(p00, p10, p11, p01, outward: outward)
                }
            }
            return tris
        }
        let lo = gap, hi = size - gap, extent = hi - lo
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(u, v, 0) }, outward: SIMD3(0, 0, -1))
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(u, v, size) }, outward: SIMD3(0, 0, 1))
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(u, 0, v) }, outward: SIMD3(0, -1, 0))
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(u, size, v) }, outward: SIMD3(0, 1, 0))
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(0, u, v) }, outward: SIMD3(-1, 0, 0))
        tris += gridQuads(originU: lo, sizeUV: extent, originV: lo, toPoint: { u, v in SIMD3(size, u, v) }, outward: SIMD3(1, 0, 0))

        var out = "solid panelcube\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid panelcube\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A multi-ring, multi-segment OPEN cylindrical shell (no end caps),
    /// i.e. just the barrel of a tube, radius constant along the axis.
    /// Written as raw unshared triangle soup (mirrors
    /// MeshZoneIntegrationTests.writeMiniCarbodySTL) so the import path
    /// produces a genuine soup and the weld guard both `adjacentZones` and
    /// `slippage` depend on has something real to do.
    static func writeOpenTubeSTL(
        to path: String, radius: Double = 15, height: Double = 40, segments: Int = 24, rings: Int = 6
    ) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for ring in 0..<(rings - 1) {
            let z0 = height * Double(ring) / Double(rings - 1)
            let z1 = height * Double(ring + 1) / Double(rings - 1)
            for seg in 0..<segments {
                let a0 = 2 * Double.pi * Double(seg) / Double(segments)
                let a1 = 2 * Double.pi * Double(seg + 1) / Double(segments)
                let p00 = SIMD3(radius * cos(a0), radius * sin(a0), z0)
                let p10 = SIMD3(radius * cos(a1), radius * sin(a1), z0)
                let p11 = SIMD3(radius * cos(a1), radius * sin(a1), z1)
                let p01 = SIMD3(radius * cos(a0), radius * sin(a0), z1)
                let mid = (a0 + a1) / 2
                let outward = SIMD3(cos(mid), sin(mid), 0.0)
                tris += MeshZoneIntegrationTests.quad(p00, p10, p11, p01, outward: outward)
            }
        }
        var out = "solid opentube\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid opentube\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Decodable mirrors

    struct SlippageEntry: Decodable {
        let kind: String
        let axisPoint: [Double]?
        let axisDirection: [Double]?
        let pitchPerRadianMm: Double?
        let confidence: Double
    }
    struct ZoneEntry: Decodable {
        struct Fit: Decodable { let kind: String }
        let id: String
        let triangleCount: Int
        let meanNormal: [Double]
        let fit: Fit
        let slippage: SlippageEntry?
    }
    struct ZoneReport: Decodable {
        let bodyId: String
        let zoneCount: Int
        let zones: [ZoneEntry]
        let warnings: [String]
    }
    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    // MARK: - Tests

    @MainActor
    @Test("box (panel cube): every zone's slippage classifies as plane, axis parallel to the face normal, confidence sensible")
    func boxZonesClassifyPlane() async throws {
        let (store, dir) = try freshScene("box")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/panelcube.stl"
        try Self.writeDisjointPanelCubeSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "box", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: ZoneRegistry(), store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ZoneReport.self, from: Data(result.text.utf8))
        #expect(r.zoneCount == 6)

        for zone in r.zones {
            let slip = try #require(zone.slippage, "zone \(zone.id) missing slippage")
            #expect(slip.kind == "plane", "zone \(zone.id): expected plane, got \(slip.kind)")
            #expect(slip.confidence > 0.25, "zone \(zone.id): unexpectedly low confidence \(slip.confidence)")
            let dir = try #require(slip.axisDirection, "zone \(zone.id): plane must have an axisDirection")
            #expect(dir.count == 3)
            let a = simd_normalize(SIMD3(dir[0], dir[1], dir[2]))
            let n = simd_normalize(SIMD3(zone.meanNormal[0], zone.meanNormal[1], zone.meanNormal[2]))
            let dot = abs(simd_dot(a, n))
            #expect(dot > 0.99, "zone \(zone.id): slippage axis not parallel to face normal, |dot|=\(dot)")
        }
    }

    @MainActor
    @Test("imported multi-ring open tube: the barrel zone classifies as cylinder with axis matching the tube's own axis")
    func tubeBarrelClassifiesCylinder() async throws {
        let (store, dir) = try freshScene("tube")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/tube.stl"
        try Self.writeOpenTubeSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "tube", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: ZoneRegistry(), store: store
        )
        #expect(!result.isError, "segment_mesh_zones failed: \(result.text)")
        let r = try JSONDecoder().decode(ZoneReport.self, from: Data(result.text.utf8))

        // The lateral surface is a single dihedral-continuous region (the
        // circumferential turn angle 360/24=15deg is under the default
        // 20deg growing threshold; adjacent Z-bands are exactly coplanar) —
        // pick the largest zone rather than assuming index 0, since OCCT's
        // own face ordering after the STL round-trip isn't this test's to
        // dictate.
        let barrel = try #require(r.zones.max(by: { $0.triangleCount < $1.triangleCount }))
        let slip = try #require(barrel.slippage, "barrel zone missing slippage")
        #expect(slip.kind == "cylinder", "expected cylinder, got \(slip.kind) (fit.kind=\(barrel.fit.kind))")
        let axisDir = try #require(slip.axisDirection)
        let a = simd_normalize(SIMD3(axisDir[0], axisDir[1], axisDir[2]))
        let tubeAxis = SIMD3<Double>(0, 0, 1)
        #expect(abs(simd_dot(a, tubeAxis)) > 0.98, "recovered axis \(a) not aligned with the tube's own Z axis")
    }
}

@Suite("zone_continuity_sweep: slippage axis default (#109)")
struct SlippageSweepAxisTests {

    struct SlippageEntry: Decodable {
        let kind: String
        let axisDirection: [Double]?
        let confidence: Double
    }
    struct ZoneEntry: Decodable {
        let id: String
        let triangleCount: Int
        let meanNormal: [Double]
        let slippage: SlippageEntry?
    }
    struct ZoneReport: Decodable {
        let zoneCount: Int
        let zones: [ZoneEntry]
    }
    struct SweepReport: Decodable {
        let axisSource: String
        let axis: [Double]
        let warnings: [String]
    }
    struct ImportReport: Decodable { let addedBodyIds: [String] }

    func freshScene(_ label: String) throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-slippagesweep-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: label, bodies: []))
        return (store, dir)
    }

    @MainActor
    @Test("tube barrel: no axis argument defaults to the zone's stored slippage axis; explicit axis still overrides")
    func tubeSweepDefaultsToSlippageAxisUnlessExplicit() async throws {
        let (store, dir) = try freshScene("tube")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/tube.stl"
        try SlippageClassificationTests.writeOpenTubeSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "tube", store: store, history: SceneHistory()
        )
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let registry = ZoneRegistry()
        let segResult = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!segResult.isError, "segment_mesh_zones failed: \(segResult.text)")
        let seg = try JSONDecoder().decode(ZoneReport.self, from: Data(segResult.text.utf8))
        let barrel = try #require(seg.zones.max(by: { $0.triangleCount < $1.triangleCount }))
        let storedSlip = try #require(barrel.slippage)
        #expect(storedSlip.kind == "cylinder")
        let storedAxis = try #require(storedSlip.axisDirection)
        #expect(storedSlip.confidence >= 0.25, "fixture must clear the sweep's own confidence floor to exercise the slippage rung")

        // No axis argument: should default to the stored slippage axis.
        let sweepNoAxis = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, zoneId: barrel.id, render: false, registry: registry, store: store
        )
        #expect(!sweepNoAxis.isError, "unexpected error: \(sweepNoAxis.text)")
        let srNoAxis = try JSONDecoder().decode(SweepReport.self, from: Data(sweepNoAxis.text.utf8))
        #expect(srNoAxis.axisSource == "slippage")
        #expect(srNoAxis.axis.count == 3)
        let dot = abs(storedAxis[0] * srNoAxis.axis[0] + storedAxis[1] * srNoAxis.axis[1] + storedAxis[2] * srNoAxis.axis[2])
        #expect(dot > 0.999, "sweep axis \(srNoAxis.axis) doesn't match the stored slippage axis \(storedAxis)")

        // Explicit axis argument still overrides everything.
        let sweepExplicit = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, zoneId: barrel.id, axis: SIMD3(1, 0, 0), render: false, registry: registry, store: store
        )
        #expect(!sweepExplicit.isError, "unexpected error: \(sweepExplicit.text)")
        let srExplicit = try JSONDecoder().decode(SweepReport.self, from: Data(sweepExplicit.text.utf8))
        #expect(srExplicit.axisSource == "explicit")
        #expect(srExplicit.axis == [1, 0, 0])
    }

    @MainActor
    @Test("mini-carbody plane zone: sweep never defaults to the slippage axis (the surface normal); PCA is used instead")
    func planeZoneSweepUsesPCA() async throws {
        let (store, dir) = try freshScene("carbody")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/carbody.stl"
        try MeshZoneIntegrationTests.writeMiniCarbodySTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "carbody", store: store, history: SceneHistory()
        )
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let registry = ZoneRegistry()
        let segResult = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!segResult.isError, "segment_mesh_zones failed: \(segResult.text)")
        let seg = try JSONDecoder().decode(ZoneReport.self, from: Data(segResult.text.utf8))
        // The TOP face (roof), not the front wall: the mini-carbody is a
        // genuinely CLOSED box (shared edges between all 6 faces, same as
        // the closed-box construction the file header documents as
        // contaminating vertexNormals() at shared edges/corners with
        // blended, non-representative normals). Empirically that leaves the
        // front wall's OWN classification unreliable here (it's a genuine
        // translational-symmetry-along-Z extrusion, but this fixture's
        // shared-edge contamination reads it as "helix" instead) — a real
        // OCCTSwiftMesh-consumer characteristic of this specific closed,
        // low-resolution fixture, not a bug in the axis-selection rule this
        // test exists to check. The roof is unambiguous either way: it is
        // flat with no ramp at all, so whatever its own slippage kind comes
        // out as on this fixture, it is never a genuine cylinder/extrusion/
        // revolution/helix, which is exactly what this test needs: proof
        // that a NON axis-eligible zone (a plane, in the textbook case; see
        // the panel-cube test above for a clean, uncontaminated plane
        // reading) never defaults the sweep axis to its own slippage axis.
        let top = try #require(seg.zones.first { $0.meanNormal.count == 3 && $0.meanNormal[2] > 0.5 })
        #expect(top.slippage.map { !["cylinder", "extrusion", "revolution", "helix"].contains($0.kind) } ?? true,
                "test premise broken: top face unexpectedly read as an axis-eligible kind (\(top.slippage?.kind ?? "nil"))")

        let sweep = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId, zoneId: top.id, render: false, registry: registry, store: store
        )
        #expect(!sweep.isError, "unexpected error: \(sweep.text)")
        let sr = try JSONDecoder().decode(SweepReport.self, from: Data(sweep.text.utf8))
        #expect(sr.axisSource == "pca")
    }

    @MainActor
    @Test("old-format zones.json record (no slippage key): decodes fine, sweep falls back to PCA cleanly")
    func oldFormatSidecarCompatibility() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-slippagesweep-oldformat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let descriptor = BodyDescriptor(id: "box", file: "box.brep", color: [1, 1, 1, 1])
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "old-format sidecar", bodies: [descriptor])
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/box.brep"))

        let registry = ZoneRegistry()
        let segResult = await MeshZoneTools.segmentMeshZones(
            bodyId: "box", minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!segResult.isError, "segment_mesh_zones failed: \(segResult.text)")
        let seg = try JSONDecoder().decode(ZoneReport.self, from: Data(segResult.text.utf8))
        let zoneId = try #require(seg.zones.first?.id)

        // Simulate a pre-#109 zones.json by stripping the "slippage" key
        // from every zone record BY HAND (raw JSON manipulation, not by
        // constructing a ZoneRecord in Swift with slippage: nil) — this is
        // what genuinely exercises the "missing key" decode path an actual
        // old sidecar file would hit, as opposed to a present-but-null key.
        let zonesPath = "\(dir)/zones.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: zonesPath))
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var zones = try #require(root["zones"] as? [[String: Any]])
        for i in zones.indices { zones[i].removeValue(forKey: "slippage") }
        root["zones"] = zones
        let stripped = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try stripped.write(to: URL(fileURLWithPath: zonesPath), options: .atomic)

        // A FRESH registry, forced to decode the stripped (old-format) sidecar.
        let reloaded = ZoneRegistry()
        await reloaded.loadSidecarIfNeeded(store: ZonesStore(path: zonesPath))
        let record = try #require(await reloaded.zone(zoneId), "old-format zone record failed to decode at all")
        #expect(record.slippage == nil)
        #expect(record.zoneId == zoneId)   // other fields intact

        // zone_continuity_sweep against the stripped registry must still
        // work cleanly, falling back to PCA (no crash, no error).
        let sweep = await ZoneSweepTool.zoneContinuitySweep(
            bodyId: "box", zoneId: zoneId, render: false, registry: reloaded, store: store
        )
        #expect(!sweep.isError, "unexpected error: \(sweep.text)")
        let sr = try JSONDecoder().decode(SweepReport.self, from: Data(sweep.text.utf8))
        #expect(sr.axisSource == "pca")
    }
}

@Suite("ZoneSweepTool.selectSweepAxis: pure axis-selection logic (#109)")
struct SelectSweepAxisTests {

    func record(kind: String, axisDirection: [Double]?, confidence: Double) -> ZoneRecord {
        ZoneRecord(
            zoneId: "zone:x#0", bodyId: "x", index: 0, triangleIndices: [0, 1, 2], areaMm2: 1,
            fit: ZoneFit(kind: "plane", params: [], residualRmsMm: 0, residualMaxMm: 0, inlierRatio: 1),
            params: SegmentParamsUsed(maxDihedralDegrees: 20, mergeRelativeTolerance: 0.004, maxMergeAngleDegrees: 50, minRegionTriangles: 8, maxZones: 64, deflection: 0.5),
            meshSignature: MeshSignature(triangleCount: 10, bboxMin: [0, 0, 0], bboxMax: [1, 1, 1]),
            slippage: ZoneSlippage(kind: kind, axisPoint: [0, 0, 0], axisDirection: axisDirection, pitchPerRadianMm: nil, confidence: confidence)
        )
    }

    func recordWithNoSlippage() -> ZoneRecord {
        ZoneRecord(
            zoneId: "zone:x#0", bodyId: "x", index: 0, triangleIndices: [0, 1, 2], areaMm2: 1,
            fit: ZoneFit(kind: "plane", params: [], residualRmsMm: 0, residualMaxMm: 0, inlierRatio: 1),
            params: SegmentParamsUsed(maxDihedralDegrees: 20, mergeRelativeTolerance: 0.004, maxMergeAngleDegrees: 50, minRegionTriangles: 8, maxZones: 64, deflection: 0.5),
            meshSignature: MeshSignature(triangleCount: 10, bboxMin: [0, 0, 0], bboxMax: [1, 1, 1])
        )
    }

    @Test("explicit axis always wins, even with a qualifying zone record present")
    func explicitWins() {
        let rec = record(kind: "cylinder", axisDirection: [0, 0, 1], confidence: 0.9)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: SIMD3(1, 0, 0))
        #expect(sel.source == "explicit")
        #expect(sel.axis == SIMD3(1, 0, 0))
        #expect(sel.warning == nil)
    }

    @Test("no record at all (whole-body sweep) falls back to PCA, no warning")
    func noRecordFallsBackToPCA() {
        let sel = ZoneSweepTool.selectSweepAxis(record: nil, explicit: nil)
        #expect(sel.source == "pca")
        #expect(sel.axis == nil)
        #expect(sel.warning == nil)
    }

    @Test("record with no slippage falls back to PCA (old-format sidecar / weld-guard omission)")
    func noSlippageFallsBackToPCA() {
        let sel = ZoneSweepTool.selectSweepAxis(record: recordWithNoSlippage(), explicit: nil)
        #expect(sel.source == "pca")
        #expect(sel.axis == nil)
        #expect(sel.warning == nil)
    }

    @Test("cylinder/extrusion/revolution/helix with sufficient confidence default to the slippage axis", arguments: ["cylinder", "extrusion", "revolution", "helix"])
    func eligibleKindsUseSlippage(kind: String) {
        let rec = record(kind: kind, axisDirection: [0, 0, 1], confidence: 0.5)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: nil)
        #expect(sel.source == "slippage", "kind \(kind) should use its slippage axis")
        #expect(sel.axis == SIMD3(0, 0, 1))
        #expect(sel.warning == nil)
    }

    @Test("plane never uses its slippage axis (it's the surface normal), even at high confidence")
    func planeNeverUsesSlippageAxis() {
        let rec = record(kind: "plane", axisDirection: [0, 0, 1], confidence: 0.99)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: nil)
        #expect(sel.source == "pca")
        #expect(sel.axis == nil)
        #expect(sel.warning == nil)
    }

    @Test("sphere and freeform never default to a slippage axis", arguments: ["sphere", "freeform"])
    func sphereAndFreeformNeverUseSlippageAxis(kind: String) {
        let rec = record(kind: kind, axisDirection: nil, confidence: 0.9)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: nil)
        #expect(sel.source == "pca", "kind \(kind) should never default to a slippage axis")
        #expect(sel.axis == nil)
    }

    @Test("an eligible kind below the confidence floor falls back to PCA with a warning naming kind + confidence")
    func lowConfidenceFallsBackWithWarning() {
        let rec = record(kind: "cylinder", axisDirection: [0, 0, 1], confidence: 0.1)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: nil)
        #expect(sel.source == "pca")
        #expect(sel.axis == nil)
        let warning = try? #require(sel.warning)
        #expect(warning?.contains("cylinder") == true)
        #expect(warning?.contains("0.1") == true)
        #expect(warning?.lowercased().contains("low-confidence") == true)
    }

    @Test("exactly at the confidence floor (0.25) qualifies")
    func exactlyAtFloorQualifies() {
        let rec = record(kind: "cylinder", axisDirection: [0, 0, 1], confidence: 0.25)
        let sel = ZoneSweepTool.selectSweepAxis(record: rec, explicit: nil)
        #expect(sel.source == "slippage")
    }
}

/// The erosion half of #109's review: on a CONNECTED mesh, zone-boundary
/// vertices' `vertexNormals()` blend neighbouring zones' surfaces in, so
/// `segment_mesh_zones` erodes boundary triangles before calling slippage
/// (see MeshZoneTools' comment) — unless the zone is too small to erode, in
/// which case the classification is kept but the zone is named in an honest
/// warning. The L-panel fixture is the smallest connected case with a real
/// fold: two square grid panels meeting at 90 degrees along one shared edge,
/// written as raw soup so the import path welds them into ONE connected mesh
/// (unlike the disjoint panel cube above, which sidesteps contamination
/// entirely and so cannot test the erosion).
@Suite("segment_mesh_zones: slippage boundary erosion (#109 review)")
struct SlippageErosionTests {

    func freshScene(_ label: String) throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-slip-erosion-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "erosion", bodies: []))
        return (store, dir)
    }

    /// Two square `size` x `size` grid panels joined at a 90-degree fold
    /// along the X axis: panel A in the z=0 plane (normal +Z), panel B in
    /// the y=0 plane (normal -Y), sharing the fold edge y=0,z=0. Raw
    /// unshared-vertex soup; welding merges the fold row so the mesh is one
    /// connected component with exactly one cross-zone vertex row.
    static func writeFoldedLPanelSTL(to path: String, size: Double = 30, gridN: Int = 10) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        let step = size / Double(gridN)
        func emitQuad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>) {
            tris.append((a, b, c)); tris.append((a, c, d))
        }
        for i in 0..<gridN {
            for j in 0..<gridN {
                let x0 = Double(i) * step, x1 = x0 + step
                let u0 = Double(j) * step, u1 = u0 + step
                // Panel A: z = 0, y in [0, size], normal +Z.
                emitQuad(SIMD3(x0, u0, 0), SIMD3(x1, u0, 0), SIMD3(x1, u1, 0), SIMD3(x0, u1, 0))
                // Panel B: y = 0, z in [0, size], normal -Y.
                emitQuad(SIMD3(x0, 0, u0), SIMD3(x1, 0, u0), SIMD3(x1, 0, u1), SIMD3(x0, 0, u1))
            }
        }
        var out = "solid lpanel\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid lpanel\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    struct SlippageEntry: Decodable { let kind: String; let axisDirection: [Double]?; let confidence: Double }
    struct ZoneEntry: Decodable { let id: String; let triangleCount: Int; let meanNormal: [Double]; let slippage: SlippageEntry? }
    struct ZoneReport: Decodable { let zoneCount: Int; let zones: [ZoneEntry]; let warnings: [String] }
    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    @MainActor
    func segmentLPanel(gridN: Int, label: String) async throws -> ZoneReport {
        let (store, dir) = try freshScene(label)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/lpanel.stl"
        try Self.writeFoldedLPanelSTL(to: stlPath, gridN: gridN)
        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "lpanel", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)
        let result = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: ZoneRegistry(), store: store
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        return try JSONDecoder().decode(ZoneReport.self, from: Data(result.text.utf8))
    }

    @MainActor
    @Test("fine connected L-panel: both zones classify plane with correct normals, no contamination warning")
    func fineLPanelClassifiesCleanly() async throws {
        let r = try await segmentLPanel(gridN: 10, label: "fine")
        #expect(r.zoneCount == 2)
        #expect(!r.warnings.contains { $0.contains("boundary erosion skipped") },
                "a 200-triangle panel must erode, not warn: \(r.warnings)")
        for zone in r.zones {
            let slip = try #require(zone.slippage, "zone \(zone.id) missing slippage")
            #expect(slip.kind == "plane", "zone \(zone.id): expected plane, got \(slip.kind)")
            let dir = try #require(slip.axisDirection)
            let a = simd_normalize(SIMD3(dir[0], dir[1], dir[2]))
            let n = simd_normalize(SIMD3(zone.meanNormal[0], zone.meanNormal[1], zone.meanNormal[2]))
            #expect(abs(simd_dot(a, n)) > 0.99,
                    "zone \(zone.id): slippage axis not parallel to the panel normal")
        }
    }

    @MainActor
    @Test("coarse connected L-panel: zones too small to erode keep their classification but are named in a warning")
    func coarseLPanelWarnsInsteadOfSilentContamination() async throws {
        let r = try await segmentLPanel(gridN: 2, label: "coarse")
        #expect(r.zoneCount == 2)
        #expect(r.warnings.contains { $0.contains("boundary erosion skipped") },
                "an 8-triangle panel cannot erode below the floor and must be named honestly: \(r.warnings)")
        for zone in r.zones {
            #expect(zone.slippage != nil, "zone \(zone.id): classification must still be reported alongside the warning")
        }
    }
}
