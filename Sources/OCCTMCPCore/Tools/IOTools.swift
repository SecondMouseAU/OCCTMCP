// IOTools: read_brep, import_file, export_scene. All three are direct
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
            return .init("BREP file not found: \(inputPath)", isError: true)
        }
        let manifest: ScriptManifest
        do {
            manifest =
                try store.requireSceneOrAbsent()
                ?? ScriptManifest(description: "Imported via read_brep", bodies: [])
        } catch {
            return .manifestFailure(error)
        }

        let resolvedId = bodyId ?? defaultBodyId(from: inputPath)
        if manifest.bodies.contains(where: { $0.id == resolvedId }) {
            return .init(
                "Body id \"\(resolvedId)\" already exists. Pass a different bodyId.", isError: true)
        }
        let shape: Shape
        do {
            shape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }
        // Read the extent BEFORE the scene is mutated, so a BREP that parses but
        // holds nothing measurable is rejected instead of being registered as a
        // body whose reported extent would have to be invented (OCCTSwift #943).
        guard let bb = shape.bounds else {
            return .init(
                "\(DeviationTools.noBoundingBoxMessage(resolvedId)) Nothing was added to the scene.",
                isError: true)
        }

        do {
            try await SceneBodies.add(
                shape: shape, bodyId: resolvedId, color: color, allowInvalid: allowInvalid,
                description: "Imported via read_brep", store: store, history: history)
        } catch SceneBodiesError.writeFailed(let underlying) {
            return .init("Failed to copy BREP: \(underlying)", isError: true)
        } catch let error as SceneBodiesError {
            return .init("\(error)", isError: true)
        } catch {
            return .manifestFailure(error)
        }

        return IntrospectionTools.encode(
            LoadReport(
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

    public enum ImportFormat: String, CaseIterable {
        case auto, step, iges, obj, brep, stl

        /// The format a file extension or a manifest body's `format` field names, nil for anything
        /// else.
        ///
        /// Case-insensitive, and it accepts the extension spellings `stp`, `igs` and `brp`.
        /// `auto` names no format, so it is nil here.
        init?(spelling: String) {
            switch spelling.lowercased() {
            case "step", "stp": self = .step
            case "iges", "igs": self = .iges
            case "obj": self = .obj
            case "brep", "brp": self = .brep
            case "stl": self = .stl
            default: return nil
            }
        }

        /// Mesh formats (STL / OBJ) load as a raw triangulated shell, open,
        /// often non-manifold, and not a valid solid.
        ///
        /// They must round-trip through BREP with the validity gate off, or
        /// `writeBREP` rejects them (which is exactly what the deviation /
        /// cross-section tools want in the scene: a raw scan / STL skin as the
        /// reference, #69).
        var isMesh: Bool { self == .stl || self == .obj }

        static func resolve(path: String, hint: ImportFormat) -> ImportFormat? {
            if hint != .auto { return hint }  // explicit format is authoritative
            return ImportFormat(spelling: (path as NSString).pathExtension)
        }
    }

    /// Read `path` as `format`; the one place a CAD file is turned into a Shape by format.
    ///
    /// `import_file` and `BodyLoader` both call it, so a body and an import of the same file agree.
    /// Throws for `.auto`, which `ImportFormat.resolve` never returns.
    static func loadShape(fromPath path: String, as format: ImportFormat) throws -> Shape {
        switch format {
        case .step:
            // 0.001 m = mm, the typical CAD-model length unit. STEP files
            // also encode their own unit, but OCCT requires a fallback.
            return try Shape.loadSTEP(fromPath: path, unitInMeters: 0.001)
        case .iges:
            return try Shape.loadIGES(fromPath: path)
        case .brep:
            return try Shape.loadBREP(fromPath: path)
        case .stl:
            // Raw triangulated shell (no sew/heal), preserves the scan
            // skin the comparison tools re-mesh; healing could fail or
            // distort an open scan.
            return try Shape.loadSTL(fromPath: path)
        case .obj:
            return try Shape.loadOBJ(fromPath: path)
        case .auto:
            // Kept as an error so a future change to `resolve` cannot turn this into a
            // success-shaped message.
            throw ImportFormatError.auto
        }
    }

    enum ImportFormatError: Error, LocalizedError {
        case auto
        var errorDescription: String? { "Format auto-detection failed." }
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
            return .init("File not found: \(inputPath)", isError: true)
        }
        guard let resolved = ImportFormat.resolve(path: inputPath, hint: format) else {
            return .init(
                "Could not determine format from extension. Pass `format` explicitly.",
                isError: true)
        }

        let shape: Shape
        do {
            shape = try loadShape(fromPath: inputPath, as: resolved)
        } catch {
            return .init("Import failed: \(error.localizedDescription)", isError: true)
        }

        let addedId: String
        do {
            // Mesh shells aren't valid solids, always skip the write-gate for
            // them so the raw scan lands in the scene.
            addedId = try await SceneBodies.add(
                shape: shape, idPrefix: idPrefix, allowInvalid: allowInvalid || resolved.isMesh,
                description: "Imported via import_file", store: store, history: history)
        } catch SceneBodiesError.writeFailed(let underlying) {
            return .init("Failed to write BREP: \(underlying)", isError: true)
        } catch let error as SceneBodiesError {
            return .init("\(error)", isError: true)
        } catch {
            return .manifestFailure(error)
        }

        return IntrospectionTools.encode(
            ImportReport(
                addedBodyIds: [addedId],
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
        let manifest: ScriptManifest
        do { manifest = try store.requireScene() } catch { return .manifestFailure(error) }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let bodies: [BodyDescriptor]
        if let ids = bodyIds, !ids.isEmpty {
            let idSet = Set(ids)
            bodies = manifest.bodies.filter { $0.id.flatMap { idSet.contains($0) } ?? false }
            let found = Set(bodies.compactMap { $0.id })
            let missing = ids.filter { !found.contains($0) }
            if !missing.isEmpty {
                return .init(
                    "Body ids not found: \(missing.joined(separator: ", "))", isError: true)
            }
        } else {
            bodies = manifest.bodies
        }
        if bodies.isEmpty {
            return .init("No bodies to export.", isError: true)
        }

        var shapes: [Shape] = []
        for body in bodies {
            do {
                let s = try BodyLoader.loadShape(body: body, outputDir: outputDir)
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
            let size = attrs[.size] as? Int
        {
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
