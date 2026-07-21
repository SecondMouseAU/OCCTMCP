// MeshTools — generate_mesh and simplify_mesh, both backed by direct
// OCCTSwift / OCCTSwiftMesh calls.

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import ScriptHarness

public enum MeshTools {

    // ── generate_mesh ──────────────────────────────────────────────────

    public struct MeshReport: Encodable {
        public let triangleCount: Int
        public let vertexCount: Int
        public let quality: Quality
        public let geometry: Geometry?
        public let outputPath: String?

        public struct Quality: Encodable {
            public let minAspectRatio: Double
            public let meanAspectRatio: Double
            public let degenerateTriangles: Int
            public let nonManifoldEdges: Int
        }
        public struct Geometry: Encodable {
            public let vertices: [Float]
            public let indices: [UInt32]
        }
    }

    public static func generateMesh(
        bodyId: String,
        linearDeflection: Double = 0.1,
        angularDeflection: Double = 0.5,
        returnGeometry: Bool = false,
        outputPath: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        var params = MeshParameters.default
        params.deflection = linearDeflection
        params.angle = angularDeflection
        guard let mesh = loaded.shape.mesh(parameters: params) else {
            return .init("Mesh generation failed.", isError: true)
        }
        let quality = computeQuality(mesh)

        var geometry: MeshReport.Geometry?
        if returnGeometry {
            let verts = mesh.vertices
            let flat = verts.flatMap { [$0.x, $0.y, $0.z] }
            geometry = .init(vertices: flat, indices: mesh.indices)
        }

        if let path = outputPath {
            do {
                try writeMesh(mesh: mesh, path: path)
            } catch {
                return .init("Failed to write mesh: \(error.localizedDescription)", isError: true)
            }
        }

        let report = MeshReport(
            triangleCount: mesh.triangleCount,
            vertexCount: mesh.vertexCount,
            quality: quality,
            geometry: geometry,
            outputPath: outputPath
        )
        return IntrospectionTools.encode(report)
    }

    // ── simplify_mesh ──────────────────────────────────────────────────

    public struct SimplifyReport: Encodable {
        public let beforeTriangleCount: Int
        public let afterTriangleCount: Int
        public let qualityDelta: QualityDelta
        public let outputPath: String

        public struct QualityDelta: Encodable {
            public let meanAspectRatioDelta: Double
            public let hausdorffDistance: Double
        }
    }

    public static func simplifyMesh(
        bodyId: String,
        outputPath: String,
        targetTriangleCount: Int? = nil,
        targetReduction: Double? = nil,
        preserveBoundary: Bool = true,
        preserveTopology: Bool = true,
        maxHausdorffDistance: Double? = nil,
        linearDeflection: Double = 0.1,
        angularDeflection: Double = 0.5,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        if (targetTriangleCount == nil) == (targetReduction == nil) {
            return .init("Pass exactly one of targetTriangleCount or targetReduction.")
        }
        let ext = (outputPath as NSString).pathExtension.lowercased()
        guard ext == "stl" || ext == "obj" else {
            return .init("outputPath must end in .stl or .obj (got .\(ext)).")
        }

        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        var params = MeshParameters.default
        params.deflection = linearDeflection
        params.angle = angularDeflection
        guard let inputMesh = loaded.shape.mesh(parameters: params) else {
            return .init("Mesh generation failed.", isError: true)
        }
        let beforeMean = meanAspectRatio(of: inputMesh)

        let options = Mesh.SimplifyOptions(
            targetTriangleCount: targetTriangleCount,
            targetReduction: targetReduction,
            preserveBoundary: preserveBoundary,
            preserveTopology: preserveTopology,
            maxHausdorffDistance: maxHausdorffDistance
        )
        guard let simplified = inputMesh.simplified(options) else {
            return .init("Simplification failed — check options.", isError: true)
        }
        let afterMean = meanAspectRatio(of: simplified.mesh)

        do {
            try writeMesh(mesh: simplified.mesh, path: outputPath)
        } catch {
            return .init("Failed to write mesh: \(error.localizedDescription)", isError: true)
        }

        return IntrospectionTools.encode(SimplifyReport(
            beforeTriangleCount: simplified.beforeTriangleCount,
            afterTriangleCount: simplified.afterTriangleCount,
            qualityDelta: .init(
                meanAspectRatioDelta: afterMean - beforeMean,
                hausdorffDistance: simplified.hausdorffDistance
            ),
            outputPath: outputPath
        ))
    }

    // ── shared mesh quality + writers ──────────────────────────────────

    static func computeQuality(_ mesh: Mesh) -> MeshReport.Quality {
        let verts = mesh.vertices
        let idx = mesh.indices
        var sum = 0.0
        var minR = Double.infinity
        var degenerates = 0
        let triCount = idx.count / 3
        for t in 0..<triCount {
            let i0 = Int(idx[t * 3]), i1 = Int(idx[t * 3 + 1]), i2 = Int(idx[t * 3 + 2])
            guard i0 < verts.count, i1 < verts.count, i2 < verts.count else { continue }
            let a = verts[i0], b = verts[i1], c = verts[i2]
            let e0 = simdLength(b - a), e1 = simdLength(c - b), e2 = simdLength(a - c)
            let mn = min(e0, min(e1, e2))
            let mx = max(e0, max(e1, e2))
            if mn <= 1e-9 { degenerates += 1; continue }
            let r = Double(mx / mn)
            sum += r
            if r < minR { minR = r }
        }
        let counted = max(triCount - degenerates, 1)
        // Non-manifold edge count (Phase 2, #mesh-diagnose): reuses
        // OCCTSwiftMesh's `integrityReport(weldTolerance:)` (weld + an
        // O(n) edge-valence map, same primitive `mesh_diagnose` calls
        // directly) rather than duplicating that edge map here.
        let nonManifoldEdges = mesh.integrityReport().nonManifoldEdgeCount
        return .init(
            minAspectRatio: minR.isFinite ? minR : 1,
            meanAspectRatio: sum / Double(counted),
            degenerateTriangles: degenerates,
            nonManifoldEdges: nonManifoldEdges
        )
    }

    static func meanAspectRatio(of mesh: Mesh) -> Double {
        return computeQuality(mesh).meanAspectRatio
    }

    static func writeMesh(mesh: Mesh, path: String) throws {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        let verts = mesh.vertices
        let idx = mesh.indices
        switch ext {
        case "stl":
            var out = "solid generated\n"
            for t in 0..<(idx.count / 3) {
                let i0 = Int(idx[t * 3]), i1 = Int(idx[t * 3 + 1]), i2 = Int(idx[t * 3 + 2])
                guard i0 < verts.count, i1 < verts.count, i2 < verts.count else { continue }
                let a = verts[i0], b = verts[i1], c = verts[i2]
                let n = simdNormalize(simdCross(b - a, c - a))
                out += "  facet normal \(n.x) \(n.y) \(n.z)\n"
                out += "    outer loop\n"
                out += "      vertex \(a.x) \(a.y) \(a.z)\n"
                out += "      vertex \(b.x) \(b.y) \(b.z)\n"
                out += "      vertex \(c.x) \(c.y) \(c.z)\n"
                out += "    endloop\n  endfacet\n"
            }
            out += "endsolid generated\n"
            try out.write(to: url, atomically: true, encoding: .utf8)
        case "obj":
            var out = "# OCCTMCP generate_mesh\n"
            for v in verts { out += "v \(v.x) \(v.y) \(v.z)\n" }
            for t in 0..<(idx.count / 3) {
                let i0 = idx[t * 3] + 1
                let i1 = idx[t * 3 + 1] + 1
                let i2 = idx[t * 3 + 2] + 1
                out += "f \(i0) \(i1) \(i2)\n"
            }
            try out.write(to: url, atomically: true, encoding: .utf8)
        default:
            throw MeshError.unsupportedExtension(ext)
        }
    }

    enum MeshError: Error, CustomStringConvertible {
        case unsupportedExtension(String)
        var description: String {
            switch self {
            case .unsupportedExtension(let ext):
                return "Unsupported mesh extension '.\(ext)'; use .stl or .obj"
            }
        }
    }
}

// Tiny SIMD helpers so the file doesn't have to import simd.
import simd
private func simdLength(_ v: SIMD3<Float>) -> Float { simd.simd_length(v) }
private func simdCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { simd.simd_cross(a, b) }
private func simdNormalize(_ v: SIMD3<Float>) -> SIMD3<Float> { simd.simd_normalize(v) }
