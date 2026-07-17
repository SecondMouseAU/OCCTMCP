// DeviationTools — surface-deviation between two scene bodies. Where
// `measure_distance` returns the *minimum* gap (≈0 for an overlapping
// reconstruction-vs-source pair, hence useless as a fidelity figure), this
// samples one body's tessellated surface and projects each sample onto the
// other body's triangles to report deviation in each direction.
//
// As of #62 the report is a *vector*, not a lone scalar. A symmetric Hausdorff
// hides systematic shape error — a reconstructed carbody whose cross-section is
// the wrong shape *everywhere* still reads as a small mean, because the correct
// faces dominate the samples and the wrong arc averages out. The fix is to also
// report the **sign** (so a constant proud/shy bias shows up as a non-zero
// `signedMean`), a robust **p95** worst-case, and an optional **per-section**
// signed-mean array along an axis (a near-constant non-zero signedMean across
// the stack is the fingerprint of a systematic section offset).
//
// Mesh-based by design: both bodies are typically meshes (an STL source vs a
// STEP reconstruction), and meshing once + a KD-tree is far cheaper than N
// per-point BRep extrema. Fidelity scales with `deflection`. The per-sample
// distance is exact point-to-triangle; the sign comes from the target triangle's
// outward face normal (OCCT meshes a solid with consistent outward winding), so
// signed distance is + outside the reference (proud / over-build) and − inside
// it (shy / missing material).
//
// WHICH target triangle claims the correspondence is the subtle part (#72).
// Taking the nearest one outright breaks against an OPEN, thin-walled reference
// — a raw scan / STL skin whose outer skin and inner wall are a wall-thickness
// apart. A sample sitting past the inner wall is nearer to that inner wall than
// to the outer skin it actually corresponds to, so the inner wall wins and
// contributes both the wrong magnitude and (since its outward normal faces the
// cavity) the wrong sign — confidently, with no tie to flag. `.robust` mode
// gates the correspondence on normal agreement: a reference triangle whose
// outward normal opposes the sample's own is the far side of a wall, never the
// surface the sample corresponds to, so it can neither win nor set the sign.

import Foundation
import OCCTSwift
import simd

public enum DeviationTools {

    /// How a sample picks which reference triangle it corresponds to.
    public enum SignMode: String, Sendable {
        /// The nearest reference triangle wins, whatever it is. Correct against a
        /// watertight / single-surface reference; against an open thin-walled one
        /// the far wall steals the correspondence and the sign lies (#72).
        case nearest
        /// Reference triangles whose outward normal opposes the sample's own are
        /// rejected before the nearest survivor wins (#72). Where no compatible
        /// surface is in reach at all the sample keeps its raw nearest distance
        /// but is flagged `ambiguous` — an honest "sign unknown" beats a guess.
        case robust
    }

    /// The unsigned figures (`max` / `rms` / `mean` / `p95` / `worstPoint`)
    /// measure to the NEAREST reference surface; the signed ones measure to the
    /// surface each sample CORRESPONDS to. Against a watertight reference those
    /// are the same surface and the two families agree. Against an open
    /// thin-walled one they diverge on purpose — `max: 2.5` alongside
    /// `signedMin: -4.5` means the nearest reference geometry is an inner wall
    /// 2.5 away while the skin the sample belongs to is 4.5 above it. Both true,
    /// different questions; `SignMode` steers only the second (#72).
    public struct DirectionStat: Encodable {
        /// Worst unsigned distance to the nearest reference surface.
        public let max: Double
        /// Unsigned RMS.
        public let rms: Double
        /// Unsigned mean.
        public let mean: Double
        /// 95th percentile of |distance| — a robust worst-case that an outlier
        /// triangle can't dominate.
        public let p95: Double
        /// Mean of the *signed* distance. ≠ 0 ⇒ a systematic proud (+) / shy (−)
        /// bias — the figure a symmetric Hausdorff throws away. **nil** when no
        /// sample had a trustworthy sign (`signedSamples == 0`) — the sign
        /// channel is unavailable for this pair, which zero would misreport as
        /// "no bias".
        public let signedMean: Double?
        /// Most-shy (most negative) signed sample — deepest under-build. nil as
        /// for `signedMean`.
        public let signedMin: Double?
        /// Most-proud (most positive) signed sample — worst over-build. nil as
        /// for `signedMean`.
        public let signedMax: Double?
        public let worstPoint: [Double]
        public let samples: Int
        /// Samples backing the three signed figures above — those whose sign is
        /// trustworthy. The unsigned figures use all `samples`; a magnitude stays
        /// valid even where the side doesn't (#72).
        public let signedSamples: Int
        /// Samples whose sign couldn't be established (no normal-compatible
        /// reference surface in reach, or comparably-close candidates
        /// disagreeing). Excluded from signedMean/Min/Max.
        public let ambiguousSamples: Int
        /// `ambiguousSamples / samples`. Near 1.0 means the reference is open /
        /// thin-walled (or its winding is inverted relative to the sampled body)
        /// and the sign channel isn't meaningful for this pair at all.
        public let ambiguousFraction: Double
    }

    /// One station of an along-axis section sweep over the forward (from→to)
    /// samples. A near-constant non-zero `signedMean` across stations is the
    /// fingerprint of a systematic section-shape error.
    public struct SectionStat: Encodable {
        /// Offset of the bin centre along the section axis, measured from the
        /// minimum sample projection.
        public let offset: Double
        public let signedMean: Double
        public let rms: Double
        public let samples: Int
    }

    public struct DeviationReport: Encodable {
        public let from: String
        public let to: String
        public let deflection: Double
        /// Deviation of `from`'s surface measured against `to` (over-extension).
        public let fromToTo: DirectionStat
        /// Deviation of `to`'s surface measured against `from` (under-coverage).
        public let toToFrom: DirectionStat
        /// max(fromToTo.max, toToFrom.max) — the symmetric Hausdorff distance.
        public let symmetricHausdorff: Double
        /// Which correspondence rule chose each sample's reference triangle.
        public let signMode: String
        /// Forward (from→to) signed samples binned along `sectionAxis`. Present
        /// only when a section axis + count was requested.
        public let sections: [SectionStat]?
    }

    public static func measureDeviation(
        fromBodyId: String,
        toBodyId: String,
        deflection: Double? = nil,
        maxSamples: Int = 20_000,
        sectionAxis: SIMD3<Double>? = nil,
        sectionCount: Int = 0,
        signMode: SignMode = .robust,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let fromShape: Shape, toShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            toShape = try IntrospectionTools.loadShape(bodyId: toBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        // Default deflection scales with the model so the bound is meaningful
        // regardless of units/size: 0.5% of the `from` bbox diagonal, floored.
        let defl = deflection ?? defaultDeflection(for: fromShape)
        guard defl > 0 else {
            return .init("deflection must be positive.", isError: true)
        }

        guard let fromTris = TriMesh(shape: fromShape, deflection: defl) else {
            return .init("Failed to tessellate '\(fromBodyId)' for deviation.", isError: true)
        }
        guard let toTris = TriMesh(shape: toShape, deflection: defl) else {
            return .init("Failed to tessellate '\(toBodyId)' for deviation.", isError: true)
        }

        guard let (fwd, fwdSamples) = directedStats(
            source: fromTris, target: toTris, maxSamples: maxSamples, signMode: signMode) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }
        guard let (rev, _) = directedStats(
            source: toTris, target: fromTris, maxSamples: maxSamples, signMode: signMode) else {
            return .init("Deviation computation failed (empty tessellation).", isError: true)
        }

        var sections: [SectionStat]? = nil
        if let axis = sectionAxis, sectionCount >= 2, simd_length(axis) > 1e-12 {
            sections = sectionize(samples: fwdSamples, axis: simd_normalize(axis), bins: sectionCount)
        }

        let report = DeviationReport(
            from: fromBodyId,
            to: toBodyId,
            deflection: defl,
            fromToTo: fwd,
            toToFrom: rev,
            symmetricHausdorff: Swift.max(fwd.max, rev.max),
            signMode: signMode.rawValue,
            sections: sections
        )
        return IntrospectionTools.encode(report)
    }

    // ── tessellation snapshot ───────────────────────────────────────────

    /// One sampled source point and its signed distance to the target.
    struct SignedSample {
        let point: SIMD3<Double>
        let signed: Double
        /// Sign not trustworthy here (#72) — magnitude still is.
        let ambiguous: Bool
    }

    /// Double-precision triangle soup + a KD-tree over vertices, with a
    /// vertex→incident-triangle adjacency for exact point-to-triangle queries.
    struct TriMesh {
        let vertices: [SIMD3<Double>]
        let triangles: [(UInt32, UInt32, UInt32)]
        let kd: KDTree
        let incident: [[Int]]   // vertexIndex → triangle indices

        init?(shape: Shape, deflection: Double) {
            var params = MeshParameters.default
            params.deflection = deflection
            params.internalVertices = true
            params.inParallel = true
            // Re-meshing keeps an existing finer/coarser triangulation unless we
            // allow it to be replaced, so the requested deflection actually takes
            // effect on an already-tessellated import (OCCTSwift #211).
            params.allowQualityDecrease = true
            guard let mesh = shape.mesh(parameters: params) else { return nil }

            let verts = mesh.vertices.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            let idx = mesh.indices
            guard !verts.isEmpty, idx.count >= 3, let kd = KDTree(points: verts) else { return nil }

            var tris: [(UInt32, UInt32, UInt32)] = []
            tris.reserveCapacity(idx.count / 3)
            var adj = [[Int]](repeating: [], count: verts.count)
            var t = 0
            while t + 2 < idx.count {
                let a = idx[t], b = idx[t + 1], c = idx[t + 2]
                let ti = tris.count
                tris.append((a, b, c))
                adj[Int(a)].append(ti)
                adj[Int(b)].append(ti)
                adj[Int(c)].append(ti)
                t += 3
            }
            self.vertices = verts
            self.triangles = tris
            self.kd = kd
            self.incident = adj
        }

        /// Outward face normal of triangle `ti` (unit, or zero if degenerate).
        func faceNormal(_ ti: Int) -> SIMD3<Double> {
            let (a, b, c) = triangles[ti]
            let n = simd_cross(vertices[Int(b)] - vertices[Int(a)],
                               vertices[Int(c)] - vertices[Int(a)])
            let len = simd_length(n)
            return len > 1e-18 ? n / len : SIMD3<Double>(0, 0, 0)
        }

        /// Outward normal at vertex `vi` — normalised sum of its incident face
        /// normals. This is the sample's own surface orientation, which `.robust`
        /// signedQuery matches reference triangles against (#72). Returns zero
        /// where the incident faces cancel (a thin plate's rim, where the two
        /// skins meet), which correctly reads as "no orientation to match".
        func vertexNormal(_ vi: Int) -> SIMD3<Double> {
            var n = SIMD3<Double>(0, 0, 0)
            for ti in incident[vi] { n += faceNormal(ti) }
            let len = simd_length(n)
            return len > 1e-12 ? n / len : SIMD3<Double>(0, 0, 0)
        }
    }

    // ── directed deviation: source samples → nearest point on target ─────

    /// Directed deviation with sign. Returns the aggregate `DirectionStat` plus
    /// the per-sample signed list (for sectioning / histograms).
    static func directedStats(source: TriMesh, target: TriMesh, maxSamples: Int,
                              signMode: SignMode = .robust)
        -> (DirectionStat, [SignedSample])?
    {
        let n = source.vertices.count
        guard n > 0 else { return nil }
        // Stride-subsample the source vertices to honour the sample cap.
        let stride = maxSamples > 0 ? Swift.max(1, (n + maxSamples - 1) / maxSamples) : 1
        let k = 6                      // candidate target vertices per query
        // Reused stamp array dedups incident triangles across the k candidates.
        var stamp = [Int](repeating: -1, count: target.triangles.count)

        var samples: [SignedSample] = []
        samples.reserveCapacity((n + stride - 1) / stride)
        var dists: [Double] = []
        dists.reserveCapacity(samples.capacity)

        var maxD = 0.0
        var sumSq = 0.0
        var sum = 0.0
        var worst = SIMD3<Double>(0, 0, 0)

        var i = 0
        while i < n {
            let p = source.vertices[i]
            // The sample's own outward normal is what lets `.robust` reject the
            // far side of a thin wall as its counterpart (#72).
            let sn = signMode == .robust ? source.vertexNormal(i) : nil
            if let hit = signedQuery(p, normal: sn, target: target, k: k,
                                     stamp: &stamp, stampToken: i, signMode: signMode) {
                // Unsigned figures track the NEAREST surface, which is what they
                // have always meant — the gate only steers the sign channel, so
                // these read the same in 1.17 as before it.
                let d = hit.nearest
                if d > maxD { maxD = d; worst = p }
                sumSq += d * d
                sum += d
                dists.append(d)
                samples.append(SignedSample(point: p, signed: hit.signed, ambiguous: hit.ambiguous))
            }
            i += stride
        }

        let count = samples.count
        guard count > 0 else { return nil }
        dists.sort()

        // Signed aggregates come from sign-RELIABLE samples only (#72): one
        // flipped sign among otherwise-uniform samples both skews the mean — the
        // very figure meant to expose a systematic bias — and can masquerade as
        // the signed extreme. When NOTHING is reliable these are nil, not zero: a
        // zeroed signedMean reads as "perfectly centred", which is a worse lie
        // than the flipped signs it replaced. Magnitudes are unaffected either
        // way, so the unsigned figures above keep every sample.
        let signedVals = samples.filter { !$0.ambiguous }.map(\.signed)
        let ambiguous = count - signedVals.count

        let stat = DirectionStat(
            max: maxD,
            rms: (sumSq / Double(count)).squareRoot(),
            mean: sum / Double(count),
            p95: percentile(dists, 0.95),
            signedMean: signedVals.isEmpty ? nil : signedVals.reduce(0, +) / Double(signedVals.count),
            signedMin: signedVals.min(),
            signedMax: signedVals.max(),
            worstPoint: [worst.x, worst.y, worst.z],
            samples: count,
            signedSamples: signedVals.count,
            ambiguousSamples: ambiguous,
            ambiguousFraction: Double(ambiguous) / Double(count)
        )
        return (stat, samples)
    }

    /// Result of a signed-distance query. Carries TWO distances, because the two
    /// questions have different answers against an open thin-walled reference:
    ///
    ///  • `nearest` — unsigned distance to the closest reference surface, full
    ///    stop. The Hausdorff-style magnitude. Independent of `SignMode`, so the
    ///    figures built on it mean in 1.17 exactly what they meant before it.
    ///  • `signed` — signed distance to the surface this sample CORRESPONDS to,
    ///    which is the fidelity question ("how far from where it should be, and
    ///    which side"). Under `.nearest` the correspondence IS the closest
    ///    triangle, so `abs(signed) == nearest`. Under `.robust` the far side of
    ///    a wall is excluded from the running, so `abs(signed) >= nearest` — a
    ///    flank 4.5 shy of a 2mm wall reports `nearest: 2.5` (the inner surface
    ///    really is 2.5 away) and `signed: -4.5` (the skin it belongs to is 4.5
    ///    above it). Both are true; they answer different questions.
    ///
    /// `ambiguous` marks `signed`'s SIGN as untrustworthy — never `nearest`, and
    /// never the magnitude. It covers the three ways the side can't be settled,
    /// all of them open-thin-wall symptoms (#72): a comparably-close candidate
    /// disagrees on the side (the winner was a coin flip); `.robust` found no
    /// normal-compatible surface in reach at all; or the sample supplied no
    /// usable orientation of its own to match against.
    struct SignedHit {
        let nearest: Double
        let signed: Double
        let ambiguous: Bool
    }

    /// Neighbourhood the `.robust` gate widens to when a sample's whole k-nearest
    /// set turns out to be the far wall (#72) — it has to reach past every one of
    /// the near wall's vertices to see the far one.
    ///
    /// Sizing this is not intuitive, because these meshes are unshared triangle
    /// soups: OCCT hands back three vertices PER TRIANGLE with no sharing (a
    /// 576-triangle test wall carries 1728 vertices), so the vertex count is ~6×
    /// what a shared-index mesh would give and the neighbourhood must be ~6×
    /// wider to span the same surface. The near wall's vertices within reach of a
    /// sample go as ~3·π·d²/spacing², which at a 2mm wall and sub-mm spacing runs
    /// to several hundred — 256 was silently too small and greyed out the very
    /// case this exists to fix.
    ///
    /// Bounded rather than unbounded because a scan-scale heatmap samples every
    /// triangle: past this, the sample reports `ambiguous`, which is the honest
    /// answer and never a wrong one.
    ///
    /// Only samples that fail the gate outright pay for the widen, so a
    /// well-registered pair costs nothing. The pathological end — a candidate
    /// entirely behind the wrong wall, so EVERY sample widens — measured 13s vs
    /// 0.3s for 20k samples against a 400k-triangle reference. That's the price
    /// of the right answer where the cheap one is confidently inverted.
    static let widenedK = 1024

    /// One reference triangle in the running for a sample's correspondence.
    private struct Candidate {
        let distance: Double
        /// Is the sample on this triangle's outward side?
        let positive: Bool
        /// Does this triangle's outward normal agree with the sample's own? False
        /// ⇒ the far side of a wall, not the sample's counterpart (#72).
        let compatible: Bool
    }

    /// Signed distance from `p` to the target surface, using a shared `stamp`
    /// array for incident-triangle dedup across the k nearest candidates.
    /// `stampToken` must be unique per query (the source sample index works).
    ///
    /// `normal` is the sample's OWN outward surface normal. Supplied in `.robust`
    /// mode it gates which reference triangles may claim the correspondence, so
    /// an open thin-walled reference's far wall can't win on proximity and invert
    /// the sign (#72). Omit it (or pass `.nearest`) for the raw nearest triangle.
    static func signedQuery(
        _ p: SIMD3<Double>,
        normal: SIMD3<Double>? = nil,
        target: TriMesh,
        k: Int,
        stamp: inout [Int],
        stampToken: Int,
        signMode: SignMode = .robust
    ) -> SignedHit? {
        // The sample's own orientation is what makes the gate possible. No normal
        // at all means the caller opted out — degrade to nearest-triangle quietly.
        // A ZERO normal is different: the caller wanted the gate but this sample
        // has no orientation to match (a thin plate's rim, where the two skins'
        // faces cancel), so there's no correspondence to establish and the sign
        // can't be trusted even though a winner will still be picked.
        var srcN: SIMD3<Double>? = nil
        var unorientedSample = false
        if signMode == .robust, let n = normal {
            if simd_length(n) > 1e-12 { srcN = simd_normalize(n) } else { unorientedSample = true }
        }

        var candidates: [Candidate] = []
        func gather(_ vertexIndices: [Int]) {
            for vi in vertexIndices {
                for ti in target.incident[vi] where stamp[ti] != stampToken {
                    stamp[ti] = stampToken
                    let (a, b, c) = target.triangles[ti]
                    let cp = closestPointOnTriangle(p, target.vertices[Int(a)],
                                                    target.vertices[Int(b)],
                                                    target.vertices[Int(c)])
                    let d = simd_length(p - cp)
                    // A degenerate triangle can drive closestPointOnTriangle to a
                    // non-finite point. `min(by:)` has no NaN-rejecting behaviour
                    // to lean on the way the old `if d < best` scan did, so drop
                    // those here rather than let one poison the winner.
                    guard d.isFinite else { continue }
                    let nrm = target.faceNormal(ti)
                    candidates.append(Candidate(
                        distance: d,
                        positive: simd_dot(p - cp, nrm) >= 0,
                        compatible: srcN.map { simd_dot(nrm, $0) > 0 } ?? true))
                }
            }
        }

        // No triangle context anywhere — report the bare vertex distance, sign 0.
        func vertexFallback() -> SignedHit? {
            guard let nv = target.kd.nearest(to: p) else { return nil }
            return SignedHit(nearest: nv.distance, signed: nv.distance, ambiguous: false)
        }

        let neighbours = target.kd.kNearest(to: p, k: k)
        if neighbours.isEmpty { return vertexFallback() }
        gather(neighbours.map { $0.index })
        // Nearest vertices had no incident triangles (isolated) — fall back.
        if candidates.isEmpty { return vertexFallback() }

        // Drop the triangles that can't be this sample's counterpart. If the whole
        // k-neighbourhood is the far wall the real counterpart is further out but
        // still local, so widen once. kNearest rather than rangeSearch: a radius
        // search truncates at maxResults in unspecified order, so it can drop the
        // very triangle being hunted, while kNearest truncates by DISTANCE —
        // exactly the ordering this search is defined by.
        var pool: [Candidate]
        var noCounterpart = false
        if srcN != nil {
            var compatible = candidates.filter(\.compatible)
            if compatible.isEmpty, k < widenedK {
                gather(target.kd.kNearest(to: p, k: widenedK).map { $0.index })
                compatible = candidates.filter(\.compatible)
            }
            if compatible.isEmpty {
                noCounterpart = true      // sign genuinely unknowable here
                pool = candidates         // post-widen, so |signed| still == nearest
            } else {
                pool = compatible
            }
        } else {
            pool = candidates
        }

        // `nearest` is the closest surface FULL STOP — over every candidate, never
        // the gated pool. It's what max / rms / p95 / symmetricHausdorff are
        // defined as, so the gate must not move them; only the sign channel below
        // is allowed to prefer the corresponding surface over the closest one.
        guard let closest = candidates.min(by: { $0.distance < $1.distance }),
              let win = pool.min(by: { $0.distance < $1.distance }) else { return nil }
        let signedDist = win.positive ? win.distance : -win.distance

        // Tie band: candidates within 15% of the winning distance are "comparably
        // close" — if any of them disagree on side, the winner was a coin flip.
        let tieBand = win.distance * 1.15 + 1e-9
        let disagree = pool.contains { $0.distance <= tieBand && $0.positive != win.positive }

        return SignedHit(nearest: closest.distance, signed: signedDist,
                         ambiguous: noCounterpart || disagree || unorientedSample)
    }

    /// Per-vertex signed-distance field for an arbitrary mesh's vertices against
    /// a reference `TriMesh`. Used by the heatmap (per-triangle centroid) and the
    /// histogram. No subsampling — every supplied point is queried.
    ///
    /// `normals[i]` is point i's own outward normal; supply it (and `.robust`) to
    /// get the normal-compatible correspondence of #72. Passing normals that
    /// aren't 1:1 with the points is a caller bug — it traps in debug, and in
    /// release degrades to nearest-triangle rather than mis-pairing a normal with
    /// someone else's point, which would corrupt the gate silently.
    static func signedDistances(
        of points: [SIMD3<Double>],
        normals: [SIMD3<Double>]? = nil,
        to target: TriMesh,
        signMode: SignMode = .robust
    ) -> [SignedHit] {
        assert(normals == nil || normals!.count == points.count,
               "signedDistances: normals must be 1:1 with points")
        var stamp = [Int](repeating: -1, count: target.triangles.count)
        var out = [SignedHit](repeating: SignedHit(nearest: 0, signed: 0, ambiguous: false),
                              count: points.count)
        let ns = normals?.count == points.count ? normals : nil
        for (i, p) in points.enumerated() {
            if let hit = signedQuery(p, normal: ns?[i], target: target, k: 6,
                                     stamp: &stamp, stampToken: i, signMode: signMode) {
                out[i] = hit
            }
        }
        return out
    }

    // ── per-section binning ──────────────────────────────────────────────

    /// Bin forward samples by their projection onto `axis` (unit) into `bins`
    /// equal-width stations, reporting per-station signed-mean / RMS.
    ///
    /// Sign-ambiguous samples (#72) are excluded from the per-station figures — a
    /// station's signed mean exists to expose a systematic section offset, which
    /// is exactly the fingerprint a flipped sign fakes. They still define the
    /// axis SPAN though: `offset` is documented as measured from the body's
    /// minimum projection, so deriving lo/hi from the reliable subset alone would
    /// silently re-base every station and rescale the bin width the moment
    /// ambiguity clipped an extreme (an end cap, say). Stations left with no
    /// reliable sample are simply omitted.
    static func sectionize(samples: [SignedSample], axis: SIMD3<Double>, bins: Int) -> [SectionStat] {
        guard !samples.isEmpty, bins >= 2 else { return [] }
        var ts = [Double](repeating: 0, count: samples.count)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for (i, s) in samples.enumerated() {
            let t = simd_dot(s.point, axis)
            ts[i] = t
            if t < lo { lo = t }
            if t > hi { hi = t }
        }
        let span = hi - lo
        guard span > 1e-12 else { return [] }
        let width = span / Double(bins)

        var signedSum = [Double](repeating: 0, count: bins)
        var sqSum = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        for (i, s) in samples.enumerated() where !s.ambiguous {
            var b = Int((ts[i] - lo) / width)
            if b >= bins { b = bins - 1 }
            if b < 0 { b = 0 }
            signedSum[b] += s.signed
            sqSum[b] += s.signed * s.signed
            counts[b] += 1
        }

        var out: [SectionStat] = []
        out.reserveCapacity(bins)
        for b in 0..<bins where counts[b] > 0 {
            let c = Double(counts[b])
            out.append(SectionStat(
                offset: (Double(b) + 0.5) * width,
                signedMean: signedSum[b] / c,
                rms: (sqSum[b] / c).squareRoot(),
                samples: counts[b]
            ))
        }
        return out
    }

    // ── geometry helpers ────────────────────────────────────────────────

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[Swift.min(Swift.max(idx, 0), sorted.count - 1)]
    }

    static func defaultDeflection(for shape: Shape) -> Double {
        let b = shape.bounds
        let diag = simd_length(b.max - b.min)
        // 0.5% of the diagonal, with a 1µm floor for degenerate/tiny shapes.
        return Swift.max(diag * 0.005, 1e-6)
    }

    /// Closest point on triangle (a,b,c) to `p`.
    /// Ericson "Real-Time Collision Detection" §5.1.5.
    static func closestPointOnTriangle(
        _ p: SIMD3<Double>,
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>
    ) -> SIMD3<Double> {
        let ab = b - a
        let ac = c - a
        let ap = p - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }                               // vertex A

        let bp = p - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }                              // vertex B

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {                                // edge AB
            let v = d1 / (d1 - d3)
            return a + v * ab
        }

        let cp = p - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }                              // vertex C

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {                                // edge AC
            let w = d2 / (d2 - d6)
            return a + w * ac
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {                  // edge BC
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + w * (c - b)
        }

        // Interior — barycentric projection onto the triangle plane.
        let denom = 1.0 / (va + vb + vc)
        let v = vb * denom
        let w = vc * denom
        return a + ab * v + ac * w
    }

    /// Exact distance from point `p` to triangle (a,b,c). Retained for callers
    /// that only need the magnitude.
    static func pointTriangleDistance(
        _ p: SIMD3<Double>,
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>
    ) -> Double {
        simd_length(p - closestPointOnTriangle(p, a, b, c))
    }
}
