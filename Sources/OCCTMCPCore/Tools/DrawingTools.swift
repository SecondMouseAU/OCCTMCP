// DrawingTools — generate_drawing wraps DrawingComposer.Composer.render
// directly. The MCP tool accepts the canonical DrawingSpec JSON shape
// and forwards it (with shape + output paths injected) to the composer.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness
import DrawingComposer

public enum DrawingTools {

    public struct DrawingReport: Encodable {
        public let outputPath: String
        public let viewCount: Int
        public let sectionCount: Int
        public let detailCount: Int
        public let scaleLabel: String
        public let fileSize: Int
        /// Number of bodies laid out (1 for a single-part drawing; N for a
        /// general-arrangement / assembly sheet).
        public let componentCount: Int
        /// Number of parts-list rows on the sheet (0 for a single-part drawing).
        public let partCount: Int
    }

    /// Render a drawing for one or more scene bodies. A single body produces a
    /// standard multi-view part drawing (sections / dimensions honoured); several
    /// bodies produce a general-arrangement sheet — shared views, a parts list,
    /// and a numbered balloon per body (OCCTSwiftScripts#50).
    public static func generateDrawing(
        bodyIds: [String],
        outputPath: String,
        spec: Value,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        guard !bodyIds.isEmpty else {
            return .init("generate_drawing requires `bodyId` or a non-empty `bodyIds`.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent

        // Resolve + load every requested body.
        var loaded: [(id: String, name: String, shape: Shape)] = []
        for id in bodyIds {
            guard let body = manifest.body(withId: id) else {
                return .init("Body not found: \(id)")
            }
            let inputPath = "\(outputDir)/\(body.file)"
            guard FileManager.default.fileExists(atPath: inputPath) else {
                return .init("BREP file missing: \(inputPath)")
            }
            do {
                let shape = try Shape.loadBREP(fromPath: inputPath)
                loaded.append((id, body.name ?? id, shape))
            } catch {
                return .init("Failed to load BREP \(id): \(error.localizedDescription)", isError: true)
            }
        }

        guard case .object = spec else {
            return .init("`spec` must be a JSON object.")
        }
        let drawingSpec: DrawingSpec
        do {
            let specData = try JSONEncoder().encode(spec)
            drawingSpec = try JSONDecoder().decode(DrawingSpec.self, from: specData)
        } catch {
            return .init("Invalid DrawingSpec: \(error.localizedDescription)")
        }

        let result: DrawingComposerResult
        do {
            if loaded.count == 1 {
                // Single body → standard part drawing (keeps section / dimension support).
                result = try Composer.render(spec: drawingSpec, shape: loaded[0].shape)
            } else {
                // Multiple bodies → general-arrangement sheet with a parts list.
                let components = loaded.map {
                    Composer.DrawingComponent(shape: $0.shape, name: $0.name, partNumber: $0.id)
                }
                result = try Composer.render(spec: drawingSpec, components: components)
            }
        } catch {
            return .init("Composer.render failed: \(error.localizedDescription)", isError: true)
        }
        do {
            try result.writer.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("DXF write failed: \(error.localizedDescription)", isError: true)
        }

        var size = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let n = attrs[.size] as? Int {
            size = n
        }
        return IntrospectionTools.encode(DrawingReport(
            outputPath: outputPath,
            viewCount: result.viewCount,
            sectionCount: result.sectionCount,
            detailCount: result.detailCount,
            scaleLabel: result.scaleLabel,
            fileSize: size,
            componentCount: result.componentCount,
            partCount: result.partsList.count
        ))
    }
}
