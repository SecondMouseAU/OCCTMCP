// Unit + integration tests for detect_mesh_features (#108, Phase 3 of the
// mesh-analysis expansion).
//
// Fixture note: MeshZoneIntegrationTests' mini-carbody deliberately RAMPS its
// recess (atan(3/15) =~ 11.3 degrees) to stay UNDER segment_mesh_zones'
// default 20-degree dihedral threshold, so a single front-wall zone keeps
// growing across the whole recess. That is exactly the wrong shape for a
// crease-detection fixture, which needs a genuine sharp (90-degree) step to
// produce closed rings at all. This file's own fixtures use hand-written
// ASCII STL with unshared per-facet vertices (mirroring
// MeshZoneIntegrationTests'/MeshCurvatureToolsTests' writers, "reimplemented
// locally to keep this file self-contained" per that established
// convention), built around a ROUND stepped "mesa" (a two-tier cylinder)
// rather than a ramp — and rather than a square mesa, whose vertical corners
// are themselves additional creases that fragment a clean ring; see
// `writeTieredCylinderSTL`'s own doc comment below.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("detect_mesh_features: crease-ring feature outlines (#108)")
struct MeshFeatureToolsTests {

    // MARK: - Scene / decoding helpers

    func freshScene() throws -> (store: ManifestStore, dir: String) {
        let dir = NSTemporaryDirectory() + "occtmcp-meshfeatures-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "mesh features", bodies: []))
        return (store, dir)
    }

    struct ImportReport: Decodable { let addedBodyIds: [String]; let warnings: [String] }

    func importSTL(_ path: String, idPrefix: String, store: ManifestStore) async throws -> String {
        let importResult = await IOTools.importFile(
            inputPath: path, format: .stl, idPrefix: idPrefix, store: store, history: SceneHistory()
        )
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        return try #require(imported.addedBodyIds.first)
    }

    struct FeatureReport: Decodable {
        struct BBox: Decodable { let min: [Double]; let max: [Double] }
        struct RingEntry: Decodable {
            let id: String
            let closed: Bool
            let lengthMm: Double
            let bbox: BBox
            let meanFoldAngleDegrees: Double
            let maxFoldAngleDegrees: Double
            let edgeCount: Int
            let containingZones: [String]?
        }
        let bodyId: String
        let ringCount: Int
        let unchainedCreaseEdgeCount: Int
        let rings: [RingEntry]
        let renderPath: String?
        let warnings: [String]
    }

    struct ZoneReport: Decodable {
        struct BBox: Decodable { let min: [Double]; let max: [Double] }
        struct Entry: Decodable {
            let id: String
            let triangleCount: Int
            let bbox: BBox
            let meanNormal: [Double]
        }
        let bodyId: String
        let zoneCount: Int
        let zones: [Entry]
        let warnings: [String]
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

    /// A plain `w` x `d` x `h` closed box. Every one of its 12 edges is a
    /// 90-degree crease between two degree-3 CORNER junctions, so
    /// `creaseEdges` returns exactly 12 OPEN (`closed: false`) single-edge
    /// paths, none of them rings — useful for the maxRings-cap test.
    static func writeBoxSTL(to path: String, w: Double = 40, d: Double = 40, h: Double = 8) throws {
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        tris += quad(SIMD3(0, 0, h), SIMD3(w, 0, h), SIMD3(w, d, h), SIMD3(0, d, h), outward: SIMD3(0, 0, 1))
        tris += quad(SIMD3(0, 0, 0), SIMD3(w, 0, 0), SIMD3(w, d, 0), SIMD3(0, d, 0), outward: SIMD3(0, 0, -1))
        tris += quad(SIMD3(0, 0, 0), SIMD3(0, d, 0), SIMD3(0, d, h), SIMD3(0, 0, h), outward: SIMD3(-1, 0, 0))
        tris += quad(SIMD3(w, 0, 0), SIMD3(w, d, 0), SIMD3(w, d, h), SIMD3(w, 0, h), outward: SIMD3(1, 0, 0))
        tris += quad(SIMD3(0, 0, 0), SIMD3(w, 0, 0), SIMD3(w, 0, h), SIMD3(0, 0, h), outward: SIMD3(0, -1, 0))
        tris += quad(SIMD3(0, d, 0), SIMD3(w, d, 0), SIMD3(w, d, h), SIMD3(0, d, h), outward: SIMD3(0, 1, 0))
        try writeSTL(tris, solidName: "plate", to: path)
    }

    static func tri(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, outward: SIMD3<Double>)
        -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
    {
        let n = simd_cross(b - a, c - a)
        return simd_dot(n, outward) >= 0 ? (a, b, c) : (a, c, b)
    }

    /// A two-tier cylinder: a squat base cylinder (radius `router`, height
    /// `hBase`) with a smaller boss cylinder (radius `rinner`, height
    /// `hBoss`) on top — a ROUND stepped feature, deliberately NOT a square
    /// mesa. A square/rectangular mesa's 4 vertical corners are themselves
    /// additional 90-degree creases (where two adjacent walls meet), which
    /// turns every corner into a degree-3 JUNCTION and fragments what should
    /// be one clean closed ring into several short open paths — exactly the
    /// "generic XY-grid raised mesa... POOR fixture" pitfall OCCTSwiftMesh's
    /// own docs/algorithms/crease-detection.md test-fixture notes call out,
    /// recommending a `coarseCappedCylinderMesh`-style fixture (a fan cap
    /// sharing an exact boundary ring with the barrel — no corner ambiguity)
    /// instead. A cylindrical wall has no corners: adjacent wall segments
    /// differ by only `360/segments` degrees (well under the default
    /// 30-degree threshold with `segments >= 24`), so they region-grow into
    /// ONE continuous wall rather than fragmenting, while each wall still
    /// meets its flat cap/annulus neighbor at a genuine 90-degree crease.
    ///
    /// Produces exactly 4 clean closed rings, largest-first by radius:
    /// bottom-cap/base-wall (Z=0, radius `router`), base-wall/top-annulus
    /// (Z=`hBase`, radius `router`), top-annulus/boss-wall (Z=`hBase`,
    /// radius `rinner` — the "mesa base"), boss-wall/boss-top-cap
    /// (Z=`hBase+hBoss`, radius `rinner` — the "mesa top rim").
    static func writeTieredCylinderSTL(
        to path: String, router: Double = 20, rinner: Double = 8,
        hBase: Double = 8, hBoss: Double = 4, segments: Int = 24
    ) throws {
        func p(_ radius: Double, _ i: Int, _ z: Double) -> SIMD3<Double> {
            let theta = 2 * Double.pi * Double(i) / Double(segments)
            return SIMD3(radius * cos(theta), radius * sin(theta), z)
        }
        var tris: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        let hTop = hBase + hBoss

        for i in 0..<segments {
            let i2 = (i + 1) % segments

            // Bottom cap (fan from origin), normal -Z.
            tris.append(tri(SIMD3(0, 0, 0), p(router, i, 0), p(router, i2, 0), outward: SIMD3(0, 0, -1)))

            // Base outer wall (Z 0 -> hBase, radius router), outward radial.
            do {
                let a0 = p(router, i, 0), b0 = p(router, i2, 0)
                let a1 = p(router, i, hBase), b1 = p(router, i2, hBase)
                let mid = (a0 + b0 + a1 + b1) / 4
                tris += quad(a0, b0, b1, a1, outward: SIMD3(mid.x, mid.y, 0))
            }

            // Top annulus (Z = hBase, between rinner and router), normal +Z.
            tris += quad(p(router, i, hBase), p(router, i2, hBase), p(rinner, i2, hBase), p(rinner, i, hBase), outward: SIMD3(0, 0, 1))

            // Boss wall (Z hBase -> hTop, radius rinner), outward radial.
            do {
                let a0 = p(rinner, i, hBase), b0 = p(rinner, i2, hBase)
                let a1 = p(rinner, i, hTop), b1 = p(rinner, i2, hTop)
                let mid = (a0 + b0 + a1 + b1) / 4
                tris += quad(a0, b0, b1, a1, outward: SIMD3(mid.x, mid.y, 0))
            }

            // Boss top cap (fan from the boss's own axis point), normal +Z.
            tris.append(tri(SIMD3(0, 0, hTop), p(rinner, i, hTop), p(rinner, i2, hTop), outward: SIMD3(0, 0, 1)))
        }

        try writeSTL(tris, solidName: "tieredcyl", to: path)
    }

    /// Exact polygon (not true-circle) perimeter of an N-segment regular
    /// polygon inscribed at `radius` — what `writeTieredCylinderSTL`'s own
    /// straight-chord rings actually measure as `lengthMm`.
    static func polygonPerimeter(radius: Double, segments: Int) -> Double {
        Double(segments) * 2 * radius * sin(.pi / Double(segments))
    }

    /// A single flat quad (2 triangles, 1 shared internal edge at 0-degree
    /// dihedral, 3 true boundary edges used by only 1 triangle each — none
    /// of which qualify as a crease edge in the first place). Genuinely
    /// zero creases, not merely zero CLOSED rings.
    static func writeFlatQuadSTL(to path: String, size: Double = 40) throws {
        let tris = quad(SIMD3(0, 0, 0), SIMD3(size, 0, 0), SIMD3(size, size, 0), SIMD3(0, size, 0), outward: SIMD3(0, 0, 1))
        try writeSTL(tris, solidName: "flatplate", to: path)
    }

    // MARK: - 1. Tiered cylinder: four closed rings, ~90-degree fold, largest-first, stable ids

    @MainActor
    @Test("tiered cylinder: four closed 90-degree crease rings, largest-first, stable ring ids")
    func tieredCylinderProducesFourClosedRings() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/cyl.stl"
        let router = 20.0, rinner = 8.0, segments = 24
        try Self.writeTieredCylinderSTL(to: stlPath, router: router, rinner: rinner, segments: segments)
        let bodyId = try await importSTL(stlPath, idPrefix: "cyl", store: store)

        let result = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(FeatureReport.self, from: Data(result.text.utf8))

        #expect(r.bodyId == bodyId)
        #expect(r.ringCount == 4, "expected 4 closed rings (bottom rim, base-top rim, mesa-base rim, mesa-top rim), got \(r.ringCount): \(r.rings)")
        #expect(r.rings.count == 4)
        #expect(r.unchainedCreaseEdgeCount == 0)
        #expect(!r.warnings.contains { $0.contains("unweldable") })

        let outerPerimeter = Self.polygonPerimeter(radius: router, segments: segments)
        let innerPerimeter = Self.polygonPerimeter(radius: rinner, segments: segments)

        for ring in r.rings {
            #expect(ring.closed, "every ring in this fixture is a full circular loop")
            #expect(abs(ring.meanFoldAngleDegrees - 90) < 1.0, "expected ~90 degree fold, got \(ring.meanFoldAngleDegrees)")
            #expect(abs(ring.maxFoldAngleDegrees - 90) < 1.0, "expected ~90 degree fold, got \(ring.maxFoldAngleDegrees)")
            #expect(ring.edgeCount >= segments)
            #expect(ring.id.hasPrefix("ring:\(bodyId)#"), "ring id should be self-describing: \(ring.id)")
            let matchesOuter = abs(ring.lengthMm - outerPerimeter) < 1.0
            let matchesInner = abs(ring.lengthMm - innerPerimeter) < 1.0
            #expect(matchesOuter || matchesInner, "ring length \(ring.lengthMm) matched neither outer (\(outerPerimeter)) nor inner (\(innerPerimeter)) perimeter")
        }
        // Largest-first: the two outer-radius rings must sort ahead of the two inner-radius rings.
        for i in 0..<(r.rings.count - 1) {
            #expect(r.rings[i].lengthMm >= r.rings[i + 1].lengthMm)
        }
        // Stable, distinct ids.
        #expect(Set(r.rings.map(\.id)).count == 4)
        for (i, ring) in r.rings.enumerated() {
            #expect(ring.id == "ring:\(bodyId)#\(i)")
        }
    }

    // MARK: - 2. Zone interplay: containingZones names the right zone(s)

    @MainActor
    @Test("zone interplay: a ring's containingZones names the zone(s) whose triangles touch it")
    func zoneInterplayNamesCorrectZones() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/cyl2.stl"
        let router = 20.0, rinner = 8.0
        try Self.writeTieredCylinderSTL(to: stlPath, router: router, rinner: rinner)
        let bodyId = try await importSTL(stlPath, idPrefix: "cyl2", store: store)

        let registry = ZoneRegistry()
        let zoneResult = await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId, minRegionTriangles: 1, render: false, registry: registry, store: store
        )
        #expect(!zoneResult.isError, "segment_mesh_zones failed: \(zoneResult.text)")
        let zr = try JSONDecoder().decode(ZoneReport.self, from: Data(zoneResult.text.utf8))

        // The top annulus (large XY extent ~ 2*router, Z ~ hBase, normal
        // +Z) and the boss top cap (small XY extent ~ 2*rinner, Z ~
        // hBase+hBoss, normal +Z) are distinguishable by bbox size alone —
        // both flat and both +Z, but very different footprints.
        let flatZones = zr.zones.filter { $0.meanNormal.count == 3 && $0.meanNormal[2] > 0.9 }
        let annulusZone = try #require(flatZones.first { $0.bbox.max[0] - $0.bbox.min[0] > 30 },
                                        "expected a large-footprint flat zone (the top annulus)")
        let bossTopZone = try #require(flatZones.first { ($0.bbox.max[0] - $0.bbox.min[0]) < 20 && ($0.bbox.max[0] - $0.bbox.min[0]) > 10 },
                                        "expected a small-footprint flat zone (the boss's own top)")
        #expect(annulusZone.id != bossTopZone.id)

        let featResult = await MeshFeatureTools.detectMeshFeatures(
            bodyId: bodyId, render: false, registry: registry, store: store
        )
        #expect(!featResult.isError, "unexpected error: \(featResult.text)")
        let fr = try JSONDecoder().decode(FeatureReport.self, from: Data(featResult.text.utf8))
        #expect(fr.ringCount == 4)

        // ringC: annulus <-> boss wall (Z ~ hBase=8, radius rinner — small bbox).
        // ringD: boss wall <-> boss top cap (Z ~ hBase+hBoss=12, radius rinner).
        let ringC = try #require(fr.rings.first {
            abs($0.bbox.min[2] - 8) < 0.5 && ($0.bbox.max[0] - $0.bbox.min[0]) < 20
        })
        let ringD = try #require(fr.rings.first { abs($0.bbox.min[2] - 12) < 0.5 })

        let ringCZones = try #require(ringC.containingZones)
        let ringDZones = try #require(ringD.containingZones)
        #expect(ringCZones.contains(annulusZone.id), "annulus/boss-wall ring should touch the annulus zone: \(ringCZones)")
        #expect(ringDZones.contains(bossTopZone.id), "boss-wall/boss-top ring should touch the boss-top zone: \(ringDZones)")
    }

    // MARK: - 3. Flat quad: zero creases, zero rings, no crash

    @MainActor
    @Test("flat single quad: zero creases, zero rings, no crash")
    func flatQuadProducesZeroRings() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/flat.stl"
        try Self.writeFlatQuadSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "flat", store: store)

        let result = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(FeatureReport.self, from: Data(result.text.utf8))

        #expect(r.ringCount == 0)
        #expect(r.rings.isEmpty)
        #expect(r.unchainedCreaseEdgeCount == 0)
    }

    // MARK: - 4. Unweldable soup: warning fires, zero rings

    @MainActor
    @Test("two disconnected far-apart triangles: unweldable-soup warning fires, zero rings")
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

        let result = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(FeatureReport.self, from: Data(result.text.utf8))

        #expect(r.warnings.contains { $0.contains("unweldable") }, "expected the unweldable-soup warning, got: \(r.warnings)")
        #expect(r.ringCount == 0)
    }

    // MARK: - 5. maxRings cap: explicit warning

    @MainActor
    @Test("plain box: 12 open-path creases (one per edge), maxRings caps with an explicit warning")
    func maxRingsCapWarnsExplicitly() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/box.stl"
        try Self.writeBoxSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "box", store: store)

        // Uncapped: every one of the box's 12 edges is its own open crease path.
        let uncapped = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        #expect(!uncapped.isError, "unexpected error: \(uncapped.text)")
        let ur = try JSONDecoder().decode(FeatureReport.self, from: Data(uncapped.text.utf8))
        #expect(ur.ringCount == 12, "expected 12 box-edge paths, got \(ur.ringCount)")
        #expect(ur.rings.allSatisfy { !$0.closed })

        let capped = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, maxRings: 5, render: false, store: store)
        #expect(!capped.isError, "unexpected error: \(capped.text)")
        let cr = try JSONDecoder().decode(FeatureReport.self, from: Data(capped.text.utf8))
        #expect(cr.ringCount == 5)
        #expect(cr.warnings.contains { $0.contains("beyond maxRings=5") }, "expected an explicit maxRings truncation warning, got: \(cr.warnings)")
    }

    // MARK: - 6. Determinism: two calls, byte-identical JSON

    @MainActor
    @Test("determinism: two identical calls produce byte-identical JSON")
    func repeatCallsAreDeterministic() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/cyl3.stl"
        try Self.writeTieredCylinderSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "cyl3", store: store)

        let first = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        let second = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: false, store: store)
        #expect(!first.isError && !second.isError)
        #expect(first.text == second.text, "two identical calls must produce byte-identical JSON")
    }

    // MARK: - 7. Render: PNG file exists and is non-trivial in size

    @MainActor
    @Test("render: writes a non-trivial PNG with the body surface + per-ring wireframe overlays")
    func renderProducesNonTrivialPNG() async throws {
        let (store, dir) = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stlPath = "\(dir)/cyl4.stl"
        try Self.writeTieredCylinderSTL(to: stlPath)
        let bodyId = try await importSTL(stlPath, idPrefix: "cyl4", store: store)

        let result = await MeshFeatureTools.detectMeshFeatures(bodyId: bodyId, render: true, store: store)
        if result.isError && result.text.contains("Metal") { return }   // headless w/o GPU
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(FeatureReport.self, from: Data(result.text.utf8))

        let path = try #require(r.renderPath)
        #expect(FileManager.default.fileExists(atPath: path))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int) ?? 0
        #expect(size > 1_000, "rendered PNG was only \(size) bytes; render may have produced a blank/near-empty image")
    }

    // MARK: - 8. Dispatch: an invalid minAngleDegrees errors

    @MainActor
    @Test("dispatch rejects a non-positive minAngleDegrees instead of silently defaulting")
    func invalidMinAngleIsDispatchError() async throws {
        let result = await dispatch(callName: "detect_mesh_features", arguments: [
            "bodyId": .string("a"),
            "minAngleDegrees": .double(-5),
        ])
        #expect(result.isError == true)
        let text = result.content.compactMap { if case let .text(t, _, _) = $0 { t } else { nil } }.joined()
        #expect(text.contains("minAngleDegrees"))
    }
}
