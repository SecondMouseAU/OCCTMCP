// TriBVH: a minimal AABB bounding-volume hierarchy over a triangle soup,
// for ray-triangle nearest-hit queries AND exact nearest-triangle-to-point
// queries. Backs `mesh_thickness` (Phase 2): the ray method samples up to
// `maxSamples` surface points and casts a ray from each along its inward
// normal, and brute-forcing that against a 400k-triangle scan (2000 samples
// × 400k tris ≈ 800M ray-triangle tests) is not acceptable within the
// 2-minute request budget. `DeviationTools.TriMesh` builds one of these too
// (#116, see below) for its own correspondence search.
//
// `DeviationTools.TriMesh` also indexes VERTICES (a KD-tree, for nearest-
// point queries), but a vertex index has no triangle-level spatial index:
// a ray query needs to cull whole TRIANGLES by their bounding box, not walk
// from a nearby vertex outward. Hence a separate, small structure here
// rather than extending TriMesh directly (`TriMesh.bvh` wraps one).
//
// `nearestTriangle`/`kNearestTriangles` (#116) exist because a k-nearest-
// VERTEX search, which is what DeviationTools.signedQuery used before this,
// is not a nearest-TRIANGLE search: a large, low-curvature triangle's
// closest point to a query can sit far from all three of its own vertices
// (a coarsely tessellated planar/cylindrical solid face is the common case),
// so none of its vertices land in even a generously sized k-nearest-vertex
// set and the triangle is never gathered as a candidate at all, reported
// as overstating `measure_deviation`'s `max`/`p95`/`symmetricHausdorff` by
// 15x-317x on real fixtures (OCCTMCP#116). Pruning branch-and-bound directly
// on each TRIANGLE's own bounding box (not its vertices) is what makes this
// exhaustive regardless of triangle size: a subtree is only skipped when its
// bounding box is PROVABLY farther than the current best, which is a correct
// admissible bound for the triangles inside it.
//
// Deliberately unsophisticated per the design brief ("nothing fancy"):
// median-split on the longest axis (re-sorting the node's own triangle
// range by centroid each split: O(n log^2 n) build, not O(n log n), but
// this runs once per tool call and n is bounded by the mesh's own triangle
// count), leaf size ~8, no SAH, no parallel build.

import Foundation
import simd

/// AABB BVH over a triangle soup (vertices + (a,b,c) index triples, the
/// same representation `DeviationTools.TriMesh` uses), supporting nearest-
/// hit ray queries via Möller–Trumbore.
struct TriBVH {
    /// A ray-triangle hit: `point` is `origin + direction * t` (so `t` is a
    /// true distance only when `direction` is unit-length, which every
    /// caller here supplies).
    struct Hit {
        let t: Double
        let triangleIndex: Int
        let point: SIMD3<Double>
    }

    private final class Node {
        var boundsMin: SIMD3<Double>
        var boundsMax: SIMD3<Double>
        var left: Node?
        var right: Node?
        /// Populated on leaves only.
        var triangleIndices: [Int] = []
        init(boundsMin: SIMD3<Double>, boundsMax: SIMD3<Double>) {
            self.boundsMin = boundsMin
            self.boundsMax = boundsMax
        }
        var isLeaf: Bool { left == nil && right == nil }
    }

    private let vertices: [SIMD3<Double>]
    private let triangles: [(UInt32, UInt32, UInt32)]
    private let root: Node

    static let leafSize = 8

    /// Builds the tree eagerly. `nil` for empty input.
    init?(vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]) {
        guard !vertices.isEmpty, !triangles.isEmpty else { return nil }
        self.vertices = vertices
        self.triangles = triangles
        var order = Array(0..<triangles.count)
        guard
            let r = TriBVH.build(
                indices: &order, vertices: vertices, triangles: triangles, range: 0..<order.count
            )
        else { return nil }
        self.root = r
    }

    // MARK: - Build

    private static func triBounds(
        _ ti: Int, vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]
    )
        -> (SIMD3<Double>, SIMD3<Double>)
    {
        let (a, b, c) = triangles[ti]
        let pa = vertices[Int(a)]
        let pb = vertices[Int(b)]
        let pc = vertices[Int(c)]
        return (simd_min(pa, simd_min(pb, pc)), simd_max(pa, simd_max(pb, pc)))
    }

    private static func rangeBounds(
        _ range: Range<Int>, order: [Int], vertices: [SIMD3<Double>],
        triangles: [(UInt32, UInt32, UInt32)]
    ) -> (SIMD3<Double>, SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for i in range {
            let (tlo, thi) = triBounds(order[i], vertices: vertices, triangles: triangles)
            lo = simd_min(lo, tlo)
            hi = simd_max(hi, thi)
        }
        return (lo, hi)
    }

    private static func build(
        indices order: inout [Int], vertices: [SIMD3<Double>],
        triangles: [(UInt32, UInt32, UInt32)],
        range: Range<Int>
    ) -> Node? {
        guard !range.isEmpty else { return nil }
        let (lo, hi) = rangeBounds(range, order: order, vertices: vertices, triangles: triangles)
        let node = Node(boundsMin: lo, boundsMax: hi)

        if range.count <= leafSize {
            node.triangleIndices = Array(order[range])
            return node
        }

        // Median-split on the longest axis of this node's own bounding box.
        let extent = hi - lo
        let axis: Int =
            (extent.x >= extent.y && extent.x >= extent.z) ? 0 : (extent.y >= extent.z ? 1 : 2)
        func centroid(_ ti: Int) -> Double {
            let (a, b, c) = triangles[ti]
            let pa = vertices[Int(a)]
            let pb = vertices[Int(b)]
            let pc = vertices[Int(c)]
            return ((pa + pb + pc) / 3)[axis]
        }
        let sortedSlice = order[range].sorted { centroid($0) < centroid($1) }
        for (offset, value) in sortedSlice.enumerated() {
            order[range.lowerBound + offset] = value
        }

        let mid = range.lowerBound + range.count / 2
        node.left = build(
            indices: &order, vertices: vertices, triangles: triangles, range: range.lowerBound..<mid
        )
        node.right = build(
            indices: &order, vertices: vertices, triangles: triangles, range: mid..<range.upperBound
        )
        return node
    }

    // MARK: - Query

    /// Nearest ray-triangle hit along `direction` (should be unit-length so
    /// `t`/`point` behave as documented) from `origin`, with `t` in
    /// `(tMin, tMax]`.
    ///
    /// No back-face culling: a thickness ray must hit the
    /// interior surface it's cast toward regardless of that triangle's
    /// winding.
    func firstHit(
        origin: SIMD3<Double>, direction: SIMD3<Double>,
        tMin: Double = 1e-9, tMax: Double = .greatestFiniteMagnitude
    ) -> Hit? {
        var bestT = tMax
        var best: Hit? = nil
        TriBVH.traverse(
            root, origin: origin, direction: direction, tMin: tMin,
            bestT: &bestT, best: &best, vertices: vertices, triangles: triangles
        )
        return best
    }

    private static func traverse(
        _ node: Node, origin: SIMD3<Double>, direction: SIMD3<Double>, tMin: Double,
        bestT: inout Double, best: inout Hit?,
        vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]
    ) {
        guard
            rayIntersectsAABB(
                origin: origin, direction: direction,
                boundsMin: node.boundsMin, boundsMax: node.boundsMax, tMin: tMin, tMax: bestT
            )
        else { return }

        if node.isLeaf {
            for ti in node.triangleIndices {
                let (a, b, c) = triangles[ti]
                if let t = rayTriangle(
                    origin: origin, direction: direction,
                    a: vertices[Int(a)], b: vertices[Int(b)], c: vertices[Int(c)],
                    tMin: tMin, tMax: bestT
                ), t < bestT {
                    bestT = t
                    best = Hit(t: t, triangleIndex: ti, point: origin + direction * t)
                }
            }
            return
        }
        if let l = node.left {
            traverse(
                l, origin: origin, direction: direction, tMin: tMin, bestT: &bestT, best: &best,
                vertices: vertices, triangles: triangles)
        }
        if let r = node.right {
            traverse(
                r, origin: origin, direction: direction, tMin: tMin, bestT: &bestT, best: &best,
                vertices: vertices, triangles: triangles)
        }
    }

    // MARK: - Nearest-triangle-to-point query (#116)

    /// One triangle in the running for a nearest-point query: the closest
    /// point ON that triangle to the query, and the (exact) distance to it.
    struct NearestHit {
        let triangleIndex: Int
        let point: SIMD3<Double>
        let distance: Double
    }

    /// The EXACT nearest triangle (by point-to-triangle distance) to `p`,
    /// full stop, not an approximation via nearby vertices. `nil` only for
    /// an empty tree, which `init?` already rules out.
    func nearestTriangle(to p: SIMD3<Double>) -> NearestHit? {
        var bestDist = Double.infinity
        var best: NearestHit? = nil
        TriBVH.nearestTraverse(
            root, p: p, bestDist: &bestDist, best: &best, vertices: vertices, triangles: triangles)
        return best
    }

    /// The exact `k` nearest triangles (by point-to-triangle distance) to
    /// `p`, sorted nearest-first.
    ///
    /// Rank 1 is always identical to
    /// `nearestTriangle(to:)` regardless of `k`: both are exact, `k` only
    /// controls how many of the close-but-not-closest candidates come back,
    /// which is what a correspondence gate (normal compatibility, tie-band
    /// disagreement) needs beyond the single winner.
    func kNearestTriangles(to p: SIMD3<Double>, k: Int) -> [NearestHit] {
        guard k > 0 else { return [] }
        var heap: [NearestHit] = []  // kept sorted ascending by distance, capped at k
        heap.reserveCapacity(k)
        TriBVH.kNearestTraverse(
            root, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
        return heap
    }

    /// Squared distance from `p` to its closest point INSIDE the box
    /// `[boundsMin, boundsMax]` (0 if `p` is inside).
    ///
    /// An admissible lower
    /// bound on the distance from `p` to anything the box contains, which is
    /// what makes pruning by it exact rather than heuristic.
    private static func pointAABBDistanceSquared(
        _ p: SIMD3<Double>, boundsMin: SIMD3<Double>, boundsMax: SIMD3<Double>
    ) -> Double {
        let c = simd_clamp(p, boundsMin, boundsMax)
        let d = p - c
        return simd_length_squared(d)
    }

    private static func nearestTraverse(
        _ node: Node, p: SIMD3<Double>, bestDist: inout Double, best: inout NearestHit?,
        vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]
    ) {
        guard
            pointAABBDistanceSquared(p, boundsMin: node.boundsMin, boundsMax: node.boundsMax)
                <= bestDist * bestDist
        else { return }

        if node.isLeaf {
            for ti in node.triangleIndices {
                let (a, b, c) = triangles[ti]
                let cp = DeviationTools.closestPointOnTriangle(
                    p, vertices[Int(a)], vertices[Int(b)], vertices[Int(c)])
                let d = simd_length(p - cp)
                guard d.isFinite, d < bestDist else { continue }
                bestDist = d
                best = NearestHit(triangleIndex: ti, point: cp, distance: d)
            }
            return
        }
        guard let l = node.left, let r = node.right else {
            if let only = node.left ?? node.right {
                nearestTraverse(
                    only, p: p, bestDist: &bestDist, best: &best, vertices: vertices,
                    triangles: triangles)
            }
            return
        }
        // Visit the nearer child first so `bestDist` tightens as early as
        // possible, maximising how much the farther child's own bound prunes.
        let ld = pointAABBDistanceSquared(p, boundsMin: l.boundsMin, boundsMax: l.boundsMax)
        let rd = pointAABBDistanceSquared(p, boundsMin: r.boundsMin, boundsMax: r.boundsMax)
        if ld <= rd {
            nearestTraverse(
                l, p: p, bestDist: &bestDist, best: &best, vertices: vertices, triangles: triangles)
            nearestTraverse(
                r, p: p, bestDist: &bestDist, best: &best, vertices: vertices, triangles: triangles)
        } else {
            nearestTraverse(
                r, p: p, bestDist: &bestDist, best: &best, vertices: vertices, triangles: triangles)
            nearestTraverse(
                l, p: p, bestDist: &bestDist, best: &best, vertices: vertices, triangles: triangles)
        }
    }

    private static func kNearestTraverse(
        _ node: Node, p: SIMD3<Double>, k: Int, heap: inout [NearestHit],
        vertices: [SIMD3<Double>], triangles: [(UInt32, UInt32, UInt32)]
    ) {
        let boxDist2 = pointAABBDistanceSquared(
            p, boundsMin: node.boundsMin, boundsMax: node.boundsMax)
        if heap.count >= k, let worst = heap.last, boxDist2 > worst.distance * worst.distance {
            return
        }

        if node.isLeaf {
            for ti in node.triangleIndices {
                let (a, b, c) = triangles[ti]
                let cp = DeviationTools.closestPointOnTriangle(
                    p, vertices[Int(a)], vertices[Int(b)], vertices[Int(c)])
                let d = simd_length(p - cp)
                guard d.isFinite else { continue }
                if heap.count < k {
                    let insertAt = heap.firstIndex { $0.distance > d } ?? heap.count
                    heap.insert(NearestHit(triangleIndex: ti, point: cp, distance: d), at: insertAt)
                } else if let worst = heap.last, d < worst.distance {
                    heap.removeLast()
                    let insertAt = heap.firstIndex { $0.distance > d } ?? heap.count
                    heap.insert(NearestHit(triangleIndex: ti, point: cp, distance: d), at: insertAt)
                }
            }
            return
        }
        guard let l = node.left, let r = node.right else {
            if let only = node.left ?? node.right {
                kNearestTraverse(
                    only, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
            }
            return
        }
        let ld = pointAABBDistanceSquared(p, boundsMin: l.boundsMin, boundsMax: l.boundsMax)
        let rd = pointAABBDistanceSquared(p, boundsMin: r.boundsMin, boundsMax: r.boundsMax)
        if ld <= rd {
            kNearestTraverse(l, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
            kNearestTraverse(r, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
        } else {
            kNearestTraverse(r, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
            kNearestTraverse(l, p: p, k: k, heap: &heap, vertices: vertices, triangles: triangles)
        }
    }

    /// Slab method. `tMax` is passed as the current best hit distance so a
    /// box entirely farther than an already-found hit is culled without
    /// descending into it.
    private static func rayIntersectsAABB(
        origin: SIMD3<Double>, direction: SIMD3<Double>,
        boundsMin: SIMD3<Double>, boundsMax: SIMD3<Double>, tMin: Double, tMax: Double
    ) -> Bool {
        var t0 = tMin
        var t1 = tMax
        for axis in 0..<3 {
            let d = direction[axis]
            let invD = d != 0 ? 1.0 / d : (d >= 0 ? Double.infinity : -Double.infinity)
            var tNear = (boundsMin[axis] - origin[axis]) * invD
            var tFar = (boundsMax[axis] - origin[axis]) * invD
            if tNear.isNaN { tNear = -.infinity }
            if tFar.isNaN { tFar = .infinity }
            if tNear > tFar { swap(&tNear, &tFar) }
            t0 = max(t0, tNear)
            t1 = min(t1, tFar)
            if t0 > t1 { return false }
        }
        return true
    }

    /// Möller–Trumbore ray-triangle intersection.
    ///
    /// Returns `t` (along
    /// `direction`, which the caller is responsible for normalising if it
    /// wants `t` to read as a true distance) when the hit lands within
    /// `[tMin, tMax]` and inside the triangle (with a small epsilon on the
    /// barycentric bounds to admit edge-on hits), else `nil`. A degenerate
    /// (zero-area) triangle drives `det` to ~0 and is safely rejected;
    /// never reports a phantom hit.
    static func rayTriangle(
        origin: SIMD3<Double>, direction: SIMD3<Double>,
        a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>,
        tMin: Double, tMax: Double
    ) -> Double? {
        let eps = 1e-12
        let e1 = b - a
        let e2 = c - a
        let pvec = simd_cross(direction, e2)
        let det = simd_dot(e1, pvec)
        guard abs(det) > eps else { return nil }
        let invDet = 1.0 / det
        let tvec = origin - a
        let u = simd_dot(tvec, pvec) * invDet
        guard u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        let qvec = simd_cross(tvec, e1)
        let v = simd_dot(direction, qvec) * invDet
        guard v >= -1e-9, u + v <= 1 + 1e-9 else { return nil }
        let t = simd_dot(e2, qvec) * invDet
        guard t >= tMin, t <= tMax, t.isFinite else { return nil }
        return t
    }
}
