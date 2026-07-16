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

    /// Above this many edges, `shapeToBodyAndMetadata`'s full B-rep extraction
    /// is skipped in favour of `meshDirectBody`. Historically this guarded an
    /// O(edges²) hang (#75) — since OCCTSwift 1.10.0 / OCCTSwiftTools 1.3.1
    /// both paths are linear (OCCTSwift#275), so the threshold now guards
    /// weight, not correctness: a mesh import (StlAPI_Reader = one face per
    /// facet; a 442k-tri scan is ~1.3M edges) would still pay for per-segment
    /// edge-pick indices, B-rep vertex pick arrays, and per-edge polyline
    /// allocations that render/raycast never consume at that scale.
    static let meshDirectEdgeThreshold = 10_000

    /// Above this many edges, `meshDirectBody` omits edge overlays outright.
    /// Below it they come from OCCTSwift ≥1.9.0's bulk `allEdgePolylines`
    /// (O(edges), OCCTSwift#275 — ~0.02s at 12k edges), so mid-size mesh
    /// imports keep their wireframe; past it, hundreds of thousands of facet
    /// edges are wireframe noise and pure memory churn.
    static let edgeOverlayCap = 100_000

    /// Bridge a scene shape to a renderable body, routing mesh-scale shapes
    /// (edge count above `meshDirectEdgeThreshold`) around Tools'
    /// O(edges²) B-rep edge/vertex extraction. Mesh-scale bodies up to
    /// `edgeOverlayCap` edges keep edge overlays via the linear bulk API
    /// (dense — no per-edge pick identity, which render/raycast never used);
    /// beyond the cap they render surface-only.
    static func viewportBody(
        for shape: Shape, id: String, color: SIMD4<Float>,
        meshDirectEdgeThreshold: Int = RenderPreviewTool.meshDirectEdgeThreshold,
        edgeOverlayCap: Int = RenderPreviewTool.edgeOverlayCap
    ) -> ViewportBody? {
        let edgeCount = shape.edgeCount
        if edgeCount > meshDirectEdgeThreshold {
            return meshDirectBody(for: shape, id: id, color: color,
                                  withEdgeOverlays: edgeCount <= edgeOverlayCap)
        }
        // #76 step 3: B-rep bodies take Tools' direct-mesh bridge — OCCT's
        // per-vertex normals off a fine B-rep mesh are analytic-quality, so
        // skipping the interleave + NormalSmoothing pass changes nothing
        // visually and drops a full CPU copy per body. The one class that
        // MUST stay interleaved (the issue's own caveat) is a facet shell,
        // whose planar per-face normals only shade smoothly because
        // NormalSmoothing welds them by position.
        let direct = !isLikelyFacetShell(faceCount: shape.faces().count, edgeCount: edgeCount)
        let (vb, _) = CADFileLoader.shapeToBodyAndMetadata(
            shape, id: id, color: color, directMesh: direct)
        return vb
    }

    /// Facet-shell heuristic for the sub-threshold path. Triangle soups sit at
    /// a distinctive edges-per-face ratio: ~1.5 sewn (each interior edge shared
    /// by two triangles), ~3.0 unsewn (nothing shared). Genuine B-reps at any
    /// real face count live between — prismatic/quad-dominant faces ≈ 2.0–2.5.
    /// Below 64 faces nothing is a scan; ratios there are meaningless (a
    /// cylinder is 3 faces / 3 edges) and analytic normals make direct safe.
    /// False positives are harmless: an interleaved body renders identically,
    /// it just keeps the smoothing pass it didn't need.
    static func isLikelyFacetShell(faceCount: Int, edgeCount: Int) -> Bool {
        guard faceCount >= 64 else { return false }
        let ratio = Double(edgeCount) / Double(faceCount)
        return !(1.85...2.55).contains(ratio)
    }

    /// Tessellation-only bridge: mesh the shape, interleave positions+normals,
    /// crease-smooth (welds the per-facet vertices STL faces don't share), and
    /// return a body whose edge overlays (when requested) come from the bulk
    /// O(edges) `allEdgePolylines` instead of Tools' per-index loop. Linear in
    /// triangle count.
    ///
    /// Deliberately NOT `ViewportBody.directMesh` (#76): the direct path uses
    /// normals verbatim, but a facet-per-face STL import needs the
    /// `NormalSmoothing` pass here to shade smoothly — smoothing only runs on
    /// the interleaved layout.
    static func meshDirectBody(
        for shape: Shape, id: String, color: SIMD4<Float>,
        withEdgeOverlays: Bool = false
    ) -> ViewportBody? {
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

        // Dense polylines suffice here: the offscreen renderer draws them and
        // SceneRaycast picks triangles — nothing consumes per-edge indices.
        // 0.005 matches OCCTSwiftTools' defaultEdgeDeflection so the wireframe
        // reads the same as the sub-threshold Tools path.
        var edges: [[SIMD3<Float>]] = []
        if withEdgeOverlays {
            edges = shape.allEdgePolylines(deflection: 0.005, maxPointsPerEdge: 1000)
                .map { $0.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) } }
        }

        // `vertices` feeds combinedBoundsSphere (camera framing) and the CPU
        // pick fallback — mesh positions serve both.
        return ViewportBody(
            id: id, vertexData: vertexData, indices: indices, edges: edges,
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
