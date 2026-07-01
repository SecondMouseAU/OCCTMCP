// IOTools — read_brep, import_file, export_scene. All three are direct
// OCCTSwift calls now: Shape.loadBREP / .loadSTEP / .loadIGES,
// Exporter.writeSTEP / .writeIGES / .writeBREP / .writeSTL / .writeOBJ /
// .writeGLTF.

import Foundation
import OCCTSwift
import ScriptHarness

public enum IOTools {

    // ── read_brep ──────────────────────────────────────────────────────

    public struct LoadReport: Encodable {
        public let bodyId: String
        public let isValid: Bool
        public let shapeType: String
        public let faceCount: Int
        public let edgeCount: Int
        public let vertexCount: Int
        public let boundingBox: IntrospectionTools.MetricsReport.BBox
    }

    public static func readBrep(
        inputPath: String,
        bodyId: String? = nil,
        color: [Float]? = nil,
        allowInvalid: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            return .init("BREP file not found: \(inputPath)")
        }
        let manifestExists = (try? store.read()) != nil
        let manifest: ScriptManifest = (manifestExists ? (try? store.read()) ?? nil : nil) ?? ScriptManifest(
            description: "Imported via read_brep",
            bodies: []
        )

        let resolvedId = bodyId ?? defaultBodyId(from: inputPath)
        if manifest.bodies.contains(where: { $0.id == resolvedId }) {
            return .init("Body id \"\(resolvedId)\" already exists. Pass a different bodyId.")
        }
        let shape: Shape
        do {
            shape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let outFile = "\(resolvedId).brep"
        let outPath = "\(outputDir)/\(outFile)"
        do {
            try Exporter.writeBREP(shape: shape, to: URL(fileURLWithPath: outPath), allowInvalid: allowInvalid)
        } catch {
            return .init("Failed to copy BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)
        var bodies = manifest.bodies
        bodies.append(BodyDescriptor(
            id: resolvedId,
            file: outFile,
            color: color
        ))
        try? store.write(ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description ?? "Imported via read_brep",
            bodies: bodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        ))

        let bb = shape.bounds
        return IntrospectionTools.encode(LoadReport(
            bodyId: resolvedId,
            isValid: shape.isValid,
            shapeType: String(describing: shape.shapeType),
            faceCount: shape.faces().count,
            edgeCount: shape.edges().count,
            vertexCount: shape.vertices().count,
            boundingBox: .init(
                min: [bb.min.x, bb.min.y, bb.min.z],
                max: [bb.max.x, bb.max.y, bb.max.z]
            )
        ))
    }

    // ── import_file ────────────────────────────────────────────────────

    public enum ImportFormat: String {
        case auto, step, iges, obj, brep, stl

        /// Mesh formats (STL / OBJ) load as a raw triangulated shell — open,
        /// often non-manifold, and not a valid solid. They must round-trip
        /// through BREP with the validity gate off, or `writeBREP` rejects them
        /// (which is exactly what the deviation / cross-section tools want in
        /// the scene: a raw scan / STL skin as the reference — #69).
        var isMesh: Bool { self == .stl || self == .obj }

        static func resolve(path: String, hint: ImportFormat) -> ImportFormat? {
            if hint != .auto { return hint }   // explicit format is authoritative
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "step", "stp": return .step
            case "iges", "igs": return .iges
            case "obj": return .obj
            case "brep", "brp": return .brep
            case "stl": return .stl
            default: return nil
            }
        }
    }

    public struct ImportReport: Encodable {
        public let addedBodyIds: [String]
        public let warnings: [String]
    }

    public static func importFile(
        inputPath: String,
        format: ImportFormat = .auto,
        idPrefix: String = "imported",
        allowInvalid: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: inputPath) else {
            return .init("File not found: \(inputPath)")
        }
        guard let resolved = ImportFormat.resolve(path: inputPath, hint: format) else {
            return .init("Could not determine format from extension. Pass `format` explicitly.")
        }

        let shape: Shape
        do {
            switch resolved {
            case .step:
                // 0.001 m = mm, the typical CAD-model length unit. STEP files
                // also encode their own unit, but OCCT requires a fallback.
                shape = try Shape.loadSTEP(fromPath: inputPath, unitInMeters: 0.001)
            case .iges:
                shape = try Shape.loadIGES(fromPath: inputPath)
            case .brep:
                shape = try Shape.loadBREP(fromPath: inputPath)
            case .stl:
                // Raw triangulated shell (no sew/heal) — preserves the scan
                // skin the comparison tools re-mesh; healing could fail or
                // distort an open scan.
                shape = try Shape.loadSTL(fromPath: inputPath)
            case .obj:
                shape = try Shape.loadOBJ(fromPath: inputPath)
            case .auto:
                return .init("Format auto-detection failed.")
            }
        } catch {
            return .init("Import failed: \(error.localizedDescription)", isError: true)
        }

        let manifest: ScriptManifest = (try? store.read()) ?? ScriptManifest(
            description: "Imported via import_file",
            bodies: []
        )
        let id = uniqueBodyId(prefix: idPrefix, manifest: manifest)
        let outputDir = (store.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let outFile = "\(id).brep"
        let outPath = "\(outputDir)/\(outFile)"
        do {
            // Mesh shells aren't valid solids — always skip the write-gate for
            // them so the raw scan lands in the scene.
            try Exporter.writeBREP(shape: shape, to: URL(fileURLWithPath: outPath),
                                   allowInvalid: allowInvalid || resolved.isMesh)
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)
        var bodies = manifest.bodies
        bodies.append(BodyDescriptor(id: id, file: outFile))
        try? store.write(ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description ?? "Imported via import_file",
            bodies: bodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        ))

        return IntrospectionTools.encode(ImportReport(
            addedBodyIds: [id],
            warnings: []
        ))
    }

    // ── export_scene ───────────────────────────────────────────────────

    public enum ExportFormat: String {
        case step, iges, brep, stl, obj, gltf, glb
    }

    public static func exportScene(
        format: ExportFormat,
        outputPath: String,
        bodyIds: [String]? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let bodies: [BodyDescriptor]
        if let ids = bodyIds, !ids.isEmpty {
            let idSet = Set(ids)
            bodies = manifest.bodies.filter { $0.id.flatMap { idSet.contains($0) } ?? false }
            let found = Set(bodies.compactMap { $0.id })
            let missing = ids.filter { !found.contains($0) }
            if !missing.isEmpty {
                return .init("Body ids not found: \(missing.joined(separator: ", "))")
            }
        } else {
            bodies = manifest.bodies
        }
        if bodies.isEmpty {
            return .init("No bodies to export.")
        }

        var shapes: [Shape] = []
        for body in bodies {
            do {
                let s = try Shape.loadBREP(fromPath: "\(outputDir)/\(body.file)")
                shapes.append(s)
            } catch {
                return .init(
                    "Failed to load body \(body.id ?? body.file): \(error.localizedDescription)",
                    isError: true
                )
            }
        }
        let combined: Shape
        if shapes.count == 1 {
            combined = shapes[0]
        } else if let compound = Shape.compound(shapes) {
            combined = compound
        } else {
            return .init("Failed to build compound for \(shapes.count) bodies.", isError: true)
        }

        let outURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            switch format {
            case .step:
                try Exporter.writeSTEP(shape: combined, to: outURL)
            case .iges:
                try Exporter.writeIGES(shape: combined, to: outURL)
            case .brep:
                try Exporter.writeBREP(shape: combined, to: outURL)
            case .stl:
                try Exporter.writeSTL(shape: combined, to: outURL)
            case .obj:
                try Exporter.writeOBJ(shape: combined, to: outURL)
            case .gltf:
                try Exporter.writeGLTF(shape: combined, to: outURL, binary: false)
            case .glb:
                try Exporter.writeGLTF(shape: combined, to: outURL, binary: true)
            }
        } catch {
            return .init("Export failed: \(error.localizedDescription)", isError: true)
        }
        var fileSize = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let size = attrs[.size] as? Int {
            fileSize = size
        }
        return .init(
            "Exported \(shapes.count) bodies → \(outputPath) (\(format.rawValue), \(fileSize) bytes)."
        )
    }

    // ── helpers ────────────────────────────────────────────────────────

    static func defaultBodyId(from path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? "imported" : stem
    }

    static func uniqueBodyId(prefix: String, manifest: ScriptManifest) -> String {
        var i = 0
        while true {
            let candidate = i == 0 ? prefix : "\(prefix)_\(i)"
            if !manifest.bodies.contains(where: { $0.id == candidate }) {
                return candidate
            }
            i += 1
        }
    }
}
