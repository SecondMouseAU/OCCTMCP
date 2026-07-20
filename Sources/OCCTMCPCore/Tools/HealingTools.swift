// HealingTools — heal_shape. Wraps Shape.healed() (which dispatches
// through OCCT's ShapeFix_Shape pipeline).

import Foundation
import OCCTSwift
import ScriptHarness

public enum HealingTools {

    public struct HealReport: Encodable {
        public let outputPath: String
        public let before: HealthSnapshot
        public let after: HealthSnapshot
        public let warnings: [String]

        public struct HealthSnapshot: Encodable {
            public let faceCount: Int
            public let edgeCount: Int
            public let isValid: Bool
        }
    }

    public static func healShape(
        bodyId: String,
        outputBodyId: String? = nil,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        guard let body = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let inputPath = "\(outputDir)/\(body.file)"
        guard FileManager.default.fileExists(atPath: inputPath) else {
            return .init("BREP file missing: \(inputPath)")
        }
        let isInPlace = outputBodyId == nil || outputBodyId == bodyId
        if !isInPlace, let id = outputBodyId, manifest.bodies.contains(where: { $0.id == id }) {
            return .init("Output body id \"\(id)\" already exists.")
        }

        let lineage: (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool)
        do {
            lineage = try await HistoryRegistry.shared.currentInput(bodyId: bodyId, path: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error)", isError: true)
        }
        let inputShape = lineage.shape
        let before = HealReport.HealthSnapshot(
            faceCount: inputShape.faces().count,
            edgeCount: inputShape.edges().count,
            isValid: inputShape.isValid
        )

        // OCCTSwift 1.13.0 (#327) added healedWithFullHistory(); prefer
        // real per-input-subshape history over the old topology-count
        // heuristic; fall back to the plain (history-less) heal only if
        // the *WithFullHistory variant itself returns nil.
        let healed: Shape
        let healHistory: ShapeHistoryRef?
        if let full = inputShape.healedWithFullHistory() {
            healed = full.result
            healHistory = full.history
        } else if let plain = inputShape.healed() {
            healed = plain
            healHistory = nil
        } else {
            return .init("Healing failed (Shape.healed returned nil).", isError: true)
        }
        let after = HealReport.HealthSnapshot(
            faceCount: healed.faces().count,
            edgeCount: healed.edges().count,
            isValid: healed.isValid
        )

        let outputPath: String
        if isInPlace {
            outputPath = inputPath
        } else {
            outputPath = "\(outputDir)/heal-\(outputBodyId!)-\(ConstructionTools.shortUUID()).brep"
        }
        do {
            try Exporter.writeBREP(shape: healed, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)

        let recordedBodyId = isInPlace ? bodyId : (outputBodyId ?? bodyId)
        let historyRecorded = await HistoryRegistry.shared.commit(
            bodyId: recordedBodyId,
            path: outputPath,
            output: healed,
            ref: healHistory,
            from: (lineage.graph, lineage.root),
            operationName: "heal_shape"
        )

        var warnings: [String] = []
        if before.faceCount == after.faceCount &&
            before.edgeCount == after.edgeCount &&
            before.isValid == after.isValid {
            warnings.append("Shape.healed() reported no structural change; before/after may be identical")
        }
        if !historyRecorded {
            warnings.append("Heal history unavailable or absorbed no records: remap_selection will fall back to the centroid heuristic for selections on this body.")
        }

        if !isInPlace, let newId = outputBodyId {
            let newFile = (outputPath as NSString).lastPathComponent
            var bodies = manifest.bodies
            bodies.append(BodyDescriptor(
                id: newId,
                file: newFile,
                format: body.format,
                name: body.name,
                color: body.color,
                roughness: body.roughness,
                metallic: body.metallic
            ))
            try? store.write(ScriptManifest(
                version: manifest.version,
                timestamp: Date(),
                description: manifest.description,
                bodies: bodies,
                graphs: manifest.graphs,
                metadata: manifest.metadata
            ))
        } else {
            try? store.write(manifest)
        }

        return IntrospectionTools.encode(HealReport(
            outputPath: outputPath,
            before: before,
            after: after,
            warnings: warnings
        ))
    }
}
