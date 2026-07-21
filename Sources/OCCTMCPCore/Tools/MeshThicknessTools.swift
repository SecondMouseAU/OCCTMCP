// MeshThicknessTools — `mesh_thickness` (Phase 2 of the mesh-analysis
// expansion). The mesh-domain complement to the BREP-only `check_thickness`
// (EngineeringTools.swift), which degrades on facet shells (a raw STL
// import is one BREP face per facet — see CLAUDE.md's tool table). This
// tool never touches BREP topology at all: it works directly on the
// tessellated surface via the ray (normal-opposite, first-hit) method.
//
// Pipeline: mesh (same MeshParameters recipe as DeviationTools.TriMesh /
// MeshZoneTools) -> TriBVH over its triangles -> stride-subsample vertices
// (mirrors DeviationTools.directedStats' maxSamples convention) -> for each
// sample, cast from `p - 1e-4*n` along `-n` (the tiny epsilon nudge is so
// the ray's own origin triangle isn't itself the first hit) -> first hit
// distance is the local thickness. A ray that exits without hitting
// anything (an open shell, or a sample whose own vertex normal is zero —
// two coincident-but-oppositely-wound skins meeting at a rim) is excluded
// from the stats and counted in `noHitSamples`.
//
// Optional cone averaging (`coneAngleDegrees > 0`) casts 5 rays — the
// sample's own inward direction plus 4 more at the cone's angular boundary,
// evenly spaced in azimuth — and takes the MEDIAN hit distance (the SDF/
// signed-distance-field convention for a robust local thickness estimate,
// less sensitive to one ray grazing a nearby feature than a single ray).
// This is a deterministic fixed pattern, not randomized jitter, so a repeat
// call on the same body produces byte-identical output.

import Foundation
import OCCTSwift
import simd
import ScriptHarness

public enum MeshThicknessTools {

    public struct ThicknessReport: Encodable {
        public let bodyId: String
        public let samples: Int
        public let noHitSamples: Int
        public let thicknessMm: Stat
        public let belowThreshold: BelowThreshold?
        public let chartPath: String?
        public let warnings: [String]

        public struct Stat: Encodable {
            public let min: Double
            public let p05: Double
            public let median: Double
            public let mean: Double
            public let p95: Double
            public let max: Double
        }
        public struct BelowThreshold: Encodable {
            public let thresholdMm: Double
            public let count: Int
            /// Fraction of samples that produced a measurable thickness
            /// (`samples - noHitSamples`) falling below `thresholdMm` — NOT
            /// a fraction of `samples`, since a noHit sample has no
            /// thickness to compare against the threshold at all.
            public let fraction: Double
            public let worst: [WorstPoint]
        }
        public struct WorstPoint: Encodable {
            public let point: [Double]
            public let thicknessMm: Double
        }
    }

    static let worstPointsCap = 8
    static let noHitWarnFraction = 0.2
    static let coneRayCount = 5

    @MainActor
    public static func meshThickness(
        bodyId: String,
        maxSamples: Int = 2000,
        deflection: Double? = nil,
        thresholdMm: Double? = nil,
        coneAngleDegrees: Double = 0,
        chart: Bool = false,
        chartPath: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        let defl = deflection ?? DeviationTools.defaultDeflection(for: shape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }
        guard maxSamples > 0 else { return .init("maxSamples must be positive.", isError: true) }
        guard coneAngleDegrees >= 0, coneAngleDegrees < 90 else {
            return .init("coneAngleDegrees must be in [0, 90).", isError: true)
        }
        if let thr = thresholdMm, thr < 0 {
            return .init("thresholdMm must be >= 0.", isError: true)
        }

        guard let tri = DeviationTools.TriMesh(shape: shape, deflection: defl) else {
            return .init("Failed to tessellate '\(bodyId)' for thickness.", isError: true)
        }
        guard let bvh = TriBVH(vertices: tri.vertices, triangles: tri.triangles) else {
            return .init("Failed to build a spatial index for '\(bodyId)' (empty tessellation).", isError: true)
        }

        var warnings: [String] = []
        let n = tri.vertices.count
        let stride = max(1, (n + maxSamples - 1) / maxSamples)

        var thicknesses: [Double] = []
        var below: [(point: SIMD3<Double>, thicknessMm: Double)] = []
        var noHit = 0
        var totalSamples = 0

        var i = 0
        while i < n {
            totalSamples += 1
            let p = tri.vertices[i]
            let normal = tri.vertexNormal(i)
            if simd_length(normal) > 1e-9,
               let d = castThickness(bvh: bvh, point: p, outward: normal, coneAngleDegrees: coneAngleDegrees) {
                thicknesses.append(d)
                if let thr = thresholdMm, d < thr {
                    below.append((p, d))
                }
            } else {
                noHit += 1
            }
            i += stride
        }

        if totalSamples > 0 {
            let noHitFraction = Double(noHit) / Double(totalSamples)
            if noHitFraction > noHitWarnFraction {
                warnings.append(
                    "\(noHit)/\(totalSamples) sample rays (\(Int((noHitFraction * 100).rounded()))%) found no hit — " +
                    "likely an open shell along the sampled surface normals (or a zero-normal rim). " +
                    "thicknessMm stats exclude these."
                )
            }
        }

        let stat: ThicknessReport.Stat
        if thicknesses.isEmpty {
            stat = .init(min: 0, p05: 0, median: 0, mean: 0, p95: 0, max: 0)
            warnings.append(
                "No hits: thickness could not be measured for any sample (a fully open shell along every " +
                "sampled normal, or geometry thinner than the internal offset epsilon)."
            )
        } else {
            let sorted = thicknesses.sorted()
            let mean = thicknesses.reduce(0, +) / Double(thicknesses.count)
            stat = .init(
                min: sorted.first!,
                p05: DeviationTools.percentile(sorted, 0.05),
                median: DeviationTools.percentile(sorted, 0.5),
                mean: mean,
                p95: DeviationTools.percentile(sorted, 0.95),
                max: sorted.last!
            )
        }

        var belowEntry: ThicknessReport.BelowThreshold? = nil
        if let thr = thresholdMm {
            let sortedBelow = below.sorted { $0.thicknessMm < $1.thicknessMm }
            if sortedBelow.count > worstPointsCap {
                warnings.append(
                    "belowThreshold.worst capped at \(worstPointsCap); \(sortedBelow.count - worstPointsCap) more sample(s) below thresholdMm=\(thr) not shown."
                )
            }
            let worst = sortedBelow.prefix(worstPointsCap).map {
                ThicknessReport.WorstPoint(point: [$0.point.x, $0.point.y, $0.point.z], thicknessMm: $0.thicknessMm)
            }
            belowEntry = .init(
                thresholdMm: thr,
                count: sortedBelow.count,
                fraction: thicknesses.isEmpty ? 0 : Double(sortedBelow.count) / Double(thicknesses.count),
                worst: Array(worst)
            )
        }

        var writtenChartPath: String? = nil
        if chart {
            let outputDir = (store.path as NSString).deletingLastPathComponent
            let path = chartPath ?? "\(outputDir)/\(bodyId)_thickness.png"
            do {
                try ChartRenderer.histogram(
                    values: thicknesses, tolerance: thresholdMm, bins: 40,
                    title: "thicknessMm  \(bodyId)  (n=\(thicknesses.count))",
                    to: URL(fileURLWithPath: path)
                )
                writtenChartPath = path
            } catch {
                warnings.append("Chart failed: \(error.localizedDescription)")
            }
        }

        let report = ThicknessReport(
            bodyId: bodyId, samples: totalSamples, noHitSamples: noHit,
            thicknessMm: stat, belowThreshold: belowEntry, chartPath: writtenChartPath, warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }

    // MARK: - Ray casting

    /// Local thickness at `point`, whose outward surface normal is
    /// `outward` (unit or near-unit; the caller already checked its
    /// length). Single ray when `coneAngleDegrees == 0`; otherwise casts
    /// `coneRayCount` rays inside the cone and returns their MEDIAN hit
    /// distance (nil only if every ray in the cone misses).
    static func castThickness(
        bvh: TriBVH, point: SIMD3<Double>, outward: SIMD3<Double>, coneAngleDegrees: Double
    ) -> Double? {
        let n = simd_normalize(outward)
        let origin = point - n * 1e-4
        let directions = coneAngleDegrees > 0
            ? coneDirections(base: -n, halfAngleDegrees: coneAngleDegrees, count: coneRayCount)
            : [-n]

        var hits: [Double] = []
        hits.reserveCapacity(directions.count)
        for dir in directions {
            if let hit = bvh.firstHit(origin: origin, direction: dir) {
                hits.append(hit.t)
            }
        }
        guard !hits.isEmpty else { return nil }
        hits.sort()
        let mid = hits.count / 2
        return hits.count % 2 == 1 ? hits[mid] : (hits[mid - 1] + hits[mid]) / 2
    }

    /// `count` unit directions inside a cone of half-angle
    /// `halfAngleDegrees` around `base` (unit): `base` itself, then
    /// `count - 1` more evenly spaced in azimuth exactly AT the cone's
    /// angular boundary. A deterministic fixed pattern (not randomized
    /// jitter), so repeat calls are byte-identical.
    static func coneDirections(base: SIMD3<Double>, halfAngleDegrees: Double, count: Int) -> [SIMD3<Double>] {
        guard halfAngleDegrees > 0, count > 1 else { return [simd_normalize(base)] }
        let d = simd_normalize(base)
        // Any vector not parallel to d works as the seed for an orthonormal
        // basis; pick whichever world axis is least aligned with d.
        let seed: SIMD3<Double> = abs(d.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = simd_normalize(simd_cross(seed, d))
        let v = simd_cross(d, u)

        let halfAngleRad = halfAngleDegrees * .pi / 180
        let cosA = cos(halfAngleRad), sinA = sin(halfAngleRad)

        var dirs: [SIMD3<Double>] = [d]
        let ringCount = count - 1
        for k in 0..<ringCount {
            let az = 2 * Double.pi * Double(k) / Double(ringCount)
            let dir = d * cosA + (u * cos(az) + v * sin(az)) * sinA
            dirs.append(simd_normalize(dir))
        }
        return dirs
    }
}
