// RenderPreviewTool — render_preview wired against the post-split Tools
// + Viewport stack. Loads each scene body's BREP, converts to
// ViewportBody via OCCTSwiftTools' shapeToBodyAndMetadata, then runs
// OCCTSwiftViewport's OffscreenRenderer.renderToPNG.
//
// Headless-safe on macOS — OffscreenRenderer creates its own MTLDevice
// and renders into an offscreen MTLTexture. No window/display required.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport
import ScriptHarness

public enum RenderPreviewTool {

    public struct Options {
        public var camera: CameraPreset
        public var cameraPosition: SIMD3<Float>?
        public var cameraTarget: SIMD3<Float>?
        public var cameraUp: SIMD3<Float>?
        public var width: Int
        public var height: Int
        public var displayMode: DisplayMode
        public var background: BackgroundSpec
        /// Read `<output_dir>/annotations.json` and overlay the
        /// supported primitive kinds (Trihedron / WorkPlane / Axis /
        /// BoundingBox / DiffMarker). Default true. Dimensions and
        /// PointClouds are silently skipped in v0.5 — no text rendering
        /// path on OffscreenRenderer yet.
        public var renderAnnotations: Bool
        public init(
            camera: CameraPreset = .iso,
            cameraPosition: SIMD3<Float>? = nil,
            cameraTarget: SIMD3<Float>? = nil,
            cameraUp: SIMD3<Float>? = nil,
            width: Int = 800,
            height: Int = 600,
            displayMode: DisplayMode = .shadedWithEdges,
            background: BackgroundSpec = .light,
            renderAnnotations: Bool = true
        ) {
            self.camera = camera
            self.cameraPosition = cameraPosition
            self.cameraTarget = cameraTarget
            self.cameraUp = cameraUp
            self.width = width
            self.height = height
            self.displayMode = displayMode
            self.background = background
            self.renderAnnotations = renderAnnotations
        }
    }

    public enum CameraPreset: String {
        case iso, front, back, top, bottom, left, right
        var standardView: StandardView {
            switch self {
            case .iso:    return .isometricFrontRight
            case .front:  return .front
            case .back:   return .back
            case .top:    return .top
            case .bottom: return .bottom
            case .left:   return .left
            case .right:  return .right
            }
        }
    }

    public enum BackgroundSpec {
        case light, dark, transparent, hex(String)
        var color: SIMD4<Float> {
            switch self {
            case .light:        return SIMD4(0.95, 0.95, 0.95, 1)
            case .dark:         return SIMD4(0.10, 0.10, 0.12, 1)
            case .transparent:  return SIMD4(0, 0, 0, 0)
            case .hex(let s):   return Self.parseHex(s) ?? SIMD4(0.95, 0.95, 0.95, 1)
            }
        }
        static func parseHex(_ s: String) -> SIMD4<Float>? {
            var trimmed = s
            if trimmed.hasPrefix("#") { trimmed.removeFirst() }
            guard trimmed.count == 6 || trimmed.count == 8,
                  let raw = UInt64(trimmed, radix: 16) else { return nil }
            let r, g, b, a: Float
            if trimmed.count == 6 {
                r = Float((raw >> 16) & 0xFF) / 255
                g = Float((raw >> 8)  & 0xFF) / 255
                b = Float(raw         & 0xFF) / 255
                a = 1
            } else {
                r = Float((raw >> 24) & 0xFF) / 255
                g = Float((raw >> 16) & 0xFF) / 255
                b = Float((raw >> 8)  & 0xFF) / 255
                a = Float(raw         & 0xFF) / 255
            }
            return SIMD4(r, g, b, a)
        }
    }

    public struct PreviewReport: Encodable {
        public let outputPath: String
        public let width: Int
        public let height: Int
        public let mimeType: String
    }

    @MainActor
    public static func render(
        outputPath: String,
        bodyIds: [String]? = nil,
        options: Options = .init(),
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let targets: [BodyDescriptor]
        if let ids = bodyIds, !ids.isEmpty {
            let set = Set(ids)
            targets = manifest.bodies.filter { $0.id.flatMap { set.contains($0) } ?? false }
            let found = Set(targets.compactMap { $0.id })
            let missing = ids.filter { !found.contains($0) }
            if !missing.isEmpty {
                return .init("Body ids not found: \(missing.joined(separator: ", "))")
            }
        } else {
            targets = manifest.bodies
        }
        if targets.isEmpty {
            return .init("No bodies to render.")
        }

        var bodies: [ViewportBody] = []
        for body in targets {
            let path = "\(outputDir)/\(body.file)"
            do {
                let shape = try Shape.loadBREP(fromPath: path)
                let color = bodyColor(body)
                let id = body.id ?? UUID().uuidString
                if let vb = viewportBody(for: shape, id: id, color: color) {
                    bodies.append(vb)
                }
            } catch {
                return .init(
                    "Failed to load body \(body.id ?? body.file): \(error.localizedDescription)",
                    isError: true
                )
            }
        }
        if bodies.isEmpty {
            return .init("No renderable bodies.", isError: true)
        }

        // v0.5+: overlay sidecar primitives as additional ViewportBodies.
        // v0.9+: dimensions go through OffscreenRenderOptions.measurements
        // instead, so OffscreenRenderer can render leader/arrow/label
        // in a 2D overlay pass with proper text.
        var measurements: [ViewportMeasurement] = []
        if options.renderAnnotations {
            let sidecar = AnnotationsStore(outputDir: outputDir).read()
            let overlays = AnnotationsRenderer.bodies(from: sidecar)
            bodies.append(contentsOf: overlays)
            measurements = AnnotationsRenderer.measurements(from: sidecar)
        }

        guard let renderer = OffscreenRenderer() else {
            return .init("OffscreenRenderer init failed (no Metal device available).", isError: true)
        }

        var renderOptions = OffscreenRenderOptions(
            width: options.width,
            height: options.height,
            displayMode: options.displayMode,
            backgroundColor: options.background.color
        )
        renderOptions.cameraState = makeCameraState(options: options, bodies: bodies)
        renderOptions.measurements = measurements

        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            let size = try renderer.renderToPNG(bodies: bodies, url: url, options: renderOptions)
            return IntrospectionTools.encode(PreviewReport(
                outputPath: outputPath,
                width: options.width,
                height: options.height,
                mimeType: "image/png"
            )).also(extra: "\nFile size: \(size) bytes")
        } catch {
            return .init("Render failed: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Shape → ViewportBody (mesh-scale guard, #75)

    /// Above this many edges, `shapeToBodyAndMetadata`'s B-rep extraction is
    /// skipped in favour of `meshDirectBody`. The per-edge polyline bridge call
    /// rebuilds an indexed map of ALL edges on every query, so extraction is
    /// O(edges²) — fine for a genuine B-rep solid (hundreds of edges), fatal for
    /// a mesh import: OCCT's StlAPI_Reader lands an STL as one face per facet,
    /// so a 442k-triangle scan is ~1.3M edges ≈ days of extraction (#75). At
    /// this threshold the legacy path worst-cases around a couple of seconds.
    static let meshDirectEdgeThreshold = 10_000

    /// Bridge a scene shape to a renderable body, routing mesh-scale shapes
    /// (edge count above `meshDirectEdgeThreshold`) around the O(edges²) B-rep
    /// edge/vertex extraction. Mesh-scale bodies render without edge overlays
    /// or B-rep vertex pick data — at hundreds of thousands of facets those
    /// would be visual noise anyway.
    static func viewportBody(for shape: Shape, id: String, color: SIMD4<Float>) -> ViewportBody? {
        if shape.edgeCount > meshDirectEdgeThreshold {
            return meshDirectBody(for: shape, id: id, color: color)
        }
        let (vb, _) = CADFileLoader.shapeToBodyAndMetadata(shape, id: id, color: color)
        return vb
    }

    /// Tessellation-only bridge: mesh the shape, interleave positions+normals,
    /// crease-smooth (welds the per-facet vertices STL faces don't share), and
    /// return a body with no edge polylines. Linear in triangle count.
    static func meshDirectBody(for shape: Shape, id: String, color: SIMD4<Float>) -> ViewportBody? {
        guard let mesh = shape.mesh(parameters: CADFileLoader.highQualityMeshParams) else { return nil }
        let vertexCount = mesh.vertexCount
        let indices = mesh.indices
        guard vertexCount > 0, indices.count >= 3 else { return nil }

        let positions = mesh.vertices
        let normals = mesh.normals
        var vertexData: [Float] = []
        vertexData.reserveCapacity(vertexCount * 6)
        for i in 0..<vertexCount {
            let p = positions[i], n = normals[i]
            vertexData.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
        }
        NormalSmoothing.smoothNormals(vertexData: &vertexData, indices: indices)

        // `vertices` feeds combinedBoundsSphere (camera framing) and the CPU
        // pick fallback — mesh positions serve both.
        return ViewportBody(
            id: id, vertexData: vertexData, indices: indices, edges: [],
            vertices: positions,
            color: color
        )
    }

    // MARK: - Helpers

    static func bodyColor(_ body: BodyDescriptor) -> SIMD4<Float> {
        guard let c = body.color, c.count >= 3 else { return SIMD4(0.7, 0.7, 0.75, 1) }
        let a: Float = c.count >= 4 ? c[3] : 1
        return SIMD4(c[0], c[1], c[2], a)
    }

    static func makeCameraState(options: Options, bodies: [ViewportBody]) -> CameraState {
        // Explicit position/target overrides the preset.
        if let pos = options.cameraPosition, let target = options.cameraTarget {
            let up = options.cameraUp ?? SIMD3<Float>(0, 0, 1)
            return CameraState.lookAt(target: target, from: pos, up: up)
        }
        var state = options.camera.standardView.cameraState()
        // Frame: pivot at the centre of the bodies' combined bbox, distance
        // scaled to the bbox extent so the geometry isn't tiny / clipped.
        if let (centre, radius) = combinedBoundsSphere(bodies: bodies) {
            state.pivot = centre
            // Comfortable framing factor; matches OffscreenRenderer demo presets.
            state.distance = max(radius * 3, 1)
        }
        return state
    }

    static func combinedBoundsSphere(bodies: [ViewportBody]) -> (SIMD3<Float>, Float)? {
        var minP = SIMD3<Float>(Float.infinity, .infinity, .infinity)
        var maxP = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        var seen = false
        for body in bodies {
            for v in body.vertices {
                seen = true
                minP = simd.simd_min(minP, v)
                maxP = simd.simd_max(maxP, v)
            }
        }
        guard seen else { return nil }
        let centre = (minP + maxP) * 0.5
        let extent = maxP - minP
        let radius = simd.simd_length(extent) * 0.5
        return (centre, radius)
    }
}

private extension ToolText {
    func also(extra: String) -> ToolText {
        return ToolText(self.text + extra, isError: self.isError)
    }
}
