// Unit tests for TriBVH — the AABB BVH backing mesh_thickness's ray casts.
// No OCCT/mesh involved: builds triangle soups by hand and checks known
// ray-box hits / misses and that a degenerate triangle never reports a
// phantom hit.

import Testing
import simd
@testable import OCCTMCPCore

@Suite("TriBVH: ray-triangle spatial index")
struct TriBVHTests {

    /// A unit square (2 triangles) in the z=0 plane, corners (0,0,0)-(1,1,0).
    static func unitSquare() -> (vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]) {
        let verts: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        ]
        let tris: [(UInt32, UInt32, UInt32)] = [(0, 1, 2), (0, 2, 3)]
        return (verts, tris)
    }

    @Test("a ray straight down through the square hits at the expected distance")
    func directHit() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        let hit = bvh.firstHit(origin: SIMD3(0.5, 0.5, 5), direction: SIMD3(0, 0, -1))
        let h = try #require(hit)
        #expect(abs(h.t - 5) < 1e-9)
        #expect(abs(h.point.z) < 1e-9)
    }

    @Test("a ray outside the square's footprint misses entirely")
    func missOutsideFootprint() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        let hit = bvh.firstHit(origin: SIMD3(5, 5, 5), direction: SIMD3(0, 0, -1))
        #expect(hit == nil)
    }

    @Test("a ray parallel to the square (never crosses its plane) misses")
    func missParallel() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        let hit = bvh.firstHit(origin: SIMD3(0.5, 0.5, 1), direction: SIMD3(1, 0, 0))
        #expect(hit == nil)
    }

    @Test("a ray pointing away from the square (behind tMin) misses")
    func missBehind() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        // Origin is BELOW the plane, ray points further down and away: the
        // plane crossing (if any) would be at negative t.
        let hit = bvh.firstHit(origin: SIMD3(0.5, 0.5, -1), direction: SIMD3(0, 0, -1))
        #expect(hit == nil)
    }

    @Test("nearest of two stacked squares wins, not the farther one")
    func nearestWins() throws {
        // Two unit squares stacked along z: one at z=0, one at z=2. A ray
        // from above must report the z=2 hit (t=3), not the z=0 one (t=5).
        let verts: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 2), SIMD3(1, 0, 2), SIMD3(1, 1, 2), SIMD3(0, 1, 2),
        ]
        let tris: [(UInt32, UInt32, UInt32)] = [(0, 1, 2), (0, 2, 3), (4, 5, 6), (4, 6, 7)]
        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        let hit = try #require(bvh.firstHit(origin: SIMD3(0.5, 0.5, 5), direction: SIMD3(0, 0, -1)))
        #expect(abs(hit.t - 3) < 1e-9)
        #expect(abs(hit.point.z - 2) < 1e-9)
    }

    @Test("a degenerate (zero-area) triangle never reports a phantom hit")
    func degenerateTriangleIsSafelyIgnored() throws {
        // A single degenerate triangle (two coincident vertices) plus one
        // real triangle in the same leaf. A ray that only crosses the
        // degenerate triangle's plane/line must still report nil.
        let verts: [SIMD3<Double>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0),   // degenerate: v0==v1
            SIMD3(10, 10, 0), SIMD3(11, 10, 0), SIMD3(10, 11, 0),  // real, far away
        ]
        let tris: [(UInt32, UInt32, UInt32)] = [(0, 1, 2), (3, 4, 5)]
        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        // Ray toward the degenerate triangle's location only.
        let hit = bvh.firstHit(origin: SIMD3(0.3, 0.01, 5), direction: SIMD3(0, 0, -1))
        #expect(hit == nil)
    }

    @Test("Moller-Trumbore rejects a degenerate triangle directly (det ~ 0)")
    func rayTriangleDegenerateDirect() {
        let a = SIMD3<Double>(0, 0, 0)
        let b = SIMD3<Double>(0, 0, 0)   // coincident with a
        let c = SIMD3<Double>(1, 0, 0)
        let t = TriBVH.rayTriangle(
            origin: SIMD3(0.2, 0, 5), direction: SIMD3(0, 0, -1),
            a: a, b: b, c: c, tMin: 1e-9, tMax: .greatestFiniteMagnitude
        )
        #expect(t == nil)
    }

    @Test("a BVH built from many triangles (forces internal split nodes) still finds the true nearest hit")
    func manyLeafSplit() throws {
        // A 5x5 grid of unit squares in the z=0 plane (50 triangles) —
        // comfortably past TriBVH.leafSize (8), forcing at least one
        // internal split. A ray through the center square must still find
        // exactly that square's hit.
        var verts: [SIMD3<Double>] = []
        var tris: [(UInt32, UInt32, UInt32)] = []
        for gx in 0..<5 {
            for gy in 0..<5 {
                let x0 = Double(gx), y0 = Double(gy)
                let base = UInt32(verts.count)
                verts.append(SIMD3(x0, y0, 0))
                verts.append(SIMD3(x0 + 1, y0, 0))
                verts.append(SIMD3(x0 + 1, y0 + 1, 0))
                verts.append(SIMD3(x0, y0 + 1, 0))
                tris.append((base, base + 1, base + 2))
                tris.append((base, base + 2, base + 3))
            }
        }
        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        let hit = try #require(bvh.firstHit(origin: SIMD3(2.5, 2.5, 9), direction: SIMD3(0, 0, -1)))
        #expect(abs(hit.t - 9) < 1e-9)
        let miss = bvh.firstHit(origin: SIMD3(100, 100, 9), direction: SIMD3(0, 0, -1))
        #expect(miss == nil)
    }

    // ── nearestTriangle / kNearestTriangles (#116) ─────────────────────────

    @Test("nearestTriangle on a unit square finds the exact closest point")
    func nearestTriangleOnUnitSquare() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        let hit = try #require(bvh.nearestTriangle(to: SIMD3(0.5, 0.5, 2)))
        #expect(abs(hit.distance - 2) < 1e-9)
        #expect(abs(hit.point.x - 0.5) < 1e-9)
        #expect(abs(hit.point.y - 0.5) < 1e-9)
        #expect(abs(hit.point.z) < 1e-9)
    }

    @Test("kNearestTriangles rank-1 always matches nearestTriangle, regardless of k")
    func kNearestRank1MatchesNearest() throws {
        let (v, t) = Self.unitSquare()
        let bvh = try #require(TriBVH(vertices: v, triangles: t))
        let nearest = try #require(bvh.nearestTriangle(to: SIMD3(0.5, 0.5, 2)))
        let k1 = try #require(bvh.kNearestTriangles(to: SIMD3(0.5, 0.5, 2), k: 1).first)
        let k2 = try #require(bvh.kNearestTriangles(to: SIMD3(0.5, 0.5, 2), k: 2).first)
        #expect(abs(k1.distance - nearest.distance) < 1e-9)
        #expect(abs(k2.distance - nearest.distance) < 1e-9)
        #expect(k1.triangleIndex == nearest.triangleIndex)
    }

    @Test("kNearestTriangles returns results sorted nearest-first, capped at k")
    func kNearestSortedAndCapped() throws {
        // 5x5 grid (50 triangles): ask for k=5 nearest to a point above the
        // center and confirm strictly non-decreasing distances, count == k.
        var verts: [SIMD3<Double>] = []
        var tris: [(UInt32, UInt32, UInt32)] = []
        for gx in 0..<5 {
            for gy in 0..<5 {
                let x0 = Double(gx), y0 = Double(gy)
                let base = UInt32(verts.count)
                verts.append(SIMD3(x0, y0, 0))
                verts.append(SIMD3(x0 + 1, y0, 0))
                verts.append(SIMD3(x0 + 1, y0 + 1, 0))
                verts.append(SIMD3(x0, y0 + 1, 0))
                tris.append((base, base + 1, base + 2))
                tris.append((base, base + 2, base + 3))
            }
        }
        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        let hits = bvh.kNearestTriangles(to: SIMD3(2.5, 2.5, 3), k: 5)
        #expect(hits.count == 5)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.distance <= $1.distance })
    }

    @Test("nearestTriangle finds a large sparse triangle a k-nearest-VERTEX search would miss (#116)")
    func nearestTriangleFindsLargeSparseTriangle() throws {
        // The exact failure mode reported in #116: ONE huge triangle (a
        // coarsely tessellated planar face) whose three vertices sit far
        // from a query point directly above its CENTER, plus a cluster of
        // small, DENSE triangles nearby whose vertices dominate any
        // k-nearest-vertex neighbourhood. A vertex-based search never even
        // considers the big triangle as a candidate; a triangle-BVH search
        // must still find it as the true global nearest.
        let bigA = SIMD3<Double>(-1000, -1000, 0)
        let bigB = SIMD3<Double>(1000, -1000, 0)
        let bigC = SIMD3<Double>(0, 1000, 0)
        var verts: [SIMD3<Double>] = [bigA, bigB, bigC]
        var tris: [(UInt32, UInt32, UInt32)] = [(0, 1, 2)]

        // A dense cluster of tiny triangles far off to the side (near
        // (500, -900, 0), well away from the query below) so their vertices
        // saturate a small k-nearest-vertex neighbourhood without being
        // anywhere near the actual closest point.
        for i in 0..<200 {
            let cx = 500.0 + Double(i) * 0.01
            let cy = -900.0
            let base = UInt32(verts.count)
            verts.append(SIMD3(cx, cy, 0))
            verts.append(SIMD3(cx + 0.005, cy, 0))
            verts.append(SIMD3(cx, cy + 0.005, 0))
            tris.append((base, base + 1, base + 2))
        }

        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        // Directly above the big triangle's centroid-ish interior, far from
        // its own 3 vertices (each ~1000+ units away) and far from the tiny
        // cluster (~1000+ units away too); the true nearest surface is the
        // big triangle's interior, distance == the query height.
        let query = SIMD3<Double>(0, -300, 50)
        let hit = try #require(bvh.nearestTriangle(to: query))
        #expect(hit.triangleIndex == 0, "expected the big sparse triangle to win, got triangle \(hit.triangleIndex)")
        #expect(abs(hit.distance - 50) < 1e-6, "expected the exact perpendicular distance, got \(hit.distance)")
    }

    @Test("nearestTriangle on a many-leaf tree still finds the true nearest across split boundaries")
    func nearestTriangleAcrossSplits() throws {
        var verts: [SIMD3<Double>] = []
        var tris: [(UInt32, UInt32, UInt32)] = []
        for gx in 0..<5 {
            for gy in 0..<5 {
                let x0 = Double(gx), y0 = Double(gy)
                let base = UInt32(verts.count)
                verts.append(SIMD3(x0, y0, 0))
                verts.append(SIMD3(x0 + 1, y0, 0))
                verts.append(SIMD3(x0 + 1, y0 + 1, 0))
                verts.append(SIMD3(x0, y0 + 1, 0))
                tris.append((base, base + 1, base + 2))
                tris.append((base, base + 2, base + 3))
            }
        }
        let bvh = try #require(TriBVH(vertices: verts, triangles: tris))
        // Directly above the corner square (0,0)-(1,1): nearest point must be
        // exactly the vertical projection, distance 4.
        let hit = try #require(bvh.nearestTriangle(to: SIMD3(0.5, 0.5, 4)))
        #expect(abs(hit.distance - 4) < 1e-9)
    }
}
