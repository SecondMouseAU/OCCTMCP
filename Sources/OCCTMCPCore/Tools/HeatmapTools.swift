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
        let signed = DeviationTools.signedDistances(of: centroids, to: refTris)

        let signedMin = signed.min() ?? 0
        let signedMax = signed.max() ?? 0
        let signedMean = signed.isEmpty ? 0 : signed.reduce(0, +) / Double(signed.count)

        // Colormap bound: explicit clamp, else robust p95 of |signed|.
        let absSorted = signed.map { abs($0) }.sorted()
        let autoClamp = DeviationTools.percentile(absSorted, 0.95)
        let bound = (clamp ?? autoClamp) > 1e-12 ? (clamp ?? autoClamp) : max(1e-9, absSorted.last ?? 1)

        // Bucket triangles into bands across [-bound, +bound].
        let nb = max(2, bands)
        var bandTris = [[Int]](repeating: [], count: nb)
        for t in 0..<triCount {
            let norm = max(-1.0, min(1.0, signed[t] / bound))     // -1..1
            var b = Int((norm + 1) / 2 * Double(nb))              // 0..nb
            if b >= nb { b = nb - 1 }
            if b < 0 { b = 0 }
            bandTris[b].append(t)
        }

        // One flat-coloured ViewportBody per non-empty band.
        var bodies: [ViewportBody] = []
        for b in 0..<nb where !bandTris[b].isEmpty {
            let bandCenter = (Double(b) + 0.5) / Double(nb) * 2 - 1   // -1..1
            let color = ChartRenderer.divergingColor(bandCenter)
            var positions: [Float] = []
            var bnormals: [Float] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(bandTris[b].count * 9)
            bnormals.reserveCapacity(bandTris[b].count * 9)
            indices.reserveCapacity(bandTris[b].count * 3)
            for t in bandTris[b] {
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
            // ViewportBody.directMesh (positions/normals as separate arrays) no longer exists —
            // ViewportBody's init takes a single interleaved vertexData ([px,py,pz,nx,ny,nz,...],
            // stride 6), so zip the two flat per-vertex arrays together here (same idiom the
            // OCCTSwiftViewport primitive factories, e.g. .box, use internally).
            var vertexData: [Float] = []
            vertexData.reserveCapacity(positions.count * 2)
            for i in stride(from: 0, to: positions.count, by: 3) {
                vertexData.append(positions[i]); vertexData.append(positions[i + 1]); vertexData.append(positions[i + 2])
                vertexData.append(bnormals[i]); vertexData.append(bnormals[i + 1]); vertexData.append(bnormals[i + 2])
            }
            bodies.append(ViewportBody(
                id: "\(fromBodyId)#band\(b)",
                vertexData: vertexData, indices: indices, edges: [], color: color
            ))
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
        try? ChartRenderer.overlayColorbar(on: url, minValue: -bound, maxValue: bound, label: "signed mm")

        return IntrospectionTools.encode(HeatmapReport(
            outputPath: outputPath, width: options.width, height: options.height,
            bands: nb, clamp: bound, triangles: triCount,
            signedMin: signedMin, signedMax: signedMax, signedMean: signedMean,
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
