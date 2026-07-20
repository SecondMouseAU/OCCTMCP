// FeatureTools — apply_feature. Wraps OCCTSwift's
// FeatureReconstructor.buildJSON, the JSON-driven dispatcher for the
// FeatureSpec catalog (drill / fillet / chamfer / extrude / revolve /
// thread / boolean).

import Foundation
import MCP
import OCCTSwift
import ScriptHarness

public enum FeatureTools {

    public struct ApplyReport: Encodable {
        public let outputPath: String
        public let inPlace: Bool
        public let bodyId: String
        public let outputBodyId: String?
        public let fulfilled: [String]
        public let skipped: [SkippedReport]
        public let annotations: [AnnotationReport]

        public struct SkippedReport: Encodable {
            public let id: String
            public let stage: String
            public let reason: String
        }
        public struct AnnotationReport: Encodable {
            public let id: String
            public let kind: String
        }
    }

    public static func applyFeature(
        bodyId: String,
        feature: Value,
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

        let lineage: (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool)
        do {
            lineage = try await HistoryRegistry.shared.currentInput(bodyId: bodyId, path: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error)", isError: true)
        }
        let inputShape = lineage.shape

        let envelope: Value = .object([
            "features": .array([feature]),
        ])
        let envelopeData: Data
        do {
            envelopeData = try JSONEncoder().encode(envelope)
        } catch {
            return .init("Failed to encode feature spec: \(error.localizedDescription)", isError: true)
        }

        let result: FeatureReconstructor.BuildResult
        do {
            result = try FeatureReconstructor.buildJSON(envelopeData, inputBody: inputShape)
        } catch {
            return .init("FeatureReconstructor failed: \(error.localizedDescription)", isError: true)
        }
        guard let outputShape = result.shape else {
            let skipped = result.skipped.map { "\($0.featureID): \($0.reason)" }.joined(separator: "; ")
            return .init("FeatureReconstructor produced no shape. Skipped: \(skipped)")
        }

        let isInPlace = outputBodyId == nil || outputBodyId == bodyId
        if !isInPlace, let id = outputBodyId, manifest.bodies.contains(where: { $0.id == id }) {
            return .init("Output body id \"\(id)\" already exists.")
        }
        let outputPath = isInPlace
            ? inputPath
            : "\(outputDir)/applied-\(outputBodyId!)-\(ConstructionTools.shortUUID()).brep"
        do {
            try Exporter.writeBREP(shape: outputShape, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)

        // Per-feature history (#90/#93): absorb into the source body's
        // retained graph. Only one feature is submitted per apply_feature
        // call (`features: [feature]` above), so result.histories almost
        // always has at most one entry; the rare multi-entry case chains
        // each absorb against the previous one's resulting root.
        //
        // Absorb ONCE per graph object and write ONLY mutatedBodyId's
        // entry: when it differs from bodyId (a new output body), bodyId's
        // own entry already shares the SAME graph object (BRepGraph is
        // a reference type) and sees the absorbed history for free.
        // Writing a second entry for it would overwrite its liveShape/
        // fingerprint with the output and corrupt the next read of the
        // source body, which is exactly the double-absorb-into-one-graph
        // hazard retention introduces (harmless when each side built its
        // own disposable graph, as it did pre-retention).
        let mutatedBodyId = (isInPlace || outputBodyId == nil) ? bodyId : outputBodyId!
        let refs = result.histories.sorted { $0.key < $1.key }.map(\.value)
        if refs.isEmpty {
            await HistoryRegistry.shared.commit(
                bodyId: mutatedBodyId, path: outputPath, output: outputShape,
                ref: nil, from: nil, operationName: "apply_feature"
            )
        } else {
            var chain: (graph: BRepGraph, root: BRepGraph.NodeRef)? = (lineage.graph, lineage.root)
            for ref in refs.dropLast() {
                guard let current = chain,
                      let newRoot = await HistoryRegistry.shared.absorb(
                          into: current.graph, root: current.root, output: outputShape,
                          ref: ref, operationName: "apply_feature"
                      ) else {
                    chain = nil
                    break
                }
                chain = (current.graph, newRoot)
            }
            await HistoryRegistry.shared.commit(
                bodyId: mutatedBodyId, path: outputPath, output: outputShape,
                ref: refs.last, from: chain, operationName: "apply_feature"
            )
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

        return IntrospectionTools.encode(ApplyReport(
            outputPath: outputPath,
            inPlace: isInPlace,
            bodyId: bodyId,
            outputBodyId: outputBodyId,
            fulfilled: result.fulfilled,
            skipped: result.skipped.map {
                .init(id: $0.featureID, stage: "\($0.stage)", reason: "\($0.reason)")
            },
            annotations: result.annotations.map {
                .init(id: $0.featureID, kind: "\($0.kind)")
            }
        ))
    }
}
