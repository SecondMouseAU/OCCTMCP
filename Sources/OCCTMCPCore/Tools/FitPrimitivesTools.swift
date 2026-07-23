// FitPrimitivesTools — `fit_primitives` (#107). The RANSAC primitive report
// over a body's (or one zone's) mesh: `OCCTSwiftMesh.Mesh.segmentedRANSAC(_:)`
// / `segmentedAutoSelect(dihedral:ransac:)` (OCCTSwiftMesh#27/#32, >=1.7.0),
// wrapped in the same JSON-report + categorical-render conventions
// MeshZoneTools/ZoneSweepTool established.
//
// WHY THIS IS A SEPARATE TOOL FROM `segment_mesh_zones` — Schnabel-style
// RANSAC claims GLOBAL inliers: every triangle within tolerance of a fitted
// candidate counts, wherever it sits in the mesh, not just triangles
// contiguous with where the candidate was sampled. `segment_mesh_zones`'s
// dihedral region-growing only ever absorbs edge-ADJACENT neighbours, so a
// single continuous cylindrical barrel interrupted by a boss (a raised
// feature that locally breaks the dihedral-continuity graph) reads as TWO OR
// MORE zones there, even though it is genuinely one cylindrical surface. That
// is exactly the reverse-engineering question RANSAC's global-inlier claim
// can answer and a per-region zone fit cannot: "does this same primitive
// recur elsewhere in the mesh." See docs/algorithms/ransac-segmentation.md
// (OCCTSwiftMesh) for the full algorithm writeup.
//
// PIPELINE — resolve body (whole mesh) or zone (ZoneRegistry, re-meshed at
// the zone's OWN stored deflection + a MeshSignature staleness check +
// subMesh — the IDENTICAL resolution path ZoneSweepTool.zoneContinuitySweep
// uses, for the identical reason: `triangleIndices` only lines up with a mesh
// built at that exact deflection) -> `segmentedRANSAC` (strategy "ransac",
// default) or `segmentedAutoSelect` (strategy "auto") -> primitive table
// (largest-support-first, matching `SegmentedMesh.regions`' own order) ->
// optional categorical per-primitive PNG render (MeshZoneTools' band-group
// trick, reimplemented here rather than shared since each mesh-analysis tool
// owns its own render helper, e.g. ZoneSweepTool.renderVerdicts).
//
// UNCOVERED VS. CAPPED — kept strictly separate, per design intent, because
// conflating them under RANSAC's "global inliers" story would misrepresent
// two very different situations: "genuinely no primitive claims this
// triangle" vs. "a primitive claimed it, but `maxPrimitives` cut the REPORT
// off before showing it." `SegmentedMesh.truncatedTriangleCount` alone can't
// tell these apart when a caller passes its own cap straight into
// `RANSACSegmentOptions.maxRegions` (the library conflates "never claimed"
// and "cut by the cap" into that one number, by its own docs). This tool
// therefore NEVER passes `maxPrimitives` into the library call itself —
// it always asks for every region the algorithm found (`maxRegions: nil`),
// computes `uncoveredFraction` from THAT unbounded `truncatedTriangleCount`,
// and only then applies `maxPrimitives` itself against the already
// largest-first-sorted `regions`/`fits` arrays, warning separately (with its
// own triangle count) about whatever it trims. `uncoveredFraction` therefore
// always means "no primitive, at any cap, claimed this triangle" — it never
// moves just because `maxPrimitives` got smaller.
//
// STRATEGY "auto" — `segmentedAutoSelect` shares the SAME `SegmentedMesh`
// result type across both dihedral growing and RANSAC (by upstream design,
// see SegmentedMesh's own doc comment), so no special-casing is needed
// downstream of the bake-off: `strategyScores.chosen` names which one won,
// and the primitive table is built identically either way. `minSupportTriangles`,
// when given, is applied to BOTH candidates in the bake-off (RANSAC's
// `minSupportCount` and dihedral's `minRegionTriangles`) so the two are
// compared on a consistent floor rather than RANSAC's own default silently
// diverging from dihedral's.
//
// DETERMINISM — inherited from the upstream primitive: `segmentedRANSAC`
// draws candidates via a deterministic splitmix64 hash (no system RNG), so
// two calls with identical arguments against an unchanged mesh return
// byte-identical primitive tables.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import OCCTSwiftViewport
import ScriptHarness

public enum FitPrimitivesTools {

    public enum Strategy: String, Sendable, CaseIterable {
        /// Schnabel-style global-inlier RANSAC extraction (`Mesh.segmentedRANSAC(_:)`).
        case ransac
        /// `Mesh.segmentedAutoSelect(dihedral:ransac:)`'s dihedral-vs-RANSAC bake-off; reports
        /// which strategy won via `strategyScores`.
        case auto
    }

    public struct FitReport: Encodable {
        public let bodyId: String
        public let zoneId: String?
        public let strategy: String
        public let strategyScores: StrategyScores?
        /// Largest-support-first, matching `SegmentedMesh.regions`' own order.
        public let primitives: [PrimitiveEntry]
        /// Fraction of the fitted mesh's triangles that NO primitive ever claimed as an inlier,
        /// computed BEFORE any `maxPrimitives` cap — see the file header's "uncovered vs.
        /// capped" note. Never moves when `maxPrimitives` shrinks the report.
        public let uncoveredFraction: Double
        public let renderPath: String?
        public let warnings: [String]

        public struct StrategyScores: Encodable {
            public let dihedral: Double
            public let ransac: Double
            public let chosen: String
        }
        public struct PrimitiveEntry: Encodable {
            public let kind: String
            public let params: [Double]
            public let residualRmsMm: Double
            public let residualMaxMm: Double
            public let inlierRatio: Double
            public let supportTriangles: Int
            public let supportFraction: Double
            public let areaMm2: Double
        }
    }

    @MainActor
    public static func fitPrimitives(
        bodyId: String,
        zoneId: String? = nil,
        strategy: Strategy = .ransac,
        inlierEpsilonMm: Double? = nil,
        minSupportTriangles: Int? = nil,
        maxPrimitives: Int? = nil,
        deflection: Double? = nil,
        render: Bool = true,
        renderPath: String? = nil,
        options: RenderPreviewTool.Options = .init(),
        registry: ZoneRegistry = .shared,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        var warnings: [String] = []
        var zoneRecord: ZoneRecord? = nil
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)

        // Zone resolution: the SAME path ZoneSweepTool.zoneContinuitySweep uses (re-mesh at the
        // zone's own stored deflection, or triangleIndices no longer lines up with a freshly
        // built mesh's triangle order).
        var meshDeflection = deflection ?? DeviationTools.defaultDeflection(for: shape)
        if let zid = zoneId {
            await registry.loadSidecarIfNeeded(store: zonesStore)
            guard let rec = await registry.zone(zid) else {
                return .init("Unknown zoneId \"\(zid)\". Run segment_mesh_zones first, or list_zones to see what's registered.", isError: true)
            }
            guard rec.bodyId == bodyId else {
                return .init("zoneId \"\(zid)\" belongs to body \"\(rec.bodyId)\", not \"\(bodyId)\".", isError: true)
            }
            zoneRecord = rec
            meshDeflection = rec.params.deflection
            if let requested = deflection, abs(requested - rec.params.deflection) > 1e-12 {
                warnings.append("deflection argument (\(requested)) ignored for a zoneId-scoped fit: re-meshing at the zone's own segmentation deflection (\(rec.params.deflection)) so triangleIndices stay valid.")
            }
        }
        guard meshDeflection > 0 else { return .init("deflection must be positive.", isError: true) }

        var meshParams = MeshParameters.default
        meshParams.deflection = meshDeflection
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let fullMesh = shape.mesh(parameters: meshParams), fullMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)'.", isError: true)
        }

        let fitMesh: Mesh
        if let rec = zoneRecord {
            let bb = shape.bounds
            let sig = MeshSignature(
                triangleCount: fullMesh.triangleCount,
                bboxMin: [Double(bb.min.x), Double(bb.min.y), Double(bb.min.z)],
                bboxMax: [Double(bb.max.x), Double(bb.max.y), Double(bb.max.z)]
            )
            guard sig.matches(rec.meshSignature) else {
                return .init(
                    "Zone \"\(rec.zoneId)\" is stale: body \"\(bodyId)\"'s mesh no longer matches the mesh it was segmented from (triangle count / bounding box changed). Re-run segment_mesh_zones.",
                    isError: true
                )
            }
            guard let sub = fullMesh.subMesh(triangleIndices: rec.triangleIndices) else {
                return .init("Failed to extract zone \"\(rec.zoneId)\"'s triangles from the current mesh.", isError: true)
            }
            fitMesh = sub
        } else {
            fitMesh = fullMesh
        }
        guard fitMesh.triangleCount > 0 else { return .init("Zone/body has no triangles to fit.", isError: true) }

        let totalTriangles = fitMesh.triangleCount

        // Always unbounded at the library call (maxRegions: nil) regardless of `maxPrimitives` —
        // see the file header's "uncovered vs. capped" note. `maxPrimitives` is applied ourselves,
        // below, against the already largest-first-sorted regions/fits.
        var ransacOptions = Mesh.RANSACSegmentOptions()
        if let eps = inlierEpsilonMm { ransacOptions.inlierEpsilon = eps }
        if let minSupport = minSupportTriangles { ransacOptions.minSupportCount = minSupport }
        ransacOptions.maxRegions = nil

        var segResult: SegmentedMesh
        var strategyScores: FitReport.StrategyScores? = nil
        let strategyLabel: String

        switch strategy {
        case .ransac:
            segResult = fitMesh.segmentedRANSAC(ransacOptions)
            strategyLabel = Strategy.ransac.rawValue
        case .auto:
            var dihedralOptions = Mesh.SegmentOptions()
            if let minSupport = minSupportTriangles { dihedralOptions.minRegionTriangles = minSupport }
            dihedralOptions.maxRegions = nil
            let auto = fitMesh.segmentedAutoSelect(dihedral: dihedralOptions, ransac: ransacOptions)
            segResult = auto.result
            strategyScores = .init(dihedral: auto.dihedralScore, ransac: auto.ransacScore, chosen: auto.strategy.rawValue)
            strategyLabel = Strategy.auto.rawValue
        }

        let uncoveredFraction = totalTriangles > 0 ? Double(segResult.truncatedTriangleCount) / Double(totalTriangles) : 0
        if segResult.truncatedTriangleCount > 0 {
            let pct = String(format: "%.1f", uncoveredFraction * 100)
            warnings.append(
                "\(segResult.truncatedTriangleCount)/\(totalTriangles) triangles (\(pct)%) were never claimed by any primitive (uncoveredFraction=\(uncoveredFraction))."
            )
        }
        if strategy == .auto && segResult.fitMergeSkipped {
            warnings.append(
                "the dihedral bake-off candidate's fit-gated merge pass was skipped (raw region count exceeded the internal cap even after coplanar pre-merge); if dihedral won (see strategyScores.chosen), its regions are unmerged seed regions."
            )
        }

        // maxPrimitives cap: applied ourselves, after the fact, against the already
        // largest-first-sorted regions/fits — kept separate from uncoveredFraction above.
        var regions = segResult.regions
        var fits = segResult.fits
        if let rawCap = maxPrimitives {
            let cap = max(0, rawCap)
            if regions.count > cap {
                var cutTriangles = 0
                for region in regions[cap...] { cutTriangles += region.triangleIndices.count }
                let cutCount = regions.count - cap
                regions = Array(regions.prefix(cap))
                fits = Array(fits.prefix(cap))
                warnings.append(
                    "maxPrimitives=\(cap) capped the report: \(cutCount) smaller primitive(s) covering \(cutTriangles) triangles were dropped from `primitives` (they WERE claimed by a primitive, unlike uncoveredFraction's triangles — not double-counted there)."
                )
            }
        }

        guard !regions.isEmpty else {
            return IntrospectionTools.encode(FitReport(
                bodyId: bodyId, zoneId: zoneId, strategy: strategyLabel, strategyScores: strategyScores,
                primitives: [], uncoveredFraction: uncoveredFraction, renderPath: nil,
                warnings: warnings + ["No primitive met minSupportTriangles; nothing to report."]
            ))
        }

        var entries: [FitReport.PrimitiveEntry] = []
        entries.reserveCapacity(regions.count)
        for (region, fit) in zip(regions, fits) {
            entries.append(FitReport.PrimitiveEntry(
                kind: fit.kind.rawValue,
                params: fit.params,
                residualRmsMm: fit.residualRMS,
                residualMaxMm: fit.residualMax,
                inlierRatio: fit.inlierRatio,
                supportTriangles: region.triangleIndices.count,
                supportFraction: totalTriangles > 0 ? Double(region.triangleIndices.count) / Double(totalTriangles) : 0,
                areaMm2: region.area
            ))
        }

        // ── optional render (band-group trick, mirrors MeshZoneTools/ZoneSweepTool) ──
        var writtenRenderPath: String? = nil
        if render {
            let path = renderPath ?? "\(outputDir)/\(bodyId)_primitives.png"
            if regions.count > ChartRenderer.categoricalPalette.count {
                warnings.append(
                    "\(regions.count) primitives exceed the \(ChartRenderer.categoricalPalette.count)-color palette; colors repeat past #\(ChartRenderer.categoricalPalette.count - 1) and are not visually distinct beyond it."
                )
            }
            if let err = renderPrimitives(
                mesh: fitMesh, regions: regions, fits: fits, bodyId: bodyId,
                outputPath: path, options: options
            ) {
                warnings.append("Render failed: \(err)")
            } else {
                writtenRenderPath = path
            }
        }

        return IntrospectionTools.encode(FitReport(
            bodyId: bodyId, zoneId: zoneId, strategy: strategyLabel, strategyScores: strategyScores,
            primitives: entries, uncoveredFraction: uncoveredFraction, renderPath: writtenRenderPath,
            warnings: warnings
        ))
    }

    // MARK: - Rendering (band-group trick, mirrors MeshZoneTools/ZoneSweepTool)

    @MainActor
    private static func renderPrimitives(
        mesh: Mesh, regions: [MeshRegion], fits: [FittedPrimitive], bodyId: String, outputPath: String,
        options: RenderPreviewTool.Options
    ) -> String? {
        let verts = mesh.vertices
        let normals = mesh.normals
        let idx = mesh.indices
        let hasNormals = normals.count == verts.count
        let faceNormals = mesh.faceNormals()

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
                let fn = faceNormals[t]
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
        var legend: [(label: String, color: SIMD4<Float>)] = []
        for (pi, region) in regions.enumerated() where !region.triangleIndices.isEmpty {
            let color = ChartRenderer.categoricalColor(pi)
            bodies.append(buildBody(id: "\(bodyId)#primitive\(pi)", tris: region.triangleIndices, color: color))
            let kind = pi < fits.count ? fits[pi].kind.rawValue : "?"
            legend.append((label: "primitive#\(pi) \(kind) (\(region.triangleIndices.count) tri)", color: color))
        }
        guard !bodies.isEmpty else { return "no primitive triangles to render" }

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
        try? ChartRenderer.overlayZoneLegend(on: url, entries: legend)
        return nil
    }
}
