// ConstructionTools — scene-mutating tools that build new shapes from
// existing ones via direct OCCTSwift calls. Each tool snapshots the
// scene before mutating so compare_versions has prior state.
//
// Phase 5.3b covers transform_body and boolean_op. mirror_or_pattern
// and apply_feature land alongside Phase 5.3c.

import Foundation
import OCCTSwift
import ScriptHarness

public enum ConstructionTools {

    // ── transform_body ─────────────────────────────────────────────────

    public struct TransformOptions {
        public var translate: SIMD3<Double>?
        public var rotateAxisAngle: (axis: SIMD3<Double>, radians: Double)?
        public var rotateEulerXyz: SIMD3<Double>?
        public var scale: Double?
        public var inPlace: Bool?
        public var outputBodyId: String?
        public init(
            translate: SIMD3<Double>? = nil,
            rotateAxisAngle: (axis: SIMD3<Double>, radians: Double)? = nil,
            rotateEulerXyz: SIMD3<Double>? = nil,
            scale: Double? = nil,
            inPlace: Bool? = nil,
            outputBodyId: String? = nil
        ) {
            self.translate = translate
            self.rotateAxisAngle = rotateAxisAngle
            self.rotateEulerXyz = rotateEulerXyz
            self.scale = scale
            self.inPlace = inPlace
            self.outputBodyId = outputBodyId
        }
    }

    public static func transformBody(
        bodyId: String,
        options: TransformOptions,
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

        let isInPlace = options.inPlace ?? (options.outputBodyId == nil)
        if !isInPlace, let newId = options.outputBodyId,
           manifest.bodies.contains(where: { $0.id == newId }) {
            return .init("Output body id \"\(newId)\" already exists.")
        }

        let inputShape: Shape
        do {
            inputShape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }

        var current: Shape = inputShape
        if let t = options.translate {
            guard let next = current.translated(by: t) else {
                return .init("Translation failed.", isError: true)
            }
            current = next
        }
        if let r = options.rotateAxisAngle {
            guard let next = current.rotated(axis: r.axis, angle: r.radians) else {
                return .init("Rotation failed.", isError: true)
            }
            current = next
        }
        if let euler = options.rotateEulerXyz {
            // extrinsic XYZ: Rx then Ry then Rz
            for (axis, angle) in [
                (SIMD3<Double>(1, 0, 0), euler.x),
                (SIMD3<Double>(0, 1, 0), euler.y),
                (SIMD3<Double>(0, 0, 1), euler.z),
            ] where angle != 0 {
                guard let next = current.rotated(axis: axis, angle: angle) else {
                    return .init("Rotation failed.", isError: true)
                }
                current = next
            }
        }
        if let s = options.scale {
            guard let next = current.scaled(by: s) else {
                return .init("Scale failed.", isError: true)
            }
            current = next
        }

        let outputPath: String
        if isInPlace {
            outputPath = inputPath
        } else {
            let id = options.outputBodyId ?? bodyId
            outputPath = "\(outputDir)/xform-\(id)-\(shortUUID()).brep"
        }
        do {
            try Exporter.writeBREP(shape: current, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)

        // v0.6: record 1:1 identity history so remap_selection can
        // resolve via TopologyGraph.findDerived rather than the
        // centroid heuristic. Transforms preserve topology, so every
        // post-mutation node maps to the same index pre-mutation.
        let recordedBodyId = isInPlace ? bodyId : (options.outputBodyId ?? bodyId)
        await HistoryRegistry.shared.recordIdentityHistory(
            bodyId: recordedBodyId,
            postMutationShape: current,
            operationName: "transform_body"
        )

        if !isInPlace, let newId = options.outputBodyId {
            let newFile = (outputPath as NSString).lastPathComponent
            let newBodies = manifest.bodies + [BodyDescriptor(
                id: newId,
                file: newFile,
                format: body.format,
                name: body.name,
                color: body.color,
                roughness: body.roughness,
                metallic: body.metallic
            )]
            let updated = ScriptManifest(
                version: manifest.version,
                timestamp: Date(),
                description: manifest.description,
                bodies: newBodies,
                graphs: manifest.graphs,
                metadata: manifest.metadata
            )
            try? store.write(updated)
        } else {
            // Manifest body file unchanged; bump timestamp so the watcher reloads.
            try? store.write(manifest)
        }

        let summary = isInPlace
            ? "Transformed \"\(bodyId)\" in place (\(body.file))."
            : "Transformed \"\(bodyId)\" → new body \"\(options.outputBodyId!)\" → \((outputPath as NSString).lastPathComponent)"
        return .init(summary)
    }

    // ── boolean_op ─────────────────────────────────────────────────────

    public enum BooleanOp: String {
        case union, subtract, intersect, split
    }

    public static func booleanOp(
        op: BooleanOp,
        aBodyId: String,
        bBodyId: String,
        outputBodyId: String? = nil,
        removeInputs: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        guard let aBody = manifest.body(withId: aBodyId) else {
            return .init("Body not found: \(aBodyId)")
        }
        guard let bBody = manifest.body(withId: bBodyId) else {
            return .init("Body not found: \(bBodyId)")
        }
        let outId = outputBodyId ?? "\(op.rawValue)-\(aBodyId)-\(bBodyId)"
        if manifest.bodies.contains(where: { $0.id == outId && $0.id != aBodyId && $0.id != bBodyId }) {
            return .init("Output body id \"\(outId)\" already exists. Pass a different outputBodyId.")
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent
        let aShape: Shape
        let bShape: Shape
        do {
            aShape = try Shape.loadBREP(fromPath: "\(outputDir)/\(aBody.file)")
            bShape = try Shape.loadBREP(fromPath: "\(outputDir)/\(bBody.file)")
        } catch {
            return .init("Failed to load input BREP: \(error.localizedDescription)", isError: true)
        }

        // v0.10: prefer the per-input-history variants (gsdali/OCCTSwift#165
        // Tier 1) so remap_selection can resolve via TopologyGraph.findDerived
        // instead of the centroid heuristic. Fall back to the no-history calls
        // only if the WithFullHistory variant returned nil — same observable
        // behaviour as v0.9 for the failure path.
        let output: Shape
        let historyRef: ShapeHistoryRef?
        switch op {
        case .union:
            if let r = aShape.unionWithFullHistory(bShape) {
                output = r.result; historyRef = r.history
            } else if let r = aShape.union(bShape) {
                output = r; historyRef = nil
            } else {
                return .init("Boolean union failed.", isError: true)
            }
        case .subtract:
            if let r = aShape.subtractedWithFullHistory(bShape) {
                output = r.result; historyRef = r.history
            } else if let r = aShape.subtracting(bShape) {
                output = r; historyRef = nil
            } else {
                return .init("Boolean subtract failed.", isError: true)
            }
        case .intersect:
            if let r = aShape.intersectionWithFullHistory(bShape) {
                output = r.result; historyRef = r.history
            } else if let r = aShape.intersection(bShape) {
                output = r; historyRef = nil
            } else {
                return .init("Boolean intersect failed.", isError: true)
            }
        case .split:
            // splitWithFullHistory returns [Shape] pieces + history;
            // wrap multi-piece into a Compound so the manifest holds
            // a single body, the same shape v0.9 produced.
            if let r = aShape.splitWithFullHistory(by: bShape), let first = r.pieces.first {
                output = (r.pieces.count > 1)
                    ? (Shape.compound(r.pieces) ?? first)
                    : first
                historyRef = r.history
            } else if let pieces = aShape.split(by: bShape), let first = pieces.first {
                output = (pieces.count > 1)
                    ? (Shape.compound(pieces) ?? first)
                    : first
                historyRef = nil
            } else {
                return .init("Boolean split failed.", isError: true)
            }
        }

        let outFile = "\(op.rawValue)-\(outId)-\(shortUUID()).brep"
        let outputPath = "\(outputDir)/\(outFile)"
        do {
            try Exporter.writeBREP(shape: output, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)

        // v0.10: translate per-input ShapeHistoryRef into
        // TopologyGraph.recordHistory entries on the post-mutation graph.
        // remap_selection's history path then resolves selections on
        // either input body via findDerived rather than the
        // centroid-distance heuristic.
        if let hist = historyRef {
            await HistoryRegistry.shared.recordBooleanHistory(
                bodyId: outId,
                aBodyId: aBodyId,
                bBodyId: bBodyId,
                aShape: aShape,
                bShape: bShape,
                output: output,
                ref: hist,
                operationName: "boolean_\(op.rawValue)"
            )
        }

        var bodies = manifest.bodies
        bodies.append(BodyDescriptor(
            id: outId,
            file: outFile,
            format: aBody.format,
            name: aBody.name.map { "\(op.rawValue) \($0)" },
            color: aBody.color,
            roughness: aBody.roughness,
            metallic: aBody.metallic
        ))
        if removeInputs {
            for id in [aBodyId, bBodyId] {
                if let idx = bodies.firstIndex(where: { $0.id == id }) {
                    let removed = bodies.remove(at: idx)
                    try? FileManager.default.removeItem(atPath: "\(outputDir)/\(removed.file)")
                }
            }
        }
        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description,
            bodies: bodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        try? store.write(updated)

        let extra = removeInputs ? "; inputs removed" : ""
        return .init("Boolean \(op.rawValue)(\(aBodyId), \(bBodyId)) → \"\(outId)\" (\(outFile))\(extra).")
    }

    // ── mirror_or_pattern ──────────────────────────────────────────────

    public enum PatternKind: String {
        case mirror, linear, circular
    }

    public struct PatternParams {
        // mirror
        public var planeOrigin: SIMD3<Double>?
        public var planeNormal: SIMD3<Double>?
        // linear
        public var direction: SIMD3<Double>?
        public var spacing: Double?
        public var count: Int?
        // circular
        public var axisOrigin: SIMD3<Double>?
        public var axisDirection: SIMD3<Double>?
        public var totalCount: Int?
        public var totalAngle: Double?
        public init() {}
    }

    /// OCCTSwift's pattern primitives return a single (possibly compound)
    /// Shape — different from the Node implementation which split the
    /// compound into N separate BREPs/bodies. Emit one body per call;
    /// callers wanting individual instances can do scene-graph splits in
    /// a follow-up.
    public static func mirrorOrPattern(
        bodyId: String,
        kind: PatternKind,
        params: PatternParams,
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
        let outId = outputBodyId ?? "\(kind.rawValue)-\(bodyId)"
        if manifest.bodies.contains(where: { $0.id == outId }) {
            return .init("Output body id \"\(outId)\" already exists.")
        }

        let shape: Shape
        do {
            shape = try Shape.loadBREP(fromPath: inputPath)
        } catch {
            return .init("Failed to load BREP: \(error.localizedDescription)", isError: true)
        }

        let result: Shape?
        switch kind {
        case .mirror:
            guard let normal = params.planeNormal else {
                return .init("mirror requires `planeNormal`.")
            }
            result = shape.mirrored(planeNormal: normal, planeOrigin: params.planeOrigin ?? .zero)
        case .linear:
            guard let dir = params.direction, let spacing = params.spacing, let count = params.count else {
                return .init("linear requires `direction`, `spacing`, `count`.")
            }
            result = shape.linearPattern(direction: dir, spacing: spacing, count: count)
        case .circular:
            guard let axisO = params.axisOrigin, let axisD = params.axisDirection, let total = params.totalCount else {
                return .init("circular requires `axisOrigin`, `axisDirection`, `totalCount`.")
            }
            result = shape.circularPattern(
                axisPoint: axisO,
                axisDirection: axisD,
                count: total,
                angle: params.totalAngle ?? 0
            )
        }
        guard let output = result else {
            return .init("Pattern \(kind.rawValue) failed.", isError: true)
        }

        let outFile = "\(kind.rawValue)-\(outId)-\(shortUUID()).brep"
        let outputPath = "\(outputDir)/\(outFile)"
        do {
            try Exporter.writeBREP(shape: output, to: URL(fileURLWithPath: outputPath))
        } catch {
            return .init("Failed to write BREP: \(error.localizedDescription)", isError: true)
        }

        await history.snapshot(store: store)
        var bodies = manifest.bodies
        bodies.append(BodyDescriptor(
            id: outId,
            file: outFile,
            format: body.format,
            name: body.name.map { "\(kind.rawValue) \($0)" },
            color: body.color,
            roughness: body.roughness,
            metallic: body.metallic
        ))
        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description,
            bodies: bodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        try? store.write(updated)

        // Mirror provenance — single-target case fits
        // find_correspondences's "one target id per source id" contract.
        // Linear / circular patterns produce N copies, so a single
        // TransformHint can't describe the full mapping; skip those
        // until find_correspondences grows a multi-target return type.
        if kind == .mirror,
           let normal = params.planeNormal {
            let provenance = ProvenanceStore(outputDir: outputDir)
            provenance.upsert(
                bodyId: outId,
                record: ProvenanceRecord(
                    sourceBodyId: bodyId,
                    transform: .mirror(
                        planeOrigin: params.planeOrigin ?? .zero,
                        planeNormal: normal
                    )
                )
            )
        }

        return .init("Pattern \(kind.rawValue) on \"\(bodyId)\" → \"\(outId)\" (\(outFile)).")
    }

    // ── helpers ────────────────────────────────────────────────────────

    static func shortUUID() -> String {
        return String(UUID().uuidString.prefix(8))
    }
}
