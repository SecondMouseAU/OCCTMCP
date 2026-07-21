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
}
