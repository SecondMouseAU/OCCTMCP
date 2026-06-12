// RayPickTool — pick_surface_point. Resolves a screen coordinate (in the
// same camera/framing as render_preview) to a world-space point on the
// nearest body surface, by casting a camera ray into the scene.
//
// This surfaces the viewport's pick math headlessly: the interactive client
// gained tap-to-measure in OCCTSwiftViewport 1.1.20 (#68, including
// ViewportBody.worldHitPoint ray→surface reconstruction); here an LLM that
// is looking at a render_preview PNG can name a pixel and get back the
// measurable world point under it. The returned selectionId is a valid
// add_dimension anchor, so pick → measure composes with the existing
// dimensioning pipeline.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import ScriptHarness

public enum RayPickTool {

    public struct PickReport: Encodable {
        public let hit: Bool
        public let bodyId: String?
        /// World-space surface point [x, y, z] (mm).
        public let point: [Double]?
        /// Distance from the camera/ray origin to the hit (mm).
        public let distance: Double?
        /// Stable id for the picked point, usable directly as an
        /// `add_dimension` anchor (e.g. anchors.from = this id).
        public let selectionId: String?
        /// Human note when nothing was under the coordinate.
        public let note: String?
    }

    /// Cast a ray through pixel (`screenX`, `screenY`) of a `width`×`height`
    /// view framed exactly like `render_preview` with the same `options`, and
    /// return the nearest surface point.
    ///
    /// - Parameters:
    ///   - screenX/screenY: pixel coordinates, top-left origin, in the
    ///     `options.width`×`options.height` image space (matching the preview).
    ///   - id: optional explicit selectionId for the picked point.
    @MainActor
    public static func pickSurfacePoint(
        screenX: Double,
        screenY: Double,
        options: RenderPreviewTool.Options = .init(),
        id: String? = nil,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent

        var bodies: [ViewportBody] = []
        for body in manifest.bodies {
            let path = "\(outputDir)/\(body.file)"
            do {
                let shape = try Shape.loadBREP(fromPath: path)
                let color = RenderPreviewTool.bodyColor(body)
                let bid = body.id ?? UUID().uuidString
                let (vb, _) = CADFileLoader.shapeToBodyAndMetadata(shape, id: bid, color: color)
                if let vb = vb { bodies.append(vb) }
            } catch {
                return .init(
                    "Failed to load body \(body.id ?? body.file): \(error.localizedDescription)",
                    isError: true
                )
            }
        }
        if bodies.isEmpty {
            return .init("No bodies in scene to pick.")
        }

        // Same camera + framing as render_preview, so a pixel the LLM reads
        // off a preview maps to the same ray.
        let state = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)
        let width = max(options.width, 1)
        let height = max(options.height, 1)
        let aspect = Float(width) / Float(height)

        // Pixel (top-left origin) → NDC (centre origin, y up), matching
        // MetalViewportView.handlePickAt.
        let ndcX = Float(screenX / Double(width)) * 2 - 1
        let ndcY = Float(1 - screenY / Double(height)) * 2 - 1
        let ray = Ray.fromCamera(ndc: SIMD2(ndcX, ndcY), cameraState: state, aspectRatio: aspect)

        var bbCache: [String: BoundingBox] = [:]
        for body in bodies where body.boundingBox != nil {
            bbCache[body.id] = body.boundingBox
        }

        guard let hit = SceneRaycast.cast(ray: ray, bodies: bodies, boundingBoxCache: bbCache) else {
            return IntrospectionTools.encode(PickReport(
                hit: false, bodyId: nil, point: nil, distance: nil, selectionId: nil,
                note: "No surface under (\(Int(screenX)), \(Int(screenY))) in this view."
            ))
        }

        let p = hit.point
        let pickId = id ?? "pick:\(hit.bodyID)#\(UUID().uuidString.prefix(8))"
        await registry.recordPointSnapshot(
            selectionId: pickId,
            snapshot: AnchorSnapshot(center: [Double(p.x), Double(p.y), Double(p.z)])
        )

        return IntrospectionTools.encode(PickReport(
            hit: true,
            bodyId: hit.bodyID,
            point: [Double(p.x), Double(p.y), Double(p.z)],
            distance: Double(hit.distance),
            selectionId: pickId,
            note: nil
        ))
    }
}
