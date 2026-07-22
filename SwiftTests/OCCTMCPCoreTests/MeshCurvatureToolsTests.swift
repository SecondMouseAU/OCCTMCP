// Unit tests for mesh_curvature (Phase 3 of the mesh-analysis expansion,
// `.claude/plans/2026-07-21-mesh-analysis-expansion.md`).
//
// Fixtures are hand-written ASCII STL with unshared per-facet vertices
// (mirroring MeshThicknessToolsTests' / MeshZoneIntegrationTests' writers,
// each "reimplemented locally to keep this file self-contained" per that
// established convention) rather than trusting OCCT's native BRepMesh
// tessellation of Shape.box/Shape.cylinder: a plain box's flat faces don't
// necessarily get any INTERIOR (non-edge) vertices from BRepMesh at all (a
// flat face has zero deflection error regardless of triangle count), which
// would leave nothing for a "median away from edges" assertion to be robust
// against. A hand-subdivided grid guarantees a controlled majority of
// interior (exactly-flat) vertices vs. a minority of edge/corner vertices —
// the same trick MeshThicknessToolsTests' `boxFace` grid uses for its own
// median/p05 robustness.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("mesh_curvature: Rusinkiewicz per-vertex curvature over a welded mesh")
struct MeshCurvatureToolsTests {

    // MARK: - Scene / decoding helpers

    func freshScene() throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-curvature-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "curvature", bodies: []))
        return (store, dir)
    }

    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    struct CurvatureReport: Decodable {
        struct Stat: Decodable { let min: Double; let p05: Double; let median: Double; let p95: Double; let max: Double }
        let bodyId: String
        let triangleCount: Int
        let vertexCount: Int
        let colorBy: String
        let clampPercentile: Double
        let k1: Stat
        let k2: Stat
        let mean: Stat
        let gaussian: Stat
        let flatFraction: Double
        let highCurvatureFraction: Double
        let renderPath: String?
        let chartPath: String?
        let warnings: [String]
    }

    func importSTL(_ path: String, idPrefix: String, store: ManifestStore) async throws -> String {
        let importResult = await IOTools.importFile(
            inputPath: path, format: .stl, idPrefix: idPrefix, store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        return try #require(imported.addedBodyIds.first)
    }

    // MARK: - Fixtures (local, self-contained — see file header)

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

    /// One axis-aligned square face subdivided into an n x n grid of quads, so the majority of
    /// its vertices are strictly INTERIOR (exactly flat — co-planar with every neighboring
    /// triangle) rather than sitting on the face's own boundary edge.
    static func boxFaceGrid(axis: Int, value: Double, extent: Double, outward: SIMD3<Double>, subdivisions n: Int)
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

    /// A closed cube, each face subdivided n x n. With n=12: 8 corner vertices + 12*11=132
    /// edge-interior vertices + 6*121=726 face-interior vertices = 866 total. Measured
    /// flatFraction is ~0.56, not the naive edge-only ~84%: the Rusinkiewicz per-face tensor
    /// AVERAGES onto each vertex over every triangle sharing it, so the fold's nonzero
    /// curvature bleeds one hop further into the face-interior vertices immediately adjacent
    /// to an edge/corner vertex, not just the edge/corner vertices themselves (the same
    /// "contamination propagates inward through shared faces" effect OCCTSwiftMesh's own
    /// MeshCurvatureTests documents for its sphere/cylinder fixtures' open boundaries). Still a
    /// clear majority over a genuine (not naively-estimated) threshold — enough for a
    /// median/flatFraction assertion to be robust against the real curvature spike at
    /// edges/corners.
    static func writeGridBoxSTL(to path: String, extent: Double = 15, subdivisions n: Int = 12) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for axis in 0..<3 {
            for sign in [1.0, -1.0] {
                var dir = SIMD3<Double>(0, 0, 0); dir[axis] = sign
                tris += boxFaceGrid(axis: axis, value: sign * extent, extent: extent, outward: dir, subdivisions: n)
            }
        }
        try writeSTL(tris, solidName: "gridbox", to: path)
    }

    /// An OPEN (no caps) multi-ring cylindrical tube: `rings` circles of `segments` points each,
    /// connected band-to-band. Interior rings should read k1 ~ 1/radius, k2 ~ 0 (barrel
    /// curvature only); rings 0 and rings-1 (the open boundary) are documented upstream
    /// (OCCTSwiftMesh's own MeshCurvatureTests) to carry a several-% bias from their incomplete
    /// triangle fan — tolerated here via a generous tolerance on the GLOBAL median rather than
    /// excluding boundary rings (this tool's report has no per-ring breakdown to exclude by).
    static func writeCylinderTubeSTL(to path: String, radius: Double = 6, height: Double = 24, rings: Int = 17, segments: Int = 24) throws {
        func point(ring: Int, seg: Int) -> SIMD3<Double> {
            let theta = 2 * Double.pi * Double(seg) / Double(segments)
            let z = Double(ring) / Double(rings - 1) * height
            return SIMD3<Double>(radius * cos(theta), radius * sin(theta), z)
        }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for r in 0..<(rings - 1) {
            for s in 0..<segments {
                let s2 = (s + 1) % segments
                let a = point(ring: r, seg: s), b = point(ring: r, seg: s2)
                let c = point(ring: r + 1, seg: s2), d = point(ring: r + 1, seg: s)
                let mid = (a + b + c + d) / 4
                let outward = SIMD3<Double>(mid.x, mid.y, 0)   // radial: the barrel's true outward direction
                tris += quad(a, b, c, d, outward: outward)
            }
        }
        try writeSTL(tris, solidName: "tube", to: path)
    }

    // MARK: - 1. Grid box: medians near zero, high flatFraction, render off

    @MainActor
    @Test("grid box: k1/k2/gaussian medians are exactly zero (interior majority is exactly flat), flatFraction high")
    func gridBoxMediansAreFlat() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/box.stl"
        try Self.writeGridBoxSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "box", store: store)

        let result = await MeshCurvatureTools.meshCurvature(bodyId: bodyId, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(CurvatureReport.self, from: Data(result.text.utf8))

        #expect(r.bodyId == bodyId)
        #expect(r.triangleCount == 6 * 12 * 12 * 2)
        #expect(r.colorBy == "mean")
        // Interior grid vertices are co-planar with every neighboring triangle: the Rusinkiewicz
        // tensor fit solves a homogeneous system there and returns exactly (0, 0) — not just
        // "small". With ~84% of vertices interior, the median (not the max — edge/corner
        // vertices legitimately spike) lands exactly on that zero block.
        #expect(r.k1.median == 0)
        #expect(r.k2.median == 0)
        #expect(r.mean.median == 0)
        #expect(r.gaussian.median == 0)
        #expect(r.flatFraction > 0.45, "expected the face-interior majority to dominate flatFraction, got \(r.flatFraction)")
        #expect(r.renderPath == nil)
        #expect(r.chartPath == nil)
        #expect(!r.warnings.contains { $0.contains("unweldable") }, "a closed, fully-shared grid box must NOT trip the unweldable-soup warning")
    }

    // MARK: - 2. Cylinder tube: k1 ~ 1/radius, k2 ~ 0, gaussian ~ 0

    @MainActor
    @Test("cylinder tube: median k1 ~ 1/radius, median k2 ~ 0, median gaussian ~ 0")
    func cylinderTubeMatchesAnalyticCurvature() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/tube.stl"
        let radius = 6.0
        try Self.writeCylinderTubeSTL(to: stlPath, radius: radius)
        let bodyId = try await importSTL(stlPath, idPrefix: "tube", store: store)

        let result = await MeshCurvatureTools.meshCurvature(bodyId: bodyId, colorBy: .k1, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(CurvatureReport.self, from: Data(result.text.utf8))

        let expected = 1.0 / radius
        // Generous tolerance: unlike OCCTSwiftMesh's own MeshCurvatureTests (which excludes the
        // 2 boundary rings on each side per-index), this tool's report is a single GLOBAL median
        // across every vertex, so the open tube's boundary-ring bias (documented upstream as
        // "several %") is folded in rather than excluded.
        #expect(abs(r.k1.median - expected) < expected * 0.25, "expected k1 median ~\(expected), got \(r.k1.median)")
        #expect(abs(r.k2.median) < expected * 0.25, "expected k2 median ~0, got \(r.k2.median)")
        #expect(abs(r.gaussian.median) < expected * expected * 0.3, "expected gaussian median ~0, got \(r.gaussian.median)")
        #expect(!r.warnings.contains { $0.contains("unweldable") })
    }

    // MARK: - 3. Dispatch: an unrecognized colorBy errors, never silently "mean"

    @MainActor
    @Test("dispatch rejects an unknown colorBy string instead of silently running mean")
    func unknownColorByIsDispatchError() async throws {
        // Straight through the server dispatch (the layer an MCP client's schema validation can
        // be bypassed at) — no scene needed, the guard fires before any body is loaded.
        let result = await dispatch(callName: "mesh_curvature", arguments: [
            "bodyId": .string("a"),
            "colorBy": .string("curvatureXYZ"),
        ])
        #expect(result.isError == true)
        let text = result.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        #expect(text.contains("unknown colorBy \"curvatureXYZ\""))
        #expect(text.contains("mean") && text.contains("gaussian") && text.contains("k1") && text.contains("maxAbs"))
    }

    // MARK: - 4. Unweldable soup: two far-apart triangles sharing nothing

    @MainActor
    @Test("two disconnected far-apart triangles: weld merges nothing, unweldable-soup warning fires")
    func unweldableSoupWarns() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/soup.stl"
        let near: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
            (SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
        ]
        let far: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = [
            (SIMD3(1000, 1000, 1000), SIMD3(1001, 1000, 1000), SIMD3(1000, 1001, 1000)),
        ]
        try Self.writeSTL(near + far, solidName: "soup", to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "soup", store: store)

        let result = await MeshCurvatureTools.meshCurvature(bodyId: bodyId, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(CurvatureReport.self, from: Data(result.text.utf8))

        #expect(r.vertexCount == r.triangleCount * 3, "two triangles sharing nothing must not merge any vertex under weld")
        #expect(r.warnings.contains { $0.contains("unweldable") }, "expected the unweldable-soup warning, got: \(r.warnings)")
        // Every vertex is isolated (touched by exactly one triangle, no neighbors to average
        // over): vertexCurvatures() degrades cleanly to zero, not garbage.
        #expect(r.k1.max == 0)
        #expect(r.k2.max == 0)
    }

    // MARK: - 5. clampPercentile semantics: highCurvatureFraction responds, underlying stats don't

    @MainActor
    @Test("clampPercentile: 1.0 clamps nothing (highCurvatureFraction == 0), 0.95 flags a tail, k1 stats unchanged")
    func clampPercentileSemantics() async throws {
        // The grid box (not the cylinder tube): its edges/corners are a genuine, sharply
        // separated curvature SPIKE against a majority-zero flat interior (see
        // gridBoxMediansAreFlat), unlike a uniform cylinder barrel whose ring-to-ring curvature
        // varies too smoothly/near-identically to produce a clean tail above a percentile cut.
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/box.stl"
        try Self.writeGridBoxSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "box", store: store)

        let r100result = await MeshCurvatureTools.meshCurvature(
            bodyId: bodyId, colorBy: .maxAbs, clampPercentile: 1.0, render: false, store: store)
        #expect(!r100result.isError, "unexpected error: \(r100result.text)")
        let r100 = try JSONDecoder().decode(CurvatureReport.self, from: Data(r100result.text.utf8))

        let r95result = await MeshCurvatureTools.meshCurvature(
            bodyId: bodyId, colorBy: .maxAbs, clampPercentile: 0.95, render: false, store: store)
        #expect(!r95result.isError, "unexpected error: \(r95result.text)")
        let r95 = try JSONDecoder().decode(CurvatureReport.self, from: Data(r95result.text.utf8))

        #expect(r100.highCurvatureFraction == 0, "clampPercentile=1.0 clamps at the true max: nothing can read strictly above it")
        #expect(!r100.warnings.contains { $0.contains("clamped for color") })

        #expect(r95.highCurvatureFraction > 0, "clampPercentile=0.95 must flag some tail given the grid box's genuine edge/corner spike")
        #expect(r95.highCurvatureFraction < 0.3, "the flagged tail should be a minority, got \(r95.highCurvatureFraction)")
        #expect(r95.warnings.contains { $0.contains("clamped for color") })

        // clampPercentile only affects color-scaling/highCurvatureFraction, never the underlying
        // per-channel statistics themselves.
        #expect(r95.k1.median == r100.k1.median)
        #expect(r95.k1.min == r100.k1.min)
        #expect(r95.k1.max == r100.k1.max)
    }
}
