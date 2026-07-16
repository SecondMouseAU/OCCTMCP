// Tests for the render_preview mesh-scale guard (#75).
//
// OCCT's StlAPI_Reader lands an STL as one TopoDS_Face per facet, and the
// per-edge polyline bridge call rebuilds an indexed map of ALL edges on every
// query — so shapeToBodyAndMetadata's edge extraction is O(edges²): measured
// 0.11s @ 800 edges, 1.3s @ 3.1k, 20s @ 12k, extrapolating to ~84 HOURS at the
// 1.3M edges of a real 442k-triangle scan. render_preview / pick_surface_point /
// overlay_render route shapes above `meshDirectEdgeThreshold` through a
// tessellation-only bridge instead (no edge polylines — linear).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("render_preview mesh-scale guard (#75)")
struct RenderPreviewMeshDirectTests {

    /// Sewn shell of 2·rows² triangular faces — the same one-face-per-triangle
    /// structure class an STL import produces, with ~1.5 edges per triangle.
    func meshShell(rows: Int) throws -> Shape {
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity((rows + 1) * (rows + 1))
        for r in 0...rows {
            for c in 0...rows {
                let x = Float(c), y = Float(r)
                verts.append(SIMD3(x, y, sinf(x * 0.3) * cosf(y * 0.3) * 2))
            }
        }
        var idx: [UInt32] = []
        idx.reserveCapacity(rows * rows * 6)
        let stride = UInt32(rows + 1)
        for r in 0..<rows {
            for c in 0..<rows {
                let a = UInt32(r) * stride + UInt32(c)
                let b = a + 1, d = a + stride, e = d + 1
                idx += [a, b, e, a, e, d]
            }
        }
        guard let mesh = OCCTSwift.Mesh(vertices: verts, indices: idx),
              let shape = mesh.toShape() else {
            throw TestError.fixture("failed to build mesh shell")
        }
        return shape
    }

    enum TestError: Error { case fixture(String) }

    @Test("mesh-scale routing: mid-size keeps linear edge overlays, huge goes surface-only")
    func routing() throws {
        // 63 rows → 7,938 triangular faces, ~12k edges — above the mesh-direct
        // threshold, below the edge-overlay cap: linear bulk wireframe (#275).
        let shell = try meshShell(rows: 63)
        let edgeCount = shell.edgeCount
        #expect(edgeCount > RenderPreviewTool.meshDirectEdgeThreshold)
        #expect(edgeCount <= RenderPreviewTool.edgeOverlayCap)

        let mid = try #require(RenderPreviewTool.viewportBody(
            for: shell, id: "scan", color: SIMD4(1, 1, 1, 1)))
        #expect(!mid.edges.isEmpty)                       // wireframe restored via bulk API
        #expect(mid.edges.count <= edgeCount)             // dense: skips allowed, no invention
        #expect(mid.indices.count / 3 >= 7938)            // every facet made it
        #expect(!mid.vertices.isEmpty)                     // camera framing works
        #expect(mid.vertexData.count == (mid.vertexData.count / 6) * 6)

        // Past the overlay cap (forced low here), the same shape renders
        // surface-only — facet wireframe at scan scale is noise + memory churn.
        let huge = try #require(RenderPreviewTool.viewportBody(
            for: shell, id: "scan2", color: SIMD4(1, 1, 1, 1),
            edgeOverlayCap: 1_000))
        #expect(huge.edges.isEmpty)
        #expect(huge.indices == mid.indices)              // surface identical either way

        // A plain solid stays on the full B-rep path, edge overlays intact.
        let box = Shape.box(width: 10, height: 10, depth: 10)!
        let small = try #require(RenderPreviewTool.viewportBody(
            for: box, id: "box", color: SIMD4(1, 1, 1, 1)))
        #expect(!small.edges.isEmpty)
    }

    // ── #76 step 3: sub-threshold B-reps take the Tools direct-mesh bridge ──

    @Test("sub-threshold routing: B-reps go direct-mesh, facet shells keep smoothing")
    func directMeshCallsites() throws {
        // B-rep solids (analytic normals) → direct bridge, edge overlays intact.
        for shape in [Shape.box(width: 10, height: 10, depth: 10)!,
                      Shape.cylinder(radius: 5, height: 20)!] {
            let body = try #require(RenderPreviewTool.viewportBody(
                for: shape, id: "brep", color: SIMD4(1, 1, 1, 1)))
            #expect(body.usesDirectMesh, "B-rep should take the direct-mesh bridge")
            #expect(body.vertexData.isEmpty)
            #expect(!body.edges.isEmpty, "edge overlays survive the direct path")
        }

        // A sub-threshold sewn facet shell (planar per-face normals) must stay
        // interleaved so NormalSmoothing can weld its shading — the #76 caveat.
        let shell = try meshShell(rows: 40)          // 3,200 tris, ~4.9k edges
        #expect(shell.edgeCount <= RenderPreviewTool.meshDirectEdgeThreshold)
        let shellBody = try #require(RenderPreviewTool.viewportBody(
            for: shell, id: "shell", color: SIMD4(1, 1, 1, 1)))
        #expect(!shellBody.usesDirectMesh, "facet shell must keep the smoothing path")
        #expect(!shellBody.vertexData.isEmpty)
    }

    @Test("facet-shell heuristic: ratio bands classify soups vs B-reps")
    func facetShellHeuristic() {
        // Sewn triangle soup: E/F ≈ 1.5.
        #expect(RenderPreviewTool.isLikelyFacetShell(faceCount: 3200, edgeCount: 4880))
        // Unsewn triangle compound: E/F = 3.0.
        #expect(RenderPreviewTool.isLikelyFacetShell(faceCount: 3200, edgeCount: 9600))
        // Prismatic assembly: E/F ≈ 2.0 (boxes) — genuine B-rep, direct-safe.
        #expect(!RenderPreviewTool.isLikelyFacetShell(faceCount: 600, edgeCount: 1200))
        // Small shapes are never scans; ratio is meaningless (cylinder: 3/3).
        #expect(!RenderPreviewTool.isLikelyFacetShell(faceCount: 3, edgeCount: 3))
        #expect(!RenderPreviewTool.isLikelyFacetShell(faceCount: 6, edgeCount: 12))
    }

    @MainActor
    @Test("render_preview completes on a mesh-scale body")
    func renderCompletes() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-meshdirect-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let shell = try meshShell(rows: 63)
        try Exporter.writeBREP(shape: shell, to: URL(fileURLWithPath: "\(dir)/scan.brep"),
                               allowInvalid: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(
            version: 1, timestamp: Date(), description: "meshdirect",
            bodies: [BodyDescriptor(id: "scan", file: "scan.brep", color: [1, 1, 1, 1])]))

        let png = "\(dir)/preview.png"
        let result = await RenderPreviewTool.render(
            outputPath: png, bodyIds: ["scan"], options: .init(width: 400, height: 300),
            store: store)
        if result.isError && result.text.contains("Metal") { return }   // headless w/o GPU
        #expect(!result.isError, "unexpected error: \(result.text)")
        #expect(FileManager.default.fileExists(atPath: png))
    }
}
