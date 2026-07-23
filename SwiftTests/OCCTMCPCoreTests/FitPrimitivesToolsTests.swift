// Tests for #107: fit_primitives — the RANSAC primitive report, distinct
// from segment_mesh_zones' per-zone fits because RANSAC claims GLOBAL
// inliers: one primitive can span regions the dihedral grower keeps
// separate.
//
// Fixtures:
//   - a disjoint "panel + sphere" scene: one flat square panel and one UV
//     sphere, far apart in space, written as ONE raw unshared-vertex-soup
//     STL (same convention as MeshZoneIntegrationTests/
//     SlippageClassificationTests) so RANSAC's GLOBAL-inlier claim has two
//     genuinely disconnected clusters to find, and a plane vs. sphere
//     candidate has to be told apart rather than trivially matching a
//     single, already-uniform surface.
//   - SlippageClassificationTests' open-tube fixture, reused as-is, for the
//     zoneId-scoped cylinder case.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("fit_primitives: RANSAC primitive report (#107)")
struct FitPrimitivesToolsTests {

    // MARK: - Fixtures

    func freshScene(_ label: String) throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-fitprim-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: label, bodies: []))
        return (store, dir)
    }

    /// A single oriented triangle, winding corrected so its normal points (roughly) toward
    /// `outward` — the single-triangle sibling of `MeshZoneIntegrationTests.quad`, needed for the
    /// sphere fixture's polar caps (a triangle fan, not a quad grid, meets each pole).
    static func orientedTri(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, outward: SIMD3<Double>)
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        let n = simd_cross(b - a, c - a)
        return simd_dot(n, outward) >= 0 ? [(a, b, c)] : [(a, c, b)]
    }

    /// A UV sphere centered at `center`: explicit triangle fans at both poles (never a degenerate
    /// quad collapsed onto a point) plus quad rings in between, reusing
    /// `MeshZoneIntegrationTests.quad`'s winding-correction helper.
    static func sphereTriangles(center: SIMD3<Double>, radius: Double, latSegments: Int, lonSegments: Int)
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        func point(phi: Double, theta: Double) -> SIMD3<Double> {
            center + SIMD3(radius * sin(phi) * cos(theta), radius * sin(phi) * sin(theta), radius * cos(phi))
        }
        let north = point(phi: 0, theta: 0)
        let south = point(phi: .pi, theta: 0)
        var rings: [[SIMD3<Double>]] = []
        for i in 0..<latSegments {
            let phi = Double.pi * Double(i + 1) / Double(latSegments + 1)
            rings.append((0..<lonSegments).map { j in point(phi: phi, theta: 2 * .pi * Double(j) / Double(lonSegments)) })
        }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for j in 0..<lonSegments {
            let a = rings[0][j], b = rings[0][(j + 1) % lonSegments]
            let outward = simd_normalize((a + b + north) / 3 - center)
            tris += orientedTri(north, a, b, outward: outward)
        }
        for i in 0..<(latSegments - 1) {
            for j in 0..<lonSegments {
                let a = rings[i][j], b = rings[i][(j + 1) % lonSegments]
                let c = rings[i + 1][(j + 1) % lonSegments], d = rings[i + 1][j]
                let outward = simd_normalize((a + b + c + d) / 4 - center)
                tris += MeshZoneIntegrationTests.quad(a, b, c, d, outward: outward)
            }
        }
        let last = latSegments - 1
        for j in 0..<lonSegments {
            let a = rings[last][j], b = rings[last][(j + 1) % lonSegments]
            let outward = simd_normalize((a + b + south) / 3 - center)
            tris += orientedTri(south, b, a, outward: outward)
        }
        return tris
    }

    static func writeTrianglesSTL(_ tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)], to path: String, name: String) throws {
        var out = "solid \(name)\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid \(name)\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A flat square panel (a grid of quads in the z=0 plane) plus a disjoint UV sphere far away —
    /// two genuinely disconnected primitive clusters in ONE mesh, exactly the scene where a
    /// dihedral grower's edge-adjacency-only reach is irrelevant and RANSAC's GLOBAL-inlier claim
    /// is what has to tell "plane" from "sphere" apart.
    static func writePanelAndSphereSTL(
        to path: String, panelSize: Double = 40, gridN: Int = 6,
        sphereCenter: SIMD3<Double> = SIMD3(150, 150, 50), sphereRadius: Double = 10,
        sphereLatSegments: Int = 10, sphereLonSegments: Int = 12
    ) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        let step = panelSize / Double(gridN)
        for i in 0..<gridN {
            for j in 0..<gridN {
                let x0 = Double(i) * step, x1 = x0 + step
                let y0 = Double(j) * step, y1 = y0 + step
                tris += MeshZoneIntegrationTests.quad(
                    SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y1, 0), SIMD3(x0, y1, 0), outward: SIMD3(0, 0, 1)
                )
            }
        }
        tris += sphereTriangles(
            center: sphereCenter, radius: sphereRadius, latSegments: sphereLatSegments, lonSegments: sphereLonSegments
        )
        try writeTrianglesSTL(tris, to: path, name: "panelsphere")
    }

    // MARK: - Decodable mirrors

    struct PrimitiveEntry: Decodable {
        let kind: String
        let params: [Double]
        let residualRmsMm: Double
        let residualMaxMm: Double
        let inlierRatio: Double
        let supportTriangles: Int
        let supportFraction: Double
        let areaMm2: Double
    }
    struct StrategyScores: Decodable { let dihedral: Double; let ransac: Double; let chosen: String }
    struct FitReport: Decodable {
        let bodyId: String
        let zoneId: String?
        let strategy: String
        let strategyScores: StrategyScores?
        let primitives: [PrimitiveEntry]
        let uncoveredFraction: Double
        let renderPath: String?
        let warnings: [String]
    }
    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }
    struct ZoneReportEntry: Decodable { let id: String; let triangleCount: Int }
    struct ZoneReport: Decodable { let zoneCount: Int; let zones: [ZoneReportEntry] }

    // MARK: - Tests

    @MainActor
    @Test("disjoint panel + sphere scene: both primitive kinds found, largest-support-first, deterministic")
    func disjointSceneFindsBothPrimitives() async throws {
        let (store, dir) = try freshScene("panelsphere")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/panelsphere.stl"
        try Self.writePanelAndSphereSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "scene", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result1 = await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId, inlierEpsilonMm: 1.5, render: false, store: store
        )
        #expect(!result1.isError, "fit_primitives failed: \(result1.text)")
        let r1 = try JSONDecoder().decode(FitReport.self, from: Data(result1.text.utf8))

        #expect(r1.strategy == "ransac")
        #expect(r1.zoneId == nil)
        let kinds = Set(r1.primitives.map(\.kind))
        #expect(kinds.contains("plane"), "expected a plane primitive for the panel, got kinds \(kinds)")
        #expect(kinds.contains("sphere"), "expected a sphere primitive, got kinds \(kinds)")

        // Largest-support-first (matches SegmentedMesh.regions' own order).
        for i in 1..<r1.primitives.count {
            #expect(r1.primitives[i - 1].supportTriangles >= r1.primitives[i].supportTriangles,
                    "primitives not largest-support-first: \(r1.primitives.map(\.supportTriangles))")
        }
        for p in r1.primitives {
            #expect(p.supportFraction > 0 && p.supportFraction <= 1, "supportFraction out of (0,1]: \(p.supportFraction)")
        }

        // Determinism: a repeat call with identical arguments against the unchanged body returns
        // byte-identical JSON (splitmix64 candidate sampling, no system RNG anywhere upstream).
        let result2 = await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId, inlierEpsilonMm: 1.5, render: false, store: store
        )
        #expect(!result2.isError)
        #expect(result1.text == result2.text, "repeat fit_primitives calls were not byte-identical")
    }

    @MainActor
    @Test("zoneId-scoped fit on the open-tube fixture fits ~one cylinder")
    func zoneScopedFitsCylinder() async throws {
        let (store, dir) = try freshScene("tube")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/tube.stl"
        try SlippageClassificationTests.writeOpenTubeSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "tube", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let registry = ZoneRegistry()
        let segResult = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!segResult.isError, "segment_mesh_zones failed: \(segResult.text)")
        let seg = try JSONDecoder().decode(ZoneReport.self, from: Data(segResult.text.utf8))
        // Pick the largest zone (the barrel), not index 0 — OCCT's own face ordering after the
        // STL round-trip isn't this test's to dictate (same convention as SlippageClassificationTests).
        let barrel = try #require(seg.zones.max(by: { $0.triangleCount < $1.triangleCount }))

        let fitResult = await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId, zoneId: barrel.id, render: false, registry: registry, store: store
        )
        #expect(!fitResult.isError, "fit_primitives failed: \(fitResult.text)")
        let fr = try JSONDecoder().decode(FitReport.self, from: Data(fitResult.text.utf8))
        #expect(fr.zoneId == barrel.id)
        #expect(fr.strategy == "ransac")
        let top = try #require(fr.primitives.first, "expected at least one fitted primitive")
        #expect(top.kind == "cylinder", "largest primitive in the barrel zone should be its own cylinder, got \(top.kind)")
        #expect(top.supportFraction > 0.5, "the barrel zone's own cylinder should cover most of its own triangles, got \(top.supportFraction)")
    }

    @MainActor
    @Test("strategy \"auto\" reports both bake-off scores and which strategy was chosen")
    func autoStrategyReportsScores() async throws {
        let (store, dir) = try freshScene("auto")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/tube.stl"
        try SlippageClassificationTests.writeOpenTubeSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "tubeauto", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId, strategy: .auto, render: false, store: store
        )
        #expect(!result.isError, "fit_primitives failed: \(result.text)")
        let r = try JSONDecoder().decode(FitReport.self, from: Data(result.text.utf8))
        #expect(r.strategy == "auto")
        let scores = try #require(r.strategyScores, "strategy \"auto\" must report strategyScores")
        #expect(scores.dihedral >= 0 && scores.dihedral <= 1)
        #expect(scores.ransac >= 0 && scores.ransac <= 1)
        #expect(scores.chosen == "dihedral" || scores.chosen == "ransac")
    }

    // ── Dispatch: an unrecognized strategy errors, never silently defaults ──

    @Test("dispatch rejects an unknown strategy string instead of silently running ransac")
    func dispatchUnknownStrategyErrors() async throws {
        // Straight through the server dispatch (the layer where the schema's enum can be
        // bypassed by a non-validating MCP client); no scene needed — the strategy guard fires
        // before any body is loaded.
        let result = await dispatch(callName: "fit_primitives", arguments: [
            "bodyId": .string("whatever"),
            "strategy": .string("bogus"),
        ])
        #expect(result.isError == true)
        let text = result.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        #expect(text.contains("unknown strategy \"bogus\""))
        #expect(text.contains("ransac") && text.contains("auto"))
    }

    @MainActor
    @Test("minSupportTriangles excluding a small feature reports uncoveredFraction, kept separate from a found primitive")
    func minSupportExcludesSmallFeatureReportsUncovered() async throws {
        let (store, dir) = try freshScene("uncovered")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/panelsphere.stl"
        // Panel (8x8 grid = 128 triangles) well above the floor; a SMALL sphere (6x8 UV segments
        // = 96 triangles) just below it. minSupportTriangles=100 sits strictly between the two,
        // so the panel is still found while the sphere is genuinely excluded (never claimed).
        try Self.writePanelAndSphereSTL(
            to: stlPath, panelSize: 40, gridN: 8,
            sphereCenter: SIMD3(150, 150, 50), sphereRadius: 4, sphereLatSegments: 6, sphereLonSegments: 8
        )

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "uncov", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId, inlierEpsilonMm: 1.5, minSupportTriangles: 100, render: false, store: store
        )
        #expect(!result.isError, "fit_primitives failed: \(result.text)")
        let r = try JSONDecoder().decode(FitReport.self, from: Data(result.text.utf8))

        #expect(!r.primitives.isEmpty, "the panel (128 tri) should still clear a 100-triangle floor")
        #expect(r.primitives.contains { $0.kind == "plane" })
        #expect(r.uncoveredFraction > 0, "the small sphere (96 tri) should read as genuinely uncovered")
        #expect(r.uncoveredFraction < 0.6, "uncoveredFraction should reflect only the small sphere, not swallow the panel too: \(r.uncoveredFraction)")
        #expect(r.warnings.contains { $0.contains("never claimed") })
        // No maxPrimitives cap was passed, so nothing should be attributed to a cap-truncation warning.
        #expect(!r.warnings.contains { $0.contains("maxPrimitives") })
    }
}
