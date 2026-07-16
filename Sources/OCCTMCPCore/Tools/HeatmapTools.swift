// HeatmapTools — visual deviation diagnostics (#63).
//
//  • signed_deviation_heatmap — per-triangle SIGNED distance from one body to a
//    reference, mapped through a diverging colormap and rendered as a shaded
//    surface. OffscreenRenderer only colours the *point* pass per-vertex and has
//    no per-triangle style pass, so a true coloured SURFACE is built as one
//    flat-coloured ViewportBody per signed-distance band — the band's triangles
//    grouped and tinted with the band colour. A colorbar legend is composited
//    onto the PNG so + (proud / red) and − (shy / blue) read at a glance.
//
//    CAVEAT (#72): the sign comes from the reference's single nearest triangle's
//    face normal, which is only trustworthy against a watertight/single-surface
//    reference. Against an OPEN, thin-walled reference (a raw scan / STL skin
//    whose outer skin and inner wall are a small gap apart) the nearest triangle
//    can be either surface from one sample to the next, so the sign flips with
//    no real positional meaning — it looks like a dramatic proud/shy split that
//    isn't there. Triangles where a comparably-close candidate disagrees on
//    sign are rendered GREY (not red/blue) and counted in `ambiguousTriangles` /
//    `ambiguousFraction`; a heatmap that's mostly grey means trust the
//    magnitude (or `cross_section_compare`'s overlap-robust comparison), not
//    this tool's sign.
//
//  • overlay_render — the reference mesh drawn semi-transparent over the opaque
//    candidate solid, so you can see in 3D exactly where the reconstruction
//    departs from the source. OffscreenRenderer's transparent pass kicks in for
//    any body whose effective opacity < 1.
//
// Both reuse RenderPreviewTool's camera framing helpers.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

public enum HeatmapTools {

    // MARK: - signed_deviation_heatmap

    public struct HeatmapReport: Encodable {
        public let outputPath: String
        public let width: Int
        public let height: Int
        public let bands: Int
        /// Colormap saturation bound: |signed| ≥ clamp maps to full red/blue.
        public let clamp: Double
        public let triangles: Int
        public let signedMin: Double
        public let signedMax: Double
        public let signedMean: Double
        /// Triangles whose sign disagreed with a comparably-close candidate on
        /// the reference surface (#72) — rendered grey, excluded from the
        /// red/blue bands. A high fraction means the reference is open/thin-
        /// walled and the SIGN channel (not the magnitude) isn't trustworthy here.
        public let ambiguousTriangles: Int
        public let ambiguousFraction: Double
        public let mimeType: String
    }

    @MainActor
    public static func signedDeviationHeatmap(
        fromBodyId: String,
        referenceBodyId: String,
        outputPath: String,
        deflection: Double? = nil,
        bands: Int = 11,
        clamp: Double? = nil,
        options: RenderPreviewTool.Options = .init(),
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let fromShape: Shape, refShape: Shape
        do {
            fromShape = try IntrospectionTools.loadShape(bodyId: fromBodyId, store: store).shape
            refShape = try IntrospectionTools.loadShape(bodyId: referenceBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }

        let defl = deflection ?? DeviationTools.defaultDeflection(for: fromShape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }

        guard let mesh = CrossSectionCompareTool.mesh(fromShape, deflection: defl) else {
            return .init("Failed to tessellate '\(fromBodyId)'.", isError: true)
        }
        guard let refTris = DeviationTools.TriMesh(shape: refShape, deflection: defl) else {
            return .init("Failed to tessellate '\(referenceBodyId)'.", isError: true)
        }

        let verts = mesh.vertices
        let normals = mesh.normals
        let idx = mesh.indices
        guard idx.count >= 3 else { return .init("Body '\(fromBodyId)' has no triangles to colour.", isError: true) }
        let hasNormals = normals.count == verts.count

        // Per-triangle signed distance, sampled at the centroid.
        let triCount = idx.count / 3
        var centroids: [SIMD3<Double>] = []
        centroids.reserveCapacity(triCount)
        for t in 0..<triCount {
            let a = verts[Int(idx[t * 3])], b = verts[Int(idx[t * 3 + 1])], c = verts[Int(idx[t * 3 + 2])]
            let ctr = (a + b + c) / 3
            centroids.append(SIMD3<Double>(Double(ctr.x), Double(ctr.y), Double(ctr.z)))
        }
        let hits = DeviationTools.signedDistances(of: centroids, to: refTris)

        // Aggregate stats from sign-RELIABLE triangles only (#72): an open/thin-
        // walled reference's ambiguous-sign triangles are noise on signedMin/Max/
        // Mean too, not just on the render, since a flipped sign among otherwise-
        // uniform samples skews the mean and can masquerade as the extreme.
        let reliableDistances = hits.filter { !$0.ambiguous }.map { $0.distance }
        let statsSource = reliableDistances.isEmpty ? hits.map { $0.distance } : reliableDistances
        let signedMin = statsSource.min() ?? 0
        let signedMax = statsSource.max() ?? 0
        let signedMean = statsSource.isEmpty ? 0 : statsSource.reduce(0, +) / Double(statsSource.count)
        let ambiguousCount = hits.filter { $0.ambiguous }.count
        let ambiguousFraction = hits.isEmpty ? 0 : Double(ambiguousCount) / Double(hits.count)

        // Colormap bound: explicit clamp, else robust p95 of |signed| over reliable samples.
        let absSorted = statsSource.map { abs($0) }.sorted()
        let autoClamp = DeviationTools.percentile(absSorted, 0.95)
        let bound = (clamp ?? autoClamp) > 1e-12 ? (clamp ?? autoClamp) : max(1e-9, absSorted.last ?? 1)

        // Bucket triangles into bands across [-bound, +bound]; sign-ambiguous
        // triangles are set aside into their own grey group instead of being
        // coloured by a sign that's a coin flip.
        let nb = max(2, bands)
        var bandTris = [[Int]](repeating: [], count: nb)
        var ambiguousTris: [Int] = []
        for t in 0..<triCount {
            guard !hits[t].ambiguous else { ambiguousTris.append(t); continue }
            let norm = max(-1.0, min(1.0, hits[t].distance / bound))     // -1..1
            var b = Int((norm + 1) / 2 * Double(nb))              // 0..nb
            if b >= nb { b = nb - 1 }
            if b < 0 { b = 0 }
            bandTris[b].append(t)
        }

        // Build one flat-coloured direct-mesh ViewportBody per non-empty group
        // (OCCTSwiftViewport ≥1.1.23, #76): positions/bnormals are de-interleaved
        // arrays the renderer uploads as separate GPU buffers — no stride-6 zip
        // pass, no duplicate copy. Normals are used verbatim (no NormalSmoothing),
        // which is what a heatmap wants: the per-group normals are already correct.
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
                    fn = SIMD3<Float>(0, 0, 0)  // use per-vertex below
                } else {
                    let n = simd_cross(pb - pa, pc - pa)
                    let l = simd_length(n)
                    fn = l > 1e-12 ? n / l : SIMD3<Float>(0, 0, 1)
                }
                for (vi, p) in [(ia, pa), (ib, pb), (ic, pc)] {
                    positions.append(p.x); positions.append(p.y); positions.append(p.z)
                    let nrm = hasNormals ? normals[vi] : fn
                    bnormals.append(nrm.x); bnormals.append(nrm.y); bnormals.append(nrm.z)
                }
                let base = UInt32(indices.count)
                indices.append(base); indices.append(base + 1); indices.append(base + 2)
            }
            return ViewportBody.directMesh(
                id: id, positions: positions, normals: bnormals, indices: indices, color: color)
        }

        var bodies: [ViewportBody] = []
        for b in 0..<nb where !bandTris[b].isEmpty {
            let bandCenter = (Double(b) + 0.5) / Double(nb) * 2 - 1   // -1..1
            bodies.append(buildBody(id: "\(fromBodyId)#band\(b)", tris: bandTris[b], color: ChartRenderer.divergingColor(bandCenter)))
        }
        if !ambiguousTris.isEmpty {
            let grey = SIMD4<Float>(0.55, 0.55, 0.55, 1)
            bodies.append(buildBody(id: "\(fromBodyId)#ambiguous", tris: ambiguousTris, color: grey))
        }
        guard !bodies.isEmpty else { return .init("No coloured surface produced.", isError: true) }

        guard let renderer = OffscreenRenderer() else {
            return .init("OffscreenRenderer init failed (no Metal device available).", isError: true)
        }
        var ro = OffscreenRenderOptions(
            width: options.width, height: options.height,
            displayMode: .shaded,                       // edges off — bands read cleaner
            backgroundColor: options.background.color
        )
        ro.cameraState = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)

        let url = URL(fileURLWithPath: outputPath)
        do {
            _ = try renderer.renderToPNG(bodies: bodies, url: url, options: ro)
        } catch {
            return .init("Render failed: \(error.localizedDescription)", isError: true)
        }
        // Composite the colorbar legend onto the render.
        let barLabel = ambiguousTris.isEmpty ? "signed mm" : "signed mm  (grey = sign-ambiguous)"
        try? ChartRenderer.overlayColorbar(on: url, minValue: -bound, maxValue: bound, label: barLabel)

        return IntrospectionTools.encode(HeatmapReport(
            outputPath: outputPath, width: options.width, height: options.height,
            bands: nb, clamp: bound, triangles: triCount,
            signedMin: signedMin, signedMax: signedMax, signedMean: signedMean,
            ambiguousTriangles: ambiguousCount, ambiguousFraction: ambiguousFraction,
            mimeType: "image/png"
        ))
    }

    // MARK: - overlay_render

    public struct OverlayReport: Encodable {
        public let outputPath: String
        public let width: Int
        public let height: Int
        public let solidBodyId: String
        public let meshBodyId: String
        public let transparency: Double
        public let mimeType: String
    }

    @MainActor
    public static func overlayRender(
        solidBodyId: String,
        meshBodyId: String,
        outputPath: String,
        transparency: Double = 0.5,
        options: RenderPreviewTool.Options = .init(),
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let solidShape: Shape, meshShape: Shape
        do {
            solidShape = try IntrospectionTools.loadShape(bodyId: solidBodyId, store: store).shape
            meshShape = try IntrospectionTools.loadShape(bodyId: meshBodyId, store: store).shape
        } catch {
            return .init("\(error)")
        }
        let alpha = Float(max(0.05, min(0.95, transparency)))

        // Opaque candidate solid (steel-grey), translucent reference mesh (amber).
        // Routed through the mesh-scale guard (#75): the reference is typically a
        // raw scan / STL skin whose one-face-per-facet structure would hang the
        // O(edges²) B-rep edge extraction.
        let solidVBopt = RenderPreviewTool.viewportBody(
            for: solidShape, id: solidBodyId, color: SIMD4(0.66, 0.69, 0.74, 1))
        let meshVBopt = RenderPreviewTool.viewportBody(
            for: meshShape, id: meshBodyId, color: SIMD4(0.95, 0.65, 0.20, alpha))
        guard var solidVB = solidVBopt, var meshVB = meshVBopt else {
            return .init("Failed to build renderable bodies.", isError: true)
        }
        // Force the reference body translucent on whichever material path is live.
        meshVB.color.w = alpha
        if var m = meshVB.material { m.opacity = alpha; meshVB.material = m }
        solidVB.color.w = 1

        let bodies = [solidVB, meshVB]
        guard let renderer = OffscreenRenderer() else {
            return .init("OffscreenRenderer init failed (no Metal device available).", isError: true)
        }
        var ro = OffscreenRenderOptions(
            width: options.width, height: options.height,
            displayMode: options.displayMode,
            backgroundColor: options.background.color
        )
        ro.cameraState = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)

        let url = URL(fileURLWithPath: outputPath)
        do {
            _ = try renderer.renderToPNG(bodies: bodies, url: url, options: ro)
        } catch {
            return .init("Render failed: \(error.localizedDescription)", isError: true)
        }
        return IntrospectionTools.encode(OverlayReport(
            outputPath: outputPath, width: options.width, height: options.height,
            solidBodyId: solidBodyId, meshBodyId: meshBodyId,
            transparency: Double(alpha), mimeType: "image/png"
        ))
    }
}
