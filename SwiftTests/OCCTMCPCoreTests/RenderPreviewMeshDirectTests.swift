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

    @Test("mesh-scale shape routes around edge extraction; B-rep solid keeps edges")
    func routing() throws {
        // 63 rows → 7,938 triangular faces, ~12k edges — above the threshold.
        let shell = try meshShell(rows: 63)
        #expect(shell.edgeCount > RenderPreviewTool.meshDirectEdgeThreshold)

        let big = try #require(RenderPreviewTool.viewportBody(
            for: shell, id: "scan", color: SIMD4(1, 1, 1, 1)))
        #expect(big.edges.isEmpty)                       // no O(edges²) extraction
        #expect(big.indices.count / 3 >= 7938)           // every facet made it
        #expect(!big.vertices.isEmpty)                    // camera framing works
        #expect(big.vertexData.count == (big.vertexData.count / 6) * 6)

        // A plain solid stays on the full B-rep path, edge overlays intact.
        let box = Shape.box(width: 10, height: 10, depth: 10)!
        let small = try #require(RenderPreviewTool.viewportBody(
            for: box, id: "box", color: SIMD4(1, 1, 1, 1)))
        #expect(!small.edges.isEmpty)
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
