// MeshCurvatureTools — `mesh_curvature`. Phase 3 of the mesh-analysis expansion
// (`.claude/plans/2026-07-21-mesh-analysis-expansion.md`): the single-body
// curvature render mode deferred from #101, plus LLM-grade curvature
// statistics. No reference body needed — this is a property of one mesh.
//
// Phase 3's other primitives (slippage classification, RANSAC segmentation,
// crease-edge detection, curvature-ordered segmentation seeding, generalized
// winding number) belong upstream in OCCTSwiftMesh per the ecosystem's
// factoring rule (OCCTMCP wraps, never implements mesh algorithms) and are
// tracked as filed issues rather than implemented here — see
// SecondMouseAU/OCCTSwiftMesh#26/#27/#28/#29/#30 and the OCCTMCP tracking
// issues #107/#108/#109. This tool ships because its one primitive,
// `OCCTSwiftMesh.Mesh.vertexCurvatures()` (v1.4.0, OCCTSwiftMesh#23/#24), is
// already released and pinned (Package.swift already floors OCCTSwiftMesh at
// 1.5.0 for align_bodies) — no repin needed.
//
// PIPELINE — loadShape -> mesh (the standard MeshParameters recipe shared
// with DeviationTools/MeshZoneTools/MeshDiagnoseTools/AlignTools) ->
// `mesh.welded()` -> `welded.vertexCurvatures()`. Welding is MANDATORY:
// `vertexCurvatures()`'s own precondition is a WELDED mesh (per-face tensors
// are averaged onto each vertex over every triangle sharing that vertex's
// WELDED index) — on unwelded input every vertex touches exactly one
// triangle, so the result degrades to that triangle's own unaveraged
// curvature. Both the render and the stats below are computed entirely on
// `welded` (never `mesh`), so there's no triangle-index correspondence
// problem to guard against here, unlike MeshZoneTools' `adjacentZones`
// (which needs adjacency on a SEPARATE weld pass while its own
// `triangleIndices` stay indexed against the unwelded mesh).
//
// UNITS — k1/k2/mean are in 1/mm (curvature = 1/radius of curvature).
// `gaussian = k1 * k2` is in 1/mm-squared, NOT 1/mm — a real unit, kept in
// mind below: `highCurvatureFraction`'s clamp is always computed from the
// SAME channel selected by `colorBy` (never cross-compared against a
// different channel's clamp), so this never creates a unit mismatch even
// though `gaussian`'s numbers are on a different scale than the other three.
//
// COLOR-BY SEMANTICS — `clampPercentile` (default 0.95) computes a clamp
// value from the p-th percentile of |colorBy channel value| over all welded
// vertices; the diverging colormap (ChartRenderer.divergingColor, the same
// one HeatmapTools uses) is clamped symmetrically at that value for the 3
// signed channels (mean/gaussian/k1), or 0..clamp using just the positive
// (white->red) half of the same map for the unsigned `maxAbs` channel
// (= max(|k1|, |k2|)). `highCurvatureFraction` reports the fraction of
// vertices whose |colorBy value| exceeds that SAME clamp — by construction
// close to `1 - clampPercentile` (not a coincidence: it's exactly what
// "clamped for color" means), which is what lets `clampPercentile: 1.0`
// (no clamp at all) drive it to 0 and is exercised directly by
// MeshCurvatureToolsTests' clampPercentile-semantics test.
//
// FLATNESS — `flatFraction` is independent of `colorBy`: a vertex is "flat"
// when max(|k1|, |k2|) is below `0.1 / bboxDiag` (1/mm) — a curvature radius
// past ~10x the body's own bounding-box diagonal reads as flat at model
// scale. This is deliberately an absolute-ish heuristic (not a percentile of
// the sample itself, unlike highCurvatureFraction) so it means the same
// thing regardless of how curved or flat the rest of the body happens to be.
//
// UNWELDABLE-SOUP WARNING — per vertexCurvatures()'s own docs, unwelded
// input (or input that welds to nothing, i.e. every triangle owns its own 3
// unique vertices even after welding) degrades to zero curvature everywhere.
// A GENUINE flat body (a box, away from its edges) is also mostly zero
// curvature, so "curvature reads near-zero" can't itself be the warning
// trigger. Instead this tool warns only when the WELD demonstrably failed to
// merge anything (`welded.vertexCount == welded.triangleCount * 3`) — a
// mesh-topology fact, not a curvature-value heuristic, so it can't
// false-positive on a genuinely flat part.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import OCCTSwiftViewport
import ScriptHarness

public enum MeshCurvatureTools {

    public enum ColorBy: String, Sendable, CaseIterable {
        case mean
        case gaussian
        case k1
        case maxAbs
    }

    public struct CurvatureReport: Encodable {
        public let bodyId: String
        public let triangleCount: Int
        public let vertexCount: Int
        public let colorBy: String
        public let clampPercentile: Double
        /// 1/mm.
        public let k1: Stat
        /// 1/mm.
        public let k2: Stat
        /// 1/mm.
        public let mean: Stat
        /// 1/mm^2 (k1 * k2) — NOT the same unit as the other three.
        public let gaussian: Stat
        public let flatFraction: Double
        public let highCurvatureFraction: Double
        public let renderPath: String?
        public let chartPath: String?
        public let warnings: [String]

        public struct Stat: Encodable {
            public let min: Double
            public let p05: Double
            public let median: Double
            public let p95: Double
            public let max: Double
        }
    }

    static let bands = 11
    /// A vertex with max(|k1|,|k2|) under `flatCurvatureBboxFraction / bboxDiag` (1/mm) reads
    /// flat — see the file header.
    static let flatCurvatureBboxFraction = 0.1

    @MainActor
    public static func meshCurvature(
        bodyId: String,
        deflection: Double? = nil,
        colorBy: ColorBy = .mean,
        clampPercentile: Double = 0.95,
        render: Bool = true,
        renderPath: String? = nil,
        chart: Bool = false,
        chartPath: String? = nil,
        options: RenderPreviewTool.Options = .init(),
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
        guard clampPercentile > 0, clampPercentile <= 1.0 else {
            return .init("clampPercentile must be in (0, 1].", isError: true)
        }

        var meshParams = MeshParameters.default
        meshParams.deflection = defl
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let mesh = shape.mesh(parameters: meshParams), mesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)'.", isError: true)
        }

        // MANDATORY precondition, see the file header: vertexCurvatures() needs a welded mesh.
        // Everything downstream (stats AND render) is indexed against `welded`, never `mesh`.
        let welded = mesh.welded()
        guard welded.triangleCount > 0, welded.vertexCount > 0 else {
            return .init("Welding '\(bodyId)' produced an empty mesh.", isError: true)
        }

        var warnings: [String] = []
        if welded.vertexCount == welded.triangleCount * 3 {
            warnings.append(
                "mesh appears unweldable (no shared vertices found); curvature may read zero everywhere."
            )
        }

        let curvatures = welded.vertexCurvatures()
        let bb = shape.bounds
        let bboxDiag = Double(simd_length(bb.max - bb.min))
        let flatThreshold = flatCurvatureBboxFraction / max(bboxDiag, 1e-9)

        var k1s = [Double](); var k2s = [Double](); var means = [Double](); var gaussians = [Double]()
        var maxAbsK = [Double]()
        k1s.reserveCapacity(curvatures.count)
        k2s.reserveCapacity(curvatures.count)
        means.reserveCapacity(curvatures.count)
        gaussians.reserveCapacity(curvatures.count)
        maxAbsK.reserveCapacity(curvatures.count)
        for c in curvatures {
            k1s.append(c.k1)
            k2s.append(c.k2)
            means.append(c.mean)
            gaussians.append(c.gaussian)
            maxAbsK.append(max(abs(c.k1), abs(c.k2)))
        }

        let flatCount = maxAbsK.filter { $0 < flatThreshold }.count
        let flatFraction = maxAbsK.isEmpty ? 0 : Double(flatCount) / Double(maxAbsK.count)

        let colorByValues: [Double]
        switch colorBy {
        case .mean:     colorByValues = means
        case .gaussian: colorByValues = gaussians
        case .k1:       colorByValues = k1s
        case .maxAbs:   colorByValues = maxAbsK
        }
        let absSorted = colorByValues.map { abs($0) }.sorted()
        let clampValue = max(1e-12, DeviationTools.percentile(absSorted, clampPercentile))
        let highCount = colorByValues.filter { abs($0) > clampValue }.count
        let highCurvatureFraction = colorByValues.isEmpty ? 0 : Double(highCount) / Double(colorByValues.count)
        if clampPercentile < 1.0, highCount > 0 {
            let phrase = colorBy == .maxAbs ? "above" : "beyond \u{b1}"
            warnings.append(
                "values \(phrase) \(fmt(clampValue)) 1/mm clamped for color (clampPercentile=\(fmt(clampPercentile)))."
            )
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent

        var writtenRenderPath: String? = nil
        if render {
            let path = renderPath ?? "\(outputDir)/\(bodyId)_curvature.png"
            if let err = renderCurvature(
                welded: welded, values: colorByValues, colorBy: colorBy, clampValue: clampValue,
                bodyId: bodyId, outputPath: path, options: options
            ) {
                warnings.append("Render failed: \(err)")
            } else {
                writtenRenderPath = path
            }
        }

        var writtenChartPath: String? = nil
        if chart {
            let path = chartPath ?? "\(outputDir)/\(bodyId)_curvature_hist.png"
            do {
                try ChartRenderer.histogram(
                    values: colorByValues, tolerance: nil, bins: 40,
                    title: "\(bodyId) \(colorBy.rawValue) curvature (1/mm)",
                    to: URL(fileURLWithPath: path)
                )
                writtenChartPath = path
            } catch {
                warnings.append("Chart failed: \(error.localizedDescription)")
            }
        }

        let report = CurvatureReport(
            bodyId: bodyId,
            triangleCount: welded.triangleCount,
            vertexCount: welded.vertexCount,
            colorBy: colorBy.rawValue,
            clampPercentile: clampPercentile,
            k1: stat(k1s), k2: stat(k2s), mean: stat(means), gaussian: stat(gaussians),
            flatFraction: flatFraction,
            highCurvatureFraction: highCurvatureFraction,
            renderPath: writtenRenderPath,
            chartPath: writtenChartPath,
            warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }

    // MARK: - Stats

    static func stat(_ values: [Double]) -> CurvatureReport.Stat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .init(min: 0, p05: 0, median: 0, p95: 0, max: 0) }
        return .init(
            min: sorted.first!,
            p05: DeviationTools.percentile(sorted, 0.05),
            median: DeviationTools.percentile(sorted, 0.5),
            p95: DeviationTools.percentile(sorted, 0.95),
            max: sorted.last!
        )
    }

    // MARK: - Rendering (band-group trick, mirrors HeatmapTools / MeshZoneTools)

    @MainActor
    private static func renderCurvature(
        welded: Mesh, values: [Double], colorBy: ColorBy, clampValue: Double,
        bodyId: String, outputPath: String, options: RenderPreviewTool.Options
    ) -> String? {
        let verts = welded.vertices
        let normals = welded.normals
        let idx = welded.indices
        let hasNormals = normals.count == verts.count
        let triCount = welded.triangleCount
        guard triCount > 0, values.count == verts.count else { return "no triangles to render" }

        // Per-triangle value = mean of its 3 (welded) corner values.
        var bandTris = [[Int]](repeating: [], count: bands)
        for t in 0..<triCount {
            let ia = Int(idx[t * 3]), ib = Int(idx[t * 3 + 1]), ic = Int(idx[t * 3 + 2])
            let v = (values[ia] + values[ib] + values[ic]) / 3
            bandTris[bandIndex(for: v, colorBy: colorBy, clamp: clampValue)].append(t)
        }

        func buildBody(id: String, tris: [Int], color: SIMD4<Float>) -> ViewportBody {
            var positions: [Float] = []
            var bnormals: [Float] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(tris.count * 9)
            bnormals.reserveCapacity(tris.count * 9)
            indices.reserveCapacity(tris.count * 3)
            for t in tris {
                let ia = Int(idx[t * 3]), ib = Int(idx[t * 3 + 1]), ic = Int(idx[t * 3 + 2])
                let pa = verts[ia], pb = verts[ib], pc = verts[ic]
                let fn: SIMD3<Float>
                if hasNormals {
                    fn = SIMD3<Float>(0, 0, 0)  // per-vertex normals used below
                } else {
                    let n = simd_cross(pb - pa, pc - pa)
                    let len = simd_length(n)
                    fn = len > 1e-12 ? n / len : SIMD3<Float>(0, 0, 1)
                }
                for (vi, p) in [(ia, pa), (ib, pb), (ic, pc)] {
                    positions.append(p.x); positions.append(p.y); positions.append(p.z)
                    let nrm = hasNormals ? normals[vi] : fn
                    bnormals.append(nrm.x); bnormals.append(nrm.y); bnormals.append(nrm.z)
                }
                let base = UInt32(indices.count)
                indices.append(base); indices.append(base + 1); indices.append(base + 2)
            }
            return ViewportBody.directMesh(id: id, positions: positions, normals: bnormals, indices: indices, color: color)
        }

        var bodies: [ViewportBody] = []
        for b in 0..<bands where !bandTris[b].isEmpty {
            let t = bandCenterT(for: b, colorBy: colorBy)
            bodies.append(buildBody(id: "\(bodyId)#curv\(b)", tris: bandTris[b], color: ChartRenderer.divergingColor(t)))
        }
        guard !bodies.isEmpty else { return "no colored surface produced" }

        guard let renderer = OffscreenRenderer() else {
            return "OffscreenRenderer init failed (no Metal device available)."
        }
        var ro = OffscreenRenderOptions(
            width: options.width, height: options.height,
            displayMode: .shaded, backgroundColor: options.background.color
        )
        ro.cameraState = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)

        let url = URL(fileURLWithPath: outputPath)
        do {
            _ = try renderer.renderToPNG(bodies: bodies, url: url, options: ro)
        } catch {
            return error.localizedDescription
        }
        let (minV, maxV): (Double, Double) = colorBy == .maxAbs ? (0, clampValue) : (-clampValue, clampValue)
        let unitLabel = colorBy == .gaussian ? "\(colorBy.rawValue) 1/mm\u{b2}" : "\(colorBy.rawValue) 1/mm"
        try? ChartRenderer.overlayColorbar(on: url, minValue: minV, maxValue: maxV, label: unitLabel)
        return nil
    }

    /// `.maxAbs` (unsigned): 0..bands-1 across `[0, clamp]`. Every other channel (signed):
    /// 0..bands-1 across `[-clamp, clamp]` — matches HeatmapTools' bucketing exactly.
    private static func bandIndex(for value: Double, colorBy: ColorBy, clamp: Double) -> Int {
        let norm: Double
        if colorBy == .maxAbs {
            norm = max(0.0, min(1.0, value / clamp))
        } else {
            norm = (max(-1.0, min(1.0, value / clamp)) + 1) / 2
        }
        var b = Int(norm * Double(bands))
        if b >= bands { b = bands - 1 }
        return max(0, b)
    }

    /// The `t ∈ [-1, 1]` (or `[0, 1]` for `.maxAbs`) passed to `ChartRenderer.divergingColor`
    /// for band `b`'s fill color.
    private static func bandCenterT(for b: Int, colorBy: ColorBy) -> Double {
        let frac = (Double(b) + 0.5) / Double(bands)
        return colorBy == .maxAbs ? frac : frac * 2 - 1
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.4g", v) }
}
