// Unit tests for mesh_thickness: a hand-built hollow-box STL shell with
// known 2mm walls (outer cube half-extent 15, inner cavity half-extent 13
// on every axis — every ray, inner or outer, should read ~2mm), and a flat
// single-layer open sheet (every ray must miss — nothing to hit).
//
// Both fixtures are hand-written ASCII STL with unshared per-facet vertices
// (mirroring MeshZoneIntegrationTests' STL writer) so the pipeline exercises
// the real import_file -> mesh -> TriBVH path rather than a synthetic
// TriMesh built in-process.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("mesh_thickness: ray-method thickness on hand-built STL shells")
struct MeshThicknessToolsTests {

    // MARK: - Fixtures

    /// A quad's 2 triangles, winding corrected so the face normal points
    /// (roughly) toward `outward` — same trick as
    /// MeshZoneIntegrationTests.quad, reimplemented locally to keep this
    /// file self-contained.
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

    /// One axis-aligned square face, `extent` half-width, centred at
    /// `value` along `axis`, subdivided into an `n`x`n` grid of quads (not
    /// just its 4 outer corners): a straight ray fired perpendicular from a
    /// corner of the FULL face necessarily leaves the smaller opposing
    /// wall's own (smaller) footprint before it gets there — a real
    /// characteristic of single-ray thickness sampling near an edge, not a
    /// bug — so the grid's INTERIOR points (which stay within the smaller
    /// wall's footprint) are what let most samples read the true wall
    /// thickness. Walked via the other two axes so each cell's perimeter is
    /// always simple (no manual corner-order bookkeeping).
    static func boxFace(axis: Int, value: Double, extent: Double, outward: SIMD3<Double>, subdivisions n: Int = 10)
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        let others = [0, 1, 2].filter { $0 != axis }
        let (u, v) = (others[0], others[1])
        func pt(_ pu: Double, _ pv: Double) -> SIMD3<Double> {
            var p = SIMD3<Double>(0, 0, 0)
            p[axis] = value; p[u] = pu; p[v] = pv
            return p
        }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        let step = (2 * extent) / Double(n)
        for i in 0..<n {
            for j in 0..<n {
                let u0 = -extent + Double(i) * step, u1 = u0 + step
                let v0 = -extent + Double(j) * step, v1 = v0 + step
                tris += quad(pt(u0, v0), pt(u1, v0), pt(u1, v1), pt(u0, v1), outward: outward)
            }
        }
        return tris
    }

    /// Nested boxes (outer half-extent `outer`, inner cavity half-extent
    /// `inner`): 6 outer faces with standard outward normals, 6 inner
    /// faces with normals flipped to point INTO the cavity (the true
    /// outward-of-the-solid direction for a shell's inner boundary). Wall
    /// thickness is uniformly `outer - inner` on every side.
    static func writeHollowBoxSTL(to path: String, outer: Double = 15, inner: Double = 13) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for axis in 0..<3 {
            for sign in [1.0, -1.0] {
                var dir = SIMD3<Double>(0, 0, 0); dir[axis] = sign
                tris += boxFace(axis: axis, value: sign * outer, extent: outer, outward: dir)
                tris += boxFace(axis: axis, value: sign * inner, extent: inner, outward: -dir)
            }
        }
        try writeSTL(tris, solidName: "hollowbox", to: path)
    }

    /// A single flat 20x20mm sheet (2 triangles, z=0) — an open, single-
    /// layer surface with nothing behind it in either direction.
    static func writeFlatSheetSTL(to path: String) throws {
        let tris = boxFace(axis: 2, value: 0, extent: 10, outward: SIMD3(0, 0, 1), subdivisions: 1)
        try writeSTL(tris, solidName: "sheet", to: path)
    }

    static func writeSTL(_ tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)], solidName: String, to path: String) throws {
        var out = "solid \(solidName)\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
            out += "    outer loop\n"
            out += "      vertex \(a.x) \(a.y) \(a.z)\n"
            out += "      vertex \(b.x) \(b.y) \(b.z)\n"
            out += "      vertex \(c.x) \(c.y) \(c.z)\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid \(solidName)\n"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func freshScene() throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-thickness-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "thickness", bodies: []))
        return (store, dir)
    }

    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }
    struct ThicknessReport: Decodable {
        struct Stat: Decodable { let min: Double; let p05: Double; let median: Double; let mean: Double; let p95: Double; let max: Double }
        struct Below: Decodable { let thresholdMm: Double; let count: Int; let fraction: Double }
        let bodyId: String
        let samples: Int
        let noHitSamples: Int
        let thicknessMm: Stat
        let belowThreshold: Below?
        let warnings: [String]
    }

    // MARK: - Tests

    @MainActor
    @Test("hollow box with 2mm walls: median thickness reads ~2mm, no misses")
    func hollowBoxReadsKnownWallThickness() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/hollow.stl"
        try Self.writeHollowBoxSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "shell", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await MeshThicknessTools.meshThickness(bodyId: bodyId, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ThicknessReport.self, from: Data(result.text.utf8))

        #expect(r.noHitSamples == 0, "every sample on a fully nested hollow box should find SOME opposite wall")
        #expect(abs(r.thicknessMm.median - 2.0) < 0.01, "expected ~2mm median, got \(r.thicknessMm.median)")
        #expect(abs(r.thicknessMm.p05 - 2.0) < 0.01, "the majority of samples should read the true wall thickness")
        #expect(abs(r.thicknessMm.min - 2.0) < 0.01)
        // NOT asserting max/p95: a straight ray fired from a sample near a
        // face's own outer edge legitimately overshoots the (smaller)
        // opposing wall's footprint and reads through to the FAR wall
        // instead — a real characteristic of single-ray thickness sampling
        // near an edge, not a bug (see boxFace's doc comment). The fixture
        // subdivides each face finely enough that this is a minority of
        // samples, which is what the p05/median assertions above check for.
    }

    @MainActor
    @Test("thresholdMm exercised both sides: below the true 2mm wall reports nothing, above it reports the majority")
    func thresholdBothSides() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/hollow.stl"
        try Self.writeHollowBoxSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "shell", store: store, history: SceneHistory()
        )
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let below = await MeshThicknessTools.meshThickness(bodyId: bodyId, thresholdMm: 1.0, store: store)
        let belowReport = try JSONDecoder().decode(ThicknessReport.self, from: Data(below.text.utf8))
        let belowSection = try #require(belowReport.belowThreshold)
        #expect(belowSection.count == 0, "no wall (correctly- or edge-misread) is thinner than 1mm on a 2mm-wall fixture")

        let above = await MeshThicknessTools.meshThickness(bodyId: bodyId, thresholdMm: 3.0, store: store)
        let aboveReport = try JSONDecoder().decode(ThicknessReport.self, from: Data(above.text.utf8))
        let aboveSection = try #require(aboveReport.belowThreshold)
        // Most (not necessarily all — see the edge-overshoot note above)
        // measured samples correctly read ~2mm, which is below 3mm.
        #expect(aboveSection.fraction > 0.7, "expected a strong majority of samples below thresholdMm=3.0, got fraction \(aboveSection.fraction)")
    }

    @MainActor
    @Test("a flat open sheet: every ray misses, reported as noHitSamples with a warning")
    func flatSheetIsAllMisses() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/sheet.stl"
        try Self.writeFlatSheetSTL(to: stlPath)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "sheet", store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let result = await MeshThicknessTools.meshThickness(bodyId: bodyId, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ThicknessReport.self, from: Data(result.text.utf8))

        #expect(r.noHitSamples == r.samples, "a single-layer sheet has nothing behind it in either normal direction")
        #expect(r.thicknessMm.median == 0, "no valid thickness samples")
        #expect(r.warnings.contains { $0.contains("No hits") })
    }
}
